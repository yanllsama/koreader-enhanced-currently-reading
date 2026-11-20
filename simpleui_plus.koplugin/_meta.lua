local _ = (function()
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    local dir = src:sub(1, 1) == "@" and src:sub(2):match("^(.*)[/\\]_meta%.lua$")
    if dir and dir ~= "" then
        _G._simpleui_plus_path = _G._simpleui_plus_path or dir
        local ok, i18n = pcall(dofile, dir .. "/infra/plus_i18n.lua")
        if ok and i18n and type(i18n.translate) == "function" then
            return i18n.translate
        end
    end
    return function(s) return s end
end)()

return {
    name = "simpleui_plus",
    fullname = _("SimpleUI Plus"),
    description = _("Enhanced module suite and setup wizard for SimpleUI dashboard."),
    version     = "3.0.1",
    author      = "Yanllsama",
}
