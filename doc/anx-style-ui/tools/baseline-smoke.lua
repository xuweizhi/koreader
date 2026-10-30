-- Test-only late user patch, installed only in an isolated KO_HOME by run-sdl-smoke.py.
-- Exercises the real SDL application and document engine, not commonrequire's dummy device.
local UIManager = require("ui/uimanager")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local Screen = require("device").screen
local evidence = assert(os.getenv("ANX_SMOKE_EVIDENCE"))
local attempts = 0

local function step(callback)
    UIManager:scheduleIn(0.4, function()
        local ok, err = xpcall(callback, debug.traceback)
        if not ok then
            print("ANX_SMOKE_FAIL", err)
            UIManager:quit(1)
        end
    end)
end

local function inspectReader()
    attempts = attempts + 1
    local reader = ReaderUI.instance
    if not reader or not reader.document or not reader.document.info.number_of_pages then
        assert(attempts < 75, "reader did not become ready")
        step(inspectReader)
        return
    end
    assert(reader.document.info.number_of_pages >= 2, "fixture must contain multiple pages")
    print("ANX_SMOKE_READER", reader.document.file, reader.document.info.number_of_pages)
    Screen:shot(evidence .. "/reader-first.png")
    local target = math.min(3, reader.document.info.number_of_pages)
    if reader.document.info.has_pages then
        reader.paging:onGotoPage(target)
    else
        reader.rolling:onGotoPage(target)
    end
    step(function()
        assert(reader.view.state.page == target, "page navigation did not reach target")
        Screen:shot(evidence .. "/reader-page-3.png")
        reader:saveSettings()
        print("ANX_SMOKE_PAGE", reader.view.state.page, reader.doc_settings:readSetting("last_xpointer"),
            reader.doc_settings:readSetting("last_page"))
        reader:onHome()
        step(function()
            assert(not ReaderUI.instance, "reader instance survived close")
            assert(FileManager.instance, "file manager did not return")
            Screen:shot(evidence .. "/classic-filemanager.png")
            FileManager.instance:onClose()
            print("ANX_SMOKE_PASS")
            UIManager:quit()
        end)
    end)
end

-- Let the original, timed first-run cache update message dismiss itself.
UIManager:scheduleIn(3.5, function() step(inspectReader) end)
