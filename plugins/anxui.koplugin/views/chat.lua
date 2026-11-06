local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputText = require("ui/widget/inputtext")
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
    self.draft_book=self.reader_ui and self.reader_ui.document.file or ""
    self:loadDraft()
    self.session:fresh(self.context)
    self:rebuild()
end

function Chat:loadDraft()
    local data=self.store:read("draft",{schema=1,entries={}})
    if not data or type(data.entries)~="table" or #data.entries>8 then return end
    for _,entry in ipairs(data.entries) do
        if type(entry)~="table" or type(entry.book)~="string" or #entry.book>4096
            or type(entry.text)~="string" or #entry.text>32768 then return end
    end
    self.draft_data=data
    for _,entry in ipairs(data.entries) do
        if entry.book==self.draft_book then self.draft=entry.text;break end
    end
    self.saved_draft=self.draft or ""
end

function Chat:saveDraft()
    local text=self.composer and self.composer:getText() or self.draft or ""
    if text==self.saved_draft then return true end
    if not self.draft_data or #text>32768 then return false end
    local data=require("util").tableDeepCopy(self.draft_data)
    for i=#data.entries,1,-1 do
        if data.entries[i].book==self.draft_book then table.remove(data.entries,i) end
    end
    if text~="" then table.insert(data.entries,1,{book=self.draft_book,text=text}) end
    while #data.entries>8 do table.remove(data.entries) end
    if not self.store:write("draft",data) then return false end
    self.draft_data,self.saved_draft=data,text
    return true
end

-- Native InputText opens clipboard windows outside its child tree. Track those
-- windows and their nested actions for this specific editor's lifetime.
function Chat:bindComposerPopups(input,scope)
    local bound,collecting=setmetatable({},{__mode="k"}),false
    local bind,collect
    collect=function(callback,...)
        local args={...}
        if collecting then return callback(unpack(args)) end
        collecting=true
        local result,reason=scope:collectWindows(function() return callback(unpack(args)) end)
        collecting=false
        for _,window in ipairs(scope.windows) do bind(window) end
        return result,reason
    end
    bind=function(widget)
        if type(widget)~="table" or bound[widget] then return end
        bound[widget]=true
        for _,name in ipairs({"holdTextBox","showSelectionDialog","showClipboardSnippets","editClipboardSnippet",
            "callback","hold_callback"}) do
            local callback=widget[name]
            if type(callback)=="function" then
                widget[name]=scope:guard(function(...) return collect(callback,...) end)
            end
        end
        for _,child in ipairs(widget) do bind(child) end
        for _,child in ipairs(widget.input_fields or {}) do bind(child) end
        bind(widget.button_table)
        bind(widget._input_widget)
    end
    bind(input)
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

-- Keep the editor alive across streamed replies: rebuilding a keyboard and
-- its input widget on every delta loses the cursor, selection and draft.
function Chat:prepareComposer(width, height)
    local old = self.composer
    if old then self.draft = old:getText() end
    if self.composer_holder then self.composer_holder[1] = nil end
    if old and (self.resize_composer or old.width ~= width or old.height ~= height) then
        self.restore_keyboard = old:isKeyboardVisible()
        self.restore_focus = old.focused
        self.draft_cursor = old.charpos
        if self.composer_scope then self.composer_scope:close() end
        if old.keyboard then old.keyboard.active_widgets=nil end
        old:onCloseKeyboard(); old:onCloseWidget()
        self.composer = nil
    end
    self.resize_composer = nil
    if not self.composer then
        self.composer = InputText:new{
            text=self.draft or "",hint=self.translate("Write a message…"),
            width=width,height=height,scroll=true,scroll_by_pan=true,
            face=self.widgets.face(self.theme,16*self.theme.text_scale),
            padding=0,margin=0,bordersize=0,parent=self,
            focused=self.restore_focus or false,charpos=self.draft_cursor,
            edit_callback=function() self:updateDraft() end,
        }
        self.composer_scope=self.new_scope()
        self:bindComposerPopups(self.composer,self.composer_scope)
        -- UIManager only forwards events below a top-level virtual keyboard to
        -- registered active widgets. Bind this editor's owner specifically,
        -- so Send and text input work without activating chat beneath dialogs.
        if self.composer.keyboard then self.composer.keyboard.active_widgets={self} end
        self.draft_cursor,self.restore_focus=nil,nil
    end
end

function Chat:updateDraft()
    if not self.composer then return end
    local had_text=(self.draft or ""):find("%S")~=nil
    self.draft = self.composer:getText()
    if #self.draft>32768 and not self.draft_limit_shown then
        self.draft_limit_shown=true
        self:message("Draft exceeds 32 KB and cannot be saved. Shorten it before closing.")
    elseif #self.draft<=32768 then self.draft_limit_shown=nil end
    if not self.draft_save_task then
        self.draft_save_task=self.scope:later(1,function()
            self.draft_save_task=nil
            if not self:saveDraft() and #self.draft<=32768 then self:message("storage_error") end
        end)
    end
    local send = self.buttons and self.buttons.send
    if send then
        send:enableDisable(not self.session.running and not self.context_loading and self.draft:find("%S") ~= nil)
        UIManager:setDirty(self,"ui",send.dimen)
    end
    if self.inline_retry and had_text~=(self.draft:find("%S")~=nil) then self:refresh() end
end

function Chat:hideComposerKeyboard()
    if not self.composer then return end
    self.draft = self.composer:getText()
    self.composer:onCloseKeyboard(); self.composer:unfocus()
    self:refresh()
end

function Chat:onSwitchFocus(input)
    if input ~= self.composer then return end
    input:focus()
    if not ((Device:hasKeyboard() or Device:hasScreenKB()) and G_reader_settings:nilOrFalse("virtual_keyboard_enabled")) then
        input:onShowKeyboard()
    end
    self:refresh()
end

function Chat:shouldDelegateToggleKeyboard() return true end
function Chat:toggleKeyboard()
    if self.composer:isKeyboardVisible() then self:hideComposerKeyboard()
    else self.composer:focus();self.composer:onShowKeyboard();self:refresh() end
end
function Chat:onKeyboardClosed() self:refresh() end
function Chat:onKeyboardHeightChanged() self:refresh() end
function Chat:onCloseDialog() return self:onClose() end

function Chat:sendComposer()
    if self.session.running or self.context_loading then return end
    local text=self.composer:getText()
    self.draft=text
    local ok,reason=self:send(text)
    if ok then
        self.composer:setText("");self.draft=""
        if not self:saveDraft() then self:message("storage_error") end
        self:hideComposerKeyboard()
    end
    return ok,reason
end

function Chat:rebuild()
    if self.closed then return end
    local old_scroll=self.log
    local keep_position=old_scroll and self.session.running and old_scroll._is_scrollable
        and old_scroll._scroll_offset_y < old_scroll._max_scroll_offset_y - self.theme.s(24)
    local scroll_offset=keep_position and old_scroll._scroll_offset_y
    local t, W, _ = self.theme, self.widgets, self.translate
    local width, height = Device.screen:getWidth(), Device.screen:getHeight()
    local margin, gap, touch = t.s(16), t.s(8), t.touch
    local inner = width - 2 * margin
    local send_width, composer_height = t.s(66), t.s(height<width and 54 or 68*t.text_scale)
    self:prepareComposer(inner-send_width-gap-2*t.s(8),composer_height-2*t.s(8))
    if self[1] then self:clear() end
    local keyboard_visible=self.composer:isKeyboardVisible() or self.restore_keyboard
    local keyboard_height=keyboard_visible and self.composer:getKeyboardDimen().h or 0
    local compact=keyboard_visible or height<t.s(450)
    self.dimen = Geom:new{w=width,h=height}
    local body = OverlapGroup:new{dimen=self.dimen:copy(),allow_mirroring=false}
    local function place(widget,x,y) widget.overlap_offset={x,y}; body[#body+1]=widget; return widget end
    local function button(text,w,callback) return W.button(text,w,t,self.scope:guard(callback),{parent=self}) end
    self.buttons = {}
    self.buttons.settings = button(_("Model"),t.s(64),function() self:showConfig() end)
    self.buttons.history = button(_("History"),t.s(80),function() self:showHistory() end)
    self.buttons.close = button("×",touch,function() UIManager:close(self) end)
    self.buttons.new = button(_("New"),t.s(66),function()
        self:hideComposerKeyboard();self:cancelContext();self.session:fresh()
    end)
    place(W.text("AI",t,t.title,math.max(t.s(24),inner-t.s(210)-touch-4*gap),true),margin,margin)
    place(self.buttons.new,width-margin-touch-3*gap-t.s(210),margin)
    place(self.buttons.history,width-margin-touch-2*gap-t.s(144),margin)
    place(self.buttons.settings,width-margin-touch-gap-t.s(64),margin)
    place(self.buttons.close,width-margin-touch,margin)
    self.layout={{self.buttons.new,self.buttons.history,self.buttons.settings,self.buttons.close}}
    local config = self.store:config()
    local label = config and config.model ~= "" and config.model or _("Model not configured")
    if not compact then place(W.text(label,t,12*t.text_scale,inner,false,true),margin,margin+touch+gap) end
    local context = self.session.data.context
    local kinds={selection="Selected text",page="Page excerpt",chapter="Chapter excerpt",notes="Reading notes",search="Search results",collection="Across books"}
    local caption = context and ((_(kinds[context.kind] or "Attached text"))
        .. ": " .. (context.chapter or context.title or "") .. (context.truncated and " · " .. _("Truncated") or "")) or _("Attach reference text")
    local top = margin+touch+gap+(compact and 0 or t.s(24*t.text_scale))
    local busy=self.session.running or self.context_loading
    local context_width=context and inner-2*(t.s(64)+gap) or inner
    self.buttons.context = button(self.context_loading and _("Preparing context…") or caption,
        compact and math.floor((inner-2*gap)/3) or context_width,function() self:showContext() end)
    self.buttons.context:enableDisable(not busy)
    if not compact then
        place(self.buttons.context,margin,top)
        local reference_row={self.buttons.context}
        if context then
            self.buttons.preview=button(_("Preview"),t.s(64),function() self:previewContext() end)
            self.buttons.remove_context=button(_("Remove"),t.s(64),function() self:setContext(nil) end)
            self.buttons.remove_context:enableDisable(not busy)
            place(self.buttons.preview,margin+context_width+gap,top)
            place(self.buttons.remove_context,width-margin-t.s(64),top)
            reference_row[#reference_row+1]=self.buttons.preview
            reference_row[#reference_row+1]=self.buttons.remove_context
        end
        self.layout[#self.layout+1]=reference_row
        top = top+touch+gap
    end
    local bottom = height-keyboard_height-margin-composer_height
    -- On a short landscape viewport the keyboard, editor and Stop control
    -- take precedence. Reference/task actions return when the keyboard closes.
    local show_actions=not keyboard_visible or bottom-top>=3*touch+3*gap
    local action_width=math.floor((inner-(compact and 2 or 1)*gap)/(compact and 3 or 2))
    local action_x=margin
    local action_row={}
    if compact and show_actions then
        self.buttons.context:setText(_("Reference content")..(context and " · "..tostring(#(context.sources or {})) or ""),action_width)
        place(self.buttons.context,action_x,top);action_row[#action_row+1]=self.buttons.context
        action_x=action_x+action_width+gap
    end
    self.buttons.tasks=button(_("Reading tasks"),action_width,function() self:readingActions() end)
    self.buttons.tools=button(_("Search and tools"),action_width,function() self:showTools() end)
    self.buttons.tasks:enableDisable(not busy);self.buttons.tools:enableDisable(not busy)
    if show_actions then
        place(self.buttons.tasks,action_x,top);place(self.buttons.tools,action_x+action_width+gap,top)
        action_row[#action_row+1]=self.buttons.tasks;action_row[#action_row+1]=self.buttons.tools
        self.layout[#self.layout+1]=action_row
        top=top+touch+gap
    end
    local last_message=self.session.data.messages[#self.session.data.messages]
    local can_retry=not busy and last_message and last_message.role=="assistant"
        and (last_message.status=="error" or last_message.status=="cancelled")
    local has_status=self.session.running or self.context_loading or self.session.error or self.session.data.tools_enabled
        or (last_message and (last_message.status=="cancelled" or last_message.limited))
    local status_height=has_status and touch or 0
    -- A landscape keyboard can leave less than one row above the editor.
    -- Keep Stop/Retry reachable beside the editor instead of overlapping the
    -- conversation with a separate status row.
    local inline_status=keyboard_visible and bottom-status_height-2*gap<top+t.s(12)
    if inline_status then status_height=0 end
    self.inline_retry=inline_status and can_retry
    if self.inline_retry and (self.draft or ""):find("%S") then can_retry=false end
    local status_y = bottom-status_height-gap
    local log_height = math.max(t.s(12),status_y-top-gap)
    local messages = VerticalGroup:new{align="left"}
    self.message_buttons={};self.source_buttons={};self.message_previews={}
    for index, entry in ipairs(self.session.data.messages) do
        local human = entry.role == "user"
        local bg = human and t.selected or t.surface
        local value = entry.content ~= "" and entry.content or (entry.status == "streaming" and _("Thinking…") or _("No answer received"))
        local preview=self.protocol.clip(value,1800)
        local text_widget
        if not human and entry.status~="streaming" then
            local ok,widget=pcall(self.markdown.preview,preview,inner-t.s(48),t.s(14*t.text_scale),entry.sources,
                self.scope:guard(function(ref) self:openSource(ref) end))
            if ok then text_widget=widget;self.message_previews[index]=widget end
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
        if not human and entry.status~="streaming" and (entry.sources==nil or #entry.sources>0) then
            local source_button=button(entry.sources and (_("Sources · open original text").." · "..#entry.sources)
                or _("Sources not saved"),inner-t.s(48),function() self:showMessageSources(entry) end)
            self.source_buttons[index]=source_button
            content[#content+1]=VerticalSpan:new{width=t.s(4)}
            content[#content+1]=source_button
        end
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
        if not config or config.model == "" then
            messages[#messages+1]=VerticalSpan:new{width=gap}
            self.buttons.configure=button(_("Add model provider"),inner-t.s(16),function() self:showConfig() end)
            messages[#messages+1]=self.buttons.configure
            self.layout[#self.layout+1]={self.buttons.configure}
        end
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
        local http_errors={ [401]="Authentication failed. Check the API key.",
            [403]="Access denied. Check the model permission.",
            [404]="Model or endpoint not found. Check the API settings.",
            [429]="Request limit reached. Check your quota or retry later." }
        status = self.session.http_code and (_(http_errors[self.session.http_code] or "Check the API settings or retry").." ("..self.session.http_code..")")
            or _(errors[self.session.error] or "Request failed")
    end
    local status_width=inner-((busy or can_retry) and (t.s(66)+gap) or 0)
    if not inline_status then
    place(TextBoxWidget:new{text=status,face=W.face(t,12*t.text_scale),width=status_width,height=touch,
        height_overflow_show_ellipsis=true,fgcolor=t.muted,bgcolor=t.background},margin,status_y)
    end
    if can_retry then
    self.buttons.retry=button(_("Retry"),t.s(66),function()
        if self.context_loading then return end
        self:hideComposerKeyboard()
        local ok,err=self.session:retry(); if not ok then self:message(err) end
    end)
    place(self.buttons.retry,width-margin-t.s(66),inline_status and bottom+composer_height-touch or status_y)
    if not inline_status then self.layout[#self.layout+1]={self.buttons.retry} end
    end
    if busy then
    self.buttons.stop=button(_("Stop"),t.s(66),function()
        if self.session.running then self.session:stop()
        elseif self.context_loading then self:cancelContext();self:refresh() end
    end)
    place(self.buttons.stop,width-margin-t.s(66),inline_status and bottom+composer_height-touch or status_y)
    if not inline_status then self.layout[#self.layout+1]={self.buttons.stop} end
    end
    self.composer_holder=FrameContainer:new{padding=t.s(8),bordersize=0,radius=t.radius,background=t.surface,self.composer}
    self.buttons.compose=self.composer
    self.buttons.send=button(_("Send"),send_width,function() self:sendComposer() end)
    self.buttons.send:enableDisable(not busy and (self.draft or ""):find("%S")~=nil)
    place(self.composer_holder,margin,bottom)
    local editor_action=inline_status and (self.buttons.stop or self.buttons.retry) or self.buttons.send
    if editor_action==self.buttons.send then
        place(self.buttons.send,width-margin-send_width,bottom+composer_height-touch)
    end
    self.layout[#self.layout+1]={self.composer,editor_action}
    self[1]=FrameContainer:new{padding=0,bordersize=0,background=t.background,body}
    self.selected={x=1,y=self.composer.focused and #self.layout or 1}
    self:refocusWidget(FocusManager.RENDER_NOW,FocusManager.NOT_FOCUS+FocusManager.NOT_UNFOCUS)
    if self.restore_keyboard then self.restore_keyboard=nil;self.composer:onShowKeyboard() end
    UIManager:setDirty(self,"ui")
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
    if not edit then
        if initial~=nil then self.composer:setText(initial) end
        self:onSwitchFocus(self.composer)
        return
    end
    self:hideComposerKeyboard()
    local dialog
    dialog=require("ui/widget/inputdialog"):new{title=self.translate(edit and "Edit and resend" or "Message"),input=initial or "",allow_newline=true,
        buttons={{{text=self.translate("Cancel"),id="close",callback=function() UIManager:close(dialog) end},
            {text=self.translate("Send"),is_enter_default=true,callback=self.scope:guard(function()
                if not UIManager:isWidgetShown(dialog) then return end
                local text=dialog:getInputText()
                local ok,err=self.session:editLast(text)
                if ok then UIManager:close(dialog)
                elseif err=="configure_ai" then self:message("configure_ai")
                else self:message(err) end
            end)}}}}
    self.compose_dialog=dialog;UIManager:show(self:ownInputDialog(dialog));dialog:onShowKeyboard()
end

function Chat:messageActions(index)
    self:hideComposerKeyboard()
    local entry=self.session.data.messages[index]
    if not entry then return end
    local _,menu=self.translate,nil
    local items={{text=_("Read full message"),callback=self.scope:guard(function()
        if not UIManager:isWidgetShown(menu) then return end
        UIManager:close(menu)
        local html=entry.role=="assistant"
        local TextViewer=require("ui/widget/textviewer")
        local viewer=TextViewer:new{title=html and "AI" or _("You"),
            text=html and self.markdown.document(entry,_) or entry.content,text_format=html and "html" or "txt",
            add_default_buttons=true,
            buttons_table=html and {{{text=_("Sources · open original text"),callback=self.scope:guard(function()
                self:showMessageSources(entry)
            end)}}} or nil,
            init=function(widget)
                TextViewer.init(widget)
                if html and widget.box_widget then
                    widget.box_widget.html_link_tapped_callback=self.scope:guard(function(link)
                        local ref=self.markdown.sourceForLink(link,entry.sources)
                        if ref then self:openSource(ref) end
                    end)
                end
            end,
        }
        self.message_viewer=viewer;UIManager:show(self.scope:own(viewer))
    end)},
    {text=_("Copy message"),callback=self.scope:guard(function()
        if not UIManager:isWidgetShown(menu) then return end
        UIManager:close(menu);Device.input.setClipboardText(entry.content);self:message("Copied")
    end)}}
    if entry.role=="assistant" then
        items[#items+1]={text=_("Sources · open original text"),callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(menu) then return end
            UIManager:close(menu);self:showMessageSources(entry)
        end)}
    end
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

function Chat:showConfig() self:hideComposerKeyboard();self.settings_ui.show(self) end

function Chat:ownInputDialog(dialog) return self.dialogs.own(self,dialog) end

function Chat:showHistory(query)
    self:hideComposerKeyboard()
    local history, err=self.store:history()
    if not history then return self:message(err) end
    local menu, items=nil,{}
    self.history_query=query or self.history_query or ""
    items[#items+1]={text=self.translate("Search conversations")..(self.history_query~="" and ": "..self.history_query or ""),callback=self.scope:guard(function()
        if not UIManager:isWidgetShown(menu) then return end
        UIManager:close(menu)
        local input
        input=require("ui/widget/inputdialog"):new{title=self.translate("Search conversations"),input=self.history_query,buttons={
            {{text=self.translate("Cancel"),id="close",callback=function() UIManager:close(input) end},
            {text=self.translate("Search"),is_enter_default=true,callback=self.scope:guard(function()
                if not UIManager:isWidgetShown(input) then return end
                local text=input:getInputText();UIManager:close(input);self:showHistory(text)
            end)}}}}
        self.history_search=input;UIManager:show(self:ownInputDialog(input));input:onShowKeyboard()
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
                {{text=_("Cancel"),id="close",callback=function() UIManager:close(input) end},
                {text=_("Save"),is_enter_default=true,callback=self.scope:guard(function()
                    if not UIManager:isWidgetShown(input) then return end
                    local title=input:getInputText():match("^%s*(.-)%s*$")
                    if title=="" or #title>120 then return self:message("Enter a conversation title (up to 120 bytes).") end
                    if not self.store:renameSession(data.id,title) then return self:message("storage_error") end
                    if self.session.data.id==data.id then self.session.data.title=title end
                    UIManager:close(input);self:showHistory()
                end)}}}}
            self.rename_dialog=input;UIManager:show(self:ownInputDialog(input));input:onShowKeyboard()
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

function Chat:setContext(context)
    if self.session.running or self.context_loading then return false,"busy" end
    local ok,err=self.session:setContext(context)
    if not ok then self:message(err) end
    return ok,err
end

function Chat:previewContext()
    local context=self.session.data.context
    if not context then return end
    self:hideComposerKeyboard()
    local viewer=require("ui/widget/textviewer"):new{title=self.translate("Reference content"),
        text=context.text,add_default_buttons=true,
        buttons_table=#(context.sources or {})>0 and {{{text=self.translate("Sources · open original text"),
            callback=self.scope:guard(function() self:showSources(context.sources) end)}}} or nil}
    self.context_viewer=viewer;UIManager:show(self.scope:own(viewer))
end

function Chat:showContext()
    if self.session.running or self.context_loading then return end
    self:hideComposerKeyboard()
    local _, menu=self.translate,nil
    local items={{text=_("Remove reference text"),enabled=self.session.data.context~=nil,
        callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(menu) then return end
            UIManager:close(menu);self:setContext(nil)
        end)}}
    if self.reader_ui then
        items[#items+1]={text=_("Use current chapter"),callback=self.scope:guard(function()
            UIManager:close(menu);self:loadChapter()
        end)}
        items[#items+1]={text=_("Choose chapter"),callback=self.scope:guard(function() UIManager:close(menu);self:chooseChapter() end)}
        items[#items+1]={text=_("Choose reading notes"),callback=self.scope:guard(function() UIManager:close(menu);self:chooseNotes() end)}
        items[#items+1]={text=_("Search this book"),callback=self.scope:guard(function() UIManager:close(menu);self:searchBook() end)}
    end
    items[#items+1]={text=_("Search indexed books"),callback=self.scope:guard(function() UIManager:close(menu);self:searchIndex() end)}
    if self.session.data.context then
        items[#items+1]={text=_("Preview attached text"),callback=self.scope:guard(function()
            UIManager:close(menu);self:previewContext()
        end)}
    end
    items[#items+1]={text=_("About reference content"),callback=self.scope:guard(function()
        UIManager:close(menu)
        self:message("Changes apply to your next message or retry. Earlier messages and their saved sources are kept.")
    end)}
    menu=require("ui/widget/menu"):new{title=_("Reference content"),item_table=items}
    self.context_menu=menu;UIManager:show(self.scope:own(menu))
end

function Chat:showTools()
    if self.session.running or self.context_loading then return end
    self:hideComposerKeyboard()
    local _,menu,items=self.translate,nil,{}
    if self.reader_ui then
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
            ok_callback=self.scope:guard(function()
                if self.session.running or self.context_loading then return end
                self.session.data.tools_enabled=true;self.session:save();self:refresh()
            end)}))
    end)}
    menu=require("ui/widget/menu"):new{title=_("Search and tools"),item_table=items}
    self.tools_menu=menu;UIManager:show(self.scope:own(menu))
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
    if self.session.running or self.context_loading then return end
    local input,_=nil,self.translate
    input=require("ui/widget/inputdialog"):new{title=_("Search indexed books"),input="",buttons={
        {{text=_("Cancel"),id="close",callback=function() UIManager:close(input) end},
        {text=_("Search"),is_enter_default=true,callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(input) then return end
            local query=input:getInputText();UIManager:close(input)
            self:loadContext(function(scope,done) self:index():search(query,scope,done) end)
        end)}}}}
    self.index_search=input;UIManager:show(self:ownInputDialog(input));input:onShowKeyboard()
end

function Chat:showIndexes()
    if self.session.running or self.context_loading then return end
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
    if self.session.running or self.context_loading then return end
    self:hideComposerKeyboard()
    if not self.session.data.context then
        local dialog=require("ui/widget/confirmbox"):new{
            text=self.translate("No reference text attached. Attach a chapter, selection, notes or search results first."),
            ok_text=self.translate("Attach reference text"),
            ok_callback=self.scope:guard(function() self:showContext() end),
        }
        self.reference_prompt=dialog;UIManager:show(self.scope:own(dialog));return
    end
    local _,menu,items=self.translate,nil,{}
    local actions={
        {"Explain",nil,"Please explain the supplied passage."},
        {"Translate",nil,"Translate the supplied passage into English."},
        {"Summarize",nil,"Summarize the supplied passage."},
        {"Reading report","report","Write a reading report based only on the supplied excerpts: scope, key ideas, supporting quotations with [S#] references, questions and next reading steps. Do not invent reading statistics."},
        {"Mind map","mindmap","Create a mind map of the supplied excerpts using only nested bullet lists. Use two spaces per level, at most six levels and 100 nodes. Keep labels short and preserve [S#] references."},
        {"Parallel translation","parallel","Translate the supplied excerpts into English. Output only the translation, preserving paragraph order and source labels."},
    }
    for __,action in ipairs(actions) do
        items[#items+1]={text=_(action[1]),callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(menu) then return end
            if self.session.running or self.context_loading or not self.session.data.context then return end
            UIManager:close(menu);self:send(_(action[3]),{mode=action[2]})
        end)}
    end
    menu=require("ui/widget/menu"):new{title=_("Reading tasks"),item_table=items}
    self.reading_actions=menu;UIManager:show(self.scope:own(menu))
end

function Chat:loadContext(operation)
    if self.session.running or self.context_loading then return false,"busy" end
    self:cancelContext();self.context_loading=true;self:refresh()
    local scope=self.new_scope();self.context_scope=scope
    operation(scope,scope:guard(function(context,err)
        self.context_loading=false;scope:close();self.context_scope=nil
        if context then self:setContext(context) else self:message(err) end
        self:refresh()
    end))
end

function Chat:loadChapter(index)
    self:loadContext(function(scope,done) self.context_module.chapter(self.reader_ui,scope,self.protocol,done,index) end)
end

function Chat:chooseChapter()
    if self.session.running or self.context_loading then return end
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
    if self.session.running or self.context_loading then return end
    local menu,items=nil,{}
    local function attach(note)
        if not UIManager:isWidgetShown(menu) then return end
        if self.session.running or self.context_loading then return end
        local context,err=self.context_module.notes(self.reader_ui,self.protocol,note)
        UIManager:close(menu)
        if context then self:setContext(context) else self:message(err) end
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
    if self.session.running or self.context_loading then return end
    local input,_=nil,self.translate
    input=require("ui/widget/inputdialog"):new{title=_("Search this book"),input="",buttons={
        {{text=_("Cancel"),id="close",callback=function() UIManager:close(input) end},
        {text=_("Search"),is_enter_default=true,callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(input) then return end
            local query=input:getInputText();UIManager:close(input)
            self:loadContext(function(scope,done)
                self.context_module.search(self.reader_ui,query,scope,self.protocol,self.worker,done)
            end)
        end)}}}}
    self.book_search=input;UIManager:show(self:ownInputDialog(input));input:onShowKeyboard()
end

function Chat:openSource(ref)
    self:hideComposerKeyboard()
    self.on_source(ref)
end

function Chat:showMessageSources(entry)
    -- Missing snapshots identify older records. Never substitute the current
    -- attachment: the same [S1] may refer to a completely different book now.
    if entry.sources==nil then return self:message("No saved sources for this reply.") end
    if #entry.sources==0 then return self:message("This reply has no sources.") end
    self:showSources(entry.sources)
end

function Chat:showSources(sources)
    self:hideComposerKeyboard()
    sources=sources or (self.session.data.context and self.session.data.context.sources) or {}
    if #sources==0 then return self:message("This reply has no sources.") end
    local menu,items=nil,{}
    for _,ref in ipairs(sources) do
        items[#items+1]={text="["..ref.id.."] "..ref.title.." · "..ref.label.." · "..tostring(ref.page or ""),
            callback=self.scope:guard(function()
                if not UIManager:isWidgetShown(menu) then return end
                UIManager:close(menu);self:openSource(ref)
            end)}
    end
    menu=require("ui/widget/menu"):new{title=self.translate("Sources · open original text"),item_table=items}
    self.sources_menu=menu;UIManager:show(self.scope:own(menu))
end

function Chat:onSetDimensions() self.theme=self.new_theme();self.resize_composer=true;self:rebuild() end
function Chat:onClose()
    if self.composer and self.composer:isKeyboardVisible() then self:hideComposerKeyboard();return true end
    UIManager:close(self);return true
end
function Chat:onCloseWidget()
    if self.closed then return end
    self:saveDraft()
    self.closed=true;self:cancelContext();self.session:close();self.scope:close();self.reader_ui=nil
    if self.probe_scope then self.probe_scope:close();self.probe_scope=nil end
    if self.composer then
        if self.composer_scope then self.composer_scope:close();self.composer_scope=nil end
        if self.composer.keyboard then self.composer.keyboard.active_widgets=nil end
        self.composer:onCloseKeyboard();self.composer:onCloseWidget()
        if self.composer_holder then self.composer_holder[1]=nil end
        self.composer=nil
    end
    self:clear();UIManager:setDirty(nil,"ui");self.on_closed()
end

return Chat
