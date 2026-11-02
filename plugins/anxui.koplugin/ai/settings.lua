local UIManager = require("ui/uimanager")
local Settings = {}

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
    local err
    if not profile then profile,err = chat.store:config() end
    if not profile then return chat:message(err) end
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
    dialog=require("ui/widget/multiinputdialog"):new{title=_("AI model · OpenAI compatible").." · ".._(profile.name),
        fields={{description=_("API base address (usually ends in /v1)"),text=profile.endpoint},
            {description=_("Model ID"),text=profile.model},
            {description=_("API key (optional for local services)"),text=profile.api_key,text_type="password"}},
        buttons={{{text=_("Cancel"),callback=function() UIManager:close(dialog) end},
            {text=_("Save"),callback=chat.scope:guard(function()
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
    chat.config_dialog=dialog;UIManager:show(chat.scope:own(dialog));dialog:onShowKeyboard()
end

function Settings.profiles(chat)
    local data,err=chat.store:profiles()
    if not data then return chat:message(err) end
    local items,menu, _={},nil,chat.translate
    local function valid() return UIManager:isWidgetShown(menu) end
    local function create(provider)
        if not valid() then return end
        if #data.profiles>=8 then return chat:message("At most 8 model profiles") end
        UIManager:close(menu)
        Settings.show(chat,{id=tostring(require("socket").gettime()),name=provider=="deepseek" and "DeepSeek" or "Custom",
            endpoint=provider=="deepseek" and "https://api.deepseek.com" or "https://api.openai.com/v1",
            model=provider=="deepseek" and "deepseek-flash" or "",api_key="",provider=provider})
    end
    for __,profile in ipairs(data.profiles) do
        items[#items+1]={text=(profile.id==data.active and "✓ " or "").._(profile.name).." · "..profile.model,
            callback=chat.scope:guard(function()
                if not valid() then return end
                if not chat.store:selectProfile(profile.id) then return chat:message("storage_error") end
                UIManager:close(menu);chat:refresh()
            end),hold_callback=chat.scope:guard(function()
                if not valid() then return end
                UIManager:close(menu)
                local actions
                actions=require("ui/widget/buttondialog"):new{title=_(profile.name),buttons={
                    {{text=_("Edit"),callback=function() UIManager:close(actions);Settings.show(chat,profile) end}},
                    {{text=_("Rename"),callback=function()
                        UIManager:close(actions)
                        local input
                        input=require("ui/widget/inputdialog"):new{title=_("Profile name"),input=profile.name,buttons={
                            {{text=_("Cancel"),callback=function() UIManager:close(input) end},
                            {text=_("Save"),callback=chat.scope:guard(function()
                                if not UIManager:isWidgetShown(input) then return end
                                local name=input:getInputText():match("^%s*(.-)%s*$")
                                if name=="" or #name>100 then return end
                                profile.name=name
                                if not chat.store:saveProfile(profile) then return chat:message("storage_error") end
                                UIManager:close(input);chat:refresh();Settings.profiles(chat)
                            end)}}}}
                        UIManager:show(chat.scope:own(input));input:onShowKeyboard()
                    end}},
                    {{text=_("Delete profile"),enabled=#data.profiles>1,callback=function()
                        UIManager:close(actions)
                        UIManager:show(chat.scope:own(require("ui/widget/confirmbox"):new{text=_("Delete this model profile?"),
                            ok_callback=chat.scope:guard(function()
                                if not chat.store:deleteProfile(profile.id) then return chat:message("storage_error") end
                                chat:refresh();Settings.profiles(chat)
                            end)}))
                    end}},
                }}
                UIManager:show(chat.scope:own(actions))
            end)}
    end
    items[#items+1]={text=_("Add DeepSeek profile"),callback=chat.scope:guard(function() create("deepseek") end)}
    items[#items+1]={text=_("Add custom profile"),callback=chat.scope:guard(function() create("compatible") end)}
    menu=require("ui/widget/menu"):new{title=_("Profiles · hold to edit"),item_table=items}
    chat.profiles_menu=menu;UIManager:show(chat.scope:own(menu))
end
return Settings
