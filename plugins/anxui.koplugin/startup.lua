local Startup = {}

function Startup.shouldOpen(options, context)
    if not options.startup or not context.first_owner or context.is_reader or context.recovery
        or not context.guide_shown or context.original_start ~= "filemanager" then return false end
    -- Match the launcher's known no-path options conservatively. Any explicit
    -- path, URI, separator, or unknown option retains KOReader's own routing.
    local flags = { ["-d"] = true, ["-v"] = true, ["-p"] = true,
        ["--debug"] = true, ["--verbose"] = true, ["--profile"] = true }
    for _, value in ipairs(context.arguments or {}) do if not flags[value] then return false end end
    return true
end

return Startup
