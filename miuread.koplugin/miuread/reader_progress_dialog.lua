local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local TransientGuard = require("miuread.transient_guard")
local Skin = require("miuread.reader_skin")
local PanelBase = require("miuread.reader_panel_base")
local Ui = require("miuread.ui_components")

local Screen = Device.screen
local live_dialog

local OffsetContainer = Ui.OffsetContainer

local TapBox = Ui.TapBox

local ProgressTap = TapBox:extend{}
function ProgressTap:onTapSelect(_, ges)
    local pos = ges and ges.pos
    if not pos then return true end
    local ratio = (pos.x - self.dimen.x) / math.max(1, self.dimen.w)
    ratio = math.max(0, math.min(1, ratio))
    if self.callback then self.callback(ratio * 100) end
    return true
end

local Dialog = PanelBase:extend{
    name = "miuread_reader_progress_dialog",
    percent = 0,
    on_goto_percent = nil,
    on_adjust = nil,
    on_jump = nil,
    on_prev_chapter = nil,
    on_next_chapter = nil,
    on_back = nil,
    on_home = nil,
}

function Dialog:_button(label, width, height, callback, primary)
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = callback ~= nil,
        callback = function() self:_close(callback) end,
    }
    tap[1] = Skin.frame(width, height, {
        bordersize = primary and Skin.line("thick") or Skin.line("thin"),
        radius = Skin.radius(6, 5, 10),
        background = Blitbuffer.COLOR_WHITE,
        color = callback and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_GRAY,
    }, Ui.textbox(tostring(label or ""), width - Skin.dp(10, 8, 15),
        height - Skin.dp(4, 2, 6), Skin.face("cfont", 11.4, 15.2, 9.8), {
            bold = primary == true, alignment = "center", halign = "center",
            fgcolor = callback and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }))
    return tap
end

function Dialog:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local portrait = sw < sh
    local outer_margin = Skin.dp(10, 8, 18)
    local top_inset = Skin.dp(3, 2, 5)
    local pad = Skin.dp(11, 9, 17)
    local gap = Skin.dp(8, 6, 11)
    local panel_w = sw - outer_margin * 2
    local content_w = panel_w - pad * 2
    local header_h = math.max(Skin.dp(40, 34, 53), math.floor(sh * .04))
    local value_h = math.max(Skin.dp(38, 32, 52), math.floor(sh * (portrait and .036 or .052)))
    local value_track_gap = Skin.dp(8, 6, 12)
    local track_h = math.max(Skin.dp(24, 20, 34), math.floor(sh * (portrait and .024 or .035)))
    local progress_h = value_h + value_track_gap + track_h
    local small_h = math.max(Skin.dp(42, 36, 55), math.floor(sh * (portrait and .04 or .058)))
    local wide_h = math.max(Skin.dp(45, 39, 58), math.floor(sh * (portrait and .043 or .062)))
    local handle_h = Skin.dp(18, 15, 25)
    local content_h = header_h + progress_h + gap + small_h + gap + wide_h + gap + wide_h + handle_h
    self.panel_h = math.min(sh - top_inset - math.max(28, math.floor(sh * .052)), pad * 2 + content_h)
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.frame_dimen = Geom:new{x = outer_margin, y = top_inset, w = panel_w, h = self.panel_h}
    self:_init_dismiss()

    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin,
        y_off = top_inset,
        Skin.paper(panel_w, self.panel_h, {accent = false, seed = 9}, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }

    local y = top_inset + pad
    local back_w = Skin.dp(44, 38, 58)
    local title_w = math.max(1, content_w - back_w * 2)
    local back_tap = TapBox:new{
        dimen = Geom:new{w = back_w, h = header_h},
        callback = function() self:_close(self.on_back) end,
    }
    back_tap[1] = Ui.icon("back", back_w, header_h, Skin.dp(21, 18, 28), {
        face = Skin.face("cfont", 21, 26, 18),
    })
    local home_tap = TapBox:new{
        dimen = Geom:new{w = back_w, h = header_h},
        enabled = type(self.on_home) == "function",
        callback = function() self:_close(self.on_home) end,
    }
    home_tap[1] = Ui.icon("home", back_w, header_h, Skin.dp(21, 18, 28), {
        face = Skin.face("cfont", 15.8, 20.8, 13.2),
        fgcolor = type(self.on_home) == "function" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
    local header = HorizontalGroup:new{
        align = "center",
        back_tap,
        Ui.textbox("当前进度", title_w, header_h, Skin.face("cfont", 16.2, 20.8, 13.6), {
            bold = true, alignment = "center", halign = "center",
        }),
        home_tap,
    }
    root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, header}
    y = y + header_h

    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + pad,
        y_off = y,
        Ui.textbox(tostring(math.floor((tonumber(self.percent) or 0) + .5)) .. "%",
            content_w, value_h, Skin.face("cfont", 22, 28, 18.5), {
                bold = true, alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
            }),
    }

    local bar_w = math.max(1, content_w - math.floor(content_w * .04))
    local bar_h = math.max(2, Skin.line("thick"))
    local pct = math.max(0, math.min(100, tonumber(self.percent) or 0))
    local filled = math.max(1, math.floor(bar_w * pct / 100))
    local marker = Skin.dp(13, 10, 18)
    local bar_x = outer_margin + pad + math.floor((content_w - bar_w) / 2)
    local track_y = y + value_h + value_track_gap
    local bar_y = track_y + math.floor((track_h - bar_h) / 2)
    root[#root + 1] = OffsetContainer:new{x_off = bar_x, y_off = bar_y, LineWidget:new{
        background = Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{w = bar_w, h = bar_h},
    }}
    root[#root + 1] = OffsetContainer:new{x_off = bar_x, y_off = bar_y, LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{w = math.min(bar_w, filled), h = bar_h},
    }}
    root[#root + 1] = OffsetContainer:new{
        x_off = bar_x + math.max(0, math.min(bar_w - marker, filled - math.floor(marker / 2))),
        y_off = track_y + math.floor((track_h - marker) / 2),
        Skin.frame(marker, marker, {
            bordersize = 0,
            radius = math.floor(marker / 2),
            background = Blitbuffer.COLOR_BLACK,
            color = Blitbuffer.COLOR_BLACK,
        }, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }
    local progress_tap = ProgressTap:new{
        dimen = Geom:new{w = bar_w, h = value_track_gap + track_h},
        callback = function(target)
            self:_close(function() if self.on_goto_percent then self.on_goto_percent(target) end end)
        end,
    }
    progress_tap[1] = Widget:new{dimen = Geom:new{w = bar_w, h = value_track_gap + track_h}}
    root[#root + 1] = OffsetContainer:new{x_off = bar_x, y_off = y + value_h, progress_tap}
    y = y + progress_h + gap

    local small_gap = Skin.dp(6, 4, 9)
    local small_w = math.max(1, math.floor((content_w - small_gap * 3) / 4))
    local deltas = {-5, -1, 1, 5}
    local labels = {"−5%", "−1%", "+1%", "+5%"}
    for index, delta in ipairs(deltas) do
        local value = delta
        root[#root + 1] = OffsetContainer:new{
            x_off = outer_margin + pad + (index - 1) * (small_w + small_gap),
            y_off = y,
            self:_button(labels[index], small_w, small_h, function()
                if self.on_adjust then self.on_adjust(value) end
            end, false),
        }
    end
    y = y + small_h + gap

    local wide_gap = Skin.dp(8, 6, 12)
    local wide_w = math.max(1, math.floor((content_w - wide_gap) / 2))
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + pad,
        y_off = y,
        self:_button("上一章", wide_w, wide_h, self.on_prev_chapter, false),
    }
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + pad + wide_w + wide_gap,
        y_off = y,
        self:_button("下一章", wide_w, wide_h, self.on_next_chapter, false),
    }
    y = y + wide_h + gap

    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + pad,
        y_off = y,
        self:_button("输入位置", content_w, wide_h, self.on_jump, true),
    }

    local handle_w = Skin.dp(34, 28, 48)
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + math.floor((panel_w - handle_w) / 2),
        y_off = top_inset + self.panel_h - math.floor(handle_h * .55),
        LineWidget:new{
            background = Blitbuffer.COLOR_DARK_GRAY,
            dimen = Geom:new{w = handle_w, h = math.max(1, Skin.line("thin"))},
        },
    }
    self[1] = root
end

function Dialog:onClose() return self:_close(self.on_back) end
function Dialog:onCloseWidget()
    self:finish_close_widget(function(widget)
        if live_dialog == widget then live_dialog = nil end
    end, "[MiuRead][ReaderProgressDialog] action failed")
end

local M = {}
function M.close()
    if live_dialog and not live_dialog.closed then live_dialog:_close(nil, true) end
    live_dialog = nil
end
function M.show(opts)
    TransientGuard.close_all()
    opts = opts or {}
    M.close()
    local ok, dialog = pcall(Dialog.new, Dialog, {
        percent = opts.percent,
        on_goto_percent = opts.on_goto_percent,
        on_adjust = opts.on_adjust,
        on_jump = opts.on_jump,
        on_prev_chapter = opts.on_prev_chapter,
        on_next_chapter = opts.on_next_chapter,
        on_back = opts.on_back,
        on_home = opts.on_home,
    })
    if not ok or not dialog then
        logger.warn("[MiuRead][ReaderProgressDialog] build failed", tostring(dialog))
        return nil, tostring(dialog)
    end
    live_dialog = dialog
    UIManager:show(dialog, "ui", dialog.frame_dimen)
    return dialog
end
return M
