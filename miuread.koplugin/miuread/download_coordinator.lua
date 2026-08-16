-- Download state / queue coordinator for MiuRead.
--
-- Deep module behind the plugin_download controller. It owns the persisted
-- download state semantics (active-state merge, throttle writes, payload
-- shape), queue invariants (duplicate detection, one-waiting limit) and the
-- "can the next queued job start" decision. UI remains in the controller;
-- this module only reads/writes the store and computes values, so it is fully
-- testable with an in-memory fake store.
local U = require("miuread.util")

local DownloadCoordinator = {}
DownloadCoordinator.__index = DownloadCoordinator

function DownloadCoordinator.new(store, clock)
    clock = clock or os.time
    return setmetatable({
        store = store,
        clock = clock,
        last_write = 0,
        last_stage = nil,
    }, DownloadCoordinator)
end

function DownloadCoordinator:percent(state)
    state = state or {}
    local p = tonumber(state.percent)
    if not p then
        local current, total = tonumber(state.current) or 0, tonumber(state.total) or 0
        p = total > 0 and current / total or 0
    elseif p > 1 then
        p = p / 100
    end
    if p < 0 then p = 0 elseif p > 1 then p = 1 end
    return math.floor(p * 100 + 0.5)
end

function DownloadCoordinator:active_state(runtime, task_busy)
    if runtime and task_busy then
        local state = U.copy(runtime.last_state or {})
        state.status = "active"
        state.title = runtime.book and runtime.book.title or state.title
        state.book_id = runtime.book and runtime.book.bookId or state.book_id
        state.background = runtime.background == true
        return state
    end
    return self.store:download_state()
end

function DownloadCoordinator:has_status(task_busy)
    if task_busy then return true end
    local state = self.store:download_state()
    if state.status == "completed" then
        self.store:clear_download_state()
        return false
    end
    return state.status == "failed" or state.status == "interrupted"
        or state.status == "pending_install" or state.status == "annotation_pending"
end

function DownloadCoordinator:status_label(runtime, task_busy)
    local state = self:active_state(runtime, task_busy)
    if state.status == "active" then
        if state.stage == "rate_limit" then
            local wait = tonumber(state.wait_seconds) or 0
            return wait > 0 and ("后台下载 · 请求受限，" .. tostring(wait) .. "秒后继续")
                or "后台下载 · 请求受限，等待恢复"
        end
        if state.stage == "restart" then return "后台下载 · 正在从断点恢复" end
        if state.waiting_network == true or state.stage == "waiting_network" then
            return "后台下载 · 等待网络，已保存进度"
        end
        local title = U.utf8_truncate(state.title or "未命名", 9)
        return "后台下载：《" .. title .. "》 " .. tostring(self:percent(state)) .. "%"
    end
    if state.status == "pending_install" then return "后台下载 · 等待更新" end
    if state.status == "annotation_pending" then return "后台下载 · 正文已完成，批注待修复" end
    if state.status == "completed" then return "后台下载 · 已完成" end
    if state.status == "failed" and state.auth_required == true then return "后台下载 · 等待重新登录" end
    if state.status == "failed" and state.error_kind == "network" then return "后台下载 · 等待网络，可继续" end
    if state.status == "failed" and state.error_kind == "image_missing" then return "后台下载 · 正文图片待修复" end
    if state.status == "failed" then return "后台下载 · 未完成" end
    if state.status == "interrupted" then return "后台下载 · 可继续" end
    return "后台下载"
end

function DownloadCoordinator:write_state(status, patch, force)
    local now = self.clock()
    local stage = patch and patch.stage
    if not force and status == "active"
        and now - self.last_write < 2 and stage == self.last_stage then
        return false
    end
    local state
    if force or status ~= "active" then
        state = U.copy(patch or {})
    else
        state = U.merge(self.store:download_state(), patch or {})
    end
    state.status = status
    state.updated_at = now
    self.store:save_download_state(state)
    self.last_write = now
    self.last_stage = stage
    return true
end

function DownloadCoordinator:active_payload(runtime, state, task_descriptor)
    local task = task_descriptor or runtime.task
    return {
        title = runtime.book and runtime.book.title or "未命名",
        book_id = runtime.book and runtime.book.bookId or "",
        book = U.copy(runtime.book or {}),
        options = U.copy(runtime.options or {}),
        background = runtime.background == true,
        stage = state and state.stage or "prepare",
        current = state and state.current or 0,
        total = state and state.total or 0,
        percent = state and state.percent or 0,
        chapter = state and state.chapter or "",
        message = state and state.message or "",
        waiting_network = state and (state.waiting_network == true or state.stage == "waiting_network") or nil,
        wait_seconds = state and state.wait_seconds or nil,
        rate_limit_code = state and state.rate_limit_code or nil,
        started_at = runtime.started_at,
        task = U.copy(task),
    }
end

function DownloadCoordinator:job_key(book, opt)
    opt = opt or {}
    local kind = opt.annotations and "notes" or "clean"
    return table.concat({
        tostring(book and book.bookId or ""), kind, tostring(opt.chapter_uid or "full"),
        tostring(opt.limit or "all"), tostring(opt.range_start_index or ""),
        tostring(opt.range_end_index or ""),
    }, ":")
end

-- Returns "active" when the current runtime is the same book/job, or
-- "queued", job, index when a queued job duplicates it.
function DownloadCoordinator:find_duplicate(book, opt, runtime_book, runtime_options)
    local key = self:job_key(book, opt)
    local book_id = tostring(book and (book.bookId or book.book_id) or "")
    if runtime_book then
        local runtime_id = tostring(runtime_book.bookId or runtime_book.book_id or "")
        if (book_id ~= "" and runtime_id == book_id)
            or self:job_key(runtime_book, runtime_options) == key then
            return "active"
        end
    end
    for index, job in ipairs(self.store:download_queue()) do
        local queued_id = tostring(job.book and (job.book.bookId or job.book.book_id) or "")
        if (book_id ~= "" and queued_id == book_id) or tostring(job.key or "") == key then
            return "queued", job, index
        end
    end
    return nil
end

function DownloadCoordinator:enqueue(book, opt, open_after, extra)
    extra = type(extra) == "table" and extra or {}
    local job = {
        key = self:job_key(book, opt),
        book = U.copy(book or {}),
        options = U.copy(opt or {}),
        open_after = open_after == true,
        queued_at = self.clock(),
        defer_until_reader_closed = extra.defer_until_reader_closed == true or nil,
        wait_reason = extra.reason,
    }
    local position, reason = self.store:enqueue_download(job)
    return position, reason, job
end

-- Returns true, next_job when the next queued job may start now.
function DownloadCoordinator:can_start_next(task_busy, has_runtime, online, logged_in, reader_active)
    if task_busy or has_runtime then return false end
    local state = self.store:download_state()
    if state.status == "active" or state.status == "failed" or state.status == "interrupted" then
        return false
    end
    if not online or not logged_in then return false end
    local next_job = self.store:download_queue()[1]
    if not next_job then return false end
    if next_job.defer_until_reader_closed == true and reader_active then return false end
    return true, next_job
end

function DownloadCoordinator:dequeue_next()
    return self.store:dequeue_download()
end

return DownloadCoordinator
