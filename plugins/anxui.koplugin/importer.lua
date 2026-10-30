local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FileChooser = require("ui/widget/filechooser")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local Importer = {}
Importer.__index = Importer

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
    local function updateTitle(widget)
        local count = 0
        for __ in pairs(selected) do count = count + 1 end
        widget.title_bar:setTitle(_("Select books, then tap ✓") .. " (" .. count .. ")")
        widget:updateItems()
    end
    picker = FileChooser:new{
        name="anxui_import_picker", title=folder and _("Choose a folder, then tap ✓") or _("Select books, then tap ✓") .. " (0)",
        title_shrink_font_to_fit=true, title_bar_left_icon="check",
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
            for _, item in ipairs(widget.item_table) do
                if item.is_file then selected[item.path], item.dim = true, true end
            end
            updateTitle(widget)
        end,
        onFileSelect=function(widget, item)
            if folder or self.picker ~= widget then return end
            selected[item.path] = not selected[item.path] or nil
            item.dim = selected[item.path]
            updateTitle(widget)
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
    local dialog, dialog_scope = nil, self.new_scope()
    dialog = ButtonDialog:new{
        title=_("Scan folders and subfolders") .. "\n\n" .. table.concat(roots, "\n") .. "\n\n"
            .. _("Books stay in their original locations. Existing books are skipped."),
        buttons={{
            {text=_("Cancel"), callback=function() UIManager:close(dialog) end},
            {text=_("Start scan"), callback=dialog_scope:guard(function()
                UIManager:close(dialog)
                self:run({roots=roots, recursive=true})
            end)},
        }},
    }
    local original_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(widget)
        dialog_scope:close()
        if self.scan_confirmation == widget then self.scan_confirmation = nil end
        if original_close then original_close(widget) end
    end
    self.scan_confirmation = dialog
    UIManager:show(self.scope:own(dialog))
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
