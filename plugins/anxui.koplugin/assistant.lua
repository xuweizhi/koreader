local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local Assistant = {}
Assistant.__index = Assistant
local cached -- Paths, hashes and file attributes only; never a ReaderUI or credential.

function Assistant.verify(path, lock)
    local stamp = {}
    for file in pairs(lock.files) do
        local attr = lfs.attributes(path .. "/" .. file)
        if not attr or attr.mode ~= "file" or attr.size > 4 * 1024 * 1024 then return false end
        stamp[file] = table.concat({attr.size, attr.modification, attr.change, attr.ino}, ":")
    end
    local same = cached and cached.path == path and cached.commit == lock.commit
    if same then
        for file, value in pairs(stamp) do if cached.stamp[file] ~= value then same = false; break end end
    end
    if same then return true end
    local sha256 = require("ffi/sha2").sha256
    for file, expected in pairs(lock.files) do
        local handle = io.open(path .. "/" .. file, "rb")
        if not handle then return false end
        local content = handle:read("*a"); handle:close()
        if not content or sha256(content) ~= expected then return false end
    end
    cached = {path = path, commit = lock.commit, stamp = stamp}
    return true
end

function Assistant.new(ui, scope, capabilities, lock)
    local self = setmetatable({ui = ui, scope = scope, capabilities = capabilities, lock = lock}, Assistant)
    scope:defer(function()
        -- A native refresh closes its old composer before creating the new one.
        -- Owner teardown can happen before our next-tick ownership handoff.
        local plugin = self.refresh_plugin
        self.refresh_plugin = nil
        local widget = plugin and plugin.current_input_dialog
        if widget and UIManager:isWidgetShown(widget) then self:closeComposer(plugin, widget) end
        self.composer, self.ui = nil, nil
    end)
    return self
end

function Assistant:closeComposer(plugin, widget)
    if plugin.current_input_dialog == widget and self.capabilities.callable(widget.onCloseDialog) then
        widget:onCloseDialog()
    else UIManager:close(widget) end
end

function Assistant:watchComposer(plugin, widget)
    if self.composer == widget then return end
    self.composer = widget
    local original_close = widget.onCloseWidget
    widget.onCloseWidget = function(closed, ...)
        local watching = self.composer == closed
        if watching then self.composer = nil end
        if original_close then original_close(closed, ...) end
        -- This flag belongs to the pinned KOAssistant refresh path (rotation
        -- and session chips). A normal user close must not claim a later chat.
        if watching and closed._koa_internal_close and self.scope.alive then
            self.refresh_plugin = plugin
            self.scope:later(0, function()
                if self.refresh_plugin ~= plugin then return end
                self.refresh_plugin = nil
                local replacement = plugin.current_input_dialog
                if replacement and replacement ~= closed and replacement ~= self.composer
                        and UIManager:isWidgetShown(replacement) then
                    self.scope:own(replacement, function(owned) self:closeComposer(plugin, owned) end)
                    self:watchComposer(plugin, replacement)
                end
            end)
        end
    end
end

function Assistant:active()
    if not self.scope.alive or not self.ui then return false end
    if self.ui.document then return require("apps/reader/readerui").instance == self.ui and not self.ui.tearing_down end
    return require("apps/filemanager/filemanager").instance == self.ui
end

function Assistant:status()
    if not self:active() then return {state = "unavailable", reason = "stale_session"} end
    local capability = self.capabilities.plugin(self.ui, "koassistant", "onKOAssistantGeneralChat")
    if capability.state ~= "available" then return capability end
    local plugin = self.ui.koassistant
    if G_reader_settings:isTrue("plugins_disable_external") then
        return {state = "disabled", reason = "Disabled in the plugin manager"}
    end
    if not plugin.path or not Assistant.verify(plugin.path, self.lock)
            or not self.capabilities.callable(plugin.onKOAssistantBookChat) then
        return {state = "version_mismatch", reason = "KOAssistant version differs from the tested version"}
    end
    local ok, configured = pcall(function()
        return require("koassistant.ui.setup_wizard").probe(plugin, "provider")
    end)
    return {state = "available", reason = not ok and "Assistant configuration could not be read"
        or (configured and "Configured; connection has not been tested" or "Configure a provider in KOAssistant"),
        configured = ok and configured == true, book = self.ui.document ~= nil}
end

function Assistant:open(mode)
    local status = self:status()
    if status.state ~= "available" then return false, status.reason end
    if mode == "book" and not status.book then return false, "Unavailable in this context" end
    local plugin = self.ui.koassistant
    local method = mode == "book" and "onKOAssistantBookChat" or "onKOAssistantGeneralChat"
    local result = self.scope:collectWindows(function() return plugin[method](plugin) end, function(widget)
        -- Use the original composer's cancel path so its per-session context is
        -- cleared on a book switch or on Anx disable, before closing the owner.
        self:closeComposer(plugin, widget)
    end)
    if result == false then return false, "KOAssistant could not open its window" end
    local composer = plugin.current_input_dialog
    if composer and UIManager:isWidgetShown(composer) then self:watchComposer(plugin, composer) end
    return true
end

return Assistant
