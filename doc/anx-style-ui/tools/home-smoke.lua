-- Test-only integration script: real menus, document engines and original data writers.
local UIManager = require("ui/uimanager")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local Screen = require("device").screen
local JSON = require("json")
local time = require("ui/time")
local evidence = assert(os.getenv("ANX_SMOKE_EVIDENCE"))
local book = assert(os.getenv("ANX_SMOKE_BOOK"))
local scenario = assert(os.getenv("ANX_SMOKE_SCENARIO"))
local expected_path = assert(os.getenv("ANX_SMOKE_EXPECTED"))
local input_id = 0

if scenario == "init_failure" then
    for _, plugin in ipairs(require("pluginloader"):loadPlugins()) do
        if plugin.name == "anxui" then
            plugin.init = function() error("ANX_INJECTED_INIT_FAILURE") end
        end
    end
end

local function step(callback)
    UIManager:scheduleIn(0.4, function()
        local ok, err = xpcall(callback, debug.traceback)
        if not ok then
            print("ANX_SMOKE_FAIL", err)
            UIManager:quit(1)
        end
    end)
end

local shot_counts = {}
local function shot(name)
    UIManager:forceRePaint()
    shot_counts[name] = (shot_counts[name] or 0) + 1
    if shot_counts[name] > 1 then name = name .. "-" .. shot_counts[name] end
    assert(Screen:shot(evidence .. "/" .. name .. ".png"))
end

local function finish()
    local reader = ReaderUI.instance
    if reader then reader:onClose() end
    local fm = FileManager.instance
    if fm then fm:onClose() end
    print("ANX_SMOKE_PASS", scenario)
    UIManager:quit()
end

local function waitReader(callback, tries)
    local reader = ReaderUI.instance
    if reader and reader.document and reader.document.info.number_of_pages then
        assert(reader.document.file == book, "opened the wrong document")
        assert(not FileManager.instance, "file manager was not torn down")
        callback(reader)
    else
        tries = (tries or 0) + 1
        assert(tries < 75, "reader did not become ready")
        step(function() waitReader(callback, tries) end)
    end
end

local function editNote(reader, text, callback)
    reader.bookmark:setBookmarkNote(1)
    local dialog
    for _, window in ipairs(UIManager._window_stack) do
        if type(window.widget.getInputText) == "function" then
            dialog = window.widget
        end
    end
    assert(dialog, "original note editor is not shown")
    dialog:setInputText(text)
    step(function()
        shot("original-note-editor")
        local save
        for _, row in ipairs(dialog.buttons) do
            for _, button in ipairs(row) do
                if button.is_enter_default then save = button.callback end
            end
        end
        assert(save, "original Save action is missing")
        save()
        assert(reader.annotation.annotations[1].note == text, "original editor did not save note")
        step(callback)
    end)
end

local function openFromMenu(callback)
    local fm = assert(FileManager.instance)
    assert(fm.anxui and not fm.anxui.home, "expected classic file manager with available plugin")
    fm.menu:onShowMenu(3)
    local entry = assert(fm.menu.menu_items.anxui_home, "plugin entry missing from real main menu")
    step(function()
        shot("original-menu")
        fm.menu:onCloseFileManagerMenu()
        local started = time.monotonic()
        entry.callback()
        UIManager:forceRePaint()
        local elapsed = time.to_ms(time.monotonic() - started)
        local output = assert(io.open(evidence .. "/home-paint-ms.txt", "a"))
        output:write(tostring(elapsed), "\n")
        output:close()
        print("ANX_SMOKE_HOME_PAINT_MS", elapsed)
        step(function()
            assert(fm.anxui.home, "menu did not open Anx home")
            if scenario ~= "shelf_import" and scenario ~= "shelf_reopen" then
                fm.anxui.home:setSource("directory") -- legacy scenarios use the current-folder fixture
            end
            shot("anx-home")
            callback(fm)
        end)
    end)
end

local function selectBook(fm, callback)
    local home = assert(fm.anxui.home)
    local target_page
    for index, candidate in ipairs(home.filtered) do
        if candidate.file == book then target_page = math.ceil(index / home.perpage); break end
    end
    assert(target_page, "fixture missing from the filtered file list")
    if home.page ~= target_page then home:changePage(target_page - home.page) end
    local card
    for _, candidate in ipairs(home.cards) do
        if candidate.item.file == book then card = candidate; break end
    end
    assert(card, "fixture missing from its visible page")
    card.callback()
    assert(not fm.anxui.home, "home overlay was not closed before reading")
    step(function() waitReader(callback) end)
end

local function verifyClassicRestart(reader)
    local file = assert(io.open(expected_path, "r"))
    local expected = JSON.decode(file:read("*a"))
    file:close()
    assert(not reader.anxui, "disabled plugin still attached after restart")
    assert(reader.view.state.page == expected.page, "reading position changed across restart")
    assert(#reader.annotation.annotations == 1, "annotation count changed across restart")
    local note = reader.annotation.annotations[1]
    assert(note.page == expected.anchor and note.note == expected.note, "annotation semantics changed across restart")
    shot("classic-restart-data")
    print("ANX_SMOKE_DATA_RESTART", expected.page, expected.anchor, expected.note)
    finish()
end

local function input(actions, callback)
    input_id = input_id + 1
    local id = input_id
    local request = assert(io.open(evidence .. "/input-request.tmp", "w"))
    request:write(JSON.encode({id = id, display = os.getenv("DISPLAY"),
        xauthority = os.getenv("XAUTHORITY"), actions = actions}))
    request:close()
    assert(os.rename(evidence .. "/input-request.tmp", evidence .. "/input-request.json"))
    local function poll(tries)
        local response = io.open(evidence .. "/input-response.json", "r")
        if response then
            local answer = JSON.decode(response:read("*a"))
            response:close()
            if answer.id == id then
                assert(answer.ok, answer.error)
                step(callback)
                return
            end
        end
        assert(tries < 40, "X11 input did not complete")
        step(function() poll(tries + 1) end)
    end
    step(function() poll(0) end)
end

local function components(fm)
    local home = assert(fm.anxui.home)
    home:showSearch()
    input({{kind = "type", value = "zznonexistent"}, {kind = "key", value = "Return"}}, function()
        shot("search-input-result")
        print("ANX_SEARCH_INPUT", home.query, home.search_dialog and home.search_dialog:getInputText())
        -- The original Chinese keyboard converts Latin keystrokes to phonetic
        -- candidates. Verify the submitted text and result, not an English IME.
        assert(home.query ~= "" and #home.filtered == 0, "real search input did not filter")
        assert(not home.search_dialog, "search dialog was not released")
        shot("no-search-results")
        home:showSearch()
        input({{kind = "key", value = "ctrl+u"},
            {kind = "key", value = "Return"}}, function()
            assert(home.query == "" and #home.filtered > 0, "clear search failed")
            shot("search-cleared")
            local card = assert(home.cards[1])
            assert(card.dimen.x >= 0 and card.dimen.y >= 0)
            assert(card.dimen.x + card.dimen.w <= Screen:getWidth())
            assert(card.dimen.y + card.dimen.h <= Screen:getHeight())
            input({{kind = "click", x = math.floor(card.dimen.x + card.dimen.w / 2),
                y = math.floor(card.dimen.y + card.dimen.h / 2)}}, function()
                waitReader(function(reader)
                    assert(not fm.anxui.home, "mouse opening retained overlay")
                    shot("mouse-opened-reader")
                    reader:onHome()
                    step(function()
                        local returned = assert(FileManager.instance)
                        assert(returned.anxui.home)
                        local actions = {}
                        for y, row in ipairs(returned.anxui.home.layout) do
                            if row[1] == returned.anxui.home.cards[1] then
                                local delta = y - returned.anxui.home.selected.y
                                for __ = 1, math.abs(delta) do
                                    actions[#actions + 1] = {kind = "key", value = delta > 0 and "Down" or "Up"}
                                end
                                break
                            end
                        end
                        actions[#actions + 1] = {kind = "key", value = "Return"}
                        input(actions, function()
                            waitReader(function(key_reader)
                                shot("keyboard-opened-reader")
                                key_reader:onHome()
                                step(function()
                                    input({{kind = "key", value = "Escape"}}, function()
                                        local classic = assert(FileManager.instance)
                                        assert(not classic.anxui.home, "Escape retained overlay")
                                        classic.anxui:showHome()
                                        local before_removal = classic.anxui.home
                                        assert(os.rename(book, book .. ".test-hidden"))
                                        local ok, reason = classic.anxui:openBook(book)
                                        assert(not ok and reason == "missing_file")
                                        assert(before_removal.error_dialog and not ReaderUI.instance)
                                        shot("missing-file-error")
                                        assert(os.rename(book .. ".test-hidden", book))
                                        input({{kind = "key", value = "Escape"}}, function()
                                            assert(not before_removal.error_dialog)
                                            assert(classic.anxui.home == before_removal)
                                            before_removal:onClose()
                                            classic.file_chooser:changeToPath(book:match("(.+)/[^/]+$") .. "/empty")
                                            openFromMenu(function(empty_fm)
                                                assert(#empty_fm.anxui.home.filtered == 0, "empty directory contains stale books")
                                                shot("empty-folder")
                                                finish()
                                            end)
                                        end)
                                    end)
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end)
end

local function library(fm)
    local home = assert(fm.anxui.home)
    local function ready(tries)
        local card = assert(home.cards[1])
        if not card.info or (book:match("%.pdf$") and (not card.info.cover or card.info.cover.h < 192)) then
            assert(tries < 40, "native metadata/cover extraction did not finish")
            step(function() ready(tries + 1) end)
            return
        end
        assert(home.covers.bytes <= home.covers.limit)
        shot("cached-cover-grid")
        local recent = home.layout[3][2]
        input({{kind = "click", x = math.floor(recent.dimen.x + recent.dimen.w / 2),
            y = math.floor(recent.dimen.y + recent.dimen.h / 2)}}, function()
            assert(home.source == "recent" and #home.filtered == 2)
            assert(home.filtered[1].id ~= home.filtered[2].id)
            home:showOptions()
            home.options_menu.item_table[1].callback()
            assert(home.list_mode)
            step(function()
                shot("recent-list")
                local old_scope, old_covers = home.render_scope, home.covers
                home:setSource("favorites")
                assert(not old_scope.alive and old_covers.bytes == 0)
                assert(#home.filtered == 2)
                home:setSource("collection", "Smoke test")
                assert(#home.filtered == 1)
                home:setSource("recent")
                selectBook(fm, function(reader)
                    reader:onHome()
                    step(function()
                        local returned = assert(FileManager.instance)
                        local restored = assert(returned.anxui.home)
                        assert(restored.source == "recent" and restored.list_mode)
                        shot("restored-recent-list")
                        for __ = 1, 20 do restored:setSource("directory"); restored:setSource("favorites") end
                        restored:setSource("collection", "Absent test collection")
                        step(function()
                            assert(#restored.filtered == 0 and #restored.cards == 0)
                            assert(restored.covers.bytes == 0)
                            shot("empty-collection-after-cancel")
                            finish()
                        end)
                    end)
                end)
            end)
        end)
    end
    ready(0)
end

local function nativeButton(dialog, label)
    local _ = require("gettext")
    for __, row in ipairs(dialog.buttons) do
        for ___, button in ipairs(row) do
            if button.text == _(label) or button.text == _.pgettext("File", label) then
                assert(button.enabled ~= false, "native action is disabled: " .. label)
                button.callback()
                return
            end
        end
    end
    error("native action missing: " .. label)
end

local function fileActions(fm)
    selectBook(fm, function(reader)
        reader.bookmark:onToggleBookmark()
        editNote(reader, "Keep this note through rename and move", function()
            reader:onHome()
            step(function()
                local owner = assert(FileManager.instance)
                local plugin = assert(owner.anxui)
                input({{kind = "key", value = "shift+Return"}}, function()
                    assert(plugin.book_actions, "keyboard long press did not show actions")
                    shot("book-actions")
                    plugin.book_actions.item_table[3].callback()
                    assert(not plugin.home)
                    local list = assert(owner.collections.coll_list)
                    local favorite
                    for __, item in ipairs(list.item_table) do if item.name == "favorites" then favorite = item end end
                    assert(favorite and favorite.idx)
                    list:onMenuChoice(favorite)
                    list:onLeftButtonTap()
                    local dialog = UIManager._window_stack[#UIManager._window_stack].widget
                    nativeButton(dialog, "Apply selection")
                    assert(require("readcollection"):isFileInCollection(book, "favorites"))
                    plugin:showHome()
                    plugin.home:setSource("favorites")
                    assert(#plugin.home.filtered == 1)
                    plugin:showBookActions(book)
                    plugin.book_actions.item_table[2].callback()
                    shot("native-book-information")
                    input({{kind = "key", value = "Escape"}}, function()
                        plugin:showHome()
                        plugin:showBookActions(book)
                        plugin.book_actions.item_table[4].callback()
                        shot("native-more-actions")
                        nativeButton(owner.file_chooser.file_dialog, "Rename")
                        local rename = UIManager._window_stack[#UIManager._window_stack].widget
                        assert(type(rename.setInputText) == "function")
                        local original = book
                        local name = "renamed-" .. book:match("([^/]+)$")
                        rename:setInputText(name)
                        nativeButton(rename, "Rename")
                        book = original:match("(.+)/[^/]+$") .. "/" .. name
                        local lfs = require("libs/libkoreader-lfs")
                        assert(not lfs.attributes(original) and lfs.attributes(book))
                        local function verifyData()
                            assert(require("readhistory"):getIndexByFile(book))
                            assert(require("readcollection"):isFileInCollection(book, "favorites"))
                            local notes = require("docsettings"):open(book):readSetting("annotations")
                            assert(#notes == 1 and notes[1].note == "Keep this note through rename and move")
                        end
                        verifyData()
                        plugin:showHome()
                        assert(#plugin.home.filtered == 1 and plugin.home.filtered[1].file == book)
                        shot("renamed-book-favorite")
                        plugin:showBookActions(book)
                        plugin.book_actions.item_table[4].callback()
                        nativeButton(owner.file_chooser.file_dialog, "Cut")
                        local destination = book:match("(.+)/[^/]+$") .. "/empty"
                        owner.file_chooser:changeToPath(destination)
                        owner:onShowPlusMenu()
                        nativeButton(owner.plus_dialog, "Paste")
                        local renamed = book
                        book = destination .. "/" .. name
                        assert(not lfs.attributes(renamed) and lfs.attributes(book))
                        verifyData()
                        plugin:showHome()
                        assert(#plugin.home.filtered == 1 and plugin.home.filtered[1].file == book)
                        shot("moved-book-favorite")
                        selectBook(owner, function(final_reader)
                            assert(final_reader.annotation.annotations[1].note == "Keep this note through rename and move")
                            shot("reader-after-native-move")
                            finish()
                        end)
                    end)
                end)
            end)
        end)
    end)
end

UIManager:scheduleIn(3.5, function() step(function()
    if scenario == "startup" then
        local case = assert(os.getenv("ANX_SMOKE_STARTUP_CASE"))
        local fm, reader = FileManager.instance, ReaderUI.instance
        if case == "missing_last" then
            assert(not fm and not reader)
            local dialog = assert(UIManager._window_stack[#UIManager._window_stack].widget)
            assert(dialog.cancel_callback)
            shot("native-missing-last-file")
            dialog.cancel_callback()
            UIManager:close(dialog)
            step(function()
                assert(FileManager.instance and not FileManager.instance.anxui.home)
                shot("classic-after-missing-last-file")
                finish()
            end)
            return
        elseif case == "last" or case == "explicit_file" or case == "guide" then
            assert(reader and not fm and not reader.anxui.home)
            assert((case == "guide" and reader.document.file ~= book) or reader.document.file == book)
            shot("preserved-" .. case)
            reader:onHome()
            step(function()
                assert(FileManager.instance and not FileManager.instance.anxui.home)
                finish()
            end)
            return
        end
        assert(fm and not reader)
        if case == "library" then
            assert(fm.anxui.home and not G_reader_settings:readSetting("anxui").opening)
        elseif case == "disabled" then assert(not fm.anxui)
        else
            assert(not fm.anxui.home)
            if case == "recovery" then
                fm.anxui:showHome()
                assert(fm.anxui.recovery_dialog)
            elseif case == "history" then assert(fm.history.booklist_menu)
            elseif case == "favorites" then assert(fm.collections.booklist_menu)
            elseif case == "folder_shortcuts" then assert(#UIManager._window_stack > 1) end
        end
        shot("startup-" .. case)
        finish()
        return
    end
    if scenario == "classic_home" then
        assert(FileManager.instance and not FileManager.instance.anxui)
        shot("classic-filemanager")
        finish()
        return
    end
    if scenario == "init_failure" then
        local fm = assert(FileManager.instance)
        assert(not fm.anxui, "failed initializer still registered a plugin")
        shot("classic-after-init-failure")
        fm:openFile(book)
        step(function()
            waitReader(function(reader)
                assert(not reader.anxui, "failed initializer still attached in reader")
                shot("reader-after-init-failure")
                finish()
            end)
        end)
        return
    end
    if scenario == "reopen" then
        waitReader(verifyClassicRestart)
        return
    end
    if scenario == "library" then
        local other = book:gsub("([^/]+)$", "other/%1")
        local history, collections = require("readhistory"), require("readcollection")
        history:addItem(book)
        history:addItem(other)
        collections:addItem(book, "favorites")
        collections:addItem(other, "favorites")
        collections:addCollection("Smoke test")
        collections:addItem(book, "Smoke test")
        collections:write()
    end
    if scenario == "home_failure" then
        local fm = assert(FileManager.instance)
        local plugin = assert(fm.anxui)
        local original_module = plugin.module
        plugin.module = function(self, name)
            if name == "views/home" then return { new = function() error("ANX_INJECTED_HOME_FAILURE") end } end
            return original_module(self, name)
        end
        local ok, reason = plugin:showHome()
        assert(not ok and reason == "home_failed" and not plugin.home)
        assert(G_reader_settings:readSetting("anxui").opening)
        shot("home-failure-classic-available")
        UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget)
        -- Leave the persisted opening marker for a genuinely new process.
        finish()
        return
    end
    if scenario == "recovery_resume" then
        local fm = assert(FileManager.instance)
        local plugin = assert(fm.anxui)
        assert(plugin.recovery_reason == "unfinished_open" and not plugin.home)
        shot("restart-classic-available")
        plugin:showHome()
        assert(plugin.recovery_dialog)
        shot("recovery-prompt")
        input({{kind = "key", value = "Escape"}}, function()
            assert(not plugin.recovery_dialog and not plugin.home)
            plugin:showHome()
            local dialog = assert(plugin.recovery_dialog)
            dialog.ok_callback()
            UIManager:close(dialog)
            step(function()
                assert(plugin.home and not G_reader_settings:readSetting("anxui").opening)
                shot("recovered-home")
                selectBook(fm, function(reader)
                    shot("reader-after-recovery")
                    assert(reader.document.file == book)
                    finish()
                end)
            end)
        end)
        return
    end
    if scenario == "broken" or scenario == "broken_classic" then
        local function opened()
            step(function()
                assert(not ReaderUI.instance, "original engine accepted the malformed fixture; revise test expectation")
                assert(FileManager.instance, "failed open lost original file manager")
                assert(require("libs/libkoreader-lfs").attributes(book, "mode") == "file", "failed open deleted the source")
                shot("original-open-error")
                finish()
            end)
        end
        if scenario == "broken_classic" then FileManager.instance:openFile(book); opened()
        else openFromMenu(function(fm) fm.anxui:openBook(book); opened() end) end
        return
    end
    openFromMenu(function(fm)
        if scenario == "shelf_import" or scenario == "shelf_reopen" then
            dofile("/data/koreader/doc/anx-style-ui/tools/shelf-smoke.lua"){
                fm=fm, step=step, shot=shot, input=input, selectBook=selectBook,
                finish=finish, evidence=evidence, book=book, scenario=scenario,
            }
            return
        end
        if scenario == "entry_points" then
            dofile("/data/koreader/doc/anx-style-ui/tools/entry-smoke.lua"){
                fm = fm, step = step, shot = shot, input = input, selectBook = selectBook,
                finish = finish, evidence = evidence,
            }
            return
        end
        if scenario == "visual" then
            dofile("/data/koreader/doc/anx-style-ui/tools/visual-smoke.lua"){
                fm = fm, step = step, shot = shot, selectBook = selectBook, finish = finish,
            }
            return
        end
        if scenario == "plugins" or scenario == "plugins_disabled" or scenario == "plugins_enabled" then
            dofile("/data/koreader/doc/anx-style-ui/tools/plugins-smoke.lua"){
                fm = fm, shot = shot, finish = finish, selectBook = selectBook,
                archive = assert(os.getenv("ANX_SMOKE_ARCHIVE")),
            }
            return
        end
        if scenario == "assistant" then
            dofile("/data/koreader/doc/anx-style-ui/tools/assistant-smoke.lua"){
                fm = fm, shot = shot, step = step, finish = finish, book = book, selectBook = selectBook,
            }
            return
        end
        if scenario == "settings_groups" then
            local check = dofile("/data/koreader/doc/anx-style-ui/tools/settings-groups-smoke.lua")
            check{ui = fm, shot = shot, done = function()
                selectBook(fm, function(reader)
                    check{ui = reader, shot = shot, done = finish}
                end)
            end}
            return
        end
        if scenario == "statistics" then
            selectBook(fm, function(reader)
                dofile("/data/koreader/doc/anx-style-ui/tools/statistics-smoke.lua"){
                    reader = reader, step = step, shot = shot, finish = finish,
                }
            end)
            return
        end
        if scenario == "advanced" then
            selectBook(fm, function(reader)
                dofile("/data/koreader/doc/anx-style-ui/tools/advanced-smoke.lua"){
                    reader = reader, step = step, shot = shot, finish = finish,
                }
            end)
            return
        end
        if scenario == "note_index" then
            selectBook(fm, function(reader)
                dofile("/data/koreader/doc/anx-style-ui/tools/note-index-smoke.lua"){
                    reader = reader, step = step, shot = shot, input = input, finish = finish,
                    editNote = editNote, book = book, evidence = evidence,
                }
            end)
            return
        end
        if scenario == "reader_tools" then
            selectBook(fm, function(reader)
                dofile("/data/koreader/doc/anx-style-ui/tools/reader-smoke.lua"){
                    reader = reader, step = step, shot = shot, input = input, finish = finish,
                    editNote = editNote, book = book, evidence = evidence,
                }
            end)
            return
        end
        if scenario == "replace" then
            local home = fm.anxui.home
            local function waitTitle(title, callback, tries)
                local info = home.cards[1] and home.cards[1].info
                if info and info.title and (not title or info.title == title) then callback(info); return end
                assert((tries or 0) < 50, "metadata did not become ready: " .. tostring(title))
                step(function() waitTitle(title, callback, (tries or 0) + 1) end)
            end
            local function search(query, count)
                home:showSearch()
                local dialog = home.search_dialog
                dialog:setInputText(query)
                dialog.buttons[1][2].callback()
                assert(#home.filtered == count, "metadata query returned an incorrect count")
            end
            waitTitle(nil, function(info)
                assert(info.authors == "Anx UI Test")
                search("Anx UI Test", 1)
                shot("search-original-author")
                search("absent-author", 0)
                search("", 1)
                local before = home.library.signature(book)
                assert(os.rename(assert(os.getenv("ANX_SMOKE_REPLACEMENT")), book))
                assert(before ~= home.library.signature(book))
                assert(home.covers:read(book) == nil, "old metadata survived changed file identity")
                home:loadItems(); home:rebuild()
                waitTitle("Replacement edition with a new title", function(replaced)
                    assert(replaced.authors == "Replacement Author")
                    search("Replacement Author", 1)
                    shot("search-replacement-author")
                    selectBook(fm, function(reader)
                        assert(reader.doc_props.display_title == "Replacement edition with a new title")
                        shot("reader-after-replacement")
                        finish()
                    end)
                end)
            end)
            return
        end
        if scenario == "large_library" then
            local home = fm.anxui.home
            local count = tonumber(os.getenv("ANX_SMOKE_LIBRARY_COUNT"))
            assert(#home.item_table == count and #home.filtered == count)
            assert(#home.cards <= home.perpage)
            local expected = 0
            for n = 2, count do if string.format("Sample-%05d", n):find("Sample-00", 1, true) then expected = expected + 1 end end
            home:showSearch()
            local dialog = home.search_dialog
            dialog:setInputText("Sample-00")
            dialog.buttons[1][2].callback()
            assert(#home.filtered == expected)
            home.sort = "title"
            home:rebuild()
            -- Cached titles may differ from filenames. Validate the actual
            -- title/fallback ordering, including the deterministic path tie.
            for index = 2, #home.filtered do
                local a, b = home.filtered[index - 1], home.filtered[index]
                local a_title, b_title = a.title or a.text, b.title or b.text
                assert(a_title < b_title or (a_title == b_title and a.file < b.file))
            end
            home:changePage(home.page_count)
            assert(home.page == home.page_count and #home.cards <= home.perpage)
            shot("large-library-last-results")
            home.query = "absent-large-library-query"
            home:rebuild()
            step(function()
                assert(#home.filtered == 0 and home.query == "absent-large-library-query")
                assert(home.covers.bytes == 0)
                shot("large-library-no-results")
                print("ANX_LARGE_LIBRARY_COUNTS", count, expected)
                finish()
            end)
            return
        end
        if scenario == "resize" then
            local home = fm.anxui.home
            home.query = book:match("([^/]+)$")
            home.selected_file = book
            home:rebuild()
            local function resize(width, height, label, callback)
                local old_scope = home.render_scope
                input({{kind = "resize", width = width, height = height}}, function()
                    assert(Screen:getWidth() == width and Screen:getHeight() == height)
                    assert(not old_scope.alive and home.selected_file == book)
                    assert(home.query == book:match("([^/]+)$") and #home.filtered == 1)
                    assert(home:getFocusItem().item.file == book)
                    shot(label)
                    for __, row in ipairs(home.layout) do
                        for ___, widget in ipairs(row) do
                            assert(widget.dimen.x >= 0 and widget.dimen.y >= 0)
                            assert(widget.dimen.x + widget.dimen.w <= width)
                            assert(widget.dimen.y + widget.dimen.h <= height)
                        end
                    end
                    callback()
                end)
            end
            resize(1280, 800, "wide-selected-query", function()
                assert(home.wide)
                resize(360, 640, "narrow-selected-query", function()
                    assert(not home.wide)
                    resize(640, 360, "landscape-selected-query", function()
                        input({{kind = "key", value = "Return"}}, function()
                            waitReader(function(reader)
                                shot("reader-after-resize")
                                assert(reader.document.file == book)
                                finish()
                            end)
                        end)
                    end)
                end)
            end)
            return
        end
        if scenario == "library" then library(fm); return end
        if scenario == "file_actions" then fileActions(fm); return end
        if scenario == "settings_reopen" then
            assert(fm.anxui.settings:options().mode == "gray")
            assert(fm.anxui.settings:options().large_text)
            assert(not G_reader_settings:readSetting("anxui").opening)
            shot("persisted-gray-large-text")
            finish()
            return
        end
        if scenario == "settings" then
            local plugin = fm.anxui
            assert(plugin:module("capabilities").plugin(fm, "statistics", "onShowReaderProgress").state == "available")
            plugin:showPreferences()
            shot("appearance-settings")
            plugin.preferences_menu.item_table[1].sub_item_table[3].callback()
            assert(plugin.settings:options().mode == "gray" and not plugin.preferences_menu)
            plugin:showPreferences()
            plugin.preferences_menu.item_table[2].callback()
            assert(plugin.settings:options().large_text)
            shot("gray-large-text")
            assert(not G_reader_settings:readSetting("anxui").opening)
            plugin:showPreferences()
            plugin.preferences_menu.item_table[4].callback()
            assert(not plugin.home and fm.menu.menu_container)
            local native = fm.menu.menu_container[1]
            assert(native.tab_item_table[native.cur_tab].id == "setting")
            shot("native-settings-by-stable-id")
            native:closeMenu()
            plugin:showHome()
            plugin:showPreferences()
            plugin.preferences_menu.item_table[5].callback()
            assert(not plugin.home and not plugin.preferences_menu)
            shot("classic-from-settings")
            finish()
            return
        end
        if scenario == "components" then
            components(fm)
            return
        end
        if scenario == "home" then
            local plugin = fm.anxui
            local count = #UIManager._window_stack
            plugin:showHome()
            assert(#UIManager._window_stack == count, "duplicate overlay")
            plugin.home:onClose()
            assert(not plugin.home, "close retained overlay")
            plugin:showHome()
            local PluginLoader = require("pluginloader")
            local disable
            for _, item in ipairs(PluginLoader:genPluginManagerSubItem()[2].sub_item_table) do
                if item.text == plugin.fullname then disable = item.callback end
            end
            assert(disable, "original plugin manager is missing the plugin")
            disable()
            assert(G_reader_settings:readSetting("plugins_disabled").anxui, "plugin manager did not persist disabled state")
            assert(not plugin.home, "disabling retained overlay")
            plugin:showHome()
            assert(not plugin.home, "stale action reopened a stopped plugin")
            shot("original-restart-prompt")
            -- Close the original restart prompt without restarting; its saved
            -- setting is verified in the separate roundtrip/reopen scenario.
            for i = #UIManager._window_stack, 1, -1 do
                local widget = UIManager._window_stack[i].widget
                if widget ~= fm then UIManager:close(widget) end
            end
            shot("classic-after-disable")
            finish()
            return
        end
        selectBook(fm, function(reader)
            assert(#reader.annotation.annotations == 0, "fixture must start without annotations")
            if scenario == "format" then
                reader.anxui:showReaderPanel()
                assert(reader.anxui.reader:snapshot().pages == reader.document:getPageCount())
                shot("format-reading-tools")
                reader.anxui.reader_panel.buttons.advanced.callback()
                shot("format-original-advanced")
                reader.menu:onCloseReaderMenu()
            end
            local target = math.min(3, reader.document.info.number_of_pages)
            if reader.document.info.has_pages then
                reader.paging:onGotoPage(target)
            else
                reader.rolling:onGotoPage(target)
            end
            reader.bookmark:onToggleBookmark()
            assert(#reader.annotation.annotations == 1, "original bookmark action did not add a bookmark")
            local anchor = reader.annotation.annotations[1].page
            editNote(reader, "Created through Anx entry", function()
                shot("anx-reader-bookmark")
                if scenario == "format" then
                    reader.anxui:showReaderList("notes")
                    assert(#reader.anxui.reader_list.entries == 1)
                    shot("format-anx-notes")
                    reader.anxui.reader_list.rows[1].callback()
                    assert(reader:getCurrentPage() == target)
                end
                reader:onHome()
                step(function()
                    local returned = assert(FileManager.instance)
                    assert(returned ~= fm, "reused a closed file manager")
                    assert(returned.anxui.home, "return to Anx library failed")
                    assert(not ReaderUI.instance, "reader survived return")
                    shot("returned-to-library")
                    returned.anxui.home:onClose()
                    returned:openFile(book)
                    step(function()
                        waitReader(function(classic_reader)
                            assert(classic_reader.view.state.page == target, "progress changed on classic reopen")
                            local note = classic_reader.annotation.annotations[1]
                            assert(note.page == anchor and note.note == "Created through Anx entry")
                            editNote(classic_reader, "Edited through classic entry", function()
                                classic_reader:onHome()
                                step(function()
                                    local classic_fm = assert(FileManager.instance)
                                    assert(not classic_fm.anxui.home, "classic opening was unexpectedly redirected")
                                    openFromMenu(function(new_fm)
                                        selectBook(new_fm, function(final_reader)
                                            local final_note = final_reader.annotation.annotations[1]
                                            assert(final_note.page == anchor and final_note.note == "Edited through classic entry")
                                            assert(final_reader.view.state.page == target, "reverse roundtrip lost position")
                                            shot("anx-after-classic-edit")
                                            local output = assert(io.open(expected_path, "w"))
                                            output:write(JSON.encode({page = target, anchor = anchor, note = final_note.note}))
                                            output:close()
                                            local disabled = G_reader_settings:readSetting("plugins_disabled", {})
                                            disabled.anxui = true
                                            G_reader_settings:saveSetting("plugins_disabled", disabled)
                                            G_reader_settings:flush()
                                            finish()
                                        end)
                                    end)
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end)
end) end)
