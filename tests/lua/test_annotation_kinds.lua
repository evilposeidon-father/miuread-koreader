local B = require("tests.lua.bootstrap")

local Kinds = require("miuread.annotation_kinds")

local T = {}

function T.test_labels_and_icons()
    B.eq(Kinds.label("bookmark"), "书签")
    B.eq(Kinds.label("highlight"), "划线")
    B.eq(Kinds.label("thought"), "想法")
    B.eq(Kinds.label("bogus"), "批注", "unknown falls back to 批注")
    B.eq(Kinds.label(nil), "批注")
    B.eq(Kinds.icon("bookmark"), "bookmark")
    B.eq(Kinds.icon("thought"), "thought")
    B.eq(Kinds.icon("bogus"), "highlight", "unknown icon falls back to highlight")
    B.ok(Kinds.is_kind("highlight"))
    B.ok(not Kinds.is_kind("bogus"))
end

function T.test_summary()
    B.eq(Kinds.summary({}), "暂无批注")
    B.eq(Kinds.summary({bookmark = 3, highlight = 5, thought = 2}), "书签 3 · 划线 5 · 想法 2")
    B.eq(Kinds.summary({highlight = 1}), "书签 0 · 划线 1 · 想法 0")
    B.eq(Kinds.summary(nil), "暂无批注")
end

function T.test_kind_order_stable()
    B.eq(table.concat(Kinds.KINDS, ","), "bookmark,highlight,thought", "stable kind order")
end

return T