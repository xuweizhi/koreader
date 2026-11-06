-- Test-only Android patch, installed solely in the dedicated emulator's KO_HOME.
local UIManager = require("ui/uimanager")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local Screen = require("device").screen
local JSON = require("json")
local Event = require("ui/event")
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
local function tapBook(card)
    -- The card has a separate 48dp More target over its lower-right cover.
    -- On narrow grids that target can include the overall card's centre.
    UIManager:forceRePaint()
    local dimen = assert(card.dimen)
    return {kind="tap", x=math.floor(dimen.x+dimen.w*.2), y=math.floor(dimen.y+dimen.h*.25)}
end

local function findText(widget, text, seen)
    seen = seen or {}
    if seen[widget] then return end
    seen[widget] = true
    if widget.text == text and widget.callback and widget.dimen then return widget end
    for _, child in ipairs(widget) do
        if type(child) == "table" then
            local found = findText(child, text, seen)
            if found then return found end
        end
    end
end
local function tapText(widget, text)
    UIManager:forceRePaint()
    for _, row in ipairs(widget.item_group or {}) do
        if row.entry and row.entry.text == text then return tap(row) end
    end
    return tap(assert(findText(widget, text), "button unavailable: " .. text))
end
local function ready()
    local fm = FileManager.instance
    local home = fm and fm.anxui and fm.anxui.home
    if home and UIManager:isWidgetShown(home) and home.on_ready == nil then return fm end
end
local function dismissMessages(home)
    for index = #UIManager._window_stack, 1, -1 do
        local widget = UIManager._window_stack[index].widget
        if widget == home then break end
        UIManager:close(widget)
    end
end
local function finish()
    local reader = ReaderUI.instance
    if reader then reader:onClose() end
    if FileManager.instance then FileManager.instance:onClose() end
    result.passed = true
    write("result", result)
    UIManager:quit()
end
local function exercise(fm)
    local plugin, home = fm.anxui, fm.anxui.home
    local sha256 = require("ffi/sha2").sha256
    for relative, expected in pairs(control.plugin_files) do
        local file = assert(io.open(plugin.path .. "/" .. relative, "rb"))
        local bytes = file:read("*a"); file:close()
        assert(sha256(bytes) == expected, "installed plugin mismatch: " .. relative)
    end
    result.checks.installed_plugin_identity = true
    local function current()
        plugin = assert(FileManager.instance.anxui)
        home = assert(plugin.home)
    end
    if control.phase == "reopen" then
        assert(#home.item_table == 2, "membership lost after restart")
        assert(#plugin:module("shelf").roots() == 0, "removed scan root returned")
        assert(home.controls.continue, "continue reading missing after restart")
        request({tap(home.controls.continue)}, function()
            waitFor(function() return ReaderUI.instance end, function(reader)
                assert(sameBook(reader.document.file, "continue_after_restart"))
                assert(reader:getCurrentPage() == 3 and #reader.annotation.annotations == 1)
                result.checks.restart_membership_position_and_note = true
                shot("continue-after-restart", finish)
            end)
        end)
        return
    end
    assert(#home.item_table == 0)
    local importer = plugin:libraryImporter()
    local folder = control.book:match("(.+)/[^/]+$")
    importer:run{roots={folder},recursive=false}
    waitFor(function() return importer.last_result and not importer.operation end, function()
        assert(importer.last_result.stats.added == 3 and not importer.last_result.reason)
        dismissMessages(home)
        local steps = {}
        local function add(callback) steps[#steps + 1] = callback end
        local function nextStep()
            local callback = table.remove(steps, 1)
            if callback then step(function() callback(nextStep) end) else finish() end
        end
        add(function(done)
            shot("bookshelf-portrait", function()
                request({tap(home.cards[1].more_button)}, function()
                    assert(plugin.book_actions)
                    result.checks.touch_visible_more = true
                    request({tapText(plugin.book_actions, plugin.translate("Select / manage books"))}, done)
                end)
            end)
        end)
        add(function(done)
            assert(home.selection_mode)
            request({tap(home.cards[2])}, function()
                request({tap(home.controls.batch_actions)}, function()
                    request({tapText(plugin.batch_actions_menu, plugin.translate("Mark as finished"))}, function()
                        local confirm = assert(plugin.batch_confirmation)
                        request({tapText(confirm, confirm.ok_text)}, done)
                    end)
                end)
            end)
        end)
        add(function(done)
            dismissMessages(home)
            assert(not home.selection_mode)
            request({tap(home.controls.complete)}, function()
                waitFor(function() return not home.loading_status end, function()
                    assert(#home.filtered == 2)
                    result.checks.touch_batch_finished_and_filter = true
                    shot("finished-filter", function() request({tap(home.controls.all)}, done) end)
                end)
            end)
        end)
        add(function(done)
            assert(home.status == nil and #home.filtered == 3)
            local removed
            for _, candidate in ipairs(home.cards) do
                if not sameBook(candidate.item.file, "removed_other_book") then
                    removed = candidate.item.file
                    break
                end
            end
            assert(removed, "no other fixture book is visible")
            home:selectFile(removed)
            request({tap(home.controls.batch_actions)}, function()
                request({tapText(plugin.batch_actions_menu, plugin.translate("Remove from bookshelf"))}, function()
                    local confirm = assert(plugin.batch_confirmation)
                    request({tapText(confirm, confirm.ok_text)}, function()
                        dismissMessages(home)
                        assert(#home.item_table == 2)
                        assert(require("libs/libkoreader-lfs").attributes(removed, "mode") == "file")
                        result.checks.touch_remove_preserves_file = true
                        done()
                    end)
                end)
            end)
        end)
        add(function(done)
            home.on_manage_scan_roots()
            local menu = assert(importer.scan_roots_menu)
            request({tap(menu.item_group[2])}, function()
                request({tapText(importer.scan_root_actions, plugin.translate("Remove scan folder"))}, function()
                    local confirm = importer.scan_root_confirmation
                    request({tapText(confirm, confirm.ok_text)}, function()
                        assert(#plugin:module("shelf").roots() == 0 and #home.item_table == 2)
                        result.checks.touch_remove_scan_root_keeps_books = true
                        shot("empty-scan-roots", function() dismissMessages(home); done() end)
                    end)
                end)
            end)
        end)
        add(function(done)
            local card
            for _, candidate in ipairs(home.cards) do
                if sameBook(candidate.item.file, "find_open_book") then card = candidate end
            end
            request({tapBook(assert(card))}, function()
                waitFor(function() return ReaderUI.instance end, function(reader)
                    reader.rolling:onGotoPage(3)
                    reader.bookmark:onToggleBookmark()
                    reader:onHome()
                    waitFor(ready, function() current(); done() end)
                end)
            end)
        end)
        add(function(done)
            assert(home.controls.continue)
            local width = Screen:getWidth()
            UIManager:broadcastEvent(Event:new("SetRotationMode", 1))
            waitFor(function() return Screen:getWidth() ~= width end, function()
                assert(home.dimen.w == Screen:getWidth() and #home.item_table == 2)
                shot("bookshelf-landscape", function()
                    UIManager:broadcastEvent(Event:new("SetRotationMode", 0))
                    waitFor(function() return Screen:getWidth() == width end, function()
                        result.checks.shelf_rotation = true
                        shot("continue-portrait", done)
                    end)
                end)
            end)
        end)
        add(function(done)
            request({tap(home.controls.continue)}, function()
                waitFor(function() return ReaderUI.instance end, function(reader)
                    assert(sameBook(reader.document.file, "continue_reading"))
                    assert(reader:getCurrentPage() == 3 and #reader.annotation.annotations == 1)
                    result.checks.touch_continue_preserves_position_and_bookmark = true
                    reader:onHome()
                    waitFor(ready, function() current(); done() end)
                end)
            end)
        end)
        nextStep()
    end)
end

step(function() waitFor(ready, exercise, nil, "Anx bookshelf startup") end, 5)
