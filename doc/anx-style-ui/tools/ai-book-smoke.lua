return function(ctx)
    local UIManager=require("ui/uimanager")
    local reader,chat=ctx.reader,nil
    local checks={}
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
                chat.sources_menu.item_table[1].callback()
                ctx.step(function()
                    assert(reader:getCurrentPage()==target)
                    checks[#checks+1]="native background text search and source navigation"
                    assert(#reader.annotation.annotations==1 and reader.annotation.annotations[1].note=="AI 来源笔记")
                    local f=assert(io.open(ctx.evidence.."/book-checks.json","w"))
                    f:write(require("json").encode({passed=true,checks=checks}));f:close();ctx.finish()
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
                chat:showSources();ctx.shot("ai-chapter-reference")
                chat.sources_menu.item_table[1].callback()
                ctx.step(function()
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
