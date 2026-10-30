return function(context)
    local ui, shot = context.ui, context.shot
    local plugin, UIManager = ui.anxui, require("ui/uimanager")
    local Native = plugin:module("native")
    local function closeNative()
        if ui.menu.menu_container then ui.menu.menu_container[1]:closeMenu() end
        for index = #UIManager._window_stack, 1, -1 do
            local widget = UIManager._window_stack[index].widget
            if widget ~= ui and widget ~= plugin.home then UIManager:close(widget) end
        end
    end
    local function select(id)
        for _, entry in ipairs(plugin.settings_view.entries) do
            if entry.id == id then plugin.settings_view.on_select(entry); return end
        end
        error("missing setting " .. id)
    end
    plugin:showSettings()
    assert(#plugin.settings_view.entries == 6)
    shot(ui.document and "reader-settings-groups" or "library-settings-groups")
    select("device"); select("device")
    assert(ui.menu.menu_container)
    local menu = ui.menu.menu_container[1]
    local units
    for _, item in ipairs(menu.item_table) do if item.id == "units" then units = item end end
    assert(units, "device group did not open the original device menu")
    menu:onMenuSelect(units)
    local before = G_reader_settings:isTrue("dimension_units_append_px")
    menu:onMenuSelect(menu.item_table[1])
    assert(G_reader_settings:isTrue("dimension_units_append_px") ~= before)
    closeNative()
    assert(Native.open(ui, "units", plugin.scope))
    assert(ui.menu.menu_container[1].item_table[1].checked_func() ~= before)
    shot("native-setting-readback")
    closeNative()
    for _, group in ipairs({"reading", "device", "plugins"}) do
        plugin:showSettings(group)
        local entries = plugin.settings_view.entries
        for _, entry in ipairs(entries) do
            if entry.native then
                local route = Native.resolve(ui, entry.native)
                if entry.native == "advanced_settings" and ui.document then
                    assert(not route, "advanced settings is file-manager-only in the pinned core")
                    assert(entry.subtitle == plugin.translate("Unavailable in this context"))
                else assert(route, "native route not available: " .. entry.native) end
            end
        end
        plugin.settings_view:onClose()
    end
    plugin:showSettings("plugins"); select("plugin_management")
    assert(#ui.menu.menu_container[1].item_table == 2)
    shot("native-plugin-manager")
    closeNative()
    plugin:showSettings("sync")
    shot("separate-progress-and-files")
    select("progress_sync")
    if ui.document then assert(ui.menu.menu_container, "progress sync menu missing in reader")
    else assert(not ui.menu.menu_container, "document-only sync should be unavailable in file manager") end
    closeNative()
    plugin:showSettings("sync"); select("cloudstorage")
    assert(#UIManager._window_stack > (plugin.home and 2 or 1), "cloud storage did not open")
    shot("original-cloud-storage")
    closeNative()
    G_reader_settings:saveSetting("plugins_disabled", {cloudstorage = true})
    plugin:showSettings("sync"); select("cloudstorage")
    assert(not ui.menu.menu_container)
    shot("disabled-cloud-storage")
    closeNative()
    G_reader_settings:saveSetting("plugins_disabled", {})
    context.done()
end
