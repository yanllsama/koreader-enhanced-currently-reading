-- modules/currently_reading/menu.lua — Full settings menu tree, live preview HUD, and Arrange pickers.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer  = require("ui/widget/container/inputcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Size            = require("ui/size")
local SortWidget      = require("ui/widget/sortwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local Screen          = Device.screen

local C              = require("modules/currently_reading/config")
local StatsMod       = require("modules/currently_reading/stats")
local ProfilesMod    = require("modules/currently_reading/profiles")
local StatsEditor    = require("modules/currently_reading/stats_editor")
local PositionEditor = require("modules/currently_reading/position_editor")
local VisualsMod     = require("modules/currently_reading/visuals")
local CFG          = C.CFG
local _            = C._
local getSUIModule = C.getSUIModule

local M = {}

local _preview_state = {
    is_active = false,
    stashed_stack = {},
    stashed_sui = {},
    floating_container = nil,
    timer_alarm = nil,
    timer_seq = 0,
    reopen_spin_fn = nil,
    pfx = "",
    _lc = nil,
}

local _time_ok, _TimeMod = pcall(require, "ui/time")
local function nowMs()
    if _time_ok and _TimeMod and type(_TimeMod.now) == "function" and type(_TimeMod.to_ms) == "function" then
        return _TimeMod.to_ms(_TimeMod.now())
    end
    return os.time() * 1000
end

local function makeDirtyGeom(old_x, old_y, old_w, old_h, target_dimen)
    local new_w = (target_dimen and target_dimen.w) or 0
    local new_h = (target_dimen and target_dimen.h) or 0
    local gx = (target_dimen and target_dimen.x and target_dimen.x ~= 0) and target_dimen.x or old_x or 0
    local gy = (target_dimen and target_dimen.y and target_dimen.y ~= 0) and target_dimen.y or old_y or 0
    return Geom:new{
        x = gx,
        y = gy,
        w = math.max(old_w or 0, new_w),
        h = math.max(old_h or 0, new_h),
    }
end

-- In-memory fast-step hook for SUISlider.Control.activate scoped strictly to our
-- live-preview spin sheet ("sui_win_spin"), avoiding the blocking 2x forceRePaint
-- tap-feedback stall on +/- buttons without touching SimpleUI files on disk.
local function ensureFastSpinStepperControls()
    local SUISlider = getSUIModule("sui_slider", "engines")
    local SUIWindow = getSUIModule("sui_window", "engines")
    if not (SUISlider and SUISlider.Control and type(SUISlider.Control.activate) == "function") then
        return
    end
    if SUISlider.Control._yan_fast_spin_patched then return end
    SUISlider.Control._yan_fast_spin_patched = true
    local orig_activate = SUISlider.Control.activate
    SUISlider.Control.activate = function(self)
        local wins = SUIWindow and SUIWindow._open_instances
        local top = wins and wins[#wins]
        if top and top._name == "sui_win_spin" and type(self.callback) == "function" then
            self.callback()
            return
        end
        return orig_activate(self)
    end
end

function M.buildMenuItems(ctx_menu)
    local pfx         = ctx_menu.pfx or ""
    local SUISettings = getSUIModule("sui_store", "infra")
    local Config      = C.getConfig()
    local refresh     = ctx_menu.refresh
    local _lc         = _

    _preview_state.pfx = pfx
    _preview_state._lc = _lc

    local ICON_EYE      = "\xEF\x81\xAE"
    local ICON_SETTINGS = "\xEF\x80\x93"
    local ICON_CLOSE    = "\xEF\x80\x8D"

    local restoreAllSettings, dismissAllSettings, triggerPreviewMode, notifyChange
    local triggerSurgicalPreviewRepaint, relayoutScreensKeepCache

    local function getLiveScreens()
        local SE = getSUIModule("sui_screen_engine", "engines")
            or getSUIModule("sui_homescreen", "screens")
        local screens = {}
        if SE then
            if type(SE.liveScreenIds) == "function" then
                for _, id in ipairs(SE.liveScreenIds()) do
                    local inst = SE.getInstance(id)
                    if inst then table.insert(screens, inst) end
                end
            end
            if #screens == 0 and type(SE.getInstance) == "function" then
                local inst = SE.getInstance("hs") or SE.getInstance()
                if inst then table.insert(screens, inst) end
            end
            if #screens == 0 and SE._instance then
                table.insert(screens, SE._instance)
            end
        end
        return screens
    end

    local function needsColorSettle()
        return C.isColorScreenActive() or CFG.hasAnyCustomColor(pfx)
    end

    local function getPreviewRefreshMode()
        return needsColorSettle() and "partial" or "ui"
    end

    local function getActiveBottomSheetTopY()
        local SUIWindow = getSUIModule("sui_window", "engines")
        local wins = SUIWindow and SUIWindow._open_instances
        local top = wins and wins[#wins]
        if top and top._modal_frame and top._modal_frame.overlap_offset then
            local oy = top._modal_frame.overlap_offset[2]
            if oy and oy > 0 then return oy end
        end
        if top and top._modal_frame and top._modal_frame.dimen and top._modal_frame.dimen.y and top._modal_frame.dimen.y > 0 then
            return top._modal_frame.dimen.y
        end
        return nil
    end

    local function resolveScreenBgColor(lay)
        if lay and lay.bg_color ~= nil then return lay.bg_color end
        local SS = C.getSUIStyle()
        return (SS and SS.COLOR and SS.COLOR.bg) or Blitbuffer.COLOR_WHITE
    end

    local function paintSlotDirect(sc, paint_target, old_x, old_y, old_w, old_h, bg_color, refresh_mode, sheet_top_y)
        if not paint_target then return false end
        local has_wp = sc and sc._ctx_cache and sc._ctx_cache.has_wallpaper
        local target_dimen = paint_target.dimen
        local dirty_rect = makeDirtyGeom(old_x, old_y, old_w, old_h, target_dimen)
        if dirty_rect.w <= 0 or dirty_rect.h <= 0 then
            UIManager:setDirty(sc, refresh_mode)
            return true
        end

        local top_y = sheet_top_y or getActiveBottomSheetTopY()
        local overlaps_sheet = (top_y ~= nil) and ((dirty_rect.y + dirty_rect.h) > top_y)

        if (not has_wp) and (not overlaps_sheet) and old_x ~= nil and old_y ~= nil then
            if Screen and Screen.bb then
                Screen.bb:paintRect(dirty_rect.x, dirty_rect.y, dirty_rect.w, dirty_rect.h, bg_color or Blitbuffer.COLOR_WHITE)
                paint_target:paintTo(Screen.bb, old_x, old_y)
                if refresh_mode == "partial" then
                    UIManager:avoidFlashOnNextRepaint()
                end
                UIManager:setDirty(nil, refresh_mode, dirty_rect, refresh_mode == "partial")
                return true
            end
        end

        if refresh_mode == "partial" then
            UIManager:avoidFlashOnNextRepaint()
        end
        UIManager:setDirty(sc, function() return refresh_mode, dirty_rect, refresh_mode == "partial" end)
        return true
    end

    local function settleColorRect(sheet_top_y)
        if not needsColorSettle() then return end
        local live_screens = getLiveScreens()
        local top_y = sheet_top_y or getActiveBottomSheetTopY()
        for _, sc in ipairs(live_screens) do
            local slot = sc and sc._book_mod_slots and sc._book_mod_slots["currently_yanllsama"]
            if slot then
                local wrapper = slot.has_menu and sc._wrapper_pool and sc._wrapper_pool["currently_yanllsama"]
                local rect = (wrapper and wrapper.dimen) or (slot.widget and slot.widget.dimen)
                if rect and rect.w > 0 and rect.h > 0 then
                    local h = rect.h
                    if top_y and (rect.y + h) > top_y then
                        h = math.max(0, top_y - rect.y)
                    end
                    if h > 0 then
                        UIManager:avoidFlashOnNextRepaint()
                        UIManager:setDirty(nil, "partial", Geom:new{ x = rect.x, y = rect.y, w = rect.w, h = h }, true)
                    end
                end
            end
        end
    end

    local function suiToast(msg, duration)
        local UI = getSUIModule("sui_core", "infra")
        if UI and UI.Notify and type(UI.Notify.toast) == "function" then
            UI.Notify.toast(msg, duration or 2)
            return
        end
        local ok_notif, Notification = pcall(require, "ui/widget/notification")
        if ok_notif and Notification then
            UIManager:show(Notification:new{ text = msg })
        end
    end

    local function suiConfirm(opts)
        opts = opts or {}
        local text = opts.text or opts.message or ""
        local ok_cb = opts.ok_callback or opts.on_confirm
        local cancel_cb = opts.cancel_callback or opts.on_cancel
        local ok_text = opts.ok_text or _lc("OK")
        local cancel_text = opts.cancel_text or _lc("Cancel")

        local Dialogs = getSUIModule("sui_dialogs", "features/dialogs")
        if Dialogs and type(Dialogs.confirm) == "function" then
            return Dialogs.confirm{
                title           = opts.title,
                text            = text,
                ok_text         = ok_text,
                cancel_text     = cancel_text,
                no_ok_button    = opts.no_ok_button,
                ok_callback     = ok_cb,
                cancel_callback = cancel_cb,
            }
        end
        local ok_c, ConfirmBox = pcall(require, "ui/widget/confirmbox")
        if ok_c and ConfirmBox then
            local dlg = ConfirmBox:new{
                text            = text,
                ok_text         = ok_text,
                cancel_text     = cancel_text,
                no_ok_button    = opts.no_ok_button,
                ok_callback     = ok_cb,
                cancel_callback = cancel_cb,
            }
            UIManager:show(dlg)
            return dlg
        end
    end

    local function suiPrompt(opts)
        local Dialogs = getSUIModule("sui_dialogs", "features/dialogs")
        if Dialogs and type(Dialogs.prompt) == "function" then
            return Dialogs.prompt{
                title       = opts.title,
                description = opts.description,
                value       = opts.value or opts.input or "",
                hint        = opts.hint or opts.input_hint,
                ok_text     = opts.ok_text or _lc("Save"),
                cancel_text = opts.cancel_text or _lc("Cancel"),
                allow_empty = opts.allow_empty or false,
                on_submit   = function(text)
                    if opts.on_submit then opts.on_submit(text)
                    elseif opts.callback then opts.callback(text) end
                end,
                on_cancel   = opts.on_cancel or opts.cancel_callback,
            }
        end
        local ok_inp, InputDialog = pcall(require, "ui/widget/inputdialog")
        if ok_inp and InputDialog then
            local dlg
            dlg = InputDialog:new{
                title         = opts.title,
                description   = opts.description,
                input         = opts.value or opts.input or "",
                input_hint    = opts.hint or opts.input_hint,
                allow_newline = opts.allow_newline or false,
                buttons       = {{
                    {
                        text = opts.cancel_text or _lc("Cancel"),
                        callback = function()
                            UIManager:close(dlg)
                            if opts.on_cancel then opts.on_cancel() end
                        end
                    },
                    {
                        text = opts.ok_text or _lc("Save"),
                        is_enter_default = true,
                        callback = function()
                            local text = dlg:getInputText()
                            UIManager:close(dlg)
                            if opts.on_submit then opts.on_submit(text)
                            elseif opts.callback then opts.callback(text) end
                        end,
                    },
                }},
            }
            UIManager:show(dlg)
            dlg:onShowKeyboard()
            return dlg
        end
    end

    local function suiActionMenu(opts)
        local ActionSheet = getSUIModule("sui_action_sheet", "engines")
        if ActionSheet and type(ActionSheet.show) == "function" then
            local items = {}
            for _, it in ipairs(opts.items or {}) do
                table.insert(items, {
                    text     = it.text,
                    icon     = it.icon,
                    callback = it.callback,
                })
            end
            local sheet
            local footer = {
                {
                    text = opts.cancel_text or _lc("Cancel"),
                    callback = function()
                        if sheet and sheet.close then sheet:close() end
                        if opts.on_cancel then opts.on_cancel() end
                    end,
                }
            }
            sheet = ActionSheet.show{
                name        = opts.name or "sui_win_action_menu",
                title       = opts.title,
                message     = opts.message,
                auto_close  = true,
                sections    = { ActionSheet.list(items) },
                footer      = footer,
                on_dismiss  = opts.on_cancel,
            }
            return sheet
        end
        local ok_b, ButtonDialog = pcall(require, "ui/widget/buttondialog")
        if ok_b and ButtonDialog then
            local buttons = {}
            local bd
            for _, it in ipairs(opts.items or {}) do
                local cb = it.callback
                table.insert(buttons, {{
                    text     = it.text,
                    align    = "left",
                    callback = function()
                        UIManager:close(bd)
                        if cb then cb() end
                    end,
                }})
            end
            table.insert(buttons, {{
                text     = opts.cancel_text or _lc("Cancel"),
                callback = function()
                    UIManager:close(bd)
                    if opts.on_cancel then opts.on_cancel() end
                end,
            }})
            bd = ButtonDialog:new{
                title              = opts.title,
                width_factor       = opts.width_factor or 0.8,
                buttons            = buttons,
                tap_close_callback = function()
                    UIManager:close(bd)
                    if opts.on_cancel then opts.on_cancel() end
                end,
            }
            UIManager:show(bd)
            return bd
        end
    end

    local function findHomescreenIndex()
        if not UIManager._window_stack then return nil end
        local SE = getSUIModule("sui_screen_engine", "engines")
            or getSUIModule("sui_homescreen", "screens")
        local hs_widget = SE and (SE._instance or (SE.getInstance and SE.getInstance()))
        if hs_widget then
            for i = #UIManager._window_stack, 1, -1 do
                if UIManager._window_stack[i].widget == hs_widget then
                    return i
                end
            end
        end
        for i = #UIManager._window_stack, 1, -1 do
            local w = UIManager._window_stack[i].widget
            if w and (w.name == "homescreen" or w.name == "sui_homescreen") then
                return i
            end
        end
        return nil
    end

    restoreAllSettings = function()
        if not _preview_state.is_active then return end

        if _preview_state.timer_alarm then
            pcall(function() UIManager:unschedule(_preview_state.timer_alarm) end)
            _preview_state.timer_alarm = nil
        end

        if _preview_state.floating_container then
            local fc = _preview_state.floating_container
            _preview_state.floating_container = nil
            pcall(function() UIManager:close(fc) end)
        end

        local SUIWindow = getSUIModule("sui_window", "engines")
        if SUIWindow and SUIWindow._open_instances then
            for _, win_inst in ipairs(_preview_state.stashed_sui) do
                table.insert(SUIWindow._open_instances, win_inst)
                if win_inst and type(win_inst.repaint) == "function" then
                    pcall(function() win_inst:repaint() end)
                end
            end
        end
        _preview_state.stashed_sui = {}

        for _, entry in ipairs(_preview_state.stashed_stack) do
            table.insert(UIManager._window_stack, entry)
            UIManager:setDirty(entry.widget)
        end
        _preview_state.stashed_stack = {}

        _preview_state.is_active = false
        UIManager:setDirty(nil, "full")

        local spin_fn = _preview_state.reopen_spin_fn
        _preview_state.reopen_spin_fn = nil
        if type(spin_fn) == "function" then
            UIManager:nextTick(function()
                spin_fn()
            end)
        end
    end

    dismissAllSettings = function()
        if _preview_state.timer_alarm then
            pcall(function() UIManager:unschedule(_preview_state.timer_alarm) end)
            _preview_state.timer_alarm = nil
        end

        if _preview_state.floating_container then
            local fc = _preview_state.floating_container
            _preview_state.floating_container = nil
            pcall(function() UIManager:close(fc) end)
        end

        for _, win in ipairs(_preview_state.stashed_sui) do
            if win and win.close then
                pcall(function() win:close() end)
            elseif win and win._wrapper then
                pcall(function() UIManager:close(win._wrapper) end)
            end
        end
        _preview_state.stashed_sui = {}

        local Event = require("ui/event")
        for _, entry in ipairs(_preview_state.stashed_stack) do
            if entry.widget then
                pcall(function()
                    entry.widget:handleEvent(Event:new("FlushSettings"))
                    entry.widget:handleEvent(Event:new("CloseWidget"))
                end)
            end
        end
        _preview_state.stashed_stack = {}
        _preview_state.reopen_spin_fn = nil
        _preview_state.is_active = false

        local SE = getSUIModule("sui_screen_engine", "engines")
            or getSUIModule("sui_homescreen", "screens")
        if SE and SE.invalidateAllCfgAndRefresh then
            pcall(function() SE.invalidateAllCfgAndRefresh(false) end)
        end
        local hs_widget = SE and (SE._instance or (SE.getInstance and SE.getInstance()))
        if hs_widget and type(hs_widget._refreshImmediate) == "function" then
            pcall(function() hs_widget:_refreshImmediate(false) end)
        end
        UIManager:setDirty(nil, "full")
    end

    triggerPreviewMode = function(reopen_fn)
        if not CFG.getPreviewMode(pfx) then return end

        if _preview_state.is_active then
            if reopen_fn then
                _preview_state.reopen_spin_fn = reopen_fn
            end
            if CFG.getPreviewType(pfx) == "timer" then
                if _preview_state.timer_alarm then
                    pcall(function() UIManager:unschedule(_preview_state.timer_alarm) end)
                end
                _preview_state.timer_seq = _preview_state.timer_seq + 1
                local cur_seq = _preview_state.timer_seq
                local dur = CFG.getPreviewDuration(pfx)
                _preview_state.timer_alarm = UIManager:scheduleIn(dur, function()
                    if _preview_state.is_active and _preview_state.timer_seq == cur_seq then
                        restoreAllSettings()
                    end
                end)
            end
            return
        end

        local hs_idx = findHomescreenIndex()
        local base_idx = hs_idx or 1
        if not UIManager._window_stack or #UIManager._window_stack <= base_idx then
            return
        end

        UIManager:nextTick(function()
            if _preview_state.is_active then return end

            local cur_hs_idx = findHomescreenIndex()
            if not cur_hs_idx then
                local SE = getSUIModule("sui_screen_engine", "engines")
                    or getSUIModule("sui_homescreen", "screens")
                if SE and type(SE.show) == "function" then
                    pcall(function() SE.show() end)
                    cur_hs_idx = findHomescreenIndex()
                end
            end

            local target_base = cur_hs_idx or 1
            if not UIManager._window_stack or #UIManager._window_stack <= target_base then return end

            _preview_state.is_active = true
            _preview_state.reopen_spin_fn = reopen_fn

            _preview_state.stashed_sui = {}
            local SUIWindow = getSUIModule("sui_window", "engines")
            if SUIWindow and SUIWindow._open_instances then
                for i = #SUIWindow._open_instances, 1, -1 do
                    table.insert(_preview_state.stashed_sui, 1, table.remove(SUIWindow._open_instances, i))
                end
            end

            _preview_state.stashed_stack = {}
            while #UIManager._window_stack > target_base do
                local entry = table.remove(UIManager._window_stack)
                table.insert(_preview_state.stashed_stack, 1, entry)
            end

            local SE = getSUIModule("sui_screen_engine", "engines")
                or getSUIModule("sui_homescreen", "screens")
            if SE and SE.invalidateAllCfgAndRefresh then
                pcall(function() SE.invalidateAllCfgAndRefresh(false) end)
            end
            local hs_widget = SE and (SE._instance or (SE.getInstance and SE.getInstance()))
            if hs_widget and type(hs_widget._refreshImmediate) == "function" then
                pcall(function() hs_widget:_refreshImmediate(false) end)
            end
            local Event = require("ui/event")
            pcall(function() UIManager:broadcastEvent(Event:new("SimpleUIHomescreenRefresh")) end)

            local sw = Screen:getWidth()
            local sh = Screen:getHeight()
            UIManager:setDirty(nil, function() return "ui", Geom:new{ x = 0, y = 0, w = sw, h = sh }, true end)

            local p_type = CFG.getPreviewType(pfx)
            local dur = CFG.getPreviewDuration(pfx)

            local pad_h = Screen:scaleBySize(10)
            local pad_v = Screen:scaleBySize(5)
            local btn_h = Screen:scaleBySize(30)
            local lbl_face = Font:getFace("cfont", 11) or Font:getFace("tfont", 11)

            local btn_text = ICON_SETTINGS .. " " .. _lc("Settings")
            if p_type == "timer" then
                btn_text = ICON_SETTINGS .. " " .. _lc("Settings") .. string.format(" (%ds)", dur)
            end

            local icon_label = TextWidget:new{
                text = btn_text,
                face = lbl_face,
                bold = true,
                padding = 0,
                max_width = math.max(140, Screen:scaleBySize(200)),
                truncation_char = "…",
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            local close_label = TextWidget:new{
                text = "   " .. ICON_CLOSE,
                face = lbl_face,
                bold = true,
                padding = 0,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }

            local pill = FrameContainer:new{
                bordersize = Size.line.thin or 1,
                color = Blitbuffer.COLOR_BLACK,
                background = Blitbuffer.COLOR_WHITE,
                radius = math.floor(btn_h / 2),
                padding_left = pad_h,
                padding_right = pad_h,
                padding_top = pad_v,
                padding_bottom = pad_v,
                [1] = HorizontalGroup:new{
                    align = "center",
                    icon_label,
                    close_label,
                },
            }

            local float_w = pill:getSize().w
            local float_h = pill:getSize().h
            local float_x = math.max(10, Screen:scaleBySize(12))
            local float_y = math.max(10, Screen:scaleBySize(12))
            pill.overlap_offset = { float_x, float_y }

            local float_container = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
                OverlapGroup:new{
                    dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
                    pill,
                },
            }

            float_container.ges_events = {
                Tap = {
                    GestureRange:new{
                        ges = "tap",
                        range = function() return Geom:new{ x = 0, y = 0, w = sw, h = sh } end,
                    }
                }
            }

            if Device:hasKeys() then
                float_container.key_events = { Close = { { "Back" } } }
                function float_container:onClose()
                    restoreAllSettings()
                    return true
                end
            end

            function float_container:onTap(_, ges)
                local pos = ges and ges.pos
                local hit_box = Geom:new{
                    x = math.max(0, float_x - 10),
                    y = math.max(0, float_y - 10),
                    w = float_w + 20,
                    h = float_h + 20
                }
                if pos and pos:intersectWith(hit_box) then
                    local close_boundary = float_x + float_w - pad_h - close_label:getSize().w - 2
                    if pos.x >= close_boundary then
                        dismissAllSettings()
                        return true
                    end
                    restoreAllSettings()
                    return true
                end
                if CFG.getPreviewType(pfx) == "timer" then
                    restoreAllSettings()
                    return true
                end
                return true
            end

            _preview_state.floating_container = float_container
            UIManager:show(float_container)

            if p_type == "timer" then
                _preview_state.timer_seq = _preview_state.timer_seq + 1
                local cur_seq = _preview_state.timer_seq
                _preview_state.timer_alarm = UIManager:scheduleIn(dur, function()
                    if _preview_state.is_active and _preview_state.timer_seq == cur_seq then
                        restoreAllSettings()
                    end
                end)
            end
        end)
    end

    notifyChange = function(reopen_fn, skip_preview, keep_cache, opts_nc)
        if opts_nc and opts_nc.clear_stats then
            StatsMod.clearCache()
        end
        if SUISettings and type(SUISettings.flush) == "function" then
            pcall(function() SUISettings:flush() end)
        end
        pcall(function()
            local SE = getSUIModule("sui_screen_engine", "engines")
                or getSUIModule("sui_homescreen", "screens")
            if SE and type(SE.setCfgCache) == "function" and type(SE.knownScreenIds) == "function" then
                for _, id in ipairs(SE.knownScreenIds()) do
                    SE.setCfgCache(id, nil)
                end
            end

            if opts_nc and opts_nc.full_rebuild then
                local hs_widget = SE and (SE._instance or (SE.getInstance and SE.getInstance()))
                if hs_widget and type(hs_widget._refreshImmediate) == "function" then
                    hs_widget:_refreshImmediate(false)
                elseif SE then
                    if type(SE.invalidateAllCfgAndRefresh) == "function" then
                        SE.invalidateAllCfgAndRefresh(true)
                    elseif type(SE.refresh) == "function" then
                        SE.refresh(false)
                    end
                else
                    local Event = require("ui/event")
                    UIManager:broadcastEvent(Event:new("SimpleUIHomescreenRefresh"))
                end
                return
            end

            local repainted, h_changed = triggerSurgicalPreviewRepaint(false, false)
            if not repainted or h_changed then
                relayoutScreensKeepCache(nil, getPreviewRefreshMode())
            end
        end)
        if type(refresh) == "function" then
            pcall(refresh)
        end
        if not skip_preview and CFG.getPreviewMode(pfx) then
            triggerPreviewMode(reopen_fn)
        end
    end

    local font_options = {
        { name = "NotoSerif", label = "Noto Serif" },
        { name = "NotoSans", label = "Noto Sans" },
        { name = "LinLibertine", label = "Linux Libertine" },
        { name = "tfont", label = _lc("System UI Font") }
    }

    local function makeFontMenu(key_name, default_val)
        local sub = {}
        for _idx, opt in ipairs(font_options) do
            table.insert(sub, {
                text = opt.label, radio = true, keep_menu_open = true,
                checked_func = function() return (SUISettings:readSetting(pfx .. key_name) or default_val) == opt.name end,
                callback = function() SUISettings:saveSetting(pfx .. key_name, opt.name) notifyChange() end,
            })
        end
        return sub
    end

    local function makeCountMenu(key_name, min_val, max_val, default_val)
        local sub = {}
        for n = min_val, max_val do
            table.insert(sub, {
                text = tostring(n) .. (n == default_val and _lc(" (Default)") or ""), radio = true, keep_menu_open = true,
                checked_func = function() return (tonumber(SUISettings:readSetting(pfx .. key_name)) or default_val) == n end,
                callback = function() SUISettings:saveSetting(pfx .. key_name, n) notifyChange() end,
            })
        end
        return sub
    end

    local function hideParentMenus(skip_dirty)
        local SUIWindow = getSUIModule("sui_window", "engines")
        local stashed_sui = {}
        if SUIWindow and SUIWindow._open_instances then
            for i = #SUIWindow._open_instances, 1, -1 do
                local win = SUIWindow._open_instances[i]
                table.insert(stashed_sui, 1, win)
                table.remove(SUIWindow._open_instances, i)
            end
        end

        local live_screens = getLiveScreens()
        local stack = UIManager._window_stack
        local stashed_stack = {}
        if stack and #stack > 0 then
            local base_idx = 1
            if #live_screens > 0 then
                for i, entry in ipairs(stack) do
                    for _, sc in ipairs(live_screens) do
                        if entry.widget == sc then
                            base_idx = math.max(base_idx, i)
                            break
                        end
                    end
                end
            end
            for i = #stack, base_idx + 1, -1 do
                table.insert(stashed_stack, 1, table.remove(stack, i))
            end
        end

        if not skip_dirty then
            if stack then
                for i = 1, #stack do
                    if stack[i] and stack[i].widget then
                        UIManager:setDirty(stack[i].widget, "ui")
                    end
                end
            end
            for _, sc in ipairs(live_screens) do
                UIManager:setDirty(sc, "ui")
            end
            UIManager:setDirty(nil, "ui")
        end

        return stashed_sui, stashed_stack, live_screens
    end

    local function restoreParentMenus(stashed_sui, stashed_stack)
        if not stashed_sui and not stashed_stack then return end
        local SUIWindow = getSUIModule("sui_window", "engines")
        if SUIWindow and SUIWindow._open_instances and stashed_sui then
            for _, win in ipairs(stashed_sui) do
                table.insert(SUIWindow._open_instances, win)
            end
        end

        local stack = UIManager._window_stack
        if stack and stashed_stack then
            for _, entry in ipairs(stashed_stack) do
                table.insert(stack, entry)
            end
        end
        UIManager:setDirty(nil, "ui")
    end

    local function refreshHomescreenImmediate()
        local SE = getSUIModule("sui_screen_engine", "engines")
            or getSUIModule("sui_homescreen", "screens")
        if SE and type(SE.refreshAllLiveImmediate) == "function" then
            SE.refreshAllLiveImmediate(true)
        else
            for _, sc in ipairs(getLiveScreens()) do
                if type(sc._refreshImmediate) == "function" then
                    sc:_refreshImmediate(true)
                elseif type(sc.refresh) == "function" then
                    sc:refresh(false)
                end
            end
        end
        for _, sc in ipairs(getLiveScreens()) do
            UIManager:setDirty(sc, "ui")
        end
        UIManager:setDirty(nil, "ui")
    end

    local function withNoFlush(fn)
        if not SUISettings or type(SUISettings.setNoFlush) ~= "function" then
            return fn()
        end
        local orig_set = SUISettings.set
        local orig_save = SUISettings.saveSetting
        SUISettings.set = SUISettings.setNoFlush
        SUISettings.saveSetting = SUISettings.setNoFlush
        local ok, res = pcall(fn)
        SUISettings.set = orig_set
        SUISettings.saveSetting = orig_save
        if not ok then error(res) end
        return res
    end

    local function flushSUISettings()
        if SUISettings and type(SUISettings.flush) == "function" then
            pcall(function() SUISettings:flush() end)
        end
    end

    local function trySurgicalOffsetUpdate(sc, slot, is_fast, sheet_top_y)
        local lay = slot and slot.widget and slot.widget._yan_layout
        if not lay then return false end
        local p = lay.pfx
        local sc_f = lay.scale
        local tx = math.floor(CFG.getTitlePosX(p) * sc_f)
        local ty = math.floor(CFG.getTitlePosY(p) * sc_f)
        local sx = math.floor(CFG.getStatsPosX(p) * sc_f)
        local sy = math.floor(CFG.getStatsPosY(p) * sc_f)
        local uvx = math.floor(CFG.getVisualsPosX(p) * sc_f)
        local uvy = math.floor(CFG.getVisualsPosY(p) * sc_f)
        local vy = lay.both_borders and sy or uvy

        local min_top_y = (lay.show_visuals and not lay.both_borders)
            and math.min(0, ty, lay.base_stats_y + sy, lay.base_stats_y + vy)
            or  math.min(0, ty, lay.base_stats_y + sy)
        if lay.is_horizontal then
            min_top_y = math.min(min_top_y, lay.base_stats_y + sy + (lay.both_borders and lay.frame_total_h or lay.stats_grid_h) + lay.hbar_offset_gap + uvy)
        end
        local new_top_pad = math.max(0, -min_top_y)

        local hbar_bot_extra = (lay.is_horizontal and lay.hbar_container)
            and math.max(0, lay.hbar_extra_h + math.max(0, uvy))
            or lay.hbar_extra_h
        local mid_req_h = math.max(
            lay.fixed_ta_h + math.max(0, ty),
            lay.base_stats_y + math.max(0, sy)
                + (lay.both_borders and lay.frame_total_h or lay.stats_grid_h)
                + hbar_bot_extra
        )
        local right_req_h = (lay.show_visuals and not lay.both_borders)
            and (lay.base_stats_y + math.max(0, vy) + lay.visuals_h)
            or 0
        local right_h = (lay.show_visuals and not lay.both_borders)
            and math.max(mid_req_h, right_req_h)
            or mid_req_h
        local new_content_h = new_top_pad + math.max(lay.deck_h, right_h)

        if new_top_pad ~= lay.top_pad or new_content_h ~= lay.content_h then
            return false
        end

        if lay.pos then
            lay.pos.tx, lay.pos.ty = tx, ty
            lay.pos.sx, lay.pos.sy = sx, sy
            lay.pos.vx, lay.pos.vy = uvx, uvy
        end

        if lay.info_tap_container and lay.info_tap_container.overlap_offset then
            lay.info_tap_container.overlap_offset[1] = tx
            lay.info_tap_container.overlap_offset[2] = new_top_pad + ty
        end
        if lay.both_borders then
            if lay.unified_frame and lay.unified_frame.overlap_offset then
                lay.unified_frame.overlap_offset[1] = sx
                lay.unified_frame.overlap_offset[2] = new_top_pad + lay.base_stats_y + sy
            end
            if lay.visuals_shifted and lay.visuals_shifted.overlap_offset and lay.inner_h then
                local base_y = math.floor((lay.inner_h - lay.vw_raw_h) / 2)
                local target_y = base_y + uvy
                if lay.inner_h > lay.vw_raw_h then
                    target_y = math.max(1, math.min(math.max(1, lay.inner_h - lay.vw_raw_h - 1), target_y))
                end
                local max_vx = math.max(0, math.floor((lay.inner_w or 0) * 0.45))
                local target_x = math.max(-max_vx, math.min(max_vx, uvx))
                lay.visuals_shifted.overlap_offset[1] = target_x
                lay.visuals_shifted.overlap_offset[2] = target_y
            end
            if lay.is_horizontal and lay.hbar_container and lay.hbar_container.overlap_offset then
                lay.hbar_container.overlap_offset[1] = uvx
                lay.hbar_container.overlap_offset[2] = new_top_pad + lay.base_stats_y + sy + lay.frame_total_h + lay.hbar_offset_gap + uvy
            end
        else
            if lay.grid_widget and lay.grid_widget.overlap_offset then
                lay.grid_widget.overlap_offset[1] = sx
                lay.grid_widget.overlap_offset[2] = new_top_pad + lay.base_stats_y + sy
            end
            if lay.is_horizontal and lay.hbar_container and lay.hbar_container.overlap_offset then
                lay.hbar_container.overlap_offset[1] = uvx
                lay.hbar_container.overlap_offset[2] = new_top_pad + lay.base_stats_y + sy + lay.stats_grid_h + lay.hbar_offset_gap + uvy
            end
            if lay.show_visuals and lay.visuals_widget and lay.visuals_widget.overlap_offset then
                lay.visuals_widget.overlap_offset[1] = (lay.base_vis_x or 0) + uvx
                lay.visuals_widget.overlap_offset[2] = new_top_pad + lay.base_stats_y + vy
            end
        end

        local refresh_mode = is_fast and "ui" or getPreviewRefreshMode()
        local wrapper = slot.has_menu and sc._wrapper_pool and sc._wrapper_pool["currently_yanllsama"]
        local paint_target = wrapper or slot.widget
        local rect = paint_target and paint_target.dimen
        paintSlotDirect(
            sc,
            paint_target,
            rect and rect.x,
            rect and rect.y,
            rect and rect.w,
            rect and rect.h,
            resolveScreenBgColor(lay),
            refresh_mode,
            sheet_top_y
        )
        return true
    end

    relayoutScreensKeepCache = function(screens, rmode)
        local live = screens or getLiveScreens()
        if #live == 0 then
            local SE = getSUIModule("sui_screen_engine", "engines")
                or getSUIModule("sui_homescreen", "screens")
            if SE and type(SE.refresh) == "function" then
                SE.refresh(true)
            else
                local Event = require("ui/event")
                UIManager:broadcastEvent(Event:new("SimpleUIHomescreenRefresh"))
            end
            return false
        end
        local mode = rmode or getPreviewRefreshMode()
        local ok_any = false
        for _, sc in ipairs(live) do
            if sc._navbar_container and type(sc._updatePage) == "function" then
                sc:_updatePage(true)
                if mode == "partial" then UIManager:avoidFlashOnNextRepaint() end
                UIManager:setDirty(sc, mode)
                ok_any = true
            elseif type(sc._refreshImmediate) == "function" then
                sc:_refreshImmediate(true)
                if mode == "partial" then UIManager:avoidFlashOnNextRepaint() end
                UIManager:setDirty(sc, mode)
                ok_any = true
            elseif type(sc.refresh) == "function" then
                sc:refresh(false)
                ok_any = true
            end
        end
        return ok_any
    end

    triggerSurgicalPreviewRepaint = function(is_fast, opt_offset_only, skip_fallback, sheet_top_y)
        local live_screens = getLiveScreens()
        local repainted = false
        local height_changed = false
        local refresh_mode = is_fast and "ui" or getPreviewRefreshMode()

        for _, sc in ipairs(live_screens) do
            if sc._ctx_cache and sc._book_mod_slots then
                local slot = sc._book_mod_slots["currently_yanllsama"]
                if slot and slot.mod and type(slot.mod.build) == "function" then
                    if opt_offset_only and trySurgicalOffsetUpdate(sc, slot, is_fast, sheet_top_y) then
                        repainted = true
                    else
                        local wrapper_existing = slot.has_menu and sc._wrapper_pool and sc._wrapper_pool["currently_yanllsama"]
                        local old_dimen = (wrapper_existing and wrapper_existing.dimen) or (slot.widget and slot.widget.dimen)
                        local old_x = old_dimen and old_dimen.x
                        local old_y = old_dimen and old_dimen.y
                        local old_w = old_dimen and old_dimen.w or 0
                        local old_h = old_dimen and old_dimen.h or 0

                        sc._ctx_cache._yan_live_preview = true
                        local ok_b, new_widget, new_content = pcall(sc._buildModWidget, sc, slot.mod, slot.col_w, sc._ctx_cache, slot.min_h)
                        sc._ctx_cache._yan_live_preview = nil
                        if ok_b and new_widget then
                            local paint_target
                            if slot.has_menu and sc._wrapper_pool and sc._wrapper_pool["currently_yanllsama"] then
                                local wrapper = sc:_makeModWrapper(slot.mod, new_widget, slot.col_w)
                                slot.widget  = new_widget
                                slot.content = new_content
                                local new_h = wrapper.dimen and wrapper.dimen.h or 0
                                if math.abs(new_h - old_h) > 1 then height_changed = true end
                                paint_target = wrapper
                                repainted = true
                            elseif slot.parent then
                                slot.parent[slot.index] = new_widget
                                slot.widget  = new_widget
                                slot.content = new_content
                                local new_h = new_widget.dimen and new_widget.dimen.h or 0
                                if math.abs(new_h - old_h) > 1 then height_changed = true end
                                paint_target = new_widget
                                repainted = true
                            end
                            local stats_slot = sc._stats_mod_slots and sc._stats_mod_slots["currently_yanllsama"]
                            if stats_slot then stats_slot.content = new_content end
                            if sc._cover_mod_slots and slot.mod.has_covers and type(slot.mod.updateCovers) == "function" then
                                sc._cover_mod_slots["currently_yanllsama"] = { mod = slot.mod, widget = new_content }
                            end
                            if repainted and paint_target and (is_fast or not height_changed) then
                                local bg_c = resolveScreenBgColor(new_widget._yan_layout)
                                paintSlotDirect(sc, paint_target, old_x, old_y, old_w, old_h, bg_c, refresh_mode, sheet_top_y)
                            end
                        end
                    end
                end
            end
        end

        if not repainted and not skip_fallback then
            repainted = relayoutScreensKeepCache(live_screens, refresh_mode)
        end
        return repainted, height_changed
    end

    local function makeSpinItem(opts)
        local unit = opts.unit or ""
        local min_val = opts.min or opts.value_min or 0
        local max_val = opts.max or opts.value_max or 100
        local step_val = opts.step or opts.value_step or 1
        local hold_step_val = opts.hold_step or opts.value_hold_step or (step_val * 4)
        local def_val = opts.default ~= nil and opts.default or opts.default_value
        local offset_only = opts.offset_only and true or false

        return {
            text_func = opts.text_func,
            enabled_func = opts.enabled_func,
            separator = opts.separator,
            keep_menu_open = true,
            value_func = opts.value_func or function() return "" end,
            callback = function()
                if opts.guard and not opts.guard() then return end

                local openSpinDialog
                openSpinDialog = function(init_val)
                    local cur_val = init_val or opts.get()
                    local initial = cur_val
                    local current_val = cur_val
                    local is_preview = CFG.getPreviewMode(pfx)

                    local stashed_sui, stashed_stack, live_screens = hideParentMenus(true)

                    local need_rebuild = (#live_screens == 0)
                    for _, sc in ipairs(live_screens) do
                        if not sc._ctx_cache or not sc._book_mod_slots then
                            need_rebuild = true
                            break
                        end
                    end
                    if need_rebuild then
                        refreshHomescreenImmediate()
                    else
                        for _, sc in ipairs(live_screens) do
                            UIManager:setDirty(sc, "ui")
                        end
                    end

                    local restored = false
                    local function doRestore()
                        if restored then return end
                        restored = true
                        restoreParentMenus(stashed_sui, stashed_stack)
                    end

                    local _preview_timer = nil
                    local _settle_timer = nil
                    local _last_preview_v = nil
                    local _last_rendered_v = initial
                    local _last_preview_ms = 0
                    local _session_height_changed = false
                    local LIVE_FAST_MS = offset_only and 20 or 50

                    local function cancelPendingTimers()
                        if _preview_timer then
                            pcall(function() UIManager:unschedule(_preview_timer) end)
                            _preview_timer = nil
                        end
                        if _settle_timer then
                            pcall(function() UIManager:unschedule(_settle_timer) end)
                            _settle_timer = nil
                        end
                    end

                    local function performPreview(v, is_fast)
                        if not is_preview then return end
                        local val_to_apply = (v ~= nil) and v or _last_preview_v
                        if val_to_apply == nil then return end
                        if _last_rendered_v == val_to_apply and (is_fast or not _session_height_changed) then
                            return
                        end
                        withNoFlush(function() opts.set(val_to_apply) end)
                        local repainted, h_changed = triggerSurgicalPreviewRepaint(is_fast, offset_only, not is_fast)
                        if h_changed then
                            _session_height_changed = true
                        end
                        _last_rendered_v = val_to_apply
                        if not is_fast and (not repainted or _session_height_changed) then
                            _session_height_changed = false
                            relayoutScreensKeepCache(live_screens, getPreviewRefreshMode())
                        end
                    end

                    local function scheduleSettle()
                        if not is_preview then return end
                        if _settle_timer then
                            pcall(function() UIManager:unschedule(_settle_timer) end)
                            _settle_timer = nil
                        end
                        _settle_timer = UIManager:scheduleIn(0.32, function()
                            _settle_timer = nil
                            if restored then return end
                            if _session_height_changed then
                                _session_height_changed = false
                                UIManager:avoidFlashOnNextRepaint()
                                relayoutScreensKeepCache(live_screens, getPreviewRefreshMode())
                            elseif needsColorSettle() then
                                settleColorRect()
                            end
                        end)
                    end

                    local function fastPreviewUpdate(v, is_commit)
                        withNoFlush(function() opts.set(v) end)
                        if not is_preview then return end
                        _last_preview_v = v

                        if _settle_timer then
                            pcall(function() UIManager:unschedule(_settle_timer) end)
                            _settle_timer = nil
                        end

                        if is_commit then
                            if _preview_timer then
                                pcall(function() UIManager:unschedule(_preview_timer) end)
                                _preview_timer = nil
                            end
                            _last_preview_ms = nowMs()
                            performPreview(v, true)
                            scheduleSettle()
                            return
                        end

                        local now = nowMs()
                        local elapsed = now - _last_preview_ms
                        if elapsed >= LIVE_FAST_MS then
                            if _preview_timer then
                                pcall(function() UIManager:unschedule(_preview_timer) end)
                                _preview_timer = nil
                            end
                            _last_preview_ms = now
                            performPreview(v, true)
                        elseif not _preview_timer then
                            local delay_s = math.max(0.015, (LIVE_FAST_MS - elapsed) / 1000)
                            _preview_timer = UIManager:scheduleIn(delay_s, function()
                                _preview_timer = nil
                                if restored then return end
                                _last_preview_ms = nowMs()
                                performPreview(nil, true)
                            end)
                        end
                    end

                    ensureFastSpinStepperControls()
                    local ActionSheet = getSUIModule("sui_action_sheet", "engines")
                    if ActionSheet and type(ActionSheet.show) == "function" then
                        local window
                        local info = opts.info
                        if type(info) == "function" then info = info() end

                        local function makeSections()
                            return {
                                {
                                    type      = "stepper",
                                    label     = opts.title,
                                    value     = current_val,
                                    min       = min_val,
                                    max       = max_val,
                                    step      = step_val,
                                    hold_step = hold_step_val,
                                    unit      = unit,
                                    on_change = function(v)
                                        current_val = v
                                        fastPreviewUpdate(v, false)
                                    end,
                                    on_commit = function(v)
                                        current_val = v
                                        fastPreviewUpdate(v, true)
                                    end,
                                }
                            }
                        end

                        local footer = {}
                        if opts.allow_manual then
                            footer[#footer + 1] = {
                                text = _lc("Enter Manually"),
                                callback = function()
                                    local InputDialog = require("ui/widget/inputdialog")
                                    local input_dlg
                                    input_dlg = InputDialog:new{
                                        title = opts.title,
                                        input = tostring(current_val),
                                        input_type = "number",
                                        input_hint = string.format("%d - %d%s", min_val, max_val, unit),
                                        description = string.format("%s (%d - %d%s)", _lc("Enter a value"), min_val, max_val, unit),
                                        buttons = {
                                            {
                                                {
                                                    text = _lc("Cancel"),
                                                    id = "close",
                                                    callback = function()
                                                        UIManager:close(input_dlg)
                                                    end,
                                                },
                                                {
                                                    text = _lc("Apply"),
                                                    is_enter_default = true,
                                                    callback = function()
                                                        local raw = input_dlg:getInputText()
                                                        local num = tonumber(raw)
                                                        UIManager:close(input_dlg)
                                                        if num then
                                                            local clamped = math.max(min_val, math.min(max_val, math.floor(num + 0.5)))
                                                            current_val = clamped
                                                            fastPreviewUpdate(clamped, true)
                                                            window:update{ sections = makeSections() }
                                                        end
                                                    end,
                                                },
                                            },
                                        },
                                    }
                                    UIManager:show(input_dlg)
                                    input_dlg:onShowKeyboard()
                                end,
                            }
                        end
                        if def_val ~= nil then
                            footer[#footer + 1] = {
                                text = _lc("Default"),
                                callback = function()
                                    current_val = def_val
                                    fastPreviewUpdate(def_val, true)
                                    window:update{ sections = makeSections() }
                                end,
                            }
                        end
                        footer[#footer + 1] = {
                            text = _lc("Cancel"),
                            callback = function()
                                cancelPendingTimers()
                                window:close()
                                doRestore()
                                if current_val ~= initial then
                                    opts.set(initial)
                                    flushSUISettings()
                                    if _session_height_changed then
                                        relayoutScreensKeepCache(live_screens, getPreviewRefreshMode())
                                    else
                                        triggerSurgicalPreviewRepaint(false, offset_only)
                                    end
                                    UIManager:setDirty(nil, "ui")
                                end
                            end,
                        }
                        footer[#footer + 1] = {
                            text = _lc("Apply"),
                            primary = true,
                            callback = function()
                                cancelPendingTimers()
                                window:close()
                                doRestore()
                                opts.set(current_val)
                                flushSUISettings()
                                if type(opts.on_apply) == "function" then
                                    pcall(opts.on_apply, current_val)
                                elseif (not is_preview) or (_last_rendered_v ~= current_val) or _session_height_changed then
                                    _session_height_changed = false
                                    notifyChange(nil, true, true)
                                else
                                    if type(refresh) == "function" then pcall(refresh) end
                                    UIManager:setDirty(nil, "ui")
                                end
                            end,
                        }

                        local show_args = {
                            name        = "sui_win_spin",
                            title       = opts.title,
                            message     = info,
                            position    = "bottom",
                            on_dismiss  = function()
                                cancelPendingTimers()
                                doRestore()
                                if current_val ~= initial then
                                    opts.set(initial)
                                    flushSUISettings()
                                    if _session_height_changed then
                                        relayoutScreensKeepCache(live_screens, getPreviewRefreshMode())
                                    else
                                        triggerSurgicalPreviewRepaint(false, offset_only)
                                    end
                                    UIManager:setDirty(nil, "ui")
                                end
                            end,
                            footer      = footer,
                            sections    = makeSections(),
                        }

                        local SUIWindow = getSUIModule("sui_window", "engines")
                        if SUIWindow and type(SUIWindow.new) == "function" then
                            local orig_new = SUIWindow.new
                            local function styleManualBtn(widget)
                                if type(widget) ~= "table" then return false end
                                if widget.radius ~= nil and widget[1] and widget[1][1] and widget[1][1].text then
                                    local Accent = getSUIModule("sui_accent", "infra")
                                    local lb = C.isColorScreenActive()
                                        and ((Accent and type(Accent.toColor) == "function" and Accent.toColor("#87CEFA")) or C.hexToColor("#87CEFA"))
                                        or Blitbuffer.COLOR_GRAY_D
                                    widget.background = lb
                                    widget[1][1].fgcolor = Blitbuffer.COLOR_BLACK
                                    widget[1][1].bold = true
                                    return true
                                end
                                for i = 1, #widget do
                                    if styleManualBtn(widget[i]) then return true end
                                end
                                return false
                            end
                            SUIWindow.new = function(self_cls, wopts, ...)
                                if type(wopts) == "table" and wopts.name == "sui_win_spin" then
                                    wopts.position = "bottom"
                                    if opts.allow_manual and wopts.screen_footers and type(wopts.screen_footers.__root__) == "function" then
                                        local orig_root = wopts.screen_footers.__root__
                                        wopts.screen_footers.__root__ = function(fctx, ...)
                                            local res = orig_root(fctx, ...)
                                            if res and res[2] and res[2][1] then
                                                styleManualBtn(res[2][1])
                                            end
                                            return res
                                        end
                                    end
                                end
                                return orig_new(self_cls, wopts, ...)
                            end
                            local ok_show, show_res = pcall(ActionSheet.show, show_args)
                            SUIWindow.new = orig_new
                            if ok_show then
                                window = show_res
                            else
                                error(show_res)
                            end
                        else
                            window = ActionSheet.show(show_args)
                        end
                        return
                    end

                    local SpinWidget = require("ui/widget/spinwidget")
                    local spin_dlg
                    spin_dlg = SpinWidget:new{
                        title_text      = opts.title,
                        info_text       = opts.info,
                        value           = cur_val,
                        value_min       = min_val,
                        value_max       = max_val,
                        value_step      = step_val,
                        value_hold_step = hold_step_val,
                        default_value   = def_val,
                        unit            = unit,
                        ok_text         = _("Apply"),
                        cancel_text     = _("Close"),
                        callback        = function(spin)
                            cancelPendingTimers()
                            doRestore()
                            opts.set(spin.value)
                            flushSUISettings()
                            notifyChange(nil, true, true)
                        end,
                    }
                    spin_dlg.modal = true
                    local orig_onClose = spin_dlg.onClose
                    spin_dlg.onClose = function(s)
                        cancelPendingTimers()
                        doRestore()
                        if orig_onClose then orig_onClose(s) end
                    end
                    UIManager:nextTick(function()
                        UIManager:show(spin_dlg)
                    end)
                end

                UIManager:nextTick(function()
                    openSpinDialog()
                end)
            end,
        }
    end

    local function makePosition2DItem(opts)
        return {
            text_func = function()
                local x = opts.get_x()
                local y = opts.get_y()
                if x == 0 and y == 0 then
                    return string.format("%s: X 0, Y 0%s", opts.title, _lc(" (Default)"))
                end
                local xs = (x > 0 and "+" or "") .. tostring(x)
                local ys = (y > 0 and "+" or "") .. tostring(y)
                return string.format("%s: X %s, Y %s px", opts.title, xs, ys)
            end,
            keep_menu_open = true,
            callback = function()
                UIManager:nextTick(function()
                    PositionEditor.show{
                        title                         = opts.title,
                        _lc                           = _lc,
                        is_preview                    = CFG.getPreviewMode(pfx),
                        win_size                      = CFG.getPosWinSize(pfx),
                        win_pos                       = CFG.getPosWinPos(pfx),
                        get_x                         = opts.get_x,
                        set_x                         = opts.set_x,
                        get_y                         = opts.get_y,
                        set_y                         = opts.set_y,
                        min_x                         = opts.min_x or -250,
                        max_x                         = opts.max_x or 250,
                        min_y                         = opts.min_y or -250,
                        max_y                         = opts.max_y or 250,
                        default_x                     = 0,
                        default_y                     = 0,
                        hideParentMenus               = hideParentMenus,
                        restoreParentMenus            = restoreParentMenus,
                        refreshHomescreenImmediate    = refreshHomescreenImmediate,
                        triggerSurgicalPreviewRepaint = triggerSurgicalPreviewRepaint,
                        relayoutScreensKeepCache      = relayoutScreensKeepCache,
                        getPreviewRefreshMode         = getPreviewRefreshMode,
                        needsColorSettle              = needsColorSettle,
                        settleColorRect               = settleColorRect,
                        withNoFlush                   = withNoFlush,
                        flushSUISettings              = flushSUISettings,
                        notifyChange                  = notifyChange,
                        refresh                       = refresh,
                    }
                end)
            end,
        }
    end

    -- Positioning & Borders submenu
    local positioning_menu = {
        makePosition2DItem({
            title = _lc("Title and Author"),
            get_x = function() return CFG.getTitlePosX(pfx) end,
            set_x = function(v) SUISettings:saveSetting(pfx .. CFG.TITLE_POS_X_KEY, v) end,
            get_y = function() return CFG.getTitlePosY(pfx) end,
            set_y = function(v) SUISettings:saveSetting(pfx .. CFG.TITLE_POS_Y_KEY, v) end,
            min_x = -250, max_x = 250, min_y = -200, max_y = 200,
        }),
        makePosition2DItem({
            title = _lc("Statistics Table"),
            get_x = function() return CFG.getStatsPosX(pfx) end,
            set_x = function(v) SUISettings:saveSetting(pfx .. CFG.STATS_POS_X_KEY, v) end,
            get_y = function() return CFG.getStatsPosY(pfx) end,
            set_y = function(v) SUISettings:saveSetting(pfx .. CFG.STATS_POS_Y_KEY, v) end,
            min_x = -250, max_x = 250, min_y = -200, max_y = 200,
        }),
        makePosition2DItem({
            title = _lc("Progress Visuals"),
            get_x = function() return CFG.getVisualsPosX(pfx) end,
            set_x = function(v) SUISettings:saveSetting(pfx .. CFG.VISUALS_POS_X_KEY, v) end,
            get_y = function() return CFG.getVisualsPosY(pfx) end,
            set_y = function(v) SUISettings:saveSetting(pfx .. CFG.VISUALS_POS_Y_KEY, v) end,
            min_x = -350, max_x = 350, min_y = -300, max_y = 300,
        }),
        {
            text_func = function() return CFG.getShowStatsBorder(pfx) and _lc("Statistics Border: On") or _lc("Statistics Border: Off") end,
            keep_menu_open = true,
            callback = function() SUISettings:saveSetting(pfx .. CFG.SHOW_STATS_BORDER_KEY, not CFG.getShowStatsBorder(pfx)) notifyChange() end,
        },
        {
            text_func = function() return CFG.getShowVisualsBorder(pfx) and _lc("Visuals Border: On") or _lc("Visuals Border: Off") end,
            keep_menu_open = true,
            callback = function() SUISettings:saveSetting(pfx .. CFG.SHOW_VISUALS_BORDER_KEY, not CFG.getShowVisualsBorder(pfx)) notifyChange() end,
        },
        makeSpinItem({
            text_func = function()
                local r = CFG.getBorderRadius(pfx)
                local str = tostring(r) .. " px" .. (r == 10 and _lc(" (Default)") or "")
                return string.format("%s: %s", _lc("Corner Radius"), str)
            end,
            title = _lc("Corner Radius"),
            info = _lc("Corner radius for the statistics and progress borders.\nDefault is 10 px. Set to 0 px for square corners."),
            get = function() return CFG.getBorderRadius(pfx) end,
            set = function(v) SUISettings:saveSetting(pfx .. CFG.BORDER_RADIUS_KEY, v) end,
            min = 0, max = 30, step = 1, default = 10, unit = "px",
        }),
        {
            text_func = function()
                return CFG.getHeaderRadiusEnabled(pfx) and _lc("Tab Headers Radius: On") or _lc("Tab Headers Radius: Off")
            end,
            keep_menu_open = true,
            callback = function()
                SUISettings:saveSetting(pfx .. CFG.HEADER_RADIUS_KEY, not CFG.getHeaderRadiusEnabled(pfx))
                notifyChange()
            end,
        },
        makeSpinItem({
            text_func = function()
                local r = CFG.getStatsWidthRatio(pfx)
                return string.format("%s: %%%d / %%%d%s", _lc("Width Ratio (Stats / Visuals)"), r, 100 - r, r == 65 and _lc(" (Default)") or "")
            end,
            title = _lc("Width Ratio (Stats / Visuals)"),
            get = function() return CFG.getStatsWidthRatio(pfx) end,
            set = function(v) SUISettings:saveSetting(pfx .. CFG.STATS_WIDTH_RATIO_KEY, v) end,
            min = 40, max = 85, step = 5, default = 65, unit = "%",
        }),
        makeSpinItem({
            text_func = function()
                local m = CFG.getSideMargin(pfx)
                local str = (m == 0) and _lc("0 px (Full Width)") or string.format("%d px", m)
                return string.format("%s: %s", _lc("Side Padding"), str)
            end,
            title = _lc("Side Padding"),
            info = _lc("Horizontal side padding for the module.\n0 px expands to full width, matching all other SimpleUI modules."),
            get = function() return CFG.getSideMargin(pfx) end,
            set = function(v) SUISettings:saveSetting(pfx .. CFG.SIDE_MARGIN_KEY, v) end,
            min = 0, max = 60, step = 2, default = 0, unit = "px",
        }),
        {
            text = _lc("Positioning Window"),
            separator = true,
            sub_item_table = {
                {
                    text_func = function()
                        local sz = CFG.getPosWinSize(pfx)
                        local names = {
                            small  = _lc("Small"),
                            medium = _lc("Medium") .. _lc(" (Default)"),
                            large  = _lc("Large"),
                        }
                        return string.format("%s: %s", _lc("Window Size"), names[sz] or (_lc("Medium") .. _lc(" (Default)")))
                    end,
                    sub_item_table = {
                        {
                            text = _lc("Small"),
                            radio = true,
                            keep_menu_open = true,
                            checked_func = function() return CFG.getPosWinSize(pfx) == "small" end,
                            callback = function() SUISettings:saveSetting(pfx .. CFG.POS_WIN_SIZE_KEY, "small") end,
                        },
                        {
                            text = _lc("Medium") .. _lc(" (Default)"),
                            radio = true,
                            keep_menu_open = true,
                            checked_func = function() return CFG.getPosWinSize(pfx) == "medium" end,
                            callback = function() SUISettings:saveSetting(pfx .. CFG.POS_WIN_SIZE_KEY, "medium") end,
                        },
                        {
                            text = _lc("Large"),
                            radio = true,
                            keep_menu_open = true,
                            checked_func = function() return CFG.getPosWinSize(pfx) == "large" end,
                            callback = function() SUISettings:saveSetting(pfx .. CFG.POS_WIN_SIZE_KEY, "large") end,
                        },
                    },
                },
                {
                    text_func = function()
                        local wp = CFG.getPosWinPos(pfx)
                        local names = {
                            bottom = _lc("At Bottom") .. _lc(" (Default)"),
                            center = _lc("In Center"),
                            top    = _lc("At Top"),
                        }
                        return string.format("%s: %s", _lc("Window Position"), names[wp] or (_lc("At Bottom") .. _lc(" (Default)")))
                    end,
                    sub_item_table = {
                        {
                            text = _lc("At Bottom") .. _lc(" (Default)"),
                            radio = true,
                            keep_menu_open = true,
                            checked_func = function() return CFG.getPosWinPos(pfx) == "bottom" end,
                            callback = function() SUISettings:saveSetting(pfx .. CFG.POS_WIN_POS_KEY, "bottom") end,
                        },
                        {
                            text = _lc("In Center"),
                            radio = true,
                            keep_menu_open = true,
                            checked_func = function() return CFG.getPosWinPos(pfx) == "center" end,
                            callback = function() SUISettings:saveSetting(pfx .. CFG.POS_WIN_POS_KEY, "center") end,
                        },
                        {
                            text = _lc("At Top"),
                            radio = true,
                            keep_menu_open = true,
                            checked_func = function() return CFG.getPosWinPos(pfx) == "top" end,
                            callback = function() SUISettings:saveSetting(pfx .. CFG.POS_WIN_POS_KEY, "top") end,
                        },
                    },
                },
            },
        },
    }

    -- Profiles menu
    local profiles_menu = {}
    local saved_profiles_sub = {}
    local buildProfilesMenu, rebuildSavedProfilesSub
    local function rebuildProfilesMenu()
        if type(rebuildSavedProfilesSub) == "function" then
            rebuildSavedProfilesSub()
        end
        for k in pairs(profiles_menu) do profiles_menu[k] = nil end
        for _, it in ipairs(buildProfilesMenu()) do
            table.insert(profiles_menu, it)
        end
    end
    local function syncProfileUI(touchmenu_instance)
        rebuildProfilesMenu()
        if touchmenu_instance and type(touchmenu_instance.updateItems) == "function" then
            pcall(function() touchmenu_instance:updateItems() end)
        end
        UIManager:nextTick(function()
            if type(refresh) == "function" then pcall(refresh) end
        end)
    end

    buildProfilesMenu = function()
        local sub = {}
        local profiles = CFG.getProfiles(pfx)
        local default_name = CFG.getDefaultProfileName(pfx)

        local function showProfileActionsDialog(target_name)
            local list = CFG.getProfiles(pfx)
            local target_idx, target_prof = nil, nil
            for i, p in ipairs(list) do
                if p.name == target_name then
                    target_idx, target_prof = i, p
                    break
                end
            end
            if not target_prof then return end

            local is_locked = target_prof.locked == true
            local is_default = (CFG.getDefaultProfileName(pfx) == target_name)
            local in_quick = CFG.isProfileInQuickSwitch(pfx, target_name)

            local items = {
                {
                    text = _lc("Apply Profile"),
                    callback = function()
                        ProfilesMod.applyProfileData(pfx, target_prof.data)
                        SUISettings:saveSetting(pfx .. CFG.ACTIVE_PROFILE_KEY, target_name)
                        notifyChange(nil, nil, true)
                        rebuildProfilesMenu()
                    end,
                },
                {
                    text = _lc("Overwrite with Current Settings"),
                    callback = function()
                        if is_locked then
                            suiConfirm{
                                title = _lc("Profile Locked"),
                                message = string.format(_lc("Profile '%s' is locked.\nUnlock it first if you want to overwrite it."), target_name),
                                ok_text = _("OK"),
                                cancel_text = nil,
                            }
                            return
                        end
                        suiConfirm{
                            title = _lc("Overwrite Profile"),
                            text = string.format(_lc("Overwrite profile '%s' with your current settings?"), target_name),
                            ok_text = _lc("Overwrite"),
                            cancel_text = _lc("Cancel"),
                            ok_callback = function()
                                local cur_list = CFG.getProfiles(pfx)
                                for _, cp in ipairs(cur_list) do
                                    if cp.name == target_name then
                                        cp.data = ProfilesMod.captureCurrentProfileData(pfx)
                                        break
                                    end
                                end
                                SUISettings:saveSetting(pfx .. CFG.PROFILES_KEY, cur_list)
                                SUISettings:saveSetting(pfx .. CFG.ACTIVE_PROFILE_KEY, target_name)
                                rebuildProfilesMenu()
                                notifyChange(nil, true)
                                suiToast(string.format(_lc("Profile '%s' updated."), target_name))
                            end,
                        }
                    end,
                },
                {
                    text = is_locked and _lc("Unlock Profile") or _lc("Lock Profile (Prevent Deletion & Edits)"),
                    callback = function()
                        local cur_list = CFG.getProfiles(pfx)
                        for _, cp in ipairs(cur_list) do
                            if cp.name == target_name then
                                cp.locked = not is_locked
                                break
                            end
                        end
                        SUISettings:saveSetting(pfx .. CFG.PROFILES_KEY, cur_list)
                        syncProfileUI()
                        notifyChange(nil, true)
                        suiToast(is_locked and _lc("Profile unlocked.") or _lc("Profile locked."))
                    end,
                },
                {
                    text = is_default and _lc("Unset as Default Profile") or _lc("Set as Default Profile (Auto-Load on Startup)"),
                    callback = function()
                        SUISettings:saveSetting(pfx .. CFG.DEFAULT_PROFILE_KEY, is_default and "" or target_name)
                        syncProfileUI()
                        notifyChange(nil, true)
                        suiToast(is_default and _lc("Default profile unset.") or string.format(_lc("'%s' set as default profile."), target_name))
                    end,
                },
                {
                    text = in_quick and _lc("Remove from Quick Switch") or _lc("Add to Quick Switch"),
                    callback = function()
                        CFG.setProfileInQuickSwitch(pfx, target_name, not in_quick)
                        rebuildProfilesMenu()
                        if type(refresh) == "function" then pcall(refresh) end
                        suiToast(in_quick and _lc("Removed from Quick Switch.") or _lc("Added to Quick Switch."))
                    end,
                },
                {
                    text = _lc("Rename Profile..."),
                    callback = function()
                        if is_locked then
                            suiToast(_lc("Unlock profile first to rename it."))
                            return
                        end
                        suiPrompt{
                            title = _lc("Rename Profile"),
                            value = target_name,
                            ok_text = _lc("Rename"),
                            cancel_text = _lc("Cancel"),
                            callback = function(new_name)
                                if not new_name or not new_name:match("%S") then return end
                                new_name = new_name:match("^%s*(.-)%s*$")
                                if new_name == target_name then return end
                                local cur_list = CFG.getProfiles(pfx)
                                for _, cp in ipairs(cur_list) do
                                    if cp.name == new_name then
                                        suiToast(_lc("A profile with that name already exists."))
                                        return
                                    end
                                end
                                for _, cp in ipairs(cur_list) do
                                    if cp.name == target_name then
                                        cp.name = new_name
                                        break
                                    end
                                end
                                SUISettings:saveSetting(pfx .. CFG.PROFILES_KEY, cur_list)
                                if CFG.getActiveProfileName(pfx) == target_name then
                                    SUISettings:saveSetting(pfx .. CFG.ACTIVE_PROFILE_KEY, new_name)
                                end
                                if CFG.getDefaultProfileName(pfx) == target_name then
                                    SUISettings:saveSetting(pfx .. CFG.DEFAULT_PROFILE_KEY, new_name)
                                end
                                local qraw = SUISettings:readSetting(pfx .. CFG.QUICK_PROFILES_KEY)
                                if type(qraw) == "table" and qraw[target_name] ~= nil then
                                    qraw[new_name] = qraw[target_name]
                                    qraw[target_name] = nil
                                    SUISettings:saveSetting(pfx .. CFG.QUICK_PROFILES_KEY, qraw)
                                end
                                syncProfileUI()
                                notifyChange(nil, true)
                            end,
                        }
                    end,
                },
                {
                    text = _lc("Delete Profile"),
                    callback = function()
                        if is_locked then
                            suiConfirm{
                                title = _lc("Profile Locked"),
                                message = string.format(_lc("Profile '%s' is locked and cannot be deleted!\nUnlock it first to delete."), target_name),
                                ok_text = _("OK"),
                                cancel_text = nil,
                            }
                            return
                        end
                        suiConfirm{
                            title = _lc("Delete Profile"),
                            text = string.format(_lc("Are you sure you want to delete profile '%s'?"), target_name),
                            ok_text = _lc("Delete"),
                            cancel_text = _lc("Cancel"),
                            ok_callback = function()
                                local cur_list = CFG.getProfiles(pfx)
                                for i, cp in ipairs(cur_list) do
                                    if cp.name == target_name then
                                        table.remove(cur_list, i)
                                        break
                                    end
                                end
                                SUISettings:saveSetting(pfx .. CFG.PROFILES_KEY, cur_list)
                                if CFG.getActiveProfileName(pfx) == target_name then
                                    SUISettings:saveSetting(pfx .. CFG.ACTIVE_PROFILE_KEY, "")
                                end
                                if CFG.getDefaultProfileName(pfx) == target_name then
                                    SUISettings:saveSetting(pfx .. CFG.DEFAULT_PROFILE_KEY, "")
                                end
                                local qraw = SUISettings:readSetting(pfx .. CFG.QUICK_PROFILES_KEY)
                                if type(qraw) == "table" and qraw[target_name] ~= nil then
                                    qraw[target_name] = nil
                                    SUISettings:saveSetting(pfx .. CFG.QUICK_PROFILES_KEY, qraw)
                                end
                                syncProfileUI()
                                notifyChange(nil, true)
                                suiToast(string.format(_lc("Profile '%s' deleted."), target_name))
                            end,
                        }
                    end,
                },
            }

            suiActionMenu{
                name = "sui_win_profile_actions",
                title = string.format("%s: %s", _lc("Profile Actions"), target_name),
                items = items,
            }
        end

        rebuildSavedProfilesSub = function()
            for k in pairs(saved_profiles_sub) do saved_profiles_sub[k] = nil end
            local cur_profiles = CFG.getProfiles(pfx)
            local cur_def_name = CFG.getDefaultProfileName(pfx)
            if #cur_profiles > 0 then
                for _, p in ipairs(cur_profiles) do
                    local prof_name = p.name
                    local prof_data = p.data
                    local is_locked = p.locked == true
                    local is_default = (cur_def_name == prof_name)

                    local badge = ""
                    if is_default then badge = badge .. " ★" end
                    if is_locked then badge = badge .. " 🔒" end

                    table.insert(saved_profiles_sub, {
                        text = prof_name .. badge,
                        radio = true,
                        keep_menu_open = true,
                        checked_func = function()
                            return CFG.getActiveProfileName(pfx) == prof_name
                        end,
                        callback = function()
                            ProfilesMod.applyProfileData(pfx, prof_data)
                            SUISettings:saveSetting(pfx .. CFG.ACTIVE_PROFILE_KEY, prof_name)
                            syncProfileUI()
                            notifyChange(nil, nil, true)
                        end,
                        on_hold = function() showProfileActionsDialog(prof_name) end,
                        hold_callback = function() showProfileActionsDialog(prof_name) end,
                        sui_build = function(build_ctx)
                            local SUI = getSUIModule("sui_window", "engines")
                            if not SUI or not SUI.ListRow then return nil end

                            local is_active = (CFG.getActiveProfileName(pfx) == prof_name)
                            local row = SUI.ListRow{
                                title = prof_name .. badge,
                                inner_w = (build_ctx and build_ctx.inner_w) or Screen:getWidth(),
                                checked = is_active,
                                on_tap = function()
                                    ProfilesMod.applyProfileData(pfx, prof_data)
                                    SUISettings:saveSetting(pfx .. CFG.ACTIVE_PROFILE_KEY, prof_name)
                                    syncProfileUI()
                                    notifyChange(nil, nil, true)
                                end,
                                on_more = function() showProfileActionsDialog(prof_name) end,
                                on_hold = function() showProfileActionsDialog(prof_name) end,
                            }
                            local ic = row and row[1]
                            if ic and ic.ges_events then
                                local hold_done = false
                                ic.ges_events.Hold = {
                                    GestureRange:new{ ges = "hold", range = function() return ic.dimen end }
                                }
                                ic.ges_events.HoldRelease = {
                                    GestureRange:new{ ges = "hold_release", range = function() return ic.dimen end }
                                }
                                function ic:onHold()
                                    hold_done = true
                                    showProfileActionsDialog(prof_name)
                                    return true
                                end
                                function ic:onHoldRelease()
                                    if not hold_done then showProfileActionsDialog(prof_name) end
                                    hold_done = false
                                    return true
                                end
                            end
                            return row
                        end,
                    })
                end

                table.insert(saved_profiles_sub, {
                    text = _lc("Manage Profile Options..."),
                    callback = function()
                        local cur_profs = CFG.getProfiles(pfx)
                        if #cur_profs == 1 then
                            showProfileActionsDialog(cur_profs[1].name)
                        else
                            local picker_items = {}
                            for _, p in ipairs(cur_profs) do
                                local p_name = p.name
                                table.insert(picker_items, {
                                    text = p_name .. (p.locked and " 🔒" or "") .. (CFG.getDefaultProfileName(pfx) == p_name and " ★" or ""),
                                    callback = function() showProfileActionsDialog(p_name) end,
                                })
                            end
                            suiActionMenu{
                                title = _lc("Select Profile to Manage"),
                                items = picker_items,
                                cancel_text = _lc("Cancel"),
                            }
                        end
                    end,
                })
            else
                table.insert(saved_profiles_sub, { text = _lc("(No saved profiles)"), dim = true })
            end
            return saved_profiles_sub
        end
        rebuildSavedProfilesSub()

        table.insert(sub, {
            text_func = function()
                local cur_active = CFG.getActiveProfileName(pfx)
                if cur_active and cur_active ~= "" then
                    return string.format("%s: %s", _lc("Saved Profiles"), cur_active)
                else
                    return _lc("Saved Profiles")
                end
            end,
            sub_item_table_func = function() return rebuildSavedProfilesSub() end,
        })

        table.insert(sub, {
            text_func = function()
                if not CFG.getQuickSwitchEnabled(pfx) then
                    return string.format("%s (%s)", _lc("Quick Profile Switch"), _lc("Off"))
                end
                local all_p = CFG.getProfiles(pfx)
                local raw_q = SUISettings and SUISettings:readSetting(pfx .. CFG.QUICK_PROFILES_KEY)
                if type(raw_q) ~= "table" then
                    return string.format("%s (%s)", _lc("Quick Profile Switch"), _lc("All"))
                end
                local q_list = CFG.getQuickSwitchProfiles(pfx)
                return string.format("%s (%d/%d)", _lc("Quick Profile Switch"), #q_list, #all_p)
            end,
            sub_item_table_func = function()
                local cur_profs = CFG.getProfiles(pfx)
                local q_sub = {}

                local function applyQuickRefresh(touchmenu_instance)
                    rebuildProfilesMenu()
                    if touchmenu_instance and type(touchmenu_instance.updateItems) == "function" then
                        touchmenu_instance:updateItems()
                    end
                    if type(refresh) == "function" then
                        pcall(refresh)
                    end
                end

                local function isQuickOn()
                    return CFG.getQuickSwitchEnabled(pfx)
                end

                table.insert(q_sub, {
                    text_func = function()
                        return isQuickOn()
                            and _lc("Quick Profile Switch: On")
                            or  _lc("Quick Profile Switch: Off")
                    end,
                    keep_menu_open = true,
                    checked_func = isQuickOn,
                    callback = function(touchmenu_instance)
                        if SUISettings then
                            SUISettings:saveSetting(pfx .. CFG.QUICK_SWITCH_ENABLED_KEY, not isQuickOn())
                        end
                        applyQuickRefresh(touchmenu_instance)
                    end,
                })

                if #cur_profs == 0 then
                    table.insert(q_sub, { text = _lc("(No saved profiles)"), dim = true })
                    return q_sub
                end

                table.insert(q_sub, {
                    text = _lc("Select All"),
                    keep_menu_open = true,
                    enabled_func = isQuickOn,
                    callback = function(touchmenu_instance)
                        local tbl = { _configured = true }
                        for _, cp in ipairs(CFG.getProfiles(pfx)) do
                            if cp.name then tbl[cp.name] = true end
                        end
                        if SUISettings then
                            SUISettings:saveSetting(pfx .. CFG.QUICK_PROFILES_KEY, tbl)
                        end
                        applyQuickRefresh(touchmenu_instance)
                    end,
                })
                table.insert(q_sub, {
                    text = _lc("Clear All"),
                    keep_menu_open = true,
                    enabled_func = isQuickOn,
                    callback = function(touchmenu_instance)
                        if SUISettings then
                            SUISettings:saveSetting(pfx .. CFG.QUICK_PROFILES_KEY, { _configured = true })
                        end
                        applyQuickRefresh(touchmenu_instance)
                    end,
                })

                for _, p in ipairs(cur_profs) do
                    local pname = p.name
                    local pbadge = ""
                    if CFG.getDefaultProfileName(pfx) == pname then pbadge = pbadge .. " ★" end
                    if p.locked == true then pbadge = pbadge .. " 🔒" end
                    table.insert(q_sub, {
                        text = pname .. pbadge,
                        keep_menu_open = true,
                        enabled_func = isQuickOn,
                        checked_func = function()
                            return CFG.isProfileInQuickSwitch(pfx, pname)
                        end,
                        callback = function(touchmenu_instance)
                            local next_val = not CFG.isProfileInQuickSwitch(pfx, pname)
                            CFG.setProfileInQuickSwitch(pfx, pname, next_val)
                            applyQuickRefresh(touchmenu_instance)
                        end,
                    })
                end
                return q_sub
            end,
        })

        table.insert(sub, {
            text = _lc("Save as New Profile..."),
            callback = function()
                local cur_profs = CFG.getProfiles(pfx)
                local default_prof_name = string.format("%s %d", _lc("Profile"), #cur_profs + 1)
                suiPrompt{
                    title = _lc("Save as New Profile"),
                    description = _lc("Enter a name for the new profile:"),
                    value = default_prof_name,
                    ok_text = _lc("Save"),
                    cancel_text = _lc("Cancel"),
                    callback = function(name)
                        if not name or not name:match("%S") then return end
                        name = name:match("^%s*(.-)%s*$")
                        local list = CFG.getProfiles(pfx)
                        local existing_idx = nil
                        for i, p in ipairs(list) do
                            if p.name == name then existing_idx = i; break end
                        end
                        if existing_idx and list[existing_idx].locked then
                            suiConfirm{
                                title = _lc("Profile Locked"),
                                message = string.format(_lc("Profile '%s' is locked!\nYou must unlock it before overwriting."), name),
                                ok_text = _("OK"),
                                cancel_text = nil,
                            }
                            return
                        end
                        local doSave = function()
                            local snapshot = ProfilesMod.captureCurrentProfileData(pfx)
                            if existing_idx then list[existing_idx].data = snapshot
                            else table.insert(list, { name = name, data = snapshot, locked = false }) end
                            SUISettings:saveSetting(pfx .. CFG.PROFILES_KEY, list)
                            SUISettings:saveSetting(pfx .. CFG.ACTIVE_PROFILE_KEY, name)
                            syncProfileUI()
                            notifyChange(nil, true)
                            suiToast(string.format(_lc("Profile '%s' saved."), name))
                        end
                        if existing_idx then
                            suiConfirm{
                                title = _lc("Overwrite Profile?"),
                                text = string.format(_lc("Profile '%s' already exists.\nOverwrite?"), name),
                                ok_text = _lc("Overwrite"),
                                cancel_text = _lc("Cancel"),
                                ok_callback = doSave,
                            }
                        else
                            doSave()
                        end
                    end,
                }
            end,
        })

        table.insert(sub, {
            text = _lc("Reset to Factory Defaults..."),
            callback = function()
                suiConfirm{
                    title = _lc("Reset to Factory Defaults"),
                    text = _lc("Reset all settings for Currently Reading to default?"),
                    ok_text = _lc("Reset"),
                    cancel_text = _lc("Cancel"),
                    ok_callback = function()
                        ProfilesMod.resetAllSettingsToDefault(pfx)
                        SUISettings:saveSetting(pfx .. CFG.ACTIVE_PROFILE_KEY, "")
                        rebuildProfilesMenu()
                        notifyChange(nil, nil, nil, { full_rebuild = true, clear_stats = true })
                        suiToast(_lc("Settings reset to default."))
                    end,
                }
            end,
        })

        table.insert(sub, {
            text = _lc("Restore Bundled Profiles..."),
            callback = function()
                suiConfirm{
                    title = _lc("Restore Bundled Profiles"),
                    text = _lc("Restore default bundled profiles? Custom profiles created by you will be kept safely."),
                    ok_text = _lc("Restore"),
                    cancel_text = _lc("Cancel"),
                    ok_callback = function()
                        CFG.seedDefaultProfiles(pfx, true)
                        syncProfileUI()
                        notifyChange()
                        suiToast(_lc("Bundled profiles restored."))
                    end,
                }
            end,
        })

        table.insert(sub, {
            text = _lc("Export Profiles to Plugin..."),
            callback = function()
                suiConfirm{
                    title = _lc("Export Profiles to Plugin"),
                    text = _lc("Export current profiles to default_profiles.lua inside plugin?\n\nThis will update bundled presets for all future users."),
                    ok_text = _lc("Export"),
                    cancel_text = _lc("Cancel"),
                    ok_callback = function()
                        local ok, err = CFG.exportProfilesToPlugin(pfx)
                        if ok then
                            rebuildProfilesMenu()
                            suiToast(_lc("Profiles exported to plugin successfully."))
                        else
                            suiToast(_lc("Failed to export: ") .. tostring(err))
                        end
                    end,
                }
            end,
        })

        table.insert(sub, {
            text = _lc("Delete All Profiles from SimpleUI..."),
            separator = true,
            callback = function(touchmenu_instance)
                suiConfirm{
                    title = _lc("Delete All Profiles from SimpleUI"),
                    text = _lc("Delete all unlocked profiles from SimpleUI settings (sui_settings.lua)?\n\nLocked profiles will be kept. Unlocked presets in default_profiles.lua will reload on the next restart unless removed from default_profiles.lua."),
                    ok_text = _lc("Delete"),
                    cancel_text = _lc("Cancel"),
                    ok_callback = function()
                        local deleted_cnt, kept_cnt = ProfilesMod.purgeUnlockedProfilesFromStore(pfx)
                        syncProfileUI(touchmenu_instance)
                        notifyChange(nil, true)
                        suiToast(string.format(_lc("Deleted %d unlocked profile(s) from SimpleUI (%d locked kept)."), deleted_cnt, kept_cnt))
                    end,
                }
            end,
        })

        return sub
    end

    rebuildProfilesMenu()

    local GRAY_TONES = {
        { hex = "#000000", label = _lc("Black") },
        { hex = "#404040", label = _lc("Dark Gray") },
        { hex = "#737373", label = _lc("Medium Gray") },
        { hex = "#B0B0B0", label = _lc("Light Gray") },
    }

    local function formatColorHex(hex)
        if not hex then return _lc("Default") end
        if not C.isColorScreenActive() then
            for _, t in ipairs(GRAY_TONES) do
                if t.hex == hex then return t.label end
            end
        end
        return hex
    end

    local function saveColorSetting(key, hex, touchmenu_instance)
        if hex == nil then
            if SUISettings.del then
                SUISettings:del(pfx .. key)
            else
                SUISettings:saveSetting(pfx .. key, nil)
            end
        else
            SUISettings:saveSetting(pfx .. key, hex)
        end
        notifyChange()
        if touchmenu_instance and type(touchmenu_instance.updateItems) == "function" then
            touchmenu_instance:updateItems()
        end
    end

    local function openColorPicker(title, key, touchmenu_instance)
        local cur_hex = CFG.getColorHex(pfx, key)
        local is_color = C.isColorScreenActive()

        if is_color then
            local AccentPicker = getSUIModule("sui_accent_picker", "features")
            if AccentPicker and type(AccentPicker.show) == "function" then
                AccentPicker.show{
                    title      = title,
                    hex        = cur_hex,
                    clear_text = _lc("Default"),
                    on_apply   = function(hex)
                        saveColorSetting(key, hex, touchmenu_instance)
                    end,
                }
                return
            end
        end

        local ActionSheet = getSUIModule("sui_action_sheet", "engines")
        local Accent = getSUIModule("sui_accent", "infra")
        if (not is_color) and ActionSheet and type(ActionSheet.show) == "function" then
            local sel_hex = cur_hex
            local win, sections, footer
            local function toSwatchColor(h)
                if Accent and type(Accent.toColor) == "function" then
                    return Accent.toColor(h)
                end
                return C.hexToColor(h)
            end
            sections = function()
                local items = {}
                for i, t in ipairs(GRAY_TONES) do
                    local th = t.hex
                    items[i] = {
                        color    = toSwatchColor(th),
                        selected = (sel_hex == th),
                        callback = function()
                            sel_hex = th
                            win:update{ sections = sections(), footer = footer() }
                        end,
                    }
                end
                return {
                    { type = "swatches", items = items },
                    { type = "note", text = string.format("%s: %s", _lc("Selected Tone"), formatColorHex(sel_hex)) },
                }
            end
            footer = function()
                return {
                    { text = _lc("Default"), enabled = cur_hex ~= nil,
                      callback = function() win:close(); saveColorSetting(key, nil, touchmenu_instance) end },
                    { text = _lc("Cancel"), callback = function() win:close() end },
                    { text = _lc("Apply"), primary = true, enabled = sel_hex ~= nil and sel_hex ~= cur_hex,
                      callback = function() win:close(); saveColorSetting(key, sel_hex, touchmenu_instance) end },
                }
            end
            win = ActionSheet.show{
                name     = "sui_win_cr_gray_picker",
                title    = title,
                sections = sections(),
                footer   = footer(),
            }
            return
        end

        local ok_bd, ButtonDialog = pcall(require, "ui/widget/buttondialog")
        if not ok_bd or not ButtonDialog then return end
        local dlg
        local rows = {}
        if is_color then
            local pal = (Accent and Accent.PALETTE) or { "#2F6FDB", "#1B9AAA", "#2E8B57", "#B8860B", "#E07B1F", "#C93C3C", "#B03A8C", "#7A4FC7" }
            for i = 1, #pal, 2 do
                local row = {}
                for j = i, math.min(i + 1, #pal) do
                    local h = pal[j]
                    table.insert(row, {
                        text = (cur_hex == h and "● " or "") .. h,
                        callback = function() UIManager:close(dlg); saveColorSetting(key, h, touchmenu_instance) end,
                    })
                end
                table.insert(rows, row)
            end
        else
            for _, t in ipairs(GRAY_TONES) do
                local th, tl = t.hex, t.label
                table.insert(rows, { {
                    text = (cur_hex == th and "● " or "") .. tl,
                    callback = function() UIManager:close(dlg); saveColorSetting(key, th, touchmenu_instance) end,
                } })
            end
        end
        table.insert(rows, {
            { text = _lc("Default"), callback = function() UIManager:close(dlg); saveColorSetting(key, nil, touchmenu_instance) end },
            { text = _lc("Cancel"), callback = function() UIManager:close(dlg) end },
        })
        dlg = ButtonDialog:new{ title = title, buttons = rows }
        UIManager:show(dlg)
    end

    local function makeColorMenuItem(label_or_fn, key, with_sep)
        local function getTitle()
            return type(label_or_fn) == "function" and label_or_fn() or label_or_fn
        end
        return {
            text_func = function()
                return string.format("%s: %s", getTitle(), formatColorHex(CFG.getColorHex(pfx, key)))
            end,
            separator = with_sep or false,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                openColorPicker(getTitle(), key, touchmenu_instance)
            end,
        }
    end

    local function makeVisSlotColorItem(slot_idx, with_sep)
        local ring_keys = { _lc("1st Ring Color"), _lc("2nd Ring Color"), _lc("3rd Ring Color") }
        local bar_keys  = { _lc("1st Bar Color"),  _lc("2nd Bar Color"),  _lc("3rd Bar Color")  }
        return makeColorMenuItem(function()
            return (CFG.getBarStyle(pfx) == "rings") and ring_keys[slot_idx] or bar_keys[slot_idx]
        end, CFG.VIS_COLOR_KEYS[slot_idx], with_sep)
    end

    local function resetColorKeys(keys, toast_msg, touchmenu_instance)
        for _, k in ipairs(keys) do
            if SUISettings.del then
                SUISettings:del(pfx .. k)
            else
                SUISettings:saveSetting(pfx .. k, nil)
            end
        end
        notifyChange()
        if touchmenu_instance and type(touchmenu_instance.updateItems) == "function" then
            touchmenu_instance:updateItems()
        end
        suiToast(toast_msg)
    end

    local cover_settings_menu = {
        {
            text = _lc("Book Source"),
            sub_item_table = {
                { text = _lc("Recent"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getSource(pfx) == "recent" end, callback = function() SUISettings:saveSetting(pfx .. CFG.SETTING_SOURCE, "recent") notifyChange(nil, nil, nil, { full_rebuild = true }) end },
                { text = _lc("To Be Read (TBR)"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getSource(pfx) == "tbr" end, callback = function() SUISettings:saveSetting(pfx .. CFG.SETTING_SOURCE, "tbr") notifyChange(nil, nil, nil, { full_rebuild = true }) end },
            }
        },
        {
            text_func = function()
                local mode = CFG.getCoverDeckMode(pfx)
                local lbl = (mode == 1 and _lc("Single Cover (No Stack)"))
                    or (mode == 3 and _lc("3 Covers (1 Above / 1 Below)"))
                    or (mode == 7 and _lc("7 Covers (3 Above / 3 Below)"))
                    or _lc("5 Covers (2 Above / 2 Below)")
                return string.format("%s: %s", _lc("Cover Deck Stack"), lbl)
            end,
            sub_item_table = {
                { text = _lc("7 Covers (3 Above / 3 Below)"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getCoverDeckMode(pfx) == 7 end, callback = function() SUISettings:saveSetting(pfx .. CFG.COVER_DECK_MODE_KEY, 7) notifyChange() end },
                { text = _lc("5 Covers (2 Above / 2 Below)"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getCoverDeckMode(pfx) == 5 end, callback = function() SUISettings:saveSetting(pfx .. CFG.COVER_DECK_MODE_KEY, 5) notifyChange() end },
                { text = _lc("3 Covers (1 Above / 1 Below)"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getCoverDeckMode(pfx) == 3 end, callback = function() SUISettings:saveSetting(pfx .. CFG.COVER_DECK_MODE_KEY, 3) notifyChange() end },
                { text = _lc("Single Cover (No Stack)"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getCoverDeckMode(pfx) == 1 end, callback = function() SUISettings:saveSetting(pfx .. CFG.COVER_DECK_MODE_KEY, 1) notifyChange() end },
            }
        },
    }

    -- Context copy for Arrange.makeListItem so inline updates refresh homescreen without preview hijacking mid-edit
    local arrange_ctx = {}
    for k, v in pairs(ctx_menu) do arrange_ctx[k] = v end
    arrange_ctx.refresh = function()
        notifyChange(nil, true, true)
    end

    local Arrange = getSUIModule("sui_arrange", "features")

    -- Compact Left-Docked Statistics Items Editor (covers left cover column only for live preview)
    local edit_stats_item = {
        text = _lc("Edit Statistics Items"),
        value_func = function()
            return tostring(#CFG.getActiveOrderedStats(pfx))
        end,
        keep_menu_open = true,
        callback = function()
            StatsEditor.show{
                pfx                           = pfx,
                _lc                           = _lc,
                hideParentMenus               = hideParentMenus,
                restoreParentMenus            = restoreParentMenus,
                refreshHomescreenImmediate    = refreshHomescreenImmediate,
                triggerSurgicalPreviewRepaint = triggerSurgicalPreviewRepaint,
                withNoFlush                   = withNoFlush,
                flushSUISettings              = flushSUISettings,
            }
        end,
    }

    -- Progress Visuals Active Items Selector (max 3)
    local visual_pool_cached = nil
    local function getVisualPoolCached()
        if not visual_pool_cached then
            visual_pool_cached = CFG.getVisualPool(_lc)
        end
        return visual_pool_cached
    end

    local function fmtMinAsHr(mins)
        local h = mins / 60
        if math.floor(h) == h then
            return string.format("%d %s", math.floor(h), _lc("hr"))
        end
        return string.format("%.1f %s", h, _lc("hr"))
    end

    local function visualItemGoalDetail(vid)
        if vid == "book_progress" then return _lc("Automatic (Active Book)")
        elseif vid == "daily_page" then return string.format("%s: %d %s", _lc("Goal"), CFG.getDailyPageGoal(pfx), _lc("pages"))
        elseif vid == "daily_time" then return string.format("%s: %d %s", _lc("Goal"), CFG.getDailyTimeGoal(pfx), _lc("min"))
        elseif vid == "week_pages" then return string.format("%s: %d %s", _lc("Goal"), CFG.getWeekPageGoal(pfx), _lc("pages"))
        elseif vid == "week_time" then return string.format("%s: %s", _lc("Goal"), fmtMinAsHr(CFG.getWeekTimeGoal(pfx)))
        elseif vid == "month_pages" then return string.format("%s: %d %s", _lc("Goal"), CFG.getMonthPageGoal(pfx), _lc("pages"))
        elseif vid == "month_time" then return string.format("%s: %s", _lc("Goal"), fmtMinAsHr(CFG.getMonthTimeGoal(pfx)))
        elseif vid == "year_pages" then return string.format("%s: %d %s", _lc("Goal"), CFG.getYearPageGoal(pfx), _lc("pages"))
        elseif vid == "year_time" then return string.format("%s: %s", _lc("Goal"), fmtMinAsHr(CFG.getYearTimeGoal(pfx)))
        elseif vid == "year_books" then return string.format("%s: %d %s", _lc("Goal"), CFG.getYearBookGoal(pfx), _lc("books"))
        end
        return nil
    end

    local function makeVisualItemsMenuItem(is_vis_on)
        if Arrange and type(Arrange.makeListItem) == "function" then
            return Arrange.makeListItem{
                ctx_menu = arrange_ctx,
                title    = _lc("Visual Items (Max 3)"),
                max      = CFG.MAX_VISUAL_ITEMS,
                min      = 0,
                isEnabled = is_vis_on,
                labels   = {
                    action  = _lc("Arrange Visual Items"),
                    empty   = _lc("No visual items selected."),
                    too_few = _lc("Add at least 2 visual items to arrange."),
                    add     = _lc("Add Visual Item"),
                    full    = function(mx)
                        return string.format(_lc("You can activate at most %d progress visuals. Remove one first."), mx)
                    end,
                },
                pool   = getVisualPoolCached,
                getIds = function() return CFG.getActiveVisuals(pfx) end,
                setIds = function(ids) CFG.setActiveVisuals(pfx, ids) end,
                detail = visualItemGoalDetail,
            }
        else
            return {
                text_func = function()
                    return string.format("%s (%d / %d)", _lc("Visual Items (Max 3)"), #CFG.getActiveVisuals(pfx), CFG.MAX_VISUAL_ITEMS)
                end,
                enabled_func = is_vis_on,
                sub_item_table_func = function()
                    local rows = {}
                    for _, entry in ipairs(getVisualPoolCached()) do
                        local vid = entry.id
                        rows[#rows + 1] = {
                            text = entry.label,
                            keep_menu_open = true,
                            checked_func = function()
                                for _, a in ipairs(CFG.getActiveVisuals(pfx)) do
                                    if a == vid then return true end
                                end
                                return false
                            end,
                            callback = function()
                                local cur = CFG.getActiveVisuals(pfx)
                                local found_idx
                                for i, a in ipairs(cur) do
                                    if a == vid then found_idx = i; break end
                                end
                                if found_idx then
                                    table.remove(cur, found_idx)
                                else
                                    if #cur >= CFG.MAX_VISUAL_ITEMS then
                                        suiToast(string.format(_lc("You can activate at most %d progress visuals. Remove one first."), CFG.MAX_VISUAL_ITEMS))
                                        return
                                    end
                                    cur[#cur + 1] = vid
                                end
                                CFG.setActiveVisuals(pfx, cur)
                                notifyChange()
                            end,
                        }
                    end
                    return rows
                end,
            }
        end
    end

    -- Goals submenu (categorized by Daily, Weekly, Monthly, Yearly)
    local goals_menu = {
        {
            text = _lc("Daily"),
            sub_item_table = {
                makeSpinItem({
                    text_func = function() return string.format("%s: %d %s", _lc("Daily Page Goal"), CFG.getDailyPageGoal(pfx), _lc("pages")) end,
                    title = _lc("Daily Page Goal"),
                    get = function() return CFG.getDailyPageGoal(pfx) end,
                    set = function(v) SUISettings:saveSetting(pfx .. CFG.DAILY_PAGE_GOAL_KEY, v) end,
                    min = 5, max = 1000, step = 5, hold_step = 50, default = 50, unit = "", allow_manual = true,
                }),
                makeSpinItem({
                    text_func = function() return string.format("%s: %d %s", _lc("Daily Time Goal"), CFG.getDailyTimeGoal(pfx), _lc("min")) end,
                    title = _lc("Daily Time Goal"),
                    get = function() return CFG.getDailyTimeGoal(pfx) end,
                    set = function(v) SUISettings:saveSetting(pfx .. CFG.DAILY_TIME_GOAL_KEY, v) end,
                    min = 5, max = 480, step = 5, hold_step = 30, default = 30, unit = " " .. _lc("min"), allow_manual = true,
                }),
            },
        },
        {
            text = _lc("Weekly"),
            sub_item_table = {
                makeSpinItem({
                    text_func = function() return string.format("%s: %d %s", _lc("Weekly Page Goal"), CFG.getWeekPageGoal(pfx), _lc("pages")) end,
                    title = _lc("Weekly Page Goal"),
                    get = function() return CFG.getWeekPageGoal(pfx) end,
                    set = function(v) SUISettings:saveSetting(pfx .. CFG.WEEK_PAGE_GOAL_KEY, v) end,
                    min = 25, max = 5000, step = 25, hold_step = 200, default = 300, unit = "", allow_manual = true,
                }),
                makeSpinItem({
                    text_func = function() return string.format("%s: %s", _lc("Weekly Time Goal"), fmtMinAsHr(CFG.getWeekTimeGoal(pfx))) end,
                    title = _lc("Weekly Time Goal"),
                    get = function() return math.max(1, math.floor(CFG.getWeekTimeGoal(pfx) / 60 + 0.5)) end,
                    set = function(v) SUISettings:saveSetting(pfx .. CFG.WEEK_TIME_GOAL_KEY, math.max(1, v) * 60) end,
                    min = 1, max = 168, step = 1, hold_step = 5, default = 4, unit = " " .. _lc("hr"), allow_manual = true,
                }),
            },
        },
        {
            text = _lc("Monthly"),
            sub_item_table = {
                makeSpinItem({
                    text_func = function() return string.format("%s: %d %s", _lc("Monthly Page Goal"), CFG.getMonthPageGoal(pfx), _lc("pages")) end,
                    title = _lc("Monthly Page Goal"),
                    get = function() return CFG.getMonthPageGoal(pfx) end,
                    set = function(v) SUISettings:saveSetting(pfx .. CFG.MONTH_PAGE_GOAL_KEY, v) end,
                    min = 50, max = 20000, step = 50, hold_step = 500, default = 1000, unit = "", allow_manual = true,
                }),
                makeSpinItem({
                    text_func = function() return string.format("%s: %s", _lc("Monthly Time Goal"), fmtMinAsHr(CFG.getMonthTimeGoal(pfx))) end,
                    title = _lc("Monthly Time Goal"),
                    get = function() return math.max(1, math.floor(CFG.getMonthTimeGoal(pfx) / 60 + 0.5)) end,
                    set = function(v) SUISettings:saveSetting(pfx .. CFG.MONTH_TIME_GOAL_KEY, math.max(1, v) * 60) end,
                    min = 1, max = 744, step = 1, hold_step = 10, default = 15, unit = " " .. _lc("hr"), allow_manual = true,
                }),
            },
        },
        {
            text = _lc("Yearly"),
            sub_item_table = {
                makeSpinItem({
                    text_func = function() return string.format("%s: %d %s", _lc("Yearly Page Goal"), CFG.getYearPageGoal(pfx), _lc("pages")) end,
                    title = _lc("Yearly Page Goal"),
                    get = function() return CFG.getYearPageGoal(pfx) end,
                    set = function(v) SUISettings:saveSetting(pfx .. CFG.YEAR_PAGE_GOAL_KEY, v) end,
                    min = 100, max = 100000, step = 100, hold_step = 2000, default = 10000, unit = "", allow_manual = true,
                }),
                makeSpinItem({
                    text_func = function() return string.format("%s: %s", _lc("Yearly Time Goal"), fmtMinAsHr(CFG.getYearTimeGoal(pfx))) end,
                    title = _lc("Yearly Time Goal"),
                    get = function() return math.max(1, math.floor(CFG.getYearTimeGoal(pfx) / 60 + 0.5)) end,
                    set = function(v) SUISettings:saveSetting(pfx .. CFG.YEAR_TIME_GOAL_KEY, math.max(1, v) * 60) end,
                    min = 1, max = 8760, step = 5, hold_step = 25, default = 100, unit = " " .. _lc("hr"), allow_manual = true,
                }),
                makeSpinItem({
                    text_func = function() return string.format("%s: %d %s", _lc("Yearly Book Goal"), CFG.getYearBookGoal(pfx), _lc("books")) end,
                    title = _lc("Yearly Book Goal"),
                    get = function() return CFG.getYearBookGoal(pfx) end,
                    set = function(v) SUISettings:saveSetting(pfx .. CFG.YEAR_BOOK_GOAL_KEY, v) end,
                    min = 1, max = 500, step = 1, hold_step = 5, default = 12, unit = "", allow_manual = true,
                }),
            },
        },
    }

    return {
        makeSpinItem({
            text_func = function()
                local pct = Config.getModuleScalePct("currently_yanllsama", pfx)
                return pct == 100 and _lc("Scale") or string.format("%s (%d%%)", _lc("Scale"), pct)
            end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title = _lc("Scale"),
            info  = _lc("Scale for this module.\n100% is the default size."),
            get   = function() return Config.getModuleScalePct("currently_yanllsama", pfx) end,
            set   = function(v)
                Config.setModuleScale(v, "currently_yanllsama", pfx)
                local new_s = Config.getModuleScale("currently_yanllsama", pfx)
                for _, sc in ipairs(getLiveScreens()) do
                    if sc._ctx_cache and sc._ctx_cache.cfg and sc._ctx_cache.cfg.currently_yanllsama then
                        sc._ctx_cache.cfg.currently_yanllsama.scale = new_s
                    end
                end
            end,
            min = 50, max = 200, step = 5, hold_step = 15, default = 100, unit = "%",
        }),
        makeSpinItem({
            text_func = function()
                local pct = Config.getThumbScalePct("currently_yanllsama", pfx)
                return pct == 100 and _lc("Cover size") or string.format("%s (%d%%)", _lc("Cover size"), pct)
            end,
            title = _lc("Cover size"),
            info  = _lc("Scale for the cover thumbnail only.\n100% is the default size."),
            get   = function() return Config.getThumbScalePct("currently_yanllsama", pfx) end,
            set   = function(v)
                Config.setThumbScale(v, "currently_yanllsama", pfx)
                local new_ts = Config.getThumbScale("currently_yanllsama", pfx)
                for _, sc in ipairs(getLiveScreens()) do
                    if sc._ctx_cache and sc._ctx_cache.cfg and sc._ctx_cache.cfg.currently_yanllsama then
                        sc._ctx_cache.cfg.currently_yanllsama.thumb_scale = new_ts
                    end
                end
            end,
            min = 50, max = 200, step = 5, hold_step = 15, default = 100, unit = "%",
        }),
        makeSpinItem({
            text_func = function()
                local pct = CFG.getCoverGapPct(pfx)
                return pct == 100 and _lc("Cover Spacing") or string.format("%s (%d%%)", _lc("Cover Spacing"), pct)
            end,
            separator = true,
            title = _lc("Cover Spacing"),
            info  = _lc("Horizontal space between the cover and the text.\n100% is the default spacing."),
            get   = function() return CFG.getCoverGapPct(pfx) end,
            set   = function(v) SUISettings:saveSetting(pfx .. CFG.COVER_GAP_KEY, v) end,
            min = 0, max = 300, step = 10, hold_step = 30, default = 100, unit = "%",
        }),
        Config.makeLabelToggleItem("currently_yanllsama", _("Currently Reading"), notifyChange, _lc),

        {
            text = _lc("Statistics Layout & Appearance"),
            sub_item_table = {
                {
                    text_func = function()
                        local act = CFG.getActiveProfileName(pfx)
                        return (act and act ~= "") and string.format("%s: %s", _lc("Profiles"), act) or _lc("Profiles")
                    end,
                    sub_item_table = profiles_menu,
                },
                {
                    text = _lc("Cover Settings"),
                    sub_item_table = cover_settings_menu,
                },
                {
                    text = _lc("Positioning & Border Settings"),
                    sub_item_table = positioning_menu,
                },
                edit_stats_item,
                {
                    text = _lc("Grid Settings"),
                    sub_item_table = {
                        {
                            text = _lc("Grid Dimensions"),
                            sub_item_table = {
                                { text = _lc("Columns"), sub_item_table = makeCountMenu(CFG.GRID_COLS_KEY, 1, 4, 2) },
                                { text = _lc("Rows"), sub_item_table = makeCountMenu(CFG.GRID_ROWS_KEY, 1, 7, 4) },
                            },
                        },
                        {
                            text = _lc("Category Headers"),
                            sub_item_table = {
                                {
                                    text_func = function()
                                        local st = CFG.getHeaderStyle(pfx)
                                        local hdr_names = {
                                            underline        = _lc("Underline"),
                                            fill             = _lc("Gray Fill"),
                                            none             = _lc("Plain"),
                                            left_bar         = _lc("Left Accent Bar"),
                                            outlined         = _lc("Outlined Box"),
                                            underline_accent = _lc("Heavy Underline"),
                                            side_lines       = _lc("Side Lines"),
                                            badge            = _lc("Dark Capsule Badge"),
                                            bracket          = _lc("Bracket Frame"),
                                            underline_dot    = _lc("Dot & Line"),
                                        }
                                        return string.format("%s: %s", _lc("Header Style"), hdr_names[st] or _lc("Underline"))
                                    end,
                                    sub_item_table_func = function()
                                        local header_style_opts = {
                                            { id = "underline",        label = _lc("Underline") },
                                            { id = "fill",             label = _lc("Gray Fill") },
                                            { id = "none",             label = _lc("Plain") },
                                            { id = "left_bar",         label = _lc("Left Accent Bar") },
                                            { id = "outlined",         label = _lc("Outlined Box") },
                                            { id = "underline_accent", label = _lc("Heavy Underline") },
                                            { id = "side_lines",       label = _lc("Side Lines") },
                                            { id = "badge",            label = _lc("Dark Capsule Badge") },
                                            { id = "bracket",          label = _lc("Bracket Frame") },
                                            { id = "underline_dot",    label = _lc("Dot & Line") },
                                        }
                                        local out = {}
                                        for _, opt in ipairs(header_style_opts) do
                                            local sid = opt.id
                                            table.insert(out, {
                                                text = opt.label,
                                                radio = true,
                                                keep_menu_open = true,
                                                checked_func = function() return CFG.getHeaderStyle(pfx) == sid end,
                                                callback = function()
                                                    SUISettings:saveSetting(pfx .. CFG.HEADER_STYLE_KEY, sid)
                                                    notifyChange()
                                                end,
                                            })
                                        end
                                        return out
                                    end,
                                },
                                {
                                    text_func = function() return CFG.getShowHeaders(pfx) and _lc("Show Headers: On") or _lc("Show Headers: Off") end,
                                    keep_menu_open = true,
                                    callback = function() SUISettings:saveSetting(pfx .. CFG.SHOW_HEADERS_KEY, not CFG.getShowHeaders(pfx)) notifyChange() end,
                                },
                                {
                                    text = _lc("Header Thickness"),
                                    sub_item_table = {
                                        { text = _lc("Thin"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getHeaderWeight(pfx) == "thin" end, callback = function() SUISettings:saveSetting(pfx .. CFG.HEADER_WEIGHT_KEY, "thin") notifyChange() end },
                                        { text = _lc("Medium"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getHeaderWeight(pfx) == "medium" end, callback = function() SUISettings:saveSetting(pfx .. CFG.HEADER_WEIGHT_KEY, "medium") notifyChange() end },
                                        { text = _lc("Bold"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getHeaderWeight(pfx) == "bold" end, callback = function() SUISettings:saveSetting(pfx .. CFG.HEADER_WEIGHT_KEY, "bold") notifyChange() end },
                                    }
                                },
                                {
                                    text = _lc("Change Column 1 Header"),
                                    callback = function()
                                        suiPrompt{
                                            title = _lc("Column 1 Header"), value = CFG.getHeaderTxt(pfx, 1), allow_empty = true,
                                            ok_text = _lc("Save"), cancel_text = _lc("Cancel"),
                                            callback = function(text) SUISettings:saveSetting(pfx .. CFG.HEADER_TXT_PFX .. "1", text or "") notifyChange() end,
                                        }
                                    end,
                                },
                                {
                                    text = _lc("Change Column 2 Header"),
                                    callback = function()
                                        suiPrompt{
                                            title = _lc("Column 2 Header"), value = CFG.getHeaderTxt(pfx, 2), allow_empty = true,
                                            ok_text = _lc("Save"), cancel_text = _lc("Cancel"),
                                            callback = function(text) SUISettings:saveSetting(pfx .. CFG.HEADER_TXT_PFX .. "2", text or "") notifyChange() end,
                                        }
                                    end,
                                },
                                {
                                    text = _lc("Change Column 3 Header"),
                                    callback = function()
                                        suiPrompt{
                                            title = _lc("Column 3 Header"), value = CFG.getHeaderTxt(pfx, 3), allow_empty = true,
                                            ok_text = _lc("Save"), cancel_text = _lc("Cancel"),
                                            callback = function(text) SUISettings:saveSetting(pfx .. CFG.HEADER_TXT_PFX .. "3", text or "") notifyChange() end,
                                        }
                                    end,
                                },
                                {
                                    text = _lc("Change Column 4 Header"),
                                    callback = function()
                                        suiPrompt{
                                            title = _lc("Column 4 Header"), value = CFG.getHeaderTxt(pfx, 4), allow_empty = true,
                                            ok_text = _lc("Save"), cancel_text = _lc("Cancel"),
                                            callback = function(text) SUISettings:saveSetting(pfx .. CFG.HEADER_TXT_PFX .. "4", text or "") notifyChange() end,
                                        }
                                    end,
                                },
                            }
                        },
                    }
                },
                {
                    text = _lc("Text, Font and Color Settings"), separator = true,
                    sub_item_table = {
                        {
                            text = _lc("Book and Author"),
                            sub_item_table = {
                                { text = _lc("Book Title Font"), sub_item_table = makeFontMenu(CFG.TITLE_FONT_KEY, "NotoSerif") },
                                makeSpinItem({
                                    text_func = function()
                                        local fs = tonumber(SUISettings:readSetting(pfx .. CFG.TITLE_FS_KEY)) or 24
                                        return string.format("%s: %d pt%s", _lc("Book Title Size"), fs, fs == 24 and _lc(" (Default)") or "")
                                    end,
                                    title = _lc("Book Title Size"),
                                    get = function() return tonumber(SUISettings:readSetting(pfx .. CFG.TITLE_FS_KEY)) or 24 end,
                                    set = function(v) SUISettings:saveSetting(pfx .. CFG.TITLE_FS_KEY, v) end,
                                    min = 10, max = 72, step = 1, default = 24, unit = "pt",
                                }),
                                makeColorMenuItem(_lc("Book Title Color"), CFG.TITLE_COLOR_KEY),
                                { text = _lc("Author Name Font"), sub_item_table = makeFontMenu(CFG.AUTHOR_FONT_KEY, "NotoSerif"), separator = true },
                                makeSpinItem({
                                    text_func = function()
                                        local fs = tonumber(SUISettings:readSetting(pfx .. CFG.AUTHOR_FS_KEY)) or 20
                                        return string.format("%s: %d pt%s", _lc("Author Name Size"), fs, fs == 20 and _lc(" (Default)") or "")
                                    end,
                                    title = _lc("Author Name Size"),
                                    get = function() return tonumber(SUISettings:readSetting(pfx .. CFG.AUTHOR_FS_KEY)) or 20 end,
                                    set = function(v) SUISettings:saveSetting(pfx .. CFG.AUTHOR_FS_KEY, v) end,
                                    min = 10, max = 72, step = 1, default = 20, unit = "pt",
                                }),
                                makeColorMenuItem(_lc("Author Name Color"), CFG.AUTHOR_COLOR_KEY),
                            }
                        },
                        {
                            text = _lc("Data"),
                            sub_item_table = {
                                { text = _lc("Number Font"), sub_item_table = makeFontMenu(CFG.VAL_FONT_KEY, "NotoSerif") },
                                makeSpinItem({
                                    text_func = function()
                                        local fs = tonumber(SUISettings:readSetting(pfx .. CFG.VAL_FS_KEY)) or 30
                                        return string.format("%s: %d pt%s", _lc("Number Size"), fs, fs == 30 and _lc(" (Default)") or "")
                                    end,
                                    title = _lc("Number Size"),
                                    get = function() return tonumber(SUISettings:readSetting(pfx .. CFG.VAL_FS_KEY)) or 30 end,
                                    set = function(v) SUISettings:saveSetting(pfx .. CFG.VAL_FS_KEY, v) end,
                                    min = 10, max = 72, step = 1, default = 30, unit = "pt",
                                }),
                                { text_func = function() return CFG.getValBold(pfx) and _lc("Number Weight: Bold") or _lc("Number Weight: Normal") end, keep_menu_open = true, callback = function() SUISettings:saveSetting(pfx .. CFG.VAL_BOLD_KEY, not CFG.getValBold(pfx)) notifyChange() end },
                                makeColorMenuItem(_lc("Number Color"), CFG.VAL_COLOR_KEY),
                            }
                        },
                        {
                            text = _lc("Label"),
                            sub_item_table = {
                                { text = _lc("Label Font"), sub_item_table = makeFontMenu(CFG.LBL_FONT_KEY, "x_smallinfofont") },
                                makeSpinItem({
                                    text_func = function()
                                        local fs = tonumber(SUISettings:readSetting(pfx .. CFG.LBL_FS_KEY)) or 16
                                        return string.format("%s: %d pt%s", _lc("Label Size"), fs, fs == 16 and _lc(" (Default)") or "")
                                    end,
                                    title = _lc("Label Size"),
                                    get = function() return tonumber(SUISettings:readSetting(pfx .. CFG.LBL_FS_KEY)) or 16 end,
                                    set = function(v) SUISettings:saveSetting(pfx .. CFG.LBL_FS_KEY, v) end,
                                    min = 10, max = 72, step = 1, default = 16, unit = "pt",
                                }),
                                { text_func = function() return CFG.getLblBold(pfx) and _lc("Label Weight: Bold") or _lc("Label Weight: Normal") end, keep_menu_open = true, callback = function() SUISettings:saveSetting(pfx .. CFG.LBL_BOLD_KEY, not CFG.getLblBold(pfx)) notifyChange() end },
                                makeColorMenuItem(_lc("Label Color"), CFG.LBL_COLOR_KEY),
                                makeColorMenuItem(_lc("Category Header Color"), CFG.HDR_COLOR_KEY, true),
                            }
                        },
                        {
                            text = _lc("Progress Visuals"),
                            sub_item_table_func = function()
                                return {
                                    { text = _lc("Label Font"), sub_item_table = makeFontMenu(CFG.BAR_LBL_FONT_KEY, "NotoSans") },
                                    makeSpinItem({
                                        text_func = function()
                                            local fs = CFG.getBarLblFs(pfx)
                                            return string.format("%s: %d pt%s", _lc("Label Size"), fs, fs == 16 and _lc(" (Default)") or "")
                                        end,
                                        title = _lc("Label Size"),
                                        get = function() return CFG.getBarLblFs(pfx) end,
                                        set = function(v) SUISettings:saveSetting(pfx .. CFG.BAR_LBL_FS_KEY, v) end,
                                        min = 8, max = 40, step = 1, default = 16, unit = "pt",
                                    }),
                                    { text_func = function() return CFG.getBarLblBold(pfx) and _lc("Label Weight: Bold") or _lc("Label Weight: Normal") end, keep_menu_open = true, callback = function() SUISettings:saveSetting(pfx .. CFG.BAR_LBL_BOLD_KEY, not CFG.getBarLblBold(pfx)) notifyChange() end },
                                    makeColorMenuItem(_lc("Visual Text Color"), CFG.BAR_LBL_COLOR_KEY),
                                    makeVisSlotColorItem(1, true),
                                    makeVisSlotColorItem(2),
                                    makeVisSlotColorItem(3),
                                    makeColorMenuItem(_lc("Track Background Color"), CFG.VIS_TRACK_COLOR_KEY),
                                    {
                                        text = _lc("Reset Visual Colors"),
                                        separator = true,
                                        keep_menu_open = true,
                                        callback = function(touchmenu_instance)
                                            resetColorKeys({ CFG.VIS_COLOR_1_KEY, CFG.VIS_COLOR_2_KEY, CFG.VIS_COLOR_3_KEY, CFG.VIS_TRACK_COLOR_KEY, CFG.BAR_LBL_COLOR_KEY }, _lc("Visual colors reset."), touchmenu_instance)
                                        end,
                                    },
                                }
                            end,
                        },
                        {
                            text = _lc("Colors"),
                            sub_item_table_func = function()
                                return {
                                    makeColorMenuItem(_lc("Book Title Color"), CFG.TITLE_COLOR_KEY),
                                    makeColorMenuItem(_lc("Author Name Color"), CFG.AUTHOR_COLOR_KEY),
                                    makeColorMenuItem(_lc("Number Color"), CFG.VAL_COLOR_KEY),
                                    makeColorMenuItem(_lc("Label Color"), CFG.LBL_COLOR_KEY),
                                    makeColorMenuItem(_lc("Category Header Color"), CFG.HDR_COLOR_KEY),
                                    makeColorMenuItem(_lc("Statistics Area Background Color"), CFG.STATS_BG_COLOR_KEY),
                                    makeColorMenuItem(_lc("Visual Text Color"), CFG.BAR_LBL_COLOR_KEY),
                                    makeVisSlotColorItem(1, true),
                                    makeVisSlotColorItem(2),
                                    makeVisSlotColorItem(3),
                                    makeColorMenuItem(_lc("Track Background Color"), CFG.VIS_TRACK_COLOR_KEY),
                                    {
                                        text = _lc("Reset All Colors"),
                                        separator = true,
                                        keep_menu_open = true,
                                        callback = function(touchmenu_instance)
                                            resetColorKeys(CFG.ALL_COLOR_KEYS, _lc("All colors reset."), touchmenu_instance)
                                        end,
                                    },
                                }
                            end,
                        },
                        makeColorMenuItem(_lc("Statistics Area Background Color"), CFG.STATS_BG_COLOR_KEY),
                        {
                            text_func = function() local fmt = CFG.getTimeFmt(pfx); local lbl = (fmt == CFG.FMT_XHYM) and "XhYm" or _lc("Readable"); return string.format("%s \u{2014} %s", _lc("Time Format"), lbl) end,
                            sub_item_table = {
                                { text = _lc("Readable (e.g., 3.5 hours)"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getTimeFmt(pfx) ~= CFG.FMT_XHYM end, callback = function() SUISettings:saveSetting(pfx .. CFG.SK_TIME_FMT, CFG.FMT_NICKEL) notifyChange() end },
                                { text = _lc("XhYm (e.g., 3h 30 min)"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getTimeFmt(pfx) == CFG.FMT_XHYM end, callback = function() SUISettings:saveSetting(pfx .. CFG.SK_TIME_FMT, CFG.FMT_XHYM) notifyChange() end },
                            },
                        },
                        {
                            text = _lc("Line Spacing"),
                            separator = true,
                            sub_item_table_func = function()
                                local function makeGapItem(label, key, getter, min_v, max_v)
                                    return makeSpinItem({
                                        text_func = function()
                                            local v = getter(pfx)
                                            return string.format("%s: %s%d px%s", label, v > 0 and "+" or "", v, v == 0 and _lc(" (Default)") or "")
                                        end,
                                        title = label,
                                        get = function() return getter(pfx) end,
                                        set = function(v) SUISettings:saveSetting(pfx .. key, v) end,
                                        min = min_v, max = max_v, step = 1, default = 0, unit = "px",
                                    })
                                end
                                return {
                                    {
                                        text = _lc("Book and Author"),
                                        sub_item_table = {
                                            makeGapItem(_lc("Title Line Spacing"), CFG.TITLE_LINE_GAP_KEY, CFG.getTitleLineGap, -20, 30),
                                            makeGapItem(_lc("Title-Author Spacing"), CFG.AUTHOR_GAP_KEY, CFG.getAuthorGap, -20, 30),
                                        },
                                    },
                                    {
                                        text = _lc("Data"),
                                        sub_item_table = {
                                            makeGapItem(_lc("Data Row Spacing"), CFG.STAT_ROW_GAP_KEY, CFG.getStatRowGap, -20, 30),
                                        },
                                    },
                                    {
                                        text = _lc("Label"),
                                        sub_item_table = {
                                            makeGapItem(_lc("Category Header Spacing"), CFG.HDR_ROW_GAP_KEY, CFG.getHdrRowGap, -15, 30),
                                            makeGapItem(_lc("Value-Label Gap"), CFG.LBL_GAP_KEY, CFG.getLblGap, -10, 30),
                                        },
                                    },
                                }
                            end,
                        },
                    }
                },
                {
                    text = _lc("Progress Visuals"),
                    sub_item_table_func = function()
                        local st = CFG.getBarStyle(pfx)
                        local is_vis_on = function() return CFG.getShowVisuals(pfx) end

                        local style_names = {
                            bars       = _lc("Vertical Bars"),
                            rings      = _lc("Rings"),
                            horizontal = _lc("Horizontal Bar"),
                        }

                        local variant_defs = {
                            rings = {
                                { id = "classic",        label = _lc("Classic") },
                                { id = "flat_arc",       label = _lc("Flat Cut") },
                                { id = "hairline_track", label = _lc("Thin Track") },
                                { id = "double_ring",    label = _lc("Double Framed") },
                                { id = "gauge",          label = _lc("Open Gauge (270°)") },
                                { id = "hud_220",        label = _lc("HUD Visor (220°)") },
                                { id = "orbit_node",     label = _lc("Orbit Satellite") },
                                { id = "reticle",        label = _lc("Tactical Reticle") },
                                { id = "halo_glow",      label = _lc("Neon Halo") },
                                { id = "telemetry_dial", label = _lc("Telemetry Dial") },
                                { id = "reactor_core",   label = _lc("Reactor Core") },
                                { id = "cyber_crescent", label = _lc("Cyber Crescent") },
                                { id = "chronometer",    label = _lc("Chronometer Bezel") },
                                { id = "sonar_pulse",    label = _lc("Sonar Ping") },
                                { id = "eclipse_rim",    label = _lc("Eclipse Rim") },
                            },
                            bars = {
                                { id = "capsule",        label = _lc("Classic Capsule") },
                                { id = "flat",           label = _lc("Sharp Rectangular") },
                                { id = "rounded",        label = _lc("Soft Rounded") },
                                { id = "outlined",       label = _lc("Outlined Box") },
                                { id = "double_frame",   label = _lc("Double Bordered") },
                                { id = "needle",         label = _lc("Track & Knob") },
                                { id = "ruler",          label = _lc("Graduated Scale") },
                                { id = "spine_core",     label = _lc("Spine Core") },
                                { id = "horizon_cap",    label = _lc("Horizon Blade") },
                                { id = "orbit_pin",      label = _lc("Orbit Pin") },
                                { id = "split_rail",     label = _lc("Dual Split Rail") },
                                { id = "bracket_hud",    label = _lc("HUD Calipers") },
                                { id = "prism_taper",    label = _lc("Prism Monolith") },
                                { id = "crosshair_bar",  label = _lc("Target Pillar") },
                                { id = "neon_edge",      label = _lc("Neon Side Stripe") },
                            },
                            horizontal = {
                                { id = "sui",            label = _lc("Classic Bar") },
                                { id = "rounded",        label = _lc("Soft Rounded") },
                                { id = "flat",           label = _lc("Sharp Minimal") },
                                { id = "outlined",       label = _lc("Outlined Tank") },
                                { id = "inset_frame",    label = _lc("Double Framed Tank") },
                                { id = "thin_track",     label = _lc("Thin Track + Bold Fill") },
                                { id = "slider_dot",     label = _lc("Line & Marker") },
                                { id = "ruler",          label = _lc("Ruler Gauge") },
                                { id = "horizon_tip",    label = _lc("Horizon Blade") },
                                { id = "twin_rail",      label = _lc("Dual Split Rail") },
                                { id = "bracket_hud",    label = _lc("HUD Calipers") },
                                { id = "plasma_core",    label = _lc("Plasma Conduit") },
                                { id = "target_node",    label = _lc("Target Node") },
                                { id = "visor_strip",    label = _lc("Visor Strip") },
                                { id = "neon_chamber",   label = _lc("Neon Chamber") },
                            },
                        }

                        local function getActiveVariantLabel(cur_st)
                            local list = variant_defs[cur_st] or variant_defs.rings
                            local cur_v
                            if cur_st == "rings" then cur_v = CFG.getRingVariant(pfx)
                            elseif cur_st == "bars" then cur_v = CFG.getVBarVariant(pfx)
                            else cur_v = CFG.getHBarVariant(pfx) end
                            for _, opt in ipairs(list) do
                                if opt.id == cur_v then return opt.label end
                            end
                            return list[1].label
                        end

                        local items = {
                            {
                                text = _lc("Goals"),
                                sub_item_table = goals_menu,
                            },
                            {
                                text_func = function() return CFG.getShowVisuals(pfx) and _lc("Show Visuals: On") or _lc("Show Visuals: Off") end,
                                keep_menu_open = true,
                                callback = function() SUISettings:saveSetting(pfx .. CFG.SHOW_VISUALS_KEY, not CFG.getShowVisuals(pfx)) notifyChange() end,
                            },
                            makeVisualItemsMenuItem(is_vis_on),
                            {
                                text_func = function()
                                    local cur_st = CFG.getBarStyle(pfx)
                                    return string.format("%s \u{2014} %s", _lc("Style"), style_names[cur_st] or cur_st)
                                end,
                                enabled_func = is_vis_on,
                                sub_item_table_func = function()
                                    return {
                                        { text = _lc("Rings"),          radio = true, keep_menu_open = true, checked_func = function() return CFG.getBarStyle(pfx) == "rings" end,      callback = function() SUISettings:saveSetting(pfx .. CFG.BAR_STYLE_KEY, "rings"); notifyChange() end },
                                        { text = _lc("Vertical Bars"),  radio = true, keep_menu_open = true, checked_func = function() return CFG.getBarStyle(pfx) == "bars" end,       callback = function() SUISettings:saveSetting(pfx .. CFG.BAR_STYLE_KEY, "bars"); notifyChange() end },
                                        { text = _lc("Horizontal Bar"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getBarStyle(pfx) == "horizontal" end, callback = function() SUISettings:saveSetting(pfx .. CFG.BAR_STYLE_KEY, "horizontal"); notifyChange() end },
                                    }
                                end,
                            },
                            {
                                text_func = function()
                                    local cur_st = CFG.getBarStyle(pfx)
                                    return string.format("%s \u{2014} %s", _lc("Variant"), getActiveVariantLabel(cur_st))
                                end,
                                enabled_func = is_vis_on,
                                sub_item_table_func = function()
                                    local cur_st = CFG.getBarStyle(pfx)
                                    local list = variant_defs[cur_st] or variant_defs.rings
                                    local key = (cur_st == "rings") and CFG.RING_VARIANT_KEY
                                             or (cur_st == "bars" and CFG.VBAR_VARIANT_KEY or CFG.HBAR_VARIANT_KEY)
                                    local get_fn = (cur_st == "rings") and CFG.getRingVariant
                                                or (cur_st == "bars" and CFG.getVBarVariant or CFG.getHBarVariant)
                                    local save_key = pfx .. key
                                    local out = {}
                                    for _, opt in ipairs(list) do
                                        local opt_id = opt.id
                                        table.insert(out, {
                                            text = opt.label,
                                            radio = true,
                                            keep_menu_open = true,
                                            checked_func = function() return get_fn(pfx) == opt_id end,
                                            callback = function()
                                                SUISettings:saveSetting(save_key, opt_id)
                                                notifyChange()
                                            end,
                                        })
                                    end
                                    return out
                                end,
                            },
                        }

                        if st == "horizontal" then
                            table.insert(items, makeSpinItem({
                                text_func = function()
                                    local p = CFG.getHBarLengthPct(pfx)
                                    return string.format("%s: %d%%%s", _lc("Bar Length"), p, p == 100 and _lc(" (Default)") or "")
                                end,
                                enabled_func = is_vis_on,
                                title = _lc("Bar Length"),
                                get = function() return CFG.getHBarLengthPct(pfx) end,
                                set = function(v) SUISettings:saveSetting(pfx .. CFG.HBAR_LENGTH_PCT_KEY, v) end,
                                min = 25, max = 100, step = 5, default = 100, unit = "%",
                            }))
                            table.insert(items, makeSpinItem({
                                text_func = function()
                                    local g = CFG.getHBarGap(pfx)
                                    return string.format("%s: %d px%s", _lc("Vertical Spacing"), g, g == 5 and _lc(" (Default)") or "")
                                end,
                                enabled_func = is_vis_on,
                                title = _lc("Vertical Spacing"),
                                get = function() return CFG.getHBarGap(pfx) end,
                                set = function(v) SUISettings:saveSetting(pfx .. CFG.HBAR_GAP_KEY, v) end,
                                min = 0, max = 40, step = 1, hold_step = 4, default = 5, unit = "px",
                            }))
                            table.insert(items, makeSpinItem({
                                text_func = function()
                                    local t = CFG.getHBarThickness(pfx)
                                    return string.format("%s: %d / 12%s", _lc("Thickness"), t, t == 5 and _lc(" (Default)") or "")
                                end,
                                enabled_func = is_vis_on,
                                title = _lc("Thickness"),
                                get = function() return CFG.getHBarThickness(pfx) end,
                                set = function(v) CFG.setHBarThickness(pfx, v) end,
                                min = 1, max = 12, step = 1, hold_step = 2, default = 5, unit = "",
                            }))
                        elseif st == "bars" then
                            table.insert(items, makeSpinItem({
                                text_func = function()
                                    local p = CFG.getVBarHeightPct(pfx)
                                    return string.format("%s: %d%%%s", _lc("Bar Height"), p, p == 100 and _lc(" (Default)") or "")
                                end,
                                enabled_func = is_vis_on,
                                title = _lc("Bar Height"),
                                get = function() return CFG.getVBarHeightPct(pfx) end,
                                set = function(v) SUISettings:saveSetting(pfx .. CFG.VBAR_HEIGHT_PCT_KEY, v) end,
                                min = 20, max = 200, step = 5, default = 100, unit = "%",
                            }))
                            table.insert(items, makeSpinItem({
                                text_func = function()
                                    local g = CFG.getVBarGap(pfx)
                                    return string.format("%s: %d px%s", _lc("Horizontal Spacing"), g, g == 15 and _lc(" (Default)") or "")
                                end,
                                enabled_func = is_vis_on,
                                title = _lc("Horizontal Spacing"),
                                get = function() return CFG.getVBarGap(pfx) end,
                                set = function(v) SUISettings:saveSetting(pfx .. CFG.VBAR_GAP_PCT_KEY, v) end,
                                min = 0, max = 100, step = 2, default = 15, unit = "px",
                            }))
                            table.insert(items, makeSpinItem({
                                text_func = function()
                                    local t = CFG.getVBarThickness(pfx)
                                    return string.format("%s: %d / 12%s", _lc("Thickness"), t, t == 5 and _lc(" (Default)") or "")
                                end,
                                enabled_func = is_vis_on,
                                title = _lc("Thickness"),
                                get = function() return CFG.getVBarThickness(pfx) end,
                                set = function(v) CFG.setVBarThickness(pfx, v) end,
                                min = 1, max = 12, step = 1, hold_step = 2, default = 5, unit = "",
                            }))
                        else
                            table.insert(items, makeSpinItem({
                                text_func = function()
                                    local p = CFG.getBarHeightPct(pfx)
                                    return string.format("%s: %d%%%s", _lc("Ring Size"), p, p == 100 and _lc(" (Default)") or "")
                                end,
                                enabled_func = is_vis_on,
                                title = _lc("Ring Size"),
                                get = function() return math.min(150, CFG.getBarHeightPct(pfx)) end,
                                set = function(v) SUISettings:saveSetting(pfx .. CFG.BAR_HEIGHT_PCT_KEY, v) end,
                                min = 15, max = 150, step = 5, default = 100, unit = "%",
                            }))
                            table.insert(items, makeSpinItem({
                                text_func = function()
                                    local g = CFG.getBarGap(pfx)
                                    return string.format("%s: %d px%s", _lc("Vertical Spacing"), g, g == 15 and _lc(" (Default)") or "")
                                end,
                                enabled_func = is_vis_on,
                                title = _lc("Vertical Spacing"),
                                get = function() return CFG.getBarGap(pfx) end,
                                set = function(v) SUISettings:saveSetting(pfx .. CFG.BAR_GAP_PCT_KEY, v) end,
                                min = 0, max = 100, step = 2, default = 15, unit = "px",
                            }))
                            table.insert(items, makeSpinItem({
                                text_func = function()
                                    local t = CFG.getRingThickness(pfx)
                                    return string.format("%s: %d / 6%s", _lc("Thickness"), t, t == 4 and _lc(" (Default)") or "")
                                end,
                                enabled_func = is_vis_on,
                                title = _lc("Thickness"),
                                get = function() return CFG.getRingThickness(pfx) end,
                                set = function(v) CFG.setRingThickness(pfx, v) end,
                                min = 1, max = 6, step = 1, hold_step = 2, default = 4, unit = "",
                            }))
                            table.insert(items, {
                                text_func = function() return CFG.getShowRingLabels(pfx) and _lc("Ring Labels: On") or _lc("Ring Labels: Off") end,
                                enabled_func = is_vis_on,
                                keep_menu_open = true,
                                callback = function() SUISettings:saveSetting(pfx .. CFG.SHOW_RING_LABELS_KEY, not CFG.getShowRingLabels(pfx)) notifyChange() end,
                            })
                        end

                        return items
                    end,
                },
                {
                    text_func = function()
                        local is_on = CFG.getPreviewMode(pfx)
                        local p_type = CFG.getPreviewType(pfx)
                        local type_lbl = (p_type == "timer") and _lc("Timed Auto-Return (Seconds)") or _lc("Return via Button (Manual)")
                        return string.format("%s \u{2014} %s", _lc("Live Preview Mode"), is_on and type_lbl or _lc("Off"))
                    end,
                    sub_item_table = {
                        {
                            text_func = function()
                                return CFG.getPreviewMode(pfx) and _lc("Live Preview Mode: On") or _lc("Live Preview Mode: Off")
                            end,
                            keep_menu_open = true,
                            callback = function()
                                SUISettings:saveSetting(pfx .. CFG.PREVIEW_MODE_KEY, not CFG.getPreviewMode(pfx))
                                notifyChange(nil, true)
                            end,
                        },
                        {
                            text = ICON_EYE .. " " .. _lc("Preview Homescreen Now"),
                            enabled_func = function() return CFG.getPreviewMode(pfx) end,
                            callback = function() triggerPreviewMode(nil) end,
                        },
                        {
                            text = _lc("Preview Behavior"),
                            sub_item_table = {
                                {
                                    text = _lc("Return via Button (Manual)"), radio = true, keep_menu_open = true,
                                    checked_func = function() return CFG.getPreviewType(pfx) ~= "timer" end,
                                    callback = function() SUISettings:saveSetting(pfx .. CFG.PREVIEW_TYPE_KEY, "button") notifyChange(nil, true) end,
                                },
                                {
                                    text = _lc("Timed Auto-Return (Seconds)"), radio = true, keep_menu_open = true,
                                    checked_func = function() return CFG.getPreviewType(pfx) == "timer" end,
                                    callback = function() SUISettings:saveSetting(pfx .. CFG.PREVIEW_TYPE_KEY, "timer") notifyChange(nil, true) end,
                                },
                            },
                        },
                        {
                            text_func = function()
                                local d = CFG.getPreviewDuration(pfx)
                                return string.format("%s: %d %s", _lc("Preview Duration"), d, _lc("Seconds"))
                            end,
                            enabled_func = function() return CFG.getPreviewType(pfx) == "timer" end,
                            sub_item_table = {
                                { text = _lc("2 Seconds"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getPreviewDuration(pfx) == 2 end, callback = function() SUISettings:saveSetting(pfx .. CFG.PREVIEW_DURATION_KEY, 2) notifyChange(nil, true) end },
                                { text = _lc("3 Seconds (Default)"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getPreviewDuration(pfx) == 3 end, callback = function() SUISettings:saveSetting(pfx .. CFG.PREVIEW_DURATION_KEY, 3) notifyChange(nil, true) end },
                                { text = _lc("4 Seconds"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getPreviewDuration(pfx) == 4 end, callback = function() SUISettings:saveSetting(pfx .. CFG.PREVIEW_DURATION_KEY, 4) notifyChange(nil, true) end },
                                { text = _lc("5 Seconds"), radio = true, keep_menu_open = true, checked_func = function() return CFG.getPreviewDuration(pfx) == 5 end, callback = function() SUISettings:saveSetting(pfx .. CFG.PREVIEW_DURATION_KEY, 5) notifyChange(nil, true) end },
                            },
                        },
                    },
                },
                {
                    text_func = function()
                        local cur = C.getLanguage()
                        local lbl = _lc("Auto (Follow KOReader)")
                        if cur ~= "auto" then
                            for _, opt in ipairs(C.LANG_OPTIONS) do
                                if opt.code == cur then
                                    lbl = opt.native
                                    break
                                end
                            end
                        end
                        return string.format("%s: %s", _lc("Language"), lbl)
                    end,
                    sub_item_table_func = function()
                        local items = {}
                        for _, opt in ipairs(C.LANG_OPTIONS) do
                            local code = opt.code
                            local title = (code == "auto") and _lc("Auto (Follow KOReader)") or opt.label
                            table.insert(items, {
                                text = title,
                                radio = true,
                                keep_menu_open = true,
                                checked_func = function() return C.getLanguage() == code end,
                                callback = function()
                                    C.setLanguage(code, CFG.refreshTranslations)
                                    local mod_y = package.loaded["modules/module_currently_yanllsama"]
                                    if mod_y and type(mod_y.refreshTranslations) == "function" then pcall(mod_y.refreshTranslations) end
                                    local mod_b = package.loaded["modules/module_currently_books_stat"]
                                    if mod_b and type(mod_b.refreshTranslations) == "function" then pcall(mod_b.refreshTranslations) end
                                    notifyChange(nil, true, true)
                                    local SUIWin = getSUIModule("sui_window", "engines")
                                    local open_wins = SUIWin and SUIWin._open_instances
                                    local top_win = open_wins and open_wins[#open_wins]
                                    if top_win and type(top_win.close) == "function" then
                                        pcall(function() top_win:close() end)
                                    elseif type(refresh) == "function" then
                                        pcall(refresh)
                                    end
                                    suiToast(_("Language changed. Reopen settings to refresh all menu labels."))
                                end,
                            })
                        end
                        return items
                    end,
                },
            }
        },
        {
            text_func = function()
                local raw = SUISettings:readSetting(pfx .. CFG.SK_EXCLUDE_PATHS) or ""
                if raw == "" then return _lc("Exclude Paths from Recents") end
                local n = 0; for _ in raw:gmatch("[^,\n]+") do n = n + 1 end
                return string.format("%s (%d)", _lc("Exclude Paths from Recents"), n)
            end,
            callback = function()
                local raw = SUISettings:readSetting(pfx .. CFG.SK_EXCLUDE_PATHS) or ""
                suiPrompt{
                    title       = _lc("Exclude Paths from Recents"),
                    value       = raw,
                    hint        = "/mnt/onboard/rss, instapaper",
                    description = _lc("Comma separated path fragments.\nBooks containing any of these fragments in their path will be skipped."),
                    allow_empty = true,
                    ok_text     = _lc("Save"),
                    cancel_text = _lc("Cancel"),
                    callback    = function(text)
                        SUISettings:saveSetting(pfx .. CFG.SK_EXCLUDE_PATHS, text or "")
                        notifyChange()
                    end,
                }
            end,
        },
    }
end

return M
