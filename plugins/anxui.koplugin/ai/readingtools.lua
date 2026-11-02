-- Explicit allowlist of read-only tools; model output cannot name a file,
-- execute Lua/shell, modify the library, or trigger arbitrary HTTP requests.
local Tools = {}
Tools.__index = Tools
local function definition(name,description,properties,required)
    return {type="function",["function"]={name=name,description=description,parameters={type="object",
        properties=properties,required=required,additionalProperties=false}}}
end
local query={type="string",description="A literal word or short phrase, at most 200 UTF-8 bytes."}
function Tools.new(chat)
    local self=setmetatable({chat=chat},Tools)
    self.definitions={
        definition("search_index","Find source passages in books the user has explicitly indexed on this device.",{query=query},{"query"}),
        definition("list_indexed_books","List the locally indexed books, their completeness and freshness.",{}),
    }
    if chat.reader_ui then
        self.definitions[#self.definitions+1]=definition("current_book_toc","Read the current book's table of contents.",{})
        self.definitions[#self.definitions+1]=definition("read_chapter","Read a bounded excerpt of a chapter from the current book.",
            {chapter={type="integer",minimum=1,description="Chapter number from current_book_toc."}},{"chapter"})
        self.definitions[#self.definitions+1]=definition("search_current_book","Search literal text in the current book.",{query=query},{"query"})
        self.definitions[#self.definitions+1]=definition("current_book_notes","Read up to 30 existing notes from the current book.",{})
    end
    return self
end
function Tools:execute(call,scope,done)
    local name=call["function"] and call["function"].name
    local allowed=false
    for _,tool in ipairs(self.definitions) do if tool["function"].name==name then allowed=true end end
    if not allowed then return done(nil,"unsupported_tool") end
    local ok,args=pcall(require("json").decode,call["function"].arguments or "{}")
    if not ok or type(args)~="table" then return done(nil,"invalid_tool_arguments") end
    if name=="search_index" or name=="search_current_book" then
        if type(args.query)~="string" or not args.query:find("%S") or #args.query>200 then return done(nil,"invalid_tool_arguments") end
    end
    local c=self.chat
    if name=="search_index" then
        c:index():search(args.query,scope,function(context,err) done(context and {context=context} or nil,err) end)
    elseif name=="list_indexed_books" then
        local books=c:index():list();local result={}
        for index,book in ipairs(books) do
            if index>20 then break end
            result[#result+1]={title=book.title,pages=book.pages,total=book.total,truncated=book.truncated,needs_refresh=book.stale}
        end
        done({data=result})
    elseif not c.reader_ui or c.reader_ui.tearing_down or require("apps/reader/readerui").instance~=c.reader_ui then done(nil,"stale_session")
    elseif name=="current_book_toc" then
        c.reader_ui.toc:fillToc()
        local result={}
        for index,item in ipairs(c.reader_ui.toc.toc) do
            if index>100 then break end
            result[#result+1]={chapter=index,title=c.protocol.clip(item.title or "",120),page=item.page}
        end
        done({data=result})
    elseif name=="read_chapter" then
        if type(args.chapter)~="number" or args.chapter%1~=0 or args.chapter<1 then return done(nil,"invalid_tool_arguments") end
        c.context_module.chapter(c.reader_ui,scope,c.protocol,function(context,err) done(context and {context=context} or nil,err) end,args.chapter)
    elseif name=="search_current_book" then
        c.context_module.search(c.reader_ui,args.query,scope,c.protocol,c.worker,function(context,err) done(context and {context=context} or nil,err) end)
    elseif name=="current_book_notes" then
        local context,err=c.context_module.notes(c.reader_ui,c.protocol)
        done(context and {context=context} or nil,err)
    end
end
return Tools
