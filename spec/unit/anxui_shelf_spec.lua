describe("Anx persistent bookshelf import", function()
    local Shelf, Scope, Collection, UIManager, lfs, root, scope, collection_file
    local original_coll, original_settings, original_read_time, sequence
    local function write(path, text)
        local f = assert(io.open(path, "wb")); f:write(text or "ebook fixture"); f:close()
    end
    local function read(path)
        local f = assert(io.open(path, "rb")); local data = f:read("*a"); f:close(); return data
    end
    local function run(options)
        local result, reason
        options.on_done = function(stats, err) result, reason = stats, err end
        local job = Shelf.start(scope, options)
        for __ = 1, 10000 do
            if not job.running then break end
            local task = assert(next(scope.tasks))
            UIManager:unschedule(task); task()
        end
        assert.is_false(job.running)
        return result, reason
    end
    setup(function()
        require("commonrequire")
        Shelf, Scope = dofile("plugins/anxui.koplugin/shelf.lua"), dofile("plugins/anxui.koplugin/lifecycle.lua")
        Collection, UIManager, lfs = require("readcollection"), require("ui/uimanager"), require("libs/libkoreader-lfs")
        original_coll, original_settings, original_read_time = Collection.coll, Collection.coll_settings, Collection.last_read_time
        collection_file = require("datastorage"):getSettingsDir() .. "/collection.lua"
        sequence = 0
    end)
    before_each(function()
        sequence = sequence + 1
        root = require("datastorage"):getDataDir() .. "/anx-import-" .. sequence
        require("util").makePath(root .. "/nested")
        root = require("ffi/util").realpath(root)
        Collection.coll, Collection.coll_settings, Collection.last_read_time = {favorites={}}, {favorites={order=1}}, 0
        Collection:write()
        scope = Scope.new()
        write(root .. "/same.epub", "first book")
        write(root .. "/nested/same.epub", "second book")
    end)
    after_each(function() scope:close(); UIManager:quit() end)
    teardown(function()
        Collection.coll, Collection.coll_settings, Collection.last_read_time = original_coll, original_settings, original_read_time
    end)

    it("imports real paths once and preserves distinct books, files and sidecars across reload", function()
        local a, b = root .. "/same.epub", root .. "/nested/same.epub"
        require("util").makePath(root .. "/same.sdr")
        local sidecar = root .. "/same.sdr/metadata.epub.lua"
        write(sidecar, 'return {last_xpointer="same-anchor",annotations={{note="keep"}}}')
        assert(lfs.link(a, root .. "/alias.epub", true))
        local original = read(sidecar)
        local stats, reason = run{files={a, b, a, root .. "/alias.epub"}}
        assert.is_nil(reason); assert.are.equal(2, stats.added); assert.are.equal(2, stats.duplicates)
        assert.are.equal("first book", read(a)); assert.are.equal("second book", read(b))
        assert.are.equal(original, read(sidecar))
        Collection.coll, Collection.coll_settings, Collection.last_read_time = nil, nil, 0
        Collection:_read()
        local name = assert(Shelf.collection(false))
        assert.is_true(Collection:isFileInCollection(a, name))
        assert.is_true(Collection:isFileInCollection(b, name))
        local again = run{files={a, b}}
        assert.are.equal(0, again.added); assert.are.equal(2, again.duplicates)
    end)

    it("scans nested folders, skips hidden files, sidecars, images and symlink cycles, and remembers roots", function()
        require("util").makePath(root .. "/.hidden")
        require("util").makePath(root .. "/same.sdr")
        write(root .. "/.hidden/secret.epub")
        write(root .. "/same.sdr/ignored.epub")
        write(root .. "/cover.jpg")
        write(root .. "/data.lua")
        assert(lfs.link(root, root .. "/nested/cycle", true))
        local stats, reason = run{roots={root, root .. "/nested"}, recursive=true}
        assert.is_nil(reason); assert.are.equal(2, stats.added)
        assert.is_true(stats.skipped >= 4)
        assert.same({root, root .. "/nested"}, Shelf.roots())
        local again = run{roots=Shelf.roots()}
        assert.are.equal(0, again.added); assert.are.equal(2, again.duplicates)
    end)

    it("can scan just the chosen folder and reports missing input without creating a library", function()
        local stats = run{files={root .. "/missing.epub", root .. "/unknown.bin"}, roots={root .. "/missing"}}
        assert.are.equal(0, stats.added); assert.are.equal(2, stats.errors)
        assert.is_nil(Shelf.collection(false))
        stats = run{roots={root}, recursive=false}
        assert.are.equal(1, stats.added)
    end)

    it("cancels between batches without saving partial results or executing stale callbacks", function()
        for n = 1, 150 do write(root .. "/item" .. n .. ".epub") end
        local original = read(collection_file)
        local job = Shelf.start(scope, {roots={root}, on_done=function() error("canceled import completed") end})
        local first = assert(next(scope.tasks)); UIManager:unschedule(first); first()
        assert.is_true(job.running); assert.is_true(#job.pending > 0)
        local stale = assert(next(scope.tasks))
        scope:close(); stale()
        assert.is_false(job.running); assert.is_true(job.cancelled)
        assert.are.equal(0, #job.pending)
        assert.are.equal(original, read(collection_file))
        assert.is_nil(Shelf.collection(false))
    end)

    it("keeps native collections, rename and removal semantics without deleting ebook files", function()
        local a, b = root .. "/same.epub", root .. "/nested/same.epub"
        Collection:addItem(a, "favorites"); Collection:write()
        run{files={a, b}}
        local name = assert(Shelf.collection(false))
        local renamed = root .. "/renamed.epub"
        assert(os.rename(a, renamed)); Collection:updateItem(a, renamed)
        assert.is_true(Collection:isFileInCollection(renamed, name))
        assert.is_true(Collection:isFileInCollection(renamed, "favorites"))
        Collection:removeItem(renamed, name)
        assert.are.equal("first book", read(renamed))
        assert.is_true(Collection:isFileInCollection(renamed, "favorites"))
    end)

    it("does not report success when native persistence fails", function()
        run{files={root .. "/same.epub"}}
        local name, native_write = Shelf.collection(false), Collection.write
        Collection.write = function() end -- simulates a logged write failure without a thrown exception
        local stats, reason = run{files={root .. "/nested/same.epub"}}
        Collection.write = native_write
        assert.are.equal(0, stats.added); assert.is_string(reason)
        assert.is_nil(Collection.coll[name][root .. "/nested/same.epub"])
    end)
end)
