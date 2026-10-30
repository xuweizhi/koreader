local DocSettings = require("docsettings")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")

-- Disposable search cache, never a second annotation writer. SQLite queries
-- return only the visible page. A canceled rebuild rolls back atomically.
local Index = {}
Index.__index = Index

function Index.new(scope, new_scope, library, path)
    local self = setmetatable({ scope = scope, new_scope = new_scope, library = library }, Index)
    path = path or require("datastorage"):getSettingsDir() .. "/anxui-notes.sqlite3"
    self.db = require("lua-ljsqlite3/init").open(path)
    self.db:set_busy_timeout(5)
    scope:defer(function() self:close() end)
    local version = tonumber(self.db:rowexec("PRAGMA user_version"))
    if version ~= 0 and version ~= 1 then error("unsupported note cache schema") end
    self.db:exec([[CREATE TABLE IF NOT EXISTS notes (
        file TEXT NOT NULL, ordinal INTEGER NOT NULL, title TEXT NOT NULL,
        text TEXT NOT NULL, note TEXT NOT NULL, kind TEXT NOT NULL,
        page_label TEXT NOT NULL, datetime TEXT NOT NULL, anchor TEXT NOT NULL,
        signature TEXT NOT NULL, PRIMARY KEY(file, ordinal));
        CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT);
        PRAGMA user_version=1;]])
    return self
end

function Index.sources(ui, library)
    local seen, result = {}, {}
    local function add(file)
        if type(file) == "string" and not seen[file] then
            seen[file] = true; result[#result + 1] = file
        end
    end
    if ui.document then add(ui.document.file) end
    for _, item in ipairs(library.snapshot(ui, "directory")) do add(item.file) end
    for _, item in ipairs(require("readhistory").hist or {}) do add(item.file) end
    for _, collection in pairs(require("readcollection").coll or {}) do
        for _, item in pairs(collection) do add(item.file) end
    end
    table.sort(result)
    return result
end

function Index:readBook(file, active)
    if active and active:active() and active.document.file == file then
        return active.ui.annotation.annotations, active:snapshot().title, "active"
    end
    local sidecar = DocSettings:findSidecarFile(file)
    if not sidecar then return {}, file:match("([^/]+)$"), "empty" end
    if (lfs.attributes(sidecar, "size") or 0) > 2 * 1024 * 1024 then return nil, nil, "oversized" end
    -- DocSettings:open removes malformed candidates. The light reader does not
    -- delete, migrate or flush anything; legacy conversions remain native.
    local ok, settings = pcall(DocSettings.openSettingsFile, sidecar)
    if not ok or next(settings.data) == nil then return nil, nil, "invalid" end
    local annotations = settings:readSetting("annotations")
    if annotations == nil and (settings:has("bookmarks") or settings:has("highlight")) then
        return nil, nil, "legacy"
    end
    if annotations ~= nil and type(annotations) ~= "table" then return nil, nil, "invalid" end
    local props = settings:readSetting("doc_props", {})
    local title = type(props) == "table" and props.title
    return annotations or {}, type(title) == "string" and title ~= "" and title or file:match("([^/]+)$"), "saved"
end

function Index:cancel()
    if self.job then self.job:close(); self.job = nil end
    if self.insert then self.insert:close(); self.insert = nil end
    if self.transaction then self.db:exec("ROLLBACK"); self.transaction = false end
    self.running = false
end

function Index:rebuild(files, active, on_progress, on_done)
    self:cancel()
    self.running, self.transaction = true, true
    self.db:exec("BEGIN; DELETE FROM notes;")
    self.job = self.new_scope()
    self.insert = self.db:prepare("INSERT INTO notes VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    local cursor, annotations, annotation_index, title, signature = 1, nil, 1, nil, nil
    local stats = {books = #files, scanned = 0, notes = 0, skipped = 0}
    local function batch()
        local ok, err = xpcall(function()
            local file = files[cursor]
            if not file then
                self.insert:close(); self.insert = nil
                local stmt = self.db:prepare("INSERT OR REPLACE INTO metadata VALUES ('last_scan', ?)")
                stmt:bind(JSON.encode(stats)):step(); stmt:close()
                self.db:exec("COMMIT"); self.transaction = false
                self.running = false; self.job:close(); self.job = nil
                on_done(stats)
                return
            end
            if not annotations then
                signature = self.library.signature(file)
                if signature then annotations, title = self:readBook(file, active) end
                if not annotations then
                    stats.skipped = stats.skipped + 1; annotations = {}
                end
                annotation_index = 1
            end
            for __ = 1, 50 do
                local item = annotations[annotation_index]
                if not item then break end
                if type(item) == "table" and (type(item.page) == "string" or type(item.page) == "number") then
                    local anchor = {page = item.page, pos0 = item.pos0, pos1 = item.pos1,
                        datetime = item.datetime, drawer = item.drawer}
                    self.insert:bind(file, annotation_index, title or file:match("([^/]+)$"),
                        type(item.text) == "string" and item.text or "", type(item.note) == "string" and item.note or "",
                        item.drawer and "highlights" or "bookmarks", tostring(item.pageref or item.pageno or ""),
                        item.datetime or "", JSON.encode(anchor), signature):step()
                    self.insert:reset():clearbind()
                    stats.notes = stats.notes + 1
                else stats.skipped = stats.skipped + 1 end
                annotation_index = annotation_index + 1
            end
            if annotation_index > #annotations then
                annotations = nil; cursor = cursor + 1; stats.scanned = stats.scanned + 1
                on_progress(stats)
            end
            self.job:later(.01, batch)
        end, debug.traceback)
        if not ok then
            self:cancel()
            require("logger").warn("Anx note index rebuild failed:", err)
            on_done(nil, "The note index could not be rebuilt.")
        end
    end
    self.job:later(0, batch)
end

function Index:page(query, filter, page, perpage)
    local where = [[ WHERE (? = 'all' OR kind = ? OR ? = 'notes' AND note <> '')
        AND instr(lower(title || char(10) || text || char(10) || note), lower(?)) > 0]]
    local function prepare(sql)
        return self.db:prepare(sql):bind(filter, filter, filter, query)
    end
    local count_stmt = prepare("SELECT count(*) FROM notes" .. where)
    local total = tonumber(count_stmt:step()[1]); count_stmt:close()
    local pages = math.max(1, math.ceil(total / perpage))
    page = math.max(1, math.min(page, pages))
    local stmt = prepare("SELECT file, title, text, note, kind, page_label, datetime, anchor, signature FROM notes" .. where
        .. " ORDER BY title, file, ordinal LIMIT " .. math.floor(perpage) .. " OFFSET " .. (page - 1) * math.floor(perpage))
    local result = {}
    while true do
        local row = stmt:step()
        if not row then break end
        result[#result + 1] = {file = row[1], book_title = row[2], text = row[3], note = row[4], kind = row[5],
            has_note = row[4] ~= "", page_label = row[6], datetime = row[7], anchor = JSON.decode(row[8]),
            signature = row[9], subtitle = row[2] .. (row[6] ~= "" and " · " .. row[6] or "")}
    end
    stmt:close()
    return result, page, pages, total
end

function Index:clear()
    self:cancel(); self.db:exec("DELETE FROM notes; DELETE FROM metadata;")
end

function Index:close()
    if not self.db then return end
    self:cancel(); self.db:close(); self.db = nil
end

return Index
