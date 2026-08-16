local B = require("tests.lua.bootstrap")

local StoreMeta = require("miuread.store_meta")

local T = {}

local function fake_store()
    local store = { values = {}, covers_dir = "/tmp/covers", saved_sessions = {} }
    setmetatable(store, { __index = StoreMeta })
    function store:get(key, fallback)
        local value = self.values[key]
        return value == nil and fallback or value
    end
    function store:set(key, value) self.values[key] = value end
    function store:set_deferred(key, value) self.values[key] = value end
    function store:flush() end
    function store:save_session(id, patch) self.saved_sessions[id] = patch end
    return store
end

function T.test_shelf_cache_and_progress()
    local store = fake_store()
    local cache = store:shelf_cache()
    B.eq(cache.updated_at, 0, "shelf defaults merged")
    store:save_shelf_cache({ books = { { bookId = "b1", progress = 10 } } })
    B.eq(store:update_cached_progress("b1", 150), true)
    B.eq(store:shelf_cache().books[1].progress, 100, "clamped to 100")
    B.eq(store:shelf_cache().books[1].finished, true)
end

function T.test_cover_guard_and_paths()
    local store = fake_store()
    B.eq(store:cover_guard().active, false, "cover guard defaults")
    store:save_cover_guard({ active = true })
    B.eq(store:cover_guard().active, true)
    B.eq(store:cover_path("b 1"), "/tmp/covers/b_1.img", "id-safe cover path")
    store:save_update_state({ version = "x" })
    B.eq(store:update_state().version, "x")
end

function T.test_recent_reads_and_mark_last_read()
    local store = fake_store()
    store:record_recent_read("b1", "/tmp/b1.epub", 1000)
    store:record_recent_read("b2", "/tmp/b2.epub", 2000)
    local reads = store:recent_reads()
    B.eq(#reads.items, 2)
    B.eq(reads.items[1].book_id, "b2", "newest first")
    B.eq(store.saved_sessions.b2.last_read_at, 2000, "mark_last_read via session")
    store:record_recent_read("b1", "/tmp/b1.epub", 3000)
    B.eq(#store:recent_reads().items, 2, "duplicate book replaced, not appended")
end

return T
