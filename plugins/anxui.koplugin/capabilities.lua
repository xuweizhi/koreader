local Capabilities = {}

function Capabilities.callable(value)
    if type(value) == "function" then return true end
    local meta = type(value) == "table" and getmetatable(value)
    return type(meta) == "table" and type(meta.__call) == "function" or false
end

-- Availability is queried when rendering a control and again on invocation.
-- An object may survive in a cached loader after the user disabled its plugin.
function Capabilities.plugin(ui, name, method)
    local disabled = G_reader_settings:readSetting("plugins_disabled")
    if type(disabled) == "table" and disabled[name] then
        return { state = "disabled", reason = "Disabled in the plugin manager" }
    end
    local instance = ui and ui[name]
    if not instance then
        return { state = "unavailable", reason = "Unavailable in this context" }
    end
    -- KOReader wraps plugin event handlers in callable HandlerSandbox tables.
    if method and not Capabilities.callable(instance[method]) then
        return { state = "unavailable", reason = "This version does not provide the required action" }
    end
    return { state = "available", reason = "Available" }
end

return Capabilities
