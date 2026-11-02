local JSON = require("json")
local Protocol = {}

function Protocol.clip(text, limit)
    if #text <= limit then return text end
    while limit > 0 do
        local byte = text:byte(limit + 1)
        if not byte or byte < 128 or byte > 191 then break end
        limit = limit - 1
    end
    return text:sub(1, limit)
end

function Protocol.endpoint(value)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$"):gsub("/+$", "")
    if #value > 2048 then return nil end
    local url = require("socket.url").parse(value)
    if not url or (url.scheme ~= "https" and url.scheme ~= "http") or not url.host or url.host == ""
        or url.userinfo or url.query or url.fragment or value:find("[%s%c]") then return nil end
    if not value:match("/chat/completions$") then value = value .. "/chat/completions" end
    return value
end

-- Stateful SSE decoding: chunks can split UTF-8, JSON, CRLF or event boundaries.
function Protocol.decoder(emit)
    local parser = {buffer="", data={}, complete=false, bytes=0, text_bytes=0,tool_calls={}}
    local function event()
        local payload = table.concat(parser.data, "\n")
        parser.data = {}
        if payload == "" then return end
        if payload == "[DONE]" then parser.complete = true; return end
        local ok, value = pcall(JSON.decode, payload)
        if not ok or type(value) ~= "table" then error("invalid_stream") end
        if value.error then error("provider_error") end
        local choice = type(value.choices) == "table" and value.choices[1]
        local delta = choice and choice.delta
        if delta and type(delta.content) == "string" then
            parser.text_bytes = parser.text_bytes + #delta.content
            if parser.text_bytes > 32768 then error("response_limit") end
            emit(delta.content)
        end
        for _,part in ipairs(delta and type(delta.tool_calls)=="table" and delta.tool_calls or {}) do
            local index=part.index
            if type(index)~="number" or index%1~=0 or index<0 or index>3 then error("invalid_tool_call") end
            local call=parser.tool_calls[index+1] or {id="",type="function",["function"]={name="",arguments=""}}
            parser.tool_calls[index+1]=call
            if type(part.id)=="string" then call.id=call.id..part.id end
            if type(part["function"])=="table" then
                for _,field in ipairs({"name","arguments"}) do
                    if type(part["function"][field])=="string" then call["function"][field]=call["function"][field]..part["function"][field] end
                end
            end
            if #call.id>200 or #call["function"].name>128 or #call["function"].arguments>8192 then error("invalid_tool_call") end
        end
        if choice and type(choice.finish_reason) == "string" then
            if choice.finish_reason == "length" then parser.limited = true end
            if choice.finish_reason == "stop" or choice.finish_reason == "length" or choice.finish_reason == "tool_calls" then parser.complete = true end
        end
    end
    function parser:feed(chunk)
        self.bytes = self.bytes + #chunk
        if self.bytes > 1024 * 1024 then error("response_limit") end
        self.buffer = self.buffer .. chunk
        while true do
            local newline = self.buffer:find("\n", 1, true)
            if not newline then break end
            local line = self.buffer:sub(1, newline - 1):gsub("\r$", "")
            self.buffer = self.buffer:sub(newline + 1)
            if line == "" then event()
            elseif line:sub(1, 5) == "data:" then self.data[#self.data + 1] = line:sub(6):gsub("^ ", "") end
        end
        if #self.buffer > 65536 then error("invalid_stream") end
    end
    function parser:validTools()
        local count=0
        local ids={}
        for index,call in pairs(self.tool_calls) do
            count=count+1
            if index>4 or call.id=="" or call["function"].name=="" or ids[call.id] then return false end
            ids[call.id]=true
        end
        for index=1,count do if not self.tool_calls[index] then return false end end
        return true
    end
    return parser
end

return Protocol
