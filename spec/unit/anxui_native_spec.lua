describe("Anx native settings routing", function()
    local Native
    setup(function()
        require("commonrequire")
        Native = dofile("plugins/anxui.koplugin/native.lua")
    end)
    it("follows reordered stable IDs without evaluating unrelated dynamic menus", function()
        local target = {id = "device"}
        local tabs = {
            {id = "tools", {id = "dynamic", sub_item_table_func = function() error("must not call") end}},
            {id = "setting", {id = "network"}, {id = "parent", sub_item_table = {target}}},
        }
        local route, item = Native.find(tabs, "device")
        assert.same({2, 2, 1}, route)
        assert.are.equal(target, item)
        assert.same({2}, Native.find(tabs, "setting"))
        assert.is_nil(Native.find(tabs, "missing"))
    end)
    it("checks current availability and invokes the native menu objects", function()
        local disabled = false
        local leaf = {id = "units", enabled_func = function() return not disabled end}
        local tab = {id = "setting", {id = "device", sub_item_table = {leaf}}}
        local calls = {}
        local ui = {menu = {tab_item_table = {tab}}}
        function ui.menu:onShowMenu(index)
            assert.are.equal(1, index)
            self.menu_container = {{item_table = tab, perpage = 8,
                updateItems = function() end,
                onMenuSelect = function(menu, item)
                    calls[#calls + 1] = item.id
                    if item.sub_item_table then menu.item_table = item.sub_item_table end
                end,
                closeMenu = function() ui.menu.menu_container = nil end,
            }}
        end
        local scope = {alive = true, collectWindows = function(_, callback) return callback() end}
        assert.is_true(Native.open(ui, "units", scope))
        assert.same({"device", "units"}, calls)
        disabled = true
        assert.is_nil(Native.resolve(ui, "units"))
        scope.alive = false
        assert.is_false(Native.open(ui, "units", scope))
    end)
end)
