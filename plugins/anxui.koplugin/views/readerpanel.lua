local BottomContainer = require("ui/widget/container/bottomcontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Panel = FocusManager:extend{ name = "anxui_reader_panel", stop_events_propagation = true }

function Panel:init()
    self.key_events.Close = { { Device.input.group.Back } }
    self:rebuild()
end

function Panel:rebuild()
    if self[1] then self:clear() end
    local t, W, _ = self.theme, self.widgets, self.translate
    local width, height = Device.screen:getWidth(), Device.screen:getHeight()
    self.dimen = Geom:new{ w = width, h = height }
    local gap, margin = t.s(8), t.s(16)
    local inner = math.min(width - 2 * margin, t.s(640))
    local columns = width >= t.s(600) and 4 or 3
    local column_width = math.floor((inner - (columns - 1) * gap) / columns)
    local snapshot = self.snapshot
    local body = VerticalGroup:new{ align = "left",
        W.text(snapshot.title, t, t.heading, inner, true),
        VerticalSpan:new{ width = gap },
        W.text(string.format("%s · %s / %s", _(snapshot.mode), tostring(snapshot.page), tostring(snapshot.pages)),
            t, t.small, inner, false, true),
        VerticalSpan:new{ width = margin },
    }
    self.layout, self.buttons = {}, {}
    for start = 1, #self.actions, columns do
        local group, focus_row = HorizontalGroup:new{}, {}
        for index = start, math.min(start + columns - 1, #self.actions) do
            local entry = self.actions[index]
            if #focus_row > 0 then table.insert(group, HorizontalSpan:new{ width = gap }) end
            local button = W.button(_(entry.text), column_width, t, self.scope:guard(entry.callback),
                { parent = self, enabled = entry.enabled })
            self.buttons[entry.id] = button
            table.insert(group, button)
            table.insert(focus_row, button)
        end
        table.insert(body, group)
        table.insert(body, VerticalSpan:new{ width = gap })
        table.insert(self.layout, focus_row)
    end
    local close = W.button(_("Continue reading"), inner, t, function() self:onClose() end,
        { parent = self, selected = true })
    table.insert(body, close)
    table.insert(self.layout, {close})
    self[1] = BottomContainer:new{ dimen = self.dimen:copy(),
        FrameContainer:new{ padding = margin, bordersize = t.gray and 1 or 0,
            background = t.background, radius = t.nav_radius, body },
    }
    self.ges_events.TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } }
    self.selected = {x = 1, y = 1}
    self:refocusWidget()
    UIManager:setDirty(self, "ui")
end

function Panel:onTapOutside(_, gesture)
    if not self[1]:contentRange():contains(gesture.pos) then self:onClose() end
    return true
end

function Panel:onSetDimensions()
    self.theme = self.new_theme()
    self:rebuild()
end

function Panel:onClose()
    UIManager:close(self)
    return true
end

function Panel:onCloseWidget()
    if self.closed then return end
    self.closed = true
    self.scope:close()
    self:clear()
    UIManager:setDirty(nil, "ui")
    self.on_closed()
end

return Panel
