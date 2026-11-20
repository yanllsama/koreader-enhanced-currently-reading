-- modules/currently_reading/profiles.lua — Profile snapshot, apply, reset, seed, and export logic.

local logger = require("logger")

local C            = require("modules/currently_reading/config")
local CFG          = C.CFG
local _            = C._
local getSUIModule = C.getSUIModule

local M = {}

local function cloneVal(v)
    if type(v) ~= "table" then return v end
    local res = {}
    for k, val in pairs(v) do
        res[k] = cloneVal(val)
    end
    return res
end

-- SimpleUI's SUISettings:set / :saveSetting / :del flush to disk on every call.
-- Batching ~80 key updates inside setNoFlush / delNoFlush avoids 80x synchronous flash I/O.
local function withBatchWrite(SUISettings, fn)
    if not SUISettings or type(SUISettings.setNoFlush) ~= "function" then
        return fn()
    end
    local orig_set         = SUISettings.set
    local orig_saveSetting = SUISettings.saveSetting
    local orig_del         = SUISettings.del
    local orig_delSetting  = SUISettings.delSetting
    local no_flush_del     = type(SUISettings.delNoFlush) == "function" and SUISettings.delNoFlush
        or function(self, k) return self:setNoFlush(k, nil) end

    SUISettings.set         = SUISettings.setNoFlush
    SUISettings.saveSetting = SUISettings.setNoFlush
    SUISettings.del         = no_flush_del
    SUISettings.delSetting  = no_flush_del

    local ok, r1, r2 = pcall(fn)

    SUISettings.set         = orig_set
    SUISettings.saveSetting = orig_saveSetting
    SUISettings.del         = orig_del
    SUISettings.delSetting  = orig_delSetting

    if not ok then error(r1) end
    return r1, r2
end

local PROFILE_KEYS = {
    CFG.SETTING_SOURCE,
    CFG.COVER_DECK_MODE_KEY,
    CFG.COVER_GAP_KEY,

    CFG.TITLE_POS_X_KEY,
    CFG.TITLE_POS_Y_KEY,
    CFG.TITLE_FS_KEY,
    CFG.TITLE_FONT_KEY,
    CFG.AUTHOR_FS_KEY,
    CFG.AUTHOR_FONT_KEY,
    CFG.TITLE_LINE_GAP_KEY,
    CFG.AUTHOR_GAP_KEY,
    CFG.TITLE_COLOR_KEY,
    CFG.AUTHOR_COLOR_KEY,

    CFG.STATS_POS_X_KEY,
    CFG.STATS_POS_Y_KEY,
    CFG.VISUALS_POS_X_KEY,
    CFG.VISUALS_POS_Y_KEY,
    CFG.SHOW_STATS_BORDER_KEY,
    CFG.SHOW_VISUALS_BORDER_KEY,
    CFG.BORDER_RADIUS_KEY,
    CFG.HEADER_RADIUS_KEY,
    CFG.STATS_WIDTH_RATIO_KEY,
    CFG.SIDE_MARGIN_KEY,

    CFG.GRID_COLS_KEY,
    CFG.GRID_ROWS_KEY,
    CFG.STAT_ORDER_KEY,
    CFG.ACTIVE_STATS_KEY,
    CFG.VAL_FS_KEY,
    CFG.LBL_FS_KEY,
    CFG.VAL_FONT_KEY,
    CFG.LBL_FONT_KEY,
    CFG.VAL_BOLD_KEY,
    CFG.LBL_BOLD_KEY,
    CFG.STAT_ROW_GAP_KEY,
    CFG.HDR_ROW_GAP_KEY,
    CFG.LBL_GAP_KEY,
    CFG.VAL_COLOR_KEY,
    CFG.LBL_COLOR_KEY,
    CFG.HDR_COLOR_KEY,

    CFG.SHOW_HEADERS_KEY,
    CFG.HEADER_STYLE_KEY,
    CFG.HEADER_WEIGHT_KEY,
    CFG.HEADER_TXT_PFX .. "1",
    CFG.HEADER_TXT_PFX .. "2",
    CFG.HEADER_TXT_PFX .. "3",
    CFG.HEADER_TXT_PFX .. "4",

    CFG.SHOW_VISUALS_KEY,
    CFG.ACTIVE_VISUALS_KEY,
    CFG.BAR_STYLE_KEY,
    CFG.BAR_THICKNESS_KEY,
    CFG.BAR_THICK_V2_KEY,
    CFG.VBAR_THICKNESS_KEY,
    CFG.HBAR_THICKNESS_KEY,
    CFG.RING_VARIANT_KEY,
    CFG.VBAR_VARIANT_KEY,
    CFG.HBAR_VARIANT_KEY,
    CFG.BAR_HEIGHT_PCT_KEY,
    CFG.VBAR_HEIGHT_PCT_KEY,
    CFG.HBAR_LENGTH_PCT_KEY,
    CFG.BAR_GAP_PCT_KEY,
    CFG.VBAR_GAP_PCT_KEY,
    CFG.HBAR_GAP_KEY,
    CFG.BAR_POS_Y_KEY,
    CFG.BAR_LBL_FS_KEY,
    CFG.BAR_LBL_FONT_KEY,
    CFG.BAR_LBL_BOLD_KEY,
    CFG.BAR_LBL_COLOR_KEY,
    CFG.STATS_BG_COLOR_KEY,
    CFG.VIS_COLOR_1_KEY,
    CFG.VIS_COLOR_2_KEY,
    CFG.VIS_COLOR_3_KEY,
    CFG.VIS_TRACK_COLOR_KEY,
    CFG.SHOW_RING_LABELS_KEY,
    CFG.DAILY_PAGE_GOAL_KEY,
    CFG.DAILY_TIME_GOAL_KEY,
    CFG.WEEK_PAGE_GOAL_KEY,
    CFG.WEEK_TIME_GOAL_KEY,
    CFG.MONTH_PAGE_GOAL_KEY,
    CFG.MONTH_TIME_GOAL_KEY,
    CFG.YEAR_PAGE_GOAL_KEY,
    CFG.YEAR_TIME_GOAL_KEY,
    CFG.YEAR_BOOK_GOAL_KEY,

    CFG.SK_TIME_FMT,
}

M.PROFILE_KEYS = PROFILE_KEYS

function M.captureCurrentProfileData(pfx)
    local SUISettings = getSUIModule("sui_store", "infra")
    local Config = C.getConfig()
    local data = {
        [CFG.SETTING_SOURCE]         = CFG.getSource(pfx),
        [CFG.COVER_DECK_MODE_KEY]    = CFG.getCoverDeckMode(pfx),
        [CFG.COVER_GAP_KEY]          = CFG.getCoverGapPct(pfx),

        [CFG.TITLE_POS_X_KEY]        = CFG.getTitlePosX(pfx),
        [CFG.TITLE_POS_Y_KEY]        = CFG.getTitlePosY(pfx),
        [CFG.TITLE_FS_KEY]           = CFG.getTitleFs(pfx),
        [CFG.TITLE_FONT_KEY]         = CFG.getTitleFont(pfx),
        [CFG.AUTHOR_FS_KEY]          = CFG.getAuthorFs(pfx),
        [CFG.AUTHOR_FONT_KEY]        = CFG.getAuthorFont(pfx),
        [CFG.TITLE_LINE_GAP_KEY]     = CFG.getTitleLineGap(pfx),
        [CFG.AUTHOR_GAP_KEY]         = CFG.getAuthorGap(pfx),
        [CFG.TITLE_COLOR_KEY]        = CFG.getColorHex(pfx, CFG.TITLE_COLOR_KEY),
        [CFG.AUTHOR_COLOR_KEY]       = CFG.getColorHex(pfx, CFG.AUTHOR_COLOR_KEY),

        [CFG.STATS_POS_X_KEY]        = CFG.getStatsPosX(pfx),
        [CFG.STATS_POS_Y_KEY]        = CFG.getStatsPosY(pfx),
        [CFG.VISUALS_POS_X_KEY]      = CFG.getVisualsPosX(pfx),
        [CFG.VISUALS_POS_Y_KEY]      = CFG.getVisualsPosY(pfx),
        [CFG.SHOW_STATS_BORDER_KEY]  = CFG.getShowStatsBorder(pfx),
        [CFG.SHOW_VISUALS_BORDER_KEY]= CFG.getShowVisualsBorder(pfx),
        [CFG.BORDER_RADIUS_KEY]      = CFG.getBorderRadius(pfx),
        [CFG.HEADER_RADIUS_KEY]      = CFG.getHeaderRadiusEnabled(pfx),
        [CFG.STATS_WIDTH_RATIO_KEY]  = CFG.getStatsWidthRatio(pfx),
        [CFG.SIDE_MARGIN_KEY]        = CFG.getSideMargin(pfx),

        [CFG.GRID_COLS_KEY]          = CFG.getGridCols(pfx),
        [CFG.GRID_ROWS_KEY]          = CFG.getGridRows(pfx),
        [CFG.STAT_ORDER_KEY]         = cloneVal(CFG.resolveStatOrder(SUISettings and SUISettings:readSetting(pfx .. CFG.STAT_ORDER_KEY))),
        [CFG.ACTIVE_STATS_KEY]       = cloneVal(CFG.getActiveStatsDict(pfx)),
        [CFG.VAL_FS_KEY]             = CFG.getValFs(pfx),
        [CFG.LBL_FS_KEY]             = CFG.getLblFs(pfx),
        [CFG.VAL_FONT_KEY]           = CFG.getValFont(pfx),
        [CFG.LBL_FONT_KEY]           = CFG.getLblFont(pfx),
        [CFG.VAL_BOLD_KEY]           = CFG.getValBold(pfx),
        [CFG.LBL_BOLD_KEY]           = CFG.getLblBold(pfx),
        [CFG.STAT_ROW_GAP_KEY]       = CFG.getStatRowGap(pfx),
        [CFG.HDR_ROW_GAP_KEY]        = CFG.getHdrRowGap(pfx),
        [CFG.LBL_GAP_KEY]            = CFG.getLblGap(pfx),
        [CFG.VAL_COLOR_KEY]          = CFG.getColorHex(pfx, CFG.VAL_COLOR_KEY),
        [CFG.LBL_COLOR_KEY]          = CFG.getColorHex(pfx, CFG.LBL_COLOR_KEY),
        [CFG.HDR_COLOR_KEY]          = CFG.getColorHex(pfx, CFG.HDR_COLOR_KEY),
        [CFG.STATS_BG_COLOR_KEY]     = CFG.getColorHex(pfx, CFG.STATS_BG_COLOR_KEY),

        [CFG.SHOW_HEADERS_KEY]       = CFG.getShowHeaders(pfx),
        [CFG.HEADER_STYLE_KEY]       = CFG.getHeaderStyle(pfx),
        [CFG.HEADER_WEIGHT_KEY]      = CFG.getHeaderWeight(pfx),
        [CFG.HEADER_TXT_PFX .. "1"]  = CFG.getHeaderTxt(pfx, 1),
        [CFG.HEADER_TXT_PFX .. "2"]  = CFG.getHeaderTxt(pfx, 2),
        [CFG.HEADER_TXT_PFX .. "3"]  = CFG.getHeaderTxt(pfx, 3),
        [CFG.HEADER_TXT_PFX .. "4"]  = CFG.getHeaderTxt(pfx, 4),

        [CFG.SHOW_VISUALS_KEY]       = CFG.getShowVisuals(pfx),
        [CFG.ACTIVE_VISUALS_KEY]     = cloneVal(CFG.getActiveVisuals(pfx)),
        [CFG.BAR_STYLE_KEY]          = CFG.getBarStyle(pfx),
        [CFG.BAR_THICKNESS_KEY]      = CFG.getRingThickness(pfx),
        [CFG.BAR_THICK_V2_KEY]       = true,
        [CFG.VBAR_THICKNESS_KEY]     = CFG.getVBarThickness(pfx),
        [CFG.HBAR_THICKNESS_KEY]     = CFG.getHBarThickness(pfx),
        [CFG.RING_VARIANT_KEY]       = CFG.getRingVariant(pfx),
        [CFG.VBAR_VARIANT_KEY]       = CFG.getVBarVariant(pfx),
        [CFG.HBAR_VARIANT_KEY]       = CFG.getHBarVariant(pfx),
        [CFG.BAR_HEIGHT_PCT_KEY]     = CFG.getBarHeightPct(pfx),
        [CFG.VBAR_HEIGHT_PCT_KEY]    = CFG.getVBarHeightPct(pfx),
        [CFG.HBAR_LENGTH_PCT_KEY]    = CFG.getHBarLengthPct(pfx),
        [CFG.BAR_GAP_PCT_KEY]        = CFG.getBarGap(pfx),
        [CFG.VBAR_GAP_PCT_KEY]       = CFG.getVBarGap(pfx),
        [CFG.HBAR_GAP_KEY]           = CFG.getHBarGap(pfx),
        [CFG.BAR_POS_Y_KEY]          = CFG.getBarPosY(pfx),
        [CFG.BAR_LBL_FS_KEY]         = CFG.getBarLblFs(pfx),
        [CFG.BAR_LBL_FONT_KEY]       = CFG.getBarLblFont(pfx),
        [CFG.BAR_LBL_BOLD_KEY]       = CFG.getBarLblBold(pfx),
        [CFG.BAR_LBL_COLOR_KEY]      = CFG.getColorHex(pfx, CFG.BAR_LBL_COLOR_KEY),
        [CFG.VIS_COLOR_1_KEY]        = CFG.getColorHex(pfx, CFG.VIS_COLOR_1_KEY),
        [CFG.VIS_COLOR_2_KEY]        = CFG.getColorHex(pfx, CFG.VIS_COLOR_2_KEY),
        [CFG.VIS_COLOR_3_KEY]        = CFG.getColorHex(pfx, CFG.VIS_COLOR_3_KEY),
        [CFG.VIS_TRACK_COLOR_KEY]    = CFG.getColorHex(pfx, CFG.VIS_TRACK_COLOR_KEY),
        [CFG.SHOW_RING_LABELS_KEY]   = CFG.getShowRingLabels(pfx),
        [CFG.DAILY_PAGE_GOAL_KEY]    = CFG.getDailyPageGoal(pfx),
        [CFG.DAILY_TIME_GOAL_KEY]    = CFG.getDailyTimeGoal(pfx),
        [CFG.WEEK_PAGE_GOAL_KEY]     = CFG.getWeekPageGoal(pfx),
        [CFG.WEEK_TIME_GOAL_KEY]     = CFG.getWeekTimeGoal(pfx),
        [CFG.MONTH_PAGE_GOAL_KEY]    = CFG.getMonthPageGoal(pfx),
        [CFG.MONTH_TIME_GOAL_KEY]    = CFG.getMonthTimeGoal(pfx),
        [CFG.YEAR_PAGE_GOAL_KEY]     = CFG.getYearPageGoal(pfx),
        [CFG.YEAR_TIME_GOAL_KEY]     = CFG.getYearTimeGoal(pfx),
        [CFG.YEAR_BOOK_GOAL_KEY]     = CFG.getYearBookGoal(pfx),

        [CFG.SK_TIME_FMT]            = CFG.getTimeFmt(pfx),
    }
    if Config and Config.getModuleScalePct then
        pcall(function() data["__module_scale"] = Config.getModuleScalePct("currently_yanllsama", pfx) end)
    end
    if Config and Config.getThumbScalePct then
        pcall(function() data["__thumb_scale"] = Config.getThumbScalePct("currently_yanllsama", pfx) end)
    end
    return data
end

function M.resetAllSettingsToDefault(pfx)
    local SUISettings = getSUIModule("sui_store", "infra")
    if not SUISettings then return end
    withBatchWrite(SUISettings, function()
        for _, key in ipairs(PROFILE_KEYS) do
            if SUISettings.del then
                SUISettings:del(pfx .. key)
            elseif SUISettings.saveSetting then
                SUISettings:saveSetting(pfx .. key, nil)
            end
        end
    end)
end

function M.applyProfileData(pfx, data)
    if not data or type(data) ~= "table" then return end
    local SUISettings = getSUIModule("sui_store", "infra")
    local Config = C.getConfig()

    withBatchWrite(SUISettings, function()
        -- Clear only keys absent from the target snapshot so missing fields
        -- (e.g. yanllsama_active_visuals) never leak from the prior profile
        -- without paying redundant deletes before overwriting.
        if SUISettings then
            for _, key in ipairs(PROFILE_KEYS) do
                if data[key] == nil then
                    if SUISettings.del then
                        SUISettings:del(pfx .. key)
                    elseif SUISettings.saveSetting then
                        SUISettings:saveSetting(pfx .. key, nil)
                    end
                end
            end
        end

        for k, v in pairs(data) do
            if k == "__module_scale" then
                if Config and Config.setModuleScale then
                    pcall(Config.setModuleScale, v, "currently_yanllsama", pfx)
                end
            elseif k == "__thumb_scale" then
                if Config and Config.setThumbScale then
                    pcall(Config.setThumbScale, v, "currently_yanllsama", pfx)
                end
            else
                if SUISettings then
                    SUISettings:saveSetting(pfx .. k, cloneVal(v))
                end
            end
        end
        if SUISettings and data[CFG.ACTIVE_VISUALS_KEY] == nil then
            SUISettings:saveSetting(pfx .. CFG.ACTIVE_VISUALS_KEY, cloneVal(CFG.DEFAULT_VISUAL_ITEMS))
        end
        if SUISettings and data[CFG.BAR_THICK_V2_KEY] == nil and data[CFG.BAR_THICKNESS_KEY] ~= nil then
            if SUISettings.del then
                SUISettings:del(pfx .. CFG.BAR_THICK_V2_KEY)
            else
                SUISettings:saveSetting(pfx .. CFG.BAR_THICK_V2_KEY, nil)
            end
        end
        if SUISettings and data[CFG.BAR_STYLE_KEY] == "bars" then
            if data[CFG.VBAR_HEIGHT_PCT_KEY] == nil and data[CFG.BAR_HEIGHT_PCT_KEY] ~= nil then
                SUISettings:saveSetting(pfx .. CFG.VBAR_HEIGHT_PCT_KEY, data[CFG.BAR_HEIGHT_PCT_KEY])
            end
            if data[CFG.VBAR_GAP_PCT_KEY] == nil and data[CFG.BAR_GAP_PCT_KEY] ~= nil then
                SUISettings:saveSetting(pfx .. CFG.VBAR_GAP_PCT_KEY, data[CFG.BAR_GAP_PCT_KEY])
            end
            if data[CFG.VBAR_THICKNESS_KEY] == nil and data[CFG.BAR_THICKNESS_KEY] ~= nil then
                local raw_t = tonumber(data[CFG.BAR_THICKNESS_KEY]) or 2
                local vbar_t = (data[CFG.BAR_THICK_V2_KEY] == true) and raw_t or math.max(1, math.min(12, math.floor(raw_t) + 3))
                SUISettings:saveSetting(pfx .. CFG.VBAR_THICKNESS_KEY, vbar_t)
            end
        end
    end)
end

local function getPluginDir()
    local candidates = {}
    if _G._simpleui_plus_path and _G._simpleui_plus_path ~= "" then
        table.insert(candidates, _G._simpleui_plus_path)
    end
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    src = src:gsub("\\", "/")
    local dir = src:match("^(.*)/modules/currently_reading/[^/]+$")
             or src:match("^(.*)/modules/[^/]+$")
             or src:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then table.insert(candidates, dir) end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getDataDir then
        table.insert(candidates, DataStorage:getDataDir() .. "/plugins/simpleui_plus.koplugin")
    end
    table.insert(candidates, "plugins/simpleui_plus.koplugin")
    table.insert(candidates, "./plugins/simpleui_plus.koplugin")

    for _, cdir in ipairs(candidates) do
        local test_file = io.open(cdir .. "/default_profiles.lua", "r")
        if test_file then
            test_file:close()
            return cdir
        end
    end
    return candidates[1] or "plugins/simpleui_plus.koplugin"
end

local function serializeLuaValue(val, indent)
    indent = indent or "    "
    local t = type(val)
    if t == "number" or t == "boolean" then
        return tostring(val)
    elseif t == "string" then
        return string.format("%q", val)
    elseif t == "table" then
        local is_array = true
        local n = 0
        for k, _ in pairs(val) do
            n = n + 1
            if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
                is_array = false
            end
        end
        if is_array and n > 0 then
            for i = 1, n do
                if val[i] == nil then
                    is_array = false
                    break
                end
            end
        end

        local parts = { "{\n" }
        local child_indent = indent .. "    "
        if is_array and n > 0 then
            for i = 1, n do
                table.insert(parts, child_indent .. serializeLuaValue(val[i], child_indent) .. ",\n")
            end
        else
            local sorted_keys = {}
            for k in pairs(val) do table.insert(sorted_keys, k) end
            table.sort(sorted_keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(sorted_keys) do
                local v = val[k]
                local key_str
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                    key_str = k
                else
                    key_str = "[" .. serializeLuaValue(k, child_indent) .. "]"
                end
                table.insert(parts, child_indent .. key_str .. " = " .. serializeLuaValue(v, child_indent) .. ",\n")
            end
        end
        table.insert(parts, indent .. "}")
        return table.concat(parts)
    else
        return "nil"
    end
end

local function serializeProfiles(profiles)
    return table.concat({
        "-- default_profiles.lua — SimpleUI Plus Bundled Profiles\n",
        "-- Auto-generated preset file for SimpleUI Plus.\n",
        "-- These profiles are bundled directly with the plugin and automatically seeded\n",
        "-- into the user's settings when installed on another device.\n\n",
        "return " .. serializeLuaValue(profiles, "") .. "\n"
    })
end

local function getBundledProfiles()
    local plugin_dir = getPluginDir()
    local path = plugin_dir .. "/default_profiles.lua"
    local f = io.open(path, "r")
    if f then
        local content = f:read("*all")
        f:close()
        local chunk = loadstring(content)
        if chunk then
            local ok_exec, res = pcall(chunk)
            if ok_exec and type(res) == "table" and #res > 0 then
                return res
            end
        end
    end
    local ok, profs = pcall(require, "default_profiles")
    if ok and type(profs) == "table" and #profs > 0 then
        return profs
    end
    return nil
end

function CFG.seedDefaultProfiles(pfx, force_overwrite)
    pfx = (pfx and pfx ~= "") and pfx or "simpleui_hs_"
    if force_overwrite and type(CFG.setSkipAutoSeed) == "function" then
        CFG.setSkipAutoSeed(pfx, false)
    end
    local SUISettings = getSUIModule("sui_store", "infra")
    if not SUISettings then return false end

    local bundled = getBundledProfiles()
    if not bundled or #bundled == 0 then return false end

    local current = SUISettings:readSetting(pfx .. CFG.PROFILES_KEY)
    if type(current) ~= "table" then
        current = {}
    end

    local modified = false
    for _, b_prof in ipairs(bundled) do
        if type(b_prof) == "table" and b_prof.name and b_prof.data then
            local existing_idx = nil
            for idx, c_prof in ipairs(current) do
                if c_prof.name == b_prof.name then
                    existing_idx = idx
                    break
                end
            end

            if not existing_idx then
                table.insert(current, {
                    name = b_prof.name,
                    locked = b_prof.locked or false,
                    is_bundled = true,
                    data = cloneVal(b_prof.data),
                })
                modified = true
            elseif force_overwrite then
                current[existing_idx].data = cloneVal(b_prof.data)
                current[existing_idx].locked = b_prof.locked or false
                current[existing_idx].is_bundled = true
                modified = true
            elseif b_prof.locked and type(current[existing_idx].data) == "table" then
                for bk, bv in pairs(b_prof.data) do
                    if current[existing_idx].data[bk] == nil then
                        current[existing_idx].data[bk] = cloneVal(bv)
                        modified = true
                    end
                end
            end
        end
    end

    if modified then
        SUISettings:saveSetting(pfx .. CFG.PROFILES_KEY, current)
        local cur_act = SUISettings:readSetting(pfx .. CFG.ACTIVE_PROFILE_KEY)
        if (not cur_act or cur_act == "") and #current > 0 then
            SUISettings:saveSetting(pfx .. CFG.ACTIVE_PROFILE_KEY, current[1].name)
            M.applyProfileData(pfx, current[1].data)
        end
        if SUISettings.flush then
            pcall(function() SUISettings:flush() end)
        end
    end
    return modified
end

function CFG.exportProfilesToPlugin(pfx)
    pfx = (pfx and pfx ~= "") and pfx or "simpleui_hs_"
    local SUISettings = getSUIModule("sui_store", "infra")
    local cur_profiles = (SUISettings and SUISettings:readSetting(pfx .. CFG.PROFILES_KEY)) or {}
    if type(cur_profiles) ~= "table" then
        cur_profiles = {}
    end

    if #cur_profiles == 0 then
        local current_data = M.captureCurrentProfileData(pfx)
        cur_profiles = {
            {
                name = "Default",
                locked = false,
                data = current_data,
            }
        }
        if SUISettings then
            SUISettings:saveSetting(pfx .. CFG.PROFILES_KEY, cur_profiles)
            SUISettings:saveSetting(pfx .. CFG.ACTIVE_PROFILE_KEY, "Default")
            if SUISettings.flush then pcall(function() SUISettings:flush() end) end
        end
    end

    local active_name = CFG.getActiveProfileName(pfx)
    if active_name and active_name ~= "" then
        for _, p in ipairs(cur_profiles) do
            if p.name == active_name then
                p.data = M.captureCurrentProfileData(pfx)
                break
            end
        end
    end

    local serialized = serializeProfiles(cur_profiles)
    local plugin_dir = getPluginDir()
    local path = plugin_dir .. "/default_profiles.lua"

    logger.info("simpleui_plus: exporting profiles to " .. tostring(path) .. " (count: " .. tostring(#cur_profiles) .. ")")

    local f, err = io.open(path, "w+")
    if not f then
        f, err = io.open(path, "w")
    end
    if not f then
        logger.err("simpleui_plus: failed to open " .. tostring(path) .. " for writing: " .. tostring(err))
        return false, err or string.format(_("Failed to write file: %s"), tostring(path))
    end
    f:write(serialized)
    f:flush()
    f:close()

    package.loaded["default_profiles"] = nil
    logger.info("simpleui_plus: successfully wrote profiles to " .. tostring(path))
    return true
end

local _flush_timer = nil

function M.cycleProfile(pfx, step)
    pfx = (pfx and pfx ~= "") and pfx or "simpleui_hs_"
    if not CFG.getQuickSwitchEnabled(pfx) then
        return false, nil
    end
    local SUISettings = getSUIModule("sui_store", "infra")
    local profiles = CFG.getQuickSwitchProfiles(pfx)
    if type(profiles) ~= "table" or #profiles == 0 then
        return false, nil
    end

    local cur_name = CFG.getActiveProfileName(pfx)
    if #profiles == 1 and profiles[1].name == cur_name then
        return false, nil
    end

    local cur_idx = nil
    for i, p in ipairs(profiles) do
        if p.name == cur_name then
            cur_idx = i
            break
        end
    end

    local delta = step or 1
    local next_idx
    if cur_idx then
        next_idx = ((cur_idx - 1 + delta) % #profiles) + 1
    else
        next_idx = (delta < 0) and #profiles or 1
    end

    local target = profiles[next_idx]
    if not target or not target.name then
        return false, nil
    end

    withBatchWrite(SUISettings, function()
        if type(target.data) == "table" then
            M.applyProfileData(pfx, target.data)
        end
        if SUISettings then
            SUISettings:saveSetting(pfx .. CFG.ACTIVE_PROFILE_KEY, target.name)
        end
    end)
    if SUISettings and type(SUISettings.flush) == "function" then
        pcall(function()
            local UIManager = require("ui/uimanager")
            if _flush_timer then UIManager:unschedule(_flush_timer) end
            _flush_timer = function()
                _flush_timer = nil
                local S = getSUIModule("sui_store", "infra")
                if S and type(S.flush) == "function" then pcall(function() S:flush() end) end
            end
            UIManager:scheduleIn(1.5, _flush_timer)
        end)
    end
    return true, target.name
end

function M.purgeUnlockedProfilesFromStore(pfx)
    pfx = (pfx and pfx ~= "") and pfx or "simpleui_hs_"
    local SUISettings = getSUIModule("sui_store", "infra")
    if not SUISettings then return 0, 0 end

    local current = SUISettings:readSetting(pfx .. CFG.PROFILES_KEY)
    if type(current) ~= "table" then current = {} end

    local kept = {}
    local kept_names = {}
    local deleted_count = 0
    for _, p in ipairs(current) do
        if type(p) == "table" and p.locked == true then
            table.insert(kept, p)
            if p.name then kept_names[p.name] = true end
        else
            deleted_count = deleted_count + 1
        end
    end

    if type(CFG.setSkipAutoSeed) == "function" then
        CFG.setSkipAutoSeed(pfx, true)
    end

    withBatchWrite(SUISettings, function()
        if #kept > 0 then
            SUISettings:saveSetting(pfx .. CFG.PROFILES_KEY, kept)
        elseif SUISettings.del then
            SUISettings:del(pfx .. CFG.PROFILES_KEY)
        else
            SUISettings:saveSetting(pfx .. CFG.PROFILES_KEY, nil)
        end

        local act = SUISettings:readSetting(pfx .. CFG.ACTIVE_PROFILE_KEY)
        if act and act ~= "" and not kept_names[act] then
            if SUISettings.del then SUISettings:del(pfx .. CFG.ACTIVE_PROFILE_KEY)
            else SUISettings:saveSetting(pfx .. CFG.ACTIVE_PROFILE_KEY, nil) end
        end

        local def = SUISettings:readSetting(pfx .. CFG.DEFAULT_PROFILE_KEY)
        if def and def ~= "" and not kept_names[def] then
            if SUISettings.del then SUISettings:del(pfx .. CFG.DEFAULT_PROFILE_KEY)
            else SUISettings:saveSetting(pfx .. CFG.DEFAULT_PROFILE_KEY, nil) end
        end

        local qraw = SUISettings:readSetting(pfx .. CFG.QUICK_PROFILES_KEY)
        if type(qraw) == "table" then
            if #kept == 0 then
                if SUISettings.del then SUISettings:del(pfx .. CFG.QUICK_PROFILES_KEY)
                else SUISettings:saveSetting(pfx .. CFG.QUICK_PROFILES_KEY, nil) end
            else
                local new_q = {}
                if qraw._configured then new_q._configured = true end
                for k, v in pairs(qraw) do
                    if k ~= "_configured" and kept_names[k] and v == true then
                        new_q[k] = true
                    end
                end
                SUISettings:saveSetting(pfx .. CFG.QUICK_PROFILES_KEY, new_q)
            end
        end
    end)

    if SUISettings.flush then
        pcall(function() SUISettings:flush() end)
    end
    return deleted_count, #kept
end

return M
