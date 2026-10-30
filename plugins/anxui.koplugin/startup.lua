local Startup = {}

function Startup.shouldOpen(options, context)
    if not options.startup or not context.first_owner or context.is_reader or context.recovery
        or not context.guide_shown or context.original_start ~= "anxui" then return false end
    -- Match the launcher's known no-path options conservatively. Any explicit
    -- path, URI, separator, or unknown option retains KOReader's own routing.
    local flags = { ["-d"] = true, ["-v"] = true, ["-p"] = true,
        ["--debug"] = true, ["--verbose"] = true, ["--profile"] = true }
    for _, value in ipairs(context.arguments or {}) do if not flags[value] then return false end end
    return true
end

function Startup.extendMenu(menu, settings, translate, scope)
    if not menu or not menu.sub_item_table or menu.anxui_startup_entry or not scope.alive then return end
    local entry = {
        text = translate("Anx library"), radio = true,
        checked_func = function() return settings:options().startup end,
        enabled_func = function() return scope.alive and not settings:recoveryReason() end,
        callback = scope:guard(function() return settings:update("startup", true) end),
    }
    local original_text = menu.text_func
    local text = function()
        if settings:options().startup then
            return require("ffi/util").template(require("gettext")("Start with: %1"), translate("Anx library"))
        end
        return original_text()
    end
    table.insert(menu.sub_item_table, entry)
    menu.anxui_startup_entry, menu.text_func = entry, text
    scope:defer(function()
        for index, item in ipairs(menu.sub_item_table) do
            if item == entry then table.remove(menu.sub_item_table, index); break end
        end
        if menu.text_func == text then menu.text_func = original_text end
        if menu.anxui_startup_entry == entry then menu.anxui_startup_entry = nil end
    end)
end

return Startup
