local B = require("tests.lua.bootstrap")
local SR = require("miuread.sync_response")

local T = {}

function T.test_accepted_and_synckey()
    B.eq(SR.accepted({ succ = 1 }), true, "succ=1 accepted")
    B.eq(SR.accepted({ data = { succ = true } }), true, "deep succ accepted")
    B.eq(SR.accepted({ succ = 0 }), false, "succ=0 rejected")
    B.eq(SR.response_synckey({ data = { synckey = "sk1" } }), "sk1", "synckey nested")
    B.eq(SR.response_synckey({ syncKey = "sk2" }), "sk2", "syncKey alias")
end

function T.test_progress_from_node()
    local p = SR.progress_from_node({ bookId = "b1", progress = 50 }, "b1")
    B.eq(p.percent, 50, "percent kept")
    B.eq(SR.progress_from_node({ progress = 0.5 }, "").percent, 50, "fraction expanded")
    B.eq(SR.progress_from_node({ progress = 1 }, "").percent, 1, "literal 1 stays 1")
    B.eq(SR.progress_from_node({ bookId = "other", progress = 50 }, "b1"), nil, "wrong book rejected")
end

function T.test_normalize_timestamp()
    B.eq(SR.normalize_timestamp(1700000000123), 1700000000, "ms to seconds")
    B.eq(SR.normalize_timestamp(1700000000), 1700000000, "seconds kept")
    B.eq(SR.normalize_timestamp(nil), nil, "nil kept")
end

function T.test_choose_remote_progress()
    local tie = SR.choose_remote_progress({ percent = 50, updated_at = 100 }, { percent = 50, updated_at = 100 }, 2)
    B.eq(tie.conflict, nil, "no conflict on tie")
    B.eq(tie.source, "web_cookie", "web wins tie")
    local conflict = SR.choose_remote_progress({ percent = 10 }, { percent = 90 }, 2)
    B.eq(conflict.conflict, true, "conflict detected")
    B.eq(conflict.source, "conflict", "conflict source")
end

function T.test_positions_match()
    local ok1 = SR.positions_match({ chapter_uid = "c1", offset = 100, chapter_word_count = 1000 }, { chapter_uid = "c1", offset = 100 }, 2)
    B.eq(ok1, true, "same offset matches")
    local ok2 = SR.positions_match({ chapter_uid = "c1" }, { chapter_uid = "c2" }, 2)
    B.eq(ok2, false, "uid mismatch rejected")
end

function T.test_report_ratio_from_position()
    B.almost(SR.report_ratio_from_position({ progress = 42 }), 0.42, 0.0001, "whole-book ratio")
    B.almost(SR.report_ratio_from_position({ standalone = true, chapter_percent = 50 }), 0.5, 0.0001, "standalone percent")
    B.almost(SR.report_ratio_from_position({ standalone = true, chapter_ratio = 0.5 }), 0.5, 0.0001, "standalone ratio")
end

return T
