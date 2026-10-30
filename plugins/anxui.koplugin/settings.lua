local util = require("util")

local Settings = {}
Settings.__index = Settings
local modes = { auto = true, color = true, gray = true }

function Settings.new(root)
    return setmetatable({ root = root or G_reader_settings }, Settings)
end

function Settings:stored()
    return self.root:readSetting("anxui")
end

function Settings:recoveryReason()
    local data = self:stored()
    if data ~= nil and type(data) ~= "table" then return "invalid_settings" end
    if data and data.schema ~= nil and data.schema ~= 1 then return "unknown_schema" end
    if data and data.opening == true then return "unfinished_open" end
end

function Settings:options()
    local data = self:stored()
    if type(data) ~= "table" then data = {} end
    return { mode = modes[data.mode] and data.mode or "auto", large_text = data.large_text == true,
        startup = data.startup == true }
end

function Settings:update(key, value)
    local data = self:stored()
    if type(data) ~= "table" and data ~= nil then return false, "invalid_settings" end
    if data and data.schema ~= nil and data.schema ~= 1 then return false, "unknown_schema" end
    if (key == "mode" and not modes[value])
        or ((key == "large_text" or key == "opening" or key == "startup") and type(value) ~= "boolean")
        or (key ~= "mode" and key ~= "large_text" and key ~= "opening" and key ~= "startup") then
        return false, "invalid_option"
    end
    if data and data[key] == value and data.schema == 1 then return true end
    data = util.tableDeepCopy(data or {})
    data.schema, data[key] = 1, value
    self.root:saveSetting("anxui", data)
    self.root:flush()
    return true
end

function Settings:reset()
    self.root:saveSetting("anxui", { schema = 1 })
    self.root:flush()
end

return Settings
