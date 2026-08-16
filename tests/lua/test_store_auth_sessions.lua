local B = require("tests.lua.bootstrap")

local StoreAuth = require("miuread.store_auth")
local StoreSessions = require("miuread.store_sessions")

local T = {}

local function fake_db()
    local db = { values = {} }
    function db:readSetting(key, fallback)
        local value = self.values[key]
        return value == nil and fallback or value
    end
    function db:saveSetting(key, value) self.values[key] = value end
    return db
end

local function fake_store()
    local store = { db = fake_db(), _shelf_cache = { books = { 1 }, mp = { 2 }, updated_at = 3 } }
    setmetatable(store, {
        __index = function(_, key)
            return StoreAuth[key] or StoreSessions[key]
        end,
    })
    function store:get(key, fallback) return self.db:readSetting(key, fallback) end
    function store:set(key, value) self.db:saveSetting(key, value) end
    function store:flush() end
    function store:shelf_cache() return self._shelf_cache end
    function store:save_shelf_cache(value) self._shelf_cache = value end
    return store
end

function T.test_auth_sanitizes_mp_fields()
    local store = fake_store()
    store:save_auth({ api_key = "k", mp_cookie_header = "secret", cookies = { a = 1 } })
    local auth = store:auth()
    B.eq(auth.api_key, "k")
    B.ok(auth.mp_cookie_header == nil, "mp cookie header stripped")
    B.ok(auth.mp_extra_headers == nil)
    B.eq(auth.health.state, "unknown", "defaults merged")
end

function T.test_ensure_login_session_id()
    local store = fake_store()
    B.eq(store:generate_login_session_id() ~= "", true, "id generated")
    store:save_auth({ login_session_id = "", api_key = "k", cookies = { a = 1 }, account = { vid = "v1" } })
    local id = store:ensure_login_session_id()
    B.ok(id ~= "", "id created for logged-in account")
    B.eq(store:ensure_login_session_id(), id, "id stable across calls")
end

function T.test_auth_health_update_and_clear()
    local store = fake_store()
    local health = store:update_auth_health({ state = "ok", notice_pending = true })
    B.eq(health.state, "ok")
    B.eq(store:auth_health().notice_pending, true)
    store:clear_auth()
    B.eq(store:auth().api_key, "", "auth reset to defaults")
    store:clear_account_shelf_cache()
    B.ok(next(store:shelf_cache().books) == nil, "shelf cache cleared")
end

function T.test_sessions_helpers()
    local sessions = { b1 = { legacy_report_context = 1, pending_report_seconds = 5 } }
    local cleaned, changed = StoreSessions.invalidate_report_contexts_table(sessions)
    B.ok(changed > 0, "changed counted")
    B.ok(cleaned.b1.legacy_report_context == nil)
    B.eq(cleaned.b1.pending_report_seconds, 0)

    local auth = StoreSessions.invalidate_upload_health_table({ api_key = "k", cookies = { a = 1 } })
    B.eq(auth.health.notice_pending, false)
    B.eq(auth.health.channels.progress.state, "unknown", "progress channel reset")
end

function T.test_save_and_invalidate_book_context()
    local store = fake_store()
    store:save_session("b1", { progress_sync_state = "aligned" })
    B.eq(store:session("b1").progress_sync_state, "aligned")
    local ok, row = store:invalidate_book_sync_context("b1", "test", "hash1")
    B.eq(ok, true)
    B.eq(row.book_core_map_hash, "hash1")
    B.ok(row.sync_context_invalidated_at > 0)
    store:clear_session("b1")
    B.ok(store:session("b1") == nil, "session cleared")
end

function T.test_clear_login_bound_sessions_integration()
    local store = fake_store()
    store:save_session("b1", { report_context = "ctx", pending_report_seconds = 12 })
    local changed = store:clear_login_bound_sessions("test")
    B.ok(changed > 0)
    B.ok(store:session("b1").report_context == nil)
    B.eq(store:session("b1").pending_report_seconds, 0)
end

return T
