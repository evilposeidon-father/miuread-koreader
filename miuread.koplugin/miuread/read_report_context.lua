-- Reading-context subset for the read-report path.
local Protocol = require("miuread.protocol")
local Context = {}

function Context.extract_reader_state(html)
    return {
        book_id = html:match([["bookId"%s*:%s*"([^"]+)"]]) or html:match([["bookId"%s*:%s*(%d+)]]),
        title = html:match([["title"%s*:%s*"([^"]+)"]]),
        author = html:match([["author"%s*:%s*"([^"]+)"]]),
        psvts = html:match([["psvts"%s*:%s*"([^"]+)"]]),
        pclts = html:match([["pclts"%s*:%s*"([^"]+)"]]),
        token = html:match([["token"%s*:%s*"([^"]+)"]]),
    }
end

function Context.normalize_chapters(payload, book_id)
    local records = payload
    if type(payload) == "table" and payload.data then records = payload.data end
    if type(records) ~= "table" then return {} end
    if records.bookId or records.updated then records = { records } end
    for _, record in ipairs(records) do
        if tostring(record.bookId or "") == tostring(book_id) then
            return record.updated or record.chapterInfos or record.chapters or {}
        end
    end
    return {}
end

local function truthy(value)
    return value == true or value == 1 or value == "1" or value == "true"
end

function Context.chapter_uid(chapter)
    return chapter and (chapter.chapterUid or chapter.uid or chapter.chapter_uid)
end

function Context.is_structural_chapter(chapter)
    if type(chapter) ~= "table" then return true end
    local title = tostring(chapter.title or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if title == "封面" then return true end
    if truthy(chapter.isCover) or truthy(chapter.cover) then return true end
    local kind = tostring(chapter.chapterType or chapter.type or ""):lower()
    if kind == "cover" then return true end
    return Context.chapter_uid(chapter) == nil
end

function Context.is_readable_chapter(chapter)
    if Context.is_structural_chapter(chapter) then return false end
    return (tonumber(chapter.wordCount or chapter.word_count or 0) or 0) > 0
end

function Context.first_readable_chapter(chapters)
    for _, chapter in ipairs(chapters or {}) do
        if Context.is_readable_chapter(chapter) then return chapter end
    end
end

function Context.readable_chapters(chapters)
    local out = {}
    for _, chapter in ipairs(chapters or {}) do
        if Context.is_readable_chapter(chapter) then out[#out + 1] = chapter end
    end
    return out
end

function Context.ensure_reader_state(transport, book)
    local book_id = book.book_id or book.bookId
    local reader_url = book.reader_url or Protocol.reader_url(book_id)
    local reader_html = transport:get_text(reader_url, { referer = reader_url })
    local state = Context.extract_reader_state(reader_html)
    book.book_id = book.book_id or state.book_id or book.bookId
    book.title = book.title or state.title
    book.author = book.author or state.author
    book.psvts = state.psvts or book.psvts
    book.pclts = state.pclts or book.pclts
    book.token = state.token or book.token
    book.reader_url = reader_url
    if not book.psvts then error("reader.psvts not found") end
    return state
end

function Context.fetch_catalog(transport, book)
    local book_id = book.book_id or book.bookId
    local reader_url = book.reader_url or Protocol.reader_url(book_id)
    local catalog = transport:post_json("https://weread.qq.com/web/book/chapterInfos", {
        bookIds = { tostring(book_id) },
    }, { referer = reader_url })
    local chapters = Context.normalize_chapters(catalog, book_id)
    book.chapters = chapters
    return chapters
end

return Context
