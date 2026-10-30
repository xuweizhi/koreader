local DocumentRegistry = require("document/documentregistry")
local ReadCollection = require("readcollection")
local ReadHistory = require("readhistory")
local lfs = require("libs/libkoreader-lfs")

local Library = {}

-- Snapshots contain values only. Never mutate the authoritative history or
-- collection entries, and never identify a book by title. Existing owners
-- initialize/reload these singletons; this adapter does not flush them.
-- Optional scratch belongs exclusively to the caller and is mutable. Reusing
-- it refreshes every value from the current source; it is not a cached snapshot
-- and must not alias authoritative input or another live page's working data.
function Library.snapshot(ui, source, collection, scratch)
    local input, result, seen = {}, scratch or {}, {}
    local last_read = {}
    for _, entry in ipairs(ReadHistory.hist or {}) do last_read[entry.file] = entry.time end
    if source == "recent" then
        input = ReadHistory.hist
    elseif source == "favorites" or source == "collection" then
        local name = source == "favorites" and ReadCollection.default_collection_name or collection
        for _, entry in pairs(ReadCollection.coll and ReadCollection.coll[name] or {}) do input[#input + 1] = entry end
        table.sort(input, function(a, b)
            if (a.order or 0) ~= (b.order or 0) then return (a.order or 0) < (b.order or 0) end
            return a.file < b.file
        end)
    else
        input = ui.file_chooser and ui.file_chooser.item_table or {}
    end
    local count = 0
    for _, entry in ipairs(input) do
        local file = entry.file or (entry.is_file and entry.path)
        if type(file) == "string" and not seen[file] and DocumentRegistry:hasProvider(file) then
            seen[file] = true
            count = count + 1
            local item = result[count]
            if type(item) ~= "table" or item.file ~= file then
                item = {}
                result[count] = item
            else
                -- Discard metadata and any fields absent from the new source.
                -- A row is never repurposed to represent a different file.
                for key in pairs(item) do item[key] = nil end
            end
            item.id, item.file = file, file
            item.text = entry.text or file:match("([^/]+)$") or file
            item.time, item.order = entry.time or last_read[file], count
            item.bidi_wrap_func, item.missing = entry.bidi_wrap_func, entry.dim == true
        end
    end
    for index = count + 1, #result do result[index] = nil end
    return result
end

function Library.collections()
    local result = {}
    for name in pairs(ReadCollection.coll or {}) do result[#result + 1] = name end
    table.sort(result)
    return result
end

function Library.query(items, query, sort, status, reverse)
    local result = {}
    query = (query or ""):lower()
    for _, item in ipairs(items) do
        local match_status = not status or item.progress and item.progress.status == status
        if match_status and query == "" then
            result[#result + 1] = item
        elseif match_status then
            local searchable = (item.text .. "\n" .. (item.title or "") .. "\n" .. (item.authors or "")):lower()
            if searchable:find(query, 1, true) or item.file:lower():find(query, 1, true) then
                result[#result + 1] = item
            end
        end
    end
    table.sort(result, function(a, b)
        if reverse then a, b = b, a end
        local a_title, b_title = a.title or a.text, b.title or b.text
        if sort == "title" and a_title ~= b_title then return a_title < b_title end
        if sort == "author" and (a.authors or "") ~= (b.authors or "") then return (a.authors or "") < (b.authors or "") end
        if sort == "progress" and (a.progress and a.progress.percent or 0) ~= (b.progress and b.progress.percent or 0) then
            return (a.progress and a.progress.percent or 0) < (b.progress and b.progress.percent or 0)
        end
        if sort == "recent" and (a.time or 0) ~= (b.time or 0) then return (a.time or 0) > (b.time or 0) end
        if sort == "native" and a.order ~= b.order then return a.order < b.order end
        return a.file < b.file
    end)
    return result
end

-- Existing cached metadata only: no document engines, sidecar writes, or
-- recursive disk scanning. Yield between bounded batches so a query or close
-- can interrupt the job; the owner scope closes its SQLite handle.
function Library.enrich(items, scope, on_done)
    local database = require("datastorage"):getSettingsDir() .. "/bookinfo_cache.sqlite3"
    if not lfs.attributes(database) then return end
    local db, stmt
    local function cleanup()
        if stmt then stmt:close(); stmt = nil end
        if db then db:close(); db = nil end
    end
    scope:defer(cleanup)
    local ok = pcall(function()
        db = require("lua-ljsqlite3/init").open(database, "ro")
        db:set_busy_timeout(1)
        stmt = db:prepare([[SELECT title, authors, filesize, filemtime FROM bookinfo
            WHERE directory=? AND filename=? AND in_progress=0 AND ignore_meta IS NULL]])
    end)
    if not ok then cleanup(); return end
    local index, util = 1, require("util")
    local function batch()
        local success = pcall(function()
            for __ = 1, 50 do
                local item = items[index]
                if not item then break end
                local directory, filename = util.splitFilePathName(item.file)
                local row = stmt:bind(directory, filename):step()
                local attr = row and lfs.attributes(item.file)
                if attr and attr.size == tonumber(row[3]) and attr.modification == tonumber(row[4]) then
                    item.title, item.authors = row[1], row[2]
                end
                stmt:clearbind():reset()
                index = index + 1
            end
        end)
        if not success or index > #items then
            cleanup()
            on_done()
        else scope:later(.01, batch) end
    end
    scope:later(.01, batch)
end

function Library.progress(file)
    local info = require("ui/widget/booklist").getBookInfo(file)
    return { opened = info.been_opened, percent = info.percent_finished,
        status = not info.been_opened and "new" or info.status == "complete" and "complete" or "reading" }
end

function Library.enrichProgress(items, scope, on_done)
    local index = 1
    local function batch()
        for __ = 1, 40 do
            local item = items[index]
            if not item then on_done(); return end
            item.progress = Library.progress(item.file)
            index = index + 1
        end
        scope:later(.01, batch)
    end
    scope:later(.01, batch)
end

function Library.page(items, number, size)
    size = math.max(1, math.floor(size or 1))
    local pages = math.max(1, math.ceil(#items / size))
    number = math.max(1, math.min(pages, math.floor(number or 1)))
    local result = {}
    for i = (number - 1) * size + 1, math.min(number * size, #items) do result[#result + 1] = items[i] end
    return result, number, pages
end

-- Called only for visible items or a user action, never from paintTo.
function Library.signature(file)
    local attr = lfs.attributes(file)
    if not attr or attr.mode ~= "file" then return nil, "missing_file" end
    return table.concat({file, attr.dev or "", attr.ino or "", attr.size, attr.modification, attr.change or ""}, "\0"), attr
end

return Library
