-- Authorized, bounded requests against DeepSeek's official HTTPS endpoint.
-- Credential path is supplied by the runner; values are never printed.
return function(ctx)
    local plugin=ctx.fm.anxui
    plugin:showAssistant()
    local chat=assert(plugin.assistant_view)
    local keyfile=assert(io.open(assert(os.getenv("ANX_AI_KEY_FILE")),"rb"))
    local key=keyfile:read("*a"):match("^%s*(.-)%s*$");keyfile:close()
    local config={id="deepseek-live",name="DeepSeek",provider="deepseek",endpoint="https://api.deepseek.com",
        model="deepseek-flash",api_key=key,max_tokens=96}
    assert(chat.store:saveProfile(config))
    local results={provider="DeepSeek",model=config.model,endpoint=config.endpoint,verification="real HTTPS + native Lua transport"}
    local function wait(predicate,callback,tries)
        if predicate() then return callback() end
        assert((tries or 0)<180,"live request did not finish")
        ctx.step(function() wait(predicate,callback,(tries or 0)+1) end)
    end
    local function save()
        config.api_key="";assert(chat.store:saveProfile(config))
        results.passed=true
        local file=assert(io.open(ctx.evidence.."/live-checks.json","w"))
        file:write(require("json").encode(results));file:close()
        ctx.finish()
    end
    local function tools()
        chat.session:fresh();chat.session.data.tools_enabled=true
        config.max_tokens=256;assert(chat.store:saveProfile(config))
        assert(chat:send("请必须先调用 list_indexed_books 工具，再根据工具返回的信息，用一句中文告诉我已经索引了几本书。"))
        wait(function() return not chat.session.running end,function()
            local answer=chat.session.data.messages[2]
            assert(answer.status=="complete",tostring(chat.session.error).." "..tostring(chat.session.http_code))
            assert(answer.tool_steps and #answer.tool_steps>0,"live model did not use requested reading tool")
            assert(answer.tool_steps[1].name=="list_indexed_books")
            results.tools={status=answer.status,steps=answer.tool_steps,answer=answer.content}
            ctx.step(function() ctx.shot("deepseek-live-tools");save() end)
        end)
    end
    assert(chat:send("请只回复四个字：测试通过。"))
    wait(function() return not chat.session.running end,function()
        local answer=chat.session.data.messages[2]
        assert(answer.status=="complete",tostring(chat.session.error).." "..tostring(chat.session.http_code))
        assert(answer.content:find("测试通过",1,true),"unexpected live answer")
        results.success={status=answer.status,answer=answer.content}
        ctx.step(function()
            ctx.shot("deepseek-live-answer")
            chat.session:fresh();config.api_key="invalid-anx-test-key";assert(chat.store:saveProfile(config))
            assert(chat:send("Reply only with OK."))
            wait(function() return not chat.session.running end,function()
                assert(chat.session.http_code==401,"invalid credential should report HTTP 401")
                results.invalid_key={code=chat.session.http_code,error=chat.session.error}
                config.api_key=key;assert(chat.store:saveProfile(config));chat.session:fresh()
                assert(chat:send("请依次列出 1 到 200 的数字。"))
                local job=chat.session.job
                chat.session:stop()
                ctx.step(function()
                    assert(not job.pid and not job.fd and not job.running)
                    local stopped=chat.session.data.messages[2]
                    local size=#stopped.content
                    ctx.step(function()
                        assert(stopped.status=="cancelled" and #stopped.content==size)
                        results.cancel={status=stopped.status,partial_bytes=size,late_response_ignored=true}
                        ctx.shot("deepseek-live-cancelled");tools()
                    end)
                end)
            end)
        end)
    end)
end
