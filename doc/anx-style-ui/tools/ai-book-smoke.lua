return function(ctx)
    local UIManager=require("ui/uimanager")
    local reader,chat=ctx.reader,nil
    local checks={}
    local function click(widget,done)
        UIManager:forceRePaint()
        local d=assert(widget.dimen)
        ctx.input({{kind="click",x=math.floor(d.x+d.w/2),y=math.floor(d.y+d.h/2)}},done)
    end
    local function clickCitation(viewer,id,done)
        UIManager:forceRePaint()
        local box=viewer.box_widget
        local page=box.document:openPage(box.page_number)
        local links=page:getPageLinks();page:close()
        local debug_file=assert(io.open(ctx.evidence.."/citation-rendering.json","w"))
        debug_file:write(require("json").encode({html=viewer.text,links=links,page=box.page_number}));debug_file:close()
        local found
        for _,link in ipairs(links) do if link.uri=="anx-source:"..id then found=link;break end end
        assert(found,"rendered answer has no tappable citation "..id)
        ctx.input({{kind="click",x=math.floor(box.dimen.x+(found.x0+found.x1)/2),
            y=math.floor(box.dimen.y+(found.y0+found.y1)/2)}},done)
    end
    local function wait(predicate,done,tries)
        if predicate() then return done() end
        assert((tries or 0)<100,"book AI condition timed out")
        ctx.step(function() wait(predicate,done,(tries or 0)+1) end)
    end
    local function open()
        reader.anxui:showAssistant();chat=reader.anxui.assistant_view
    end
    local function search()
        chat:searchBook();chat.book_search:setInputText("Reading sample 3.20")
        chat.book_search.buttons[1][2].callback()
        wait(function() return not chat.context_loading end,function()
            local attached=assert(chat.session.data.context)
            assert(attached.kind=="search" and #attached.sources>=1)
            assert(attached.text:find("3.20",1,true))
            assert(chat:send("请概括找到的段落，并标注 [S1]。"))
            wait(function() return not chat.session.running end,function()
                assert(chat.session.data.messages[2].status=="complete")
                ctx.shot("ai-book-search-answer")
                local target=attached.sources[1].page
                chat:showSources();ctx.shot("ai-book-search-sources")
                UIManager:close(chat.sources_menu)
                chat:compose("来源跳转时保留草稿")
                chat.composer:onShowKeyboard() -- SDL also reports a physical keyboard.
                assert(chat.composer:isKeyboardVisible())
                local previous_page=reader:getCurrentPage()
                local invalid=require("util").tableDeepCopy(attached.sources[1])
                invalid.xpointer,invalid.note,invalid.page=nil,nil,0
                reader.anxui:openAISource(invalid)
                assert(reader:getCurrentPage()==previous_page and reader.anxui.assistant_view==chat)
                UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget)
                reader.anxui:openAISource(attached.sources[1])
                ctx.step(function()
                    assert(reader:getCurrentPage()==target)
                    assert(not reader.anxui.assistant_view and not chat.composer)
                    local drafts=assert(chat.store:read("draft"))
                    assert(drafts.entries[1].text=="来源跳转时保留草稿")
                    checks[#checks+1]="native background text search and source navigation"
                    checks[#checks+1]="invalid source keeps reading position; valid source fully closes keyboard/chat and preserves draft"
                    assert(#reader.annotation.annotations==1 and reader.annotation.annotations[1].note=="AI 来源笔记")
                    local f=assert(io.open(ctx.evidence.."/book-checks.json","w"))
                    f:write(require("json").encode({passed=true,checks=checks}));f:close();ctx.finish()
                end)
            end)
        end)
    end
    local function referenceUX(done)
        local id=chat.session.data.id
        local original_source=chat.session.data.messages[2].sources[1]
        chat.composer:setText("保留的未发送草稿");chat:updateDraft()
        chat:rebuild()
        click(chat.buttons.preview,function()
            assert(chat.context_viewer.text:find("Reading sample 2.30",1,true))
            ctx.shot("reference-preview")
            UIManager:close(chat.context_viewer)
            click(chat.buttons.remove_context,function()
                assert(not chat.session.data.context and #chat.session.data.messages==2)
                assert(chat.session.data.id==id and chat.draft=="保留的未发送草稿")
                assert(chat.session.data.messages[2].sources[1].signature==original_source.signature)
                checks[#checks+1]="preview and removal preserve conversation, draft and answer source snapshot"
                assert(chat:send("__without_reference__ 不附原文的新问题"))
                wait(function() return not chat.session.running end,function()
                    assert(#chat.session.data.messages==4 and #chat.session.data.messages[4].sources==0)
                    chat:chooseChapter();chat.chapter_menu.item_table[3].callback()
                    wait(function() return not chat.context_loading end,function()
                        assert(chat.session.data.context.chapter:find("第3章",1,true))
                        assert(chat.session.data.id==id and #chat.session.data.messages==4)
                        assert(chat.draft=="保留的未发送草稿")
                        chat:messageActions(2);chat.message_menu.item_table[1].callback()
                        ctx.shot("old-answer-current-chapter-changed")
                        clickCitation(chat.message_viewer,"S1",function()
                            assert(not reader.anxui.assistant_view,"citation left the chat open")
                            assert(reader:getCurrentPage()==reader.toc.toc[2].page,"old citation used newly attached chapter")
                            checks[#checks+1]="rendered old-answer citation opens its original chapter after attachment replacement"
                            done()
                        end)
                    end)
                end)
            end)
        end)
    end
    reader.bookmark:onToggleBookmark()
    ctx.editNote(reader,"AI 来源笔记",function()
        local initial=reader:getCurrentPage()
        open()
        chat.store:saveProfile({id="test",name="Test",provider="compatible",endpoint=assert(os.getenv("ANX_SMOKE_AI_URL")),
            model="fixture-model",api_key="anx-fixture-key"})
        chat:chooseChapter();chat.chapter_menu.item_table[2].callback()
        wait(function() return not chat.context_loading end,function()
            local context=assert(chat.session.data.context)
            assert(context.chapter:find("第2章",1,true) and context.text:find("Reading sample 2.30",1,true))
            assert(not context.text:find("第3章",1,true) and reader:getCurrentPage()==initial)
            assert(chat:send("解释这一章，并引用 [S1]。"))
            wait(function() return not chat.session.running end,function()
                assert(chat.session.data.book.file==reader.document.file)
                checks[#checks+1]="chosen chapter attached without moving reader"
                referenceUX(function()
                    assert(reader:getCurrentPage()==reader.toc.toc[2].page)
                    open();chat:chooseNotes();chat.notes_menu.item_table[1].callback()
                    assert(chat.session.data.context.text:find("AI 来源笔记",1,true))
                    chat:showSources();chat.sources_menu.item_table[1].callback()
                    ctx.step(function()
                        assert(reader:getCurrentPage()==initial)
                        checks[#checks+1]="original notes attached and exact stored anchor restored"
                        open()
                        chat.store:saveSession({id="other-book",title="Other book only",messages={{role="user",content="Other"}},
                            book={file="/not-this-book.epub",title="Other"}})
                        chat:showHistory("")
                        for _,item in ipairs(chat.history_menu.item_table) do assert(item.text~="Other book only") end
                        chat.history_menu.item_table[2].callback()
                        local found=false
                        for _,item in ipairs(chat.history_menu.item_table) do if item.text=="Other book only" then found=true end end
                        assert(found);UIManager:close(chat.history_menu)
                        checks[#checks+1]="history defaults to current book with explicit all-books switch"
                        search()
                    end)
                end)
            end)
        end)
    end)
end
