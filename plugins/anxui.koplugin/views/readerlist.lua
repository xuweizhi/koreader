local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputDialog = require("ui/widget/inputdialog")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")

local List = FocusManager:extend{
    name = "anxui_reader_list", covers_fullscreen = true, stop_events_propagation = true,
}

function List:init()
    self.page, self.query, self.filter = 1, "", "all"
    self.key_events.Close = { { Device.input.group.Back } }
    self:rebuild()
end

function List:rebuild()
    if self.closed then return end
    if self[1] then self:clear() end
    if self.render_scope then self.render_scope:close() end
    self.render_scope = self.new_scope()
    local t, W, _ = self.theme, self.widgets, self.translate
    local width, height = Device.screen:getWidth(), Device.screen:getHeight()
    self.dimen = Geom:new{ w = width, h = height }
    local margin, gap, control = t.s(16), t.s(8), t.touch
    local inner = width - 2 * margin
    local body = OverlapGroup:new{ dimen = self.dimen:copy(), allow_mirroring = false }
    local function place(widget, x, y)
        widget.overlap_offset = {x, y}; table.insert(body, widget); return widget
    end
    local close = W.button("×", control, t, function() self:onClose() end, {parent = self})
    place(W.text(_(self.title), t, t.title, inner - control - gap, true), margin, margin)
    place(close, width - margin - control, margin)
    self.layout = {{close}}
    local top = margin + control + gap
    if not self.no_search then
        local search = W.button(self.query == "" and _("Search") or self.query, inner, t,
            function() self:showSearch() end, {parent = self})
        place(search, margin, top)
        table.insert(self.layout, {search})
        top = top + control + gap
    end
    if self.status_text then
        place(W.text(self.status_text, t, t.small, inner, false, true), margin, top)
        top = top + t.s(24 * t.text_scale)
    end
    if self.filters then
        local row, button_width = {}, math.floor((inner - (#self.filters - 1) * gap) / #self.filters)
        for index, entry in ipairs(self.filters) do
            local button = W.button(_(entry[2]), button_width, t, function()
                self.filter, self.page = entry[1], 1; self:rebuild()
            end, {parent = self, selected = entry[1] == self.filter})
            place(button, margin + (index - 1) * (button_width + gap), top)
            table.insert(row, button)
        end
        table.insert(self.layout, row)
        top = top + control + gap
    end
    local footer = height - margin - 2 * control - gap
    local row_height = math.min(t.s((self.row_height or (self.filters and 140 or 100)) * t.text_scale),
        math.max(control, footer - top - gap))
    local perpage = math.max(1, math.floor((footer - top) / (row_height + gap)))
    self.filtered = {}
    for _, row in ipairs(self.entries or {}) do
        if (self.filter == "all" or row.kind == self.filter or self.filter == "notes" and row.has_note)
                and (row.text .. "\n" .. (row.note or "")):lower():find(self.query:lower(), 1, true) then
            self.filtered[#self.filtered + 1] = row
        end
    end
    self.page_count = math.max(1, math.ceil(#self.filtered / perpage))
    self.page = math.max(1, math.min(self.page, self.page_count))
    self.total = #self.filtered
    local offset = (self.page - 1) * perpage
    if self.load_page then
        self.filtered, self.page, self.page_count, self.total = self.load_page(self.query, self.filter, self.page, perpage)
        offset = 0
    end
    self.rows = {}
    for index = 1, perpage do
        local entry = self.filtered[offset + index]
        if not entry then break end
        local row = W.Row:new{
            entry = entry, theme = t, translate = _, width = inner, height = row_height, show_parent = self,
            callback = self.render_scope:guard(function() self.on_select(entry) end),
            hold_callback = self.on_hold and self.render_scope:guard(function() self.on_hold(entry) end),
        }
        place(row, margin, top + (index - 1) * (row_height + gap))
        table.insert(self.rows, row); table.insert(self.layout, {row})
    end
    if #self.filtered == 0 then
        local message = self.empty_text
        if self.query ~= "" then message = "No matching items" end
        place(W.text(_(message), t, t.heading, inner), margin, top + gap)
    end
    local previous = W.button("‹", control, t, function() self.page = self.page - 1; self:rebuild() end,
        {parent = self, enabled = self.page > 1})
    local following = W.button("›", control, t, function() self.page = self.page + 1; self:rebuild() end,
        {parent = self, enabled = self.page < self.page_count})
    place(previous, margin, footer)
    place(following, width - margin - control, footer)
    place(W.text(string.format("%d / %d · %d", self.page, self.page_count, self.total),
        t, t.small, inner - 2 * (control + gap), false, true), margin + control + gap, footer + t.s(12))
    table.insert(self.layout, {previous, following})
    local bottom, action_width = {}, math.floor((inner - (#self.actions - 1) * gap) / #self.actions)
    self.buttons = {}
    for index, action in ipairs(self.actions) do
        local button = W.button(_(action.text), action_width, t, self.scope:guard(action.callback),
            {parent = self, enabled = action.enabled})
        self.buttons[action.id] = button
        place(button, margin + (index - 1) * (action_width + gap), footer + control + gap)
        table.insert(bottom, button)
    end
    table.insert(self.layout, bottom)
    self[1] = FrameContainer:new{padding = 0, bordersize = 0, background = t.background, body}
    self.selected = {x = 1, y = 1}; self:refocusWidget()
    UIManager:setDirty(self, "ui")
end

function List:showSearch()
    if self.closed or self.search_dialog then return end
    local dialog_scope = self.new_scope()
    local dialog, _ = nil, self.translate
    dialog = InputDialog:new{ title = _("Search"), input = self.query,
        buttons = {{
            {text = _("Cancel"), callback = function() UIManager:close(dialog) end},
            {text = _("Search"), is_enter_default = true, callback = dialog_scope:guard(function()
                self.query, self.page = dialog:getInputText(), 1
                UIManager:close(dialog); self:rebuild()
            end)},
        }},
    }
    local original_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(widget)
        dialog_scope:close()
        self.search_dialog = nil
        if original_close then original_close(widget) end
    end
    self.search_dialog = dialog
    UIManager:show(self.scope:own(dialog)); dialog:onShowKeyboard()
end

function List:onSetDimensions()
    self.theme = self.new_theme(); self:rebuild()
end

function List:onClose()
    UIManager:close(self); return true
end

function List:onCloseWidget()
    if self.closed then return end
    self.closed = true
    self.scope:close()
    if self.render_scope then self.render_scope:close() end
    self:clear(); UIManager:setDirty(nil, "ui")
    self.on_closed()
end

return List
