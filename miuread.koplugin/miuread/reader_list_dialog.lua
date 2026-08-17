local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
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

local TapBox = Ui.TapBox:extend{hold_on_release = true, tap_guard = true}

local function resolved(value, fallback)
    if type(value) == "function" then
        local ok, result = pcall(value)
        if ok then return result end
        logger.warn("[MiuRead][ReaderListDialog] provider failed", tostring(result))
        return fallback
    end
    if value == nil then return fallback end
    return value
end

local Dialog = PanelBase:extend{
    name = "miuread_reader_list_dialog",
    selected_key = nil,
    page = 1,
    expanded_index = nil,
}

function Dialog:_categories()
    -- Fluency: a categories PROVIDER (e.g. the reader records dialog, which
    -- queries the annotation mirror per kind) is evaluated once when the
    -- dialog opens and then frozen; rebuilds on expand/page/tab must not
    -- re-run SQLite. Mutating actions invalidate the cache before rebuilding.
    -- The single-items fallback (settings menus etc.) is intentionally NOT
    -- frozen: those providers re-snapshot checked/state per rebuild.
    if self._categories_cache ~= nil then return self._categories_cache end
    local categories = resolved(self.opts and self.opts.categories, nil)
    if type(categories) == "table" and #categories > 0 then
        self._categories_cache = categories
        return categories
    end
    return {{key = "all", label = "", items = resolved(self.opts and self.opts.items, {})}}
end

function Dialog:_invalidate_categories()
    self._categories_cache = nil
end

function Dialog:_selected_category()
    local categories = self:_categories()
    for _, category in ipairs(categories) do
        if tostring(category.key or "") == tostring(self.selected_key or "") then return category end
    end
    return categories[1]
end

function Dialog:_items(category)
    local items = resolved(category and (category.items or category.rows), {})
    return type(items) == "table" and items or {}
end

function Dialog:_page_size()
    local requested = tonumber(self.opts and self.opts.page_size)
    if requested and requested >= 2 then return math.floor(requested) end
    local _, sh = Screen:getWidth(), Screen:getHeight()
    return sh > 1100 and 7 or 6
end

function Dialog:_inline_actions(item)
    local actions = resolved(item and item.inline_actions, {})
    return type(actions) == "table" and actions or {}
end

function Dialog:_run_item(item, index)
    if not item or item.enabled == false then return true end
    local inline_actions = self:_inline_actions(item)
    if #inline_actions > 0 then
        self.expanded_index = self.expanded_index == index and nil or index
        self:_rebuild()
        return true
    end
    if item.keep_open == true then
        if item.callback then
            local ok, err = pcall(item.callback)
            if not ok then logger.warn("[MiuRead][ReaderListDialog] action failed", tostring(err)) end
        end
        -- The action may have mutated data the categories provider reads.
        self:_invalidate_categories()
        UIManager:scheduleIn(.04, function()
            if not self.closed then self:_rebuild() end
        end)
        return true
    end
    return self:_close(item.callback)
end

function Dialog:_row_widget(item, width, height, index)
    local enabled = item.enabled ~= false
    local value = tostring(item.value or item.post_text or "")
    local detail = tostring(item.detail or "")
    local inline_actions = self:_inline_actions(item)
    local arrow = item.arrow ~= false and ((#inline_actions > 0) or (item.callback ~= nil and item.keep_open ~= true))
    -- Shared row skeleton (same as home rows / control center). Per-surface
    -- geometry overrides keep this dialog pixel-identical to before.
    local row = UiRows.build({
        icon = item.icon or "",
        label = item.label or item.text or "",
        subtitle = detail,
        value = value,
        enabled = enabled,
        arrow = arrow,
        bold = item.bold == true or item.checked == true,
        value_bold = item.value_bold == true or item.checked == true,
        callback = item.callback,
    }, width, height, {
        pad = Skin.dp(7, 6, 10),
        icon_w = Skin.dp(31, 27, 41),
        value_w = math.max(Skin.dp(92, 76, 126), math.floor(width * .30)),
        chevron_w = Skin.dp(15, 13, 20),
        gap = Skin.dp(5, 4, 7),
        icon_gap = Skin.dp(5, 4, 7),
        label_basis = "height",
        checked = item.checked == true,
        icon_size = Skin.dp(19, 16, 25),
        icon_face = Skin.face("cfont", 14.5, 19.5, 12.2),
        chevron_size = Skin.dp(14, 12, 19),
        chevron_face = Skin.face("cfont", 12.8, 17.2, 10.8),
        label_face = Skin.face("cfont", detail ~= "" and 11.1 or 11.6, detail ~= "" and 14.9 or 15.6, detail ~= "" and 9.4 or 9.9),
        subtitle_face = Skin.face("smallinfofont", 9.0, 11.9, 7.7),
        value_face = Skin.face("cfont", 10.5, 13.9, 8.9),
        value_fg_disabled = Blitbuffer.COLOR_GRAY,
    })

    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height}, enabled = enabled,
        callback = function() self:_run_item(item, index) end,
        hold_callback = (#inline_actions == 0 and item.hold_callback) and function(anchor)
            return self:_close(function() item.hold_callback(anchor) end)
        end or nil,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, row}
    return tap
end

function Dialog:_inline_actions_widget(item, width, height)
    local actions = self:_inline_actions(item)
    local count = math.max(1, #actions)
    local gap = Skin.dp(5, 4, 7)
    local button_w = math.max(1, math.floor((width - gap * (count - 1)) / count))
    local group = HorizontalGroup:new{align = "center"}
    for index, action in ipairs(actions) do
        local actual_w = index == count and math.max(1, width - (button_w + gap) * (count - 1)) or button_w
        local label = tostring(action.label or action.text or "操作")
        local enabled = action.enabled ~= false
        local tap = TapBox:new{
            dimen = Geom:new{w = actual_w, h = height},
            enabled = enabled,
            callback = function()
                if action.close == true then
                    return self:_close(action.callback)
                end
                if type(action.callback) == "function" then
                    local ok, err = pcall(action.callback)
                    if not ok then
                        logger.warn("[MiuRead][ReaderListDialog] inline action failed", tostring(err))
                    end
                end
                -- The action may have mutated the underlying data.
                self:_invalidate_categories()
                UIManager:scheduleIn(.05, function()
                    if not self.closed then self:_rebuild() end
                end)
                return true
            end,
        }
        tap[1] = Skin.frame(actual_w, height, {
            bordersize = Skin.line("thin"), padding = Skin.dp(2, 1, 3), radius = Skin.dp(5, 4, 7),
            background = Blitbuffer.COLOR_WHITE,
            color = action.danger == true and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_GRAY,
        }, Ui.textbox(label, math.max(1, actual_w - Skin.dp(6, 4, 8)), height - Skin.dp(4, 2, 6),
            Skin.face("smallinfofont", count >= 4 and 8.6 or 9.3, count >= 4 and 11.4 or 12.3, count >= 4 and 7.2 or 7.9), {
                bold = action.danger == true or action.bold == true,
                alignment = "center", halign = "center",
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            }))
        group[#group + 1] = tap
        if index < count then group[#group + 1] = HorizontalSpan:new{width = gap} end
    end
    return group
end

function Dialog:_tab_widget(category, width, height, selected)
    local key = tostring(category.key or "")
    local layers = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    layers[#layers + 1] = Ui.textbox(tostring(category.label or key), width, height,
        Skin.face("cfont", 11.0, 14.8, 9.4), {
            bold = selected, alignment = "center", halign = "center",
            fgcolor = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        })
    if selected then
        local line_w = math.max(Skin.dp(26, 22, 38), math.floor(width * .36))
        layers[#layers + 1] = OffsetContainer:new{
            x_off = math.floor((width - line_w) / 2),
            y_off = height - Skin.line("thick"),
            LineWidget:new{background = Blitbuffer.COLOR_BLACK, dimen = Geom:new{w = line_w, h = Skin.line("thick")}},
        }
    end
    local tap = TapBox:new{dimen = Geom:new{w = width, h = height}, callback = function()
        if self.selected_key ~= key then
            self.selected_key = key
            self.page = 1
            self.expanded_index = nil
            self:_rebuild()
        end
    end}
    tap[1] = layers
    return tap
end

function Dialog:_pager_button(icon, width, height, callback, enabled)
    local tap = TapBox:new{dimen = Geom:new{w = width, h = height}, enabled = enabled ~= false, callback = callback}
    tap[1] = Ui.icon(icon, width, height, Skin.dp(19, 16, 25), {
        icon_key = icon,
        face = Skin.face("cfont", 17, 22, 14),
        fgcolor = enabled ~= false and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
    return tap
end

function Dialog:_build_content()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local portrait = sw < sh
    local outer = Skin.dp(8, 6, 14)
    local pad = Skin.dp(13, 10, 19)
    local panel_w = sw - outer * 2
    local content_w = panel_w - pad * 2
    local header_h = math.max(Skin.dp(42, 36, 56), math.floor(sh * .041))
    local subtitle = tostring(resolved(self.opts and self.opts.subtitle, "") or "")
    local subtitle_h = subtitle ~= "" and Skin.dp(27, 23, 36) or 0
    local categories = self:_categories()
    local selected = self:_selected_category()
    self.selected_key = tostring(selected and selected.key or "all")
    local tab_h = #categories > 1 and math.max(Skin.dp(37, 32, 49), math.floor(sh * .036)) or 0
    local pager_h_default = Skin.dp(34, 29, 45)
    local row_h = math.max(Skin.dp(64, 55, 86), math.floor(sh * (portrait and .060 or .084)))
    local action_h = Skin.dp(40, 35, 52)
    local action_gap = Skin.dp(5, 4, 7)
    local page_size = self:_page_size()
    local items = self:_items(selected)
    local pages = math.max(1, math.ceil(#items / page_size))
    self.page = math.max(1, math.min(pages, tonumber(self.page) or 1))
    local first = (self.page - 1) * page_size + 1
    local last = math.min(#items, first + page_size - 1)
    -- Keep both the list body and pager footprint stable across every page and
    -- category. Otherwise a short final page (or a tab without pagination) can
    -- leave lower rows from the previous state visible after a partial refresh.
    local visible_slots = 1
    local has_pager = false
    for _, candidate in ipairs(categories) do
        local candidate_items = self:_items(candidate)
        visible_slots = math.max(visible_slots, math.min(page_size, math.max(1, #candidate_items)))
        if #candidate_items > page_size then has_pager = true end
    end
    local pager_h = has_pager and pager_h_default or 0
    if self.expanded_index and (self.expanded_index < first or self.expanded_index > last) then
        self.expanded_index = nil
    end
    local expanded_h = self.expanded_index and (action_gap + action_h) or 0
    local body_h = visible_slots * row_h + expanded_h
    -- Keep the panel clear of the reader bottom toolbar / page-turn zone.
    local max_h = sh - Skin.dp(100, 88, 132)
    local panel_h = math.min(max_h, pad * 2 + header_h + subtitle_h + tab_h + body_h + pager_h + Skin.dp(8, 6, 12))

    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.panel_h = panel_h
    self.frame_dimen = Geom:new{x = outer, y = 0, w = panel_w, h = panel_h}

    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{
        x_off = outer, y_off = 0,
        Skin.frame(panel_w, panel_h, {bordersize = 0, padding = 0, radius = 0, background = Blitbuffer.COLOR_WHITE, color = Blitbuffer.COLOR_WHITE},
            Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }
    root[#root + 1] = OffsetContainer:new{
        x_off = outer, y_off = panel_h - Skin.line("thin"),
        LineWidget:new{background = Blitbuffer.COLOR_DARK_GRAY, dimen = Geom:new{w = panel_w, h = Skin.line("thin")}},
    }

    local y = pad
    local side_w = Skin.dp(44, 38, 58)
    local back = TapBox:new{dimen = Geom:new{w = side_w, h = header_h}, callback = function()
        self:_close(self.opts and self.opts.on_back or nil)
    end}
    back[1] = Ui.icon("back", side_w, header_h, Skin.dp(21, 18, 28), {face = Skin.face("cfont", 20, 26, 17)})
    local home_action = self.opts and self.opts.on_home or nil
    local home = TapBox:new{dimen = Geom:new{w = side_w, h = header_h}, enabled = type(home_action) == "function", callback = function()
        self:_close(home_action)
    end}
    home[1] = Ui.icon("home", side_w, header_h, Skin.dp(20, 17, 27), {
        face = Skin.face("cfont", 16, 21, 13.5),
        fgcolor = type(home_action) == "function" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
    root[#root + 1] = OffsetContainer:new{
        x_off = outer + pad, y_off = y,
        HorizontalGroup:new{
            align = "center",
            back,
            Ui.textbox(tostring(self.opts.title or "阅读列表"), math.max(1, content_w - side_w * 2), header_h,
                Skin.face("cfont", 16.0, 20.6, 13.4), {bold = true, alignment = "center", halign = "center"}),
            home,
        },
    }
    y = y + header_h

    if subtitle_h > 0 then
        root[#root + 1] = OffsetContainer:new{x_off = outer + pad, y_off = y,
            Ui.textbox(subtitle, content_w, subtitle_h, Skin.face("smallinfofont", 8.7, 11.5, 7.4), {
                alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            })}
        y = y + subtitle_h
    end

    if tab_h > 0 then
        local tab_w = math.max(1, math.floor(content_w / #categories))
        for index, category in ipairs(categories) do
            local x = outer + pad + (index - 1) * tab_w
            local actual_w = index == #categories and (outer + pad + content_w - x) or tab_w
            root[#root + 1] = OffsetContainer:new{x_off = x, y_off = y,
                self:_tab_widget(category, actual_w, tab_h, tostring(category.key or "") == self.selected_key)}
        end
        y = y + tab_h
    end

    if #items == 0 then
        root[#root + 1] = OffsetContainer:new{x_off = outer + pad, y_off = y,
            Ui.textbox(tostring(selected and selected.empty_text or self.opts.empty_text or "当前没有内容"), content_w, row_h,
                Skin.face("cfont", 11.0, 14.8, 9.4), {alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_DARK_GRAY})}
        y = y + row_h
    else
        for index = first, last do
            local item = items[index]
            root[#root + 1] = OffsetContainer:new{x_off = outer + pad, y_off = y, self:_row_widget(item, content_w, row_h, index)}
            y = y + row_h
            if self.expanded_index == index then
                y = y + action_gap
                root[#root + 1] = OffsetContainer:new{x_off = outer + pad, y_off = y,
                    self:_inline_actions_widget(item, content_w, action_h)}
                y = y + action_h
            end
            if index < last then
                root[#root + 1] = OffsetContainer:new{x_off = outer + pad + Skin.dp(4, 3, 6), y_off = y,
                    Skin.divider(math.max(1, content_w - Skin.dp(8, 6, 12)), Blitbuffer.COLOR_GRAY)}
            end
        end
    end

    if pages > 1 then
        local prev_w = Skin.dp(54, 46, 72)
        local next_w = prev_w
        local page_w = math.max(1, content_w - prev_w - next_w)
        root[#root + 1] = OffsetContainer:new{x_off = outer + pad, y_off = panel_h - pad - pager_h,
            HorizontalGroup:new{
                align = "center",
                self:_pager_button("back", prev_w, pager_h, function()
                    if self.page > 1 then self.page = self.page - 1; self.expanded_index = nil; self:_rebuild() end
                end, self.page > 1),
                Ui.textbox(tostring(self.page).." / "..tostring(pages), page_w, pager_h, Skin.face("cfont", 10.0, 13.3, 8.5), {
                    alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                }),
                self:_pager_button("chevron-right", next_w, pager_h, function()
                    if self.page < pages then self.page = self.page + 1; self.expanded_index = nil; self:_rebuild() end
                end, self.page < pages),
            }}
    end

    self[1] = root
end

function Dialog:_rebuild()
    local old = self.frame_dimen and self.frame_dimen:copy() or nil
    self:_build_content()
    local dirty = self.frame_dimen
    if old then
        dirty = Geom:new{
            x = math.min(old.x, self.frame_dimen.x), y = math.min(old.y, self.frame_dimen.y),
            w = math.max(old.x + old.w, self.frame_dimen.x + self.frame_dimen.w) - math.min(old.x, self.frame_dimen.x),
            h = math.max(old.y + old.h, self.frame_dimen.y + self.frame_dimen.h) - math.min(old.y, self.frame_dimen.y),
        }
    end
    UIManager:setDirty(self, function() return "ui", Skin.expand_region(dirty) end)
end

function Dialog:init()
    self.opts = self.opts or {}
    self.selected_key = tostring(self.opts.initial_category or "")
    self.page = tonumber(self.opts.initial_page) or 1
    self.expanded_index = nil
    self:_build_content()
    self:_init_dismiss()
end

function Dialog:onClose() return self:_close(self.opts and self.opts.on_back or nil) end
function Dialog:onCloseWidget()
    self:finish_close_widget(function(widget)
        if live_dialog == widget then live_dialog = nil end
    end, "[MiuRead][ReaderListDialog] action failed")
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
        logger.warn("[MiuRead][ReaderListDialog] build failed", tostring(dialog))
        return nil, tostring(dialog)
    end
    live_dialog = dialog
    UIManager:show(dialog, "ui", dialog.frame_dimen)
    return dialog
end
return M
