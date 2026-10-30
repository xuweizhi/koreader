return function(context)
    local reader, step, shot, finish = context.reader, context.step, context.shot, context.finish
    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    local plugin = reader.anxui
    local function waitTicks(left, callback)
        if left == 0 then callback(); return end
        step(function() waitTicks(left - 1, callback) end)
    end
    local function databaseBytes()
        local path = require("datastorage"):getSettingsDir() .. "/statistics.sqlite3"
        local file = assert(io.open(path, "rb")); local bytes = file:read("*a"); file:close(); return bytes
    end
    local function verify()
        -- Native insertDB deliberately excludes the still-open page interval.
        -- Turn once more to finish both measured intervals before comparison.
        reader:handleEvent(Event:new("GotoPage", 3))
        plugin:showStatistics()
        shot("saved-statistics-before-native-flush")
        plugin.statistics_view.buttons.details.callback()
        step(function()
            local native
            for _, window in ipairs(UIManager._window_stack) do
                if window.widget.today_duration then native = window.widget end
            end
            assert(native, "original reading progress window did not open")
            assert(native.today_duration >= 10, "original timed reading was not recorded")
            shot("original-statistics")
            UIManager:close(native)
            local duration, pages = reader.statistics:getTodayBookStats()
            local session_duration, session_pages = reader.statistics:getCurrentBookStats()
            local database_before = databaseBytes()
            for _ = 1, 20 do
                plugin:showStatistics()
                local view = plugin.statistics_view
                assert(view.snapshot.today.duration == duration and view.snapshot.today.pages == pages)
                assert(view.snapshot.session.duration == session_duration and view.snapshot.session.pages == session_pages)
                view:onClose()
            end
            assert(databaseBytes() == database_before, "opening statistics modified the authoritative database")
            plugin:showStatistics()
            shot("anx-statistics-matches-native")
            plugin.statistics_view:onClose()
            local disabled
            for _, group in ipairs(require("pluginloader"):genPluginManagerSubItem()) do
                for _, item in ipairs(group.sub_item_table or {}) do
                    if item.text == reader.statistics.fullname then disabled = item.callback; break end
                end
            end
            assert(disabled); disabled()
            for index = #UIManager._window_stack, 1, -1 do
                if UIManager._window_stack[index].widget ~= reader then UIManager:close(UIManager._window_stack[index].widget) end
            end
            plugin:showStatistics()
            assert(not plugin.statistics_view.snapshot)
            assert(not plugin.statistics_view.buttons.details.enabled)
            shot("statistics-plugin-disabled")
            plugin.statistics_view:onClose()
            finish()
        end)
    end
    reader:handleEvent(Event:new("GotoPage", 1))
    waitTicks(16, function()
        reader:handleEvent(Event:new("GotoPage", 2))
        waitTicks(16, verify)
    end)
end
