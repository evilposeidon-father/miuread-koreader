-- SQLite persistence for WeRead annotations projected onto arbitrary local
-- books. Kept out of settings so bindings, XPointer ranges, quotations, and
-- thoughts can grow with every synced book.
--
-- Ported from weread.koplugin and adapted to the miuread namespace.

local Digests = require("miuread.digests")
local Json = require("miuread.json")
local U = require("miuread.util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local ExternalAnnotationsDB = {}
ExternalAnnotationsDB.__index = ExternalAnnotationsDB
ExternalAnnotationsDB.LEGACY_SETTINGS_KEY = "external_annotations"

local function getSQ3()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    return ok and SQ3 or nil
end

local function encode(value)
    local ok, result = pcall(function()
        return Json.encode(value)
    end)
    return ok and result or nil, ok and nil or result
end

local function decode(value)
    if type(value) ~= "string" or value == "" then return nil end
    local ok, result = pcall(function()
        return Json.decode(value)
    end)
    return ok and type(result) == "table" and result or nil
end

local function close_statement(stmt)
    if stmt then pcall(function() stmt:close() end) end
end

function ExternalAnnotationsDB:new(store, options)
    options = options or {}
    local data_dir = store.data_dir or "."
    return setmetatable({
        store = store,
        data_dir = data_dir .. "/external-annotations",
        remove_file = options.remove_file or os.remove,
    }, self)
end

local function safe_basename(path)
    local name = tostring(path or ""):match("([^/]+)$") or "local-book"
    name = name:gsub("%.[^%.]+$", "")
        :gsub("[%z\1-\31/\\:*?\"<>|]", "_")
        :gsub("^%s+", ""):gsub("%s+$", "")
    if #name > 96 then
        local cut = 96
        while cut > 1 do
            local byte = name:byte(cut + 1)
            if not byte or byte < 0x80 or byte >= 0xC0 then break end
            cut = cut - 1
        end
        name = name:sub(1, cut)
    end
    if name == "" then name = "local-book" end
    return name
end

function ExternalAnnotationsDB:databasePath(document_path)
    document_path = tostring(document_path or "")
    if document_path == "" then return nil end
    local suffix = Digests.sha256(document_path):sub(1, 16)
    return self.data_dir .. "/" .. safe_basename(document_path)
        .. "-" .. suffix .. ".db"
end

function ExternalAnnotationsDB:open(document_path, create)
    local path = self:databasePath(document_path)
    if not path then return nil, "document path is required" end
    if not create and not lfs.attributes(path, "mode") then return nil end
    if not lfs.attributes(self.data_dir, "mode") then
        local created, mkdir_err = lfs.mkdir(self.data_dir)
        if not created and not lfs.attributes(self.data_dir, "mode") then
            return nil, tostring(mkdir_err or "database directory creation failed")
        end
    end
    local SQ3 = getSQ3()
    if not SQ3 then
        return nil, "lua-ljsqlite3 is unavailable"
    end
    local ok, db = pcall(SQ3.open, path)
    if not ok or not db then
        return nil, tostring(db or "database open failed")
    end
    local schema_ok, schema_err = pcall(function()
        db:exec("PRAGMA journal_mode=WAL")
        db:exec("PRAGMA synchronous=NORMAL")
        db:exec([[
            CREATE TABLE IF NOT EXISTS documents (
                document_path TEXT PRIMARY KEY,
                payload       TEXT NOT NULL,
                updated_at    INTEGER NOT NULL
            ) WITHOUT ROWID
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS sync_state (
                id      INTEGER PRIMARY KEY CHECK (id=1),
                payload TEXT NOT NULL
            )
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS sync_chapters (
                position    INTEGER PRIMARY KEY,
                chapter_uid TEXT NOT NULL UNIQUE,
                payload     TEXT NOT NULL
            )
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS sync_review_batches (
                chapter_uid TEXT NOT NULL,
                batch_index INTEGER NOT NULL,
                payload     TEXT NOT NULL,
                PRIMARY KEY (chapter_uid, batch_index)
            ) WITHOUT ROWID
        ]])
    end)
    if not schema_ok then
        pcall(function() db:close() end)
        return nil, tostring(schema_err)
    end
    return db
end

function ExternalAnnotationsDB:getDocument(path)
    path = tostring(path or "")
    if path == "" then return nil end
    local db, open_err = self:open(path, false)
    if not db then
        if open_err then
            logger.warn("[MiuRead][ExternalAnnotations] db read skipped:", open_err)
        end
        return nil
    end
    local stmt
    local value
    local ok, err = pcall(function()
        stmt = db:prepare("SELECT payload FROM documents WHERE document_path=?")
        local row = stmt:reset():bind(path):step()
        value = row and decode(row[1]) or nil
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    if not ok then
        logger.warn("[MiuRead][ExternalAnnotations] db read failed:", err)
        return nil
    end
    return value
end

function ExternalAnnotationsDB:saveDocument(path, value)
    path = tostring(path or "")
    if path == "" or type(value) ~= "table" then
        return false, "document path and value are required"
    end
    local payload, encode_err = encode(value)
    if not payload then return false, tostring(encode_err) end
    local db, open_err = self:open(path, true)
    if not db then return false, open_err end
    local stmt
    local ok, err = pcall(function()
        stmt = db:prepare([[
            INSERT INTO documents (document_path, payload, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(document_path) DO UPDATE SET
                payload=excluded.payload,
                updated_at=excluded.updated_at
        ]])
        stmt:reset():bind(path, payload, os.time()):step()
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    if not ok then
        logger.warn("[MiuRead][ExternalAnnotations] db write failed:", err)
        return false, tostring(err)
    end
    return true
end

function ExternalAnnotationsDB:clearDocument(path)
    path = tostring(path or "")
    if path == "" then return false, "document path is required" end
    local db_path = self:databasePath(path)
    for _, target in ipairs({ db_path, db_path .. "-wal", db_path .. "-shm" }) do
        local removed, remove_err = self.remove_file(target)
        if not removed and lfs.attributes(target, "mode") then
            logger.warn("[MiuRead][ExternalAnnotations] db delete failed:", remove_err)
            return false, tostring(remove_err)
        end
    end
    return true
end

function ExternalAnnotationsDB:getSyncCheckpoint(path)
    path = tostring(path or "")
    if path == "" then return nil end
    local db, open_err = self:open(path, false)
    if not db then
        if open_err then logger.warn("[MiuRead][ExternalAnnotations] checkpoint read skipped:", open_err) end
        return nil
    end
    local state_stmt, chapter_stmt, batch_stmt
    local state
    local ok, err = pcall(function()
        state_stmt = db:prepare("SELECT payload FROM sync_state WHERE id=1")
        local row = state_stmt:reset():step()
        state = row and decode(row[1]) or nil
        if type(state) ~= "table" then return end
        state.chapters = {}
        local chapters_by_uid = {}
        chapter_stmt = db:prepare([[
            SELECT position, chapter_uid, payload
            FROM sync_chapters ORDER BY position
        ]])
        row = chapter_stmt:reset():step()
        while row do
            local chapter = decode(row[3])
            if type(chapter) == "table" then
                chapter.position = tonumber(row[1]) or chapter.position
                chapter.chapter_uid = tostring(row[2])
                chapter.review_batches = {}
                state.chapters[#state.chapters + 1] = chapter
                chapters_by_uid[chapter.chapter_uid] = chapter
            end
            row = chapter_stmt:step()
        end
        batch_stmt = db:prepare([[
            SELECT chapter_uid, batch_index, payload
            FROM sync_review_batches ORDER BY chapter_uid, batch_index
        ]])
        row = batch_stmt:reset():step()
        while row do
            local chapter = chapters_by_uid[tostring(row[1])]
            local batch = decode(row[3])
            if chapter and type(batch) == "table" then
                chapter.review_batches[#chapter.review_batches + 1] = {
                    batch_index = tonumber(row[2]),
                    reviews = type(batch.reviews) == "table" and batch.reviews or {},
                }
            end
            row = batch_stmt:step()
        end
    end)
    close_statement(state_stmt)
    close_statement(chapter_stmt)
    close_statement(batch_stmt)
    pcall(function() db:close() end)
    if not ok then
        logger.warn("[MiuRead][ExternalAnnotations] checkpoint read failed:", err)
        return nil
    end
    return state
end

function ExternalAnnotationsDB:replaceSyncCheckpoint(path, state)
    path = tostring(path or "")
    if path == "" or type(state) ~= "table" then
        return false, "document path and checkpoint state are required"
    end
    local checkpoint = {}
    for key, value in pairs(state) do
        if key ~= "chapters" then checkpoint[key] = value end
    end
    local payload, encode_err = encode(checkpoint)
    if not payload then return false, tostring(encode_err) end
    local db, open_err = self:open(path, true)
    if not db then return false, open_err end
    local transaction_open = false
    local stmt
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        db:exec("DELETE FROM sync_review_batches")
        db:exec("DELETE FROM sync_chapters")
        db:exec("DELETE FROM sync_state")
        stmt = db:prepare("INSERT INTO sync_state (id, payload) VALUES (1, ?)")
        stmt:reset():bind(payload):step()
        close_statement(stmt)
        stmt = nil
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    return ok, ok and nil or tostring(err)
end

function ExternalAnnotationsDB:saveSyncChapter(path, position, chapter_uid, value)
    path = tostring(path or "")
    chapter_uid = tostring(chapter_uid or "")
    position = tonumber(position)
    if path == "" or not position or chapter_uid == "" or type(value) ~= "table" then
        return false, "valid checkpoint chapter fields are required"
    end
    local payload, encode_err = encode(value)
    if not payload then return false, tostring(encode_err) end
    local db, open_err = self:open(path, true)
    if not db then return false, open_err end
    local stmt
    local ok, err = pcall(function()
        stmt = db:prepare([[
            INSERT INTO sync_chapters (position, chapter_uid, payload)
            VALUES (?, ?, ?)
            ON CONFLICT(position) DO UPDATE SET
                chapter_uid=excluded.chapter_uid,
                payload=excluded.payload
        ]])
        stmt:reset():bind(position, chapter_uid, payload):step()
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok, ok and nil or tostring(err)
end

function ExternalAnnotationsDB:saveSyncReviewBatch(path, chapter_uid, batch_index, reviews)
    path = tostring(path or "")
    chapter_uid = tostring(chapter_uid or "")
    batch_index = tonumber(batch_index)
    if path == "" or chapter_uid == "" or not batch_index
        or type(reviews) ~= "table" then
        return false, "valid checkpoint review batch fields are required"
    end
    local payload, encode_err = encode({ reviews = reviews })
    if not payload then return false, tostring(encode_err) end
    local db, open_err = self:open(path, true)
    if not db then return false, open_err end
    local stmt
    local ok, err = pcall(function()
        stmt = db:prepare([[
            INSERT INTO sync_review_batches (chapter_uid, batch_index, payload)
            VALUES (?, ?, ?)
            ON CONFLICT(chapter_uid, batch_index) DO UPDATE SET
                payload=excluded.payload
        ]])
        stmt:reset():bind(chapter_uid, batch_index, payload):step()
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok, ok and nil or tostring(err)
end

function ExternalAnnotationsDB:finishSyncChapter(path, position, chapter_uid, value)
    path = tostring(path or "")
    chapter_uid = tostring(chapter_uid or "")
    position = tonumber(position)
    if path == "" or not position or chapter_uid == "" or type(value) ~= "table" then
        return false, "valid completed checkpoint chapter fields are required"
    end
    local payload, encode_err = encode(value)
    if not payload then return false, tostring(encode_err) end
    local db, open_err = self:open(path, true)
    if not db then return false, open_err end
    local transaction_open = false
    local chapter_stmt, batch_stmt
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        chapter_stmt = db:prepare([[
            INSERT INTO sync_chapters (position, chapter_uid, payload)
            VALUES (?, ?, ?)
            ON CONFLICT(position) DO UPDATE SET
                chapter_uid=excluded.chapter_uid,
                payload=excluded.payload
        ]])
        chapter_stmt:reset():bind(position, chapter_uid, payload):step()
        close_statement(chapter_stmt)
        chapter_stmt = nil
        batch_stmt = db:prepare(
            "DELETE FROM sync_review_batches WHERE chapter_uid=?")
        batch_stmt:reset():bind(chapter_uid):step()
        close_statement(batch_stmt)
        batch_stmt = nil
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(chapter_stmt)
    close_statement(batch_stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    return ok, ok and nil or tostring(err)
end

function ExternalAnnotationsDB:clearSyncCheckpoint(path)
    path = tostring(path or "")
    if path == "" then return false, "document path is required" end
    local db, open_err = self:open(path, false)
    if not db then return open_err == nil, open_err end
    local transaction_open = false
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        db:exec("DELETE FROM sync_review_batches")
        db:exec("DELETE FROM sync_chapters")
        db:exec("DELETE FROM sync_state")
        db:exec("COMMIT")
        transaction_open = false
    end)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    return ok, ok and nil or tostring(err)
end

return ExternalAnnotationsDB
