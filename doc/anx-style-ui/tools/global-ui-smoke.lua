-- Native X11 input against isolated books/settings: global shelf/import paths.
return function(ctx)
    local UIManager, Screen = require("ui/uimanager"), require("device").screen
    local plugin, home = ctx.fm.anxui, assert(ctx.fm.anxui.home)
    local original_width, original_height = Screen:getWidth(), Screen:getHeight()
    local result, thread = {checks={}, geometry={}}, nil
    local function save()
        local file = assert(io.open(ctx.evidence .. "/global-ui-checks.json", "w"))
        file:write(require("json").encode(result)); file:close()
    end
    local function resume(...)
        local ok, err = coroutine.resume(thread, ...); assert(ok, err)
    end
    local function await(register)
        register(function(...) resume(...) end); return coroutine.yield()
    end
    local function input(actions) await(function(done) ctx.input(actions, done) end) end
    local function settle() await(function(done) ctx.step(done) end) end
    local function key(value) input({{kind="key",value=value}}) end
    local function resize(w, h) input({{kind="resize",width=w,height=h}}) end
    local function tap(widget)
        UIManager:forceRePaint()
        local d = assert(widget.dimen)
        input({{kind="click",x=math.floor(d.x+d.w/2),y=math.floor(d.y+d.h/2)}})
    end
    local function button(widget, text)
        if widget.text == text and type(widget.callback) == "function" then return widget end
        for _, child in ipairs(widget) do
            local found = button(child, text); if found then return found end
        end
    end
    local function focus(view, target)
        local x, y = view:getFocusableWidgetXY(target)
        assert(x and y, "target not in focus layout")
        local control_id, file, more
        if view == home then
            for id, widget in pairs(home.controls) do if widget == target then control_id=id end end
            for _, card in ipairs(home.cards) do
                if target == card or target == card.more_button then
                    file, more = card.item.file, target == card.more_button
                end
            end
        end
        for __ = 1, 40 do
            if control_id then target = home.controls[control_id] end
            if file then
                for _, card in ipairs(home.cards) do
                    if card.item.file == file then target = more and card.more_button or card end
                end
            end
            x, y = view:getFocusableWidgetXY(target)
            assert(x and y, "focused target disappeared")
            if view:getFocusItem() == target then return end
            local selected = view.selected
            key(selected.y < y and "Down" or selected.y > y and "Up" or selected.x < x and "Right" or "Left")
        end
        error("hardware focus could not reach target")
    end
    local function inspect(label, widgets)
        UIManager:forceRePaint()
        local rectangles = {}
        for _, widget in ipairs(widgets) do
            local d = assert(widget.dimen)
            rectangles[#rectangles+1] = {x=d.x,y=d.y,w=d.w,h=d.h,text=widget.text}
        end
        result.geometry[label] = rectangles
        ctx.shot(label); save()
        for index, widget in ipairs(widgets) do
            local d = widget.dimen
            local detail = string.format("%s [%d: %s] x=%d y=%d w=%d h=%d min=%d", label,index,
                widget.text or "",d.x,d.y,d.w,d.h,Screen:scaleByDPI(48))
            assert(d.x >= -1 and d.y >= -1 and d.x+d.w <= Screen:getWidth()+1
                and d.y+d.h <= Screen:getHeight()+1, detail .. ": clipped control")
            assert(d.w >= Screen:scaleByDPI(48) and d.h >= Screen:scaleByDPI(48), detail .. ": small target")
        end
    end
    local function pickerRow(picker, file)
        for _, row in ipairs(picker.item_group) do
            if row.entry and row.entry.path == file then return row end
        end
    end
    local function inspectShelf(label)
        local widgets, parents = {}, {}
        for _, card in ipairs(home.cards) do parents[card.more_button]=card end
        for _, row in ipairs(home.layout) do
            for _, widget in ipairs(row) do widgets[#widgets+1]=widget end
        end
        inspect(label, widgets)
        for i, widget in ipairs(widgets) do
            local d = widget.dimen
            for j=1,i-1 do
                local other = widgets[j]
                if parents[widget] ~= other and parents[other] ~= widget then
                    local o = other.dimen
                    assert(math.min(d.x+d.w,o.x+o.w) <= math.max(d.x,o.x)+1
                        or math.min(d.y+d.h,o.y+o.h) <= math.max(d.y,o.y)+1, label .. ": overlapping controls")
                end
            end
        end
    end
    thread = coroutine.create(function()
        focus(home, home.controls.add)
        home:rebuild(); settle()
        assert(home:getFocusItem() == home.controls.add, "rebuild reset toolbar focus")
        resize(640, 360)
        assert(home:getFocusItem() == home.controls.add, "rotation reset toolbar focus")
        key("Return"); assert(home.options_menu)
        key("Escape"); assert(not home.options_menu and not home.closed)
        local card = assert(home.cards[1])
        local file = card.item.file
        focus(home, card.more_button)
        home:rebuild(); settle()
        assert(home:focusTarget().file == file and home:focusTarget().more, "rebuild reset more-button focus")
        resize(original_width, original_height)
        assert(home:focusTarget().file == file and home:focusTarget().more, "rotation reset book focus")
        key("Return"); assert(plugin.book_actions, "focused more button did not open actions")
        key("Escape"); assert(not plugin.book_actions and not home.closed)
        result.checks.shelf_focus_rebuild_rotation = true
        inspect("shelf-restored-focus", {home.controls.search,home.controls.add,home.controls.sources,home.controls.sort})

        tap(home.controls.search)
        local search = assert(home.search_dialog)
        input({{kind="type",value="rotation"}})
        local draft = search:getInputText()
        assert(draft ~= "")
        resize(640, 360)
        assert(home.search_dialog == search and search:getInputText() == draft, "rotation discarded search draft")
        local frame = search.dialog_frame.dimen
        assert(frame.x >= 0 and frame.y >= 0 and frame.x+frame.w <= Screen:getWidth()+1
            and frame.y+frame.h <= Screen:getHeight()+1, "search form outside resized screen")
        ctx.shot("search-landscape-draft")
        key("Escape"); if home.search_dialog then key("Escape") end
        assert(not home.search_dialog and home.query == "", "cancel changed search query or retained dialog")
        tap(home.controls.search); assert(home.search_dialog)
        key("Escape"); if home.search_dialog then key("Escape") end
        resize(original_width, original_height)
        result.checks.search_rotation_draft_back_reopen = true; save()

        local importer = plugin:libraryImporter()
        importer:choose(false); settle()
        local picker = assert(importer.picker)
        local scan = ctx.book:match("^(.*)/[^/]+$") .. "/scan"
        picker:changeToPath(scan); settle()
        resize(640, 360)
        assert(picker.perpage >= 2, "landscape picker wastes available rows")
        local target
        for _, item in ipairs(picker.item_table) do if item.is_file then target = item.path end end
        assert(target)
        for __ = 1, 20 do
            if pickerRow(picker,target) then break end
            key("Page_Down")
        end
        local row = assert(pickerRow(picker,target))
        focus(picker, row); key("Return")
        assert(picker.ui.selected_files[target] and picker:getFocusItem().entry.path == target,
            "selecting ebook reset focused row")
        resize(original_width, original_height)
        assert(picker.ui.selected_files[target] and picker:getFocusItem().entry.path == target,
            "rotation lost selected row/page")
        local selected_anchor = picker.path_items[picker.path]
        focus(picker, picker.select_all_button); key("Return")
        assert(picker:getFocusItem() == picker.select_all_button, "select-all reset footer focus")
        assert(picker.path_items[picker.path] == selected_anchor, "select-all discarded the focused file anchor")
        local count = 0; for __ in pairs(picker.ui.selected_files) do count=count+1 end
        assert(count == 7)
        resize(640, 360)
        assert(picker:getFocusItem() == picker.select_all_button, "rotation lost footer focus")
        inspect("import-landscape-density", {picker.select_all_button,picker.clear_selection_button,picker.confirm_button})
        for _, control in ipairs({picker.select_all_button,picker.clear_selection_button,picker.confirm_button}) do
            local occurrences = 0
            for _, controls in ipairs(picker.layout) do
                for _, widget in ipairs(controls) do if widget == control then occurrences=occurrences+1 end end
            end
            assert(occurrences == 1, "duplicate footer focus entry")
        end
        resize(640,220)
        assert(picker.compact_footer and picker:getFocusItem() == picker.select_all_button)
        local short_controls = {picker.select_all_button,picker.clear_selection_button,picker.confirm_button}
        local visible_files = 0
        for _, item_row in ipairs(picker.item_group) do
            if item_row.entry and item_row.entry.is_file then
                visible_files=visible_files+1;short_controls[#short_controls+1]=item_row
            end
        end
        assert(visible_files > 0, "short picker has no full ebook row")
        result.short_picker_metrics = {available_height=picker.available_height,perpage=picker.perpage,
            item_height=picker.item_dimen.h,footer_height=picker.footer_height,
            title_height=picker.title_bar:getHeight(),page_info_height=picker.page_info:getSize().h,
            minimum=Screen:scaleByDPI(48)}
        inspect("import-short-landscape",short_controls)
        count=0;for __ in pairs(picker.ui.selected_files) do count=count+1 end
        assert(count==7, "short landscape lost selected files")
        resize(640,360)
        key("Escape"); assert(not importer.picker and not importer.operation)
        result.checks.import_density_selection_page_focus_back = true; save()

        local roots, lfs = {}, require("libs/libkoreader-lfs")
        local base = scan .. "/long-path-scan-fixtures"
        assert(lfs.mkdir(base))
        for index=1,20 do
            local root = base .. "/" .. string.rep("long-folder-name-", 8) .. tostring(index)
            assert(lfs.mkdir(root)); roots[#roots+1] = root
        end
        importer:confirmScan(roots); settle()
        local confirm = assert(importer.scan_confirmation)
        inspect("scan-many-long-folders", {button(confirm,plugin.translate("Cancel")),
            button(confirm,plugin.translate("Start scan")),button(confirm,plugin.translate("View folders"))})
        tap(button(confirm,plugin.translate("View folders")))
        local paths = assert(importer.scan_paths_menu)
        assert(#paths.item_table == #roots and paths.item_table[20].text == roots[20], "full paths unavailable")
        key("Page_Down"); assert(paths.page > 1)
        ctx.shot("scan-paths-paged")
        key("Escape"); assert(UIManager:isWidgetShown(confirm))
        resize(original_width, original_height)
        inspect("scan-confirmation-restored", {button(confirm,plugin.translate("Cancel")),
            button(confirm,plugin.translate("Start scan")),button(confirm,plugin.translate("View folders"))})
        key("Escape"); assert(not importer.scan_confirmation and not importer.operation)
        result.checks.scan_long_paths_confirmation_rotation_cancel = true
        resize(640,220)
        assert(home.compact)
        inspectShelf("shelf-short-landscape")
        tap(home.controls.sort)
        local options = assert(home.options_menu)
        local settings
        for __=1,20 do
            for _, item_row in ipairs(options.item_group) do
                if item_row.entry and item_row.entry.text == plugin.translate("Settings") then settings=item_row end
            end
            if settings then break end
            key("Page_Down")
        end
        assert(settings, "compact navigation missing settings")
        inspect("shelf-short-menu-settings", {settings})
        tap(settings); assert(plugin.settings_view)
        key("Escape"); assert(not plugin.settings_view and not home.closed)
        home:selectFile(home.cards[1].item.file); settle()
        inspectShelf("shelf-short-selection")
        assert(#home:selectedFiles()==1)
        key("Escape"); assert(not home.selection_mode and not home.closed)
        resize(original_width,original_height)
        result.checks.shelf_short_layout_and_menu_navigation=true
        result.passed = true; save()
        dofile("/data/koreader/doc/anx-style-ui/tools/global-pages-smoke.lua")(ctx)
    end)
    resume()
end
