describe("Anx current reader session", function()
    local Reader, Scope, capabilities, UIManager, ui, scope, session, current, calls
    setup(function()
        require("commonrequire")
        Reader = dofile("plugins/anxui.koplugin/reader.lua")
        Scope = dofile("plugins/anxui.koplugin/lifecycle.lua")
        capabilities = dofile("plugins/anxui.koplugin/capabilities.lua")
        UIManager = require("ui/uimanager")
    end)
    before_each(function()
        calls = {}
        G_reader_settings:delSetting("plugins_disabled")
        ui = {
            document = {file = "book.epub", getPageCount = function() return 10 end},
            getCurrentPage = function() return 3 end, doc_props = {title = "Title"},
            view = {footer = {percent_finished = .25}}, rolling = {},
            annotation = {annotations = {}}, toc = {toc = {}, fillToc = function() end},
            link = {addCurrentLocationToStack = function() table.insert(calls, "history") end},
            handleEvent = function(_, event) table.insert(calls, event) end,
            bookmark = {
                getBookmarkPageString = function(_, page) return "native:" .. page end,
                gotoBookmark = function(_, page, pos) table.insert(calls, {page, pos}) end,
                removeItem = function(_, item, index)
                    assert.are.equal(ui.annotation.annotations[index], item)
                    table.remove(ui.annotation.annotations, index)
                end,
            },
        }
        current, scope = ui, Scope.new()
        session = Reader.new(ui, scope, capabilities, function() return current end)
    end)
    after_each(function()
        scope:close(); UIManager:quit(); G_reader_settings:delSetting("plugins_disabled")
    end)

    it("keeps native progress and treats reflow as a paged document", function()
        assert.same({file = "book.epub", title = "Title", page = 3, pages = 10, percent = .25, mode = "Text"}, session:snapshot())
        ui.paging, ui.rolling, ui.document.configurable = {}, nil, {text_wrap = 1}
        assert.are.equal("Reflow", session:snapshot().mode)
        ui.document.configurable.text_wrap = 0
        assert.are.equal("Pages", session:snapshot().mode)
    end)

    it("rejects the previous owner even when another reader opens the same file", function()
        current = {document = ui.document}
        assert.is_false(session:active())
        local snapshot, reason = session:snapshot()
        assert.is_nil(snapshot); assert.are.equal("stale_session", reason)
        current = ui; scope:close()
        assert.is_nil(session.ui); assert.is_nil(session.document)
        assert.is_false(session:active())
    end)

    it("resolves shifted rows by identity and refuses a deleted row with an identical anchor", function()
        local first, chosen = {page = "xp1", datetime = "now"}, {page = "xp1", datetime = "now", note = "A"}
        ui.annotation.annotations = {first, chosen}
        local rows = session:notes()
        table.remove(ui.annotation.annotations, 1)
        assert.are.equal(1, session:resolveNote(rows[2]))
        assert.is_true(session:noteAction("delete", rows[2]))
        ui.annotation.annotations[1] = {page = "xp1", datetime = "now", note = "A"}
        assert.is_false(session:noteAction("delete", rows[2]))
        assert.are.equal(1, #ui.annotation.annotations)
    end)

    it("separates bookmark notes from highlights and preserves opaque anchors", function()
        ui.annotation.annotations = {{page = "xp/opaque", pos0 = "xp/start", note = "Bookmark note"},
            {page = "xp/highlight", drawer = "lighten", text = "Quote"}}
        local rows = session:notes()
        assert.are.equal("bookmarks", rows[1].kind); assert.is_true(rows[1].has_note)
        assert.are.equal("highlights", rows[2].kind); assert.is_false(rows[2].has_note)
        assert.is_true(session:noteAction("goto", rows[1]))
        assert.same({"history", {"xp/opaque", "xp/start"}}, calls)
    end)

    it("preserves chapter navigation history and invalidates a replaced TOC", function()
        local chapter = {title = "Chapter", page = 7, xpointer = "chapter/xp", depth = 2}
        ui.toc.toc = {chapter}
        local row = session:toc()[1]
        assert.is_true(session:gotoChapter(row))
        assert.are.equal("history", calls[1]); assert.are.equal("GotoXPointer", calls[2].handler:sub(3))
        assert.are.equal("chapter/xp", calls[2].args[1])
        ui.toc.toc = {{title = "Other", page = 7}}
        assert.is_false(session:gotoChapter(row)); assert.are.equal(2, #calls)
    end)

    it("closes only native windows opened through this session", function()
        local original = require("ui/widget/infomessage"):new{text = "existing"}
        UIManager:show(original)
        ui.search = {onShowFulltextSearchInput = function()
            UIManager:show(require("ui/widget/infomessage"):new{text = "new"})
        end}
        assert.is_true(session:run("search")); assert.are.equal(2, #UIManager._window_stack)
        scope:close(); assert.are.equal(1, #UIManager._window_stack)
        assert.is_true(UIManager:isWidgetShown(original))
    end)

    it("rechecks exporter configuration and disabled state before calling it", function()
        local ready, exports = false, 0
        ui.exporter = {isReadyToExport = function() return ready end,
            onExportCurrentNotes = setmetatable({}, {__call = function() exports = exports + 1 end})}
        assert.is_false(session:run("export")); ready = true
        assert.is_true(session:run("export")); assert.are.equal(1, exports)
        G_reader_settings:saveSetting("plugins_disabled", {exporter = true})
        assert.is_false(session:run("export")); assert.are.equal(1, exports)
    end)

    it("distinguishes native rolling dogears by page and rejects ambiguous cached anchors", function()
        ui.annotation.getMatchFunc = function()
            return function(a, b) return a.datetime == b.datetime and a.pos0 == b.pos0 end
        end
        ui.annotation.annotations = {{page = "xp/one", datetime = "same"}, {page = "xp/two", datetime = "same"}}
        assert.is_true(session:gotoStoredNote{page = "xp/two", datetime = "same"})
        assert.are.equal("xp/two", calls[2][1])
        assert.is_false(session:gotoStoredNote{page = 2, datetime = "same"})
        ui.annotation.annotations[3] = {page = "xp/two", datetime = "same"}
        assert.is_false(session:gotoStoredNote{page = "xp/two", datetime = "same"})
    end)
end)
