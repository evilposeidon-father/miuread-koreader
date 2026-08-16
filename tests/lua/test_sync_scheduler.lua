local B = require("tests.lua.bootstrap")
local Scheduler = require("miuread.sync_scheduler")

local T = {}

local function fake_host(now)
    local host = {
        now = now or 1000,
        gate_open = true,
        runs = {},
        timers = {},
        next_token = 1,
    }
    host.clock = function() return host.now end
    function host:schedule(delay, fn)
        local token = self.next_token
        self.next_token = token + 1
        self.timers[token] = { delay = delay, fn = fn, cancelled = false }
        return token
    end
    function host:cancel(token)
        if self.timers[token] then self.timers[token].cancelled = true end
    end
    function host:gate(kind) return self.gate_open end
    function host:run(kind, callback)
        self.runs[#self.runs + 1] = { kind = kind, callback = callback }
        return true
    end
    return host
end

local function fire_timer(host, token)
    local entry = host.timers[token]
    if entry and not entry.cancelled then
        entry.cancelled = true
        entry.fn()
    end
end

local function fire_earliest(host)
    local earliest_token, earliest_delay
    for token, entry in pairs(host.timers) do
        if not entry.cancelled and (earliest_delay == nil or entry.delay < earliest_delay) then
            earliest_token, earliest_delay = token, entry.delay
        end
    end
    if earliest_token then fire_timer(host, earliest_token) end
end

function T.test_debounce_coalesces_same_kind()
    local host = fake_host(1000)
    host.default_delay = 10
    local s = Scheduler.new(host)
    s:request("local_annotations", 10, "first")
    host.now = 1005
    s:request("local_annotations", 10, "second")
    host.now = 1015
    s:tick()
    B.eq(#host.runs, 1, "two requests within window dispatch once")
    B.eq(host.runs[1].kind, "local_annotations")
end

function T.test_gate_blocks_and_retries_later()
    local host = fake_host(1000)
    host.gate_open = false
    host.default_delay = 0
    host.backoff_base = 20
    local s = Scheduler.new(host)
    s:request("external_annotations", 0, "test")
    s:tick()
    B.eq(#host.runs, 0, "gate closed prevents dispatch")
    host.gate_open = true
    host.now = 1060
    s:tick()
    B.eq(#host.runs, 1, "dispatch after gate opens")
end

function T.test_failure_backoff_and_recovery()
    local host = fake_host(1000)
    host.default_delay = 0
    host.backoff_base = 20
    host.backoff_max = 600
    local s = Scheduler.new(host)
    s:request("local_annotations", 0, "test")
    s:tick()
    B.eq(#host.runs, 1)
    host.runs[1].callback(false, "boom")
    B.eq(s:status().failed, 1, "failure visible in status")
    host.now = 1040
    s:tick()
    B.eq(#host.runs, 2, "retry scheduled with backoff")
    host.runs[2].callback(true)
    B.eq(s:status().failed, 0, "success clears failure")
    B.eq(s:status_label(), "已同步")
end

function T.test_force_run_bypasses_gate_and_due()
    local host = fake_host(1000)
    host.gate_open = false
    host.default_delay = 100
    local s = Scheduler.new(host)
    local started, err = s:run_now("progress", true)
    B.eq(started, true, "force dispatches even when gate closed")
    B.eq(#host.runs, 1)
    B.eq(err, nil)
end

function T.test_status_label_transitions()
    local host = fake_host(1000)
    host.default_delay = 60
    local s = Scheduler.new(host)
    B.eq(s:status_label(), "已同步")
    s:request("local_annotations", 60, "test")
    B.eq(s:status_label(), "等待同步")
    s:run_now("local_annotations", true)
    B.eq(s:status_label(), "同步中")
end

function T.test_unknown_kind_rejected()
    local host = fake_host(1000)
    local s = Scheduler.new(host)
    B.eq(s:request("bogus", 1, "x"), false)
end

return T
