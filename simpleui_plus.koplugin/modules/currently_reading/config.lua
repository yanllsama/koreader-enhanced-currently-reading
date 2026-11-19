-- modules/currently_reading/config.lua — Configuration keys, goals, stat catalog, and formatting helpers.

local Device    = require("device")
local DataStorage = require("datastorage")
local Blitbuffer = require("ffi/blitbuffer")
local util      = require("util")
local Math      = require("optmath")

local function getSUIModule(short_name, folder)
    local candidates = {}
    if folder then table.insert(candidates, folder .. "/" .. short_name) end
    for _, f in ipairs({"engines", "features", "screens", "infra", "modules", "features/dialogs"}) do
        if f ~= folder then table.insert(candidates, f .. "/" .. short_name) end
    end
    table.insert(candidates, short_name)

    for _, path in ipairs(candidates) do
        local mod = package.loaded[path]
        if mod then return mod end
    end

    for _, path in ipairs(candidates) do
        local ok, m = pcall(require, path)
        if ok and m then
            package.loaded[path] = m
            package.loaded[short_name] = m
            return m
        end
    end

    return nil
end

local function ensureBentoCompat(cfg)
    if type(cfg) == "table" and type(cfg.getBentoWidth) ~= "function" then
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
            local SUISettings = package.loaded["infra/sui_store"] or package.loaded["sui_store"] or (function()
                local ok, s = pcall(require, "infra/sui_store"); return ok and s or nil
            end)()
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
                local SUISettings = package.loaded["infra/sui_store"] or package.loaded["sui_store"]
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
    end
    if type(cfg) == "table" then
        if type(cfg.applyLabelToggle) ~= "function" then
            cfg.applyLabelToggle = function(mod, default_label)
                if cfg.isLabelHidden and cfg.isLabelHidden(mod.id) then
                    mod.label = nil
                else
                    mod.label = default_label or mod.label
                end
            end
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
end

local SUI_i18n = getSUIModule("sui_i18n", "infra")
local _        = SUI_i18n and SUI_i18n.translate or require("gettext")

local function getSH()
    local mod = getSUIModule("module_books_shared", "modules")
    if mod then return mod end
    local ok, m = pcall(require, "desktop_modules/module_books_shared")
    if ok and m then return m end
    return nil
end

local function getSUIStyle()
    return getSUIModule("sui_style", "features")
end

local SUISettings = getSUIModule("sui_store", "infra")
local Config      = getSUIModule("sui_config", "infra")
local UI          = getSUIModule("sui_core", "infra")

if Config then ensureBentoCompat(Config) end

local function getStore()
    SUISettings = SUISettings or getSUIModule("sui_store", "infra")
    return SUISettings
end

local function getConfig()
    Config = Config or getSUIModule("sui_config", "infra")
    if Config then ensureBentoCompat(Config) end
    return Config
end

local CFG = {
    BAR_STYLE_KEY           = "yanllsama_bar_style",
    BAR_THICKNESS_KEY       = "yanllsama_bar_thickness",
    BAR_THICK_V2_KEY        = "yanllsama_bar_thick_v2",
    VBAR_THICKNESS_KEY      = "yanllsama_vbar_thickness",
    HBAR_THICKNESS_KEY      = "yanllsama_hbar_thickness",
    RING_VARIANT_KEY        = "yanllsama_ring_variant",
    VBAR_VARIANT_KEY        = "yanllsama_vbar_variant",
    HBAR_VARIANT_KEY        = "yanllsama_hbar_variant",
    BAR_HEIGHT_PCT_KEY      = "yanllsama_bar_height_pct",
    VBAR_HEIGHT_PCT_KEY     = "yanllsama_vbar_height_pct",
    HBAR_LENGTH_PCT_KEY     = "yanllsama_hbar_length_pct",
    BAR_GAP_PCT_KEY         = "yanllsama_bar_gap_pct",
    VBAR_GAP_PCT_KEY        = "yanllsama_vbar_gap_pct",
    HBAR_GAP_KEY            = "yanllsama_hbar_gap",
    BAR_POS_Y_KEY           = "yanllsama_bar_pos_y",
    BAR_LBL_FS_KEY          = "yanllsama_bar_lbl_fs",
    BAR_LBL_FONT_KEY        = "yanllsama_bar_lbl_font",
    BAR_LBL_BOLD_KEY        = "yanllsama_bar_lbl_bold",
    SETTING_SOURCE          = "yanllsama_source",
    SK_EXCLUDE_PATHS        = "yanllsama_exclude",
    SK_TIME_FMT             = "yanllsama_time_fmt",
    FMT_NICKEL              = "nickel",
    FMT_XHYM                = "xhym",

    -- Progress Visuals active list (max 3 items, ordered) & Goals
    ACTIVE_VISUALS_KEY      = "yanllsama_active_visuals",
    DAILY_PAGE_GOAL_KEY     = "yanllsama_daily_page_goal",
    DAILY_TIME_GOAL_KEY     = "yanllsama_daily_time_goal",
    WEEK_PAGE_GOAL_KEY      = "yanllsama_week_page_goal",
    WEEK_TIME_GOAL_KEY      = "yanllsama_week_time_goal",
    MONTH_PAGE_GOAL_KEY     = "yanllsama_month_page_goal",
    MONTH_TIME_GOAL_KEY     = "yanllsama_month_time_goal",
    YEAR_PAGE_GOAL_KEY      = "yanllsama_year_page_goal",
    YEAR_TIME_GOAL_KEY      = "yanllsama_year_time_goal",
    YEAR_BOOK_GOAL_KEY      = "yanllsama_year_book_goal",

    TITLE_POS_X_KEY         = "yanllsama_title_pos_x",
    TITLE_POS_Y_KEY         = "yanllsama_title_pos_y",
    STATS_POS_X_KEY         = "yanllsama_stats_pos_x",
    STATS_POS_Y_KEY         = "yanllsama_stats_pos_y",
    VISUALS_POS_X_KEY       = "yanllsama_visuals_pos_x",
    VISUALS_POS_Y_KEY       = "yanllsama_visuals_pos_y",
    COVER_GAP_KEY           = "yanllsama_cover_gap_pct",
    COVER_DECK_MODE_KEY     = "yanllsama_cover_deck_mode",
    GRID_COLS_KEY           = "yanllsama_grid_cols",
    GRID_ROWS_KEY           = "yanllsama_grid_rows",
    STAT_ORDER_KEY          = "yanllsama_stat_order",
    ACTIVE_STATS_KEY        = "yanllsama_active_stats",
    VAL_FS_KEY              = "yanllsama_val_fs",
    LBL_FS_KEY              = "yanllsama_lbl_fs",
    TITLE_FS_KEY            = "yanllsama_title_fs",
    AUTHOR_FS_KEY           = "yanllsama_author_fs",
    TITLE_LINE_GAP_KEY      = "yanllsama_title_line_gap",
    AUTHOR_GAP_KEY          = "yanllsama_author_gap",
    STAT_ROW_GAP_KEY        = "yanllsama_stat_row_gap",
    HDR_ROW_GAP_KEY         = "yanllsama_hdr_row_gap",
    LBL_GAP_KEY             = "yanllsama_lbl_gap",
    TITLE_COLOR_KEY         = "yanllsama_title_color",
    AUTHOR_COLOR_KEY        = "yanllsama_author_color",
    VAL_COLOR_KEY           = "yanllsama_val_color",
    LBL_COLOR_KEY           = "yanllsama_lbl_color",
    HDR_COLOR_KEY           = "yanllsama_hdr_color",
    STATS_BG_COLOR_KEY      = "yanllsama_stats_bg_color",
    BAR_LBL_COLOR_KEY       = "yanllsama_bar_lbl_color",
    VIS_COLOR_1_KEY         = "yanllsama_vis_color_1",
    VIS_COLOR_2_KEY         = "yanllsama_vis_color_2",
    VIS_COLOR_3_KEY         = "yanllsama_vis_color_3",
    VIS_TRACK_COLOR_KEY     = "yanllsama_vis_track_color",
    VAL_FONT_KEY            = "yanllsama_val_font",
    LBL_FONT_KEY            = "yanllsama_lbl_font",
    TITLE_FONT_KEY          = "yanllsama_title_font",
    AUTHOR_FONT_KEY         = "yanllsama_author_font",
    VAL_BOLD_KEY            = "yanllsama_val_bold",
    LBL_BOLD_KEY            = "yanllsama_lbl_bold",
    SHOW_HEADERS_KEY        = "yanllsama_show_headers",
    HEADER_TXT_PFX          = "yanllsama_hdr_txt_",
    HEADER_WEIGHT_KEY       = "yanllsama_header_weight",
    HEADER_STYLE_KEY        = "yanllsama_header_style",
    SHOW_STATS_BORDER_KEY   = "yanllsama_show_stats_border",
    SHOW_VISUALS_KEY        = "yanllsama_show_visuals",
    STATS_WIDTH_RATIO_KEY   = "yanllsama_stats_width_ratio",
    SHOW_VISUALS_BORDER_KEY = "yanllsama_show_visuals_border",
    SHOW_RING_LABELS_KEY    = "yanllsama_show_ring_labels",
    SIDE_MARGIN_KEY         = "yanllsama_side_margin",
    BORDER_RADIUS_KEY       = "yanllsama_border_radius",
    HEADER_RADIUS_KEY       = "yanllsama_header_radius_enabled",
    POS_WIN_SIZE_KEY        = "yanllsama_pos_win_size",
    POS_WIN_POS_KEY         = "yanllsama_pos_win_pos",

    PREVIEW_MODE_KEY        = "yanllsama_preview_mode",
    PREVIEW_TYPE_KEY        = "yanllsama_preview_type",
    PREVIEW_DURATION_KEY    = "yanllsama_preview_duration",
    PROFILES_KEY            = "yanllsama_profiles_v1",
    ACTIVE_PROFILE_KEY      = "yanllsama_active_profile",
    DEFAULT_PROFILE_KEY     = "yanllsama_default_profile",
    QUICK_PROFILES_KEY      = "yanllsama_quick_profiles",
    QUICK_SWITCH_ENABLED_KEY = "yanllsama_quick_switch_enabled",
}

CFG.MAX_VISUAL_ITEMS = 3
CFG.DEFAULT_VISUAL_ITEMS = { "daily_page", "book_progress" }

CFG.STAT_LABELS = {
    book_time_left          = _("Time Left"),
    book_pages_read         = _("Pages Read"),
    book_time_spent         = _("Time Spent"),
    pages_left              = _("Pages Left"),
    days_reading            = _("Days Reading"),
    days_to_go              = _("Days to Go"),
    avg_time_per_day        = _("Daily Average"),
    pages_per_minute        = _("Pages/Minute"),
    mins_per_session        = _("Mins/Session"),
    pages_last_session      = _("Last Session Pages"),
    today_pages             = _("Today's Pages"),
    today_time              = _("Today's Time"),
    seconds_per_page        = _("Sec/Page"),
    days_since_start        = _("Days Since Start"),
    started_date            = _("Started Date"),
    last_read_date          = _("Last Read Date"),
    estimated_finish_date   = _("Est. Finish Date"),
    total_sessions          = _("Total Sessions"),
    reading_streak          = _("Daily Streak"),
    highlights_count        = _("Highlights"),
    notes_count             = _("Notes"),
    this_chapter_pages_left = _("Chapter Pages Left"),
    this_chapter_time_left  = _("Chapter Time Left"),
    week_pages              = _("This Week's Pages"),
    week_time               = _("This Week's Time"),
    week_books              = _("This Week's Books"),
    week_days               = _("This Week's Days"),
    month_pages             = _("This Month's Pages"),
    month_time              = _("This Month's Time"),
    month_books             = _("This Month's Books"),
    month_days              = _("This Month's Days"),
    year_pages              = _("Yearly Pages (2026)"),
    year_time               = _("Yearly Time (2026)"),
    year_books              = _("Yearly Books (2026)"),
    year_days               = _("Yearly Days (2026)"),
    all_time_pages          = _("All-Time Pages"),
    all_time_time           = _("All-Time Duration"),
    all_time_books          = _("All-Time Books"),
    all_time_days           = _("All-Time Days"),
}

CFG.DEFAULT_STAT_ORDER = {
    "book_time_left", "book_pages_read",
    "book_time_spent", "pages_left",
    "days_reading", "days_to_go",
    "avg_time_per_day", "pages_per_minute",
    "mins_per_session", "pages_last_session",
    "today_pages", "today_time",
    "seconds_per_page", "days_since_start",
    "started_date", "last_read_date",
    "estimated_finish_date", "total_sessions",
    "reading_streak", "highlights_count",
    "notes_count", "this_chapter_pages_left",
    "this_chapter_time_left", "week_pages",
    "week_time", "week_books", "week_days",
    "month_pages", "month_time", "month_books", "month_days",
    "year_pages", "year_time", "year_books", "year_days",
    "all_time_pages", "all_time_time", "all_time_books", "all_time_days"
}

local STAT_GROUPS = {
    { id = "book_time_left",          group = _("This Book") },
    { id = "book_pages_read",         group = _("This Book") },
    { id = "book_time_spent",         group = _("This Book") },
    { id = "pages_left",              group = _("This Book") },
    { id = "this_chapter_pages_left", group = _("This Book") },
    { id = "this_chapter_time_left",  group = _("This Book") },
    { id = "days_reading",            group = _("This Book") },
    { id = "days_to_go",              group = _("This Book") },
    { id = "days_since_start",        group = _("This Book") },
    { id = "started_date",            group = _("This Book") },
    { id = "last_read_date",          group = _("This Book") },
    { id = "estimated_finish_date",   group = _("This Book") },
    { id = "total_sessions",          group = _("This Book") },
    { id = "pages_last_session",      group = _("This Book") },
    { id = "highlights_count",        group = _("This Book") },
    { id = "notes_count",             group = _("This Book") },

    { id = "avg_time_per_day",        group = _("Speed & Pace") },
    { id = "pages_per_minute",        group = _("Speed & Pace") },
    { id = "seconds_per_page",        group = _("Speed & Pace") },
    { id = "mins_per_session",        group = _("Speed & Pace") },

    { id = "today_pages",             group = _("Today & Streak") },
    { id = "today_time",              group = _("Today & Streak") },
    { id = "reading_streak",          group = _("Today & Streak") },

    { id = "week_pages",              group = _("This Week") },
    { id = "week_time",               group = _("This Week") },
    { id = "week_books",              group = _("This Week") },
    { id = "week_days",               group = _("This Week") },

    { id = "month_pages",             group = _("This Month") },
    { id = "month_time",              group = _("This Month") },
    { id = "month_books",             group = _("This Month") },
    { id = "month_days",              group = _("This Month") },

    { id = "year_pages",              group = _("Yearly") },
    { id = "year_time",               group = _("Yearly") },
    { id = "year_books",              group = _("Yearly") },
    { id = "year_days",               group = _("Yearly") },

    { id = "all_time_pages",          group = _("All-Time") },
    { id = "all_time_time",           group = _("All-Time") },
    { id = "all_time_books",          group = _("All-Time") },
    { id = "all_time_days",           group = _("All-Time") },
}

local STAT_GROUP_OF = {}
for _, g in ipairs(STAT_GROUPS) do
    STAT_GROUP_OF[g.id] = g.group
end

function CFG.getStatGroup(id)
    return STAT_GROUP_OF[id]
end

function CFG.getStatPool(_lc)
    local tr = _lc or _
    local pool = {}
    for _, entry in ipairs(STAT_GROUPS) do
        local lbl = CFG.STAT_LABELS[entry.id] or entry.id
        pool[#pool + 1] = {
            id    = entry.id,
            label = tr(lbl),
            group = tr(entry.group),
        }
    end
    return pool
end

-- Progress Visual Item Registry (used by both visuals renderer & menu picker)
local VISUAL_DEFS = {
    { id = "book_progress", label = _("Book Progress"),      short = _("Book"),       group = _("Book Progress"), kind = "book" },
    { id = "daily_page",    label = _("Daily Page Goal"),    short = _("Daily Pg"),   group = _("Daily Goals"),   kind = "pages", period = "day" },
    { id = "daily_time",    label = _("Daily Time Goal"),    short = _("Daily Min"),  group = _("Daily Goals"),   kind = "time",  period = "day" },
    { id = "week_pages",    label = _("Weekly Page Goal"),   short = _("Week Pg"),    group = _("Weekly Goals"),  kind = "pages", period = "week" },
    { id = "week_time",     label = _("Weekly Time Goal"),   short = _("Week Min"),   group = _("Weekly Goals"),  kind = "time",  period = "week" },
    { id = "month_pages",   label = _("Monthly Page Goal"),  short = _("Month Pg"),   group = _("Monthly Goals"), kind = "pages", period = "month" },
    { id = "month_time",    label = _("Monthly Time Goal"),  short = _("Month Min"),  group = _("Monthly Goals"), kind = "time",  period = "month" },
    { id = "year_pages",    label = _("Yearly Page Goal"),   short = _("Year Pg"),    group = _("Yearly Goals"),  kind = "pages", period = "year" },
    { id = "year_time",     label = _("Yearly Time Goal"),   short = _("Year Min"),   group = _("Yearly Goals"),  kind = "time",  period = "year" },
    { id = "year_books",    label = _("Yearly Book Goal"),   short = _("Year Books"), group = _("Yearly Goals"),  kind = "books", period = "year" },
}

local VISUAL_BY_ID = {}
for _, v in ipairs(VISUAL_DEFS) do
    VISUAL_BY_ID[v.id] = v
end

CFG.VISUAL_DEFS  = VISUAL_DEFS
CFG.VISUAL_BY_ID = VISUAL_BY_ID

function CFG.getVisualPool(_lc)
    local tr = _lc or _
    local pool = {}
    for _, v in ipairs(VISUAL_DEFS) do
        pool[#pool + 1] = {
            id    = v.id,
            label = tr(v.label),
            group = tr(v.group),
        }
    end
    return pool
end

function CFG.getActiveVisuals(pfx)
    local S = getStore()
    local saved = S and S:readSetting(pfx .. CFG.ACTIVE_VISUALS_KEY)
    if type(saved) ~= "table" then
        local def = {}
        for i, id in ipairs(CFG.DEFAULT_VISUAL_ITEMS) do def[i] = id end
        return def
    end
    local seen, out = {}, {}
    for _, id in ipairs(saved) do
        if VISUAL_BY_ID[id] and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
            if #out >= CFG.MAX_VISUAL_ITEMS then break end
        end
    end
    return out
end

function CFG.setActiveVisuals(pfx, ids)
    local S = getStore()
    if not S then return end
    local seen, out = {}, {}
    if type(ids) == "table" then
        for _, id in ipairs(ids) do
            if VISUAL_BY_ID[id] and not seen[id] then
                seen[id] = true
                out[#out + 1] = id
                if #out >= CFG.MAX_VISUAL_ITEMS then break end
            end
        end
    end
    S:saveSetting(pfx .. CFG.ACTIVE_VISUALS_KEY, out)
end

-- Style & visual thickness/size/gap getters/setters
function CFG.getBarStyle(pfx) return getStore():readSetting(pfx .. CFG.BAR_STYLE_KEY) or "rings" end

function CFG.getRingThickness(pfx)
    local S = getStore()
    local raw = tonumber(S:readSetting(pfx .. CFG.BAR_THICKNESS_KEY))
    if not raw then return 4 end
    if S:readSetting(pfx .. CFG.BAR_THICK_V2_KEY) ~= true then
        raw = math.max(1, math.min(4, math.floor(raw))) + 2
    end
    return math.max(1, math.min(6, math.floor(raw)))
end
function CFG.setRingThickness(pfx, v)
    local S = getStore()
    local clamped = math.max(1, math.min(6, math.floor(tonumber(v) or 4)))
    S:saveSetting(pfx .. CFG.BAR_THICKNESS_KEY, clamped)
    S:saveSetting(pfx .. CFG.BAR_THICK_V2_KEY, true)
end
CFG.getBarThickness = CFG.getRingThickness
CFG.setBarThickness = CFG.setRingThickness

function CFG.getVBarThickness(pfx)
    local S = getStore()
    local v = tonumber(S:readSetting(pfx .. CFG.VBAR_THICKNESS_KEY))
    if v ~= nil then return math.max(1, math.min(12, math.floor(v))) end
    if CFG.getBarStyle(pfx) == "bars" then
        local legacy = tonumber(S:readSetting(pfx .. CFG.BAR_THICKNESS_KEY))
        if legacy then return math.max(1, math.min(12, math.floor(legacy) + 3)) end
    end
    return 5
end
function CFG.setVBarThickness(pfx, v)
    getStore():saveSetting(pfx .. CFG.VBAR_THICKNESS_KEY, math.max(1, math.min(12, math.floor(tonumber(v) or 5))))
end

function CFG.getHBarThickness(pfx)
    local S = getStore()
    local v = tonumber(S:readSetting(pfx .. CFG.HBAR_THICKNESS_KEY))
    if v ~= nil then return math.max(1, math.min(12, math.floor(v))) end
    if CFG.getBarStyle(pfx) == "horizontal" then
        local legacy = tonumber(S:readSetting(pfx .. CFG.BAR_THICKNESS_KEY))
        if legacy then return math.max(1, math.min(12, math.floor(legacy) + 3)) end
    end
    return 5
end
function CFG.setHBarThickness(pfx, v)
    getStore():saveSetting(pfx .. CFG.HBAR_THICKNESS_KEY, math.max(1, math.min(12, math.floor(tonumber(v) or 5))))
end

function CFG.getRingVariant(pfx) return getStore():readSetting(pfx .. CFG.RING_VARIANT_KEY) or "classic" end
function CFG.getVBarVariant(pfx) return getStore():readSetting(pfx .. CFG.VBAR_VARIANT_KEY) or "capsule" end
function CFG.getHBarVariant(pfx) return getStore():readSetting(pfx .. CFG.HBAR_VARIANT_KEY) or "sui" end

function CFG.getBarHeightPct(pfx) return tonumber(getStore():readSetting(pfx .. CFG.BAR_HEIGHT_PCT_KEY)) or 100 end
function CFG.getBarGap(pfx) return tonumber(getStore():readSetting(pfx .. CFG.BAR_GAP_PCT_KEY)) or 15 end

function CFG.getVBarHeightPct(pfx)
    local S = getStore()
    local v = tonumber(S:readSetting(pfx .. CFG.VBAR_HEIGHT_PCT_KEY))
    if v ~= nil then return v end
    if CFG.getBarStyle(pfx) == "bars" then
        return tonumber(S:readSetting(pfx .. CFG.BAR_HEIGHT_PCT_KEY)) or 100
    end
    return 100
end
function CFG.getVBarGap(pfx)
    local S = getStore()
    local v = tonumber(S:readSetting(pfx .. CFG.VBAR_GAP_PCT_KEY))
    if v ~= nil then return v end
    if CFG.getBarStyle(pfx) == "bars" then
        return tonumber(S:readSetting(pfx .. CFG.BAR_GAP_PCT_KEY)) or 15
    end
    return 15
end

function CFG.getHBarLengthPct(pfx)
    local n = tonumber(getStore():readSetting(pfx .. CFG.HBAR_LENGTH_PCT_KEY)) or 100
    return math.max(25, math.min(100, math.floor(n)))
end
function CFG.getHBarGap(pfx)
    local v = getStore():readSetting(pfx .. CFG.HBAR_GAP_KEY)
    if v == nil then return 5 end
    local n = tonumber(v) or 5
    return math.max(0, math.min(40, math.floor(n)))
end
CFG.getBarGapPct = CFG.getBarGap
function CFG.getBarPosY(pfx) return tonumber(getStore():readSetting(pfx .. CFG.BAR_POS_Y_KEY)) or 0 end
function CFG.getBarLblFs(pfx) return tonumber(getStore():readSetting(pfx .. CFG.BAR_LBL_FS_KEY)) or 16 end
function CFG.getBarLblFont(pfx) return getStore():readSetting(pfx .. CFG.BAR_LBL_FONT_KEY) or "NotoSans" end
function CFG.getBarLblBold(pfx) local v = getStore():readSetting(pfx .. CFG.BAR_LBL_BOLD_KEY); if v == nil then return false else return v end end
function CFG.getSource(pfx) return getStore():readSetting(pfx .. CFG.SETTING_SOURCE) or "recent" end

-- Goal getters
function CFG.getDailyPageGoal(pfx) return math.max(1, tonumber(getStore():readSetting(pfx .. CFG.DAILY_PAGE_GOAL_KEY)) or 50) end
function CFG.getDailyTimeGoal(pfx) return math.max(1, tonumber(getStore():readSetting(pfx .. CFG.DAILY_TIME_GOAL_KEY)) or 30) end
function CFG.getWeekPageGoal(pfx)  return math.max(1, tonumber(getStore():readSetting(pfx .. CFG.WEEK_PAGE_GOAL_KEY)) or 300) end
function CFG.getWeekTimeGoal(pfx)  return math.max(1, tonumber(getStore():readSetting(pfx .. CFG.WEEK_TIME_GOAL_KEY)) or 240) end
function CFG.getMonthPageGoal(pfx) return math.max(1, tonumber(getStore():readSetting(pfx .. CFG.MONTH_PAGE_GOAL_KEY)) or 1000) end
function CFG.getMonthTimeGoal(pfx) return math.max(1, tonumber(getStore():readSetting(pfx .. CFG.MONTH_TIME_GOAL_KEY)) or 900) end
function CFG.getYearPageGoal(pfx)  return math.max(1, tonumber(getStore():readSetting(pfx .. CFG.YEAR_PAGE_GOAL_KEY)) or 10000) end
function CFG.getYearTimeGoal(pfx)  return math.max(1, tonumber(getStore():readSetting(pfx .. CFG.YEAR_TIME_GOAL_KEY)) or 6000) end
function CFG.getYearBookGoal(pfx)  return math.max(1, tonumber(getStore():readSetting(pfx .. CFG.YEAR_BOOK_GOAL_KEY)) or 12) end

function CFG.getCoverGapPct(pfx)
    local v = getStore():readSetting(pfx .. CFG.COVER_GAP_KEY)
    local n = tonumber(v)
    return n and math.max(0, math.min(300, math.floor(n))) or 100
end
function CFG.getCoverDeckMode(pfx) return tonumber(getStore():readSetting(pfx .. CFG.COVER_DECK_MODE_KEY)) or 5 end
function CFG.getTitlePosX(pfx) return tonumber(getStore():readSetting(pfx .. CFG.TITLE_POS_X_KEY)) or 0 end
function CFG.getTitlePosY(pfx) return tonumber(getStore():readSetting(pfx .. CFG.TITLE_POS_Y_KEY)) or 0 end
function CFG.getStatsPosX(pfx) return tonumber(getStore():readSetting(pfx .. CFG.STATS_POS_X_KEY)) or 0 end
function CFG.getStatsPosY(pfx) return tonumber(getStore():readSetting(pfx .. CFG.STATS_POS_Y_KEY)) or 0 end
function CFG.getVisualsPosX(pfx) return tonumber(getStore():readSetting(pfx .. CFG.VISUALS_POS_X_KEY)) or 0 end
function CFG.getVisualsPosY(pfx) return tonumber(getStore():readSetting(pfx .. CFG.VISUALS_POS_Y_KEY)) or 0 end
function CFG.getTimeFmt(pfx) return getStore():readSetting(pfx .. CFG.SK_TIME_FMT) == CFG.FMT_XHYM and CFG.FMT_XHYM or CFG.FMT_NICKEL end
function CFG.getGridCols(pfx)
    local v = tonumber(getStore():readSetting(pfx .. CFG.GRID_COLS_KEY))
    if not v then return 2 end
    return math.max(1, math.min(4, math.floor(v)))
end
function CFG.getGridRows(pfx) return tonumber(getStore():readSetting(pfx .. CFG.GRID_ROWS_KEY)) or 4 end
function CFG.getValFs(pfx) return tonumber(getStore():readSetting(pfx .. CFG.VAL_FS_KEY)) or 30 end
function CFG.getLblFs(pfx) return tonumber(getStore():readSetting(pfx .. CFG.LBL_FS_KEY)) or 16 end
local function getClampedInt(pfx, key, def, lo, hi)
    local v = getStore():readSetting(pfx .. key)
    if v == nil then return def end
    local n = tonumber(v)
    if not n then return def end
    return math.max(lo, math.min(hi, math.floor(n)))
end

function CFG.getTitleFs(pfx) return tonumber(getStore():readSetting(pfx .. CFG.TITLE_FS_KEY)) or 24 end
function CFG.getAuthorFs(pfx) return tonumber(getStore():readSetting(pfx .. CFG.AUTHOR_FS_KEY)) or 20 end
function CFG.getTitleLineGap(pfx) return getClampedInt(pfx, CFG.TITLE_LINE_GAP_KEY, 0, -20, 30) end
function CFG.getAuthorGap(pfx) return getClampedInt(pfx, CFG.AUTHOR_GAP_KEY, 0, -20, 30) end
function CFG.getStatRowGap(pfx) return getClampedInt(pfx, CFG.STAT_ROW_GAP_KEY, 0, -20, 30) end
function CFG.getHdrRowGap(pfx) return getClampedInt(pfx, CFG.HDR_ROW_GAP_KEY, 0, -15, 30) end
function CFG.getLblGap(pfx) return getClampedInt(pfx, CFG.LBL_GAP_KEY, 0, -10, 30) end

local function normalizeHex(hex)
    if type(hex) ~= "string" then return nil end
    local d = hex:match("^%s*#?(%x+)%s*$")
    if not d then return nil end
    if #d == 3 then
        d = d:gsub("%x", "%0%0")
    elseif #d ~= 6 then
        return nil
    end
    return "#" .. d:upper()
end

function CFG.getColorHex(pfx, key)
    if not key then return nil end
    return normalizeHex(getStore():readSetting(pfx .. key))
end

CFG.VIS_COLOR_KEYS = { CFG.VIS_COLOR_1_KEY, CFG.VIS_COLOR_2_KEY, CFG.VIS_COLOR_3_KEY }
CFG.ALL_COLOR_KEYS = {
    CFG.TITLE_COLOR_KEY, CFG.AUTHOR_COLOR_KEY, CFG.VAL_COLOR_KEY,
    CFG.LBL_COLOR_KEY, CFG.HDR_COLOR_KEY, CFG.STATS_BG_COLOR_KEY,
    CFG.BAR_LBL_COLOR_KEY, CFG.VIS_COLOR_1_KEY, CFG.VIS_COLOR_2_KEY,
    CFG.VIS_COLOR_3_KEY, CFG.VIS_TRACK_COLOR_KEY,
}

function CFG.hasAnyCustomColor(pfx)
    for _, k in ipairs(CFG.ALL_COLOR_KEYS) do
        if CFG.getColorHex(pfx, k) ~= nil then return true end
    end
    return false
end

function CFG.getVisColorHex(pfx, idx)
    local key = CFG.VIS_COLOR_KEYS[idx]
    return key and CFG.getColorHex(pfx, key) or nil
end
function CFG.getValFont(pfx) return getStore():readSetting(pfx .. CFG.VAL_FONT_KEY) or "NotoSerif" end
function CFG.getLblFont(pfx) return getStore():readSetting(pfx .. CFG.LBL_FONT_KEY) or "x_smallinfofont" end
function CFG.getTitleFont(pfx) return getStore():readSetting(pfx .. CFG.TITLE_FONT_KEY) or "NotoSerif" end
function CFG.getAuthorFont(pfx) return getStore():readSetting(pfx .. CFG.AUTHOR_FONT_KEY) or "NotoSerif" end
function CFG.getValBold(pfx) local v = getStore():readSetting(pfx .. CFG.VAL_BOLD_KEY); if v == nil then return true else return v end end
function CFG.getLblBold(pfx) return getStore():readSetting(pfx .. CFG.LBL_BOLD_KEY) or false end
function CFG.getShowHeaders(pfx) local v = getStore():readSetting(pfx .. CFG.SHOW_HEADERS_KEY); if v == nil then return true else return v end end
function CFG.getHeaderTxt(pfx, col_idx)
    local defaults = { _("THIS BOOK"), _("SPEED"), _("EXTRA 1"), _("EXTRA 2") }
    return getStore():readSetting(pfx .. CFG.HEADER_TXT_PFX .. tostring(col_idx)) or defaults[col_idx] or _("INFO")
end
function CFG.getHeaderWeight(pfx) return getStore():readSetting(pfx .. CFG.HEADER_WEIGHT_KEY) or "bold" end
function CFG.getHeaderStyle(pfx) return getStore():readSetting(pfx .. CFG.HEADER_STYLE_KEY) or "underline" end
function CFG.getShowStatsBorder(pfx) local v = getStore():readSetting(pfx .. CFG.SHOW_STATS_BORDER_KEY); if v == nil then return false else return v end end
function CFG.getShowVisuals(pfx) local v = getStore():readSetting(pfx .. CFG.SHOW_VISUALS_KEY); if v == nil then return true else return v end end
function CFG.getStatsWidthRatio(pfx) return tonumber(getStore():readSetting(pfx .. CFG.STATS_WIDTH_RATIO_KEY)) or 65 end
function CFG.getShowVisualsBorder(pfx) local v = getStore():readSetting(pfx .. CFG.SHOW_VISUALS_BORDER_KEY); if v == nil then return false else return v end end
function CFG.getShowRingLabels(pfx) local v = getStore():readSetting(pfx .. CFG.SHOW_RING_LABELS_KEY); if v == nil then return true else return v end end
function CFG.getPreviewMode(pfx) local v = getStore():readSetting(pfx .. CFG.PREVIEW_MODE_KEY); if v == nil then return true else return v end end
function CFG.getPreviewType(pfx) return getStore():readSetting(pfx .. CFG.PREVIEW_TYPE_KEY) or "button" end
function CFG.getPreviewDuration(pfx) return tonumber(getStore():readSetting(pfx .. CFG.PREVIEW_DURATION_KEY)) or 3 end
function CFG.getSideMargin(pfx)
    local v = getStore():readSetting(pfx .. CFG.SIDE_MARGIN_KEY)
    if v == nil then return 0 end
    local n = tonumber(v)
    return n and math.max(0, math.min(60, math.floor(n))) or 0
end
function CFG.getBorderRadius(pfx)
    local v = getStore():readSetting(pfx .. CFG.BORDER_RADIUS_KEY)
    if v == nil then return 10 end
    local n = tonumber(v)
    return n and math.max(0, math.min(30, math.floor(n))) or 10
end
function CFG.getHeaderRadiusEnabled(pfx)
    local v = getStore():readSetting(pfx .. CFG.HEADER_RADIUS_KEY)
    if v == nil then return true else return v end
end
function CFG.getPosWinSize(pfx)
    local v = getStore():readSetting(pfx .. CFG.POS_WIN_SIZE_KEY)
    if v == "small" or v == "large" then return v end
    return "medium"
end
function CFG.getPosWinPos(pfx)
    local v = getStore():readSetting(pfx .. CFG.POS_WIN_POS_KEY)
    if v == "center" or v == "top" then return v end
    return "bottom"
end
local _skip_auto_seed = {}
function CFG.setSkipAutoSeed(pfx, val)
    _skip_auto_seed[pfx or ""] = (val == true)
end
function CFG.getProfiles(pfx)
    local S = getStore()
    if not S then return {} end
    local list = S:readSetting(pfx .. CFG.PROFILES_KEY)
    if (type(list) ~= "table" or #list == 0) and (not _skip_auto_seed[pfx or ""]) and type(CFG.seedDefaultProfiles) == "function" then
        CFG.seedDefaultProfiles(pfx, false)
        list = S:readSetting(pfx .. CFG.PROFILES_KEY)
    end
    if type(list) ~= "table" then return {} end
    return list
end
function CFG.getActiveProfileName(pfx)
    local S = getStore()
    if not S then return "" end
    return S:readSetting(pfx .. CFG.ACTIVE_PROFILE_KEY) or ""
end
function CFG.getDefaultProfileName(pfx)
    local S = getStore()
    if not S then return "" end
    return S:readSetting(pfx .. CFG.DEFAULT_PROFILE_KEY) or ""
end
function CFG.getQuickSwitchEnabled(pfx)
    local S = getStore()
    if not S then return true end
    return S:readSetting(pfx .. CFG.QUICK_SWITCH_ENABLED_KEY) ~= false
end
function CFG.isProfileInQuickSwitch(pfx, prof_name)
    if not prof_name or prof_name == "" then return false end
    local S = getStore()
    if not S then return true end
    local raw = S:readSetting(pfx .. CFG.QUICK_PROFILES_KEY)
    if type(raw) ~= "table" then return true end
    return raw[prof_name] == true
end
function CFG.getQuickSwitchProfiles(pfx)
    local all = CFG.getProfiles(pfx)
    local S = getStore()
    if not S then return all end
    local raw = S:readSetting(pfx .. CFG.QUICK_PROFILES_KEY)
    if type(raw) ~= "table" then return all end
    local out = {}
    for _, p in ipairs(all) do
        if p and p.name and raw[p.name] == true then
            out[#out + 1] = p
        end
    end
    return out
end
function CFG.setProfileInQuickSwitch(pfx, prof_name, enabled)
    if not prof_name or prof_name == "" then return end
    local S = getStore()
    if not S then return end
    local raw = S:readSetting(pfx .. CFG.QUICK_PROFILES_KEY)
    local tbl = { _configured = true }
    if type(raw) ~= "table" then
        for _, p in ipairs(CFG.getProfiles(pfx)) do
            if p and p.name then tbl[p.name] = true end
        end
    else
        for k, v in pairs(raw) do
            if k ~= "_configured" and v == true then
                tbl[k] = true
            end
        end
    end
    tbl[prof_name] = enabled and true or nil
    S:saveSetting(pfx .. CFG.QUICK_PROFILES_KEY, tbl)
end

function CFG.getExcludePaths(pfx)
    local S = getStore()
    if not S then return {} end
    local raw = S:readSetting(pfx .. CFG.SK_EXCLUDE_PATHS)
    if not raw or raw == "" then return {} end
    local result = {}
    for token in raw:gmatch("[^,\n]+") do
        local t = token:match("^%s*(.-)%s*$")
        if t ~= "" then result[#result + 1] = t end
    end
    return result
end

function CFG.isExcluded(fp, excludes)
    if not fp or #excludes == 0 then return false end
    for _idx, frag in ipairs(excludes) do
        if fp:find(frag, 1, true) then return true end
    end
    return false
end

function CFG.getCurrentFP(ctx, pfx)
    local excludes = CFG.getExcludePaths(pfx)
    if ctx.current_fp and not CFG.isExcluded(ctx.current_fp, excludes) then
        return ctx.current_fp
    end
    local ok, RH = pcall(require, "readhistory")
    if not ok or not RH then return nil end
    if not (RH.hist and #RH.hist > 0) then
        pcall(function() RH:reload() end)
    end
    if not RH.hist then return nil end
    for _idx, e in ipairs(RH.hist) do
        if e and e.file and not CFG.isExcluded(e.file, excludes) then
            return e.file
        end
    end
    return nil
end

function CFG.getActiveStatsDict(pfx)
    local S = getStore()
    local d = S and S:readSetting(pfx .. CFG.ACTIVE_STATS_KEY)
    if type(d) ~= "table" then
        d = {}
        for k, _ in pairs(CFG.STAT_LABELS) do d[k] = true end
    end
    return d
end

function CFG.resolveStatOrder(saved)
    if type(saved) ~= "table" or #saved == 0 then return CFG.DEFAULT_STAT_ORDER end
    local seen, result = {}, {}
    for _idx, v in ipairs(saved) do
        if CFG.STAT_LABELS[v] and not seen[v] then seen[v] = true; table.insert(result, v) end
    end
    for _idx, v in ipairs(CFG.DEFAULT_STAT_ORDER) do
        if not seen[v] then seen[v] = true; table.insert(result, v) end
    end
    return result
end

-- Returns ordered array of currently active stat IDs
function CFG.getActiveOrderedStats(pfx)
    local S = getStore()
    local active_dict = CFG.getActiveStatsDict(pfx)
    local order = CFG.resolveStatOrder(S and S:readSetting(pfx .. CFG.STAT_ORDER_KEY))
    local out = {}
    for _, k in ipairs(order) do
        if active_dict[k] then
            out[#out + 1] = k
        end
    end
    return out
end

-- Saves active stat IDs in order while keeping inactive keys after them for legacy compat
function CFG.setActiveOrderedStats(pfx, active_ids)
    local S = getStore()
    if not S then return end
    local active_dict = {}
    for k, _ in pairs(CFG.STAT_LABELS) do
        active_dict[k] = false
    end
    local new_order = {}
    local seen = {}
    for _, id in ipairs(active_ids or {}) do
        if CFG.STAT_LABELS[id] and not seen[id] then
            seen[id] = true
            active_dict[id] = true
            new_order[#new_order + 1] = id
        end
    end
    local prev_order = CFG.resolveStatOrder(S:readSetting(pfx .. CFG.STAT_ORDER_KEY))
    for _, id in ipairs(prev_order) do
        if not seen[id] then
            seen[id] = true
            new_order[#new_order + 1] = id
        end
    end
    S:saveSetting(pfx .. CFG.ACTIVE_STATS_KEY, active_dict)
    S:saveSetting(pfx .. CFG.STAT_ORDER_KEY, new_order)
end

-- Formatting helpers
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

local function pickFormatter(pfx) return (CFG.getTimeFmt(pfx) == CFG.FMT_XHYM) and fmtTimeXhym or fmtTimeHuman end

local function humanDayCount(days, kind)
    local n = math.max(0, tonumber(days) or 0)
    if kind == "days" then
        return { value = fmtCount(n), unit = _("days") }
    end
    local unit = "day"
    if n >= 60 then unit = "month"; n = math.floor((n + 15) / 30)
    elseif n >= 14 then unit = "week"; n = math.floor((n + 3) / 7) end
    local labels = {
        reading     = { day = { _("days read") }, week = { _("weeks read") }, month = { _("months read") } },
        to_go       = { day = { _("days left") }, week = { _("weeks left") }, month = { _("months left") } },
        streak      = { day = { _("days streak") }, week = { _("weeks streak") }, month = { _("months streak") } },
        since_start = { day = { _("days ago") }, week = { _("weeks ago") }, month = { _("months ago") } },
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

local function parseHex(hex)
    local norm = normalizeHex(hex)
    if not norm then return nil end
    local r, g, b = norm:match("^#(%x%x)(%x%x)(%x%x)$")
    return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

local function isColorScreenActive()
    local Screen = Device.screen
    if not Screen then return true end
    if Screen.isColorScreen and not Screen:isColorScreen() then return false end
    if Screen.isColorEnabled and not Screen:isColorEnabled() then return false end
    return true
end

local function hexToColor(hex)
    local r, g, b = parseHex(hex)
    if not r then return nil end
    local Screen = Device.screen
    local night = Screen and Screen.night_mode
    if not isColorScreenActive() or not Blitbuffer.ColorRGB32 then
        local lum = math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5)
        if night then lum = 255 - lum end
        return Blitbuffer.Color8(math.max(0, math.min(255, lum)))
    end
    local c = Blitbuffer.ColorRGB32(r, g, b, 0xFF)
    return night and c:invert() or c
end

local function darkenColor(color, factor)
    if type(color) == "nil" then return nil end
    factor = factor or 0.55
    if Blitbuffer.isColor8(color) then
        local v = math.floor(color:getColor8().a * factor + 0.5)
        return Blitbuffer.Color8(math.max(0, math.min(255, v)))
    end
    local rgb = color:getColorRGB32()
    return Blitbuffer.ColorRGB32(
        math.max(0, math.min(255, math.floor(rgb.r * factor + 0.5))),
        math.max(0, math.min(255, math.floor(rgb.g * factor + 0.5))),
        math.max(0, math.min(255, math.floor(rgb.b * factor + 0.5))),
        0xFF
    )
end

local function srgbLinear(v)
    v = v / 255
    return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
end

local function contrastFg(color)
    if type(color) == "nil" then return Blitbuffer.COLOR_WHITE end
    local lum
    if Blitbuffer.isColor8(color) then
        lum = srgbLinear(color:getColor8().a)
    else
        local rgb = color:getColorRGB32()
        lum = 0.2126 * srgbLinear(rgb.r) + 0.7152 * srgbLinear(rgb.g) + 0.0722 * srgbLinear(rgb.b)
    end
    return (lum > 0.179) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
end

local function resolveColor(pfx, key, fallback)
    local hex = CFG.getColorHex(pfx, key)
    if not hex then return fallback end
    return hexToColor(hex) or fallback
end

local _paint_mask_cache = {}
local _paint_mask_order = {}
local _PAINT_MASK_MAX = 72
local _ColorFillWid, _ColorMaskWid

local function getPaintWidgets()
    if _ColorFillWid then return _ColorFillWid, _ColorMaskWid end
    local Widget = require("ui/widget/widget")
    local COLOUR_BB = {}
    for _, name in ipairs({ "TYPE_BBRGB32", "TYPE_BBRGB24", "TYPE_BBRGB16" }) do
        if Blitbuffer[name] then COLOUR_BB[Blitbuffer[name]] = true end
    end
    _ColorFillWid = Widget:extend{ color = nil }
    function _ColorFillWid:paintTo(bb, x, y)
        local c = self.color
        if type(c) == "nil" then return end
        local w, h = self.dimen.w, self.dimen.h
        if w <= 0 or h <= 0 then return end
        if not Blitbuffer.isColor8(c) and COLOUR_BB[bb:getType()] and type(bb.paintRectRGB32) == "function" then
            bb:paintRectRGB32(x, y, w, h, c)
        else
            bb:paintRect(x, y, w, h, c)
        end
    end
    _ColorMaskWid = Widget:extend{ mask = nil, color = nil }
    function _ColorMaskWid:paintTo(bb, x, y)
        local c, m = self.color, self.mask
        if type(c) == "nil" or not m then return end
        local w, h = self.dimen.w, self.dimen.h
        if type(bb.colorblitFromRGB32) == "function" and COLOUR_BB[bb:getType()] then
            bb:colorblitFromRGB32(m, x, y, 0, 0, w, h, c)
        elseif type(bb.colorblitFrom) == "function" then
            bb:colorblitFrom(m, x, y, 0, 0, w, h, c)
        end
    end
    return _ColorFillWid, _ColorMaskWid
end

local function storePaintMask(key, mask)
    if #_paint_mask_order >= _PAINT_MASK_MAX then
        local old_k = table.remove(_paint_mask_order, 1)
        local old_bb = old_k and _paint_mask_cache[old_k]
        if type(old_bb) == "table" and type(old_bb.free) == "function" then
            pcall(function() old_bb:free() end)
        end
        if old_k then _paint_mask_cache[old_k] = nil end
    end
    _paint_mask_cache[key] = mask
    _paint_mask_order[#_paint_mask_order + 1] = key
    return mask
end

local function roundedRectCoverage(px, py, cx, cy, hw, hh, radius)
    local qx = math.abs(px - cx) - hw + radius
    local qy = math.abs(py - cy) - hh + radius
    local ax = (qx > 0) and qx or 0
    local ay = (qy > 0) and qy or 0
    local dist = math.sqrt(ax * ax + ay * ay) + ((qx > qy and qx or qy) < 0 and (qx > qy and qx or qy) or 0) - radius
    return 0.5 - dist, dist
end

local function getRoundedMask(w, h, radius, bw)
    bw = bw or 0
    radius = math.min(radius or 0, math.floor(w / 2), math.floor(h / 2))
    local key = string.format("%d_%d_%d_%d", w, h, radius, bw)
    if _paint_mask_cache[key] then return _paint_mask_cache[key] end
    local mask = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    mask:fill(Blitbuffer.COLOR_BLACK)
    local cx, cy, hw, hh = w * 0.5, h * 0.5, w * 0.5, h * 0.5
    local inner_rad = math.max(0, radius - bw)
    local ihw, ihh = math.max(0, hw - bw), math.max(0, hh - bw)
    local data = mask.data
    local stride = tonumber(mask.stride)
    local band_y = math.max(radius, bw) + 1
    local band_x = math.max(radius, bw) + 1
    local mid_y0 = math.min(h, band_y)
    local mid_y1 = math.max(mid_y0, h - band_y)

    if bw == 0 then
        if mid_y1 > mid_y0 then
            mask:paintRect(0, mid_y0, w, mid_y1 - mid_y0, Blitbuffer.COLOR_WHITE)
        end
    else
        if mid_y1 > mid_y0 then
            local lbw = math.min(bw, w)
            mask:paintRect(0, mid_y0, lbw, mid_y1 - mid_y0, Blitbuffer.COLOR_WHITE)
            if w > lbw then
                mask:paintRect(w - lbw, mid_y0, lbw, mid_y1 - mid_y0, Blitbuffer.COLOR_WHITE)
            end
        end
    end

    local half_h = math.floor((h + 1) / 2)
    local half_w = math.floor((w + 1) / 2)
    local top_lim = math.min(half_h, band_y)
    local left_lim = math.min(half_w, band_x)

    if data and stride then
        local function set4(px, py, val)
            local mx = w - 1 - px
            local my = h - 1 - py
            local r1 = py * stride
            data[r1 + px].a = val
            if mx ~= px then data[r1 + mx].a = val end
            if my ~= py then
                local r2 = my * stride
                data[r2 + px].a = val
                if mx ~= px then data[r2 + mx].a = val end
            end
        end
        for py = 0, top_lim - 1 do
            local yc = py + 0.5
            -- Fill horizontal straight span between corners
            if left_lim < half_w then
                if bw == 0 then
                    local span_w = w - (left_lim * 2)
                    if span_w > 0 then
                        mask:paintRect(left_lim, py, span_w, 1, Blitbuffer.COLOR_WHITE)
                        local my = h - 1 - py
                        if my ~= py then
                            mask:paintRect(left_lim, my, span_w, 1, Blitbuffer.COLOR_WHITE)
                        end
                    end
                elseif py < bw then
                    local span_w = w - (left_lim * 2)
                    if span_w > 0 then
                        mask:paintRect(left_lim, py, span_w, 1, Blitbuffer.COLOR_WHITE)
                        local my = h - 1 - py
                        if my ~= py then
                            mask:paintRect(left_lim, my, span_w, 1, Blitbuffer.COLOR_WHITE)
                        end
                    end
                end
            end
            for px = 0, left_lim - 1 do
                local cov_out = roundedRectCoverage(px + 0.5, yc, cx, cy, hw, hh, radius)
                local cov = cov_out
                if bw > 0 and cov > 0 then
                    local cov_in = roundedRectCoverage(px + 0.5, yc, cx, cy, ihw, ihh, inner_rad)
                    if cov_in > 0 then
                        cov = math.max(0, cov_out - cov_in)
                    end
                end
                if cov > 0 then
                    local val = (cov >= 1) and 255 or math.floor(cov * 255 + 0.5)
                    set4(px, py, val)
                end
            end
        end
    else
        for py = 0, h - 1 do
            local yc = py + 0.5
            local in_corner_y = (py < band_y) or (py >= h - band_y)
            if in_corner_y then
                for px = 0, w - 1 do
                    local cov_out = roundedRectCoverage(px + 0.5, yc, cx, cy, hw, hh, radius)
                    local cov = cov_out
                    if bw > 0 and cov > 0 then
                        local cov_in = roundedRectCoverage(px + 0.5, yc, cx, cy, ihw, ihh, inner_rad)
                        if cov_in > 0 then
                            cov = math.max(0, cov_out - cov_in)
                        end
                    end
                    if cov > 0 then
                        if cov >= 1 then
                            mask:setPixel(px, py, Blitbuffer.COLOR_WHITE)
                        else
                            mask:setPixel(px, py, Blitbuffer.Color8(math.floor(cov * 255 + 0.5)))
                        end
                    end
                end
            end
        end
    end
    return storePaintMask(key, mask)
end

local function makeColorFill(w, h, color, radius)
    w = math.max(1, math.floor(w + 0.5))
    h = math.max(1, math.floor(h + 0.5))
    radius = math.max(0, math.floor(radius or 0))
    local Geom = require("ui/geometry")
    local FillWid, MaskWid = getPaintWidgets()
    if radius <= 0 then
        return FillWid:new{ dimen = Geom:new{ w = w, h = h }, color = color }
    end
    if type(color) ~= "nil" and not Blitbuffer.isColor8(color) then
        local mask = getRoundedMask(w, h, radius, 0)
        return MaskWid:new{ dimen = Geom:new{ w = w, h = h }, mask = mask, color = color }
    end
    local FrameContainer = require("ui/widget/container/framecontainer")
    local LineWidget = require("ui/widget/linewidget")
    return FrameContainer:new{
        bordersize = 0, margin = 0, padding = 0,
        background = color, radius = radius,
        [1] = LineWidget:new{ dimen = Geom:new{ w = w, h = h }, style = "none" },
    }
end

local function makeColorStrokeBox(w, h, bw, color, radius, inner_wid, bg_color)
    w = math.max(1, math.floor(w + 0.5))
    h = math.max(1, math.floor(h + 0.5))
    bw = math.max(1, math.floor(bw or 1))
    radius = math.max(0, math.floor(radius or 0))
    local color_rgb = (type(color) ~= "nil" and not Blitbuffer.isColor8(color))
    local bg_rgb = (type(bg_color) ~= "nil" and not Blitbuffer.isColor8(bg_color))
    if color_rgb or bg_rgb then
        local Geom = require("ui/geometry")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local OverlapGroup = require("ui/widget/overlapgroup")
        local ov = { dimen = Geom:new{ w = w, h = h } }
        if type(bg_color) ~= "nil" then
            ov[#ov + 1] = makeColorFill(w, h, bg_color, radius)
        end
        if color_rgb then
            local _, MaskWid = getPaintWidgets()
            if inner_wid then
                ov[#ov + 1] = CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, inner_wid }
            end
            ov[#ov + 1] = MaskWid:new{
                dimen = Geom:new{ w = w, h = h },
                mask = getRoundedMask(w, h, radius, bw),
                color = color,
            }
        else
            local FrameContainer = require("ui/widget/container/framecontainer")
            local iw = math.max(1, w - bw * 2)
            local ih = math.max(1, h - bw * 2)
            ov[#ov + 1] = FrameContainer:new{
                bordersize = bw, color = color, background = nil,
                radius = radius, padding = 0, margin = 0,
                [1] = inner_wid and CenterContainer:new{ dimen = Geom:new{ w = iw, h = ih }, inner_wid } or nil,
            }
        end
        return OverlapGroup:new(ov)
    end
    local FrameContainer = require("ui/widget/container/framecontainer")
    return FrameContainer:new{
        bordersize = bw, color = color, background = bg_color,
        radius = radius, padding = 0, margin = 0,
        [1] = inner_wid,
    }
end

return {
    CFG             = CFG,
    _               = _,
    getSUIModule    = getSUIModule,
    ensureBentoCompat = ensureBentoCompat,
    getSH           = getSH,
    getSUIStyle     = getSUIStyle,
    getStore        = getStore,
    getConfig       = getConfig,
    fmtCount        = fmtCount,
    emptyVal        = emptyVal,
    fmtFraction     = fmtFraction,
    fmtTimeHuman    = fmtTimeHuman,
    fmtTimeXhym     = fmtTimeXhym,
    pickFormatter   = pickFormatter,
    humanDayCount   = humanDayCount,
    resolveFontFace = resolveFontFace,
    truncateTitle   = truncateTitle,
    normalizeHex    = normalizeHex,
    parseHex        = parseHex,
    isColorScreenActive = isColorScreenActive,
    hexToColor      = hexToColor,
    darkenColor     = darkenColor,
    contrastFg      = contrastFg,
    resolveColor    = resolveColor,
    makeColorFill   = makeColorFill,
    makeColorStrokeBox = makeColorStrokeBox,
}
