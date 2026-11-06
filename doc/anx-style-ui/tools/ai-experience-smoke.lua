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
    local function modelForm(done)
        local Screen=require("device").screen
        local width,height=Screen:getWidth(),Screen:getHeight()
        local saved=chat.store:config()
        chat.settings_ui.show(chat,saved)
        local editor=chat.config_dialog
        local drafts={saved.endpoint.."/unsaved","unsaved-model","fixture-unsaved-"..string.rep("k",240)}
        for i,value in ipairs(drafts) do editor.input_fields[i]:setText(value) end
        editor.skip_first_show_keyboard=nil;editor:onShowKeyboard()
        local function inspect(label)
            UIManager:forceRePaint()
            local keyboard_top=Screen:getHeight()-editor._input_widget:getKeyboardDimen().h
            local frame=editor.dialog_frame.dimen
            ctx.shot(label)
            assert(frame.y>=0 and frame.y+frame.h<=keyboard_top,
                string.format("model form extends behind keyboard: y=%d h=%d keyboard_top=%d visible=%s",frame.y,frame.h,keyboard_top,tostring(editor:isKeyboardVisible())))
            for _,id in ipairs({"close","save"}) do
                local d=editor.button_table:getButtonById(id).dimen
                assert(d.y>=0 and d.y+d.h<=keyboard_top,"model confirmation action is hidden")
            end
            local active=editor._input_widget.dimen
            local crop=editor.fields_scroll.dimen
            assert(active.y>=crop.y and active.y+active.h<=crop.y+crop.h,"focused model field is clipped")
            assert(editor:isKeyboardVisible())
            for i,value in ipairs(editor:getFields()) do assert(value==drafts[i],"model input lost on resize") end
        end
        step(function()
            inspect("ai-model-form-portrait")
            editor:onCloseKeyboard()
            ctx.input({{kind="key",value="Return"}},function()
                assert(editor.focused_field_idx==2,"Enter should advance to the next model field")
                editor:onShowKeyboard()
                editor._input_widget:moveCursorToCharPos(3)
                editor._input_widget:holdTextBox()
                local popup=UIManager._window_stack[#UIManager._window_stack].widget
                assert(popup~=editor and popup~=editor._input_widget.keyboard)
                ctx.input({{kind="resize",width=height,height=width}},function()
                    step(function()
                        assert(not UIManager:isWidgetShown(popup),"resizing a model editor leaves a stale clipboard window")
                        assert(editor.focused_field_idx==2 and editor._input_widget.charpos==3,"model field focus/cursor lost")
                        inspect("ai-model-form-landscape")
                        editor:onSwitchFocus(editor.input_fields[3]);editor:onShowKeyboard()
                        step(function()
                            inspect("ai-model-key-landscape")
                            local cancel=editor.button_table:getButtonById("close").dimen
                            ctx.input({{kind="click",x=math.floor(cancel.x+cancel.w/2),y=math.floor(cancel.y+cancel.h/2)}},function()
                                assert(not UIManager:isWidgetShown(editor),"Cancel must work above keyboard")
                                assert(chat.store:config().endpoint==saved.endpoint and chat.store:config().model==saved.model)
                                ctx.input({{kind="resize",width=width,height=height}},function()
                                    observations[#observations+1]="model form keeps all inputs, cursor and focused field across native resize; footer remains visible; Enter advances and real Cancel keeps saved profile"
                                    step(done)
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end
    local function history()
        local id=chat.session.data.id
        local Screen=require("device").screen
        local width,height=Screen:getWidth(),Screen:getHeight()
        local function restoreAndDelete()
            assert(#chat.history_menu.item_table==2)
            ctx.shot("ai-history-filtered")
            chat.history_menu.item_table[2].callback()
            assert(chat.session.data.id==id)
            observations[#observations+1]="history rename/search survive native resize and accept physical Enter; empty title gives actionable feedback"
            chat:showHistory("");chat.history_menu.item_table[2].hold_callback()
            chat.history_actions.item_table[2].callback()
            local confirm=UIManager._window_stack[#UIManager._window_stack].widget
            confirm.ok_callback();UIManager:close(confirm)
            for _,item in ipairs(chat.store:history()) do assert(item.id~=id) end
            UIManager:close(chat.history_menu)
            observations[#observations+1]="history delete only selected session"
            finish()
        end
        chat:showHistory("")
        chat.history_menu.item_table[2].hold_callback()
        chat.history_actions.item_table[1].callback()
        chat.rename_dialog:setInputText("   ")
        chat.rename_dialog.buttons[1][2].callback()
        assert(UIManager._window_stack[#UIManager._window_stack].widget.text==chat.translate("Enter a conversation title (up to 120 bytes)."))
        closeTop();assert(chat.rename_dialog:getInputText()=="   ")
        chat.rename_dialog:setInputText("阅读练习报告")
        chat.rename_dialog.skip_first_show_keyboard=nil;chat.rename_dialog:onShowKeyboard()
        ctx.input({{kind="resize",width=height,height=width}},function()
            step(function()
                assert(chat.rename_dialog:getInputText()=="阅读练习报告" and chat.rename_dialog:isKeyboardVisible())
                ctx.shot("ai-history-rename-landscape")
                chat.rename_dialog:onCloseKeyboard()
                ctx.input({{kind="key",value="Return"}},function()
                    assert(chat.store:history()[1].title=="阅读练习报告")
                    chat.history_menu.item_table[1].callback()
                    chat.history_search:setInputText("阅读练习报告")
                    chat.history_search.skip_first_show_keyboard=nil;chat.history_search:onShowKeyboard()
                    ctx.input({{kind="resize",width=width,height=height}},function()
                        step(function()
                            assert(chat.history_search:getInputText()=="阅读练习报告" and chat.history_search:isKeyboardVisible())
                            ctx.shot("ai-history-search-restored")
                            chat.history_search:onCloseKeyboard()
                            ctx.input({{kind="key",value="Return"}},restoreAndDelete)
                        end)
                    end)
                end)
            end)
        end)
    end
    local function profilePages()
        local first=chat.store:config()
        for index=1,6 do
            local profile=require("util").tableDeepCopy(first)
            profile.id="ux-pagination-"..index;profile.name="模型 "..index
            assert(chat.store:saveProfile(profile))
        end
        chat.settings_ui.profiles(chat)
        local manager=assert(chat.profiles_menu)
        local seen={}
        repeat
            UIManager:forceRePaint()
            for index,button in pairs(manager.buttons.edit) do
                local d=assert(button.dimen)
                assert(d.y>=0 and d.y+d.h<=manager.buttons.add_custom.dimen.y,"model editor overlaps footer")
                seen[index]=true
            end
            if manager.page==manager.page_count then break end
            manager:onNextPage()
        until false
        assert(seen[1] and seen[8],"all eight profiles must be reachable")
        ctx.shot("ai-model-last-page")
        assert(not manager.buttons.add_custom.enabled)
        manager:onClose()
        for index=1,6 do assert(chat.store:deleteProfile("ux-pagination-"..index)) end
        assert(chat.store:selectProfile(first.id))
        observations[#observations+1]="all eight model profiles reachable with footer actions visible"
    end
    local function keyboardRotation(done)
        local Screen=require("device").screen
        local width,height=Screen:getWidth(),Screen:getHeight()
        local draft="横竖屏输入时保留这份草稿"
        chat.composer:setText(draft);chat.composer:focus();chat.composer:onShowKeyboard();chat:refresh()
        local function inspect(label)
            UIManager:forceRePaint()
            assert(chat.composer:isKeyboardVisible() and chat.composer:getText()==draft,"rotation lost editor or draft")
            assert(chat.composer.keyboard.active_widgets[1]==chat,"keyboard owner was not rebound")
            local editor=assert(chat.composer_holder.dimen)
            local action=assert(chat.layout[#chat.layout][2].dimen,"editor action must remain visible")
            local keyboard_top=Screen:getHeight()-chat.composer:getKeyboardDimen().h
            assert(editor.y+editor.h<=keyboard_top and action.y+action.h<=keyboard_top,"keyboard overlaps editor or action")
            assert(chat.log.dimen.y+chat.log.dimen.h<=editor.y,"conversation overlaps editor")
            if chat.session.running then
                local stop=assert(chat.buttons.stop.dimen)
                assert(chat.log.dimen.y+chat.log.dimen.h<=stop.y,"conversation overlaps generating status or Stop")
                assert(stop.y+stop.h<=editor.y or stop.x>=editor.x+editor.w,"Stop overlaps editor")
            end
            ctx.shot(label)
        end
        step(function()
            inspect("ai-keyboard-portrait")
            ctx.input({{kind="resize",width=height,height=width}},function()
                step(function()
                    assert(Screen:getWidth()==height and Screen:getHeight()==width)
                    inspect("ai-keyboard-landscape")
                    assert(chat:send("__slow__ keyboard layout"))
                    step(function()
                        assert(chat.session.running)
                        inspect("ai-keyboard-landscape-generating")
                        local stop=chat.buttons.stop.dimen
                        ctx.input({{kind="click",x=math.floor(stop.x+stop.w/2),y=math.floor(stop.y+stop.h/2)}},function()
                            assert(not chat.session.running,"Stop must accept a real tap above the keyboard")
                            step(function()
                                assert(chat.layout[#chat.layout][2]==chat.buttons.send,"a nonempty draft must still be sendable after Stop")
                                chat.composer:setText("");chat:updateDraft()
                                step(function()
                                    if chat.inline_retry then
                                        assert(chat.layout[#chat.layout][2]==chat.buttons.retry,"empty editor must expose Retry")
                                    end
                                    chat.composer:setText(draft);chat:updateDraft()
                                    ctx.input({{kind="resize",width=width,height=height}},function()
                                        step(function()
                                            inspect("ai-keyboard-restored")
                                            chat.composer:setText("");chat:updateDraft();chat:hideComposerKeyboard()
                                            observations[#observations+1]="native keyboard portrait/landscape/portrait resize keeps draft, active owner and non-overlapping input; Stop accepts a real tap; nonempty draft keeps Send and empty draft exposes Retry"
                                            step(done)
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
    local function references(done)
        local id=chat.session.data.id
        local messages=chat.session.data.messages
        local original_text=messages[2].content
        chat.composer:setText("附文变更后仍需保留的草稿")
        chat:updateDraft()
        assert(not chat.session.data.context)
        chat:readingActions()
        assert(chat.reference_prompt and UIManager:isWidgetShown(chat.reference_prompt),"missing-reference task must explain how to attach")
        ctx.shot("ai-task-needs-reference")
        UIManager:close(chat.reference_prompt)
        chat:showContext()
        for _,item in ipairs(chat.context_menu.item_table) do
            assert(item.text~=chat.translate("Enable reading tools") and item.text~=chat.translate("Reading tasks"),"reference menu mixes tools or tasks")
        end
        UIManager:close(chat.context_menu)
        chat:showTools()
        local has_toggle=false
        for _,item in ipairs(chat.tools_menu.item_table) do
            if item.text==chat.translate("Enable reading tools") then has_toggle=true end
        end
        assert(has_toggle,"tool permission needs a separate entry")
        ctx.shot("ai-search-tools");UIManager:close(chat.tools_menu)
        local reference={kind="selection",title="附文预览测试",text="仅供下一次请求参考的文字。",sources={}}
        assert(chat:setContext(reference))
        step(function()
            assert(chat.session.data.id==id and chat.session.data.messages==messages and messages[2].content==original_text)
            assert(chat.composer:getText()=="附文变更后仍需保留的草稿")
            assert(chat.buttons.preview and chat.buttons.remove_context and chat.buttons.tasks and chat.buttons.tools)
            ctx.shot("ai-reference-controls")
            chat.buttons.preview.callback()
            assert(chat.context_viewer.text==reference.text)
            ctx.shot("ai-reference-preview");UIManager:close(chat.context_viewer)
            chat:readingActions();assert(#chat.reading_actions.item_table==6)
            ctx.shot("ai-reading-task-menu");UIManager:close(chat.reading_actions)
            -- Pre-migration records may contain [S1] but no snapshot. The UI
            -- must never resolve those IDs using a newly attached document.
            local saved_sources=messages[2].sources
            messages[2].sources=nil
            local old_menu=chat.sources_menu
            chat:showMessageSources(messages[2])
            assert(chat.sources_menu==old_menu and UIManager._window_stack[#UIManager._window_stack].widget.text==chat.translate("No saved sources for this reply."))
            ctx.shot("ai-legacy-source-feedback");closeTop()
            messages[2].sources=saved_sources
            chat.buttons.remove_context.callback()
            assert(not chat.session.data.context and chat.session.data.id==id and #messages==2)
            assert(chat.composer:getText()=="附文变更后仍需保留的草稿")
            chat.composer:setText("");chat:updateDraft()
            observations[#observations+1]="reference preview/remove preserves conversation and draft; six tasks and tools use separate menus"
            observations[#observations+1]="legacy replies without source snapshots explain missing provenance instead of using current reference"
            keyboardRotation(done)
        end)
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
                    references(history)
                end)
            end)
        end)
    end
    chat:showConfig()
    local first=chat.store:config()
    chat.profiles_menu.buttons.add_deepseek.callback()
    local editor=chat.config_dialog
    editor.input_fields[1]:setText(first.endpoint)
    editor.input_fields[2]:setText("fixture-model-2")
    editor.input_fields[3]:setText("anx-fixture-key")
    editor.buttons[1][2].callback()
    assert(chat.store:config().provider=="deepseek" and #chat.store:profiles().profiles==2)
    chat:showConfig()
    while not chat.profiles_menu.buttons.edit[2] do chat.profiles_menu:onNextPage() end
    chat.profiles_menu.buttons.edit[2].callback()
    local count=#chat.store:history()
    chat.config_dialog.buttons[2][2].callback()
    wait(function() return chat.probe_result~=nil end,function()
        assert(chat.probe_result.ok and #chat.store:history()==count)
        closeTop();UIManager:close(chat.config_dialog)
        chat.settings_ui.profiles(chat);ctx.shot("ai-model-profiles")
        chat.profiles_menu.buttons.select[1].callback()
        assert(chat.store:config().id==first.id)
        observations[#observations+1]="profiles switch and independent connection probe"
        modelForm(function()
            profilePages()
            messages()
        end)
    end)
end
