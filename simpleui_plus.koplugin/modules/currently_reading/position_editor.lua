-- modules/currently_reading/position_editor.lua — Compact single-window 2D (X & Y) live position editor.

local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local Math       = require("optmath")
local Size       = require("ui/size")
local UIManager  = require("ui/uimanager")
local Widget     = require("ui/widget/widget")
local Screen     = Device.screen

local W = {
    CenterContainer = require("ui/widget/container/centercontainer"),
    FrameContainer  = require("ui/widget/container/framecontainer"),
    GestureRange    = require("ui/gesturerange"),
    HorizontalGroup = require("ui/widget/horizontalgroup"),
    HorizontalSpan  = require("ui/widget/horizontalspan"),
    InputContainer  = require("ui/widget/container/inputcontainer"),
    LeftContainer   = require("ui/widget/container/leftcontainer"),
    LineWidget      = require("ui/widget/linewidget"),
    OverlapGroup    = require("ui/widget/overlapgroup"),
    RightContainer  = require("ui/widget/container/rightcontainer"),
    TextWidget      = require("ui/widget/textwidget"),
    VerticalGroup   = require("ui/widget/verticalgroup"),
    VerticalSpan    = require("ui/widget/verticalspan"),
}

local C = require("modules/currently_reading/config")
local _ = C._

local M = {}

local _time_ok, _TimeMod = pcall(require, "ui/time")
local function nowMs()
    if _time_ok and _TimeMod and type(_TimeMod.now) == "function" and type(_TimeMod.to_ms) == "function" then
        return _TimeMod.to_ms(_TimeMod.now())
    end
    return os.time() * 1000
end

local STEPS = { 1, 5, 15 }

local DIRECTION_DX = {
    east      = 1,
    west      = -1,
    northeast = 0.7071,
    southeast = 0.7071,
    northwest = -0.7071,
    southwest = -0.7071,
}

local function fmtCoord(v)
    if v > 0 then return "+" .. tostring(v) end
    return tostring(v)
end

local function getTheme()
    local SS = C.getSUIStyle()
    local UI = C.getSUIModule("sui_core", "infra")
    local AAPaint = C.getSUIModule("sui_aa_paint", "infra")
    local Backdrop = C.getSUIModule("sui_backdrop", "infra")
    local RoundedFrame = (Backdrop and Backdrop.RoundedFrame) or W.FrameContainer

    local surface      = (SS and SS.COLOR and SS.COLOR.surface)      or Blitbuffer.COLOR_WHITE
    local surface_flat = (SS and SS.COLOR and SS.COLOR.surface_flat) or Blitbuffer.gray(0.08)
    local text_primary = (SS and SS.COLOR and SS.COLOR.text_primary) or Blitbuffer.COLOR_BLACK
    local text_sec     = (SS and SS.COLOR and SS.COLOR.text_secondary) or Blitbuffer.gray(0.45)
    local track        = (SS and SS.COLOR and SS.COLOR.track)        or Blitbuffer.gray(0.22)
    local border_c     = (SS and SS.COLOR and SS.COLOR.gray_strong)  or Blitbuffer.gray(0.35)
    local accent       = (SS and type(SS.accent) == "function" and SS.accent(text_primary)) or text_primary
    local accent_fg    = (SS and type(SS.accentFg) == "function" and SS.accentFg(surface)) or surface

    local lf = (UI and type(UI.getLandscapeFactor) == "function") and UI.getLandscapeFactor() or 1
    local portrait_w = (UI and type(UI.getPortraitDims) == "function") and UI.getPortraitDims() or math.min(Screen:getWidth(), Screen:getHeight())

    local bot_h = 0
    local Bottombar = C.getSUIModule("sui_bottombar", "screens")
    if Bottombar and type(Bottombar.AREA_H) == "function" then
        bot_h = Bottombar.AREA_H() or 0
    end

    local top_h = 0
    local Topbar = C.getSUIModule("sui_topbar", "screens")
    if Topbar and type(Topbar.TOTAL_TOP_H) == "function" then
        top_h = Topbar.TOTAL_TOP_H() or 0
    end

    return {
        SS           = SS,
        UI           = UI,
        AAPaint      = AAPaint,
        RoundedFrame = RoundedFrame,
        surface      = surface,
        surface_flat = surface_flat,
        text_primary = text_primary,
        text_sec     = text_sec,
        track        = track,
        border_c     = border_c,
        accent       = accent,
        accent_fg    = accent_fg,
        lf           = lf,
        portrait_w   = portrait_w,
        bot_h        = bot_h,
        top_h        = top_h,
    }
end

local function paintPill(AAPaint, bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    if AAPaint and type(AAPaint.fillPill) == "function" then
        AAPaint.fillPill(bb, x, y, w, h, color, 255)
    else
        bb:paintRect(x, y, w, h, color)
    end
end

-- Compact bidirectional horizontal axis slider (supports direct partial repaint)
local CompactAxisBar = Widget:extend{
    width   = 100,
    height  = 28,
    min     = -200,
    max     = 200,
    value   = 0,
    step    = 5,
    theme   = nil,
}

function CompactAxisBar:init()
    self.knob_r  = math.max(5, math.floor(self.height * 0.34))
    self.ring    = math.max(2, Screen:scaleBySize(1.5))
    self.track_h = math.max(2, math.floor(self.height * 0.12))
    self.fill_h  = math.max(self.track_h + 1, math.floor(self.height * 0.22))
    self._value  = self:clamp(self.value)
    self.dimen   = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function CompactAxisBar:clamp(v)
    return math.max(self.min, math.min(self.max, Math.round(v)))
end

function CompactAxisBar:getSize()
    return self.dimen
end

function CompactAxisBar:getValue()
    return self._value
end

function CompactAxisBar:setValue(v)
    self._value = self:clamp(v)
end

function CompactAxisBar:offsetFor(val)
    local span = self.max - self.min
    local frac = (span > 0) and ((val - self.min) / span) or 0.5
    return self.knob_r + math.floor(frac * (self.width - 2 * self.knob_r) + 0.5)
end

function CompactAxisBar:valueAt(abs_x, step_snap)
    local span = self.width - 2 * self.knob_r
    local frac = (span > 0) and ((abs_x - self.dimen.x - self.knob_r) / span) or 0.5
    local raw = self.min + math.max(0, math.min(1, frac)) * (self.max - self.min)
    local st = step_snap or self.step or 1
    if st > 1 then
        raw = Math.round(raw / st) * st
    end
    return self:clamp(raw)
end

function CompactAxisBar:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local T = self.theme
    local AAPaint = T.AAPaint
    local cy = y + math.floor(self.height / 2)
    local knob_x = x + self:offsetFor(self._value)
    local zero_x = x + self:offsetFor(0)

    -- Clear bar strip
    bb:paintRect(x, y, self.width, self.height, T.surface)
    -- Base track
    paintPill(AAPaint, bb, x, cy - math.floor(self.track_h / 2), self.width, self.track_h, T.track)
    -- Center 0 tick mark
    if self.min < 0 and self.max > 0 then
        local tick_h = math.max(6, math.floor(self.knob_r * 1.1))
        local tick_w = math.max(1, Screen:scaleBySize(1))
        bb:paintRect(zero_x - math.floor(tick_w / 2), cy - math.floor(tick_h / 2), tick_w, tick_h, T.border_c)
    end
    -- Bidirectional active fill from 0 to knob
    local fx0 = math.min(zero_x, knob_x)
    local fw = math.abs(knob_x - zero_x)
    if fw > 0 then
        paintPill(AAPaint, bb, fx0, cy - math.floor(self.fill_h / 2), fw, self.fill_h, T.accent)
    end
    -- Hollow circular knob
    local d = self.knob_r * 2
    paintPill(AAPaint, bb, knob_x - self.knob_r, cy - self.knob_r, d, d, T.accent)
    local ir = math.max(2, self.knob_r - self.ring)
    paintPill(AAPaint, bb, knob_x - ir, cy - ir, ir * 2, ir * 2, T.surface)
end

function CompactAxisBar:repaintDirect()
    local d = self.dimen
    if not d or d.w <= 0 or d.h <= 0 then return end
    self:paintTo(Screen.bb, d.x, d.y)
    UIManager:setDirty(nil, "ui", Geom:new{ x = d.x, y = d.y, w = d.w, h = d.h })
end

-- Compact tappable pill that can update its text and repaint directly in place
local DirectPill = Widget:extend{
    width      = 60,
    height     = 28,
    radius     = 8,
    text       = "",
    face       = nil,
    bold       = false,
    bg         = nil,
    fg         = nil,
    border_sz  = 0,
    border_c   = nil,
    pad_h      = 6,
    no_truncate = false,
    frame_cls  = nil,
}

function DirectPill:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local tw_args = {
        text    = self.text,
        face    = self.face,
        bold    = self.bold,
        fgcolor = self.fg,
        padding = 0,
    }
    if not self.no_truncate then
        tw_args.max_width = math.max(8, self.width - self.pad_h * 2)
        tw_args.truncate_with_ellipsis = true
    end
    self._tw = W.TextWidget:new(tw_args)
end

function DirectPill:getSize()
    return self.dimen
end

function DirectPill:setText(txt)
    if self.text == txt then return false end
    self.text = txt
    self._tw:setText(txt)
    return true
end

function DirectPill:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local FrameCls = self.frame_cls or W.FrameContainer
    local frame = FrameCls:new{
        bordersize = self.border_sz or 0,
        color      = self.border_c or self.fg,
        background = self.bg,
        radius     = self.radius,
        padding    = 0,
        margin     = 0,
        [1] = W.CenterContainer:new{
            dimen = Geom:new{
                w = math.max(1, self.width - (self.border_sz or 0) * 2),
                h = math.max(1, self.height - (self.border_sz or 0) * 2),
            },
            self._tw,
        },
    }
    frame:paintTo(bb, x, y)
end

function DirectPill:repaintDirect(surface_bg)
    local d = self.dimen
    if not d or d.w <= 0 or d.h <= 0 then return end
    if surface_bg then
        Screen.bb:paintRect(d.x, d.y, d.w, d.h, surface_bg)
    end
    self:paintTo(Screen.bb, d.x, d.y)
    UIManager:setDirty(nil, "ui", Geom:new{ x = d.x, y = d.y, w = d.w, h = d.h })
end

function DirectPill:free()
    if self._tw and type(self._tw.free) == "function" then
        self._tw:free()
    end
end

function M.show(opts)
    local _lc = opts._lc or _
    local min_x = opts.min_x or -250
    local max_x = opts.max_x or 250
    local min_y = opts.min_y or -250
    local max_y = opts.max_y or 250
    local def_x = opts.default_x or 0
    local def_y = opts.default_y or 0

    local init_x = opts.get_x()
    local init_y = opts.get_y()
    local cur_x  = init_x
    local cur_y  = init_y
    local step_idx = 2 -- default 5px (cycles 1 -> 5 -> 15)

    local stashed_sui, stashed_stack, live_screens = opts.hideParentMenus(true)
    local need_rebuild = (#live_screens == 0)
    for _, sc in ipairs(live_screens) do
        if not sc._ctx_cache or not sc._book_mod_slots then
            need_rebuild = true
            break
        end
    end
    if need_rebuild then
        opts.refreshHomescreenImmediate()
    else
        for _, sc in ipairs(live_screens) do
            UIManager:setDirty(sc, "ui")
        end
    end

    local T = getTheme()
    local win_size = opts.win_size or "medium"
    local win_pos  = opts.win_pos  or "bottom"
    local sm = (win_size == "small") and 0.84 or ((win_size == "large") and 1.18 or 1.0)
    local wf = (win_size == "small") and 0.72 or ((win_size == "large") and 0.94 or (5 / 6))

    local function dp(n)
        return math.max(1, math.floor(Screen:scaleBySize(n) * T.lf + 0.5))
    end
    local function dps(n)
        return math.max(1, math.floor(Screen:scaleBySize(n) * T.lf * sm + 0.5))
    end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local card_w = math.min(sw - dp(12), math.floor(T.portrait_w * wf * T.lf))
    local pad_h  = dps(12)
    local pad_v  = dps(8)
    local inner_w = card_w - (pad_h * 2)

    local face_title = Font:getFace(C.resolveFontFace("NotoSans", true), math.max(10, math.floor(12 * T.lf * sm + 0.5)))
        or Font:getFace("smallinfofont", 12)
    local face_axis  = Font:getFace(C.resolveFontFace("NotoSans", true), math.max(9, math.floor(11 * T.lf * sm + 0.5)))
        or Font:getFace("smallinfofont", 11)
    local face_pill  = Font:getFace(C.resolveFontFace("NotoSans", true), math.max(8, math.floor(10 * T.lf * sm + 0.5)))
        or Font:getFace("x_smallinfofont", 10)
    local face_btn   = Font:getFace(C.resolveFontFace("NotoSans", true), math.max(9, math.floor(11 * T.lf * sm + 0.5)))
        or Font:getFace("smallinfofont", 11)
    local face_pm    = Font:getFace(C.resolveFontFace("NotoSans", true), math.max(11, math.floor(14 * T.lf * sm + 0.5)))
        or face_btn

    local hdr_h     = dps(24)
    local coord_w   = dps(68)
    local coord_h   = dps(22)
    local coord_gap = dps(5)
    local title_w   = math.max(40, inner_w - (coord_w * 2) - coord_gap - dps(6))

    local pill_x = DirectPill:new{
        width  = coord_w,
        height = coord_h,
        radius = dps(6),
        text   = "X: " .. fmtCoord(cur_x),
        face   = face_pill,
        bold   = true,
        bg     = T.surface_flat,
        fg     = T.text_primary,
        pad_h  = dps(4),
    }
    local pill_y = DirectPill:new{
        width  = coord_w,
        height = coord_h,
        radius = dps(6),
        text   = "Y: " .. fmtCoord(cur_y),
        face   = face_pill,
        bold   = true,
        bg     = T.surface_flat,
        fg     = T.text_primary,
        pad_h  = dps(4),
    }

    local title_tw = W.TextWidget:new{
        text                   = opts.title or "",
        face                   = face_title,
        bold                   = true,
        fgcolor                = T.text_primary,
        padding                = 0,
        max_width              = title_w,
        truncate_with_ellipsis = true,
    }

    local header_row = W.HorizontalGroup:new{
        align = "center",
        W.LeftContainer:new{
            dimen = Geom:new{ w = title_w, h = hdr_h },
            title_tw,
        },
        W.HorizontalSpan:new{ width = dps(6) },
        pill_x,
        W.HorizontalSpan:new{ width = coord_gap },
        pill_y,
    }

    -- Axis rows: compact [Label] [-] [====O====] [+]
    local row_h    = dps(30)
    local lbl_w    = dps(16)
    local arr_w    = dps(30)
    local arr_h    = dps(28)
    local row_gap  = dps(6)
    local bar_w    = math.max(60, inner_w - lbl_w - (arr_w * 2) - (row_gap * 3))

    local function makeStepPill(glyph)
        return DirectPill:new{
            width       = arr_w,
            height      = arr_h,
            radius      = dps(7),
            text        = glyph,
            face        = face_pm,
            bold        = true,
            bg          = T.surface_flat,
            fg          = T.text_primary,
            pad_h       = 0,
            no_truncate = true,
        }
    end

    local btn_x_dec = makeStepPill("-")
    local btn_x_inc = makeStepPill("+")
    local btn_y_dec = makeStepPill("-")
    local btn_y_inc = makeStepPill("+")

    local bar_x = CompactAxisBar:new{
        width  = bar_w,
        height = row_h,
        min    = min_x,
        max    = max_x,
        value  = cur_x,
        step   = STEPS[step_idx],
        theme  = T,
    }
    local bar_y = CompactAxisBar:new{
        width  = bar_w,
        height = row_h,
        min    = min_y,
        max    = max_y,
        value  = cur_y,
        step   = STEPS[step_idx],
        theme  = T,
    }

    local function makeAxisRow(lbl_txt, b_dec, bar, b_inc)
        return W.HorizontalGroup:new{
            align = "center",
            W.CenterContainer:new{
                dimen = Geom:new{ w = lbl_w, h = row_h },
                W.TextWidget:new{
                    text    = lbl_txt,
                    face    = face_axis,
                    bold    = true,
                    fgcolor = T.text_sec,
                    padding = 0,
                },
            },
            W.HorizontalSpan:new{ width = row_gap },
            b_dec,
            W.HorizontalSpan:new{ width = row_gap },
            bar,
            W.HorizontalSpan:new{ width = row_gap },
            b_inc,
        }
    end

    local row_x = makeAxisRow("X", btn_x_dec, bar_x, btn_x_inc)
    local row_y = makeAxisRow("Y", btn_y_dec, bar_y, btn_y_inc)

    -- Compact 4-button footer: [±5px] [Default] [Cancel] [Apply]
    local foot_h   = dps(32)
    local foot_gap = dps(6)
    local step_w   = dps(58)
    local rem_fw   = inner_w - step_w - (foot_gap * 3)
    local def_w    = math.floor(rem_fw * 0.35)
    local can_w    = math.floor(rem_fw * 0.32)
    local app_w    = math.max(30, rem_fw - def_w - can_w)

    local btn_step = DirectPill:new{
        width     = step_w,
        height    = foot_h,
        radius    = dps(8),
        text      = string.format("±%dpx", STEPS[step_idx]),
        face      = face_pill,
        bold      = true,
        bg        = T.surface,
        fg        = T.text_primary,
        border_sz = math.max(1, Size.line.thin or 1),
        border_c  = T.border_c,
        pad_h     = dps(3),
    }
    local btn_default = DirectPill:new{
        width  = def_w,
        height = foot_h,
        radius = dps(8),
        text   = _lc("Default"),
        face   = face_btn,
        bold   = false,
        bg     = T.surface_flat,
        fg     = T.text_primary,
        pad_h  = dps(3),
    }
    local btn_cancel = DirectPill:new{
        width  = can_w,
        height = foot_h,
        radius = dps(8),
        text   = _lc("Cancel"),
        face   = face_btn,
        bold   = false,
        bg     = T.surface_flat,
        fg     = T.text_primary,
        pad_h  = dps(3),
    }
    local btn_apply = DirectPill:new{
        width     = app_w,
        height    = foot_h,
        radius    = dps(8),
        text      = _lc("Apply"),
        face      = face_btn,
        bold      = true,
        bg        = T.accent,
        fg        = T.accent_fg,
        pad_h     = dps(3),
        frame_cls = T.RoundedFrame,
    }

    local footer_row = W.HorizontalGroup:new{
        align = "center",
        btn_step,
        W.HorizontalSpan:new{ width = foot_gap },
        btn_default,
        W.HorizontalSpan:new{ width = foot_gap },
        btn_cancel,
        W.HorizontalSpan:new{ width = foot_gap },
        btn_apply,
    }

    local card_body = W.VerticalGroup:new{
        align = "left",
        header_row,
        W.VerticalSpan:new{ width = dps(5) },
        W.LineWidget:new{ dimen = Geom:new{ w = inner_w, h = math.max(1, Size.line.thin or 1) }, background = T.border_c },
        W.VerticalSpan:new{ width = dps(5) },
        row_x,
        W.VerticalSpan:new{ width = dps(4) },
        row_y,
        W.VerticalSpan:new{ width = dps(7) },
        footer_row,
    }

    local card_frame = T.RoundedFrame:new{
        bordersize     = math.max(1, Size.line.medium or 2),
        color          = T.text_primary,
        background     = T.surface,
        radius         = dps(12),
        padding_left   = pad_h,
        padding_right  = pad_h,
        padding_top    = pad_v,
        padding_bottom = pad_v,
        [1]            = card_body,
    }

    local card_sz = card_frame:getSize()
    local card_x = math.floor((sw - card_sz.w) / 2)
    local card_y
    if win_pos == "top" then
        local top_margin = math.max(dp(12), T.top_h + Size.padding.small)
        card_y = math.min(math.max(dp(12), sh - card_sz.h - dp(12)), top_margin)
    elseif win_pos == "center" then
        card_y = math.max(dp(12), math.floor((sh - card_sz.h) / 2))
    else
        card_y = math.max(dp(12), sh - T.bot_h - card_sz.h - Size.padding.small)
    end
    card_frame.overlap_offset = { card_x, card_y }

    local st = {
        closed             = false,
        drag_axis          = nil,
        last_preview_ms    = 0,
        preview_timer      = nil,
        settle_timer       = nil,
        session_h_changed  = false,
        last_rendered_x    = init_x,
        last_rendered_y    = init_y,
    }

    local function cancelTimers()
        if st.preview_timer then
            pcall(function() UIManager:unschedule(st.preview_timer) end)
            st.preview_timer = nil
        end
        if st.settle_timer then
            pcall(function() UIManager:unschedule(st.settle_timer) end)
            st.settle_timer = nil
        end
    end

    local function doPreviewNow(nx, ny, is_fast)
        if not opts.is_preview then return end
        if st.last_rendered_x == nx and st.last_rendered_y == ny and (is_fast or not st.session_h_changed) then
            return
        end
        opts.withNoFlush(function()
            opts.set_x(nx)
            opts.set_y(ny)
        end)
        local repainted, h_changed = opts.triggerSurgicalPreviewRepaint(is_fast, true, not is_fast, card_y)
        if h_changed then
            st.session_h_changed = true
        end
        st.last_rendered_x = nx
        st.last_rendered_y = ny
        if not is_fast and (not repainted or st.session_h_changed) then
            st.session_h_changed = false
            opts.relayoutScreensKeepCache(live_screens, opts.getPreviewRefreshMode())
        end
    end

    local function scheduleSettle()
        if not opts.is_preview then return end
        if st.settle_timer then
            pcall(function() UIManager:unschedule(st.settle_timer) end)
            st.settle_timer = nil
        end
        st.settle_timer = UIManager:scheduleIn(0.32, function()
            st.settle_timer = nil
            if st.closed or st.drag_axis then return end
            if st.session_h_changed then
                st.session_h_changed = false
                UIManager:avoidFlashOnNextRepaint()
                opts.relayoutScreensKeepCache(live_screens, opts.getPreviewRefreshMode())
            elseif opts.needsColorSettle and opts.needsColorSettle() then
                opts.settleColorRect(card_y)
            end
        end)
    end

    local function applyXY(nx, ny, dragging)
        nx = math.max(min_x, math.min(max_x, Math.round(nx)))
        ny = math.max(min_y, math.min(max_y, Math.round(ny)))
        local dx = (nx ~= cur_x)
        local dy = (ny ~= cur_y)
        if not dx and not dy then return end
        cur_x, cur_y = nx, ny

        if dx then
            bar_x:setValue(cur_x)
            bar_x:repaintDirect()
            if pill_x:setText("X: " .. fmtCoord(cur_x)) then
                pill_x:repaintDirect(T.surface)
            end
        end
        if dy then
            bar_y:setValue(cur_y)
            bar_y:repaintDirect()
            if pill_y:setText("Y: " .. fmtCoord(cur_y)) then
                pill_y:repaintDirect(T.surface)
            end
        end

        opts.withNoFlush(function()
            opts.set_x(cur_x)
            opts.set_y(cur_y)
        end)
        if not opts.is_preview then return end

        local now = nowMs()
        local elapsed = now - st.last_preview_ms
        local THROTTLE_MS = 20

        if (not dragging) or elapsed >= THROTTLE_MS then
            if st.preview_timer then
                pcall(function() UIManager:unschedule(st.preview_timer) end)
                st.preview_timer = nil
            end
            st.last_preview_ms = now
            doPreviewNow(cur_x, cur_y, true)
            if not dragging then
                scheduleSettle()
            end
        elseif not st.preview_timer then
            local wait_s = math.max(0.015, (THROTTLE_MS - elapsed) / 1000)
            st.preview_timer = UIManager:scheduleIn(wait_s, function()
                st.preview_timer = nil
                if st.closed then return end
                st.last_preview_ms = nowMs()
                doPreviewNow(cur_x, cur_y, true)
            end)
        end
    end

    local overlay = W.InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        [1] = W.OverlapGroup:new{
            dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
            card_frame,
        },
    }

    local function closeWithRevert()
        if st.closed then return end
        st.closed = true
        cancelTimers()
        UIManager:close(overlay)
        opts.restoreParentMenus(stashed_sui, stashed_stack)
        if cur_x ~= init_x or cur_y ~= init_y then
            opts.withNoFlush(function()
                opts.set_x(init_x)
                opts.set_y(init_y)
            end)
            opts.flushSUISettings()
            if st.session_h_changed then
                opts.relayoutScreensKeepCache(live_screens, opts.getPreviewRefreshMode())
            else
                opts.triggerSurgicalPreviewRepaint(false, true)
            end
            UIManager:setDirty(nil, "ui")
        end
    end

    local function closeWithApply()
        if st.closed then return end
        st.closed = true
        cancelTimers()
        UIManager:close(overlay)
        opts.restoreParentMenus(stashed_sui, stashed_stack)
        opts.withNoFlush(function()
            opts.set_x(cur_x)
            opts.set_y(cur_y)
        end)
        opts.flushSUISettings()
        if (not opts.is_preview) or st.last_rendered_x ~= cur_x or st.last_rendered_y ~= cur_y or st.session_h_changed then
            st.session_h_changed = false
            opts.notifyChange(nil, true, true)
        else
            if type(opts.refresh) == "function" then pcall(opts.refresh) end
            UIManager:setDirty(nil, "ui")
        end
    end

    local full_rect = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    overlay.ges_events = {
        TapPos        = { W.GestureRange:new{ ges = "tap",         range = full_rect } },
        HoldPos       = { W.GestureRange:new{ ges = "hold",        range = full_rect } },
        PanPos        = { W.GestureRange:new{ ges = "pan",         range = full_rect } },
        PanReleasePos = { W.GestureRange:new{ ges = "pan_release", range = full_rect } },
        SwipePos      = { W.GestureRange:new{ ges = "swipe",       range = full_rect } },
    }

    if Device:hasKeys() then
        overlay.key_events = { Close = { { "Back" } } }
        function overlay:onClose()
            closeWithRevert()
            return true
        end
    end

    local function hitPad(d, px_pad, py_pad)
        if not d then return nil end
        return Geom:new{
            x = d.x - px_pad,
            y = d.y - py_pad,
            w = d.w + px_pad * 2,
            h = d.h + py_pad * 2,
        }
    end

    local bar_slop_y = dp(5)
    local btn_slop = dp(4)

    local function matchBarAxis(pos)
        if pos:intersectWith(hitPad(bar_x.dimen, dp(4), bar_slop_y)) then return "x" end
        if pos:intersectWith(hitPad(bar_y.dimen, dp(4), bar_slop_y)) then return "y" end
        return nil
    end

    function overlay:onPanPos(_, ges)
        if not ges or not ges.pos then return false end
        if not st.drag_axis then
            if DIRECTION_DX[ges.direction] == nil then return false end
            local ax = matchBarAxis(ges.pos)
            if not ax then return false end
            st.drag_axis = ax
        end
        local step_v = STEPS[step_idx]
        if st.drag_axis == "x" then
            applyXY(bar_x:valueAt(ges.pos.x, step_v), cur_y, true)
        else
            applyXY(cur_x, bar_y:valueAt(ges.pos.x, step_v), true)
        end
        return true
    end

    function overlay:onPanReleasePos(_, ges)
        if not st.drag_axis then return false end
        local ax = st.drag_axis
        st.drag_axis = nil
        local step_v = STEPS[step_idx]
        if ges and ges.pos then
            if ax == "x" then
                applyXY(bar_x:valueAt(ges.pos.x, step_v), cur_y, false)
            else
                applyXY(cur_x, bar_y:valueAt(ges.pos.x, step_v), false)
            end
        else
            doPreviewNow(cur_x, cur_y, true)
            scheduleSettle()
        end
        return true
    end

    function overlay:onSwipePos(_, ges)
        if st.drag_axis then
            st.drag_axis = nil
            doPreviewNow(cur_x, cur_y, true)
            scheduleSettle()
            return true
        end
        if not ges or not ges.pos then return true end
        local dx_mult = DIRECTION_DX[ges.direction]
        if dx_mult then
            local ax = matchBarAxis(ges.pos)
            if ax then
                local end_x = ges.pos.x + dx_mult * (ges.distance or 0)
                local step_v = STEPS[step_idx]
                if ax == "x" then
                    applyXY(bar_x:valueAt(end_x, step_v), cur_y, false)
                else
                    applyXY(cur_x, bar_y:valueAt(end_x, step_v), false)
                end
                return true
            end
        end
        return true
    end

    function overlay:onHoldPos(_, ges)
        local pos = ges and ges.pos
        if not pos then return true end
        local jump = STEPS[step_idx] * 4
        if pos:intersectWith(hitPad(btn_x_dec.dimen, btn_slop, btn_slop)) then
            applyXY(cur_x - jump, cur_y, false)
            return true
        elseif pos:intersectWith(hitPad(btn_x_inc.dimen, btn_slop, btn_slop)) then
            applyXY(cur_x + jump, cur_y, false)
            return true
        elseif pos:intersectWith(hitPad(btn_y_dec.dimen, btn_slop, btn_slop)) then
            applyXY(cur_x, cur_y - jump, false)
            return true
        elseif pos:intersectWith(hitPad(btn_y_inc.dimen, btn_slop, btn_slop)) then
            applyXY(cur_x, cur_y + jump, false)
            return true
        end
        return true
    end

    function overlay:onTapPos(_, ges)
        local pos = ges and ges.pos
        if not pos then return true end
        local card_box = Geom:new{ x = card_x, y = card_y, w = card_sz.w, h = card_sz.h }
        if not pos:intersectWith(card_box) then
            closeWithRevert()
            return true
        end

        local step_v = STEPS[step_idx]
        if pos:intersectWith(hitPad(btn_x_dec.dimen, btn_slop, btn_slop)) then
            applyXY(cur_x - step_v, cur_y, false)
        elseif pos:intersectWith(hitPad(btn_x_inc.dimen, btn_slop, btn_slop)) then
            applyXY(cur_x + step_v, cur_y, false)
        elseif pos:intersectWith(hitPad(btn_y_dec.dimen, btn_slop, btn_slop)) then
            applyXY(cur_x, cur_y - step_v, false)
        elseif pos:intersectWith(hitPad(btn_y_inc.dimen, btn_slop, btn_slop)) then
            applyXY(cur_x, cur_y + step_v, false)
        elseif pos:intersectWith(hitPad(bar_x.dimen, dp(4), bar_slop_y)) then
            applyXY(bar_x:valueAt(pos.x, step_v), cur_y, false)
        elseif pos:intersectWith(hitPad(bar_y.dimen, dp(4), bar_slop_y)) then
            applyXY(cur_x, bar_y:valueAt(pos.x, step_v), false)
        elseif pos:intersectWith(hitPad(pill_x.dimen, dp(2), dp(3))) then
            applyXY(def_x, cur_y, false)
        elseif pos:intersectWith(hitPad(pill_y.dimen, dp(2), dp(3))) then
            applyXY(cur_x, def_y, false)
        elseif pos:intersectWith(hitPad(btn_step.dimen, dp(2), dp(3))) then
            step_idx = (step_idx % #STEPS) + 1
            local ns = STEPS[step_idx]
            bar_x.step = ns
            bar_y.step = ns
            if btn_step:setText(string.format("±%dpx", ns)) then
                btn_step:repaintDirect(T.surface)
            end
        elseif pos:intersectWith(hitPad(btn_default.dimen, dp(2), dp(3))) then
            applyXY(def_x, def_y, false)
        elseif pos:intersectWith(hitPad(btn_cancel.dimen, dp(2), dp(3))) then
            closeWithRevert()
        elseif pos:intersectWith(hitPad(btn_apply.dimen, dp(2), dp(3))) then
            closeWithApply()
        end
        return true
    end

    UIManager:show(overlay)
    UIManager:setDirty(overlay, function()
        return "ui", Geom:new{ x = card_x, y = card_y, w = card_sz.w, h = card_sz.h }, false
    end)
    return overlay
end

return M
