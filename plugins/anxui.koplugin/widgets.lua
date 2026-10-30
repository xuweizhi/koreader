local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Widgets = {}

function Widgets.text(text, theme, size, width, bold, muted)
    return TextWidget:new{
        text = text, face = Font:getFace("cfont", size or theme.body),
        fgcolor = muted and theme.muted or theme.ink,
        max_width = width, bold = bold or false, padding = 0,
    }
end

function Widgets.button(text, width, theme, callback, options)
    options = options or {}
    return Button:new{
        text = text, width = width, height = theme.touch,
        text_font_size = theme.body, text_font_bold = options.selected or false,
        padding = 0, padding_h = theme.s(8), bordersize = 0,
        background = options.selected and theme.selected or theme.surface,
        radius = theme.radius, enabled = options.enabled ~= false,
        callback = callback, show_parent = options.parent,
    }
end

-- Keep the label and icon in one focusable/tappable target. Native Button is
-- text-or-icon, so navigation composes the same containers without global UI changes.
local Navigation = InputContainer:extend{}

function Navigation:init()
    local t = self.theme
    self.dimen = Geom:new{w = self.width, h = t.touch}
    self.icon_widget = IconWidget:new{icon = self.icon, alpha = true, width = t.s(20), height = t.s(20)}
    self.label_widget = Widgets.text(self.text, t, t.body, self.width - t.s(8), self.selected)
    local content = VerticalGroup:new{
        self.icon_widget, VerticalSpan:new{width = t.s(2)}, self.label_widget,
    }
    self.frame = FrameContainer:new{
        padding = 0, bordersize = 0, radius = t.radius,
        background = self.selected and t.selected or t.surface,
        focusable = true, focus_inner_border = true, focus_border_size = math.max(1, t.s(2)),
        CenterContainer:new{dimen = self.dimen:copy(), content},
    }
    self[1] = self.frame
    self.ges_events.TapNavigation = {GestureRange:new{ges = "tap", range = self.dimen}}
end

function Navigation:onTapNavigation()
    if self.callback then self.callback() end
    return true
end

function Navigation:onFocus()
    self.frame:onFocus(); UIManager:setDirty(self.show_parent, "ui", self.dimen); return true
end

function Navigation:onUnfocus()
    self.frame:onUnfocus(); UIManager:setDirty(self.show_parent, "ui", self.dimen); return true
end

function Widgets.navigation(text, icon, width, theme, callback, options)
    options = options or {}
    return Navigation:new{text = text, icon = icon, width = width, theme = theme,
        callback = callback, show_parent = options.parent, selected = options.selected}
end

local Card = InputContainer:extend{}

function Card:init()
    local t, s = self.theme, self.theme.s
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local inner = self.width - s(16)
    local cover_height = math.max(1, self.list_mode and self.height - s(16) or self.height - s(112 * t.text_scale))
    local cover_width = self.list_mode and math.floor(cover_height * .7) or inner
    local text_width = self.list_mode and inner - cover_width - s(12) or inner
    local title = TextBoxWidget:new{
        text = self.info and self.info.title or self.item.title or self.item.text, face = Font:getFace("cfont", t.body), bold = true,
        fgcolor = t.ink, bgcolor = t.background, width = text_width,
        height = s(48 * t.text_scale), height_overflow_show_ellipsis = true,
    }
    local cover_content
    if self.info and self.info.cover then
        local buffer = self.info.cover
        cover_content = ImageWidget:new{
            image = buffer, image_disposable = false, width = cover_width, height = cover_height,
            scale_factor = math.min(1, cover_width / buffer.w, cover_height / buffer.h),
        }
        cover_content:_render() -- Bounded bitmap only; no document I/O in paintTo.
    else
        cover_content = VerticalGroup:new{
            Widgets.text((self.item.file:match("%.([^%.]+)$") or "BOOK"):upper(), t,
                (self.list_mode or cover_height < s(80)) and t.small or t.title, cover_width),
        }
        if not self.list_mode and cover_height >= s(80) then
            table.insert(cover_content, VerticalSpan:new{ width = s(8) })
            table.insert(cover_content, Widgets.text(self.translate(self.info and "No cover" or "Loading cover…"),
                t, t.small, cover_width, false, true))
        end
    end
    local cover = FrameContainer:new{
        bordersize = t.gray and s(1) or 0, color = t.outline,
        background = t.surface, radius = t.radius, padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = cover_width, h = cover_height }, cover_content,
        },
    }
    local description = VerticalGroup:new{ align = "left", title,
        Widgets.text(self.info and self.info.authors or self.item.authors or self.translate("Unknown author"),
            t, t.small, text_width, false, true),
    }
    local progress = self.progress or {}
    local progress_text = type(progress.percent) == "number" and progress.percent >= 0 and progress.percent <= 1
        and string.format("%d%%", math.floor(progress.percent * 100 + .5))
        or self.translate(progress.opened and "Reading" or "Unread")
    table.insert(description, Widgets.text(progress_text, t, t.small, text_width, false, true))
    local content = self.list_mode and HorizontalGroup:new{
        cover, HorizontalSpan:new{ width = s(12) }, description,
    } or VerticalGroup:new{ align = "left", cover, VerticalSpan:new{ width = s(8) }, description }
    self.frame = FrameContainer:new{
        width = self.width, height = self.height, padding = s(8),
        bordersize = 0, background = t.background, radius = t.radius,
        focusable = true, focus_inner_border = true, focus_border_size = s(2),
        content,
    }
    self[1] = self.frame
    self.ges_events.TapCard = { GestureRange:new{ ges = "tap", range = self.dimen } }
    self.ges_events.HoldCard = { GestureRange:new{ ges = "hold", range = self.dimen } }
end

function Card:updateInfo(info)
    local focused = self.frame._focused
    self:clear()
    local position = self.dimen:copy()
    self.info = info
    if info.title then self.item.title = info.title end
    if info.authors then self.item.authors = info.authors end
    self:init()
    if focused then self.frame:onFocus() end
    self.dimen.x, self.dimen.y = position.x, position.y
    UIManager:setDirty(self.show_parent, "ui")
end

function Card:onTapCard()
    if self.callback then self.callback() end
    return true
end

function Card:onHoldCard()
    if self.hold_callback then self.hold_callback() end
    return true
end

function Card:onFocus()
    self.show_parent.selected_file = self.item.file
    self.frame:onFocus()
    UIManager:setDirty(self.show_parent, "ui", self.dimen)
    return true
end

function Card:onUnfocus()
    self.frame:onUnfocus()
    UIManager:setDirty(self.show_parent, "ui", self.dimen)
    return true
end

Widgets.Card = Card

local Row = InputContainer:extend{}

function Row:init()
    local t, entry = self.theme, self.entry
    local padding = t.s(12)
    local inner = self.width - 2 * padding
    self.dimen = Geom:new{w = self.width, h = self.height}
    local title = entry.text
    if title == "" then title = self.translate("Bookmark") end
    local note_height = entry.has_note and t.s(28 * t.text_scale) or 0
    local content = VerticalGroup:new{align = "left",
        TextBoxWidget:new{
            text = title, face = Font:getFace("cfont", t.body), fgcolor = t.ink, bgcolor = t.surface,
            width = inner, height = math.max(t.s(24), self.height - 2 * padding - t.s(24 * t.text_scale) - note_height),
            height_overflow_show_ellipsis = true,
        },
    }
    if entry.has_note then
        table.insert(content, Widgets.text(self.translate("Note") .. ": " .. entry.note, t, t.body, inner))
    end
    local type_label, type_icon
    if entry.kind == "bookmarks" or entry.kind == "highlights" then
        type_label = self.translate(entry.has_note and "Note" or entry.kind == "highlights" and "Highlights" or "Bookmark")
        type_icon = entry.has_note and "edit" or entry.kind == "highlights" and "appbar.typeset" or "bookmark"
    end
    local subtitle = entry.subtitle or ((type_label or self.translate("Bookmark"))
        .. " · " .. (entry.page_label or entry.page or "") .. (entry.datetime and " · " .. entry.datetime or ""))
    if type_icon then
        -- Cross-book subtitles contain the book name; keep the note type explicit.
        if entry.subtitle then subtitle = type_label .. " · " .. subtitle end
        local icon_size, gap = t.s(20), t.s(4)
        self.type_icon = IconWidget:new{icon = type_icon, alpha = true, width = icon_size, height = icon_size}
        table.insert(content, HorizontalGroup:new{
            self.type_icon, HorizontalSpan:new{width = gap},
            Widgets.text(subtitle, t, t.small, inner - icon_size - gap, false, true),
        })
    else
        table.insert(content, Widgets.text(subtitle, t, t.small, inner, false, true))
    end
    self.frame = FrameContainer:new{width = self.width, height = self.height, padding = padding,
        bordersize = 0, background = t.surface, radius = t.radius,
        focusable = true, focus_inner_border = true, focus_border_size = t.s(2), content}
    self[1] = self.frame
    self.ges_events.TapRow = {GestureRange:new{ges = "tap", range = self.dimen}}
    self.ges_events.HoldRow = {GestureRange:new{ges = "hold", range = self.dimen}}
end

function Row:onTapRow()
    if self.callback then self.callback() end
    return true
end

function Row:onHoldRow()
    if self.hold_callback then self.hold_callback() end
    return true
end

function Row:onFocus()
    self.frame:onFocus(); UIManager:setDirty(self.show_parent, "ui", self.dimen); return true
end

function Row:onUnfocus()
    self.frame:onUnfocus(); UIManager:setDirty(self.show_parent, "ui", self.dimen); return true
end

Widgets.Row = Row
return Widgets
