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
        background = color("#FAFBFE", 255),
        surface = color("#EEF2FA", 238),
        selected = color("#D7E6FA", 208),
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
    }
end

return Theme
