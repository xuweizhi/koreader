local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Dashboard = FocusManager:extend{
    name = "anxui_dashboard", covers_fullscreen = true, stop_events_propagation = true,
}

function Dashboard:init()
    self.key_events.Close = {{Device.input.group.Back}}
    self.key_events.NextPage = {{Device.input.group.PgFwd}}
    self.key_events.PreviousPage = {{Device.input.group.PgBack}}
    self.page=1
    self:rebuild()
end

function Dashboard:rebuild()
    local old=self.selected and self.layout and self.layout[self.selected.y]
    old=old and old[self.selected.x]
    local focus_id,focused=old and old.focus_id,old and old.frame and old.frame.invert
    if self[1] then self:clear() end
    local t, W, _ = self.theme, self.widgets, self.translate
    local width, height = Device.screen:getWidth(), Device.screen:getHeight()
    self.dimen = Geom:new{w = width, h = height}
    local compact=height<t.s(350)
    local margin, gap, control = t.s(compact and 8 or 16), t.s(compact and 8 or 12), t.touch
    local inner = width - 2 * margin
    local body = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    local function place(widget, x, y)
        widget.overlap_offset = {x, y}; table.insert(body, widget)
    end
    local close = W.button("×", control, t, function() self:onClose() end, {parent = self})
    close.focus_id="close"
    place(W.text(_(self.title), t, t.title, inner - control - gap, true), margin, margin)
    place(close, width - margin - control, margin)
    self.layout = {{close}}
    local top, bottom = margin + control + gap, height - margin - control
    if not compact then
        place(W.text(self.subtitle, t, t.small, inner, false, true), margin, top)
        top=top+t.s(32*t.text_scale)
    end
    local columns = width > height and 3 or 2
    local card_width = math.floor((inner - gap * (columns - 1)) / columns)
    local contents,min_height={},control
    for index, metric in ipairs(self.metrics) do
        contents[index] = VerticalGroup:new{
            W.text(_(metric.label), t, t.small, card_width - t.s(16), false, true),
            VerticalSpan:new{width = gap},
            W.text(metric.value, t, t.title, card_width - t.s(16), true),
        }
        min_height=math.max(min_height,contents[index]:getSize().h+2*t.s(8))
    end
    local rows=math.max(1,math.min(math.ceil(#self.metrics/columns),math.floor((bottom-top)/(min_height+gap))))
    local perpage=rows*columns
    self.page_count=math.max(1,math.ceil(#self.metrics/perpage))
    self.page=math.max(1,math.min(self.page or 1,self.page_count))
    local card_height = math.min(t.s(144), math.floor((bottom - top - gap * rows) / rows))
    self.cards={}
    local offset=(self.page-1)*perpage
    for index=1,perpage do
        local content=contents[offset+index]
        if not content then break end
        local card = FrameContainer:new{padding = 0, bordersize = 0, background = t.surface, radius = t.radius,
            CenterContainer:new{dimen = Geom:new{w = card_width, h = card_height}, content}}
        place(card, margin + ((index - 1) % columns) * (card_width + gap),
            top + math.floor((index - 1) / columns) * (card_height + gap))
        self.cards[#self.cards+1]=card
        contents[offset+index]=nil
    end
    for _,content in pairs(contents) do content:free() end
    local footer,action_x={},margin
    local action_width=math.floor((inner-(self.page_count>1 and 2*(control+gap) or 0)-gap*(#self.actions-1))/#self.actions)
    self.buttons = {}
    if self.page_count>1 then
        self.buttons.previous=W.button("‹",control,t,function() self:onPreviousPage() end,{parent=self,enabled=self.page>1})
        self.buttons.previous.focus_id="previous"
        place(self.buttons.previous,margin,bottom);footer[#footer+1]=self.buttons.previous
        action_x=action_x+control+gap
    end
    for index, action in ipairs(self.actions) do
        local button = W.button(_(action.text), action_width, t, self.scope:guard(action.callback),
            {parent = self, enabled = action.enabled})
        self.buttons[action.id] = button
        button.focus_id=action.id
        place(button, action_x + (index - 1) * (action_width + gap), bottom)
        footer[#footer + 1] = button
    end
    if self.page_count>1 then
        self.buttons.next=W.button("›",control,t,function() self:onNextPage() end,{parent=self,enabled=self.page<self.page_count})
        self.buttons.next.focus_id="next"
        place(self.buttons.next,width-margin-control,bottom);footer[#footer+1]=self.buttons.next
    end
    self.layout[#self.layout + 1] = footer
    self[1] = FrameContainer:new{padding = 0, bordersize = 0, background = t.background, body}
    self.selected = {x = 1, y = 1}
    for y,row in ipairs(self.layout) do
        for x,widget in ipairs(row) do if widget.focus_id==focus_id then self.selected={x=x,y=y} end end
    end
    self:refocusWidget(nil,focused and FocusManager.FORCED_FOCUS or nil); UIManager:setDirty(self, "ui")
end

function Dashboard:onNextPage()
    if self.page<self.page_count then self.page=self.page+1;self:rebuild() end
    return true
end

function Dashboard:onPreviousPage()
    if self.page>1 then self.page=self.page-1;self:rebuild() end
    return true
end

function Dashboard:onSetDimensions()
    self.theme = self.new_theme(); self:rebuild()
end

function Dashboard:onClose()
    UIManager:close(self); return true
end

function Dashboard:onCloseWidget()
    if self.closed then return end
    self.closed = true; self.scope:close(); self:clear()
    UIManager:setDirty(nil, "ui"); self.on_closed()
end

return Dashboard
