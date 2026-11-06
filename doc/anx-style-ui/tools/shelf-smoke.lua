-- Real file pickers, native collection persistence and reading roundtrip.
return function(ctx)
    local UIManager, Screen = require("ui/uimanager"), require("device").screen
    local FileManager = require("apps/filemanager/filemanager")
    local JSON = require("json")
    local plugin, home = ctx.fm.anxui, ctx.fm.anxui.home
    local results = {phase=ctx.scenario, checks={}, geometry={}}
    local function save()
        local f = assert(io.open(ctx.evidence .. "/shelf-checks.json", "w"))
        f:write(JSON.encode(results)); f:close()
    end
    local function inspect(view, label)
        ctx.shot(label)
        local rectangles = {}
        for _, row in ipairs(view.layout) do
            for _, widget in ipairs(row) do
                local d = assert(widget.dimen)
                assert(d.x >= -2 and d.y >= -2 and d.x + d.w <= Screen:getWidth() + 2
                    and d.y + d.h <= Screen:getHeight() + 2, label .. ": control outside screen")
                assert(d.w >= Screen:scaleByDPI(44) and d.h >= Screen:scaleByDPI(44), label .. ": control too small")
                rectangles[#rectangles + 1] = {x=d.x,y=d.y,w=d.w,h=d.h,label=widget.text or widget.label}
            end
        end
        results.geometry[label] = rectangles
        local nav = view.layout[#view.layout]
        assert(#nav == 5)
        for i, label_key in ipairs({"Library", "Stats", "AI", "Notes", "Settings"}) do
            assert(nav[i].text == plugin.translate(label_key))
            assert(not nav[i].label_widget:isTruncated())
        end
        save()
    end
    local function click(widget, callback)
        UIManager:forceRePaint()
        local d = assert(widget.dimen)
        ctx.input({{kind="click", x=math.floor(d.x + d.w / 2), y=math.floor(d.y + d.h / 2)}}, callback)
    end
    local function chooseRow(picker, path, callback)
        UIManager:forceRePaint()
        for _, row in ipairs(picker.item_group) do
            if row.entry and row.entry.path == path then return click(row, callback) end
        end
        error("picker row not found: " .. path)
    end
    local function resizeSelectedPicker(importer, picker, callback)
        local original_width, original_height = Screen:getWidth(), Screen:getHeight()
        local path, selected = picker.path, {}
        for file in pairs(picker.ui.selected_files) do selected[file] = true end
        local function inspectPicker(width, height, label)
            assert(Screen:getWidth() == width and Screen:getHeight() == height, "native resize not applied")
            assert(importer.picker == picker and UIManager:isWidgetShown(picker), "picker lost during resize")
            assert(picker.path == path, "selected folder changed during resize")
            local count = 0
            for file in pairs(picker.ui.selected_files) do
                assert(selected[file], "resize added an unintended selection")
                count = count + 1
            end
            assert(count == 2 and picker.confirm_button.enabled, "selection lost during resize")
            for file in pairs(selected) do assert(picker.ui.selected_files[file]) end
            UIManager:forceRePaint()
            local controls = {picker.select_all_button, picker.clear_selection_button, picker.confirm_button}
            local rectangles = {}
            for _, control in ipairs(controls) do
                local occurrences = 0
                for _, row in ipairs(picker.layout) do
                    for _, widget in ipairs(row) do if widget == control then occurrences = occurrences + 1 end end
                end
                assert(occurrences == 1, "footer control missing or duplicated in focus layout")
                local d = assert(control.dimen)
                assert(d.x >= 0 and d.y >= 0 and d.x + d.w <= width and d.y + d.h <= height,
                    "resized footer outside screen")
                assert(d.w >= Screen:scaleByDPI(48) and d.h >= Screen:scaleByDPI(48), "resized footer too small")
                rectangles[#rectangles + 1] = {x=d.x,y=d.y,w=d.w,h=d.h,label=control.text}
            end
            results.geometry[label] = rectangles
            ctx.shot(label)
            save()
        end
        ctx.input({{kind="resize",width=original_height,height=original_width}}, function()
            inspectPicker(original_height, original_width, "picker-landscape-selected")
            ctx.input({{kind="resize",width=original_width,height=original_height}}, function()
                inspectPicker(original_width, original_height, "picker-portrait-selected")
                results.checks.picker_resize_selection_and_focus = true
                save()
                callback()
            end)
        end)
    end
    local function waitImport(importer, callback, tries)
        if not importer.operation and importer.last_result then
            assert(not importer.last_result.reason, importer.last_result.reason)
            local top = UIManager._window_stack[#UIManager._window_stack].widget
            if top ~= home then UIManager:close(top) end
            callback(importer.last_result.stats)
        else
            assert((tries or 0) < 50, "import did not finish")
            ctx.step(function() waitImport(importer, callback, (tries or 0) + 1) end)
        end
    end
    local function waitStatus(callback, tries)
        if not home.loading_status then callback()
        else
            assert((tries or 0) < 40)
            ctx.step(function() waitStatus(callback, (tries or 0) + 1) end)
        end
    end
    -- Drive the longer management journey with real input while retaining the
    -- same fail-fast assertions as the callback-based import checks below.
    local function management(importer, scan, second, finished)
        local thread
        local function resume(...)
            local ok, err = coroutine.resume(thread, ...)
            assert(ok, err)
        end
        local function await(register)
            register(function(...) resume(...) end)
            return coroutine.yield()
        end
        local function tap(widget) await(function(done) click(assert(widget), done) end) end
        local function input(actions) await(function(done) ctx.input(actions, done) end) end
        local function settle() await(function(done) ctx.step(done) end) end
        local function menuItem(menu, text)
            assert(menu)
            for _, row in ipairs(menu.item_group) do
                if row.entry and row.entry.text == text then return row end
            end
            error("visible menu item missing: " .. text)
        end
        local function button(widget, text)
            if widget.text == text and type(widget.callback) == "function" then return widget end
            for _, child in ipairs(widget) do
                local found = button(child, text)
                if found then return found end
            end
        end
        local function dismissResult()
            local top = UIManager._window_stack[#UIManager._window_stack].widget
            assert(top ~= home, "expected operation result")
            UIManager:close(top)
        end
        local function card(file)
            local index
            for i, item in ipairs(home.filtered) do if item.file == file then index = i; break end end
            assert(index, "book missing from shelf")
            local target = math.ceil(index / home.perpage)
            while home.page < target do input({{kind="key",value="Page_Down"}}) end
            while home.page > target do input({{kind="key",value="Page_Up"}}) end
            for _, visible in ipairs(home.cards) do if visible.item.file == file then return visible end end
            error("book not rendered on expected page")
        end
        local function selectBooks(files)
            tap(card(files[1]).more_button)
            assert(not require("apps/reader/readerui").instance, "more button opened the book")
            tap(menuItem(plugin.book_actions, plugin.translate("Select / manage books")))
            for i = 2, #files do tap(card(files[i]).more_button) end
            assert(#home:selectedFiles() == #files)
        end
        local function batch(action)
            tap(home.controls.batch_actions)
            tap(menuItem(plugin.batch_actions_menu, plugin.translate(action)))
        end
        local function openRoots()
            tap(home.controls.add)
            tap(menuItem(home.options_menu, plugin.translate("Manage scan folders")))
            assert(importer.scan_roots_menu)
        end
        local function rootActions()
            openRoots()
            tap(importer.scan_roots_menu.item_group[2])
            assert(importer.scan_root_actions)
        end
        local function completeScan()
            importer.last_result = nil
            tap(button(importer.scan_confirmation, plugin.translate("Start scan")))
            return await(function(done) ctx.step(function() waitImport(importer, done) end) end)
        end
        local function fileData(path)
            local f = assert(io.open(path, "rb")); local data = f:read("*a"); f:close(); return data
        end
        thread = coroutine.create(function()
            local shelf, collections = plugin:module("shelf"), require("readcollection")
            local last = scan .. "/07-旅行手记.epub"
            tap(home.controls.sort)
            tap(menuItem(home.options_menu, plugin.translate("List view")))
            selectBooks({second,last})
            assert(home.selection[second] and home.selection[last])
            assert(home.page > 1, "selection journey did not cross pages")
            ctx.shot("batch-cross-page-selection")
            input({{kind="key",value="Escape"}})
            assert(UIManager:isWidgetShown(home) and not home.selection_mode and #home:selectedFiles() == 0)
            results.checks.more_and_cross_page_selection_back = true
            selectBooks({second,last})
            batch("Add to collection")
            tap(menuItem(plugin.batch_collection_menu, "favorites"))
            assert(plugin.last_batch_result.changed == 2 and plugin.last_batch_result.errors == 0)
            dismissResult()
            assert(collections:isFileInCollection(second,"favorites") and collections:isFileInCollection(last,"favorites"))
            results.checks.batch_add_collection = true
            selectBooks({second,last})
            batch("Mark as finished")
            tap(button(plugin.batch_confirmation, plugin.translate("Mark as finished")))
            assert(plugin.last_batch_result.changed == 2 and plugin.last_batch_result.errors == 0)
            dismissResult()
            tap(home.controls.complete)
            await(function(done) ctx.step(function() waitStatus(done) end) end)
            assert(#home.filtered == 2, "finished filter did not reflect batch status")
            ctx.shot("batch-finished-filter")
            tap(home.controls.all); settle()
            assert(home.status == nil and #home.filtered == 8)
            results.checks.batch_finished_and_all_filter = true
            local docsettings = require("docsettings")
            local sidecar = assert(docsettings:findSidecarFile(second))
            local before_book, before_sidecar = fileData(second), fileData(sidecar)
            selectBooks({second})
            batch("Remove from bookshelf")
            tap(button(plugin.batch_confirmation, plugin.translate("Remove from bookshelf")))
            assert(plugin.last_batch_result.changed == 1 and plugin.last_batch_result.errors == 0)
            dismissResult()
            assert(#home.item_table == 7 and not collections:isFileInCollection(second,shelf.collection(false)))
            assert(collections:isFileInCollection(second,"favorites"))
            assert(before_book == fileData(second) and before_sidecar == fileData(sidecar))
            ctx.shot("batch-remove-keeps-files")
            results.checks.batch_remove_preserves_data = true
            rootActions()
            tap(button(importer.scan_root_actions, plugin.translate("Rescan folder")))
            local scan_result = completeScan()
            assert(scan_result.added == 1 and scan_result.duplicates == 6 and #home.item_table == 8)
            assert(shelf.rootInfo()[1].last_scan)
            results.checks.single_folder_rescan = true
            openRoots(); ctx.shot("scan-folder-manager")
            tap(importer.scan_roots_menu.item_group[2])
            tap(button(importer.scan_root_actions, plugin.translate("Remove scan folder")))
            local confirmation = importer.scan_root_confirmation
            tap(button(confirmation, confirmation.cancel_text))
            assert(#shelf.roots() == 1)
            rootActions()
            tap(button(importer.scan_root_actions, plugin.translate("Remove scan folder")))
            tap(button(importer.scan_root_confirmation, plugin.translate("Remove scan folder")))
            assert(#shelf.roots() == 0 and #home.item_table == 8)
            assert(before_book == fileData(second) and before_sidecar == fileData(sidecar))
            ctx.shot("scan-folder-removed-books-kept")
            tap(importer.scan_roots_menu.item_group[1])
            assert(importer.picker.folder and importer.picker.path == scan)
            tap(importer.picker.confirm_button)
            scan_result = completeScan()
            assert(scan_result.added == 0 and scan_result.duplicates == 7 and #shelf.roots() == 1)
            results.checks.scan_folder_remove_cancel_add = true
            tap(home.controls.sort)
            tap(menuItem(home.options_menu, plugin.translate("Grid view")))
            selectBooks({second})
            tap(home.controls.sort)
            tap(menuItem(home.options_menu, plugin.translate("Classic interface")))
            assert(home.closed and not UIManager:isWidgetShown(home) and not plugin.home,
                "explicit Classic action must close the shelf even during selection")
            ctx.shot("classic-from-selection")
            ctx.fm.menu:onShowMenu(3); settle()
            local entry = assert(ctx.fm.menu.menu_items.anxui_home)
            ctx.fm.menu:onCloseFileManagerMenu(); entry.callback(); settle()
            home = assert(plugin.home)
            assert(not home.selection_mode and #home.item_table == 8)
            results.checks.explicit_classic_and_return = true
            ctx.shot("shelf-after-classic-selection")
            save(); finished()
        end)
        resume()
    end
    local function navigation(callback)
        local function sources()
            click(home.controls.sources, function()
                assert(#home.options_menu.item_table >= 4)
                home.options_menu.item_table[1].callback()
                assert(home.source == "library" and #home.item_table == 8)
                results.checks.source_menu = true
                callback()
            end)
        end
        if home.page_count == 1 then return sources() end
        local x, y = Screen:getWidth() - 8, math.floor(Screen:getHeight() * .7)
        ctx.input({{kind="swipe", x=x, y=y, end_x=x, end_y=y-150}}, function()
            assert(home.page == 2, "upward swipe did not change shelf page")
            ctx.input({{kind="key", value="Page_Up"}}, function()
                assert(home.page == 1, "PageUp did not change shelf page")
                ctx.input({{kind="key", value="Page_Down"}}, function()
                    assert(home.page == 2, "PageDown did not change shelf page")
                    ctx.input({{kind="swipe", x=x, y=y-150, end_x=x, end_y=y}}, function()
                        assert(home.page == 1, "downward swipe did not change shelf page")
                        results.checks.swipe_and_keys = true
                        sources()
                    end)
                end)
            end)
        end)
    end
    if ctx.scenario == "shelf_reopen" then
        assert(home.source == "library" and #home.item_table == 8, "imported membership lost after process restart")
        assert(#plugin:module("shelf").roots() == 1, "scan root was not persisted")
        inspect(home, "persistent-library")
        home:setStatus("reading")
        waitStatus(function()
            assert(#home.filtered == 1 and home.filtered[1].file == ctx.book)
            inspect(home, "reading-filter")
            ctx.selectBook(ctx.fm, function(reader)
                assert(reader:getCurrentPage() == 3, "reading position changed")
                assert(#reader.annotation.annotations == 1, "bookmark changed")
                results.checks.restart_membership = true
                results.checks.restart_reading_data = true
                results.passed = true; save(); ctx.finish()
            end)
        end)
        return
    end
    assert(home.source == "library" and #home.item_table == 0, "new library should start empty")
    inspect(home, "empty-library")
    local folder = ctx.book:match("(.+)/[^/]+$")
    local scan = folder .. "/scan"
    local second = scan .. "/01-海边的清晨.epub"
    click(home.controls.add, function()
        ctx.shot("add-books-menu")
        home.options_menu.item_table[1].callback()
        local importer = assert(home.importer)
        local picker = assert(importer.picker)
        assert(not picker.confirm_button.enabled, "empty selection must not import")
        picker.select_all_button.callback()
        assert(picker.confirm_button.enabled)
        picker.clear_selection_button.callback()
        assert(not picker.confirm_button.enabled and not next(picker.ui.selected_files))
        ctx.shot("file-picker")
        chooseRow(picker, ctx.book, function()
            assert(picker.ui.selected_files[ctx.book])
            assert(picker.confirm_button.enabled)
            for _,entry in ipairs(picker.item_table) do
                if entry.path==ctx.book then assert(not entry.dim and entry.text_bgcolor, "selection must be highlighted, not dimmed") end
            end
            chooseRow(picker, scan, function()
                chooseRow(picker, second, function()
                    assert(picker.ui.selected_files[ctx.book] and picker.ui.selected_files[second])
                    UIManager:forceRePaint()
                    local marked=false
                    for _,row in ipairs(picker.item_group) do
                        if row.entry and row.entry.path==second then
                            marked=row.text:find("☑",1,true)~=nil
                        end
                    end
                    assert(marked,"selected checkbox must be rendered in native row")
                    local d=picker.confirm_button.dimen
                    assert(d.y+d.h<=Screen:getHeight() and d.w>=Screen:scaleByDPI(48))
                    ctx.shot("multi-selection")
                    resizeSelectedPicker(importer, picker, function()
                    click(picker.confirm_button, function()
                        waitImport(importer, function(stats)
                            assert(stats.added == 2 and #home.item_table == 2)
                            results.checks.manual_multiselect = true
                            inspect(home, "manual-import-result")
                            click(home.controls.add, function()
                                home.options_menu.item_table[2].callback()
                                local folder_picker = assert(importer.picker)
                                assert(folder_picker.path == scan)
                                click(folder_picker.confirm_button, function()
                                    ctx.shot("scan-confirmation")
                                    importer.last_result = nil
                                    importer.scan_confirmation.buttons[1][2].callback()
                                    ctx.shot("scan-progress")
                                    waitImport(importer, function(scanned)
                                        assert(scanned.added == 6 and scanned.duplicates == 1)
                                        assert(scanned.skipped >= 4 and #home.item_table == 8)
                                        results.checks.recursive_scan_and_dedup = true
                                        inspect(home, "scanned-library")
                                        importer.last_result = nil
                                        home.on_rescan()
                                        importer.scan_confirmation.buttons[1][2].callback()
                                        waitImport(importer, function(again)
                                            assert(again.added == 0 and again.duplicates == 7)
                                            results.checks.rescan_dedup = true
                                            home.query = "海边"; home:rebuild()
                                            assert(#home.filtered == 1)
                                            inspect(home, "search-result")
                                            home.query = ""; home:rebuild()
                                            home:setStatus("complete")
                                            waitStatus(function()
                                                assert(#home.filtered == 0)
                                                inspect(home, "finished-empty")
                                                home:setStatus("complete")
                                                home.list_mode = true; home:rebuild()
                                                inspect(home, "library-list")
                                                home.list_mode = false; home:rebuild()
                                                ctx.step(function()
                                                    inspect(home, "final-library-grid")
                                                    results.checks.layout_search_and_status = true
                                                    navigation(function() management(importer, scan, second, function() ctx.selectBook(ctx.fm, function(reader)
                                                        reader.rolling:onGotoPage(3)
                                                        reader.bookmark:onToggleBookmark()
                                                        reader:onHome()
                                                        ctx.step(function()
                                                            local fm = assert(FileManager.instance)
                                                            home = assert(fm.anxui.home)
                                                            assert(home.source == "library" and #home.item_table == 8)
                                                            inspect(home, "reader-return")
                                                            results.checks.reader_return = true
                                                            assert(home.controls.continue, "continue-reading card missing")
                                                            click(home.controls.continue, function()
                                                                local resumed = assert(require("apps/reader/readerui").instance)
                                                                assert(resumed:getCurrentPage() == 3 and #resumed.annotation.annotations == 1)
                                                                results.checks.continue_reading_card = true
                                                                resumed:onHome()
                                                                ctx.step(function()
                                                                    results.passed = true; save(); ctx.finish()
                                                                end)
                                                            end)
                                                        end)
                                                    end) end) end)
                                                end)
                                            end)
                                        end)
                                    end)
                                end)
                            end)
                        end)
                    end)
                    end)
                end)
            end)
        end)
    end)
end
