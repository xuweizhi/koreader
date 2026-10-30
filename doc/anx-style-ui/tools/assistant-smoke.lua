return function(context)
    local fm, shot, step = context.fm, context.shot, context.step
    local UIManager = require("ui/uimanager")
    local plugin = fm.anxui
    local installed = os.getenv("ANX_SMOKE_ASSISTANT_CASE") == "installed"
    plugin:showAssistant()
    local status = plugin.assistant_view.snapshot
    shot(installed and "assistant-unconfigured" or "assistant-absent")
    if not installed then
        assert(status.state == "unavailable")
        plugin.assistant_view.on_select(plugin.assistant_view.entries[1])
        assert(not fm.koassistant)
        context.finish(); return
    end
    assert(fm.koassistant, "real pinned plugin was not loaded")
    assert(status.state == "available", status.reason)
    assert(not status.configured, "test must not have provider credentials")
    local function closePopups(ui)
        local koa = ui.koassistant
        if koa.current_input_dialog then koa.current_input_dialog:onCloseDialog() end
        if ui.menu.menu_container then ui.menu.menu_container[1]:closeMenu() end
        for index = #UIManager._window_stack, 1, -1 do
            local widget = UIManager._window_stack[index].widget
            if widget ~= ui and widget ~= ui.anxui.home then UIManager:close(widget) end
        end
    end
    plugin.assistant_view.on_select(plugin.assistant_view.entries[1])
    step(function()
        assert(fm.koassistant.current_input_dialog, "original general composer did not open")
        shot("original-general-composer")
        closePopups(fm)
        assert(not fm.koassistant.current_input_dialog)
        plugin:showAssistant()
        plugin.assistant_view.on_select(plugin.assistant_view.entries[3])
        assert(fm.menu.menu_container, "original assistant settings missing")
        shot("original-assistant-settings")
        closePopups(fm)
        -- Tamper only the isolated copy, then restore it; the audited vendor is unchanged.
        local path = fm.koassistant.path .. "/_meta.lua"
        local file = assert(io.open(path, "rb")); local bytes = file:read("*a"); file:close()
        file = assert(io.open(path, "ab")); file:write("\n-- isolated version mismatch\n"); file:close()
        plugin:showAssistant()
        assert(plugin.assistant_view.snapshot.state == "version_mismatch")
        shot("assistant-version-mismatch")
        assert(not plugin:assistantSession():open("general"))
        plugin.assistant_view:onClose()
        file = assert(io.open(path, "wb")); file:write(bytes); file:close()
        assert(plugin:assistantSession():status().state == "available")
        -- Exercise original manager toggle; this instance can remain cached.
        for _, group in ipairs(require("pluginloader"):genPluginManagerSubItem()) do
            for _, entry in ipairs(group.sub_item_table or {}) do
                if entry.text == fm.koassistant.fullname then
                    entry.callback()
                    assert(plugin:assistantSession():status().state == "disabled")
                    assert(not plugin:assistantSession():open("general"))
                    closePopups(fm)
                    entry.callback()
                end
            end
        end
        closePopups(fm)
        context.selectBook(fm, function(reader)
            local owner = reader.anxui
            owner:showReaderPanel()
            owner.reader_panel.buttons.assistant.callback()
            assert(owner.assistant_view.snapshot.book)
            owner.assistant_view.on_select(owner.assistant_view.entries[2])
            step(function()
                assert(reader.koassistant.current_input_dialog, "original book composer missing")
                assert(reader.koassistant.configuration.features.book_metadata.file == context.book)
                shot("original-book-composer")
                closePopups(reader)
                -- Enter through KOAssistant's original highlighted-text button.
                local Screen, Geom = require("device").screen, require("ui/geometry")
                local position
                for y = 60, Screen:getHeight() - 80, 16 do
                    for x = 40, Screen:getWidth() - 40, 24 do
                        local point = Geom:new{x = x, y = y, w = 0, h = 0}
                        local page_point = reader.view:screenToPageTransform(point)
                        if page_point then
                            local ok, word = pcall(reader.document.getWordFromPosition, reader.document, page_point)
                            if ok and word and word.word and word.word ~= "" then position = point; break end
                        end
                    end
                    if position then break end
                end
                assert(position)
                reader.highlight:onHold(nil, {pos = position})
                local selected = assert(reader.highlight.selected_text)
                local text, pos0, pos1 = selected.text, selected.pos0, selected.pos1
                local entry = assert(reader.highlight._highlight_buttons.koassistant_dialog)(reader.highlight)
                entry.callback()
                assert(reader.koassistant.current_input_dialog)
                local captured = reader.koassistant.configuration.features.selection_data
                assert(captured.text == text and captured.pos0 == pos0 and captured.pos1 == pos1)
                shot("original-selected-text-composer")
                closePopups(reader)
                assert(owner:assistantSession():open("book"))
                local original = reader.koassistant
                local stale = owner.scope:guard(function() return owner:assistantSession():open("book") end)
                local before_resize = assert(original.current_input_dialog)
                before_resize:onScreenResize(Screen:getSize())
                local resized = assert(original.current_input_dialog)
                assert(resized ~= before_resize and not UIManager:isWidgetShown(before_resize))
                shot("composer-refreshed-on-resize")
                step(function()
                    assert(owner:assistantSession().composer == resized, "replacement was not adopted")
                    -- A second refresh followed by immediate close exercises the
                    -- handoff gap before the scheduled adoption can run.
                    resized:onScreenResize(Screen:getSize())
                    local replacement = assert(original.current_input_dialog)
                    assert(replacement ~= resized and not UIManager:isWidgetShown(resized))
                    reader:onHome()
                    assert(not UIManager:isWidgetShown(replacement), "refreshed composer survived owner close")
                    step(function()
                        assert(not original.current_input_dialog, "composer survived book close")
                        assert(not owner:assistantSession():active())
                        assert(not owner:assistantSession().composer and not owner:assistantSession().refresh_plugin)
                        assert(not stale())
                        shot("assistant-cancelled-on-return")
                        local next_owner = assert(require("apps/filemanager/filemanager").instance).anxui
                        assert(next_owner:assistantSession():open("general"))
                        local next_plugin = next_owner.ui.koassistant
                        next_plugin.current_input_dialog:onScreenResize(Screen:getSize())
                        local next_composer = assert(next_plugin.current_input_dialog)
                        step(function()
                            assert(next_owner:assistantSession().composer == next_composer)
                            next_owner:stopPlugin()
                            assert(not next_plugin.current_input_dialog and not UIManager:isWidgetShown(next_composer),
                                "refreshed composer survived live plugin disable")
                            shot("assistant-refreshed-cancelled-on-disable")
                            context.finish()
                        end)
                    end)
                end)
            end)
        end)
    end)
end
