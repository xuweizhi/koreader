local ffi = require("ffi")
local ffiutil = require("ffi/util")
local JSON = require("json")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local Transport = {}

-- All network work, including DNS/TLS and SSE decoding, lives in the child.
-- The parent only reads the currently available bytes; no blocking pipe reads.
function Transport.start(scope, config, messages, protocol, callbacks)
    local job = {running=true, buffer="", started=time.now()}
    local pid, fd = ffiutil.runInSubProcess(function(__, output)
        local function emit(value)
            local data = JSON.encode(value) .. "\n"
            local offset = 0
            while offset < #data do
                local written = tonumber(ffi.C.write(output, data:sub(offset + 1), #data - offset))
                if written <= 0 then error("pipe_closed") end
                offset = offset + written
            end
        end
        local ok = pcall(function()
            local endpoint = assert(protocol.endpoint(config.endpoint))
            local payload = {model=config.model, messages=messages, stream=true, max_tokens=config.max_tokens or 2048}
            if config.provider == "deepseek" then payload.thinking = {type="disabled"} end
            if config.tools then payload.tools=config.tools end
            local body = JSON.encode(payload)
            local parser = protocol.decoder(function(text) emit({delta=text}) end)
            local request = {url=endpoint, method="POST", redirect=false,
                headers={["Content-Type"]="application/json", ["Content-Length"]=tostring(#body),
                    ["Accept"]="text/event-stream", ["User-Agent"]="KOReader-AnxUI/1"},
                source=require("ltn12").source.string(body),
                sink=function(chunk)
                    if chunk then parser:feed(chunk) end
                    return 1
                end,
            }
            if config.api_key ~= "" then request.headers.Authorization = "Bearer " .. config.api_key end
            require("socketutil"):set_timeout(30, 90)
            local client
            if endpoint:match("^https:") then
                client = require("ssl.https")
                request.cafile = assert(require("ssl").get_system_ca(), "missing_ca")
                request.verify = "peer" -- Native LuaSec also verifies the hostname.
            else client = require("socket.http") end
            local success, code = client.request(request)
            if not success then emit({error="network_error"})
            elseif tonumber(code) ~= 200 then emit({error="http_error", code=tonumber(code)})
            elseif not parser.complete or not parser:validTools() or (parser.text_bytes == 0 and #parser.tool_calls==0) then emit({error="invalid_stream"})
            else emit({done=true, limited=parser.limited == true,tool_calls=parser.tool_calls}) end
        end)
        -- Never forward raw exceptions or provider error bodies: they may echo
        -- Authorization, selected passages or the entire request.
        if not ok then pcall(emit, {error="response_error"}) end
        ffi.C.close(output)
    end, true)
    if not pid then return nil, "network_error" end
    job.pid, job.fd = pid, fd
    local function release()
        if job.fd then ffi.C.close(job.fd); job.fd = nil end
        local child = job.pid
        job.pid = nil
        if child then
            if not ffiutil.isSubProcessDone(child) then
                ffi.C.kill(-child, 9)
                -- The window can close immediately after fork, before the
                -- child has called setpgid. Also signal our direct child.
                ffi.C.kill(child, 9)
            end
            local function reap()
                if not ffiutil.isSubProcessDone(child) then UIManager:scheduleIn(.1, reap) end
            end
            reap()
        end
    end
    function job:cancel()
        if not self.running then return end
        self.running = false
        if self.task then UIManager:unschedule(self.task); self.task = nil end
        release()
    end
    scope:defer(function() job:cancel() end)
    local function finish(err, code, limited, tool_calls)
        job:cancel()
        if scope.alive then callbacks.done(err, code, limited, tool_calls) end
    end
    local function poll()
        job.task = nil
        if not job.running then return end
        if time.to_s(time.since(job.started)) > 90 then return finish("timeout") end
        local available = ffiutil.getNonBlockingReadSize(job.fd) or 0
        if available > 0 then
            local buffer = ffi.new("char[?]", math.min(available, 65536))
            local n = tonumber(ffi.C.read(job.fd, buffer, math.min(available, 65536)))
            if n > 0 then job.buffer = job.buffer .. ffi.string(buffer, n) end
        end
        while job.running do
            local line = job.buffer:find("\n", 1, true)
            if not line then break end
            local ok, value = pcall(JSON.decode, job.buffer:sub(1, line - 1))
            job.buffer = job.buffer:sub(line + 1)
            if not ok or type(value) ~= "table" then return finish("response_error") end
            if type(value.delta) == "string" then callbacks.delta(value.delta)
            elseif value.error then return finish(value.error, value.code)
            elseif value.done then return finish(nil, nil, value.limited, value.tool_calls) end
        end
        if #job.buffer > 262144 then return finish("response_error") end
        if ffiutil.isSubProcessDone(job.pid) and (ffiutil.getNonBlockingReadSize(job.fd) or 0) == 0 then
            return finish("invalid_stream")
        end
        job.task = scope:later(.15, poll)
    end
    job.task = scope:later(.05, poll)
    return job
end

return Transport
