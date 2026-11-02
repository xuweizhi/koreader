-- Exercise actual CRE/MuPDF extraction at the end of a book, without a model.
return function(ctx)
    local reader=ctx.reader
    local doc=reader.document
    local scope=reader.anxui:module("lifecycle").new()
    local context=reader.anxui:module("ai/context")
    local protocol=reader.anxui:module("ai/protocol")
    local observations={}
    local function extract(label,done)
        local page=reader:getCurrentPage()
        local pointer=doc.getXPointer and doc:getXPointer()
        local notes=#reader.annotation.annotations
        context.chapter(reader,scope,protocol,function(value,err)
            assert(value,err)
            assert(#value.text>10 and #value.text<=16001)
            assert(reader:getCurrentPage()==page and (not pointer or doc:getXPointer()==pointer))
            assert(#reader.annotation.annotations==notes)
            observations[#observations+1]={label=label,page=page,kind=value.kind,truncated=value.truncated,text=value.text}
            ctx.shot("context-"..label)
            ctx.step(done)
        end)
    end
    extract("first",function()
        (reader.rolling or reader.paging):onGotoPage(doc:getPageCount())
        ctx.step(function()
            extract("last",function()
                assert(observations[2].text:find(doc.getXPointer and "这是一条测试注释" or "paragraph 16",1,true),"end of fixture omitted")
                -- Cancelling before the next UI tick must prevent any callback.
                local cancelled=reader.anxui:module("lifecycle").new()
                local called=false
                context.chapter(reader,cancelled,protocol,function() called=true end)
                cancelled:close()
                ctx.step(function()
                    assert(not called)
                    scope:close()
                    local file=assert(io.open(ctx.evidence.."/context-checks.json","w"))
                    file:write(require("json").encode({passed=true,checks=observations,cancelled=true}));file:close()
                    ctx.finish()
                end)
            end)
        end)
    end)
end
