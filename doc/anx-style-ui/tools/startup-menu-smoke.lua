-- Select the native radio row with real input, then verify two fresh launches.
return function(ctx)
    local UIManager, Screen = require("ui/uimanager"), require("device").screen
    local plugin, menu = assert(ctx.fm.anxui), ctx.fm.menu
    local function finish(checks)
        local file = assert(io.open(ctx.evidence .. "/startup-menu-checks.json", "w"))
        file:write(require("json").encode({passed=true, phase=ctx.scenario, checks=checks})); file:close()
        ctx.finish()
    end
    if ctx.scenario == "startup_menu_selected" then
        assert(plugin.home and G_reader_settings:readSetting("start_with") == "anxui")
        ctx.shot("started-in-anx-library")
        plugin:closeHome()
    else
        assert(not plugin.home and G_reader_settings:readSetting("start_with") == "filemanager")
        ctx.shot("started-in-classic")
    end
    menu:setUpdateItemTable()
    local entry = assert(require("ui/menusorter"):findById(menu.tab_item_table, "start_with"))
    assert(#entry.sub_item_table == 6, "native startup choice missing or duplicated")
    local selected = ctx.scenario == "startup_menu_selected" and 6 or 1
    for index, option in ipairs(entry.sub_item_table) do
        assert(option.checked_func() == (index == selected), "startup radio selection is inconsistent")
    end
    if ctx.scenario == "startup_menu_classic" then
        assert(not plugin.settings:options().startup)
        return finish({classic_restart=true, single_selected_radio=true})
    end
    local tab
    for index, items in ipairs(menu.tab_item_table) do
        for _, item in ipairs(items) do if item.id == "start_with" then tab = index end end
    end
    menu:onShowMenu(assert(tab))
    ctx.step(function()
        local touch = assert(menu.menu_container[1])
        local function clickItem(item, label, callback)
            local index
            for i, candidate in ipairs(touch.item_table) do if candidate == item then index = i; break end end
            touch:updateItems(math.floor((assert(index) - 1) / touch.perpage) + 1)
            UIManager:forceRePaint()
            local target
            for _, row in ipairs(touch.layout) do
                for _, widget in pairs(row) do if widget.item == item then target = widget end end
            end
            assert(target and not target.text_truncated, "native startup label missing or truncated")
            local d = target.dimen
            assert(d.x >= 0 and d.y >= 0 and d.x+d.w <= Screen:getWidth() and d.y+d.h <= Screen:getHeight())
            ctx.shot(label)
            ctx.input({{kind="click", x=math.floor(d.x+d.w/2), y=math.floor(d.y+d.h/2)}}, callback)
        end
        clickItem(entry, "native-start-with-menu", function()
            local next_index = selected == 1 and 6 or 1
            local option = entry.sub_item_table[next_index]
            clickItem(option, "startup-options", function()
                local expected = next_index == 6 and "anxui" or "filemanager"
                assert(G_reader_settings:readSetting("start_with") == expected)
                assert(plugin.settings:options().startup == (expected == "anxui"))
                for index, choice in ipairs(entry.sub_item_table) do
                    assert(choice.checked_func() == (index == next_index))
                end
                ctx.shot("startup-selection-saved")
                touch:backToUpperMenu()
                ctx.shot("native-start-with-label")
                menu:onCloseFileManagerMenu()
                finish({actual_radio_click=true, single_selected_radio=true, choice=expected,
                    anx_restart=ctx.scenario == "startup_menu_selected"})
            end)
        end)
    end)
end
