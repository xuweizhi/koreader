-- Real widgets, document engine, pipe transport and local HTTP/SSE fixture.
return function(ctx)
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local observations, chat = {}, nil
    local function record(name) observations[#observations+1]=name end
    local function wait(predicate, callback, tries)
        if predicate() then return callback() end
        assert((tries or 0)<40,"AI condition timed out")
        ctx.step(function() wait(predicate,callback,(tries or 0)+1) end)
    end
    local function click(widget, callback)
        UIManager:forceRePaint()
        local d=assert(widget.dimen)
        assert(d.x>=0 and d.y>=0 and d.x+d.w<=Screen:getWidth() and d.y+d.h<=Screen:getHeight(),"offscreen control")
        ctx.input({{kind="click",x=math.floor(d.x+d.w/2),y=math.floor(d.y+d.h/2)}},callback)
    end
    local function complete(callback)
        wait(function() return not chat.session.running end,function()
            local last=chat.session.data.messages[#chat.session.data.messages]
            assert(last and last.status=="complete",chat.session.error)
            assert(last.content:find("你好，",1,true),"fragmented UTF-8 response lost")
            ctx.step(callback)
        end)
    end
    local function send(text,callback)
        chat:compose(text)
        assert(chat.composer:getText()==text)
        local action=chat.buttons.send.callback
        action()
        assert(chat.session.running,"Send did not start transport")
        action() -- busy/stale send must never duplicate a turn.
        callback()
    end
    local function done()
        local file=assert(io.open(ctx.evidence.."/ai-checks.json","w"))
        file:write(require("json").encode({passed=true,checks=observations}));file:close()
        ctx.finish()
    end
    local function reading()
        chat:onClose()
        ctx.selectBook(ctx.fm,function(reader)
            local page, count, pointer=reader:getCurrentPage(),#reader.annotation.annotations,reader.document:getXPointer()
            local Geom=require("ui/geometry")
            local position
            for y=60,Screen:getHeight()-80,16 do
                for x=40,Screen:getWidth()-40,24 do
                    local point=Geom:new{x=x,y=y,w=0,h=0}
                    local page_point=reader.view:screenToPageTransform(point)
                    if page_point then
                        local ok,word=pcall(reader.document.getWordFromPosition,reader.document,page_point)
                        if ok and word and word.word and word.word~="" then position=point;break end
                    end
                end
                if position then break end
            end
            assert(position,"fixture contains no selectable text")
            reader.highlight:onHold(nil,{pos=position})
            local selected=assert(reader.highlight.selected_text).text
            assert(reader.highlight._highlight_buttons.anxui_ai)(reader.highlight).callback()
            chat=assert(reader.anxui.assistant_view)
            assert(chat.session.data.context.text==selected and not chat.session.running)
            assert(chat.session.data.context.file==ctx.book)
            record("selected text captured without automatic request")
            ctx.step(function()
                ctx.shot("ai-selected-text")
                click(chat.buttons.tasks,function()
                    chat.reading_actions.item_table[1].callback()
                    complete(function()
                        ctx.shot("ai-explain")
                        record("selected text explanation uses native highlight entry")
                        chat:showContext();chat.context_menu.item_table[2].callback()
                        wait(function() return not chat.context_loading end,function()
                            local attached=assert(chat.session.data.context)
                            assert(attached.file==ctx.book and attached.kind=="chapter" and #attached.text>0)
                            assert(reader:getCurrentPage()==page and reader.document:getXPointer()==pointer,"chapter extraction moved reading position")
                            assert(#reader.annotation.annotations==count,"AI changed annotations")
                            record("chapter excerpt bounded and reader position/annotations unchanged")
                            ctx.step(function()
                                ctx.shot("ai-chapter-context")
                                send("本章讲了什么？",function()
                                    complete(function()
                                        ctx.shot("ai-chapter-answer")
                                        record("chapter question sends explicit attached context")
                                        send("__slow__ closing reader",function()
                                            wait(function() return #chat.session.data.messages[#chat.session.data.messages].content>0 end,function()
                                                local job=chat.session.job
                                                reader:onHome()
                                                assert(chat.closed and not job.running and not job.fd and not job.pid)
                                                record("reader teardown cancels child and closes chat")
                                                ctx.step(done)
                                            end)
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
    local function errorCases()
        chat.session:fresh()
        send("__fail__",function()
            wait(function() return not chat.session.running end,function()
                assert(chat.session.error=="http_error" and chat.session.http_code==429)
                assert(not chat.session.data.messages[2].content:find("private",1,true))
                record("HTTP 429 mapped without exposing raw provider body")
                ctx.step(function()
                    ctx.shot("ai-http-error")
                    chat.session:fresh()
                    send("__cut__",function()
                        wait(function() return not chat.session.running end,function()
                            assert(chat.session.error=="invalid_stream")
                            assert(chat.session.data.messages[2].content~="")
                            record("truncated stream preserves partial answer and reports failure")
                            chat.session:fresh()
                            send("__slow__ stop",function()
                                wait(function() return #chat.session.data.messages[2].content>0 end,function()
                                    local job=chat.session.job
                                    chat.session:stop()
                                    assert(not job.running and not job.fd and not job.pid)
                                    assert(chat.session.data.messages[2].status=="cancelled")
                                    local partial=chat.session.data.messages[2].content
                                    ctx.step(function()
                                        assert(chat.session.data.messages[2].content==partial)
                                        ctx.shot("ai-stopped")
                                        record("stop closes pipe/process and rejects late responses")
                                        send("__slow__ timeout",function()
                                            wait(function() return #chat.session.data.messages[#chat.session.data.messages].content>0 end,function()
                                                local time=require("ui/time")
                                                -- Force elapsed time only; the socket and child are real.
                                                chat.session.job.started=time.now()-time.s(91)
                                                wait(function() return not chat.session.running end,function()
                                                    assert(chat.session.error=="timeout")
                                                    record("forced elapsed deadline cancels real pending HTTP request")
                                                    reading()
                                                end)
                                            end)
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
    local function general()
        send("你好，请介绍你的阅读辅助功能。",function()
            complete(function()
                ctx.shot("ai-general-answer")
                record("real streaming HTTP response in native chat UI")
                send("继续解释",function()
                    complete(function()
                        assert(#chat.session.data.messages==4)
                        assert(chat.session:retry())
                        complete(function()
                            assert(#chat.session.data.messages==4,"retry duplicated turns")
                            record("multi-turn context and retry without duplicate messages")
                            local id=chat.session.data.id
                            chat:onClose();ctx.fm.anxui:showAssistant();chat=ctx.fm.anxui.assistant_view
                            chat:showHistory();chat.history_menu.item_table[2].callback()
                            assert(chat.session.data.id==id and #chat.session.data.messages==4)
                            record("saved conversation restored after closing chat")
                            ctx.step(function()
                                dofile("/data/koreader/doc/anx-style-ui/tools/ai-experience-smoke.lua"){
                                    chat=chat,step=ctx.step,shot=ctx.shot,input=ctx.input,evidence=ctx.evidence,done=errorCases,
                                }
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end
    local function immediateClose()
        send("__slow__ immediate close",function()
            local job=chat.session.job
            local pid=job.pid
            chat:onClose()
            assert(not job.running and not job.fd and not job.pid)
            ctx.step(function()
                assert(require("ffi").C.kill(pid,0)~=0,"cancelled child survived immediate close")
                record("immediate close before first poll terminates and reaps child")
                ctx.fm.anxui:showAssistant();chat=assert(ctx.fm.anxui.assistant_view)
                ctx.step(general)
            end)
        end)
    end
    ctx.fm.anxui:showAssistant();chat=assert(ctx.fm.anxui.assistant_view)
    ctx.step(function()
        if ctx.scenario=="ai_reopen" then
            assert(chat.store:config().model=="fixture-model")
            local history=assert(chat.store:history());assert(#history>=5)
            chat:showHistory();chat.history_menu.item_table[2].callback()
            local last=chat.session.data.messages[#chat.session.data.messages]
            assert(last.status=="cancelled" and last.content~="")
            assert(chat.session.data.context.file==ctx.book)
            record("fresh process retains model, chapter context and stopped partial answer")
            ctx.step(function() ctx.shot("ai-history-restored");done() end)
            return
        end
        ctx.shot("ai-empty")
        assert(not chat.buttons.retry and not chat.buttons.stop)
        chat.composer:setText("未发送的中文草稿")
        chat:rebuild()
        assert(chat.composer:getText()=="未发送的中文草稿")
        local sent,reason=chat:sendComposer()
        assert(not sent and reason=="configure_ai")
        assert(chat.profiles_menu and chat.composer:getText()=="未发送的中文草稿")
        chat.profiles_menu:onClose()
        record("inline draft survives redraw and missing-model validation")
        click(chat.buttons.settings,function()
            assert(chat.profiles_menu).buttons.edit[1].callback()
            local dialog=assert(chat.config_dialog)
            for index,value in ipairs({assert(os.getenv("ANX_SMOKE_AI_URL")),"fixture-model","anx-fixture-key"}) do
                dialog.input_fields[index]:setText(value)
            end
            ctx.shot("ai-model-settings")
            dialog.buttons[1][2].callback()
            assert(chat.store:config().model=="fixture-model")
            assert(chat.composer:getText()=="未发送的中文草稿")
            chat.composer:setText("")
            record("native configuration UI saves model and masks key; draft retained")
            ctx.step(immediateClose)
        end)
    end)
end
