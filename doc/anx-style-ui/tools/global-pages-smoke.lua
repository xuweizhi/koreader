-- Exercise shared lists/dashboards with native focus, paging and window resize.
return function(ctx)
    local UIManager,Screen=require("ui/uimanager"),require("device").screen
    local plugin=ctx.fm.anxui
    local width,height=Screen:getWidth(),Screen:getHeight()
    local thread,checks=nil,{geometry={},checks={}}
    local function resume(...)
        local ok,err=coroutine.resume(thread,...);assert(ok,err)
    end
    local function await(register)
        register(function(...) resume(...) end);return coroutine.yield()
    end
    local function input(actions) await(function(done) ctx.input(actions,done) end) end
    local function key(value) input({{kind="key",value=value}}) end
    local function resize(w,h) input({{kind="resize",width=w,height=h}}) end
    local function settle() await(function(done) ctx.step(done) end) end
    local function inspect(view,label)
        UIManager:forceRePaint()
        local rectangles={}
        for _,row in ipairs(view.layout) do
            for _,widget in ipairs(row) do
                local d=assert(widget.dimen)
                assert(d.x>=0 and d.y>=0 and d.x+d.w<=Screen:getWidth()+1 and d.y+d.h<=Screen:getHeight()+1,label..": offscreen control")
                assert(d.w>=Screen:scaleByDPI(48) and d.h>=Screen:scaleByDPI(48),label..": small control")
                for _,other in ipairs(rectangles) do
                    local intersect=math.min(d.x+d.w,other.x+other.w)>math.max(d.x,other.x)+1
                        and math.min(d.y+d.h,other.y+other.h)>math.max(d.y,other.y)+1
                    assert(not intersect,label..": overlapping controls")
                end
                rectangles[#rectangles+1]={x=d.x,y=d.y,w=d.w,h=d.h}
            end
        end
        for _,card in ipairs(view.cards or {}) do
            local frame=card:getSize()
            local content=card[1][1]:getSize()
            assert(content.w<=frame.w+1 and content.h<=frame.h+1,label..": statistics text exceeds card")
        end
        checks.geometry[label]=rectangles;ctx.shot(label)
    end
    local function focus(view,widget)
        local x,y=view:getFocusableWidgetXY(widget);assert(x and y)
        view:moveFocusTo(x,y,require("ui/widget/focusmanager").FORCED_FOCUS)
    end
    thread=coroutine.create(function()
        plugin:showSettings();local view=assert(plugin.settings_view)
        inspect(view,"settings-normal")
        local row
        for __=1,10 do
            for _,item in ipairs(view.rows) do if item.entry.id=="device" then row=item end end
            if row then break end
            key("Page_Down")
        end
        focus(view,assert(row));view:rebuild();settle()
        assert(view:getFocusItem().entry.id=="device","list rebuild lost focused setting")
        key("Return");assert(plugin.settings_view.title=="Device")
        key("Escape");assert(plugin.settings_view.title=="Settings","Back must return to setting groups")
        view=plugin.settings_view
        resize(640,220);inspect(view,"settings-short-landscape")
        assert(view.page_count>1)
        local page=view.page;key("Page_Down");assert(view.page==page+1)
        key("Page_Up");assert(view.page==page)
        key("Escape");assert(not plugin.settings_view)
        resize(width,height)
        checks.checks.settings_paging_focus_parent_back=true

        plugin:showStatistics();local dashboard=assert(plugin.statistics_view)
        inspect(dashboard,"statistics-normal")
        resize(640,220);inspect(dashboard,"statistics-short-landscape")
        if #dashboard.metrics>3 then
            assert(dashboard.page_count>1)
            key("Page_Down");assert(dashboard.page==2)
            inspect(dashboard,"statistics-short-second-page")
            key("Page_Up");assert(dashboard.page==1)
        end
        key("Escape");assert(not plugin.statistics_view)
        resize(width,height)
        checks.checks.statistics_cards_fit_and_page=true

        plugin:showNoteLibrary();view=assert(plugin.notes_library)
        inspect(view,"notes-normal")
        resize(640,220);inspect(view,"notes-short-landscape")
        view:showFilters();local menu=assert(view.filter_menu)
        menu.item_table[4].callback();assert(view.filter=="bookmarks")
        view:showFilters();view.filter_menu.item_table[1].callback()
        key("Escape");assert(not plugin.notes_library)
        resize(width,height)
        checks.checks.notes_compact_filter_and_back=true

        local reader=await(function(done) ctx.selectBook(ctx.fm,done) end)
        plugin=reader.anxui
        reader.bookmark:onToggleBookmark()
        plugin:showReaderList("notes");view=assert(plugin.reader_list)
        inspect(view,"reader-notes-normal")
        resize(640,220);inspect(view,"reader-notes-short-landscape")
        assert(#view.rows>0)
        focus(view,view.rows[1]);local entry=view:getFocusItem().entry
        view:rebuild();assert(view:getFocusItem().entry==entry)
        key("Escape");assert(not plugin.reader_list)
        resize(width,height)
        plugin:showReaderList("toc");view=assert(plugin.reader_list)
        view:showSearch();local dialog=assert(view.search_dialog)
        dialog:setInputText("未提交的章节搜索");dialog._input_widget:moveCursorToCharPos(4)
        local cursor=dialog._input_widget.charpos
        resize(640,360)
        assert(view.search_dialog==dialog and dialog:getInputText()=="未提交的章节搜索")
        assert(dialog._input_widget.charpos==cursor,"search cursor lost on rotation")
        local frame=dialog.dialog_frame.dimen
        assert(frame.x>=0 and frame.y>=0 and frame.x+frame.w<=640 and frame.y+frame.h<=360,"rotated search dialog outside screen")
        ctx.shot("reader-search-rotated-draft")
        key("Escape");if view.search_dialog then key("Escape") end
        assert(not view.search_dialog and view.query=="","cancel search modified list")
        resize(640,220);inspect(view,"contents-short-landscape")
        if view.page_count>1 then local toc_page=view.page;key("Page_Down");assert(view.page==toc_page+1) end
        key("Escape");assert(not plugin.reader_list)
        resize(width,height)
        checks.checks.reader_list_focus_search_rotation_paging=true
        checks.passed=true
        local file=assert(io.open(ctx.evidence.."/global-pages-checks.json","w"))
        file:write(require("json").encode(checks));file:close()
        ctx.finish()
    end)
    resume()
end
