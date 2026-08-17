-- MiuRead crash report controller (opt-in, off by default).
--
-- On startup (end of Plugin:init) it compares crash.log growth against the
-- last-seen marker; when a new crash is detected it assembles a markdown
-- report (diagnostic context + crash tail + recent oplog) and either POSTs it
-- to Config.CRASH_REPORT_ENDPOINT or saves it under the temp dir and notifies
-- the user. Sensitive fields are redacted before anything leaves the device.
--
-- Design notes:
--   * The marker is saved every startup, so a crash that happens after the
--     check is still reported by the next run (the log only grows).
--   * Requires opt-in: preferences.crash_report.enabled == true.
--   * Endpoint payload is {"report": "<markdown>"}; leave the endpoint empty
--     to keep reports local (temp/crash-reports) for manual sharing.
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local Config = require("miuread.config")
local CrashReport = require("miuread.crash_report")
local OpLog = require("miuread.oplog")
local DiagnosticContext = require("miuread.diagnostic_context")
local U = require("miuread.util")

local Plugin = {}

local CRASH_TAIL_BYTES = 4096
local CRASH_LOG_CANDIDATES = { "/tmp/crash.log" }
local REPORT_DIR_NAME = "crash-reports"
local OPLOG_IN_REPORT = 50

local function schedule(delay, fn)
    local ok = pcall(function() UIManager:scheduleIn(delay, fn) end)
    if not ok then pcall(fn) end
end

function Plugin:crash_report_preferences()
    local prefs = self.store:preferences()
    if type(prefs.crash_report) ~= "table" then prefs.crash_report = {} end
    return prefs.crash_report, prefs
end

function Plugin:crash_report_startup()
    if not self.store then return end
    local prefs = self:crash_report_preferences()
    local path = self:_crash_log_path()
    local state = path and self:_crash_log_state(path)

    if prefs.enabled ~= true then
        -- Remember the baseline anyway so enabling later never reports old
        -- crashes from before the feature was turned on.
        if state then self:_crash_report_save_marker(state.size) end
        return
    end
    if not path or not state then
        OpLog.push{ cat = "crash_report", op = "detect", status = "warn", code = "crash.log unavailable" }
        return
    end

    if CrashReport.should_report(prefs.marker, state) then
        local raw = self:_read_crash_tail(path, CRASH_TAIL_BYTES) or ""
        local aligned = CrashReport.extract_tail(raw, CRASH_TAIL_BYTES)
        local tail = CrashReport.redact_text(aligned)
        if CrashReport.is_crash_content(tail) then
            self:_crash_report_dispatch(self:_crash_report_build(path, tail, state))
        else
            OpLog.push{ cat = "crash_report", op = "detect", status = "warn", code = "log grew without crash marker" }
        end
    end
    self:_crash_report_save_marker(state.size)
end

function Plugin:_crash_log_path()
    local ok, value = pcall(function() return logger.crash_log end)
    if ok and type(value) == "string" and value ~= "" then return value end
    for _, candidate in ipairs(CRASH_LOG_CANDIDATES) do
        if U.file_exists(candidate) then return candidate end
    end
    local settings = self.store and self.store.settings_path
    if type(settings) == "string" and settings ~= "" then
        local root = settings:gsub("[/\\]settings[/\\][^/\\]+$", "")
        if root ~= settings then
            local derived = root .. "/crash.log"
            if U.file_exists(derived) then return derived end
        end
    end
    return nil
end

function Plugin:_crash_log_state(path)
    local ok, attrs = pcall(lfs.attributes, path)
    if not ok or type(attrs) ~= "table" then return nil end
    return { size = tonumber(attrs.size) or 0, time = tonumber(attrs.modification) or 0 }
end

function Plugin:_read_crash_tail(path, max_bytes)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local total = f:seek("end")
    local start = math.max(0, total - (max_bytes or CRASH_TAIL_BYTES))
    f:seek("set", start)
    local data = f:read("*a")
    f:close()
    return data or ""
end

function Plugin:_crash_report_build(path, tail, state)
    local device_model = "unknown"
    local ok_device, Device = pcall(require, "device")
    if ok_device and Device then device_model = tostring(Device.model or "unknown") end
    local prefs = self.store:preferences()
    local provider = {
        version = Config.VERSION,
        schema = Config.SCHEMA,
        channel = Config.UPDATE_CHANNEL,
        runtime = self._runtime_mode or "unknown",
        logged_in = (self.logged_in and self:logged_in() == true) or false,
        time = os.date("%Y-%m-%d %H:%M:%S"),
        device = { model = device_model, firmware = "unknown", screen = "?" },
        preferences = prefs,
    }
    local ctx = DiagnosticContext.collect(provider)
    local lines = {}
    for _, entry in ipairs(OpLog.list(OPLOG_IN_REPORT)) do
        lines[#lines + 1] = OpLog.render(entry)
    end
    return CrashReport.build_report({
        version = ctx.version,
        schema = ctx.schema,
        channel = ctx.channel,
        device_label = device_model,
        logged_in = ctx.logged_in,
        time = ctx.time,
        crash_log_path = tostring(path),
        crash_log_size = tostring(state.size or ""),
        crash_tail = tail,
        oplog_entries = lines,
    })
end

function Plugin:_crash_report_dispatch(report)
    local endpoint = tostring(Config.CRASH_REPORT_ENDPOINT or "")
    if endpoint ~= "" then
        schedule(3, function()
            local ok, err = pcall(function()
                local Http = require("miuread.http")
                local http = Http:new(self.store)
                local _, code = http:post_json(endpoint, { report = report }, { retries = 0 })
                if code and code >= 200 and code < 300 then
                    OpLog.push{ cat = "crash_report", op = "send", status = "ok", code = tostring(code) }
                else
                    OpLog.push{ cat = "crash_report", op = "send", status = "fail", code = tostring(code or "nil") }
                end
            end)
            if not ok then
                OpLog.push{ cat = "crash_report", op = "send", status = "fail", code = tostring(err) }
            end
        end)
        return
    end
    -- No endpoint configured: keep a local copy so the existing diagnostic
    -- entry point (工具与维护) can pick it up.
    local dir = self.store.temp_dir .. "/" .. REPORT_DIR_NAME
    if not U.mkdir(dir) then return end
    local path = dir .. "/" .. os.date("%Y%m%d-%H%M%S") .. ".md"
    local written, err = U.atomic_write(path, report, true)
    if written then
        OpLog.push{ cat = "crash_report", op = "save", status = "ok", code = path }
        local ok_toast = pcall(function()
            self:toast("检测到上次异常退出，报告已保存：\n" .. tostring(path), 6)
        end)
        if not ok_toast then
            logger.warn("[MiuRead][CrashReport] toast failed")
        end
    else
        OpLog.push{ cat = "crash_report", op = "save", status = "fail", code = tostring(err or "write failed") }
    end
end

function Plugin:_crash_report_save_marker(size)
    local prefs, all = self:crash_report_preferences()
    prefs.marker = { size = tonumber(size) or 0, time = os.time() }
    self.store:save_preferences(all)
end

local M = {}
function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end
return M
