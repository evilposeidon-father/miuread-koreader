-- Chapter-title normalization and heading-scan helpers, extracted from
-- downloader.lua.
--
-- MiuRead 4.5.39 moved the pure title folding/numbering/heading helpers into
-- this deep module so they are independently unit-testable.
local M = {}

local function normalized_book(value)
    value = type(value) == "table" and value or {}
    local source = value.bookInfo or value.book or value
    return {
        bookId = tostring(source.bookId or source.book_id or value.bookId or value.book_id or ""),
        title = tostring(source.title or value.title or "未命名"),
        author = tostring(source.author or value.author or ""),
        cover = source.cover or source.coverUrl or value.cover,
        category = source.category or value.category,
        version = tonumber(source.version or source.bookVersion or source.book_version
            or value.version or value.bookVersion or value.book_version),
    }
end

local function css_add(list, seen, css)
    css = tostring(css or "")
    if css ~= "" and not seen[css] then seen[css] = true; list[#list + 1] = css end
end

local function plain(value)
    return tostring(value or ""):gsub("<[^>]+>", " "):gsub("&[%#%w]+;", " "):gsub("%s+", " ")
end

-- Fold the full-width ASCII block (U+FF01-U+FF5E) onto plain ASCII so a title
-- differing from the body only by punctuation width still compares equal.
local function fold_fullwidth(value)
    value = tostring(value or "")
    value = value:gsub("\239\188([\129-\191])", function(c) return string.char(c:byte() - 96) end)
    value = value:gsub("\239\189([\128-\158])", function(c) return string.char(c:byte() - 32) end)
    return value
end

-- Lua's %s and %p only cover single-byte ASCII. Remove common invisible spacing
-- and CJK punctuation explicitly so visually identical headings compare equal.
local BLANK_PATTERNS = {
    "\194\160",             -- U+00A0 no-break space
    "\194\173",             -- U+00AD soft hyphen
    "\227\128[\128-\191]",  -- U+3000-U+303F ideographic space and CJK punctuation
    "\226\128[\128-\191]",  -- U+2000-U+203F spaces, dashes, quotes and ellipsis
    "\226\129[\128-\175]",  -- U+2040-U+206F
    "\239\187\191",         -- U+FEFF byte order mark
}

local function normalized_title(value)
    local text = fold_fullwidth(plain(value)):lower()
    for _, pattern in ipairs(BLANK_PATTERNS) do text = text:gsub(pattern, "") end
    return text:gsub("[%s%p%c]", "")
end

local function trim_lead(value)
    value = tostring(value or "")
    while true do
        local stripped = value:gsub("^[%s%c]+", "")
        for _, pattern in ipairs(BLANK_PATTERNS) do stripped = stripped:gsub("^" .. pattern, "") end
        if stripped == value then return value end
        value = stripped
    end
end

local CJK_DIGITS = {
    ["〇"]=true, ["零"]=true, ["一"]=true, ["二"]=true, ["三"]=true, ["四"]=true,
    ["五"]=true, ["六"]=true, ["七"]=true, ["八"]=true, ["九"]=true, ["十"]=true,
    ["百"]=true, ["千"]=true, ["两"]=true,
}
local NUMBER_UNITS = {"章", "节", "節", "回", "卷", "篇", "部", "夜", "话", "話", "集", "幕", "折", "出"}
local NUMBER_SEPARATORS = {["、"]=true, ["．"]=true, ["："]=true, ["，"]=true, ["。"]=true}

local function has_number_unit(text)
    for _, unit in ipairs(NUMBER_UNITS) do
        if text:find(unit, 1, true) then return true end
    end
    return false
end

local function title_is_numbered(title)
    title = trim_lead(title)
    if title == "" then return false end
    if title:find("^%d") or title:find("^[%(%[]%s*%d") then return true end
    if title:find("^（%s*%d") or title:find("^【%s*%d") then return true end
    local lowered = title:lower()
    if lowered:find("^chapter") or lowered:find("^part%s") or lowered:find("^section%s") then return true end
    if title:sub(1, 3) == "第" then
        local following = title:sub(4, 6)
        if CJK_DIGITS[following] or title:sub(4, 4):find("%d") then return true end
    end
    if CJK_DIGITS[title:sub(1, 3)] then
        local head = title:sub(1, 24)
        if has_number_unit(head) then return true end
        if NUMBER_SEPARATORS[title:sub(4, 6)] then return true end
        if title:find("^...[%.%s]") then return true end
    end
    return false
end

local TITLE_SCAN_LIMIT = 2400
local TITLE_SCAN_WINDOW = TITLE_SCAN_LIMIT + 2000
local TITLE_SCAN_HEADINGS = 8
local TITLE_SLACK_BYTES = 40

local function attribute(attrs, name)
    attrs = tostring(attrs or "")
    return attrs:match(name .. '%s*=%s*"([^"]*)"')
        or attrs:match(name .. "%s*=%s*'([^']*)'")
        or ""
end

local function heading_labels(head)
    local out = {head.inner, attribute(head.attrs, "title")}
    for image_attrs in tostring(head.inner or ""):gmatch("<img([^>]*)>") do
        out[#out + 1] = attribute(image_attrs, "alt")
        out[#out + 1] = attribute(image_attrs, "title")
    end
    return out
end

local function collect_headings(window, limit)
    local headings, position = {}, 1
    while #headings < TITLE_SCAN_HEADINGS do
        local first, last, tag, attrs, inner = window:find("<(h[1-6])([^>]*)>(.-)</%1%s*>", position)
        if not first or first > limit then break end
        headings[#headings + 1] = {first=first, last=last, tag=tag, attrs=attrs, inner=inner}
        position = last + 1
    end
    return headings
end

local function normalized_title_legacy(value)
    return plain(value):lower():gsub("[%s%p%c]", "")
end

M.normalized_book = normalized_book
M.css_add = css_add
M.plain = plain
M.fold_fullwidth = fold_fullwidth
M.normalized_title = normalized_title
M.trim_lead = trim_lead
M.has_number_unit = has_number_unit
M.title_is_numbered = title_is_numbered
M.attribute = attribute
M.heading_labels = heading_labels
M.collect_headings = collect_headings
M.normalized_title_legacy = normalized_title_legacy
M.BLANK_PATTERNS = BLANK_PATTERNS
M.CJK_DIGITS = CJK_DIGITS
M.NUMBER_UNITS = NUMBER_UNITS
M.NUMBER_SEPARATORS = NUMBER_SEPARATORS
M.TITLE_SCAN_LIMIT = TITLE_SCAN_LIMIT
M.TITLE_SCAN_WINDOW = TITLE_SCAN_WINDOW
M.TITLE_SCAN_HEADINGS = TITLE_SCAN_HEADINGS
M.TITLE_SLACK_BYTES = TITLE_SLACK_BYTES

return M
