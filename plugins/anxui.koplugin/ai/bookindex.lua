-- An explicit, disposable local text index. Never opens another book or changes
-- a reader's settings. Only the currently opened document can be indexed.
local Index = {}
Index.__index = Index
local function open(path)
    local db=require("lua-ljsqlite3/init").open(path)
    db:set_busy_timeout(500)
    local version=tonumber(db:rowexec("PRAGMA user_version"))
    if version~=0 and version~=1 then db:close();error("unsupported AI index schema") end
    db:exec([[CREATE TABLE IF NOT EXISTS books(file TEXT PRIMARY KEY,title TEXT,signature TEXT,
        pages INTEGER,total INTEGER,bytes INTEGER,truncated INTEGER,updated INTEGER);
        CREATE TABLE IF NOT EXISTS pages(file TEXT,page INTEGER,text TEXT,xpointer TEXT,PRIMARY KEY(file,page));
        PRAGMA user_version=1;]])
    local ffi=require("ffi");ffi.cdef[[int chmod(const char*,unsigned int);]]
    ffi.C.chmod(path,384)
    return db
end
function Index.new(path,context,protocol,worker)
    return setmetatable({path=path,context=context,protocol=protocol,worker=worker},Index)
end
function Index:list()
    local db=open(self.path)
    local statement=db:prepare("SELECT file,title,signature,pages,total,bytes,truncated FROM books ORDER BY updated DESC")
    local result={}
    while true do
        local row=statement:step();if not row then break end
        result[#result+1]={file=row[1],title=row[2],signature=row[3],pages=tonumber(row[4]),total=tonumber(row[5]),
            bytes=tonumber(row[6]),truncated=tonumber(row[7])==1,stale=self.context.signature(row[1])~=row[3]}
    end
    statement:close();db:close();return result
end
function Index:remove(file)
    local db=open(self.path);db:exec("BEGIN")
    for _,table_name in ipairs({"pages","books"}) do
        local statement=db:prepare("DELETE FROM "..table_name.." WHERE file=?")
        statement:bind(file):step();statement:close()
    end
    db:exec("COMMIT");db:close()
end
function Index:build(ui,scope,done)
    local doc,title=ui.document,ui.doc_props and ui.doc_props.title or ""
    self.worker.start(scope,function()
        local db=open(self.path)
        local count=tonumber(db:rowexec("SELECT count(*) FROM books"))
        local exists=db:prepare("SELECT 1 FROM books WHERE file=?"):bind(doc.file)
        local present=exists:step();exists:close()
        if count>=50 and not present then db:close();return {limit=true} end
        local signature=assert(self.context.signature(doc.file))
        db:exec("BEGIN")
        local remove=db:prepare("DELETE FROM pages WHERE file=?"):bind(doc.file);remove:step();remove:close()
        local insert=db:prepare("INSERT INTO pages VALUES(?,?,?,?)")
        local total=doc:getPageCount()
        local bytes,pages,limited=0,0,false
        for page=1,math.min(total,2000) do
            local text,complete=self.context.pageText(doc,page)
            text=require("util").fixUtf8(text,"?")
            local clipped=self.protocol.clip(text,math.max(0,2*1024*1024-bytes))
            local xp=doc.getPageXPointer and doc:getPageXPointer(page) or ""
            insert:bind(doc.file,page,clipped,xp):step();insert:reset():clearbind()
            bytes=bytes+#clipped;pages=page
            limited=limited or not complete or #clipped<#text
            if #clipped<#text or bytes>=2*1024*1024 then break end
        end
        insert:close()
        assert(self.context.signature(doc.file)==signature,"source changed")
        limited=limited or pages<total
        local info=db:prepare("INSERT OR REPLACE INTO books VALUES(?,?,?,?,?,?,?,?)")
        info:bind(doc.file,title,signature,pages,total,bytes,limited and 1 or 0,os.time()):step();info:close()
        db:exec("COMMIT");db:close()
        return {pages=pages,total=total,bytes=bytes,truncated=limited}
    end,scope:guard(done),90)
end
function Index:search(query,scope,done,file)
    if type(query)~="string" or not query:find("%S") or #query>200 then return done(nil,"input_limit") end
    self.worker.start(scope,function()
        local db=open(self.path)
        local stmt=db:prepare([[SELECT p.file,p.page,p.text,p.xpointer,b.title,b.signature
            FROM pages p JOIN books b ON b.file=p.file WHERE instr(lower(p.text),lower(?))>0
            AND (?='' OR p.file=?) ORDER BY b.updated DESC,p.page LIMIT 2000]])
        stmt:bind(query,file or "",file or "")
        local result={kind="collection",file="",title="Indexed books",chapter=query,text="",sources={},truncated=false}
        while true do
            local row=stmt:step();if not row then break end
            if self.context.signature(row[1])==row[6] then
                if #result.sources>=8 then result.truncated=true;break end
                local start=row[3]:lower():find(query:lower(),1,true) or 1
                local text=require("util").fixUtf8(row[3]:sub(math.max(1,start-250),start+1100),"?")
                local id="S"..tostring(#result.sources+1)
                result.sources[#result.sources+1]={id=id,file=row[1],page=tonumber(row[2]),
                    xpointer=row[4]~="" and row[4] or nil,title=row[5],signature=row[6],label=query}
                result.text=result.text.."["..id.."] "..self.protocol.clip(text,1700).."\n"
            end
        end
        stmt:close();db:close();return result
    end,scope:guard(function(result,err)
        if result and #result.sources==0 then return done(nil,"context_empty") end
        done(result,err)
    end))
end
return Index
