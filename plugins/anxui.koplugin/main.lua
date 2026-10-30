local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

-- Plugin classes live across FileManager/ReaderUI instances. Keep only a file
-- identity here, never the old UI instance or its document. This is a one-shot
-- return intent for books opened from this library, not a startup preference.
local return_file
local return_state
local first_owner = true
local modules = {}

local AnxUI = WidgetContainer:extend{
    name = "anxui",
    is_doc_only = false,
}

function AnxUI:init()
    self.stopped = false
    self.scope = self:module("lifecycle").new()
    self.translate = self:module("i18n")
    self.settings = self:module("settings").new()
    self.recovery_reason = self.settings:recoveryReason()
    local options = self.settings:options()
    self.startup_candidate = self:module("startup").shouldOpen(options, {
        first_owner = first_owner, is_reader = self.ui.document ~= nil, recovery = self.recovery_reason,
        guide_shown = options.startup and require("ui/quickstart"):isShown(),
        original_start = G_reader_settings:readSetting("start_with", "filemanager"), arguments = arg,
    })
    first_owner = false
    local disabled = G_reader_settings:readSetting("plugins_disabled")
    if type(disabled) == "table" and disabled.anxui then
        self.stopped = true
        return
    end
    self.ui.menu:registerToMainMenu(self)
end

function AnxUI:module(name)
    local path = self.path .. "/" .. name .. ".lua"
    if not modules[path] then modules[path] = dofile(path) end
    return modules[path]
end

function AnxUI:addToMainMenu(menu_items)
    -- Menu order tables are the native plugin extension point. Only add our
    -- own IDs; disabled plugins contribute no items, and user menu orders can
    -- still override these defaults. Never retain an owner in these tables.
    local is_reader = self.ui.document ~= nil
    local order = require(is_reader and "ui/elements/reader_menu_order" or "ui/elements/filemanager_menu_order")
    local placements = {
        {id = "anxui_home_shortcut", group = is_reader and "navi" or "filemanager_settings"},
        {id = "anxui_home_tools", group = "tools"},
    }
    for _, placement in ipairs(placements) do
        local group = order[placement.group]
        local present = false
        for _, id in ipairs(group) do
            if id == placement.id then present = true; break end
        end
        if not present then table.insert(group, 1, placement.id) end
        menu_items[placement.id] = {
            text = self.translate("Open Anx library"),
            sorting_hint = placement.group,
            font_func = function(size) return require("ui/font"):getFace("smallinfofontbold", size) end,
            separator = true,
            enabled_func = function() return not self.stopped end,
            callback = function() self:showHome() end,
        }
    end
    menu_items.anxui_assistant = {
        text = self.translate("AI assistant"), sorting_hint = "more_tools",
        enabled_func = function() return not self.stopped end,
        callback = function() self:showAssistant() end,
    }
    menu_items.anxui_settings = {
        text = self.translate("Anx settings"), sorting_hint = "more_tools",
        enabled_func = function() return not self.stopped end,
        callback = function() self:showSettings() end,
    }
    menu_items.anxui_statistics = {
        text = self.translate("Anx reading statistics"), sorting_hint = "more_tools",
        enabled_func = function() return not self.stopped end,
        callback = function() self:showStatistics() end,
    }
    menu_items.anxui_notes = {
        text = self.translate("Notes across books"), sorting_hint = "more_tools",
        enabled_func = function() return not self.stopped end,
        callback = function() self:showNoteLibrary() end,
    }
    if self.ui.document then
        menu_items.anxui_reader = {
            text = self.translate("Anx reading tools"), sorting_hint = "more_tools",
            enabled_func = function() return not self.stopped end,
            callback = function() self:showReaderPanel() end,
        }
    end
    menu_items.anxui_home = {
        text = self.translate("Anx library"),
        sorting_hint = "more_tools",
        enabled_func = function() return not self.stopped end,
        callback = function() self:showHome() end,
    }
    menu_items.anxui_preferences = {
        text = self.translate("Anx appearance"), sorting_hint = "more_tools",
        enabled_func = function() return not self.stopped end,
        callback = function() self:showPreferences() end,
    }
end

function AnxUI:assistantSession()
    if not self.assistant then
        self.assistant = self:module("assistant").new(self.ui, self.scope,
            self:module("capabilities"), self:module("koassistant-lock"))
    end
    return self.assistant
end

function AnxUI:showAssistant()
    if self.stopped or self.assistant_view then return end
    local bridge = self:assistantSession()
    local status = bridge:status()
    local options = self:readerViewOptions("assistant_view")
    options.title, options.no_search, options.row_height = "AI assistant", true, 100
    options.status_text = self.translate(status.reason)
    options.entries = {
        {id = "general", text = self.translate("General chat"), subtitle = self.translate("Open the KOAssistant composer")},
        {id = "book", text = self.translate("Chat about this book"), subtitle = self.translate("Uses the current book context")},
        {id = "settings", text = self.translate("Assistant settings"), subtitle = self.translate("Provider, model and data access")},
    }
    options.on_select = function(entry)
        local current = bridge:status()
        if current.state ~= "available" then return self:readerResult(false, current.reason) end
        UIManager:close(self.assistant_view)
        if entry.id == "settings" then self:showNativeSetting("koassistant", "koassistant")
        else self:readerResult(bridge:open(entry.id)) end
    end
    options.actions = {
        {id = "refresh", text = "Refresh", callback = function()
            UIManager:close(self.assistant_view); self:showAssistant()
        end},
        {id = "close", text = "Close", callback = function() UIManager:close(self.assistant_view) end},
    }
    options.snapshot = status
    self.assistant_view = self:module("views/readerlist"):new(options)
    UIManager:show(self.scope:own(self.assistant_view))
end

function AnxUI:showStatistics()
    if self.stopped or self.statistics_view then return end
    local snapshot, reason = self:module("statistics").snapshot(self.ui, self:module("capabilities"))
    local options = self:readerViewOptions("statistics_view")
    options.title = "Statistics"
    options.subtitle = self.translate(snapshot and "Saved reading records" or reason)
    local function duration(seconds)
        return require("datetime").secondsToClockDuration(G_reader_settings:readSetting("duration_format"), seconds, false)
    end
    options.metrics = snapshot and {
        {label = "Today · time", value = duration(snapshot.today.duration)},
        {label = "Today · pages", value = tostring(snapshot.today.pages)},
        {label = "This session · time", value = duration(snapshot.session.duration)},
        {label = "This session · pages", value = tostring(snapshot.session.pages)},
        {label = "All time · reading", value = duration(snapshot.total.duration)},
        {label = "Books with records", value = tostring(snapshot.total.books)},
    } or {}
    local capability = self:module("capabilities").plugin(self.ui, "statistics", "onShowReaderProgress")
    options.actions = {
        {id = "refresh", text = "Refresh", callback = function()
            UIManager:close(self.statistics_view); self:showStatistics()
        end},
        {id = "details", text = "Classic statistics", enabled = capability.state == "available", callback = function()
            UIManager:close(self.statistics_view)
            local current = self:module("capabilities").plugin(self.ui, "statistics", "onShowReaderProgress")
            if current.state == "available" then
                self.scope:collectWindows(function() self.ui.statistics:onShowReaderProgress() end)
            else self:readerResult(false, current.reason) end
        end},
    }
    options.snapshot = snapshot
    self.statistics_view = self:module("views/dashboard"):new(options)
    UIManager:show(self.scope:own(self.statistics_view))
end

function AnxUI:readerSession()
    if self.stopped or not self.ui.document then return end
    if not self.reader then
        self.reader = self:module("reader").new(self.ui, self.scope, self:module("capabilities"))
    end
    if self.reader:active() then return self.reader end
end

function AnxUI:closeReaderViews()
    for _, key in ipairs({"reader_panel", "reader_list", "notes_library"}) do
        local view = self[key]
        self[key] = nil
        if view then UIManager:close(view) end
    end
end

function AnxUI:readerResult(ok, reason)
    if ok or self.stopped or reason == "stale_session" then return end
    UIManager:show(self.scope:own(require("ui/widget/infomessage"):new{
        text = self.translate(reason or "Unavailable in this context"),
    }))
end

function AnxUI:readerAction(action)
    local reader = self:readerSession()
    if not reader then return end
    self:closeReaderViews()
    self:readerResult(reader:run(action))
end

function AnxUI:readerViewOptions(key)
    return {
        scope = self:module("lifecycle").new(), new_scope = self:module("lifecycle").new,
        theme = self:module("theme").new(self.settings:options()),
        new_theme = function() return self:module("theme").new(self.settings:options()) end,
        widgets = self:module("widgets"), translate = self.translate,
        on_closed = function() self[key] = nil end,
    }
end

function AnxUI:showReaderPanel()
    local reader = self:readerSession()
    if not reader or self.reader_panel then return end
    self:closeReaderViews()
    local options = self:readerViewOptions("reader_panel")
    options.snapshot = reader:snapshot()
    options.actions = {
        {id = "toc", text = "Contents", callback = function() self:showReaderList("toc") end},
        {id = "progress", text = "Progress", callback = function() self:readerAction("progress") end},
        {id = "notes", text = "Notes", callback = function() self:showReaderList("notes") end},
    }
    for _, entry in ipairs({{"layout", "Reading settings"}, {"search", "Search text"}, {"bookmark", "Toggle bookmark"},
            {"back", "Previous location"}, {"advanced", "Advanced"}}) do
        options.actions[#options.actions + 1] = {id = entry[1], text = entry[2], enabled = reader:available(entry[1]),
            callback = function() self:readerAction(entry[1]) end}
    end
    options.actions[#options.actions + 1] = {id = "library", text = "Library", callback = function()
        self:closeReaderViews(); self:showHome()
    end}
    options.actions[#options.actions + 1] = {id = "dictionary", text = "Dictionaries", callback = function()
        self:closeReaderViews(); self:showNativeSetting("dictionary_lookup")
    end}
    options.actions[#options.actions + 1] = {id = "assistant", text = "AI assistant", callback = function()
        self:closeReaderViews(); self:showAssistant()
    end}
    self.reader_panel = self:module("views/readerpanel"):new(options)
    UIManager:show(self.scope:own(self.reader_panel))
end

function AnxUI:showReaderList(kind)
    local reader = self:readerSession()
    if not reader then return end
    self:closeReaderViews()
    local options = self:readerViewOptions("reader_list")
    options.title = kind == "toc" and "Contents" or "Notes"
    options.empty_text = kind == "toc" and "No chapters" or "No notes in this book"
    options.entries = kind == "toc" and reader:toc() or reader:notes()
    if kind == "notes" then
        options.filters = {{"all", "All"}, {"notes", "Notes"}, {"highlights", "Highlights"}, {"bookmarks", "Bookmarks"}}
        options.on_select = function(row)
            self:closeReaderViews(); self:readerResult(reader:noteAction("goto", row))
        end
        options.on_hold = function(row) self:showNoteActions(row) end
    else
        for _, row in ipairs(options.entries) do
            row.subtitle = self.translate("Level") .. " " .. row.depth .. " · " .. self.translate("Page") .. " " .. row.page
        end
        options.on_select = function(row)
            self:closeReaderViews(); self:readerResult(reader:gotoChapter(row))
        end
    end
    options.actions = {
        {id = "original", text = "Classic interface", callback = function()
            self:readerAction(kind == "toc" and "original_toc" or "original_notes")
        end},
        {id = "tools", text = "Reading tools", callback = function() self:showReaderPanel() end},
    }
    if kind == "notes" then
        options.actions[#options.actions + 1] = {id = "export", text = "Export", callback = function()
            self:readerAction("export")
        end}
        options.actions[#options.actions + 1] = {id = "all_books", text = "All books", callback = function()
            self:showNoteLibrary()
        end}
    end
    self.reader_list = self:module("views/readerlist"):new(options)
    UIManager:show(self.scope:own(self.reader_list))
end

function AnxUI:showNoteLibrary()
    if self.stopped or self.notes_library then return end
    self:closeReaderViews()
    local options = self:readerViewOptions("notes_library")
    local index_module = self:module("noteindex")
    local library = self:module("library")
    local ok, index = pcall(index_module.new, options.scope, options.new_scope, library)
    if not ok then
        options.scope:close()
        require("logger").warn("Anx note index could not open:", index)
        self:readerResult(false, "The note index could not be opened.")
        return
    end
    self.note_index = index
    options.title, options.empty_text = "Notes across books", "Build an index to find notes across books"
    options.status_text = self.translate("Folder, history and collections · refresh to update")
    options.filters = {{"all", "All"}, {"notes", "Notes"}, {"highlights", "Highlights"}, {"bookmarks", "Bookmarks"}}
    options.load_page = function(...) return index:page(...) end
    options.on_select = function(row) self:openIndexedNote(row) end
    options.on_hold = options.on_select
    options.actions = {
        {id = "rebuild", text = "Rebuild index", callback = function()
            local view = self.notes_library
            if index.running then
                index:cancel()
                view.status_text = self.translate("Index rebuild canceled; previous cache restored")
                view.actions[1].text = "Rebuild index"
                view:rebuild()
                return
            end
            view.actions[1].text = "Cancel"
            index:rebuild(index_module.sources(self.ui, library), self:readerSession(), function(stats)
                if stats.scanned % 10 == 0 or stats.scanned == stats.books then
                    view.status_text = string.format("%s %d / %d · %d", self.translate("Indexing"), stats.scanned, stats.books, stats.notes)
                    view:rebuild()
                end
            end, function(stats, error_message)
                view.status_text = stats and string.format("%s: %d · %s: %d", self.translate("Indexed books"), stats.scanned,
                    self.translate("Skipped items"), stats.skipped) or self.translate(error_message)
                view.actions[1].text = "Rebuild index"
                view:rebuild()
            end)
            view:rebuild()
        end},
        {id = "clear", text = "Clear index", callback = function()
            index:clear()
            self.notes_library.actions[1].text = "Rebuild index"
            self.notes_library.status_text = self.translate("Index cleared; original notes are unchanged")
            self.notes_library:rebuild()
        end},
        {id = "close", text = "Close", callback = function() self.notes_library:onClose() end},
    }
    options.on_closed = function() self.notes_library, self.note_index = nil, nil end
    self.notes_library = self:module("views/readerlist"):new(options)
    UIManager:show(self.scope:own(self.notes_library))
end

function AnxUI:openIndexedNote(row)
    if self.stopped then return end
    local reader = self:readerSession()
    if reader and reader.document.file == row.file then
        self:closeReaderViews(); self:readerResult(reader:gotoStoredNote(row.anchor)); return
    end
    if self:module("library").signature(row.file) ~= row.signature then
        self:readerResult(false, "This book has changed or moved. Rebuild the note index.")
        return
    end
    -- The original after-open callback supplies the NEW ReaderUI. Carry values
    -- only across this transition; never guard it with the already-closed owner.
    local anchor = row.anchor
    local function after_open(new_ui)
        local plugin = new_ui.anxui
        if not plugin or plugin.stopped then return end
        plugin.scope:later(0, function()
            local session = plugin:readerSession()
            if session then plugin:readerResult(session:gotoStoredNote(anchor)) end
        end)
    end
    self:closeReaderViews()
    if reader then self.ui:switchDocument(row.file, nil, after_open)
    else self:openBook(row.file, after_open) end
end

function AnxUI:showNoteActions(row)
    local reader = self:readerSession()
    if not reader or not self.reader_list or self.note_actions then return end
    local action_scope, menu = self:module("lifecycle").new(), nil
    local function action(name)
        return action_scope:guard(function()
            UIManager:close(menu)
            self:closeReaderViews()
            if name == "delete" then self:confirmDeleteNote(row)
            else self:readerResult(reader:noteAction(name, row)) end
        end)
    end
    menu = require("ui/widget/menu"):new{title = self.translate("Note actions"), item_table = {
        {text = self.translate("Go to location"), callback = action("goto")},
        {text = self.translate("Edit note"), callback = action("edit")},
        {text = self.translate("Delete"), callback = action("delete")},
    }}
    local original_close = menu.onCloseWidget
    menu.onCloseWidget = function(widget)
        action_scope:close(); self.note_actions = nil
        if original_close then original_close(widget) end
    end
    self.note_actions = menu
    UIManager:show(self.reader_list.scope:own(menu))
end

function AnxUI:confirmDeleteNote(row)
    local reader = self:readerSession()
    if not reader then return end
    local scope = self:module("lifecycle").new()
    local dialog = require("ui/widget/confirmbox"):new{
        text = self.translate("Delete this annotation?"), ok_text = self.translate("Delete"),
        ok_callback = scope:guard(function()
            self:readerResult(reader:noteAction("delete", row)); self:showReaderList("notes")
        end),
    }
    local original_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(widget)
        scope:close(); if original_close then original_close(widget) end
    end
    UIManager:show(self.scope:own(dialog))
end

function AnxUI:showHome()
    if self.stopped or self.home then
        return
    end
    if self.recovery_reason then return self:showRecovery() end
    if self.ui.document then
        return_file = self.ui.document.file
        self.ui:onHome()
        return
    end
    -- Resolve relative to the loader's actual plugin path, including external
    -- installation paths, without global require names such as "home".
    local page_scope = self:module("lifecycle").new()
    local home
    self.settings:update("opening", true)
    local ok, err = xpcall(function()
        home = self:module("views/home"):new{
            scope = page_scope,
            state = self.home_state,
            library = self:module("library"),
            new_scope = self:module("lifecycle").new,
            new_covers = function(scope, gray) return self:module("covers").new(scope, self.ui, gray) end,
            load_source = function(source, collection) return self:getBookItems(source, collection) end,
            on_open_book = page_scope:guard(function(file) self:openBook(file) end),
            on_book_actions = page_scope:guard(function(file) self:showBookActions(file) end),
            theme = self:module("theme").new(self.settings:options()),
            new_theme = function() return self:module("theme").new(self.settings:options()) end,
            widgets = self:module("widgets"), translate = self.translate,
            on_preferences = function() self:showSettings() end,
            on_statistics = function() self:showStatistics() end,
            on_notes = function() self:showNoteLibrary() end,
            on_continue = function()
                local file = G_reader_settings:readSetting("lastfile")
                if file then self:openBook(file) end
            end,
            on_ready = function() self.settings:update("opening", false) end,
            on_closed = function()
                if home then self.home_state = home:viewState() end
                if self.home == home then self.home = nil end
                self.settings:update("opening", false)
            end,
        }
    end, debug.traceback)
    if not ok then
        page_scope:close()
        self.recovery_reason = "unfinished_open"
        require("logger").err("Anx UI home failed:", err)
        UIManager:show(self.scope:own(require("ui/widget/infomessage"):new{
            text = self.translate("The library could not open. The classic interface is available. Retry from the Anx library menu."),
        }))
        return false, "home_failed"
    end
    self.home = home
    self.scope:own(home)
    UIManager:show(home)
end

function AnxUI:showRecovery()
    if self.stopped or self.recovery_dialog then return end
    local dialog_scope = self:module("lifecycle").new()
    local reset = self.recovery_reason ~= "unfinished_open"
    local _ = self.translate
    local dialog = require("ui/widget/confirmbox"):new{
        text = reset and _("The Anx interface settings cannot be read. Reset only these interface settings?")
            or _("The Anx library did not finish opening last time. You can keep using the classic interface or retry."),
        ok_text = reset and _("Reset interface settings") or _("Retry"),
        cancel_text = _("Classic interface"),
        ok_callback = dialog_scope:guard(function()
            if reset then self.settings:reset() else self.settings:update("opening", false) end
            self.recovery_reason, self.recovery_dialog = nil, nil
            self:showHome()
        end),
        cancel_callback = function() self.recovery_dialog = nil end,
    }
    local original_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(widget)
        dialog_scope:close()
        if self.recovery_dialog == widget then self.recovery_dialog = nil end
        if original_close then return original_close(widget) end
    end
    self.recovery_dialog = dialog
    UIManager:show(self.scope:own(dialog))
end

function AnxUI:closePreferences()
    local menu = self.preferences_menu
    self.preferences_menu = nil
    if menu and UIManager:isWidgetShown(menu) then UIManager:close(menu) end
end

function AnxUI:showNativeSetting(id, plugin)
    if self.stopped then return end
    if plugin then
        local capability = self:module("capabilities").plugin(self.ui, plugin)
        if capability.state ~= "available" then return self:readerResult(false, capability.reason) end
    end
    if self.settings_view then UIManager:close(self.settings_view) end
    self:readerResult(self:module("native").open(self.ui, id, self.scope))
end

function AnxUI:showSettings(group)
    if self.stopped then return end
    if self.recovery_reason then return self:showRecovery() end
    if self.settings_view then UIManager:close(self.settings_view) end
    local options = self:readerViewOptions("settings_view")
    local groups = {
        {id = "appearance", text = "Appearance", subtitle = "Theme, text size and startup"},
        {id = "reading", text = "Reading preferences", subtitle = "Layout, dictionaries and statistics"},
        {id = "device", text = "Device", subtitle = "Screen, input and network"},
        {id = "sync", text = "Sync", subtitle = "Reading progress and book files"},
        {id = "plugins", text = "Plugins", subtitle = "Native plugin manager and advanced settings"},
        {id = "assistant", text = "AI assistant", subtitle = "Optional KOAssistant"},
    }
    local entries = {
        reading = {
            {id = "layout", text = "Reading settings", subtitle = "Open a book to adjust its layout", reader_action = "layout"},
            {id = "document", text = "Document settings", subtitle = "Native document preferences", native = "document"},
            {id = "dictionary_settings", text = "Dictionaries", subtitle = "Native dictionary preferences", native = "dictionary_settings"},
            {id = "statistics", text = "Statistics", subtitle = "Saved reading records"},
        },
        device = {
            {id = "screen", text = "Screen", subtitle = "Rotation, display and refresh", native = "screen"},
            {id = "device", text = "Device", subtitle = "Keyboard and device preferences", native = "device"},
            {id = "navigation", text = "Navigation", subtitle = "Back button and input", native = "navigation"},
            {id = "network", text = "Network", subtitle = "Native network preferences", native = "network"},
        },
        sync = {
            {id = "progress_sync", text = "Reading progress sync", subtitle = "Position only; does not transfer book files", native = "progress_sync", plugin = "kosync"},
            {id = "cloudstorage", text = "Book files and cloud storage", subtitle = "File transfer; separate from reading position", native = "cloudstorage", plugin = "cloudstorage"},
        },
        plugins = {
            {id = "plugin_management", text = "Plugin manager", subtitle = "Enable or disable installed plugins", native = "plugin_management"},
            {id = "advanced_settings", text = "Advanced settings (classic)", subtitle = "Native advanced preferences", native = "advanced_settings"},
        },
    }
    options.title, options.row_height, options.no_search = "Settings", 72, true
    for _, entry in ipairs(groups) do if entry.id == group then options.title = entry.text end end
    options.entries = entries[group] or groups
    for _, entry in ipairs(options.entries) do
        entry.text, entry.subtitle = self.translate(entry.text), self.translate(entry.subtitle)
        local reason
        if entry.plugin then
            local capability = self:module("capabilities").plugin(self.ui, entry.plugin)
            if capability.state ~= "available" then reason = capability.reason end
        elseif entry.reader_action and not self:readerSession() then reason = "Unavailable in this context" end
        if entry.native and not reason then
            local route
            route, reason = self:module("native").resolve(self.ui, entry.native)
            if route then reason = nil end
        end
        if reason then entry.subtitle = self.translate(reason) end
    end
    options.on_select = function(entry)
        if entry.native then return self:showNativeSetting(entry.native, entry.plugin) end
        if entry.reader_action then
            if not self:readerSession() then return self:readerResult(false, "Unavailable in this context") end
            UIManager:close(self.settings_view); return self:readerAction(entry.reader_action)
        end
        UIManager:close(self.settings_view)
        if entry.id == "appearance" then self:showPreferences()
        elseif entry.id == "statistics" then self:showStatistics()
        elseif entry.id == "assistant" then
            if self.showAssistant then self:showAssistant() else self:readerResult(false, "Unavailable in this context") end
        else self:showSettings(entry.id) end
    end
    options.actions = {
        {id = "back", text = group and "Settings" or "Close", callback = function()
            UIManager:close(self.settings_view); if group then self:showSettings() end
        end},
        {id = "classic", text = "Classic interface", callback = function() self:showNativeSetting("setting") end},
    }
    self.settings_view = self:module("views/readerlist"):new(options)
    UIManager:show(self.scope:own(self.settings_view))
end

function AnxUI:showPreferences()
    if self.stopped or self.preferences_menu then return end
    if self.recovery_reason then return self:showRecovery() end
    local _, options = self.translate, self.settings:options()
    local menu_scope = self:module("lifecycle").new()
    local function change(key, value)
        self:closePreferences()
        if self.stopped then return end
        self.settings:update(key, value)
        if self.home then
            self.home.theme = self:module("theme").new(self.settings:options())
            self.home:rebuild()
        end
    end
    local modes = {}
    for __, entry in ipairs({ {"auto", "Automatic"}, {"color", "Color"}, {"gray", "Grayscale"} }) do
        table.insert(modes, {
            text = (options.mode == entry[1] and "✓ " or "") .. _(entry[2]),
            callback = menu_scope:guard(function() change("mode", entry[1]) end),
        })
    end
    local statistics = self:module("capabilities").plugin(self.ui, "statistics", "onShowReaderProgress")
    local menu = require("ui/widget/menu"):new{
        title = _("Anx appearance"), width = math.floor(require("device").screen:getWidth() * .9),
        item_table = {
            { text = _("Display mode"), sub_item_table = modes },
            { text = (options.large_text and "✓ " or "") .. _("Larger interface text"),
                callback = menu_scope:guard(function() change("large_text", not options.large_text) end) },
            { text = _("Statistics") .. ": " .. _(statistics.reason), callback = menu_scope:guard(function()
                self:closePreferences(); self:showStatistics()
            end) },
            { text = _("KOReader settings"), callback = menu_scope:guard(function()
                self:closePreferences()
                self:closeHome()
                self:showNativeSetting("setting")
            end) },
            { text = _("Classic interface"), callback = menu_scope:guard(function()
                self:closePreferences()
                self:closeHome()
            end) },
            { text = (options.startup and "✓ " or "") .. _("Open Anx library at startup"),
                callback = menu_scope:guard(function() change("startup", not options.startup) end) },
        },
    }
    local original_close = menu.onCloseWidget
    menu.onCloseWidget = function(widget)
        menu_scope:close()
        if self.preferences_menu == widget then self.preferences_menu = nil end
        if original_close then return original_close(widget) end
    end
    self.preferences_menu = menu
    UIManager:show(self.scope:own(menu))
end

function AnxUI:getBookItems(source, collection)
    -- Keep the full-library snapshot free of per-item closures. Actions are
    -- bound only to the visible cards and expire with their render scope. The
    -- scratch array belongs to this owner and is refreshed on every load.
    self.book_items = self:module("library").snapshot(self.ui, source, collection, self.book_items)
    return self.book_items
end

function AnxUI:showBookActions(file)
    if self.stopped or not self.home or self.book_actions then return end
    if not self:module("library").signature(file) then
        return self.home:showError("This book no longer exists. Refresh the folder in the classic interface.")
    end
    local _, dialog = self.translate
    local action_scope = self:module("lifecycle").new()
    local function action(callback)
        return action_scope:guard(function()
            UIManager:close(dialog)
            callback()
        end)
    end
    dialog = require("ui/widget/menu"):new{
        title = file:match("([^/]+)$"),
        item_table = {
            { text = _("Read"), callback = action(function() self:openBook(file) end) },
            { text = _("Book information"), callback = action(function()
                self:closeHome(); self.ui.bookinfo:show(file)
            end) },
            { text = _("Collections"), callback = action(function()
                self:closeHome()
                self.ui.collections:genAddToCollectionButton(file).callback()
            end) },
            { text = _("More book actions (classic)"), callback = action(function()
                self:closeHome()
                local folder = file:match("(.+)/[^/]+$")
                self.ui.file_chooser:changeToPath(folder, file)
                self.ui.file_chooser:onFileHold{path = file, text = file:match("([^/]+)$"), is_file = true}
            end) },
        },
    }
    local original_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(widget)
        action_scope:close()
        if self.book_actions == widget then self.book_actions = nil end
        if original_close then original_close(widget) end
    end
    self.book_actions = dialog
    UIManager:show(self.home.scope:own(dialog))
end

function AnxUI:openBook(file, after_open_callback)
    if self.stopped or self.ui.document then
        return
    end
    if type(file) ~= "string" or require("libs/libkoreader-lfs").attributes(file, "mode") ~= "file" then
        if self.home then
            self.home:showError("This book no longer exists. Refresh the folder in the classic interface.")
        end
        return false, "missing_file"
    end
    self.ui:openFile(file, nil, function()
        return_file = file
        if self.home then self.home.selected_file = file end
        return_state = self.home and self.home:viewState() or nil
        self:closeHome()
    end, function()
        -- Auxiliary providers own their own navigation; no reader return intent.
        return_file = nil
        return_state = nil
        self:closeHome()
    end, after_open_callback)
end

function AnxUI:onShow()
    if self.ui.document or self.stopped then
        return
    end
    local should_return = return_file and return_file == G_reader_settings:readSetting("lastfile")
    local startup = self.startup_candidate
    self.startup_candidate = false
    return_file = nil
    local state = return_state
    return_state = nil
    if not should_return and not startup then return end
    self.home_state = state
    -- Show is sent after FileManager.instance has been assigned. Defer one tick
    -- so the original file manager completes its own show processing first.
    self.show_pending = self.scope:later(0, function()
        self.show_pending = nil
        local FileManager = require("apps/filemanager/filemanager")
        if not self.stopped and FileManager.instance == self.ui then
            if startup then
                local stack = UIManager._window_stack
                -- Modal notices (including the native first-run cache update)
                -- stay above our non-modal home. Preserve other startup pages.
                for index = #stack, 1, -1 do
                    local widget = stack[index].widget
                    if widget == self.ui then break end
                    if not widget.modal and not widget.toast then return end
                end
            end
            self:showHome()
        end
    end)
end

function AnxUI:closeHome()
    local home = self.home
    self.home = nil
    if home then
        UIManager:close(home)
    end
end

function AnxUI:stopPlugin()
    return_file = nil
    return_state = nil
    self:onCloseWidget()
end

function AnxUI:onCloseWidget()
    self.stopped = true
    self.scope:close()
    self.show_pending = nil
    self.home = nil
    self.book_items = nil
    self.reader, self.reader_panel, self.reader_list, self.note_actions = nil, nil, nil, nil
    self.notes_library, self.note_index = nil, nil
    self.statistics_view = nil
    self.preferences_menu, self.recovery_dialog = nil, nil
end

return AnxUI
