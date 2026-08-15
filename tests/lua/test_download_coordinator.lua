local B = require("tests.lua.bootstrap")
local Coordinator = require("miuread.download_coordinator")

local T = {}

local function fake_store()
    local store = { state = { status = "idle" }, queue = {} }
    function store:download_state() return self.state end
    function store:save_download_state(value) self.state = value end
    function store:clear_download_state() self.state = { status = "idle" } end
    function store:download_queue() return self.queue end
    function store:save_download_queue(queue) self.queue = queue end
    function store:enqueue_download(job)
        if #self.queue >= 1 then return nil, "full" end
        table.insert(self.queue, job)
        return #self.queue
    end
    function store:dequeue_download() return table.remove(self.queue, 1) end
    function store:remove_queued_download(index) table.remove(self.queue, index) end
    return store
end

local function fake_clock(start)
    local now = start or 1000
    return function()
        return now
    end
end

function T.test_percent_variants()
    local c = Coordinator.new(fake_store(), fake_clock())
    B.eq(c:percent({ percent = 0.5 }), 50, "fraction percent")
    B.eq(c:percent({ percent = 50 }), 50, "percent over 1 treated as 100-scale")
    B.eq(c:percent({ current = 1, total = 3 }), 33, "current/total fallback")
    B.eq(c:percent({ percent = -1 }), 0, "negative clamped")
    B.eq(c:percent({ percent = 2 }), 2, "101-scale percent divided once")
    B.eq(c:percent({ percent = 200 }), 100, "double-oversized clamped to 100")
end

function T.test_active_state_merges_runtime()
    local store = fake_store()
    store.state = { status = "idle", title = "old" }
    local c = Coordinator.new(store)
    local runtime = {
        book = { bookId = "42", title = "new" },
        options = {},
        last_state = { stage = "fetch", current = 1, total = 2, percent = 0.5 },
        background = false,
        started_at = 123,
    }
    local state = c:active_state(runtime, true)
    B.eq(state.status, "active")
    B.eq(state.title, "new")
    B.eq(state.book_id, "42")
    B.eq(state.background, false)
    B.eq(state.stage, "fetch")
    B.ok(c:active_state(runtime, false) == store.state, "not busy reads persisted state")
end

function T.test_has_status_clears_completed()
    local store = fake_store()
    store.state = { status = "completed" }
    local c = Coordinator.new(store)
    B.eq(c:has_status(false), false, "completed has no sticky status")
    B.eq(store.state.status, "idle", "completed state cleared")
    store.state = { status = "failed" }
    B.eq(c:has_status(false), true, "failed is sticky")
    B.eq(c:has_status(true), true, "busy task always sticky")
end

function T.test_status_label_branches()
    local store = fake_store()
    store.state = { status = "active", stage = "rate_limit", wait_seconds = 9, title = "书" }
    local c = Coordinator.new(store)
    B.contains(c:status_label(nil, false), "9秒后继续")
    store.state = { status = "active", stage = "waiting_network", title = "书" }
    B.contains(c:status_label(nil, false), "等待网络")
    store.state = { status = "failed", error_kind = "network" }
    B.contains(c:status_label(nil, false), "等待网络，可继续")
    store.state = { status = "failed", error_kind = "image_missing" }
    B.contains(c:status_label(nil, false), "图片待修复")
end

function T.test_write_state_throttles_active_writes()
    local store = fake_store()
    local c = Coordinator.new(store, fake_clock(1000))
    B.eq(c:write_state("active", { stage = "fetch", current = 0 }), true, "first write lands")
    B.eq(c:write_state("active", { stage = "fetch", current = 1 }), false, "same stage within 2s throttled")
    B.eq(c:write_state("active", { stage = "chapters", current = 2 }), true, "new stage lands")
    B.eq(c:write_state("failed", { error = "x" }), true, "non-active always lands")
    B.eq(store.state.status, "failed")
end

function T.test_active_payload_shape()
    local c = Coordinator.new(fake_store())
    local runtime = {
        book = { bookId = "7", title = "测试书" },
        options = { annotations = true },
        background = true,
        started_at = 99,
        task = { pid = 1 },
    }
    local payload = c:active_payload(runtime, { stage = "prepare", waiting_network = false }, { pid = 2 })
    B.eq(payload.title, "测试书")
    B.eq(payload.book_id, "7")
    B.eq(payload.background, true)
    B.eq(payload.task.pid, 2, "task descriptor overrides runtime task")
    B.ok(payload.waiting_network == nil, "waiting_network nil unless true")
end

function T.test_job_key_and_duplicates()
    local store = fake_store()
    local c = Coordinator.new(store)
    local book_a = { bookId = "1", title = "A" }
    local book_b = { bookId = "2", title = "B" }
    local opt = { annotations = true, chapter_uid = "u" }
    local runtime_book = { bookId = "1" }
    B.eq(c:find_duplicate(book_a, opt, runtime_book, opt), "active", "same book id blocks")
    B.ok(c:find_duplicate(book_b, opt, runtime_book, opt) == nil, "other book may start")
    local _, _, job = c:enqueue(book_a, opt, false, {})
    local duplicate, found = c:find_duplicate(book_a, opt, nil, nil)
    B.eq(duplicate, "queued")
    B.ok(found == job, "found the queued job")
end

function T.test_can_start_next_gates()
    local store = fake_store()
    local c = Coordinator.new(store)
    store.queue = { { book = { bookId = "1" }, options = {}, open_after = false } }
    B.eq(c:can_start_next(true, false, true, true, false), false, "busy task blocks")
    B.eq(c:can_start_next(false, true, true, true, false), false, "runtime blocks")
    store.state = { status = "interrupted" }
    B.eq(c:can_start_next(false, false, true, true, false), false, "interrupted state blocks")
    store.state = { status = "idle" }
    B.eq(c:can_start_next(false, false, false, true, false), false, "offline blocks")
    B.eq(c:can_start_next(false, false, true, false, false), false, "not logged in blocks")
    B.eq(c:can_start_next(false, false, true, true, false), true, "ready to start")
    store.queue[1].defer_until_reader_closed = true
    B.eq(c:can_start_next(false, false, true, true, true), false, "deferred while reader open")
    B.eq(c:can_start_next(false, false, true, true, false), true, "deferred once reader closed")
end

return T
