-- Render model Markdown using KOReader's bundled parser. Keep only structural
-- tags: no images, external resources, styles, or actionable links from a model.
-- Navigation links are created separately, from trusted local source snapshots.
local Markdown = {}
local allowed = {p=true,br=true,strong=true,b=true,em=true,i=true,pre=true,code=true,
    h1=true,h2=true,h3=true,h4=true,h5=true,h6=true,ul=true,ol=true,li=true,
    blockquote=true,hr=true,table=true,thead=true,tbody=true,tr=true,td=true,th=true,del=true}
function Markdown.html(text)
    local output,lines,fence={}, {}, nil
    local function flush(code)
        local value=table.concat(lines,"\n");lines={}
        if value=="" then return end
        if code then output[#output+1]="<pre><code>"..require("util").htmlEscape(value).."</code></pre>";return end
        -- The bundled parser treats bare [S1] as a shortcut link and drops
        -- its brackets. Protect literal citation labels through parsing,
        -- including inline code, then restore them after stripping tags.
        local prefix, citations = "ANXLOCALCITATION", {}
        while value:find(prefix,1,true) do prefix=prefix.."X" end
        value=value:gsub("%[(S%d+)%]",function(id)
            citations[#citations+1]="["..id.."]"
            return prefix..#citations.."END"
        end)
        local ok,html=pcall(function() return require("apps/filemanager/lib/md")(value) end)
        if not ok or type(html)~="string" then html="<p>"..require("util").htmlEscape(value).."</p>" end
        html=html:gsub("<([^>]+)>",function(raw)
            local closing,name=raw:match("^%s*(/?)%s*([%a%d]+)")
            name=name and name:lower()
            if allowed[name] then return "<"..closing..name..">" end
            return ""
        end)
        output[#output+1]=html:gsub(prefix.."(%d+)END",function(index) return citations[tonumber(index)] or "" end)
    end
    for line in (text.."\n"):gmatch("(.-)\n") do
        local marker=line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
        if marker and not fence then flush(false);fence=marker:sub(1,1)
        elseif marker and marker:sub(1,1)==fence then flush(true);fence=nil
        else lines[#lines+1]=line end
    end
    flush(fence~=nil)
    return table.concat(output,"\n")
end
function Markdown.sourceForLink(link, sources)
    local id = type(link) == "table" and type(link.uri) == "string" and link.uri:match("^anx%-source:(S%d+)$")
    if not id then return end
    for _, ref in ipairs(sources or {}) do
        if ref.id == id then return ref end
    end
end

function Markdown.citations(html, sources)
    local ids = {}
    for _, ref in ipairs(sources or {}) do
        if type(ref.id) == "string" and ref.id:match("^S%d+$") then ids[ref.id] = true end
    end
    if not next(ids) then return html end
    local code_depth = 0
    -- Only text nodes outside code/pre are eligible. The input has already
    -- been sanitized, or was produced by the local structured renderer.
    return (html .. "<anx-end>"):gsub("(.-)(<[^>]*>)", function(text, tag)
        if code_depth == 0 then
            text = text:gsub("%[(S%d+)%]", function(id)
                if ids[id] then return '<a href="anx-source:' .. id .. '">[' .. id .. ']</a>' end
                return "[" .. id .. "]"
            end)
        end
        local closing, name = tag:match("^<(/?)([%w]+)")
        if name == "pre" or name == "code" then
            code_depth = math.max(0, code_depth + (closing == "/" and -1 or 1))
        end
        return text .. (tag == "<anx-end>" and "" or tag)
    end)
end

function Markdown.preview(text, width, font_size, sources, on_source)
    local widget = require("ui/widget/htmlboxwidget"):new{dimen=require("ui/geometry"):new{w=width,h=2048}}
    if on_source then
        widget.html_link_tapped_callback = function(link)
            local ref = Markdown.sourceForLink(link, sources)
            if ref then on_source(ref) end
        end
    end
    local ok=pcall(widget.setContent,widget,Markdown.citations(Markdown.html(text), sources), [[@page{margin:0}body{margin:0;line-height:1.3}
        p{margin:0 0 .5em}h1,h2,h3{margin:.3em 0;font-size:1.15em}
        pre{white-space:pre-wrap;background:#f3f3f3}code{font-family:monospace}
        blockquote{margin:.4em;padding-left:.5em;border-left:2px solid #999}
        td,th{padding:.2em;border:1px solid #aaa}]], font_size)
    if not ok then widget:free();return nil end
    local height = widget:getSinglePageHeight()
    if not height then widget:free(); return nil end
    widget.dimen.h = math.max(font_size, height + 2)
    return widget
end

function Markdown.document(entry, translate)
    if entry.mode=="parallel" and entry.source_text then
        local escape=require("util").htmlEscape
        -- MuPDF keeps a table row together. Split long passages into bounded
        -- rows so a whole chapter cannot push both columns off the first page.
        local function chunks(text)
            local parts={}
            for line in (text.."\n"):gmatch("(.-)\n") do
                while #line>0 do
                    local length=math.min(#line,240)
                    while length>0 and line:byte(length+1) and line:byte(length+1)>=128 and line:byte(length+1)<=191 do length=length-1 end
                    parts[#parts+1]=escape(line:sub(1,length));line=line:sub(length+1)
                end
            end
            return parts
        end
        local original,translation=chunks(entry.source_text),chunks(entry.content)
        local rows={'<table style="width:100%;table-layout:fixed"><tr><th>'..escape(translate("Original text"))
            ..'</th><th>'..escape(translate("Translation"))..'</th></tr>'}
        for index=1,math.max(#original,#translation) do
            rows[#rows+1]='<tr><td style="width:50%;vertical-align:top;border:1px solid #999;padding:.4em">'
                ..(original[index] or "")..'</td><td style="width:50%;vertical-align:top;border:1px solid #999;padding:.4em">'
                ..(translation[index] or "")..'</td></tr>'
        end
        rows[#rows+1]='</table>';return Markdown.citations(table.concat(rows), entry.sources)
    end
    if entry.mode=="mindmap" then
        local output,depth,count={},0,0
        for line in (entry.content.."\n"):gmatch("(.-)\n") do
            local indent,text=line:match("^(%s*)[-*+]%s+(.+)$")
            if text then
                count=count+1;if count>100 then break end
                local target=math.min(6,math.floor(#indent/2)+1,depth+1)
                local previous=depth
                while depth<target do output[#output+1]='<ul style="border-left:2px solid #888;padding-left:1.2em">';depth=depth+1 end
                while depth>target do output[#output+1]='</li></ul>';depth=depth-1 end
                if target<=previous then output[#output+1]='</li>' end
                output[#output+1]='<li style="padding:.3em">'..require("util").htmlEscape(text)
            end
        end
        if count>0 then
            while depth>0 do output[#output+1]='</li></ul>';depth=depth-1 end
            return Markdown.citations(table.concat(output), entry.sources)
        end
    end
    return Markdown.citations(Markdown.html(entry.content), entry.sources)
end
return Markdown
