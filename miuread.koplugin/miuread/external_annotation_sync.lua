-- EPUB-safe WeRead underlines and thoughts for arbitrary local reflowable
-- books. The overlay projects XPointer records without touching the document,
-- so no EPUB regeneration is needed.
--
-- The sync engine supports cancellation and resumable checkpoints: every
-- completed chapter and every downloaded review batch is persisted in SQLite
-- before the next network request starts.

local Device = require("device")
local Lazy = require("miuread.lazy")
local Digests = require("miuread.digests")
local DownloadProgress = require("miuread.download_progress")
local External = require("miuread.external_annotations")
local GestureBridge = require("miuread.gesture_bridge")
local Overlay = require("miuread.xpointer_overlay")
local ThoughtNativePopup = require("miuread.thought_native_popup")
local UIManager = require("ui/uimanager")
local U = require("miuread.util")
local logger = require("logger")

local RawConfirmBox = require("ui/widget/confirmbox")
local RawInputDialog = require("ui/widget/inputdialog")

local M = {}

local VIEW_MODULE = "miuread_xpointer_overlay"
local TOUCH_ZONE = "miuread_external_annotation_tap"
local SYNC_FORMAT_VERSION = 6
local REVIEW_BATCH_SIZE = 5

local function wrap_class(base, attributes)
    local class = base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local InputDialog = wrap_class(RawInputDialog, {
    _miuread_transient = true,
    _miuread_modal_surface = true,
})
local ConfirmBox = wrap_class(RawConfirmBox, {
    _miuread_transient = true,
    _miuread_modal_surface = true,
})

local function current_file(plugin)
    local doc = plugin.ui and plugin.ui.document
    return doc and (doc.file or (doc.getFilePath and doc:getFilePath())) or nil
end

local function current_entry(plugin)
    local file = current_file(plugin)
    if not file then return nil end
    return plugin.external_annotations_db:getDocument(file)
end

local function current_records(plugin)
    local entry = current_entry(plugin)
    return entry and type(entry.records) == "table" and entry.records or {}
end

local function is_supported(plugin)
    local document = plugin.ui and plugin.ui.document
    return document and document.info and not document.info.has_pages
        and type(document.getXPointer) == "function"
        and type(document.getScreenBoxesFromPositions) == "function"
end

local function is_miuread_book(plugin)
    if plugin.sync and plugin.sync:record() then return true end
    local doc = plugin.ui and plugin.ui.document
    local path = doc and (doc.file or (doc.getFilePath and doc:getFilePath()))
    if not path then return false end
    local book = plugin.store:identify_file(path, false)
    return book ~= nil
end

local function is_legacy_notes_variant(plugin)
    local current
    if plugin.sync and type(plugin.sync.record) == "function" then
        current = plugin.sync:record()
    end
    if current and current.record then
        if current.record.annotation_requested == true
            or tostring(current.variant or current.record.variant or ""):find("notes", 1, true) then
            return true
        end
    end
    local path = current_file(plugin)
    if not path or not plugin.store or type(plugin.store.identify_file) ~= "function" then return false end
    local book, record, variant = plugin.store:identify_file(path, false)
    return record and (record.annotation_requested == true
        or tostring(variant or record.variant or ""):find("notes", 1, true)) or false
end

local ExternalAnnotationParse = require("miuread.external_annotation_parse")
local collect_ranges = ExternalAnnotationParse.collect_ranges
local catalog_signature = ExternalAnnotationParse.catalog_signature
local chapter_uid = ExternalAnnotationParse.chapter_uid
local chapter_title = ExternalAnnotationParse.chapter_title
local normalize_comments = ExternalAnnotationParse.normalize_comments
local scalar = ExternalAnnotationParse.scalar
local collect_records = ExternalAnnotationParse.collect_records
local review_parts = ExternalAnnotationParse.review_parts
local clean_book_keyword = ExternalAnnotationParse.clean_book_keyword

function M.install(Plugin)
    for name, method in pairs(M) do
        if name ~= "install" and Plugin[name] == nil then
            Plugin[name] = method
        end
    end
    return Plugin
end

function M:_external_annotations_supported()
    return is_supported(self)
end

function M:_external_current_file()
    return current_file(self)
end

function M:_external_current_entry()
    return current_entry(self)
end

function M:_external_annotations_visible()
    return self.store:preferences().external_annotations_visible ~= false
end

-- MiuRead-generated books already know their WeRead book id. Reuse it so a
-- downloaded "书名-纯净版.epub" can bind automatically without searching.
function M:_external_auto_bind_miuread_book()
    local path = current_file(self)
    if not path then return false end
    local current = self.sync and self.sync:record() or self:_current_book_record()
    local book = current and current.book
    if not book then return false end
    local book_id = tostring(book.book_id or book.bookId or "")
    if book_id == "" then return false end

    local entry = self.external_annotations_db:getDocument(path) or {}
    local previous_id = entry.binding and tostring(entry.binding.book_id or "") or ""
    if previous_id == book_id then return true end

    entry.binding = {
        book_id = book_id,
        title = tostring(book.title or ""),
        author = tostring(book.author or ""),
        format = tostring(book.format or book.variant or ""),
        bound_at = os.time(),
        auto = true,
    }
    entry.records = {}
    entry.stats = nil
    entry.synced_at = nil
    local saved, save_err = self.external_annotations_db:saveDocument(path, entry)
    if not saved then
        logger.warn("[MiuRead][ExternalAnnotations] auto bind save failed:", save_err)
        return false
    end
    self.external_annotations_db:clearSyncCheckpoint(path)
    if self._external_annotation_overlay then
        self._external_annotation_overlay:setRecords({})
    end
    logger.info("[MiuRead][ExternalAnnotations] auto bound MiuRead book:",
        "book_id=", book_id, "path=", tostring(path))
    return true
end

function M:_setup_external_annotations()
    self:_teardown_external_annotations()
    if not is_supported(self)
        or is_legacy_notes_variant(self)
        or not self.ui.view or type(self.ui.view.registerViewModule) ~= "function" then
        return false
    end
    local overlay = Overlay:new{
        records = current_records(self),
        enabled = self:_external_annotations_visible(),
    }
    self.ui.view:registerViewModule(VIEW_MODULE, overlay)
    self._external_annotation_overlay = overlay

    if Device:isTouchDevice() then
        self.ui:registerTouchZones({
            {
                id = TOUCH_ZONE,
                ges = "tap",
                screen_zone = {
                    ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1,
                },
                overrides = {
                    "readerhighlight_tap",
                    "tap_top_left_corner", "tap_top_right_corner",
                    "tap_left_bottom_corner", "tap_right_bottom_corner",
                    "readerfooter_tap", "readermenu_ext_tap", "readermenu_tap",
                    "tap_forward", "tap_backward",
                },
                handler = function(ges)
                    return self:_on_external_annotation_tap(ges)
                end,
            },
        })
        self._external_annotation_touch_registered = true
    end
    return true
end

function M:_teardown_external_annotations()
    if self._external_dynamic_hint_task then
        UIManager:unschedule(self._external_dynamic_hint_task)
        self._external_dynamic_hint_task = nil
    end
    self._external_pending_chapter_uid = nil
    self._external_dynamic_skip_until = nil
    if self._external_annotation_touch_registered and self.ui then
        self.ui:unRegisterTouchZones({
            {
                id = TOUCH_ZONE,
                overrides = {
                    "readerhighlight_tap",
                    "tap_top_left_corner", "tap_top_right_corner",
                    "tap_left_bottom_corner", "tap_right_bottom_corner",
                    "readerfooter_tap", "readermenu_ext_tap", "readermenu_tap",
                    "tap_forward", "tap_backward",
                },
            },
        })
    end
    self._external_annotation_touch_registered = nil
    if self.ui and self.ui.view and self.ui.view.view_modules then
        self.ui.view.view_modules[VIEW_MODULE] = nil
    end
    if self._external_popup then
        pcall(UIManager.close, UIManager, self._external_popup)
    end
    self._external_annotation_overlay = nil
    self._external_popup = nil
end

function M:_invalidate_external_annotations_layout()
    if self._external_annotation_overlay then
        self._external_annotation_overlay:invalidate()
    end
end

function M:onUpdatePos()
    self:_invalidate_external_annotations_layout()
end

function M:onDocumentRerendered()
    if self._external_annotation_overlay then
        self._external_annotation_overlay:resetLayout()
    end
end

function M:_external_edge_ignored(pos)
    if not pos then return false end
    local prefs = self.store:preferences()
    local reader = prefs.reader_ui or {}
    if reader.edge_guard_enabled == false then return false end
    local percent = tonumber(reader.edge_guard_percent) or 10
    local ratio = math.max(0.05, math.min(0.20, percent / 100))
    local width = Device.screen:getWidth()
    return pos.x < width * ratio or pos.x > width * (1 - ratio)
end

function M:_on_external_annotation_tap(ges)
    -- Keep KOReader Gesture Manager corner actions authoritative.
    if GestureBridge.dispatch(ges) then return true end
    local overlay = self._external_annotation_overlay
    if not overlay or not overlay.enabled or not ges or not ges.pos then
        return false
    end
    if self:_external_edge_ignored(ges.pos) then return false end
    local record = overlay:hitTest(ges.pos)
    if not record then return false end
    self:_show_external_annotation_popup(record)
    return true
end

function M:_show_external_annotation_popup(record)
    if type(record) ~= "table" then return false end
    self:_close_active_thought_popup("external annotation")
    if self._external_popup then
        pcall(UIManager.close, UIManager, self._external_popup)
        self._external_popup = nil
    end
    local prefs = self.store:preferences().thoughts or {}
    local ok, popup = pcall(ThoughtNativePopup.show, {
        source_text = tostring(record.text or ""),
        comments = normalize_comments(record.items),
        cache_key = "miuread-external-" .. tostring(record.id or "x"),
        font_size = self:_thought_font_size_value(prefs),
        font_name = self:_thought_font_name(prefs),
        width_ratio = tonumber(prefs.width_ratio) or 0.91,
        height_ratio = tonumber(prefs.height_ratio) or 0.55,
        on_close = function()
            self._external_popup = nil
        end,
        on_interact = function()
            self:_mark_reader_busy(30)
        end,
        on_error = function()
            self:info("划线想法显示失败，窗口已安全关闭。当前阅读位置不会丢失。")
        end,
    })
    if not ok then
        logger.warn("[MiuRead][ExternalAnnotations] popup failed:", popup)
        self:info("划线想法暂时无法显示。")
        return false
    end
    self._external_popup = popup
    return true
end

function M:bind_external_annotations_book(touchmenu_instance)
    if not self:logged_in() then
        self:info("请先登录微信读书账号。")
        return
    end
    local path = current_file(self)
    if not path then return end

    -- MiuRead downloaded books already know their WeRead book id; bind directly
    -- instead of forcing the user to search a "书名-纯净版" style filename.
    if self:_external_auto_bind_miuread_book() then
        local entry = current_entry(self)
        local title = entry and entry.binding and entry.binding.title or ""
        if touchmenu_instance and type(touchmenu_instance.updateItems) == "function" then
            touchmenu_instance:updateItems()
        end
        UIManager:show(ConfirmBox:new{
            title = "已自动匹配",
            text = "已根据当前觅阅书籍自动匹配《" .. tostring(title ~= "" and title or "微信读书书籍")
                .. "》。\n\n现在同步划线与想法吗？\n\n你可以随时取消；已下载的进度会自动保存，下次继续。",
            ok_text = "同步划线与想法",
            cancel_text = "稍后",
            ok_callback = function()
                self:sync_external_annotations()
            end,
        })
        return
    end

    local current = self.sync and self.sync:record() or self:_current_book_record()
    local fallback_input = current and current.book and tostring(current.book.title or "")
        or clean_book_keyword(path)
    if fallback_input == "" then fallback_input = path:match("([^/]+)%.[^%.]+$") or path end

    local dialog
    dialog = InputDialog:new{
        title = "匹配微信读书书籍",
        input = fallback_input,
        input_type = "text",
        buttons = { { {
            text = "取消",
            id = "close",
            callback = function()
                UIManager:close(dialog)
            end,
        }, {
            text = "搜索",
            is_enter_default = true,
            callback = function()
                local keyword = dialog:getInputText()
                UIManager:close(dialog)
                if not keyword or tostring(keyword):gsub("%s+", "") == "" then
                    self:info("请输入书名或关键词。")
                    return
                end
                self:online("搜索微信读书", function()
                    local ok, result = pcall(self.api.search, self.api, keyword, 0, 20)
                    if not ok then
                        self:info("搜索失败：\n" .. U.first_line(tostring(result or "未知错误"), 160))
                        return
                    end
                    local items = {}
                    for _, book in ipairs(External.normalize_search(result)) do
                        items[#items + 1] = {
                            text = book.title ~= "" and book.title or book.book_id,
                            post_text = book.author,
                            callback = function()
                                self:_external_bind_book(path, book, touchmenu_instance)
                            end,
                        }
                    end
                    self:list("选择匹配的微信读书书籍", items, "没有搜索到相关书籍。")
                end)
            end,
        } } },
    }
    UIManager:show(dialog)
end

function M:_external_bind_book(path, book, touchmenu_instance)
    if type(book) ~= "table" or tostring(book.book_id or "") == "" then
        self:info("匹配信息无效，请重新搜索。")
        return
    end
    local entry = self.external_annotations_db:getDocument(path) or {}
    entry.binding = {
        book_id = tostring(book.book_id),
        title = tostring(book.title or ""),
        author = tostring(book.author or ""),
        format = tostring(book.format or ""),
        bound_at = os.time(),
    }
    entry.records = {}
    entry.stats = nil
    entry.synced_at = nil
    local saved, save_err = self.external_annotations_db:saveDocument(path, entry)
    if not saved then
        self:info("保存匹配失败：" .. tostring(save_err or "未知错误"))
        return
    end
    local cleared, clear_err = self.external_annotations_db:clearSyncCheckpoint(path)
    if not cleared then
        logger.warn("[MiuRead][ExternalAnnotations] checkpoint clear failed:", clear_err)
    end
    if self._external_annotation_overlay then
        self._external_annotation_overlay:setRecords({})
    end
    if touchmenu_instance and type(touchmenu_instance.updateItems) == "function" then
        touchmenu_instance:updateItems()
    end
    UIManager:show(ConfirmBox:new{
        title = "本地书已匹配",
        text = "已匹配《" .. tostring(book.title ~= "" and book.title or book.book_id) .. "》。\n\n现在同步划线与想法吗？\n\n你可以随时取消；已下载的进度会自动保存，下次继续。",
        ok_text = "同步划线与想法",
        cancel_text = "稍后",
        ok_callback = function()
            self:sync_external_annotations()
        end,
    })
end

function M:sync_external_annotations(options)
    local opts = type(options) == "table" and options or {}
    local silent = opts.silent == true
    local on_done = type(opts.on_done) == "function" and opts.on_done or nil
    local path = current_file(self)
    if not path then
        if on_done then on_done(false, "no_file") end
        return false
    end
    if not self:logged_in() then
        if silent then
            if on_done then on_done(false, "not_logged_in") end
        else
            self:info("请先登录微信读书账号。")
        end
        return false
    end
    local entry = current_entry(self)
    if not entry or not entry.binding then
        -- MiuRead downloaded books are auto-bound from the known WeRead id.
        if not self:_external_auto_bind_miuread_book() then
            if silent then
                if on_done then on_done(false, "no_binding") end
            else
                self:info("请先把本地书匹配到微信读书书籍。")
            end
            return false
        end
    end
    if self._external_annotation_sync then
        if silent then
            if on_done then on_done(false, "already_running") end
        else
            self:toast("划线与想法同步正在进行", 2)
        end
        return false
    end
    local function start_quiet()
        local ok, err = xpcall(function()
            self:_sync_external_annotations_start({ silent = true, on_done = on_done })
        end, debug.traceback)
        if not ok and on_done then
            on_done(false, tostring(err or "unknown"))
        end
    end
    if silent then
        if not self:is_online() then
            if on_done then on_done(false, "offline") end
            return false
        end
        UIManager:scheduleIn(.05, start_quiet)
        return true
    end
    self:online("同步划线与想法", function()
        self:_sync_external_annotations_start()
    end)
    return true
end

function M:_sync_external_annotations_start(options)
    local opts = type(options) == "table" and options or {}
    local silent = opts.silent == true
    local on_done = type(opts.on_done) == "function" and opts.on_done or nil
    local path = current_file(self)
    local entry = current_entry(self)
    local binding = entry and entry.binding
    if not path or not binding then
        if on_done then on_done(false, "no_context") end
        return
    end
    if self._external_annotation_sync then
        if on_done then on_done(false, "already_running") end
        return
    end

    local request = {
        path = path,
        entry = entry,
        binding = binding,
        cancelled = false,
        backgrounded = false,
        signal_sent = false,
    }

    local function request_is_current()
        return self._external_annotation_sync == request
            and not request.cancelled
            and current_file(self) == request.path
    end

    local function finish_request()
        if self._external_annotation_sync == request then
            self._external_annotation_sync = nil
        end
        if request.progress then
            request.progress:close("sync_finished")
            request.progress = nil
        end
    end

    local function complete_signal(ok, err)
        if request.signal_sent then return end
        request.signal_sent = true
        if on_done then on_done(ok, err) end
    end

    local function cancel_request()
        if request.cancelled then return end
        request.cancelled = true
        finish_request()
        self:status_toast("同步已取消", "已下载的进度已保存，下次同步会自动继续", 3)
    end

    local function fail_request(err)
        if not request_is_current() then
            finish_request()
            complete_signal(false, "interrupted")
            return
        end
        finish_request()
        logger.warn("[MiuRead][ExternalAnnotations] sync interrupted:", tostring(err))
        complete_signal(false, tostring(err or "unknown"))
        if not silent then
            self:info("划线与想法同步被中断：\n" .. U.first_line(tostring(err or "未知错误"), 160)
                .. "\n\n已下载的进度已保存，重新同步即可继续。")
        end
    end

    local function schedule_step(callback, delay)
        UIManager:scheduleIn(delay or 0.1, function()
            if not request_is_current() then
                if self._external_annotation_sync == request then finish_request() end
                complete_signal(false, "interrupted")
                return
            end
            local ok, err = xpcall(callback, debug.traceback)
            if not ok then fail_request(err) end
        end)
    end

    local function report_progress(stage, percent, opts)
        if not request.progress then return end
        opts = opts or {}
        request.progress:set_state{
            stage = stage or "thoughts",
            current = tonumber(opts.current) or request.completed_count or 0,
            total = tonumber(opts.total) or request.total_chapters or 1,
            percent = tonumber(percent),
            chapter = opts.chapter,
            batch = tonumber(opts.batch),
            batch_total = tonumber(opts.batch_total),
            underlines = tonumber(opts.underlines),
            thoughts = tonumber(opts.thoughts),
            message = opts.message,
        }
    end

    if silent then
        request.progress = nil
    else
        local progress = DownloadProgress:new{
            title = "同步划线与想法",
            cancel_text = "取消同步",
            background_text = "后台同步",
            on_cancel = function()
                cancel_request()
            end,
            on_background = function()
                request.backgrounded = true
                if request.progress then
                    request.progress:close("background")
                    request.progress = nil
                end
                self:toast("已转入后台继续同步，完成后会提醒", 2)
            end,
            on_close = function() end,
        }
        request.progress = progress
        self._external_annotation_sync = request
        progress:show()
        report_progress("prepare", 0, { message = "正在准备同步……" })
    end
    self._external_annotation_sync = request

    local download_next_chapter
    local download_current_review_batch
    local finish_current_chapter
    local finish_sync

    local function load_catalog()
        local payload = self.reader:catalog(binding.book_id)
        local source = External.normalize_catalog(payload, binding.book_id)
        local catalog, seen = {}, {}
        for _, chapter in ipairs(type(source) == "table" and source or {}) do
            local uid = chapter_uid(chapter)
            if uid ~= "" and not seen[uid]
                and tonumber(chapter.wordCount or 0) > 0
                and tostring(chapter.title or "") ~= "封面" then
                seen[uid] = true
                catalog[#catalog + 1] = chapter
            end
        end
        if #catalog == 0 then error("微信读书章节目录为空") end
        return catalog
    end

    finish_sync = function()
        if request.progress then
            report_progress("package", 1, { message = "正在本地书中定位划线……" })
        end
        local chapters = {}
        for _, chapter in ipairs(request.catalog) do
            local uid = chapter_uid(chapter)
            local downloaded = request.completed[uid]
            if downloaded and #(downloaded.underlines or {}) > 0 then
                chapters[#chapters + 1] = downloaded
            end
        end
        local records, stats = External.locate(self.ui.document, chapters)
        if stats.total > 0 and stats.located == 0 then
            error("已下载 " .. tostring(stats.total)
                .. " 条划线，但都无法在本地书中匹配。已有数据未改动，请重试。")
        end
        request.entry.records = records
        request.entry.stats = stats
        request.entry.synced_at = os.time()
        for _, chapter in ipairs(request.catalog or {}) do
            local fetched_uid = chapter_uid(chapter)
            if fetched_uid ~= "" and request.completed[fetched_uid] then
                mark_chapter_fetched(request.entry, fetched_uid)
            end
        end
        local saved, save_err = self.external_annotations_db:saveDocument(
            request.path, request.entry)
        if not saved then error(save_err) end
        local cleared, clear_err = self.external_annotations_db:clearSyncCheckpoint(
            request.path)
        if not cleared then error(clear_err) end
        if self._external_annotation_overlay then
            self._external_annotation_overlay:setRecords(records)
        end
        UIManager:setDirty(self.dialog, "ui")
        finish_request()
        logger.info("[MiuRead][ExternalAnnotations] sync completed:",
            "located=", tostring(stats.located), "total=", tostring(stats.total))
        complete_signal(true, nil)
        if not silent then
            self:info("同步完成：" .. tostring(stats.located) .. "/"
                .. tostring(stats.total) .. " 条划线已匹配。")
        end
    end

    finish_current_chapter = function()
        local value = {
            book_id = tostring(binding.book_id),
            chapter_uid = request.current_uid,
            underlines = request.current_underlines.underlines or {},
            reviews = request.current_reviews,
            complete = true,
        }
        local saved, save_err = self.external_annotations_db:finishSyncChapter(
            request.path, request.current_index, request.current_uid, value)
        if not saved then error(save_err) end
        request.completed[request.current_uid] = value
        request.partials[request.current_uid] = nil
        request.completed_count = request.completed_count + 1
        report_progress("done", request.completed_count / #request.catalog, {
            message = "已完成 " .. tostring(request.completed_count) .. "/" .. tostring(#request.catalog) .. " 章",
        })
        schedule_step(download_next_chapter)
    end

    download_current_review_batch = function()
        local batch_index = request.review_batch_index
        if batch_index > #request.review_batches then
            finish_current_chapter()
            return
        end
        local call_ok, result = pcall(self.api.readreviews, self.api,
            binding.book_id, request.current_api_uid,
            request.review_batches[batch_index])
        if not call_ok or type(result) ~= "table"
            or type(result.reviews) ~= "table" then
            error((not call_ok and result) or "could not download thoughts")
        end
        local saved, save_err = self.external_annotations_db:saveSyncReviewBatch(
            request.path, request.current_uid, batch_index, result.reviews)
        if not saved then error(save_err) end
        for _, review in ipairs(result.reviews) do
            request.current_reviews[#request.current_reviews + 1] = review
        end
        request.review_batch_index = batch_index + 1
        report_progress("thoughts", (request.completed_count
            + (request.review_batch_index - 1) / #request.review_batches)
            / #request.catalog, {
            chapter = tostring(request.current_index) .. ". " .. chapter_title(request.current_chapter),
            batch = request.review_batch_index - 1,
            batch_total = #request.review_batches,
            thoughts = #request.current_reviews,
        })
        schedule_step(download_current_review_batch)
    end

    local function resume_current_chapter(partial)
        request.current_underlines = {
            underlines = type(partial.underlines) == "table"
                and partial.underlines or {},
        }
        request.ranges = collect_ranges(request.current_underlines)
        request.review_batches = self.api:review_batches(request.ranges, REVIEW_BATCH_SIZE)
        request.current_reviews = {}
        request.review_batch_index = 1
        for _, saved_batch in ipairs(partial.review_batches or {}) do
            local saved_index = tonumber(saved_batch.batch_index)
            if saved_index ~= request.review_batch_index
                or saved_index > #request.review_batches then
                break
            end
            for _, review in ipairs(saved_batch.reviews or {}) do
                request.current_reviews[#request.current_reviews + 1] = review
            end
            request.review_batch_index = saved_index + 1
        end
        if #request.review_batches > 0 then
            report_progress("thoughts", (request.completed_count
                + (request.review_batch_index - 1) / #request.review_batches)
                / #request.catalog, {
                chapter = tostring(request.current_index) .. ". " .. chapter_title(request.current_chapter),
                batch = request.review_batch_index - 1,
                batch_total = #request.review_batches,
                thoughts = #request.current_reviews,
                message = "正在恢复本章已下载的想法……",
            })
            schedule_step(download_current_review_batch)
        else
            schedule_step(finish_current_chapter)
        end
    end

    download_next_chapter = function()
        local selected_index, selected_chapter, selected_uid, selected_api_uid
        for chapter_index, chapter in ipairs(request.catalog) do
            local uid = chapter_uid(chapter)
            if not request.completed[uid] then
                selected_index, selected_chapter, selected_uid, selected_api_uid =
                    chapter_index, chapter, uid, (chapter.chapterUid or chapter.chapterId or chapter.uid)
                break
            end
        end
        if not selected_chapter then
            finish_sync()
            return
        end
        request.current_index = selected_index
        request.current_chapter = selected_chapter
        request.current_uid = selected_uid
        request.current_api_uid = selected_api_uid
        report_progress("underlines", request.completed_count / #request.catalog, {
            chapter = tostring(selected_index) .. ". " .. chapter_title(selected_chapter),
            message = "正在获取第 " .. tostring(selected_index) .. "/" .. tostring(#request.catalog) .. " 章划线……",
        })
        local partial = request.partials[selected_uid]
        if partial then
            resume_current_chapter(partial)
            return
        end
        local call_ok, underlines = pcall(self.api.underlines, self.api,
            binding.book_id, selected_api_uid)
        if not call_ok or type(underlines) ~= "table" then
            error((not call_ok and underlines) or "could not download underlines")
        end
        request.current_underlines = underlines
        request.ranges = collect_ranges(underlines)
        request.review_batches = self.api:review_batches(request.ranges, REVIEW_BATCH_SIZE)
        request.review_batch_index = 1
        request.current_reviews = {}
        local partial_value = {
            book_id = tostring(binding.book_id),
            chapter_uid = selected_uid,
            underlines = underlines.underlines or {},
            reviews = {},
            complete = false,
        }
        local saved, save_err = self.external_annotations_db:saveSyncChapter(
            request.path, selected_index, selected_uid, partial_value)
        if not saved then error(save_err) end
        request.partials[selected_uid] = partial_value
        if #request.review_batches > 0 then
            schedule_step(download_current_review_batch)
        else
            schedule_step(finish_current_chapter)
        end
    end

    local function run_personal_sync_if_any()
        request.completed_count = 0
        request.total_chapters = 1
        report_progress("underlines", 0, { message = "正在读取个人划线与想法……" })

        local bookmark_rows = {}
        local ok_bookmarks, value_bookmarks = pcall(
            self.api.bookmark_list, self.api, binding.book_id)
        if ok_bookmarks then bookmark_rows = collect_records(value_bookmarks) end

        local review_rows = {}
        local ok_reviews, value_reviews = pcall(
            self.api.review_list_mine, self.api, binding.book_id, 0, 200)
        if ok_reviews then review_rows = collect_records(value_reviews) end

        if #bookmark_rows == 0 and #review_rows == 0 then return false end

        local chapters, chapters_by_uid = {}, {}
        local seen_underline_keys = {}
        local review_groups_by_key = {}

        local function chapter_for(uid)
            local key = tostring(uid or "")
            if key == "" then key = "__miuread_whole_book__" end
            local chapter = chapters_by_uid[key]
            if not chapter then
                chapter = {
                    book_id = tostring(binding.book_id),
                    chapter_uid = key,
                    underlines = {},
                    reviews = {},
                }
                chapters_by_uid[key] = chapter
                chapters[#chapters + 1] = chapter
            end
            return chapter
        end

        local function add_underline(uid, range, mark_text)
            range = tostring(range or "")
            mark_text = tostring(mark_text or "")
            if range == "" or mark_text == "" then return end
            local key = tostring(uid or "") .. ":" .. range
            if seen_underline_keys[key] then return end
            seen_underline_keys[key] = true
            local chapter = chapter_for(uid)
            chapter.underlines[#chapter.underlines + 1] = {
                range = range,
                markText = mark_text,
            }
        end

        for _, row in ipairs(bookmark_rows) do
            local uid = scalar(row.chapterUid or row.chapter_uid)
            local range = scalar(row.range or row.markRange or row.bookmarkRange)
            local mark_text = scalar(row.markText or row.rangeText
                or row.abstract or row.bookmarkText)
            local bookmark_type = tonumber(row.type or row.bookmarkType or row.markType)
            if bookmark_type ~= 0 and range ~= "" and mark_text ~= "" then
                add_underline(uid, range, mark_text)
            end
        end

        local seen_review_keys = {}
        for _, row in ipairs(review_rows) do
            local range, abstract, content, author_name = review_parts(row)
            if range ~= "" and (content ~= "" or abstract ~= "") then
                local uid = scalar(row.chapterUid or row.chapter_uid)
                local key = uid .. ":" .. range
                local identity = key .. "|" .. author_name .. "|" .. content
                if not seen_review_keys[identity] then
                    seen_review_keys[identity] = true
                    local group = review_groups_by_key[key]
                    if not group then
                        group = { range = range, pageReviews = {} }
                        review_groups_by_key[key] = group
                    end
                    group.pageReviews[#group.pageReviews + 1] = {
                        review = {
                            author = { nick = author_name },
                            content = content,
                            abstract = abstract,
                        },
                        likesCount = tonumber(row.likesCount or row.likes_count
                            or row.likes or 0) or 0,
                    }
                end
                -- A thought range may not have a matching personal underline
                -- record; the review abstract is enough to locate it.
                add_underline(uid, range, abstract)
            end
        end

        for key, group in pairs(review_groups_by_key) do
            local uid = key:match("^(.-):") or ""
            local chapter = chapter_for(uid)
            chapter.reviews[#chapter.reviews + 1] = group
        end

        local located_chapters = {}
        for _, chapter in ipairs(chapters) do
            if #chapter.underlines > 0 then
                located_chapters[#located_chapters + 1] = chapter
            end
        end
        if #located_chapters == 0 then return false end

        report_progress("package", 1, { message = "正在本地书中定位个人划线……" })
        local records, stats = External.locate(self.ui.document, located_chapters)
        if stats.total > 0 and stats.located == 0 then
            error("已读取 " .. tostring(stats.total)
                .. " 条个人划线，但都无法在本地书中匹配。请确认本地文件与导入微信读书的文件一致。")
        end
        request.entry.records = records
        request.entry.stats = stats
        request.entry.synced_at = os.time()
        local saved, save_err = self.external_annotations_db:saveDocument(
            request.path, request.entry)
        if not saved then error(save_err) end
        local cleared, clear_err = self.external_annotations_db:clearSyncCheckpoint(
            request.path)
        if not cleared then error(clear_err) end
        if self._external_annotation_overlay then
            self._external_annotation_overlay:setRecords(records)
        end
        UIManager:setDirty(self.dialog, "ui")
        finish_request()
        logger.info("[MiuRead][ExternalAnnotations] personal sync completed:",
            "located=", tostring(stats.located), "total=", tostring(stats.total))
        complete_signal(true, nil)
        if not silent then
            self:info("同步完成：" .. tostring(stats.located) .. "/"
                .. tostring(stats.total) .. " 条个人划线已匹配。")
        end
        return true
    end

    local function prepare_sync()
        if run_personal_sync_if_any() then return end
        report_progress("catalog", 0, { message = "正在加载微信读书章节目录……" })
        local catalog = load_catalog()
        request.catalog = catalog
        request.total_chapters = #catalog
        local signature = catalog_signature(binding.book_id, catalog)
        local checkpoint = self.external_annotations_db:getSyncCheckpoint(path)
        if not checkpoint
            or tostring(checkpoint.book_id or "") ~= tostring(binding.book_id)
            or checkpoint.catalog_signature ~= signature
            or tonumber(checkpoint.format_version) ~= SYNC_FORMAT_VERSION then
            checkpoint = {
                book_id = tostring(binding.book_id),
                format_version = SYNC_FORMAT_VERSION,
                catalog_signature = signature,
                total = #catalog,
                started_at = os.time(),
                chapters = {},
            }
            local saved, save_err = self.external_annotations_db:replaceSyncCheckpoint(
                path, checkpoint)
            if not saved then error(save_err) end
        end
        request.completed = {}
        request.partials = {}
        request.completed_count = 0
        local catalog_uids = {}
        for _, chapter in ipairs(request.catalog) do
            catalog_uids[chapter_uid(chapter)] = true
        end
        for _, chapter in ipairs(checkpoint.chapters or {}) do
            local uid = tostring(chapter.chapter_uid or "")
            if uid ~= "" and catalog_uids[uid] then
                if chapter.complete == true then
                    request.completed[uid] = chapter
                    request.completed_count = request.completed_count + 1
                else
                    request.partials[uid] = chapter
                end
            end
        end
        report_progress("resume", request.completed_count / #catalog, {
            message = request.completed_count > 0
                and ("正在恢复断点：已完成 " .. tostring(request.completed_count) .. "/" .. tostring(#catalog) .. " 章")
                or "开始下载划线与想法……",
        })
        schedule_step(download_next_chapter)
    end

    schedule_step(prepare_sync)
end

-- ---------------------------------------------------------------------------
-- Dynamic per-chapter sync.
--
-- New downloads are clean editions only. Underlines and thoughts are fetched
-- chapter by chapter as the reader advances (current chapter + next chapter)
-- and projected through the same XPointer overlay. This path is always quiet:
-- no progress window, no confirmation, no toast.
-- ---------------------------------------------------------------------------

local function chapter_cached(entry, uid)
    uid = tostring(uid or "")
    if uid == "" then return false end
    if type(entry.fetched_chapters) == "table" and entry.fetched_chapters[uid] then
        return true
    end
    for _, record in ipairs(type(entry.records) == "table" and entry.records or {}) do
        if tostring(record.chapter_uid or "") == uid then return true end
    end
    return false
end

local function mark_chapter_fetched(entry, uid)
    entry.fetched_chapters = type(entry.fetched_chapters) == "table" and entry.fetched_chapters or {}
    entry.fetched_chapters[tostring(uid or "")] = os.time()
end

local function merge_chapter_records(entry, uid, records)
    uid = tostring(uid or "")
    local out = {}
    for _, record in ipairs(type(entry.records) == "table" and entry.records or {}) do
        if tostring(record.chapter_uid or "") ~= uid then out[#out + 1] = record end
    end
    for _, record in ipairs(type(records) == "table" and records or {}) do
        out[#out + 1] = record
    end
    return out
end

local function dynamic_catalog(self, binding)
    local cache = self._external_dynamic_catalog
    if type(cache) ~= "table" or tostring(cache.book_id or "") ~= tostring(binding.book_id or "") then
        cache = { book_id = tostring(binding.book_id or "") }
        self._external_dynamic_catalog = cache
        local payload = self.reader:catalog(binding.book_id)
        local source = External.normalize_catalog(payload, binding.book_id)
        local catalog, seen = {}, {}
        for _, chapter in ipairs(type(source) == "table" and source or {}) do
            local uid = chapter_uid(chapter)
            if uid ~= "" and not seen[uid]
                and tonumber(chapter.wordCount or 0) > 0
                and tostring(chapter.title or "") ~= "封面" then
                seen[uid] = true
                catalog[#catalog + 1] = chapter
            end
        end
        cache.catalog = catalog
    end
    return cache.catalog or {}
end

function M:sync_external_chapter(options)
    local opts = type(options) == "table" and options or {}
    local requested_uid = tostring(opts.chapter_uid or "")
    local on_done = type(opts.on_done) == "function" and opts.on_done or nil
    local path = current_file(self)
    if not path then return false, "no_file" end
    if is_legacy_notes_variant(self) then return false, "legacy_notes_variant" end
    if not self:logged_in() then return false, "not_logged_in" end
    local entry = current_entry(self)
    if not entry or not entry.binding then
        if not self:_external_auto_bind_miuread_book() then return false, "no_binding" end
        entry = current_entry(self)
    end
    if not entry or not entry.binding then return false, "no_binding" end
    if self._external_annotation_sync or self._external_chapter_sync then
        return false, "already_running"
    end
    if requested_uid == "" then
        local position
        if self.sync and type(self.sync.local_position) == "function" then
            position = self.sync:local_position()
        end
        requested_uid = tostring(position and position.chapter_uid or "")
    end
    if requested_uid == "" then return false, "no_current_chapter" end
    if not self:is_online() then return false, "offline" end

    local request = {
        path = path,
        entry = entry,
        binding = entry.binding,
        chapter_uid = requested_uid,
        cancelled = false,
        signal_sent = false,
    }
    self._external_chapter_sync = request

    local function request_is_current()
        return self._external_chapter_sync == request
            and not request.cancelled
            and current_file(self) == request.path
    end
    local function finish_request()
        if self._external_chapter_sync == request then self._external_chapter_sync = nil end
    end
    local function signal(ok, err, result)
        if request.signal_sent then return end
        request.signal_sent = true
        if on_done then on_done(ok, err, result) end
    end
    local function fail_chapter(err)
        if not request_is_current() then
            finish_request()
            signal(false, "interrupted")
            return
        end
        finish_request()
        logger.warn("[MiuRead][ExternalAnnotations] chapter sync failed:",
            "book=", tostring(request.binding.book_id or ""),
            "chapter=", tostring(request.chapter_uid or ""),
            tostring(err))
        signal(false, tostring(err or "unknown"))
    end
    request.finish_request = finish_request
    request.signal = signal
    request.fail = fail_chapter

    UIManager:scheduleIn(.05, function()
        local ok, err = xpcall(function()
            self:_sync_external_chapter_start(request)
        end, debug.traceback)
        if not ok then fail_chapter(err) end
    end)
    return true
end

function M:_sync_external_chapter_start(request)
    local path = request.path
    local entry = request.entry
    local binding = request.binding
    local uid = request.chapter_uid
    if self._external_chapter_sync ~= request or request.cancelled
        or current_file(self) ~= path then
        request.finish_request()
        request.signal(false, "interrupted")
        return
    end
    local catalog = dynamic_catalog(self, binding)
    local selected_index, selected_chapter, selected_api_uid
    for index, chapter in ipairs(catalog) do
        if chapter_uid(chapter) == uid then
            selected_index, selected_chapter = index, chapter
            selected_api_uid = chapter.chapterUid or chapter.chapterId or chapter.uid
            break
        end
    end
    if not selected_chapter then
        error("chapter not found in catalog: " .. tostring(uid))
    end

    local call_ok, underlines = pcall(self.api.underlines, self.api,
        binding.book_id, selected_api_uid)
    if not call_ok or type(underlines) ~= "table" then
        error((not call_ok and underlines) or "could not download underlines")
    end

    local ranges = collect_ranges(underlines)
    local batches = self.api:review_batches(ranges, REVIEW_BATCH_SIZE) or {}
    local reviews = {}
    for _, batch in ipairs(batches) do
        local review_ok, review_result = pcall(self.api.readreviews, self.api,
            binding.book_id, selected_api_uid, batch)
        if not review_ok or type(review_result) ~= "table"
            or type(review_result.reviews) ~= "table" then
            error((not review_ok and review_result) or "could not download thoughts")
        end
        for _, review in ipairs(review_result.reviews) do
            reviews[#reviews + 1] = review
        end
    end

    local value = {
        book_id = tostring(binding.book_id),
        chapter_uid = uid,
        underlines = underlines.underlines or {},
        reviews = reviews,
        complete = true,
    }
    local saved, save_err = self.external_annotations_db:finishSyncChapter(
        path, selected_index, uid, value)
    if not saved then error(save_err) end

    local records, stats = External.locate(self.ui.document, { value })
    request.entry.records = merge_chapter_records(entry, uid, records)
    mark_chapter_fetched(request.entry, uid)
    -- Dynamic stats count persisted overlay records instead of pretending a
    -- single-chapter locate result describes the whole book.
    request.entry.stats = {
        total = #request.entry.records,
        located = #request.entry.records,
        missing_text = tonumber(stats.missing_text) or 0,
        unmatched = tonumber(stats.unmatched) or 0,
        partial = tonumber(stats.partial) or 0,
    }
    local document_saved, document_err = self.external_annotations_db:saveDocument(
        path, request.entry)
    if not document_saved then error(document_err) end
    if self._external_annotation_overlay then
        self._external_annotation_overlay:setRecords(request.entry.records)
    end
    UIManager:setDirty(self.dialog, "ui")

    local next_uid
    if selected_index and catalog[selected_index + 1] then
        next_uid = chapter_uid(catalog[selected_index + 1])
    end

    request.finish_request()
    logger.info("[MiuRead][ExternalAnnotations] chapter synced:",
        "book=", tostring(binding.book_id or ""), "chapter=", tostring(uid),
        "located=", tostring(stats.located), "total=", tostring(stats.total))
    request.signal(true, nil, { next_uid = next_uid })
end

function M:_external_annotation_next_uid(catalog, current_uid)
    for index, chapter in ipairs(catalog or {}) do
        if chapter_uid(chapter) == tostring(current_uid or "") and catalog[index + 1] then
            return chapter_uid(catalog[index + 1])
        end
    end
    return nil
end

function M:_external_annotation_dynamic_hint()
    if not is_supported(self) or not (self.ui and self.ui.document) then return false end
    -- Hidden means hidden: stop the dynamic prefetch too. Showing again
    -- triggers one immediate hint in toggle_external_annotations().
    if not self:_external_annotations_visible() then return false end
    local entry = current_entry(self)
    if not entry or not entry.binding then
        local now = os.time()
        if now < (tonumber(self._external_dynamic_skip_until) or 0) then return false end
        if not self:_external_auto_bind_miuread_book() then
            -- Arbitrary local books have no WeRead binding. Remember the miss
            -- so page turns do not re-identify the file every few seconds.
            self._external_dynamic_skip_until = now + 120
            return false
        end
        self._external_dynamic_skip_until = nil
        entry = current_entry(self)
    end
    if not entry or not entry.binding then return false end
    local position
    if self.sync and type(self.sync.local_position) == "function" then
        position = self.sync:local_position()
    end
    local current_uid = tostring(position and position.chapter_uid or "")
    if current_uid == "" then return false end

    local wanted = { current_uid }
    local catalog = self._external_dynamic_catalog
        and tostring(self._external_dynamic_catalog.book_id or "") == tostring(entry.binding.book_id or "")
        and self._external_dynamic_catalog.catalog or nil
    -- The first hint must not fetch the catalog on the reader-open path; the
    -- chapter worker loads and caches it, then prefetches the next chapter.
    if type(catalog) == "table" then
        local next_uid = self:_external_annotation_next_uid(catalog, current_uid)
        if next_uid then wanted[#wanted + 1] = next_uid end
    end

    local selected
    for _, uid in ipairs(wanted) do
        if not chapter_cached(entry, uid) then
            selected = uid
            break
        end
    end
    if not selected then
        self._external_pending_chapter_uid = nil
        return false
    end
    self._external_pending_chapter_uid = selected
    if type(self._sync_scheduler_request) == "function" then
        self:_sync_scheduler_request("external_annotations", .4, "dynamic_chapter_" .. selected)
    end
    return true
end

function M:_external_annotation_dynamic_next(current_uid)
    -- Called after a chapter sync completes; queue the following chapter when
    -- it is still missing from the overlay records.
    local entry = current_entry(self)
    if not entry or not entry.binding then return false end
    local binding = entry.binding
    local catalog = self._external_dynamic_catalog
        and tostring(self._external_dynamic_catalog.book_id or "") == tostring(binding.book_id or "")
        and self._external_dynamic_catalog.catalog or nil
    if type(catalog) ~= "table" then
        local ok_catalog, loaded = pcall(dynamic_catalog, self, binding)
        if ok_catalog then catalog = loaded end
    end
    local next_uid = self:_external_annotation_next_uid(catalog, current_uid)
    if not next_uid or chapter_cached(entry, next_uid) then
        self._external_pending_chapter_uid = nil
        return false
    end
    self._external_pending_chapter_uid = next_uid
    if type(self._sync_scheduler_request) == "function" then
        self:_sync_scheduler_request("external_annotations", 1.2, "dynamic_prefetch_" .. next_uid)
    end
    return true
end

function M:_external_annotation_page_update(page)
    if not (self.ui and self.ui.document) then return false end
    if self._external_dynamic_hint_task then return true end
    local now = os.time()
    if now - (tonumber(self._external_dynamic_hint_last) or 0) < 4 then return true end
    local task
    task = function()
        if self._external_dynamic_hint_task ~= task then return end
        self._external_dynamic_hint_task = nil
        self._external_dynamic_hint_last = os.time()
        if self.ui and self.ui.document then
            self:_external_annotation_dynamic_hint()
        end
    end
    self._external_dynamic_hint_task = task
    UIManager:scheduleIn(.70, task)
    return true
end

function M:clear_external_annotations(touchmenu_instance)
    local path = current_file(self)
    if not path then return end
    local cleared, clear_err = self.external_annotations_db:clearDocument(path)
    if not cleared then
        self:info("清除失败：" .. tostring(clear_err or "未知错误"))
        return
    end
    if self._external_annotation_overlay then
        self._external_annotation_overlay:setRecords({})
    end
    UIManager:setDirty(self.dialog, "ui")
    if touchmenu_instance and type(touchmenu_instance.updateItems) == "function" then
        touchmenu_instance:updateItems()
    end
    self:toast("本地书划线与想法数据已清除", 2)
end

function M:toggle_external_annotations()
    local p = self.store:preferences()
    p.external_annotations_visible = not (p.external_annotations_visible ~= false)
    self.store:save_preferences(p)
    if self._external_annotation_overlay then
        self._external_annotation_overlay:setEnabled(p.external_annotations_visible)
        UIManager:setDirty(self.dialog, "ui")
    end
    if not p.external_annotations_visible then
        self:_close_active_thought_popup("external annotations hidden")
        if self._external_popup then
            pcall(UIManager.close, UIManager, self._external_popup)
            self._external_popup = nil
        end
        self:toast("已隐藏本地书划线与想法", 2)
    else
        self:toast("已显示本地书划线与想法", 2)
        self:_external_annotation_dynamic_hint()
    end
    return true
end

function M:_external_annotations_visibility_label()
    return self:_external_annotations_visible() and "已显示" or "已隐藏"
end

function M:external_annotations_menu_items()
    local entry = current_entry(self)
    local binding = entry and entry.binding
    local located = entry and entry.stats and tonumber(entry.stats.located) or nil
    return {
        {
            text = binding and ("已匹配：" .. tostring(binding.title or binding.book_id))
                or "匹配微信读书书籍",
            callback = function(touchmenu_instance)
                self:bind_external_annotations_book(touchmenu_instance)
            end,
        },
        {
            text = located and ("同步划线与想法 · 已匹配 " .. tostring(located))
                or "同步划线与想法",
            enabled_func = function()
                return current_entry(self) ~= nil
                    and current_entry(self).binding ~= nil
            end,
            callback = function()
                self:sync_external_annotations()
            end,
        },
        {
            text = "显示本地书划线与想法",
            post_text = self:_external_annotations_visibility_label(),
            checked_func = function()
                return self:_external_annotations_visible()
            end,
            keep_menu_open = true,
            callback = function()
                self:toggle_external_annotations()
            end,
        },
        {
            text = "清除本地书划线与想法",
            enabled_func = function()
                return current_entry(self) ~= nil
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:clear_external_annotations(touchmenu_instance)
            end,
        },
    }
end

-- True when the external annotation overlay can work for the open document.
-- Any reflowable CREngine book with XPointer support is allowed, including
-- MiuRead-generated books whose embedded underlines are unavailable.
function M:_external_annotations_menu_available()
    if not is_supported(self) then return false end
    if not self.ui.view or type(self.ui.view.registerViewModule) ~= "function" then
        return false
    end
    return true
end

return M
