local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local IconRegistry = require("miuread.icon_registry")
local UiScale = require("miuread.ui_scale")

local Ui = {}

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end
Ui.OffsetContainer = OffsetContainer

function Ui.face(name, nominal, maximum, minimum)
    return UiScale.face(name, nominal, maximum, minimum)
end

function Ui.frame(width, height, options, content)
    options = options or {}
    local border = tonumber(options.bordersize) or 0
    local padding = tonumber(options.padding) or 0
    local margin = tonumber(options.margin) or 0
    local inset = border + padding + margin
    return FrameContainer:new{
        bordersize = border,
        radius = options.radius or 0,
        padding = padding,
        margin = margin,
        background = options.background,
        color = options.color or Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{
                w = math.max(1, width - inset * 2),
                h = math.max(1, height - inset * 2),
            },
            content or Widget:new{dimen = Geom:new{w = 1, h = 1}},
        },
    }
end

local TapBox = InputContainer:extend{
    dimen = nil,
    callback = nil,
    hold_callback = nil,
    enabled = true,
    hold_on_release = false,
    tap_guard = false,
    _hold_handled = false,
    _pending_hold_anchor = nil,
    _miu_tap_block_until = 0,
}

function TapBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {
        TapSelect = {GestureRange:new{ges = "tap", range = self.dimen}},
    }
    if self.hold_callback then
        self.ges_events.HoldSelect = {GestureRange:new{ges = "hold", range = self.dimen}}
        self.ges_events.HoldReleaseSelect = {GestureRange:new{ges = "hold_release", range = self.dimen}}
    end
end

function TapBox:getSize()
    return Geom:new{w = self.dimen.w, h = self.dimen.h}
end

function TapBox:_anchor()
    return self.dimen and self.dimen:copy() or nil
end

function TapBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end

function TapBox:onTapSelect()
    if self.enabled == false then return true end
    if self._hold_handled then
        self._hold_handled = false
        return true
    end
    if os.clock() < (tonumber(self._miu_tap_block_until) or 0) then return true end
    if self.tap_guard == true then
        self._miu_tap_block_until = os.clock() + .20
    end
    if self.callback then self.callback(self:_anchor()) end
    return true
end

function TapBox:onHoldSelect()
    if self.enabled == false or not self.hold_callback then return false end
    self._hold_handled = true
    if self.hold_on_release then
        self._pending_hold_anchor = self:_anchor()
    else
        self.hold_callback(self:_anchor())
    end
    return true
end

function TapBox:onHoldReleaseSelect()
    if self._hold_handled then
        self._hold_handled = false
        self._miu_tap_block_until = os.clock() + .20
        if self.hold_on_release and self.hold_callback then
            self.hold_callback(self._pending_hold_anchor)
        end
        self._pending_hold_anchor = nil
        return true
    end
    return false
end

function TapBox:handleEvent(event)
    return InputContainer.handleEvent(self, event)
end

Ui.TapBox = TapBox

function Ui.tappable(width, height, child, callback, hold_callback, options)
    options = options or {}
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        callback = callback,
        hold_callback = hold_callback,
        enabled = options.enabled ~= false,
        hold_on_release = options.hold_on_release == true,
        tap_guard = options.tap_guard == true,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, child}
    return tap
end

local AlignContainer = WidgetContainer:extend{
    dimen = nil,
    halign = "center",
    valign = "center",
}

function AlignContainer:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
end

function AlignContainer:getSize()
    return Geom:new{w = self.dimen.w, h = self.dimen.h}
end

function AlignContainer:paintTo(bb, x, y)
    local child = self[1]
    if not child then return end
    local size = child:getSize()
    local cw, ch = tonumber(size.w) or 0, tonumber(size.h) or 0
    local dx = 0
    if self.halign == "right" then
        dx = self.dimen.w - cw
    elseif self.halign == "center" then
        dx = math.floor((self.dimen.w - cw) / 2)
    end
    local dy = 0
    if self.valign == "bottom" then
        dy = self.dimen.h - ch
    elseif self.valign == "center" then
        dy = math.floor((self.dimen.h - ch) / 2)
    end
    child:paintTo(bb, x + math.max(0, dx), y + math.max(0, dy))
end

function Ui.align(child, width, height, halign, valign)
    return AlignContainer:new{
        dimen = Geom:new{w = math.max(1, width), h = math.max(1, height)},
        halign = halign or "center",
        valign = valign or "center",
        child,
    }
end

function Ui.text(text, width, height, face, opts)
    opts = opts or {}
    local child = TextWidget:new{
        text = tostring(text or ""),
        face = face,
        bold = opts.bold == true,
        fgcolor = opts.fgcolor or Blitbuffer.COLOR_BLACK,
    }
    return Ui.align(child, width, height, opts.halign or opts.alignment or "center", opts.valign or "center")
end

function Ui.textbox(text, width, height, face, opts)
    opts = opts or {}
    local child = TextBoxWidget:new{
        text = tostring(text or ""),
        face = face,
        bold = opts.bold == true,
        width = math.max(1, width),
        height_adjust = true,
        height_overflow_show_ellipsis = opts.ellipsis ~= false,
        alignment = opts.text_alignment or opts.alignment or "left",
        fgcolor = opts.fgcolor or Blitbuffer.COLOR_BLACK,
    }
    return Ui.align(child, width, height, opts.halign or opts.alignment or "left", opts.valign or "center")
end

function Ui.icon(value, width, height, size, opts)
    opts = opts or {}
    local child = IconRegistry.widget(opts.icon_key or value, size, {
        path = opts.icon_path,
        face = opts.face,
        bold = opts.bold,
        fgcolor = opts.fgcolor,
        fallback_text = opts.fallback_text,
    })
    return Ui.align(child, width, height, opts.halign or "center", opts.valign or "center")
end

return Ui
