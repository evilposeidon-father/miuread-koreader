-- Silent sync scheduler for MiuRead.
--
-- Progress and reading time are already automatic; this module adds the same
-- silent behaviour to the two annotation directions (local upload and cloud
-- pull) and later to the one-shot sync shortcut. It owns:
--   * debounce/coalescing (same kind requested repeatedly = one dispatch)
--   * the run gate (logged in, online, not busy)
--   * silent retry with linear backoff
--   * a small status table for the shortcut's "yellow dot"
--
-- The host supplies timing and actions; this module stays pure and testable.
local Scheduler = {}
Scheduler.__index = Scheduler

local KINDS = {
    local_annotations = true,
    external_annotations = true,
    reading_time = true,
    progress = true,
}

function Scheduler.new(host)
    host = host or {}
    return setmetatable({
        host = host,
        clock = host.clock or os.time,
        default_delay = tonumber(host.default_delay) or 12,
        backoff_base = tonumber(host.backoff_base) or 20,
        backoff_max = tonumber(host.backoff_max) or 600,
        timer = nil,
        state = {},
    }, Scheduler)
end

local function kind_state(self, kind)
    local state = self.state[kind]
    if not state then
        state = {
            dirty = false,
            due_at = 0,
            running = false,
            attempts = 0,
            failures = 0,
            last_ok_at = 0,
            last_error = nil,
            last_attempt_at = 0,
        }
        self.state[kind] = state
    end
    return state
end

local function backoff(self, failures)
    local base = self.backoff_base
    return math.min(self.backoff_max, base * math.min(failures, 8))
end

function Scheduler:request(kind, delay, reason)
    if not KINDS[kind] then return false end
    local state = kind_state(self, kind)
    state.dirty = true
    state.reason = tostring(reason or "requested")
    state.due_at = math.max(state.due_at, self.clock() + (tonumber(delay) or self.default_delay))
    self:_ensure_timer()
    return true
end

function Scheduler:cancel(kind)
    local state = self.state[kind]
    if not state then return false end
    state.dirty = false
    state.running = false
    state.due_at = 0
    self:_ensure_timer()
    return true
end

function Scheduler:cancel_all()
    for kind in pairs(KINDS) do
        local state = self.state[kind]
        if state then
            state.dirty = false
            state.running = false
            state.due_at = 0
        end
    end
    self:_ensure_timer()
    return true
end

function Scheduler:run_now(kind, force)
    if not KINDS[kind] then return false end
    local state = kind_state(self, kind)
    state.dirty = true
    state.due_at = 0
    state.reason = "forced"
    return self:_dispatch(kind, state, force == true)
end

function Scheduler:record_result(kind, ok, err)
    local state = kind_state(self, kind)
    state.running = false
    state.last_attempt_at = self.clock()
    if ok then
        state.failures = 0
        state.last_ok_at = self.clock()
        state.last_error = nil
    else
        state.failures = state.failures + 1
        state.last_error = tostring(err or "unknown")
        -- Silently schedule a retry; the caller does not see anything.
        self:request(kind, backoff(self, state.failures), "retry_" .. tostring(state.failures))
    end
    return ok
end

function Scheduler:status()
    local summary = { dirty = 0, running = 0, failed = 0, pending = 0, kinds = {} }
    local now = self.clock()
    for kind in pairs(KINDS) do
        local state = self.state[kind]
        if state then
            local failed = state.failures > 0 or state.last_error ~= nil
            summary.kinds[kind] = {
                dirty = state.dirty,
                running = state.running,
                failed = failed,
                failures = state.failures,
                last_error = state.last_error,
                last_ok_at = state.last_ok_at,
            }
            if state.dirty or (state.due_at > now) then summary.pending = summary.pending + 1 end
            if state.running then summary.running = summary.running + 1 end
            if failed then summary.failed = summary.failed + 1 end
        end
    end
    return summary
end

function Scheduler:status_label()
    local summary = self:status()
    if summary.running > 0 then return "同步中" end
    if summary.failed > 0 then return tostring(summary.failed) .. " 项未完成" end
    if summary.pending > 0 then return "等待同步" end
    return "已同步"
end

function Scheduler:_dispatch(kind, state, force)
    if state.running then return false end
    local now = self.clock()
    if not force and (not state.dirty or state.due_at > now) then return false end
    if not force and not self.host:gate(kind) then
        -- Gate closed: keep dirty and retry later silently.
        state.due_at = now + math.max(8, self.backoff_base)
        self:_ensure_timer()
        return false, "gate_blocked"
    end
    state.dirty = false
    state.running = true
    state.attempts = state.attempts + 1
    local started, err = self.host:run(kind, function(ok, action_err)
        self:record_result(kind, ok, action_err)
    end)
    if started == false then
        if err == "skip" then
            -- The action is not applicable right now (for example a reader-only
            -- pull requested from the home screen). Do not retry and do not
            -- count it as a failure; a later request can schedule it again.
            state.running = false
            state.dirty = false
            state.due_at = 0
            state.reason = "skipped"
            state.last_error = nil
            return false, "skipped"
        end
        if err == "busy" then
            -- The action is already running somewhere else. Keep the request
            -- dirty and retry silently without recording a failure.
            state.running = false
            state.dirty = true
            state.due_at = now + math.max(8, self.backoff_base)
            state.reason = "busy"
            self:_ensure_timer()
            return false, "busy"
        end
        self:record_result(kind, false, err)
        return false, tostring(err or "action_unavailable")
    end
    return true
end

function Scheduler:_ensure_timer()
    local next_due
    local now = self.clock()
    for kind in pairs(KINDS) do
        local state = self.state[kind]
        if state and state.dirty and not state.running and state.due_at > now then
            if next_due == nil or state.due_at < next_due then next_due = state.due_at end
        end
    end
    if self.timer then
        self.host:cancel(self.timer)
        self.timer = nil
    end
    if next_due then
        local delay = math.max(0.5, next_due - self.clock())
        self.timer = self.host:schedule(delay, function()
            self.timer = nil
            self:tick()
        end)
    end
    return self.timer ~= nil
end

function Scheduler:tick()
    local now = self.clock()
    for kind in pairs(KINDS) do
        local state = self.state[kind]
        if state and state.dirty and not state.running and state.due_at <= now then
            self:_dispatch(kind, state, false)
        end
    end
    self:_ensure_timer()
end

return Scheduler
