local B = require("tests.lua.bootstrap")
local Stubs = require("tests.lua.koreader_stubs")

-- sync.lua pulls in ui/uimanager, ui/event etc.; the fake world covers them.
Stubs.install()

local Sync = require("miuread.sync")

local T = {}

local function auth_with(overrides)
    local a = { api_key = "k", cookies = { wr_vid = "v", wr_skey = "s" } }
    if overrides then
        for k, v in pairs(overrides) do a[k] = v end
    end
    return a
end

function T.test_due_when_no_record()
    local due = Sync._keepalive_due(auth_with{}, 1000, 86400, false)
    B.ok(due == true, "first check must be due")
end

function T.test_due_when_past_interval()
    local a = auth_with{ health = { last_renewal_at = 1000 } }
    local due = Sync._keepalive_due(a, 1000 + 86400 + 1, 86400, false)
    B.ok(due == true, "past interval must be due")
end

function T.test_throttled_within_interval()
    local a = auth_with{ health = { last_renewal_at = 1000 } }
    local due, reason = Sync._keepalive_due(a, 1000 + 3600, 86400, false)
    B.eq(due, false)
    B.eq(reason, "throttled")
end

function T.test_not_logged_in()
    local due, reason = Sync._keepalive_due({ api_key = "", cookies = {} }, 1000, 86400, false)
    B.eq(due, false)
    B.eq(reason, "not_logged_in")
end

function T.test_force_bypasses_throttle()
    local a = auth_with{ health = { last_renewal_at = 1000 } }
    local due = Sync._keepalive_due(a, 1001, 86400, true)
    B.ok(due == true, "force must bypass throttle")
end

function T.test_unavailable()
    local due, reason = Sync._keepalive_due(nil, 1000, 86400, false)
    B.eq(due, false)
    B.eq(reason, "unavailable")
end

function T.test_interval_zero_always_due()
    local a = auth_with{ health = { last_renewal_at = 999999 } }
    local due = Sync._keepalive_due(a, 1000000, 0, false)
    B.ok(due == true, "zero interval means always due")
end

return T
