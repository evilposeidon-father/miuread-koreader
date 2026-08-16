local B = require("tests.lua.bootstrap")
local CT = require("miuread.chapter_title")

local T = {}

function T.test_plain()
    B.eq(CT.plain("a&amp;b"), "a b", "strip entity")
    B.eq(CT.plain("<p>text</p>"), " text ", "strip tag")
end

function T.test_normalized_title()
    B.eq(CT.normalized_title(" Hello  World "), "helloworld", "lower and strip spaces")
    B.eq(CT.normalized_title_legacy(" Hello  World "), "helloworld", "legacy normalization")
end

function T.test_trim_lead()
    B.eq(CT.trim_lead("   hello"), "hello", "trim spaces")
    B.eq(CT.trim_lead("\t\nhi"), "hi", "trim control")
end

function T.test_has_number_unit()
    B.eq(CT.has_number_unit("第一章"), true, "章 unit")
    B.eq(CT.has_number_unit("第三回"), true, "回 unit")
    B.eq(CT.has_number_unit("序言"), false, "no unit")
end

function T.test_title_is_numbered()
    B.eq(CT.title_is_numbered("第一章 你好"), true, "第 + cjk digit")
    B.eq(CT.title_is_numbered("Chapter 1"), true, "chapter")
    B.eq(CT.title_is_numbered("12 开始"), true, "leading digit")
    B.eq(CT.title_is_numbered("序言"), false, "not numbered")
end

function T.test_attribute_and_headings()
    B.eq(CT.attribute('id="x" class="y"', "id"), "x", "double quote attr")
    B.eq(CT.attribute("id='z'", "id"), "z", "single quote attr")
    local labels = CT.heading_labels({ inner = '<img alt="封面" title="封">' })
    B.eq(labels[1], '<img alt="封面" title="封">', "inner first")
    B.eq(labels[2], "", "no title attr")
end

return T
