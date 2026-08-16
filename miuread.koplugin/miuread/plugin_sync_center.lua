-- MiuRead silent sync center controller.
--
-- The heavy lifting lives in miuread/sync_scheduler.lua (debounce, gate,
-- silent retry, status). This controller adapts that pure module to the
-- Plugin: UIManager is the timer, logged_in/is_online/busy are the gate, and
-- the existing annotation/progress/read-time entry points are the actions.
--
-- Reading progress and reading time are already automatic services; the
-- scheduler only triggers them on the explicit sync-all shortcut and never
-- claims ownership of their retry loops.
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Scheduler = require("miuread.sync_scheduler")

local Plugin = {}

function Plugin:_ensure_sync_scheduler()
    if self._sync_scheduler then return self._sync_scheduler end
    local plugin_self = self
    local host = {
        clock = function() return os.time() end,
        default_delay = 12,
        backoff_base = 20,
        backoff_max = 600,
    }
    function host:schedule(delay, fn)
        return UIManager:scheduleIn(delay, fn)
    end
    function host:cancel(token)
        if token then UIManager:unschedule(token) end
    end
    function host:gate(kind)
        return plugin_self:_sync_gate_allowed(kind)
    end
    function host:run(kind, callback)
        return plugin_self:_sync_scheduler_run_action(kind, callback)
    end
    self._sync_scheduler = Scheduler.new(host)
    return self._sync_scheduler
end

function Plugin:_sync_scheduler_request(kind, delay, reason)
    return self:_ensure_sync_scheduler():request(kind, delay, reason)
end

function Plugin:_sync_scheduler_cancel(kind)
    local scheduler = self._sync_scheduler
    if scheduler then return scheduler:cancel(kind) end
    return false
end

function Plugin:_sync_scheduler_cancel_all()
    local scheduler = self._sync_scheduler
    if scheduler then return scheduler:cancel_all() end
    return false
end

function Plugin:_sync_scheduler_run_now(kind, force)
    return self:_ensure_sync_scheduler():run_now(kind, force)
end

function Plugin:_sync_scheduler_status_label()
    local scheduler = self._sync_scheduler
    if not scheduler then return "已同步" end
    return scheduler:status_label()
end

function Plugin:_sync_preferences()
    local store = self.store
    if not store or type(store.preferences) ~= "function" then return nil end
    local ok, prefs = pcall(store.preferences, store)
    if not ok then return nil end
    return prefs or nil
end

function Plugin:_sync_gate_allowed(kind)
    if not self:logged_in() then return false end
    if not self:is_online() then return false end
    if self._miuread_suspended == true then return false end
    if kind == "local_annotations" then
        if self.annotation_async and self.annotation_async:busy() then return false end
        return true
    end
    if kind == "external_annotations" then
        -- Reader-only pull: a home-screen request stays silent and waits for
        -- the next book open instead of becoming a retry storm.
        if self._external_annotation_sync then return false end
        if not (self.ui and self.ui.document) then return false end
        return true
    end
    -- Progress and reading time run on their own automatic services and are
    -- only triggered explicitly by the shortcut, so their gate is shared.
    return false
end

function Plugin:_sync_scheduler_run_action(kind, callback)
    if kind == "local_annotations" then
        if not self:logged_in() then return false, "skip" end
        if not self:is_online() then return false, "busy" end
        if self.annotation_async and self.annotation_async:busy() then return false, "busy" end
        local started = self:_sync_all_pending_annotations(function(ok, result)
            callback(ok, type(result) == "table" and result.error or nil)
        end)
        if not started then return false, "busy" end
        return true
    end
    if kind == "external_annotations" then
        return self:_sync_external_annotations_quiet(callback)
    end
    if kind == "reading_time" then
        return self:_sync_reading_time_quiet(callback)
    end
    if kind == "progress" then
        return self:_sync_progress_quiet(callback)
    end
    return false, "skip"
end

function Plugin:_sync_external_annotations_quiet(callback)
    if self._external_annotation_sync then return false, "busy" end
    if not (self.ui and self.ui.document) then return false, "skip" end
    if not self:is_online() then return false, "busy" end
    local ok_path, path = pcall(self._external_current_file, self)
    if not ok_path or not path then return false, "skip" end
    local ok_entry, entry = pcall(self._external_current_entry, self)
    if ok_entry and entry and entry.binding then
        -- binding is ready; fall through to start below
    else
        local ok_bind, bound = pcall(self._external_auto_bind_miuread_book, self)
        if not ok_bind or not bound then return false, "skip" end
    end
    -- Preconditions are validated above, so the quiet entry point below should
    -- start rather than present a manual dialog or toast.
    local started = self:sync_external_annotations({
        silent = true,
        on_done = function(ok, err)
            callback(ok, err)
        end,
    })
    if not started then return false, "busy" end
    return true
end

function Plugin:_sync_reading_time_quiet(callback)
    local prefs = self:_sync_preferences() or {}
    local sync_prefs = prefs.sync or {}
    if sync_prefs.time_enabled ~= true then return false, "skip" end
    if not (self.sync and self.sync:record()) then return false, "skip" end
    local started = self.sync:start("sync_all_shortcut")
    if not started then
        -- "position not verified yet" is owned by the progress pipeline, not
        -- a read-time failure. The shortcut trigger is enough.
        return false, "skip"
    end
    callback(true, nil)
    return true
end

function Plugin:_sync_progress_quiet(callback)
    local prefs = self:_sync_preferences() or {}
    local sync_prefs = prefs.sync or {}
    if sync_prefs.progress_enabled == false then return false, "skip" end
    if not (self.ui and self.ui.document) then return false, "skip" end
    if self._progress_check_running then return false, "busy" end
    if not (self.sync and self.sync:record()) then return false, "skip" end
    local started = self:ensure_read_report_progress("sync_all_shortcut", true)
    if not started then return false, "busy" end
    -- The progress pipeline verifies and retries on its own; the scheduler
    -- records only that the trigger was accepted.
    callback(true, nil)
    return true
end

function Plugin:_sync_scheduler_force_all()
    local scheduler = self:_ensure_sync_scheduler()
    local started_any = false
    for _, kind in ipairs({
        "local_annotations",
        "external_annotations",
        "reading_time",
        "progress",
    }) do
        if scheduler:run_now(kind, true) then started_any = true end
    end
    return started_any
end

function Plugin:_sync_shortcut()
    if not self:logged_in() then
        self:info("请先登录微信读书账号。")
        return false
    end
    local started = self:_sync_scheduler_force_all()
    if started then
        self:status_toast("觅阅同步", "已开始后台同步", 2)
    else
        self:status_toast("觅阅同步", self:_sync_scheduler_status_label(), 2)
    end
    return started
end

function Plugin:_sync_shortcut_diagnostics()
    self:show_sync_status(true)
    return true
end

function Plugin:_sync_scheduler_log_state(reason)
    local scheduler = self._sync_scheduler
    if not scheduler then return end
    logger.info("[MiuRead][SyncCenter] scheduler state",
        "reason=", tostring(reason or "state"),
        "label=", tostring(scheduler:status_label()))
end

local M = {}

function M.install(target)
    for name, method in pairs(Plugin) do
        target[name] = method
    end
end

return M
