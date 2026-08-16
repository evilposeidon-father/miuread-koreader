local B = require("tests.lua.bootstrap")

local StoreIdentity = require("miuread.store_identity")
local StoreLibrary = require("miuread.store_library")

local T = {}

local function fake_store(library)
    local store = { values = { library = library or {} } }
    setmetatable(store, { __index = function(_, key) return StoreIdentity[key] or StoreLibrary[key] end })
    function store:get(key, fallback)
        local value = self.values[key]
        return value == nil and fallback or value
    end
    function store:set(key, value) self.values[key] = value end
    function store:flush() end
    return store
end

function T.test_epub_identity_light_rejects_missing_file()
    B.ok(StoreIdentity.epub_identity_light(fake_store(), "/no/such.epub") == nil,
        "missing file has no identity")
end

function T.test_file_record_fast_uses_filename_key()
    local store = fake_store({ b1 = {
        book_id = "b1",
        variants = { clean = { file = "/tmp/other.epub" } },
    } })
    local book, record, kind = StoreIdentity.file_record_fast(store, "/tmp/wanted.epub", false)
    B.ok(book == nil and record == nil and kind == nil,
        "no match returns nil without basename crash")
end

function T.test_file_record_fast_matches_exact_path()
    local store = fake_store({ b1 = {
        book_id = "b1",
        variants = { clean = { file = "/tmp/wanted.epub", variant = "clean" } },
    } })
    local book, record, kind = StoreIdentity.file_record_fast(store, "/tmp/wanted.epub", false)
    B.ok(book ~= nil, "book found by path")
    B.eq(kind, "clean")
end

function T.test_identify_file_falls_through_missing_epub()
    local store = fake_store({})
    local book, record, kind = StoreIdentity.identify_file(store, "/no/such.epub", false)
    B.ok(book == nil, "missing epub returns no record")
end

return T
