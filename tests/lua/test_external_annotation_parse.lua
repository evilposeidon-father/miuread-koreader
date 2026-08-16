local B = require("tests.lua.bootstrap")
local EP = require("miuread.external_annotation_parse")

local T = {}

function T.test_collect_ranges()
    local ranges = EP.collect_ranges({ underlines = { { range = "a" }, { range = "b" }, { range = "a" } } })
    B.eq(#ranges, 2, "deduped")
    B.eq(ranges[1], "a", "first")
    B.eq(ranges[2], "b", "second")
end

function T.test_catalog_signature()
    local sig = EP.catalog_signature("bk1", { { chapterUid = "c1" }, { chapterUid = "c2" } })
    B.eq(type(sig), "string", "string signature")
    B.eq(#sig, 64, "sha256 length")
    B.eq(sig, EP.catalog_signature("bk1", { { chapterUid = "c1" }, { chapterUid = "c2" } }), "deterministic")
end

function T.test_chapter_uid_and_title()
    B.eq(EP.chapter_uid({ chapterUid = 123 }), "123", "uid")
    B.eq(EP.chapter_title({ title = "标题" }), "标题", "title")
end

function T.test_normalize_comments()
    local one = EP.normalize_comments({ { author = "a", content = "c", likes = 3 } })
    B.eq(#one, 1, "one comment")
    B.eq(one[1].author, "a", "author")
    B.eq(one[1].likes, 3, "likes")
    local fallback = EP.normalize_comments({})
    B.eq(fallback[1].content, "这条划线没有想法", "default comment")
end

function T.test_review_parts()
    local range, abstract, content, author = EP.review_parts({ range = "r1", abstract = "abs", content = "con", nick = "nick" })
    B.eq(range, "r1", "range")
    B.eq(abstract, "abs", "abstract")
    B.eq(content, "con", "content")
    B.eq(author, "nick", "author")
end

function T.test_clean_book_keyword()
    B.eq(EP.clean_book_keyword("书名-纯净版.epub"), "书名", "clean edition suffix")
    B.eq(EP.clean_book_keyword("书名-划线与想法版.epub"), "书名", "notes edition suffix")
    B.eq(EP.clean_book_keyword("普通书名.epub"), "普通书名", "no suffix")
end

return T
