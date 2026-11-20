-- currently_books_stat.lua
-- Custom popup for Currently Reading statistics

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Widget          = require("ui/widget/widget")
local Button          = require("ui/widget/button")
local ImageWidget     = require("ui/widget/imagewidget")
local DataStorage     = require("datastorage")
if DataStorage and not DataStorage.getPatchesDir then
    function DataStorage:getPatchesDir()
        return self:getDataDir() .. "/patches"
    end
end
local Screen          = Device.screen

local function getSUIModule(short_name, default_folder)
    local folders = {}
    if default_folder then table.insert(folders, default_folder) end
    for _, f in ipairs({"engines", "features", "screens", "infra", "modules"}) do
        if f ~= default_folder then table.insert(folders, f) end
    end

    if default_folder and package.loaded[default_folder .. "/" .. short_name] then
        return package.loaded[default_folder .. "/" .. short_name]
    end
    if package.loaded[short_name] then
        return package.loaded[short_name]
    end
    for _, f in ipairs(folders) do
        if package.loaded[f .. "/" .. short_name] then
            return package.loaded[f .. "/" .. short_name]
        end
    end

    for _, f in ipairs(folders) do
        local ok, m = pcall(require, f .. "/" .. short_name)
        if ok and m then
            package.loaded[f .. "/" .. short_name] = m
            package.loaded[short_name] = m
            return m
        end
    end

    local ok, m = pcall(require, short_name)
    if ok and m then
        package.loaded[short_name] = m
        return m
    end

    return nil
end

local _ = (function()
    local ok_p, pi = pcall(require, "infra/plus_i18n")
    if ok_p and pi and type(pi.translate) == "function" then
        return pi.translate
    end
    return function(s) return s end
end)()

local Config = getSUIModule("sui_config", "infra")

local SUIStyle = getSUIModule("sui_style", "features")
if SUIStyle then
    if type(SUIStyle.getThemeColor) ~= "function" then
        SUIStyle.getThemeColor = function(_) return nil end
    end
    if type(SUIStyle.icon) ~= "function" then
        local icons_fallback = {
            chevron     = "\u{F105}",
            chevron_left= "\u{F104}",
            clock       = "\u{E385}",
            page        = "\u{F40E}",
            highlights  = "\u{EE6B}",
            notes       = "\u{EAEC}",
            arrow_right = "\u{F178}",
        }
        SUIStyle.icon = function(name)
            return (SUIStyle.ICON and SUIStyle.ICON[name]) or icons_fallback[name] or ""
        end
    end
    SUIStyle.BORDER_SZ    = SUIStyle.BORDER_SZ or math.max(1, Screen:scaleBySize(1))
    SUIStyle.FS_TITLE     = SUIStyle.FS_TITLE or 22
    SUIStyle.FS_SUBTITLE  = SUIStyle.FS_SUBTITLE or 20
    SUIStyle.FS_BODY      = SUIStyle.FS_BODY or 18
    SUIStyle.FS_DETAIL    = SUIStyle.FS_DETAIL or 15
    SUIStyle.FACE_REGULAR = SUIStyle.FACE_REGULAR or "cfont"
    SUIStyle.FACE_ICONS   = SUIStyle.FACE_ICONS or "symbols"
end

local Size = require("ui/size")

local CBS = {
    id              = "currently_books_stat",
    default_enabled = true,
    enabled_key     = "currently_books_stat",
    is_popup        = true,
}

function CBS.refreshTranslations()
    CBS.name        = _("Book Statistics Window")
    CBS.description = _("Detailed reading statistics and time-of-day distribution window opened by tapping the progress rings or bars.")
    CBS.how_to_use  = _("User Guide & Features:\n• How to Open: Tap the progress rings or bars on the right side of the Currently Reading card.\n• Analytics: View total reading time, active days, pages read percentage, reading speed, and time-of-day distribution (morning, afternoon, evening, night).\n• Browse Books: Use the left/right arrows to browse statistics for previously read books.\n• Quick Shortcuts: Tap 'Finished Books' or 'All Statistics' at the bottom for detailed views.")
end
CBS.refreshTranslations()

function CBS.isEnabled()
    local SUIStore = getSUIModule("sui_store", "infra")
    if SUIStore then
        local v = SUIStore:readSetting("sui_plus_mod_currently_books_stat")
        if v ~= nil then return v == true end
        v = SUIStore:readSetting("currently_books_stat")
        if v ~= nil then return v == true end
    end

    local ok_ds, DS = pcall(require, "datastorage")
    local ok_ls, LS = pcall(require, "luasettings")
    if ok_ds and ok_ls and DS and LS then
        local p = DS:getSettingsDir() .. "/simpleui_plus.lua"
        local s = LS:open(p)
        if s then
            local states = s:readSetting("module_states")
            if states and states["currently_books_stat"] ~= nil then
                return states["currently_books_stat"] == true
            end
        end
    end

    return true
end

function CBS.setEnabled(pfx, is_active)
    pfx = pfx or "simpleui_hs_"
    local SUIStore = getSUIModule("sui_store", "infra")
    if SUIStore then
        SUIStore:saveSetting(pfx .. CBS.enabled_key, is_active == true)
        SUIStore:saveSetting("sui_plus_mod_" .. CBS.id, is_active == true)
    end
end

local function _fmtDuration(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0s" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    if h > 0 then
        return string.format("%dh %02dm", h, m)
    elseif m > 0 then
        return string.format("%dm %02ds", m, s)
    else
        return string.format("%ds", s)
    end
end

local function _fmtDate(ts)
    if not ts or ts == 0 then return "-" end
    return os.date("%d-%m-%Y", ts)
end

local function _fetchBookStatsData(fp, md5)
    if not fp then return nil, _("No filepath.") end

    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 or not SQ3 then
        return nil, _("Statistics database library not available.")
    end
    local db_path = (Config and Config.getStatsDbPath and Config.getStatsDbPath())
    if not db_path then
        db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and not lfs.attributes(db_path, "mode") then
        return nil, _("No statistics found for this book.")
    end

    -- Flush active reading session to DB if book is currently open in ReaderUI
    pcall(function()
        local ReaderUI = package.loaded["apps/reader/readerui"]
        if ReaderUI and ReaderUI.instance and ReaderUI.instance.statistics then
            ReaderUI.instance.statistics:insertDB()
        end
    end)

    local ok_conn, conn = pcall(SQ3.open, db_path)
    if not ok_conn or not conn then
        return nil, _("Could not open statistics database.")
    end

    if not md5 and fp then
        pcall(function()
            local DocSettings = package.loaded["docsettings"] or require("docsettings")
            if DocSettings then
                local ds = DocSettings:open(fp)
                if ds then
                    md5 = ds:readSetting("partial_md5_checksum")
                    pcall(function() ds:close() end)
                end
            end
        end)
        if not md5 then
            local ok_util, util = pcall(require, "util")
            if ok_util and util and util.partialMD5 then
                md5 = util.partialMD5(fp)
            end
        end
    end

    local id_book
    if md5 then
        local ok_q, row = pcall(function()
            return conn:rowexec(string.format("SELECT id FROM book WHERE md5 = '%s' ORDER BY last_open DESC LIMIT 1", md5))
        end)
        if ok_q then id_book = row and tonumber(row) or nil end
    end
    if not id_book then
        pcall(function() conn:close() end)
        return nil, _("No statistics found for this book.")
    end

    local title, authors, pages, last_open, highlights, notes, b_total_read_time, b_total_read_pages
    pcall(function()
        title, authors, pages, last_open, highlights, notes, b_total_read_time, b_total_read_pages = conn:rowexec(
            string.format([[
                SELECT title, authors, pages, last_open, highlights, notes, total_read_time, total_read_pages
                FROM book WHERE id = %d
            ]], id_book))
    end)
    highlights = tonumber(highlights) or 0
    notes      = tonumber(notes)      or 0

    local MAX_SEC = 120
    pcall(function()
        local stat_settings = G_reader_settings and G_reader_settings:readSetting("statistics")
        if type(stat_settings) == "table" and stat_settings.max_sec then
            MAX_SEC = tonumber(stat_settings.max_sec) or 120
        else
            local v = G_reader_settings and G_reader_settings:readSetting("statistics_max_sec")
            if v and tonumber(v) then MAX_SEC = tonumber(v) end
        end
    end)

    local _ps_table = "page_stat_data"
    local ok_check = pcall(function() conn:rowexec("SELECT 1 FROM page_stat_data LIMIT 1") end)
    if not ok_check then _ps_table = "page_stat" end

    -- Accurate Uncapped Total Duration & Unique Pages Read
    local total_time_book, total_read_pages
    pcall(function()
        total_time_book, total_read_pages = conn:rowexec(
            string.format([[
                SELECT COALESCE(SUM(duration), 0), COUNT(DISTINCT page)
                FROM %s WHERE id_book = %d
            ]], _ps_table, id_book))
    end)
    total_time_book = tonumber(total_time_book) or tonumber(b_total_read_time) or 0
    total_read_pages = tonumber(total_read_pages) or tonumber(b_total_read_pages) or 0

    -- Accurate Total Reading Days (distinct calendar dates in local time)
    local total_days = 0
    pcall(function()
        local ndays = conn:rowexec(string.format([[
            SELECT count(*) FROM (
                SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS d
                FROM %s WHERE id_book = %d GROUP BY d
            )
        ]], _ps_table, id_book))
        total_days = ndays and tonumber(ndays) or 0
    end)

    -- Capped Duration for Average-Time-Per-Page (matches KOReader Statistics logic)
    local capped_pages, capped_time
    pcall(function()
        capped_pages, capped_time = conn:rowexec(
            string.format([[
                WITH ps_agg AS (
                    SELECT page, sum(duration) AS page_dur
                    FROM %s WHERE id_book = %d GROUP BY page
                )
                SELECT count(*), sum(min(page_dur, %d)) FROM ps_agg
            ]], _ps_table, id_book, MAX_SEC))
    end)
    capped_pages = tonumber(capped_pages) or 0
    capped_time  = tonumber(capped_time)  or 0
    local book_read_time = capped_time

    local first_open, last_page
    pcall(function()
        first_open, last_page = conn:rowexec(
            string.format([[
                SELECT min(start_time),
                       (SELECT max(ps2.page) FROM %s AS ps2
                        WHERE ps2.id_book = %d AND ps2.start_time = max(%s.start_time))
                FROM %s WHERE id_book = %d
            ]], _ps_table, id_book, _ps_table, _ps_table, id_book))
    end)

    -- Time of Day Distribution (Uncapped, accurate grouped by hour)
    local tod = { morning = 0, afternoon = 0, evening = 0, night = 0, total = 0 }
    pcall(function()
        local rows = conn:exec(string.format([[
            SELECT
                CAST(strftime('%%H', start_time, 'unixepoch', 'localtime') AS INTEGER) AS hour,
                sum(duration) AS dur
            FROM %s
            WHERE id_book = %d
            GROUP BY hour
        ]], _ps_table, id_book))

        if rows and rows[1] then
            local hours = rows[1]
            local durs  = rows[2]

            for i = 1, #hours do
                local h   = tonumber(hours[i]) or 0
                local dur = tonumber(durs[i])  or 0
                if h >= 5 and h <= 11 then
                    tod.morning   = tod.morning   + dur
                elseif h >= 12 and h <= 16 then
                    tod.afternoon = tod.afternoon + dur
                elseif h >= 17 and h <= 20 then
                    tod.evening   = tod.evening   + dur
                else
                    tod.night     = tod.night     + dur
                end
                tod.total = tod.total + dur
            end
        end
    end)

    pcall(function() conn:close() end)

    local now_ts = os.time()
    total_days       = tonumber(total_days)       or 0
    total_time_book  = tonumber(total_time_book)  or 0
    total_read_pages = tonumber(total_read_pages) or 0
    local book_read_pages = total_read_pages
    book_read_time   = tonumber(book_read_time)   or 0
    first_open       = tonumber(first_open)        or now_ts
    last_open        = tonumber(last_open)         or now_ts
    last_page        = tonumber(last_page)         or 0
    pages            = tonumber(pages)
    if not pages or pages == 0 then pages = 1 end

    local avg_time_per_page = (capped_pages > 0 and capped_time > 0) and (capped_time / capped_pages) or 0
    local avg_time_per_day  = (total_days > 0 and total_time_book > 0) and (total_time_book / total_days) or 0

    return {
        title            = title   or "",
        authors          = authors or "",
        pages            = pages,
        last_open        = last_open,
        first_open       = first_open,
        last_page        = last_page,
        total_time_book  = total_time_book,
        book_read_time   = book_read_time,
        book_read_pages  = book_read_pages,
        total_read_pages = total_read_pages,
        total_days       = total_days,
        avg_time_per_page= avg_time_per_page,
        avg_time_per_day = avg_time_per_day,
        highlights       = highlights,
        notes            = notes,
        tod              = tod
    }
end

local function makeHBar(lbl, pct_str, val, pct, max_w, bar_h, face_l, face_r, clr_fg, clr_bg, lbl_w, pct_w_spc, val_w)
    local pct_w = math.floor(pct * max_w)
    local r = math.floor(bar_h / 2)
    local bar_bg_fc = FrameContainer:new{
        bordersize = SUIStyle.BORDER_SZ or 1, margin = 0, padding = 0, radius = r, color = Blitbuffer.COLOR_BLACK, background = Blitbuffer.COLOR_WHITE,
        Widget:new{ dimen = Geom:new{ w = max_w - 2, h = bar_h - 2 } }
    }
    local bar_fg_fc = FrameContainer:new{
        bordersize = 0, margin = 0, padding = 0, radius = r, background = clr_fg,
        Widget:new{ dimen = Geom:new{ w = pct_w > 0 and pct_w or 1, h = bar_h } }
    }
    local bar = OverlapGroup:new{
        dimen = Geom:new{ w = max_w, h = bar_h },
        bar_bg_fc,
        bar_fg_fc,
    }
    local lbl_widget
    if type(lbl) == "table" then
        lbl_widget = lbl
    else
        lbl_widget = TextWidget:new{ text = lbl, face = face_l, fgcolor = Blitbuffer.COLOR_BLACK, alignment = "left" }
    end
    return HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = lbl_w, h = face_l.size * 1.5 }, lbl_widget },
        CenterContainer:new{ dimen = Geom:new{ w = pct_w_spc, h = face_l.size * 1.5 }, TextWidget:new{ text = pct_str, face = face_l, fgcolor = Blitbuffer.COLOR_BLACK, alignment = "center" } },
        CenterContainer:new{ dimen = Geom:new{ w = max_w, h = face_r.size * 1.5 }, [1] = bar },
        RightContainer:new{ dimen = Geom:new{ w = val_w, h = face_r.size * 1.5 }, TextWidget:new{ text = val, face = face_r, fgcolor = Blitbuffer.COLOR_BLACK, alignment = "right" } },
    }
end

function CBS.showBookStatsWindow(fp, md5, ui_context)
    local d, err = _fetchBookStatsData(fp, md5)
    if not d then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = err or _("Unknown error.") })
        return
    end

    local SUIWindow = getSUIModule("sui_window", "engines")
    if not SUIWindow then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = _("Window system not available.") })
        return
    end
    
    local my_win
    
    local clean_fps = {}
    local seen_fps = {}
    local ok_rh, rh = pcall(require, "readhistory")
    if ok_rh and rh and type(rh.hist) == "table" then
        for _idx, v in ipairs(rh.hist) do
            if type(v) == "table" and v.file and not v.dim then
                if not seen_fps[v.file] then
                    table.insert(clean_fps, v.file)
                    seen_fps[v.file] = true
                end
            end
        end
    end
    local cur_idx = 1
    for i, f in ipairs(clean_fps) do
        if f == fp then cur_idx = i; break end
    end
    if clean_fps[cur_idx] ~= fp then
        table.insert(clean_fps, 1, fp)
        cur_idx = 1
    end

    local function buildStatsScreen(ctx)
        local inner_w = ctx.inner_w
        
        local CLR_BORDER = Blitbuffer.gray(0.72)
        local CLR_BLACK  = Blitbuffer.COLOR_BLACK
        local CLR_GRAY   = Blitbuffer.gray(0.50)
        local PAD_H      = Size.padding.large
        local ROW_H      = Screen:scaleBySize(42)
        local ICON_FS    = SUIStyle.FS_BODY

        local face_title  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_SUBTITLE)
        local face_author = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
        local face_val    = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
        local face_lbl    = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL)
        
        local text_max_w  = inner_w - 2 * PAD_H
        local card_gap = Screen:scaleBySize(10)
        local col_w    = math.floor((inner_w - 2 * card_gap) / 3)

        local pages_read_str = string.format("%d (%d%%)",
            d.total_read_pages,
            math.floor(100 * d.total_read_pages / (d.pages > 0 and d.pages or 1) + 0.5))

        local lbl_h = math.floor(face_lbl.size * 1.2)
        local val_h = face_val.size
        local cell_v_pad = Screen:scaleBySize(6)
        local cell_h = cell_v_pad * 2 + val_h + Screen:scaleBySize(2) + lbl_h

        local function makeTopCell(value, label, w)
            local vg = VerticalGroup:new{
                align = "center",
                TextWidget:new{ text = tostring(value), face = face_val, bold = true, fgcolor = CLR_BLACK, alignment = "center" },
                VerticalSpan:new{ width = Screen:scaleBySize(2) },
                TextWidget:new{ text = label, face = face_lbl, fgcolor = CLR_GRAY, alignment = "center" },
            }
            return FrameContainer:new{
                bordersize = SUIStyle.BORDER_SZ, color = CLR_BORDER,
                radius = Screen:scaleBySize(12), padding = 0, margin = 0,
                CenterContainer:new{ dimen = Geom:new{ w = w - 2*SUIStyle.BORDER_SZ, h = cell_h }, [1] = vg },
            }
        end

        local metrics_row = HorizontalGroup:new{
            makeTopCell(_fmtDuration(d.total_time_book), _("Total"),   col_w),
            HorizontalSpan:new{ width = card_gap },
            makeTopCell(tostring(d.total_days),           _("Days"),    col_w),
            HorizontalSpan:new{ width = card_gap },
            makeTopCell(pages_read_str,                   _("Pages"),   col_w),
        }

        local nav_group
        if #clean_fps > 1 then
            local arrow_w = Screen:scaleBySize(52)
            local arrow_h = Screen:scaleBySize(64)
            local nav_text_max_w = text_max_w - 2 * arrow_w - Screen:scaleBySize(16)
            
            local face_arrow = Font:getFace(SUIStyle.FACE_ICONS, (SUIStyle and SUIStyle.FS_ICON) or 28)
            
            local function findNextValidFp(start_idx, direction)
                local idx = start_idx
                for i = 1, #clean_fps do
                    idx = idx + direction
                    if idx < 1 then idx = #clean_fps end
                    if idx > #clean_fps then idx = 1 end
                    
                    local d_test = _fetchBookStatsData(clean_fps[idx], nil)
                    if d_test then return idx end
                end
                return nil
            end

            local function switchToBook(next_idx)
                if not next_idx or next_idx == cur_idx then return end
                local next_fp = clean_fps[next_idx]
                local new_d = _fetchBookStatsData(next_fp, nil)
                if new_d then
                    cur_idx = next_idx
                    fp = next_fp
                    d = new_d
                    if my_win then
                        my_win._current_page = 1
                        my_win:repaint()
                    end
                end
            end
            
            local left_icon_glyph = (SUIStyle and SUIStyle.icon and SUIStyle.icon("chevron_left")) or "\u{F104}"
            local left_btn = InputContainer:new{
                dimen = Geom:new{ w = arrow_w, h = arrow_h },
                CenterContainer:new{ dimen = Geom:new{ w = arrow_w, h = arrow_h }, TextWidget:new{ text = left_icon_glyph, face = face_arrow, fgcolor = CLR_BLACK } }
            }
            left_btn.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = function() return left_btn.dimen end } } }
            function left_btn:onTap()
                local next_idx = findNextValidFp(cur_idx, 1)
                switchToBook(next_idx)
                return true
            end
            
            local right_icon_glyph = (SUIStyle and SUIStyle.icon and SUIStyle.icon("chevron")) or "\u{F105}"
            local right_btn = InputContainer:new{
                dimen = Geom:new{ w = arrow_w, h = arrow_h },
                CenterContainer:new{ dimen = Geom:new{ w = arrow_w, h = arrow_h }, TextWidget:new{ text = right_icon_glyph, face = face_arrow, fgcolor = CLR_BLACK } }
            }
            right_btn.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = function() return right_btn.dimen end } } }
            function right_btn:onTap()
                local next_idx = findNextValidFp(cur_idx, -1)
                switchToBook(next_idx)
                return true
            end
            
            local title_author_group = VerticalGroup:new{
                align = "center",
                VerticalSpan:new{ width = Screen:scaleBySize(8) },
                TextBoxWidget:new{ text = d.title, face = face_title, bold = true, fgcolor = CLR_BLACK, width = nav_text_max_w, alignment = "center", max_lines = 2 },
                VerticalSpan:new{ width = Screen:scaleBySize(2) },
                TextWidget:new{ text = d.authors or "", face = face_author, fgcolor = CLR_BLACK, max_width = nav_text_max_w },
                VerticalSpan:new{ width = Screen:scaleBySize(8) },
            }
            
            nav_group = HorizontalGroup:new{
                align = "center",
                left_btn,
                CenterContainer:new{ dimen = Geom:new{ w = nav_text_max_w + Screen:scaleBySize(16) }, [1] = title_author_group },
                right_btn
            }
        else
            nav_group = VerticalGroup:new{
                align = "center",
                VerticalSpan:new{ width = Screen:scaleBySize(8) },
                TextBoxWidget:new{ text = d.title, face = face_title, bold = true, fgcolor = CLR_BLACK, width = text_max_w, alignment = "center", max_lines = 2 },
                VerticalSpan:new{ width = Screen:scaleBySize(2) },
                TextWidget:new{ text = d.authors or "", face = face_author, fgcolor = CLR_BLACK, max_width = text_max_w },
                VerticalSpan:new{ width = Screen:scaleBySize(8) },
            }
        end

        local top_card = FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0,
            VerticalGroup:new{ align = "center", nav_group, VerticalSpan:new{ width = Screen:scaleBySize(8) }, metrics_row }
        }

        -- TOD Card
        local tod = d.tod
        local total_tod = math.max(1, tod.total)
        local CLR_MORN = Blitbuffer.COLOR_YELLOW or Blitbuffer.gray(0.2)
        local CLR_AFT  = Blitbuffer.COLOR_ORANGE or Blitbuffer.gray(0.4)
        local CLR_EVE  = Blitbuffer.COLOR_BLUE or Blitbuffer.gray(0.6)
        local CLR_NGHT = Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.gray(0.8)

        local tod_items = {
            { _("Morning"),   tod.morning,   CLR_MORN },
            { _("Afternoon"), tod.afternoon, CLR_AFT  },
            { _("Evening"),   tod.evening,   CLR_EVE  },
            { _("Night"),     tod.night,     CLR_NGHT },
        }
        local lbl_w_tod = Screen:scaleBySize(60) -- Reduced slightly since no icon
        local pct_w_spc = Screen:scaleBySize(45)
        local val_w_tod = Screen:scaleBySize(80)
        local bar_w_tod = (inner_w - 2 * PAD_H) - lbl_w_tod - pct_w_spc - val_w_tod
        local bar_h_tod = Screen:scaleBySize(8)
        local tod_vg = VerticalGroup:new{ align = "left" }
        table.insert(tod_vg, VerticalSpan:new{ height = Size.padding.default })
        for _idx, item in ipairs(tod_items) do
            local pct_t = item[2] / total_tod
            local pct_str = string.format("%%%d", math.floor(pct_t * 100))
            table.insert(tod_vg, makeHBar(item[1], pct_str, _fmtDuration(item[2]), pct_t, bar_w_tod, bar_h_tod, face_lbl, face_lbl, Blitbuffer.COLOR_BLACK, Blitbuffer.gray(0.85), lbl_w_tod, pct_w_spc, val_w_tod))
            table.insert(tod_vg, VerticalSpan:new{ height = Size.padding.small })
        end

        local tod_card = FrameContainer:new{
            bordersize = SUIStyle.BORDER_SZ, color = CLR_BORDER, radius = Screen:scaleBySize(12), padding = Screen:scaleBySize(8),
            VerticalGroup:new{ align = "center",
                TextWidget:new{ text = _("Reading Time Distribution"), face = face_author, bold = true, fgcolor = CLR_BLACK },
                tod_vg
            }
        }

        -- Icon Rows
        local icon_face  = Font:getFace(SUIStyle.FACE_ICONS,   ICON_FS)
        local lbl_face   = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
        local val_face   = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
        local ICON_W     = Screen:scaleBySize(36)
        local row_inner  = inner_w - 2 * PAD_H

        local function makeIconRow(icon_glyph, label, value_str, on_tap)
            local val_w = Screen:scaleBySize(160)
            local lbl_w = row_inner - ICON_W - val_w
            local row_ui = FrameContainer:new{
                bordersize = 0, padding = 0, padding_left = PAD_H, padding_right = PAD_H, dimen = Geom:new{ w = inner_w, h = ROW_H },
                HorizontalGroup:new{ align = "center",
                    CenterContainer:new{ dimen = Geom:new{ w = ICON_W, h = ROW_H }, TextWidget:new{ text = icon_glyph, face = icon_face, fgcolor = CLR_BLACK } },
                    LeftContainer:new{ dimen = Geom:new{ w = lbl_w, h = ROW_H }, TextWidget:new{ text = label, face = lbl_face, fgcolor = CLR_BLACK, max_width = lbl_w } },
                    RightContainer:new{ dimen = Geom:new{ w = val_w, h = ROW_H }, TextWidget:new{ text = tostring(value_str), face = val_face, bold = true, fgcolor = CLR_BLACK, max_width = val_w } },
                }
            }
            if on_tap then
                local ic = InputContainer:new{ dimen = Geom:new{ w = inner_w, h = ROW_H }, row_ui }
                ic.ges_events = {
                    Tap = { GestureRange:new{ ges = "tap", range = function() return ic.dimen end } }
                }
                function ic:onTap() on_tap(); return true end
                return ic
            end
            return row_ui
        end
        local function makeRowSep()
            return FrameContainer:new{ bordersize = 0, padding = 0, padding_left = PAD_H, padding_right = PAD_H, LineWidget:new{ dimen = Geom:new{ w = row_inner, h = SUIStyle.BORDER_SZ }, background = CLR_BORDER } }
        end

        local on_tap_highlights, on_tap_notes
        if fp and (d.highlights > 0 or d.notes > 0) then
            local function openBrowser()
                if my_win then my_win:close() end
                local BookmarkBrowser = require("ui/widget/bookmarkbrowser")
                if not ui_context then
                    -- Fallback in case ui_context is missing
                    local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
                    if ok_rui and ReaderUI and ReaderUI.instance then
                        ui_context = ReaderUI.instance
                    else
                        local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
                        ui_context = FM and FM.instance or {}
                        if not ui_context.openFile then
                            ui_context.openFile = function(self, f)
                                local Event = require("ui/event")
                                UIManager:broadcastEvent(Event:new("SetupShowReader"))
                                UIManager:broadcastEvent(Event:new("SetupOpenFile", f))
                            end
                        end
                    end
                    if ui_context and not ui_context.bookinfo then
                        local ok_bi, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
                        if ok_bi and BookInfo then
                            ui_context.bookinfo = BookInfo
                        end
                    end
                end
                BookmarkBrowser:show({ [fp] = true }, ui_context)
            end
            if d.highlights > 0 then on_tap_highlights = openBrowser end
            if d.notes > 0 then on_tap_notes = openBrowser end
        end

        local btn_w1 = math.floor((inner_w - card_gap) / 2)
        local btn_w2 = inner_w - btn_w1 - card_gap

        local function _ensureStyleThemeSafe()
            local _VARIANT_FLAGS = {
                regular    = { bold = false, italic = false },
                bold       = { bold = true,  italic = false },
                italic     = { bold = false, italic = true  },
                bolditalic = { bold = true,  italic = true  },
            }
            local function patchStyle(st)
                if type(st) ~= "table" then return end
                if not st.VARIANTS then st.VARIANTS = { "regular", "bold", "italic", "bolditalic" } end
                if type(st.isVariant) ~= "function" then
                    st.isVariant = function(v) return _VARIANT_FLAGS[v] and true or false end
                end
                if type(st.emphasize) ~= "function" then
                    st.emphasize = function(v)
                        local flags = _VARIANT_FLAGS[v] or _VARIANT_FLAGS.regular
                        return flags.italic and "bolditalic" or "bold"
                    end
                end
                if type(st.getThemeColor) ~= "function" then
                    st.getThemeColor = function(_) return nil end
                end
                if type(st.setThemeColor) ~= "function" then st.setThemeColor = function(_) end end
                if type(st.resetTheme) ~= "function" then st.resetTheme = function() end end
                if type(st.makeThemeMenuItems) ~= "function" then st.makeThemeMenuItems = function() return {} end end
            end

            local st = getSUIModule("sui_style", "features")
            if st then patchStyle(st) end
            for _, mod_name in ipairs({"sui_style", "features/sui_style", "infra/sui_style"}) do
                if package.loaded[mod_name] then
                    patchStyle(package.loaded[mod_name])
                end
            end
        end

        local finished_stats_btn = Button:new{
            text = _("Finished Books"),
            callback = function()
                local UIManager = require("ui/uimanager")
                UIManager:nextTick(function()
                    _ensureStyleThemeSafe()
                    if my_win then my_win:close() end
                    local SUIStats = getSUIModule("sui_stats_windows", "screens")
                    if SUIStats and SUIStats.showFinishedBooksDialog then
                        SUIStats.showFinishedBooksDialog()
                    end
                end)
            end,
            width = btn_w1,
            bordersize = 0, margin = 0, padding = Screen:scaleBySize(10),
            radius = Screen:scaleBySize(12),
            background = Blitbuffer.gray(0.1),
        }

        local all_stats_btn = Button:new{
            text = _("All Statistics"),
            callback = function()
                local UIManager = require("ui/uimanager")
                UIManager:nextTick(function()
                    _ensureStyleThemeSafe()
                    if my_win then my_win:close() end
                    local SUIStats = getSUIModule("sui_stats_windows", "screens")
                    if SUIStats and SUIStats.showReadingInsightsWindow then
                        SUIStats.showReadingInsightsWindow()
                    end
                end)
            end,
            width = btn_w2,
            bordersize = 0, margin = 0, padding = Screen:scaleBySize(10),
            radius = Screen:scaleBySize(12),
            background = Blitbuffer.gray(0.1),
        }

        local buttons_row = HorizontalGroup:new{
            align = "center",
            finished_stats_btn,
            HorizontalSpan:new{ width = card_gap },
            all_stats_btn
        }

        local rows_block = FrameContainer:new{
            bordersize = SUIStyle.BORDER_SZ, color = CLR_BORDER, radius = Screen:scaleBySize(12), padding = 0,
            VerticalGroup:new{ align = "left",
                makeIconRow(SUIStyle.icon("clock"), _("Average per day"),  _fmtDuration(d.avg_time_per_day)),
                makeRowSep(),
                makeIconRow(SUIStyle.icon("page"),  _("Average per page"), _fmtDuration(d.avg_time_per_page)),
                makeRowSep(),
                makeIconRow(SUIStyle.icon("highlights"), _("Highlights"),  tostring(d.highlights), on_tap_highlights),
                makeRowSep(),
                makeIconRow(SUIStyle.icon("notes"),      _("Notes"),       tostring(d.notes), on_tap_notes),
            }
        }

        -- Date range
        local face_date  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
        local face_arrow = Font:getFace(SUIStyle.FACE_ICONS, SUIStyle.FS_BODY)
        local date_inner = inner_w - 2 * PAD_H
        local date_third = math.floor(date_inner / 3)
        local date_row_h = Screen:scaleBySize(24)

        local date_card = FrameContainer:new{
            bordersize = 0, radius = Screen:scaleBySize(12), background = Blitbuffer.gray(0.08),
            padding_top = Screen:scaleBySize(8), padding_bottom = Screen:scaleBySize(8), padding_left = PAD_H, padding_right = PAD_H,
            HorizontalGroup:new{ align = "center",
                CenterContainer:new{ dimen = Geom:new{ w = date_third, h = date_row_h }, TextWidget:new{ text = _fmtDate(d.first_open), face = face_date, fgcolor = CLR_BLACK } },
                CenterContainer:new{ dimen = Geom:new{ w = date_inner - 2 * date_third, h = date_row_h }, TextWidget:new{ text = SUIStyle.icon("arrow_right"), face = face_arrow, fgcolor = CLR_BLACK } },
                CenterContainer:new{ dimen = Geom:new{ w = date_third, h = date_row_h }, TextWidget:new{ text = d.last_open and _fmtDate(d.last_open) or "-", face = face_date, fgcolor = CLR_BLACK } },
            }
        }

        local block_gap = VerticalSpan:new{ width = Screen:scaleBySize(4) }
        return { top_card, block_gap, tod_card, block_gap, rows_block, block_gap, date_card, block_gap, buttons_row }
    end

    my_win = SUIWindow:new{
        title = _("Book Statistics"),
        height = math.floor(Screen:getHeight() * 0.96),
        position = "bottom",
        navpager_mode = Config.isNavpagerEnabled and Config.isNavpagerEnabled() or false,
        screens = {
            __root__ = buildStatsScreen
        },
    }
    my_win:show()
end

return CBS
