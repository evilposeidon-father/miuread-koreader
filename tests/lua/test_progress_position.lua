local B = require("tests.lua.bootstrap")
local PP = require("miuread.progress_position")

local T = {}

local MAP = {
    { uid = "u1", title = "Chapter One", word_count = 10, index = 1 },
    { uid = "u2", title = "Chapter Two", word_count = 20, index = 2 },
}

function T.test_chapter_helpers()
    B.eq(PP.chapter_uid({ chapterUid = "x" }), "x")
    B.eq(PP.chapter_uid({ uid = "y" }), "y")
    B.eq(PP.chapter_index({ chapterIdx = 7 }), 7)
    B.eq(PP.chapter_words({ wordCount = 0 }), 1, "words never below one")
    B.eq(PP.readable_local_chapter_count(MAP), 2)
    B.eq(PP.readable_local_chapter_count({ { structural = true, uid = "s" } }), 0)
    local chapter = PP.local_chapter_by_uid(MAP, "u2")
    B.eq(chapter.title, "Chapter Two")
end

function T.test_map_position_mid_chapter()
    local position = PP.map_position(MAP, 0.5, { summary = "Book" })
    B.eq(position.chapter_uid, "u2", "15/30 words lands in chapter two")
    B.eq(position.offset, 5)
    B.eq(position.progress, 50)
    B.eq(position.summary, "Chapter Two")
end

function T.test_resolve_precise_when_maps_equivalent()
    local resolved = PP.resolve(MAP, MAP, 0.25, { summary = "Book" })
    B.eq(resolved.safe, true)
    B.eq(resolved.source, "full_epub_catalog")
    B.ok(resolved.progress ~= nil)
end

function T.test_resolve_fallback_when_chapter_missing()
    local other = { { uid = "u9", title = "Other", word_count = 30 } }
    local resolved = PP.resolve(MAP, other, 0.5, { summary = "Book" })
    B.eq(resolved.safe, false, "maps differ so fallback is unsafe")
    B.eq(resolved.source, "unsafe_local_ratio")
    B.eq(resolved.chapter_uid, "u2", "fallback uses local map")
end

function T.test_resolve_empty_maps()
    local resolved = PP.resolve({}, {}, 0.4, { chapter_uid = 0, summary = "" })
    B.eq(resolved.progress, 40)
    B.eq(resolved.safe, false)
end

return T
