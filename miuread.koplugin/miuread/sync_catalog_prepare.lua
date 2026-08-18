-- Catalog-preparation deep module, extracted from sync.lua.
--
-- MiuRead 4.6.2 moved the pure input snapshoting, worker selection, legacy
-- context merging, verified-session drift detection and the cookies
-- write-back out of Sync:_prepare_progress_catalog so they are independently
-- unit-testable. sync.lua keeps the worker:run() orchestration and the
-- callback assembly; every decision here is injectable and never touches
-- self.

local U = require("miuread.util")
local BookIntegrity = require("miuread.book_integrity")
local ProgressPosition = require("miuread.progress_position")
local logger = require("logger")

local map_position = ProgressPosition.map_position
local local_chapter_by_uid = ProgressPosition.local_chapter_by_uid

local M = {}

-- Snapshot the record and host state that _prepare_progress_catalog needs.
-- host_state carries everything owned by the Sync instance: auth, session,
-- core_map_hash, local_ratio and record_generation. Returns the input table
-- (plus saved/auth for the caller), or nil + the exact early-return error
-- code ("position_context_missing" / "book_id_missing" / "authentication_required").
local function prepare_catalog_input(record, host_state)
    if type(record) ~= "table" then return nil, "position_context_missing" end
    local book_id = tostring(record.book and record.book.book_id or "")
    if book_id == "" then return nil, "book_id_missing" end
    host_state = type(host_state) == "table" and host_state or {}
    local auth = type(host_state.auth) == "table" and host_state.auth or {}
    local account = type(auth.account) == "table" and auth.account or {}
    local login_snapshot = tostring(auth.login_session_id or "")
    local vid_snapshot = tostring(account.vid or "")
    if login_snapshot == "" or vid_snapshot == "" then return nil, "authentication_required" end
    local core_hash = tostring(host_state.core_map_hash or "")
    local session = type(host_state.session) == "table" and host_state.session or {}
    local saved = type(session.legacy_report_context) == "table" and session.legacy_report_context or nil
    local context_matches = saved ~= nil
        and tostring(session.report_login_session_id or "") == login_snapshot
        and (tostring(session.report_core_map_hash or "") == ""
            or tostring(session.report_core_map_hash or "") == tostring(core_hash or ""))
    local ratio = host_state.local_ratio
    local record_record = type(record.record) == "table" and record.record or {}
    local local_map = type(record_record.chapter_map) == "table" and record_record.chapter_map or {}
    local local_guess = map_position(local_map, ratio or 0, {
        chapter_uid = record_record.chapter_uid,
        summary = record.book and record.book.title or "",
    })
    local legacy_book = M.merge_legacy_context(context_matches and saved or nil, record, record_record, local_guess)
    return {
        book_id = book_id,
        login_snapshot = login_snapshot,
        vid_snapshot = vid_snapshot,
        core_hash = core_hash,
        legacy_book = legacy_book,
        local_guess = local_guess,
        ratio_snapshot = ratio or 0,
        book_title = tostring(record.book and record.book.title or ""),
        generation = tonumber(host_state.record_generation or 0) or 0,
        path = tostring(record.path or ""),
        session = session,
        saved = saved,
        auth = auth,
    }
end

-- Pure worker-choice decision: prefer the identity worker, fall back to the
-- async worker, and otherwise report the exact busy/unavailable reason.
-- Returns { worker = w } or { reason_if_busy = "catalog_worker_busy" |
-- "catalog_worker_unavailable" }.
local function select_catalog_worker(identity_async, async)
    local function available(worker)
        return type(worker) == "table"
            and type(worker.available) == "function" and worker:available()
            and not (type(worker.busy) == "function" and worker:busy())
    end
    if available(identity_async) then return { worker = identity_async } end
    if available(async) then return { worker = async } end
    local busy = (type(identity_async) == "table" and type(identity_async.busy) == "function" and identity_async:busy())
        or (type(async) == "table" and type(async.busy) == "function" and async:busy())
    if busy then return { reason_if_busy = "catalog_worker_busy" } end
    return { reason_if_busy = "catalog_worker_unavailable" }
end

-- Pure data merge of the saved legacy context with the current record data.
-- The optional local_guess (map_position over the local chapter map, computed
-- by prepare_catalog_input) seeds the worker's reader-chapter hint fields.
-- Never calls a worker and never touches self.
local function merge_legacy_context(saved_legacy_book, record, record_record, local_guess)
    record = type(record) == "table" and record or {}
    record_record = type(record_record) == "table" and record_record or {}
    local legacy_book = U.copy(type(saved_legacy_book) == "table" and saved_legacy_book or {})
    legacy_book.book_id = tostring(record.book and record.book.book_id or legacy_book.book_id or "")
    legacy_book.title = (record.book and record.book.title) or legacy_book.title
    if type(local_guess) == "table" then
        legacy_book.local_chapter_uid = local_guess.chapter_uid
        legacy_book.local_chapter_idx = local_guess.chapter_index
        legacy_book.local_chapter_offset = local_guess.offset
        legacy_book.local_native_chapter_offset = false
        legacy_book.local_chapter_offset_basis = "catalog_word_fallback"
        local row = local_chapter_by_uid(
            type(record_record.chapter_map) == "table" and record_record.chapter_map or {},
            local_guess.chapter_uid)
        legacy_book.local_chapter_word_count = tonumber(row and (row.word_count or row.wordCount) or 0) or 0
    end
    return legacy_book
end

-- Verified-session drift guard: while a saved context is still within the
-- verification TTL, a structurally different fresh catalog must not silently
-- change the whole-book percentage basis. Returns the replacement context
-- (a copy of the saved one, re-tagged with the current core hash) when drift
-- is detected, otherwise nil. now is injectable for tests.
local function detect_catalog_drift(session, context, core_hash, verification_ttl, book_id, now)
    session = type(session) == "table" and session or {}
    if type(context) ~= "table" or type(context.chapters) ~= "table" then return nil end
    local saved = type(session.legacy_report_context) == "table" and session.legacy_report_context or nil
    local verified_at = tonumber(session.verified_at or 0) or 0
    local age = (tonumber(now) or os.time()) - verified_at
    local saved_verified = session.remote_verified == true
        and verified_at > 0 and age >= 0 and age <= (tonumber(verification_ttl) or 14400)
        and type(saved) == "table" and saved.catalog_complete == true
        and type(saved.chapters) == "table" and #saved.chapters > 0
    if not saved_verified then return nil end
    book_id = tostring(book_id or "")
    local saved_hash = BookIntegrity.core_map_hash(book_id, saved.chapters, {})
    local new_hash = BookIntegrity.core_map_hash(book_id, context.chapters, {})
    if saved_hash == "" or new_hash == "" or saved_hash == new_hash then return nil end
    logger.warn("[MiuRead][ProgressMap] catalog drift ignored during verified session",
        "book=", book_id, "kept=", tostring(#saved.chapters),
        "new=", tostring(#context.chapters))
    local kept = U.copy(saved)
    kept.core_map_hash = core_hash
    return kept
end

-- Single place for the cookies write-back side effect after a successful
-- context fetch. Re-reads the live auth from the store (like the original
-- callback) and persists only when cookies actually changed. Returns true
-- when a change was applied.
local function apply_cookies_change(store, auth, value)
    if type(value) ~= "table" or value.cookies_changed ~= true or type(value.cookies) ~= "table" then
        return false
    end
    local latest_auth
    if type(store) == "table" and type(store.auth) == "function" then
        latest_auth = store:auth()
    else
        latest_auth = type(auth) == "table" and auth or nil
    end
    if type(latest_auth) ~= "table" then return false end
    latest_auth.cookies = value.cookies
    if value.wr_ticket_changed then latest_auth.wr_ticket = value.wr_ticket end
    if value.wr_wrpa_changed then latest_auth.wr_wrpa = value.wr_wrpa end
    if type(store) == "table" and type(store.save_auth) == "function" then
        store:save_auth(latest_auth)
    end
    return true
end

M.prepare_catalog_input = prepare_catalog_input
M.select_catalog_worker = select_catalog_worker
M.merge_legacy_context = merge_legacy_context
M.detect_catalog_drift = detect_catalog_drift
M.apply_cookies_change = apply_cookies_change

return M
