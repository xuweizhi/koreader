-- Real EPUB/PDF integration. Runs only against the runner's isolated copies.
return function(context)
    local reader, step, shot, input, finish = context.reader, context.step, context.shot, context.input, context.finish
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local Event = require("ui/event")
    local plugin = assert(reader.anxui)
    local first_anchor, stale_row_callback
    local function shownInput()
        for index = #UIManager._window_stack, 1, -1 do
            local widget = UIManager._window_stack[index].widget
            if type(widget.getInputText) == "function" then return widget end
        end
        error("expected original input dialog")
    end
    local function saveInput(text)
        local dialog = shownInput()
        dialog:setInputText(text)
        for _, row in ipairs(dialog.buttons) do
            for _, button in ipairs(row) do
                if button.is_enter_default then button.callback(); return end
            end
        end
        error("default dialog action missing")
    end
    local function panel()
        assert(not plugin.reader_panel)
        reader.menu:onShowMenu(3)
        local entry = assert(reader.menu.menu_items.anxui_reader)
        reader.menu:onCloseReaderMenu()
        entry.callback()
        return assert(plugin.reader_panel)
    end
    local function notes()
        panel().buttons.notes.callback()
        return assert(plugin.reader_list)
    end
    local function closeAndReopen()
            local previous_session = plugin.reader
            panel().buttons.progress.callback()
            assert(shownInput())
            reader:onHome() -- Original save/close must close our native dialog, too.
            assert(not previous_session:active())
            assert(not previous_session.document and not previous_session.ui)
            step(function()
                local fm = assert(require("apps/filemanager/filemanager").instance)
                assert(not plugin.reader_panel and not plugin.reader_list)
                for _, window in ipairs(UIManager._window_stack) do
                    assert(not window.widget.getInputText, "reader dialog survived document close")
                end
                fm.anxui:closeHome()
                fm:openFile(context.book)
                step(function()
                    local reopened = assert(require("apps/reader/readerui").instance)
                    assert(#reopened.annotation.annotations == 1)
                    assert(reopened.annotation.annotations[1].note == "Second surviving note")
                    assert(reopened.view.state.page == 2)
                    shot("reader-reopened-surviving-note")
                    finish()
                end)
            end)
    end
    local function exportAndClose()
        local list = assert(plugin.reader_list)
        list.buttons.export.callback()
        step(function()
            assert(not plugin.reader_list)
            shot("export-not-configured")
            for index = #UIManager._window_stack, 1, -1 do
                local widget = UIManager._window_stack[index].widget
                if widget ~= reader then UIManager:close(widget) end
            end
            -- Select real text using the original document/selection APIs.
            local Geom = require("ui/geometry")
            local position
            for y = 60, Screen:getHeight() - 80, 16 do
                for x = 40, Screen:getWidth() - 40, 24 do
                    local point = Geom:new{x = x, y = y, w = 0, h = 0}
                    local page_point = reader.view:screenToPageTransform(point)
                    if page_point then
                        local ok, word = pcall(reader.document.getWordFromPosition, reader.document, page_point)
                        if ok and word and word.word and word.word ~= "" then position = point; break end
                    end
                end
                if position then break end
            end
            assert(position, "fixture text cannot be selected by the original engine")
            reader.highlight:onHold(nil, {pos = position})
            assert(reader.highlight.selected_text)
            local selected_text = reader.highlight.selected_text.text
            local highlight_index = assert(reader.highlight:saveHighlight())
            reader.highlight:clear()
            assert(#reader.annotation.annotations == 2)
            local highlighted = reader.annotation.annotations[highlight_index]
            assert(highlighted.drawer and highlighted.text ~= "")
            local refreshed = notes()
            refreshed.filter = "highlights"; refreshed:rebuild()
            assert(#refreshed.filtered == 1)
            shot("native-highlight-in-anx-list")
            refreshed.rows[1].hold_callback()
            plugin.note_actions.item_table[2].callback()
            saveInput("Exported highlight note")
            local exporter = assert(reader.exporter)
            for _, target in pairs(exporter.targets) do target.settings.enabled = false end
            exporter.targets.text:toggleEnabled()
            exporter.settings.clipping_dir = context.evidence
            exporter.settings.clipping_filename_single = "anx-export"
            local ready = notes()
            ready.buttons.export.callback()
            step(function()
                local output = assert(io.open(context.evidence .. "/anx-export.txt", "r"))
                local content = output:read("*a"); output:close()
                assert(content:find("Exported highlight note", 1, true))
                assert(content:find(selected_text, 1, true))
                shot("native-export-success")
                for index = #UIManager._window_stack, 1, -1 do
                    local widget = UIManager._window_stack[index].widget
                    if widget ~= reader then UIManager:close(widget) end
                end
                reader.bookmark:removeItem(highlighted, reader.annotation:getItemIndex(highlighted))
                assert(#reader.annotation.annotations == 1)
                closeAndReopen()
            end)
        end)
    end
    local function deleteFirst()
        local list = notes()
        assert(#list.entries == 2)
        list.rows[1].hold_callback()
        assert(plugin.note_actions).item_table[3].callback()
        step(function()
            local confirm = UIManager._window_stack[#UIManager._window_stack].widget
            assert(confirm.ok_callback)
            shot("delete-confirmation")
            confirm.ok_callback(); UIManager:close(confirm)
            assert(#reader.annotation.annotations == 1)
            assert(reader.annotation.annotations[1].note == "Second surviving note")
            assert(#plugin.reader_list.entries == 1)
            exportAndClose()
        end)
    end
    local function verifyNavigation()
        local list = assert(plugin.reader_list)
        assert(#list.filtered == 1 and list.filtered[1].note == "Edited from classic")
        stale_row_callback = list.rows[1].callback
        list.rows[1].callback()
        step(function()
            assert(not plugin.reader_list)
            assert(reader:getCurrentPage() == 2)
            assert(reader.annotation.annotations[1].page == first_anchor)
            local count = #UIManager._window_stack
            stale_row_callback()
            assert(count == #UIManager._window_stack, "closed list callback reopened a window")
            reader:handleEvent(Event:new("GotoPage", 3))
            reader.bookmark:onToggleBookmark()
            assert(#reader.annotation.annotations == 2)
            reader.bookmark:setBookmarkNote(2)
            saveInput("Second surviving note")
            reader:handleEvent(Event:new("GotoPage", 2))
            deleteFirst()
        end)
    end
    local function editFromClassic()
        context.editNote(reader, "Edited from classic", function()
            local list = notes()
            assert(list.entries[1].note == "Edited from classic", "stale saved notes hid the active annotation")
            -- Use the original English keyboard for this exact Latin query;
            -- a Chinese IME correctly transforms those key events otherwise.
            G_reader_settings:saveSetting("keyboard_layout", "en")
            list:showSearch()
            input({{kind = "key", value = "ctrl+u"}, {kind = "type", value = "Edited from classic"},
                {kind = "key", value = "Return"}}, function()
                shot("filtered-notes")
                verifyNavigation()
            end)
        end)
    end
    local function editFromAnx()
        local list = notes()
        assert(#list.entries == 1)
        assert(list.entries[1].kind == "bookmarks" and not list.entries[1].has_note)
        list.rows[1].hold_callback()
        assert(plugin.note_actions).item_table[2].callback()
        step(function()
            assert(not plugin.reader_list)
            shot("anx-native-note-editor")
            saveInput("Written from Anx notes")
            assert(reader.annotation.annotations[1].note == "Written from Anx notes")
            step(function()
                local refreshed = notes()
                assert(refreshed.entries[1].has_note)
                refreshed.filter = "notes"; refreshed:rebuild()
                assert(#refreshed.filtered == 1)
                shot("anx-notes")
                refreshed.filter = "highlights"; refreshed:rebuild()
                assert(#refreshed.filtered == 0, "bookmark note incorrectly classified as a highlight")
                shot("empty-highlights")
                refreshed:onClose()
                editFromClassic()
            end)
        end)
    end
    local function progress()
        panel().buttons.progress.callback()
        step(function()
            shot("native-progress-dialog")
            saveInput("2")
            step(function()
                assert(reader:getCurrentPage() == 2)
                panel().buttons.bookmark.callback()
                assert(#reader.annotation.annotations == 1)
                first_anchor = reader.annotation.annotations[1].page
                editFromAnx()
            end)
        end)
    end
    local function toc()
        local original_page = reader:getCurrentPage()
        panel().buttons.toc.callback()
        step(function()
            local list = assert(plugin.reader_list)
            shot("anx-contents")
            if reader.rolling then
                assert(#list.entries >= 2)
                local chapter = list.entries[2]
                list.on_select(chapter)
                step(function()
                    assert(reader:getCurrentPage() == chapter.page)
                    shot("chapter-target")
                    panel().buttons.back.callback()
                    step(function()
                        assert(reader:getCurrentPage() == original_page, "chapter jump lost native return history")
                        progress()
                    end)
                end)
            else
                assert(#list.entries == 0) -- generated text PDF has no outline
                list:onClose(); progress()
            end
        end)
    end
    local function layout()
        local controls = panel()
        local snapshot = plugin.reader:snapshot()
        assert(snapshot.mode == (reader.paging and "Pages" or "Text"))
        assert(snapshot.percent == reader.view.footer.percent_finished)
        controls.buttons.layout.callback()
        step(function()
            assert(not plugin.reader_panel)
            shot("original-reading-settings")
            reader.config:onCloseConfigMenu()
            panel().buttons.advanced.callback()
            step(function()
                shot("original-advanced-menu")
                reader.menu:onCloseReaderMenu()
                if reader.paging then
                    reader.paging:onToggleReflow()
                    step(function()
                        panel()
                        assert(plugin.reader:snapshot().mode == "Reflow")
                        shot("pdf-reflow-toolbar")
                        plugin:closeReaderViews()
                        reader.paging:onToggleReflow()
                        step(toc)
                    end)
                else toc() end
            end)
        end)
    end
    reader:handleEvent(Event:new("GotoPage", 1))
    panel()
    step(function()
        shot("anx-reader-toolbar")
        input({{kind = "key", value = "Escape"}}, function()
            assert(not plugin.reader_panel)
            local before = reader:getCurrentPage()
            input({{kind = "click", x = math.floor(Screen:getWidth() * .9), y = math.floor(Screen:getHeight() * .5)}}, function()
                assert(reader:getCurrentPage() > before, "toolbar left a hidden overlay intercepting page taps")
                shot("native-page-tap-after-toolbar")
                layout()
            end)
        end)
    end)
end
