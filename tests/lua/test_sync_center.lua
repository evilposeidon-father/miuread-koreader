local B = require("tests.lua.bootstrap")
local Scheduler = require("miuread.sync_scheduler")

-- Install a deterministic UIManager before the controller is first loaded.
local timers = {}
local next_token = 1
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, delay, fn)
            local token = next_token
            next_token = next_token + 1
            timers[token] = { delay = delay, fn = fn }
            return token
        end,
        unschedule = function(_, token)
            timers[token] = nil
        end,
    }
end

local SyncCenter = require("miuread.plugin_sync_center")

local T = {}

local function fake_plugin()
    local plugin = {
        logged_in_state = true,
        online_state = true,
        ui = { document = { file = "/tmp/book.epub" } },
        toasts = {},
        calls = {},
        store = {},
    }
    function plugin.store:preferences() return plugin.preferences end
    plugin.preferences = { sync = { progress_enabled = true, time_enabled = true } }
    function plugin:logged_in() return self.logged_in_state end
    function plugin:is_online() return self.online_state end
    function plugin:status_toast(title, text, timeout)
        self.toasts[#self.toasts + 1] = { title = title, text = text, timeout = timeout }
    end
    function plugin:_sync_all_pending_annotations(callback)
        self.calls.local_annotations = (self.calls.local_annotations or 0) + 1
        self._pending_annotation_callback = callback
        return true
    end
    function plugin:_external_current_file() return self.ui and self.ui.document and self.ui.document.file end
    function plugin:_external_current_entry() return self.external_entry end
    function plugin:_external_auto_bind_miuread_book()
        self.calls.auto_bind = (self.calls.auto_bind or 0) + 1
        return self.auto_bind_result == true
    end
    function plugin:sync_external_chapter(options)
        self.calls.external_annotations = (self.calls.external_annotations or 0) + 1
        self._external_options = options
        if self.external_start_result == false then return false end
        return true
    end
    function plugin:_external_annotation_dynamic_next(uid)
        self.calls.external_next = (self.calls.external_next or 0) + 1
        self.calls.external_next_uid = uid
        return true
    end
    function plugin:ensure_read_report_progress(reason, automatic)
        self.calls.progress = (self.calls.progress or 0) + 1
        return self.progress_start_result ~= false
    end
    function plugin:show_sync_status(detail) self.calls.show_sync_status = detail end
    plugin.sync = {}
    function plugin.sync:record() return { book = { book_id = "42" } } end
    function plugin.sync:start(reason) return plugin.time_start_result ~= false end
    plugin.annotation_async = { busy = function() return plugin.annotation_busy == true end }
    SyncCenter.install(plugin)
    return plugin
end

function T.test_install_and_scheduler_creation()
    local plugin = fake_plugin()
    local scheduler = plugin:_ensure_sync_scheduler()
    B.ok(scheduler ~= nil, "scheduler created")
    B.eq(plugin:_ensure_sync_scheduler(), scheduler, "scheduler is cached")
    B.eq(plugin:_sync_scheduler_request("local_annotations", 30, "test"), true)
    B.eq(plugin:_sync_scheduler_status_label(), "等待同步")
    B.eq(plugin:_sync_scheduler_cancel("local_annotations"), true)
    B.eq(plugin:_sync_scheduler_status_label(), "已同步")
end

function T.test_gate_requires_login_online_and_not_suspended()
    local plugin = fake_plugin()
    B.eq(plugin:_sync_gate_allowed("local_annotations"), true)
    plugin.logged_in_state = false
    B.eq(plugin:_sync_gate_allowed("local_annotations"), false, "logout closes gate")
    plugin.logged_in_state = true
    plugin.online_state = false
    B.eq(plugin:_sync_gate_allowed("local_annotations"), false, "offline closes gate")
    plugin.online_state = true
    plugin._miuread_suspended = true
    B.eq(plugin:_sync_gate_allowed("local_annotations"), false, "suspend closes gate")
end

function T.test_local_annotation_action_signals_completion()
    local plugin = fake_plugin()
    plugin:_sync_scheduler_request("local_annotations", 0, "test")
    plugin:_sync_scheduler_run_now("local_annotations", true)
    B.eq(plugin.calls.local_annotations, 1, "annotation worker started")
    B.ok(plugin._pending_annotation_callback ~= nil)
    B.eq(plugin:_sync_scheduler_status_label(), "同步中")
    plugin._pending_annotation_callback(true, { synced = 2, deleted = 0, failed = 0 })
    B.eq(plugin:_sync_scheduler_status_label(), "已同步")
end

function T.test_external_action_skips_without_binding()
    local plugin = fake_plugin()
    plugin.external_entry = {}
    plugin.auto_bind_result = false
    local started, err = plugin:_sync_scheduler_run_now("external_annotations", true)
    B.eq(started, false, "reader pull without binding does not start")
    B.eq(err, "skipped")
    B.eq(plugin.calls.external_annotations, nil, "manual sync entry point not reached")
    B.eq(plugin:_sync_scheduler_status_label(), "已同步", "skip is not reported as failure")
end

function T.test_external_action_starts_quiet_sync()
    local plugin = fake_plugin()
    plugin.external_entry = { binding = { book_id = "42" } }
    plugin._external_pending_chapter_uid = "u7"
    local started = plugin:_sync_scheduler_run_now("external_annotations", true)
    B.eq(started, true, "bound book starts quiet per-chapter pull")
    B.eq(plugin.calls.external_annotations, 1)
    B.ok(plugin._external_options and plugin._external_options.silent == true, "silent option set")
    B.eq(plugin._external_options.chapter_uid, "u7", "pending chapter passed through")
    B.ok(type(plugin._external_options.on_done) == "function", "completion callback supplied")
    plugin._external_options.on_done(true, nil, { next_uid = "u8" })
    B.eq(plugin.calls.external_next, 1, "next chapter prefetch queued after success")
    B.eq(plugin:_sync_scheduler_status_label(), "已同步")
end

function T.test_progress_and_reading_time_trigger_or_skip()
    local plugin = fake_plugin()
    plugin.progress_start_result = true
    plugin.time_start_result = true
    B.eq(plugin:_sync_scheduler_run_now("progress", true), true, "progress trigger accepted")
    B.eq(plugin:_sync_scheduler_run_now("reading_time", true), true, "read-time trigger accepted")
    plugin.preferences.sync.progress_enabled = false
    plugin.preferences.sync.time_enabled = false
    B.eq(plugin:_sync_scheduler_run_now("progress", true), false, "disabled progress skips")
    B.eq(plugin:_sync_scheduler_run_now("reading_time", true), false, "disabled time skips")
end

function T.test_shortcut_toasts()
    local plugin = fake_plugin()
    plugin:_sync_shortcut()
    B.eq(plugin.toasts[1].title, "觅阅同步")
    plugin.calls.show_sync_status = nil
    plugin:_sync_shortcut_diagnostics()
    B.eq(plugin.calls.show_sync_status, true, "long-press opens diagnostics")
end

return T
