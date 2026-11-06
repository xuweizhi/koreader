describe("Anx built-in AI", function()
    local Protocol, Store, Session, Lifecycle, UIManager, path, store
    setup(function()
        require("commonrequire")
        Protocol=dofile("plugins/anxui.koplugin/ai/protocol.lua")
        Store=dofile("plugins/anxui.koplugin/ai/store.lua")
        Session=dofile("plugins/anxui.koplugin/ai/session.lua")
        Lifecycle=dofile("plugins/anxui.koplugin/lifecycle.lua")
        UIManager=require("ui/uimanager")
    end)
    before_each(function()
        path=os.tmpname();os.remove(path);store=assert(Store.new(path))
    end)
    after_each(function()
        for file in require("libs/libkoreader-lfs").dir(path) do
            if file~="." and file~=".." then os.remove(path.."/"..file) end
        end
        require("libs/libkoreader-lfs").rmdir(path);UIManager:quit()
    end)

    it("normalizes compatible endpoints and rejects credentials or control characters in the URL", function()
        assert.are.equal("https://example.test/v1/chat/completions",Protocol.endpoint(" https://example.test/v1/ "))
        assert.are.equal("http://127.0.0.1:8080/v1/chat/completions",Protocol.endpoint("http://127.0.0.1:8080/v1/chat/completions"))
        for _,url in ipairs({"file:///tmp/a","https://key@host/v1","https://host/v1?key=secret","https://host/a\r\nx: y"}) do
            assert.is_nil(Protocol.endpoint(url))
        end
        assert.are.equal("你",Protocol.clip("你好",5))
    end)

    it("decodes fragmented UTF-8 SSE with CRLF, comments and completion markers", function()
        local chunks={};local parser=Protocol.decoder(function(s) chunks[#chunks+1]=s end)
        local wire=': keepalive\r\n\r\ndata: {"choices":[{"delta":{"content":"你好"}}]}\r\n\r\n'
            ..'data: {"choices":[{"delta":{"content":" world"},"finish_reason":"stop"}]}\n\n'
            ..'data: [DONE]\n\n'
        for index=1,#wire do parser:feed(wire:sub(index,index)) end
        assert.are.equal("你好 world",table.concat(chunks));assert.is_true(parser.complete)
    end)

    it("rejects malformed and unbounded streams without treating partial text as complete", function()
        local parser=Protocol.decoder(function() end)
        parser:feed('data: {"choices":[{"delta":{"content":"partial"}}]}\n\n')
        assert.is_false(parser.complete)
        assert.has_error(function() parser:feed('data: not-json\n\n') end)
        assert.has_error(function() Protocol.decoder(function() end):feed(string.rep("x",65537)) end)
        assert.has_error(function() Protocol.decoder(function() end):feed('data: {"error":{"message":"secret"}}\n\n') end)
    end)

    it("stores credentials privately and keeps them separate from conversation history", function()
        assert.is_true(store:write("config",{schema=1,endpoint="https://example.test/v1",model="test",api_key="fixture-secret"}))
        assert.are.equal("fixture-secret",assert(Store.new(path)):config().api_key)
        assert.are.equal("rw-------",require("libs/libkoreader-lfs").attributes(path.."/config.json","permissions"))
        assert.is_true(store:saveSession({id="1",title="Hello",messages={{role="user",content="Hi"}}}))
        local f=assert(io.open(path.."/history.json"));local text=f:read("*a");f:close()
        assert.is_nil(text:find("fixture-secret",1,true))
        assert.is_true(store:deleteSession("1"));assert.are.equal(0,#store:history())
    end)

    it("preserves corrupt files and never silently overwrites unreadable history", function()
        local f=assert(io.open(path.."/history.json","w"));f:write("broken");f:close()
        local data,reason=store:history();assert.is_nil(data);assert.are.equal("storage_error",reason)
        assert.is_false(store:saveSession({id="1",title="x",messages={}}))
        f=assert(io.open(path.."/history.json"));assert.are.equal("broken",f:read("*a"));f:close()
    end)

    it("rejects malformed schemas and symbolic links without changing existing targets", function()
        assert.is_true(store:write("config",{schema=1,endpoint={},model="test",api_key=""}))
        assert.is_nil(store:config())
        local target=path.."/untouched"
        local f=assert(io.open(target,"w"));f:write("original");f:close()
        assert(require("libs/libkoreader-lfs").link(target,path.."/history.json",true))
        assert.is_nil(store:history())
        assert.is_false(store:saveSession({id="1",title="x",messages={}}))
        f=assert(io.open(target));assert.are.equal("original",f:read("*a"));f:close()
    end)

    it("stores Android AI data outside the launcher's replaceable assets directory", function()
        local original=package.loaded.android
        package.loaded.android={dir=path.."/files"}
        require("libs/libkoreader-lfs").mkdir(path.."/files")
        local android_store=Store.new()
        package.loaded.android=original
        assert.are.equal(path.."/files/../anxui-ai",android_store.path)
        require("libs/libkoreader-lfs").rmdir(android_store.path)
        require("libs/libkoreader-lfs").rmdir(path.."/files")
    end)

    it("retains the most recent ten sessions across a fresh store instance", function()
        for index=1,12 do assert.is_true(store:saveSession({id=tostring(index),title="x",messages={}})) end
        local history=assert(Store.new(path)):history()
        assert.are.equal(10,#history);assert.are.equal("12",history[1].id);assert.are.equal("3",history[10].id)
    end)

    local function session()
        assert.is_true(store:write("config",{schema=1,endpoint="https://example.test/v1",model="test",api_key="fixture-secret"}))
        local captured={}
        local transport={start=function(scope,config,messages,protocol,callbacks)
            captured.callbacks,captured.messages,captured.scope=callbacks,messages,scope
            scope:defer(function() captured.cancelled=true end)
            return {cancel=function() captured.cancelled=true end}
        end}
        return Session.new(store,Protocol,transport,Lifecycle.new),captured
    end

    local function attachment(name)
        return {kind="selection",file=name..".epub",title=name,page=3,text="Excerpt "..name,
            sources={{id="S1",file=name..".epub",title=name,label="Selection",page=3,
                xpointer="/body/"..name,signature="123:456",note={datetime="saved-"..name}}}}
    end

    it("changes or removes attachments without losing conversation identity or messages", function()
        local chat,captured=session();chat:fresh(attachment("First"));chat:send("Explain")
        captured.callbacks.delta("Saved reply");captured.callbacks.done()
        local id,title,book,messages=chat.data.id,chat.data.title,chat.data.book,chat.data.messages
        chat.data.draft="Unsent draft"
        local changed=0;chat.changed=function() changed=changed+1 end
        local next_context=attachment("Second")
        assert.is_true(chat:setContext(next_context))
        next_context.sources[1].title="Changed elsewhere"
        assert.are.equal("Second",chat.data.context.sources[1].title)
        assert.is_true(chat:setContext(nil))
        assert.are.equal(id,chat.data.id);assert.are.equal(title,chat.data.title)
        assert.are.equal(book,chat.data.book);assert.are.equal(messages,chat.data.messages)
        assert.are.equal("Unsent draft",chat.data.draft);assert.are.equal(2,changed)
        local saved=assert(Store.new(path)):history()[1]
        assert.is_nil(saved.context);assert.are.equal("First.epub",saved.book.file)
        assert.are.equal("Saved reply",saved.messages[2].content)
        assert.is_true(chat:send("Next"))
        assert.are.equal(4,#captured.messages) -- system, previous turn, new question
        for _,message in ipairs(captured.messages) do
            assert.is_nil(message.content:find("<book_excerpt>",1,true))
        end
        chat:close()
    end)

    it("rejects attachment changes while sending and restores attachments on storage failure", function()
        local chat,captured=session();chat:fresh(attachment("First"));chat:send("Explain")
        local context=chat.data.context
        local ok,err=chat:setContext(nil)
        assert.is_false(ok);assert.are.equal("busy",err);assert.are.equal(context,chat.data.context)
        captured.callbacks.done()
        local original_save=store.saveSession
        store.saveSession=function() return false end
        ok,err=chat:setContext(attachment("Second"))
        store.saveSession=original_save
        assert.is_false(ok);assert.are.equal("storage_error",err)
        assert.are.equal(context,chat.data.context)
        assert.are.equal("First",store:history()[1].context.title)
        assert.is_false(chat:setContext({title="Invalid",text=string.rep("x",16002)}))
        assert.are.equal(context,chat.data.context)
        chat:close()
    end)

    it("freezes each reply's sources and parallel original across attachment changes and reload", function()
        local chat,captured=session();local first=attachment("First");chat:fresh(first)
        chat:send("Translate",{mode="parallel"})
        local answer=chat.data.messages[2]
        first.sources[1].note.datetime="mutated";first.sources[1].file="different.epub";first.text="Changed text"
        assert.are.equal("First.epub",answer.sources[1].file)
        assert.are.equal("saved-First",answer.sources[1].note.datetime)
        assert.are.equal("Excerpt First",answer.source_text)
        captured.callbacks.delta("Translation");captured.callbacks.done()
        assert.is_true(chat:setContext(attachment("Second")))
        assert.is_true(chat:send("Report",{mode="report"}))
        captured.callbacks.delta("Report [S1]");captured.callbacks.done()
        assert.are.equal("First.epub",answer.sources[1].file)
        assert.are.equal("Second.epub",chat.data.messages[4].sources[1].file)
        local reloaded=assert(Store.new(path)):history()[1]
        chat:load(reloaded)
        assert.are.equal("Excerpt First",chat.data.messages[2].source_text)
        assert.are.equal("First.epub",chat.data.messages[2].sources[1].file)
        assert.are.equal("Second.epub",chat.data.messages[4].sources[1].file)
        chat:close()
    end)

    it("retries and edits using the current attachment while preserving earlier reply snapshots", function()
        local chat,captured=session();chat:fresh(attachment("First"));chat:send("First question")
        captured.callbacks.delta("First answer");captured.callbacks.done()
        chat:setContext(attachment("Second"));chat:send("Translate",{mode="parallel"})
        captured.callbacks.delta("Second answer");captured.callbacks.done()
        chat:load(assert(Store.new(path)):history()[1])
        assert.is_true(chat:setContext(nil));assert.is_true(chat:retry())
        assert.are.same({},chat.data.messages[4].sources);assert.is_nil(chat.data.messages[4].source_text)
        for _,message in ipairs(captured.messages) do
            assert.is_nil(message.content:find("Excerpt ",1,true))
            assert.is_nil(message.content:find("Available sources",1,true))
        end
        captured.callbacks.delta("Without reference");captured.callbacks.done()
        assert.is_true(chat:setContext(attachment("Third")))
        assert.is_true(chat:editLast("Edited question"))
        assert.are.equal("Third.epub",chat.data.messages[4].sources[1].file)
        assert.are.equal("Excerpt Third",chat.data.messages[4].source_text)
        assert.are.equal("First.epub",chat.data.messages[2].sources[1].file)
        assert.is_truthy(captured.messages[2].content:find("Excerpt Third",1,true))
        assert.is_nil(captured.messages[2].content:find("Third.epub",1,true))
        chat:close()
    end)

    it("keeps legacy replies without sources distinct from newly attached material", function()
        local chat,captured=session()
        chat:load({id="legacy",title="Old",messages={{role="user",content="Old question"},
            {role="assistant",content="Old answer [S1]",status="complete"}}})
        assert.is_true(chat:setContext(attachment("New")))
        assert.is_nil(chat.data.messages[2].sources)
        chat:send("New question");captured.callbacks.done()
        local saved=assert(Store.new(path)):history()[1]
        assert.is_nil(saved.messages[2].sources)
        assert.are.equal("New.epub",saved.messages[4].sources[1].file)
        chat:close()
    end)

    it("validates saved reply sources and bounded originals while accepting legacy history", function()
        local data={schema=1,sessions={{id="check",title="Check",messages={{role="assistant",content="Reply"}}}}}
        local answer=data.sessions[1].messages[1]
        local function valid()
            assert.is_true(store:write("history",data))
            return store:history()~=nil
        end
        assert.is_true(valid())
        answer.sources=attachment("Valid").sources;answer.source_text=string.rep("x",16001)
        assert.is_true(valid())
        answer.source_text=string.rep("x",16002);assert.is_false(valid());answer.source_text=nil
        answer.sources[1].page={};assert.is_false(valid())
        answer.sources=attachment("Valid").sources;answer.sources[1].id="https://example.test"
        assert.is_false(valid())
        answer.sources=attachment("Valid").sources;answer.sources[2]=attachment("Other").sources[1]
        assert.is_false(valid()) -- duplicate local IDs cannot identify a unique source
        answer.sources={}
        for index=1,31 do
            answer.sources[index]=attachment("Book"..index).sources[1];answer.sources[index].id="S"..index
        end
        assert.is_false(valid())
    end)

    it("keeps cancellation, retry, persistence and late responses tied to the correct session", function()
        local chat,captured=session();chat:fresh({kind="selection",title="Book",page=1,text="Reference"})
        assert.is_true(chat:send("Explain"));captured.callbacks.delta("Partial")
        local stale=captured.callbacks.delta
        chat:stop();assert.is_true(captured.cancelled)
        assert.are.equal("cancelled",chat.data.messages[2].status)
        stale(" late");assert.are.equal("Partial",chat.data.messages[2].content)
        assert.is_true(chat:retry());assert.are.equal(2,#chat.data.messages)
        captured.callbacks.delta("Final");captured.callbacks.done()
        assert.are.equal("complete",chat.data.messages[2].status)
        assert.are.equal("Final",assert(Store.new(path)):history()[1].messages[2].content)
        assert.is_truthy(captured.messages[2].content:find("Reference",1,true))
        assert.are.equal("Explain",captured.messages[#captured.messages].content)
        chat:close()
    end)

    it("reports HTTP failures, keeps partial answers, and rejects a second in-flight request", function()
        local chat,captured=session();chat:fresh()
        chat:send("Hello");assert.is_false(chat:send("second"))
        captured.callbacks.delta("part");captured.callbacks.done("http_error",429)
        assert.are.equal(429,chat.http_code);assert.are.equal("error",chat.data.messages[2].status)
        chat:send("Next")
        for _,message in ipairs(captured.messages) do assert.are_not.equal("part",message.content) end
        chat:close();assert.is_true(captured.cancelled)
    end)

    it("does not start a request until configuration is usable", function()
        local called=false
        local chat=Session.new(store,Protocol,{start=function() called=true end},Lifecycle.new)
        chat:fresh();local ok,err=chat:send("Hello")
        assert.is_false(ok);assert.are.equal("configure_ai",err);assert.is_false(called)
    end)

    it("does not transmit a message when history cannot be persisted", function()
        local chat,captured=session();chat:fresh()
        local f=assert(io.open(path.."/history.json","w"));f:write("corrupt");f:close()
        local ok,err=chat:send("Hello")
        assert.is_false(ok);assert.are.equal("storage_error",err)
        assert.is_nil(captured.messages);assert.are.equal(0,#chat.data.messages)
    end)

    local function chapter(text, pages, has_toc)
        local ReaderUI=require("apps/reader/readerui")
        local original=ReaderUI.instance
        local calls,result,err=0,nil,nil
        local ui={getCurrentPage=function() return 1 end,doc_props={title="Test"},
            document={file="test.pdf",getPageCount=function() return pages end,
                getPageTextBoxes=function() calls=calls+1;return text and {{{word=text}}} or {} end,
                getTextBoxes=function() error("must not trigger OCR") end},
            toc={fillToc=function() end,getTocIndexByPage=function() return has_toc and 1 end,
                toc={{page=1,title="Chapter"}}}}
        local scope=Lifecycle.new();ReaderUI.instance=ui
        local ok,failure=pcall(function()
            dofile("plugins/anxui.koplugin/ai/context.lua").chapter(ui,scope,Protocol,function(value,reason) result,err=value,reason end)
            for __=1,40 do
                local task=next(scope.tasks);if not task then break end
                UIManager:unschedule(task);task()
            end
        end)
        scope:close();ReaderUI.instance=original
        assert.is_true(ok,failure)
        return result,err,calls
    end

    it("refuses empty text layers without triggering synchronous OCR", function()
        local value,err,calls=chapter(nil,10,false)
        assert.is_nil(value);assert.are.equal("context_empty",err);assert.are.equal(1,calls)
    end)

    it("bounds chapter extraction by UTF-8 byte count and page count", function()
        local value,__,calls=chapter(string.rep("你",6000),100,true)
        assert.is_true(value.truncated);assert.is_true(#value.text<=16001);assert.are.equal(1,calls)
        assert.are.equal(value.text,require("util").fixUtf8(value.text,"?"))
        value,__,calls=chapter("small",100,true)
        assert.is_true(value.truncated);assert.are.equal(30,calls)
    end)

    it("migrates one legacy configuration to profiles without losing its credential", function()
        store:write("config",{schema=1,endpoint="https://example.test/v1",model="legacy",api_key="old-secret"})
        local p=store:config();assert.are.equal("default",p.id);assert.are.equal("old-secret",p.api_key)
        assert.is_true(store:saveProfile({id="second",name="DeepSeek",endpoint="https://api.deepseek.com",model="test",api_key="new-secret",provider="deepseek"}))
        assert.are.equal(2,#store:profiles().profiles)
        assert.are.equal("second",store:profiles().active)
        assert.is_true(store:selectProfile("default"));assert.are.equal("old-secret",store:config().api_key)
        assert.is_true(store:deleteProfile("default"));assert.are.equal("second",store:config().id)
        assert.is_false(store:deleteProfile("second"))
    end)

    it("edits the last question without duplicating turns and restores it if validation fails", function()
        local chat,captured=session();chat:fresh();chat:send("old")
        captured.callbacks.delta("answer");captured.callbacks.done()
        assert.is_false(chat:editLast(""));assert.are.equal("old",chat.data.messages[1].content)
        assert.is_true(chat:editLast("new"));assert.are.equal(2,#chat.data.messages)
        assert.are.equal("new",captured.messages[#captured.messages].content)
        assert.are.equal("new",chat.data.title);chat:stop()
    end)

    it("renames history while preserving its contents", function()
        store:saveSession({id="1",title="Original",messages={{role="user",content="Body"}}})
        assert.is_true(store:renameSession("1","Renamed"))
        assert.are.equal("Body",store:history()[1].messages[1].content)
        assert.are.equal("Renamed",store:history()[1].title)
        assert.is_false(store:renameSession("1"," "))
    end)

    it("reassembles tool calls and rejects missing indices and duplicate ids", function()
        local parser=Protocol.decoder(function() end)
        local json=require("json")
        local function feed(parts)
            local wire="data: "..json.encode({choices={{delta={tool_calls=parts},finish_reason="tool_calls"}}}).."\n\n"
            for index=1,#wire,3 do parser:feed(wire:sub(index,index+2)) end
        end
        feed({{index=0,id="call-1",["function"]={name="search_index",arguments='{"query":'}}})
        feed({{index=0,["function"]={arguments='"中文"}'}}})
        assert.is_true(parser:validTools())
        assert.are.equal('中文',json.decode(parser.tool_calls[1]["function"].arguments).query)
        feed({{index=2,id="call-2",["function"]={name="search_index",arguments="{}"}}})
        assert.is_false(parser:validTools())
        feed({{index=1,id="call-1",["function"]={name="search_index",arguments="{}"}}})
        assert.is_false(parser:validTools())
    end)

    it("bounds tool rounds, merges cited passages and cancels pending tools", function()
        local chat,captured=session();chat:fresh();chat.data.tools_enabled=true
        local done
        chat.tools={definitions={{type="function"}},execute=function(self,call,scope,callback) done=callback end}
        local call={id="call-1",["function"]={name="search_index",arguments="{}"}}
        assert.is_true(chat:send("Search"))
        captured.callbacks.done(nil,nil,nil,{call})
        assert.are.equal("search_index",chat.using_tool)
        done({context={text="[S1] Evidence",sources={{id="S1",file="book",title="Book",label="Search",page=2}}}})
        assert.are.equal("tool",captured.messages[#captured.messages].role)
        assert.are.equal("S1",chat.data.context.sources[1].id)
        for index=1,2 do captured.callbacks.done(nil,nil,nil,{call});done({data={found=true}}) end
        captured.callbacks.done(nil,nil,nil,{call})
        assert.are.equal("tool_limit",chat.error);assert.is_false(chat.running)
        chat:fresh();chat.data.tools_enabled=true;chat:send("Again")
        captured.callbacks.done(nil,nil,nil,{call})
        chat:stop();done({data={late=true}})
        assert.are.equal("cancelled",chat.data.messages[2].status)
        assert.is_nil(chat.data.context)
    end)

    it("adds remapped tool sources only to the active reply and its bounded parallel original", function()
        local chat,captured=session();chat:fresh(attachment("First"));chat:send("Explain")
        captured.callbacks.done()
        chat:setContext(attachment("Second"));chat.data.tools_enabled=true
        local done
        chat.tools={definitions={{type="function"}},execute=function(self,call,scope,callback) done=callback end}
        chat:send("Translate with evidence",{mode="parallel"})
        local call={id="call-1",["function"]={name="search_index",arguments="{}"}}
        captured.callbacks.done(nil,nil,nil,{call})
        local incoming=attachment("Third");incoming.text="[S1] "..string.rep("中",7000)
        done({context=incoming})
        local answer=chat.data.messages[4]
        assert.are.equal(2,#answer.sources);assert.are.equal("S2",answer.sources[2].id)
        assert.are.equal("Third.epub",answer.sources[2].file)
        assert.is_truthy(answer.source_text:find("[S2]",1,true));assert.is_true(#answer.source_text<=16001)
        assert.are.equal(1,#chat.data.messages[2].sources)
        assert.are.equal("First.epub",chat.data.messages[2].sources[1].file)
        incoming.sources[1].file="changed.epub"
        chat.data.context.sources[2].title="Changed current source"
        assert.are.equal("Third",answer.sources[2].title);assert.are.equal("Third.epub",answer.sources[2].file)
        captured.callbacks.delta("Translation");captured.callbacks.done()
        assert.are.equal("Third.epub",assert(Store.new(path)):history()[1].messages[4].sources[2].file)
        chat:close()
    end)

    it("indexes and searches two books without changing them and skips stale sources", function()
        local Context=dofile("plugins/anxui.koplugin/ai/context.lua")
        local worker={start=function(scope,operation,done) done(operation()) end}
        local context={signature=Context.signature,pageText=function(doc,page) return doc.text,true end}
        local index=dofile("plugins/anxui.koplugin/ai/bookindex.lua").new(path.."/books.sqlite3",context,Protocol,worker)
        local scope=Lifecycle.new()
        for n=1,2 do
            local file=path.."/book"..n;local f=assert(io.open(file,"w"));f:write("unchanged");f:close()
            index:build({doc_props={title="Book "..n},document={file=file,text="Shared evidence "..n,getPageCount=function() return 1 end}},scope,
                function(result) assert.are.equal(1,result.pages) end)
        end
        assert.are.equal(2,#index:list())
        index:search("Shared",scope,function(result) assert.are.equal(2,#result.sources) end)
        local f=assert(io.open(path.."/book1","a"));f:write("changed size");f:close()
        index:search("Shared",scope,function(result) assert.are.equal(1,#result.sources);assert.are.equal("Book 2",result.sources[1].title) end)
        index:remove(path.."/book2")
        f=assert(io.open(path.."/book2"));assert.are.equal("unchanged",f:read("*a"));f:close()
        assert.are.equal(1,#index:list());scope:close()
    end)

    it("rejects invented tools and encodes object schemas for no-argument tools", function()
        local tools=dofile("plugins/anxui.koplugin/ai/readingtools.lua").new({})
        local wire=require("json").encode(tools.definitions)
        assert.is_truthy(wire:find('"properties":{}',1,true))
        local scope=Lifecycle.new()
        tools:execute({["function"]={name="run_shell",arguments='{}'}},scope,function(result,err)
            assert.is_nil(result);assert.are.equal("unsupported_tool",err)
        end)
        tools:execute({["function"]={name="search_index",arguments='{"query":12}'}},scope,function(result,err)
            assert.is_nil(result);assert.are.equal("invalid_tool_arguments",err)
        end)
        scope:close()
    end)

    it("renders Markdown structure without loading resources or enabling model links", function()
        local md=dofile("plugins/anxui.koplugin/ai/markdown.lua")
        local html=md.html('# Heading\n\n**Bold**\n\n- One\n- Two\n\n![x](file:///secret)\n<a href="https://example.test">Link</a><img src="/etc/passwd">')
        assert.is_truthy(html:find('<h1>Heading</h1>',1,true))
        assert.is_truthy(html:find('<strong>Bold</strong>',1,true))
        assert.is_truthy(html:find('<li>',1,true))
        assert.is_nil(html:find('<img',1,true));assert.is_nil(html:find('href=',1,true));assert.is_nil(html:find('src=',1,true))
        assert.is_truthy(md.html('```lua\nprint("<x>")\n```'):find('<pre>',1,true))
        html=md.document({mode="parallel",source_text="<img src='secret'>",content="Translated"},function(s) return s end)
        assert.is_nil(html:find("<img",1,true));assert.is_truthy(html:find("<table",1,true))
        html=md.document({mode="mindmap",content="- Root\n  - Child\n- Next"},function(s) return s end)
        assert.is_truthy(html:find("border-left",1,true));assert.is_truthy(html:find("Child",1,true))
    end)
end)
