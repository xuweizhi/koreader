describe("Anx UI manual home", function()
    local AnxUI, UIManager, plugin, registered
    local sample = "spec/front/unit/data/juliet.epub"

    setup(function()
        require("commonrequire")
        UIManager = require("ui/uimanager")
        AnxUI = dofile("plugins/anxui.koplugin/main.lua")
        AnxUI.path = "plugins/anxui.koplugin"
    end)

    before_each(function()
        G_reader_settings:delSetting("anxui")
        G_reader_settings:delSetting("plugins_disabled")
        registered = nil
        plugin = AnxUI:new{
            home_state = {source = "directory"}, -- These legacy lifecycle cases use a file-browser fixture.
            ui = {
                menu = {
                    registerToMainMenu = function(_, item) registered = item end,
                },
            },
        }
    end)

    after_each(function()
        plugin:stopPlugin()
        UIManager:quit()
        G_reader_settings:delSetting("anxui")
        G_reader_settings:delSetting("plugins_disabled")
    end)

    it("registers a manual entry without opening a window at startup", function()
        assert.are.equal(plugin, registered)
        assert.is_nil(plugin.home)
        local items = {}
        plugin:addToMainMenu(items)
        assert.is_true(items.anxui_home.enabled_func())
        items.anxui_home.callback()
        assert.is_not_nil(plugin.home)
    end)

    it("pins native menu shortcuts without duplicates and omits them when disabled", function()
        local MenuSorter = require("ui/menusorter")
        for _, context in ipairs({
            {module = "filemanager", first = "filemanager_settings"},
            {module = "reader", first = "navi", document = {file = sample}},
        }) do
            plugin.ui.document = context.document
            local order = require("ui/elements/" .. context.module .. "_menu_order")
            local function nativeItems()
                local items = {}
                for id, children in pairs(order) do
                    items[id] = {}
                    for _, child in ipairs(children) do
                        if not child:match("^anxui_") and child ~= "----------------------------" then
                            items[child] = {text = child}
                        end
                    end
                end
                return items
            end
            for __ = 1, 3 do
                local items = nativeItems()
                plugin:addToMainMenu(items)
                local tabs = MenuSorter:sort(items, order)
                assert.are.equal("anxui_home_shortcut", MenuSorter:findById(tabs, context.first)[1].id)
                assert.are.equal("anxui_home_tools", MenuSorter:findById(tabs, "tools")[1].id)
                assert.is_not_nil(MenuSorter:findById(tabs, "anxui_home")) -- legacy entry
            end
            for _, group in ipairs({context.first, "tools"}) do
                local count = 0
                for _, id in ipairs(order[group]) do
                    if id:match("^anxui_home_") then count = count + 1 end
                end
                assert.are.equal(1, count)
            end
            local disabled_tabs = MenuSorter:sort(nativeItems(), order)
            assert.is_nil(MenuSorter:findById(disabled_tabs, "anxui_home_shortcut"))
            assert.is_nil(MenuSorter:findById(disabled_tabs, "anxui_home_tools"))
            assert.is_true(#MenuSorter:findById(disabled_tabs, context.first) > 0)
        end
        plugin.ui.document = nil
    end)

    it("keeps one overlay and releases it when the close button is used", function()
        plugin:showHome()
        local home = plugin.home
        local windows = #UIManager._window_stack
        plugin:showHome()
        assert.are.equal(home, plugin.home)
        assert.are.equal(windows, #UIManager._window_stack)
        home:onClose()
        assert.is_nil(plugin.home)
        assert.are.equal(windows - 1, #UIManager._window_stack)
        plugin:showHome()
        assert.are_not.equal(home, plugin.home)
    end)

    it("closes its overlay when disabled and rejects stale menu callbacks", function()
        local items = {}
        plugin:addToMainMenu(items)
        plugin:showHome()
        local windows = #UIManager._window_stack
        plugin:stopPlugin()
        plugin:stopPlugin()
        assert.is_nil(plugin.home)
        assert.is_nil(plugin.book_items)
        assert.are.equal(windows - 1, #UIManager._window_stack)
        assert.is_false(items.anxui_home.enabled_func())
        items.anxui_home.callback()
        assert.is_false(items.anxui_home_shortcut.enabled_func())
        items.anxui_home_shortcut.callback()
        assert.is_false(items.anxui_home_tools.enabled_func())
        items.anxui_home_tools.callback()
        assert.is_nil(plugin.home)
    end)

    it("delegates the reading-to-library action to the existing reader home flow", function()
        local registered_in_reader = false
        local home_calls = 0
        local reader_plugin = AnxUI:new{
            ui = {
                document = { file = "/tmp/test.epub" },
                menu = { registerToMainMenu = function() registered_in_reader = true end },
                onHome = function() home_calls = home_calls + 1 end,
            },
        }
        reader_plugin:showHome()
        assert.is_true(registered_in_reader)
        assert.are.equal(1, home_calls)
        assert.is_nil(reader_plugin.home)
        reader_plugin:stopPlugin()
    end)

    it("uses the existing openFile callback path and closes before opening a document", function()
        local calls = 0
        plugin.ui.openFile = function(_, file, provider, before_document)
            assert.are.equal(sample, file)
            assert.is_nil(provider)
            assert.is_not_nil(plugin.home)
            before_document()
            assert.is_nil(plugin.home)
            calls = calls + 1
        end
        plugin:showHome()
        plugin:openBook(sample)
        assert.are.equal(1, calls)
    end)

    it("does not intercept classic startup without a matching return intent", function()
        plugin:onShow()
        assert.is_nil(plugin.show_pending)
        assert.is_nil(plugin.home)
    end)

    it("ignores a scheduled return after its owning file manager has closed", function()
        plugin.ui.openFile = function(_, _, _, before_document) before_document() end
        G_reader_settings:saveSetting("lastfile", sample)
        plugin:openBook(sample)
        plugin:onShow()
        local callback = plugin.show_pending
        assert.is_function(callback)
        plugin:onCloseWidget()
        assert.is_nil(plugin.show_pending)
        callback() -- A callback that was already dispatched must also be harmless.
        assert.is_nil(plugin.home)
    end)

    it("does not redirect a different book opened through the classic interface", function()
        plugin.ui.openFile = function(_, _, _, before_document) before_document() end
        plugin:openBook(sample)
        G_reader_settings:saveSetting("lastfile", "/tmp/from-classic.epub")
        plugin:onShow()
        assert.is_nil(plugin.show_pending)
        assert.is_nil(plugin.home)
    end)

    it("keeps the home usable when a listed file was removed", function()
        plugin:showHome()
        local called = false
        plugin.ui.openFile = function() called = true end
        local ok, reason = plugin:openBook("/nonexistent-anxui-test.epub")
        assert.is_false(ok)
        assert.are.equal("missing_file", reason)
        assert.is_false(called)
        assert.is_not_nil(plugin.home.error_dialog)
        plugin:closeHome()
        assert.are.equal(0, #UIManager._window_stack)
    end)

    it("does not open a book from a closed page after a new page opens", function()
        plugin.ui.file_chooser = { item_table = { { is_file = true, path = sample, text = "Juliet" } } }
        local opens = 0
        plugin.ui.openFile = function() opens = opens + 1 end
        plugin:showHome()
        local stale_action = plugin.home.cards[1].callback
        local stale_page_action = plugin.home.on_open_book
        plugin:closeHome()
        plugin:showHome()
        local _, reason = stale_action()
        assert.are.equal("stale_session", reason)
        local __, page_reason = stale_page_action(sample)
        assert.are.equal("stale_session", page_reason)
        assert.are.equal(0, opens)
        plugin.home.cards[1].callback()
        assert.are.equal(1, opens)
    end)

    it("closes its active search and rejects a late search submission when disabled", function()
        plugin:showHome()
        local home = plugin.home
        home:showSearch()
        local dialog = home.search_dialog
        local submit = dialog.buttons[1][2].callback
        dialog.getInputText = function() error("late callback touched a closed input") end
        plugin:stopPlugin()
        assert.is_nil(home.search_dialog)
        assert.is_false(home.scope.alive)
        submit()
        assert.are.equal("", home.query)
        assert.are.equal(0, #UIManager._window_stack)
    end)

    it("recovers from a failed page constructor without hiding the classic owner", function()
        local original_module = plugin.module
        plugin.module = function(self, name)
            if name == "views/home" then return { new = function() error("injected page failure") end } end
            return original_module(self, name)
        end
        local ok, reason = plugin:showHome()
        assert.is_false(ok)
        assert.are.equal("home_failed", reason)
        assert.is_nil(plugin.home)
        assert.is_true(G_reader_settings:readSetting("anxui").opening)
        plugin.module = original_module
        UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget)
        plugin:showHome()
        local dialog = plugin.recovery_dialog
        assert.is_not_nil(dialog)
        UIManager:close(dialog)
        assert.is_nil(plugin.recovery_dialog)
        dialog.ok_callback() -- Dismissed recovery actions cannot reopen anything.
        assert.is_nil(plugin.home)
        plugin:showHome()
        dialog = plugin.recovery_dialog
        dialog.ok_callback()
        UIManager:close(dialog)
        assert.is_not_nil(plugin.home)
        UIManager:forceRePaint()
        plugin.home.on_ready = nil
        plugin:closeHome()
        assert.is_false(G_reader_settings:readSetting("anxui").opening)
    end)

    it("rejects actions retained from a dismissed preferences menu", function()
        plugin:showHome()
        plugin:showPreferences()
        local stale_toggle = plugin.preferences_menu.item_table[2].callback
        plugin:closePreferences()
        local _, reason = stale_toggle()
        assert.are.equal("stale_session", reason)
        assert.is_false(plugin.settings:options().large_text)
    end)

    it("does not register a cached plugin class when externally disabled", function()
        plugin:stopPlugin()
        registered = nil
        G_reader_settings:saveSetting("plugins_disabled", { anxui = true })
        plugin = AnxUI:new{ ui = { menu = { registerToMainMenu = function() registered = true end } } }
        assert.is_nil(registered)
        plugin:showHome()
        assert.is_nil(plugin.home)
    end)

    it("rejects a card action after switching sources in the same page", function()
        plugin.ui.file_chooser = { item_table = { { is_file = true, path = sample, text = "Juliet" } } }
        local opens = 0
        plugin.ui.openFile = function() opens = opens + 1 end
        plugin:showHome()
        local card = plugin.home.cards[1]
        plugin.home:setSource("recent")
        card:onTapCard()
        assert.are.equal(0, opens)
    end)

    it("binds visible card actions to their file and rejects both actions after a rebuild", function()
        plugin.ui.file_chooser = { item_table = {
            { is_file = true, path = sample, text = "Same title" },
            { is_file = true, path = "/other/book.epub", text = "Same title" },
        } }
        local opened, held = {}, {}
        plugin.openBook = function(_, file) opened[#opened + 1] = file end
        plugin.showBookActions = function(_, file) held[#held + 1] = file end
        plugin:showHome()
        local home = plugin.home
        local card = home.cards[1]
        local expected = card.item.file
        card.callback(); card.hold_callback()
        assert.same({expected}, opened)
        assert.same({expected}, held)
        local stale_open, stale_hold = card.callback, card.hold_callback
        home:rebuild()
        local _, open_reason = stale_open()
        local __, hold_reason = stale_hold()
        assert.are.equal("stale_session", open_reason)
        assert.are.equal("stale_session", hold_reason)
        assert.are.equal(1, #opened)
        assert.are.equal(1, #held)
        local current = home.cards[1]
        current.callback(); current.hold_callback()
        assert.are.equal(current.item.file, opened[2])
        assert.are.equal(current.item.file, held[2])
    end)

    it("defaults to the persistent library and rejects import actions retained from a closed home", function()
        plugin.home_state = nil
        plugin:showHome()
        local home = plugin.home
        assert.are.equal("library", home.source)
        home:showOptions()
        home.options_menu.item_table[3].callback()
        assert.are.equal("recent", home.sort)
        home:showOptions()
        assert.are.equal(plugin.translate("Descending order"), home.options_menu.item_table[6].text)
        home.options_menu.item_table[6].callback()
        assert.is_true(home.reverse)
        home:showSources()
        home.options_menu.item_table[1].callback()
        assert.are.equal("library", home.source)
        plugin:closeHome()
        local _, reason = home.on_import()
        assert.are.equal("stale_session", reason)
        local __, scan_reason = home.on_scan()
        assert.are.equal("stale_session", scan_reason)
        assert.is_nil(plugin.home)
    end)

    it("isolates picker selection and cancels picker and confirmation callbacks on close", function()
        plugin.ui.file_chooser = {path="spec/front/unit/data"}
        plugin.ui.folder_shortcuts = {getShortcutFullName=function() end, hasFolderShortcut=function() return false end}
        plugin.ui.selected_files = {original=true}
        plugin:showHome()
        plugin.home.on_import()
        local importer, picker = plugin.home.importer, plugin.home.importer.picker
        assert.is_not_nil(picker)
        assert.are_not.equal(plugin.ui.selected_files, picker.ui.selected_files)
        local stale = picker.onLeftButtonTap
        UIManager:close(picker)
        local _, reason = stale()
        assert.are.equal("stale_session", reason)
        assert.same({original=true}, plugin.ui.selected_files)
        importer:confirmScan({"spec/front/unit/data"})
        local dialog = importer.scan_confirmation
        local scan = dialog.buttons[1][2].callback
        UIManager:close(dialog)
        local __, scan_reason = scan()
        assert.are.equal("stale_session", scan_reason)
        assert.is_nil(importer.operation)
    end)
end)
