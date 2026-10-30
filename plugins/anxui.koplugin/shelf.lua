local Collection = require("readcollection")
local DataStorage = require("datastorage")
local DocumentRegistry = require("document/documentregistry")
local LuaSettings = require("luasettings")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local Shelf = {}
-- Keep membership in native collections so native rename/move/delete updates
-- it too. Never copy books, sidecars, progress or annotations into a second DB.
function Shelf.collection(create)
    if not Collection.coll then Collection:_read() end
    for name, settings in pairs(Collection.coll_settings or {}) do
        if settings.anxui_library and Collection.coll[name] then return name end
    end
    if not create then return end
    local name, suffix = "Anx library", 1
    while Collection.coll[name] do
        suffix = suffix + 1
        name = "Anx library (" .. suffix .. ")"
    end
    Collection:addCollection(name)
    Collection.coll_settings[name].anxui_library = true
    return name
end

-- Standalone cover images are not ebooks. Auxiliary executors are excluded by
-- hasProvider's default; all other native reading formats remain available.
local images = {jpg=true, jpeg=true, png=true, gif=true, bmp=true, webp=true, svg=true, tif=true, tiff=true}
function Shelf.supported(file)
    local ext = type(file) == "string" and file:match("%.([^./]+)$")
    return ext ~= nil and not images[ext:lower()] and DocumentRegistry:hasProvider(file) or false
end

function Shelf.roots()
    local name = Shelf.collection(false)
    local result = {}
    for _, root in ipairs(name and Collection.coll_settings[name].anxui_scan_roots or {}) do
        if type(root) == "string" then result[#result + 1] = root end
    end
    return result
end

-- Scan and validate in bounded batches. Until commit, candidates belong only
-- to this job; cancel/owner close discards them without altering collections.
function Shelf.start(scope, options)
    local job = {running=true, stats={checked=0, found=0, added=0, duplicates=0, skipped=0, errors=0},
        pending={}, seen={}, directories={}, roots={}, scope=scope}
    local current, iterator, dir_handle
    local files, file_index = options.files or {}, 1
    local source_name = Shelf.collection(false)
    local existing = source_name and Collection.coll[source_name] or {}
    local function closeDir()
        if dir_handle then pcall(dir_handle.close, dir_handle) end
        iterator, dir_handle, current = nil, nil, nil
    end
    function job:cancel()
        if not self.running then return end
        self.running, self.cancelled = false, true
        closeDir()
        self.pending, self.directories = {}, {}
    end
    scope:defer(function() job:cancel() end)
    local function done(reason)
        job.running = false
        closeDir()
        job.pending, job.directories = {}, {}
        if scope.alive and options.on_done then options.on_done(job.stats, reason) end
    end
    local function candidate(path)
        job.stats.checked = job.stats.checked + 1
        if not Shelf.supported(path) then job.stats.skipped = job.stats.skipped + 1; return end
        local real = ffiUtil.realpath(path)
        local attr = real and lfs.attributes(real)
        if not attr or attr.mode ~= "file" then job.stats.errors = job.stats.errors + 1; return end
        job.stats.found = job.stats.found + 1
        if job.seen[real] or existing[real] then
            job.stats.duplicates = job.stats.duplicates + 1
        else
            job.seen[real] = true
            job.pending[#job.pending + 1] = {file=real, text=real:match("([^/]+)$"), attr=attr}
        end
    end
    for _, path in ipairs(options.roots or {}) do
        local real = ffiUtil.realpath(path)
        if real and lfs.attributes(real, "mode") == "directory" then
            if not job.roots[real] then
                job.roots[real] = true
                job.directories[#job.directories + 1] = {path=real, depth=0}
            end
        else job.stats.errors = job.stats.errors + 1 end
    end
    local visited, directory_index = {}, 1
    local function commit()
        if #job.pending == 0 and not next(job.roots) then return done() end
        local previous_name = Shelf.collection(false)
        local name = Shelf.collection(true)
        local coll, settings = Collection.coll[name], Collection.coll_settings[name]
        local order, added = Collection:getCollectionNextOrder(name), {}
        local old_roots = settings.anxui_scan_roots
        for _, item in ipairs(job.pending) do
            if not coll[item.file] then
                item.order = order
                if order then order = order + 1 end
                coll[item.file] = item
                added[#added + 1] = item.file
            else job.stats.duplicates = job.stats.duplicates + 1 end
        end
        local roots, known = {}, {}
        for _, root in ipairs(old_roots or {}) do roots[#roots + 1], known[root] = root, true end
        for root in pairs(job.roots) do if not known[root] then roots[#roots + 1] = root end end
        table.sort(roots)
        settings.anxui_scan_roots = roots
        local ok = pcall(function()
            Collection:write({[name]=true})
            -- Native flush logs I/O failures instead of propagating a result.
            -- Read back membership before telling the user that import succeeded.
            local saved = LuaSettings:open(DataStorage:getSettingsDir() .. "/collection.lua"):readSetting(name)
            assert(type(saved) == "table", "collection write failed")
            local saved_files = {}
            for _, item in ipairs(saved) do saved_files[item.file] = true end
            for _, file in ipairs(added) do assert(saved_files[file], "collection write incomplete") end
            assert(saved.settings and saved.settings.anxui_library, "collection settings write failed")
            local saved_roots = saved.settings.anxui_scan_roots or {}
            assert(#saved_roots == #roots, "scan roots write failed")
            for index, root in ipairs(roots) do assert(saved_roots[index] == root, "scan roots write incomplete") end
        end)
        if not ok then
            for _, file in ipairs(added) do coll[file] = nil end
            settings.anxui_scan_roots = old_roots
            if not previous_name then Collection:removeCollection(name) end
            return done("The library could not be saved. Check free space and folder permissions.")
        end
        job.stats.added = #added
        done()
    end
    local function batch()
        if not job.running then return end
        for __ = 1, 60 do
            if file_index <= #files then
                candidate(files[file_index]); file_index = file_index + 1
            elseif iterator then
                local ok, entry = pcall(iterator, dir_handle)
                if not ok or not entry then
                    if not ok then job.stats.errors = job.stats.errors + 1 end
                    closeDir()
                elseif entry ~= "." and entry ~= ".." then
                    job.stats.checked = job.stats.checked + 1
                    local path = current.path .. "/" .. entry
                    local mode = lfs.symlinkattributes(path, "mode")
                    if entry:sub(1, 1) == "." or entry:lower():match("%.sdr$") then
                        job.stats.skipped = job.stats.skipped + 1
                    elseif mode == "directory" and options.recursive ~= false then
                        if current.depth < 32 then
                            job.directories[#job.directories + 1] = {path=path, depth=current.depth + 1}
                        else job.stats.skipped = job.stats.skipped + 1 end
                    elseif mode == "file" then
                        job.stats.checked = job.stats.checked - 1
                        candidate(path)
                    elseif mode == nil then job.stats.errors = job.stats.errors + 1
                    else job.stats.skipped = job.stats.skipped + 1 end
                end
            else
                current = job.directories[directory_index]
                job.directories[directory_index], directory_index = false, directory_index + 1
                if not current then return commit() end
                if not visited[current.path] then
                    visited[current.path] = true
                    local ok, next_entry, handle = pcall(lfs.dir, current.path)
                    if ok then iterator, dir_handle = next_entry, handle
                    else job.stats.errors = job.stats.errors + 1; current = nil end
                end
            end
        end
        if options.on_progress then options.on_progress(job.stats) end
        scope:later(.01, batch)
    end
    scope:later(.01, batch)
    return job
end

return Shelf
