return function(context)
    local UIManager, Event = require("ui/uimanager"), require("ui/event")
    local reader, step, shot, finish = context.reader, context.step, context.shot, context.finish
    local function closeOverlays()
        for index = #UIManager._window_stack, 1, -1 do
            local widget = UIManager._window_stack[index].widget
            if widget ~= reader then UIManager:close(widget) end
        end
    end
    local function dictionary()
        reader.dictionary:onLookupWord("needle")
        step(function()
            local window = assert(reader.dictionary.dict_window)
            assert(window.results and window.results[1])
            assert(window.results[1].definition:find("self%-authored test definition"))
            shot("original-offline-dictionary")
            closeOverlays()
            assert(not reader.anxui.reader_panel and not reader.anxui.reader_list)
            finish()
        end)
    end
    local function searchDone(tries)
        if not reader.search.findall_results then
            assert((tries or 0) < 30, "native search did not return results")
            step(function() searchDone((tries or 0) + 1) end)
            return
        end
        assert(#reader.search.findall_results > 0)
        shot("original-fulltext-results")
        closeOverlays(); dictionary()
    end
    reader:handleEvent(Event:new("GotoPage", 1))
    reader.anxui:showReaderPanel(); reader.anxui.reader_panel:onClose()
    local links = reader.document:getPageLinks(true)
    local target
    for _, link in ipairs(links or {}) do if link.section then target = link.section; break end end
    assert(target, "fixture must have an internal footnote link on the first page")
    reader.link:onGotoLink({xpointer = target, marker_xpointer = target})
    step(function()
        assert(reader:getCurrentPage() > 1)
        shot("original-footnote-target")
        reader.anxui:showReaderPanel(); reader.anxui.reader_panel.buttons.back.callback()
        step(function()
            assert(reader:getCurrentPage() == 1, "native footnote return position was lost")
            shot("footnote-return-through-toolbar")
            reader.anxui:showReaderPanel(); reader.anxui.reader_panel.buttons.search.callback()
            reader.search.input_dialog:setInputText("needle")
            reader.search:searchCallback()
            step(searchDone)
        end)
    end)
end
