local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FileChooser = require("ui/widget/filechooser")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local Importer = {}
Importer.__index = Importer

-- Reserve space below the native browser instead of covering its last rows.
-- FileChooser still owns paths, pagination, file filtering and hardware keys.
local ImportPicker = FileChooser:extend{
    -- coverbrowser replaces FileChooser's renderer globally. Its cover rows do
    -- not render selection labels; keep this picker on the native text rows.
    onCloseWidget = Menu.onCloseWidget,
}

function ImportPicker:_recalculateDimen(no_recalculate_dimen)
    Menu._recalculateDimen(self, no_recalculate_dimen)
    local rows = math.max(1, math.floor(self.available_height / self.theme.s(48 * self.theme.text_scale)))
    if self.items_per_page ~= rows then
        self.items_per_page = rows
        Menu._recalculateDimen(self)
    end
end

function ImportPicker:init()
    local focused = self.layout and self.selected and self:getFocusItem()
    local focused_path = focused and focused.entry and focused.entry.path
    local focused_footer
    for _, id in ipairs({"confirm_button", "select_all_button", "clear_selection_button"}) do
        if focused and focused == self[id] then focused_footer = id end
    end
    local previous_paths, previous_index = self.path_items, self.path_items and self.path_items[self.path]
    if self.footer then self.footer:free(); self.footer = nil end
    self.theme = self.new_theme()
    local t, W, _ = self.theme, self.widgets, self.translate
    local width, height = Device.screen:getWidth(), Device.screen:getHeight()
    local margin, gap = t.s(height < t.s(300) and 8 or 12), t.s(8)
    local touch = math.max(t.touch, t.s(48))
    self.footer_theme = setmetatable({touch=touch}, {__index=t})
    self.compact_footer = not self.folder and height < t.s(300)
    self.footer_height = 2 * margin + touch + ((self.folder or self.compact_footer) and 0 or touch + gap)
    self.width, self.height = width, height - self.footer_height
    self.confirm_button, self.select_all_button, self.clear_selection_button = nil, nil, nil
    -- Keep rows touchable even when the keyboard/large text reduces the screen.
    self.items_per_page = 1
    self.items_font_size = t.font and t.font(16 * t.text_scale) or 16 * t.text_scale
    FileChooser.init(self)
    if previous_paths then self.path_items = previous_paths end
    local selected_index = previous_index
    if focused_path then
        for index, item in ipairs(self.item_table) do
            if item.path == focused_path then selected_index = index; break end
        end
    end
    if selected_index then
        self.page = self:getPageNumber(selected_index)
        self:updateItems(selected_index - (self.page - 1) * self.perpage)
    end
    local native_browser = self[1]
    local controls = VerticalGroup:new{align="left"}
    local inner = width - 2 * margin
    local confirm_width = self.compact_footer and math.floor(inner / 2) or inner
    local selection_width = self.compact_footer and inner - confirm_width - gap or inner
    local selection_row
    if not self.folder then
        local half = math.floor((selection_width - gap) / 2)
        self.select_all_button = W.button(_(self.compact_footer and "Select all" or "Select all in folder"), half, self.footer_theme,
            function() self:selectFolderFiles() end, {parent=self})
        self.clear_selection_button = W.button(_("Clear selection"), selection_width - half - gap, self.footer_theme,
            function() self:clearSelection() end, {parent=self})
        selection_row = HorizontalGroup:new{self.select_all_button,
            HorizontalSpan:new{width=gap}, self.clear_selection_button}
        controls[#controls + 1] = selection_row
        if not self.compact_footer then controls[#controls + 1] = VerticalSpan:new{width=gap} end
    end
    self.confirm_button = W.button(self.folder and _("Scan this folder") or "", confirm_width, self.footer_theme,
        self.confirm, {parent=self, selected=true})
    if self.compact_footer then
        selection_row[#selection_row+1] = HorizontalSpan:new{width=gap}
        selection_row[#selection_row+1] = self.confirm_button
    else
        controls[#controls + 1] = self.confirm_button
    end
    self.footer = FrameContainer:new{padding=margin, bordersize=0, background=t.background, controls}
    self[1] = VerticalGroup:new{align="left", native_browser, self.footer}
    self.dimen = Geom:new{x=0,y=0,w=width,h=height}
    self:updateFooter()
    if focused_footer then
        for y, row in ipairs(self.layout) do
            for x, widget in ipairs(row) do
                if widget == self[focused_footer] then self:moveFocusTo(x, y); break end
            end
        end
    end
end

function ImportPicker:updateFooter()
    if not self.confirm_button then return end
    for index = #self.layout, 1, -1 do
        local first = self.layout[index][1]
        if first == self.confirm_button or first == self.select_all_button or first == self.clear_selection_button then
            table.remove(self.layout, index)
        end
    end
    local count = 0
    for __ in pairs(self.ui.selected_files) do count = count + 1 end
    if not self.folder then
        self.confirm_button:setText(string.format(self.translate("Import selected (%d books)"), count), self.confirm_button.width)
        self.confirm_button:enableDisable(count > 0)
        self.clear_selection_button:enableDisable(count > 0)
        local has_files = false
        for _, item in ipairs(self.item_table) do if item.is_file then has_files = true; break end end
        self.select_all_button:enableDisable(has_files)
        if self.compact_footer and not Device:hasFewKeys() then
            self.layout[#self.layout+1] = {self.select_all_button,self.clear_selection_button,self.confirm_button}
            return
        end
        if Device:hasFewKeys() then
            self.layout[#self.layout + 1] = {self.select_all_button}
            self.layout[#self.layout + 1] = {self.clear_selection_button}
        else
            self.layout[#self.layout + 1] = {self.select_all_button, self.clear_selection_button}
        end
    end
    self.layout[#self.layout + 1] = {self.confirm_button}
end

function ImportPicker:updateItems(select_number, no_recalculate_dimen)
    local previous_index = self.path_items and self.path_items[self.path]
    local focused = self.layout and self.selected and self:getFocusItem()
    local footer
    for _, id in ipairs({"confirm_button", "select_all_button", "clear_selection_button"}) do
        if focused and focused == self[id] then footer = id end
    end
    for _, item in ipairs(self.item_table or {}) do
        item.shortcut_icon_width = self.theme.s(22 * self.theme.text_scale)
        if item.is_file then
            local selected = self.ui.selected_files[item.path] == true
            item.dim, item.mandatory_dim = false, false
            item.text_bgcolor = selected and self.theme.selected or nil
            item.text_func = function() return (self.ui.selected_files[item.path] and "☑  " or "☐  ") .. item.text end
        end
    end
    Menu.updateItems(self, select_number, no_recalculate_dimen)
    local page_start = (self.page - 1) * self.perpage
    -- Footer actions redraw the current page without selecting a different
    -- file. Keep its anchor, including when a taller screen fits every item.
    self.path_items[self.path] = not select_number and previous_index
        and previous_index > page_start and previous_index <= page_start + self.perpage
        and previous_index or page_start + (select_number or 1)
    self:updateFooter()
    if footer then
        for y, row in ipairs(self.layout) do
            for x, widget in ipairs(row) do
                if widget == self[footer] then self:moveFocusTo(x, y); break end
            end
        end
    end
end

function ImportPicker:selectFolderFiles()
    if not self.picker_scope.alive then return end
    for _, item in ipairs(self.item_table) do
        if item.is_file then self.ui.selected_files[item.path] = true end
    end
    self:updateItems()
end

function ImportPicker:clearSelection()
    if not self.picker_scope.alive then return end
    for path in pairs(self.ui.selected_files) do self.ui.selected_files[path] = nil end
    self:updateItems()
end

function Importer.new(home, shelf, new_scope, path, ui)
    local self = setmetatable({home=home, shelf=shelf, new_scope=new_scope, scope=new_scope(),
        translate=home.translate, path=path, ui=ui}, Importer)
    home.scope:defer(function() self:close() end)
    return self
end

function Importer:close()
    if self.operation then self.operation:close(); self.operation = nil end
    self.scope:close()
end

function Importer:message(text)
    if self.scope.alive then UIManager:show(self.scope:own(InfoMessage:new{text=text})) end
end

function Importer:choose(folder)
    if not self.scope.alive or self.picker or self.operation then return end
    local _, selected = self.translate, {}
    self.path = self:defaultPath()
    local picker, picker_scope = nil, self.new_scope()
    local confirm = picker_scope:guard(function()
        if not self.scope.alive then return end
        self.path = picker.path
        if folder then
            local root = picker.path
            UIManager:close(picker)
            self:confirmScan({root})
        else
            local files = {}
            for path in pairs(selected) do files[#files + 1] = path end
            if #files == 0 then return self:message(_("Select at least one ebook.")) end
            table.sort(files)
            UIManager:close(picker)
            self:run({files=files})
        end
    end)
    picker = ImportPicker:new{
        name="anxui_import_picker", title=folder and _("Choose ebook folder") or _("Select ebooks"),
        title_shrink_font_to_fit=true, folder=folder, confirm=confirm, picker_scope=picker_scope,
        new_theme=self.home.new_theme, widgets=self.home.widgets, translate=_,
        path=self.path, ui=setmetatable({selected_files=selected}, {__index=self.ui}), show_hidden=false,
        show_unsupported=false, show_flat_view=false, is_popout=false,
        show_file=function(__, filename) return not folder and self.shelf.supported(filename) end,
        refreshPath=function(widget)
            self.scope:collectWindows(function() FileChooser.refreshPath(widget) end)
        end,
        onLeftButtonTap=confirm,
        onLeftButtonHold=function(widget)
            if self.picker ~= widget then return end
            if folder then return confirm() end
            widget:selectFolderFiles()
        end,
        onFileSelect=function(widget, item)
            if folder or self.picker ~= widget then return end
            selected[item.path] = not selected[item.path] or nil
            for index, entry in ipairs(widget.item_table) do
                if entry == item then
                    widget:updateItems(index - (widget.page - 1) * widget.perpage)
                    break
                end
            end
        end,
        onFileHold=function(widget, item)
            if self.picker ~= widget then return end
            if item.is_file then widget:onFileSelect(item) else widget:changeToPath(item.path) end
        end,
    }
    local original_close = picker.onCloseWidget
    picker.onCloseWidget = function(widget)
        picker_scope:close()
        if self.picker == widget then self.picker = nil end
        if original_close then original_close(widget) end
    end
    self.picker = picker
    UIManager:show(self.scope:own(picker))
end

function Importer:confirmScan(roots)
    if not self.scope.alive or self.operation then return end
    local _ = self.translate
    if #roots == 0 then return self:message(_("No saved folders. Choose a folder to scan first.")) end
    for __, root in ipairs(roots) do
        if lfs.attributes(root, "mode") ~= "directory" then
            return self:message(_("This scan folder is unavailable. Reconnect its storage or remove the saved folder.") .. "\n\n" .. root)
        end
    end
    local dialog, dialog_scope = nil, self.new_scope()
    dialog = ButtonDialog:new{
        width=math.floor(Device.screen:getWidth() * .9),
        title=_("Scan folders and subfolders") .. "\n" .. string.format(_("Folders to scan: %d"), #roots) .. "\n\n"
            .. _("Books stay in their original locations. Existing books are skipped."),
        buttons={{
            {text=_("Cancel"), height=Device.screen:scaleByDPI(48), callback=function() UIManager:close(dialog) end},
            {text=_("Start scan"), height=Device.screen:scaleByDPI(48), callback=dialog_scope:guard(function()
                UIManager:close(dialog)
                self:run({roots=roots, recursive=true})
            end)},
        }, {{text=_("View folders"), height=Device.screen:scaleByDPI(48), callback=dialog_scope:guard(function()
            local items = {}
            for __, root in ipairs(roots) do items[#items + 1] = {text=root} end
            self.scan_paths_menu = Menu:new{title=_("Scan folders"), item_table=items, items_max_lines=3}
            UIManager:show(dialog_scope:own(self.scan_paths_menu))
        end)}}},
    }
    dialog.onScreenResize = function(widget)
        widget.width = math.floor(Device.screen:getWidth() * .9)
        widget:reinit()
        UIManager:setDirty(widget, "ui")
        return false
    end
    local original_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(widget)
        dialog_scope:close()
        if self.scan_confirmation == widget then self.scan_confirmation = nil end
        if original_close then original_close(widget) end
    end
    self.scan_confirmation = dialog
    UIManager:show(self.scope:own(dialog))
end

function Importer:showScanRoots()
    if not self.scope.alive or self.operation or self.picker then return end
    if self.scan_roots_menu and UIManager:isWidgetShown(self.scan_roots_menu) then UIManager:close(self.scan_roots_menu) end
    local _, menu, items = self.translate, nil, {}
    items[1] = {text=_("Add scan folder"), callback=self.scope:guard(function()
        if not UIManager:isWidgetShown(menu) then return end
        UIManager:close(menu); self:choose(true)
    end)}
    for __, info in ipairs(self.shelf.rootInfo()) do
        local status = info.available and _("Folder available") or _("Folder unavailable")
        local last = info.last_scan and (_("Last scanned") .. ": " .. os.date("%Y-%m-%d %H:%M", info.last_scan))
            or _("No scan time recorded")
        items[#items + 1] = {text=info.path .. "\n" .. status .. " · " .. last,
            callback=self.scope:guard(function()
                if not UIManager:isWidgetShown(menu) then return end
                UIManager:close(menu); self:showScanRootActions(info.path)
            end)}
    end
    if #items == 1 then items[#items + 1] = {text=_("No saved scan folders"), enabled=false} end
    menu = Menu:new{title=_("Scan folders"), item_table=items, items_max_lines=3, items_per_page=5}
    self.scan_roots_menu = menu
    UIManager:show(self.scope:own(menu))
end

function Importer:showScanRootActions(path)
    if not self.scope.alive or self.operation then return end
    local _, actions = self.translate, nil
    actions = ButtonDialog:new{title=path, buttons={
        {{text=_("Rescan folder"), callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(actions) then return end
            UIManager:close(actions); self:confirmScan({path})
        end)}},
        {{text=_("Remove scan folder"), callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(actions) then return end
            UIManager:close(actions)
            local confirmation
            confirmation = require("ui/widget/confirmbox"):new{
                text=_("Remove this folder from future scans? Imported books, ebook files and reading data will be kept.") .. "\n\n" .. path,
                ok_text=_("Remove scan folder"),
                ok_callback=self.scope:guard(function()
                    if not UIManager:isWidgetShown(confirmation) then return end
                    if not self.shelf.removeRoot(path) then return self:message(_("The scan folder settings could not be saved.")) end
                    self:showScanRoots()
                end),
            }
            self.scan_root_confirmation = confirmation
            UIManager:show(self.scope:own(confirmation))
        end)}},
        {{text=_("Back"), callback=self.scope:guard(function()
            if not UIManager:isWidgetShown(actions) then return end
            UIManager:close(actions); self:showScanRoots()
        end)}},
    }}
    self.scan_root_actions = actions
    UIManager:show(self.scope:own(actions))
end

function Importer:run(options)
    if not self.scope.alive or self.operation then return end
    local _, operation = self.translate, self.new_scope()
    self.operation = operation
    local width = math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * .75)
    local status = TextWidget:new{text=_("Preparing…"), face=Font:getFace("cfont", 16), max_width=width}
    local dialog
    local function dismiss()
        if not operation.alive then return end
        if self.job then self.job:cancel() end
        operation:close()
        if self.operation == operation then self.operation = nil end
        if UIManager:isWidgetShown(dialog) then UIManager:close(dialog) end
    end
    dialog = ButtonDialog:new{
        title=_(options.roots and "Scanning ebook folders…" or "Importing ebooks…"), dismissable=false,
        _added_widgets={CenterContainer:new{dimen=Geom:new{w=width, h=Device.screen:scaleBySize(60)}, status}},
        buttons={{{text=_("Cancel"), callback=dismiss}}},
    }
    local original_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(widget)
        if self.operation == operation then
            operation:close(); self.operation = nil
        end
        if original_close then original_close(widget) end
    end
    self.progress_dialog = dialog
    UIManager:show(self.scope:own(dialog))
    options.on_progress = operation:guard(function(stats)
        status:setText(string.format(_("Checked %d · Found %d"), stats.checked, stats.found))
        UIManager:setDirty(dialog, "ui")
    end)
    options.on_done = operation:guard(function(stats, reason)
        self.last_result = {stats=stats, reason=reason}
        self.operation = nil
        UIManager:close(dialog)
        operation:close()
        self.home.status = nil
        self.home:setSource("library")
        if reason then self:message(_(reason))
        else
            self:message(string.format(_("Added %d books\nAlready in library: %d\nSkipped: %d · Unreadable: %d"),
                stats.added, stats.duplicates, stats.skipped, stats.errors))
        end
    end)
    self.job = self.shelf.start(operation, options)
end

function Importer:defaultPath()
    if self.path and lfs.attributes(self.path, "mode") == "directory" then return ffiUtil.realpath(self.path) end
    return require("apps/filemanager/filemanagerutil").getHomeFolder()
end

return Importer
