-- main.lua — SimpleUI Plus
-- Core plugin entry point, runtime module registry integration, and setup wizard coordinator.
-- Developed by Yanllsama.
--
-- Architecture Note:
--   SimpleUI Plus does NOT modify any files inside simpleui.koplugin.
--   All integrations, backwards compatibility shims (coverdeck, quick_actions),
--   and module registrations are applied dynamically in memory at startup.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings     = require("luasettings")
local DataStorage     = require("datastorage")
if DataStorage and not DataStorage.getPatchesDir then
    function DataStorage:getPatchesDir()
        return self:getDataDir() .. "/patches"
    end
end
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local logger          = require("logger")
local _src_path = debug.getinfo(1, "S") and debug.getinfo(1, "S").source or ""
local _plugin_dir = _src_path:sub(1, 1) == "@" and _src_path:sub(2):match("^(.*)[/\\]main%.lua$")
if _plugin_dir and _plugin_dir ~= "" then
    _G._simpleui_plus_path = _plugin_dir
    if not package.path:find(_plugin_dir, 1, true) then
        package.path = _plugin_dir .. "/?.lua;" .. _plugin_dir .. "/modules/?.lua;" .. package.path
    end
end
local _               = require("infra/plus_i18n").translate

-- Lazy load wizard when needed
local function getWizardDialog()
    local ok, Wizard = pcall(require, "wizard")
    if ok and Wizard then return Wizard end
    return nil
end

local function getSettingsFilePath()
    return DataStorage:getSettingsDir() .. "/simpleui_plus.lua"
end

local function getSUISettings()
    local ok, s = pcall(require, "infra/sui_store")
    if ok and s then return s end
    ok, s = pcall(require, "sui_store")
    if ok and s then return s end
    return nil
end

local function getSimpleUIRegistry()
    local ok, r = pcall(require, "modules/moduleregistry")
    if ok and r then return r end
    ok, r = pcall(require, "desktop_modules/moduleregistry")
    if ok and r then return r end
    return nil
end

-- Discover module_*.lua files inside plugin_dir/modules/
local function discover_modules(plugin_dir)
    if not plugin_dir then return {} end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then
        logger.warn("simpleui_plus: lfs unavailable, skipping module auto-discovery")
        return {}
    end

    local modules = {}
    local ok, iter, dir_obj = pcall(lfs.dir, plugin_dir .. "/modules")
    if not ok then
        logger.warn("simpleui_plus: cannot open modules/ directory: " .. tostring(iter))
        return modules
    end

    for entry in iter, dir_obj do
        local stem = entry:match("^(module_%a[%w_]*)%.lua$")
        if stem then
            modules[#modules + 1] = "modules/" .. stem
        end
    end
    table.sort(modules, function(a, b)
        local a_top = (a:find("currently_yanllsama", 1, true) ~= nil)
        local b_top = (b:find("currently_yanllsama", 1, true) ~= nil)
        if a_top and not b_top then return true end
        if not a_top and b_top then return false end
        return a < b
    end)
    return modules
end

local SimpleUIPlus = WidgetContainer:new{
    name          = "simpleui_plus",
    is_doc_only   = false,
    _settings     = nil,
    _modules_meta = {},     -- Discovered modules: array of module tables
    _registered   = {},     -- Currently registered in SimpleUI: { [id] = mod }
}

function SimpleUIPlus:_getSettings()
    if not self._settings then
        self._settings = LuaSettings:open(getSettingsFilePath())
    end
    return self._settings
end

function SimpleUIPlus:_isSetupCompleted()
    local val = self:_getSettings():readSetting("setup_completed")
    return val == true
end

function SimpleUIPlus:_setSetupCompleted(completed)
    self:_getSettings():saveSetting("setup_completed", completed == true)
    self:_getSettings():flush()
end

function SimpleUIPlus:_isModuleEnabled(mod_id, default_state)
    local states = self:_getSettings():readSetting("module_states") or {}
    local enabled = states[mod_id]
    if enabled == nil then
        return default_state ~= false
    end
    return enabled == true
end

function SimpleUIPlus:_setModuleEnabled(mod_id, enabled)
    local states = self:_getSettings():readSetting("module_states") or {}
    states[mod_id] = (enabled == true)
    self:_getSettings():saveSetting("module_states", states)
    self:_getSettings():flush()
end

function SimpleUIPlus:_loadModuleMetadata()
    self._modules_meta = {}
    local paths = discover_modules(self.path)

    for _idx, path in ipairs(paths) do
        local ok, mod = pcall(require, path)
        if ok and type(mod) == "table" and type(mod.id) == "string" then
            table.insert(self._modules_meta, mod)
        else
            logger.warn("simpleui_plus: failed to load module at " .. tostring(path) .. ": " .. tostring(mod))
        end
    end

    table.sort(self._modules_meta, function(a, b)
        local a_top = (a.id == "currently_yanllsama")
        local b_top = (b.id == "currently_yanllsama")
        if a_top and not b_top then return true end
        if not a_top and b_top then return false end
        return tostring(a.name or a.id) < tostring(b.name or b.id)
    end)
end

-- ---------------------------------------------------------------------------
-- SimpleUI Architecture & Bento Compatibility (SimpleUI 2.0 / 2.5 / 2.7+)
-- ---------------------------------------------------------------------------
function SimpleUIPlus:_setupCompatAliases()
    local function ensureBento(cfg)
        if type(cfg) ~= "table" then return end
        if type(cfg.getBentoWidth) ~= "function" then
            local BENTO_DEF = 100
            local function _clampBento(n)
                n = math.floor(tonumber(n) or BENTO_DEF)
                if n < 20 then n = 20 elseif n > 100 then n = 100 end
                n = math.floor((n + 2.5) / 5) * 5
                if n < 20 then n = 20 elseif n > 100 then n = 100 end
                return n
            end

            cfg.getBentoWidth = function(mod_id, pfx)
                if not mod_id then return BENTO_DEF end
                local SUISettings = getSUISettings()
                local key = (pfx or "simpleui_hs_") .. "bento_width_" .. tostring(mod_id)
                local v = SUISettings and (SUISettings.get and SUISettings:get(key) or (SUISettings.readSetting and SUISettings:readSetting(key)))
                if v == nil then
                    local legacy = _G.G_reader_settings and _G.G_reader_settings:readSetting("simpleui_bento_width_" .. mod_id)
                    if legacy ~= nil then return _clampBento(legacy) end
                    return BENTO_DEF
                end
                return _clampBento(v)
            end

            cfg.setBentoWidth = cfg.setBentoWidth or function(pct, mod_id, pfx)
                if mod_id and pfx then
                    local SUISettings = getSUISettings()
                    local key = (pfx or "simpleui_hs_") .. "bento_width_" .. tostring(mod_id)
                    if SUISettings then
                        if SUISettings.set then SUISettings:set(key, _clampBento(pct))
                        elseif SUISettings.saveSetting then SUISettings:saveSetting(key, _clampBento(pct)) end
                    end
                end
            end

            cfg.makeBentoWidthItem = cfg.makeBentoWidthItem or function(opts)
                return { text_func = opts and opts.text_func, callback = function() end }
            end
            logger.info("simpleui_plus: attached getBentoWidth fallback to Config")
        end

        if type(cfg.applyLabelToggle) ~= "function" then
            cfg.applyLabelToggle = function(mod, default_label)
                if cfg.isLabelHidden and cfg.isLabelHidden(mod.id) then
                    mod.label = nil
                else
                    mod.label = default_label or mod.label
                end
            end
            logger.info("simpleui_plus: attached applyLabelToggle fallback to Config")
        end

        if type(cfg.makeLabelToggleItem) == "function" and not cfg._plus_wrapped_makeLabelToggle then
            cfg._plus_wrapped_makeLabelToggle = true
            local orig_make = cfg.makeLabelToggleItem
            cfg.makeLabelToggleItem = function(mod_id, b, c, d)
                if type(b) == "string" and type(c) == "function" then
                    return orig_make(mod_id, c, d)
                end
                return orig_make(mod_id, b, c)
            end
        end
    end

    -- 1. Resolve Config: prefer modern infra/sui_config, fallback to sui_config
    local Config = package.loaded["infra/sui_config"] or package.loaded["sui_config"]
    if not Config then
        local ok_c, c = pcall(require, "infra/sui_config")
        if ok_c and c then Config = c end
    end
    if not Config then
        local ok_c, c = pcall(require, "sui_config")
        if ok_c and c then Config = c end
    end
    if Config and type(Config) == "table" then
        ensureBento(Config)
        package.loaded["infra/sui_config"] = Config
        package.loaded["sui_config"] = Config
    end

    -- 2. Style, Font Variants & Theme fallback
    local _VARIANT_FLAGS = {
        regular    = { bold = false, italic = false },
        bold       = { bold = true,  italic = false },
        italic     = { bold = false, italic = true  },
        bolditalic = { bold = true,  italic = true  },
    }
    local function _variantName(bold, italic)
        if bold then return italic and "bolditalic" or "bold" end
        return italic and "italic" or "regular"
    end

    local function ensureStyle(style)
        if type(style) ~= "table" then return end

        -- Font variants fallback (required by sui_config.lua:925: getChromeLabelStyle / isVariant)
        if not style.VARIANTS then
            style.VARIANTS = { "regular", "bold", "italic", "bolditalic" }
        end
        if type(style.isVariant) ~= "function" then
            style.isVariant = function(variant)
                return _VARIANT_FLAGS[variant] and true or false
            end
        end
        if type(style.emphasize) ~= "function" then
            style.emphasize = function(variant)
                local flags = _VARIANT_FLAGS[variant] or _VARIANT_FLAGS.regular
                return _variantName(true, flags.italic)
            end
        end

        -- Theme color fallback (required by sui_window.lua:1268: _PageDotClass / getThemeColor)
        if type(style.getThemeColor) ~= "function" then
            style.getThemeColor = function(role)
                local SUISettings = package.loaded["sui_store"] or package.loaded["infra/sui_store"]
                if not SUISettings then
                    local ok, s = pcall(require, "infra/sui_store")
                    if ok and s then SUISettings = s end
                    if not SUISettings then
                        ok, s = pcall(require, "sui_store")
                        if ok and s then SUISettings = s end
                    end
                end
                if SUISettings and type(SUISettings.get) == "function" then
                    local hex = SUISettings:get("simpleui_theme_color_" .. tostring(role))
                    if hex and type(hex) == "string" and hex:match("^#%x%x%x%x%x%x$") then
                        local r = tonumber(hex:sub(2, 3), 16)
                        local g = tonumber(hex:sub(4, 5), 16)
                        local b = tonumber(hex:sub(6, 7), 16)
                        local Blitbuffer = require("ffi/blitbuffer")
                        return Blitbuffer.rgb888(r, g, b)
                    end
                end
                return nil
            end
            logger.info("simpleui_plus: attached getThemeColor fallback to SUIStyle")
        end
        if type(style.setThemeColor) ~= "function" then
            style.setThemeColor = function(role, hex) end
        end
        if type(style.resetTheme) ~= "function" then
            style.resetTheme = function() end
        end
        if type(style.makeThemeMenuItems) ~= "function" then
            style.makeThemeMenuItems = function() return {} end
        end
    end

    -- 3. Alias essential modules across both structured and flat require paths
    local function aliasMod(short_name, preferred_folder)
        local candidates = {}
        if preferred_folder then table.insert(candidates, preferred_folder .. "/" .. short_name) end
        for _, f in ipairs({"engines", "features", "screens", "infra", "modules"}) do
            if f ~= preferred_folder then table.insert(candidates, f .. "/" .. short_name) end
        end
        table.insert(candidates, short_name)

        local m
        for _, path in ipairs(candidates) do
            m = package.loaded[path]
            if m then break end
        end
        if not m then
            for _, path in ipairs(candidates) do
                local ok, mod = pcall(require, path)
                if ok and mod then
                    m = mod
                    break
                end
            end
        end
        if m then
            for _, path in ipairs(candidates) do
                package.loaded[path] = m
            end
        end
        return m
    end

    aliasMod("sui_store", "infra")
    aliasMod("sui_core", "infra")
    aliasMod("sui_config", "infra")
    local SUIStyle = aliasMod("sui_style", "features")
    aliasMod("sui_i18n", "infra")
    local SH = aliasMod("module_books_shared", "modules")
    aliasMod("sui_aa_paint", "infra")
    aliasMod("sui_window", "engines")
    aliasMod("sui_stats_windows", "screens")
    aliasMod("sui_screen_engine", "engines")
    aliasMod("sui_action_sheet", "engines")
    aliasMod("sui_tab_window", "engines")
    aliasMod("sui_settings_window", "screens")
    aliasMod("sui_homescreen", "screens")
    local PatchCompat = aliasMod("sui_patch_compat", "features")

    if PatchCompat and type(PatchCompat.check) == "function" and not PatchCompat._plus_hooked then
        PatchCompat._plus_hooked = true
        local orig_check = PatchCompat.check
        PatchCompat.check = function()
            local ok_ds, DS = pcall(require, "datastorage")
            if ok_ds and DS and not DS.getPatchesDir then
                DS.getPatchesDir = function(s) return s:getDataDir() .. "/patches" end
            end
            return orig_check()
        end
    end

    if SH and not SH._plus_hooked then
        SH._plus_hooked = true
        local orig_prefetch = SH.prefetchBooks
        if type(orig_prefetch) == "function" then
            SH.prefetchBooks = function(show_currently, show_recent, max_recent, opts)
                local S = getSUISettings()
                local yan_on = S and (S:readSetting("sui_plus_mod_currently_yanllsama") == true or S:readSetting("simpleui_hs_currently_yanllsama") == true)
                if yan_on then
                    show_currently = true
                    if not show_recent or (max_recent or 0) < 7 then
                        show_recent = true
                        max_recent = math.max(max_recent or 0, 7)
                    end
                end
                return orig_prefetch(show_currently, show_recent, max_recent, opts)
            end
            logger.info("simpleui_plus: attached prefetchBooks hook for currently_yanllsama")
        end
    end

    if SUIStyle then ensureStyle(SUIStyle) end
    if package.loaded["sui_style"] then ensureStyle(package.loaded["sui_style"]) end
    if package.loaded["features/sui_style"] then ensureStyle(package.loaded["features/sui_style"]) end
    if package.loaded["infra/sui_style"] then ensureStyle(package.loaded["infra/sui_style"]) end
end

-- ---------------------------------------------------------------------------
-- Dynamic SimpleUI In-Memory Compatibility Hooks (No SimpleUI files modified)
-- ---------------------------------------------------------------------------
function SimpleUIPlus:_installSimpleUIHooks()
    self:_setupCompatAliases()
    local SUISettings = getSUISettings()

    -- 1. Recover quick_actions instances (e.g. quick_actions_1) if not yet materialized
    if SUISettings then
        local inst_key = "simpleui_qa_row_instances"
        local inst_ids = SUISettings:readSetting(inst_key) or {}
        if #inst_ids == 0 then
            local order = SUISettings:readSetting("simpleui_hs_module_order") or {}
            local found = {}
            for _, id in ipairs(order) do
                if type(id) == "string" and (id:match("^quick_actions_%d+$") or id:match("^quick_actions_row_%w+$")) then
                    table.insert(found, id)
                end
            end
            if #found > 0 then
                table.sort(found)
                SUISettings:set(inst_key, found)
                logger.info("simpleui_plus: dynamically recovered quick_actions instances into " .. inst_key .. ": " .. table.concat(found, ", "))
            end
        end
    end

    -- 2. Hook moduleregistry: on-the-fly instance resolution and legacy key compatibility
    local Registry = getSimpleUIRegistry()
    if Registry and not Registry._plus_hooked then
        Registry._plus_hooked = true

        local orig_get = Registry.get
        Registry.get = function(id)
            local m = orig_get(id)
            if m then return m end
            if id and id:match("^quick_actions_") and Registry.isInstanciable("quick_actions_row") then
                local base = Registry.getBase("quick_actions_row")
                if base and type(base.makeInstance) == "function" then
                    local inst = base.makeInstance(id)
                    if inst then return inst end
                end
            end
            return nil
        end

        local orig_isEnabled = Registry.isEnabled
        Registry.isEnabled = function(mod, pfx)
            if not mod then return false end
            pfx = pfx or "simpleui_hs_"
            local S = getSUISettings()
            if S then
                -- In legacy flat mode (no simpleui_layout), suppress built-in "currently" if currently_yanllsama is enabled
                local layout = S:readSetting("simpleui_layout")
                if not layout and mod.id == "currently" then
                    local yan_on = S:readSetting(pfx .. "currently_yanllsama")
                    if yan_on == nil then yan_on = S:readSetting("sui_plus_mod_currently_yanllsama") end
                    if yan_on == true then
                        return false
                    end
                end
                -- Legacy coverdeck setting: "simpleui_hs_coverdeck"
                if mod.id == "coverdeck" then
                    local v = S:readSetting(pfx .. "coverdeck_enabled")
                    if v == nil then v = S:readSetting(pfx .. "coverdeck") end
                    if v ~= nil then return v == true end
                end
                -- Legacy quick_actions setting: "simpleui_hs_quick_actions_1_enabled"
                if mod.id and mod.id:match("^quick_actions_") then
                    local v = S:readSetting(pfx .. mod.id .. "_enabled")
                    if v ~= nil then return v == true end
                end
                -- Any module managed by SimpleUI Plus: if disabled in Plus settings, suppress
                if mod.id then
                    local plus_en = S:readSetting("sui_plus_mod_" .. mod.id)
                    if plus_en == false then return false end
                end
            end
            return orig_isEnabled(mod, pfx)
        end

        local orig_loadOrder = Registry.loadOrder
        if type(orig_loadOrder) == "function" then
            Registry.loadOrder = function(pfx)
                local order = orig_loadOrder(pfx)
                local S = getSUISettings()
                pfx = pfx or "simpleui_hs_"
                -- Only modify loadOrder if simpleui_layout is NOT yet present (legacy 2.x mode or initial setup)
                local layout = S and S:readSetting("simpleui_layout")
                if not layout and type(order) == "table" then
                    local yan_on = S and (S:readSetting("sui_plus_mod_currently_yanllsama") == true or S:readSetting(pfx .. "currently_yanllsama") == true)
                    if yan_on then
                        local new_order = {}
                        local placed = false
                        for _, id in ipairs(order) do
                            if id == "currently" then
                                table.insert(new_order, "currently_yanllsama")
                                placed = true
                            elseif id == "currently_yanllsama" then
                                if not placed then
                                    table.insert(new_order, id)
                                    placed = true
                                end
                            else
                                table.insert(new_order, id)
                            end
                        end
                        if not placed then
                            table.insert(new_order, 1, "currently_yanllsama")
                        end
                        return new_order
                    end
                end
                return order
            end
        end
        logger.info("simpleui_plus: installed in-memory hooks for SimpleUI Registry")
    end

    -- 3. Hook module_coverdeck in memory
    local ok_cd, Coverdeck = pcall(require, "modules/module_coverdeck")
    if not ok_cd or not Coverdeck then
        ok_cd, Coverdeck = pcall(require, "desktop_modules/module_coverdeck")
    end
    if ok_cd and Coverdeck and not Coverdeck._plus_hooked then
        Coverdeck._plus_hooked = true
        local orig_cd_isEnabled = Coverdeck.isEnabled
        Coverdeck.isEnabled = function(pfx)
            pfx = pfx or "simpleui_hs_"
            local S = getSUISettings()
            if S then
                local v = S:readSetting(pfx .. "coverdeck_enabled")
                if v == nil then v = S:readSetting(pfx .. "coverdeck") end
                if v ~= nil then return v == true end
            end
            if type(orig_cd_isEnabled) == "function" then
                return orig_cd_isEnabled(pfx)
            end
            return Coverdeck.default_on ~= false
        end
        logger.info("simpleui_plus: installed in-memory hook for module_coverdeck")
    end

    -- 4. Hook SUIWindow.MenuTable in memory for hold support
    local SUI = package.loaded["engines/sui_window"] or package.loaded["sui_window"]
    if not SUI then
        local ok, s = pcall(require, "engines/sui_window")
        if ok and s then SUI = s end
    end
    if not SUI then
        local ok, s = pcall(require, "sui_window")
        if ok and s then SUI = s end
    end
    if SUI and type(SUI.MenuTable) == "function" and not SUI._plus_hold_patched then
        SUI._plus_hold_patched = true
        local orig_MenuTable = SUI.MenuTable
        SUI.MenuTable = function(opts)
            if opts and type(opts.items) == "table" then
                for _, item in ipairs(opts.items) do
                    if not item.sui_build and (item.on_hold or item.hold_callback) then
                        local user_hold = item.on_hold or item.hold_callback
                        item.sui_build = function(build_ctx)
                            local is_disabled = (item.dim == true)
                            local title = type(item.text_func) == "function" and item.text_func() or item.text
                            local checked
                            if type(item.checked_func) == "function" then
                                checked = (item.checked_func() == true)
                            end
                            local row = SUI.ListRow{
                                title = title,
                                inner_w = (build_ctx and build_ctx.inner_w) or Screen:getWidth(),
                                checked = checked,
                                on_tap = not is_disabled and item.callback or nil,
                                on_hold = not is_disabled and function() user_hold() end or nil,
                                on_more = not is_disabled and item.on_more or nil,
                            }
                            local ic = row and row[1]
                            if ic and ic.ges_events and not is_disabled then
                                local GestureRange = require("ui/gesturerange")
                                local h_done = false
                                ic.ges_events.Hold = { GestureRange:new{ ges = "hold", range = function() return ic.dimen end } }
                                ic.ges_events.HoldRelease = { GestureRange:new{ ges = "hold_release", range = function() return ic.dimen end } }
                                function ic:onHold() h_done = true; user_hold(); return true end
                                function ic:onHoldRelease() if not h_done then user_hold() end; h_done = false; return true end
                            end
                            return row
                        end
                    end
                end
            end
            return orig_MenuTable(opts)
        end
        logger.info("simpleui_plus: in-memory SUIWindow.MenuTable hold support installed")
    end

    -- 5. Make top-left back button (chevron_left) in SUIWindow always exit the current menu/submenu
    -- instead of paging backwards when _current_page > 1.
    if SUI and type(SUI._buildTitleBar) == "function" and not SUI._plus_back_exit_patched then
        SUI._plus_back_exit_patched = true
        local orig_buildTitleBar = SUI._buildTitleBar
        SUI._buildTitleBar = function(self, ctx)
            local saved_page = self._current_page
            if saved_page and saved_page > 1 then
                self._current_page = 1
            end
            local ok, bar, h = pcall(orig_buildTitleBar, self, ctx)
            self._current_page = saved_page
            if not ok then error(bar) end
            return bar, h
        end
        logger.info("simpleui_plus: in-memory SUIWindow back-exits-menu patch installed")
    end
end

-- Refresh SimpleUI home screen if it's currently open
function SimpleUIPlus:_refreshSimpleUI()
    local UIManager = require("ui/uimanager")
    pcall(function()
        local HS = package.loaded["screens/sui_homescreen"] or package.loaded["engines/sui_screen_engine"]
        if not HS then
            local ok, h = pcall(require, "screens/sui_homescreen")
            if ok and h then HS = h end
        end
        if HS then
            if type(HS.invalidateAllCfgAndRefresh) == "function" then
                HS.invalidateAllCfgAndRefresh(true)
            end
            if type(HS.rebuildLayout) == "function" then
                HS.rebuildLayout()
            elseif type(HS.refresh) == "function" then
                HS.refresh(false)
            end
        end

        local ok_hs, Homescreen = pcall(require, "sui_homescreen")
        if ok_hs and Homescreen and Homescreen._instance and type(Homescreen._instance._refreshImmediate) == "function" then
            Homescreen._instance:_refreshImmediate(false)
        end

        UIManager:broadcastEvent(require("ui/event"):new("SimpleUIHomescreenRefresh"))
    end)
end

-- Prewarm caches for book-based modules (e.g. hero_currently, recent_book_stats)
function SimpleUIPlus:_prewarmBookModuleCaches()
    if not self._modules_meta or #self._modules_meta == 0 then return end
    local has_prewarm = false
    for _i, mod in ipairs(self._modules_meta) do
        if type(mod.prewarm) == "function" then
            has_prewarm = true
            break
        end
    end
    if not has_prewarm then return end

    pcall(function()
        local ok_cfg, Config = pcall(require, "infra/sui_config")
        if not ok_cfg or not Config then ok_cfg, Config = pcall(require, "sui_config") end
        if not ok_cfg or not Config or type(Config.openStatsDB) ~= "function" then return end
        local db_conn = Config.openStatsDB()
        if not db_conn then return end

        local ok_sh, SH = pcall(require, "desktop_modules/module_books_shared")
        if not ok_sh or not SH then ok_sh, SH = pcall(require, "modules/module_books_shared") end
        if not ok_sh or not SH or type(SH.prefetchBooks) ~= "function" then
            pcall(function() db_conn:close() end)
            return
        end

        local books_state
        pcall(function()
            books_state = SH.prefetchBooks(true, true, 5)
        end)
        if not books_state then
            pcall(function() db_conn:close() end)
            return
        end

        for _i, mod in ipairs(self._modules_meta) do
            if type(mod.prewarm) == "function" then
                pcall(function() mod.prewarm(books_state, db_conn) end)
            end
        end

        pcall(function() db_conn:close() end)
    end)
end

function SimpleUIPlus:onCloseDocument()
    for _i, mod in ipairs(self._modules_meta) do
        if type(mod.invalidateCache) == "function" then
            pcall(function() mod.invalidateCache() end)
        end
    end
end

-- Synchronize SimpleUI module order and layout for SimpleUI Plus modules
function SimpleUIPlus:_syncLayoutAndOrder(states)
    local SUISettings = getSUISettings()
    if not SUISettings then return end

    local pfx = "simpleui_hs_"
    local is_yan_enabled
    if states and states["currently_yanllsama"] ~= nil then
        is_yan_enabled = (states["currently_yanllsama"] == true)
    else
        is_yan_enabled = self:_isModuleEnabled("currently_yanllsama", true)
    end

    -- 1. Synchronize simpleui_hs_module_order
    local order = SUISettings:readSetting(pfx .. "module_order")
    if type(order) == "table" and #order > 0 then
        local changed = false
        local new_order = {}
        local placed = false

        if is_yan_enabled then
            for _i, id in ipairs(order) do
                if id == "currently" then
                    table.insert(new_order, "currently_yanllsama")
                    placed = true
                    changed = true
                elseif id == "currently_yanllsama" then
                    if not placed then
                        table.insert(new_order, id)
                        placed = true
                    else
                        changed = true
                    end
                else
                    table.insert(new_order, id)
                end
            end
            if not placed and not self:_isSetupCompleted() then
                table.insert(new_order, 1, "currently_yanllsama")
                changed = true
            end
        else
            for _i, id in ipairs(order) do
                if id == "currently_yanllsama" then
                    table.insert(new_order, "currently")
                    changed = true
                else
                    table.insert(new_order, id)
                end
            end
        end

        if changed then
            SUISettings:saveSetting(pfx .. "module_order", new_order)
            logger.info("simpleui_plus: synced " .. pfx .. "module_order for currently_yanllsama")
        end
    end

    -- 2. Synchronize simpleui_layout (SimpleUI 3.0 layout sheet)
    local layout = SUISettings:readSetting("simpleui_layout")
    if type(layout) == "table" and type(layout.pages) == "table" then
        local changed = false
        local has_yan = false
        for _, page in ipairs(layout.pages) do
            if type(page.modules) == "table" then
                for _i, entry in ipairs(page.modules) do
                    local mid = type(entry) == "table" and entry.id or entry
                    if mid == "currently_yanllsama" then
                        has_yan = true
                    end
                end
            end
        end

        if is_yan_enabled then
            if not has_yan then
                for _, page in ipairs(layout.pages) do
                    if type(page.modules) == "table" then
                        for i, entry in ipairs(page.modules) do
                            local mid = type(entry) == "table" and entry.id or entry
                            if mid == "currently" then
                                if type(entry) == "table" then
                                    entry.id = "currently_yanllsama"
                                else
                                    page.modules[i] = "currently_yanllsama"
                                end
                                has_yan = true
                                changed = true
                                break
                            end
                        end
                    end
                    if changed then break end
                end
            end
            -- Note: If neither currently nor currently_yanllsama is placed, do NOT forcibly insert it into page 1
            -- unless this is the very first setup (wizard apply on fresh install).
            -- Respect the user's manual deletions in SimpleUI's layout editor!
            if not has_yan and not self:_isSetupCompleted() and #layout.pages > 0 and type(layout.pages[1].modules) == "table" then
                table.insert(layout.pages[1].modules, 1, "currently_yanllsama")
                changed = true
            end
        else
            for _, page in ipairs(layout.pages) do
                if type(page.modules) == "table" then
                    for i, entry in ipairs(page.modules) do
                        local mid = type(entry) == "table" and entry.id or entry
                        if mid == "currently_yanllsama" then
                            if type(entry) == "table" then
                                entry.id = "currently"
                            else
                                page.modules[i] = "currently"
                            end
                            changed = true
                        end
                    end
                end
            end
        end

        if changed then
            SUISettings:saveSetting("simpleui_layout", layout)
            logger.info("simpleui_plus: synced simpleui_layout for currently_yanllsama")
        end
    end
end

-- Synchronize modules with SimpleUI moduleregistry and sui_store
function SimpleUIPlus:_applyModuleStates(states)
    local Registry = getSimpleUIRegistry()
    local SUISettings = getSUISettings()

    for _idx, mod in ipairs(self._modules_meta) do
        local should_enable = (states[mod.id] == true)
        self:_setModuleEnabled(mod.id, should_enable)

        if SUISettings then
            SUISettings:saveSetting("sui_plus_mod_" .. mod.id, should_enable)
            if not should_enable then
                SUISettings:saveSetting("simpleui_hs_" .. mod.id, false)
                if mod.enabled_key then
                    SUISettings:saveSetting("simpleui_hs_" .. mod.enabled_key, false)
                end
            end
        end

        if Registry and type(mod.build) == "function" then
            if should_enable then
                if not self._registered[mod.id] then
                    Registry.register(mod)
                    self._registered[mod.id] = mod
                    logger.info("simpleui_plus: registered widget module '" .. mod.id .. "'")
                end
            else
                if self._registered[mod.id] then
                    if type(Registry.unregister) == "function" then
                        Registry.unregister(mod.id)
                    end
                    self._registered[mod.id] = nil
                    logger.info("simpleui_plus: unregistered widget module '" .. mod.id .. "'")
                end
            end
        end
    end

    self:_syncLayoutAndOrder(states)

    if SUISettings then
        pcall(function() SUISettings:flush() end)
    end

    self:_refreshSimpleUI()
end

function SimpleUIPlus:_registerModules()
    self:_loadModuleMetadata()
    local Registry = getSimpleUIRegistry()
    if not Registry then
        logger.warn("simpleui_plus: SimpleUI moduleregistry not found. Make sure SimpleUI is installed.")
        return
    end

    local SUISettings = getSUISettings()

    for _idx, mod in ipairs(self._modules_meta) do
        local is_enabled = self:_isModuleEnabled(mod.id, mod.default_enabled)
        if is_enabled then
            if Registry and type(mod.build) == "function" then
                Registry.register(mod)
                self._registered[mod.id] = mod
                logger.info("simpleui_plus: auto-registered widget module '" .. mod.id .. "'")
            end
            if SUISettings then
                if SUISettings:readSetting("sui_plus_mod_" .. mod.id) == nil then
                    SUISettings:saveSetting("sui_plus_mod_" .. mod.id, true)
                end
                -- Do NOT force simpleui_hs_ flags to true if they already exist,
                -- so user deletions in SimpleUI layout editor are preserved.
                if mod.enabled_key and SUISettings:readSetting("simpleui_hs_" .. mod.enabled_key) == nil then
                    SUISettings:saveSetting("simpleui_hs_" .. mod.enabled_key, true)
                end
            end
        end
    end

    -- Only sync layout on initial setup, never on subsequent boots
    if not self:_isSetupCompleted() then
        self:_syncLayoutAndOrder()
    end

    if SUISettings then
        pcall(function() SUISettings:flush() end)
    end
end

-- Open the interactive Setup Wizard
function SimpleUIPlus:showWizard(is_manual)
    local WizardDialog = getWizardDialog()
    if not WizardDialog then
        logger.err("simpleui_plus: cannot load WizardDialog")
        return
    end

    self:_loadModuleMetadata()

    local current_states = {}
    for _idx, mod in ipairs(self._modules_meta) do
        current_states[mod.id] = self:_isModuleEnabled(mod.id, mod.default_enabled)
    end

    local plugin = self
    local wizard = WizardDialog:new{
        modules        = self._modules_meta,
        current_states = current_states,
        on_apply       = function(selected_dict)
            plugin:_setSetupCompleted(true)
            plugin:_applyModuleStates(selected_dict)

            UIManager:show(InfoMessage:new{
                text = _("SimpleUI Plus: Selected modules have been saved and enabled on the SimpleUI home screen."),
                timeout = 4,
            })
        end,
        on_cancel      = function()
            plugin:_setSetupCompleted(true)
        end,
    }

    logger.info("simpleui_plus: showWizard called, is_manual=" .. tostring(is_manual) .. ", discovered=" .. tostring(#self._modules_meta))
    UIManager:show(wizard)
    UIManager:setDirty(wizard, "full")
end

function SimpleUIPlus:_seedBundledProfiles()
    pcall(function()
        local ok, mod = pcall(require, "modules/module_currently_yanllsama")
        if ok and mod and type(mod.seedBundledProfiles) == "function" then
            mod.seedBundledProfiles("simpleui_hs_", false)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function SimpleUIPlus:init()
    _G._simpleui_plus_path = self.path
    if self.path and not package.path:find(self.path, 1, true) then
        package.path = self.path .. "/?.lua;" .. self.path .. "/modules/?.lua;" .. package.path
    end
    pcall(function()
        local pi = package.loaded["infra/plus_i18n"]
        if pi and type(pi.reset) == "function" then pi.reset() end
        local cfg_mod = package.loaded["modules/currently_reading/config"]
        if cfg_mod and cfg_mod.CFG and type(cfg_mod.CFG.refreshTranslations) == "function" then
            cfg_mod.CFG.refreshTranslations()
        end
    end)

    -- Immediate compatibility setup so Config and aliases are ready before any UI render
    pcall(function() self:_setupCompatAliases() end)

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Delay registration by one scheduler tick so that all plugins
    -- (including SimpleUI itself) have finished their own init().
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(0, function()
        self:_setupCompatAliases()
        self:_installSimpleUIHooks()
        self:_registerModules()
        self:_seedBundledProfiles()
        self:_prewarmBookModuleCaches()
        if not self:_isSetupCompleted() then
            self:showWizard(false)
        end
    end)
end

function SimpleUIPlus:onClosePlugin()
    local Registry = getSimpleUIRegistry()
    if Registry and type(Registry.unregister) == "function" then
        for id, _ in pairs(self._registered) do
            Registry.unregister(id)
        end
    end
    self._registered = {}
    self._modules_meta = {}
end

-- ---------------------------------------------------------------------------
-- Menu Integration
-- ---------------------------------------------------------------------------
function SimpleUIPlus:addToMainMenu(menu_list)
    menu_list["simpleui_plus"] = {
        text_func = function() return _("SimpleUI Plus") end,
        sorting_hint = "tools",
        sub_item_table_func = function() return {
            {
                text = _("Setup Wizard"),
                help_text = _("Open the setup wizard to select and toggle modules."),
                callback = function() self:showWizard(true) end,
            },
            {
                text = _("Modules"),
                sub_item_table_func = function() return self:_buildModuleToggleMenu() end,
            },
            {
                text = _("About"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("SimpleUI Plus v3.0.0\nDeveloper: Yanllsama\n\nEnhanced reading modules and interactive setup wizard suite for SimpleUI."),
                    })
                end,
            },
        } end,
    }
end

function SimpleUIPlus:_buildModuleToggleMenu()
    local menu = {}
    self:_loadModuleMetadata()

    for _idx, mod in ipairs(self._modules_meta) do
        local mod_id = mod.id
        table.insert(menu, {
            text = mod.name or mod_id,
            help_text = mod.description,
            checked_func = function()
                return self:_isModuleEnabled(mod_id, mod.default_enabled)
            end,
            callback = function()
                local currently_on = self:_isModuleEnabled(mod_id, mod.default_enabled)
                local new_state = not currently_on
                local current_states = {}
                for _idx, m in ipairs(self._modules_meta) do
                    current_states[m.id] = self:_isModuleEnabled(m.id, m.default_enabled)
                end
                current_states[mod_id] = new_state
                self:_applyModuleStates(current_states)
            end,
        })
    end

    if #menu == 0 then
        table.insert(menu, {
            text = _("No modules available"),
            enabled = false,
        })
    end

    return menu
end

return SimpleUIPlus
