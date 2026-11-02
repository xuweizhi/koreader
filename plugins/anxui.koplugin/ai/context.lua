local Context = {}
local lfs = require("libs/libkoreader-lfs")

function Context.signature(file)
    local attr=lfs.attributes(file)
    return attr and attr.mode=="file" and (tostring(attr.size)..":"..tostring(attr.modification)) or nil
end

local function source(ui, page, xpointer, label)
    return {id="S1",file=ui.document.file,title=ui.doc_props and ui.doc_props.title or "",
        page=page,xpointer=xpointer,label=label or "",signature=Context.signature(ui.document.file)}
end

local function documentEnd(doc)
    local saved = doc:getXPointer()
    local ok, result = pcall(function()
        doc:gotoPage(doc:getPageCount())
        local size = require("device").screen:getSize()
        local selection = doc:getTextFromPositions({x=0,y=0},{x=size.w,y=size.h},true)
        return selection and selection.pos1
    end)
    -- No ReaderUI event or settings write: restore the engine before yielding.
    doc:gotoXPointer(saved)
    if ok then return result end
end

local function pageText(doc, page, first, last)
    if doc.getPageXPointer then
        local a = first or doc:getPageXPointer(page)
        local b = last or (page < doc:getPageCount() and doc:getPageXPointer(page + 1) or documentEnd(doc))
        if not a or not b then return "", false end
        return doc:getTextFromXPointers(a, b, false) or "", true
    end
    local lines = {}
    -- Use the embedded text layer. getTextBoxes() may trigger synchronous OCR
    -- on scanned PDFs, which would block the UI and defeat cancellation.
    for _, line in ipairs(doc.getPageTextBoxes and doc:getPageTextBoxes(page) or {}) do
        local words = {}
        for _, word in ipairs(line) do if word.word then words[#words + 1] = word.word end end
        lines[#lines + 1] = table.concat(words, " ")
    end
    return table.concat(lines, "\n"), true
end

function Context.selection(ui, text, protocol, anchor)
    return {kind="selection", title=ui.doc_props and ui.doc_props.title or "", file=ui.document.file,
        page=ui:getCurrentPage(), text=protocol.clip(require("util").fixUtf8(text, "?"), 16000), truncated=#text > 16000,
        sources={source(ui,ui:getCurrentPage(),type(anchor)=="string" and anchor
            or ui.document.getXPointer and ui.document:getXPointer(),"Selection")}}
end

function Context.chapter(ui, scope, protocol, done, requested_index)
    local doc, toc = ui.document, ui.toc
    toc:fillToc()
    local current = ui:getCurrentPage()
    local index = requested_index or toc:getTocIndexByPage(doc.getXPointer and doc:getXPointer() or current)
    if requested_index and not toc.toc[requested_index] then return done(nil,"context_error") end
    local chapter = index and toc.toc[index]
    local following = index and toc.toc[index + 1]
    local start = chapter and chapter.page or current
    local last = following and following.page or doc:getPageCount()
    local first_xp, last_xp = chapter and chapter.xpointer, following and following.xpointer
    local context = {kind=chapter and "chapter" or "page", file=doc.file,
        title=ui.doc_props and ui.doc_props.title or "", chapter=chapter and chapter.title,
        page=start, text="", truncated=false,
        sources={source(ui,start,first_xp,chapter and chapter.title or "Page")}}
    if not chapter then last = current; last_xp = nil end
    -- For page-based books the next chapter's first page belongs to that chapter.
    if following and not doc.getPageXPointer then last = math.max(start, last - 1) end
    local ending, page = math.min(last, start + 29), start
    context.truncated = ending < last
    local function batch()
        if ui.tearing_down or require("apps/reader/readerui").instance ~= ui then return done(nil, "stale_session") end
        local ok, text, complete = pcall(pageText, doc, page,
            page == start and first_xp or nil, page == last and last_xp or nil)
        if not ok then return done(nil, "context_error") end
        if not complete then context.truncated = true end
        text = require("util").fixUtf8(text, "?")
        local remaining = math.max(0, 16000 - #context.text)
        context.text = context.text .. protocol.clip(text, remaining) .. "\n"
        if #text > remaining then context.truncated = true end
        page = page + 1
        if page > ending or #context.text >= 16000 then
            context.truncated = context.truncated or page <= ending
            if not context.text:find("%S") then return done(nil, "context_empty") end
            done(context)
        else scope:later(.01, batch) end
    end
    scope:later(0, batch)
end

function Context.notes(ui,protocol,selected)
    local notes=selected and {selected} or ui.annotation.annotations
    local result={kind="notes",file=ui.document.file,title=ui.doc_props and ui.doc_props.title or "",
        text="",sources={},truncated=false}
    for _,note in ipairs(notes or {}) do
        local text=(note.text or "").."\n"..(note.note or "")
        if text:find("%S") then
            if #result.sources>=30 or #result.text>=15000 then result.truncated=true;break end
            local page=type(note.page)=="number" and note.page or ui.document:getPageFromXPointer(note.page)
            local ref=source(ui,page,type(note.page)=="string" and note.page or nil,"Note")
            ref.id="S"..tostring(#result.sources+1)
            ref.note={page=note.page,pos0=note.pos0,pos1=note.pos1,datetime=note.datetime,drawer=note.drawer}
            local excerpt=protocol.clip(text,math.max(0,15800-#result.text))
            result.truncated=result.truncated or #excerpt<#text
            result.text=result.text.."["..ref.id.."] "..excerpt.."\n"
            result.sources[#result.sources+1]=ref
        end
    end
    if #result.sources==0 then return nil,"context_empty" end
    return result
end

function Context.search(ui,query,scope,protocol,worker,done)
    query=query:match("^%s*(.-)%s*$")
    if query=="" or #query>200 then return done(nil,"input_limit") end
    local doc=ui.document
    local title=ui.doc_props and ui.doc_props.title or ""
    worker.start(scope,function()
        if doc.getPageXPointer then
            local results=doc:findAllText(query,true,28,8,false,0) or {}
            local out={}
            for _,item in ipairs(results) do
                out[#out+1]={page=doc:getPageFromXPointer(item.start),xpointer=item.start,
                    text=(item.prev_text or "").." "..(item.matched_word_prefix or "")..(item.matched_text or "")
                        ..(item.matched_word_suffix or "").." "..(item.next_text or "")}
            end
            return {rows=out,truncated=#out>=8}
        end
        local out,limit={},math.min(doc:getPageCount(),2000)
        for page=1,limit do
            local text=pageText(doc,page)
            local start=text:lower():find(query:lower(),1,true)
            if start then
                out[#out+1]={page=page,text=require("util").fixUtf8(text:sub(math.max(1,start-250),start+1000),"?")}
                if #out>=8 then return {rows=out,truncated=true} end
            end
        end
        return {rows=out,truncated=limit<doc:getPageCount()}
    end,scope:guard(function(found,err)
        if not found then return done(nil,err or "context_empty") end
        if ui.tearing_down or require("apps/reader/readerui").instance~=ui then return done(nil,"stale_session") end
        local result={kind="search",file=doc.file,title=title,chapter=query,text="",sources={},truncated=found.truncated}
        for index,item in ipairs(found.rows) do
            local ref=source(ui,item.page,item.xpointer,query);ref.id="S"..index
            result.sources[#result.sources+1]=ref
            result.text=result.text.."["..ref.id.."] "..protocol.clip(item.text,1700).."\n"
        end
        if #result.sources==0 then return done(nil,"context_empty") end
        done(result)
    end))
end

Context.pageText=pageText

return Context
