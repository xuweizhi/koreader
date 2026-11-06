local UIManager = require("ui/uimanager")
local Settings = {}
local ModelDialog

function Settings.probe(chat, config)
    if chat.probe_scope then chat.probe_scope:close() end
    local scope = chat.new_scope()
    chat.probe_scope = scope
    local progress = require("ui/widget/infomessage"):new{text=chat.translate("Testing connection…"),
        dismiss_callback=function() scope:close() end}
    UIManager:show(scope:own(progress))
    local request = require("util").tableDeepCopy(config)
    request.max_tokens = 64
    chat.probe_result = nil
    local job = chat.transport.start(scope,request,{{role="user",content="Reply only with OK."}},chat.protocol,{
        delta=function() end,
        done=scope:guard(function(err,code)
            chat.probe_result = {ok=not err,error=err,code=code}
            scope:close();chat.probe_scope=nil
            if chat.closed then return end
            if err then chat:message(code and ("HTTP "..code) or err)
            else chat:message("Connection successful") end
        end),
    })
    if not job then scope:close();chat.probe_scope=nil;chat:message("network_error") end
end

function Settings.show(chat, profile)
    if chat.session.running then return end
    if not profile then return Settings.profiles(chat) end
    profile = require("util").tableDeepCopy(profile)
    local dialog, _ = nil,chat.translate
    local function fields()
        if not UIManager:isWidgetShown(dialog) then return end
        local input = dialog:getFields()
        local model = input[2]:match("^%s*(.-)%s*$")
        if not chat.protocol.endpoint(input[1]) or model=="" or #model>200 or model:find("[%c]")
            or input[3]:find("[%c]") or #input[3]>4096 then chat:message("configure_ai");return end
        profile.endpoint,profile.model,profile.api_key=input[1],model,input[3]
        return profile
    end
    dialog=ModelDialog:new{chat=chat,title=_("AI model · OpenAI compatible").." · ".._(profile.name),
        fields={{description=_("API base address (usually ends in /v1)"),text=profile.endpoint},
            {description=_("Model ID"),text=profile.model},
            {description=_("API key (optional for local services)"),text=profile.api_key,text_type="password"}},
        buttons={{{text=_("Cancel"),id="close",callback=function() UIManager:close(dialog) end},
            {text=_("Save"),id="save",callback=chat.scope:guard(function()
                local config=fields();if not config then return end
                if not chat.store:saveProfile(config) then return chat:message("storage_error") end
                UIManager:close(dialog);chat:refresh()
            end)}},
            {{text=_("Profiles"),callback=chat.scope:guard(function()
                if not UIManager:isWidgetShown(dialog) then return end
                UIManager:close(dialog);Settings.profiles(chat)
            end)},
            {text=_("Test connection"),callback=chat.scope:guard(function()
                local config=fields();if config then Settings.probe(chat,config) end
            end)}}}}
    local close=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget,...)
        if chat.probe_scope then chat.probe_scope:close();chat.probe_scope=nil end
        if close then return close(widget,...) end
    end
    chat.config_dialog=dialog;UIManager:show(chat:ownInputDialog(dialog));dialog:onShowKeyboard()
end

local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local MultiInputDialog = require("ui/widget/multiinputdialog")

-- Keep the native fields and button APIs. Only the field area scrolls, so
-- confirmation/cancellation stay reachable above a landscape keyboard.
ModelDialog = MultiInputDialog:extend{}

function ModelDialog:init(reinit)
    local restore_keyboard=reinit and self.keyboard_visible
    self._building=true
    self.fields_scroll=nil
    local t=self.chat.new_theme()
    self.width=math.min(Device.screen:getWidth()-2*t.s(12),t.s(640))
    self.input_face=self.chat.widgets.face(t,16*t.text_scale)
    self.enter_callback=function()
        local index=self.focused_field_idx or 1
        if index<#self.input_fields then self:onSwitchFocus(self.input_fields[index+1])
        else self.button_table:getButtonById("save").callback() end
    end
    MultiInputDialog.init(self,reinit)
    local original=self.dialog_frame[1]
    for _,field in ipairs(self.input_fields) do
        -- Addresses and keys may be very long. Their input area stays one
        -- line high and uses InputText's own scrolling around the cursor.
        if field.height>field:getLineHeight() then
            field.height=field:getLineHeight()
            field:initTextBox()
        end
    end
    local fields=VerticalGroup:new{align="left"}
    local scrollbar=Device.screen:scaleBySize(6)
    self.field_offsets={}
    local offset=0
    for index=2,#original-1 do
        local child=original[index]
        child.dimen.w=self.width-3*scrollbar
        for field_index,field in ipairs(self.input_fields) do
            if child[1]==field then
                child.dimen.h=field:getSize().h
                self.field_offsets[field_index]={top=offset,height=child:getSize().h}
            end
        end
        fields[#fields+1]=child;offset=offset+child:getSize().h
    end
    self.fields_scroll=require("ui/widget/container/scrollablecontainer"):new{
        dimen=Geom:new{w=self.width,h=1},scroll_bar_width=scrollbar,fields}
    self.dialog_frame[1]=VerticalGroup:new{align="left",original[1],self.fields_scroll,original[#original]}
    self._building=nil
    if restore_keyboard then self:onShowKeyboard() else self:fitFields() end
end

function ModelDialog:fitFields()
    if self._building or not self.fields_scroll then return end
    local group=self.dialog_frame[1]
    local keyboard=self:isKeyboardVisible() and self._input_widget:getKeyboardDimen().h or 0
    local height=Device.screen:getHeight()-keyboard
    local available=height-group[1]:getSize().h-group[3]:getSize().h
        -2*self.dialog_frame.bordersize-Device.screen:scaleByDPI(8)
    self.fields_scroll.dimen.h=math.max(1,math.min(available,self.fields_scroll[1]:getSize().h))
    self.fields_scroll:reset();self.fields_scroll:initState()
    self[1].dimen.h=height
    group:resetLayout()
    self.dialog_frame.dimen=nil
    self:revealField()
end

function ModelDialog:revealField()
    local scroll=self.fields_scroll
    local row=self.field_offsets and self.field_offsets[self.focused_field_idx]
    if not scroll or not row then return end
    local offset=scroll._scroll_offset_y
    if row.top<offset then offset=row.top
    elseif row.top+row.height>offset+scroll.dimen.h then offset=row.top+row.height-scroll.dimen.h end
    scroll:setScrolledOffset{x=0,y=math.max(0,math.min(scroll._max_scroll_offset_y,offset))}
    if scroll._is_scrollable then scroll:_updateScrollBars() end
    UIManager:setDirty(self,"ui")
end

function ModelDialog:onSwitchFocus(input)
    local keyboard_visible=self:isKeyboardVisible()
    MultiInputDialog.onSwitchFocus(self,input)
    if keyboard_visible and not self:isKeyboardVisible() then self:onShowKeyboard() end
    for y,row in ipairs(self.layout) do
        if row[1]==input then self.selected={x=1,y=y};break end
    end
    self:fitFields()
end

function ModelDialog:onShowKeyboard(...)
    MultiInputDialog.onShowKeyboard(self,...)
    self:fitFields()
end

function ModelDialog:onKeyboardClosed() self:fitFields() end

local Providers = FocusManager:extend{
    name="anxui_ai_providers", covers_fullscreen=true, stop_events_propagation=true,
}

function Providers:init()
    self.page=1
    self.key_events.Close={{Device.input.group.Back}}
    self.key_events.NextPage={{Device.input.group.PgFwd}}
    self.key_events.PreviousPage={{Device.input.group.PgBack}}
    self:rebuild()
end

function Providers:rebuild()
    if self.closed then return end
    if self[1] then self:clear() end
    local chat=self.chat
    local t=chat.new_theme()
    t.touch=math.max(t.touch,Device.screen:scaleByDPI(48))
    local W,_=chat.widgets,chat.translate
    local width,height=Device.screen:getWidth(),Device.screen:getHeight()
    local margin,gap=t.s(16),t.s(8)
    local inner=width-2*margin
    self.dimen=Geom:new{w=width,h=height}
    local body=OverlapGroup:new{dimen=self.dimen:copy(),allow_mirroring=false}
    local function place(widget,x,y) widget.overlap_offset={x,y};body[#body+1]=widget end
    local function button(label,w,callback,selected,enabled)
        return W.button(label,w,t,chat.scope:guard(function()
            if not self.closed and UIManager:isWidgetShown(self) then callback() end
        end),{parent=self,selected=selected,enabled=enabled})
    end
    local data=self.data
    self.buttons={edit={},select={},more={}}
    self.buttons.close=button("×",t.touch,function() self:onClose() end)
    place(W.text(_("Model providers"),t,t.heading,inner-t.touch-gap,true),margin,margin)
    place(self.buttons.close,width-margin-t.touch,margin)
    self.layout={{self.buttons.close}}
    place(W.text(string.format("%s · %d / 8",_("Profiles"),#data.profiles),t,t.small,inner,false,true),
        margin,margin+t.touch+gap)
    local top=margin+t.touch+gap+t.s(28*t.text_scale)
    local footer=height-margin-t.touch
    local pager=footer-gap-t.touch
    local padding=t.s(12)
    local card_height=2*padding+t.s(50*t.text_scale)+gap+t.touch
    self.perpage=math.max(1,math.floor((pager-top)/(card_height+gap)))
    self.page_count=math.max(1,math.ceil(#data.profiles/self.perpage))
    self.page=math.max(1,math.min(self.page_count,self.page))
    local first=(self.page-1)*self.perpage+1
    for index=first,math.min(#data.profiles,first+self.perpage-1) do
        local profile=data.profiles[index]
        local active=profile.id==data.active
        local available=inner-2*padding
        local bw=math.floor((available-2*gap)/3)
        local select=button(_(active and "Active" or "Use model"),bw,function()
            if not chat.store:selectProfile(profile.id) then return chat:message("storage_error") end
            self:onClose();chat:refresh()
        end,active)
        local edit=button(_("Edit"),bw,function() self:onClose();Settings.show(chat,profile) end)
        local more=button(_("More"),bw,function() self:onClose();Settings.actions(chat,profile) end)
        self.buttons.select[index],self.buttons.edit[index],self.buttons.more[index]=select,edit,more
        local content=VerticalGroup:new{align="left",
            W.text((active and "✓ " or "").._(profile.name),t,16*t.text_scale,available,true),
            VerticalSpan:new{width=t.s(4)},
            W.text(profile.model~="" and profile.model or _("Model not configured"),t,14*t.text_scale,available,false,true),
            VerticalSpan:new{width=gap},
            HorizontalGroup:new{select,HorizontalSpan:new{width=gap},edit,HorizontalSpan:new{width=gap},more},
        }
        local card=FrameContainer:new{padding=padding,bordersize=active and 1 or 0,
            background=t.surface,color=t.accent,radius=t.radius,content}
        place(card,margin,top+(index-first)*(card_height+gap))
        self.layout[#self.layout+1]={select,edit,more}
    end
    if self.page_count>1 then
        self.buttons.previous=button("‹",t.touch,function() self:onPreviousPage() end,false,self.page>1)
        self.buttons.next=button("›",t.touch,function() self:onNextPage() end,false,self.page<self.page_count)
        place(self.buttons.previous,margin,pager)
        place(W.text(string.format("%d / %d",self.page,self.page_count),t,t.small,inner-2*t.touch-2*gap),margin+t.touch+gap,pager+t.s(12))
        place(self.buttons.next,width-margin-t.touch,pager)
        self.layout[#self.layout+1]={self.buttons.previous,self.buttons.next}
    end
    local add_width=math.floor((inner-gap)/2)
    self.buttons.add_deepseek=button(_("Add DeepSeek profile"),add_width,function() self:create("deepseek") end,false,#data.profiles<8)
    self.buttons.add_custom=button(_("Add custom profile"),add_width,function() self:create("compatible") end,true,#data.profiles<8)
    place(self.buttons.add_deepseek,margin,footer)
    place(self.buttons.add_custom,margin+add_width+gap,footer)
    self.layout[#self.layout+1]={self.buttons.add_deepseek,self.buttons.add_custom}
    self[1]=FrameContainer:new{padding=0,bordersize=0,background=t.background,body}
    self.selected={x=1,y=1};self:refocusWidget();UIManager:setDirty(self,"ui")
end

function Providers:create(provider)
    if #self.data.profiles>=8 then return self.chat:message("At most 8 model profiles") end
    self:onClose()
    Settings.show(self.chat,{id=tostring(require("socket").gettime()),name=provider=="deepseek" and "DeepSeek" or "Custom",
        endpoint=provider=="deepseek" and "https://api.deepseek.com" or "https://api.openai.com/v1",
        model=provider=="deepseek" and "deepseek-flash" or "",api_key="",provider=provider})
end

function Providers:onNextPage() self.page=self.page+1;self:rebuild();return true end
function Providers:onPreviousPage() self.page=self.page-1;self:rebuild();return true end
function Providers:onSetDimensions() self:rebuild() end
function Providers:onClose() UIManager:close(self);return true end
function Providers:onCloseWidget()
    if self.closed then return end
    self.closed=true;self:clear()
    if self.chat.profiles_menu==self then self.chat.profiles_menu=nil end
    UIManager:setDirty(nil,"ui")
end

function Settings.actions(chat,profile)
    local actions,_=nil,chat.translate
    local data=chat.store:profiles()
    if not data then return chat:message("storage_error") end
    actions=require("ui/widget/buttondialog"):new{title=_(profile.name),buttons={
        {{text=_("Rename"),callback=chat.scope:guard(function()
            if not UIManager:isWidgetShown(actions) then return end
            UIManager:close(actions)
            local input
            input=require("ui/widget/inputdialog"):new{title=_("Profile name"),input=profile.name,buttons={
                {{text=_("Cancel"),id="close",callback=function() UIManager:close(input) end},
                {text=_("Save"),is_enter_default=true,callback=chat.scope:guard(function()
                    if not UIManager:isWidgetShown(input) then return end
                    local name=input:getInputText():match("^%s*(.-)%s*$")
                    if name=="" or #name>100 then return chat:message("Enter a profile name (up to 100 bytes).") end
                    local replacement=require("util").tableDeepCopy(profile)
                    replacement.name=name
                    if not chat.store:saveProfile(replacement) then return chat:message("storage_error") end
                    -- Renaming another profile must not silently switch models.
                    if not chat.store:selectProfile(data.active) then return chat:message("storage_error") end
                    UIManager:close(input);chat:refresh();Settings.profiles(chat)
                end)}}}}
            chat.profile_rename=input;UIManager:show(chat:ownInputDialog(input));input:onShowKeyboard()
        end)}},
        {{text=_("Delete profile"),enabled=#data.profiles>1,callback=chat.scope:guard(function()
            if not UIManager:isWidgetShown(actions) then return end
            UIManager:close(actions)
            UIManager:show(chat.scope:own(require("ui/widget/confirmbox"):new{text=_("Delete this model profile?"),
                ok_callback=chat.scope:guard(function()
                    if not chat.store:deleteProfile(profile.id) then return chat:message("storage_error") end
                    chat:refresh();Settings.profiles(chat)
                end)}))
        end)}},
    }}
    UIManager:show(chat.scope:own(actions))
end

function Settings.profiles(chat)
    if chat.closed or chat.session.running then return end
    if chat.profiles_menu and UIManager:isWidgetShown(chat.profiles_menu) then return end
    local data,err=chat.store:profiles()
    if not data then return chat:message(err) end
    local view=Providers:new{chat=chat,data=data}
    chat.profiles_menu=view
    UIManager:show(chat.scope:own(view))
end
return Settings
