-- Shared list-row layout for the EXTERNAL UI (我的页/书城 entries) and the
-- READER UI (control center rows). One skeleton: icon + label (+subtitle)
-- + value + chevron, so the two surfaces never drift apart visually.
local Blitbuffer = require("ffi/blitbuffer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local Skin = require("miuread.reader_skin")
local Ui = require("miuread.ui_components")

local M = {}

-- Pure row-config normalization. Every row source (home cards, control
-- center, future list dialogs) funnels through this so enabled/arrow/
-- value/subtitle defaults can never diverge.
function M.normalize(entry)
    entry = type(entry) == "table" and entry or {}
    return {
        icon = tostring(entry.icon or ""),
        label = tostring(entry.label or entry.text or ""),
        subtitle = tostring(entry.subtitle or entry.detail or ""),
        value = tostring(entry.value or ""),
        enabled = entry.enabled ~= false,
        arrow = entry.arrow ~= false and (entry.callback ~= nil or entry.arrow == true),
        bold = entry.bold == true,
        value_bold = entry.value_bold == true,
        checked = entry.checked == true,
    }
end

-- Pure row geometry: every consuming surface (home rows, control center,
-- reader list/settings dialogs) computes the same slot widths from one place.
-- Callers may override per-surface geometry (pad/icon/value widths).
function M.geometry(entry, width, height, opts)
    local cfg = M.normalize(entry)
    opts = type(opts) == "table" and opts or {}
    local pad = tonumber(opts.pad) or Skin.dp(10, 8, 14)
    local icon_w = cfg.icon ~= "" and (tonumber(opts.icon_w) or Skin.dp(34, 28, 46)) or 0
    local chevron_w = cfg.arrow and (tonumber(opts.chevron_w) or Skin.dp(18, 15, 24)) or 0
    local value_w = cfg.value ~= "" and (tonumber(opts.value_w) or math.max(Skin.dp(94, 78, 128), math.floor(width * .34))) or 0
    local gap = tonumber(opts.gap) or Skin.dp(5, 4, 7)
    local inner_w = math.max(1, width - pad * 2 - icon_w - value_w - chevron_w
        - gap * ((value_w > 0 and 1 or 0) + (chevron_w > 0 and 1 or 0)))
    local inner_h = math.max(1, height - pad * 2)
    -- Two-line rows (label + subtitle) may split against the inner height
    -- (framed home rows) or the full height (unframed list dialogs).
    local basis_h = opts.label_basis == "height" and height or inner_h
    local label_h = cfg.subtitle ~= "" and math.floor(basis_h * .52) or inner_h
    local subtitle_h = math.max(1, basis_h - label_h)
    local icon_gap = cfg.icon ~= "" and (tonumber(opts.icon_gap) or 0) or 0
    return {
        pad = pad, icon_w = icon_w, chevron_w = chevron_w, value_w = value_w,
        gap = gap, icon_gap = icon_gap, inner_w = inner_w, inner_h = inner_h,
        label_h = label_h, subtitle_h = subtitle_h,
    }
end

-- Widget builder: icon + label(+subtitle) + value + chevron on one skeleton.
-- Returns a HorizontalGroup the caller wraps in its own frame/tap layer.
function M.build(entry, width, height, opts)
    local cfg = M.normalize(entry)
    opts = type(opts) == "table" and opts or {}
    local geo = M.geometry(entry, width, height, opts)
    local pad, icon_w, chevron_w, value_w = geo.pad, geo.icon_w, geo.chevron_w, geo.value_w
    local gap, inner_w, inner_h = geo.gap, geo.inner_w, geo.inner_h
    local label_h, subtitle_h = geo.label_h, geo.subtitle_h
    local label_face = opts.label_face or Skin.face("cfont", 10.9, 14.8, 9.4)
    local value_face = opts.value_face or Skin.face("cfont", 10.0, 13.3, 8.5)

    local fg = cfg.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY
    local row = HorizontalGroup:new{align = "center"}
    if icon_w > 0 then
        row[#row + 1] = Ui.icon(cfg.icon, icon_w, inner_h,
            opts.icon_size or Skin.dp(20, 17, 27), {
                icon_key = cfg.icon,
                face = opts.icon_face or Skin.face("cfont", 15.8, 21.2, 13.2),
                fgcolor = fg,
            })
        if geo.icon_gap > 0 then
            row[#row + 1] = HorizontalSpan:new{width = geo.icon_gap}
        end
    end
    local column = VerticalGroup:new{align = "left"}
    column[#column + 1] = Ui.textbox(cfg.label, inner_w, label_h,
        label_face, {
            bold = cfg.bold or opts.checked == true, alignment = "left",
            fgcolor = fg, height_overflow_show_ellipsis = true,
        })
    if cfg.subtitle ~= "" then
        column[#column + 1] = Ui.textbox(cfg.subtitle, inner_w, subtitle_h,
            opts.subtitle_face or Skin.face("smallinfofont", 9.2, 13), {
                fgcolor = Blitbuffer.COLOR_DARK_GRAY, alignment = "left",
                height_overflow_show_ellipsis = true,
            })
    end
    row[#row + 1] = column
    if value_w > 0 then
        row[#row + 1] = HorizontalSpan:new{width = gap}
        row[#row + 1] = Ui.textbox(cfg.value, value_w, inner_h,
            value_face, {
                bold = cfg.value_bold or opts.checked == true, alignment = "right", halign = "right",
                fgcolor = cfg.enabled and Blitbuffer.COLOR_BLACK or (opts.value_fg_disabled or Blitbuffer.COLOR_DARK_GRAY),
            })
    end
    if chevron_w > 0 then
        row[#row + 1] = HorizontalSpan:new{width = gap}
        row[#row + 1] = Ui.icon("chevron-right", chevron_w, inner_h,
            opts.chevron_size or Skin.dp(15, 13, 20), {
            face = opts.chevron_face or Skin.face("cfont", 13.2, 17.8, 11),
            fgcolor = cfg.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        })
    end
    return row
end

return M