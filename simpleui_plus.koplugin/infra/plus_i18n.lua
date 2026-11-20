-- infra/plus_i18n.lua — Strictly isolated translation loader for SimpleUI Plus.
-- Reads ONLY .po files from simpleui_plus.koplugin/locale/<lang>.po.
-- Never falls back to simpleui.koplugin (sui_i18n) or KOReader global gettext,
-- preventing mixed or mismatched translations across plugins.

local ok_log, logger = pcall(require, "logger")

local _MODULE_SRC = (debug and debug.getinfo and debug.getinfo(1, "S") and debug.getinfo(1, "S").source) or ""

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^[\r\n%s]+", ""):gsub("[\r\n%s]+$", ""))
end

local function normalizeDir(d)
    if type(d) ~= "string" or d == "" then return nil end
    d = d:gsub("\\", "/"):gsub("/+$", "")
    if d == "" then return nil end
    return d
end

local function getLocaleCandidates()
    local dirs = {}
    local seen = {}
    local function addRoot(root)
        root = normalizeDir(root)
        if not root then return end
        local loc = (root:match("/locale$") and (root .. "/")) or (root .. "/locale/")
        if not seen[loc] then
            seen[loc] = true
            dirs[#dirs + 1] = loc
        end
    end

    -- 1. Source path of this file (handles custom plugin folder names too)
    local src = _MODULE_SRC
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    src = src:gsub("\\", "/")
    if src ~= "" then
        addRoot(src:match("^(.*)/infra/plus_i18n%.lua$"))
        addRoot(src:match("^(.-%.koplugin)/"))
    end

    -- 2. Runtime path recorded by _meta.lua / main.lua
    addRoot(_G._simpleui_plus_path)

    -- 3. package.path templates pointing to simpleui_plus.koplugin
    if type(package.path) == "string" then
        for seg in package.path:gmatch("([^;]+)") do
            local norm = seg:gsub("\\", "/")
            local p = norm:match("^(.-simpleui_plus[^/]*%.koplugin)/")
            if p then addRoot(p) end
        end
        for seg in package.path:gmatch("([^;]+)") do
            local norm = seg:gsub("\\", "/")
            local p = norm:match("^(.-%.koplugin)/")
            if p then addRoot(p) end
        end
    end

    -- 4. KOReader DataStorage standard plugin locations
    local ok_ds, DS = pcall(require, "datastorage")
    if ok_ds and DS then
        if type(DS.getFullDataDir) == "function" then
            local ok_f, fd = pcall(function() return DS:getFullDataDir() end)
            if ok_f and type(fd) == "string" then
                addRoot(fd .. "/plugins/simpleui_plus.koplugin")
            end
        end
        if type(DS.getDataDir) == "function" then
            local ok_d, dd = pcall(function() return DS:getDataDir() end)
            if ok_d and type(dd) == "string" then
                addRoot(dd .. "/plugins/simpleui_plus.koplugin")
            end
        end
    end

    -- 5. Relative fallbacks (when CWD is KOReader root)
    addRoot("plugins/simpleui_plus.koplugin")
    addRoot("./plugins/simpleui_plus.koplugin")
    addRoot(".")

    return dirs
end

local function parsePluralExpression(expr)
    expr = expr:match("plural%s*=%s*(.-)%s*;?%s*$") or expr

    local toks, pos = {}, 1
    while pos <= #expr do
        local s = expr:match("^%s+", pos)
        if s then
            pos = pos + #s
        else
            local t = expr:match("^%d+", pos)
                or expr:match("^[=!<>]=", pos)
                or expr:match("^&&", pos) or expr:match("^||", pos)
                or expr:match("^[n%(%)%?:!<>%%%*/%+%-]", pos)
            if not t then return nil end
            toks[#toks + 1] = t
            pos = pos + #t
        end
    end

    local i = 1
    local parseTernary

    local function binary(next_level, ops)
        return function()
            local lhs = next_level()
            while lhs and ops[toks[i]] do
                local op = ops[toks[i]]
                i = i + 1
                local rhs = next_level()
                if not rhs then return nil end
                local l = lhs
                lhs = function(n) return op(l(n), rhs(n)) end
            end
            return lhs
        end
    end

    local function parsePrimary()
        local t = toks[i]
        if not t then return nil end
        i = i + 1
        if t == "n" then return function(n) return n end end
        if t:match("^%d+$") then
            local v = tonumber(t)
            return function() return v end
        end
        if t == "(" then
            local e = parseTernary()
            if not e or toks[i] ~= ")" then return nil end
            i = i + 1
            return e
        end
        return nil
    end

    local function parseUnary()
        if toks[i] == "!" then
            i = i + 1
            local e = parseUnary()
            if not e then return nil end
            return function(n) return e(n) == 0 and 1 or 0 end
        end
        return parsePrimary()
    end

    local function b2n(v) return v and 1 or 0 end
    local mul = binary(parseUnary, {
        ["*"] = function(a, b) return a * b end,
        ["/"] = function(a, b) return b ~= 0 and math.floor(a / b) or 0 end,
        ["%"] = function(a, b) return b ~= 0 and a % b or 0 end,
    })
    local add = binary(mul, {
        ["+"] = function(a, b) return a + b end,
        ["-"] = function(a, b) return a - b end,
    })
    local rel = binary(add, {
        ["<"]  = function(a, b) return b2n(a < b) end,
        [">"]  = function(a, b) return b2n(a > b) end,
        ["<="] = function(a, b) return b2n(a <= b) end,
        [">="] = function(a, b) return b2n(a >= b) end,
    })
    local eq = binary(rel, {
        ["=="] = function(a, b) return b2n(a == b) end,
        ["!="] = function(a, b) return b2n(a ~= b) end,
    })
    local land = binary(eq, {
        ["&&"] = function(a, b) return b2n(a ~= 0 and b ~= 0) end,
    })
    local lor = binary(land, {
        ["||"] = function(a, b) return b2n(a ~= 0 or b ~= 0) end,
    })

    parseTernary = function()
        local cond = lor()
        if not cond or toks[i] ~= "?" then return cond end
        i = i + 1
        local a = parseTernary()
        if not a or toks[i] ~= ":" then return nil end
        i = i + 1
        local b = parseTernary()
        if not b then return nil end
        return function(n) return cond(n) ~= 0 and a(n) or b(n) end
    end

    local fn = parseTernary()
    if not fn or i <= #toks then return nil end
    return function(n) return fn(math.floor(math.abs(tonumber(n) or 0))) end
end

local UNESCAPE_MAP = {
    n = "\n",
    r = "\r",
    t = "\t",
    ['"'] = '"',
    ["\\"] = "\\",
}

local function unescapePO(s)
    if type(s) ~= "string" or s == "" then return "" end
    return (s:gsub("\\(.)", UNESCAPE_MAP))
end

local function parsePO(path)
    local f = io.open(path, "r")
    if not f then return nil end

    local data = f:read("*a")
    f:close()
    if type(data) ~= "string" or data == "" then return nil end

    data = data:gsub("^\239\187\191", "")

    local map           = {}
    local pluralizer    = nil
    local entry         = { msgid = nil, msgid_plural = nil, msgstrs = {} }
    local current_field = nil

    local function flush()
        if not entry.msgid then
            entry         = { msgid = nil, msgid_plural = nil, msgstrs = {} }
            current_field = nil
            return
        end

        if entry.msgid == "" then
            local header = entry.msgstrs[0] or ""
            for line in header:gmatch("([^\n]*)\n?") do
                local plural_line = line:match("^Plural%-Forms:%s*(.-)%s*$")
                if plural_line then
                    local ok_p, p_fn = pcall(parsePluralExpression, plural_line)
                    if ok_p and type(p_fn) == "function" then
                        pluralizer = p_fn
                    end
                    break
                end
            end
        else
            if entry.msgid_plural then
                local trans = {}
                for idx, str in pairs(entry.msgstrs) do
                    if str and str ~= "" then trans[idx] = str end
                end
                if next(trans) then map[entry.msgid] = trans end
            else
                local str = entry.msgstrs[0]
                if str and str ~= "" then map[entry.msgid] = str end
            end
        end

        entry         = { msgid = nil, msgid_plural = nil, msgstrs = {} }
        current_field = nil
    end

    for raw_line in (data .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local text = trim(raw_line)
        if text == "" then
            flush()
        elseif text:match("^#") then
            -- ignore comments
        elseif text:match('^msgid%s+"') then
            flush()
            entry.msgid = unescapePO(text:match('^msgid%s+"(.*)"') or "")
            current_field = "msgid"
        elseif text:match('^msgid_plural%s+"') then
            entry.msgid_plural = unescapePO(text:match('^msgid_plural%s+"(.*)"') or "")
            current_field = "msgid_plural"
        elseif text:match('^msgstr%[%d+%]%s+"') then
            local idx = tonumber(text:match('^msgstr%[(%d+)%]%s+"'))
            if idx then
                entry.msgstrs[idx] = unescapePO(text:match('^msgstr%[%d+%]%s+"(.*)"') or "")
                current_field = "msgstr" .. idx
            end
        elseif text:match('^msgstr%s+"') then
            entry.msgstrs[0] = unescapePO(text:match('^msgstr%s+"(.*)"') or "")
            current_field = "msgstr0"
        elseif text:match('^"') and current_field then
            local cont = unescapePO(text:match('^"(.*)"') or "")
            if current_field == "msgid" then
                entry.msgid = entry.msgid .. cont
            elseif current_field == "msgid_plural" then
                entry.msgid_plural = entry.msgid_plural .. cont
            else
                local idx = tonumber(current_field:match("^msgstr(%d+)$"))
                if idx then
                    entry.msgstrs[idx] = (entry.msgstrs[idx] or "") .. cont
                end
            end
        end
    end
    flush()
    return map, pluralizer
end

local LANG_OPTIONS = {
    { code = "auto", label = "Auto (Follow KOReader)", native = "Auto" },
    { code = "en",   label = "English",                native = "English" },
    { code = "tr",   label = "Türkçe (Turkish)",       native = "Türkçe" },
    { code = "de",   label = "Deutsch (German)",       native = "Deutsch" },
    { code = "es",   label = "Español (Spanish)",      native = "Español" },
    { code = "fr",   label = "Français (French)",      native = "Français" },
    { code = "pt",   label = "Português (Portuguese)", native = "Português" },
    { code = "it",   label = "Italiano (Italian)",     native = "Italiano" },
    { code = "nl",   label = "Nederlands (Dutch)",     native = "Nederlands" },
    { code = "pl",   label = "Polski (Polish)",        native = "Polski" },
}

local function detectSystemLang()
    local gs = _G.G_reader_settings
    local lang = gs and type(gs.readSetting) == "function" and gs:readSetting("language")
    if type(lang) == "string" and lang ~= "" then
        if lang == "C" then return "en" end
        return lang
    end
    local lc = os.getenv("LANG") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or ""
    lang = lc:match("^([a-zA-Z_%-]+)")
    if lang == "C" or lang == "POSIX" then return "en" end
    return lang or "en"
end

local function getOverrideLang()
    local gs = _G.G_reader_settings
    local ov = gs and type(gs.readSetting) == "function" and gs:readSetting("simpleui_plus_language")
    if type(ov) == "string" and ov ~= "" and ov ~= "auto" then
        return ov
    end
    return "auto"
end

local function detectLang()
    local ov = getOverrideLang()
    if ov ~= "auto" then return ov end
    return detectSystemLang()
end

local _translations    = nil
local _loaded          = false
local _loaded_lang     = nil
local _loaded_path_sig = nil

local function reset()
    _translations    = nil
    _loaded          = false
    _loaded_lang     = nil
    _loaded_path_sig = nil
end

local function setOverrideLang(code)
    local gs = _G.G_reader_settings
    if gs and type(gs.saveSetting) == "function" then
        if not code or code == "" or code == "auto" then
            if type(gs.delSetting) == "function" then
                gs:delSetting("simpleui_plus_language")
            else
                gs:saveSetting("simpleui_plus_language", "auto")
            end
        else
            gs:saveSetting("simpleui_plus_language", code)
        end
        if type(gs.flush) == "function" then pcall(function() gs:flush() end) end
    end
    reset()
end

local function loadTranslations()
    local lang = detectLang()
    local path_sig = tostring(_G._simpleui_plus_path or "")
    if _loaded and _loaded_lang == lang and _loaded_path_sig == path_sig then
        return _translations
    end
    _loaded          = true
    _loaded_lang     = lang
    _loaded_path_sig = path_sig
    _translations    = nil

    if type(lang) ~= "string" or lang == "" or lang == "en" or lang:match("^en[_%-]") then
        return nil
    end

    local names = {}
    local seen_name = {}
    local function addName(n)
        if type(n) == "string" and n ~= "" and not seen_name[n] then
            seen_name[n] = true
            names[#names + 1] = n
        end
    end
    addName(lang)
    addName(lang:gsub("%-", "_"))
    addName(lang:lower())
    addName(lang:gsub("%-", "_"):lower())
    local prefix = lang:match("^([a-zA-Z]+)")
    if prefix then
        addName(prefix)
        addName(prefix:lower())
    end

    local tried = {}
    local cands = getLocaleCandidates()
    for _, loc_dir in ipairs(cands) do
        for _, name in ipairs(names) do
            local path = loc_dir .. name .. ".po"
            tried[#tried + 1] = path
            local entries, pluralizer = parsePO(path)
            if entries and next(entries) then
                if ok_log and logger then
                    local n = 0; for _ in pairs(entries) do n = n + 1 end
                    logger.info("simpleui_plus i18n: loaded " .. path .. " (" .. n .. " strings, lang=" .. lang .. ")")
                end
                _translations = { entries = entries, plural = pluralizer, path = path }
                return _translations
            end
        end
    end

    if ok_log and logger then
        logger.warn("simpleui_plus i18n: no .po loaded for lang=" .. tostring(lang) .. "; tried: " .. table.concat(tried, ", "))
    end
    return nil
end

local function lookupLocal(msgid)
    if type(msgid) ~= "string" then return msgid end
    local t = loadTranslations()
    if not t then return nil end
    local entry = t.entries[msgid]
    if type(entry) == "string" then
        return entry
    elseif type(entry) == "table" then
        return entry[0] or entry[1]
    end
    return nil
end

local function translate(msgid)
    if type(msgid) ~= "string" then return msgid end

    local lang = detectLang()
    if lang == "en" or lang:match("^en[_%-]") then
        return msgid
    end

    local hit = lookupLocal(msgid)
    if hit then return hit end

    return msgid
end

local function ngettext(msgid, msgid_plural, n)
    local lang = detectLang()
    if lang == "en" or lang:match("^en[_%-]") then
        return (n == 1) and msgid or msgid_plural
    end

    local t = loadTranslations()
    if t and type(msgid) == "string" then
        local entry = t.entries[msgid]
        if type(entry) == "table" then
            local idx = t.plural and (t.plural(n) or 0) or ((n == 1) and 0 or 1)
            for i = idx, 0, -1 do
                if entry[i] then return entry[i] end
            end
        elseif type(entry) == "string" and n == 1 then
            return entry
        end
    end

    return (n == 1) and msgid or msgid_plural
end

local function wrap(_unused_fallback)
    return translate
end

local M = {
    LANG_OPTIONS          = LANG_OPTIONS,
    translate             = translate,
    ngettext              = ngettext,
    lookup                = lookupLocal,
    wrap                  = wrap,
    getLang               = detectLang,
    getOverrideLang       = getOverrideLang,
    setOverrideLang       = setOverrideLang,
    parsePluralExpression = parsePluralExpression,
    reset                 = reset,
}

package.loaded["infra/plus_i18n"] = package.loaded["infra/plus_i18n"] or M
return M
