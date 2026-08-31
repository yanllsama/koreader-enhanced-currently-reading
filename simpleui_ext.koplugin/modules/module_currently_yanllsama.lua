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
local _       = (package.loaded["sui_i18n"] or package.loaded["infra/sui_i18n"] or (function() local ok, m = pcall(require, "infra/sui_i18n"); return ok and m or require("sui_i18n") end)()).translate
local N_      = (package.loaded["sui_i18n"] or package.loaded["infra/sui_i18n"] or (function() local ok, m = pcall(require, "infra/sui_i18n"); return ok and m or require("sui_i18n") end)()).ngettext
local logger  = require("logger")

local Blitbuffer      = require("ffi/blitbuffer")
local DataStorage     = require("datastorage")
local Font            = require("ui/font")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local UIManager       = require("ui/uimanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Math            = require("optmath")
local Size            = require("ui/size")
local util            = require("util")

local Config       = package.loaded["sui_config"] or package.loaded["infra/sui_config"] or (function() local ok, m = pcall(require, "infra/sui_config"); return ok and m or require("sui_config") end)()
local UI           = package.loaded["sui_core"] or package.loaded["infra/sui_core"] or (function() local ok, m = pcall(require, "infra/sui_core"); return ok and m or require("sui_core") end)()
local SUISettings  = package.loaded["sui_store"] or package.loaded["infra/sui_store"] or (function() local ok, m = pcall(require, "infra/sui_store"); return ok and m or require("sui_store") end)()
local PAD          = UI.PAD
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "modules/module_books_shared")
        if not ok or not m then
            ok, m = pcall(require, "desktop_modules/module_books_shared")
        end
        if ok and m then _SH = m else logger.warn("simpleui: cannot load module_books_shared") end
    end
    return _SH
end

local _SUIStyle = nil
local function getSUIStyle()
    if not _SUIStyle then
        local ok, m = pcall(require, "features/sui_style")
        if not ok or not m then
            ok, m = pcall(require, "sui_style")
        end
        if ok and m then _SUIStyle = m end
    end
    return _SUIStyle
end

local _CLR_DARK   = Blitbuffer.COLOR_BLACK
local _CLR_BAR_BG = Blitbuffer.gray(0.15)
local _CLR_BAR_FG = Blitbuffer.gray(0.75)

local _BASE_COVER_GAP      = Screen:scaleBySize(16)
local _BASE_BAR_GAP_BEFORE = Screen:scaleBySize(6)
local _BASE_BAR_H          = Screen:scaleBySize(7)
local _BASE_BAR_PCT_GAP    = Screen:scaleBySize(6)
local _BASE_PCT_W          = Screen:scaleBySize(32)
local _BASE_INLINEPCT_FS   = Screen:scaleBySize(11)
local _BASE_AUTHOR_GAP     = Screen:scaleBySize(6)

local BAR_THICKNESS_KEY = "yanllsama_bar_thickness"
local BAR_HEIGHT_PCT_KEY = "yanllsama_bar_height_pct"
local BAR_POS_Y_KEY     = "yanllsama_bar_pos_y"
local BAR_LBL_FS_KEY    = "yanllsama_bar_lbl_fs"
local BAR_LBL_FONT_KEY  = "yanllsama_bar_lbl_font"
local BAR_LBL_BOLD_KEY  = "yanllsama_bar_lbl_bold"

local SETTING_SOURCE    = "yanllsama_source"

local DAILY_PAGE_GOAL_KEY = "yanllsama_daily_page_goal"
local COVER_GAP_KEY     = "yanllsama_cover_gap"
local SK_TIME_FMT       = "yanllsama_time_format"
local SK_EXCLUDE_PATHS  = "yanllsama_exclude_paths"
local FMT_NICKEL        = "nickel"
local FMT_XHYM          = "xhym"

local GRID_COLS_KEY     = "yanllsama_grid_cols"
local GRID_ROWS_KEY     = "yanllsama_grid_rows"
local STAT_ORDER_KEY    = "yanllsama_stat_order"
local ACTIVE_STATS_KEY  = "yanllsama_active_stats"

local VAL_FS_KEY        = "yanllsama_val_fs"
local LBL_FS_KEY        = "yanllsama_lbl_fs"
local TITLE_FS_KEY      = "yanllsama_title_fs"
local AUTHOR_FS_KEY     = "yanllsama_author_fs"

local VAL_FONT_KEY      = "yanllsama_val_font"
local LBL_FONT_KEY      = "yanllsama_lbl_font"
local TITLE_FONT_KEY    = "yanllsama_title_font"
local AUTHOR_FONT_KEY   = "yanllsama_author_font"

local VAL_BOLD_KEY      = "yanllsama_val_bold"
local LBL_BOLD_KEY      = "yanllsama_lbl_bold"

local SHOW_HEADERS_KEY  = "yanllsama_show_headers"
local HEADER_TXT_PFX    = "yanllsama_header_txt_"
local HEADER_WEIGHT_KEY = "yanllsama_header_weight"

local _STAT_LABELS = {
    book_time_left     = _("Time Left"),
    book_pages_read    = _("Pages Read"),
    book_time_spent    = _("Time Spent"),
    pages_left         = _("Pages Left"),
    days_reading       = _("Days Reading"),
    days_to_go         = _("Days to Go"),
    avg_time_per_day   = _("Daily Average"),
    pages_per_minute   = _("Pages/Minute"),
    mins_per_session   = _("Mins/Session"),
    pages_last_session = _("Last Session Pages"),
}

local _DEFAULT_STAT_ORDER = {
    "book_time_left", "book_pages_read",
    "book_time_spent", "pages_left",
    "days_reading", "days_to_go",
    "avg_time_per_day", "pages_per_minute",
    "mins_per_session", "pages_last_session"
}

local function getBarThickness(pfx) return tonumber(SUISettings:readSetting(pfx .. BAR_THICKNESS_KEY)) or 2 end
local function getBarHeightPct(pfx) return tonumber(SUISettings:readSetting(pfx .. BAR_HEIGHT_PCT_KEY)) or 100 end
local function getBarPosY(pfx) return tonumber(SUISettings:readSetting(pfx .. BAR_POS_Y_KEY)) or 0 end
local function getBarLblFs(pfx) return tonumber(SUISettings:readSetting(pfx .. BAR_LBL_FS_KEY)) or 10 end
local function getBarLblFont(pfx) return SUISettings:readSetting(pfx .. BAR_LBL_FONT_KEY) or "NotoSans" end
local function getBarLblBold(pfx) local v = SUISettings:readSetting(pfx .. BAR_LBL_BOLD_KEY); if v == nil then return false else return v end end
local function getSource(pfx) return SUISettings:readSetting(pfx .. SETTING_SOURCE) or "recent" end

local function getDailyPageGoal(pfx) return tonumber(SUISettings:readSetting(pfx .. DAILY_PAGE_GOAL_KEY)) or 50 end
local function getCoverGapPct(pfx)
    local v = SUISettings:readSetting(pfx .. COVER_GAP_KEY)
    local n = tonumber(v)
    return n and math.max(0, math.min(300, math.floor(n))) or 100
end
local function getTimeFmt(pfx) return SUISettings:readSetting(pfx .. SK_TIME_FMT) == FMT_XHYM and FMT_XHYM or FMT_NICKEL end
local function getGridCols(pfx) return tonumber(SUISettings:readSetting(pfx .. GRID_COLS_KEY)) or 2 end
local function getGridRows(pfx) return tonumber(SUISettings:readSetting(pfx .. GRID_ROWS_KEY)) or 4 end
local function getValFs(pfx) return tonumber(SUISettings:readSetting(pfx .. VAL_FS_KEY)) or 30 end
local function getLblFs(pfx) return tonumber(SUISettings:readSetting(pfx .. LBL_FS_KEY)) or 16 end
local function getTitleFs(pfx) return tonumber(SUISettings:readSetting(pfx .. TITLE_FS_KEY)) or 24 end
local function getAuthorFs(pfx) return tonumber(SUISettings:readSetting(pfx .. AUTHOR_FS_KEY)) or 20 end
local function getValFont(pfx) return SUISettings:readSetting(pfx .. VAL_FONT_KEY) or "NotoSerif" end
local function getLblFont(pfx) return SUISettings:readSetting(pfx .. LBL_FONT_KEY) or "x_smallinfofont" end
local function getTitleFont(pfx) return SUISettings:readSetting(pfx .. TITLE_FONT_KEY) or "NotoSerif" end
local function getAuthorFont(pfx) return SUISettings:readSetting(pfx .. AUTHOR_FONT_KEY) or "NotoSerif" end
local function getValBold(pfx) local v = SUISettings:readSetting(pfx .. VAL_BOLD_KEY); if v == nil then return true else return v end end
local function getLblBold(pfx) return SUISettings:readSetting(pfx .. LBL_BOLD_KEY) or false end
local function getShowHeaders(pfx) local v = SUISettings:readSetting(pfx .. SHOW_HEADERS_KEY); if v == nil then return true else return v end end
local function getHeaderTxt(pfx, col_idx) 
    local defaults = { _("THIS BOOK"), _("SPEED"), _("EXTRA 1"), _("EXTRA 2") }
    return SUISettings:readSetting(pfx .. HEADER_TXT_PFX .. tostring(col_idx)) or defaults[col_idx] or _("INFO")
end
local function getHeaderWeight(pfx) return SUISettings:readSetting(pfx .. HEADER_WEIGHT_KEY) or "bold" end

local function getExcludePaths(pfx)
    if not SUISettings then return {} end
    local raw = SUISettings:readSetting(pfx .. SK_EXCLUDE_PATHS)
    if not raw or raw == "" then return {} end
    local result = {}
    for token in raw:gmatch("[^,\n]+") do
        local t = token:match("^%s*(.-)%s*$")
        if t ~= "" then result[#result + 1] = t end
    end
    return result
end

local function isExcluded(fp, excludes)
    if not fp or #excludes == 0 then return false end
    for _, frag in ipairs(excludes) do
        if fp:find(frag, 1, true) then return true end
    end
    return false
end

local function _getCurrentFP(ctx, pfx)
    local excludes = getExcludePaths(pfx)
    if ctx.current_fp and not isExcluded(ctx.current_fp, excludes) then
        return ctx.current_fp
    end
    local ok, RH = pcall(require, "readhistory")
    if not ok or not RH then return nil end
    if not (RH.hist and #RH.hist > 0) then
        pcall(function() RH:reload() end)
    end
    if not RH.hist then return nil end
    for _, e in ipairs(RH.hist) do
        if e and e.file and not isExcluded(e.file, excludes) then
            return e.file
        end
    end
    return nil
end

local function getActiveStatsDict(pfx)
    local d = SUISettings:readSetting(pfx .. ACTIVE_STATS_KEY)
    if type(d) ~= "table" then
        d = {}
        for k, _ in pairs(_STAT_LABELS) do d[k] = true end
    end
    return d
end

local function _resolveStatOrder(saved)
    if type(saved) ~= "table" or #saved == 0 then return _DEFAULT_STAT_ORDER end
    local seen, result = {}, {}
    for _, v in ipairs(saved) do
        if _STAT_LABELS[v] and not seen[v] then seen[v] = true; table.insert(result, v) end
    end
    for _, v in ipairs(_DEFAULT_STAT_ORDER) do
        if not seen[v] then seen[v] = true; table.insert(result, v) end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Text Formatting & Translation Normalizers
-- ---------------------------------------------------------------------------
local function fmtCount(n)
    if n == nil then return "" end
    return util.getFormattedSize(n)
end

local function emptyVal() return { value = "", unit = "" } end
local function fmtFraction(a, b) return string.format("%s/%s", fmtCount(a), fmtCount(b)) end

local function fmtTimeHuman(secs)
    if not secs or secs ~= secs then return emptyVal() end
    if secs <= 0 then return { value = fmtCount(0), unit = _("min") } end
    local mins = Math.round(secs / 60)
    if mins <= 0 then return { value = fmtCount(0), unit = _("min") }
    elseif mins < 60 then return { value = fmtCount(mins), unit = _("min") } end
    local h = mins / 60
    local val = (h < 100) and string.format("%.1f", h) or string.format("%.0f", h)
    return { value = val, unit = _("hours") }
end

local function fmtTimeXhym(secs)
    if not secs or secs ~= secs then return emptyVal() end
    local mins = Math.round(secs / 60)
    if mins <= 0 then return { value = _("0 min"), unit = "" } end
    local h = math.floor(mins / 60)
    local m = mins % 60
    return { value = (h > 0) and string.format(_("%dh %02d min"), h, m) or string.format(_("%d min"), m), unit = "" }
end

local function pickFormatter(pfx) return (getTimeFmt(pfx) == FMT_XHYM) and fmtTimeXhym or fmtTimeHuman end

local function humanDayCount(days, kind)
    local n = math.max(0, tonumber(days) or 0)
    local unit = "day"
    if n >= 60 then unit = "month"; n = math.floor((n + 15) / 30)
    elseif n >= 14 then unit = "week"; n = math.floor((n + 3) / 7) end
    local labels = {
        reading = { day = { _("days read") }, week = { _("weeks read") }, month = { _("months read") } },
        to_go   = { day = { _("days left") }, week = { _("weeks left") }, month = { _("months left") } },
    }
    local group = labels[kind] or labels.to_go
    local pair  = group[unit]  or group.day
    return { value = fmtCount(n), unit = pair[1] }
end

local function resolveFontFace(fam, is_bold)
    if fam == "NotoSerif" then return is_bold and "NotoSerif-Bold.ttf" or "NotoSerif-Regular.ttf" end
    if fam == "NotoSans" then return is_bold and "NotoSans-Bold.ttf" or "NotoSans-Regular.ttf" end
    if fam == "LinLibertine" then return is_bold and "LinLibertine_RB.ttf" or "LinLibertine_R.ttf" end
    if fam == "tfont" then return "tfont" end
    if fam == "x_smallinfofont" then return "x_smallinfofont" end
    return is_bold and "NotoSerif-Bold.ttf" or "NotoSerif-Regular.ttf"
end

local function truncateTitle(title)
    if not title then return title end
    local count, i = 0, 1
    while i <= #title do
        local byte    = title:byte(i)
        local charLen = byte >= 240 and 4 or byte >= 224 and 3 or byte >= 192 and 2 or 1
        count = count + 1
        if count > 60 then return title:sub(1, i - 1) .. "…" end
        i = i + charLen
    end
    return title
end

-- ---------------------------------------------------------------------------
-- SQLite Statistics Database Connection & Engine
-- ---------------------------------------------------------------------------
local function getMaxSec()
    local ok, max = pcall(function() return tonumber(G_reader_settings:readSetting("statistics").max_sec) end)
    return (ok and max and max > 0) and max or 120
end

local function openStatsDB()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then return nil end
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local conn
    pcall(function() conn = SQ3.open(path) end)
    return conn
end

local function dbGetBookId(conn, md5)
    if not md5 then return nil end
    local id
    pcall(function() id = conn:rowexec(string.format("SELECT id FROM book WHERE md5 = '%s' ORDER BY last_open DESC LIMIT 1;", md5)) end)
    return id and tonumber(id) or nil
end

local function gatherStats(book, pfx, conn_ext)
    local fmt  = pickFormatter(pfx)
    local zero = fmt(0)
    local s = {
        book_progress      = emptyVal(),
        book_pages_read    = emptyVal(),
        book_time_spent    = zero,
        book_time_left     = zero,
        avg_time_per_day   = zero,
        pages_per_minute   = { value = fmtCount(0), unit = _("pages/min") },
        days_reading       = humanDayCount(0, "reading"),
        days_to_go         = humanDayCount(0, "to_go"),
        mins_per_session   = { value = "-", unit = _("mins/session") },
        pages_last_session = { value = "-", unit = _("pages (last)") }
    }
    
    s.today_pages = 0
    if not book or not book.md5 then return s end

    local pct      = book.percent or 0
    local pages    = book.pages   or 0
    local cur_page = (pages > 0) and math.max(1, math.floor(pct * pages)) or 0

    if pct > 0 then s.book_progress = { value = string.format("%%%.0f", pct * 100), unit = "" } end

    local conn = conn_ext or openStatsDB()
    if not conn then 
        if pages > 0 then s.book_pages_read = { value = fmtFraction(cur_page, pages), unit = _("read") } end
        return s 
    end

    local book_id = dbGetBookId(conn, book.md5)
    
    if book_id then
        pcall(function()
            local max_db = conn:rowexec(string.format("SELECT max(page) FROM page_stat_data WHERE id_book = %d", book_id))
            if max_db and tonumber(max_db) > 0 then
                cur_page = tonumber(max_db)
            end
        end)
    end
    
    if pages > 0 then s.book_pages_read = { value = fmtFraction(cur_page, pages), unit = _("read") } end
    if not book_id then
        if not conn_ext then pcall(function() conn:close() end) end
        return s
    end

    local max_sec = getMaxSec()
    local ts = nil
    local total_days = nil
    local session_cnt = 0
    local last_session_pages = nil

    pcall(function()
        local rows = conn:exec(string.format([[
            WITH ps AS (SELECT page, sum(duration) AS pd FROM page_stat_data WHERE id_book = %d GROUP BY page)
            SELECT sum(min(pd, %d)), count(*) FROM ps;
        ]], book_id, max_sec))
        
        if rows and rows[1] and rows[1][1] then
            local tt = tonumber(rows[1][1]) or 0
            local rp = tonumber(rows[2] and rows[2][1]) or 0
            ts = { total_time = tt, read_pages = rp, avg_time = (rp > 0 and tt > 0) and (tt / rp) or nil }
        end

        local ndays = conn:rowexec(string.format("SELECT count(*) FROM (SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') FROM page_stat_data WHERE id_book = %d GROUP BY 1);", book_id))
        total_days = ndays and tonumber(ndays) or nil

        local nses = conn:rowexec(string.format("SELECT count(DISTINCT round(start_time / 3600)) FROM page_stat_data WHERE id_book = %d", book_id))
        session_cnt = tonumber(nses) or 0

        local q_last = string.format([[
            SELECT count(DISTINCT page) FROM page_stat_data 
            WHERE id_book = %d AND strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') = 
                (SELECT strftime('%%Y-%%m-%%d', max(start_time), 'unixepoch', 'localtime') FROM page_stat_data WHERE id_book = %d)
        ]], book_id, book_id)
        last_session_pages = conn:rowexec(q_last)
        
        local t = os.date("*t")
        local start_today = os.time() - (t.hour * 3600 + t.min * 60 + t.sec)
        local q_today = string.format("SELECT count(DISTINCT page) FROM page_stat_data WHERE id_book = %d AND start_time >= %d", book_id, start_today)
        s.today_pages = tonumber(conn:rowexec(q_today)) or 0
    end)

    if not conn_ext then pcall(function() conn:close() end) end

    if ts and ts.total_time and ts.total_time > 0 then
        s.book_time_spent = fmt(ts.total_time)
        if session_cnt > 0 then
            s.mins_per_session.value = fmtCount(math.floor(ts.total_time / 60 / session_cnt))
        end
    end

    if last_session_pages then
        s.pages_last_session.value = fmtCount(tonumber(last_session_pages))
    end

    local avg_time   = ts and ts.avg_time
    local pages_left = (pages > 0) and (pages - cur_page) or nil

    if avg_time and avg_time > 0 and pages_left and pages_left > 0 then
        s.book_time_left = fmt(pages_left * avg_time)
    end

    if avg_time and avg_time > 0 then
        local ppm = 60 / avg_time
        s.pages_per_minute = {
            value = (ppm >= 1) and string.format("%.1f", ppm) or string.format("%.2f", ppm),
            unit  = _("pages/min"),
        }
    end

    if total_days and total_days > 0 then
        s.days_reading = humanDayCount(total_days, "reading")
        s.avg_time_per_day = fmt(ts.total_time / total_days)

        if avg_time and avg_time > 0 and pages_left and pages_left > 0 and ts.total_time > 0 then
            local avg_per_day = ts.total_time / total_days
            if avg_per_day > 0 then
                local days_to_finish = math.ceil((pages_left * avg_time) / avg_per_day)
                s.days_to_go = humanDayCount(days_to_finish, "to_go")
            end
        end
    end

    return s
end

local _cache = nil
local _CACHE_TTL = 300 

local function cacheGet(fp, pfx)
    if not _cache then return nil end
    if _cache.fp  ~= fp  then return nil end
    if _cache.pfx ~= pfx then return nil end
    if (os.time() - _cache.ts) > _CACHE_TTL then return nil end
    return _cache.stats
end

local function cachePut(fp, pfx, stats)
    _cache = { fp = fp, pfx = pfx, ts = os.time(), stats = stats }
end

local function mkSectionHeader(face, text, full_w, bg_color, left_pad, transparent)
    left_pad = left_pad or Size.padding.large
    local tw = TextWidget:new{ text = text, face = face }
    if transparent then
        return VerticalGroup:new{
            align = "left", VerticalSpan:new{ height = Size.padding.small },
            HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = left_pad }, tw },
            VerticalSpan:new{ height = Size.padding.small },
            LineWidget:new{ dimen = Geom:new{ w = full_w, h = Size.line.thick }, background = Blitbuffer.COLOR_BLACK },
        }
    end
    local h = tw:getSize().h + Size.padding.small * 2
    return FrameContainer:new{
        background = bg_color or Blitbuffer.COLOR_GRAY_E, bordersize = 0,
        padding_top = Size.padding.small, padding_bottom = Size.padding.small, padding_left = left_pad, padding_right = 0,
        radius = math.max(1, math.floor(h / 4)),
        LeftContainer:new{ dimen = Geom:new{ w = full_w - left_pad, h = tw:getSize().h }, tw },
    }
end

local M = {}

M.id              = "currently_yanllsama"
M.name            = _("Currently Reading (Yanllsama)")
M.label           = _("Currently Reading")
M.description     = _("Enhanced reading dashboard with dynamic grid (1-4 cols, 1-6 rows), customizable headers, rich statistics (10 metrics), and 6 progress bar styles. Tap book/author for description.")
M.default_enabled = false
M.enabled_key     = "currently_yanllsama"
M.default_on      = false
M.has_covers      = true   
M.is_book_mod     = true   
M.needs           = { db = true, books = true, stats = true }

function M.isEnabled(pfx)
    local SUISettings = package.loaded["infra/sui_store"] or package.loaded["sui_store"]
    if SUISettings then
        local ext_enabled = SUISettings:readSetting("sui_ext_mod_" .. M.id)
        if ext_enabled ~= nil then return ext_enabled end
        
        local val = SUISettings:readSetting(pfx .. M.enabled_key)
        if val ~= nil then return val end
    end
    return M.default_on
end

function M.reset()
    _SH = nil; _SUIStyle = nil; _cache = nil
end

local function _buildWidget(w, ctx, pfx, SH, bd, cover, stats, D, scale, lbl_scale, cols, rows, current_fp, fps, curIdx)
    local cover_gap      = math.max(0, math.floor(_BASE_COVER_GAP      * scale * (getCoverGapPct(pfx) / 100)))
    local bar_gap_before = math.max(1, math.floor(_BASE_BAR_GAP_BEFORE * scale))
    local bar_h          = math.max(1, math.floor(_BASE_BAR_H          * scale))
    local author_gap     = math.max(1, math.floor(_BASE_AUTHOR_GAP     * scale))

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

    local val_fg_color = _CLR_DARK_EFF
    local lbl_fg_color = CLR_TEXT_SUB_EFF

    local face_inlinepct = Font:getFace("smallinfofont", math.max(7, math.floor(_BASE_INLINEPCT_FS * scale * lbl_scale)))
    
    local title_fs = math.max(12, math.floor(getTitleFs(pfx) * scale))
    local author_fs = math.max(10, math.floor(getAuthorFs(pfx) * scale))
    local face_title = Font:getFace(resolveFontFace(getTitleFont(pfx), true), title_fs) or Font:getFace("tfont", title_fs)
    local face_author = Font:getFace(resolveFontFace(getAuthorFont(pfx), false), author_fs) or Font:getFace("tfont", author_fs)

    local val_fs = math.max(12, math.floor(getValFs(pfx) * scale))
    local lbl_fs = math.max(10, math.floor(getLblFs(pfx) * scale))
    local face_v = Font:getFace(resolveFontFace(getValFont(pfx), getValBold(pfx)), val_fs) or Font:getFace("tfont", val_fs)
    local face_l = Font:getFace(resolveFontFace(getLblFont(pfx), getLblBold(pfx)), lbl_fs) or Font:getFace("x_smallinfofont", lbl_fs)

    local left_frame = FrameContainer:new{ bordersize = 0, padding = 0, padding_right = cover_gap, [1] = cover }

    local tw = w - PAD - D.COVER_W - cover_gap - PAD
    
    local ip     = Size.padding.default
    
    local pad_x   = ip
    local sep_w   = math.max(1, math.floor(Size.line.medium * scale))
    local box_bordersize = math.max(1, math.floor(1 * scale))
    local box_padding = Size.padding.small
    local box_extra = (box_padding + box_bordersize) * 2
    local inner_tw = math.max(10, tw - box_extra)

    local stats_w = math.max(1, math.floor(inner_tw * 0.80))
    local bars_w  = math.max(1, inner_tw - stats_w - pad_x - sep_w)
    
    local sep_line_w = math.max(1, math.floor(Size.line.medium * scale))
    local total_isep_w = sep_line_w * (cols - 1)
    
    local col_widths = {}
    local remaining_w = stats_w - total_isep_w
    for c=1, cols do
        local cw = math.floor(remaining_w / (cols - c + 1))
        col_widths[c] = cw
        remaining_w = remaining_w - cw
    end

    local has_wp = ctx.has_wallpaper
    local function make_tbw(args)
        args.fgcolor = args.fgcolor or _CLR_DARK_EFF
        if has_wp and UI and UI.makeAlphaTextBox then return UI.makeAlphaTextBox(args) end
        return TextBoxWidget:new(args)
    end

    local function fitValFace(text, max_w)
        if not text or text == "" then return face_v end
        local fs, min_fs = val_fs, math.max(9, val_fs - 12)
        local face = face_v
        local p_tw = TextWidget:new{ text = text, face = face }
        while p_tw:getSize().w > max_w and fs > min_fs do
            fs = fs - 1
            face = Font:getFace(resolveFontFace(getValFont(pfx), getValBold(pfx)), fs) or Font:getFace("tfont", fs)
            p_tw = TextWidget:new{ text = text, face = face }
        end
        return face
    end

    local function pvline(data, extra, col_w)
        if not data or data.value == "" then
            return HorizontalGroup:new{ align = "left", HorizontalSpan:new{ width = Size.padding.large }, make_tbw({ text = "", face = face_l, width = col_w - Size.padding.large }) } 
        end
        local desc = data.unit or ""
        if extra and extra ~= "" then desc = (desc ~= "") and (desc .. " " .. extra) or extra end
        local max_val_w = (desc ~= "") and math.max(1, math.floor((col_w - Size.padding.large) * 0.55)) or math.max(1, col_w - Size.padding.large - Size.padding.small)
        
        local vw = TextWidget:new{ text = data.value, face = fitValFace(data.value, max_val_w), fgcolor = val_fg_color }
        local right_pad = Size.padding.small
        local lbl_w = math.max(1, col_w - Size.padding.large - vw:getSize().w - Size.padding.large - right_pad)
        return HorizontalGroup:new{
            align = "center", HorizontalSpan:new{ width = Size.padding.large }, vw, HorizontalSpan:new{ width = Size.padding.large },
            make_tbw({ text = desc, face = face_l, width = lbl_w, alignment = "left", fgcolor = lbl_fg_color }),
            HorizontalSpan:new{ width = right_pad }
        }
    end

    local hdr_weight = getHeaderWeight(pfx)
    local hdr_base_fs = math.max(12, math.floor(14 * scale))
    local sec_fs
    if hdr_weight == "thin" then sec_fs = Font:getFace("NotoSerif-Regular.ttf", hdr_base_fs)
    elseif hdr_weight == "medium" then sec_fs = Font:getFace("NotoSans-Regular.ttf", hdr_base_fs)
    else sec_fs = Font:getFace("NotoSans-Bold.ttf", hdr_base_fs) end

    local CLR_HDR_BG = Blitbuffer.COLOR_GRAY_D
    if SS then
        if SS.COLOR then
            CLR_HDR_BG = SS.COLOR.gray_soft or SS.COLOR.track or Blitbuffer.COLOR_GRAY_D
        elseif SS.getThemeColor then
            CLR_HDR_BG = SS.getThemeColor("muted") or SS.getThemeColor("divider") or Blitbuffer.COLOR_GRAY_D
        end
    end
    
    local function mkDynamicGrid(items)
        local grid_args = { align = "left" }
        local show_h = getShowHeaders(pfx)

        local col_groups = {}
        for c=1, cols do col_groups[c] = { align = "left" } end
        
        if show_h then
            for c=1, cols do
                local h_txt = getHeaderTxt(pfx, c)
                table.insert(col_groups[c], mkSectionHeader(sec_fs, h_txt, col_widths[c], CLR_HDR_BG, Size.padding.large, has_wp))
                table.insert(col_groups[c], VerticalSpan:new{ height = Size.padding.default })
            end
        end
        
        for r=1, rows do
            for c=1, cols do
                local idx = (c - 1) * rows + r
                if items[idx] then table.insert(col_groups[c], items[idx]) end
                if r < rows then table.insert(col_groups[c], VerticalSpan:new{ height = Size.padding.default }) end
            end
        end
        
        local hg_args = { align = "top" }
        local rendered_cols = {}
        local max_h = 0
        for c=1, cols do 
            rendered_cols[c] = VerticalGroup:new(col_groups[c])
            max_h = math.max(max_h, rendered_cols[c]:getSize().h)
        end
        
        for c=1, cols do
            table.insert(hg_args, rendered_cols[c])
            if c < cols then
                table.insert(hg_args, HorizontalSpan:new{ width = sep_line_w })
            end
        end
        table.insert(grid_args, HorizontalGroup:new(hg_args))
        return VerticalGroup:new(grid_args)
    end

    local right_header = VerticalGroup:new{ align = "left" }

    local title_wid = make_tbw({
        text      = truncateTitle(bd.title) or "?", face      = face_title,
        bold      = true, width     = tw, max_lines = 2, fgcolor   = _CLR_DARK_EFF,
    })

    local ta_group_items = { align = "left", [1] = title_wid }

    if bd.authors and bd.authors ~= "" then
        table.insert(ta_group_items, VerticalSpan:new{ height = author_gap })
        local auth_wid = UI.makeColoredText{
            text = bd.authors, face = face_author, fgcolor = CLR_TEXT_SUB_EFF,
            width = tw, max_width = tw, truncation_char = "…",
        }
        table.insert(ta_group_items, auth_wid)
    end

    local ta_group = VerticalGroup:new(ta_group_items)

    local info_tap_container = InputContainer:new{
        dimen = Geom:new{ w = tw, h = ta_group:getSize().h },
        [1] = ta_group
    }
    info_tap_container.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return info_tap_container.dimen end } }
    }
    function info_tap_container:onTap()
        local desc = bd.description
        local debug_msg = ""

        if not desc or desc == "" then
            pcall(function()
                -- YÖNTEM 1: BookInfoManager (KOReader yerleşik metadata yöneticisi - En Güvenilir)
                local Config = package.loaded["sui_config"] or package.loaded["infra/sui_config"] or (function() local ok, m = pcall(require, "infra/sui_config"); return ok and m or require("sui_config") end)()
                local bim = Config.getBookInfoManager()
                local props = nil
                
                if bim then
                    props = bim:getBookInfo(current_fp, false)
                    if props then
                        desc = props.description or props.summary or props.annotation or props.comments
                    end
                end

                -- YÖNTEM 2: DocSettings (Kitap daha önce açıldıysa okunan doc_props verisi)
                if not desc or desc == "" then
                    local ok_ds, DocSettings = pcall(require, "docsettings")
                    if ok_ds and DocSettings then
                        local ds = DocSettings:open(current_fp)
                        if ds then
                            local ds_props = ds:readSetting("doc_props")
                            if ds_props then
                                desc = ds_props.description or ds_props.summary or ds_props.annotation or ds_props.comments
                                if not props then props = ds_props end
                            end
                            ds:close() -- Dosya sızıntısını (file handle leak) önlemek için kapatılmalı
                        end
                    end
                end

                -- YÖNTEM 3: Belgeyi doğrudan açıp okumak (Ağır işlem, son çare)
                if not desc or desc == "" then
                    local DocumentRegistry = require("document/documentregistry")
                    local doc = DocumentRegistry:openDocument(current_fp)
                    if doc then
                        local doc_props = doc:getProps()
                        if doc_props then
                            desc = doc_props.description or doc_props.summary or doc_props.annotation or doc_props.comments or doc_props.subject
                            if not props then props = doc_props end
                        end
                        doc:close()
                    end
                end

                -- Eğer açıklama hâlâ bulunamazsa, uzun rastgele bir metin (150 karakter) arayalım
                if (not desc or desc == "") and props then
                    for _, v in pairs(props) do
                        if type(v) == "string" and #v > 150 then
                            desc = v
                            break
                        end
                    end
                end
                
                -- Hiçbir şey bulunamadıysa kitap meta etiketlerini (Seri, Yayıncı vb.) kart olarak göster
                if (not desc or desc == "") and props then
                    local fallback_info = {}
                    if props.series and type(props.series) == "string" and props.series ~= "" then 
                        local s = "Seri: " .. props.series 
                        if props.series_index then s = s .. " #" .. tostring(props.series_index) end
                        table.insert(fallback_info, s)
                    end
                    if props.publisher and type(props.publisher) == "string" and props.publisher ~= "" then table.insert(fallback_info, "Yayıncı: " .. props.publisher) end
                    if props.language and type(props.language) == "string" and props.language ~= "" then table.insert(fallback_info, "Dil: " .. props.language) end
                    
                    local kw = props.keywords or props.tags
                    if type(kw) == "table" then kw = table.concat(kw, ", ") end
                    if kw and type(kw) == "string" and kw ~= "" then table.insert(fallback_info, "Etiketler: " .. kw) end
                    
                    if #fallback_info > 0 then
                        desc = "Bu kitabın kimlik bilgilerinde (metadata) bir açıklama metni bulunmuyor.\n\nKitap Bilgileri:\n" .. table.concat(fallback_info, "\n")
                    end
                end
            end)
        end

        -- Veri dizi (table) olarak geldiyse birleştir
        if type(desc) == "table" then
            desc = table.concat(desc, "\n\n")
        elseif type(desc) ~= "string" then
            desc = ""
        end

        -- HTML tag'lerini ve özel karakterleri saf Lua ile temizle
        if desc and desc ~= "" then
            pcall(function()
                local util = require("util")
                if util.htmlToPlainText then desc = util.htmlToPlainText(desc) end
            end)
            desc = desc:gsub("<br%s*/?>", "\n")
            desc = desc:gsub("</p>", "\n\n")
            desc = desc:gsub("<[^>]+>", "") -- Diğer tüm HTML etiketlerini sil
            desc = desc:gsub("&nbsp;", " ")
            desc = desc:gsub("&amp;", "&")
            desc = desc:gsub("&lt;", "<")
            desc = desc:gsub("&gt;", ">")
            desc = desc:gsub("&quot;", '"')
            desc = desc:gsub("&apos;", "'")
            desc = desc:gsub("^%s+", ""):gsub("%s+$", "") -- Başındaki/sonundaki gereksiz boşlukları temizle
        end

        local final_desc = (desc and desc ~= "") and desc or _("Bu kitap hakkında ek açıklama bulunmamaktadır.")
        
        -- Uzun (paragraflı) metinleri rahat okumak için kaydırılabilir TextViewer kullanalım
        local ok_tv, TextViewer = pcall(require, "ui/widget/textviewer")
        if ok_tv and TextViewer and (final_desc and final_desc ~= "") then
            UIManager:show(TextViewer:new{
                title = bd.title or _("Kitap Açıklaması"),
                text  = final_desc,
            })
        else
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{ text = final_desc })
        end

        return true
    end

    table.insert(right_header, info_tap_container)
    table.insert(right_header, VerticalSpan:new{ height = Size.padding.large })

    local pages_left_data = { value = "", unit = "" }
    local total_p = bd.pages or 0
    if total_p > 0 then
        local cur_p = math.max(1, math.floor((bd.percent or 0) * total_p))
        local rem_p = math.max(0, total_p - cur_p)
        pages_left_data = { value = tostring(rem_p), unit = _("pages") }
    end

    local stat_defs = {
        book_time_spent    = { data = stats.book_time_spent, extra = _("read") },
        book_pages_read    = { data = stats.book_pages_read, extra = "" },
        book_time_left     = { data = stats.book_time_left,  extra = _("left") },
        pages_left         = { data = pages_left_data,       extra = _("left") },
        days_reading       = { data = stats.days_reading,    extra = "" },
        days_to_go         = { data = stats.days_to_go,      extra = "" },
        avg_time_per_day   = { data = stats.avg_time_per_day,extra = _("a day") },
        pages_per_minute   = { data = stats.pages_per_minute,extra = "" },
        mins_per_session   = { data = stats.mins_per_session,extra = "" },
        pages_last_session = { data = stats.pages_last_session, extra = "" },
    }

    local active_items = {}
    local active_dict = getActiveStatsDict(pfx)
    local max_items = cols * rows
    
    local keys_to_display = {}
    for _, key in ipairs(_resolveStatOrder(SUISettings:readSetting(pfx .. STAT_ORDER_KEY))) do
        if stat_defs[key] and active_dict[key] and #keys_to_display < max_items then
            table.insert(keys_to_display, key)
        end
    end
    
    for idx, key in ipairs(keys_to_display) do
        local c = math.ceil(idx / rows)
        if c > cols then c = cols end
        table.insert(active_items, pvline(stat_defs[key].data, stat_defs[key].extra, col_widths[c]))
    end

    local grid_widget = mkDynamicGrid(active_items)
    local grid_h = grid_widget:getSize().h
    local header_h = right_header:getSize().h
    local target_bottom_h = math.max(grid_h, D.COVER_H - header_h - Size.padding.large - box_extra)
    
    -- Çizginin etrafındaki boşluklar aşağıda HorizontalSpan ile verilecek.

    local daily_goal = math.max(1, getDailyPageGoal(pfx))
    local today_pages = stats.today_pages or 0
    local goal_pct = math.min(today_pages / daily_goal, 1.0)
    local book_pct = math.min(bd.percent or 0, 1.0)

    local bar_lbl_fs = math.max(6, math.floor(getBarLblFs(pfx) * scale * lbl_scale))
    local face_bar_lbl = Font:getFace(resolveFontFace(getBarLblFont(pfx), getBarLblBold(pfx)), bar_lbl_fs) or Font:getFace("tfont", bar_lbl_fs)
    
    local lbl_gap = math.max(2, math.floor(Size.padding.default * scale))
    local bar_lbl_h = math.floor(bar_lbl_fs * 1.4)
    local height_pct = getBarHeightPct(pfx) / 100
    local bar_max_h = math.max(10, math.floor((target_bottom_h - bar_lbl_h - lbl_gap) * height_pct))
    local thick_level = getBarThickness(pfx)
    local thick_mult = 0.12
    if thick_level == 1 then thick_mult = 0.06
    elseif thick_level == 2 then thick_mult = 0.12
    elseif thick_level == 3 then thick_mult = 0.18
    elseif thick_level == 4 then thick_mult = 0.24 end
    local shift_left = math.floor(pad_x * 1.5)
    local bars_w  = math.max(1, inner_tw - stats_w - (pad_x * 2) - sep_w - shift_left)
    local bar_thickness = math.max(2, math.floor(bars_w * thick_mult))
    local bars_gap = math.max(4, math.floor(bars_w * 0.125))
    local col_w = math.max(1, math.floor((bars_w - bars_gap) / 2))
    
local function makeVertBar(pct, label_bot, color_fg)
        local fw = math.max(0, math.floor(bar_max_h * pct))
        
        local function makeRoundedBar(w, h, color, offset)
            return FrameContainer:new{
                bordersize = 0, margin = 0, padding = 0,
                background = color, radius = math.max(1, math.floor(w / 4)),
                overlap_offset = offset,
                [1] = LineWidget:new{ dimen = Geom:new{ w = w, h = h }, style = "none" }
            }
        end

        local bar_og
        if fw <= 0 then
            bar_og = makeRoundedBar(bar_thickness, bar_max_h, _CLR_BAR_BG)
        else
            bar_og = OverlapGroup:new{
                dimen = Geom:new{ w = bar_thickness, h = bar_max_h },
                makeRoundedBar(bar_thickness, bar_max_h, _CLR_BAR_BG),
                makeRoundedBar(bar_thickness, fw, color_fg, {0, bar_max_h - fw})
            }
        end
        
        local lbl_widget = UI.makeColoredText{ text = label_bot, face = face_bar_lbl, fgcolor = val_fg_color, bold = true }
        
        -- En basit dikey grup: Çubuk -> Boşluk -> Yazı
        return VerticalGroup:new{
            align = "center",
            bar_og,
            VerticalSpan:new{ height = math.floor(10 * scale) }, -- Buradaki 10 değerini artırarak arayı açabilirsin
            lbl_widget
        }
    end
    
    local bar1 = makeVertBar(goal_pct, string.format("%d/%d", today_pages, daily_goal), _CLR_BAR_FG)
    local bar2 = makeVertBar(book_pct, string.format("%%%d", math.floor(book_pct * 100)), _CLR_BAR_FG)
    
    local bars_and_labels = HorizontalGroup:new{ align = "center", bar1, HorizontalSpan:new{ width = bars_gap }, bar2 }

    local content_h = bars_and_labels:getSize().h
    local remaining_h = math.max(0, target_bottom_h - content_h)

    local y_offset_pct = getBarPosY(pfx) / 100
    local top_padding_ratio = (1.0 - y_offset_pct) / 2.0

    local top_padding = math.floor(remaining_h * top_padding_ratio)
    local bottom_padding = remaining_h - top_padding

    local bars_content = VerticalGroup:new{ align = "center" }
    if top_padding > 0 then table.insert(bars_content, VerticalSpan:new{ height = top_padding }) end
    table.insert(bars_content, bars_and_labels)
    if bottom_padding > 0 then table.insert(bars_content, VerticalSpan:new{ height = bottom_padding }) end

    local bars_group = CenterContainer:new{
        dimen = Geom:new{ w = bars_w, h = target_bottom_h },
        bars_content
    }

    local right_bottom_content = HorizontalGroup:new{
        align = "top",
        LeftContainer:new{ dimen = Geom:new{ w = stats_w, h = target_bottom_h }, [1] = grid_widget },
        HorizontalSpan:new{ width = pad_x },
        HorizontalSpan:new{ width = sep_w },
        HorizontalSpan:new{ width = pad_x },
        CenterContainer:new{
            dimen = Geom:new{ w = bars_w, h = target_bottom_h },
            [1] = bars_content
        },
        HorizontalSpan:new{ width = shift_left }
    }

    local right_bottom = FrameContainer:new{
        bordersize = box_bordersize,
        radius = math.max(1, math.floor(16 * scale)),
        color = Blitbuffer.COLOR_BLACK,
        padding = box_padding,
        right_bottom_content
    }

    local right_col = VerticalGroup:new{
        align = "left",
        right_header,
        VerticalSpan:new{ height = Size.padding.large },
        right_bottom
    }

    local left_h = D.COVER_H
    local content_h = math.max(left_h, right_col:getSize().h)

    local left_wrapper  = LeftContainer:new{ dimen = Geom:new{ w = D.COVER_W + cover_gap, h = content_h }, [1] = left_frame }
    local right_wrapper = LeftContainer:new{ dimen = Geom:new{ w = tw, h = content_h }, [1] = right_col }

    local row = HorizontalGroup:new{ align = "top", [1] = left_wrapper, [2] = right_wrapper }
    
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = content_h }, _fp = current_fp, _open_fn = ctx.open_fn,
        _hs = ctx._screen_widget or ctx._hs_widget,
        _count = fps and #fps or 1,
        _cur = curIdx or 1,
        [1] = FrameContainer:new{ bordersize = 0, padding = 0, padding_left = PAD, padding_right = PAD, [1] = row },
    }
    
    tappable.ges_events = { 
        TapBook = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } } 
    }
    
    if tappable._count > 1 then
        tappable.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = function() return tappable.dimen end } }
        function tappable:onSwipe(_, ges)
            if ges.direction == "south" then
                self._cur = (self._cur - 2 + self._count) % self._count + 1
                ctx.yanllsama_cur_idx = self._cur
                if self._hs then
                    if type(self._hs._refreshBookModSlot) == "function" then
                        self._hs:_refreshBookModSlot("currently_yanllsama")
                    elseif type(self._hs._refreshImmediate) == "function" then
                        self._hs:_refreshImmediate(true)
                    end
                end
                return true
            elseif ges.direction == "north" then
                self._cur = self._cur % self._count + 1
                ctx.yanllsama_cur_idx = self._cur
                if self._hs then
                    if type(self._hs._refreshBookModSlot) == "function" then
                        self._hs:_refreshBookModSlot("currently_yanllsama")
                    elseif type(self._hs._refreshImmediate) == "function" then
                        self._hs:_refreshImmediate(true)
                    end
                end
                return true
            end
            return false
        end
    end
    
    tappable._cover_slots = { { container = left_frame, idx = 1, fp = current_fp, w = D.COVER_W, h = D.COVER_H, align = nil, stretch = 0.10 } }
    
    function tappable:onTapBook(_, ges)
        if ges and ges.pos and self.dimen then
            local rel_x = ges.pos.x - self.dimen.x
            local stats_start_x = PAD + D.COVER_W + cover_gap
            local bars_start_x = stats_start_x + stats_w + (pad_x * 2) + sep_w
            
            if rel_x > bars_start_x then
                local ok, CBS = pcall(require, "modules/module_currently_books_stat")
                if ok and CBS and CBS.showBookStatsWindow then
                    CBS.showBookStatsWindow(current_fp, nil, ctx.ui)
                else
                    local UIManager = require("ui/uimanager")
                    UIManager:broadcastEvent(require("ui/event"):new("ShowReaderProgress"))
                end
                return true
            elseif rel_x > stats_start_x then
                local UIManager = require("ui/uimanager")
                UIManager:broadcastEvent(require("ui/event"):new("ShowReadingInsightsPopup"))
                return true
            end
        end
        if self._open_fn then self._open_fn(self._fp) end
        return true
    end

    if ctx.kb_currently_focused then
        local bw = Screen:scaleBySize(3)
        return OverlapGroup:new{
            dimen = Geom:new{ w = w, h = content_h }, tappable,
            LineWidget:new{ dimen = Geom:new{ w = w, h = bw }, background = _CLR_DARK_EFF },
            LineWidget:new{ dimen = Geom:new{ w = w, h = bw }, background = _CLR_DARK_EFF, overlap_offset = {0, content_h - bw} },
            LineWidget:new{ dimen = Geom:new{ w = bw, h = content_h }, background = _CLR_DARK_EFF },
            LineWidget:new{ dimen = Geom:new{ w = bw, h = content_h }, background = _CLR_DARK_EFF, overlap_offset = {w - bw, 0} },
        }
    end

    return tappable
end

function M.updateCovers(widget, _ctx)
    local tappable = (widget._cover_slots) and widget or (widget[1] and widget[1]._cover_slots and widget[1])
    if not tappable or not tappable._cover_slots then return true end

    local SH = getSH()
    if not SH then return true end

    local all_done = true
    for _, slot in ipairs(tappable._cover_slots) do
        local new_cover = SH.getBookCover(slot.fp, slot.w, slot.h, slot.align, slot.stretch)
        if new_cover then slot.container[slot.idx] = new_cover
        elseif not Config.isCoverMissing(slot.fp) then all_done = false end
    end
    return all_done
end

function M.getHeight(_ctx)
    local SH = getSH()
    if not SH then return Config.getScaledLabelH() end
    local pfx   = _ctx and _ctx.pfx or ""
    local scale = Config.getModuleScale("currently_yanllsama", pfx)
    local thumb_scale = Config.getThumbScale("currently_yanllsama", pfx)
    local cols = getGridCols(pfx)
    local rows = getGridRows(pfx)
    local show_h = getShowHeaders(pfx)
    local D     = SH.getDims(scale, thumb_scale)
    
    local title_approx  = ((getTitleFs(pfx) or 24) * scale) * 2.5
    local author_approx = ((getAuthorFs(pfx) or 20) * scale) * 1.5
    local max_fs = math.max(getValFs(pfx), getLblFs(pfx))
    local row_h = Screen:scaleBySize(max_fs + 8) * scale
    
    local spans = (Size.padding.default * rows) * scale
    
    local header_approx = 0
    if show_h then
        header_approx = (Screen:scaleBySize(22) * scale) + (Size.padding.default * scale)
    end
    
    local right_h = title_approx + author_approx + header_approx + (row_h * rows) + spans
    local left_h  = D.COVER_H

    return Config.getScaledLabelH() + math.max(left_h, right_h)
end

local function moveItem(list, item, dir)
    local idx = nil
    for i, v in ipairs(list) do 
        if v == item then idx = i; break end 
    end
    if not idx then return list end
    if dir == "up" and idx > 1 then list[idx], list[idx-1] = list[idx-1], list[idx]
    elseif dir == "down" and idx < #list then list[idx], list[idx+1] = list[idx+1], list[idx] end
    return list
end

function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx or ""
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._
    local SortWidget = require("ui/widget/sortwidget")
    local InputDialog = require("ui/widget/inputdialog")
    local UIManager = require("ui/uimanager")

    local font_options = {
        { name = "NotoSerif", label = "Noto Serif" },
        { name = "NotoSans", label = "Noto Sans" },
        { name = "LinLibertine", label = "Linux Libertine" },
        { name = "tfont", label = _lc("System UI Font") }
    }
    
    local function makeFontMenu(key_name, default_val)
        local sub = {}
        for _, opt in ipairs(font_options) do
            table.insert(sub, {
                text = opt.label, radio = true, keep_menu_open = true,
                checked_func = function() return (SUISettings:readSetting(pfx .. key_name) or default_val) == opt.name end,
                callback = function() SUISettings:saveSetting(pfx .. key_name, opt.name) refresh() end,
            })
        end
        return sub
    end

    local function makeSizeMenu(key_name, default_val, max_val, step, min_val)
        local sub = {}
        for fs = (min_val or 12), (max_val or 44), (step or 2) do
            table.insert(sub, {
                text = tostring(fs) .. (fs == default_val and _lc(" (Default)") or ""), radio = true, keep_menu_open = true,
                checked_func = function() return (tonumber(SUISettings:readSetting(pfx .. key_name)) or default_val) == fs end,
                callback = function() SUISettings:saveSetting(pfx .. key_name, fs) refresh() end,
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
                callback = function() SUISettings:saveSetting(pfx .. key_name, n) refresh() end,
            })
        end
        return sub
    end
    
    local bar_height_menu = {}
    for h_pct = 10, 100, 10 do
        table.insert(bar_height_menu, {
            text = "%" .. tostring(h_pct) .. (h_pct == 100 and _lc(" (Default)") or ""), radio = true, keep_menu_open = true,
            checked_func = function() return getBarHeightPct(pfx) == h_pct end,
            callback = function() SUISettings:saveSetting(pfx .. BAR_HEIGHT_PCT_KEY, h_pct) refresh() end,
        })
    end
    
    local bar_pos_menu = {}
    for y_pct = 100, -100, -10 do
        table.insert(bar_pos_menu, {
            text = (y_pct > 0 and "+" or "") .. tostring(y_pct) .. "%" .. (y_pct == 0 and _lc(" (Default)") or ""), radio = true, keep_menu_open = true,
            checked_func = function() return getBarPosY(pfx) == y_pct end,
            callback = function() SUISettings:saveSetting(pfx .. BAR_POS_Y_KEY, y_pct) refresh() end,
        })
    end

    local toggle_items = {}
    local active_dict = getActiveStatsDict(pfx)
    for _, key in ipairs(_resolveStatOrder(SUISettings:readSetting(pfx .. STAT_ORDER_KEY))) do
        table.insert(toggle_items, {
            text_func = function()
                local d = getActiveStatsDict(pfx)
                return (d[key] and "[✔] " or "[✗] ") .. (_STAT_LABELS[key] or key)
            end,
            keep_menu_open = true,
            callback = function()
                local d = getActiveStatsDict(pfx)
                d[key] = not d[key]
                SUISettings:saveSetting(pfx .. ACTIVE_STATS_KEY, d)
                refresh()
            end
        })
    end

    return {
        Config.makeScaleItem({
            text_func    = function() return _lc("Scale") end, enabled_func = function() return not Config.isScaleLinked() end,
            title        = _lc("Scale"), info = _lc("Scale for this module.\n100% is the default size."),
            get          = function() return Config.getModuleScalePct("currently_yanllsama", pfx) end, set = function(v) Config.setModuleScale(v, "currently_yanllsama", pfx) end, refresh = refresh,
        }),
        Config.makeScaleItem({
            text_func = function() return _lc("Cover size") end, title = _lc("Cover size"), info = _lc("Scale for the cover thumbnail only.\n100% is the default size."),
            get       = function() return Config.getThumbScalePct("currently_yanllsama", pfx) end, set = function(v) Config.setThumbScale(v, "currently_yanllsama", pfx) end, refresh   = refresh,
        }),
        Config.makeScaleItem({
            text_func = function() local pct = getCoverGapPct(pfx); return pct == 100 and _lc("Cover Spacing") or string.format("%s (%d%%)", _lc("Cover Spacing"), pct) end,
            separator = true, title = _lc("Cover Spacing"), info = _lc("Horizontal space between the cover and the text.\n100% is the default spacing."),
            get       = function() return getCoverGapPct(pfx) end, set = function(v) SUISettings:saveSetting(pfx .. COVER_GAP_KEY, v) end, refresh   = refresh, value_min = 0, value_max = 300, value_step = 10, default_value = 100,
        }),
        Config.makeLabelToggleItem("currently_yanllsama", _("Currently Reading"), refresh, _lc),
        
        {
            text = _lc("Statistics Layout & Appearance"),
            sub_item_table = {
                {
                    text = _lc("Book Source"),
                    sub_item_table = {
                        { text = _lc("Recent"), radio = true, keep_menu_open = true, checked_func = function() return getSource(pfx) == "recent" end, callback = function() SUISettings:saveSetting(pfx .. SETTING_SOURCE, "recent") refresh() end },
                        { text = _lc("To Be Read (TBR)"), radio = true, keep_menu_open = true, checked_func = function() return getSource(pfx) == "tbr" end, callback = function() SUISettings:saveSetting(pfx .. SETTING_SOURCE, "tbr") refresh() end },
                    }
                },
                {
                    text_func = function() return string.format("%s: %d", _lc("Daily Page Goal"), getDailyPageGoal(pfx)) end,
                    callback = function()
                        local SpinWidget = require("ui/widget/spinwidget")
                        UIManager:show(SpinWidget:new{
                            value = getDailyPageGoal(pfx),
                            value_min = 10,
                            value_max = 500,
                            value_step = 10,
                            title_text = _lc("Daily Page Goal"),
                            ok_text = _lc("Save"),
                            callback = function(spin)
                                SUISettings:saveSetting(pfx .. DAILY_PAGE_GOAL_KEY, spin.value)
                                refresh()
                            end
                        })
                    end,
                },
                {
                    text = _lc("Edit Statistics Items"),
                    sub_item_table = {
                        { text = _lc("Toggle Visibility"), sub_item_table = toggle_items },
                        {
                            text = _lc("Sort Items"), keep_menu_open = true,
                            callback = function()
                                local sort_items = {}
                                for _, key in ipairs(_resolveStatOrder(SUISettings:readSetting(pfx .. STAT_ORDER_KEY))) do
                                    table.insert(sort_items, { text = _STAT_LABELS[key] or key, orig_item = key })
                                end
                                UIManager:show(SortWidget:new{
                                    title = _lc("Sort Statistics"), item_table = sort_items, covers_fullscreen = true,
                                    callback = function()
                                        local new_order = {}
                                        for _, item in ipairs(sort_items) do table.insert(new_order, item.orig_item) end
                                        SUISettings:saveSetting(pfx .. STAT_ORDER_KEY, new_order) refresh()
                                    end,
                                })
                            end,
                        }
                    }
                },
                {
                    text = _lc("Grid Settings"),
                    sub_item_table = {
                        {
                            text = _lc("Grid Dimensions"),
                            sub_item_table = {
                                { text = _lc("Columns"), sub_item_table = makeCountMenu(GRID_COLS_KEY, 1, 3, 2) },
                                { text = _lc("Rows"), sub_item_table = makeCountMenu(GRID_ROWS_KEY, 1, 5, 4) },
                            },
                        },
                        {
                            text = _lc("Category Headers"),
                            sub_item_table = {
                                {
                                    text_func = function() return getShowHeaders(pfx) and _lc("Show Headers: On") or _lc("Show Headers: Off") end,
                                    keep_menu_open = true, callback = function() SUISettings:saveSetting(pfx .. SHOW_HEADERS_KEY, not getShowHeaders(pfx)) refresh() end,
                                },
                                {
                                    text = _lc("Header Thickness"),
                                    sub_item_table = {
                                        { text = _lc("Thin"), radio = true, keep_menu_open = true, checked_func = function() return getHeaderWeight(pfx) == "thin" end, callback = function() SUISettings:saveSetting(pfx .. HEADER_WEIGHT_KEY, "thin") refresh() end },
                                        { text = _lc("Medium"), radio = true, keep_menu_open = true, checked_func = function() return getHeaderWeight(pfx) == "medium" end, callback = function() SUISettings:saveSetting(pfx .. HEADER_WEIGHT_KEY, "medium") refresh() end },
                                        { text = _lc("Bold"), radio = true, keep_menu_open = true, checked_func = function() return getHeaderWeight(pfx) == "bold" end, callback = function() SUISettings:saveSetting(pfx .. HEADER_WEIGHT_KEY, "bold") refresh() end },
                                    }
                                },
                                {
                                    text = _lc("Change Column 1 Header"),
                                    callback = function()
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = _lc("Column 1 Header"), input = getHeaderTxt(pfx, 1),
                                            buttons = {{
                                                { text = _lc("Cancel"), callback = function() UIManager:close(dlg) end },
                                                { text = _lc("Save"), is_enter_default = true, callback = function() SUISettings:saveSetting(pfx .. HEADER_TXT_PFX .. "1", dlg:getInputText()); UIManager:close(dlg); refresh() end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text = _lc("Change Column 2 Header"),
                                    callback = function()
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = _lc("Column 2 Header"), input = getHeaderTxt(pfx, 2),
                                            buttons = {{
                                                { text = _lc("Cancel"), callback = function() UIManager:close(dlg) end },
                                                { text = _lc("Save"), is_enter_default = true, callback = function() SUISettings:saveSetting(pfx .. HEADER_TXT_PFX .. "2", dlg:getInputText()); UIManager:close(dlg); refresh() end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text = _lc("Change Column 3 Header"),
                                    callback = function()
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = _lc("Column 3 Header"), input = getHeaderTxt(pfx, 3),
                                            buttons = {{
                                                { text = _lc("Cancel"), callback = function() UIManager:close(dlg) end },
                                                { text = _lc("Save"), is_enter_default = true, callback = function() SUISettings:saveSetting(pfx .. HEADER_TXT_PFX .. "3", dlg:getInputText()); UIManager:close(dlg); refresh() end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                            }
                        },
                    }
                },
                {
                    text = _lc("Text and Font Settings"), separator = true,
                    sub_item_table = {
                        {
                            text = _lc("Book and Author"),
                            sub_item_table = {
                                { text = _lc("Book Title Font"), sub_item_table = makeFontMenu(TITLE_FONT_KEY, "NotoSerif") },
                                { text = _lc("Book Title Size"), sub_item_table = makeSizeMenu(TITLE_FS_KEY, 24, 60, 2) },
                                { text = _lc("Author Name Font"), sub_item_table = makeFontMenu(AUTHOR_FONT_KEY, "NotoSerif") },
                                { text = _lc("Author Name Size"), sub_item_table = makeSizeMenu(AUTHOR_FS_KEY, 20, 60, 2) },
                            }
                        },
                        {
                            text = _lc("Data"),
                            sub_item_table = {
                                { text = _lc("Number Font"), sub_item_table = makeFontMenu(VAL_FONT_KEY, "NotoSerif") },
                                { text = _lc("Number Size"), sub_item_table = makeSizeMenu(VAL_FS_KEY, 30, 60, 2) },
                                { text_func = function() return getValBold(pfx) and _lc("Number Weight: Bold") or _lc("Number Weight: Normal") end, keep_menu_open = true, callback = function() SUISettings:saveSetting(pfx .. VAL_BOLD_KEY, not getValBold(pfx)) refresh() end },
                            }
                        },
                        {
                            text = _lc("Label"),
                            sub_item_table = {
                                { text = _lc("Label Font"), sub_item_table = makeFontMenu(LBL_FONT_KEY, "x_smallinfofont") },
                                { text = _lc("Label Size"), sub_item_table = makeSizeMenu(LBL_FS_KEY, 16, 60, 2) },
                                { text_func = function() return getLblBold(pfx) and _lc("Label Weight: Bold") or _lc("Label Weight: Normal") end, keep_menu_open = true, callback = function() SUISettings:saveSetting(pfx .. LBL_BOLD_KEY, not getLblBold(pfx)) refresh() end },
                            }
                        }
                    }
                },
                {
                    text = _lc("Vertical Bar Settings"),
                    sub_item_table = {
                        {
                            text = _lc("Bar Size"),
                            sub_item_table = bar_height_menu
                        },

                        {
                            text = _lc("Bar Thickness"),
                            sub_item_table = {
                                { text = _lc("Level 1 (Thin)"), radio = true, keep_menu_open = true, checked_func = function() return getBarThickness(pfx) == 1 end, callback = function() SUISettings:saveSetting(pfx .. BAR_THICKNESS_KEY, 1) refresh() end },
                                { text = _lc("Level 2 (Normal)"), radio = true, keep_menu_open = true, checked_func = function() return getBarThickness(pfx) == 2 end, callback = function() SUISettings:saveSetting(pfx .. BAR_THICKNESS_KEY, 2) refresh() end },
                                { text = _lc("Level 3 (Bold)"), radio = true, keep_menu_open = true, checked_func = function() return getBarThickness(pfx) == 3 end, callback = function() SUISettings:saveSetting(pfx .. BAR_THICKNESS_KEY, 3) refresh() end },
                                { text = _lc("Level 4 (Extra Bold)"), radio = true, keep_menu_open = true, checked_func = function() return getBarThickness(pfx) == 4 end, callback = function() SUISettings:saveSetting(pfx .. BAR_THICKNESS_KEY, 4) refresh() end },
                            }
                        },
                        { text = _lc("Bar Label Font"), sub_item_table = makeFontMenu(BAR_LBL_FONT_KEY, "NotoSans") },
                        { text = _lc("Bar Label Size"), sub_item_table = makeSizeMenu(BAR_LBL_FS_KEY, 10, 30, 2, 6) },
                        { text_func = function() return getBarLblBold(pfx) and _lc("Label Weight: Bold") or _lc("Label Weight: Normal") end, keep_menu_open = true, callback = function() SUISettings:saveSetting(pfx .. BAR_LBL_BOLD_KEY, not getBarLblBold(pfx)) refresh() end },
                    }
                },
                {
                    text_func = function() local fmt = getTimeFmt(pfx); local lbl = (fmt == FMT_XHYM) and "XhYm" or _lc("Readable"); return string.format("%s \u{2014} %s", _lc("Time Format"), lbl) end,
                    sub_item_table = {
                        { text = _lc("Readable (e.g., 3.5 hours)"), radio = true, keep_menu_open = true, checked_func = function() return getTimeFmt(pfx) ~= FMT_XHYM end, callback = function() SUISettings:saveSetting(pfx .. SK_TIME_FMT, FMT_NICKEL) refresh() end },
                        { text = _lc("XhYm (e.g., 3h 30 min)"), radio = true, keep_menu_open = true, checked_func = function() return getTimeFmt(pfx) == FMT_XHYM end, callback = function() SUISettings:saveSetting(pfx .. SK_TIME_FMT, FMT_XHYM) refresh() end },
                    },
                },
            }
        },
        {
            text_func = function()
                local raw = SUISettings:readSetting(pfx .. SK_EXCLUDE_PATHS) or ""
                if raw == "" then return _lc("Exclude Paths from Recents") end
                local n = 0; for _ in raw:gmatch("[^,\n]+") do n = n + 1 end
                return string.format("%s (%d)", _lc("Exclude Paths from Recents"), n)
            end,
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local raw = SUISettings:readSetting(pfx .. SK_EXCLUDE_PATHS) or ""
                local dlg
                dlg = InputDialog:new{
                    title       = _lc("Exclude Paths from Recents"),
                    input       = raw,
                    input_hint  = "/mnt/onboard/rss, instapaper",
                    description = _lc("Comma separated path fragments.\nBooks containing any of these fragments in their path will be skipped."),
                    allow_newline = false,
                    buttons = {
                        {
                            {
                                text = _lc("Cancel"),
                                background = Blitbuffer.COLOR_WHITE,
                                callback = function()
                                    UIManager:close(dlg)
                                end,
                            },
                            {
                                text = _lc("Save"),
                                background = Blitbuffer.COLOR_WHITE,
                                is_enter_default = true,
                                callback = function()
                                    SUISettings:saveSetting(pfx .. SK_EXCLUDE_PATHS, dlg:getInputText())
                                    _cache = nil
                                    UIManager:close(dlg)
                                    refresh()
                                end,
                            },
                        },
                    },
                }
                UIManager:show(dlg)
                dlg:onShowKeyboard()
            end,
        },
    }
end

function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Currently Reading"))

    local SH = getSH()
    if not SH then return nil end

    local c     = ctx.cfg and ctx.cfg.currently_yanllsama
    local pfx   = ctx.pfx or ""
    
    local main_fp = _getCurrentFP(ctx, pfx)
    if not main_fp then return nil end

    local excludes = getExcludePaths(pfx)
    local fps = { main_fp }
    local source = getSource(pfx)
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
        for _, fp in ipairs(source_fps) do
            if not seen[fp] and not isExcluded(fp, excludes) then
                fps[#fps+1] = fp
                seen[fp] = true
                if #fps >= 5 then break end
            end
        end
    end

    local curIdx = ctx.yanllsama_cur_idx or 1
    if curIdx > #fps then curIdx = 1 end
    ctx.yanllsama_cur_idx = curIdx
    
    local current_fp = fps[curIdx]
    
    local scale = c and c.scale or Config.getModuleScale("currently_yanllsama", pfx)
    local thumb_scale = c and c.thumb_scale or Config.getThumbScale("currently_yanllsama", pfx)
    local lbl_scale   = c and c.lbl_scale   or Config.getItemLabelScale("currently_yanllsama", pfx)
    
    local cols = getGridCols(pfx)
    local rows = getGridRows(pfx)

    local D = SH.getDims(scale, thumb_scale)
    
    local prefetched_entry = ctx.prefetched and ctx.prefetched[current_fp]
    local bd    = SH.getBookData(current_fp, prefetched_entry)
    local cover = SH.getBookCover(current_fp, D.COVER_W, D.COVER_H, nil, 0.10)
                  or SH.coverPlaceholder(bd.title, bd.authors, D.COVER_W, D.COVER_H)

    -- Fix for missing MD5 checksums causing 0-stats
    local extracted_md5 = prefetched_entry and prefetched_entry.partial_md5_checksum
    pcall(function()
        local DS = package.loaded["docsettings"] or require("docsettings")
        if DS and require("libs/libkoreader-lfs").attributes(current_fp, "mode") == "file" then
            local ok, ds = pcall(DS.open, DS, current_fp)
            if ok and ds then
                extracted_md5 = extracted_md5 or ds:readSetting("partial_md5_checksum")
                bd.percent = bd.percent or ds:readSetting("percent_finished")
                
                local phys = ds:readSetting("yanllsama_physical_pages")
                if phys and tonumber(phys) and tonumber(phys) > 0 then
                    bd.pages = tonumber(phys)
                else
                    bd.pages = bd.pages or ds:readSetting("doc_pages")
                end
                pcall(function() ds:close() end)
            end
        end
    end)

    local stats = cacheGet(current_fp, pfx)
    if not stats then
        local book_meta = {
            fp = current_fp,
            title = bd.title or "",
            md5 = extracted_md5,
            percent = bd.percent or 0,
            pages = bd.pages or 0
        }
        stats = gatherStats(book_meta, pfx, ctx.db_conn)
        cachePut(current_fp, pfx, stats)
    end

    return _buildWidget(w, ctx, pfx, SH, bd, cover, stats, D, scale, lbl_scale, cols, rows, current_fp, fps, curIdx)
end

return M









