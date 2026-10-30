describe("Anx library read adapters", function()
    local Library, History, Collection, old_history, old_collections
    setup(function()
        require("commonrequire")
        Library = dofile("plugins/anxui.koplugin/library.lua")
        History, Collection = require("readhistory"), require("readcollection")
    end)
    before_each(function()
        old_history, old_collections = History.hist, Collection.coll
        History.hist, Collection.coll = {}, { favorites = {} }
    end)
    after_each(function() History.hist, Collection.coll = old_history, old_collections end)

    it("keeps same-titled books in different directories and does not mutate the source", function()
        History.hist = {
            {file = "/a/same.epub", text = "same", time = 2},
            {file = "/b/same.epub", text = "same", time = 1, dim = true},
        }
        local result = Library.snapshot({}, "recent")
        assert.are.equal(2, #result)
        assert.are_not.equal(result[1].id, result[2].id)
        assert.is_true(result[2].missing)
        result[1].text = "changed"
        assert.are.equal("same", History.hist[1].text)
        assert.is_nil(History.hist[1].order)
    end)

    it("reads collections in native order without merging equal titles", function()
        Collection.coll.favorites = {
            a = {file = "/a/book.epub", order = 2, text = "book"},
            b = {file = "/b/book.epub", order = 1, text = "book"},
        }
        local result = Library.snapshot({}, "favorites")
        assert.are.equal("/b/book.epub", result[1].id)
        assert.are.equal(2, #result)
        assert.are.equal(0, #Library.snapshot({}, "collection", "absent"))
    end)

    it("filters supported files and handles missing paths explicitly", function()
        local ui = {file_chooser = {item_table = {
            {is_file = true, path = "/a/book.epub", text = "book"},
            {is_file = false, path = "/folder.epub"},
            {is_file = true, path = "/a/book.epub", text = "duplicate"},
        }}}
        assert.are.equal(1, #Library.snapshot(ui, "directory"))
        local signature, reason = Library.signature("/missing-anxui.epub")
        assert.is_nil(signature)
        assert.are.equal("missing_file", reason)
    end)

    it("returns exact results and bounded pages from five thousand entries", function()
        local items = {}
        for n = 1, 5000 do items[n] = {file = "/books/" .. n .. ".epub", text = "Book " .. n, order = n} end
        local results = Library.query(items, "Book 49", "title")
        assert.are.equal(111, #results)
        local page, number, pages = Library.page(results, 100, 12)
        assert.are.equal(10, number)
        assert.are.equal(10, pages)
        assert.are.equal(3, #page)
        assert.are.equal(0, #Library.query(items, "zzzz", "title"))
        assert.are.equal("Book 1", items[1].text)
    end)

    it("keeps empty-query ordering and case-insensitive metadata and path search", function()
        local first = { file = "/Books/Unique.EPUB", text = "Zulu", title = "Alpha", authors = "Writer", order = 1 }
        local second = { file = "/Books/Other.EPUB", text = "Beta", order = 2 }
        local items = { second, first }
        assert.same({first, second}, Library.query(items, "", "native"))
        assert.same({first, second}, Library.query(items, nil, "title"))
        assert.same({first}, Library.query(items, "ALPHA", "native"))
        assert.same({first}, Library.query(items, "WRITER", "native"))
        assert.same({first}, Library.query(items, "UNIQUE.EPUB", "native"))
        assert.same({first}, Library.query(items, "zulu\nalpha", "native"))
        assert.same({second, first}, items)
    end)

    it("refreshes caller-owned rows without retaining stale metadata or changing the native entries", function()
        local entry = { is_file = true, path = "/a/book.epub", text = "Old title", time = 12, dim = true }
        local ui = { file_chooser = { item_table = { entry } } }
        local scratch = Library.snapshot(ui, "directory")
        local row = scratch[1]
        row.title, row.authors = "Cached title", "Cached author"
        entry.text, entry.time, entry.dim = "New title", nil, nil
        local refreshed = Library.snapshot(ui, "directory", nil, scratch)
        assert.are.equal(scratch, refreshed)
        assert.are.equal(row, refreshed[1])
        assert.are.equal("New title", row.text)
        assert.is_nil(row.title)
        assert.is_nil(row.authors)
        assert.is_nil(row.time)
        assert.is_false(row.missing)
        assert.is_nil(entry.id)
        assert.is_nil(entry.order)
        assert.is_nil(entry.title)
        local independent = Library.snapshot(ui, "directory")
        assert.are_not.equal(scratch, independent)
        assert.are_not.equal(row, independent[1])
    end)

    it("does not repurpose old rows when reordering, shrinking, or switching the source", function()
        local a = { is_file = true, path = "/a/book.epub", text = "Same" }
        local b = { is_file = true, path = "/b/book.epub", text = "Same" }
        local ui = { file_chooser = { item_table = { a, b } } }
        local scratch = Library.snapshot(ui, "directory")
        local old_a, old_b = scratch[1], scratch[2]
        ui.file_chooser.item_table = { b, b, a }
        Library.snapshot(ui, "directory", nil, scratch)
        assert.are.equal(2, #scratch)
        assert.are.equal(b.path, scratch[1].file)
        assert.are.equal(a.path, scratch[2].file)
        assert.are_not.equal(old_a, scratch[1])
        assert.are_not.equal(old_b, scratch[2])
        assert.are.equal(a.path, old_a.file)
        assert.are.equal(b.path, old_b.file)
        History.hist = { { file = a.path, text = "Recent title", time = 25 } }
        Library.snapshot(ui, "recent", nil, scratch)
        assert.are.equal(1, #scratch)
        assert.is_nil(scratch[2])
        assert.are.equal("Recent title", scratch[1].text)
        assert.are.equal(25, scratch[1].time)
        Library.snapshot(ui, "favorites", nil, scratch)
        assert.are.equal(0, #scratch)
        assert.are.equal(3, #ui.file_chooser.item_table)
    end)

    it("combines reading status with search and supports author, progress and reversed import order", function()
        local a = {file="/a.epub", text="Alpha", authors="Zulu", order=1, progress={status="complete", percent=1}}
        local b = {file="/b.epub", text="Beta", authors="Alpha", order=2, progress={status="reading", percent=.3}}
        local c = {file="/c.epub", text="Gamma", order=3, progress={status="new"}}
        assert.same({a}, Library.query({a,b,c}, "alpha", "title", "complete"))
        assert.same({}, Library.query({a,b,c}, "Zulu", "title", "reading"))
        assert.same({b}, Library.query({a,b,c}, "", "title", "reading"))
        assert.same({c,b,a}, Library.query({a,b,c}, "", "author"))
        assert.same({c,b,a}, Library.query({a,b,c}, "", "progress"))
        assert.same({c,b,a}, Library.query({a,b,c}, "", "native", nil, true))
    end)
end)
