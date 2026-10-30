local Statistics = {}

-- Mirrors the original progress screen's grouping and day boundary, but opens
-- a read-only connection and never flushes or starts a statistics timer.
function Statistics.snapshot(ui, capabilities, path, now)
    local capability = capabilities.plugin(ui, "statistics", "onShowReaderProgress")
    if capability.state ~= "available" then return nil, capability.reason end
    local original = ui.statistics
    if original.settings and original.settings.is_enabled == false then
        return nil, "Reading statistics are turned off"
    end
    path = path or require("datastorage"):getSettingsDir() .. "/statistics.sqlite3"
    if not require("libs/libkoreader-lfs").attributes(path) then return nil, "No saved statistics yet" end
    now = now or os.time()
    local calendar = os.date("*t", now)
    local today = now - calendar.hour * 3600 - calendar.min * 60 - calendar.sec
    local db, statement
    local function period(start)
        statement = db:prepare([[SELECT count(*), coalesce(sum(elapsed), 0) FROM
            (SELECT sum(duration) AS elapsed FROM page_stat WHERE start_time >= ? GROUP BY id_book, page)]])
        local row = statement:bind(start):step()
        local pages, duration = tonumber(row[1]), tonumber(row[2])
        statement:close(); statement = nil
        return {pages = pages, duration = duration}
    end
    local ok, result = pcall(function()
        db = require("lua-ljsqlite3/init").open(path, "ro")
        db:set_busy_timeout(5)
        if tonumber(db:rowexec("PRAGMA user_version")) ~= 20221111 then error("unsupported statistics schema") end
        local today_stats = period(today)
        local session = period(tonumber(original.start_current_period) or now)
        local books, duration = db:rowexec("SELECT count(DISTINCT id_book), coalesce(sum(duration), 0) FROM page_stat")
        return {today = today_stats, session = session, total = {books = tonumber(books), duration = tonumber(duration)},
            captured_at = now, period_start = original.start_current_period}
    end)
    if statement then statement:close() end
    if db then db:close() end
    if not ok then
        require("logger").warn("Anx statistics read failed:", result)
        return nil, "Saved statistics cannot be read; open classic statistics"
    end
    return result
end

return Statistics
