-- modules/currently_reading/stats_editor.lua — Compact left-docked live Statistics editor.

local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local Size       = require("ui/size")
local UIManager  = require("ui/uimanager")
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
    TextWidget      = require("ui/widget/textwidget"),
    VerticalGroup   = require("ui/widget/verticalgroup"),
    VerticalSpan    = require("ui/widget/verticalspan"),
}

local C   = require("modules/currently_reading/config")
local CFG = C.CFG
local _   = C._

local M = {}

local function getStyleColorsAndIcons()
    local SS = C.getSUIStyle()
    local bg = Blitbuffer.COLOR_WHITE
    local fg = Blitbuffer.COLOR_BLACK
    -- KOReader Blitbuffer.gray(level) measures blackness (0.0 = white, 1.0 = black).
    local dim = Blitbuffer.gray(0.45)
    local line_c = Blitbuffer.gray(0.30)
    local pill_bg = Blitbuffer.gray(0.08)
    if SS and SS.COLOR then
        bg = SS.COLOR.surface or bg
        fg = SS.COLOR.text_primary or fg
        dim = SS.COLOR.text_dim or SS.COLOR.text_secondary or dim
        line_c = SS.COLOR.gray_soft or line_c
        pill_bg = SS.COLOR.surface_gray or pill_bg
    elseif SS and SS.getThemeColor then
        bg = SS.getThemeColor("bg") or bg
        fg = SS.getThemeColor("fg") or fg
        dim = SS.getThemeColor("text_secondary") or dim
    end
    local icon_face_name = (SS and SS.FACE_ICONS) or nil
    local icons = {
        use_sui  = (SS and type(SS.icon) == "function" and icon_face_name ~= nil),
        face     = icon_face_name,
        check    = (SS and SS.ICON and SS.ICON.check)        or "\xE2\x9C\x94",
        uncheck  = (SS and SS.ICON and SS.ICON.uncheck)      or "\xE2\x97\x8B",
        up       = (SS and SS.ICON and SS.ICON.arrow_up)     or "\xE2\x96\xB2",
        down     = (SS and SS.ICON and SS.ICON.arrow_down)   or "\xE2\x96\xBC",
        prev     = (SS and SS.ICON and SS.ICON.chevron_left) or "<",
        next     = (SS and SS.ICON and SS.ICON.chevron)      or ">",
        close    = (SS and icon_face_name) and "\u{F00D}"     or "\xC3\x97",
    }
    return bg, fg, dim, line_c, pill_bg, icons
end

-- Computes panel width docked to left edge covering primarily the book cover column.
local function computePanelWidth(pfx, sw)
    local SH = C.getSH()
    local Config = C.getConfig()
    local mod_scale = (Config and type(Config.getModuleScale) == "function" and Config.getModuleScale("currently_yanllsama", pfx)) or 1.0
    local thumb_scale = (Config and type(Config.getThumbScale) == "function" and Config.getThumbScale("currently_yanllsama", pfx)) or 1.0
    local D = (SH and type(SH.getDims) == "function")
        and SH.getDims(mod_scale, thumb_scale)
        or { COVER_W = math.floor(Screen:scaleBySize(160) * mod_scale * thumb_scale) }
    local side_margin = math.max(0, math.floor(CFG.getSideMargin(pfx) * mod_scale))
    local cover_w = (D and D.COVER_W) or math.floor(Screen:scaleBySize(160) * mod_scale)
    local cover_gap = math.max(0, math.floor(Screen:scaleBySize(8) * mod_scale * (CFG.getCoverGapPct(pfx) / 100)))
    local target = side_margin + cover_w + math.floor(cover_gap * 0.65)
    local min_w = math.floor(sw * 0.24)
    local max_w = math.floor(sw * 0.34)
    return math.max(min_w, math.min(max_w, target))
end

local function fitCompactFace(font_fam, is_bold, start_pt, min_pt, text, max_w)
    local fam = C.resolveFontFace(font_fam, is_bold)
    local pt = start_pt
    local face = Font:getFace(fam, pt) or Font:getFace("x_smallinfofont", pt)
    if not text or text == "" or not max_w or max_w <= 0 then
        return face
    end
    while pt > min_pt do
        local tw = W.TextWidget:new{ text = text, face = face }
        local tw_w = tw:getSize().w
        if type(tw.free) == "function" then tw:free() end
        if tw_w <= max_w then
            break
        end
        pt = pt - 1
        face = Font:getFace(fam, pt) or face
    end
    return face
end

local function buildCatalogEntries(pfx, _lc)
    local active_ids = CFG.getActiveOrderedStats(pfx)
    local grid_rows  = CFG.getGridRows(pfx)
    local max_slots  = CFG.getGridCols(pfx) * grid_rows
    local active_set = {}
    local list = {}
    for idx, id in ipairs(active_ids) do
        active_set[id] = idx
        list[#list + 1] = {
            kind       = "stat",
            id         = id,
            active     = true,
            active_idx = idx,
            total_act  = #active_ids,
            label      = _lc(CFG.STAT_LABELS[id] or id),
        }
        if grid_rows > 0 and (idx % grid_rows == 0) and (idx <= max_slots) and (idx < #active_ids) then
            list[#list + 1] = { kind = "col_sep" }
        end
    end

    local inactive = {}
    for _, id in ipairs(CFG.DEFAULT_STAT_ORDER) do
        if not active_set[id] and CFG.STAT_LABELS[id] then
            inactive[#inactive + 1] = {
                kind   = "stat",
                id     = id,
                active = false,
                label  = _lc(CFG.STAT_LABELS[id] or id),
            }
        end
    end

    if #inactive > 0 then
        list[#list + 1] = {
            kind  = "divider",
            label = _lc("Inactive"),
        }
        for _, entry in ipairs(inactive) do
            list[#list + 1] = entry
        end
    end

    return list, #active_ids
end

local function paginateEntries(entries, S)
    local pages = {}
    local page = {}
    local used_h = 0
    for _, ent in ipairs(entries) do
        if ent.kind == "col_sep" then
            if used_h > 0 and (used_h + S.col_sep_h) <= S.body_h then
                page[#page + 1] = ent
                used_h = used_h + S.col_sep_h
            end
        else
            local eh = ((ent.kind == "divider") and S.sep_h or S.row_h) + S.div_h
            if used_h > 0 and (used_h + eh) > S.body_h then
                if #page > 0 and page[#page].kind == "col_sep" then
                    table.remove(page)
                end
                pages[#pages + 1] = page
                page = {}
                used_h = 0
            end
            page[#page + 1] = ent
            used_h = used_h + eh
        end
    end
    if #page > 0 and page[#page].kind == "col_sep" then
        table.remove(page)
    end
    if #page > 0 or #pages == 0 then
        pages[#pages + 1] = page
    end
    return pages
end

local function tapArea(hits, widget, action)
    local area = W.FrameContainer:new{
        bordersize = 0,
        margin     = 0,
        padding    = 0,
        [1]        = widget,
    }
    hits[#hits + 1] = { widget = area, action = action }
    return area
end

local function makeArrowButton(S, glyph, enabled)
    local bdr = math.max(1, Size.line.thin or 1)
    local h = math.max(Screen:scaleBySize(22), S.row_h - Screen:scaleBySize(6))
    return W.FrameContainer:new{
        bordersize = bdr,
        margin     = 0,
        padding    = 0,
        radius     = Screen:scaleBySize(4),
        color      = enabled and S.line_c or S.pill_bg,
        background = enabled and S.pill_bg or S.bg_c,
        [1] = W.CenterContainer:new{
            dimen = Geom:new{ w = S.arr_btn_w - (bdr * 2), h = h - (bdr * 2) },
            W.TextWidget:new{
                text    = glyph,
                face    = S.icon_face_arr,
                fgcolor = enabled and S.fg_c or S.line_c,
            },
        },
    }
end

local function buildPanelWidget(S, st)
    local entries, active_cnt = buildCatalogEntries(S.pfx, S._lc)
    local pages = paginateEntries(entries, S)
    st.total_pages = math.max(1, #pages)
    if st.cur_page > st.total_pages then st.cur_page = st.total_pages end
    if st.cur_page < 1 then st.cur_page = 1 end
    local page_items = pages[st.cur_page] or {}

    local hits = {}

    -- 1. Header
    local hdr_label_w = S.content_w - S.hdr_close_w
    local title_tw = W.TextWidget:new{
        text            = S._lc("Statistics"),
        face            = S.face_title,
        fgcolor         = S.fg_c,
        bold            = true,
        max_width       = hdr_label_w - Screen:scaleBySize(4),
        truncation_char = "…",
    }
    local count_txt = string.format("%s: %d / %d", S._lc("Active"), active_cnt, S.max_slots)
    local sub_tw = W.TextWidget:new{
        text    = count_txt,
        face    = fitCompactFace("NotoSans", false, 9, 7, count_txt, hdr_label_w - Screen:scaleBySize(4)),
        fgcolor = (active_cnt > S.max_slots) and S.fg_c or S.dim_c,
    }
    local hdr_left = W.LeftContainer:new{
        dimen = Geom:new{ w = hdr_label_w, h = S.hdr_text_h },
        W.VerticalGroup:new{
            align = "left",
            title_tw,
            W.VerticalSpan:new{ width = Screen:scaleBySize(2) },
            sub_tw,
        },
    }
    local hdr_close = tapArea(hits, W.CenterContainer:new{
        dimen = Geom:new{ w = S.hdr_close_w, h = S.hdr_text_h },
        W.TextWidget:new{
            text    = S.icons.close,
            face    = S.icon_face_hdr,
            fgcolor = S.fg_c,
        },
    }, { kind = "close" })
    local header_box = W.FrameContainer:new{
        bordersize     = 0,
        margin         = 0,
        padding        = 0,
        background     = S.bg_c,
        padding_left   = S.pad_h,
        padding_right  = S.pad_h,
        padding_top    = S.hdr_pad_v,
        padding_bottom = S.hdr_pad_v,
        [1] = W.HorizontalGroup:new{
            align = "center",
            hdr_left,
            hdr_close,
        },
    }

    -- 2. Body rows (explicit zero padding/margin; exact painted .dimen hit targets)
    local body_children = { align = "left" }

    for pi, ent in ipairs(page_items) do
        if ent.kind == "col_sep" then
            body_children[#body_children + 1] = W.FrameContainer:new{
                bordersize     = 0,
                margin         = 0,
                padding        = 0,
                background     = S.bg_c,
                padding_left   = S.pad_h,
                padding_right  = S.pad_h,
                padding_top    = S.col_sep_pad,
                padding_bottom = S.col_sep_pad,
                [1] = W.LineWidget:new{
                    dimen      = Geom:new{ w = S.content_w, h = S.col_sep_line },
                    background = S.dim_c,
                },
            }
        elseif ent.kind == "divider" then
            body_children[#body_children + 1] = W.FrameContainer:new{
                bordersize     = 0,
                margin         = 0,
                padding        = 0,
                background     = S.pill_bg,
                padding_left   = S.pad_h,
                padding_right  = S.pad_h,
                padding_top    = 0,
                padding_bottom = 0,
                [1] = W.LeftContainer:new{
                    dimen = Geom:new{ w = S.content_w, h = S.sep_h },
                    W.TextWidget:new{
                        text    = ent.label,
                        face    = S.face_sec,
                        fgcolor = S.dim_c,
                        bold    = true,
                    },
                },
            }
            body_children[#body_children + 1] = W.LineWidget:new{
                dimen      = Geom:new{ w = S.inner_w, h = S.div_h },
                background = S.line_c,
            }
        else
            local is_overflow = ent.active and (ent.active_idx > S.max_slots)
            local chk_w_wid = W.CenterContainer:new{
                dimen = Geom:new{ w = S.chk_w, h = S.row_h },
                W.TextWidget:new{
                    text    = ent.active and S.icons.check or S.icons.uncheck,
                    face    = S.icon_face_chk,
                    fgcolor = ent.active and S.fg_c or S.dim_c,
                },
            }
            local lbl_box = W.LeftContainer:new{
                dimen = Geom:new{ w = S.lbl_max_w, h = S.row_h },
                W.TextWidget:new{
                    text            = ent.label,
                    face            = fitCompactFace("NotoSans", ent.active, 10, 7, ent.label, S.lbl_max_w),
                    fgcolor         = (ent.active and not is_overflow) and S.fg_c or S.dim_c,
                    bold            = ent.active,
                    max_width       = S.lbl_max_w,
                    truncation_char = "…",
                },
            }

            local toggle_group = W.HorizontalGroup:new{
                align = "center",
                chk_w_wid,
                W.HorizontalSpan:new{ width = S.lbl_gap },
                lbl_box,
            }

            local row_group
            if ent.active then
                local can_up = ent.active_idx > 1
                local can_dn = ent.active_idx < ent.total_act
                local left_tap = tapArea(hits, toggle_group, { kind = "toggle", id = ent.id })
                local up_tap = tapArea(
                    hits,
                    makeArrowButton(S, S.icons.up, can_up),
                    can_up and { kind = "move", active_idx = ent.active_idx, dir = -1 } or { kind = "noop" }
                )
                local dn_tap = tapArea(
                    hits,
                    makeArrowButton(S, S.icons.down, can_dn),
                    can_dn and { kind = "move", active_idx = ent.active_idx, dir = 1 } or { kind = "noop" }
                )
                row_group = W.HorizontalGroup:new{
                    align = "center",
                    left_tap,
                    W.HorizontalSpan:new{ width = S.ctrl_gap },
                    up_tap,
                    W.HorizontalSpan:new{ width = S.arr_gap },
                    dn_tap,
                }
            else
                row_group = tapArea(hits, W.HorizontalGroup:new{
                    align = "center",
                    toggle_group,
                    W.HorizontalSpan:new{ width = S.ctrl_gap + S.arr_total_w },
                }, { kind = "toggle", id = ent.id })
            end

            body_children[#body_children + 1] = W.FrameContainer:new{
                bordersize     = 0,
                margin         = 0,
                padding        = 0,
                background     = S.bg_c,
                padding_left   = S.pad_h,
                padding_right  = S.pad_h,
                padding_top    = 0,
                padding_bottom = 0,
                [1] = row_group,
            }
            local next_ent = page_items[pi + 1]
            if not (next_ent and next_ent.kind == "col_sep") then
                body_children[#body_children + 1] = W.LineWidget:new{
                    dimen      = Geom:new{ w = S.inner_w, h = S.div_h },
                    background = S.line_c,
                }
            end
        end
    end

    local list_vg = W.VerticalGroup:new(body_children)

    -- 3. Footer
    local pager_btn_w = S.pager_btn_w
    local done_w = S.done_w
    local page_ind_w = S.page_ind_w
    local bdr_thin = math.max(1, Size.line.thin or 1)

    local prev_btn = tapArea(hits, W.CenterContainer:new{
        dimen = Geom:new{ w = pager_btn_w, h = S.foot_btn_h },
        W.TextWidget:new{
            text    = S.icons.prev,
            face    = S.icons.use_sui and S.icon_face_arr or S.face_foot,
            fgcolor = (st.cur_page > 1) and S.fg_c or S.line_c,
        },
    }, (st.cur_page > 1) and { kind = "page", delta = -1 } or { kind = "noop" })
    local next_btn = tapArea(hits, W.CenterContainer:new{
        dimen = Geom:new{ w = pager_btn_w, h = S.foot_btn_h },
        W.TextWidget:new{
            text    = S.icons.next,
            face    = S.icons.use_sui and S.icon_face_arr or S.face_foot,
            fgcolor = (st.cur_page < st.total_pages) and S.fg_c or S.line_c,
        },
    }, (st.cur_page < st.total_pages) and { kind = "page", delta = 1 } or { kind = "noop" })
    local pg_lbl = W.CenterContainer:new{
        dimen = Geom:new{ w = page_ind_w, h = S.foot_btn_h },
        W.TextWidget:new{
            text    = string.format("%d/%d", st.cur_page, st.total_pages),
            face    = S.face_sub,
            fgcolor = S.fg_c,
        },
    }
    local done_txt = S._lc("Done")
    local done_btn = tapArea(hits, W.FrameContainer:new{
        bordersize = bdr_thin,
        margin     = 0,
        padding    = 0,
        color      = S.fg_c,
        background = S.pill_bg,
        radius     = Screen:scaleBySize(4),
        [1] = W.CenterContainer:new{
            dimen = Geom:new{ w = done_w - (bdr_thin * 2), h = S.foot_btn_h - (bdr_thin * 2) },
            W.TextWidget:new{
                text            = done_txt,
                face            = fitCompactFace("NotoSans", true, 9, 7, done_txt, done_w - 6),
                fgcolor         = S.fg_c,
                bold            = true,
                max_width       = done_w - 6,
                truncation_char = "…",
            },
        },
    }, { kind = "close" })

    local footer_box = W.FrameContainer:new{
        bordersize     = 0,
        margin         = 0,
        padding        = 0,
        background     = S.bg_c,
        padding_left   = S.pad_h,
        padding_right  = S.pad_h,
        padding_top    = S.foot_pad_v,
        padding_bottom = S.foot_pad_v,
        [1] = W.HorizontalGroup:new{
            align = "center",
            prev_btn,
            pg_lbl,
            next_btn,
            W.HorizontalSpan:new{ width = Screen:scaleBySize(4) },
            done_btn,
        },
    }

    local real_hdr_h  = header_box:getSize().h
    local real_body_h = list_vg:getSize().h
    local real_foot_h = footer_box:getSize().h
    local filler_h    = math.max(0, S.sh - real_hdr_h - S.div_h - real_body_h - S.div_h - real_foot_h)

    local panel_content = W.VerticalGroup:new{
        align = "left",
        header_box,
        W.LineWidget:new{ dimen = Geom:new{ w = S.inner_w, h = S.div_h }, background = S.fg_c },
        list_vg,
        W.VerticalSpan:new{ width = filler_h },
        W.LineWidget:new{ dimen = Geom:new{ w = S.inner_w, h = S.div_h }, background = S.fg_c },
        footer_box,
    }

    local panel_frame = W.HorizontalGroup:new{
        align = "top",
        W.FrameContainer:new{
            bordersize = 0,
            padding    = 0,
            margin     = 0,
            background = S.bg_c,
            dimen      = Geom:new{ w = S.inner_w, h = S.sh },
            [1]        = panel_content,
        },
        W.LineWidget:new{
            dimen      = Geom:new{ w = S.border_w, h = S.sh },
            background = S.fg_c,
        },
    }
    panel_frame.overlap_offset = { 0, 0 }

    return W.OverlapGroup:new{
        dimen = Geom:new{ x = 0, y = 0, w = S.sw, h = S.sh },
        panel_frame,
    }, hits
end

function M.show(opts)
    local pfx = opts.pfx or ""
    local _lc = opts._lc or _

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

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local panel_w = computePanelWidth(pfx, sw)
    local border_w = math.max(1, Size.line.medium or 2)
    local inner_w = panel_w - border_w
    local pad_h = math.max(3, Screen:scaleBySize(5))
    local content_w = inner_w - (pad_h * 2)

    local bg_c, fg_c, dim_c, line_c, pill_bg, icons = getStyleColorsAndIcons()

    local face_title = fitCompactFace("NotoSans", true, 11, 8, _lc("Statistics"), math.floor(content_w * 0.72))
    local face_sub   = Font:getFace(C.resolveFontFace("NotoSans", false), 8) or Font:getFace("x_smallinfofont", 8)
    local face_sec   = Font:getFace(C.resolveFontFace("NotoSans", true), 8)  or Font:getFace("x_smallinfofont", 8)
    local face_foot  = Font:getFace(C.resolveFontFace("NotoSans", true), 10) or Font:getFace("smallinfofont", 10)

    local icon_face_chk = icons.use_sui
        and (Font:getFace(icons.face, 11) or Font:getFace("tfont", 11))
        or  (Font:getFace(C.resolveFontFace("NotoSans", false), 11) or Font:getFace("tfont", 11))
    local icon_face_arr = icons.use_sui
        and (Font:getFace(icons.face, 10) or Font:getFace("tfont", 10))
        or  (Font:getFace(C.resolveFontFace("NotoSans", true), 9) or Font:getFace("x_smallinfofont", 9))
    local icon_face_hdr = icons.use_sui
        and (Font:getFace(icons.face, 11) or Font:getFace("tfont", 11))
        or  (Font:getFace(C.resolveFontFace("NotoSans", true), 11) or Font:getFace("tfont", 11))

    local chk_w = math.max(Screen:scaleBySize(16), 16)
    local arr_btn_w = math.max(Screen:scaleBySize(24), 24)
    local arr_gap = math.max(Screen:scaleBySize(3), 4)
    local arr_total_w = (arr_btn_w * 2) + arr_gap
    local ctrl_gap = math.max(Screen:scaleBySize(4), 4)
    local lbl_gap = math.max(2, Screen:scaleBySize(3))

    local sample_tw = W.TextWidget:new{ text = "Ag", face = Font:getFace(C.resolveFontFace("NotoSans", false), 10) or face_sub }
    local sample_h = sample_tw:getSize().h
    if type(sample_tw.free) == "function" then sample_tw:free() end

    local row_h = math.max(Screen:scaleBySize(30), sample_h + Screen:scaleBySize(14))
    local div_h = math.max(1, Size.line.thin or 1)
    local hdr_pad_v = Screen:scaleBySize(6)
    local hdr_tw = W.TextWidget:new{ text = _lc("Statistics"), face = face_title }
    local hdr_sub_tw = W.TextWidget:new{ text = "0", face = Font:getFace(C.resolveFontFace("NotoSans", false), 9) or face_sub }
    local hdr_text_h = math.max(Screen:scaleBySize(26), hdr_tw:getSize().h + hdr_sub_tw:getSize().h + Screen:scaleBySize(2))
    if type(hdr_tw.free) == "function" then hdr_tw:free() end
    if type(hdr_sub_tw.free) == "function" then hdr_sub_tw:free() end
    local hdr_h = hdr_text_h + (hdr_pad_v * 2)

    local foot_pad_v = Screen:scaleBySize(6)
    local foot_btn_h = math.max(Screen:scaleBySize(28), 28)
    local foot_h = foot_btn_h + (foot_pad_v * 2)
    local pager_btn_w = math.max(Screen:scaleBySize(26), 26)
    local done_w = math.max(Screen:scaleBySize(46), math.floor(content_w * 0.34))

    local S = {
        pfx           = pfx,
        _lc           = _lc,
        sw            = sw,
        sh            = sh,
        panel_w       = panel_w,
        border_w      = border_w,
        inner_w       = inner_w,
        pad_h         = pad_h,
        content_w     = content_w,
        bg_c          = bg_c,
        fg_c          = fg_c,
        dim_c         = dim_c,
        line_c        = line_c,
        pill_bg       = pill_bg,
        icons         = icons,
        face_title    = face_title,
        face_sub      = face_sub,
        face_sec      = face_sec,
        face_foot     = face_foot,
        icon_face_chk = icon_face_chk,
        icon_face_arr = icon_face_arr,
        icon_face_hdr = icon_face_hdr,
        max_slots     = CFG.getGridCols(pfx) * CFG.getGridRows(pfx),
        chk_w         = chk_w,
        arr_btn_w     = arr_btn_w,
        arr_gap       = arr_gap,
        arr_total_w   = arr_total_w,
        ctrl_gap      = ctrl_gap,
        lbl_gap       = lbl_gap,
        lbl_max_w     = math.max(40, content_w - chk_w - lbl_gap - ctrl_gap - arr_total_w),
        row_h         = row_h,
        sep_h         = math.max(Screen:scaleBySize(16), sample_h + Screen:scaleBySize(5)),
        div_h         = div_h,
        col_sep_pad   = math.max(2, Screen:scaleBySize(3)),
        col_sep_line  = math.max(2, Size.line.medium or 2),
        col_sep_h     = math.max(2, Size.line.medium or 2) + (math.max(2, Screen:scaleBySize(3)) * 2),
        hdr_pad_v     = hdr_pad_v,
        hdr_close_w   = math.max(Screen:scaleBySize(28), 28),
        hdr_text_h    = hdr_text_h,
        hdr_h         = hdr_h,
        foot_pad_v    = foot_pad_v,
        foot_btn_h    = foot_btn_h,
        foot_h        = foot_h,
        pager_btn_w   = pager_btn_w,
        done_w        = done_w,
        page_ind_w    = math.max(24, content_w - (pager_btn_w * 2) - done_w - Screen:scaleBySize(4)),
        body_h        = math.max(row_h * 2, sh - hdr_h - div_h - foot_h - div_h),
    }

    local st = {
        cur_page           = 1,
        total_pages        = 1,
        any_height_changed = false,
        closed             = false,
        hits               = {},
        overlay            = nil,
    }

    local function rebuildPanel()
        if st.closed then return end
        local content_widget, new_hits = buildPanelWidget(S, st)
        st.hits = new_hits
        if st.overlay[1] and type(st.overlay[1].free) == "function" then
            st.overlay[1]:free()
        end
        st.overlay[1] = content_widget
        UIManager:setDirty(st.overlay, function()
            return "ui", Geom:new{ x = 0, y = 0, w = S.panel_w + 4, h = S.sh }, true
        end)
    end

    local function applyAndLiveRefresh()
        local _, h_changed = opts.triggerSurgicalPreviewRepaint(false, false)
        if h_changed then
            st.any_height_changed = true
            opts.refreshHomescreenImmediate()
        end
    end

    local function toggleStat(id)
        local active = CFG.getActiveOrderedStats(pfx)
        local found_idx
        for i, v in ipairs(active) do
            if v == id then found_idx = i; break end
        end
        if found_idx then
            table.remove(active, found_idx)
        else
            table.insert(active, id)
        end
        opts.withNoFlush(function()
            CFG.setActiveOrderedStats(pfx, active)
        end)
        applyAndLiveRefresh()
        rebuildPanel()
    end

    local function moveStat(active_idx, dir)
        local active = CFG.getActiveOrderedStats(pfx)
        local target = active_idx + dir
        if target < 1 or target > #active then return end
        active[active_idx], active[target] = active[target], active[active_idx]
        opts.withNoFlush(function()
            CFG.setActiveOrderedStats(pfx, active)
        end)
        applyAndLiveRefresh()
        rebuildPanel()
    end

    local function closeEditor()
        if st.closed then return end
        st.closed = true
        UIManager:close(st.overlay)
        opts.flushSUISettings()
        if st.any_height_changed then
            opts.refreshHomescreenImmediate()
        end
        opts.restoreParentMenus(stashed_sui, stashed_stack)
    end

    local overlay = W.InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
    }
    st.overlay = overlay
    overlay.ges_events = {
        Tap = {
            W.GestureRange:new{
                ges   = "tap",
                range = function() return Geom:new{ x = 0, y = 0, w = sw, h = sh } end,
            },
        },
        Swipe = {
            W.GestureRange:new{
                ges   = "swipe",
                range = function() return Geom:new{ x = 0, y = 0, w = panel_w, h = sh } end,
            },
        },
    }
    if Device:hasKeys() then
        overlay.key_events = { Close = { { "Back" } } }
        function overlay:onClose()
            closeEditor()
            return true
        end
    end

    function overlay:onSwipe(_, ges)
        local dir = ges and ges.direction
        if dir == "west" and st.cur_page < st.total_pages then
            st.cur_page = st.cur_page + 1
            rebuildPanel()
        elseif dir == "east" and st.cur_page > 1 then
            st.cur_page = st.cur_page - 1
            rebuildPanel()
        end
        return true
    end

    function overlay:onTap(_, ges)
        local pos = ges and ges.pos
        if not pos then return true end
        if pos.x > S.panel_w then
            closeEditor()
            return true
        end
        for _, hit in ipairs(st.hits or {}) do
            local d = hit.widget and hit.widget.dimen
            if d and pos:intersectWith(d) then
                local act = hit.action
                if act.kind == "close" then
                    closeEditor()
                elseif act.kind == "page" then
                    local np = st.cur_page + act.delta
                    if np >= 1 and np <= st.total_pages and np ~= st.cur_page then
                        st.cur_page = np
                        rebuildPanel()
                    end
                elseif act.kind == "move" then
                    moveStat(act.active_idx, act.dir)
                elseif act.kind == "toggle" then
                    toggleStat(act.id)
                end
                return true
            end
        end
        return true
    end

    rebuildPanel()
    UIManager:show(overlay)
    return overlay
end

return M
