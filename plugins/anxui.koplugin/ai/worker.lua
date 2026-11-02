-- Bounded native document work outside the UI process. Never evaluates input.
local ffi = require("ffi")
local util = require("ffi/util")
local JSON = require("json")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local Worker = {}
function Worker.start(scope, operation, callback, timeout)
    local pid,fd=util.runInSubProcess(function(__,output)
        local ok,result=pcall(operation)
        local encoded_ok,encoded=pcall(JSON.encode,ok and {value=result or false} or {error="context_error"})
        if not encoded_ok or #encoded>262144 then encoded='{"error":"context_error"}' end
        local offset=0
        while offset<#encoded do
            local n=tonumber(ffi.C.write(output,encoded:sub(offset+1),#encoded-offset))
            if n<=0 then break end
            offset=offset+n
        end
        ffi.C.close(output)
    end,true)
    if not pid then callback(nil,"context_error");return end
    local alive,buffer,started=true,"",time.now()
    local function close()
        if not alive then return end
        alive=false;ffi.C.close(fd)
        if not util.isSubProcessDone(pid) then ffi.C.kill(-pid,9);ffi.C.kill(pid,9) end
        local function reap() if not util.isSubProcessDone(pid) then UIManager:scheduleIn(.1,reap) end end
        reap()
    end
    scope:defer(close)
    local function poll()
        if not alive then return end
        if time.to_s(time.since(started))>(timeout or 45) then close();callback(nil,"timeout");return end
        local count=math.min(util.getNonBlockingReadSize(fd) or 0,65536)
        if count>0 then
            local bytes=ffi.new("char[?]",count)
            local read=tonumber(ffi.C.read(fd,bytes,count))
            if read>0 then buffer=buffer..ffi.string(bytes,read) end
        end
        if #buffer>262144 then close();callback(nil,"context_error");return end
        if util.isSubProcessDone(pid) and (util.getNonBlockingReadSize(fd) or 0)==0 then
            close()
            local ok,value=pcall(JSON.decode,buffer)
            if not ok or type(value)~="table" then callback(nil,"context_error")
            elseif value.error then callback(nil,value.error)
            else callback(value.value or nil) end
        else scope:later(.1,poll) end
    end
    scope:later(.05,poll)
end
return Worker
