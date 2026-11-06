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
    self.key_events.NextPage = { { Device.input.group.PgFwd } }
    self.key_events.PreviousPage = { { Device.input.group.PgBack } }
    self.page = 1
    self:rebuild()
end

function Panel:rebuild()
    if self[1] then self:clear() end
    local t, W, _ = self.theme, self.widgets, self.translate
    local width, height = Device.screen:getWidth(), Device.screen:getHeight()
    self.dimen = Geom:new{ w = width, h = height }
    local gap, margin = t.s(8), t.s(12)
    local inner = math.min(width - 2 * margin, t.s(640))
    local touch = math.max(t.touch, Device.screen:scaleByDPI(48))
    local button_theme = setmetatable({touch=touch}, {__index=t})
    local columns = math.max(1, math.min(3, math.floor((inner + gap) / (t.s(125 * t.text_scale) + gap))))
    local column_width = math.floor((inner - (columns - 1) * gap) / columns)
    local snapshot = self.snapshot
    local actions = (self.show_more and self.more_actions or self.actions) or {}
    local body = VerticalGroup:new{ align = "left",
        W.text(snapshot.title, t, t.heading, inner, true),
        VerticalSpan:new{ width = t.s(4) },
        W.text(string.format("%s · %s / %s", _(snapshot.mode), tostring(snapshot.page), tostring(snapshot.pages)),
            t, t.small, inner, false, true),
        VerticalSpan:new{ width = gap },
    }
    -- Budget against the real header height. On short landscape screens the
    -- actions paginate; navigation and the close action always remain visible.
    local available = height - 2 * margin - body:getSize().h - touch - gap
    local rows = math.max(1, math.floor((available + gap) / (touch + gap)))
    local perpage = rows * columns
    self.page_count = math.max(1, math.ceil(#actions / perpage))
    self.page = math.max(1, math.min(self.page or 1, self.page_count))
    if self.page_count > 1 then
        body[3]:setText(string.format(_("Tools page %d/%d"), self.page, self.page_count))
        body:resetLayout()
    end
    local first, last = (self.page - 1) * perpage + 1, math.min(#actions, self.page * perpage)
    self.layout, self.buttons = {}, {}
    for start = first, last, columns do
        local group, focus_row = HorizontalGroup:new{}, {}
        for index = start, math.min(start + columns - 1, last) do
            local entry = actions[index]
            if #focus_row > 0 then table.insert(group, HorizontalSpan:new{ width = gap }) end
            local button = W.button(_(entry.text), column_width, button_theme, self.scope:guard(entry.callback),
                { parent = self, enabled = entry.enabled })
            self.buttons[entry.id] = button
            table.insert(group, button)
            table.insert(focus_row, button)
        end
        table.insert(body, group)
        table.insert(body, VerticalSpan:new{ width = gap })
        table.insert(self.layout, focus_row)
    end
    local controls, focus = HorizontalGroup:new{}, {}
    local remaining = inner
    local function append(button)
        if #focus > 0 then controls[#controls + 1] = HorizontalSpan:new{width=gap} end
        controls[#controls + 1], focus[#focus + 1] = button, button
    end
    if self.page_count > 1 then
        self.buttons.previous = W.button("‹", touch, button_theme, self.scope:guard(function() self:onPreviousPage() end),
            {parent=self,enabled=self.page>1})
        self.buttons.next = W.button("›", touch, button_theme, self.scope:guard(function() self:onNextPage() end),
            {parent=self,enabled=self.page<self.page_count})
        append(self.buttons.previous); append(self.buttons.next)
        remaining = remaining - 2 * (touch + gap)
    end
    local half = math.floor((remaining - gap) / 2)
    self.buttons.more = W.button(_(self.show_more and "Common tools" or "More tools"), half, button_theme,
        self.scope:guard(function() self.show_more=not self.show_more; self.page=1; self:rebuild() end), {parent=self})
    self.buttons.close = W.button(_("Continue reading"), remaining-half-gap, button_theme,
        self.scope:guard(function() self:onClose() end), {parent=self,selected=true})
    append(self.buttons.more); append(self.buttons.close)
    body[#body + 1] = controls
    self.layout[#self.layout + 1] = focus
    body:resetLayout()
    self[1] = BottomContainer:new{ dimen = self.dimen:copy(),
        FrameContainer:new{ padding = margin, bordersize = t.gray and 1 or 0,
            background = t.background, radius = t.nav_radius, body },
    }
    self.ges_events.TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } }
    self.selected = {x = 1, y = 1}
    self:refocusWidget()
    UIManager:setDirty(self, "ui")
end

function Panel:onNextPage() self.page=math.min(self.page_count,self.page+1); self:rebuild(); return true end
function Panel:onPreviousPage() self.page=math.max(1,self.page-1); self:rebuild(); return true end

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
