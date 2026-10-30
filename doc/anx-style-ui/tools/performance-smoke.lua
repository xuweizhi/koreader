-- Test-only late patch: real SDL, original engines, isolated generated books.
-- Timed intervals exclude evidence serialization, screenshots and sampling GC.
-- Waits are excluded except book open/return, whose async boundary includes readiness.
-- Product-triggered GC remains inside its measured action.
local PluginLoader = require("pluginloader")
local candidate = assert(os.getenv("ANX_PERF_CANDIDATE"))
assert(not PluginLoader.enabled_plugins, "performance patch must precede native plugin discovery")
local discover = PluginLoader._discover
PluginLoader._discover = function(self)
    local plugins = discover(self)
    for _, entry in ipairs(plugins) do
        if entry.name == "anxui" then
            entry.path = candidate
            entry.main = candidate .. (entry.disabled and "/_meta.lua" or "/main.lua")
            entry.meta = candidate .. "/_meta.lua"
        end
    end
    return plugins
end
local UIManager = require("ui/uimanager")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local Screen = require("device").screen
local Event = require("ui/event")
local JSON = require("json")
local time = require("ui/time")
local ffi = require("ffi")
require("ffi/posix_h")
local action = assert(os.getenv("ANX_PERF_ACTION"))
local mode = assert(os.getenv("ANX_PERF_MODE"))
local evidence = assert(os.getenv("ANX_PERF_EVIDENCE"))
local book = assert(os.getenv("ANX_PERF_BOOK"))
local count = assert(tonumber(os.getenv("ANX_PERF_COUNT")))
local warmup = assert(tonumber(os.getenv("ANX_PERF_WARMUP")))
local iterations = assert(tonumber(os.getenv("ANX_PERF_ITERATIONS")))
local launched = assert(tonumber(os.getenv("ANX_PERF_LAUNCH_MONOTONIC")))
local patch_started = time.monotonic()
local result = { action = action, mode = mode, count = count, warmup = warmup, iterations = iterations,
    pid = tonumber(ffi.C.getpid()), sample_count = 0, memory_count = 0, checks = {}, counts = {}, warmup_counts = {},
    boundary = "action dispatch to forceRePaint completion; product GC included; excludes screenshots, physical display latency and sampling GC",
    book_cycle_boundary = "dispatch to original UI ready and forceRePaint complete; includes asynchronous readiness polling",
    cover_peak_reserved_bytes = 0, cover_limit_bytes = 0, cover_decode_count = 0, passed = false }
local completed, idle_active, idle_anx_dirty, physical_paints = false, false, 0, 0
local old_repaint, old_after_paint, old_set_dirty = UIManager._repaint, Screen.afterPaint, UIManager.setDirty
local old_owners = setmetatable({}, {__mode = "v"})
local old_windows = setmetatable({}, {__mode = "v"})
local closed_windows = 0
local cancel_worker_probe
local sample_log = assert(io.open(evidence .. "/samples.jsonl", "wb"))
local memory_log = assert(io.open(evidence .. "/memory.jsonl", "wb"))
local hot_memory_log, diagnostic_mallinfo2
if os.getenv("ANX_PERF_DIAGNOSTIC_HOT_MEMORY") == "1" and action == "library" and mode == "anx" then
    hot_memory_log = assert(io.open(evidence .. "/hot-memory.jsonl", "wb"))
    result.diagnostic_hot_memory, result.diagnostic_hot_memory_samples = true, 0
    -- Optional glibc allocator counters. A missing symbol or incompatible FFI
    -- declaration leaves these absent; /proc and Lua observations still work.
    local declared = pcall(ffi.cdef, [[
        typedef struct {
            size_t arena, ordblks, smblks, hblks, hblkhd, usmblks,
                   fsmblks, uordblks, fordblks, keepcost;
        } anx_perf_mallinfo2;
        anx_perf_mallinfo2 mallinfo2(void);
    ]])
    if declared then
        local available, fn = pcall(function() return ffi.C.mallinfo2 end)
        if available then diagnostic_mallinfo2 = fn end
    end
end

local function hotMemory(label, iteration)
    if not hot_memory_log then return end
    -- Deliberately no collectgarbage("collect"): observe transient allocation
    -- and allocator retention without changing the hot-open GC schedule.
    local lua_kb = collectgarbage("count")
    local row = {label = label, iteration = iteration, lua_kb = lua_kb,
        elapsed_ms = time.to_ms(time.monotonic() - patch_started), explicit_gc = false}
    local file = io.open("/proc/self/smaps_rollup", "rb")
    row.smaps_rollup_available = file ~= nil
    if file then
        local contents = file:read("*a"); file:close()
        for key, output in pairs({Rss = "rss_bytes", Anonymous = "anonymous_bytes", Private_Dirty = "private_dirty_bytes"}) do
            local value = tonumber(contents:match("\n" .. key .. ":%s+(%d+)%s+kB"))
            if value then row[output] = value * 1024 end
        end
    end
    row.mallinfo2_available = false
    if diagnostic_mallinfo2 then
        local ok, info = pcall(diagnostic_mallinfo2)
        if ok then
            row.mallinfo2_available = true
            row.mallinfo2 = {}
            for _, key in ipairs({"arena", "uordblks", "fordblks", "hblkhd", "keepcost"}) do
                row.mallinfo2[key] = tonumber(info[key])
            end
        end
    end
    hot_memory_log:write(JSON.encode(row), "\n"); hot_memory_log:flush()
    result.diagnostic_hot_memory_samples = result.diagnostic_hot_memory_samples + 1
end

local function emitSample(row)
    row.warmup = row.warmup == true
    local counts = row.warmup and result.warmup_counts or result.counts
    counts[row.kind] = (counts[row.kind] or 0) + 1
    row.iteration = row.iteration or counts[row.kind]
    if not row.warmup and (row.kind == "search" or row.kind == "clear_search" or row.kind == "page"
            or row.kind == "sort" or row.kind == "layout") then
        counts.library_actions = (counts.library_actions or 0) + 1
    end
    sample_log:write(JSON.encode(row), "\n"); sample_log:flush()
    result.sample_count = result.sample_count + 1
end

local function write()
    local file = assert(io.open(evidence .. "/measurements.json", "wb"))
    file:write(JSON.encode(result)); file:close()
end

local function nativeProviderRoots()
    -- Diagnostics only: the native shortcut registry owns these closures.
    -- Report scalar identities without replacing closures, clearing their
    -- upvalues or retaining the plugin/owner objects in measurement output.
    local shortcuts = package.loaded["apps/filemanager/filemanagershortcuts"]
    local props = shortcuts and shortcuts.provider_props or {}
    local records = {}
    for _, provider in ipairs({"cloudstorage", "cloudstorage_upload", "exporter", "movetoarchive"}) do
        for _, method in ipairs({"get", "set"}) do
            local fn = props[provider] and props[provider][method]
            local info = type(fn) == "function" and debug.getinfo(fn, "S") or nil
            local row = {provider = provider, method = method, present = type(fn) == "function",
                self_upvalue_found = false, points_to_initial_filemanager = false,
                source = info and info.source or "", line = info and info.linedefined or 0}
            if type(fn) == "function" then
                local index = 1
                while true do
                    local name, value = debug.getupvalue(fn, index)
                    if not name then break end
                    if name == "self" then
                        row.self_upvalue_found = true
                        row.points_to_initial_filemanager = old_owners[2] ~= nil
                            and type(value) == "table" and value.ui == old_owners[2]
                        break
                    end
                    index = index + 1
                end
            end
            records[#records + 1] = row
        end
    end
    return records
end

local function classifyNativeInitialOwner(roots)
    -- These exact native closures were demonstrated in the classic-only
    -- owner-diag-02 run. This classifies one known baseline retention; it does
    -- not release the object, hide its raw count, or allow another old owner.
    local expected = {
        ["cloudstorage/get"] = {"@plugins/cloudstorage.koplugin/main.lua", 32},
        ["cloudstorage/set"] = {"@plugins/cloudstorage.koplugin/main.lua", 36},
        ["cloudstorage_upload/get"] = {"@plugins/cloudstorage.koplugin/main.lua", 44},
        ["cloudstorage_upload/set"] = {"@plugins/cloudstorage.koplugin/main.lua", 48},
        ["exporter/get"] = {"@plugins/exporter.koplugin/main.lua", 109},
        ["exporter/set"] = {"@plugins/exporter.koplugin/main.lua", 112},
        ["movetoarchive/get"] = {"@plugins/movetoarchive.koplugin/main.lua", 30},
        ["movetoarchive/set"] = {"@plugins/movetoarchive.koplugin/main.lua", 34},
    }
    local matched, seen = 0, {}
    for _, row in ipairs(roots) do
        local key = row.provider .. "/" .. row.method
        local want = expected[key]
        if want and not seen[key] and row.present and row.self_upvalue_found and row.points_to_initial_filemanager
                and row.source == want[1] and row.line == want[2] then
            matched = matched + 1; seen[key] = true
        end
    end
    local initial = old_owners[2]
    local plugin = initial and initial.anxui
    local state = {present = plugin ~= nil, stopped = plugin and plugin.stopped == true or false}
    local inactive = mode == "classic" and not plugin
    if plugin then
        local scope = plugin.scope
        state.scope_closed = type(scope) == "table" and scope.alive == false
        for _, key in ipairs({"tasks", "windows", "closers", "cleanups"}) do
            state[key .. "_empty"] = scope and type(scope[key]) == "table" and next(scope[key]) == nil or false
        end
        state.refs_cleared = true
        for _, key in ipairs({"home", "reader", "reader_panel", "reader_list", "note_actions", "notes_library",
                "note_index", "statistics_view", "settings_view", "assistant_view", "preferences_menu",
                "recovery_dialog", "book_actions", "book_items", "show_pending"}) do
            state[key .. "_cleared"] = plugin[key] == nil
            state.refs_cleared = state.refs_cleared and plugin[key] == nil
        end
        inactive = state.stopped and state.scope_closed and state.tasks_empty and state.windows_empty
            and state.closers_empty and state.cleanups_empty and state.refs_cleared
    end
    local baseline = initial and not initial.document and initial ~= FileManager.instance
        and initial ~= ReaderUI.instance and matched == 8 and #roots == 8 and inactive
    return baseline and 1 or 0, inactive == true, state
end

local function memory(label)
    collectgarbage("collect"); collectgarbage("collect")
    local file = assert(io.open("/proc/self/status", "rb"))
    local status = file:read("*a"); file:close()
    local owners, retained_windows, details = 0, 0, {}
    for key, owner in pairs(old_owners) do
        owners = owners + 1
        details[#details + 1] = {index = key, type = key % 2 == 0 and "FileManager" or "ReaderUI",
            current_filemanager = owner == FileManager.instance, current_reader = owner == ReaderUI.instance,
            document_present = owner.document ~= nil, name = owner.name or "unnamed"}
    end
    table.sort(details, function(a, b) return a.index < b.index end)
    for _ in pairs(old_windows) do retained_windows = retained_windows + 1 end
    local roots = nativeProviderRoots()
    local baseline, inactive, plugin_state = classifyNativeInitialOwner(roots)
    local row = {label = label, rss_bytes = assert(tonumber(status:match("VmRSS:%s+(%d+)"))) * 1024,
        lua_bytes = collectgarbage("count") * 1024, windows = #UIManager._window_stack,
        retained_old_owners = owners, retained_old_owner_details = details, retained_old_windows = retained_windows,
        native_provider_roots = roots, baseline_initial_fm_owners = baseline, unexpected_old_owners = owners - baseline,
        baseline_anx_plugin_inactive = inactive, baseline_anx_plugin_state = plugin_state,
        elapsed_ms = time.to_ms(time.monotonic() - patch_started)}
    memory_log:write(JSON.encode(row), "\n"); memory_log:flush()
    result.memory_count = result.memory_count + 1
    return row
end

local function fail(err)
    if completed then return end
    completed = true; result.error = tostring(err); write()
    print("ANX_PERF_FAIL", err)
    UIManager:quit(1)
end

local function later(delay, callback)
    UIManager:scheduleIn(delay, function()
        if completed then return end
        local ok, err = xpcall(callback, debug.traceback)
        if not ok then fail(err) end
    end)
end

local function waitFor(predicate, callback, limit, start)
    start = start or time.monotonic()
    if predicate() then callback(); return end
    assert(time.to_s(time.monotonic() - start) < (limit or 30), "readiness deadline exceeded")
    later(.01, function() waitFor(predicate, callback, limit, start) end)
end

UIManager._repaint = function(self, ...)
    local owner = ReaderUI.instance or FileManager.instance
    local dirty_main = owner and self._dirty[owner]
    local home = owner and owner.anxui and owner.anxui.home
    local dirty_home = home and self._dirty[home]
    old_repaint(self, ...)
    local now = time.monotonic()
    if dirty_main and not result.first_main_paint_ms then
        result.first_main_paint_ms = (time.to_s(now) - launched) * 1000
        result.patch_to_main_paint_ms = time.to_ms(now - patch_started)
    end
    if dirty_home and not result.first_home_paint_ms then
        result.first_home_paint_ms = (time.to_s(now) - launched) * 1000
    end
end
Screen.afterPaint = function(self, ...)
    physical_paints = physical_paints + 1
    return old_after_paint(self, ...)
end
UIManager.setDirty = function(self, widget, ...)
    if idle_active and type(widget) == "table" and type(widget.name) == "string"
            and widget.name:match("^anxui") then idle_anx_dirty = idle_anx_dirty + 1 end
    return old_set_dirty(self, widget, ...)
end

local function measure(kind, callback, fields)
    local started = time.monotonic()
    callback(); UIManager:forceRePaint()
    local elapsed = time.to_ms(time.monotonic() - started)
    fields = fields or {}
    fields.kind, fields.elapsed_ms = kind, elapsed
    emitSample(fields)
    return elapsed
end

local function finish()
    if completed then return end
    local function expected(kind, number)
        assert((result.counts[kind] or 0) == number, "incomplete samples for " .. kind)
    end
    if action == "startup" then
        assert(result.first_main_paint_ms and result.first_main_paint_ms > 0, "missing original first paint")
        if mode == "anx" then assert(result.first_home_paint_ms and result.first_home_paint_ms > 0) end
    elseif action == "reader" then expected("page_turn", iterations)
    elseif action == "stability" then
        expected("book_open", iterations); expected("book_return", iterations)
        if mode == "anx" then expected("tool_open", iterations); expected("tool_close", iterations) end
    elseif action == "library" and mode == "anx" then
        expected("hot_home", math.min(20, iterations)); expected("library_actions", iterations)
        for _, kind in ipairs({"search", "clear_search", "page", "sort", "layout"}) do
            expected(kind, iterations / 5)
        end
        expected("note_index_cancel", 1); expected("cover_cancel", 1); expected("metadata_cancel", 1)
        assert(result.cover_decode_count > 0 and result.cover_peak_reserved_bytes > 0, "cover decode was not exercised")
        assert(result.checks.cover_worker_cancel and result.checks.metadata_inflight_cancel and result.checks.note_index_cancel)
    end
    result.checks.sample_counts_complete = true
    local final = memory("final")
    if action == "stability" then
        assert(final.unexpected_old_owners == 0 and final.retained_old_windows == 0,
            "unexpected owner/window remained at final idle sample")
    end
    result.passed = true; write(); completed = true
    UIManager._repaint, Screen.afterPaint, UIManager.setDirty = old_repaint, old_after_paint, old_set_dirty
    if ReaderUI.instance then ReaderUI.instance:onClose() end
    if FileManager.instance then FileManager.instance:onClose() end
    sample_log:close(); memory_log:close()
    if hot_memory_log then hot_memory_log:close() end
    print("ANX_PERF_PASS", action, mode, count, result.sample_count)
    UIManager:quit()
end

local function checkScope(scope)
    assert(not scope.alive, "old Anx scope still alive")
    assert(next(scope.tasks) == nil and #scope.windows == 0, "old Anx scope retained tasks/windows")
    assert(next(scope.closers) == nil and #scope.cleanups == 0, "old Anx scope retained closers/cleanups")
    result.checks.scope_cleanup = true
end

local function observeCovers(plugin)
    local Covers = plugin:module("covers")
    if Covers._anx_perf_observed then return end
    Covers._anx_perf_observed = true
    local original_read = Covers.read
    Covers.read = function(self, file, ...)
        local info, reason = original_read(self, file, ...)
        assert(self.bytes <= self.limit, "cover reservation budget exceeded")
        result.cover_peak_reserved_bytes = math.max(result.cover_peak_reserved_bytes, self.bytes)
        result.cover_limit_bytes = self.limit
        if info and info.cover then
            result.cover_decode_count = result.cover_decode_count + 1
            result.checks.cover_decode_observed = true
        end
        return info, reason
    end
    local original_extract = Covers.extract
    Covers.extract = function(self, ...)
        original_extract(self, ...)
        -- Observe the native worker immediately after its real fork. No worker
        -- is synthesized, paused or delayed to manufacture a cancellation.
        if cancel_worker_probe and cancel_worker_probe.covers == self and #self.owned_pids > 0 then
            local probe = cancel_worker_probe
            local ok, err = xpcall(function() probe.started(self) end, debug.traceback)
            if not ok then fail(err) end
        end
    end
end

local function homeReady(home)
    if not home or home.closed then return false end
    local manager = home.covers:manager()
    return not next(home.source_scope.tasks) and not next(home.render_scope.tasks)
        and (not manager or not manager:isExtractingInBackground())
end

local function idle(ui, callback)
    UIManager:forceRePaint()
    local before = physical_paints
    idle_anx_dirty = 0; idle_active = true
    later(5, function()
        idle_active = false
        result.idle = {seconds = 5, actual_paints = physical_paints - before, anx_dirty_calls = idle_anx_dirty}
        assert(idle_anx_dirty == 0, "Anx UI kept refreshing while idle")
        if ui.anxui and ui.anxui.home then
            assert(not next(ui.anxui.home.render_scope.tasks) and not next(ui.anxui.home.source_scope.tasks),
                "Anx library retained work after settling")
        end
        callback()
    end)
end

local function closeAnxView(plugin, key)
    local view = assert(plugin[key], "view did not open: " .. key)
    local scope = view.scope
    view:onClose()
    assert(not plugin[key], "view reference survived close: " .. key)
    assert(not UIManager:isWidgetShown(view), "closed tool remained in native window stack")
    closed_windows = closed_windows + 1; old_windows[closed_windows] = view
    checkScope(scope)
end

local function queuedTasks(scope)
    local tasks = {}
    for task in pairs(scope.tasks) do tasks[#tasks + 1] = task end
    assert(#tasks > 0, "cancellation had no queued continuation")
    return tasks
end

local function rejectLateTasks(tasks)
    for _, task in ipairs(tasks) do
        local _, reason = task()
        assert(reason == "stale_session", "real canceled task did not reject its stale generation")
        result.late_callbacks_rejected = (result.late_callbacks_rejected or 0) + 1
    end
end

local function processState(pid)
    -- Read-only inspection: the original BookInfoManager remains the reaper.
    local file = io.open("/proc/" .. pid .. "/stat", "rb")
    if not file then return end
    local stat = file:read("*a"); file:close()
    return stat:match(".*%)%s+(%S+)")
end

local function cancelLibraryJobs(plugin, callback)
    local function cancelNotes()
        plugin:showNoteLibrary()
        local view, note_index = assert(plugin.notes_library), assert(plugin.note_index)
        view.buttons.rebuild.callback()
        assert(note_index.running and note_index.transaction)
        local job = assert(note_index.job)
        local first = assert(next(job.tasks), "index did not queue its first batch")
        waitFor(function() return not job.tasks[first] end, function()
            assert(note_index.running and note_index.transaction, "index completed before cancellation")
            local stale = queuedTasks(job)
            result.cancel_index_batch_started = true
            measure("note_index_cancel", function() view.buttons.rebuild.callback() end)
            assert(not note_index.running and not note_index.transaction)
            checkScope(job); rejectLateTasks(stale)
            view:onClose(); assert(not note_index.db)
            result.checks.note_index_cancel = true
            plugin:showHome()
            waitFor(function() return homeReady(plugin.home) end, callback)
        end)
    end

    local function cancelCoverWorker()
        local stress_file = assert(os.getenv("ANX_PERF_CANCEL_BOOK"), "missing independent cancellation stress fixture")
        local input = assert(io.open(stress_file, "rb"), "cancellation stress fixture is unreadable")
        local input_bytes = assert(input:seek("end")); input:close()
        assert(input_bytes > 0, "cancellation stress fixture is empty")
        plugin:showHome()
        local home = assert(plugin.home)
        waitFor(function() return homeReady(home) end, function()
            -- This independent real document is fed to the existing adapter after
            -- ordinary library measurements. It is not a visible library entry and
            -- does not change the 100/1000/5000 book counts or latency samples.
            result.cancel_worker_files = {stress_file}
            result.cancel_input = {kind = "standalone_adapter_stress", file = stress_file, bytes = input_bytes,
                ui_visible = false, phase = "after_library_measurements",
                note = "Self-authored complex vector PDF; native MuPDF work, no sleeps or suspended worker."}
            local covers, render_scope, source_scope = home.covers, home.render_scope, home.source_scope
            local manager = assert(covers:manager(), "native cover manager unavailable")
            local started = false
            cancel_worker_probe = {covers = covers, started = function()
                if started then return end
                started = true; cancel_worker_probe = nil
                local pids, live = {}, 0
                for _, pid in ipairs(covers.owned_pids) do
                    pids[#pids + 1] = pid
                    local state = processState(pid)
                    if state and state ~= "Z" and state ~= "X" then live = live + 1 end
                end
                result.cancel_worker_started = #pids > 0
                result.cancel_worker_live_before = live
                result.cancel_worker_pids = pids
                assert(live > 0, "cover worker finished before the cancellation observation")
                local stale = queuedTasks(render_scope)
                measure("cover_cancel", function() plugin:closeHome() end)
                checkScope(home.scope); checkScope(render_scope); checkScope(source_scope)
                assert(covers.bytes == 0 and #covers.owned_pids == 0)
                rejectLateTasks(stale)
                -- A cleared Lua PID list alone is insufficient: observe death and
                -- the original manager's collection, without reaping it ourselves.
                waitFor(function()
                    for _, pid in ipairs(pids) do
                        if processState(pid) then return false end
                        for _, tracked in ipairs(manager.subprocesses_pids) do
                            if tracked == pid then return false end
                        end
                    end
                    return true
                end, function()
                    result.worker_gone_after = true
                    result.checks.cover_worker_cancel = true
                    result.checks.cover_and_metadata_cancel = result.checks.metadata_inflight_cancel
                    cancelNotes()
                end)
            end}
            covers:load({{file = stress_file}}, render_scope:guard(function()
                result.cancel_stress_callback_count = (result.cancel_stress_callback_count or 0) + 1
            end))
            later(20, function() assert(started, "no actual cover extraction worker was exercised") end)
        end)
    end

    local home = assert(plugin.home)
    home.query, home.page, home.selected_file, home.sort = "", 1, nil, "native"
    home:loadItems()
    local source_scope, render_scope = home.source_scope, home.render_scope
    local first = assert(next(source_scope.tasks), "metadata scan was not queued")
    waitFor(function() return not source_scope.tasks[first] end, function()
        -- At least one real metadata batch has executed, and a continuation
        -- remains. The pilot uses >50 books because a batch contains 50.
        local stale = queuedTasks(source_scope)
        result.cancel_metadata_batch_started = true
        measure("metadata_cancel", function() plugin:closeHome() end)
        checkScope(home.scope); checkScope(source_scope); checkScope(render_scope)
        rejectLateTasks(stale)
        result.checks.metadata_inflight_cancel = true
        cancelCoverWorker()
    end)
end

local function libraryRun(fm)
    if mode == "classic" then
        memory("library_settled"); memory("library_interactions_settled"); idle(fm, finish); return
    end
    local plugin = assert(fm.anxui)
    observeCovers(plugin)
    local function open()
        local iteration = (result.counts.hot_home or 0) + 1
        hotMemory("before_hot_home", iteration)
        measure("hot_home", function() plugin:showHome() end)
        hotMemory("after_hot_home", iteration)
        assert(#plugin.home.item_table == count and #plugin.home.cards <= plugin.home.perpage)
    end
    open()
    local first_open = time.monotonic()
    waitFor(function() return homeReady(plugin.home) end, function()
        result.initial_visible_cache_settle_ms = time.to_ms(time.monotonic() - first_open)
        memory("library_settled")
        local index = 0
        local function sample()
            index = index + 1
            local home = assert(plugin.home)
            if index > iterations then
                -- The first EPUBs intentionally have no cover. Exercise a real
                -- PDF/image-book page before requiring any cover allocation;
                -- an empty first-screen cache is a valid product state.
                local covered_file
                for _, item in ipairs(home.item_table) do
                    if item.file:match("%.pdf$") or item.file:match("%.cbz$") then
                        covered_file = item.file; break
                    end
                end
                assert(covered_file, "corpus has no PDF/image-book cover fixture")
                local decoded_before = result.cover_decode_count
                home.query, home.page, home.selected_file, home.sort, home.list_mode = "", 1, covered_file, "native", false
                home:rebuild()
                local visible = false
                for _, card in ipairs(home.cards) do
                    if card.item.file == covered_file then visible = true end
                end
                assert(visible, "cover fixture is not in the actual viewport")
                waitFor(function() return homeReady(plugin.home) end, function()
                    assert(result.cover_decode_count > decoded_before, "PDF/image-book page settled without a decoded cover")
                    result.cover_exercise = {file = covered_file, page = home.page,
                        decoded_before = decoded_before, decoded_after = result.cover_decode_count}
                    memory("library_interactions_settled")
                    idle(fm, function()
                        cancelLibraryJobs(plugin, finish)
                    end)
                end)
                return
            end
            local kind = index % 5
            if kind == 0 then
                measure("search", function()
                    home.query, home.page, home.selected_file = "Mix-000", 1, nil; home:rebuild()
                end)
                assert(#home.filtered == math.min(count, 99), "filename search count mismatch")
            elseif kind == 1 then
                measure("clear_search", function()
                    home.query, home.page, home.selected_file = "", 1, nil; home:rebuild()
                end)
                assert(#home.filtered == count)
            elseif kind == 2 then
                measure("page", function() home:changePage(home.page == home.page_count and -1 or 1) end)
            elseif kind == 3 then
                measure("sort", function()
                    home.sort = home.sort == "title" and "native" or "title"; home:rebuild()
                end)
            else
                measure("layout", function() home.list_mode = not home.list_mode; home:rebuild() end)
            end
            assert(#home.cards <= home.perpage)
            if index % 10 == 0 then memory("library_action_" .. index); write() end
            later(.02, sample)
        end
        -- Additional hot opens have warmed metadata/cover caches and fully closed scopes.
        local opens = 1
        local function hotOpen()
            if opens >= math.min(20, iterations) then sample(); return end
            local old = plugin.home
            plugin:closeHome(); checkScope(old.scope); checkScope(old.render_scope)
            opens = opens + 1; open()
            later(.02, hotOpen)
        end
        later(.02, hotOpen)
    end)
end

local function openReader(fm, callback)
    local started = time.monotonic()
    if mode == "anx" then
        if not fm.anxui.home then fm.anxui:showHome() end
        fm.anxui:openBook(book)
    else fm:openFile(book) end
    -- Do not let this test's readiness callback retain the closed FileManager.
    fm = nil -- luacheck: ignore 311
    waitFor(function()
        local reader = ReaderUI.instance
        return reader and reader.document and reader.document.info.number_of_pages
    end, function()
        UIManager:forceRePaint()
        callback(ReaderUI.instance, time.to_ms(time.monotonic() - started))
    end)
end

local function readerRun(fm)
    openReader(fm, function(reader)
        assert(reader.document.file == book)
        local pages = reader.document.info.number_of_pages
        assert(pages >= 2)
        assert(reader.view.view_mode == "page", "page-turn pair requires identical paged mode")
        reader:handleEvent(Event:new("GotoPage", 1)); UIManager:forceRePaint()
        memory("reader_initial")
        local index, direction = 0, 1
        local function nextPage()
            index = index + 1
            if index > warmup + iterations then
                memory("reader_settled"); idle(reader, finish); return
            end
            local before = reader:getCurrentPage()
            if before >= math.min(pages, 25) then direction = -1
            elseif before <= 1 then direction = 1 end
            local started = time.monotonic()
            -- This is the same native event used by forward/back keys and the
            -- paged touch zones, rather than an absolute-location shortcut.
            reader:handleEvent(Event:new("GotoViewRel", direction)); UIManager:forceRePaint()
            local elapsed = time.to_ms(time.monotonic() - started)
            local page = reader:getCurrentPage()
            assert((page - before) * direction > 0, "native relative page turn did not move in the requested direction")
            emitSample{kind = "page_turn", elapsed_ms = elapsed, warmup = index <= warmup,
                iteration = index <= warmup and index or index - warmup,
                direction = direction, delta = page - before, page = page, document_page = page}
            if index == warmup then memory("reader_warm") end
            later(.02, nextPage)
        end
        later(.02, nextPage)
    end)
end

local function stabilityRun()
    local index, warm_windows = 0, nil
    local cycle
    -- These callbacks are siblings of cycle, not closures created inside a
    -- particular ReaderUI's open/return callback. First let that callback
    -- unwind, then wait for the current FileManager, then sample in a fresh
    -- tick. The next cycle is scheduled only after this sample has completed.
    local function sampleCycleMemory()
        local row = memory(index == warmup and "warm" or "cycle_" .. index)
        if index == warmup then warm_windows = row.windows end
        write(); later(.02, cycle)
    end
    local function settleBeforeMemory()
        local function settled() later(.02, sampleCycleMemory) end
        if mode == "anx" then waitFor(function() return homeReady(FileManager.instance.anxui.home) end, settled)
        else settled() end
    end
    cycle = function()
        local owner = assert(FileManager.instance)
        index = index + 1
        if index > warmup + iterations then
            local function ended()
                -- Run after the final book/open/return callback has unwound.
                -- Otherwise the harness itself may keep the previous owner on
                -- its stack and report a false lifecycle leak.
                later(.02, function()
                    local row = memory("cycles_complete")
                    assert(row.unexpected_old_owners == 0, "unexpected closed owner retained; see retained_old_owner_details")
                    assert(row.retained_old_windows == 0, "closed Anx tool retained after GC")
                    assert(warm_windows and row.windows == warm_windows, "native window stack grew across cycles")
                    result.checks.unexpected_old_owners_released, result.checks.windows_restored = true, true
                    result.checks.baseline_anx_plugin_inactive = row.baseline_anx_plugin_inactive
                    idle(FileManager.instance, finish)
                end)
            end
            if mode == "anx" then waitFor(function() return homeReady(FileManager.instance.anxui.home) end, ended)
            else ended() end
            return
        end
        local old_plugin = owner.anxui
        if old_plugin then observeCovers(old_plugin) end
        openReader(owner, function(reader, elapsed)
            old_owners[index * 2] = owner
            if old_plugin then checkScope(old_plugin.scope) end
            owner, old_plugin = nil, nil
            local fields = {warmup = index <= warmup, iteration = index <= warmup and index or index - warmup}
            emitSample{kind = "book_open", elapsed_ms = elapsed, warmup = fields.warmup, iteration = fields.iteration}
            if mode == "anx" then
                local plugin = reader.anxui
                local actions = {
                    {"reader_panel", function() plugin:showReaderPanel() end, "reader_panel"},
                    {"reader_list", function() plugin:showReaderList("toc") end, "toc"},
                    {"reader_list", function() plugin:showReaderList("notes") end, "notes"},
                    {"statistics_view", function() plugin:showStatistics() end, "statistics"},
                    {"settings_view", function() plugin:showSettings() end, "settings"},
                }
                local item = actions[1 + (index - 1) % #actions]
                local before = #UIManager._window_stack
                measure("tool_open", item[2], {warmup = fields.warmup, iteration = fields.iteration, action = item[3]})
                measure("tool_close", function() closeAnxView(plugin, item[1]) end,
                    {warmup = fields.warmup, iteration = fields.iteration, action = item[3]})
                assert(#UIManager._window_stack == before, "tool close did not restore native windows")
            end
            local old_reader, old_scope = reader, reader.anxui and reader.anxui.scope
            old_owners[index * 2 + 1] = old_reader
            local started = time.monotonic()
            reader:onHome()
            assert(old_reader.document == nil, "old document was not released")
            if old_scope then checkScope(old_scope) end
            reader, old_reader, old_scope = nil, nil, nil -- luacheck: ignore 311
            waitFor(function()
                local returned = FileManager.instance
                return returned and not ReaderUI.instance and (mode == "classic" or returned.anxui.home)
            end, function()
                UIManager:forceRePaint()
                emitSample{kind = "book_return", elapsed_ms = time.to_ms(time.monotonic() - started),
                    warmup = fields.warmup, iteration = fields.iteration}
                if index == warmup or index % 10 == 0 then
                    later(.02, settleBeforeMemory)
                else
                    later(.02, cycle)
                end
            end)
        end)
    end
    cycle()
end

later(3.6, function()
    local fm = assert(FileManager.instance, "initial file manager unavailable")
    if mode == "classic" then assert(not fm.anxui) else assert(fm.anxui) end
    UIManager:forceRePaint()
    memory("initial")
    if action == "startup" then
        if mode == "anx" then assert(fm.anxui.home and result.first_home_paint_ms) end
        finish()
    elseif action == "library" then libraryRun(fm)
    elseif action == "reader" then readerRun(fm)
    elseif action == "stability" then
        fm = nil -- luacheck: ignore 311
        stabilityRun()
    else error("unknown performance action") end
end)
