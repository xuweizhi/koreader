-- Exercise the actual native menu rows and their return-to-library callbacks.
return function(ctx)
    local UIManager = require("ui/uimanager")
    local FileManager = require("apps/filemanager/filemanager")
    local Screen = require("device").screen
    local JSON = require("json")
    local observations = {}
    local function enter(owner, id, image_name, done)
        local menu = owner.menu
        if owner.anxui.home then owner.anxui:closeHome() end
        menu:setUpdateItemTable()
        local tab_index
        for index, tab in ipairs(menu.tab_item_table) do
            if tab[1] and tab[1].id == id then tab_index = index; break end
        end
        assert(tab_index, "shortcut not at the top of a native menu tab: " .. id)
        menu:onShowMenu(tab_index)
        ctx.step(function()
            local touch_menu = assert(menu.menu_container[1])
            assert(touch_menu.item_table[1].id == id and touch_menu.page == 1)
            UIManager:forceRePaint()
            local row = assert(touch_menu.layout[2][touch_menu.cur_tab])
            assert(not row.text_truncated, "shortcut label truncated")
            local d = row.dimen
            assert(d.x >= 0 and d.y >= 0 and d.x + d.w <= Screen:getWidth()
                and d.y + d.h <= Screen:getHeight(), "shortcut outside the screen")
            assert(d.h >= Screen:scaleBySize(44), "shortcut tap target too short")
            assert(row.item.font_func(22).is_real_bold)
            observations[#observations + 1] = {
                id = id, tab = tab_index, label = row.item.text, x = d.x, y = d.y,
                width = d.w, height = d.h, bold = true, screenshot = image_name,
            }
            ctx.shot(image_name)
            ctx.input({{kind = "click", x = math.floor(d.x + d.w / 2),
                y = math.floor(d.y + d.h / 2)}}, function()
                assert(not menu.menu_container, "native menu remained above the library")
                local fm = assert(FileManager.instance)
                assert(fm.anxui.home, "native shortcut did not open Anx library")
                ctx.shot(image_name .. "-opened")
                done(fm)
            end)
        end)
    end
    enter(ctx.fm, "anxui_home_shortcut", "filemanager-first-tab", function(fm)
        enter(fm, "anxui_home_tools", "filemanager-tools-tab", function(current)
            ctx.selectBook(current, function(reader)
                enter(reader, "anxui_home_shortcut", "reader-first-tab", function(returned)
                    ctx.selectBook(returned, function(next_reader)
                        enter(next_reader, "anxui_home_tools", "reader-tools-tab", function(last)
                            last.anxui:stopPlugin()
                            local items = {}; last.anxui:addToMainMenu(items)
                            assert(not items.anxui_home_shortcut.enabled_func())
                            items.anxui_home_shortcut.callback()
                            assert(not last.anxui.home)
                            local file = assert(io.open(ctx.evidence .. "/entry-checks.json", "w"))
                            file:write(JSON.encode({passed = true, shortcuts = observations,
                                disabled_callback_rejected = true})); file:close()
                            ctx.finish()
                        end)
                    end)
                end)
            end)
        end)
    end)
end
