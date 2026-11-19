-- modules/currently_reading/stats.lua — SQLite reading statistics engine and caching layer.

local DataStorage = require("datastorage")

local C = require("modules/currently_reading/config")
local CFG           = C.CFG
local _             = C._
local fmtCount      = C.fmtCount
local emptyVal      = C.emptyVal
local fmtFraction   = C.fmtFraction
local pickFormatter = C.pickFormatter
local humanDayCount = C.humanDayCount

local M = {}

local _CACHE_TTL = 300
local _BOOK_CACHE_MAX = 25

local _book_cache = {}
local _book_cache_count = 0
local _book_cache_tick = 0
local _global_cache = nil

local function makeCacheKey(fp, pfx)
    return tostring(fp or "") .. "|" .. tostring(pfx or "") .. "|" .. tostring(CFG.getTimeFmt(pfx))
end

function M.isBookCached(fp, pfx)
    if not fp or fp == "" then return false end
    local entry = _book_cache[makeCacheKey(fp, pfx)]
    if not entry then return false end
    return (os.time() - entry.ts) <= _CACHE_TTL
end

function M.cacheGet(fp, pfx)
    if not fp or fp == "" then return nil end
    local key = makeCacheKey(fp, pfx)
    local entry = _book_cache[key]
    if not entry then return nil end
    if (os.time() - entry.ts) > _CACHE_TTL then
        _book_cache[key] = nil
        _book_cache_count = math.max(0, _book_cache_count - 1)
        return nil
    end
    _book_cache_tick = _book_cache_tick + 1
    entry.tick = _book_cache_tick
    return entry.stats
end

function M.cachePut(fp, pfx, stats)
    if not fp or fp == "" or not stats then return end
    local key = makeCacheKey(fp, pfx)
    if not _book_cache[key] then
        if _book_cache_count >= _BOOK_CACHE_MAX then
            local oldest_k, oldest_t
            for k, e in pairs(_book_cache) do
                if not oldest_t or e.tick < oldest_t then
                    oldest_k, oldest_t = k, e.tick
                end
            end
            if oldest_k then
                _book_cache[oldest_k] = nil
                _book_cache_count = _book_cache_count - 1
            end
        end
        _book_cache_count = _book_cache_count + 1
    end
    _book_cache_tick = _book_cache_tick + 1
    _book_cache[key] = { ts = os.time(), tick = _book_cache_tick, stats = stats }
end

function M.clearCache()
    _book_cache = {}
    _book_cache_count = 0
    _book_cache_tick = 0
    _global_cache = nil
end

local function getMaxSec()
    local ok, max = pcall(function() return tonumber(G_reader_settings:readSetting("statistics").max_sec) end)
    return (ok and max and max > 0) and max or 120
end

local function openStatsDB()
    local Config = C.getConfig and C.getConfig()
    if Config and type(Config.openStatsDB) == "function" then
        local ok_c, conn = pcall(Config.openStatsDB)
        if ok_c and conn then return conn end
    end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then return nil end
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local conn
    pcall(function() conn = SQ3.open(path) end)
    return conn
end

local function dbGetBookInfo(conn, md5)
    if not md5 then return nil, 0, 0 end
    local id, hl, nt
    pcall(function()
        local r = conn:exec(string.format(
            "SELECT id, highlights, notes FROM book WHERE md5 = '%s' ORDER BY last_open DESC LIMIT 1;",
            tostring(md5):gsub("'", "''")
        ))
        if r and r[1] and r[1][1] then
            id = tonumber(r[1][1])
            hl = tonumber(r[2] and r[2][1]) or 0
            nt = tonumber(r[3] and r[3][1]) or 0
        end
    end)
    return id, hl or 0, nt or 0
end

-- Gregorian calendar date -> integer Julian Day Number (timezone/DST safe)
local function ymdToJdn(y, m, d)
    local a = math.floor((14 - m) / 12)
    local y2 = y + 4800 - a
    local m2 = m + 12 * a - 3
    return d + math.floor((153 * m2 + 2) / 5) + 365 * y2
         + math.floor(y2 / 4) - math.floor(y2 / 100) + math.floor(y2 / 400) - 32045
end

-- Query distinct pages (using page_stat view semantics), duration, books, and active days since `since_ts` (nil = all-time)
local function queryPeriodStats(conn, since_ts)
    local where_pages = since_ts
        and string.format("WHERE start_time IN (SELECT start_time FROM page_stat_data WHERE start_time >= %d AND duration > 0)", since_ts)
        or "WHERE duration > 0"
    local pages_sql = string.format([[
        SELECT COUNT(*) FROM (
            SELECT 1 FROM page_stat %s GROUP BY id_book, page
        )
    ]], where_pages)
    local ok_ps, ps_res = pcall(function() return conn:rowexec(pages_sql) end)
    local pages
    if ok_ps and ps_res ~= nil then
        pages = tonumber(ps_res) or 0
    else
        local where_raw = since_ts
            and string.format("WHERE start_time >= %d AND duration > 0", since_ts)
            or "WHERE duration > 0"
        local raw_sql = string.format([[
            SELECT COUNT(*) FROM (
                SELECT 1 FROM page_stat_data %s GROUP BY id_book, page
            )
        ]], where_raw)
        pages = tonumber(conn:rowexec(raw_sql)) or 0
    end

    local where_agg = since_ts and string.format("WHERE start_time >= %d", since_ts) or ""
    local agg_sql = string.format([[
        SELECT COALESCE(sum(duration), 0),
               count(DISTINCT CASE WHEN duration > 0 THEN id_book END),
               count(DISTINCT CASE WHEN duration > 0 THEN strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') END)
        FROM page_stat_data %s
    ]], where_agg)
    local dur, books, days = conn:rowexec(agg_sql)
    return pages, tonumber(dur) or 0, tonumber(books) or 0, tonumber(days) or 0
end

-- Matches SimpleUI Reading Insights (_riGetAllTimeStats / pagesInYear) via infra/sui_stats_ledger.
local function queryLedgerYearAndAllTimePages(conn, cur_year)
    local Ledger = C.getSUIModule and C.getSUIModule("sui_stats_ledger", "infra")
    if not (Ledger and type(Ledger.get) == "function") then
        return nil, nil
    end
    local year_pages, all_pages
    local ok = pcall(function()
        local snap = Ledger.get(conn)
        if not snap then return end
        local yp = snap:pagesInYear(cur_year, conn)
        if type(yp) == "number" then
            year_pages = yp
        end
        local min_y, max_y = snap:yearRange()
        if min_y and max_y then
            local total = 0
            for y = min_y, max_y do
                local py = snap:pagesInYear(y, conn)
                if type(py) ~= "number" then
                    total = nil
                    break
                end
                total = total + py
            end
            if total then
                all_pages = total
            end
        end
    end)
    if not ok then
        return nil, nil
    end
    return year_pages, all_pages
end

function M.gatherStats(book, pfx, conn_ext)
    local fmt  = pickFormatter(pfx)
    local zero = fmt(0)
    local s = {
        book_progress           = emptyVal(),
        book_pages_read         = emptyVal(),
        book_time_spent         = zero,
        book_time_left          = zero,
        avg_time_per_day        = zero,
        pages_per_minute        = { value = fmtCount(0), unit = _("pages/min") },
        days_reading            = humanDayCount(0, "reading"),
        days_to_go              = humanDayCount(0, "to_go"),
        mins_per_session        = { value = "-", unit = _("mins/session") },
        pages_last_session      = { value = "-", unit = _("pages (last)") },
        today_pages             = { value = fmtCount(0), unit = _("pages") },
        today_time              = zero,
        seconds_per_page        = { value = "-", unit = _("sec/page") },
        days_since_start        = humanDayCount(0, "since_start"),
        started_date            = { value = "-", unit = "" },
        last_read_date          = { value = "-", unit = "" },
        estimated_finish_date   = { value = "-", unit = "" },
        total_sessions          = { value = fmtCount(0), unit = _("sessions") },
        reading_streak          = humanDayCount(0, "streak"),
        highlights_count        = { value = fmtCount(0), unit = _("highlights") },
        notes_count             = { value = fmtCount(0), unit = _("notes") },
        this_chapter_pages_left = { value = "-", unit = _("pages left") },
        this_chapter_time_left  = zero,
        week_pages              = { value = fmtCount(0), unit = _("pages") },
        week_time               = zero,
        week_books              = { value = fmtCount(0), unit = _("books") },
        week_days               = humanDayCount(0, "days"),
        month_pages             = { value = fmtCount(0), unit = _("pages") },
        month_time              = zero,
        month_books             = { value = fmtCount(0), unit = _("books") },
        month_days              = humanDayCount(0, "days"),
        year_pages              = { value = fmtCount(0), unit = _("pages") },
        year_time               = zero,
        year_books              = { value = fmtCount(0), unit = _("books") },
        year_days               = humanDayCount(0, "days"),
        all_time_pages          = { value = fmtCount(0), unit = _("pages") },
        all_time_time           = zero,
        all_time_books          = { value = fmtCount(0), unit = _("books") },
        all_time_days           = humanDayCount(0, "days"),

        -- Raw numeric fields for progress visuals
        today_pages_num    = 0,
        today_time_secs    = 0,
        today_time_mins    = 0,
        week_pages_num     = 0,
        week_time_secs     = 0,
        week_time_mins     = 0,
        month_pages_num    = 0,
        month_time_secs    = 0,
        month_time_mins    = 0,
        year_pages_num     = 0,
        year_time_secs     = 0,
        year_time_mins     = 0,
        year_books_num     = 0,
        all_time_pages_num = 0,
        all_time_time_secs = 0,
    }

    local pct      = (book and book.percent) or 0
    local pages    = (book and book.pages)   or 0
    local cur_page = (book and book.cur_page) or ((pages > 0) and math.max(1, math.floor(pct * pages)) or 0)

    local conn = conn_ext or openStatsDB()
    if not conn then
        if pages > 0 and cur_page > 0 then
            local real_pct = math.min(1.0, math.max(0.0, cur_page / pages))
            s.cur_page = cur_page
            s.total_pages = pages
            s.real_pct = real_pct
            local pct_int = math.floor(real_pct * 100 + 0.5)
            s.book_progress = { value = string.format("%d%%", pct_int), unit = "" }
            s.book_pages_read = { value = fmtFraction(cur_page, pages), unit = _("read") }
        elseif pct > 0 then
            s.real_pct = pct
            local pct_int = math.floor(pct * 100 + 0.5)
            s.book_progress = { value = string.format("%d%%", pct_int), unit = "" }
        end
        return s
    end

    local book_id, book_hl, book_nt = nil, 0, 0
    if book and book.md5 then
        book_id, book_hl, book_nt = dbGetBookInfo(conn, book.md5)
    end

    local max_sec = getMaxSec()
    local ts = nil
    local total_days = nil
    local session_cnt = 0
    local last_session_pages = nil
    local min_st, max_st = nil, nil

    if book_id then
        pcall(function()
            local rows = conn:exec(string.format(
                "SELECT page, start_time, duration FROM page_stat_data WHERE id_book = %d ORDER BY start_time ASC, page ASC;",
                book_id
            ))
            if rows and rows[1] then
                local pg_col  = rows[1]
                local st_col  = rows[2]
                local dur_col = rows[3]
                local page_dur = {}
                local active_days = {}
                local hour_day_cache = {}
                local prev_end = nil
                local last_st, last_pg = -1, -1
                local cur_all_day = nil
                local last_day_pages = {}
                local has_last_day_pages = false

                for i = 1, #pg_col do
                    local pg  = tonumber(pg_col[i]) or 0
                    local st  = tonumber(st_col and st_col[i]) or 0
                    local dur = tonumber(dur_col and dur_col[i]) or 0

                    page_dur[pg] = (page_dur[pg] or 0) + dur

                    if st > last_st or (st == last_st and pg > last_pg) then
                        last_st = st
                        last_pg = pg
                    end

                    if st > 0 then
                        if not min_st or st < min_st then min_st = st end
                        if not max_st or st > max_st then max_st = st end

                        if not prev_end or (st - prev_end) > 1800 then
                            session_cnt = session_cnt + 1
                        end
                        prev_end = math.max(prev_end or 0, st + dur)

                        local hb = math.floor(st / 3600)
                        local d_str = hour_day_cache[hb]
                        if not d_str then
                            d_str = os.date("%Y-%m-%d", st)
                            hour_day_cache[hb] = d_str
                        end
                        if dur > 0 then
                            active_days[d_str] = true
                        end
                        if d_str ~= cur_all_day then
                            cur_all_day = d_str
                            last_day_pages = {}
                        end
                        last_day_pages[pg] = true
                        has_last_day_pages = true
                    end
                end

                if last_pg > 0 then
                    cur_page = last_pg
                end

                local utt, ctt, rp = 0, 0, 0
                for _, pd in pairs(page_dur) do
                    utt = utt + pd
                    ctt = ctt + ((pd > max_sec) and max_sec or pd)
                    rp  = rp + 1
                end
                if rp > 0 then
                    ts = {
                        uncapped_time = utt,
                        capped_time   = ctt,
                        read_pages    = rp,
                        avg_time      = (ctt > 0) and (ctt / rp) or nil,
                    }
                end

                local nd = 0
                for _ in pairs(active_days) do nd = nd + 1 end
                if nd > 0 then total_days = nd end

                if has_last_day_pages then
                    local lp_cnt = 0
                    for _ in pairs(last_day_pages) do lp_cnt = lp_cnt + 1 end
                    last_session_pages = lp_cnt
                end
            end

            s.highlights_count = { value = fmtCount(book_hl), unit = _("highlights") }
            s.notes_count      = { value = fmtCount(book_nt), unit = _("notes") }
        end)
    end

    -- If ReaderUI is currently open with this book, take live page
    pcall(function()
        local RUI = package.loaded["apps/reader/readerui"]
        local rui = RUI and RUI.instance
        if rui and rui.document and book and (rui.file == book.fp or not book.fp) then
            local cp = rui:getCurrentPage()
            local tp = rui.document:getPageCount()
            if cp and cp > 0 then cur_page = cp end
            if tp and tp > 0 then pages = tp end
        end
    end)

    if pages > 0 and cur_page > 0 then
        local real_pct = math.min(1.0, math.max(0.0, cur_page / pages))
        pct = real_pct
        s.cur_page = cur_page
        s.total_pages = pages
        s.real_pct = real_pct
        local pct_int = math.floor(real_pct * 100 + 0.5)
        s.book_progress = { value = string.format("%d%%", pct_int), unit = "" }
        s.book_pages_read = { value = fmtFraction(cur_page, pages), unit = _("read") }
    else
        s.real_pct = pct
        if pct > 0 then
            local pct_int = math.floor(pct * 100 + 0.5)
            s.book_progress = { value = string.format("%d%%", pct_int), unit = "" }
        end
        if pages > 0 then
            s.book_pages_read = { value = fmtFraction(cur_page, pages), unit = _("read") }
        end
    end

    -- -----------------------------------------------------------------------
    -- 1. Global Period Stats (Today, Week, Month, Year, All-Time) & Streak
    -- Cached independently of book identity so switching books in the cover
    -- deck skips all 7 full-table SQLite scans.
    -- -----------------------------------------------------------------------
    local t = os.date("*t")
    local now_ts = os.time()
    local gkey = tostring(pfx or "") .. "|" .. tostring(CFG.getTimeFmt(pfx))
    local g_hit = _global_cache and _global_cache.key == gkey and (now_ts - _global_cache.ts) <= _CACHE_TTL
    if g_hit then
        for k, v in pairs(_global_cache.data) do
            s[k] = v
        end
    else
        local start_today = os.time{ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 }

        local ok_g = pcall(function()
            local tp, tt = queryPeriodStats(conn, start_today)
            s.today_pages_num = tp
            s.today_pages     = { value = fmtCount(tp), unit = _("pages") }
            s.today_time_secs = tt
            s.today_time_mins = math.floor(tt / 60 + 0.5)
            s.today_time      = fmt(tt)

            -- ISO Monday-start week: Lua wday Sun=1..Sat=7 -> Mon=0..Sun=6
            local w_wday = (t.wday + 5) % 7
            local start_week = start_today - (w_wday * 86400)
            local wp, wt, wb, wd = queryPeriodStats(conn, start_week)
            s.week_pages_num = wp
            s.week_time_secs = wt
            s.week_time_mins = math.floor(wt / 60 + 0.5)
            s.week_pages     = { value = fmtCount(wp), unit = _("pages") }
            s.week_time      = fmt(wt)
            s.week_books     = { value = fmtCount(wb), unit = _("books") }
            s.week_days      = humanDayCount(wd, "days")

            local start_month = os.time{ year = t.year, month = t.month, day = 1, hour = 0, min = 0, sec = 0 }
            local mp, mt, mb, md = queryPeriodStats(conn, start_month)
            s.month_pages_num = mp
            s.month_time_secs = mt
            s.month_time_mins = math.floor(mt / 60 + 0.5)
            s.month_pages     = { value = fmtCount(mp), unit = _("pages") }
            s.month_time      = fmt(mt)
            s.month_books     = { value = fmtCount(mb), unit = _("books") }
            s.month_days      = humanDayCount(md, "days")

            local start_year = os.time{ year = t.year, month = 1, day = 1, hour = 0, min = 0, sec = 0 }
            local yp, yt, yb, yd = queryPeriodStats(conn, start_year)
            local ap, at, ab, ad = queryPeriodStats(conn, nil)
            local ledger_yp, ledger_ap = queryLedgerYearAndAllTimePages(conn, t.year)
            if type(ledger_yp) == "number" then yp = ledger_yp end
            if type(ledger_ap) == "number" then ap = ledger_ap end

            s.year_pages_num = yp
            s.year_time_secs = yt
            s.year_time_mins = math.floor(yt / 60 + 0.5)
            s.year_books_num = yb
            s.year_pages     = { value = fmtCount(yp), unit = _("pages") }
            s.year_time      = fmt(yt)
            s.year_books     = { value = fmtCount(yb), unit = _("books") }
            s.year_days      = humanDayCount(yd, "days")

            s.all_time_pages_num = ap
            s.all_time_time_secs = at
            s.all_time_pages     = { value = fmtCount(ap), unit = _("pages") }
            s.all_time_time      = fmt(at)
            s.all_time_books     = { value = fmtCount(ab), unit = _("books") }
            s.all_time_days      = humanDayCount(ad, "days")
        end)

        -- Global Daily Reading Streak across all books
        pcall(function()
            local rows_st = conn:exec([[
                SELECT DISTINCT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') AS d_str
                FROM page_stat_data
                WHERE duration > 0
                ORDER BY d_str ASC
            ]])
            if rows_st and rows_st[1] then
                local day_nums = {}
                for _, ds in ipairs(rows_st[1]) do
                    if ds then
                        local y, m, d = ds:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
                        if y and m and d then
                            day_nums[#day_nums + 1] = ymdToJdn(tonumber(y), tonumber(m), tonumber(d))
                        end
                    end
                end
                local today_jdn = ymdToJdn(t.year, t.month, t.day)
                local streak_days = 0
                if #day_nums > 0 and (day_nums[#day_nums] == today_jdn or day_nums[#day_nums] == today_jdn - 1) then
                    streak_days = 1
                    for i = #day_nums - 1, 1, -1 do
                        if day_nums[i] == day_nums[i + 1] - 1 then
                            streak_days = streak_days + 1
                        else
                            break
                        end
                    end
                end
                s.reading_streak = humanDayCount(streak_days, "streak")
            end
        end)

        if ok_g then
            _global_cache = {
                key = gkey,
                ts  = now_ts,
                data = {
                    today_pages_num    = s.today_pages_num,
                    today_pages        = s.today_pages,
                    today_time_secs    = s.today_time_secs,
                    today_time_mins    = s.today_time_mins,
                    today_time         = s.today_time,
                    week_pages_num     = s.week_pages_num,
                    week_time_secs     = s.week_time_secs,
                    week_time_mins     = s.week_time_mins,
                    week_pages         = s.week_pages,
                    week_time          = s.week_time,
                    week_books         = s.week_books,
                    week_days          = s.week_days,
                    month_pages_num    = s.month_pages_num,
                    month_time_secs    = s.month_time_secs,
                    month_time_mins    = s.month_time_mins,
                    month_pages        = s.month_pages,
                    month_time         = s.month_time,
                    month_books        = s.month_books,
                    month_days         = s.month_days,
                    year_pages_num     = s.year_pages_num,
                    year_time_secs     = s.year_time_secs,
                    year_time_mins     = s.year_time_mins,
                    year_books_num     = s.year_books_num,
                    year_pages         = s.year_pages,
                    year_time          = s.year_time,
                    year_books         = s.year_books,
                    year_days          = s.year_days,
                    all_time_pages_num = s.all_time_pages_num,
                    all_time_time_secs = s.all_time_time_secs,
                    all_time_pages     = s.all_time_pages,
                    all_time_time      = s.all_time_time,
                    all_time_books     = s.all_time_books,
                    all_time_days      = s.all_time_days,
                    reading_streak     = s.reading_streak,
                },
            }
        end
    end

    if min_st and min_st > 0 then
        local mt = os.date("*t", min_st)
        s.started_date = { value = string.format("%04d-%02d-%02d", mt.year, mt.month, mt.day), unit = "" }
        local days_since = ymdToJdn(t.year, t.month, t.day) - ymdToJdn(mt.year, mt.month, mt.day)
        if days_since >= 0 then
            s.days_since_start = humanDayCount(days_since, "since_start")
        end
    end
    if max_st and max_st > 0 then
        s.last_read_date = { value = os.date("%Y-%m-%d", max_st), unit = "" }
    end

    if not conn_ext then pcall(function() conn:close() end) end

    if session_cnt > 0 then
        s.total_sessions = { value = fmtCount(session_cnt), unit = _("sessions") }
    end

    if ts and ts.uncapped_time and ts.uncapped_time > 0 then
        s.book_time_spent = fmt(ts.uncapped_time)
        if session_cnt > 0 then
            s.mins_per_session.value = fmtCount(math.floor(ts.uncapped_time / 60 / session_cnt))
        end
    end

    if last_session_pages and tonumber(last_session_pages) then
        s.pages_last_session.value = fmtCount(tonumber(last_session_pages))
    end

    local avg_time   = ts and ts.avg_time
    local pages_left = (pages > 0) and math.max(0, pages - cur_page) or nil

    if avg_time and avg_time > 0 and pages_left and pages_left > 0 then
        s.book_time_left = fmt(pages_left * avg_time)
    end

    if avg_time and avg_time > 0 then
        s.seconds_per_page = { value = string.format("%d", math.floor(avg_time + 0.5)), unit = _("sec/page") }
        local ppm = 60 / avg_time
        s.pages_per_minute = {
            value = (ppm >= 1) and string.format("%.1f", ppm) or string.format("%.2f", ppm),
            unit  = _("pages/min"),
        }
    end

    if total_days and total_days > 0 and ts then
        s.days_reading = humanDayCount(total_days, "reading")
        if ts.uncapped_time and ts.uncapped_time > 0 then
            s.avg_time_per_day = fmt(ts.uncapped_time / total_days)
        end

        if avg_time and avg_time > 0 and pages_left and pages_left > 0 and ts.capped_time and ts.capped_time > 0 then
            local avg_per_day = ts.capped_time / total_days
            if avg_per_day > 0 then
                local days_to_finish = math.ceil((pages_left * avg_time) / avg_per_day)
                s.days_to_go = humanDayCount(days_to_finish, "to_go")
                s.estimated_finish_date = { value = os.date("%Y-%m-%d", os.time() + days_to_finish * 86400), unit = "" }
            end
        end
    end

    -- Chapter pages/time left using minimum TOC node page strictly > cp across full tree
    pcall(function()
        local RUI = package.loaded["apps/reader/readerui"]
        local rui = RUI and RUI.instance
        if rui and rui.document and book and (rui.file == book.fp or not book.fp) then
            local cp = rui:getCurrentPage() or cur_page
            local toc = rui.toc and rui.toc.toc
            if toc and cp and cp > 0 then
                local next_ch_page = nil
                local has_any_toc = false
                local function scanToc(items)
                    for _, node in ipairs(items) do
                        if node.page then
                            has_any_toc = true
                            if node.page > cp and (not next_ch_page or node.page < next_ch_page) then
                                next_ch_page = node.page
                            end
                        end
                        if node.subitems then scanToc(node.subitems) end
                    end
                end
                if type(toc) == "table" then scanToc(toc) end
                if has_any_toc then
                    local ch_left
                    if next_ch_page then
                        ch_left = next_ch_page - cp
                    elseif pages > 0 and pages >= cp then
                        ch_left = pages - cp
                    end
                    if ch_left and ch_left >= 0 then
                        s.this_chapter_pages_left = { value = fmtCount(ch_left), unit = _("pages left") }
                        if avg_time and avg_time > 0 then
                            s.this_chapter_time_left = fmt(ch_left * avg_time)
                        end
                    end
                end
            end
        end
    end)

    s.cur_page = cur_page
    s.total_pages = pages
    s.real_pct = pct

    return s
end

return M
