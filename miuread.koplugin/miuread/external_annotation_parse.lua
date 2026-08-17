-- External-annotation record/range/keyword helpers, extracted from
-- external_annotation_sync.lua.
--
-- MiuRead 4.5.40 moved the pure range/record parsing and book-keyword cleaning
-- helpers into this deep module so local-book annotation matching can be
-- unit-tested independently.
local Digests = require("miuread.digests")

local M = {}

local function collect_ranges(underlines)
    local ranges, seen = {}, {}
    local source = type(underlines) == "table" and underlines.underlines or underlines or {}
    for _, underline in ipairs(type(source) == "table" and source or {}) do
        if type(underline) == "table" then
            local range = tostring(underline.range or "")
            if range ~= "" and not seen[range] then
                seen[range] = true
                ranges[#ranges + 1] = range
            end
        end
    end
    return ranges
end

local function catalog_signature(book_id, catalog)
    local parts = { tostring(book_id or "") }
    for _, chapter in ipairs(catalog or {}) do
        parts[#parts + 1] = tostring(chapter.chapterUid or chapter.chapterId or chapter.uid or "")
    end
    return Digests.sha256(table.concat(parts, ":"))
end

local function chapter_uid(chapter)
    return tostring(chapter and (chapter.chapterUid or chapter.chapterId or chapter.uid) or "")
end

local function chapter_title(chapter)
    return tostring(chapter and chapter.title or "")
end

local function normalize_comments(items)
    local comments = {}
    for _, item in ipairs(type(items) == "table" and items or {}) do
        if type(item) == "table" then
            comments[#comments + 1] = {
                author = tostring(item.author or "微信读书用户"),
                likes = tonumber(item.likes_count or item.likes or 0) or 0,
                content = tostring(item.content or ""),
            }
        end
    end
    if #comments == 0 then
        comments[#comments + 1] = {
            author = "微信读书",
            likes = 0,
            content = "这条划线没有想法",
        }
    end
    return comments
end

local function scalar(value)
    if type(value) == "string" or type(value) == "number" then
        return tostring(value)
    end
    return ""
end

local function collect_records(value, out, seen, depth)
    out = out or {}
    seen = seen or {}
    depth = depth or 0
    if type(value) ~= "table" or seen[value] or depth > 7 then return out end
    seen[value] = true
    local has_identity = scalar(value.bookmarkId) ~= "" or scalar(value.reviewId) ~= ""
        or scalar(value.range or value.markRange or value.bookmarkRange) ~= ""
    if has_identity then out[#out + 1] = value end
    for _, child in pairs(value) do
        if type(child) == "table" then
            collect_records(child, out, seen, depth + 1)
        end
    end
    return out
end

local function review_parts(row)
    if type(row) ~= "table" then return "", "", "", "" end
    local inner = type(row.review) == "table" and row.review or row
    local range = scalar(row.range or row.markRange or row.bookmarkRange
        or inner.range or inner.markRange or inner.bookmarkRange)
    local abstract = scalar(row.abstract or row.contextAbstract
        or inner.abstract or inner.contextAbstract)
    local content = scalar(row.content or inner.content)
    local author = type(inner.author) == "table" and inner.author or {}
    local author_name = scalar(author.nick or author.name or row.nick or row.name or "匿名")
    return range, abstract, content, author_name
end

-- Remove MiuRead variant suffixes so "书名-纯净版" or
-- "书名-划线与想法版" becomes searchable as the original book title.
local function clean_book_keyword(path)
    local name = tostring(path or "")
    name = name:match("([^/]+)%.[^%.]+$") or name
    name = name:gsub("%s+$", "")
    name = name:gsub("%s*%-%s*[^%-]*版[^%-]*$", "")
    name = name:gsub("%s+$", "")
    name = name:gsub("%s*%-%s*$", "")
    return name
end

-- Merge located record lists (primary then extra), de-duplicating by record
-- id (book_id:chapter_uid:range). Extra records whose id collides with the
-- primary list are dropped; id-less records are always appended.
function M.merge_records_by_id(primary, extra)
    local out, seen = {}, {}
    for _, record in ipairs(type(primary) == "table" and primary or {}) do
        local id = tostring(record and record.id or "")
        out[#out + 1] = record
        if id ~= "" then seen[id] = true end
    end
    for _, record in ipairs(type(extra) == "table" and extra or {}) do
        local id = tostring(record and record.id or "")
        if id == "" or not seen[id] then
            seen[id] = true
            out[#out + 1] = record
        end
    end
    return out
end

-- Edition markers stripped before title matching so "三体-纯净版" and
-- "三体（全集）" both normalize to the base title "三体".
local EDITION_MARKERS = {
    "纯净版", "注释版", "划线与想法版", "无注释版", "全本", "完整版",
    "精排版", "无删减", "典藏版", "修订版", "珍藏版", "纪念版",
    "增订版", "简装版", "精装版", "签名版",
}

-- Full-width punctuation Lua 5.1's %p class does not cover.
local FULLWIDTH_PUNCT = "（）《》「」『』【】、。，！？；：“”‘’·—…"

-- Normalize a book title for exact matching: lowercase, drop edition
-- markers, then strip whitespace and punctuation (ASCII + full-width).
-- Safe direction: a corrupted normalization only prevents a match, never
-- creates one.
function M.normalize_title(value)
    local text = tostring(value or ""):lower()
    for _, marker in ipairs(EDITION_MARKERS) do
        text = text:gsub(marker, "")
    end
    text = text:gsub("[%p%c%s]", "")
    -- Lua 5.1 has no UTF-8 iteration: walk FULLWIDTH_PUNCT by byte length.
    local i = 1
    while i <= #FULLWIDTH_PUNCT do
        local first = FULLWIDTH_PUNCT:byte(i)
        local length = 1
        if first >= 0xF0 then length = 4
        elseif first >= 0xE0 then length = 3
        elseif first >= 0xC0 then length = 2 end
        text = text:gsub(FULLWIDTH_PUNCT:sub(i, i + length - 1), "")
        i = i + length
    end
    return text
end

-- Picks the single unambiguous WeRead search hit for a local book title.
-- Exact normalized-title equality is required; when the local author is
-- known it further filters to matching authors. Returns nil when nothing
-- matches or more than one candidate remains (e.g. several editions of a
-- re-issued title) — an ambiguous hit is never auto-bound.
function M.pick_search_match(candidates, title, author)
    if type(candidates) ~= "table" then return nil end
    local want = M.normalize_title(title)
    if want == "" then return nil end
    local author_norm = M.normalize_title(author or "")
    local matches = {}
    for _, item in ipairs(candidates) do
        if type(item) == "table" and M.normalize_title(item.title or "") == want then
            matches[#matches + 1] = item
        end
    end
    if #matches == 0 then return nil end
    if author_norm ~= "" then
        local by_author = {}
        for _, item in ipairs(matches) do
            if M.normalize_title(item.author or "") == author_norm then
                by_author[#by_author + 1] = item
            end
        end
        if #by_author > 0 then matches = by_author end
    end
    if #matches == 1 then return matches[1] end
    return nil
end

M.collect_ranges = collect_ranges
M.catalog_signature = catalog_signature
M.chapter_uid = chapter_uid
M.chapter_title = chapter_title
M.normalize_comments = normalize_comments
M.scalar = scalar
M.collect_records = collect_records
M.review_parts = review_parts
M.clean_book_keyword = clean_book_keyword


-- Pure: filter located annotation records to one chapter and order them by
-- in-chapter position (pos0). Never mutates the input.
-- Matching rules: an exact chapter_uid wins; records without a uid (locate()
-- writes "" for chapters without one, and the local mirror defaults to "")
-- fall back to chapter_idx when it is given. A record with a non-matching
-- uid is always excluded, so a blank uid can never merge unrelated chapters.
function M.filter_records_by_chapter(records, chapter_uid, chapter_idx)
    chapter_uid = tostring(chapter_uid or "")
    chapter_idx = tonumber(chapter_idx)
    if chapter_uid == "" and chapter_idx == nil then return {} end
    local out = {}
    for _, record in ipairs(type(records) == "table" and records or {}) do
        if type(record) == "table" then
            local uid = tostring(record.chapter_uid or "")
            local idx = tonumber(record.chapter_idx)
            local match
            if uid ~= "" then
                match = chapter_uid ~= "" and uid == chapter_uid
            else
                match = chapter_idx ~= nil and idx == chapter_idx
            end
            if match then out[#out + 1] = record end
        end
    end
    table.sort(out, function(a, b)
        local pa = tonumber(a.pos0) or 0
        local pb = tonumber(b.pos0) or 0
        if pa ~= pb then return pa < pb end
        return tostring(a.range or "") < tostring(b.range or "")
    end)
    return out
end

return M
