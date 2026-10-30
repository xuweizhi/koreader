-- Test-only observation. Measure a completed main-window paint, not a timer
-- firing or an empty SDL window. No production file is patched.
local UIManager = require("ui/uimanager")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local time = require("ui/time")
local JSON = require("json")
local original = UIManager._repaint
local patch_started = time.monotonic()
local launch_started = assert(tonumber(os.getenv("ANX_SMOKE_LAUNCH_MONOTONIC")))

UIManager._repaint = function(self, ...)
    local main = ReaderUI.instance or FileManager.instance
    local painting_main = main and self._dirty[main]
    original(self, ...)
    if painting_main then
        UIManager._repaint = original
        local now = time.monotonic()
        local result = {
            boundary = "launcher invocation to first completed main-window repaint (includes Xvfb/kodev startup)",
            launch_to_main_paint_ms = (time.to_s(now) - launch_started) * 1000,
            late_patch_to_main_paint_ms = time.to_ms(now - patch_started),
            main_window = ReaderUI.instance and "reader" or "filemanager",
            environment = "Linux SDL software renderer / Xvfb; fresh isolated configuration",
            limitation = "initial cache update message may overlay main window; not physical display latency",
        }
        local output = assert(io.open(os.getenv("ANX_SMOKE_EVIDENCE") .. "/startup.json", "w"))
        output:write(JSON.encode(result))
        output:close()
        print("ANX_SMOKE_FIRST_MAIN_PAINT_MS", result.launch_to_main_paint_ms)
    end
end
