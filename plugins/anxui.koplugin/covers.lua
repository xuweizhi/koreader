local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
require("ffi/zstd_h")
local zstd = ffi.loadlib("zstd", "1")

local Covers = {}
Covers.__index = Covers
Covers.single_limit = 2 * 1024 * 1024

function Covers.new(scope, ui, gray)
    local self = setmetatable({ scope = scope, ui = ui, bytes = 0, buffers = {}, owned_pids = {},
        limit = (gray and 8 or 24) * 1024 * 1024,
        database = DataStorage:getSettingsDir() .. "/bookinfo_cache.sqlite3" }, Covers)
    scope:defer(function() self:close() end)
    return self
end

function Covers:manager()
    local disabled = G_reader_settings:readSetting("plugins_disabled", {})
    if type(disabled) == "table" and disabled.coverbrowser then return end
    -- Reuse the already loaded native cache owner. Never load a disabled plugin
    -- or change its schema/settings. The pinned version was audited in W11.
    if self.ui.coverbrowser then return package.loaded.bookinfomanager end
end

-- This reader bounds compressed and decoded data BEFORE allocating a buffer.
-- The native getBookInfo(true) decoder allocates from the zstd frame header;
-- reading the same cache here permits a strict per-page memory ceiling.
function Covers:read(file, require_quality)
    if not self:manager() or not lfs.attributes(self.database) then return nil, "unavailable" end
    local attr = lfs.attributes(file)
    if not attr or attr.mode ~= "file" then return nil, "missing_file" end
    local db, stmt, allocated
    local ok, info = pcall(function()
        db = SQ3.open(self.database, "ro")
        db:set_busy_timeout(1)
        stmt = db:prepare([[SELECT title, authors, cover_fetched, has_cover, ignore_cover,
            cover_w, cover_h, cover_bb_type, cover_bb_stride,
            CASE WHEN length(cover_bb_data) <= 2097152 THEN cover_bb_data END,
            filesize, filemtime, ignore_meta, cover_sizetag FROM bookinfo
            WHERE directory=? AND filename=? AND in_progress=0]])
        local directory, filename = util.splitFilePathName(file)
        local row = stmt:bind(directory, filename):step()
        if not row then return end
        if tonumber(row[11]) ~= attr.size or tonumber(row[12]) ~= attr.modification then return end
        local result = { title = not row[13] and row[1] or nil, authors = not row[13] and row[2] or nil,
            fetched = row[3] ~= nil }
        if not row[4] or row[5] then return result end
        local w, h, kind, stride = tonumber(row[6]), tonumber(row[7]), tonumber(row[8]), tonumber(row[9])
        local bits = kind and Blitbuffer.TYPE_TO_BPP[kind]
        if not w or not h or not stride or not bits or w < 1 or h < 1 or w > 1024 or h > 1536 then
            result.error = "invalid_cover"; return result
        end
        local minimum = math.ceil(w * bits / 8)
        local bytes = stride * h
        local original_w, original_h = (row[14] or ""):match("(%d+)x(%d+)")
        result.needs_refresh = math.max(w, h) < 192 and original_w
            and (tonumber(original_w) > w or tonumber(original_h) > h) or false
        if require_quality and result.needs_refresh then return end
        -- Scaling may convert even a packed grayscale source to four bytes per
        -- pixel. Reserve that worst case in addition to the decoded source.
        local reserved = bytes + w * h * 4
        if stride < minimum or stride > minimum + 64 or bytes > self.single_limit
            or self.bytes + reserved > self.limit then result.error = "cover_limit"; return result end
        local blob = row[10]
        if not blob or tonumber(zstd.ZSTD_getFrameContentSize(blob[1], blob[2])) ~= bytes then
            result.error = "invalid_cover"; return result
        end
        allocated = Blitbuffer.new(w, h, kind, nil, stride, w)
        local decoded = zstd.ZSTD_decompress(allocated.data, bytes, blob[1], blob[2])
        if zstd.ZSTD_isError(decoded) ~= 0 or tonumber(decoded) ~= bytes then
            allocated:free(); allocated = nil
            result.error = "invalid_cover"; return result
        end
        self.buffers[#self.buffers + 1] = allocated
        self.bytes = self.bytes + reserved
        result.cover = allocated
        allocated = nil
        return result
    end)
    if allocated then allocated:free() end
    if stmt then stmt:close() end
    if db then db:close() end
    if ok then return info end
    require("logger").warn("Anx cover cache read failed:", info)
    return nil, "cache_unavailable"
end

function Covers:load(items, callback)
    local missing, index = {}, 0
    local function next_item()
        index = index + 1
        local item = items[index]
        if not item then
            if #missing > 0 then self:extract(missing, callback) end
            return
        end
        local info, reason = self:read(item.file)
        if info then callback(item, info) elseif reason then callback(item, { error = reason }) end
        if (not info and not reason) or (info and (not info.fetched or info.needs_refresh)) then
            missing[#missing + 1] = item
        end
        self.scope:later(0, next_item)
    end
    self.scope:later(0, next_item)
end

function Covers:extract(items, callback)
    local manager = self:manager()
    if not manager then return end
    local attempts = 0
    local function start()
        attempts = attempts + 1
        if not self:manager() or attempts > 30 then return end
        if manager:isExtractingInBackground() then self.scope:later(.5, start); return end
        local files = {}
        for _, item in ipairs(items) do
            files[#files + 1] = { filepath = item.file, cover_specs = { max_cover_w = 384, max_cover_h = 512 } }
        end
        -- At this point the native manager has no active worker. Its own reaper
        -- and standby bookkeeping remain responsible for the created process.
        if not manager:extractInBackground(files) then return end
        for _, pid in ipairs(manager.subprocesses_pids) do self.owned_pids[#self.owned_pids + 1] = pid end
        local polls = 0
        local function poll()
            polls = polls + 1
            if not self:manager() or polls > 30 then self:cancelWorkers(); return end
            local pending = {}
            for _, item in ipairs(items) do
                local info = self:read(item.file, true)
                if info then callback(item, info) else pending[#pending + 1] = item end
            end
            items = pending
            if #items > 0 then self.scope:later(.5, poll) end
        end
        self.scope:later(.5, poll)
    end
    start()
end

function Covers:cancelWorkers()
    -- Never call terminateBackgroundJobs: it would cancel another owner's work.
    local manager = package.loaded.bookinfomanager
    local live = {}
    for _, pid in ipairs(manager and manager.subprocesses_pids or {}) do live[pid] = true end
    for _, pid in ipairs(self.owned_pids) do
        if live[pid] then ffiutil.terminateSubProcess(pid) end
    end
    self.owned_pids = {}
end

function Covers:close()
    if self.closed then return end
    self.closed = true
    self:cancelWorkers()
    for _, buffer in ipairs(self.buffers) do buffer:free() end
    self.buffers, self.bytes = {}, 0
    UIManager:setDirty(nil, "ui")
end

return Covers
