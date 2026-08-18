local B = require("tests.lua.bootstrap")
local SCP = require("miuread.sync_catalog_prepare")

local T = {}

local function fake_worker(available, busy)
    return {
        available = function() return available end,
        busy = function() return busy end,
    }
end

local function record_with(book, row, path)
    return { book = book, record = row, path = path or "/tmp/book.epub" }
end

local MAP = {
    { uid = "u1", title = "C1", word_count = 10, index = 1 },
    { uid = "u2", title = "C2", word_count = 20, index = 2 },
}

local function valid_host(overrides)
    local host = {
        auth = { login_session_id = "login-1", account = { vid = "v1" } },
        session = {},
        core_map_hash = "core-1",
        local_ratio = 0.5,
        record_generation = 7,
    }
    if overrides then
        for key, value in pairs(overrides) do host[key] = value end
    end
    return host
end

function T.test_select_worker_prefers_identity_async()
    local identity = fake_worker(true, false)
    local async = fake_worker(true, false)
    local chosen = SCP.select_catalog_worker(identity, async)
    B.eq(chosen.worker, identity, "identity worker must win")
    B.eq(chosen.reason_if_busy, nil)
end

function T.test_select_worker_falls_back_and_reports_busy()
    local async = fake_worker(true, false)
    local fallback = SCP.select_catalog_worker(fake_worker(false, true), async)
    B.eq(fallback.worker, async, "falls back to the async worker")
    local busy = SCP.select_catalog_worker(fake_worker(false, true), fake_worker(false, true))
    B.eq(busy.worker, nil)
    B.eq(busy.reason_if_busy, "catalog_worker_busy")
    local none = SCP.select_catalog_worker(nil, nil)
    B.eq(none.worker, nil)
    B.eq(none.reason_if_busy, "catalog_worker_unavailable")
end

function T.test_detect_drift_keeps_saved_verified_catalog()
    local saved = {
        catalog_complete = true,
        chapters = { { uid = "a", word_count = 10 }, { uid = "b", word_count = 20 } },
    }
    local session = { legacy_report_context = saved, remote_verified = true, verified_at = 1000 }
    local fresh = { catalog_complete = true, chapters = { { uid = "x", word_count = 30 } } }
    local kept = SCP.detect_catalog_drift(session, fresh, "core-new", 14400, "b1", 2000)
    B.ok(kept ~= nil, "structural drift inside the TTL must keep the saved catalog")
    B.eq(#kept.chapters, 2, "saved chapters kept")
    B.eq(kept.chapters[1].uid, "a")
    B.eq(kept.core_map_hash, "core-new", "replacement re-tagged with the current core hash")
end

function T.test_detect_drift_ignores_unverified_expired_or_same()
    local saved = { catalog_complete = true, chapters = { { uid = "a", word_count = 10 } } }
    local session = { legacy_report_context = saved, remote_verified = true, verified_at = 1000 }
    local fresh = { catalog_complete = true, chapters = { { uid = "b", word_count = 20 } } }
    B.eq(SCP.detect_catalog_drift(session, fresh, "h", 10, "b1", 2000), nil, "expired TTL must not keep")
    local unverified = { legacy_report_context = saved, remote_verified = false, verified_at = 1000 }
    B.eq(SCP.detect_catalog_drift(unverified, fresh, "h", 14400, "b1", 2000), nil, "not verified must not keep")
    local same = { catalog_complete = true, chapters = { { uid = "a", word_count = 10 } } }
    B.eq(SCP.detect_catalog_drift(session, same, "h", 14400, "b1", 2000), nil, "identical catalog has no drift")
end

function T.test_apply_cookies_change_writes_back_once()
    local saved_auth = { cookies = { old = 1 }, wr_ticket = "t0" }
    local calls = {}
    local store = {
        auth = function() return saved_auth end,
        save_auth = function(_, auth) calls[#calls + 1] = auth end,
    }
    local applied = SCP.apply_cookies_change(store, saved_auth, {
        cookies_changed = true,
        cookies = { wr_vid = "v2" },
        wr_ticket_changed = true,
        wr_ticket = "t2",
    })
    B.eq(applied, true)
    B.eq(#calls, 1, "exactly one save_auth")
    B.eq(calls[1].cookies.wr_vid, "v2")
    B.eq(calls[1].wr_ticket, "t2")
    B.eq(calls[1].wr_wrpa, nil, "wr_wrpa untouched when not flagged")
    B.eq(SCP.apply_cookies_change(store, saved_auth, { cookies_changed = false }), false)
    B.eq(#calls, 1, "no extra save when cookies did not change")
end

function T.test_prepare_catalog_input_validation()
    local input, err = SCP.prepare_catalog_input(nil, {})
    B.eq(input, nil)
    B.eq(err, "position_context_missing")
    local no_book = record_with({ book_id = "", title = "X" }, { chapter_map = {} })
    local input2, err2 = SCP.prepare_catalog_input(no_book, valid_host())
    B.eq(input2, nil)
    B.eq(err2, "book_id_missing")
    local host = valid_host{ auth = { login_session_id = "", account = { vid = "v1" } } }
    local input3, err3 = SCP.prepare_catalog_input(record_with({ book_id = "b1", title = "X" }, { chapter_map = {} }), host)
    B.eq(input3, nil)
    B.eq(err3, "authentication_required")
end

function T.test_prepare_catalog_input_snapshots_and_drops_stale_context()
    local stale_saved = { chapters = { { uid = "old" } }, catalog_complete = true }
    local record = record_with({ book_id = "b1", title = "Book" },
        { chapter_map = MAP, chapter_uid = "u1" }, "/p.epub")
    local host = valid_host{
        auth = { login_session_id = "login-2", account = { vid = "v2" } },
        session = { legacy_report_context = stale_saved, report_login_session_id = "login-1" },
    }
    local input, err = SCP.prepare_catalog_input(record, host)
    B.ok(input ~= nil, "valid input must pass")
    B.eq(err, nil)
    B.eq(input.book_id, "b1")
    B.eq(input.login_snapshot, "login-2")
    B.eq(input.vid_snapshot, "v2")
    B.eq(input.core_hash, "core-1")
    B.eq(input.generation, 7)
    B.eq(input.path, "/p.epub")
    B.eq(input.ratio_snapshot, 0.5)
    B.eq(input.book_title, "Book")
    B.eq(input.session, host.session)
    B.eq(input.saved, stale_saved)
    B.eq(input.legacy_book.chapters, nil, "login-stale saved context must not leak in")
    B.eq(input.legacy_book.book_id, "b1")
    B.eq(input.legacy_book.local_chapter_uid, "u2", "0.5 ratio lands in chapter two")
    B.eq(input.legacy_book.local_chapter_offset, 5, "15/30 words -> offset 5")
    B.eq(input.legacy_book.local_chapter_word_count, 20)
    B.eq(input.legacy_book.local_native_chapter_offset, false)
    B.eq(input.legacy_book.local_chapter_offset_basis, "catalog_word_fallback")
end

function T.test_merge_legacy_context_copies_saved_and_guess()
    local saved = { chapters = { { uid = "old" } }, catalog_complete = true }
    local record = record_with({ book_id = "b1", title = "Book" }, { chapter_map = {} })
    local guess = { chapter_uid = "u9", chapter_index = 3, offset = 42, summary = "X" }
    local merged = SCP.merge_legacy_context(saved, record, record.record, guess)
    B.eq(merged.catalog_complete, true, "saved content copied through")
    B.eq(merged.chapters[1].uid, "old")
    B.eq(merged.book_id, "b1")
    B.eq(merged.title, "Book")
    B.eq(merged.local_chapter_uid, "u9")
    B.eq(merged.local_chapter_idx, 3)
    B.eq(merged.local_chapter_offset, 42)
    B.eq(merged.local_native_chapter_offset, false)
    B.eq(merged.local_chapter_offset_basis, "catalog_word_fallback")
    local bare = SCP.merge_legacy_context(saved, record, record.record)
    B.eq(bare.local_chapter_uid, nil, "no guess means no hint fields")
end

return T
