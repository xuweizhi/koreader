return function(context)
    local UIManager, Loader = require("ui/uimanager"), require("pluginloader")
    local manifest = dofile("/data/koreader/doc/anx-style-ui/tools/plugins-manifest.lua")
    local phase, evidence = os.getenv("ANX_SMOKE_SCENARIO"), os.getenv("ANX_SMOKE_EVIDENCE")
    local records = {}
    local classes = {}
    for _, class in ipairs(Loader:loadPlugins()) do classes[class.name] = class end
    local function write()
        local file = assert(io.open(evidence .. "/plugins.json", "wb"))
        file:write(require("json").encode({phase = phase, backend = "Linux SDL; emulated device features", plugins = records}))
        file:close()
    end
    local function closePopups(ui)
        if ui.menu.menu_container then ui.menu.menu_container[1]:closeMenu() end
        for index = #UIManager._window_stack, 1, -1 do
            local widget = UIManager._window_stack[index].widget
            if widget ~= ui and widget ~= ui.anxui.home then UIManager:close(widget) end
        end
    end
    local function check(ui)
        local plugin = ui.anxui
        local Native = plugin:module("native")
        local kind = ui.document and "reader" or "library"
        for _, entry in ipairs(manifest) do
            local id, menu_id = entry[1], entry[2]
            local record = records[id] or {id = id, remote = entry.network and "not tested" or nil,
                physical_hardware = entry.hardware and "not tested; SDL emulation only" or nil}
            records[id] = record
            if phase == "plugins_disabled" then
                if not entry.gate then
                    assert(not classes[id] and not ui[id], "plugin still loaded after disabled restart: " .. id)
                    assert(G_reader_settings:readSetting("plugins_disabled")[id])
                end
                record[kind] = "disabled restart verified"
            elseif not classes[id] then
                assert(entry.gate, "unexpected native load failure: " .. id)
                record[kind] = "not applicable: " .. entry.gate
            elseif not ui[id] then
                assert(entry.doc_only and not ui.document, "missing plugin instance: " .. id)
                record[kind] = "native document-only context"
            elseif entry.fm_menu and ui.document then
                record[kind] = "native menu exists in file manager; instance available"
            else
                plugin:showSettings("plugins")
                plugin.settings_view:onClose()
                if entry.special == "archive" then
                    assert(ui.archiveviewer:isFileTypeSupported(context.archive))
                    ui.archiveviewer:openFile(context.archive)
                    assert(#ui.archiveviewer.booklist.item_table > 0)
                elseif entry.entry_only then
                    local route = assert(Native.resolve(ui, menu_id))
                    -- NTP changes system time; show its exact native row without running it.
                    ui.menu:onShowMenu(route[1])
                    local menu = ui.menu.menu_container[1]
                    for i = 2, #route - 1 do menu:onMenuSelect(menu.item_table[route[i]]) end
                    assert(menu.item_table[route[#route]].id == menu_id)
                    menu:updateItems(math.floor((route[#route] - 1) / menu.perpage) + 1)
                else
                    assert(Native.open(ui, menu_id, plugin.scope), "native entry unavailable: " .. id)
                end
                context.shot(kind .. "-" .. id)
                closePopups(ui)
                assert(not ui.menu.menu_container)
                record[kind] = entry.entry_only and "native action visible; system-time mutation not run" or "original entry opened and closed"
            end
            write()
        end
    end
    check(context.fm)
    context.selectBook(context.fm, function(reader)
        check(reader)
        local by_fullname = {}
        for _, class in ipairs(Loader.all_plugins or {}) do by_fullname[class.fullname] = class.name end
        Loader:genPluginManagerSubItem() -- initializes all_plugins when needed
        for _, class in ipairs(Loader.all_plugins) do by_fullname[class.fullname] = class.name end
        if phase ~= "plugins_enabled" then
            for _, group in ipairs(Loader:genPluginManagerSubItem()) do
                for _, item in ipairs(group.sub_item_table or {}) do
                    local id = by_fullname[item.text]
                    local record = id and records[id]
                    if record and (phase == "plugins_disabled" or classes[id]) then
                        local before = item.checked_func()
                        item.callback()
                        assert(item.checked_func() ~= before)
                        assert((G_reader_settings:readSetting("plugins_disabled")[id] ~= true) == item.checked_func())
                        record.toggle = phase == "plugins" and "disabled through original manager" or "enabled through original manager"
                        closePopups(reader)
                    end
                end
            end
        end
        write()
        G_reader_settings:flush()
        context.finish()
    end)
end
