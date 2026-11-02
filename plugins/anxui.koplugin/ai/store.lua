local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local ffi = require("ffi")
require("ffi/posix_h")
ffi.cdef[[int chmod(const char *path, mode_t mode);]]
local Store = {}
Store.__index = Store

function Store.new(path)
    if not path then
        local is_android, android = pcall(require, "android")
        -- Android's ordinary reader settings live on shared storage. Keep AI
        -- credentials and conversations in the application's internal files.
        -- The launcher replaces filesDir when updating bundled assets. Use a
        -- private sibling so installing a new APK preserves this data.
        path = is_android and (android.dir .. "/../anxui-ai")
            or (require("datastorage"):getSettingsDir() .. "/anxui-ai")
    end
    if lfs.symlinkattributes(path, "mode") == "link" then return nil, "storage_error" end
    if not lfs.attributes(path) then lfs.mkdir(path) end
    if lfs.attributes(path, "mode") ~= "directory" then return nil, "storage_error" end
    ffi.C.chmod(path, 448) -- 0700; local settings, no claim of encryption at rest.
    return setmetatable({path=path}, Store)
end

function Store:read(name, default)
    local path = self.path .. "/" .. name .. ".json"
    local attr = lfs.symlinkattributes(path)
    if not attr then return default end
    if attr.mode ~= "file" or attr.size > 8 * 1024 * 1024 then return nil, "storage_error" end
    local file = io.open(path, "rb")
    if not file then return nil, "storage_error" end
    local data = file:read("*a"); file:close()
    local ok, value = pcall(JSON.decode, data)
    if not ok or type(value) ~= "table" or (value.schema ~= 1 and not (name == "config" and value.schema == 2)) then return nil, "storage_error" end
    return value
end

function Store:write(name, value)
    local path, tmp = self.path .. "/" .. name .. ".json", self.path .. "/" .. name .. ".tmp"
    if lfs.symlinkattributes(path, "mode") == "link" or lfs.symlinkattributes(tmp, "mode") == "link" then return false end
    local ok, data = pcall(JSON.encode, value)
    if not ok or #data > 8 * 1024 * 1024 then return false end
    local file = io.open(tmp, "wb")
    if not file then return false end
    if ffi.C.chmod(tmp, 384) ~= 0 then file:close(); os.remove(tmp); return false end
    local written = file:write(data)
    local closed = file:close()
    if not written or not closed then os.remove(tmp); return false end
    return os.rename(tmp, path) ~= nil
end

function Store:profiles()
    local data, err = self:read("config", {schema=1, endpoint="https://api.openai.com/v1", model="", api_key=""})
    if not data then return nil, err end
    if data.schema == 1 then
        data = {schema=2, active="default", profiles={{id="default",name="Default",endpoint=data.endpoint,
            model=data.model,api_key=data.api_key,provider=data.provider or "compatible"}}}
    end
    if type(data.profiles) ~= "table" or #data.profiles < 1 or #data.profiles > 8 or type(data.active) ~= "string" then
        return nil, "storage_error"
    end
    local found, ids = false, {}
    for _, profile in ipairs(data.profiles) do
        if type(profile) ~= "table" or type(profile.id) ~= "string" or ids[profile.id]
            or type(profile.name) ~= "string" or #profile.name > 100
            or type(profile.endpoint) ~= "string" or type(profile.model) ~= "string" or type(profile.api_key) ~= "string"
            or (profile.provider ~= "compatible" and profile.provider ~= "deepseek") then return nil, "storage_error" end
        ids[profile.id] = true
        if profile.id == data.active then found = true end
    end
    if not found then return nil, "storage_error" end
    return data
end

function Store:config()
    local data, err = self:profiles()
    if not data then return nil, err end
    for _, profile in ipairs(data.profiles) do if profile.id == data.active then return profile end end
end

function Store:saveProfile(profile)
    local data = self:profiles()
    if not data then return false end
    local replacement = require("util").tableDeepCopy(profile)
    local found = false
    for index, current in ipairs(data.profiles) do
        if current.id == profile.id then data.profiles[index] = replacement; found = true; break end
    end
    if not found then
        if #data.profiles >= 8 then return false end
        data.profiles[#data.profiles+1] = replacement
    end
    data.active = profile.id
    return self:write("config", data)
end

function Store:selectProfile(id)
    local data = self:profiles()
    if not data then return false end
    for _, profile in ipairs(data.profiles) do
        if profile.id == id then data.active = id; return self:write("config", data) end
    end
    return false
end

function Store:deleteProfile(id)
    local data = self:profiles()
    if not data or #data.profiles <= 1 then return false end
    for index, profile in ipairs(data.profiles) do
        if profile.id == id then
            table.remove(data.profiles,index)
            if data.active == id then data.active = data.profiles[1].id end
            return self:write("config",data)
        end
    end
    return false
end

function Store:renameSession(id, title)
    if type(title) ~= "string" or not title:find("%S") or #title > 120 then return false end
    local sessions = self:history()
    if not sessions then return false end
    for _, session in ipairs(sessions) do
        if session.id == id then session.title = title; return self:write("history",{schema=1,sessions=sessions}) end
    end
    return false
end

function Store:history()
    local data, err = self:read("history", {schema=1, sessions={}})
    if not data or type(data.sessions) ~= "table" then return nil, err or "storage_error" end
    for _, session in ipairs(data.sessions) do
        if type(session) ~= "table" or type(session.id) ~= "string" or type(session.title) ~= "string"
            or type(session.messages) ~= "table" or #session.messages > 20 then return nil, "storage_error" end
        if session.context ~= nil and (type(session.context) ~= "table" or type(session.context.text) ~= "string"
            or #session.context.text > 16001 or type(session.context.title) ~= "string") then return nil, "storage_error" end
        if session.context then
            local context = session.context
            if (context.chapter ~= nil and type(context.chapter) ~= "string")
                or (context.page ~= nil and type(context.page) ~= "number") then return nil, "storage_error" end
            if context.sources~=nil then
                if type(context.sources)~="table" or #context.sources>30 then return nil,"storage_error" end
                for _,ref in ipairs(context.sources) do
                    if type(ref)~="table" or type(ref.id)~="string" or not ref.id:match("^S%d+$")
                        or type(ref.file)~="string" or type(ref.title)~="string" or type(ref.label)~="string"
                        or (ref.xpointer~=nil and type(ref.xpointer)~="string")
                        or (ref.page~=nil and type(ref.page)~="number")
                        or (ref.signature~=nil and type(ref.signature)~="string") then return nil,"storage_error" end
                end
            end
        end
        if session.book~=nil and (type(session.book)~="table" or type(session.book.file)~="string"
            or type(session.book.title)~="string") then return nil,"storage_error" end
        for _, message in ipairs(session.messages) do
            if type(message) ~= "table" or type(message.content) ~= "string" or #message.content > 32768
                or (message.role ~= "user" and message.role ~= "assistant")
                or (message.error ~= nil and type(message.error) ~= "string")
                or (message.http_code ~= nil and type(message.http_code) ~= "number")
                or (message.mode~=nil and message.mode~="parallel" and message.mode~="mindmap" and message.mode~="report")
                or (message.source_text~=nil and (type(message.source_text)~="string" or #message.source_text>16001)) then return nil, "storage_error" end
        end
    end
    return data.sessions
end

function Store:saveSession(session)
    local sessions = self:history()
    if not sessions then return false end
    for index = #sessions, 1, -1 do if sessions[index].id == session.id then table.remove(sessions, index) end end
    table.insert(sessions, 1, session)
    while #sessions > 10 do table.remove(sessions) end
    return self:write("history", {schema=1, sessions=sessions})
end

function Store:deleteSession(id)
    local sessions = self:history()
    if not sessions then return false end
    for index = #sessions, 1, -1 do if sessions[index].id == id then table.remove(sessions, index) end end
    return self:write("history", {schema=1, sessions=sessions})
end

return Store
