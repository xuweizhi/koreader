describe("Anx optional assistant version guard", function()
    local Assistant, path
    setup(function()
        require("commonrequire")
        Assistant = dofile("plugins/anxui.koplugin/assistant.lua")
    end)
    it("requires exact runtime bytes and invalidates a changed file", function()
        path = os.tmpname()
        os.remove(path); assert(require("libs/libkoreader-lfs").mkdir(path))
        local function write(bytes)
            local file = assert(io.open(path .. "/main.lua", "wb")); file:write(bytes); file:close()
        end
        write("original")
        local lock = {commit = "test", files = {["main.lua"] = require("ffi/sha2").sha256("original")}}
        assert.is_true(Assistant.verify(path, lock))
        assert.is_true(Assistant.verify(path, lock))
        write("changed source")
        assert.is_false(Assistant.verify(path, lock))
        os.remove(path .. "/main.lua")
        assert.is_false(Assistant.verify(path, lock))
        assert(require("libs/libkoreader-lfs").rmdir(path)); path = nil
    end)
    it("rejects missing or disabled plugins before touching configuration", function()
        local FM = require("apps/filemanager/filemanager")
        local previous = FM.instance
        local ui = {}; FM.instance = ui
        local scope = dofile("plugins/anxui.koplugin/lifecycle.lua").new()
        local adapter = Assistant.new(ui, scope, dofile("plugins/anxui.koplugin/capabilities.lua"), {})
        assert.are.equal("unavailable", adapter:status().state)
        G_reader_settings:saveSetting("plugins_disabled", {koassistant = true})
        ui.koassistant = {onKOAssistantGeneralChat = function() error("must not call") end}
        assert.are.equal("disabled", adapter:status().state)
        assert.is_false(adapter:open("general"))
        scope:close(); assert.is_nil(adapter.ui)
        assert.is_false(adapter:active())
        G_reader_settings:delSetting("plugins_disabled"); FM.instance = previous
    end)

    it("cancels a refreshed composer when the owner closes before the handoff tick", function()
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        local scope = dofile("plugins/anxui.koplugin/lifecycle.lua").new()
        local bridge = Assistant.new({}, scope, dofile("plugins/anxui.koplugin/capabilities.lua"), {})
        local plugin, cancelled = {}, 0
        local original = InfoMessage:new{text = "original composer"}
        plugin.current_input_dialog = original
        UIManager:show(scope:own(original))
        bridge:watchComposer(plugin, original)
        original._koa_internal_close = true
        UIManager:close(original)
        local pending = assert(next(scope.tasks))
        local replacement = InfoMessage:new{text = "replacement composer"}
        function replacement:onCloseDialog()
            cancelled = cancelled + 1
            UIManager:close(self); plugin.current_input_dialog = nil
        end
        plugin.current_input_dialog = replacement
        UIManager:show(replacement)
        scope:close(); pending()
        assert.are.equal(1, cancelled)
        assert.is_nil(plugin.current_input_dialog)
        assert.is_false(UIManager:isWidgetShown(replacement))
        assert.is_nil(bridge.ui)
        assert.is_nil(bridge.refresh_plugin)
        UIManager:quit()
    end)

    it("adopts a replacement but does not claim an unrelated chat after normal close", function()
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        local scope = dofile("plugins/anxui.koplugin/lifecycle.lua").new()
        local bridge = Assistant.new({}, scope, dofile("plugins/anxui.koplugin/capabilities.lua"), {})
        local plugin = {}
        local original = InfoMessage:new{text = "original composer"}
        plugin.current_input_dialog = original
        UIManager:show(scope:own(original))
        bridge:watchComposer(plugin, original)
        original._koa_internal_close = true; UIManager:close(original)
        local replacement = InfoMessage:new{text = "replacement composer"}
        plugin.current_input_dialog = replacement; UIManager:show(replacement)
        local pending = assert(next(scope.tasks))
        UIManager:unschedule(pending); pending()
        assert.are.equal(replacement, bridge.composer)
        assert.are.equal(replacement, scope.windows[1])
        UIManager:close(replacement) -- ordinary user close, without internal refresh flag
        plugin.current_input_dialog = InfoMessage:new{text = "unrelated native chat"}
        UIManager:show(plugin.current_input_dialog)
        scope:close()
        assert.is_true(UIManager:isWidgetShown(plugin.current_input_dialog))
        assert.is_nil(bridge.composer)
        UIManager:close(plugin.current_input_dialog); UIManager:quit()
    end)
end)
