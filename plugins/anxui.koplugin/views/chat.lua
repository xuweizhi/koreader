local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Chat = FocusManager:extend{name="anxui_ai_chat", covers_fullscreen=true, stop_events_propagation=true}

local errors = {
    busy="A reply is already being generated.",
    configure_ai="Set an API address and model first.", storage_error="AI data could not be saved or read. Existing files were kept.",
    input_limit="Message too long. Please shorten it.", conversation_limit="Start a new conversation to continue (10 turns per conversation).",
    context_empty="No extractable text here. Scanned pages need OCR.", context_error="Could not read this chapter.",
    network_error="Connection failed. Check the address, network and certificate.", timeout="The request timed out. You can retry.",
    response_error="The service returned an invalid response. Check the model and API settings.",
    invalid_stream="The response ended unexpectedly. You can retry.",
    tool_limit="Reading tool limit reached. Ask a more specific question.",
    index_limit="The index holds up to 50 books. Remove an old index first.",
}

function Chat:init()
    self.key_events.Close = {{Device.input.group.Back}}
    self.session = self.session_class.new(self.store, self.protocol, self.transport, self.new_scope, function() self:refresh() end)
    self.session.tools=self.readingtools.new(self)
    if self.reader_ui then self.session.book={file=self.reader_ui.document.file,title=self.reader_ui.doc_props and self.reader_ui.doc_props.title or ""} end
    self.session:fresh(self.context)
    self:rebuild()
end

function Chat:refresh()
    if self.closed or self.refresh_task then return end
    self.refresh_task = self.scope:later(.2, function()
        self.refresh_task = nil
        self:rebuild()
    end)
end

function Chat:message(reason)
    if not reason or reason == "stale_session" or reason == "empty_input" or self.closed then return end
    UIManager:show(self.scope:own(require("ui/widget/infomessage"):new{text=self.translate(errors[reason] or reason)}))
end

function Chat:rebuild()
    if self.closed then return end
    local old_scroll=self.log
    local keep_position=old_scroll and self.session.running and old_scroll._is_scrollable
        and old_scroll._scroll_offset_y < old_scroll._max_scroll_offset_y - self.theme.s(24)
    local scroll_offset=keep_position and old_scroll._scroll_offset_y
    if self[1] then self:clear() end
    local t, W, _ = self.theme, self.widgets, self.translate
    local width, height = Device.screen:getWidth(), Device.screen:getHeight()
    local margin, gap, touch = t.s(16), t.s(8), t.touch
    local inner = width - 2 * margin
    self.dimen = Geom:new{w=width,h=height}
    local body = OverlapGroup:new{dimen=self.dimen:copy(),allow_mirroring=false}
    local function place(widget,x,y) widget.overlap_offset={x,y}; body[#body+1]=widget; return widget end
    local function button(text,w,callback) return W.button(text,w,t,self.scope:guard(callback),{parent=self}) end
    self.buttons = {}
    self.buttons.settings = button(_("Model"),t.s(64),function() self:showConfig() end)
    self.buttons.history = button(_("History"),t.s(80),function() self:showHistory() end)
    self.buttons.close = button("×",touch,function() self:onClose() end)
    place(W.text("AI",t,t.title,inner-t.s(144)-touch-3*gap,true),margin,margin)
    place(self.buttons.history,width-margin-touch-2*gap-t.s(144),margin)
    place(self.buttons.settings,width-margin-touch-gap-t.s(64),margin)
    place(self.buttons.close,width-margin-touch,margin)
    self.layout={{self.buttons.history,self.buttons.settings,self.buttons.close}}
    local config = self.store:config()
    local label = config and config.model ~= "" and config.model or _("Model not configured")
    place(W.text(label,t,12*t.text_scale,inner,false,true),margin,margin+touch+gap)
    local context = self.session.data.context
    local kinds={selection="Selected text",page="Page excerpt",chapter="Chapter excerpt",notes="Reading notes",search="Search results",collection="Across books"}
    local caption = context and ((_(kinds[context.kind] or "Attached text"))
        .. ": " .. (context.chapter or context.title or "") .. (context.truncated and " · " .. _("Truncated") or "")) or _("General conversation")
    local top = margin+touch+gap+t.s(24*t.text_scale)
    self.buttons.context = button(self.context_loading and _("Preparing context…") or caption,inner,function() self:showContext() end)
    place(self.buttons.context,margin,top); self.layout[#self.layout+1]={self.buttons.context}
    top = top+touch+gap
    local bottom = height-margin-touch
    local quick_y = bottom-touch-gap
    local status_y = quick_y-t.s(24*t.text_scale)
    local log_height = math.max(t.s(40),status_y-top-gap)
    local messages = VerticalGroup:new{align="left"}
    self.message_buttons={}
    for index, entry in ipairs(self.session.data.messages) do
        local human = entry.role == "user"
        local bg = human and t.selected or t.surface
        local value = entry.content ~= "" and entry.content or (entry.status == "streaming" and _("Thinking…") or _("No answer received"))
        local preview=self.protocol.clip(value,1800)
        local text_widget
        if not human and entry.status~="streaming" then
            local ok,widget=pcall(self.markdown.preview,preview,inner-t.s(48),t.s(14*t.text_scale))
            if ok then text_widget=widget end
        end
        text_widget=text_widget or TextBoxWidget:new{text=preview,face=W.face(t,14*t.text_scale),
            width=inner-t.s(48),fgcolor=t.ink,bgcolor=bg}
        local more=button("⋯",touch,function() self:messageActions(index) end)
        self.message_buttons[index]=more
        local author_label=W.text(human and _("You") or "AI",t,12*t.text_scale,inner-t.s(48)-touch,true,true)
        local content = VerticalGroup:new{align="left",
            require("ui/widget/horizontalgroup"):new{align="center",author_label,
                require("ui/widget/horizontalspan"):new{width=math.max(0,inner-t.s(48)-touch-author_label:getSize().w)},more},
            VerticalSpan:new{width=t.s(4)},
            text_widget,
        }
        if #preview<#value then content[#content+1]=W.text(_("Open message to read more"),t,12*t.text_scale,inner-t.s(48),false,true) end
        local bubble = FrameContainer:new{padding=t.s(10),bordersize=0,radius=t.s(12),background=bg,content}
        local align = require(human and "ui/widget/container/rightcontainer" or "ui/widget/container/leftcontainer")
        messages[#messages+1]=align:new{dimen=Geom:new{w=inner-t.s(24),h=bubble:getSize().h},bubble}
        messages[#messages+1]=VerticalSpan:new{width=gap}
    end
    if #self.session.data.messages == 0 then
        messages[#messages+1]=TextBoxWidget:new{
            text=_("Ask a question, or attach a chapter or selected text. Only the displayed context and this conversation are sent when you press Send."),
            face=W.face(t,14*t.text_scale),width=inner-t.s(16),fgcolor=t.muted,bgcolor=t.background,
        }
    end
    local scroll = require("ui/widget/container/scrollablecontainer"):new{dimen=Geom:new{w=inner,h=log_height},messages}
    self.log = scroll
    place(scroll,margin,top)
    -- New output follows the last message; scrolling is otherwise handled by
    -- the native container, with no timer while the conversation is idle.
    scroll:initState()
    if scroll._is_scrollable then
        if scroll_offset then scroll._scroll_offset_y=math.min(scroll_offset,scroll._max_scroll_offset_y);scroll:_updateScrollBars()
        else scroll:scrollToRatio(nil,1) end
    end
    local status = self.session.using_tool and (_("Reading tool")..": "..self.session.using_tool)
        or self.session.running and _("Generating…") or self.session.data.tools_enabled and _("Reading tools enabled") or ""
    local last = self.session.data.messages[#self.session.data.messages]
    if not self.session.running and last and last.status == "cancelled" then status=_("Stopped; partial answer saved") end
    if last and last.limited then status=_("Answer reached the output limit") end
    if self.session.error then
        status = self.session.http_code and ("HTTP " .. self.session.http_code .. " · " .. _("Check the API settings or retry"))
            or _(errors[self.session.error] or "Request failed")
    end
    place(W.text(status,t,12*t.text_scale,inner,false,true),margin,status_y)
    local quick_width=math.floor((inner-2*gap)/3)
    local row={}
    local actions={{"Explain",function() self:send(_("Please explain the supplied passage.")) end},
        {"Translate",function() self:send(_("Translate the supplied passage into English.")) end},
        {"Summarize",function() self:send(_("Summarize the supplied passage.")) end}}
    for index, action in ipairs(actions) do
        local control=button(_(action[1]),quick_width,function()
            if self.context_loading then return end
            if not self.session.data.context then self:showContext(); return end
            action[2]()
        end)
        place(control,margin+(index-1)*(quick_width+gap),quick_y);row[#row+1]=control
        self.buttons[action[1]]=control
    end
    self.layout[#self.layout+1]=row
    self.buttons.compose=button(_("Write a message…"),inner-2*t.s(58)-2*gap,function() self:compose() end)
    self.buttons.retry=button(_("Retry"),t.s(58),function()
        if self.context_loading then return end
        local ok,err=self.session:retry(); if not ok then self:message(err) end
    end)
    self.buttons.stop=button((self.session.running or self.context_loading) and _("Stop") or _("New"),t.s(58),function()
        if self.session.running then self.session:stop()
        elseif self.context_loading then self:cancelContext();self:refresh()
        else self.session:fresh() end
    end)
    place(self.buttons.compose,margin,bottom)
    place(self.buttons.retry,width-margin-2*t.s(58)-gap,bottom)
    place(self.buttons.stop,width-margin-t.s(58),bottom)
    self.layout[#self.layout+1]={self.buttons.compose,self.buttons.retry,self.buttons.stop}
    self[1]=FrameContainer:new{padding=0,bordersize=0,background=t.background,body}
    self.selected={x=1,y=1};self:refocusWidget(); UIManager:setDirty(self,"ui")
end

function Chat:send(text,options)
    if self.context_loading then return end
    local ok, reason = self.session:send(text,options)
    if not ok then
        if reason == "configure_ai" then self:showConfig() else self:message(reason) end
    end
    return ok, reason
end

function Chat:compose(initial, edit)
    if self.session.running or self.context_loading then return end
    local dialog
    dialog=require("ui/widget/inputdialog"):new{title=self.translate(edit and "Edit and resend" or "Message"),input=initial or "",allow_newline=true,
        buttons={{{text=self.translate("Cancel"),callback=function() UIManager:close(dialog) end},
            {text=self.translate("Send"),is_enter_default=true,callback=self.scope:guard(function()
                if not UIManager:isWidgetShown(dialog) then return end
                local text=dialog:getInputText();UIManager:close(dialog)
                if edit then local ok,err=self.session:editLast(text);if not ok then self:message(err) end
                else self:send(text) end
            end)}}}}
    self.compose_dialog=dialog;UIManager:show(self.scope:own(dialog));dialog:onShowKeyboard()
end

function Chat:messageActions(index)
    local entry=self.session.data.messages[index]
    if not entry then return end
    local _,menu=self.translate,nil
    local items={{text=_("Read full message"),callback=self.scope:guard(function()
        if not UIManager:isWidgetShown(menu) then return end
        UIManager:close(menu)
        local html=entry.role=="assistant"
        local viewer=require("ui/widget/textviewer"):new{title=html and "AI" or _("You"),
            text=html and self.markdown.document(entry,_) or entry.content,text_format=html and "html" or "txt"}
        self.message_viewer=viewer;UIManager:show(self.scope:own(viewer))
    end)},
    {text=_("Copy message"),callback=self.scope:guard(function()
        if not UIManager:isWidgetShown(menu) then return end
        UIManager:close(menu);Device.input.setClipboardText(entry.content);self:message("Copied")
    end)}}
    if entry.tool_steps then
        items[#items+1]={text=_("Reading tool history"),callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(menu) then return end
            UIManager:close(menu)
            local lines={}
            for __,step in ipairs(entry.tool_steps) do lines[#lines+1]=step.name.." · ".._(step.status) end
            UIManager:show(self.scope:own(require("ui/widget/textviewer"):new{title=_("Reading tool history"),text=table.concat(lines,"\n")}))
        end)}
    end
    if entry.role=="user" and index==#self.session.data.messages-1 and not self.session.running then
        items[#items+1]={text=_("Edit and resend"),callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(menu) then return end
            UIManager:close(menu);self:compose(entry.content,true)
        end)}
    end
    menu=require("ui/widget/menu"):new{title=_("Message actions"),item_table=items}
    self.message_menu=menu;UIManager:show(self.scope:own(menu))
end

function Chat:showConfig() self.settings_ui.show(self) end

function Chat:showHistory(query)
    local history, err=self.store:history()
    if not history then return self:message(err) end
    local menu, items=nil,{}
    self.history_query=query or self.history_query or ""
    items[#items+1]={text=self.translate("Search conversations")..(self.history_query~="" and ": "..self.history_query or ""),callback=self.scope:guard(function()
        if not UIManager:isWidgetShown(menu) then return end
        UIManager:close(menu)
        local input
        input=require("ui/widget/inputdialog"):new{title=self.translate("Search conversations"),input=self.history_query,buttons={
            {{text=self.translate("Cancel"),callback=function() UIManager:close(input) end},
            {text=self.translate("Search"),callback=self.scope:guard(function()
                if not UIManager:isWidgetShown(input) then return end
                local text=input:getInputText();UIManager:close(input);self:showHistory(text)
            end)}}}}
        self.history_search=input;UIManager:show(self.scope:own(input));input:onShowKeyboard()
    end)}
    if self.reader_ui then
        items[#items+1]={text=self.translate(self.history_all and "Show this book only" or "Show all books"),callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(menu) then return end
            UIManager:close(menu);self.history_all=not self.history_all;self:showHistory()
        end)}
    end
    for _, data in ipairs(history) do
        local matches=self.history_query=="" or data.title:lower():find(self.history_query:lower(),1,true)
        if not matches then
            for _,entry in ipairs(data.messages) do
                if entry.content:lower():find(self.history_query:lower(),1,true) then matches=true;break end
            end
        end
        local file=data.book and data.book.file or data.context and data.context.file
        if self.reader_ui and not self.history_all and file~=self.reader_ui.document.file then matches=false end
        if matches then
        items[#items+1]={text=data.title,callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(menu) then return end
            UIManager:close(menu);self:cancelContext();self.session:load(data)
        end),hold_callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(menu) then return end
            UIManager:close(menu);self:historyActions(data)
        end)}
        end
    end
    menu=require("ui/widget/menu"):new{title=self.translate("History · latest 10 conversations"),item_table=items}
    self.history_menu=menu;UIManager:show(self.scope:own(menu))
end

function Chat:historyActions(data)
    local _,menu=self.translate,nil
    menu=require("ui/widget/menu"):new{title=data.title,item_table={
        {text=_("Rename"),callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(menu) then return end
            UIManager:close(menu)
            local input
            input=require("ui/widget/inputdialog"):new{title=_("Conversation title"),input=data.title,buttons={
                {{text=_("Cancel"),callback=function() UIManager:close(input) end},
                {text=_("Save"),callback=self.scope:guard(function()
                    if not UIManager:isWidgetShown(input) then return end
                    local title=input:getInputText():match("^%s*(.-)%s*$")
                    if not self.store:renameSession(data.id,title) then return self:message("storage_error") end
                    if self.session.data.id==data.id then self.session.data.title=title end
                    UIManager:close(input);self:showHistory()
                end)}}}}
            self.rename_dialog=input;UIManager:show(self.scope:own(input));input:onShowKeyboard()
        end)},
        {text=_("Delete"),callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(menu) then return end
            UIManager:close(menu)
            UIManager:show(self.scope:own(require("ui/widget/confirmbox"):new{text=_("Delete this conversation?"),
                ok_callback=self.scope:guard(function()
                    if not self.store:deleteSession(data.id) then return self:message("storage_error") end
                    if self.session.data.id==data.id then self:cancelContext();self.session:fresh() end
                    self:showHistory()
                end)}))
        end)},
    }}
    self.history_actions=menu;UIManager:show(self.scope:own(menu))
end

function Chat:cancelContext()
    if self.context_scope then self.context_scope:close();self.context_scope=nil end
    self.context_loading=false
end

function Chat:showContext()
    if self.session.running or self.context_loading then return end
    local _, menu=self.translate,nil
    local items={{text=_("General conversation"),callback=self.scope:guard(function() UIManager:close(menu);self:cancelContext();self.session:fresh() end)}}
    if self.reader_ui then
        items[#items+1]={text=_("Use current chapter"),callback=self.scope:guard(function()
            UIManager:close(menu);self:loadChapter()
        end)}
        items[#items+1]={text=_("Choose chapter"),callback=self.scope:guard(function() UIManager:close(menu);self:chooseChapter() end)}
        items[#items+1]={text=_("Choose reading notes"),callback=self.scope:guard(function() UIManager:close(menu);self:chooseNotes() end)}
        items[#items+1]={text=_("Search this book"),callback=self.scope:guard(function() UIManager:close(menu);self:searchBook() end)}
        items[#items+1]={text=_("Index this book for cross-book search"),callback=self.scope:guard(function() UIManager:close(menu);self:buildIndex() end)}
    end
    items[#items+1]={text=_("Search indexed books"),callback=self.scope:guard(function() UIManager:close(menu);self:searchIndex() end)}
    items[#items+1]={text=_("Manage book indexes"),callback=self.scope:guard(function() UIManager:close(menu);self:showIndexes() end)}
    items[#items+1]={text=_(self.session.data.tools_enabled and "Disable reading tools" or "Enable reading tools"),callback=self.scope:guard(function()
        UIManager:close(menu)
        if self.session.data.tools_enabled then self.session.data.tools_enabled=false;self.session:save();self:refresh();return end
        UIManager:show(self.scope:own(require("ui/widget/confirmbox"):new{
            text=_("Allow AI to search indexed books and read the current book's chapters and notes when you send a message? Retrieved excerpts are sent to your model service. Up to 3 tool rounds per question."),
            ok_callback=self.scope:guard(function() self.session.data.tools_enabled=true;self.session:save();self:refresh() end)}))
    end)}
    if self.session.data.context then
        items[#items+1]={text=_("Reading report / mind map / parallel translation"),callback=self.scope:guard(function()
            UIManager:close(menu);self:readingActions()
        end)}
        items[#items+1]={text=_("Preview attached text"),callback=self.scope:guard(function()
            UIManager:close(menu)
            UIManager:show(self.scope:own(require("ui/widget/textviewer"):new{title=_("Attached text"),text=self.session.data.context.text}))
        end)}
        if self.session.data.context.sources then
            items[#items+1]={text=_("Sources · open original text"),callback=self.scope:guard(function()
                UIManager:close(menu);self:showSources()
            end)}
        end
    end
    menu=require("ui/widget/menu"):new{title=_("Conversation context"),item_table=items}
    self.context_menu=menu;UIManager:show(self.scope:own(menu))
end

function Chat:index()
    if not self.book_index then self.book_index=self.bookindex.new(self.store.path.."/books.sqlite3",self.context_module,self.protocol,self.worker) end
    return self.book_index
end

function Chat:buildIndex()
    if self.session.running or self.context_loading then return end
    self.context_loading=true;self:refresh()
    local scope=self.new_scope();self.context_scope=scope
    self:index():build(self.reader_ui,scope,scope:guard(function(result,err)
        scope:close();self.context_scope=nil;self.context_loading=false;self:refresh()
        if not result then return self:message(err) end
        if result.limit then return self:message("index_limit") end
        self.index_result=result
        self:message(self.translate("Indexed pages")..": "..result.pages.." / "..result.total
            ..(result.truncated and " · "..self.translate("Truncated") or ""))
    end))
end

function Chat:searchIndex()
    local input,_=nil,self.translate
    input=require("ui/widget/inputdialog"):new{title=_("Search indexed books"),input="",buttons={
        {{text=_("Cancel"),callback=function() UIManager:close(input) end},
        {text=_("Search"),callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(input) then return end
            local query=input:getInputText();UIManager:close(input)
            self:loadContext(function(scope,done) self:index():search(query,scope,done) end)
        end)}}}}
    self.index_search=input;UIManager:show(self.scope:own(input));input:onShowKeyboard()
end

function Chat:showIndexes()
    local ok,books=pcall(function() return self:index():list() end)
    if not ok then return self:message("storage_error") end
    local items,_,menu={},self.translate,nil
    for __,book in ipairs(books) do
        items[#items+1]={text=book.title.." · "..book.pages.."/"..book.total..(book.stale and " · ".._("Needs refresh") or ""),
            callback=self.scope:guard(function()
                if not UIManager:isWidgetShown(menu) then return end
                UIManager:close(menu)
                UIManager:show(self.scope:own(require("ui/widget/confirmbox"):new{text=_("Remove this cached index? The book and its notes are kept."),
                    ok_callback=self.scope:guard(function()
                        local removed=pcall(function() self:index():remove(book.file) end)
                        if not removed then self:message("storage_error") else self:showIndexes() end
                    end)}))
            end)}
    end
    if #items==0 then return self:message("Open a book and choose Index this book first.") end
    menu=require("ui/widget/menu"):new{title=_("Manage book indexes"),item_table=items}
    self.index_menu=menu;UIManager:show(self.scope:own(menu))
end

function Chat:readingActions()
    if not self.session.data.context or self.session.running or self.context_loading then return end
    local _,menu,items=self.translate,nil,{}
    local actions={
        {"Reading report","report","Write a reading report based only on the supplied excerpts: scope, key ideas, supporting quotations with [S#] references, questions and next reading steps. Do not invent reading statistics."},
        {"Mind map","mindmap","Create a mind map of the supplied excerpts using only nested bullet lists. Use two spaces per level, at most six levels and 100 nodes. Keep labels short and preserve [S#] references."},
        {"Parallel translation","parallel","Translate the supplied excerpts into English. Output only the translation, preserving paragraph order and source labels."},
    }
    for __,action in ipairs(actions) do
        items[#items+1]={text=_(action[1]),callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(menu) then return end
            UIManager:close(menu);self:send(_(action[3]),{mode=action[2]})
        end)}
    end
    menu=require("ui/widget/menu"):new{title=_("Reading actions"),item_table=items}
    self.reading_actions=menu;UIManager:show(self.scope:own(menu))
end

function Chat:loadContext(operation)
    self:cancelContext();self.context_loading=true;self:refresh()
    local scope=self.new_scope();self.context_scope=scope
    operation(scope,scope:guard(function(context,err)
        self.context_loading=false;scope:close();self.context_scope=nil
        if context then self.session:fresh(context) else self:message(err) end
        self:refresh()
    end))
end

function Chat:loadChapter(index)
    self:loadContext(function(scope,done) self.context_module.chapter(self.reader_ui,scope,self.protocol,done,index) end)
end

function Chat:chooseChapter()
    local toc=self.reader_ui.toc;toc:fillToc()
    local menu,items=nil,{}
    for index,entry in ipairs(toc.toc) do
        items[#items+1]={text=entry.title,callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(menu) then return end
            UIManager:close(menu);self:loadChapter(index)
        end)}
    end
    menu=require("ui/widget/menu"):new{title=self.translate("Choose chapter"),item_table=items}
    self.chapter_menu=menu;UIManager:show(self.scope:own(menu))
end

function Chat:chooseNotes()
    local menu,items=nil,{}
    local function attach(note)
        if not UIManager:isWidgetShown(menu) then return end
        local context,err=self.context_module.notes(self.reader_ui,self.protocol,note)
        UIManager:close(menu)
        if context then self.session:fresh(context) else self:message(err) end
    end
    items[1]={text=self.translate("Attach up to 30 notes"),callback=self.scope:guard(function() attach() end)}
    for _,note in ipairs(self.reader_ui.annotation.annotations or {}) do
        if (note.text and note.text~="") or (note.note and note.note~="") then
            items[#items+1]={text=self.protocol.clip((note.note or "").." "..(note.text or ""),150),
                callback=self.scope:guard(function() attach(note) end)}
        end
    end
    menu=require("ui/widget/menu"):new{title=self.translate("Choose reading notes"),item_table=items}
    self.notes_menu=menu;UIManager:show(self.scope:own(menu))
end

function Chat:searchBook()
    local input,_=nil,self.translate
    input=require("ui/widget/inputdialog"):new{title=_("Search this book"),input="",buttons={
        {{text=_("Cancel"),callback=function() UIManager:close(input) end},
        {text=_("Search"),callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(input) then return end
            local query=input:getInputText();UIManager:close(input)
            self:loadContext(function(scope,done)
                self.context_module.search(self.reader_ui,query,scope,self.protocol,self.worker,done)
            end)
        end)}}}}
    self.book_search=input;UIManager:show(self.scope:own(input));input:onShowKeyboard()
end

function Chat:showSources()
    local menu,items=nil,{}
    for _,ref in ipairs(self.session.data.context and self.session.data.context.sources or {}) do
        items[#items+1]={text="["..ref.id.."] "..ref.title.." · "..ref.label.." · "..tostring(ref.page or ""),
            callback=self.scope:guard(function()
                if not UIManager:isWidgetShown(menu) then return end
                UIManager:close(menu);self.on_source(ref)
            end)}
    end
    menu=require("ui/widget/menu"):new{title=self.translate("Sources · open original text"),item_table=items}
    self.sources_menu=menu;UIManager:show(self.scope:own(menu))
end

function Chat:onSetDimensions() self.theme=self.new_theme();self:rebuild() end
function Chat:onClose() UIManager:close(self);return true end
function Chat:onCloseWidget()
    if self.closed then return end
    self.closed=true;self:cancelContext();self.session:close();self.scope:close();self.reader_ui=nil
    if self.probe_scope then self.probe_scope:close();self.probe_scope=nil end
    self:clear();UIManager:setDirty(nil,"ui");self.on_closed()
end

return Chat
