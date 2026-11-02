return function(ctx)
    local UIManager=require("ui/uimanager")
    local reader,chat=ctx.reader,nil
    local checks={}
    local function wait(predicate,done,tries)
        if predicate() then return done() end
        assert((tries or 0)<180,"AI tools condition timed out")
        ctx.step(function() wait(predicate,done,(tries or 0)+1) end)
    end
    local function open()
        reader.anxui:showAssistant();chat=reader.anxui.assistant_view
    end
    local function dismiss()
        for index=#UIManager._window_stack,1,-1 do
            local widget=UIManager._window_stack[index].widget
            if widget.name=="infomessage" then UIManager:close(widget) end
        end
    end
    local function save()
        local file=assert(io.open(ctx.evidence.."/tools-checks.json","w"))
        file:write(require("json").encode({passed=true,checks=checks}));file:close();ctx.finish()
    end
    local function actions(index)
        if index>3 then
            checks[#checks+1]="report, hierarchical mind map and two-column translation rendered"
            return save()
        end
        chat:readingActions();chat.reading_actions.item_table[index].callback()
        wait(function() return not chat.session.running end,function()
            local messages=chat.session.data.messages
            assert(messages[#messages].status=="complete")
            chat:messageActions(#messages);chat.message_menu.item_table[1].callback()
            ctx.step(function()
                ctx.shot(({"ai-reading-report","ai-mind-map","ai-parallel-translation"})[index])
                UIManager:close(chat.message_viewer);actions(index+1)
            end)
        end)
    end
    local function tools()
        chat.session:fresh();chat.session.data.tools_enabled=true
        assert(chat:send("__tools__ 读取目录，然后概括第二章。"))
        wait(function() return not chat.session.running end,function()
            local answer=chat.session.data.messages[2]
            assert(answer.status=="complete",tostring(chat.session.error))
            assert(#answer.tool_steps==2 and answer.tool_steps[1].name=="current_book_toc" and answer.tool_steps[2].name=="read_chapter")
            assert(chat.session.data.context.text:find("Reading sample 2.1",1,true))
            assert(#chat.session.data.context.sources==1)
            checks[#checks+1]="native transport completes two read-only tool rounds with persisted sources"
            chat.session.data.tools_enabled=false
            ctx.step(function() ctx.shot("ai-reading-tools");actions(1) end)
        end)
    end
    local original=reader.document.file
    local copy=original..".ai-copy.epub"
    local input=assert(io.open(original,"rb"));local output=assert(io.open(copy,"wb"))
    output:write(input:read("*a"));output:close();input:close()
    open()
    chat.store:saveProfile({id="test",name="Test",provider="compatible",endpoint=assert(os.getenv("ANX_SMOKE_AI_URL")),
        model="fixture-model",api_key="anx-fixture-key"})
    local initial=reader:getCurrentPage()
    chat:buildIndex()
    wait(function() return not chat.context_loading end,function()
        assert(chat.index_result and chat.index_result.bytes>0)
        assert(reader:getCurrentPage()==initial)
        dismiss()
        -- Immediate cancellation must preserve the previous committed index.
        chat:buildIndex();chat:cancelContext()
        ctx.step(function()
            assert(#chat:index():list()==1)
            checks[#checks+1]="background index creation and cancellation preserve reading position and prior index"
            chat:onClose()
            reader:switchDocument(copy,nil,function(next_reader)
                reader=next_reader;open();chat:buildIndex()
                wait(function() return not chat.context_loading end,function()
                    dismiss();assert(#chat:index():list()==2)
                    chat:searchIndex();chat.index_search:setInputText("Reading sample 3.20")
                    chat.index_search.buttons[1][2].callback()
                    wait(function() return not chat.context_loading end,function()
                        local context=assert(chat.session.data.context)
                        assert(#context.sources>=2 and context.kind=="collection" and not chat.session.data.book)
                        local target
                        for index,ref in ipairs(context.sources) do if ref.file==original then target=index;break end end
                        assert(target)
                        local page=context.sources[target].page
                        chat:showSources();ctx.shot("ai-cross-book-sources")
                        chat.sources_menu.item_table[target].callback()
                        wait(function() return require("apps/reader/readerui").instance and require("apps/reader/readerui").instance.document.file==original end,function()
                            reader=require("apps/reader/readerui").instance
                            ctx.step(function()
                                assert(reader:getCurrentPage()==page)
                                checks[#checks+1]="two real EPUB indexes searched and cross-book source opened at original location"
                                open();tools()
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end)
end
