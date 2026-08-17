local B = require("tests.lua.bootstrap")

local Parse = require("miuread.external_annotation_parse")

local T = {}

function T.test_filter_by_chapter_orders_by_pos0()
    local records = {
        {chapter_uid = "c1", pos0 = "30", range = "r1", text = "B"},
        {chapter_uid = "c2", pos0 = "10", range = "r2", text = "X"},
        {chapter_uid = "c1", pos0 = "5", range = "r3", text = "A"},
        {chapter_uid = "c1", pos0 = "5", range = "r4", text = "A2"},
    }
    local out = Parse.filter_records_by_chapter(records, "c1")
    B.eq(#out, 3, "only c1 kept")
    B.eq(out[1].range, "r3", "pos0 asc")
    B.eq(out[2].range, "r4", "stable tiebreak by range")
    B.eq(out[3].range, "r1")
    B.eq(#records, 4, "input untouched")
end

function T.test_filter_empty_uid_never_matches()
    local records = { {chapter_uid = "", pos0 = "1"} }
    B.eq(#Parse.filter_records_by_chapter(records, ""), 0, "blank uid -> empty")
    B.eq(#Parse.filter_records_by_chapter(nil, "c1"), 0, "nil records")
    B.eq(#Parse.filter_records_by_chapter(records, nil), 0, "nil uid")
end

function T.test_filter_falls_back_to_chapter_idx_for_blank_uid()
    local records = {
        {chapter_uid = "", chapter_idx = 3, pos0 = "20", range = "a"},
        {chapter_uid = "", chapter_idx = 4, pos0 = "5", range = "b"},
        {chapter_uid = "c1", chapter_idx = 3, pos0 = "1", range = "c"},
        {chapter_uid = "c2", chapter_idx = 3, pos0 = "0", range = "d"},
    }
    local out = Parse.filter_records_by_chapter(records, "", 3)
    B.eq(#out, 1, "blank-uid row with matching idx kept")
    B.eq(out[1].range, "a")
    local by_uid = Parse.filter_records_by_chapter(records, "c1", 3)
    B.eq(#by_uid, 2, "blank-uid same-idx row joins the chapter")
    B.eq(by_uid[1].range, "c", "pos0 asc")
    B.eq(by_uid[2].range, "a")
end

return T