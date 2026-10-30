local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen

local Theme = {}

function Theme.new(options)
    options = options or {}
    local gray = options.mode == "gray" or (options.mode ~= "color" and
        (Device:hasEinkScreen() or not Screen:isColorEnabled()))
    local function color(rgb, mono)
        return gray and Blitbuffer.Color8(mono) or Blitbuffer.colorFromString(rgb)
    end
    local text_scale = options.large_text and 1.25 or 1
    return {
        s = function(value) return Screen:scaleBySize(value) end,
        gray = gray,
        background = color("#F2F2F7", 255),
        surface = color("#FFFFFF", 238),
        selected = color("#D5E4F7", 208),
        chip = color("#DFE3EB", 238),
        ink = color("#182636", 0),
        muted = color("#556477", 85),
        accent = color("#315F8B", 0),
        outline = color("#D7DFEB", 153),
        radius = Screen:scaleBySize(gray and 4 or 12),
        nav_radius = Screen:scaleBySize(gray and 8 or 28),
        touch = math.max(Screen:scaleBySize(48), Screen:scaleByDPI(44)),
        title = 28 * text_scale,
        heading = 20 * text_scale,
        body = 18 * text_scale,
        small = 14 * text_scale,
        text_scale = text_scale,
        cover_colors = {
            color("#C8DCEB", 218), color("#D8D5EC", 224), color("#EED9BC", 230),
            color("#C7E0D4", 220), color("#E8CCD4", 226), color("#D2DFBE", 232),
        },
    }
end

-- Flutter's bookshelf uses logical pixels, rather than scaling text down with
-- the short screen edge. Preserve that density on phones and high-DPI tablets.
function Theme.shelf(options)
    local t = Theme.new(options)
    t.s = function(value) return Screen:scaleByDPI(value) end
    t.font = function(value) return value * Screen:scaleByDPI(100) / Screen:scaleBySize(100) end
    t.touch, t.radius, t.nav_radius = t.s(44), t.s(12), t.s(32)
    t.body, t.small = 14 * t.text_scale, 12 * t.text_scale
    return t
end

return Theme
