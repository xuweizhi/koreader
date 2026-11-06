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
    self.key_events.Back = { { Device.input.group.Back } }
    self.key_events.NextPage = { { Device.input.group.PgFwd } }
    self.key_events.PreviousPage = { { Device.input.group.PgBack } }
    self:rebuild()
end

function List:rebuild()
    if self.closed then return end
    local old = self.selected and self.layout and self.layout[self.selected.y]
    old = old and old[self.selected.x]
    local focus_id, focus_entry = old and old.focus_id, old and old.entry
    local was_focused = old and old.frame and (old.frame._focused or old.frame.invert)
    if self[1] then self:clear() end
    if self.render_scope then self.render_scope:close() end
    self.render_scope = self.new_scope()
    local t, W, _ = self.theme, self.widgets, self.translate
    local width, height = Device.screen:getWidth(), Device.screen:getHeight()
    local compact, short = height < t.s(450), height < t.s(300)
    self.dimen = Geom:new{ w = width, h = height }
    local margin, gap, control = t.s(16), t.s(8), t.touch
    local inner = width - 2 * margin
    local body = OverlapGroup:new{ dimen = self.dimen:copy(), allow_mirroring = false }
    local function place(widget, x, y)
        widget.overlap_offset = {x, y}; table.insert(body, widget); return widget
    end
    local close = W.button("×", control, t, function() self:onClose() end, {parent = self})
    close.focus_id = "close"
    local header_actions = short and not self.no_search and (self.filters and t.s(232) or t.s(112)) or 0
    place(W.text(_(self.title), t, t.title, inner - control - gap - header_actions, true), margin, margin)
    place(close, width - margin - control, margin)
    self.layout = {{close}}
    local top = margin + control + gap
    if not self.no_search then
        local search_width = short and t.s(104) or (compact and self.filters and inner-t.s(120)-gap or inner)
        local search = W.button(self.query == "" and _("Search") or self.query, search_width, t,
            function() self:showSearch() end, {parent = self})
        search.focus_id = "search"
        place(search, short and width-margin-control-gap-header_actions or margin, short and margin or top)
        local row = {search}
        if compact and self.filters then
            local selected = "All"
            for _, entry in ipairs(self.filters) do if entry[1]==self.filter then selected=entry[2] end end
            local filter = W.button(_(selected).." ▾",t.s(120),t,function() self:showFilters() end,{parent=self})
            filter.focus_id="filters"
            place(filter,short and width-margin-control-gap-t.s(120) or width-margin-t.s(120),short and margin or top)
            row[#row+1]=filter
        end
        if short then
            self.layout[1]={}
            for _, widget in ipairs(row) do self.layout[1][#self.layout[1]+1]=widget end
            self.layout[1][#self.layout[1]+1]=close
        else
            table.insert(self.layout,row)
            top=top+control+gap
        end
    end
    if self.status_text and not short then
        place(W.text(self.status_text, t, t.small, inner, false, true), margin, top)
        top = top + t.s(24 * t.text_scale)
    end
    if self.filters and not compact then
        local row, button_width = {}, math.floor((inner - (#self.filters - 1) * gap) / #self.filters)
        for index, entry in ipairs(self.filters) do
            local button = W.button(_(entry[2]), button_width, t, function()
                self.filter, self.page = entry[1], 1; self:rebuild()
            end, {parent = self, selected = entry[1] == self.filter})
            button.focus_id="filter:"..entry[1]
            place(button, margin + (index - 1) * (button_width + gap), top)
            table.insert(row, button)
        end
        table.insert(self.layout, row)
        top = top + control + gap
    end
    local footer = height - margin - (compact and control or 2 * control + gap)
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
    local previous = W.button("‹", control, t, function() self:onPreviousPage() end,
        {parent = self, enabled = self.page > 1})
    local following = W.button("›", control, t, function() self:onNextPage() end,
        {parent = self, enabled = self.page < self.page_count})
    previous.focus_id,following.focus_id="previous","next"
    place(previous, margin, footer)
    place(following, width - margin - control, footer)
    if not compact then
        place(W.text(string.format("%d / %d · %d", self.page, self.page_count, self.total),
            t, t.small, inner - 2 * (control + gap), false, true), margin + control + gap, footer + t.s(12))
        table.insert(self.layout, {previous, following})
    end
    local actions_width = inner-(compact and 2*(control+gap) or 0)
    local bottom, action_width = {}, math.floor((actions_width - (#self.actions - 1) * gap) / #self.actions)
    if compact then bottom[1]=previous end
    self.buttons = {}
    for index, action in ipairs(self.actions) do
        local button = W.button(_(action.text), action_width, t, self.scope:guard(action.callback),
            {parent = self, enabled = action.enabled})
        self.buttons[action.id] = button
        button.focus_id="action:"..action.id
        place(button, margin + (compact and control+gap or 0) + (index - 1) * (action_width + gap),
            compact and footer or footer + control + gap)
        table.insert(bottom, button)
    end
    if compact then bottom[#bottom+1]=following end
    table.insert(self.layout, bottom)
    self.buttons.previous,self.buttons.next=previous,following
    self[1] = FrameContainer:new{padding = 0, bordersize = 0, background = t.background, body}
    self.selected = {x = 1, y = 1}
    local found
    for y,row in ipairs(self.layout) do
        for x,widget in ipairs(row) do
            if focus_id and widget.focus_id==focus_id or focus_entry and widget.entry==focus_entry then
                self.selected={x=x,y=y}; found=true
            end
        end
    end
    if focus_entry and not found then
        for y,row in ipairs(self.layout) do if row[1].entry then self.selected={x=1,y=y}; break end end
    end
    self:refocusWidget(nil,was_focused and FocusManager.FORCED_FOCUS or nil)
    UIManager:setDirty(self, "ui")
end

function List:onNextPage()
    if self.page<self.page_count then self.page=self.page+1; self:rebuild() end
    return true
end

function List:onPreviousPage()
    if self.page>1 then self.page=self.page-1; self:rebuild() end
    return true
end

function List:showFilters()
    local items={}
    local menu
    for _, entry in ipairs(self.filters or {}) do
        items[#items+1]={text=(self.filter==entry[1] and "✓ " or "")..self.translate(entry[2]),
            callback=self.scope:guard(function()
                UIManager:close(menu);self.filter,self.page=entry[1],1;self:rebuild()
            end)}
    end
    menu=require("ui/widget/menu"):new{title=self.translate("Filter"),width=math.floor(self.dimen.w*.9),item_table=items}
    self.filter_menu=menu
    UIManager:show(self.scope:own(menu))
end

function List:showSearch()
    if self.closed or self.search_dialog then return end
    local dialog_scope = self.new_scope()
    local dialog, _ = nil, self.translate
    dialog = InputDialog:new{ title = _("Search"), input = self.query,
        buttons = {{
            {text = _("Cancel"), id="close", callback = function() UIManager:close(dialog) end},
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
    UIManager:show(self.dialogs.own(self,dialog)); dialog:onShowKeyboard()
end

function List:onSetDimensions()
    self.theme = self.new_theme(); self:rebuild()
end

function List:onClose()
    UIManager:close(self); return true
end

function List:onBack()
    if self.on_back then self.on_back() else self:onClose() end
    return true
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
