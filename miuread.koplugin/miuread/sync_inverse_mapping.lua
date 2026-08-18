-- Inverse cloud-mapping decision deep module, extracted from sync.lua.
--
-- Sync:_prefer_inverse_cloud_mapping decides whether a verified local position
-- may be corrected with the whole-book inverse mapping computed from the
-- cloud catalog. This module owns the pure guards, the decision and the field
-- merge; sync.lua keeps the self-owned inputs (local_ratio side effect, the
-- inverse position lookup) and applies the decision to the position table.

local U = require("miuread.util")
local BookIntegrity = require("miuread.book_integrity")
local logger = require("logger")

local M = {}

-- Early guards: returns false, nil when the position/record are unusable
-- (the position stays untouched), false, "local_map_not_full_catalog" when
-- the local chapter map is not a full-catalog equivalent, or true, nil when
-- the inverse mapping may be attempted.
local function should_use_inverse_mapping(record, position, local_map, catalog)
    if type(position) ~= "table" or position.safe ~= true then return false, nil end
    record = type(record) == "table" and record or {}
    if type(record.record) ~= "table" then return false, nil end
    if record.record.partial_range == true
        or not BookIntegrity.maps_equivalent(local_map, catalog) then
        return false, "local_map_not_full_catalog"
    end
    return true, nil
end

-- Main decision: given the already-computed inverse position, classifies the
-- outcome exactly like the original method:
--   source (keep the local position; reason is one of the preserved codes),
--   native (adopt the inverse whole-book percentage only),
--   inverse (adopt the inverse chapter offset + whole-book percentage).
-- The returned table carries the anchors and the log-relevant fields; it is
-- a pure decision and never touches self.
local function compute_inverse_decision(position, record, inverse, ratio, native_offset)
    if ratio == nil then
        return { action = "source", reason = "local_global_ratio_missing" }
    end
    if type(inverse) ~= "table" or inverse.safe ~= true
        or tostring(inverse.chapter_uid or "") == "" then
        return { action = "source", reason = tostring(type(inverse) == "table"
            and inverse.mapping_error or "inverse_position_unavailable") }
    end
    local source_uid = tostring(position and position.chapter_uid or "")
    local inverse_uid = tostring(inverse.chapter_uid or "")
    local source_offset = tonumber(position and (position.chapter_offset or position.offset))
    local inverse_offset = tonumber(inverse.chapter_offset or inverse.offset)
    local anchors = {
        source_anchor_offset = source_offset,
        source_anchor_progress = tonumber(position and position.progress),
        source_anchor_chapter_ratio = tonumber(position and position.chapter_ratio),
        inverse_offset = inverse_offset,
        inverse_progress = tonumber(inverse.progress),
        inverse_delta = source_offset ~= nil and inverse_offset ~= nil
            and (inverse_offset - source_offset) or nil,
        local_global_ratio = U.clamp(tonumber(ratio) or 0, 0, 1),
    }
    if source_uid == "" or inverse_uid == "" or source_uid ~= inverse_uid then
        return {
            action = "source",
            reason = "inverse_chapter_mismatch",
            inverse_chapter_uid = inverse_uid,
            anchors = anchors,
            source_uid = source_uid,
            source_offset = source_offset,
            inverse_offset = inverse_offset,
            native_offset = native_offset == true,
        }
    end
    if inverse_offset == nil then
        return {
            action = "source",
            reason = "inverse_offset_missing",
            anchors = anchors,
            source_uid = source_uid,
            source_offset = source_offset,
            inverse_offset = inverse_offset,
            native_offset = native_offset == true,
        }
    end
    if native_offset == true then
        return {
            action = "native",
            anchors = anchors,
            source_uid = source_uid,
            source_offset = source_offset,
            inverse_offset = inverse_offset,
            native_offset = true,
        }
    end
    return {
        action = "inverse",
        anchors = anchors,
        source_uid = source_uid,
        source_offset = source_offset,
        inverse_offset = inverse_offset,
        native_offset = false,
    }
end

-- Pure field merge for the native ("progress_only") and inverse branches.
-- log_context supplies the self-owned values for the preserved
-- [MiuRead][ProgressOffset] log lines: { book_id = ..., ratio_source = ... }.
local function merge_inverse_into_position(position, inverse, native_offset, log_context)
    if type(position) ~= "table" or type(inverse) ~= "table" then return position end
    local source_uid = tostring(position.chapter_uid or "")
    local source_offset = tonumber(position.chapter_offset or position.offset)
    local inverse_offset = tonumber(inverse.chapter_offset or inverse.offset)
    local ctx = type(log_context) == "table" and log_context or {}
    local book_id = tostring(ctx.book_id or "")
    local ratio_source = tostring(ctx.ratio_source or "-")
    if native_offset == true then
        -- Native co remains untouched. Only the whole-book progress percentage
        -- adopts the continuous inverse whole-book ratio so pr stays aligned
        -- with beta43's long-book precision improvements.
        position.progress = tonumber(inverse.progress) or position.progress
        position.chapter_word_count = tonumber(inverse.chapter_word_count) or position.chapter_word_count
        position.total_word_count = tonumber(inverse.total_word_count) or position.total_word_count
        position.words_before = tonumber(inverse.words_before) or position.words_before
        position.inverse_mapping_used = true
        position.inverse_mapping_role = "progress_only"
        logger.info("[MiuRead][ProgressOffset]",
            "book=", book_id,
            "chapter=", source_uid,
            "native_co=", tostring(source_offset or "-"),
            "source_word_co=", tostring(position.source_word_offset or "-"),
            "inverse_co=", tostring(inverse_offset),
            "global_ratio=", string.format("%.8f", tonumber(position.local_global_ratio) or 0),
            "ratio_source=", ratio_source,
            "selected=native")
        return position
    end
    -- Legacy beta43 fallback: when native source coordinates are unavailable,
    -- retain the proven full-book inverse mapping for chapter offset.
    position.offset = inverse_offset
    position.chapter_offset = inverse_offset
    position.progress = tonumber(inverse.progress) or position.progress
    position.chapter_word_count = tonumber(inverse.chapter_word_count) or position.chapter_word_count
    position.total_word_count = tonumber(inverse.total_word_count) or position.total_word_count
    position.words_before = tonumber(inverse.words_before) or position.words_before
    if tonumber(position.chapter_word_count) and tonumber(position.chapter_word_count) > 0 then
        position.chapter_ratio = U.clamp(inverse_offset / tonumber(position.chapter_word_count), 0, 1)
        position.chapter_percent = math.floor(position.chapter_ratio * 100 + 0.5)
    end
    position.source = "inverse_cloud_map"
    position.position_basis = "inverse_remote_chapter_offset"
    position.offset_basis = "inverse_remote_chapter_offset"
    position.native_offset = false
    position.inverse_mapping_used = true
    logger.info("[MiuRead][ProgressOffset]",
        "book=", book_id,
        "chapter=", source_uid,
        "source_co=", tostring(source_offset or "-"),
        "inverse_co=", tostring(inverse_offset),
        "delta=", tostring(position.inverse_delta or "-"),
        "global_ratio=", string.format("%.8f", tonumber(position.local_global_ratio) or 0),
        "ratio_source=", ratio_source,
        "selected=inverse")
    return position
end

M.should_use_inverse_mapping = should_use_inverse_mapping
M.compute_inverse_decision = compute_inverse_decision
M.merge_inverse_into_position = merge_inverse_into_position

return M
