local B = require("tests.lua.bootstrap")

local fake_database = {}

-- Fake DownloadDatabase before store_downloads captures its require. Other
-- suites (progress_position -> book_integrity) may have loaded the real
-- module, so clear the cache for this isolated reader test.
local saved_download_database = package.loaded["miuread.download_database"]
package.loaded["miuread.download_database"] = nil
package.loaded["miuread.store_downloads"] = nil
package.preload["miuread.download_database"] = function() return fake_database end

local StoreDownloads = require("miuread.store_downloads")

local T = {}

local function fake_store()
    local store = { data_dir = "/tmp/miu-test", _legacy = {} }
    setmetatable(store, { __index = StoreDownloads })
    function store:download_database_state() return self._state or {} end
    function store:download_database_queue() return self._queue or {} end
    function store:get(key, fallback) return self._legacy[key] or fallback end
    function store:set(key, value) self._legacy[key] = value end
    return store
end

function fake_database.get_download_state(store)
    return store:download_database_state()
end
function fake_database.set_download_state(store, value)
    store._state = value
    return true
end
function fake_database.clear_download_state(store)
    store._state = {}
    return true
end
function fake_database.get_download_queue(store)
    return store:download_database_queue()
end
function fake_database.set_download_queue(store, value)
    store._queue = value
    return true
end

function T.test_state_roundtrip()
    local store = fake_store()
    B.ok(next(StoreDownloads.download_state(store)) == nil, "empty state defaults")
    StoreDownloads.save_download_state(store, { status = "active", percent = 0.5 })
    B.eq(StoreDownloads.download_state(store).status, "active")
    StoreDownloads.clear_download_state(store)
    B.ok(next(StoreDownloads.download_state(store)) == nil, "cleared")
end

function T.test_queue_caps_to_one()
    local store = fake_store()
    store._queue = { { book = { bookId = "1" } }, { book = { bookId = "2" } } }
    local queue = StoreDownloads.download_queue(store)
    B.eq(#queue, 1, "queue capped at one entry")
    B.eq(queue[1].book.bookId, "1")
    StoreDownloads.save_download_queue(store, { { book = { bookId = "3" } }, { book = { bookId = "4" } } })
    B.eq(#store._queue, 1, "save keeps only first entry")
end

function T.test_queue_migrates_legacy()
    local store = fake_store()
    store._legacy = { download_queue = { { key = "legacy" } } }
    local queue = StoreDownloads.download_queue(store)
    B.eq(queue[1].key, "legacy", "legacy queue adopted")
    B.ok(store._queue ~= nil, "legacy copied into database")
end

function T.test_enqueue_dequeue_remove()
    local store = fake_store()
    B.eq(StoreDownloads.enqueue_download(store, { key = "a" }), 1)
    local position, reason = StoreDownloads.enqueue_download(store, { key = "b" })
    B.eq(position, nil, "second job rejected")
    B.eq(reason, "full")
    local job = StoreDownloads.dequeue_download(store)
    B.eq(job.key, "a")
    B.ok(StoreDownloads.dequeue_download(store) == nil, "empty dequeue")
    StoreDownloads.enqueue_download(store, { key = "c" })
    B.eq(StoreDownloads.remove_queued_download(store, 1), true)
    B.eq(StoreDownloads.remove_queued_download(store, 9), false, "bad index rejected")
end

function T.test_z_restore_download_database()
    package.preload["miuread.download_database"] = nil
    package.loaded["miuread.download_database"] = saved_download_database
end

return T
