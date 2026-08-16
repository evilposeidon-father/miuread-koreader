local B = require("tests.lua.bootstrap")

local StorePending = require("miuread.store_pending")
local StoreLibrary = require("miuread.store_library")

local T = {}

local function fake_store()
    local store = { values = {} }
    setmetatable(store, {
        __index = function(_, key)
            return StorePending[key] or StoreLibrary[key]
        end,
    })
    function store:get(key, fallback)
        local value = self.values[key]
        return value == nil and fallback or value
    end
    function store:set(key, value) self.values[key] = value end
    function store:flush() end
    function store:download_queue() return {} end
    function store:save_download_queue() end
    function store:pending_installs() return StorePending.pending_installs(self) end
    function store:save_pending_installs(rows) StorePending.save_pending_installs(self, rows) end
    function store:download_state() return {} end
    function store:clear_download_state() end
    function store:shelf_cache() return { books = {}, mp = {} } end
    function store:save_shelf_cache() end
    return store
end

function T.test_library_basics()
    local store = fake_store()
    B.ok(next(store:library()) == nil, "library starts empty")
    store:save_book("b1", { title = "Book" })
    B.eq(store:book("b1").title, "Book")
    store:save_variant("b1", "clean", { file = "/tmp/b1.epub" })
    B.eq(store:variant("b1", "clean").file, "/tmp/b1.epub")
    store:save_chapter_variant("b1", "u1", "notes", { file = "/tmp/u1.epub" })
    B.eq(store:chapter_variant("b1", "u1", "notes").file, "/tmp/u1.epub")
end

function T.test_forget_and_all_books_sort()
    local store = fake_store()
    store:save_book("b1", { title = "One", updated_at = 10 })
    store:save_book("b2", { title = "Two", updated_at = 30 })
    store:save_book("b3", { title = "Three", updated_at = 20 })
    local all = store:all_books()
    B.eq(all[1].title, "Two", "sorted by updated_at desc")
    B.eq(#all, 3)
    store:forget_book("b2")
    B.ok(store:book("b2") == nil, "forgotten")
    B.eq(#store:all_books(), 2)
end

function T.test_pending_install_roundtrip()
    local store = fake_store()
    local item = store:add_pending_install("b1", "clean", nil, { file = "/tmp/a" })
    B.eq(item.book_id, "b1")
    B.eq(#store:pending_installs(), 1)
    store:add_pending_install("b1", "clean", nil, { file = "/tmp/b" })
    B.eq(#store:pending_installs(), 1, "same key replaces")
    B.eq(store:pending_installs()[1].file, "/tmp/b")
    B.eq(store:remove_pending_install("b1", "clean", nil), true)
    B.eq(#store:pending_installs(), 0)
end

function T.test_prune_pending_installs_drops_missing()
    local store = fake_store()
    store:add_pending_install("b1", "clean", nil, { file = "/tmp/a", pending_file = "/tmp/no-such-file" })
    store:add_pending_install("b2", "clean", nil, { file = "/tmp/b" })
    local kept = store:prune_pending_installs()
    B.eq(#kept, 0, "fake lfs reports no files, all pruned")
    B.eq(#store:pending_installs(), 0)
end

function T.test_read_report_consumed_bookkeeping()
    local store = fake_store()
    B.eq(store:is_read_report_consumed("s1"), false)
    store:mark_read_report_consumed("s1")
    B.eq(store:is_read_report_consumed("s1"), true)
    B.eq(store:is_read_report_consumed(""), false, "empty stamp rejected")
end

function T.test_cleanup_result_roundtrip()
    local store = fake_store()
    store:save_cleanup_result({ freed = 1024 })
    B.eq(store:last_cleanup_result().freed, 1024)
end

return T
