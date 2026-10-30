describe("Anx UI scopes", function()
    local Scope, UIManager

    setup(function()
        require("commonrequire")
        UIManager = require("ui/uimanager")
        Scope = dofile("plugins/anxui.koplugin/lifecycle.lua")
    end)

    after_each(function() UIManager:quit() end)

    it("rejects results from an earlier query generation", function()
        local scope, calls = Scope.new(), 0
        local old = scope:guard(function() calls = calls + 1 end)
        scope:invalidate()
        local _, reason = old()
        assert.are.equal("stale_session", reason)
        scope:guard(function() calls = calls + 1 end)()
        assert.are.equal(1, calls)
        scope:close()
    end)

    it("unschedules work and also rejects already dispatched callbacks after close", function()
        local scope, calls = Scope.new(), 0
        local pending = scope:later(60, function() calls = calls + 1 end)
        assert.is_not_nil(next(scope.tasks))
        scope:close()
        pending()
        assert.are.equal(0, calls)
        assert.is_nil(next(scope.tasks))
        assert.are.equal(0, #UIManager._task_queue)
        assert.is_nil(scope:later(0, function() error("closed scope scheduled work") end))
    end)

    it("closes owned popups and forgets ones closed manually", function()
        local InfoMessage = require("ui/widget/infomessage")
        local scope, closed = Scope.new(), 0
        local first = scope:own(InfoMessage:new{ text = "test", dismiss_callback = function() closed = closed + 1 end })
        local second = scope:own(InfoMessage:new{ text = "test", dismiss_callback = function() closed = closed + 1 end })
        UIManager:show(first)
        UIManager:show(second)
        UIManager:close(first)
        assert.are.equal(1, #scope.windows)
        scope:close()
        scope:close()
        assert.are.equal(2, closed)
        assert.are.equal(0, #scope.windows)
        assert.is_false(UIManager:isWidgetShown(second))
    end)

    it("runs a native cancellation path once before owner teardown", function()
        local scope, cancelled = Scope.new(), 0
        local widget = require("ui/widget/infomessage"):new{text = "native owned dialog"}
        scope:collectWindows(function() UIManager:show(widget) end, function(owned)
            cancelled = cancelled + 1; UIManager:close(owned)
        end)
        scope:close(); scope:close()
        assert.are.equal(1, cancelled)
        assert.is_nil(next(scope.closers))
    end)
end)
