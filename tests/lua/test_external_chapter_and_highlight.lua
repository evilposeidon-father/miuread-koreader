local B = require("tests.lua.bootstrap")
local Stubs = require("tests.lua.koreader_stubs")

Stubs.install()

local ExternalSync = require("miuread.external_annotation_sync")
local ReaderController = require("miuread.plugin_reader")
local AnnotationSync = require("miuread.annotation_sync")

local T = {}

local function fake_external_plugin()
    local plugin = setmetatable({}, { __index = ExternalSync })
    plugin.ui = {
        document = {
            file = "/tmp/book.epub",
            info = { has_pages = false },
            getXPointer = function() return "/body[1]" end,
            getScreenBoxesFromPositions = function() return {} end,
        },
    }
    plugin.requests = {}
    function plugin:_sync_scheduler_request(kind, delay, reason)
        self.requests[#self.requests + 1] = { kind = kind, delay = delay, reason = reason }
        return true
    end
    function plugin:_external_auto_bind_miuread_book() return false end
    plugin.sync = {}
    function plugin.sync:local_position() return { chapter_uid = "u2" } end
    plugin.store = {}
    function plugin.store:preferences() return { external_annotations_visible = true } end
    plugin.reader = {}
    function plugin.reader:catalog(book_id)
        return { {
            bookId = book_id,
            chapters = {
                { chapterUid = "u1", wordCount = 100, title = "一" },
                { chapterUid = "u2", wordCount = 100, title = "二" },
                { chapterUid = "u3", wordCount = 100, title = "三" },
            },
        } }
    end
    plugin.external_entry = { binding = { book_id = "b" }, records = {} }
    plugin.external_annotations_db = {
        getDocument = function(_, path)
            if path == "/tmp/book.epub" then return plugin.external_entry end
            return nil
        end,
    }
    return plugin
end

function T.test_dynamic_hint_queues_current_then_next()
    local plugin = fake_external_plugin()
    B.eq(plugin:_external_annotation_dynamic_hint(), true, "current chapter queued")
    B.eq(#plugin.requests, 1)
    B.eq(plugin.requests[1].kind, "external_annotations")
    B.eq(plugin._external_pending_chapter_uid, "u2", "current chapter selected")
    B.contains(plugin.requests[1].reason, "u2", "reason carries the chapter uid")

    -- Current chapter is now cached; the next hint should select the next one.
    plugin.external_entry.records = { { chapter_uid = "u2" } }
    plugin._external_dynamic_catalog = {
        book_id = "b",
        catalog = { { chapterUid = "u1" }, { chapterUid = "u2" }, { chapterUid = "u3" } },
    }
    plugin._external_pending_chapter_uid = nil
    B.eq(plugin:_external_annotation_dynamic_hint(), true, "next chapter queued")
    B.eq(plugin._external_pending_chapter_uid, "u3", "prefetch chapter selected")
end

function T.test_dynamic_hint_skips_empty_fetched_chapters()
    local plugin = fake_external_plugin()
    plugin.external_entry.fetched_chapters = { u2 = 123 }
    B.eq(plugin:_external_annotation_dynamic_hint(), false, "fetched chapter with no marks is not refetched")
    B.eq(plugin._external_pending_chapter_uid, nil)
end

function T.test_dynamic_next_uid_bounds()
    local plugin = fake_external_plugin()
    local catalog = { { chapterUid = "u1" }, { chapterUid = "u2" } }
    B.eq(plugin:_external_annotation_next_uid(catalog, "u1"), "u2")
    B.eq(plugin:_external_annotation_next_uid(catalog, "u2"), nil, "last chapter has no next")
end

function T.test_chapter_sync_requires_file_and_binding()
    local plugin = fake_external_plugin()
    plugin.ui.document.file = nil
    local captured
    local started, err = plugin:sync_external_chapter({
        chapter_uid = "u2",
        on_done = function(ok, action_err) captured = { ok = ok, err = action_err } end,
    })
    B.eq(started, false)
    B.eq(err, "no_file")
    B.eq(captured, nil, "callback is reserved for started actions")
end

local function fake_reader_plugin()
    local plugin = {}
    ReaderController.install(plugin)
    local highlight = {
        prompt_seen = nil,
        selected_text = { text = "测试", pos0 = { page = 1 }, pos1 = { page = 1 } },
        hold_pos = nil,
        highlight_dialog = nil,
        saved_index = nil,
        showHighlightPrompt = function(self, caller_callback, prompt)
            self.prompt_seen = prompt
            self.saved_index = 1
            self:clear()
            if caller_callback then caller_callback(1) end
            return true
        end,
        saveHighlight = function(self, extend_to_sentence)
            self.saved_index = 42
            return 42
        end,
        clear = function(self)
            self.selected_text = nil
        end,
        highlightFromHoldPos = function(self)
            self.selected_text = { text = "长按", pos0 = { page = 1 }, pos1 = { page = 1 } }
        end,
    }
    plugin.ui = {
        view = { highlight = { saved_drawer = "lighten" } },
        highlight = highlight,
        doc_settings = {},
    }
    function plugin.ui.doc_settings:has(key) return self.values and self.values[key] ~= nil end
    function plugin.ui.doc_settings:readSetting(key) return self.values and self.values[key] end
    function plugin.ui.doc_settings:saveSetting(key, value)
        self.values = self.values or {}
        self.values[key] = value
        return true
    end
    return plugin
end

local function fake_reader_settings(data)
    return {
        readSetting = function(_, key, default)
            if data[key] ~= nil then return data[key] end
            return default
        end,
        saveSetting = function(_, key, value)
            data[key] = value
        end,
        delSetting = function(_, key)
            data[key] = nil
        end,
        flush = function() end,
    }
end

local function with_fake_reader_settings(data, fn)
    local old = rawget(_G, "G_reader_settings")
    _G.G_reader_settings = fake_reader_settings(data)
    local ok, err = pcall(fn)
    _G.G_reader_settings = old
    if not ok then error(err, 0) end
end

function T.test_highlight_defaults_are_underline_and_direct()
    with_fake_reader_settings({}, function()
        local plugin = fake_reader_plugin()
        B.eq(plugin:_apply_miuread_highlight_defaults({ book_id = "1" }), true)
        B.eq(plugin.ui.view.highlight.saved_drawer, "underscore", "default drawer is underline")
        B.eq(plugin.ui.doc_settings:readSetting("highlight_drawer"), "underscore")
        B.eq(plugin.ui.doc_settings:has("miuread_highlight_underline_applied"), true)

        -- The wrapped prompt must save immediately and skip the native
        -- implementation, even when the global prompt preference is set.
        local callback_index
        plugin.ui.highlight:showHighlightPrompt(function(index) callback_index = index end)
        B.eq(plugin.ui.highlight.saved_index, 42, "highlight is saved directly")
        B.eq(callback_index, 42, "caller callback receives the new index")
        B.eq(plugin.ui.highlight.selected_text, nil, "selection is cleared after saving")
        B.eq(plugin.ui.highlight.prompt_seen, nil, "native prompt implementation is bypassed")
    end)
end

function T.test_highlight_defaults_respect_explicit_style_after_first_apply()
    with_fake_reader_settings({}, function()
        local plugin = fake_reader_plugin()
        plugin:_apply_miuread_highlight_defaults({ book_id = "1" })
        -- Simulate the user later choosing a different KOReader highlight style.
        plugin.ui.doc_settings:saveSetting("highlight_drawer", "invert")
        plugin:_apply_miuread_highlight_defaults({ book_id = "1" })
        B.eq(plugin.ui.view.highlight.saved_drawer, "invert", "explicit style wins after first apply")
    end)
end

function T.test_highlight_action_policy_is_temporary()
    with_fake_reader_settings({
        default_highlight_action = "ask",
        highlight_action_on_single_word = false,
    }, function()
        local plugin = fake_reader_plugin()
        plugin:_apply_miuread_highlight_defaults({ book_id = "1" })
        B.eq(G_reader_settings:readSetting("default_highlight_action"), "highlight")
        B.eq(G_reader_settings:readSetting("highlight_action_on_single_word"), true)

        B.eq(plugin:_restore_miuread_highlight_action_policy(), true)
        B.eq(G_reader_settings:readSetting("default_highlight_action"), "ask")
        B.eq(G_reader_settings:readSetting("highlight_action_on_single_word"), false)
    end)
end

function T.test_highlight_action_policy_restores_absent_settings()
    with_fake_reader_settings({}, function()
        local plugin = fake_reader_plugin()
        plugin:_apply_miuread_highlight_defaults({ book_id = "1" })
        B.eq(plugin:_restore_miuread_highlight_action_policy(), true)
        B.eq(G_reader_settings:readSetting("default_highlight_action"), nil)
        B.eq(G_reader_settings:readSetting("highlight_action_on_single_word"), nil)
    end)
end

function T.test_progress_anchor_helpers()
    B.eq(AnnotationSync.is_progress_anchor({ local_id = "ko:miu-progress-anchor", kind = "bookmark" }), true)
    B.eq(AnnotationSync.is_progress_anchor({ local_id = "ko:other", kind = "bookmark" }), false)
    B.eq(AnnotationSync.is_progress_anchor({ local_id = "ko:miu-progress-anchor", kind = "highlight" }), false)
    B.eq(AnnotationSync.anchor_mark_text("  一段文字  "), "觅阅进度锚点：一段文字")
    local dupes = AnnotationSync.find_anchor_duplicates({
        { bookmarkId = "b1", markText = "觅阅进度锚点：旧位置" },
        { bookmarkId = "b2", markText = "普通书签" },
        { bookmarkId = "b3", range = "1-2" },
    })
    B.eq(#dupes, 1, "only prefixed anchor bookmarks are duplicates")
    B.eq(dupes[1].remote_id, "b1")
end

return T
