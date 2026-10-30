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
    self:rebuild()
end

function Dashboard:rebuild()
    if self[1] then self:clear() end
    local t, W, _ = self.theme, self.widgets, self.translate
    local width, height = Device.screen:getWidth(), Device.screen:getHeight()
    self.dimen = Geom:new{w = width, h = height}
    local margin, gap, control = t.s(16), t.s(12), t.touch
    local inner = width - 2 * margin
    local body = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    local function place(widget, x, y)
        widget.overlap_offset = {x, y}; table.insert(body, widget)
    end
    local close = W.button("×", control, t, function() self:onClose() end, {parent = self})
    place(W.text(_(self.title), t, t.title, inner - control - gap, true), margin, margin)
    place(close, width - margin - control, margin)
    place(W.text(self.subtitle, t, t.small, inner, false, true), margin, margin + control + gap)
    self.layout = {{close}}
    local top, bottom = margin + control + gap + t.s(32 * t.text_scale), height - margin - control
    local columns = width > height and 3 or 2
    local rows = math.max(1, math.ceil(#self.metrics / columns))
    local card_width = math.floor((inner - gap * (columns - 1)) / columns)
    local card_height = math.min(t.s(144), math.floor((bottom - top - gap * rows) / rows))
    for index, metric in ipairs(self.metrics) do
        local content = VerticalGroup:new{
            W.text(_(metric.label), t, t.small, card_width - t.s(16), false, true),
            VerticalSpan:new{width = gap},
            W.text(metric.value, t, t.title, card_width - t.s(16), true),
        }
        local card = FrameContainer:new{padding = 0, bordersize = 0, background = t.surface, radius = t.radius,
            CenterContainer:new{dimen = Geom:new{w = card_width, h = card_height}, content}}
        place(card, margin + ((index - 1) % columns) * (card_width + gap),
            top + math.floor((index - 1) / columns) * (card_height + gap))
    end
    local footer, action_width = {}, math.floor((inner - gap * (#self.actions - 1)) / #self.actions)
    self.buttons = {}
    for index, action in ipairs(self.actions) do
        local button = W.button(_(action.text), action_width, t, self.scope:guard(action.callback),
            {parent = self, enabled = action.enabled})
        self.buttons[action.id] = button
        place(button, margin + (index - 1) * (action_width + gap), bottom)
        footer[#footer + 1] = button
    end
    self.layout[#self.layout + 1] = footer
    self[1] = FrameContainer:new{padding = 0, bordersize = 0, background = t.background, body}
    self.selected = {x = 1, y = 1}; self:refocusWidget(); UIManager:setDirty(self, "ui")
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
