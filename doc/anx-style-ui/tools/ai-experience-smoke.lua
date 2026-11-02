return function(ctx)
    local chat,step,UIManager=ctx.chat,ctx.step,require("ui/uimanager")
    local observations={}
    local function wait(predicate,done,tries)
        if predicate() then return done() end
        assert((tries or 0)<50,"experience condition timed out")
        step(function() wait(predicate,done,(tries or 0)+1) end)
    end
    local function closeTop() UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget) end
    local function finish()
        local f=assert(io.open(ctx.evidence.."/experience-checks.json","w"))
        f:write(require("json").encode({passed=true,checks=observations}));f:close();ctx.done()
    end
    local function history()
        local id=chat.session.data.id
        chat:showHistory("")
        chat.history_menu.item_table[2].hold_callback()
        chat.history_actions.item_table[1].callback()
        chat.rename_dialog:setInputText("阅读练习报告")
        chat.rename_dialog.buttons[1][2].callback()
        assert(chat.store:history()[1].title=="阅读练习报告")
        chat.history_menu.item_table[1].callback()
        chat.history_search:setInputText("阅读练习报告")
        chat.history_search.buttons[1][2].callback()
        assert(#chat.history_menu.item_table==2)
        ctx.shot("ai-history-filtered")
        chat.history_menu.item_table[2].callback()
        assert(chat.session.data.id==id)
        observations[#observations+1]="history rename/search/restore"
        chat:showHistory("");chat.history_menu.item_table[2].hold_callback()
        chat.history_actions.item_table[2].callback()
        local confirm=UIManager._window_stack[#UIManager._window_stack].widget
        confirm.ok_callback();UIManager:close(confirm)
        for _,item in ipairs(chat.store:history()) do assert(item.id~=id) end
        UIManager:close(chat.history_menu)
        observations[#observations+1]="history delete only selected session"
        finish()
    end
    local function messages()
        chat.session:fresh();assert(chat:send("__markdown__"))
        wait(function() return not chat.session.running end,function()
            assert(chat.session.data.messages[2].status=="complete")
            step(function()
                ctx.shot("ai-markdown-inline")
                chat:messageActions(2);chat.message_menu.item_table[1].callback()
                assert(not chat.message_viewer.is_txt and chat.message_viewer.box_widget.page_count>=1)
                ctx.shot("ai-markdown-full");UIManager:close(chat.message_viewer)
                chat:messageActions(2);chat.message_menu.item_table[2].callback()
                assert(require("device").input.getClipboardText()==chat.session.data.messages[2].content)
                closeTop();observations[#observations+1]="Markdown preview/full view and clipboard copy"
                chat:messageActions(1);chat.message_menu.item_table[3].callback()
                chat.compose_dialog:setInputText("修改后的问题")
                chat.compose_dialog.buttons[1][2].callback()
                wait(function() return not chat.session.running end,function()
                    assert(#chat.session.data.messages==2 and chat.session.data.messages[1].content=="修改后的问题")
                    observations[#observations+1]="edit and resend replaces last turn"
                    history()
                end)
            end)
        end)
    end
    chat:showConfig()
    local first=chat.store:config()
    chat.config_dialog.buttons[2][1].callback()
    chat.profiles_menu.item_table[2].callback() -- add DeepSeek
    local editor=chat.config_dialog
    editor.input_fields[1]:setText(first.endpoint)
    editor.input_fields[2]:setText("fixture-model-2")
    editor.input_fields[3]:setText("anx-fixture-key")
    editor.buttons[1][2].callback()
    assert(chat.store:config().provider=="deepseek" and #chat.store:profiles().profiles==2)
    chat:showConfig()
    local count=#chat.store:history()
    chat.config_dialog.buttons[2][2].callback()
    wait(function() return chat.probe_result~=nil end,function()
        assert(chat.probe_result.ok and #chat.store:history()==count)
        closeTop();UIManager:close(chat.config_dialog)
        chat.settings_ui.profiles(chat);ctx.shot("ai-model-profiles")
        chat.profiles_menu.item_table[1].callback()
        assert(chat.store:config().id==first.id)
        observations[#observations+1]="profiles switch and independent connection probe"
        messages()
    end)
end
