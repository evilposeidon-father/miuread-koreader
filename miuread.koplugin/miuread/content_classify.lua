-- WeRead chapter-content classification and service-error helpers, extracted
-- from reader.lua.
--
-- MiuRead 4.5.37 moved the pure HTML/chapter classifiers and error matchers
-- out of the content fetcher so they are independently unit-testable.
local Util = require("miuread.util")
local Http = require("miuread.http")
local Json = require("miuread.json")

local M = {}

local function visible_text(html)
    return tostring(html or ""):gsub("<script.-</script>", " "):gsub("<style.-</style>", " ")
        :gsub("<[^>]+>", " "):gsub("&[%#%w]+;", " "):gsub("%s+", "")
end

local function truthy(value)
    return value == true or value == 1 or value == "1" or value == "true"
end

local function is_structure_chapter(chapter)
    chapter = type(chapter) == "table" and chapter or {}
    if truthy(chapter.isPart) or truthy(chapter.isVolume) or truthy(chapter.isTitle)
        or truthy(chapter.isSection) or truthy(chapter.isDivider)
        or truthy(chapter._miuread_has_children) or truthy(chapter.hasChildren) then
        return true
    end

    local child_count = tonumber(chapter.childCount or chapter.childrenCount or chapter.subChapterCount or 0) or 0
    if child_count > 0 then return true end

    local kind = tostring(chapter.chapterType or chapter.chapter_type or chapter.typeName or chapter.nodeType or ""):lower()
    return kind:find("part", 1, true) ~= nil
        or kind:find("volume", 1, true) ~= nil
        or kind:find("divider", 1, true) ~= nil
        or kind:find("section_title", 1, true) ~= nil
        or kind:find("season", 1, true) ~= nil
end

local function is_cover_chapter(chapter)
    chapter = type(chapter) == "table" and chapter or {}
    if truthy(chapter.isCover) or truthy(chapter.cover) then return true end
    local kind = tostring(chapter.chapterType or chapter.chapter_type or chapter.typeName or chapter.nodeType or ""):lower()
    if kind == "cover" or kind:find("cover_page", 1, true) then return true end
    return tostring(chapter.title or ""):gsub("%s+", "") == "封面"
end

local function is_unavailable_chapter(chapter)
    chapter = type(chapter) == "table" and chapter or {}
    if truthy(chapter.isDeleted) or truthy(chapter.deleted) or truthy(chapter.isRemoved)
        or truthy(chapter.isHidden) or truthy(chapter.unavailable) then
        return true
    end
    local status = tostring(chapter.status or chapter.chapterStatus or chapter.state or ""):lower()
    return status == "deleted" or status == "removed" or status == "hidden" or status == "unavailable"
end

local function has_content_markup(html)
    local value = tostring(html or ""):lower()
    return value:find("<img", 1, true) ~= nil
        or value:find("<svg", 1, true) ~= nil
        or value:find("<image", 1, true) ~= nil
        or value:find("<math", 1, true) ~= nil
        or value:find("<table", 1, true) ~= nil
        or value:find("<audio", 1, true) ~= nil
        or value:find("<video", 1, true) ~= nil
end

local function has_readable_content(html, allow_markup)
    if #visible_text(html) > 0 then return true end
    return allow_markup == true and has_content_markup(html)
end

local CONFIRMED_EMPTY = "__MIUREAD_CONFIRMED_EMPTY__"

local function structure_xhtml(title)
    return '<div class="miu-part-page" data-miuread-structure="1"><h1 class="miu-part-title">'
        .. Util.xml(title or "分部") .. "</h1></div>"
end

local function image_only_xhtml(assets)
    local rows = {'<div class="miu-image-only-page" data-miuread-image-only="1">'}
    for _, asset in ipairs(assets or {}) do
        local href = tostring(asset.href or "")
        if href ~= "" then
            rows[#rows + 1] = '<p class="miu-image-only-item"><img src="../' .. Util.xml(href) .. '" alt="" /></p>'
        end
    end
    rows[#rows + 1] = "</div>"
    return table.concat(rows, "\n")
end

local function readable_text_length(html)
    return #visible_text(html)
end

local function is_empty_error(value)
    local text = tostring(value or ""):lower()
    return text:find("decoded epub chapter is empty", 1, true)
        or text:find("decoded txt chapter is empty", 1, true)
        or text:find("returned empty content", 1, true)
        or text:find("chapter content is empty", 1, true)
end

local function is_confirmed_empty_error(value)
    return tostring(value or ""):find(CONFIRMED_EMPTY, 1, true) ~= nil
end

local function is_auth_error(value)
    return Http.is_auth_error(value)
end

-- Only explicit service-side permission messages are treated as preview or
-- entitlement limits. Network, login and decoding failures must never be
-- downgraded into a preview book.
local function is_access_denied_error(value)
    if is_auth_error(value) then return false end
    local text=tostring(value or "")
    local lower=text:lower()
    local markers={
        "permission denied", "access denied", "not authorized", "not authorised",
        "not entitled", "purchase required", "preview only", "trial only",
        "subscription required", "membership required", "not available for reading",
    }
    for _,marker in ipairs(markers) do
        if lower:find(marker,1,true) then return true end
    end
    local zh={
        "无阅读权限", "没有阅读权限", "暂无阅读权限", "无权阅读",
        "仅支持试读", "仅可试读", "只能试读", "试读结束",
        "需要购买", "请购买后阅读", "购买后可读",
        "会员已过期", "会员到期", "需要会员", "开通会员后阅读",
        "不在可读范围", "本章暂不可读", "该章节暂不可读",
    }
    for _,marker in ipairs(zh) do
        if text:find(marker,1,true) then return true end
    end
    return false
end

local function login_page_error(html, final_url)
    local url = tostring(final_url or ""):lower()
    if url:find("/web/login", 1, true) or url:find("/web/confirm", 1, true)
        or url:find("/r/weread%-skills") then
        return Http.auth_error_message("reader_redirect", "reader page redirected to login")
    end
    local head = tostring(html or ""):sub(1, 8192)
    local lower = head:lower()
    if lower:find('"errcode":-2012', 1, true)
        or lower:find('"errcode": -2012', 1, true)
        or lower:find('"err_code":-2012', 1, true)
        or lower:find("login_timeout", 1, true)
        or lower:find("login timeout", 1, true)
        or lower:find("getloginuid", 1, true)
        or head:find("扫码登录", 1, true)
        or head:find("登录微信读书", 1, true) then
        return Http.auth_error_message(-2012, "reader page session expired")
    end
end

local function raw_service_auth_error(raw)
    local text = tostring(raw or ""):gsub("^%s+", "")
    if text:sub(1, 1) ~= "{" then return nil end
    local ok, data = pcall(Json.decode, text)
    if not ok or type(data) ~= "table" then return nil end
    local code = data.errCode or data.errcode or data.code
    local message = tostring(data.errMsg or data.errmsg or data.message or data.msg or "")
    if tonumber(code) == -2012 or message:lower():find("login timeout", 1, true)
        or message:find("登录超时", 1, true) then
        return Http.auth_error_message(code or -2012, message)
    end
end

M.visible_text = visible_text
M.truthy = truthy
M.is_structure_chapter = is_structure_chapter
M.is_cover_chapter = is_cover_chapter
M.is_unavailable_chapter = is_unavailable_chapter
M.has_content_markup = has_content_markup
M.has_readable_content = has_readable_content
M.structure_xhtml = structure_xhtml
M.image_only_xhtml = image_only_xhtml
M.readable_text_length = readable_text_length
M.is_empty_error = is_empty_error
M.is_confirmed_empty_error = is_confirmed_empty_error
M.is_auth_error = is_auth_error
M.is_access_denied_error = is_access_denied_error
M.login_page_error = login_page_error
M.raw_service_auth_error = raw_service_auth_error
M.CONFIRMED_EMPTY = CONFIRMED_EMPTY

return M
