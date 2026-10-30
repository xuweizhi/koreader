local UIManager = require("ui/uimanager")

-- One scope per plugin instance or page. Only file identities cross reader/FM
-- transitions; scopes and document references never do.
local Scope = {}
Scope.__index = Scope

function Scope.new()
    return setmetatable({ alive = true, generation = 0, tasks = {}, windows = {}, closers = {}, cleanups = {} }, Scope)
end

function Scope:defer(callback)
    assert(self.alive, "cannot attach cleanup to a closed scope")
    self.cleanups[#self.cleanups + 1] = callback
end

function Scope:guard(callback)
    local generation = self.generation
    return function(...)
        if not self.alive or generation ~= self.generation then
            return nil, "stale_session"
        end
        return callback(...)
    end
end

function Scope:later(delay, callback)
    if not self.alive then return end
    local guarded = self:guard(callback)
    local task
    task = function()
        self.tasks[task] = nil
        return guarded()
    end
    self.tasks[task] = true
    UIManager:scheduleIn(delay, task)
    return task
end

function Scope:invalidate()
    self.generation = self.generation + 1
    for task in pairs(self.tasks) do UIManager:unschedule(task) end
    self.tasks = {}
end

function Scope:forget(widget)
    self.closers[widget] = nil
    for i = #self.windows, 1, -1 do
        if self.windows[i] == widget then table.remove(self.windows, i) end
    end
end

function Scope:own(widget, close)
    assert(self.alive, "cannot attach a window to a closed scope")
    table.insert(self.windows, widget)
    self.closers[widget] = close
    -- An instance-local close hook preserves the original widget's behavior.
    local original_close = widget.onCloseWidget
    widget.onCloseWidget = function(closed, ...)
        self:forget(closed)
        if original_close then return original_close(closed, ...) end
    end
    return widget
end

function Scope:collectWindows(callback, close)
    if not self.alive then return nil, "stale_session" end
    local existing = {}
    for _, window in ipairs(UIManager._window_stack) do existing[window.widget] = true end
    local result, reason = callback()
    for _, window in ipairs(UIManager._window_stack) do
        if not existing[window.widget] then self:own(window.widget, close) end
    end
    return result, reason
end

function Scope:close()
    if not self.alive then return end
    self.alive = false
    self:invalidate()
    local windows = self.windows
    self.windows = {}
    for i = #windows, 1, -1 do
        local widget = windows[i]
        if UIManager:isWidgetShown(widget) then
            if self.closers[widget] then self.closers[widget](widget) else UIManager:close(widget) end
        end
    end
    self.closers = {}
    for i = #self.cleanups, 1, -1 do self.cleanups[i]() end
    self.cleanups = {}
end

return Scope
