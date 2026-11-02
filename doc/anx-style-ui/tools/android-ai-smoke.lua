-- Test-only patch for the owned Android emulator. Uses a dummy API credential.
local UIManager=require("ui/uimanager")
local FileManager=require("apps/filemanager/filemanager")
local Device=require("device")
local JSON=require("json")
local android=require("android")
local file=assert(io.open("/sdcard/koreader/anx-android-control.json"))
local control=JSON.decode(file:read("*a"));file:close()
local result={phase=control.phase,passed=false,checks={}}
local request_id=0
local function write(name,data)
    local f=assert(io.open(control.remote.."/"..name..".tmp","w"));f:write(JSON.encode(data));f:close()
    assert(os.rename(control.remote.."/"..name..".tmp",control.remote.."/"..name..".json"))
end
local function step(callback)
    UIManager:scheduleIn(.7,function()
        local ok,err=xpcall(callback,debug.traceback)
        if not ok then result.error=err;write("result",result);UIManager:quit(1) end
    end)
end
local function wait(predicate,done,tries)
    local value=predicate()
    if value then return done(value) end
    assert((tries or 0)<100,"Android AI wait timed out")
    step(function() wait(predicate,done,(tries or 0)+1) end)
end
local function request(actions,done)
    UIManager:forceRePaint();request_id=request_id+1
    write("request",{id=request_id,actions=actions})
    wait(function()
        local f=io.open(control.remote.."/response.json");if not f then return end
        local data=JSON.decode(f:read("*a"));f:close()
        return data.id==request_id and data.ok
    end,function() step(done) end)
end
local function tap(widget)
    UIManager:forceRePaint()
    local d=assert(widget.dimen)
    return {kind="tap",x=math.floor(d.x+d.w/2),y=math.floor(d.y+d.h/2)}
end
local function shot(name,done) request({{kind="screenshot",name=name}},done) end
local function finish()
    result.passed=true;write("result",result);UIManager:quit()
end
local function seed()
    local lfs=require("libs/libkoreader-lfs")
    local path=android.dir.."/../anxui-ai"
    if lfs.attributes(path) then assert(os.rename(path,path..".before-"..control.run_id)) end
    assert(lfs.mkdir(path))
    local ffi=require("ffi");require("ffi/posix_h");ffi.cdef[[int chmod(const char*,mode_t);]]
    ffi.C.chmod(path,448)
    for name,value in pairs({config={schema=1,endpoint=control.url,model="fixture-model",api_key="anx-fixture-key"},
        history={schema=1,sessions={{id="legacy",title="Legacy Android conversation",updated=1,messages={
            {role="user",content="Legacy question"},{role="assistant",content="Legacy answer",status="complete"}}}}}}) do
        local f=assert(io.open(path.."/"..name..".json","w"));f:write(JSON.encode(value));f:close()
        ffi.C.chmod(path.."/"..name..".json",384)
    end
    result.checks.legacy_config_and_history_seeded=true;finish()
end
local function exercise(fm)
    local plugin=assert(fm.anxui);plugin:showAssistant()
    local chat=assert(plugin.assistant_view)
    assert(chat.store:config().api_key=="anx-fixture-key")
    assert(chat.store.path==android.dir.."/../anxui-ai")
    local history=assert(chat.store:history())
    local legacy,kept
    for _,data in ipairs(history) do
        if data.id=="legacy" then legacy=data end
        if data.title=="Android retained reply" then kept=data end
    end
    assert(legacy and legacy.messages[2].content=="Legacy answer")
    result.checks.legacy_private_data_preserved=true
    if control.phase=="reopen" then
        assert(kept and kept.messages[2].status=="complete")
        chat.session:load(kept)
        result.checks.schema2_and_chat_survive_restart=chat.store:read("config").schema==2
        assert(result.checks.schema2_and_chat_survive_restart)
        return shot("android-ai-reopened",finish)
    end
    chat:showConfig();chat.config_dialog.buttons[1][2].callback()
    assert(chat.store:read("config").schema==2)
    local config=chat.store:config();config.endpoint=control.url;assert(chat.store:saveProfile(config))
    result.checks.legacy_config_migrated=true
    local function stopped()
        request({{kind="background_resume"}},function()
                assert(android.isResumed() and plugin.assistant_view==chat)
                result.checks.background_resume=true
                assert(chat:send("__slow__"))
                wait(function() return #chat.session.data.messages[#chat.session.data.messages].content>0 end,function()
                assert(chat.session.running)
                request({tap(chat.buttons.stop)},function()
                    assert(not chat.session.running and chat.session.data.messages[#chat.session.data.messages].status=="cancelled")
                    result.checks.touch_stop=true
                    local width=Device.screen:getWidth()
                    UIManager:broadcastEvent(require("ui/event"):new("SetRotationMode",1))
                    wait(function() return Device.screen:getWidth()~=width end,function()
                        assert(chat.dimen.w==Device.screen:getWidth())
                        shot("android-ai-landscape",function()
                            UIManager:broadcastEvent(require("ui/event"):new("SetRotationMode",0))
                            wait(function() return Device.screen:getWidth()==width end,function()
                                result.checks.landscape_and_portrait=true
                                request({{kind="key",code=4}},function()
                                    assert(not plugin.assistant_view);result.checks.system_back=true;finish()
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end
    request({tap(chat.buttons.compose)},function()
        local dialog=assert(chat.compose_dialog)
        Device.input.setClipboardText("Android 中文输入 __markdown__")
        wait(function() return Device.input.getClipboardText()=="Android 中文输入 __markdown__" end,function()
        local clipboard=Device.input.getClipboardText()
        assert(clipboard=="Android 中文输入 __markdown__")
        dialog._input_widget:addChars(clipboard)
        assert(dialog:getInputText()==clipboard)
        shot("android-ai-input",function()
            request({tap(dialog.button_table.buttons_layout[1][2])},function()
                wait(function() return not chat.session.running end,function()
                    local answer=chat.session.data.messages[2]
                    assert(answer and answer.status=="complete")
                    chat.session.data.title="Android retained reply";assert(chat.session:save())
                    result.checks.touch_compose_send_chinese_clipboard_and_stream=true
                    chat:messageActions(2);chat.message_menu.item_table[2].callback()
                    -- Android's existing getter trims leading/trailing whitespace.
                    -- The setter receives the original, unmodified Markdown.
                    local expected_clipboard=answer.content:match("^%s*(.-)%s*$")
                    wait(function() return Device.input.getClipboardText()==expected_clipboard end,function()
                    local copied=UIManager._window_stack[#UIManager._window_stack].widget
                    assert(copied.text==chat.translate("Copied"));UIManager:close(copied)
                    chat:messageActions(2);chat.message_menu.item_table[1].callback()
                    shot("android-ai-markdown",function()
                        UIManager:close(chat.message_viewer)
                        result.checks.native_markdown_and_copy=true
                        chat.session:fresh();stopped()
                    end)
                    end)
                end)
            end)
        end)
        end)
    end)
end
step(function()
    wait(function() return FileManager.instance and FileManager.instance.anxui and FileManager.instance end,function(fm)
        if control.phase=="seed" then seed() else exercise(fm) end
    end)
end)
