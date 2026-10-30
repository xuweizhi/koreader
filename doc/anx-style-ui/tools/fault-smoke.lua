-- Late patch in a dedicated install/config copy. Never loaded by user installs.
local UIManager = require("ui/uimanager")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local JSON = require("json")
local phase = assert(os.getenv("ANX_FAULT_PHASE"))
local evidence = assert(os.getenv("ANX_FAULT_EVIDENCE"))
local book = assert(os.getenv("ANX_FAULT_BOOK"))
local expected_path = assert(os.getenv("ANX_FAULT_EXPECTED"))
local function write(path, value)
    local file = assert(io.open(path, "wb")); file:write(JSON.encode(value)); file:close()
end
local function step(callback, delay)
    UIManager:scheduleIn(delay or .3, function()
        local ok, reason = xpcall(callback, debug.traceback)
        if not ok then print("ANX_FAULT_FAIL", reason); UIManager:quit(1) end
    end)
end
local function shot(name)
    UIManager:forceRePaint()
    assert(require("device").screen:shot(evidence .. "/" .. name .. ".png"))
end
local function finish()
    if ReaderUI.instance then ReaderUI.instance:onClose() end
    if FileManager.instance then FileManager.instance:onClose() end
    print("ANX_FAULT_PASS", phase); UIManager:quit()
end
local function readExpected()
    local file = assert(io.open(expected_path, "rb")); local data = JSON.decode(file:read("*a")); file:close(); return data
end
local function data(reader)
    local notes = {}
    for _, item in ipairs(reader.annotation.annotations) do
        notes[#notes + 1] = {page = item.page, note = item.note, text = item.text, drawer = item.drawer}
    end
    return {notes = notes, page = reader.view.state.page, file = reader.document.file}
end
local function verify(reader)
    local expected, actual = readExpected(), data(reader)
    assert(actual.file == expected.file and actual.page == expected.page, "reading position changed")
    assert(#actual.notes == #expected.notes, "annotations changed")
    for i, note in ipairs(expected.notes) do
        assert(actual.notes[i].page == note.page and actual.notes[i].note == note.note
            and actual.notes[i].text == note.text and actual.notes[i].drawer == note.drawer, "annotation content/anchor changed")
    end
    assert(require("readcollection"):isFileInCollection(book, "favorites"), "favorite lost")
    write(evidence .. "/observed-data.json", actual)
    shot("original-data-readable")
end
local function openAndVerify()
    FileManager.instance:openFile(book)
    step(function() verify(assert(ReaderUI.instance)); finish() end)
end

step(function()
    if phase == "seed" then
        local reader = assert(ReaderUI.instance)
        reader:handleEvent(require("ui/event"):new("GotoPage", 1))
        step(function()
            reader:handleEvent(require("ui/event"):new("GotoPage", 3))
            reader.bookmark:onToggleBookmark()
            reader.bookmark:setBookmarkNote(1)
            local input
            for _, window in ipairs(UIManager._window_stack) do
                if window.widget.getInputText then input = window.widget end
            end
            assert(input); input:setInputText("Fault recovery must preserve this original note")
            for _, row in ipairs(input.buttons) do
                for _, button in ipairs(row) do if button.is_enter_default then button.callback() end end
            end
            local collection = require("readcollection")
            collection:addItem(book, "favorites"); collection:write()
            reader:saveSettings()
            reader.statistics:insertDB()
            G_reader_settings:saveSetting("anx_fault_unrelated", {keep = "unchanged"})
            G_reader_settings:flush()
            write(expected_path, data(reader))
            shot("seeded-original-data")
            finish()
        end, 6)
        return
    end
    if phase == "disabled" or phase == "disabled_after_live" or phase == "removed" or phase == "corrupt_main" or phase == "failed_init" then
        local fm = assert(FileManager.instance)
        assert(not fm.anxui, "faulted/disabled plugin remained attached")
        shot("classic-fallback")
        return openAndVerify()
    end
    local fm, plugin = assert(FileManager.instance), assert(FileManager.instance.anxui)
    if phase == "crash" then
        plugin:showHome(); assert(plugin.home)
        plugin:showNoteLibrary()
        plugin.scope:later(60, function() error("process survived controlled kill unexpectedly") end)
        G_reader_settings:flush()
        shot("before-controlled-kill")
        write(evidence .. "/kill-ready.json", {ready = true, phase = phase})
        return -- Python terminates this test process group, without running Lua close hooks.
    end
    assert(G_reader_settings:readSetting("anx_fault_unrelated").keep == "unchanged")
    if phase == "future_schema" or phase == "invalid_settings" or phase == "opening_marker" then
        local expected_reason = phase == "future_schema" and "unknown_schema"
            or phase == "invalid_settings" and "invalid_settings" or "unfinished_open"
        assert(plugin.recovery_reason == expected_reason)
        local before = G_reader_settings:readSetting("anxui")
        plugin:showHome(); assert(plugin.recovery_dialog and not plugin.home)
        UIManager:close(plugin.recovery_dialog) -- Cancel leaves the original value intact.
        assert(G_reader_settings:readSetting("anxui") == before)
        plugin:showHome()
        local dialog = assert(plugin.recovery_dialog)
        shot("explicit-recovery-choice")
        dialog.ok_callback(); UIManager:close(dialog)
        step(function()
            assert(plugin.home and not plugin.recovery_reason)
            assert(G_reader_settings:readSetting("anx_fault_unrelated").keep == "unchanged")
            plugin:closeHome(); openAndVerify()
        end)
        return
    end
    if phase == "legacy_settings" then
        assert(not plugin.recovery_reason)
        assert(plugin.settings:options().mode == "gray" and plugin.settings:options().large_text)
        assert(plugin.settings:update("startup", false))
        local stored = plugin.settings:stored()
        assert(stored.schema == 1 and stored.extension == "keep legacy extension")
        plugin:showHome(); shot("legacy-settings-upgraded"); plugin:closeHome()
        return openAndVerify()
    end
    if phase == "disable_live" then
        plugin:showHome(); plugin:showSettings()
        local stale = plugin.settings_view.rows[1].callback
        for _, group in ipairs(require("pluginloader"):genPluginManagerSubItem()) do
            for _, item in ipairs(group.sub_item_table or {}) do
                if item.text == plugin.fullname then item.callback() end
            end
        end
        assert(plugin.stopped and not plugin.scope.alive)
        assert(not plugin.home and not plugin.settings_view)
        stale(); assert(not plugin.preferences_menu)
        for index = #UIManager._window_stack, 1, -1 do
            local widget = UIManager._window_stack[index].widget
            if widget ~= fm then UIManager:close(widget) end
        end
        shot("classic-after-live-disable")
        return openAndVerify()
    end
    error("unknown fault phase")
end, 3.8)
