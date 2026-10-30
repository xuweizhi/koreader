-- Test-only Android patch, installed solely in the dedicated emulator's KO_HOME.
local UIManager = require("ui/uimanager")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local Screen = require("device").screen
local JSON = require("json")
local Event = require("ui/event")
local android = require("android")
local ffiUtil = require("ffi/util")
local control_file = assert(io.open("/sdcard/koreader/anx-android-control.json", "rb"))
local control = JSON.decode(control_file:read("*a")); control_file:close()
local root, request_id = control.remote, 0
local result = {phase = control.phase, book = control.book, checks = {}, passed = false}
local canonical_book = assert(ffiUtil.realpath(control.book), "Android fixture path cannot be resolved")
result.book_canonical = canonical_book

local function sameBook(file, stage)
    local canonical = file and ffiUtil.realpath(file)
    result.file_identities = result.file_identities or {}
    result.file_identities[#result.file_identities + 1] = {
        stage = stage, original = file or false, canonical = canonical or false,
        expected = control.book, expected_canonical = canonical_book,
    }
    return canonical ~= nil and canonical == canonical_book
end

local function write(name, value)
    local file = assert(io.open(root .. "/" .. name .. ".tmp", "wb"))
    file:write(JSON.encode(value)); file:close()
    assert(os.rename(root .. "/" .. name .. ".tmp", root .. "/" .. name .. ".json"))
end
local function fail(reason)
    result.error = tostring(reason)
    write("result", result)
    UIManager:quit(1)
end
local function step(callback, delay)
    UIManager:scheduleIn(delay or 0.7, function()
        local ok, reason = xpcall(callback, debug.traceback)
        if not ok then fail(reason) end
    end)
end
local function waitFor(predicate, callback, attempts, label)
    local found = predicate()
    if found then callback(found); return end
    attempts = (attempts or 0) + 1
    assert(attempts < 180, "Android condition timed out: " .. (label or "unspecified condition"))
    step(function() waitFor(predicate, callback, attempts, label) end, 1)
end
local function request(actions, callback)
    UIManager:forceRePaint()
    request_id = request_id + 1
    local id = request_id
    write("request", {id = id, actions = actions})
    waitFor(function()
        local file = io.open(root .. "/response.json", "rb")
        if not file then return end
        local text = file:read("*a"); file:close()
        local ok, response = pcall(JSON.decode, text)
        if ok and type(response) == "table" and response.id == id then return response end
    end, function(response)
        assert(response.ok, response.error or "Android host action failed")
        step(callback)
    end, nil, "host response for input request " .. id)
end
local function requestUntil(actions, label, predicate, callback)
    request(actions, function() waitFor(predicate, callback, nil, label) end)
end
local function shot(name, callback)
    request({{kind = "screenshot", name = name}}, callback)
end
local function tap(widget)
    -- Rebuilds (notably Android rotation) replace widgets before the next
    -- normal repaint. Coordinates must be read after their actual paint.
    UIManager:forceRePaint()
    local dimen = assert(widget.dimen)
    return {kind = "tap", x = math.floor(dimen.x + dimen.w / 2), y = math.floor(dimen.y + dimen.h / 2)}
end
local function noteText(reader)
    for _, annotation in ipairs(reader.annotation.annotations) do
        if annotation.note == "Android emulator preserved note" then return annotation end
    end
end
local function finish(reader)
    result.passed = true
    result.width, result.height = Screen:getWidth(), Screen:getHeight()
    if reader then
        result.page = reader:getCurrentPage()
        local note = assert(noteText(reader))
        result.note, result.anchor = note.note, note.page
        reader:onClose()
    end
    if FileManager.instance then FileManager.instance:onClose() end
    write("result", result)
    UIManager:quit()
end

local function verifyReopen(reader)
    assert(sameBook(reader.document.file, "disabled_restart"), "disabled restart opened a different book")
    assert(not reader.anxui, "Anx plugin remained active after disabled restart")
    local note = assert(noteText(reader), "native note was lost after disabled restart")
    assert(note.page == control.expected.anchor and reader:getCurrentPage() == control.expected.page)
    result.checks.disabled_restart = true
    result.checks.external_file_intent = true
    shot("classic-disabled-reopen", function() finish(reader) end)
end

local function exerciseReader(reader)
    assert(sameBook(reader.document.file, "touch_open"), "touch opened a different book")
    local plugin = assert(reader.anxui)
    result.checks.touch_open = true
    plugin:showReaderPanel()
    assert(plugin.reader_panel)
    shot("reader-toolbar", function()
        requestUntil({{kind = "key", code = 4}}, "Android Back closes reader tools",
            function() return not plugin.reader_panel end, function()
            assert(not plugin.reader_panel, "Android Back did not close Anx reader tools")
            result.checks.system_back = true
            local before = reader:getCurrentPage()
            requestUntil({{kind = "tap", x = math.floor(Screen:getWidth() * .88), y = math.floor(Screen:getHeight() * .5)}},
                "native touch advances the page", function() return reader:getCurrentPage() > before end, function()
                assert(reader:getCurrentPage() > before, "native touch page turn failed")
                result.checks.native_page_turn = true
                reader:handleEvent(Event:new("GotoPage", 3))
                reader.bookmark:onToggleBookmark()
                assert(#reader.annotation.annotations == 1)
                reader.bookmark:setBookmarkNote(1)
                local dialog
                for _, window in ipairs(UIManager._window_stack) do
                    if type(window.widget.getInputText) == "function" then dialog = window.widget end
                end
                assert(dialog, "native note editor missing")
                dialog:setInputText("Android emulator preserved note")
                for _, row in ipairs(dialog.buttons) do
                    for _, button in ipairs(row) do if button.is_enter_default then button.callback() end end
                end
                assert(noteText(reader))
                plugin:showReaderList("notes")
                shot("anx-notes", function()
                    plugin:closeReaderViews()
                    local page = reader:getCurrentPage()
                    requestUntil({{kind = "background_resume"}}, "Android MainActivity resumed",
                        function() return android.isResumed() end, function()
                        assert(ReaderUI.instance == reader and sameBook(reader.document.file, "background_resume"))
                        assert(reader:getCurrentPage() == page and noteText(reader))
                        result.checks.background_resume = true
                        shot("reader-after-background", function()
                            reader:onHome()
                            waitFor(function()
                                local fm = FileManager.instance
                                local returning_plugin = fm and fm.anxui
                                local home = returning_plugin and returning_plugin.home
                                local observation = {
                                    filemanager_exists = fm ~= nil, plugin_exists = returning_plugin ~= nil,
                                    show_pending = returning_plugin ~= nil and returning_plugin.show_pending ~= nil,
                                    recovery = returning_plugin and returning_plugin.recovery_reason
                                        and tostring(returning_plugin.recovery_reason) or false,
                                    home_exists = home ~= nil,
                                    home_shown = home ~= nil and UIManager:isWidgetShown(home) == true,
                                    first_paint_complete = home ~= nil and home.on_ready == nil,
                                }
                                result.return_first_observation = result.return_first_observation or observation
                                result.return_last_observation = observation
                                result.return_observation_count = (result.return_observation_count or 0) + 1
                                result.return_observed_pending = result.return_observed_pending == true or observation.show_pending
                                write("return", {first_observation = result.return_first_observation,
                                    last_observation = observation, observation_count = result.return_observation_count,
                                    observed_pending = result.return_observed_pending})
                                if observation.home_shown and observation.first_paint_complete then return fm end
                            end, function(fm)
                                assert(fm.anxui.home, "return did not restore Anx library")
                                result.checks.library_return = true
                                shot("returned-library", function()
                                    fm.anxui:closeHome()
                                    fm:openFile(control.book)
                                    waitFor(function() return ReaderUI.instance end, function(classic)
                                        assert(sameBook(classic.document.file, "classic_readback"))
                                        assert(classic:getCurrentPage() == page and noteText(classic))
                                        result.checks.classic_readback = true
                                        local disabled = G_reader_settings:readSetting("plugins_disabled", {})
                                        disabled.anxui = true
                                        G_reader_settings:saveSetting("plugins_disabled", disabled)
                                        G_reader_settings:flush()
                                        shot("classic-note-readback", function() finish(classic) end)
                                    end, nil, "classic reader opens the same book")
                                end)
                            end, nil, "returned Anx library shown and first paint complete")
                        end)
                    end)
                end)
            end)
        end)
    end)
end

local function exerciseLibrary(fm)
    local plugin = assert(fm.anxui)
    local sha256 = require("ffi/sha2").sha256
    for relative, expected in pairs(control.plugin_files) do
        local file = assert(io.open(plugin.path .. "/" .. relative, "rb"))
        local bytes = file:read("*a"); file:close()
        assert(sha256(bytes) == expected, "installed APK plugin differs from frozen source: " .. relative)
    end
    result.checks.installed_plugin_identity = true
    local home = assert(plugin.home, "configured Anx startup did not open")
    result.checks.android_startup = true
    shot("library-portrait", function()
        requestUntil({tap(home.layout[2][1])}, "touch search opens the original virtual keyboard", function()
            local dialog = home.search_dialog
            if dialog and UIManager:isWidgetShown(dialog) and dialog:isKeyboardVisible() then return dialog end
        end, function(dialog)
            assert(dialog:isKeyboardVisible(), "touch search did not show original virtual keyboard")
            local keyboard = assert(dialog._input_widget.keyboard)
            local key
            for _, row in ipairs(keyboard.layout) do
                for _, candidate in ipairs(row) do
                    if type(candidate.key) == "string" and candidate.key:lower() == "a" then key = candidate end
                end
            end
            assert(key, "original keyboard has no A key")
            requestUntil({tap(key)}, "virtual A key reaches the input field",
                function() return dialog:getInputText():lower() == "a" end, function()
                assert(dialog:getInputText():lower() == "a", "touch keyboard input was not delivered")
                result.checks.virtual_keyboard_touch = true
                shot("virtual-keyboard", function()
                    requestUntil({{kind = "key", code = 66}}, "Android Enter commits the search", function()
                        return not home.search_dialog and home.query:lower() == "a"
                    end, function()
                        assert(not home.search_dialog and home.query:lower() == "a")
                        assert(#home.cards >= 1)
                        result.checks.search = true
                        local old_width = Screen:getWidth()
                        UIManager:broadcastEvent(Event:new("SetRotationMode", 1))
                        waitFor(function() return Screen:getWidth() ~= old_width end, function()
                            assert(home.query:lower() == "a")
                            assert(home.dimen.w == Screen:getWidth())
                            result.checks.landscape = true
                            shot("library-landscape", function()
                                UIManager:broadcastEvent(Event:new("SetRotationMode", 0))
                                waitFor(function() return Screen:getWidth() == old_width end, function()
                                    result.checks.portrait_restore = true
                                    assert(home.query:lower() == "a")
                                    request({tap(home.cards[1])}, function()
                                        waitFor(function() return ReaderUI.instance end, exerciseReader, nil, "touch opens ReaderUI")
                                    end)
                                end, nil, "portrait dimensions restored")
                            end)
                        end, nil, "landscape dimensions applied")
                    end)
                end)
            end)
        end)
    end)
end

local function startupReady()
    local fm = FileManager.instance
    local plugin = fm and fm.anxui
    local home = plugin and plugin.home
    local stored = G_reader_settings:readSetting("anxui")
    local configured = type(stored) == "table" and stored or {}
    local arguments, windows = {}, {}
    for index, value in ipairs(arg or {}) do
        arguments[#arguments + 1] = {index = index, value = tostring(value)}
    end
    for _, window in ipairs(UIManager._window_stack) do
        local widget = window.widget
        windows[#windows + 1] = {
            name = widget == fm and "filemanager" or widget == home and "anxui_home"
                or type(widget.name) == "string" and widget.name or "unnamed",
            modal = widget.modal == true, toast = widget.toast == true,
        }
    end
    local observation = {
        filemanager_exists = fm ~= nil, plugin_exists = plugin ~= nil,
        startup = configured.startup == true,
        schema = configured.schema ~= nil and tostring(configured.schema) or "unset",
        original_start = tostring(G_reader_settings:readSetting("start_with", "filemanager")),
        guide_shown = require("ui/quickstart"):isShown() == true,
        arguments = arguments, windows = windows,
        show_pending = plugin ~= nil and plugin.show_pending ~= nil,
        stopped = plugin ~= nil and plugin.stopped == true,
        recovery = plugin and plugin.recovery_reason and tostring(plugin.recovery_reason) or false,
        home_exists = home ~= nil,
        home_shown = home ~= nil and UIManager:isWidgetShown(home) == true,
        first_paint_complete = home ~= nil and home.on_ready == nil,
    }
    result.startup_first_observation = result.startup_first_observation or observation
    result.startup_last_observation = observation
    result.startup_observation_count = (result.startup_observation_count or 0) + 1
    result.startup_observed_pending = result.startup_observed_pending == true or observation.show_pending
    write("startup", {
        first_observation = result.startup_first_observation, last_observation = observation,
        observation_count = result.startup_observation_count,
        observed_pending = result.startup_observed_pending,
    })
    if observation.home_shown and observation.first_paint_complete then return fm end
end

step(function()
    if control.phase == "reopen" then
        waitFor(function() return ReaderUI.instance end, verifyReopen, nil, "disabled restart opens ReaderUI")
    else
        waitFor(startupReady, exerciseLibrary, nil, "startup Anx library shown and first paint complete")
    end
end, 5)
