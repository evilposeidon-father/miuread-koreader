-- Selection behavior for MiuRead books (B12 mitigation).
-- auto_underline = 选词直接划线（默认）；native_menu = 保留 KOReader 原生
-- 选择菜单（复制/查词/划线）。
local M = {}

function M.policy(selection_menu)
    return selection_menu == true and "native_menu" or "auto_underline"
end

-- G5: highlight drawer styles on grayscale e-ink (WeRead 下划线/高亮/波浪
-- 的灰阶降级——波浪线 KOReader 无，用反白替代，靠齐）。
M.STYLES = {"underscore", "lighten", "invert"}
M.STYLE_LABELS = {underscore = "下划线", lighten = "浅底", invert = "反白"}

function M.style_label(style)
    return M.STYLE_LABELS[tostring(style or "")] or "下划线"
end

function M.is_style(style)
    return M.STYLE_LABELS[tostring(style or "")] ~= nil
end

return M