local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
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
    self.source, self.collection = state.source or "directory", state.collection
    self.sort, self.list_mode = state.sort or "native", state.list_mode == true
    self.selected_file = state.selected_file
    self:loadItems()
    self.key_events.Close = { { Device.input.group.Back } }
    self:rebuild()
end

function Home:viewState()
    return { query = self.query, page = self.page, source = self.source, collection = self.collection,
        sort = self.sort, list_mode = self.list_mode, selected_file = self.selected_file }
end

function Home:loadItems()
    if self.source_scope then self.source_scope:close() end
    self.source_scope = self.new_scope()
    self.item_table = self.load_source(self.source, self.collection)
    self.library.enrich(self.item_table, self.source_scope, self.source_scope:guard(function() self:rebuild() end))
end

function Home:setSource(source, collection)
    self.source, self.collection, self.query, self.page = source, collection, "", 1
    self.selected_file = nil
    self:loadItems()
    self:rebuild()
end

function Home:rebuild()
    if self.closed then return end
    if self[1] then self:clear() end
    if self.render_scope then self.render_scope:close() end
    self.cards, self.layout = nil, nil
    self.render_scope = self.new_scope()
    self.covers = self.new_covers(self.render_scope, self.theme.gray)
    local t, W, _ = self.theme, self.widgets, self.translate
    local s = t.s
    local width, height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ w = width, h = height }
    self.wide = width >= s(720)
    local margin, gap, rail = s(16), s(12), self.wide and s(112) or 0
    local content_width = width - margin * 2 - rail
    local control = t.touch
    local body = OverlapGroup:new{ dimen = self.dimen:copy(), allow_mirroring = false }
    local function place(widget, x, y)
        widget.overlap_offset = { x, y }
        table.insert(body, widget)
        return widget
    end
    local x = margin + rail
    local close = W.button("×", control, t, function() self:onClose() end, { parent = self })
    local classic_width = math.max(control, s(96))
    local classic = W.button(_("Classic"), classic_width, t, function() self:onClose() end, {parent = self})
    local title_width = content_width - control - gap - (self.wide and 0 or classic_width + gap)
    place(W.text(_("Library"), t, t.title, title_width, true), x, margin + s(6))
    place(close, width - margin - control, margin)
    if not self.wide then place(classic, width - margin - control - gap - classic_width, margin) end
    local source_title = self.source == "recent" and _("Recent") or self.source == "favorites" and _("Favorites")
        or self.source == "collection" and self.collection or _("Current folder")
    place(W.text(source_title, t, t.small, content_width, false, true), x, margin + control + s(4))
    self.layout = { self.wide and {close} or {classic, close} }

    local search_width = self.wide and math.min(s(480), content_width - classic_width - gap) or content_width
    local search = W.button(self.query == "" and _("Search books") or self.query, search_width, t,
        function() self:showSearch() end, { parent = self })
    local search_y = margin + control + s(28 * t.text_scale)
    place(search, x, search_y)
    if self.wide then place(classic, width - margin - classic_width, search_y) end
    table.insert(self.layout, self.wide and {search, classic} or {search})
    local tabs, tabs_y = {}, search_y + control + gap
    local tab_width = math.floor((content_width - gap * 3) / 4)
    for index, entry in ipairs({ {"directory", "Folder"}, {"recent", "Recent"}, {"favorites", "Favorites"}, {"more", "More"} }) do
        local button = W.button(_(entry[2]), tab_width, t, function()
            if entry[1] == "more" then self:showOptions() else self:setSource(entry[1]) end
        end, { selected = self.source == entry[1], parent = self })
        place(button, x + (index - 1) * (tab_width + gap), tabs_y)
        tabs[#tabs + 1] = button
    end
    table.insert(self.layout, tabs)
    self.filtered = self.library.query(self.item_table, self.query, self.sort)
    local top = tabs_y + control + gap
    local footer_y = height - margin - control - (self.wide and 0 or control + s(16) + gap)
    local available = footer_y - top - gap
    local columns = math.max(1, math.floor((content_width + gap) / (s(144 * t.text_scale) + gap)))
    if self.list_mode then columns = 1 end
    local card_width = math.floor((content_width - (columns - 1) * gap) / columns)
    local card_height = math.min(available, math.floor(card_width * 1.25) + s(88 * t.text_scale))
    if self.list_mode then card_height = math.max(t.touch, s(100 * t.text_scale)) end
    local rows = math.max(1, math.floor((available + gap) / (card_height + gap)))
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
        local message = self.query == "" and _("No books in this view") or _("No matching books")
        local action = W.button(self.query == "" and _("File browser") or _("Clear search"),
            math.min(content_width, s(280)), t, function()
                if self.query == "" then self:onClose() else self.query = ""; self:rebuild() end
            end, { parent = self })
        local empty = VerticalGroup:new{
            W.text(message, t, t.heading, content_width, true),
            VerticalSpan:new{ width = s(16) }, action,
        }
        place(CenterContainer:new{ dimen = Geom:new{ w = content_width, h = available }, empty }, x, top)
        table.insert(self.layout, { action })
    else
        for row = 1, rows do
            local focus_row = {}
            for col = 1, columns do
                local item = visible[(row - 1) * columns + col]
                if item then
                    local file = item.file
                    local card = W.Card:new{
                        item = item, theme = t, translate = _, width = card_width, height = card_height, show_parent = self,
                        list_mode = self.list_mode, progress = self.library.progress(item.file),
                        callback = self.render_scope:guard(function() return self.on_open_book(file) end),
                        hold_callback = self.render_scope:guard(function() return self.on_book_actions(file) end),
                    }
                    place(card, x + (col - 1) * (card_width + gap), top + (row - 1) * (card_height + gap))
                    table.insert(focus_row, card)
                    table.insert(self.cards, card)
                end
            end
            if #focus_row > 0 then table.insert(self.layout, focus_row) end
        end
    end
    local previous = W.button("‹", control, t, function() self:changePage(-1) end,
        { enabled = self.page > 1, parent = self })
    local following = W.button("›", control, t, function() self:changePage(1) end,
        { enabled = self.page < self.page_count, parent = self })
    place(previous, x, footer_y)
    place(following, width - margin - control, footer_y)
    place(CenterContainer:new{
        dimen = Geom:new{ w = content_width - 2 * (control + gap), h = control },
        W.text(string.format("%d / %d  ·  %d %s", self.page, self.page_count, #self.filtered, _("books")),
            t, t.small, content_width - 2 * (control + gap), false, true),
    }, x + control + gap, footer_y)
    table.insert(self.layout, { previous, following })

    local nav_width = self.wide and s(80) or math.min(content_width, s(360))
    local nav_items = 1 + (self.on_notes and 1 or 0) + (self.on_statistics and 1 or 0) + (self.on_preferences and 1 or 0)
    local nav_button_width = self.wide and nav_width or math.floor((nav_width - s(16) - s(4) * (nav_items - 1)) / nav_items)
    local first = W.navigation(_("Library"), "book.opened", nav_button_width, t,
        function() self.query = ""; self.page = 1; self:rebuild() end, { selected = true, parent = self })
    local preferences = self.on_preferences and W.navigation(_("Settings"), "appbar.settings", nav_button_width, t,
        self.scope:guard(self.on_preferences), { parent = self })
    local notes = self.on_notes and W.navigation(_("Notes"), "edit", nav_button_width, t,
        self.scope:guard(self.on_notes), {parent = self})
    local statistics = self.on_statistics and W.navigation(_("Stats"), "appbar.pageview", nav_button_width, t,
        self.scope:guard(self.on_statistics), {parent = self})
    local nav
    if self.wide then
        nav = VerticalGroup:new{ first }
    else
        nav = HorizontalGroup:new{ first }
    end
    if notes then
        table.insert(nav, self.wide and VerticalSpan:new{ width = s(12) } or HorizontalSpan:new{ width = s(4) })
        table.insert(nav, notes)
    end
    if statistics then
        table.insert(nav, self.wide and VerticalSpan:new{ width = s(12) } or HorizontalSpan:new{ width = s(4) })
        table.insert(nav, statistics)
    end
    if preferences then
        table.insert(nav, self.wide and VerticalSpan:new{ width = s(12) } or HorizontalSpan:new{ width = s(4) })
        table.insert(nav, preferences)
    end
    local nav_frame = FrameContainer:new{
        padding = s(8), bordersize = 0, background = t.surface, radius = t.nav_radius, nav,
    }
    place(nav_frame, self.wide and margin or math.floor((width - nav_frame:getSize().w) / 2),
        self.wide and margin or height - margin - nav_frame:getSize().h)
    local nav_layout = {first}
    if notes then nav_layout[#nav_layout + 1] = notes end
    if statistics then nav_layout[#nav_layout + 1] = statistics end
    if preferences then nav_layout[#nav_layout + 1] = preferences end
    table.insert(self.layout, nav_layout)
    self[1] = FrameContainer:new{ padding = 0, bordersize = 0, background = t.background, body }
    self.selected = { x = 1, y = 1 }
    if self.selected_file then
        for y, row in ipairs(self.layout) do
            for column, widget in ipairs(row) do
                if widget.item and widget.item.file == self.selected_file then self.selected = {x = column, y = y} end
            end
        end
    end
    self:refocusWidget()
    UIManager:setDirty(self, "ui")
    self.covers:load(visible, self.render_scope:guard(function(item, info)
        for __, card in ipairs(self.cards) do
            if card.item == item then card:updateInfo(info) end
        end
    end))
    collectRetiredWidgets()
end

function Home:showOptions()
    if self.closed or self.options_menu then return end
    local _ = self.translate
    local menu, items
    local menu_scope = self.new_scope()
    local function action(callback)
        return menu_scope:guard(function()
            UIManager:close(menu)
            callback()
        end)
    end
    items = {
        { text = self.list_mode and _("Grid view") or _("List view"), callback = action(function()
            self.list_mode = not self.list_mode; self.page = 1; self:rebuild()
        end) },
        { text = _("Sort by title"), callback = action(function() self.sort = "title"; self.page = 1; self:rebuild() end) },
        { text = _("Original order"), callback = action(function() self.sort = "native"; self.page = 1; self:rebuild() end) },
        { text = _("Refresh"), callback = action(function()
            self:loadItems(); self:rebuild()
        end) },
    }
    for __, name in ipairs(self.library.collections()) do
        items[#items + 1] = { text = _("Collection") .. ": " .. name,
            callback = action(function() self:setSource("collection", name) end) }
    end
    if self.on_continue then
        items[#items + 1] = { text = _("Continue reading"),
            enabled = G_reader_settings:readSetting("lastfile") ~= nil,
            callback = action(self.on_continue) }
    end
    menu = require("ui/widget/menu"):new{ title = _("Library"), item_table = items }
    local original_close = menu.onCloseWidget
    menu.onCloseWidget = function(widget)
        menu_scope:close()
        self.options_menu = nil
        if original_close then original_close(widget) end
    end
    self.options_menu = menu
    UIManager:show(self.scope:own(menu))
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
    self.error_dialog, self.search_dialog = nil, nil
    self:clear()
    if self.render_scope then self.render_scope:close() end
    self.cards, self.layout, self.filtered, self.item_table = nil, nil, nil, nil
    UIManager:setDirty(nil, "ui")
    if self.on_closed then self.on_closed() end
    collectRetiredWidgets()
end

return Home
