return function(context)
    local UIManager = require("ui/uimanager")
    local ReaderUI = require("apps/reader/readerui")
    local FileManager = require("apps/filemanager/filemanager")
    local Event = require("ui/event")
    local lfs = require("libs/libkoreader-lfs")
    local step, shot, finish = context.step, context.shot, context.finish
    local directory, name = context.book:match("(.+)/([^/]+)$")
    local other = directory .. "/other/" .. name
    local function current(file)
        local reader = assert(ReaderUI.instance)
        assert(reader.document.file == file, "index opened a same-title book at the wrong path")
        return reader
    end
    local function indexed(plugin, callback, tries)
        if plugin.note_index.running then
            assert((tries or 0) < 40, "index did not finish")
            step(function() indexed(plugin, callback, (tries or 0) + 1) end)
        else
            assert(plugin.notes_library.total == 2, "index lost a saved or active note")
            callback(plugin.notes_library)
        end
    end
    local function rowFor(view, file)
        view.query, view.filter, view.page = "", "all", 1; view:rebuild()
        for _, row in ipairs(view.filtered) do if row.file == file then return row end end
        if view.page_count > 1 then
            view.page = 2; view:rebuild()
            for _, row in ipairs(view.filtered) do if row.file == file then return row end end
        end
        error("indexed row missing")
    end
    local function finishFromFM(fm)
        local plugin = fm.anxui
        plugin:showNoteLibrary()
        local view, index = plugin.notes_library, plugin.note_index
        view.buttons.rebuild.callback()
        assert(index.running)
        context.input({{kind = "key", value = "Escape"}}, function()
            assert(not plugin.notes_library and not index.running and not index.db and not index.job)
            plugin:showNoteLibrary()
            view = plugin.notes_library
            assert(view.total == 2, "closing a scan did not restore previous cache")
            view.buttons.clear.callback()
            assert(view.total == 0)
            view.buttons.rebuild.callback()
            indexed(plugin, function(rebuilt)
                shot("rebuilt-cross-book-notes")
                local row = rowFor(rebuilt, other)
                local attr = lfs.attributes(other)
                assert(lfs.touch(other, attr.access, attr.modification + 2))
                rebuilt.on_select(row)
                assert(not ReaderUI.instance and plugin.notes_library)
                shot("changed-book-index-warning")
                local warning = UIManager._window_stack[#UIManager._window_stack].widget
                assert(warning ~= rebuilt); UIManager:close(warning)
                rebuilt.buttons.rebuild.callback()
                indexed(plugin, function(updated)
                    updated.on_select(rowFor(updated, other))
                    step(function()
                        local reader = current(other)
                        assert(reader:getCurrentPage() == 2)
                        assert(reader.annotation.annotations[1].note == "Beta active note")
                        shot("fm-index-to-original-note")
                        finish()
                    end)
                end)
            end)
        end)
    end
    local function activePriority()
        local reader = current(context.book)
        assert(reader:getCurrentPage() == 3)
        context.editNote(reader, "Alpha changed without closing", function()
            local plugin = reader.anxui
            plugin:showNoteLibrary()
            plugin.notes_library.buttons.rebuild.callback()
            indexed(plugin, function(view)
                view.query = "Alpha changed"; view:rebuild()
                assert(view.total == 1 and view.filtered[1].note == "Alpha changed without closing")
                shot("active-unsaved-note-in-index")
                view:onClose()
                reader:onHome()
                step(function()
                    local fm = assert(FileManager.instance)
                    fm.anxui:closeHome()
                    -- Enough actual paths to cancel a scan through a real key.
                    for i = 1, 120 do
                        assert(lfs.link(context.book, directory .. "/index-extra-" .. i .. ".epub"))
                    end
                    fm.file_chooser:refreshPath()
                    finishFromFM(fm)
                end)
            end)
        end)
    end
    local function buildFromReader()
        local reader, plugin = current(other), current(other).anxui
        reader.menu:onShowMenu(3)
        local entry = assert(reader.menu.menu_items.anxui_notes)
        reader.menu:onCloseReaderMenu(); entry.callback()
        assert(plugin.notes_library.total == 0)
        shot("cross-book-index-empty")
        plugin.notes_library.buttons.rebuild.callback()
        indexed(plugin, function(view)
            assert(ReaderUI.instance == reader, "index created another ReaderUI during scanning")
            assert(reader.annotation.annotations[1].note == "Beta active note")
            shot("cross-book-notes")
            view.on_select(rowFor(view, context.book))
            step(activePriority)
        end)
    end
    local reader = context.reader
    reader:handleEvent(Event:new("GotoPage", 3)); reader.bookmark:onToggleBookmark()
    context.editNote(reader, "Alpha saved note", function()
        reader:switchDocument(other)
        step(function()
            local second = current(other)
            second:handleEvent(Event:new("GotoPage", 2)); second.bookmark:onToggleBookmark()
            context.editNote(second, "Beta active note", buildFromReader)
        end)
    end)
end
