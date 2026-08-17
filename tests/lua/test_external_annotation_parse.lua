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

function T.test_merge_records_by_id_dedupes_collisions()
    local primary = {
        { id = "bk:1:r1", text = "a" },
        { id = "bk:1:r2", text = "b" },
    }
    local extra = {
        { id = "bk:1:r2", text = "b-dup" },
        { id = "bk:2:r3", text = "c" },
    }
    local out = EP.merge_records_by_id(primary, extra)
    B.eq(#out, 3, "collision dropped, unique appended")
    B.eq(out[1].text, "a")
    B.eq(out[2].text, "b", "primary wins on collision")
    B.eq(out[3].text, "c")
end

function T.test_merge_records_by_id_appends_idless()
    local out = EP.merge_records_by_id({ { id = "" } }, { { id = "" }, { id = "x:1" } })
    B.eq(#out, 3, "id-less records always appended")
end

function T.test_merge_records_by_id_handles_nil()
    B.eq(#EP.merge_records_by_id(nil, { { id = "a" } }), 1, "nil primary")
    B.eq(#EP.merge_records_by_id({ { id = "a" } }, nil), 1, "nil extra")
    B.eq(#EP.merge_records_by_id(nil, nil), 0, "both nil")
end

function T.test_normalize_title()
    B.eq(EP.normalize_title("三体-纯净版"), "三体", "edition suffix stripped")
    B.eq(EP.normalize_title("三体（全集）"), "三体全集", "punct removed, 全集 kept")
    B.eq(EP.normalize_title(" 三体 "), "三体", "whitespace removed")
    B.eq(EP.normalize_title("三体"), EP.normalize_title("三体-纯净版"), "edition equals base")
    B.eq(EP.normalize_title("Shan Hai Jing"), "shanhaijing", "lowercased ascii")
end

function T.test_pick_search_match_exact_title()
    local candidates = {
        { book_id = "b1", title = "三体", author = "刘慈欣" },
        { book_id = "b2", title = "三体2：黑暗森林", author = "刘慈欣" },
    }
    B.eq(EP.pick_search_match(candidates, "三体-纯净版"), candidates[1], "exact title match after cleanup")
    B.eq(EP.pick_search_match(candidates, "三体"), candidates[1], "plain title")
    B.eq(EP.pick_search_match(candidates, "三体2：黑暗森林"), candidates[2], "full-width colon title")
    B.eq(EP.pick_search_match(candidates, "三体2"), nil, "subtitle-less keyword never false-matches")
end

function T.test_pick_search_match_ambiguous_is_nil()
    local candidates = {
        { book_id = "b1", title = "三体", author = "甲出版社" },
        { book_id = "b2", title = "三体", author = "乙出版社" },
    }
    B.eq(EP.pick_search_match(candidates, "三体"), nil, "two same-title editions never auto-bind")
    B.eq(EP.pick_search_match(candidates, "三体", "刘慈欣"), nil, "author mismatch keeps ambiguity")
    B.eq(EP.pick_search_match(candidates, "三体", "甲出版社"), candidates[1], "author disambiguates")
end

function T.test_pick_search_match_no_match()
    B.eq(EP.pick_search_match({ { book_id = "b1", title = "活着" } }, "三体"), nil, "different title")
    B.eq(EP.pick_search_match({}, "三体"), nil, "no candidates")
    B.eq(EP.pick_search_match(nil, "三体"), nil, "nil candidates")
    B.eq(EP.pick_search_match({ { book_id = "b1", title = "三体" } }, ""), nil, "empty title")
end

return T
