local B = require("tests.lua.bootstrap")
local PD = require("miuread.progress_decision")

local T = {}

function T.test_remote_matches_percent_fallback()
    local matched, percent = PD.remote_matches({ percent = 50 }, { progress = 51 }, 2)
    B.eq(matched, true, "within threshold")
    B.eq(percent, 50, "remote percent returned")
    matched = PD.remote_matches({ percent = 53 }, { progress = 50 }, 2)
    B.eq(matched, false, "outside threshold")
end

function T.test_remote_matches_chapter_offset()
    local target = { progress = 40, chapter_uid = "u1", chapter_offset = 1000, chapter_word_count = 5000 }
    local matched, percent, source, meta = PD.remote_matches(
        { percent = 41, chapter_uid = "u1", offset = 1010, source = "agent_gateway" },
        target, 2)
    B.eq(matched, true, "offset within tolerance")
    B.eq(source, "agent_gateway")
    B.ok(meta.co_delta <= meta.co_tolerance, "delta reported")
    matched = PD.remote_matches({ chapter_uid = "u2", offset = 1000 }, target, 2)
    B.eq(matched, false, "different chapter rejected")
end

function T.test_remote_matches_conflict_sources()
    local target = { progress = 20, chapter_uid = "u1", chapter_offset = 500, chapter_word_count = 3000 }
    local remote = { conflict = true,
        web = { percent = 21, chapter_uid = "u1", offset = 510, source = "web_cookie" },
        agent = { percent = 80, chapter_uid = "u9", offset = 10, source = "agent_gateway" } }
    local matched, percent, source = PD.remote_matches(remote, target, 2)
    B.eq(matched, true, "web source wins")
    B.eq(source, "web_cookie")
    remote.web = { percent = 21, chapter_uid = "u9", offset = 520, source = "web_cookie" }
    matched, percent, source = PD.remote_matches(remote, target, 2)
    B.eq(matched, false, "both conflict sources mismatch")
end

function T.test_upload_failure_classification()
    local repair, kind, state = PD.upload_failure(
        { sync_repair_required = true, sync_repair_kind = "context", last_error_kind = "transport" }, "")
    B.eq(repair, true, "repair detected")
    B.eq(kind, "transport")
    B.eq(state, "upload_unconfirmed", "transport falls to unconfirmed")
    repair, kind, state = PD.upload_failure(
        { sync_repair_kind = "position", last_error_kind = "authentication" }, nil)
    B.eq(repair, false, "no repair without flag")
    B.eq(state, "upload_failed", "authentication is failed")
    repair, kind, state = PD.upload_failure(nil, "server")
    B.eq(state, "upload_unconfirmed", "sync-level server error")
end

function T.test_resolve_alignment()
    local local_position = { progress = 40, chapter_uid = "u1", chapter_offset = 1000, chapter_word_count = 5000 }
    local remote = { percent = 41, chapter_uid = "u1", offset = 1010 }
    local action, coordinate_match, remotep = PD.resolve_alignment(local_position, remote, "different", 2)
    B.eq(action, "aligned", "coordinate match wins over compare")
    B.eq(coordinate_match, true)
    B.eq(remotep, 41)
    remote = { percent = 45 }
    action, coordinate_match = PD.resolve_alignment({ progress = 40 }, remote, "same", 2)
    B.eq(action, "aligned", "compare same wins")
    B.eq(coordinate_match, false, "no coordinate match")
    remote = { percent = 80 }
    action = PD.resolve_alignment({ progress = 40 }, remote, "different", 2)
    B.eq(action, "different", "both disagree")
end

function T.test_compare_classification()
    B.eq(PD.compare(50, nil, 2), "unknown", "missing remote")
    B.eq(PD.compare(50, { percent = 51 }, 2), "same", "within threshold")
    B.eq(PD.compare(50, { percent = 53 }, 2), "remote_ahead")
    B.eq(PD.compare(50, { percent = 47 }, 2), "local_ahead")
    B.eq(PD.compare(50, { percent = 53 }, 5), "same", "larger threshold")
end

function T.test_conflict_policy()
    local should_adopt, percent = PD.conflict_policy("auto_cloud", "remote_ahead", { percent = 80 })
    B.eq(should_adopt, true, "auto_cloud adopts remote_ahead")
    B.eq(percent, 80)
    should_adopt = PD.conflict_policy("auto_cloud", "local_ahead", { percent = 40 })
    B.eq(should_adopt, true, "auto_cloud adopts even when local is ahead")
    should_adopt = PD.conflict_policy("ask", "remote_ahead", { percent = 80 })
    B.eq(should_adopt, false, "ask keeps the prompt")
    should_adopt = PD.conflict_policy("auto_cloud", "same", { percent = 80 })
    B.eq(should_adopt, false, "aligned positions never need policy")
    should_adopt = PD.conflict_policy("auto_cloud", "remote_ahead", nil)
    B.eq(should_adopt, false, "missing remote never auto-adopts")
    should_adopt = PD.conflict_policy("bogus", "remote_ahead", { percent = 80 })
    B.eq(should_adopt, false, "unknown mode falls back to ask")
end

function T.test_choose_source_prefers_newer()
    local web = { percent = 40, updated_at = 100, source = "web_cookie" }
    local agent = { percent = 80, updated_at = 200, source = "agent_gateway" }
    B.eq(PD.choose_source(web, agent), agent, "newer agent wins")
    agent.updated_at = 50
    B.eq(PD.choose_source(web, agent), web, "newer web wins")
end

function T.test_choose_source_tie_prefers_official()
    local web = { percent = 40, updated_at = 100, source = "web_cookie" }
    local agent = { percent = 80, updated_at = 100, source = "agent_gateway" }
    B.eq(PD.choose_source(web, agent), agent, "equal timestamps prefer official gateway")
    web.updated_at = nil
    agent.updated_at = nil
    B.eq(PD.choose_source(web, agent), agent, "missing timestamps prefer official gateway")
end

function T.test_choose_source_missing_side()
    local agent = { percent = 50 }
    B.eq(PD.choose_source(nil, agent), agent, "nil web returns agent")
    local web = { percent = 50 }
    B.eq(PD.choose_source(web, nil), web, "nil agent returns web")
    B.eq(PD.choose_source(nil, nil), nil, "both nil returns nil")
end

return T
