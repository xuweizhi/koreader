describe("Anx disposable note index", function()
    local Index, Scope, Library, UIManager, DocSettings, directory, database, scope, index
    local file_a, file_b, original_a, original_b
    local function write(path, text)
        local file = assert(io.open(path, "w")); file:write(text); file:close()
    end
    local function read(path)
        local file = assert(io.open(path, "r")); local text = file:read("*a"); file:close(); return text
    end
    local function runRebuild(files, active)
        local result, failure
        index:rebuild(files, active, function() end, function(stats, err) result, failure = stats, err end)
        for _ = 1, 100 do
            if not index.running then break end
            local task = next(index.job.tasks)
            assert.is_function(task)
            UIManager:unschedule(task); task()
        end
        assert.is_nil(failure); assert.is_false(index.running); return result
    end
    setup(function()
        require("commonrequire")
        Index = dofile("plugins/anxui.koplugin/noteindex.lua")
        Scope = dofile("plugins/anxui.koplugin/lifecycle.lua")
        Library = dofile("plugins/anxui.koplugin/library.lua")
        UIManager, DocSettings = require("ui/uimanager"), require("docsettings")
        directory = require("datastorage"):getDataDir() .. "/anx-notes-unit"
        require("util").makePath(directory)
        file_a, file_b = directory .. "/same.epub", directory .. "/other.epub"
        database = directory .. "/index.sqlite3"
        write(file_a, "A"); write(file_b, "B")
        for _, path in ipairs({file_a, file_b}) do require("util").makePath(DocSettings:getSidecarDir(path, "doc")) end
        original_a = DocSettings:getSidecarDir(file_a, "doc") .. "/metadata.epub.lua"
        original_b = DocSettings:getSidecarDir(file_b, "doc") .. "/metadata.epub.lua"
    end)
    before_each(function()
        os.remove(database)
        scope = Scope.new(); index = Index.new(scope, Scope.new, Library, database)
        write(original_a, 'return {doc_props={title="Same title"}, annotations={{page="xp/a",text="Quote A",note="Note A",datetime="now"}}}')
        write(original_b, 'return {doc_props={title="Same title"}, annotations={{page="xp/b",text="Quote B",drawer="lighten",datetime="now"}}}')
    end)
    after_each(function() scope:close(); UIManager:quit() end)

    it("keeps duplicate titles separate and only reads the visible page", function()
        local before_a, before_b = read(original_a), read(original_b)
        local result = runRebuild({file_a, file_b})
        assert.are.equal(2, result.notes)
        local first, page, pages, total = index:page("Same title", "all", 1, 1)
        local second = index:page("Same title", "all", 2, 1)
        assert.are.equal(1, page); assert.are.equal(2, pages); assert.are.equal(2, total)
        assert.are_not.equal(first[1].file, second[1].file)
        assert.are.equal(Library.signature(first[1].file), first[1].signature)
        assert.are.equal(before_a, read(original_a)); assert.are.equal(before_b, read(original_b))
        local filtered = index:page("Note A", "notes", 1, 10)
        assert.are.equal(1, #filtered); assert.are.equal("xp/a", filtered[1].anchor.page)
    end)

    it("uses active unsaved annotations and never flushes them to the sidecar", function()
        local before = read(original_a)
        local active = {active = function() return true end, document = {file = file_a},
            ui = {annotation = {annotations = {{page = "xp/new", note = "Unsaved current note"}}}},
            snapshot = function() return {title = "Active title"} end}
        runRebuild({file_a, file_b}, active)
        local rows = index:page("Unsaved", "notes", 1, 10)
        assert.are.equal(1, #rows); assert.are.equal("xp/new", rows[1].anchor.page)
        assert.are.equal(before, read(original_a))
    end)

    it("rolls back a canceled rebuild and rejects an already dispatched task", function()
        runRebuild({file_a, file_b})
        index:rebuild({file_a}, nil, function() end, function() error("canceled job finished") end)
        local task = next(index.job.tasks)
        UIManager:unschedule(task); task() -- insert first book inside transaction
        local stale = next(index.job.tasks)
        index:cancel(); stale()
        local _, _, _, total = index:page("", "all", 1, 10)
        assert.are.equal(2, total)
        assert.is_nil(index.job); assert.is_nil(index.insert)
    end)

    it("leaves malformed and legacy sidecars intact and can reconstruct a deleted cache", function()
        write(original_a, 'return "malformed"')
        write(original_b, 'return {bookmarks={{page="xp/legacy"}}}')
        local result = runRebuild({file_a, file_b})
        assert.are.equal(2, result.skipped); assert.are.equal(0, result.notes)
        assert.are.equal('return "malformed"', read(original_a))
        scope:close(); os.remove(database)
        scope = Scope.new(); index = Index.new(scope, Scope.new, Library, database)
        write(original_a, 'return {annotations={{page="xp/restored",note="restored"}}}')
        runRebuild({file_a})
        local rows = index:page("restored", "all", 1, 10)
        assert.are.equal("xp/restored", rows[1].anchor.page)
        index:clear()
        local _, _, _, total = index:page("", "all", 1, 10)
        assert.are.equal(0, total); assert.is_truthy(read(original_a):find("restored"))
    end)
end)
