local B = require("tests.lua.bootstrap")
local SIM = require("miuread.sync_inverse_mapping")

local T = {}

local MAP = {
    { uid = "u1", title = "C1", word_count = 100, index = 1 },
    { uid = "u2", title = "C2", word_count = 200, index = 2 },
}

local function position(overrides)
    local p = {
        safe = true,
        progress = 25,
        chapter_uid = "u1",
        chapter_offset = 10,
        chapter_ratio = 0.1,
        offset_basis = "wr_data_co",
        native_offset = true,
    }
    if overrides then
        for key, value in pairs(overrides) do p[key] = value end
    end
    return p
end

local function inverse(overrides)
    local i = {
        safe = true,
        chapter_uid = "u1",
        chapter_offset = 80,
        progress = 55,
        chapter_word_count = 200,
        total_word_count = 1000,
        words_before = 800,
    }
    if overrides then
        for key, value in pairs(overrides) do i[key] = value end
    end
    return i
end

function T.test_should_use_inverse_mapping_guards()
    local record = { record = { chapter_map = MAP, partial_range = false } }
    local ok, reason = SIM.should_use_inverse_mapping(record, { safe = false }, MAP, MAP)
    B.eq(ok, false)
    B.eq(reason, nil, "unsafe position must stay untouched (no reason written)")
    local no_record = SIM.should_use_inverse_mapping(nil, position{}, MAP, MAP)
    B.eq(no_record, false)
    local partial = { record = { chapter_map = MAP, partial_range = true } }
    local ok2, reason2 = SIM.should_use_inverse_mapping(partial, position{}, MAP, MAP)
    B.eq(ok2, false)
    B.eq(reason2, "local_map_not_full_catalog")
    local not_full = { record = { chapter_map = { { uid = "u1", word_count = 100, index = 1 } }, partial_range = false } }
    local ok3, reason3 = SIM.should_use_inverse_mapping(not_full, position{}, not_full.record.chapter_map, MAP)
    B.eq(ok3, false)
    B.eq(reason3, "local_map_not_full_catalog")
    local ok4, reason4 = SIM.should_use_inverse_mapping(record, position{}, MAP, MAP)
    B.eq(ok4, true)
    B.eq(reason4, nil)
end

function T.test_compute_decision_ratio_missing()
    local decision = SIM.compute_inverse_decision(position{}, {}, nil, nil, false)
    B.eq(decision.action, "source")
    B.eq(decision.reason, "local_global_ratio_missing")
    B.eq(decision.anchors, nil, "no anchors when the local ratio is missing")
end

function T.test_compute_decision_inverse_position_unavailable()
    local decision = SIM.compute_inverse_decision(position{}, {}, { safe = false, mapping_error = "full_map_empty" }, 0.5, false)
    B.eq(decision.action, "source")
    B.eq(decision.reason, "full_map_empty", "mapping_error preserved")
    local no_inverse = SIM.compute_inverse_decision(position{}, {}, nil, 0.5, false)
    B.eq(no_inverse.reason, "inverse_position_unavailable")
end

function T.test_compute_decision_chapter_mismatch()
    local decision = SIM.compute_inverse_decision(position{}, {}, inverse{ chapter_uid = "u9" }, 0.5, false)
    B.eq(decision.action, "source")
    B.eq(decision.reason, "inverse_chapter_mismatch")
    B.eq(decision.inverse_chapter_uid, "u9")
    B.eq(decision.source_uid, "u1")
    B.eq(decision.anchors.source_anchor_offset, 10)
    B.eq(decision.anchors.inverse_offset, 80)
    B.eq(decision.anchors.inverse_delta, 70, "80 - 10")
    B.eq(decision.anchors.local_global_ratio, 0.5)
end

function T.test_compute_decision_inverse_offset_missing()
    local inv = inverse()
    inv.chapter_offset = nil
    local decision = SIM.compute_inverse_decision(position{}, {}, inv, 0.5, false)
    B.eq(decision.action, "source")
    B.eq(decision.reason, "inverse_offset_missing")
    B.eq(decision.anchors.inverse_offset, nil)
end

function T.test_compute_decision_native_and_inverse()
    local native = SIM.compute_inverse_decision(position{}, {}, inverse{}, 0.5, true)
    B.eq(native.action, "native")
    local plain = SIM.compute_inverse_decision(position{}, {}, inverse{}, 0.5, false)
    B.eq(plain.action, "inverse")
    local non_native_position = SIM.compute_inverse_decision(position{ native_offset = false }, {}, inverse{}, 0.5, false)
    B.eq(non_native_position.action, "inverse")
end

function T.test_merge_inverse_branch()
    local p = position{ native_offset = false }
    p.local_global_ratio = 0.5
    p.inverse_delta = 70
    local out = SIM.merge_inverse_into_position(p, inverse{}, false, { book_id = "b1", ratio_source = "footer_page_ratio" })
    B.eq(out, p, "merge mutates and returns the position")
    B.eq(out.offset, 80)
    B.eq(out.chapter_offset, 80)
    B.eq(out.progress, 55)
    B.eq(out.chapter_word_count, 200)
    B.eq(out.total_word_count, 1000)
    B.eq(out.words_before, 800)
    B.eq(out.chapter_ratio, 0.4, "80/200")
    B.eq(out.chapter_percent, 40)
    B.eq(out.source, "inverse_cloud_map")
    B.eq(out.position_basis, "inverse_remote_chapter_offset")
    B.eq(out.offset_basis, "inverse_remote_chapter_offset")
    B.eq(out.native_offset, false)
    B.eq(out.inverse_mapping_used, true)
end

function T.test_merge_native_branch()
    local p = position{ native_offset = true }
    p.source_word_offset = 9
    p.local_global_ratio = 0.5
    local out = SIM.merge_inverse_into_position(p, inverse{}, true, { book_id = "b1", ratio_source = "xpointer_doc_pos" })
    B.eq(out, p)
    B.eq(out.inverse_mapping_used, true)
    B.eq(out.inverse_mapping_role, "progress_only")
    B.eq(out.progress, 55)
    B.eq(out.chapter_offset, 10, "native co untouched")
    B.eq(out.chapter_word_count, 200)
    B.eq(out.total_word_count, 1000)
    B.eq(out.words_before, 800)
    B.eq(out.source, nil, "source field untouched on the native branch")
    B.eq(out.chapter_ratio, 0.1, "chapter ratio untouched on the native branch")
end

return T
