local Event = require("ui/event")
local UIManager = require("ui/uimanager")

-- A reader session owns these references. Nothing in this module retains a
-- ReaderUI or a document after that session has closed.
local Reader = {}
Reader.__index = Reader

function Reader.new(ui, scope, capabilities, current)
    local self = setmetatable({ ui = ui, document = ui.document, scope = scope,
        capabilities = capabilities, current = current or function()
            return require("apps/reader/readerui").instance
        end }, Reader)
    scope:defer(function() self.ui, self.document = nil, nil end)
    return self
end

function Reader:active()
    return self.scope.alive and self.ui ~= nil and self.document ~= nil
        and self.current() == self.ui and self.ui.document == self.document
        and not self.ui.tearing_down
end

local actions = {
    progress = { "gotopage", "onShowGotoDialog" },
    layout = { "config", "onShowConfigMenu" },
    search = { "search", "onShowFulltextSearchInput" },
    advanced = { "menu", "onShowMenu" },
    original_toc = { "toc", "onShowToc" },
    original_notes = { "bookmark", "onShowBookmark" },
    back = { "link", "onGoBackLink" },
    bookmark = { "bookmark", "onToggleBookmark" },
}

function Reader:available(action)
    if not self:active() then return false, "Unavailable in this context" end
    if action == "export" then
        local capability = self.capabilities.plugin(self.ui, "exporter", "onExportCurrentNotes")
        if capability.state ~= "available" then return false, capability.reason end
        return self.ui.exporter:isReadyToExport(), "Choose an export format in the classic menu first."
    end
    local target = actions[action]
    return target and self.ui[target[1]]
        and self.capabilities.callable(self.ui[target[1]][target[2]]) or false,
        "Unavailable in this context"
end

function Reader:snapshot()
    if not self:active() then return nil, "stale_session" end
    local ui, doc = self.ui, self.document
    return {
        file = doc.file,
        title = ui.doc_props and ui.doc_props.title or doc.file:match("([^/]+)$"),
        page = ui:getCurrentPage(), pages = doc:getPageCount(),
        percent = ui.view and ui.view.footer and ui.view.footer.percent_finished,
        mode = ui.paging and (doc.configurable and doc.configurable.text_wrap == 1 and "Reflow" or "Pages") or "Text",
    }
end

-- Keep original dialogs and writers. Own only windows created by this call so
-- they cannot remain on screen after the reader/plugin has been closed.
function Reader:withWindows(callback)
    if not self:active() then return nil, "stale_session" end
    local existing = {}
    for _, window in ipairs(UIManager._window_stack) do existing[window.widget] = true end
    local result = callback()
    for _, window in ipairs(UIManager._window_stack) do
        if not existing[window.widget] then self.scope:own(window.widget) end
    end
    return result
end

function Reader:run(action)
    local available, reason = self:available(action)
    if not available then return false, reason end
    self:withWindows(function()
        if action == "export" then return self.ui.exporter:onExportCurrentNotes() end
        local target = actions[action]
        local owner = self.ui[target[1]]
        return owner[target[2]](owner)
    end)
    return true
end

function Reader:toc()
    if not self:active() then return {} end
    self.ui.toc:fillToc()
    local result = {}
    for _, entry in ipairs(self.ui.toc.toc or {}) do
        result[#result + 1] = { origin = entry, text = entry.title or "", depth = entry.depth or 1,
            page = entry.page, xpointer = entry.xpointer }
    end
    return result
end

function Reader:gotoChapter(row)
    if not self:active() then return false, "stale_session" end
    local found = false
    for _, entry in ipairs(self.ui.toc.toc or {}) do
        if entry == row.origin then found = true; break end
    end
    if not found then return false, "This item has changed. Reopen the list." end
    self.ui.link:addCurrentLocationToStack()
    local item = row.origin
    if item.xpointer then
        self.ui:handleEvent(Event:new("GotoXPointer", item.xpointer, item.xpointer))
    else
        self.ui:handleEvent(Event:new("GotoPage", item.page))
    end
    return true
end

function Reader:notes()
    if not self:active() then return {} end
    local result = {}
    for _, item in ipairs(self.ui.annotation.annotations) do
        result[#result + 1] = {
            origin = item, text = item.text or "", note = item.note,
            kind = item.drawer and "highlights" or "bookmarks", has_note = item.note ~= nil and item.note ~= "",
            page_label = self.ui.bookmark:getBookmarkPageString(item.page), datetime = item.datetime,
        }
    end
    return result
end

function Reader:resolveNote(row)
    if not self:active() then return nil, "stale_session" end
    -- Resolve again at invocation, since edits/deletions can shift indexes.
    -- Identity also distinguishes equal anchors and same-second timestamps.
    for index, item in ipairs(self.ui.annotation.annotations) do
        if item == row.origin then return index, item end
    end
    return nil, "This item has changed. Reopen the list."
end

function Reader:noteAction(action, row)
    local index, item = self:resolveNote(row)
    if not index then return false, item end
    if action == "goto" then
        self.ui.link:addCurrentLocationToStack()
        self.ui.bookmark:gotoBookmark(item.page, item.pos0)
    elseif action == "edit" then
        -- A native list, if any, must close before its editor receives an index.
        if self.ui.bookmark.bookmark_menu then return false, "Close the classic notes list first." end
        self:withWindows(function() self.ui.bookmark:setBookmarkNote(index) end)
    elseif action == "delete" then
        self.ui.bookmark:removeItem(item, index)
    else
        return false, "Unavailable in this context"
    end
    return true
end

function Reader:gotoStoredNote(anchor)
    if not self:active() then return false, "stale_session" end
    if type(anchor.page) ~= (self.ui.rolling and "string" or "number") then
        return false, "The annotation belongs to a different document engine. Open classic notes."
    end
    local match, found = self.ui.annotation:getMatchFunc(), nil
    for _, item in ipairs(self.ui.annotation.annotations) do
        -- Native rolling bookmark matching alone omits page for dogears.
        -- Also require the exact page anchor and kind before its match check.
        if anchor.page == item.page and (not not anchor.drawer) == (not not item.drawer) then
            local ok, matches = pcall(match, anchor, item)
            if ok and matches then
                if found then return false, "This item has changed. Reopen the list." end
                found = item
            end
        end
    end
    if not found then return false, "This item has changed. Reopen the list." end
    return self:noteAction("goto", {origin = found})
end

return Reader
