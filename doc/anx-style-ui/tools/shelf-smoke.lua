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
        ctx.shot("file-picker")
        chooseRow(picker, ctx.book, function()
            assert(picker.ui.selected_files[ctx.book])
            chooseRow(picker, scan, function()
                chooseRow(picker, second, function()
                    assert(picker.ui.selected_files[ctx.book] and picker.ui.selected_files[second])
                    ctx.shot("multi-selection")
                    click(picker.title_bar.left_button, function()
                        waitImport(importer, function(stats)
                            assert(stats.added == 2 and #home.item_table == 2)
                            results.checks.manual_multiselect = true
                            inspect(home, "manual-import-result")
                            click(home.controls.add, function()
                                home.options_menu.item_table[2].callback()
                                local folder_picker = assert(importer.picker)
                                assert(folder_picker.path == scan)
                                click(folder_picker.title_bar.left_button, function()
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
                                                    navigation(function() ctx.selectBook(ctx.fm, function(reader)
                                                        reader.rolling:onGotoPage(3)
                                                        reader.bookmark:onToggleBookmark()
                                                        reader:onHome()
                                                        ctx.step(function()
                                                            local fm = assert(FileManager.instance)
                                                            home = assert(fm.anxui.home)
                                                            assert(home.source == "library" and #home.item_table == 8)
                                                            inspect(home, "reader-return")
                                                            results.checks.reader_return = true
                                                            results.passed = true; save(); ctx.finish()
                                                        end)
                                                    end) end)
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
