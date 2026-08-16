local B = require("tests.lua.bootstrap")
local HM = require("miuread.home_network_metadata")

local T = {}

function T.test_metadata_key()
    B.eq(HM.metadata_key({ bookId = "123" }), "book:123", "book id key")
    B.eq(HM.metadata_key({ file = "a/b/c.epub" }), "file:a/b/c.epub", "file key")
    B.eq(HM.metadata_key({ file = "a\\b\\c.epub" }), "file:a/b/c.epub", "backslash normalized")
    B.eq(HM.metadata_key({ title = "  三体  ", author = " 刘慈欣 " }), "title:三体|刘慈欣", "title key trimmed")
    B.eq(HM.metadata_key(nil), "", "nil book")
end

function T.test_patch_has_data()
    B.eq(HM.patch_has_data({}), false, "empty patch")
    B.eq(HM.patch_has_data({ title = "x" }), true, "title present")
    B.eq(HM.patch_has_data({ title = "   " }), false, "blank ignored")
    B.eq(HM.patch_has_data(nil), false, "nil patch")
end

function T.test_patch_field_count()
    B.eq(HM.patch_field_count({}), 0, "empty")
    B.eq(HM.patch_field_count({ title = "x", author = "y", pages = 300 }), 3, "three fields")
    B.eq(HM.patch_field_count({ title = "  " }), 0, "blank ignored")
end

function T.test_missing_fields()
    local missing = HM.missing_fields({}, { title = "x" })
    B.eq(#missing, 5, "all detail fields missing")
    local with_intro = HM.missing_fields({ intro = "简介" }, {})
    local has_desc = false
    for _, k in ipairs(with_intro) do if k == "description" then has_desc = true end end
    B.eq(has_desc, false, "intro fills description")
end

function T.test_merge_patch()
    local book = { title = "" }
    local changed = HM.merge_patch(book, { title = "三体", author = "刘慈欣", metadata_source = "google" })
    B.eq(changed, true, "changed reported")
    B.eq(book.title, "三体", "title filled")
    B.eq(book.author, "刘慈欣", "author filled")
    B.eq(book.network_metadata_source, "google", "source filled")
    B.eq(HM.merge_patch(nil, {}), false, "nil book")
end

return T
