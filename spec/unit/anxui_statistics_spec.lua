describe("Anx saved statistics", function()
    local Statistics, capabilities, SQ3, path, ui, now
    local function contents()
        local file = assert(io.open(path, "rb")); local value = file:read("*a"); file:close(); return value
    end
    setup(function()
        require("commonrequire")
        Statistics = dofile("plugins/anxui.koplugin/statistics.lua")
        capabilities = dofile("plugins/anxui.koplugin/capabilities.lua")
        SQ3 = require("lua-ljsqlite3/init")
        path = require("datastorage"):getDataDir() .. "/anx-stats-unit.sqlite3"
        now = os.time{year = 2026, month = 10, day = 20, hour = 12}
    end)
    before_each(function()
        G_reader_settings:delSetting("plugins_disabled")
        os.remove(path)
        local db = SQ3.open(path)
        db:exec("CREATE TABLE page_stat (id_book INTEGER, page INTEGER, start_time INTEGER, duration INTEGER); PRAGMA user_version=20221111;")
        local insert = db:prepare("INSERT INTO page_stat VALUES (?, ?, ?, ?)")
        for _, row in ipairs({{1, 1, now - 20, 10}, {1, 1, now - 10, 5}, {2, 1, now - 10, 6},
                {1, 2, now - 12 * 3600 + 60, 8}, {2, 2, now - 12 * 3600 - 60, 7}}) do
            insert:bind(unpack(row)):step(); insert:reset():clearbind()
        end
        insert:close(); db:close()
        ui = {statistics = {onShowReaderProgress = function() error("native writer must not be called") end,
            start_current_period = now - 30, settings = {is_enabled = true}}}
    end)
    after_each(function() G_reader_settings:delSetting("plugins_disabled"); os.remove(path) end)

    it("matches native page grouping and committed intervals without changing the database", function()
        local before = contents()
        for _ = 1, 20 do
            local snapshot = Statistics.snapshot(ui, capabilities, path, now)
            assert.same({pages = 3, duration = 29}, snapshot.today)
            assert.same({pages = 2, duration = 21}, snapshot.session)
            assert.same({books = 2, duration = 36}, snapshot.total)
        end
        assert.are.equal(before, contents())
    end)

    it("explains missing plugins and disabled collection without querying their methods", function()
        ui.statistics.settings.is_enabled = false
        local result, reason = Statistics.snapshot(ui, capabilities, path, now)
        assert.is_nil(result); assert.are.equal("Reading statistics are turned off", reason)
        G_reader_settings:saveSetting("plugins_disabled", {statistics = true})
        result, reason = Statistics.snapshot(ui, capabilities, path, now)
        assert.is_nil(result); assert.are.equal("Disabled in the plugin manager", reason)
        G_reader_settings:delSetting("plugins_disabled"); ui.statistics = nil
        assert.is_nil(Statistics.snapshot(ui, capabilities, path, now))
    end)

    it("rejects an unknown schema and leaves it unchanged", function()
        local db = SQ3.open(path); db:exec("PRAGMA user_version=99999999"); db:close()
        local before = contents()
        local result, reason = Statistics.snapshot(ui, capabilities, path, now)
        assert.is_nil(result); assert.are.equal("Saved statistics cannot be read; open classic statistics", reason)
        assert.are.equal(before, contents())
    end)
end)
