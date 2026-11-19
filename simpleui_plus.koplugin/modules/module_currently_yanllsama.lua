-- module_currently_yanllsama.lua — Enhanced Currently Reading (SimpleUI Dashboard Module)
--
-- Enhanced Currently Reading is a completely redesigned, highly detailed, and fully dynamic
-- reading statistics dashboard module for KOReader's SimpleUI plugin.
--
-- While maintaining the solid foundation of the original module, it offers enriched data,
-- brand new progress bar designs, dynamic grid management, and flexible interface options.
--
-- Features:
-- • Fully Dynamic Grid System: Freely determine layout with Number of Columns (1-4) and Rows (1-6)
-- • 4 Customizable Category Headers: Change header text, thickness, or hide them completely
-- • Rich Statistics: Time Left/Spent, Pages Read/Left, Days Reading/To Go, Daily Average,
--   Pages/Minute Speed, Last Session Pages
-- • Advanced Progress Bars: Simple, With percentage, Bold, Minimal, Outline, Segmented
-- • Full Control (Edit Items): Show/hide any statistic, rearrange display order
-- • Smart Info Screen: Tap Book/Author name to view book description
--
-- Developed by Yanllsama, based on the original open-source codes.
-- https://github.com/yanllsama/koreader-enhanced-currently-reading

local Device  = require("device")
local Screen  = Device.screen
local UIManager = require("ui/uimanager")

-- Hook Menu:onMenuHold so that hold_callback / on_hold on Menu items is honored across KOReader
local ok_menu, MenuWidget = pcall(require, "ui/widget/menu")
if ok_menu and MenuWidget and not MenuWidget._sui_hold_patched then
    local orig_onMenuHold = MenuWidget.onMenuHold
    function MenuWidget:onMenuHold(item, pos)
        if item then
            local cb = item.hold_callback_func and item.hold_callback_func() or item.hold_callback or item.on_hold
            if type(cb) == "function" then
                cb(self, item, pos)
                return true
            end
        end
        if orig_onMenuHold then
            return orig_onMenuHold(self, item, pos)
        end
        return true
    end
    MenuWidget._sui_hold_patched = true
end

-- Ensure simpleui_plus plugin root is on package.path so modules/currently_reading/* resolves cleanly
do
    local src = debug.getinfo(1, "S").source
    if src and src:sub(1, 1) == "@" then
        local plugin_dir = src:sub(2):match("^(.*)/modules/[^/]+$")
        if plugin_dir and not package.path:find(plugin_dir, 1, true) then
            package.path = plugin_dir .. "/?.lua;" .. package.path
        end
    end
end

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local LineWidget      = require("ui/widget/linewidget")
local Math            = require("optmath")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Widget          = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage     = require("datastorage")
local logger          = require("logger")
local util            = require("util")
local Screen          = Device.screen

local C           = require("modules/currently_reading/config")
local StatsMod    = require("modules/currently_reading/stats")
local VisualsMod  = require("modules/currently_reading/visuals")
local ProfilesMod = require("modules/currently_reading/profiles")
local MenuMod     = require("modules/currently_reading/menu")

local CFG             = C.CFG
local _               = C._
local _lc             = _
local getSUIModule    = C.getSUIModule
local getSH           = C.getSH
local getSUIStyle     = C.getSUIStyle
local Config          = C.getConfig()
C.ensureBentoCompat(Config)
local fmtCount        = C.fmtCount
local emptyVal        = C.emptyVal
local fmtFraction     = C.fmtFraction
local resolveFontFace = C.resolveFontFace
local truncateTitle   = C.truncateTitle

local UI           = getSUIModule("sui_core", "infra")
local PAD          = UI.PAD
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

local _CLR_DARK   = Blitbuffer.COLOR_BLACK
local _CLR_BAR_BG = Blitbuffer.gray(0.15)
local _CLR_BAR_FG = Blitbuffer.gray(0.75)

local _BASE_COVER_GAP      = Screen:scaleBySize(8)
local _BASE_BAR_GAP_BEFORE = Screen:scaleBySize(6)
local _BASE_BAR_H          = Screen:scaleBySize(7)
local _BASE_INLINEPCT_FS   = (getSUIStyle() and getSUIStyle().FS_DETAIL) or 15
local _BASE_AUTHOR_GAP     = Screen:scaleBySize(6)

local _docsettings_cache = {}
local _line_h_cache = {}
local _fit_face_cache = {}
local _prewarm_timer = nil
local _prewarm_gen = 0
local _prewarm_close_conn = nil

local function stackVerticalGaps(widgets, gaps, min_w)
    if not widgets or #widgets == 0 then
        return VerticalSpan:new{ width = 0 }, 0
    end
    local has_neg = false
    for i = 1, #widgets - 1 do
        if (gaps[i] or 0) < 0 then
            has_neg = true
            break
        end
    end
    if not has_neg then
        local vg = { align = "left" }
        local total_h = 0
        for i, wid in ipairs(widgets) do
            local sz = wid:getSize()
            total_h = total_h + ((sz and sz.h) or 0)
            table.insert(vg, wid)
            if i < #widgets then
                local g = math.floor(gaps[i] or 0)
                if g > 0 then
                    table.insert(vg, VerticalSpan:new{ width = g })
                    total_h = total_h + g
                end
            end
        end
        return VerticalGroup:new(vg), total_h
    end
    local og = {}
    local cur_y = 0
    local max_w = min_w or 0
    local max_bot = 0
    for i, wid in ipairs(widgets) do
        local sz = wid:getSize()
        local w = (sz and sz.w) or 0
        local h = (sz and sz.h) or 0
        if w > max_w then max_w = w end
        wid.overlap_offset = { 0, cur_y }
        table.insert(og, wid)
        local bot = cur_y + h
        if bot > max_bot then max_bot = bot end
        if i < #widgets then
            cur_y = math.max(0, bot + math.floor(gaps[i] or 0))
        end
    end
    local total_h = math.max(1, max_bot)
    og.dimen = Geom:new{ w = math.max(1, max_w), h = total_h }
    return OverlapGroup:new(og), total_h
end

local function mkSectionHeader(face, text, full_w, line_color, left_pad, line_h, style, bg_color, radius, text_color)
    left_pad = left_pad or Size.padding.large
    line_color = line_color or Blitbuffer.COLOR_BLACK
    bg_color = bg_color or Blitbuffer.COLOR_GRAY_E
    line_h = line_h or Size.line.medium or 2
    style = style or "underline"

    local UI_hdr = UI or getSUIModule("sui_core", "infra")
    local txt_fg = text_color or line_color
    local pad_s = math.max(1, math.min(Size.padding.small, math.floor(full_w * 0.04)))
    if left_pad > math.floor(full_w * 0.16) then
        left_pad = math.max(2, math.floor(full_w * 0.08))
    end
    local inner_w = math.max(8, full_w - left_pad - pad_s)
    local text_max_w = inner_w
    if style == "left_bar" then
        local bar_w = math.max(3, line_h + 2)
        text_max_w = math.max(8, inner_w - bar_w - math.max(4, math.floor(pad_s * 1.2)))
    elseif style == "side_lines" then
        text_max_w = math.max(8, inner_w - math.max(8, math.floor(full_w * 0.14)))
    elseif style == "outlined" then
        local bw = math.max(1, math.min(3, line_h))
        text_max_w = math.max(8, full_w - (bw * 2) - left_pad - pad_s)
    elseif style == "badge" then
        text_max_w = math.max(8, full_w - left_pad - (math.max(4, pad_s * 2) * 2))
    elseif style == "underline_dot" then
        text_max_w = math.max(8, inner_w - math.max(8, pad_s + 8))
    end

    local function makeHdrTw(fg)
        local opts = {
            text = text,
            face = face,
            fgcolor = fg,
            max_width = text_max_w,
            truncate_with_ellipsis = true,
        }
        return (UI_hdr and UI_hdr.makeColoredText)
            and UI_hdr.makeColoredText(opts)
            or TextWidget:new(opts)
    end

    local tw = makeHdrTw(txt_fg)
    local tw_sz = tw:getSize()

    if style == "fill" then
        return FrameContainer:new{
            background = bg_color,
            bordersize = 0,
            radius = radius or 0,
            padding_top = pad_s,
            padding_bottom = pad_s,
            padding_left = left_pad,
            padding_right = pad_s,
            LeftContainer:new{
                dimen = Geom:new{ w = inner_w, h = tw_sz.h },
                tw,
            },
        }
    elseif style == "none" then
        return VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = pad_s },
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = left_pad },
                tw,
            },
            VerticalSpan:new{ width = pad_s },
        }
    elseif style == "left_bar" then
        local bar_w = math.max(3, line_h + 2)
        local bar_h = math.max(6, tw_sz.h)
        local bar = C.makeColorFill(bar_w, bar_h, line_color, math.floor(bar_w / 2))
        return VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = pad_s },
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = left_pad },
                bar,
                HorizontalSpan:new{ width = math.max(4, math.floor(pad_s * 1.2)) },
                tw,
            },
            VerticalSpan:new{ width = pad_s },
        }
    elseif style == "outlined" then
        local bw = math.max(1, math.min(3, line_h))
        local pv = math.max(1, pad_s - 1)
        local box_h = tw_sz.h + ((pv + bw) * 2)
        local inner_lc = HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = left_pad },
            LeftContainer:new{
                dimen = Geom:new{ w = math.max(1, full_w - (bw * 2) - left_pad - pad_s), h = tw_sz.h },
                tw,
            },
            HorizontalSpan:new{ width = pad_s },
        }
        return C.makeColorStrokeBox(full_w, box_h, bw, line_color, radius or 0, inner_lc)
    elseif style == "underline_accent" then
        local acc_h = math.max(2, line_h + 1)
        local thin_h = math.max(1, Size.line.thin or 1)
        local acc_w = math.max(18, math.min(full_w, math.max(math.floor(full_w * 0.34), math.floor(tw_sz.w * 0.65))))
        local base_rule = LineWidget:new{ dimen = Geom:new{ w = full_w, h = thin_h }, background = bg_color }
        base_rule.overlap_offset = { 0, math.floor((acc_h - thin_h) / 2) }
        local acc_rule = C.makeColorFill(acc_w, acc_h, line_color, 0)
        acc_rule.overlap_offset = { left_pad, 0 }
        return VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = pad_s },
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = left_pad },
                tw,
            },
            VerticalSpan:new{ width = math.max(2, math.floor(3 * (Size.line.thin or 1))) },
            OverlapGroup:new{
                dimen = Geom:new{ w = full_w, h = acc_h },
                base_rule,
                acc_rule,
            },
            VerticalSpan:new{ width = pad_s },
        }
    elseif style == "side_lines" then
        local gap = math.max(4, pad_s)
        local rem_w = full_w - left_pad - tw_sz.w - gap
        local line_el = (rem_w >= 4) and C.makeColorFill(rem_w, line_h, line_color, 0) or HorizontalSpan:new{ width = 0 }
        return VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = pad_s },
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = left_pad },
                tw,
                HorizontalSpan:new{ width = (rem_w >= 4) and gap or 0 },
                line_el,
            },
            VerticalSpan:new{ width = pad_s },
        }
    elseif style == "badge" then
        local inv_fg = C.contrastFg(line_color)
        if type(tw.free) == "function" then tw:free() end
        local inv_tw = makeHdrTw(inv_fg)
        local pad_h = math.max(4, pad_s * 2)
        local pad_v = math.max(2, math.floor(pad_s * 0.65))
        local inv_sz = inv_tw:getSize()
        local pw = math.min(math.max(10, full_w - left_pad), inv_sz.w + pad_h * 2)
        local ph = inv_sz.h + pad_v * 2
        local prad = (radius and radius > 0) and radius or math.max(3, math.floor(tw_sz.h * 0.25))
        local pill = OverlapGroup:new{
            dimen = Geom:new{ w = pw, h = ph },
            C.makeColorFill(pw, ph, line_color, prad),
            CenterContainer:new{ dimen = Geom:new{ w = pw, h = ph }, inv_tw },
        }
        return VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = math.max(1, math.floor(pad_s * 0.5)) },
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = left_pad },
                pill,
            },
            VerticalSpan:new{ width = pad_s },
        }
    elseif style == "bracket" then
        local thin_h = math.max(1, Size.line.thin or 1)
        return VerticalGroup:new{
            align = "left",
            C.makeColorFill(full_w, line_h, line_color, 0),
            VerticalSpan:new{ width = math.max(2, math.floor(pad_s * 0.8)) },
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = left_pad },
                tw,
            },
            VerticalSpan:new{ width = math.max(2, math.floor(pad_s * 0.8)) },
            LineWidget:new{ dimen = Geom:new{ w = full_w, h = thin_h }, background = bg_color },
            VerticalSpan:new{ width = math.max(2, math.floor(pad_s * 0.6)) },
        }
    elseif style == "underline_dot" then
        local dot_sz = math.max(5, math.min(10, math.floor(tw_sz.h * 0.42)))
        local dot = C.makeColorFill(dot_sz, dot_sz, line_color, math.floor(dot_sz / 2))
        return VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = pad_s },
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = left_pad },
                dot,
                HorizontalSpan:new{ width = math.max(4, pad_s) },
                tw,
            },
            VerticalSpan:new{ width = math.max(2, math.floor(3 * (Size.line.thin or 1))) },
            C.makeColorFill(full_w, line_h, line_color, 0),
            VerticalSpan:new{ width = pad_s },
        }
    else
        -- "underline" (default)
        return VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = pad_s },
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = left_pad },
                tw,
            },
            VerticalSpan:new{ width = math.max(2, math.floor(3 * (Size.line.thin or 1))) },
            C.makeColorFill(full_w, line_h, line_color, 0),
            VerticalSpan:new{ width = pad_s },
        }
    end
end

local M = {}

M.id              = "currently_yanllsama"
M.name            = _("Şu An Okunan Kitap")
M.label           = _("Şu An Okunan")
M.description     = _("Dinamik ızgara, 10 zengin istatistik metriği, dikey çubuk ve halka grafikleri sunan gelişmiş okuma gösterge paneli.")
M.how_to_use      = _("Kullanım Rehberi & Özellikler:\n• Kitap Özeti: Kitap kapağına veya başlığına dokunarak kitap özetini ve açıklamasını açabilirsiniz.\n• Halka / Çubuk İstatistikleri: Sağdaki ilerleme halkalarına veya çubuklarına dokunarak detaylı okuma grafikleri penceresini (Books Stat) açabilirsiniz.\n• Hızlı İstatistik: İstatistikler tablosuna dokunarak okuma bilgileri özet penceresine ulaşabilirsiniz.\n• Çoklu Kitap Desteği (Kapak Yığını): 1, 3 veya 5 kitaplık kapak desteği ile okuma geçmişinizdeki kitaplar arasında dikey kaydırma veya dokunmayla hızla gezinebilirsiniz.\n• Tamamen Özelleştirilebilir: Izgara boyutları (1-4 sütun, 1-7 satır), dinamik genişlik paylaşımı (%50-%80), metin boyutları, yazı tipleri, çerçeveler ve kategori başlık stilleri.")
M.default_enabled = true
M.enabled_key     = "currently_yanllsama"
M.default_on      = true
M.has_covers      = true   
M.is_book_mod     = true   
M.needs           = { db = true, books = true, stats = true, recent = 5 }

local function needColorPartialRefresh(pfx)
    return C.isColorScreenActive() or CFG.hasAnyCustomColor(pfx)
end

local function handleProfileSwipe(pfx, step, hs)
    local ok, target_name = ProfilesMod.cycleProfile(pfx, step)
    if not ok then return false end

    pcall(function()
        local repainted = false
        local slot = hs and hs._ctx_cache and hs._book_mod_slots and hs._book_mod_slots["currently_yanllsama"]
        if slot and slot.mod and type(slot.mod.build) == "function" and type(hs._buildModWidget) == "function" then
            local wrapper_existing = slot.has_menu and hs._wrapper_pool and hs._wrapper_pool["currently_yanllsama"]
            local old_dimen = (wrapper_existing and wrapper_existing.dimen) or (slot.widget and slot.widget.dimen)
            local old_h = (old_dimen and old_dimen.h) or (slot.widget and slot.widget:getSize().h) or 0
            local new_widget, new_content = hs:_buildModWidget(slot.mod, slot.col_w, hs._ctx_cache, slot.min_h)
            if new_widget then
                local new_sz = new_widget:getSize()
                local new_h = (new_sz and new_sz.h) or 0
                if old_h > 0 and math.abs(new_h - old_h) <= 1 then
                    local target_dimen
                    if slot.has_menu and wrapper_existing and type(hs._makeModWrapper) == "function" then
                        local wrapper = hs:_makeModWrapper(slot.mod, new_widget, slot.col_w)
                        target_dimen = wrapper and wrapper.dimen
                        repainted = true
                    elseif slot.parent then
                        slot.parent[slot.index] = new_widget
                        target_dimen = new_widget.dimen
                        repainted = true
                    end
                    if repainted then
                        slot.widget  = new_widget
                        slot.content = new_content
                        if hs._stats_mod_slots and hs._stats_mod_slots["currently_yanllsama"] then
                            hs._stats_mod_slots["currently_yanllsama"].content = new_content
                        end
                        if hs._cover_mod_slots and slot.mod.has_covers and type(slot.mod.updateCovers) == "function" then
                            hs._cover_mod_slots["currently_yanllsama"] = { mod = slot.mod, widget = new_content }
                        end
                        if Config and type(Config.flushCoverQueue) == "function" then
                            Config.flushCoverQueue()
                            if Config.cover_extraction_pending and not hs._cover_poll_timer and type(hs._scheduleCoverPoll) == "function" then
                                hs:_scheduleCoverPoll()
                            end
                        end
                        if type(hs._syncBookModLabel) == "function" then
                            hs:_syncBookModLabel("currently_yanllsama")
                        end
                        local rtype = needColorPartialRefresh(pfx) and "partial"
                            or (type(hs._bookModRefreshType) == "function" and hs:_bookModRefreshType("currently_yanllsama") or "ui")
                        if UIManager then
                            if target_dimen then
                                UIManager:setDirty(hs, function() return rtype, target_dimen, true end)
                            else
                                UIManager:setDirty(hs, rtype)
                            end
                        end
                    end
                end
            end
        end

        if not repainted then
            if hs and hs._navbar_container and type(hs._updatePage) == "function" then
                hs:_updatePage(true)
                local rtype = needColorPartialRefresh(pfx) and "partial" or "ui"
                if UIManager then UIManager:setDirty(hs, rtype) end
            elseif hs and type(hs._refreshImmediate) == "function" then
                hs:_refreshImmediate(true)
                if needColorPartialRefresh(pfx) and UIManager then
                    UIManager:setDirty(hs, "partial")
                end
            else
                local SE = getSUIModule("sui_screen_engine", "engines")
                    or getSUIModule("sui_homescreen", "screens")
                if SE and type(SE.refresh) == "function" then
                    SE.refresh(true)
                end
            end
        end

        local Notification = require("ui/widget/notification")
        if Notification and UIManager then
            UIManager:show(Notification:new{
                text = string.format("%s: %s", _lc("Active Profile"), tostring(target_name)),
            })
        end
    end)
    return true
end

function M.isEnabled(pfx)
    pfx = pfx or "simpleui_hs_"
    local SUISettings = SUISettings or getSUIModule("sui_store", "infra")
    if SUISettings then
        local plus_enabled = SUISettings:readSetting("sui_plus_mod_" .. M.id)
        if plus_enabled ~= nil and not plus_enabled then return false end

        local ext_enabled = SUISettings:readSetting("sui_ext_mod_" .. M.id)
        if ext_enabled ~= nil and not ext_enabled then return false end
        
        local val = SUISettings:readSetting(pfx .. M.enabled_key)
        if val ~= nil then return val end
    end
    return M.default_on
end

function M.setEnabled(pfx, is_active)
    pfx = pfx or "simpleui_hs_"
    local SUISettings = SUISettings or getSUIModule("sui_store", "infra")
    if SUISettings then
        SUISettings:saveSetting(pfx .. M.enabled_key, is_active == true)
    end
end

function M.reset()
    _prewarm_gen = _prewarm_gen + 1
    if _prewarm_timer and UIManager then
        pcall(function() UIManager:unschedule(_prewarm_timer) end)
        _prewarm_timer = nil
    end
    if _prewarm_close_conn then
        pcall(_prewarm_close_conn)
        _prewarm_close_conn = nil
    end
    _docsettings_cache = {}
    _line_h_cache = {}
    _fit_face_cache = {}
    if StatsMod and StatsMod.clearCache then StatsMod.clearCache() end
    if VisualsMod and VisualsMod.clearRingMaskCache then VisualsMod.clearRingMaskCache() end
end

M.invalidateCache = M.reset

local function getLineHeight(face)
    if not face then return 20 end
    local ckey = tostring(face.name or face.orig_font or "") .. ":" .. tostring(face.size or "") .. ":" .. tostring(face)
    if _line_h_cache[ckey] then return _line_h_cache[ckey] end
    local h
    local ok, tw_h = pcall(function()
        local tw = TextWidget:new{ text = "Wg", face = face }
        local sz = tw:getSize().h
        if type(tw.free) == "function" then tw:free() end
        return sz
    end)
    if ok and tw_h and tw_h > 0 then
        h = tw_h
    elseif face.ftsize and type(face.ftsize.getHeightAndAscender) == "function" then
        local ok2, fh = pcall(face.ftsize.getHeightAndAscender, face.ftsize)
        if ok2 and fh and fh > 0 then h = math.ceil(fh) end
    end
    if not h then
        h = face.size and math.ceil(face.size * 1.25) or 20
    end
    _line_h_cache[ckey] = h
    return h
end

local function computeTaLayoutMetrics(pfx, scale, face_title, face_author)
    local line_h_title = getLineHeight(face_title)
    local line_h_author = getLineHeight(face_author)
    local min_gap = -math.floor(line_h_title * 0.65)
    local title_line_gap = math.max(min_gap, math.floor(CFG.getTitleLineGap(pfx) * scale))
    local author_adj = CFG.getAuthorGap(pfx)
    local author_gap = math.floor((_BASE_AUTHOR_GAP + author_adj) * scale)
    if author_adj == 0 then
        author_gap = math.max(1, author_gap)
    else
        author_gap = math.max(min_gap, author_gap)
    end
    local fixed_title_h = math.max(line_h_title, (line_h_title * 2) + title_line_gap)
    local fixed_ta_h = math.max(fixed_title_h, fixed_title_h + author_gap + line_h_author)
    return title_line_gap, author_gap, fixed_ta_h
end

local function isReadingInsightsAvailable(ui)
    if ui and ui.readinginsights then return true end
    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FM then
        if FM.instance and (FM.instance.readinginsights or type(FM.instance.onShowReadingInsightsPopup) == "function") then
            return true
        end
        if type(FM.onShowReadingInsightsPopup) == "function" then
            return true
        end
    end
    local ok_rui, RUI = pcall(require, "apps/reader/readerui")
    if ok_rui and RUI and ((RUI.instance and RUI.instance.readinginsights) or type(RUI.onShowReadingInsightsPopup) == "function") then
        return true
    end
    return false
end

local function buildCoverDeckStack(pfx, ctx, SH, D, cover, current_fp, fps, curIdx, top_pad, right_h, cover_gap)
    local count     = fps and #fps or 1
    local cur       = curIdx or 1
    local deck_mode = CFG.getCoverDeckMode(pfx)

    local lvl_specs = {
        { idx = 3, min_mode = 7, min_cnt = 4, scale = 0.55, peek_pct = 0.036, prev_off = -4, next_off = 2 },
        { idx = 2, min_mode = 5, min_cnt = 3, scale = 0.70, peek_pct = 0.045, prev_off = -3, next_off = 1 },
        { idx = 1, min_mode = 3, min_cnt = 2, scale = 0.85, peek_pct = 0.055, prev_off = -2, next_off = 0 },
    }

    local peeks = { 0, 0, 0 }
    local dims  = {}
    local fps_p = {}
    local fps_n = {}
    for _, sp in ipairs(lvl_specs) do
        local cw = math.floor(D.COVER_W * sp.scale)
        local ch = math.floor(D.COVER_H * sp.scale)
        dims[sp.idx] = { w = cw, h = ch, x = math.floor((D.COVER_W - cw) / 2) }
        if deck_mode >= sp.min_mode and count >= sp.min_cnt then
            peeks[sp.idx] = math.max(3, math.floor(D.COVER_H * sp.peek_pct))
            fps_p[sp.idx] = fps[(cur + sp.prev_off + count) % count + 1]
            fps_n[sp.idx] = fps[(cur + sp.next_off) % count + 1]
        end
    end

    local function getCoverWidget(fp, cw, ch)
        if not fp then return nil end
        local entry = ctx.prefetched and ctx.prefetched[fp]
        local bdata = SH.getBookData(fp, entry)
        return SH.getBookCover(fp, cw, ch, "center", 0.10)
            or SH.coverPlaceholder(bdata.title, bdata.authors, cw, ch)
    end

    local deck_h = peeks[3] + peeks[2] + peeks[1] + D.COVER_H + peeks[1] + peeks[2] + peeks[3]
    local deck_children = { dimen = Geom:new{ w = D.COVER_W, h = deck_h } }
    local slots_meta = {}

    local y_top = {
        [3] = 0,
        [2] = peeks[3],
        [1] = peeks[3] + peeks[2],
    }
    local y_bot = {
        [3] = deck_h - dims[3].h,
        [2] = (deck_h - peeks[3]) - dims[2].h,
        [1] = (deck_h - peeks[3] - peeks[2]) - dims[1].h,
    }

    -- Z-order: lvl 3 -> lvl 2 -> lvl 1 -> center
    for _, lvl in ipairs({ 3, 2, 1 }) do
        local d = dims[lvl]
        local p_fp, n_fp = fps_p[lvl], fps_n[lvl]
        local wp = getCoverWidget(p_fp, d.w, d.h)
        if wp then
            wp.overlap_offset = { d.x, y_top[lvl] }
            table.insert(deck_children, wp)
            table.insert(slots_meta, { idx = #deck_children, fp = p_fp, w = d.w, h = d.h })
        end
        local wn = getCoverWidget(n_fp, d.w, d.h)
        if wn then
            wn.overlap_offset = { d.x, y_bot[lvl] }
            table.insert(deck_children, wn)
            table.insert(slots_meta, { idx = #deck_children, fp = n_fp, w = d.w, h = d.h })
        end
    end

    cover.overlap_offset = { 0, peeks[3] + peeks[2] + peeks[1] }
    table.insert(deck_children, cover)
    table.insert(slots_meta, { idx = #deck_children, fp = current_fp, w = D.COVER_W, h = D.COVER_H, is_center = true })

    local deck_overlap = OverlapGroup:new(deck_children)
    local slots = {}
    for _, sm in ipairs(slots_meta) do
        table.insert(slots, {
            container = deck_overlap,
            idx       = sm.idx,
            fp        = sm.fp,
            w         = sm.w,
            h         = sm.h,
            align     = sm.is_center and nil or "center",
            stretch   = 0.10,
        })
    end

    local content_h = top_pad + math.max(deck_h, right_h)
    local deck_y = top_pad + math.floor((content_h - top_pad - deck_h) / 2)
    deck_overlap.overlap_offset = { 0, deck_y }

    local left_wrapper = LeftContainer:new{
        dimen = Geom:new{ w = D.COVER_W + cover_gap, h = content_h },
        [1] = OverlapGroup:new{
            dimen = Geom:new{ w = D.COVER_W, h = content_h },
            deck_overlap,
        },
    }

    return {
        left_wrapper = left_wrapper,
        content_h    = content_h,
        deck_mode    = deck_mode,
        deck_h       = deck_h,
        deck_y       = deck_y,
        peek1        = peeks[1],
        peek2        = peeks[2],
        peek3        = peeks[3],
        count        = count,
        cur          = cur,
        slots        = slots,
    }
end

local function getLandscapeScale(ctx)
    if ctx and ctx.landscape_factor then return ctx.landscape_factor end
    if UI and type(UI.isLandscape) == "function" and UI.isLandscape() and type(UI.getLandscapeFactor) == "function" then
        return UI.getLandscapeFactor()
    end
    return 1
end

local function computeModuleDims(pfx, SH, scale, thumb_scale, avail_w)
    local D = SH.getDims(scale, thumb_scale)
    if avail_w and avail_w > 0 and D.COVER_W > 0 then
        local max_cw = math.max(40, math.floor(avail_w * 0.34))
        if D.COVER_W > max_cw then
            D = {
                COVER_W = max_cw,
                COVER_H = math.max(60, math.floor(max_cw * (D.COVER_H / D.COVER_W) + 0.5)),
            }
        end
    end
    return D
end

local function resolvePosShifts(pfx, scale)
    return {
        tx = math.floor(CFG.getTitlePosX(pfx) * scale),
        ty = math.floor(CFG.getTitlePosY(pfx) * scale),
        sx = math.floor(CFG.getStatsPosX(pfx) * scale),
        sy = math.floor(CFG.getStatsPosY(pfx) * scale),
        vx = math.floor(CFG.getVisualsPosX(pfx) * scale),
        vy = math.floor(CFG.getVisualsPosY(pfx) * scale),
    }
end

local function resolveModuleColors(pfx, def_dark, def_sub, def_bar_bg)
    local vis_c = {}
    for i = 1, 3 do
        vis_c[i] = C.resolveColor(pfx, CFG.VIS_COLOR_KEYS[i], nil)
    end
    return {
        title     = C.resolveColor(pfx, CFG.TITLE_COLOR_KEY, def_dark),
        author    = C.resolveColor(pfx, CFG.AUTHOR_COLOR_KEY, def_sub),
        val       = C.resolveColor(pfx, CFG.VAL_COLOR_KEY, def_dark),
        lbl       = C.resolveColor(pfx, CFG.LBL_COLOR_KEY, def_sub),
        hdr       = C.resolveColor(pfx, CFG.HDR_COLOR_KEY, def_dark),
        stats_bg  = C.resolveColor(pfx, CFG.STATS_BG_COLOR_KEY, nil),
        bar_lbl   = C.resolveColor(pfx, CFG.BAR_LBL_COLOR_KEY, nil),
        vis       = vis_c,
        vis_track = C.resolveColor(pfx, CFG.VIS_TRACK_COLOR_KEY, def_bar_bg),
    }
end

local function _buildWidget(w, ctx, pfx, SH, bd, cover, stats, D, scale, lbl_scale, cols, rows, current_fp, fps, curIdx, extracted_md5)
    local UI = UI or getSUIModule("sui_core", "infra")
    local SUISettings = SUISettings or getSUIModule("sui_store", "infra")
    local Config = Config or getSUIModule("sui_config", "infra")

    local cover_gap      = math.max(0, math.floor(_BASE_COVER_GAP      * scale * (CFG.getCoverGapPct(pfx) / 100)))
    local bar_gap_before = math.max(1, math.floor(_BASE_BAR_GAP_BEFORE * scale))
    local bar_h          = math.max(1, math.floor(_BASE_BAR_H          * scale))

    local _CLR_DARK_EFF = _CLR_DARK
    local CLR_TEXT_SUB_EFF = CLR_TEXT_SUB

    local SS = getSUIStyle()
    if SS then
        if SS.COLOR then
            _CLR_DARK_EFF = SS.COLOR.text_primary or _CLR_DARK_EFF
            CLR_TEXT_SUB_EFF = SS.COLOR.text_secondary or _CLR_DARK_EFF
        elseif SS.getThemeColor then
            _CLR_DARK_EFF = SS.getThemeColor("fg") or _CLR_DARK_EFF
            CLR_TEXT_SUB_EFF = SS.getThemeColor("text_secondary") or _CLR_DARK_EFF
        end
    end

    local clr = resolveModuleColors(pfx, _CLR_DARK_EFF, CLR_TEXT_SUB_EFF, _CLR_BAR_BG)
    local val_fg_color = clr.val
    local lbl_fg_color = clr.lbl

    local face_inlinepct = Font:getFace("smallinfofont", math.max(7, math.floor(_BASE_INLINEPCT_FS * scale * lbl_scale)))
    
    local title_fs = math.max(10, math.floor(CFG.getTitleFs(pfx) * scale))
    local author_fs = math.max(9, math.floor(CFG.getAuthorFs(pfx) * scale))
    local face_title = Font:getFace(resolveFontFace(CFG.getTitleFont(pfx), true), title_fs) or Font:getFace("tfont", title_fs)
    local face_author = Font:getFace(resolveFontFace(CFG.getAuthorFont(pfx), false), author_fs) or Font:getFace("tfont", author_fs)

    local val_fs = math.max(10, math.floor(CFG.getValFs(pfx) * scale))
    local lbl_fs = math.max(8, math.floor(CFG.getLblFs(pfx) * scale))
    local face_v = Font:getFace(resolveFontFace(CFG.getValFont(pfx), CFG.getValBold(pfx)), val_fs) or Font:getFace("tfont", val_fs)
    local face_l = Font:getFace(resolveFontFace(CFG.getLblFont(pfx), CFG.getLblBold(pfx)), lbl_fs) or Font:getFace("x_smallinfofont", lbl_fs)

    -- 3-Column Layout Calculations:
    -- Left:   Cover deck (D.COVER_W + cover_gap)
    -- Center: Book title, author, stats grid (mid_w + mid_gap)
    -- Right:  2 Vertically stacked rings (rings_col_w)
    local side_margin = math.max(0, math.floor(CFG.getSideMargin(pfx) * scale))
    local avail_w = math.max(100, w - (side_margin * 2))
    local left_w = D.COVER_W + cover_gap
    local rem_w = math.max(100, avail_w - left_w)
    
    local active_visuals = CFG.getActiveVisuals(pfx)
    local visuals_enabled = CFG.getShowVisuals(pfx) and (#active_visuals > 0)
    local bar_style = CFG.getBarStyle(pfx)
    local is_horizontal = visuals_enabled and (bar_style == "horizontal")
    local show_visuals = visuals_enabled and (not is_horizontal)
    local show_stats_border = CFG.getShowStatsBorder(pfx)
    local show_visuals_border = CFG.getShowVisualsBorder(pfx)
    local both_borders = show_visuals and show_stats_border and show_visuals_border

    local size_mult = ((bar_style == "bars") and CFG.getVBarHeightPct(pfx) or CFG.getBarHeightPct(pfx)) / 100
    local rings_col_w, mid_gap, mid_w
    if show_visuals then
        if both_borders then
            mid_gap = 0
        else
            mid_gap = math.max(8, math.floor(16 * scale))
        end
        local combined_w = rem_w - mid_gap
        local ratio_pct = math.max(40, math.min(85, CFG.getStatsWidthRatio(pfx)))
        mid_w = math.floor(combined_w * (ratio_pct / 100))
        rings_col_w = combined_w - mid_w
    else
        rings_col_w = 0
        mid_gap = 0
        mid_w = rem_w
    end
    local tw = mid_w
    local stats_w = mid_w
    
    local border_bw = Size.line.thin or 1
    local border_pad = Size.padding.small
    local radius_val = CFG.getBorderRadius(pfx)
    local border_radius = radius_val == 0 and 0 or math.max(1, math.floor(Screen:scaleBySize(radius_val) * scale))
    local header_radius_enabled = CFG.getHeaderRadiusEnabled(pfx)
    local header_radius = (header_radius_enabled and border_radius > 0) and math.max(1, math.floor(border_radius / 2)) or 0
    local border_extra_w = show_stats_border and (2 * (border_bw + border_pad)) or ((type(clr.stats_bg) ~= "nil") and (2 * border_pad) or 0)

    local sep_line_w = math.max(1, math.floor(Size.line.medium * scale))
    local total_isep_w = sep_line_w * (cols - 1)
    
    local col_widths = {}
    local remaining_w = (stats_w - border_extra_w) - total_isep_w
    for c=1, cols do
        local cw = math.floor(remaining_w / (cols - c + 1))
        col_widths[c] = cw
        remaining_w = remaining_w - cw
    end

    local has_wp = ctx.has_wallpaper
    local function make_tbw(args)
        args.fgcolor = args.fgcolor or _CLR_DARK_EFF
        local use_alpha = has_wp or (type(clr.stats_bg) ~= "nil") or (type(args.fgcolor) ~= "nil" and not Blitbuffer.isColor8(args.fgcolor))
        if use_alpha and UI and UI.makeAlphaTextBox then return UI.makeAlphaTextBox(args) end
        return TextBoxWidget:new(args)
    end

    local face_v = Font:getFace(resolveFontFace(CFG.getValFont(pfx), CFG.getValBold(pfx)), val_fs) or face_title
    local face_l = Font:getFace(resolveFontFace(CFG.getLblFont(pfx), CFG.getLblBold(pfx)), lbl_fs) or face_title

    local function fitValFace(text, max_w)
        if not text or text == "" then return face_v end
        local val_font = CFG.getValFont(pfx)
        local val_bold = CFG.getValBold(pfx)
        local ckey = string.format("%s|%s|%d|%d|%s", tostring(val_font), tostring(val_bold), val_fs, math.floor(max_w), text)
        local cached_fs = _fit_face_cache[ckey]
        if cached_fs then
            if cached_fs == val_fs then return face_v end
            return Font:getFace(resolveFontFace(val_font, val_bold), cached_fs) or face_v
        end
        local fs, min_fs = val_fs, math.max(7, val_fs - 12)
        local face = face_v
        local p_tw = TextWidget:new{ text = text, face = face }
        local w_px = p_tw:getSize().w
        if type(p_tw.free) == "function" then p_tw:free() end
        while w_px > max_w and fs > min_fs do
            fs = fs - 1
            face = Font:getFace(resolveFontFace(val_font, val_bold), fs) or face
            p_tw = TextWidget:new{ text = text, face = face }
            w_px = p_tw:getSize().w
            if type(p_tw.free) == "function" then p_tw:free() end
        end
        _fit_face_cache[ckey] = fs
        return face
    end

    local item_row_h = math.max(getLineHeight(face_v), getLineHeight(face_l))
    local row_lpad = math.max(2, math.floor(Size.padding.large * math.min(1, scale)))
    local row_rpad = math.max(2, math.floor(Size.padding.small * math.min(1, scale)))
    local lbl_gap_eff = math.max(2, math.floor((Size.padding.large + CFG.getLblGap(pfx)) * math.min(1, scale)))

    local function pvline(data, extra, col_w)
        if not data or data.value == "" then
            return CenterContainer:new{
                dimen = Geom:new{ w = col_w, h = item_row_h },
                HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = row_lpad }, make_tbw({ text = "", face = face_l, width = math.max(1, col_w - row_lpad), max_lines = 1 }) }
            }
        end
        local desc = data.unit or ""
        if extra and extra ~= "" then desc = (desc ~= "") and (desc .. " " .. extra) or extra end
        local max_val_w = (desc ~= "") and math.max(1, math.floor((col_w - row_lpad - row_rpad - lbl_gap_eff) * 0.56)) or math.max(1, col_w - row_lpad - row_rpad)
        
        local vw = (UI and UI.makeColoredText)
            and UI.makeColoredText{ text = data.value, face = fitValFace(data.value, max_val_w), fgcolor = val_fg_color, max_width = max_val_w, truncate_with_ellipsis = true }
            or TextWidget:new{ text = data.value, face = fitValFace(data.value, max_val_w), fgcolor = val_fg_color, max_width = max_val_w, truncate_with_ellipsis = true }
        local lbl_w = math.max(1, col_w - row_lpad - vw:getSize().w - lbl_gap_eff - row_rpad)
        local row_hg = HorizontalGroup:new{
            align = "center", HorizontalSpan:new{ width = row_lpad }, vw, HorizontalSpan:new{ width = lbl_gap_eff },
            make_tbw({ text = desc, face = face_l, width = lbl_w, alignment = "left", fgcolor = lbl_fg_color, max_lines = 1, truncation_char = "…" }),
            HorizontalSpan:new{ width = row_rpad }
        }
        return CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = item_row_h },
            row_hg,
        }
    end

    local hdr_weight = CFG.getHeaderWeight(pfx)
    local hdr_base_fs = math.max(12, math.floor(14 * scale))
    local sec_fs
    if hdr_weight == "thin" then sec_fs = Font:getFace("NotoSerif-Regular.ttf", hdr_base_fs)
    elseif hdr_weight == "medium" then sec_fs = Font:getFace("NotoSans-Regular.ttf", hdr_base_fs)
    else sec_fs = Font:getFace("NotoSans-Bold.ttf", hdr_base_fs) or Font:getFace("NotoSans-Bold", hdr_base_fs) end
    sec_fs = sec_fs or Font:getFace("tfont", hdr_base_fs)

    local CLR_HDR_BG = Blitbuffer.COLOR_GRAY_D
    if SS then
        if SS.COLOR then CLR_HDR_BG = SS.COLOR.gray_soft or SS.COLOR.track or Blitbuffer.COLOR_GRAY_D
        elseif SS.getThemeColor then CLR_HDR_BG = SS.getThemeColor("muted") or SS.getThemeColor("divider") or Blitbuffer.COLOR_GRAY_D
        end
    end

    -- Function to show book summary/description
    local function showBookDescription()
        local desc = ""
        pcall(function()
            local bim = Config.getBookInfoManager()
            if bim then
                local props = bim:getBookInfo(current_fp, false)
                if props then desc = props.description or props.summary or props.annotation or props.comments or "" end
            end
        end)
        if type(desc) == "table" then desc = table.concat(desc, "\n\n")
        elseif type(desc) ~= "string" then desc = "" end
        if desc and desc ~= "" then
            pcall(function()
                local util = require("util")
                if util.htmlToPlainText then desc = util.htmlToPlainText(desc) end
            end)
            desc = desc:gsub("<br%s*/?>", "\n"):gsub("</p>", "\n\n"):gsub("<[^>]+>", ""):gsub("^%s+", ""):gsub("%s+$", "")
        end
        local final_desc = (desc and desc ~= "") and desc or _("No description available for this book.")
        local ok_tv, TextViewer = pcall(require, "ui/widget/textviewer")
        if ok_tv and TextViewer then
            UIManager:show(TextViewer:new{ title = bd.title or _("Book Description"), text = final_desc })
        else
            UIManager:show(require("ui/widget/infomessage"):new{ text = final_desc })
        end
        return true
    end

    -- Build right_header (title + info "i" button + author)
    local right_header = VerticalGroup:new{ align = "left" }

    local info_icon = (SS and SS.icon and SS.icon("info")) or "\u{F449}"
    local info_fs = math.max(12, math.floor(title_fs * 0.85))
    local info_face = (SS and SS.FACE_ICONS and Font:getFace(SS.FACE_ICONS, info_fs))
        or Font:getFace("symbols", info_fs)
        or Font:getFace("tfont", info_fs)

    local info_btn_wid = TextWidget:new{
        text = info_icon,
        face = info_face,
        fgcolor = CLR_TEXT_SUB_EFF,
    }
    local info_btn_size = math.max(info_btn_wid:getSize().w, info_btn_wid:getSize().h) + math.max(6, math.floor(8 * scale))
    local info_btn_w = math.max(info_btn_size, math.floor(26 * scale))
    local info_btn_h = info_btn_w

    local info_btn = InputContainer:new{
        dimen = Geom:new{ w = info_btn_w, h = info_btn_h },
        CenterContainer:new{
            dimen = Geom:new{ w = info_btn_w, h = info_btn_h },
            info_btn_wid,
        }
    }
    info_btn.ges_events = {
        TapInfo = { GestureRange:new{ ges = "tap", range = function() return info_btn.dimen end } }
    }
    function info_btn:onTapInfo()
        return showBookDescription()
    end

    local gap_info = math.max(4, math.floor(6 * scale))
    local max_single_w = math.max(50, tw - info_btn_w - gap_info)
    local raw_title = truncateTitle(bd.title) or "?"

    local function make_title_tw(text)
        if UI and UI.makeColoredText then
            return UI.makeColoredText{
                text = text,
                face = face_title,
                bold = true,
                fgcolor = clr.title,
            }
        else
            return TextWidget:new{
                text = text,
                face = face_title,
                bold = true,
                fgcolor = clr.title,
            }
        end
    end

    local function getTextW(txt)
        if not txt or txt == "" then return 0 end
        local tw_m = TextWidget:new{ text = txt, face = face_title, bold = true }
        local tw_w = tw_m:getSize().w
        if type(tw_m.free) == "function" then tw_m:free() end
        return tw_w
    end

    local title_line_gap, author_gap, fixed_ta_h = computeTaLayoutMetrics(pfx, scale, face_title, face_author)

    local title_element
    if getTextW(raw_title) <= max_single_w then
        -- Title fits entirely on a single line along with the info button
        local l1_wid = make_title_tw(raw_title)
        title_element = HorizontalGroup:new{
            align = "center",
            l1_wid,
            HorizontalSpan:new{ width = gap_info },
            info_btn,
        }
    else
        -- Wrap title into 2 lines cleanly by words
        local words = {}
        for w in raw_title:gmatch("%S+") do
            table.insert(words, w)
        end

        local l1_str = ""
        local split_idx = 1
        for i, w in ipairs(words) do
            local test_str = (l1_str == "") and w or (l1_str .. " " .. w)
            if getTextW(test_str) <= tw then
                l1_str = test_str
                split_idx = i + 1
            else
                break
            end
        end

        if l1_str == "" and #words > 0 then
            local RenderText = require("ui/rendertext")
            l1_str = RenderText:truncateTextByWidth(words[1], face_title, tw, true, true)
            split_idx = 2
        end

        local l2_words = {}
        for i = split_idx, #words do
            table.insert(l2_words, words[i])
        end
        local l2_str = table.concat(l2_words, " ")

        if l2_str and l2_str ~= "" then
            if getTextW(l2_str) > max_single_w then
                local RenderText = require("ui/rendertext")
                l2_str = RenderText:truncateTextByWidth(l2_str, face_title, max_single_w, true, true)
            end
            local l1_wid = make_title_tw(l1_str)
            local l2_wid = make_title_tw(l2_str)
            local l2_row = HorizontalGroup:new{
                align = "center",
                l2_wid,
                HorizontalSpan:new{ width = gap_info },
                info_btn,
            }
            title_element = stackVerticalGaps({ l1_wid, l2_row }, { title_line_gap }, tw)
        else
            local l1_wid = make_title_tw(l1_str)
            title_element = HorizontalGroup:new{
                align = "center",
                l1_wid,
                HorizontalSpan:new{ width = gap_info },
                info_btn,
            }
        end
    end

    local ta_group
    if bd.authors and bd.authors ~= "" then
        local auth_wid = UI.makeColoredText{
            text = bd.authors, face = face_author, fgcolor = clr.author,
            width = tw, max_width = tw, truncation_char = "…",
        }
        ta_group = stackVerticalGaps({ title_element, auth_wid }, { author_gap }, tw)
    else
        ta_group = VerticalGroup:new{ align = "left", title_element }
    end

    local info_tap_container = InputContainer:new{
        dimen = Geom:new{ w = tw, h = fixed_ta_h },
        [1] = ta_group,
    }
    info_tap_container.ges_events = {
        TapAuthor = { GestureRange:new{ ges = "tap", range = function() return info_tap_container.dimen end } }
    }
    function info_tap_container:onTapAuthor()
        return showBookDescription()
    end

    -- stat_defs
    local pages_left_data = { value = "", unit = "" }
    local total_p = stats.total_pages or bd.pages or 0
    local cur_p = stats.cur_page or bd.cur_page or (total_p > 0 and math.max(1, math.floor((stats.real_pct or bd.percent or 0) * total_p))) or 0
    if total_p > 0 then
        local rem_p = math.max(0, total_p - cur_p)
        pages_left_data = { value = tostring(rem_p), unit = _("pages") }
    end

    local cur_year_str = tostring(os.date("%Y"))
    local stat_defs = {
        book_time_spent         = { data = stats.book_time_spent,         extra = _("read") },
        book_pages_read         = { data = stats.book_pages_read,         extra = "" },
        book_time_left          = { data = stats.book_time_left,          extra = _("left") },
        pages_left              = { data = pages_left_data,               extra = _("left") },
        days_reading            = { data = stats.days_reading,            extra = "" },
        days_to_go              = { data = stats.days_to_go,              extra = "" },
        avg_time_per_day        = { data = stats.avg_time_per_day,        extra = _("a day") },
        pages_per_minute        = { data = stats.pages_per_minute,        extra = "" },
        mins_per_session        = { data = stats.mins_per_session,        extra = "" },
        pages_last_session      = { data = stats.pages_last_session,      extra = "" },
        today_pages             = { data = stats.today_pages,             extra = _("today") },
        today_time              = { data = stats.today_time,              extra = _("today") },
        seconds_per_page        = { data = stats.seconds_per_page,        extra = "" },
        days_since_start        = { data = stats.days_since_start,        extra = "" },
        started_date            = { data = stats.started_date,            extra = "" },
        last_read_date          = { data = stats.last_read_date,          extra = "" },
        estimated_finish_date   = { data = stats.estimated_finish_date,   extra = "" },
        total_sessions          = { data = stats.total_sessions,          extra = "" },
        reading_streak          = { data = stats.reading_streak,          extra = "" },
        highlights_count        = { data = stats.highlights_count,        extra = "" },
        notes_count             = { data = stats.notes_count,             extra = "" },
        this_chapter_pages_left = { data = stats.this_chapter_pages_left, extra = "" },
        this_chapter_time_left  = { data = stats.this_chapter_time_left,  extra = "" },
        week_pages              = { data = stats.week_pages,              extra = _("this week") },
        week_time               = { data = stats.week_time,               extra = _("this week") },
        week_books              = { data = stats.week_books,              extra = _("this week") },
        week_days               = { data = stats.week_days,               extra = _("this week") },
        month_pages             = { data = stats.month_pages,             extra = _("this month") },
        month_time              = { data = stats.month_time,              extra = _("this month") },
        month_books             = { data = stats.month_books,             extra = _("this month") },
        month_days              = { data = stats.month_days,              extra = _("this month") },
        year_pages              = { data = stats.year_pages,              extra = cur_year_str },
        year_time               = { data = stats.year_time,               extra = cur_year_str },
        year_books              = { data = stats.year_books,              extra = cur_year_str },
        year_days               = { data = stats.year_days,               extra = cur_year_str },
        all_time_pages          = { data = stats.all_time_pages,          extra = _("all-time") },
        all_time_time           = { data = stats.all_time_time,           extra = _("all-time") },
        all_time_books          = { data = stats.all_time_books,          extra = _("all-time") },
        all_time_days           = { data = stats.all_time_days,           extra = _("all-time") },
    }

    local function mkDynamicGrid(items)
        local grid_args = { align = "left" }
        local show_h = CFG.getShowHeaders(pfx)

        local col_wids, col_gaps = {}, {}
        for c=1, cols do
            col_wids[c] = {}
            col_gaps[c] = {}
        end

        local hdr_row_gap = math.max(-math.floor(item_row_h * 0.5), Size.padding.default + math.floor(CFG.getHdrRowGap(pfx) * scale))
        local stat_row_gap = math.max(-math.floor(item_row_h * 0.65), Size.padding.default + math.floor(CFG.getStatRowGap(pfx) * scale))

        if show_h then
            local hdr_line_h = Size.line.medium or 2
            if hdr_weight == "thin" then hdr_line_h = Size.line.thin or 1
            elseif hdr_weight == "bold" then hdr_line_h = Size.line.thick or 3 end
            local hdr_style = CFG.getHeaderStyle(pfx)

            for c=1, cols do
                local h_txt = CFG.getHeaderTxt(pfx, c)
                table.insert(col_wids[c], mkSectionHeader(sec_fs, h_txt, col_widths[c], clr.hdr, row_lpad, hdr_line_h, hdr_style, CLR_HDR_BG, header_radius))
            end
        end

        for c = 1, cols do
            for r = 1, rows do
                local idx = (c - 1) * rows + r
                if items[idx] then
                    if #col_wids[c] > 0 then
                        table.insert(col_gaps[c], (r == 1 and show_h) and hdr_row_gap or stat_row_gap)
                    end
                    table.insert(col_wids[c], items[idx])
                end
            end
        end

        local hg_args = { align = "top" }
        for c=1, cols do
            local col_stack = stackVerticalGaps(col_wids[c], col_gaps[c], col_widths[c])
            table.insert(hg_args, col_stack)
            if c < cols then
                table.insert(hg_args, HorizontalSpan:new{ width = sep_line_w })
            end
        end
        table.insert(grid_args, HorizontalGroup:new(hg_args))
        return VerticalGroup:new(grid_args)
    end

    local active_items = {}
    local active_dict = CFG.getActiveStatsDict(pfx)
    local max_items = cols * rows
    local keys_to_display = {}
    for _idx, key in ipairs(CFG.resolveStatOrder(SUISettings:readSetting(pfx .. CFG.STAT_ORDER_KEY))) do
        if stat_defs[key] and active_dict[key] and #keys_to_display < max_items then
            table.insert(keys_to_display, key)
        end
    end
    for idx, key in ipairs(keys_to_display) do
        local c = math.ceil(idx / rows)
        if c > cols then c = cols end
        table.insert(active_items, pvline(stat_defs[key].data, stat_defs[key].extra, col_widths[c]))
    end

    local raw_grid = mkDynamicGrid(active_items)
    local grid_widget
    local stats_grid_h
    if show_stats_border and not both_borders then
        if type(clr.stats_bg) ~= "nil" then
            local rg_sz = raw_grid:getSize()
            local bw_w = rg_sz.w + (2 * (border_bw + border_pad))
            local bw_h = rg_sz.h + (2 * (border_bw + border_pad))
            local padded_grid = CenterContainer:new{
                dimen = Geom:new{ w = rg_sz.w + (2 * border_pad), h = rg_sz.h + (2 * border_pad) },
                raw_grid,
            }
            grid_widget = C.makeColorStrokeBox(bw_w, bw_h, border_bw, _CLR_DARK_EFF, border_radius, padded_grid, clr.stats_bg)
            stats_grid_h = bw_h
        else
            grid_widget = FrameContainer:new{
                bordersize = border_bw,
                color = _CLR_DARK_EFF,
                padding = border_pad,
                radius = border_radius,
                [1] = raw_grid,
            }
            stats_grid_h = grid_widget:getSize().h
        end
    elseif both_borders then
        grid_widget = raw_grid
        stats_grid_h = raw_grid:getSize().h + ((border_bw + border_pad) * 2)
    elseif type(clr.stats_bg) ~= "nil" then
        local rg_sz = raw_grid:getSize()
        local bw_w = rg_sz.w + (2 * border_pad)
        local bw_h = rg_sz.h + (2 * border_pad)
        grid_widget = OverlapGroup:new{
            dimen = Geom:new{ w = bw_w, h = bw_h },
            C.makeColorFill(bw_w, bw_h, clr.stats_bg, border_radius),
            CenterContainer:new{
                dimen = Geom:new{ w = bw_w, h = bw_h },
                raw_grid,
            },
        }
        stats_grid_h = bw_h
    else
        grid_widget = raw_grid
        stats_grid_h = raw_grid:getSize().h
    end

    local visuals_widget = nil
    local has_any_border = show_stats_border or show_visuals_border
    if show_visuals then
        local ring_border_w = both_borders and math.max(20, rings_col_w - border_bw)
            or (show_visuals_border and math.max(20, rings_col_w - (border_bw * 2)) or rings_col_w)
        visuals_widget = VisualsMod.buildSideVisuals({
            pfx                 = pfx,
            stats               = stats,
            bd                  = bd,
            scale               = scale,
            rings_col_w         = rings_col_w,
            ring_border_w       = ring_border_w,
            has_border          = has_any_border,
            max_free_w          = math.max(rings_col_w, rem_w - grid_widget:getSize().w - math.max(8, math.floor(14 * scale))),
            stats_grid_h        = stats_grid_h,
            size_mult           = size_mult,
            show_visuals_border = show_visuals_border,
            border_bw           = border_bw,
            val_fg_color        = val_fg_color,
            lbl_fg_color        = lbl_fg_color,
            bar_val_color       = clr.bar_lbl or val_fg_color,
            bar_lbl_color       = clr.bar_lbl or lbl_fg_color,
            vis_colors          = clr.vis,
            vis_track_color     = clr.vis_track,
            surface_color       = clr.stats_bg,
            clr_fg              = _CLR_BAR_FG,
            clr_bg              = _CLR_BAR_BG,
            clr_dark_eff        = _CLR_DARK_EFF,
            face_v              = face_v,
            face_l              = face_l,
        })
    end
    local vw_raw_sz = (show_visuals and visuals_widget) and visuals_widget:getSize() or nil
    local vw_raw_h = vw_raw_sz and vw_raw_sz.h or 0
    local border_extra_h = border_bw * 2

    if show_visuals and visuals_widget and show_visuals_border and not both_borders then
        local v_card_h = math.max(stats_grid_h, vw_raw_h + border_extra_h)
        local v_inner = CenterContainer:new{
            dimen = Geom:new{ w = rings_col_w - border_extra_h, h = v_card_h - border_extra_h },
            visuals_widget,
        }
        if type(clr.stats_bg) ~= "nil" then
            visuals_widget = C.makeColorStrokeBox(rings_col_w, v_card_h, border_bw, _CLR_DARK_EFF, border_radius, v_inner, clr.stats_bg)
        else
            visuals_widget = FrameContainer:new{
                bordersize = border_bw,
                color = _CLR_DARK_EFF,
                padding = 0,
                radius = border_radius,
                [1] = v_inner,
            }
        end
    elseif show_visuals and visuals_widget and (not show_visuals_border) and (not both_borders) and type(clr.stats_bg) ~= "nil" then
        local v_card_w = math.max(rings_col_w, (vw_raw_sz and vw_raw_sz.w or 0) + (border_pad * 2))
        local v_card_h = math.max(stats_grid_h, vw_raw_h + (border_pad * 2))
        visuals_widget = OverlapGroup:new{
            dimen = Geom:new{ w = v_card_w, h = v_card_h },
            C.makeColorFill(v_card_w, v_card_h, clr.stats_bg, border_radius),
            CenterContainer:new{
                dimen = Geom:new{ w = v_card_w, h = v_card_h },
                visuals_widget,
            },
        }
    end

    local base_stats_y = fixed_ta_h + Size.padding.large
    local pos = resolvePosShifts(pfx, scale)
    local visuals_shift = both_borders and pos.sy or pos.vy

    local frame_total_h = stats_grid_h
    if both_borders then
        frame_total_h = math.max(stats_grid_h, vw_raw_h + border_extra_h)
    end

    local visuals_h = (show_visuals and visuals_widget) and visuals_widget:getSize().h or 0
    if both_borders then
        visuals_h = frame_total_h
    end

    local min_top_y = show_visuals and math.min(0, pos.ty, base_stats_y + pos.sy, base_stats_y + visuals_shift)
                                    or math.min(0, pos.ty, base_stats_y + pos.sy)
    if both_borders then
        min_top_y = math.min(0, pos.ty, base_stats_y + pos.sy)
    end
    local hbar_offset_gap = math.max(6, math.floor(10 * scale))
    if is_horizontal then
        min_top_y = math.min(min_top_y, base_stats_y + pos.sy + (both_borders and frame_total_h or stats_grid_h) + hbar_offset_gap + pos.vy)
    end
    local top_pad = math.max(0, -min_top_y)

    local hbar_container = nil
    local hbar_extra_h = 0
    if is_horizontal then
        hbar_container, hbar_extra_h = VisualsMod.buildHorizontalVisuals({
            pfx            = pfx,
            stats          = stats,
            bd             = bd,
            scale          = scale,
            mid_w          = mid_w,
            target_total_w = mid_w,
            val_fg_color   = val_fg_color,
            bar_val_color  = clr.bar_lbl or val_fg_color,
            vis_colors     = clr.vis,
            vis_track_color = clr.vis_track,
            surface_color  = clr.stats_bg,
            bg_color       = clr.stats_bg,
            bg_pad         = border_pad,
            bg_radius      = border_radius,
            clr_fg         = _CLR_BAR_FG,
            clr_bg         = _CLR_BAR_BG,
            clr_dark_eff   = _CLR_DARK_EFF,
            face_l         = face_l,
        })
        if hbar_container then
            hbar_container.ges_events = {
                TapHBar = { GestureRange:new{ ges = "tap", range = function() return hbar_container.dimen end } }
            }
            function hbar_container:onTapHBar()
                local CBS = getSUIModule("module_currently_books_stat", "modules")
                local is_enabled = not CBS or (type(CBS.isEnabled) ~= "function" or CBS.isEnabled())
                if CBS and CBS.showBookStatsWindow and is_enabled then
                    CBS.showBookStatsWindow(current_fp, extracted_md5, ctx.ui)
                else
                    local UIManager = require("ui/uimanager")
                    UIManager:broadcastEvent(require("ui/event"):new("ShowReaderProgress"))
                end
                return true
            end
        end
    end
    local hbar_bot_extra = (is_horizontal and hbar_container) and math.max(0, hbar_extra_h + math.max(0, pos.vy)) or hbar_extra_h
    local mid_req_h = math.max(
        fixed_ta_h + math.max(0, pos.ty),
        base_stats_y + math.max(0, pos.sy) + (both_borders and frame_total_h or stats_grid_h) + hbar_bot_extra
    )
    local right_req_h = (show_visuals and not both_borders) and (base_stats_y + math.max(0, visuals_shift) + visuals_h) or 0
    local right_h = (show_visuals and not both_borders) and math.max(mid_req_h, right_req_h) or mid_req_h

    local dk = buildCoverDeckStack(pfx, ctx, SH, D, cover, current_fp, fps, curIdx, top_pad, right_h, cover_gap)
    local content_h = dk.content_h
    local deck_h    = dk.deck_h

    info_tap_container.overlap_offset = { pos.tx, top_pad + pos.ty }

    local row_items = { align = "top", [1] = dk.left_wrapper }
    local unified_frame, visuals_shifted, card_inner_h, card_inner_w, base_vis_x
    if both_borders then
        card_inner_h = frame_total_h - (border_bw * 2)
        card_inner_w = rings_col_w - border_bw
        local stats_inner = CenterContainer:new{
            dimen = Geom:new{ w = mid_w - border_bw, h = card_inner_h },
            grid_widget,
        }
        local base_y = math.floor((card_inner_h - vw_raw_h) / 2)
        local target_y = base_y + pos.vy
        if card_inner_h > vw_raw_h then
            local min_y = 1
            local max_y = math.max(1, card_inner_h - vw_raw_h - 1)
            target_y = math.max(min_y, math.min(max_y, target_y))
        end
        local max_vx = math.max(0, math.floor(card_inner_w * 0.45))
        local target_x = math.max(-max_vx, math.min(max_vx, pos.vx))

        visuals_shifted = CenterContainer:new{
            dimen = Geom:new{ w = card_inner_w, h = vw_raw_h },
            visuals_widget,
        }
        visuals_shifted.overlap_offset = { target_x, target_y }

        local visuals_inner = OverlapGroup:new{
            dimen = Geom:new{ w = card_inner_w, h = card_inner_h },
            visuals_shifted,
        }
        local combined_cards = HorizontalGroup:new{
            align = "top",
            stats_inner,
            visuals_inner,
        }
        if type(clr.stats_bg) ~= "nil" then
            unified_frame = C.makeColorStrokeBox(mid_w + rings_col_w, frame_total_h, border_bw, _CLR_DARK_EFF, border_radius, combined_cards, clr.stats_bg)
        else
            unified_frame = FrameContainer:new{
                bordersize = border_bw,
                color = _CLR_DARK_EFF,
                padding = 0,
                radius = border_radius,
                combined_cards,
            }
        end
        unified_frame.overlap_offset = { pos.sx, top_pad + base_stats_y + pos.sy }

        local mid_children = {
            dimen = Geom:new{ w = rem_w, h = content_h },
            info_tap_container,
            unified_frame,
        }
        if is_horizontal and hbar_container then
            local hbar_y = top_pad + base_stats_y + pos.sy + frame_total_h + hbar_offset_gap + pos.vy
            hbar_container.overlap_offset = { pos.vx, hbar_y }
            table.insert(mid_children, hbar_container)
        end
        local mid_content = OverlapGroup:new(mid_children)

        local mid_wrapper = LeftContainer:new{
            dimen = Geom:new{ w = rem_w, h = content_h },
            [1] = mid_content,
        }
        table.insert(row_items, mid_wrapper)
    else
        grid_widget.overlap_offset = { pos.sx, top_pad + base_stats_y + pos.sy }

        local right_children = {
            dimen = Geom:new{ w = rem_w, h = content_h },
            info_tap_container,
            grid_widget,
        }
        if is_horizontal and hbar_container then
            local hbar_y = top_pad + base_stats_y + pos.sy + stats_grid_h + hbar_offset_gap + pos.vy
            hbar_container.overlap_offset = { pos.vx, hbar_y }
            table.insert(right_children, hbar_container)
        end
        if show_visuals and visuals_widget then
            local vw_w = visuals_widget:getSize().w
            base_vis_x = (vw_w > rings_col_w) and math.max(0, rem_w - vw_w) or (mid_w + mid_gap)
            visuals_widget.overlap_offset = { base_vis_x + pos.vx, top_pad + base_stats_y + visuals_shift }
            table.insert(right_children, visuals_widget)
        end
        local right_canvas = OverlapGroup:new(right_children)
        local right_wrapper = LeftContainer:new{
            dimen = Geom:new{ w = rem_w, h = content_h },
            [1] = right_canvas,
        }
        table.insert(row_items, right_wrapper)
    end

    local row = HorizontalGroup:new(row_items)

    local bg_color = (SS and SS.COLOR and SS.COLOR.bg) or Blitbuffer.COLOR_WHITE
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = content_h }, _fp = current_fp, _open_fn = ctx.open_fn,
        _hs = ctx._screen_widget or ctx._hs_widget,
        _count = dk.count,
        _cur = dk.cur,
        [1] = FrameContainer:new{
            bordersize = 0, padding = 0, padding_left = side_margin, padding_right = side_margin,
            background = has_wp and nil or bg_color,
            [1] = row
        },
    }

    local function switchBook(new_idx)
        local cnt = tappable._count or 1
        if cnt <= 1 then return end
        tappable._cur = ((new_idx - 1) % cnt) + 1
        ctx.yanllsama_cur_idx = tappable._cur
        local hs = tappable._hs
        if hs then
            local use_partial = needColorPartialRefresh(pfx)
            if type(hs._refreshBookModSlot) == "function" then
                local orig_rt = hs._bookModRefreshType
                if use_partial and type(orig_rt) == "function" then
                    hs._bookModRefreshType = function(self_hs, mod_id, ...)
                        local rtype = orig_rt(self_hs, mod_id, ...)
                        if mod_id == "currently_yanllsama" and rtype == "ui" then
                            return "partial"
                        end
                        return rtype
                    end
                end
                local ok = pcall(hs._refreshBookModSlot, hs, "currently_yanllsama")
                if type(orig_rt) == "function" then
                    hs._bookModRefreshType = orig_rt
                end
                if not ok then
                    if hs._navbar_container and type(hs._updatePage) == "function" then
                        hs:_updatePage(true)
                        if UIManager then UIManager:setDirty(hs, use_partial and "partial" or "ui") end
                    elseif type(hs._refreshImmediate) == "function" then
                        hs:_refreshImmediate(true)
                        if use_partial and UIManager then UIManager:setDirty(hs, "partial") end
                    end
                end
            elseif hs._navbar_container and type(hs._updatePage) == "function" then
                hs:_updatePage(true)
                if UIManager then UIManager:setDirty(hs, use_partial and "partial" or "ui") end
            elseif type(hs._refreshImmediate) == "function" then
                hs:_refreshImmediate(true)
                if use_partial and UIManager then
                    UIManager:setDirty(hs, "partial")
                end
            end
        end
    end
    function tappable:_goToPrev(step) switchBook((self._cur or 1) - (step or 1)) end
    function tappable:_goToNext(step) switchBook((self._cur or 1) + (step or 1)) end

    tappable.ges_events = {
        TapBook = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
        Swipe   = { GestureRange:new{ ges = "swipe", range = function() return tappable.dimen end } },
    }

    function tappable:onSwipe(_, ges)
        if not ges or (ges.direction ~= "north" and ges.direction ~= "south") then
            return false
        end
        if ges.pos and self.dimen then
            local rel_x = ges.pos.x - self.dimen.x
            local rel_y = ges.pos.y - self.dimen.y
            local left_boundary = side_margin + D.COVER_W + cover_gap
            local stats_left = left_boundary + pos.sx
            local mid_boundary = stats_left + mid_w + mid_gap
            local y_split = top_pad + base_stats_y + pos.sy
            local hbar_split = y_split + (both_borders and frame_total_h or stats_grid_h)
            local in_stats_x = (rel_x >= stats_left) and ((not show_visuals) or (rel_x <= mid_boundary))
            local in_stats_y = (rel_y >= y_split) and ((not (is_horizontal and hbar_container)) or (rel_y < hbar_split))
            if in_stats_x and in_stats_y then
                local step = (ges.direction == "north") and 1 or -1
                if handleProfileSwipe(pfx, step, self._hs) then
                    return true
                end
            end
        end
        if (self._count or 1) > 1 then
            if ges.direction == "south" then
                self:_goToPrev(1)
                return true
            elseif ges.direction == "north" then
                self:_goToNext(1)
                return true
            end
        end
        return false
    end

    tappable._cover_slots = dk.slots

    function tappable:onTapBook(_, ges)
        if ges and ges.pos and self.dimen then
            local rel_x = ges.pos.x - self.dimen.x
            local rel_y = ges.pos.y - self.dimen.y
            
            local left_boundary = side_margin + D.COVER_W + cover_gap
            local hit_visuals = false
            if show_visuals and visuals_widget then
                if both_borders then
                    local mid_boundary = left_boundary + pos.sx + mid_w + mid_gap
                    hit_visuals = (rel_x > mid_boundary)
                else
                    local vx0 = left_boundary + (base_vis_x or (mid_w + mid_gap)) + pos.vx
                    local vy0 = top_pad + base_stats_y + visuals_shift
                    local vw_w = visuals_widget:getSize().w
                    hit_visuals = (rel_x >= vx0 and rel_x <= vx0 + vw_w and rel_y >= vy0 and rel_y <= vy0 + visuals_h)
                        or (rel_x > left_boundary + pos.sx + mid_w + mid_gap)
                end
            end
            
            if hit_visuals then
                -- Tap in Right Column (Rings -> Book stats / reader progress)
                local CBS = package.loaded["modules/module_currently_books_stat"]
                if not CBS then
                    local ok, res = pcall(require, "modules/module_currently_books_stat")
                    if ok and res then CBS = res end
                end
                if not CBS then
                    local ok, res = pcall(require, "desktop_modules/module_currently_books_stat")
                    if ok and res then CBS = res end
                end
                if not CBS then
                    local ok, res = pcall(require, "module_currently_books_stat")
                    if ok and res then CBS = res end
                end

                local is_enabled = true
                if CBS and type(CBS.isEnabled) == "function" then
                    is_enabled = CBS.isEnabled()
                end

                if CBS and CBS.showBookStatsWindow and is_enabled then
                    CBS.showBookStatsWindow(current_fp, extracted_md5, ctx.ui)
                else
                    local UIManager = require("ui/uimanager")
                    UIManager:broadcastEvent(require("ui/event"):new("ShowReaderProgress"))
                end
                return true
            elseif rel_x > left_boundary then
                -- Tap in Middle Column:
                local y_split = top_pad + base_stats_y + pos.sy
                local hbar_split = y_split + (both_borders and frame_total_h or stats_grid_h)
                if rel_y < y_split then
                    showBookDescription()
                    return true
                elseif is_horizontal and hbar_container and rel_y >= hbar_split then
                    local CBS = getSUIModule("module_currently_books_stat", "modules")
                    local is_enabled = not CBS or (type(CBS.isEnabled) ~= "function" or CBS.isEnabled())
                    if CBS and CBS.showBookStatsWindow and is_enabled then
                        CBS.showBookStatsWindow(current_fp, extracted_md5, ctx.ui)
                    else
                        local UIManager = require("ui/uimanager")
                        UIManager:broadcastEvent(require("ui/event"):new("ShowReaderProgress"))
                    end
                    return true
                else
                    if not isReadingInsightsAvailable(ctx.ui) then
                        return false
                    end
                    local UIManager = require("ui/uimanager")
                    UIManager:broadcastEvent(require("ui/event"):new("ShowReadingInsightsPopup"))
                    return true
                end
            else
                -- Tap in Left Column (Coverdeck & Navigation)
                local dm, p1, p2, p3 = dk.deck_mode, dk.peek1, dk.peek2, dk.peek3
                if self._count <= 1 or dm == 1 then
                    if self._open_fn then self._open_fn(self._fp) end
                    return true
                end

                local deck_rel_y = rel_y - dk.deck_y
                if dm == 3 then
                    if deck_rel_y < p1 then
                        self:_goToPrev(1)
                        return true
                    elseif deck_rel_y <= p1 + D.COVER_H then
                        if self._open_fn then self._open_fn(self._fp) end
                        return true
                    else
                        self:_goToNext(1)
                        return true
                    end
                elseif dm == 7 then
                    if deck_rel_y < p3 then
                        self:_goToPrev(self._count >= 7 and 3 or (self._count >= 5 and 2 or 1))
                        return true
                    elseif deck_rel_y < p3 + p2 then
                        self:_goToPrev(self._count >= 5 and 2 or 1)
                        return true
                    elseif deck_rel_y < p3 + p2 + p1 then
                        self:_goToPrev(1)
                        return true
                    elseif deck_rel_y <= p3 + p2 + p1 + D.COVER_H then
                        if self._open_fn then self._open_fn(self._fp) end
                        return true
                    elseif deck_rel_y <= deck_h - p3 - p2 then
                        self:_goToNext(1)
                        return true
                    elseif deck_rel_y <= deck_h - p3 then
                        self:_goToNext(self._count >= 5 and 2 or 1)
                        return true
                    else
                        self:_goToNext(self._count >= 7 and 3 or (self._count >= 5 and 2 or 1))
                        return true
                    end
                else
                    -- deck_mode == 5
                    if deck_rel_y < p2 then
                        self:_goToPrev(self._count >= 5 and 2 or 1)
                        return true
                    elseif deck_rel_y < p2 + p1 then
                        self:_goToPrev(1)
                        return true
                    elseif deck_rel_y <= p2 + p1 + D.COVER_H then
                        if self._open_fn then self._open_fn(self._fp) end
                        return true
                    elseif deck_rel_y <= deck_h - p2 then
                        self:_goToNext(1)
                        return true
                    else
                        self:_goToNext(self._count >= 5 and 2 or 1)
                        return true
                    end
                end
            end
        end
    if self._open_fn then self._open_fn(self._fp) end
        return true
    end

    tappable._yan_layout = {
        pfx                = pfx,
        scale              = scale,
        pos                = pos,
        top_pad            = top_pad,
        content_h          = content_h,
        deck_h             = deck_h,
        fixed_ta_h         = fixed_ta_h,
        base_stats_y       = base_stats_y,
        base_vis_x         = base_vis_x or (mid_w + mid_gap),
        both_borders       = both_borders,
        show_visuals       = show_visuals,
        is_horizontal      = is_horizontal,
        frame_total_h      = frame_total_h,
        stats_grid_h       = stats_grid_h,
        visuals_h          = visuals_h,
        vw_raw_h           = vw_raw_h,
        inner_h            = card_inner_h,
        inner_w            = card_inner_w,
        hbar_extra_h       = hbar_extra_h,
        hbar_offset_gap    = hbar_offset_gap,
        bg_color           = bg_color,
        has_wallpaper      = has_wp,
        info_tap_container = info_tap_container,
        grid_widget        = grid_widget,
        unified_frame      = unified_frame,
        visuals_widget     = visuals_widget,
        visuals_shifted    = visuals_shifted,
        hbar_container     = hbar_container,
    }

    if ctx.kb_currently_focused then
        local bw = Screen:scaleBySize(3)
        local focused = OverlapGroup:new{
            dimen = Geom:new{ w = w, h = content_h }, tappable,
            LineWidget:new{ dimen = Geom:new{ w = w, h = bw }, background = _CLR_DARK_EFF },
            LineWidget:new{ dimen = Geom:new{ w = w, h = bw }, background = _CLR_DARK_EFF, overlap_offset = {0, content_h - bw} },
            LineWidget:new{ dimen = Geom:new{ w = bw, h = content_h }, background = _CLR_DARK_EFF },
            LineWidget:new{ dimen = Geom:new{ w = bw, h = content_h }, background = _CLR_DARK_EFF, overlap_offset = {w - bw, 0} },
        }
        focused._yan_layout = tappable._yan_layout
        return focused
    end

    return tappable
end

function M.updateCovers(widget, _ctx)
    local tappable = (widget._cover_slots) and widget or (widget[1] and widget[1]._cover_slots and widget[1])
    if not tappable or not tappable._cover_slots then return true end

    local SH = getSH()
    if not SH then return true end

    local all_done = true
    for _idx, slot in ipairs(tappable._cover_slots) do
        local new_cover = SH.getBookCover(slot.fp, slot.w, slot.h, slot.align, slot.stretch)
        if new_cover then
            if slot.container and slot.container[slot.idx] then
                new_cover.overlap_offset = slot.container[slot.idx].overlap_offset
                slot.container[slot.idx] = new_cover
            end
        elseif not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done
end

function M.getHeight(_ctx)
    local SH = getSH()
    if not SH then return Config.getScaledLabelH(_ctx and _ctx.landscape_factor) end
    local pfx   = _ctx and _ctx.pfx or ""
    local lf    = getLandscapeScale(_ctx)
    local scale = Config.getModuleScale("currently_yanllsama", pfx) * lf
    local thumb_scale = Config.getThumbScale("currently_yanllsama", pfx)
    local cols = CFG.getGridCols(pfx)
    local rows = CFG.getGridRows(pfx)
    local show_h = CFG.getShowHeaders(pfx)
    local est_w = (_ctx and (_ctx.col_w or _ctx.inner_w))
        or (UI and UI.isLandscape and UI.isLandscape() and UI.getSpreadColWidth and UI.getSpreadColWidth())
        or (UI and UI.getInnerW and UI.getInnerW())
        or Screen:getWidth() or 1000
    local side_margin_est = math.max(0, math.floor(CFG.getSideMargin(pfx) * scale))
    local avail_w_est = math.max(100, est_w - (side_margin_est * 2))
    local D = computeModuleDims(pfx, SH, scale, thumb_scale, avail_w_est)
    
    local title_fs = math.max(10, math.floor((CFG.getTitleFs(pfx) or 24) * scale))
    local author_fs = math.max(9, math.floor((CFG.getAuthorFs(pfx) or 20) * scale))
    local face_title = Font:getFace(resolveFontFace(CFG.getTitleFont(pfx), true), title_fs) or Font:getFace("tfont", title_fs)
    local face_author = Font:getFace(resolveFontFace(CFG.getAuthorFont(pfx), false), author_fs) or Font:getFace("tfont", author_fs)
    local _tlg, _ag, fixed_ta_h = computeTaLayoutMetrics(pfx, scale, face_title, face_author)

    local max_fs = math.max(CFG.getValFs(pfx), CFG.getLblFs(pfx))
    local row_h = Screen:scaleBySize(max_fs + 8) * scale
    local stat_row_gap = math.max(-math.floor(row_h * 0.65), Size.padding.default + math.floor(CFG.getStatRowGap(pfx) * scale))
    local spans = math.max(0, rows - 1) * stat_row_gap

    local header_approx = 0
    if show_h then
        local hdr_row_gap = math.max(-math.floor(row_h * 0.5), Size.padding.default + math.floor(CFG.getHdrRowGap(pfx) * scale))
        header_approx = (Screen:scaleBySize(22) * scale) + hdr_row_gap
    end
    
    local deck_mode = CFG.getCoverDeckMode(pfx)
    local peek_lvl1 = (deck_mode >= 3) and math.max(3, math.floor(D.COVER_H * 0.055)) or 0
    local peek_lvl2 = (deck_mode >= 5) and math.max(3, math.floor(D.COVER_H * 0.045)) or 0
    local peek_lvl3 = (deck_mode >= 7) and math.max(3, math.floor(D.COVER_H * 0.036)) or 0
    local deck_h = peek_lvl3 + peek_lvl2 + peek_lvl1 + D.COVER_H + peek_lvl1 + peek_lvl2 + peek_lvl3
    local left_h = deck_h

    local title_shift = math.floor(CFG.getTitlePosY(pfx) * scale)
    local stats_shift = math.floor(CFG.getStatsPosY(pfx) * scale)
    local visuals_shift = math.floor(CFG.getVisualsPosY(pfx) * scale)

    local base_stats_y = fixed_ta_h + Size.padding.large

    local show_stats_border = CFG.getShowStatsBorder(pfx)
    local show_visuals_border = CFG.getShowVisualsBorder(pfx)
    local has_stats_bg = (CFG.getColorHex(pfx, CFG.STATS_BG_COLOR_KEY) ~= nil)
    local border_extra_h = show_stats_border and (2 * ((Size.line.thin or 1) + Size.padding.small)) or (has_stats_bg and (2 * Size.padding.small) or 0)
    local grid_approx = header_approx + (row_h * rows) + spans + border_extra_h

    local active_visuals = CFG.getActiveVisuals(pfx)
    local n_vis = #active_visuals
    local visuals_enabled = CFG.getShowVisuals(pfx) and (n_vis > 0)
    local bar_style = CFG.getBarStyle(pfx)
    local is_horizontal = visuals_enabled and (bar_style == "horizontal")
    local show_visuals = visuals_enabled and (not is_horizontal)
    local both_borders = show_visuals and show_stats_border and show_visuals_border
    if both_borders then
        visuals_shift = stats_shift
    end

    local visuals_approx = 0
    local right_req_h = 0
    if show_visuals then
        local size_mult = ((bar_style == "bars") and CFG.getVBarHeightPct(pfx) or CFG.getBarHeightPct(pfx)) / 100
        if bar_style == "bars" then
            local base_target_h = math.max(math.floor(130 * scale), grid_approx - math.floor(25 * scale))
            local bar_h = math.max(40, math.floor(base_target_h * size_mult))
            local val_h = math.max(12, math.floor(CFG.getBarLblFs(pfx) * scale)) + math.max(3, math.floor(6 * scale))
            visuals_approx = bar_h + val_h
        else
            local cover_gap = math.max(0, math.floor(_BASE_COVER_GAP * scale * (CFG.getCoverGapPct(pfx) / 100)))
            local mid_gap = both_borders and 0 or math.max(8, math.floor(16 * scale))
            local combined_w = math.max(80, avail_w_est - (D.COVER_W + cover_gap) - mid_gap)
            local ratio_pct = math.max(40, math.min(85, CFG.getStatsWidthRatio(pfx)))
            local approx_mid_w = math.floor(combined_w * (ratio_pct / 100))
            local approx_col_w = math.max(40, combined_w - approx_mid_w)
            local has_any_border = show_stats_border or show_visuals_border
            local border_bw_est = Size.line.thin or 1
            local ring_bound_w = both_borders and math.max(20, approx_col_w - border_bw_est)
                or (show_visuals_border and math.max(20, approx_col_w - (border_bw_est * 2)) or approx_col_w)
            local target_ring_d = VisualsMod.calcRingDiameter(scale, ring_bound_w, size_mult, has_any_border, approx_col_w)
            local chosen_fs = CFG.getBarLblFs(pfx)
            local show_ring_lbl = CFG.getShowRingLabels(pfx)
            local bot_lbl_h = 0
            if show_ring_lbl then
                local bot_lbl_fs = math.max(8, math.floor(chosen_fs * 0.85 * scale))
                bot_lbl_h = math.max(3, math.floor(5 * scale)) + bot_lbl_fs + 4
            end
            local single_ring_h = target_ring_d + bot_lbl_h
            local rings_gap_y = math.max(0, math.floor(CFG.getBarGap(pfx) * scale))
            visuals_approx = (single_ring_h * n_vis) + (rings_gap_y * math.max(0, n_vis - 1))
        end

        if show_visuals_border or both_borders then
            local border_bw = Size.line.thin or 1
            visuals_approx = math.max(grid_approx, visuals_approx + (border_bw * 2))
        elseif has_stats_bg then
            visuals_approx = math.max(grid_approx, visuals_approx + (2 * Size.padding.small))
        end
        right_req_h = (not both_borders) and (base_stats_y + math.max(0, visuals_shift) + visuals_approx) or 0
    end

    local min_top_y = (show_visuals and not both_borders) and math.min(0, title_shift, base_stats_y + stats_shift, base_stats_y + visuals_shift)
                                    or math.min(0, title_shift, base_stats_y + stats_shift)
    local top_pad = math.max(0, -min_top_y)

    local hbar_approx = 0
    if is_horizontal then
        local thick_level = CFG.getHBarThickness(pfx)
        local hbar_h = math.max(2, math.floor((VisualsMod.HBAR_H_12[thick_level] or 10) * scale))
        local is_bar_lbl_bold = CFG.getBarLblBold(pfx)
        local bar_lbl_fs = math.max(10, math.floor(CFG.getBarLblFs(pfx) * scale))
        local face_bar_lbl = Font:getFace(resolveFontFace(CFG.getBarLblFont(pfx), is_bar_lbl_bold), bar_lbl_fs) or face_title
        local line_h = getLineHeight(face_bar_lbl)
        local row_h = math.max(hbar_h, line_h)
        local inter_bar_gap = math.max(0, math.floor(CFG.getHBarGap(pfx) * scale))
        local top_margin = math.max(4, math.floor(6 * scale))
        hbar_approx = top_margin + (row_h * n_vis) + (inter_bar_gap * math.max(0, n_vis - 1)) + (has_stats_bg and (2 * Size.padding.small) or 0)
    end

    local frame_approx = both_borders and visuals_approx or grid_approx
    local mid_req_h = math.max(
        fixed_ta_h + math.max(0, title_shift),
        base_stats_y + math.max(0, stats_shift) + frame_approx + hbar_approx
    )
    local right_h = (show_visuals and not both_borders) and math.max(mid_req_h, right_req_h) or mid_req_h

    return Config.getScaledLabelH(lf) + top_pad + math.max(left_h, right_h)
end

M.seedBundledProfiles = CFG.seedDefaultProfiles
M.exportProfilesToPlugin = CFG.exportProfilesToPlugin

function M.getMenuItems(ctx_menu)
    return MenuMod.buildMenuItems(ctx_menu)
end

local function resolveBookMetaAndStats(fp, bd, prefetched_entry, pfx, db_conn)
    if not fp or fp == "" then return nil, nil end
    local extracted_md5 = prefetched_entry and prefetched_entry.partial_md5_checksum
    pcall(function()
        if _docsettings_cache and _docsettings_cache[fp] then
            local cached_ds = _docsettings_cache[fp]
            extracted_md5 = extracted_md5 or cached_ds.extracted_md5
            if bd then
                bd.percent = bd.percent or cached_ds.percent
                if cached_ds.pages then bd.pages = cached_ds.pages end
                if cached_ds.cur_page then bd.cur_page = cached_ds.cur_page end
            end
            return
        end
        local DS = package.loaded["docsettings"] or require("docsettings")
        if DS and require("libs/libkoreader-lfs").attributes(fp, "mode") == "file" then
            local ok, ds = pcall(DS.open, DS, fp)
            if ok and ds then
                extracted_md5 = extracted_md5 or ds:readSetting("partial_md5_checksum")
                local pct_ds = (bd and bd.percent) or ds:readSetting("percent_finished")
                local phys = ds:readSetting("yanllsama_physical_pages")
                local pages_ds = (phys and tonumber(phys) and tonumber(phys) > 0) and tonumber(phys)
                    or ((bd and bd.pages) or ds:readSetting("doc_pages"))
                local lp = ds:readSetting("last_page")
                local pmap_lbl = ds:readSetting("pagemap_current_page_label")
                local cur_p_from_ds = tonumber(lp) or (pmap_lbl and (tonumber(pmap_lbl) or tonumber(pmap_lbl:match("%d+"))))
                local pmap_pages = ds:readSetting("pagemap_doc_pages")
                if not pages_ds and pmap_pages and tonumber(pmap_pages) and tonumber(pmap_pages) > 0 then
                    pages_ds = tonumber(pmap_pages)
                end

                local cached_ds = {
                    extracted_md5 = extracted_md5,
                    percent       = pct_ds,
                    pages         = pages_ds,
                    cur_page      = (cur_p_from_ds and cur_p_from_ds > 0) and cur_p_from_ds or nil,
                }
                _docsettings_cache[fp] = cached_ds
                if bd then
                    bd.percent = cached_ds.percent
                    if cached_ds.pages then bd.pages = cached_ds.pages end
                    if cached_ds.cur_page then bd.cur_page = cached_ds.cur_page end
                end
                pcall(function() ds:close() end)
            end
        end
    end)

    local stats = StatsMod.cacheGet(fp, pfx)
    if not stats then
        local cached_ds = _docsettings_cache and _docsettings_cache[fp]
        local book_meta = {
            fp       = fp,
            title    = (bd and bd.title) or "",
            md5      = extracted_md5,
            percent  = (bd and bd.percent) or (cached_ds and cached_ds.percent) or 0,
            pages    = (bd and bd.pages) or (cached_ds and cached_ds.pages) or 0,
            cur_page = (bd and bd.cur_page) or (cached_ds and cached_ds.cur_page) or 0,
        }
        stats = StatsMod.gatherStats(book_meta, pfx, db_conn)
        StatsMod.cachePut(fp, pfx, stats)
    end
    return stats, extracted_md5
end

local function scheduleNeighborPrewarm(fps, curIdx, pfx, ctx, SH)
    _prewarm_gen = _prewarm_gen + 1
    if _prewarm_timer and UIManager then
        pcall(function() UIManager:unschedule(_prewarm_timer) end)
        _prewarm_timer = nil
    end
    if _prewarm_close_conn then
        pcall(_prewarm_close_conn)
        _prewarm_close_conn = nil
    end
    local count = fps and #fps or 0
    if count <= 1 or not UIManager then return end

    local queue = {}
    local queued_fp = { [fps[curIdx]] = true }
    for _, off in ipairs({ 1, -1, 2, -2 }) do
        local idx = ((curIdx - 1 + off) % count) + 1
        local nfp = fps[idx]
        if nfp and not queued_fp[nfp] then
            queued_fp[nfp] = true
            local ds_ok = _docsettings_cache and _docsettings_cache[nfp]
            local st_ok = StatsMod and StatsMod.isBookCached and StatsMod.isBookCached(nfp, pfx)
            if not (ds_ok and st_ok) then
                queue[#queue + 1] = nfp
            end
        end
    end
    if #queue == 0 then return end

    local gen = _prewarm_gen
    local pos = 1
    local local_conn = nil
    local close_conn = function()
        if local_conn then
            pcall(function() local_conn:close() end)
            local_conn = nil
        end
    end
    _prewarm_close_conn = close_conn

    local function stepPrewarm()
        if gen ~= _prewarm_gen then
            close_conn()
            return
        end
        local nfp = queue[pos]
        pos = pos + 1
        if not nfp then
            _prewarm_timer = nil
            _prewarm_close_conn = nil
            close_conn()
            return
        end

        local db_conn = ctx and ctx.db_conn
        if not db_conn and not local_conn and Config and type(Config.openStatsDB) == "function" then
            local ok_c, c = pcall(Config.openStatsDB)
            if ok_c and c then local_conn = c end
        end
        local active_conn = db_conn or local_conn
        local pe = ctx and ctx.prefetched and ctx.prefetched[nfp]
        local n_bd = SH and SH.getBookData(nfp, pe) or { percent = pe and pe.percent, pages = pe and pe.pages, cur_page = pe and pe.cur_page }
        resolveBookMetaAndStats(nfp, n_bd, pe, pfx, active_conn)

        if pos <= #queue and gen == _prewarm_gen then
            _prewarm_timer = stepPrewarm
            UIManager:scheduleIn(0.03, stepPrewarm)
        else
            _prewarm_timer = nil
            _prewarm_close_conn = nil
            close_conn()
        end
    end

    _prewarm_timer = stepPrewarm
    UIManager:scheduleIn(0.10, stepPrewarm)
end

function M.prewarm(books_state, db_conn)
    if not books_state then return end
    local SH = getSH()
    local pfx = "simpleui_hs_"
    local fp = books_state.current_fp or (books_state.recent_fps and books_state.recent_fps[1])
    if not fp then return end
    local pe = books_state.prefetched and books_state.prefetched[fp]
    local bd = SH and SH.getBookData(fp, pe) or {}
    resolveBookMetaAndStats(fp, bd, pe, pfx, db_conn)
end

function M.build(w, ctx)
    if Config and type(Config.applyLabelToggle) == "function" then
        Config.applyLabelToggle(M, _("Currently Reading"))
    end

    local SH = getSH()
    if not SH then return nil end

    local c     = ctx.cfg and ctx.cfg.currently_yanllsama
    local pfx   = ctx.pfx or ""
    
    local main_fp = CFG.getCurrentFP(ctx, pfx)
    if not main_fp then return nil end

    local excludes = CFG.getExcludePaths(pfx)
    local fps = { main_fp }
    local source = CFG.getSource(pfx)
    local source_fps = nil

    if source == "tbr" then
        local ok, tbr = pcall(require, "desktop_modules/module_tbr")
        if ok and tbr.getTBRList then
            source_fps = tbr.getTBRList()
        end
    end

    if not source_fps or #source_fps == 0 then
        source_fps = ctx.recent_fps
    end

    if source_fps then
        local seen = { [main_fp] = true }
        for _idx, fp in ipairs(source_fps) do
            if not seen[fp] and not CFG.isExcluded(fp, excludes) then
                fps[#fps+1] = fp
                seen[fp] = true
                if #fps >= 20 then break end
            end
        end
    end

    local curIdx = ctx.yanllsama_cur_idx or 1
    if curIdx > #fps then curIdx = 1 end
    ctx.yanllsama_cur_idx = curIdx
    
    local current_fp = fps[curIdx]
    
    local lf          = getLandscapeScale(ctx)
    local scale       = (c and c.scale or Config.getModuleScale("currently_yanllsama", pfx)) * lf
    local thumb_scale = c and c.thumb_scale or Config.getThumbScale("currently_yanllsama", pfx)
    local lbl_scale   = c and c.lbl_scale   or Config.getItemLabelScale("currently_yanllsama", pfx)
    
    local cols = CFG.getGridCols(pfx)
    local rows = CFG.getGridRows(pfx)

    local avail_w_build = math.max(100, w - (math.max(0, math.floor(CFG.getSideMargin(pfx) * scale)) * 2))
    local D = computeModuleDims(pfx, SH, scale, thumb_scale, avail_w_build)
    
    local prefetched_entry = ctx.prefetched and ctx.prefetched[current_fp]
    local bd    = SH.getBookData(current_fp, prefetched_entry)
    local cover = SH.getBookCover(current_fp, D.COVER_W, D.COVER_H, nil, 0.10)
            or SH.coverPlaceholder(bd.title, bd.authors, D.COVER_W, D.COVER_H)

    -- Resolve sidecar metadata + cached/SQLite statistics via shared helper
    local stats, extracted_md5 = resolveBookMetaAndStats(current_fp, bd, prefetched_entry, pfx, ctx.db_conn)

    if stats then
        if stats.real_pct and stats.real_pct > 0 then
            bd.percent = stats.real_pct
        end
        if stats.cur_page and stats.cur_page > 0 then
            bd.cur_page = stats.cur_page
        end
        if stats.total_pages and stats.total_pages > 0 then
            bd.pages = stats.total_pages
        end
    end

    if not ctx._yan_live_preview then
        scheduleNeighborPrewarm(fps, curIdx, pfx, ctx, SH)
    end

    return _buildWidget(w, ctx, pfx, SH, bd, cover, stats, D, scale, lbl_scale, cols, rows, current_fp, fps, curIdx, extracted_md5)
end

return M








