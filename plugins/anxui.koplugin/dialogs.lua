local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local UIManager = require("ui/uimanager")

local Dialogs = {}

-- InputText's clipboard windows are outside its widget tree. Keep them bound
-- to the current set of fields so resize/close cannot leave stale callbacks.
local function bindPopups(input, scope)
    local bound,collecting=setmetatable({},{__mode="k"}),false
    local bind,collect
    collect=function(callback,...)
        local args={...}
        if collecting then return callback(unpack(args)) end
        collecting=true
        local result,reason=scope:collectWindows(function() return callback(unpack(args)) end)
        collecting=false
        for _,window in ipairs(scope.windows) do bind(window) end
        return result,reason
    end
    bind=function(widget)
        if type(widget)~="table" or bound[widget] then return end
        bound[widget]=true
        for _,name in ipairs({"holdTextBox","showSelectionDialog","showClipboardSnippets","editClipboardSnippet",
            "callback","hold_callback"}) do
            local callback=widget[name]
            if type(callback)=="function" then
                widget[name]=scope:guard(function(...) return collect(callback,...) end)
            end
        end
        for _,child in ipairs(widget) do bind(child) end
        for _,child in ipairs(widget.input_fields or {}) do bind(child) end
        bind(widget.button_table)
        bind(widget._input_widget)
    end
    bind(input)
end

function Dialogs.own(owner, dialog)
    local popup_scope
    local function closePopups()
        if popup_scope then popup_scope:close();popup_scope=nil end
    end
    local function bindFields()
        closePopups()
        popup_scope=owner.new_scope()
        for _,field in ipairs(dialog.input_fields or {dialog._input_widget}) do bindPopups(field,popup_scope) end
    end
    local original_init=dialog.init
    dialog.init=function(widget,...)
        closePopups()
        original_init(widget,...)
        bindFields()
    end
    local original_height=dialog.onKeyboardHeightChanged
    dialog.onKeyboardHeightChanged=function(widget,...)
        closePopups()
        return original_height(widget,...)
    end
    local width,height=Device.screen:getWidth(),Device.screen:getHeight()
    dialog.onSetDimensions=function(widget)
        local new_width,new_height=Device.screen:getWidth(),Device.screen:getHeight()
        if widget._anx_resizing or (new_width==width and new_height==height) then return end
        width,height=new_width,new_height
        widget._anx_resizing=true
        local cursors={}
        for index,field in ipairs(widget.input_fields or {widget._input_widget}) do
            field:resyncPos();cursors[index]=field.charpos
        end
        -- Native reinit preserves input and the focused multi-field index; it
        -- otherwise retains the old dialog width across orientation changes.
        widget.width=nil;widget.text_width=nil
        widget:onKeyboardHeightChanged()
        for index,field in ipairs(widget.input_fields or {widget._input_widget}) do
            if cursors[index] then field:moveCursorToCharPos(cursors[index]) end
        end
        local active=widget._input_widget
        for y,row in ipairs(widget.layout) do
            for x,item in ipairs(row) do
                if item==active then widget.selected={x=x,y=y} end
            end
        end
        widget:refocusWidget(FocusManager.RENDER_NOW,FocusManager.NOT_FOCUS+FocusManager.NOT_UNFOCUS)
        widget._anx_resizing=nil
        UIManager:setDirty(widget,"ui")
    end
    local original_close=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget,...)
        closePopups()
        return original_close(widget,...)
    end
    bindFields()
    return owner.scope:own(dialog)
end

return Dialogs
