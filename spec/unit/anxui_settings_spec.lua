describe("Anx UI settings and capabilities", function()
    local Settings, Capabilities, settings, root
    setup(function()
        require("commonrequire")
        Settings = dofile("plugins/anxui.koplugin/settings.lua")
        Capabilities = dofile("plugins/anxui.koplugin/capabilities.lua")
    end)
    before_each(function()
        root = { data = { unrelated = { keep = true } }, writes = 0 }
        function root:readSetting(key) return self.data[key] end
        function root:saveSetting(key, value) self.data[key] = value end
        function root:flush() self.writes = self.writes + 1 end
        settings = Settings.new(root)
    end)
    after_each(function() G_reader_settings:delSetting("plugins_disabled") end)

    it("validates options without writing unknown values or losing extension fields", function()
        root.data.anxui = { extension = "keep" }
        assert.is_false(settings:update("mode", "invalid"))
        assert.is_false(settings:update("large_text", "yes"))
        assert.is_false(settings:update("unknown", true))
        assert.are.equal(0, root.writes)
        assert.is_true(settings:update("mode", "gray"))
        assert.is_true(settings:update("mode", "gray"))
        assert.are.equal(1, root.writes)
        assert.are.equal("keep", root.data.anxui.extension)
        assert.are.equal("gray", settings:options().mode)
    end)

    it("requires an explicit reset for corrupt or future settings and resets only its own namespace", function()
        for _, value in ipairs({ "broken", { schema = 99, future = "keep" } }) do
            root.data.anxui = value
            assert.is_not_nil(settings:recoveryReason())
            assert.is_false(settings:update("mode", "color"))
            assert.are.equal(value, root.data.anxui)
        end
        settings:reset()
        assert.same({ schema = 1 }, root.data.anxui)
        assert.same({ keep = true }, root.data.unrelated)
        assert.is_nil(settings:recoveryReason())
    end)

    it("persists unfinished opening across a fresh settings instance", function()
        settings:update("opening", true)
        local restarted = Settings.new(root)
        assert.are.equal("unfinished_open", restarted:recoveryReason())
        restarted:update("opening", false)
        assert.is_nil(Settings.new(root):recoveryReason())
    end)

    it("migrates an opted-in legacy file manager startup once without losing other settings", function()
        root.data.anxui = {schema=1, startup=true, mode="gray", extension="keep"}
        settings:migrateStartup()
        assert.are.equal("anxui", root.data.start_with)
        assert.is_true(settings:options().startup)
        assert.same({schema=1, mode="gray", extension="keep"}, root.data.anxui)
        settings:migrateStartup()
        assert.are.equal(1, root.writes)
        assert.same({keep=true}, root.data.unrelated)
    end)

    it("preserves native startup choices and does not revive a discarded legacy switch", function()
        for _, mode in ipairs({"last", "history", "favorites", "folder_shortcuts"}) do
            root.data.start_with = mode
            root.data.anxui = {schema=1, startup=true}
            settings:migrateStartup()
            assert.are.equal(mode, root.data.start_with)
            assert.is_false(settings:options().startup)
            root.data.start_with = "filemanager"
            settings:migrateStartup()
            assert.is_false(settings:options().startup)
        end
        root.data.anxui = {schema=99, startup=true}
        local writes = root.writes
        settings:migrateStartup()
        assert.are.equal(writes, root.writes)
        assert.is_true(root.data.anxui.startup)
    end)

    it("uses the native startup setting for both the appearance toggle and menu selection", function()
        root.data.start_with = "history"
        assert.is_true(settings:update("startup", true))
        assert.are.equal("anxui", root.data.start_with)
        assert.is_true(Settings.new(root):options().startup)
        settings:update("startup", false)
        assert.are.equal("filemanager", root.data.start_with)
        root.data.start_with = "favorites"
        settings:update("startup", false)
        assert.are.equal("favorites", root.data.start_with)
        root.data.start_with = "anxui"
        assert.is_true(settings:options().startup)
        root.data.start_with = "filemanager"
        assert.is_false(settings:options().startup)
    end)

    it("distinguishes disabled cached instances from missing context or methods", function()
        local ui = { statistics = { onShowReaderProgress = function() end } }
        assert.are.equal("available", Capabilities.plugin(ui, "statistics", "onShowReaderProgress").state)
        assert.are.equal("unavailable", Capabilities.plugin({}, "statistics").state)
        assert.are.equal("unavailable", Capabilities.plugin(ui, "statistics", "absent").state)
        ui.statistics.onShowReaderProgress = setmetatable({}, { __call = function() end })
        assert.are.equal("available", Capabilities.plugin(ui, "statistics", "onShowReaderProgress").state)
        G_reader_settings:saveSetting("plugins_disabled", { statistics = true })
        assert.are.equal("disabled", Capabilities.plugin(ui, "statistics", "onShowReaderProgress").state)
    end)
end)
