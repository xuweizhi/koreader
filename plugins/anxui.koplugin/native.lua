local Native = {}

-- Resolve stable menu IDs in the actual, user-reordered native tree. Do not
-- invoke every dynamic submenu merely to discover a route.
function Native.find(tabs, id)
    local function walk(items, path, depth)
        if depth > 10 then return end
        for index, item in ipairs(items) do
            local route = {}
            for i, value in ipairs(path) do route[i] = value end
            route[#route + 1] = index
            if item.id == id then return route, item end
            if item.sub_item_table then
                local found, target = walk(item.sub_item_table, route, depth + 1)
                if found then return found, target end
            end
        end
    end
    for index, tab in ipairs(tabs) do
        if tab.id == id then return {index}, tab end
        local route, item = walk(tab, {index}, 0)
        if route then return route, item end
    end
end

function Native.enabled(item)
    return item and item.enabled ~= false and (not item.enabled_func or item.enabled_func() ~= false)
end

function Native.resolve(ui, id)
    if not ui or not ui.menu then return nil, "Unavailable in this context" end
    if not ui.menu.tab_item_table then ui.menu:setUpdateItemTable() end
    local route, item = Native.find(ui.menu.tab_item_table, id)
    if not route or not Native.enabled(item) then return nil, "Unavailable in this context" end
    return route
end

function Native.open(ui, id, scope)
    if not scope.alive then return false, "stale_session" end
    local route, reason = Native.resolve(ui, id)
    if not route then return false, reason end
    if ui.menu.menu_container then ui.menu.menu_container[1]:closeMenu() end
    return scope:collectWindows(function()
        ui.menu:onShowMenu(route[1])
        local menu = ui.menu.menu_container[1]
        for index = 2, #route do
            local item = menu.item_table[route[index]]
            if not Native.enabled(item) then menu:closeMenu(); return false, "Unavailable in this context" end
            menu:updateItems(math.floor((route[index] - 1) / menu.perpage) + 1)
            menu:onMenuSelect(item)
        end
        return true
    end)
end

return Native
