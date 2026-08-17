local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
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
local UiRows = require("miuread.ui_rows")

local Screen = Device.screen
local live_dialog

local OffsetContainer = Ui.OffsetContainer

local TapBox = Ui.TapBox

local Dialog = PanelBase:extend{
    name = "miuread_reader_settings_dialog",
}

local function resolved(value, fallback)
    if type(value) == "function" then
        local ok, result = pcall(value)
        if ok then return result end
        logger.warn("[MiuRead][ReaderSettingsDialog] provider failed", tostring(result))
        return fallback
    end
    if value == nil then return fallback end
    return value
end

function Dialog:_rows()
    local rows = resolved(self.opts and self.opts.rows, {})
    return type(rows) == "table" and rows or {}
end

function Dialog:_sections()
    local sections = resolved(self.opts and self.opts.sections, nil)
    if type(sections) == "table" and #sections > 0 then
        local normalized = {}
        for _, section in ipairs(sections) do
            local rows = resolved(section.rows or section.items, {})
            normalized[#normalized + 1] = {
                title = tostring(section.title or ""),
                rows = type(rows) == "table" and rows or {},
            }
        end
        return normalized
    end
    return {{title = "", rows = self:_rows()}}
end

function Dialog:_subtitle()
    return tostring(resolved(self.opts and self.opts.subtitle, "") or "")
end

function Dialog:_hero()
    local hero = resolved(self.opts and self.opts.hero, nil)
    return type(hero) == "table" and hero or nil
end

function Dialog:_run_row(row)
    if not row or row.enabled == false then return true end
    if row.keep_open == true then
        if row.callback then
            local ok, err = pcall(row.callback)
            if not ok then logger.warn("[MiuRead][ReaderSettingsDialog] action failed", tostring(err)) end
        end
        UIManager:scheduleIn(.04, function()
            if not self.closed then self:_rebuild() end
        end)
        return true
    end
    return self:_close(row.callback)
end

function Dialog:_row_widget(row, width, height)
    local enabled = row.enabled ~= false
    local value = tostring(row.value or row.detail or "")
    if row.checked == true then value = value ~= "" and (value .. "  ✓") or "✓" end
    -- Shared row skeleton (same as home rows / control center). Reader
    -- settings stay visually flat: chevron only on explicit arrow=true.
    local row_content = UiRows.build({
        icon = row.icon or "",
        label = row.label or row.text or "",
        value = value,
        enabled = enabled,
        arrow = row.arrow == true,
        bold = row.bold == true or row.checked == true,
        value_bold = row.value_bold == true,
        callback = row.callback,
    }, width, height, {
        pad = Skin.dp(8, 6, 11),
        icon_w = Skin.dp(28, 23, 38),
        value_w = math.max(Skin.dp(88, 72, 118), math.floor(width * .32)),
        chevron_w = Skin.dp(17, 14, 23),
        gap = Skin.dp(4, 3, 6),
        icon_gap = Skin.dp(4, 3, 6),
        checked = row.checked == true,
        icon_size = Skin.dp(20, 17, 27),
        icon_face = Skin.face("cfont", 12.7, 17.2, 10.8),
    })

    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = function() self:_run_row(row) end,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, row_content}
    return tap
end

function Dialog:_section_widget(section, width, row_h)
    local rows = type(section.rows) == "table" and section.rows or {}
    local height = math.max(row_h, #rows * row_h)
    local layers = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    local inset = Skin.dp(2, 2, 4)
    for index = 1, #rows - 1 do
        layers[#layers + 1] = OffsetContainer:new{
            x_off = inset,
            y_off = index * row_h,
            Skin.divider(math.max(1, width - inset * 2), Blitbuffer.COLOR_LIGHT_GRAY),
        }
    end
    for index, row in ipairs(rows) do
        layers[#layers + 1] = OffsetContainer:new{
            x_off = 0,
            y_off = (index - 1) * row_h,
            self:_row_widget(row, width, row_h),
        }
    end
    if #rows == 0 then
        layers[#layers + 1] = CenterContainer:new{
            dimen = Geom:new{w = width, h = height},
            Ui.textbox("当前没有可用设置", width - Skin.dp(18, 14, 26), height,
                Skin.face("smallinfofont", 9.4, 12.4, 8), {
                    alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
                }),
        }
    end
    return layers, height
end

function Dialog:_hero_widget(hero, width, height)
    local button_h = math.max(Skin.dp(46, 40, 61), math.min(height, Skin.dp(58, 48, 72)))
    local button_w = button_h
    local value_w = math.max(Skin.dp(86, 72, 120), width - button_w * 2 - math.floor(width * .18))
    local gap = math.max(Skin.dp(8, 6, 12), math.floor((width - button_w * 2 - value_w) / 2))

    local function step_button(label, callback)
        local tap = TapBox:new{
            dimen = Geom:new{w = button_w, h = button_h},
            enabled = callback ~= nil,
            callback = function()
                if callback then
                    local ok, err = pcall(callback)
                    if not ok then logger.warn("[MiuRead][ReaderSettingsDialog] hero action failed", tostring(err)) end
                    UIManager:scheduleIn(.04, function()
                        if not self.closed then self:_rebuild() end
                    end)
                end
            end,
        }
        tap[1] = Skin.frame(button_w, button_h, {
            bordersize = Skin.line("thin"),
            radius = math.floor(button_h / 2),
            background = Blitbuffer.COLOR_WHITE,
            color = Blitbuffer.COLOR_DARK_GRAY,
        }, Ui.icon(label == "+" and "plus" or "minus",
            button_w - Skin.dp(8, 6, 12), button_h - Skin.dp(4, 2, 6), Skin.dp(22, 19, 30), {
                face = Skin.face("cfont", 20, 25, 17),
            }))
        return tap
    end

    return CenterContainer:new{
        dimen = Geom:new{w = width, h = height},
        HorizontalGroup:new{
            align = "center",
            step_button("−", hero.on_decrease),
            HorizontalSpan:new{width = gap},
            Ui.textbox(tostring(hero.value or ""), value_w, button_h, Skin.face("cfont", 27, 34, 22), {
                bold = true, alignment = "center", halign = "center",
            }),
            HorizontalSpan:new{width = gap},
            step_button("+", hero.on_increase),
        },
    }
end

function Dialog:_build_content()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local portrait = sw < sh
    local sections = self:_sections()
    local hero = self:_hero()
    local outer_margin = Skin.dp(10, 8, 18)
    local top_inset = Skin.dp(3, 2, 5)
    local pad = Skin.dp(11, 9, 17)
    local gap = Skin.dp(7, 5, 10)
    local panel_w = sw - outer_margin * 2
    local content_w = panel_w - pad * 2
    local header_h = math.max(Skin.dp(39, 34, 52), math.floor(sh * .039))
    local subtitle = self:_subtitle()
    local subtitle_h = subtitle ~= "" and Skin.dp(25, 21, 33) or 0
    local hero_h = hero and math.max(Skin.dp(68, 58, 92), math.floor(sh * (portrait and .068 or .10))) or 0
    local section_title_h = Skin.dp(24, 20, 31)
    local handle_h = Skin.dp(18, 15, 25)
    local row_count = 0
    local titled_count = 0
    for _, section in ipairs(sections) do
        row_count = row_count + #(section.rows or {})
        if tostring(section.title or "") ~= "" then titled_count = titled_count + 1 end
    end
    row_count = math.max(1, row_count)
    local natural_row_h = math.max(Skin.dp(47, 40, 61), math.floor(sh * (portrait and .044 or .062)))
    local max_h = sh - top_inset - math.max(28, math.floor(sh * .052))
    local fixed_h = pad * 2 + header_h + subtitle_h + (hero_h > 0 and gap + hero_h or 0)
        + gap + titled_count * section_title_h + math.max(0, #sections - 1) * gap + handle_h
    local available_rows = math.max(row_count * Skin.dp(38, 34, 48), max_h - fixed_h)
    local row_h = math.min(natural_row_h, math.max(Skin.dp(38, 34, 48), math.floor(available_rows / row_count)))
    local body_h = row_count * row_h + titled_count * section_title_h + math.max(0, #sections - 1) * gap
    local content_h = header_h + subtitle_h + (hero_h > 0 and gap + hero_h or 0) + gap + body_h + handle_h
    self.panel_h = math.min(max_h, pad * 2 + content_h)
    self._stable_panel_h = math.max(tonumber(self._stable_panel_h) or 0, self.panel_h)
    self.panel_h = self._stable_panel_h
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.frame_dimen = Geom:new{x = outer_margin, y = top_inset, w = panel_w, h = self.panel_h}

    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin,
        y_off = top_inset,
        Skin.paper(panel_w, self.panel_h, {accent = false, seed = 7}, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }

    local y = top_inset + pad
    local back_w = Skin.dp(44, 38, 58)
    local title_w = math.max(1, content_w - back_w * 2)
    local back_action = self.opts and self.opts.on_back or nil
    local back_tap = TapBox:new{
        dimen = Geom:new{w = back_w, h = header_h},
        callback = function() self:_close(back_action) end,
    }
    back_tap[1] = Ui.icon("back", back_w, header_h, Skin.dp(21, 18, 28), {
        face = Skin.face("cfont", 21, 26, 18),
    })
    local home_action = self.opts and self.opts.on_home or nil
    local home_tap = TapBox:new{
        dimen = Geom:new{w = back_w, h = header_h},
        enabled = type(home_action) == "function",
        callback = function() self:_close(home_action) end,
    }
    home_tap[1] = Ui.icon("home", back_w, header_h, Skin.dp(21, 18, 28), {
        face = Skin.face("cfont", 15.8, 20.8, 13.2),
        fgcolor = type(home_action) == "function" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
    local header = HorizontalGroup:new{
        align = "center",
        back_tap,
        Ui.textbox(tostring(self.opts.title or "阅读界面设置"), title_w, header_h,
            Skin.face("cfont", 16.2, 20.8, 13.6), {
                bold = true, alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
            }),
        home_tap,
    }
    root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, header}
    y = y + header_h

    if subtitle_h > 0 then
        root[#root + 1] = OffsetContainer:new{
            x_off = outer_margin + pad,
            y_off = y,
            Ui.textbox(subtitle, content_w, subtitle_h, Skin.face("smallinfofont", 8.8, 11.7, 7.5), {
                alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
            }),
        }
        y = y + subtitle_h
    end

    if hero_h > 0 then
        y = y + gap
        root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, self:_hero_widget(hero, content_w, hero_h)}
        y = y + hero_h
    end

    y = y + gap
    for section_index, section in ipairs(sections) do
        if tostring(section.title or "") ~= "" then
            root[#root + 1] = OffsetContainer:new{
                x_off = outer_margin + pad,
                y_off = y,
                Ui.textbox(tostring(section.title), content_w, section_title_h,
                    Skin.face("smallinfofont", 9.4, 12.4, 8.1), {
                        bold = true, alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK,
                    }),
            }
            y = y + section_title_h
        end
        local section_widget, section_h = self:_section_widget(section, content_w, row_h)
        root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, section_widget}
        y = y + section_h
        if section_index < #sections then y = y + gap end
    end

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

function Dialog:_rebuild()
    local old = self.frame_dimen and self.frame_dimen:copy() or nil
    self:_build_content()
    local dirty = self.frame_dimen
    if old then
        dirty = Geom:new{
            x = math.min(old.x, self.frame_dimen.x),
            y = math.min(old.y, self.frame_dimen.y),
            w = math.max(old.x + old.w, self.frame_dimen.x + self.frame_dimen.w) - math.min(old.x, self.frame_dimen.x),
            h = math.max(old.y + old.h, self.frame_dimen.y + self.frame_dimen.h) - math.min(old.y, self.frame_dimen.y),
        }
    end
    UIManager:setDirty(self, function() return "ui", Skin.expand_region(dirty) end)
end

function Dialog:init()
    self.opts = self.opts or {}
    self:_build_content()
    self:_init_dismiss()
end

function Dialog:onClose()
    return self:_close(self.opts and self.opts.on_back or nil)
end
function Dialog:onCloseWidget()
    self:finish_close_widget(function(widget)
        if live_dialog == widget then live_dialog = nil end
    end, "[MiuRead][ReaderSettingsDialog] action failed")
end

local M = {}
function M.close()
    if live_dialog and not live_dialog.closed then live_dialog:_close(nil, true) end
    live_dialog = nil
end
function M.show(opts)
    TransientGuard.close_all()
    M.close()
    local ok, dialog = pcall(Dialog.new, Dialog, {opts = opts or {}})
    if not ok or not dialog then
        logger.warn("[MiuRead][ReaderSettingsDialog] build failed", tostring(dialog))
        return nil, tostring(dialog)
    end
    live_dialog = dialog
    UIManager:show(dialog, "ui", dialog.frame_dimen)
    return dialog
end
return M
