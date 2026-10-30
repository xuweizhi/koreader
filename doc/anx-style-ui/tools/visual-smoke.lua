-- Real SDL geometry and navigation checks, isolated by run-sdl-smoke.py.
return function(context)
    local UIManager, Screen = require("ui/uimanager"), require("device").screen
    local fm, step, shot = context.fm, context.step, context.shot
    local plugin = assert(fm.anxui)
    local evidence = assert(os.getenv("ANX_SMOKE_EVIDENCE"))
    local observations = {screens = {}, idle = nil}
    local function save()
        local file = assert(io.open(evidence .. "/visual-geometry.json", "wb"))
        file:write(require("json").encode(observations)); file:close()
    end
    local function inspect(view, name)
        shot(name)
        local width, height = Screen:getWidth(), Screen:getHeight()
        local minimum = Screen:scaleByDPI(44)
        local geometry = {name = name, width = width, height = height, min_touch = minimum, controls = {}}
        for _, row in ipairs(view.layout or {}) do
            for _, widget in ipairs(row) do
                local d = assert(widget.dimen, "focus control has no painted geometry")
                assert(d.x >= -2 and d.y >= -2, name .. ": control begins outside screen")
                assert(d.x + d.w <= width + 2 and d.y + d.h <= height + 2, name .. ": control ends outside screen")
                assert(d.w >= minimum and d.h >= minimum, name .. ": focus target smaller than 44 DPI units")
                geometry.controls[#geometry.controls + 1] = {x = d.x, y = d.y, w = d.w, h = d.h,
                    text = widget.text or widget.entry and widget.entry.text or widget.item and widget.item.text}
            end
        end
        observations.screens[#observations.screens + 1] = geometry
        save()
    end
    local home = assert(plugin.home)
    inspect(home, "library-grid")
    local nav = home.layout[#home.layout]
    assert(#nav == 5, "library navigation must contain five destinations")
    for index, label in ipairs({"Library", "Stats", "AI", "Notes", "Settings"}) do
        assert(nav[index].text == plugin.translate(label), "navigation order differs from frozen spec")
        assert(nav[index].icon_widget and nav[index].icon_widget.file ~= "resources/icons/icon-not-found.svg")
        assert(not nav[index].label_widget:isTruncated(), "navigation label is truncated")
        local target = nav[index].dimen
        -- ImageWidget paints directly and does not retain absolute dimen.
        -- The CenterContainer owns placement, so compare the centered group's size.
        local content = nav[index].frame[1][1]:getSize()
        assert(content.w <= target.w + 2 and content.h <= target.h + 2,
            "navigation content exceeds its click target")
    end
    -- SDL can expose a touch-only device. Force the original focus event path
    -- without changing device capabilities or the product's normal heuristics.
    home:moveFocusTo(2, #home.layout, require("ui/widget/focusmanager").FORCED_FOCUS)
    assert(nav[2].frame._focused, "navigation focus outline missing")
    shot("navigation-focused")
    assert(home:onPress(), "keyboard activation failed")
    inspect(assert(plugin.statistics_view), "statistics-from-library")
    plugin.statistics_view:onClose()
    nav[4].callback()
    inspect(assert(plugin.notes_library), "notes-index-empty")
    plugin.notes_library:onClose()
    nav[5].callback()
    inspect(assert(plugin.settings_view), "settings-groups")
    plugin.settings_view:onClose()
    plugin:showAssistant()
    inspect(assert(plugin.assistant_view), "assistant-state")
    plugin.assistant_view:onClose()
    home:showOptions()
    local classic = home.options_menu.item_table[#home.options_menu.item_table]
    assert(classic.text == plugin.translate("Classic interface"))
    classic.callback()
    assert(not plugin.home and require("apps/filemanager/filemanager").instance == fm)
    shot("classic-from-header")
    plugin:showHome(); home = assert(plugin.home); home:setSource("directory")
    home.list_mode = true; home:rebuild()
    inspect(home, "library-list")
    home.query = "__visual_no_match__"; home:rebuild()
    inspect(home, "library-search-empty")
    home.query, home.list_mode = "", false; home:rebuild()
    local function ticks(left, done)
        if left == 0 then done() else step(function() ticks(left - 1, done) end) end
    end
    ticks(8, function()
        local original_dirty, refreshes = UIManager.setDirty, 0
        UIManager.setDirty = function(manager, widget, ...)
            if widget and type(widget.name) == "string" and widget.name:find("anxui", 1, true) then
                refreshes = refreshes + 1
            end
            return original_dirty(manager, widget, ...)
        end
        ticks(8, function()
            UIManager.setDirty = original_dirty
            observations.idle = {settle_seconds = 3.2, observed_seconds = 3.2, anx_widget_dirty_calls = refreshes,
                scope = "settled library only; original reader/device timers excluded"}
            save()
            assert(refreshes == 0, "idle library kept invalidating its widgets")
            context.selectBook(fm, function(reader)
                local owner = reader.anxui
                owner:showReaderPanel()
                inspect(assert(owner.reader_panel), "reader-toolbar")
                assert(owner.reader_panel.buttons.assistant and owner.reader_panel.buttons.dictionary)
                owner.reader_panel:onClose()
                owner:showReaderList("notes")
                inspect(assert(owner.reader_list), "reader-notes-empty")
                owner.reader_list:onClose()
                reader.bookmark:onToggleBookmark()
                owner:showReaderList("notes")
                inspect(assert(owner.reader_list), "reader-notes")
                assert(owner.reader_list.rows[1].type_icon
                    and owner.reader_list.rows[1].type_icon.file ~= "resources/icons/icon-not-found.svg")
                owner.reader_list:onClose()
                owner:showReaderList("toc")
                inspect(assert(owner.reader_list), "reader-contents")
                owner.reader_list:onClose()
                save()
                context.finish()
            end)
        end)
    end)
end
