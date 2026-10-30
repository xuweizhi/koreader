local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputDialog = require("ui/widget/inputdialog")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local Home = FocusManager:extend{
    name = "anxui_home", covers_fullscreen = true, stop_events_propagation = true,
}

local function collectRetiredWidgets()
    -- Repeated page replacement can otherwise double the Lua heap before the
    -- default collector starts a cycle. Advance it after releasing old UI,
    -- without changing its pause/step multiplier or scheduling idle work.
    -- 512 is a work hint in KiB, not a wall-clock limit (atomic GC may run).
    if collectgarbage("isrunning") then collectgarbage("step", 512) end
end

function Home:init()
    local state = self.state or {}
    self.query, self.page = state.query or "", state.page or 1
    self.source, self.collection = state.source or "library", state.collection
    self.sort, self.list_mode = state.sort or "native", state.list_mode == true
    self.selected_file = state.selected_file
    self.status, self.reverse = state.status, state.reverse == true
    self:loadItems()
    self.key_events.Close = { { Device.input.group.Back } }
    self.key_events.NextPage = { { Device.input.group.PgFwd } }
    self.key_events.PreviousPage = { { Device.input.group.PgBack } }
    self:rebuild()
end

function Home:viewState()
    return { query = self.query, page = self.page, source = self.source, collection = self.collection,
        sort = self.sort, list_mode = self.list_mode, selected_file = self.selected_file,
        status = self.status, reverse = self.reverse }
end

function Home:loadItems()
    if self.source_scope then self.source_scope:close() end
    self.source_scope = self.new_scope()
    self.item_table = self.load_source(self.source, self.collection)
    self.library.enrich(self.item_table, self.source_scope, self.source_scope:guard(function() self:rebuild() end))
    self:loadProgress()
end

function Home:setSource(source, collection)
    self.source, self.collection, self.query, self.page = source, collection, "", 1
    self.selected_file = nil
    self:loadItems()
    self:rebuild()
end

function Home:loadProgress()
    if self.progress_scope then self.progress_scope:close() end
    self.progress_scope = self.new_scope()
    self.loading_status = self.status ~= nil or self.sort == "progress"
    if self.loading_status then
        self.library.enrichProgress(self.item_table, self.progress_scope, self.progress_scope:guard(function()
            self.loading_status = false
            self:rebuild()
        end))
    end
end

function Home:setStatus(status)
    self.status = self.status ~= status and status or nil
    self.page, self.selected_file = 1, nil
    self:loadProgress()
    self:rebuild()
end

function Home:rebuild()
    if self.closed then return end
    if self[1] then self:clear() end
    if self.render_scope then self.render_scope:close() end
    self.render_scope = self.new_scope()
    self.covers = self.new_covers(self.render_scope, self.theme.gray)
    local t, W, _ = self.theme, self.widgets, self.translate
    local s = t.s
    local width, height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{w=width, h=height}
    self.wide = width > s(600) and height >= s(360 * t.text_scale)
    local margin, gap, rail = s(20), s(20), self.wide and s(104) or 0
    local x, control = margin + rail, t.touch
    local content_width = width - margin * 2 - rail
    local body = OverlapGroup:new{dimen=self.dimen:copy(), allow_mirroring=false}
    local function place(widget, left, top)
        widget.overlap_offset = {left, top}
        body[#body + 1] = widget
        return widget
    end
    self.controls = {}
    local search_width = content_width - 2 * control - s(16)
    local search = W.search(self.query == "" and _("Search books") or self.query, search_width, t,
        function() self:showSearch() end, self)
    local add = W.iconButton("plus", _("Add books"), t, function() self:showAddMenu() end, self)
    local sort = W.iconButton("appbar.menu", _("Sort and library options"), t, function() self:showOptions() end, self)
    place(search, x, margin)
    place(add, width - margin - 2 * control - s(8), margin)
    place(sort, width - margin - control, margin)
    self.controls.search, self.controls.add, self.controls.sort = search, add, sort
    self.layout = {{search, add, sort}}

    local filter_y, filter_gap = margin + control + s(10), s(8)
    local filter_width = math.floor((content_width - control - filter_gap * 3) / 3)
    local filters = {}
    for index, entry in ipairs({{"complete", "Finished"}, {"reading", "In progress"}, {"new", "Not started"}}) do
        local button = W.chip(_(entry[2]), filter_width, t, function() self:setStatus(entry[1]) end,
            self.status == entry[1], self)
        place(button, x + (index - 1) * (filter_width + filter_gap), filter_y)
        filters[#filters + 1] = button
        self.controls[entry[1]] = button
    end
    local sources = W.iconButton("appbar.filebrowser", _("Library sources and collections"), t,
        function() self:showSources() end, self)
    place(sources, width - margin - control, filter_y)
    filters[#filters + 1] = sources
    self.controls.sources = sources
    self.layout[#self.layout + 1] = filters
    self.filtered = self.library.query(self.item_table, self.query, self.sort, self.status, self.reverse)
    local top = filter_y + control + s(16)
    if self.source ~= "library" then
        local label = self.source == "recent" and _("Recent") or self.source == "favorites" and _("Favorites")
            or self.source == "collection" and self.collection or _("Current folder")
        place(W.text(label, t, t.small, content_width, false, true), x, top)
        top = top + s(26 * t.text_scale)
    end
    local nav_height = math.max(control, s(52 * t.text_scale)) + s(12)
    local footer_height = self.wide and control or s(18)
    local footer_y = height - margin - footer_height - (self.wide and 0 or nav_height + s(6))
    local available = math.max(control, footer_y - top - s(8))
    local list_mode = self.list_mode or available < s(150 * t.text_scale)
    local columns = list_mode and 1 or math.max(1, math.floor((width - rail) / Screen:scaleByDPI(120 * t.text_scale)))
    local card_width = math.floor((content_width - (columns - 1) * gap) / columns)
    local card_height = list_mode and math.min(available, s(100 * t.text_scale))
        or math.min(available, math.floor(card_width * 2.1))
    local row_gap = s(30)
    local rows = math.max(1, math.floor((available + row_gap) / (card_height * (list_mode and 1 or .85) + row_gap)))
    card_height = math.min(card_height, math.floor((available - (rows - 1) * row_gap) / rows))
    self.perpage = rows * columns
    if self.selected_file then
        for index, item in ipairs(self.filtered) do
            if item.file == self.selected_file then self.page = math.ceil(index / self.perpage); break end
        end
    end
    local visible
    visible, self.page, self.page_count = self.library.page(self.filtered, self.page, self.perpage)
    self.cards = {}
    if #self.filtered == 0 then
        local empty = VerticalGroup:new{}
        local has_filter = self.query ~= "" or self.status ~= nil
        local message = self.loading_status and _("Reading book status…")
            or has_filter and _("No matching books") or _("Your bookshelf is empty")
        if available > s(220) then
            empty[#empty + 1] = W.text("(´。＿。｀)", t, 32, content_width, false, true)
            empty[#empty + 1] = VerticalSpan:new{width=s(16)}
        end
        local compact = available < s(120 * t.text_scale)
        empty[#empty + 1] = W.text(message, t, compact and t.small or t.heading, content_width, true)
        empty[#empty + 1] = VerticalSpan:new{width=s(compact and 4 or 12)}
        local button_width = math.min(content_width, s(280))
        local action = W.button(has_filter and _("Clear filters") or _("Import ebooks"), button_width, t, function()
            if has_filter then self.query, self.status = "", nil; self:loadProgress(); self:rebuild()
            elseif self.on_import then self.on_import() end
        end, {parent=self})
        empty[#empty + 1] = action
        self.layout[#self.layout + 1] = {action}
        if not has_filter and self.on_scan and available > s(170) then
            local scan = W.button(_("Scan ebook folder"), button_width, t, self.on_scan, {parent=self})
            empty[#empty + 1] = VerticalSpan:new{width=s(8)}
            empty[#empty + 1] = scan
            self.layout[#self.layout + 1] = {scan}
        end
        place(CenterContainer:new{dimen=Geom:new{w=content_width, h=available}, empty}, x, top)
    else
        for row = 1, rows do
            local focus_row = {}
            for column = 1, columns do
                local item = visible[(row - 1) * columns + column]
                if item then
                    local file = item.file
                    local card = W.Card:new{
                        item=item, theme=t, translate=_, width=card_width, height=card_height, show_parent=self,
                        list_mode=list_mode, progress=item.progress or self.library.progress(file),
                        callback=self.render_scope:guard(function() return self.on_open_book(file) end),
                        hold_callback=self.render_scope:guard(function() return self.on_book_actions(file) end),
                    }
                    place(card, x + (column - 1) * (card_width + gap), top + (row - 1) * (card_height + row_gap))
                    focus_row[#focus_row + 1], self.cards[#self.cards + 1] = card, card
                end
            end
            if #focus_row > 0 then self.layout[#self.layout + 1] = focus_row end
        end
    end
    local footer_inset = self.wide and control + gap or 0
    place(CenterContainer:new{
        dimen=Geom:new{w=content_width - 2 * footer_inset, h=footer_height},
        W.text(string.format("%d / %d  ·  %d %s", self.page, self.page_count, #self.filtered, _("books")),
            t, 12 * t.text_scale, content_width - 2 * footer_inset, false, true),
    }, x + footer_inset, footer_y)
    if self.wide then
        local previous = W.iconButton("chevron.left", _("Previous page"), t, function() self:changePage(-1) end, self)
        local following = W.iconButton("chevron.right", _("Next page"), t, function() self:changePage(1) end, self)
        place(previous, x, footer_y); place(following, width - margin - control, footer_y)
        self.layout[#self.layout + 1] = {previous, following}
    end

    local entries = {{"Library", "book.opened", function() self:setSource("library") end}}
    if self.on_statistics then entries[#entries + 1] = {"Stats", "appbar.pageview", self.on_statistics} end
    if self.on_assistant then entries[#entries + 1] = {"AI", "star.full", self.on_assistant} end
    if self.on_notes then entries[#entries + 1] = {"Notes", "edit", self.on_notes} end
    if self.on_preferences then entries[#entries + 1] = {"Settings", "appbar.settings", self.on_preferences} end
    local nav_width = self.wide and s(68) or math.min(content_width, s(400))
    local button_width = self.wide and nav_width or math.floor((nav_width - s(12)) / #entries)
    local nav = self.wide and VerticalGroup:new{} or HorizontalGroup:new{}
    local nav_layout = {}
    for index, entry in ipairs(entries) do
        local button = W.navigation(_(entry[1]), entry[2], button_width, t, self.scope:guard(entry[3]),
            {selected=index == 1, parent=self})
        if self.wide and index > 1 then nav[#nav + 1] = VerticalSpan:new{width=s(14)} end
        nav[#nav + 1], nav_layout[#nav_layout + 1] = button, button
    end
    local nav_frame = FrameContainer:new{
        padding=s(6), bordersize=1, color=t.outline, background=t.surface, radius=t.nav_radius, nav,
    }
    place(nav_frame, self.wide and margin or math.floor((width - nav_frame:getSize().w) / 2),
        self.wide and math.floor((height - nav_frame:getSize().h) / 2) or height - margin - nav_frame:getSize().h)
    self.layout[#self.layout + 1] = nav_layout
    self[1] = FrameContainer:new{padding=0, bordersize=0, background=t.background, body}
    self.selected = {x=1, y=1}
    if self.selected_file then
        for row, controls in ipairs(self.layout) do
            for column, widget in ipairs(controls) do
                if widget.item and widget.item.file == self.selected_file then self.selected = {x=column, y=row} end
            end
        end
    end
    self:refocusWidget()
    self.ges_events.SwipeShelf = {require("ui/gesturerange"):new{ges="swipe", range=self.dimen}}
    UIManager:setDirty(self, "ui")
    self.covers:load(visible, self.render_scope:guard(function(item, info)
        for _, card in ipairs(self.cards) do if card.item == item then card:updateInfo(info) end end
    end))
    collectRetiredWidgets()
end

function Home:onSwipeShelf(_, gesture)
    if gesture.direction == "north" or gesture.direction == "west" then self:changePage(1)
    elseif gesture.direction == "south" or gesture.direction == "east" then self:changePage(-1) end
    return true
end

function Home:onNextPage() self:changePage(1); return true end
function Home:onPreviousPage() self:changePage(-1); return true end

function Home:showMenu(title, entries)
    if self.closed or self.options_menu then return end
    local menu, items = nil, {}
    local menu_scope = self.new_scope()
    for _, entry in ipairs(entries) do
        items[#items + 1] = {text=entry.text, enabled=entry.enabled, callback=menu_scope:guard(function()
            UIManager:close(menu)
            entry.callback()
        end)}
    end
    menu = require("ui/widget/menu"):new{title=title, item_table=items}
    local original_close = menu.onCloseWidget
    menu.onCloseWidget = function(widget)
        menu_scope:close()
        self.options_menu = nil
        if original_close then original_close(widget) end
    end
    self.options_menu = menu
    UIManager:show(self.scope:own(menu))
end

function Home:showAddMenu()
    local _ = self.translate
    local entries = {
        {text=_("Import ebooks"), callback=self.on_import or function() end},
        {text=_("Scan ebook folder"), callback=self.on_scan or function() end},
    }
    if self.on_rescan then entries[#entries + 1] = {text=_("Rescan saved folders"), callback=self.on_rescan} end
    self:showMenu(_("Add books"), entries)
end

function Home:showSources()
    local _ = self.translate
    local entries = {}
    for __, source in ipairs({{"library", "All books"}, {"directory", "Current folder"}, {"recent", "Recent"}, {"favorites", "Favorites"}}) do
        entries[#entries + 1] = {text=_(source[2]), callback=function() self:setSource(source[1]) end}
    end
    for __, name in ipairs(self.library.collections()) do
        entries[#entries + 1] = {text=_("Collection") .. ": " .. name,
            callback=function() self:setSource("collection", name) end}
    end
    self:showMenu(_("Library sources and collections"), entries)
end

function Home:showOptions()
    local _ = self.translate
    local entries = {}
    for __, order in ipairs({{"title", "Title"}, {"author", "Author"}, {"recent", "Last read"},
            {"progress", "Reading progress"}, {"native", "Import order"}}) do
        entries[#entries + 1] = {text=(self.sort == order[1] and "✓ " or "") .. _(order[2]), callback=function()
            self.sort, self.page, self.selected_file = order[1], 1, nil
            self:loadProgress(); self:rebuild()
        end}
    end
    local descending = self.reverse ~= (self.sort == "recent")
    entries[#entries + 1] = {text=descending and _("Descending order") or _("Ascending order"), callback=function()
        self.reverse, self.page, self.selected_file = not self.reverse, 1, nil; self:rebuild()
    end}
    entries[#entries + 1] = {text=self.list_mode and _("Grid view") or _("List view"), callback=function()
        self.list_mode, self.page = not self.list_mode, 1; self:rebuild()
    end}
    entries[#entries + 1] = {text=_("Refresh"), callback=function() self:loadItems(); self:rebuild() end}
    if self.on_continue then entries[#entries + 1] = {text=_("Continue reading"),
        enabled=G_reader_settings:readSetting("lastfile") ~= nil, callback=self.on_continue} end
    if self.on_sync then entries[#entries + 1] = {text=_("Sync settings"), callback=self.on_sync} end
    entries[#entries + 1] = {text=_("Classic interface"), callback=function() self:onClose() end}
    self:showMenu(_("Sort and library options"), entries)
end

function Home:paintTo(bb, x, y)
    FocusManager.paintTo(self, bb, x, y)
    if self.on_ready then
        self.scope:later(0, self.on_ready)
        self.on_ready = nil
    end
end

function Home:changePage(delta)
    self.selected_file = nil
    self.page = math.max(1, math.min(self.page_count, self.page + delta))
    self:rebuild()
end

function Home:showSearch()
    if self.closed or self.search_dialog then return end
    local _ = self.translate
    local dialog
    local function close()
        if UIManager:isWidgetShown(dialog) then UIManager:close(dialog) end
        if self.search_dialog == dialog then self.search_dialog = nil end
    end
    dialog = InputDialog:new{
        title = _("Search books"), input = self.query,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = close },
            { text = _("Search"), is_enter_default = true, callback = function()
                if self.closed then return end
                local query = dialog:getInputText()
                close()
                if self.closed then return end
                self.query, self.page = query, 1
                self.selected_file = nil
                self:rebuild()
            end },
        } },
    }
    self.search_dialog = dialog
    self.scope:own(dialog)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Home:onSetDimensions()
    self.theme = self.new_theme()
    self:rebuild()
end

function Home:showError(message)
    if self.closed then return end
    if self.error_dialog then UIManager:close(self.error_dialog) end
    local dialog
    dialog = require("ui/widget/infomessage"):new{
        text = self.translate(message),
        dismiss_callback = function()
            if self.error_dialog == dialog then self.error_dialog = nil end
        end,
    }
    self.error_dialog = dialog
    self.scope:own(dialog)
    UIManager:show(dialog)
end

function Home:onClose()
    UIManager:close(self)
    return true
end

function Home:onCloseWidget()
    if self.closed then return end
    self.closed = true
    self.scope:close()
    if self.source_scope then self.source_scope:close() end
    if self.progress_scope then self.progress_scope:close() end
    self.error_dialog, self.search_dialog = nil, nil
    self:clear()
    if self.render_scope then self.render_scope:close() end
    self.cards, self.layout, self.filtered, self.item_table = nil, nil, nil, nil
    UIManager:setDirty(nil, "ui")
    if self.on_closed then self.on_closed() end
    collectRetiredWidgets()
end

return Home
