local B = require("tests.lua.bootstrap")
local Stubs = require("tests.lua.koreader_stubs")
Stubs.install()
local CC = require("miuread.content_classify")

local T = {}

function T.test_truthy()
    B.eq(CC.truthy(true), true, "true")
    B.eq(CC.truthy(1), true, "1")
    B.eq(CC.truthy("1"), true, "str 1")
    B.eq(CC.truthy("true"), true, "str true")
    B.eq(CC.truthy(0), false, "0")
    B.eq(CC.truthy(false), false, "false")
end

function T.test_visible_text()
    B.eq(CC.visible_text("<p>你好</p><script>x</script>"), "你好", "strips tags and scripts")
    B.eq(CC.visible_text("a &amp; b"), "ab", "strips entities and spaces")
end

function T.test_chapter_classification()
    B.eq(CC.is_structure_chapter({ isPart = 1 }), true, "part")
    B.eq(CC.is_structure_chapter({ childCount = 2 }), true, "has children")
    B.eq(CC.is_structure_chapter({ chapterType = "volume" }), true, "volume type")
    B.eq(CC.is_structure_chapter({}), false, "plain chapter")
    B.eq(CC.is_cover_chapter({ isCover = true }), true, "cover flag")
    B.eq(CC.is_cover_chapter({ title = " 封 面 " }), true, "cover title")
    B.eq(CC.is_unavailable_chapter({ isDeleted = 1 }), true, "deleted")
    B.eq(CC.is_unavailable_chapter({ status = "hidden" }), true, "hidden status")
end

function T.test_content_markup()
    B.eq(CC.has_content_markup("<img src='a.png'>"), true, "img")
    B.eq(CC.has_content_markup("<table></table>"), true, "table")
    B.eq(CC.has_content_markup("<p>text</p>"), false, "no markup")
    B.eq(CC.has_readable_content("<p>text</p>"), true, "readable text")
    B.eq(CC.has_readable_content("<img src='a.png'>", true), true, "markup allowed")
    B.eq(CC.has_readable_content("<img src='a.png'>", false), false, "markup denied")
end

function T.test_empty_error()
    B.ok(CC.is_empty_error("decoded epub chapter is empty"), "empty epub marker")
    B.ok(not CC.is_empty_error("some other error"), "not empty marker")
    B.eq(CC.is_confirmed_empty_error("__MIUREAD_CONFIRMED_EMPTY__: x"), true, "confirmed empty")
end

function T.test_access_denied_error()
    B.eq(CC.is_access_denied_error("permission denied"), true, "english marker")
    B.eq(CC.is_access_denied_error("本章暂不可读"), true, "chinese marker")
    B.eq(CC.is_access_denied_error("network timeout"), false, "not access denied")
end

return T
