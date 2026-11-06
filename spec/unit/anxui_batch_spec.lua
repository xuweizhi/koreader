describe("Anx bookshelf batch operations", function()
    local AnxUI, Collection, DocSettings, BookList, Shelf, plugin, root, a, b, library
    local original_coll, original_settings, original_time, original_cache
    local function read(path)
        local file = assert(io.open(path, "rb"))
        local data = file:read("*a"); file:close(); return data
    end
    setup(function()
        require("commonrequire")
        AnxUI = dofile("plugins/anxui.koplugin/main.lua")
        AnxUI.path = "plugins/anxui.koplugin"
        Collection, DocSettings, BookList = require("readcollection"), require("docsettings"), require("ui/widget/booklist")
        Shelf = dofile("plugins/anxui.koplugin/shelf.lua")
        original_coll, original_settings, original_time = Collection.coll, Collection.coll_settings, Collection.last_read_time
        original_cache = BookList.book_info_cache
    end)
    before_each(function()
        root = os.tmpname(); os.remove(root)
        require("util").makePath(root)
        root = assert(require("ffi/util").realpath(root))
        a, b = root .. "/first.epub", root .. "/second.epub"
        for _, path in ipairs({a, b}) do
            local file = assert(io.open(path, "wb")); file:write("original ebook"); file:close()
        end
        Collection.coll, Collection.coll_settings, Collection.last_read_time = {favorites={}}, {favorites={order=1}}, 0
        library = Shelf.collection(true)
        Collection:addCollection("Reading group")
        for _, path in ipairs({a, b}) do Collection:addItem(path, library) end
        Collection:addItem(a, "favorites")
        Collection:write()
        BookList.book_info_cache = {}
        local doc = DocSettings:open(a)
        doc:saveSetting("percent_finished", .37)
        doc:saveSetting("last_xpointer", "preserved-anchor")
        doc:saveSetting("annotations", {{page="preserved-anchor",note="preserved note"}})
        doc:saveSetting("summary", {status="reading",rating=4})
        assert(doc:flush())
        BookList.setBookInfoCache(a, doc)
        plugin = AnxUI:new{ui={menu={registerToMainMenu=function() end}}}
    end)
    after_each(function()
        plugin:stopPlugin()
        require("ui/uimanager"):quit()
        require("ffi/util").purgeDir(root)
        Collection.coll, Collection.coll_settings, Collection.last_read_time = original_coll, original_settings, original_time
        BookList.book_info_cache = original_cache
    end)

    it("marks books finished without changing their position, annotations or rating", function()
        local stats = plugin:applyBatchBookAction({a, b}, "complete")
        assert.are.equal(2, stats.changed); assert.are.equal(0, stats.errors)
        local doc = DocSettings:open(a)
        assert.are.equal("complete", doc:readSetting("summary").status)
        assert.are.equal(4, doc:readSetting("summary").rating)
        assert.are.equal(.37, doc:readSetting("percent_finished"))
        assert.are.equal("preserved-anchor", doc:readSetting("last_xpointer"))
        assert.same({{page="preserved-anchor",note="preserved note"}}, doc:readSetting("annotations"))
        assert.are.equal("original ebook", read(a))
        assert.are.equal("complete", BookList.getBookInfo(a).status)
        assert.are.equal(.37, BookList.getBookInfo(a).percent_finished)
        assert.are.equal("complete", plugin:module("library").progress(b).status)
    end)

    it("adds to a native group and removes only Anx membership, including after reload", function()
        local sidecar = DocSettings:findSidecarFile(a)
        local original = read(sidecar)
        local added = plugin:applyBatchBookAction({a, b, a}, "add", "Reading group")
        assert.are.equal(2, added.changed)
        local removed = plugin:applyBatchBookAction({a, b}, "remove")
        assert.are.equal(2, removed.changed); assert.are.equal(0, removed.errors)
        Collection.coll, Collection.coll_settings, Collection.last_read_time = nil, nil, 0
        Collection:_read()
        assert.is_false(Collection:isFileInCollection(a, library))
        assert.is_false(Collection:isFileInCollection(b, library))
        assert.is_true(Collection:isFileInCollection(a, "favorites"))
        assert.is_true(Collection:isFileInCollection(a, "Reading group"))
        assert.is_true(Collection:isFileInCollection(b, "Reading group"))
        assert.are.equal(original, read(sidecar))
        assert.are.equal("original ebook", read(a)); assert.are.equal("original ebook", read(b))
    end)

    it("does not report a failed sidecar write as a completed operation", function()
        local sidecar = DocSettings:findSidecarFile(a)
        local original = read(sidecar)
        local flush = DocSettings.flush
        DocSettings.flush = function() return nil end
        local ok, stats = pcall(plugin.applyBatchBookAction, plugin, {a}, "complete")
        DocSettings.flush = flush
        assert.is_true(ok)
        assert.are.equal(0, stats.changed); assert.are.equal(1, stats.errors)
        assert.are.equal(original, read(sidecar))
        assert.are.equal("reading", BookList.getBookInfo(a).status)
    end)

    it("restores native membership when a collection write silently fails", function()
        local write = Collection.write
        Collection.write = function() end
        local ok, stats = pcall(plugin.applyBatchBookAction, plugin, {a, b}, "remove")
        Collection.write = write
        assert.is_true(ok)
        assert.are.equal(0, stats.changed); assert.are.equal(2, stats.errors)
        assert.is_true(Collection:isFileInCollection(a, library))
        assert.is_true(Collection:isFileInCollection(b, library))
        Collection.coll, Collection.coll_settings, Collection.last_read_time = nil, nil, 0
        Collection:_read()
        assert.is_true(Collection:isFileInCollection(a, library))
        assert.is_true(Collection:isFileInCollection(b, library))
    end)
end)
