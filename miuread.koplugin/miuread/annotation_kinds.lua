-- Canonical annotation kind spec shared by the external UI (我的批注/搜索)
-- and the reader UI (批注记录/汇总/面板). Single source so the two
-- surfaces can never drift apart in wording or icons.
local M = {}

M.KINDS = {"bookmark", "highlight", "thought"}
M.LABELS = {bookmark = "书签", highlight = "划线", thought = "想法"}
M.ICONS = {bookmark = "bookmark", highlight = "highlight", thought = "thought"}
-- Fallback row labels used by the reader records list (backend wrap-up review:
-- they were hard-coded in five places before).
M.BOOKMARK_FALLBACK = "书页书签"
M.TEXT_FALLBACK = "无文字内容"

function M.is_kind(kind)
    return M.LABELS[tostring(kind or "")] ~= nil
end

function M.label(kind)
    return M.LABELS[tostring(kind or "")] or "批注"
end

function M.icon(kind)
    return M.ICONS[tostring(kind or "")] or "highlight"
end

-- "书签 3 · 划线 5 · 想法 2" style summary used by reader panels.
function M.summary(counts)
    counts = type(counts) == "table" and counts or {}
    local total = 0
    local parts = {}
    for _, kind in ipairs(M.KINDS) do
        local count = tonumber(counts[kind]) or 0
        total = total + count
        parts[#parts + 1] = M.label(kind) .. " " .. tostring(count)
    end
    if total <= 0 then return "暂无批注" end
    return table.concat(parts, " · ")
end

return M