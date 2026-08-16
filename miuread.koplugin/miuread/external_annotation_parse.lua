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

M.collect_ranges = collect_ranges
M.catalog_signature = catalog_signature
M.chapter_uid = chapter_uid
M.chapter_title = chapter_title
M.normalize_comments = normalize_comments
M.scalar = scalar
M.collect_records = collect_records
M.review_parts = review_parts
M.clean_book_keyword = clean_book_keyword

return M
