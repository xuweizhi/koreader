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

function Widgets.face(theme, size)
    return Font:getFace("cfont", theme.font and theme.font(size) or size)
end

function Widgets.text(text, theme, size, width, bold, muted)
    return TextWidget:new{
        text = text, face = Widgets.face(theme, size or theme.body),
        fgcolor = muted and theme.muted or theme.ink,
        max_width = width, bold = bold or false, padding = 0,
    }
end

function Widgets.button(text, width, theme, callback, options)
    options = options or {}
    return Button:new{
        text = text, width = width, height = theme.touch,
        text_font_size = theme.font and theme.font(theme.body) or theme.body, text_font_bold = options.selected or false,
        padding = 0, padding_h = theme.s(8), bordersize = 0,
        background = options.selected and theme.selected or theme.surface,
        radius = theme.radius, enabled = options.enabled ~= false,
        callback = callback, show_parent = options.parent,
    }
end

function Widgets.iconButton(icon, label, theme, callback, parent)
    local button = Button:new{
        icon = icon, alpha = true, width = theme.touch, height = theme.touch,
        icon_width = theme.s(24), icon_height = theme.s(24),
        padding = 0, bordersize = 0, background = theme.background,
        callback = callback, show_parent = parent,
        hold_callback = function()
            UIManager:show(parent.scope:own(require("ui/widget/infomessage"):new{text=label, timeout=2}))
        end,
    }
    button.label = label
    return button
end

function Widgets.chip(text, width, theme, callback, selected, parent)
    return Button:new{
        text=text, width=width, height=theme.touch,
        text_font_size=theme.font and theme.font(14 * theme.text_scale) or 14 * theme.text_scale,
        text_font_bold=selected == true, padding=0, padding_h=theme.s(5),
        bordersize=selected and math.max(1, theme.s(1)) or 0,
        radius=theme.s(14), background=selected and theme.selected or theme.chip,
        callback=callback, show_parent=parent,
    }
end

local Search = InputContainer:extend{}
function Search:init()
    local t, gap = self.theme, self.theme.s(10)
    self.dimen = Geom:new{w=self.width, h=t.touch}
    local icon = IconWidget:new{icon="appbar.search", alpha=true, width=t.s(22), height=t.s(22)}
    self.label_widget = Widgets.text(self.text, t, 14 * t.text_scale, self.width - t.s(22) - 3 * gap, false, true)
    self.frame = FrameContainer:new{
        padding=0, bordersize=0, radius=t.s(14), background=t.surface,
        focusable=true, focus_inner_border=true, focus_border_size=math.max(1, t.s(2)),
        require("ui/widget/container/leftcontainer"):new{dimen=self.dimen:copy(), HorizontalGroup:new{
            HorizontalSpan:new{width=gap}, icon, HorizontalSpan:new{width=gap}, self.label_widget,
        }},
    }
    self[1] = self.frame
    self.ges_events.TapSearch = {GestureRange:new{ges="tap", range=self.dimen}}
end
function Search:onTapSearch() self.callback(); return true end
function Search:onFocus() self.frame:onFocus(); UIManager:setDirty(self.show_parent, "ui"); return true end
function Search:onUnfocus() self.frame:onUnfocus(); UIManager:setDirty(self.show_parent, "ui"); return true end
function Widgets.search(text, width, theme, callback, parent)
    return Search:new{text=text, width=width, theme=theme, callback=callback, show_parent=parent}
end

-- Keep the label and icon in one focusable/tappable target. Native Button is
-- text-or-icon, so navigation composes the same containers without global UI changes.
local Navigation = InputContainer:extend{}

function Navigation:init()
    local t = self.theme
    self.dimen = Geom:new{w = self.width, h = math.max(t.touch, t.s(52 * t.text_scale))}
    self.icon_widget = IconWidget:new{icon = self.icon, alpha = true, width = t.s(24), height = t.s(24)}
    self.label_widget = Widgets.text(self.text, t, 12 * t.text_scale, self.width - t.s(4), self.selected)
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

-- Clip the bitmap corners inside its own box; FrameContainer rounds only the
-- background, not its child image. No full-screen offscreen buffer is needed.
local CoverFrame = FrameContainer:extend{}
function CoverFrame:paintTo(bb, x, y)
    FrameContainer.paintTo(self, bb, x, y)
    local r = math.max(1, math.floor(self.radius or 0))
    local w, h = self:getSize().w, self:getSize().h
    for row = 0, r - 1 do
        local cut = math.floor(r - math.sqrt(r * r - (r - row - .5)^2) + .5)
        if cut > 0 then
            bb:paintRect(x, y + row, cut, 1, self.outside)
            bb:paintRect(x + w - cut, y + row, cut, 1, self.outside)
            bb:paintRect(x, y + h - row - 1, cut, 1, self.outside)
            bb:paintRect(x + w - cut, y + h - row - 1, cut, 1, self.outside)
        end
    end
end

function Card:init()
    local t, s = self.theme, self.theme.s
    self.dimen = Geom:new{w=self.width, h=self.height}
    local meta_height = s(60 * t.text_scale)
    local cover_height = math.max(s(40), self.list_mode and self.height or self.height - meta_height)
    local cover_width = self.list_mode and math.floor(cover_height * .65) or self.width
    local text_width = self.list_mode and self.width - cover_width - s(12) or self.width
    local title_text = self.info and self.info.title or self.item.title or self.item.text:gsub("%.[^%.]+$", "")
    local author = self.info and self.info.authors or self.item.authors or self.translate("Unknown author")
    local cover_content, cover_background
    if self.info and self.info.cover then
        local buffer = self.info.cover
        cover_content = ImageWidget:new{
            image=buffer, image_disposable=false, width=cover_width, height=cover_height,
            scale_factor=math.max(cover_width / buffer.w, cover_height / buffer.h),
        }
        cover_content:_render()
        cover_background = t.surface
    else
        local hash = 0
        for index = 1, #title_text do hash = (hash * 31 + title_text:byte(index)) % 65521 end
        cover_background = t.cover_colors[hash % #t.cover_colors + 1]
        local pad = s(10)
        local contents = require("ui/widget/overlapgroup"):new{
            dimen=Geom:new{w=cover_width, h=cover_height}, allow_mirroring=false,
        }
        local title = TextBoxWidget:new{
            text=title_text, face=Widgets.face(t, 14 * t.text_scale), bold=true,
            fgcolor=t.ink, bgcolor=cover_background, width=cover_width - 2 * pad,
            height=math.min(s(60 * t.text_scale), cover_height - 2 * pad), height_overflow_show_ellipsis=true,
        }
        title.overlap_offset = {pad, pad}
        contents[1] = title
        if cover_height > s(130) then
            local icon = IconWidget:new{icon="book.opened", alpha=true,
                width=s(44), height=s(44)}
            icon.overlap_offset = {cover_width - s(54), cover_height - s(72)}
            contents[#contents + 1] = icon
            local name = Widgets.text(author, t, 10 * t.text_scale, cover_width - 2 * pad, false, true)
            name.overlap_offset = {pad, cover_height - s(24 * t.text_scale)}
            contents[#contents + 1] = name
        end
        cover_content = contents
    end
    self.cover = CoverFrame:new{
        bordersize=t.gray and 1 or 0, color=t.outline, outside=t.background,
        background=cover_background, radius=s(8), padding=0,
        CenterContainer:new{dimen=Geom:new{w=cover_width, h=cover_height}, cover_content},
    }
    self.title_widget = TextBoxWidget:new{
        text=title_text, face=Widgets.face(t, 13 * t.text_scale), bold=true,
        fgcolor=t.ink, bgcolor=t.background, width=text_width,
        height=math.min(s(36 * t.text_scale), self.list_mode and self.height - s(20 * t.text_scale) or self.height),
        height_overflow_show_ellipsis=true,
    }
    local progress = self.progress or {}
    local percent = type(progress.percent) == "number" and math.max(0, math.min(1, progress.percent)) or 0
    local progress_width = s(34 * t.text_scale)
    local description = VerticalGroup:new{align="left", self.title_widget,
        HorizontalGroup:new{
            require("ui/widget/container/leftcontainer"):new{
                dimen=Geom:new{w=math.max(1, text_width - progress_width - s(4)), h=s(16 * t.text_scale)},
                Widgets.text(author, t, 10 * t.text_scale, math.max(1, text_width - progress_width - s(4)), false, true),
            },
            HorizontalSpan:new{width=s(4)},
            Widgets.text(string.format("%d%%", math.floor(percent * 100 + .5)), t, 10 * t.text_scale, progress_width, false, true),
        },
    }
    local content = self.list_mode and HorizontalGroup:new{
        self.cover, HorizontalSpan:new{width=s(12)}, description,
    } or VerticalGroup:new{align="left", self.cover, VerticalSpan:new{width=s(5)}, description}
    self.frame = FrameContainer:new{
        width=self.width, height=self.height, padding=0, bordersize=0,
        background=t.background, radius=s(8), focusable=true,
        focus_inner_border=true, focus_border_size=math.max(1, s(2)), content,
    }
    self[1] = self.frame
    self.ges_events.TapCard = {GestureRange:new{ges="tap", range=self.dimen}}
    self.ges_events.HoldCard = {GestureRange:new{ges="hold", range=self.dimen}}
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
