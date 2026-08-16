-- Pure decision logic for MiuRead progress sync.
--
-- plugin_sync keeps the UI and the sync service orchestration; this module
-- owns the rules that decide whether two positions match, what failure state
-- an upload lands in, and whether the local/remote positions are aligned.
-- No KOReader runtime, network or UI dependencies: fully testable.

local ProgressDecision = {}

-- Mirrors plugin_sync:_remote_matches. `threshold` is injected by the caller
-- instead of being read from store preferences.
function ProgressDecision.remote_matches(remote, target, threshold)
    threshold = tonumber(threshold) or 2
    if not remote then return false, nil, nil end
    local target_position = type(target) == "table" and target or nil
    local target_percent = target_position and tonumber(target_position.progress) or tonumber(target)
    if target_percent == nil then return false, nil, nil end
    local target_uid = target_position and tostring(target_position.chapter_uid or target_position.chapterUid or "") or ""
    local target_co = target_position and tonumber(target_position.chapter_offset or target_position.offset)
    local chapter_words = target_position and tonumber(target_position.chapter_word_count) or 0
    local co_tolerance = math.max(12, math.floor((chapter_words or 0) * 0.005))

    local function match(candidate)
        if not candidate then return false, nil, nil end
        local percent = tonumber(candidate.percent)
        local candidate_uid = tostring(candidate.chapter_uid or candidate.chapterUid or "")
        local candidate_co = tonumber(candidate.offset or candidate.chapter_offset)
        if target_uid ~= "" and candidate_uid ~= "" and target_uid ~= candidate_uid then
            return false, percent, candidate.source, { reason = "chapter_uid_mismatch" }
        end
        if target_co ~= nil and candidate_co ~= nil and target_uid ~= "" and candidate_uid ~= "" then
            local delta = math.abs(candidate_co - target_co)
            if delta <= co_tolerance then
                return true, percent, candidate.source, { co_delta = delta, co_tolerance = co_tolerance }
            end
            return false, percent, candidate.source, {
                reason = "chapter_offset_mismatch", co_delta = delta, co_tolerance = co_tolerance,
            }
        end
        return percent and math.abs(percent - target_percent) <= threshold,
            percent, candidate.source, { reason = "percent_fallback" }
    end

    if remote.conflict then
        local ok, pct, source, meta = match(remote.web)
        if ok then return true, pct, source, meta end
        ok, pct, source, meta = match(remote.agent)
        if ok then return true, pct, source, meta end
        return false, nil, nil, meta
    end
    return match(remote)
end

-- Classifies a failed progress upload from the session + sync state.
-- Returns repair, kind, state exactly as plugin_sync decides it.
function ProgressDecision.upload_failure(session, sync_last_error_kind)
    session = type(session) == "table" and session or {}
    local repair = session.sync_repair_required == true
        and (tostring(session.sync_repair_kind or "") == "context"
            or tostring(session.sync_repair_kind or "") == "position")
    local kind = tostring(session.last_error_kind or sync_last_error_kind or "")
    local state = (kind == "transport" or kind == "server" or kind == "unconfirmed")
        and "upload_unconfirmed" or "upload_failed"
    return repair, kind, state
end

-- Classifies the local/remote progress comparison used by sync:compare.
-- Returns "unknown"|"same"|"remote_ahead"|"local_ahead".
function ProgressDecision.compare(local_percent, remote, threshold)
    if not remote then return "unknown" end
    local delta = (tonumber(remote.percent) or 0) - (tonumber(local_percent) or 0)
    threshold = tonumber(threshold) or 2
    if math.abs(delta) <= threshold then return "same" end
    return delta > 0 and "remote_ahead" or "local_ahead"
end

-- Decides whether the local position and the fetched remote position are
-- aligned. Returns action ("aligned"|"different"), coordinate_match,
-- remote percent, matched remote percent, source and match metadata.
function ProgressDecision.resolve_alignment(local_position, remote, cmp, threshold)
    local coordinate_match, matched_percent, source, meta =
        ProgressDecision.remote_matches(remote, local_position, threshold)
    local remotep = math.floor((tonumber(remote and remote.percent) or 0) + .5)
    if coordinate_match or cmp == "same" then
        return "aligned", coordinate_match, remotep, matched_percent, source, meta
    end
    return "different", coordinate_match, remotep, matched_percent, source, meta
end

-- Applies the automatic progress-conflict policy. The default "auto_cloud"
-- mode silently adopts the cloud position whenever a conflict can be
-- resolved without asking; "ask" keeps the interactive prompt.
-- Returns should_adopt, remote_percent.
function ProgressDecision.conflict_policy(mode, cmp, remote)
    if mode ~= "auto_cloud" or cmp == "same" then return false end
    local remotep = tonumber(remote and remote.percent)
    if remotep == nil then return false end
    return true, remotep
end

return ProgressDecision
