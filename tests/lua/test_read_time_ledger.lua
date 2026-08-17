local B = require("tests.lua.bootstrap")

local Ledger = require("miuread.read_time_ledger")

local T = {}

-- Monday 2026-08-17 12:00 local (epoch depends on TZ; use os.time from a table)
local function local_monday_noon()
    local now = os.time({year = 2026, month = 8, day = 17, hour = 12})
    local t = os.date("*t", now)
    if t.wday ~= 2 then
        -- Adjust to the Monday of that week (portable across TZ/daylight).
        now = now - ((t.wday + 5) % 7) * 86400
        t = os.date("*t", now)
    end
    return os.time({year = t.year, month = t.month, day = t.day, hour = 12})
end

function T.test_add_accumulates_today()
    local now = local_monday_noon()
    local ledger = Ledger.add({}, 120, now)
    ledger = Ledger.add(ledger, 60, now)
    B.eq(Ledger.today(ledger, now), 180, "today accumulates")
end

function T.test_week_includes_monday_only_bucket()
    local monday = local_monday_noon()
    local sunday_after = monday + 6 * 86400
    local next_monday = monday + 7 * 86400
    local ledger = Ledger.add({}, 300, monday)
    ledger = Ledger.add(ledger, 200, sunday_after)
    B.eq(Ledger.week(ledger, sunday_after), 500, "same week sums")
    B.eq(Ledger.week(ledger, next_monday), 0, "new week excludes old days")
end

function T.test_format()
    B.eq(Ledger.format(0), "0 分钟")
    B.eq(Ledger.format(60), "1 分钟")
    B.eq(Ledger.format(3900), "1 小时 5 分")
end

function T.test_flush_due()
    B.ok(Ledger.flush_due(nil, 1000, 60) == true, "no record -> due")
    B.ok(Ledger.flush_due(0, 1000, 60) == true, "zero -> due")
    B.ok(Ledger.flush_due(1000, 1059, 60) == false, "within interval -> throttled")
    B.ok(Ledger.flush_due(1000, 1060, 60) == true, "at interval -> due")
    B.ok(Ledger.flush_due(1000, 2000, 60) == true, "past interval -> due")
end

function T.test_format_compact()
    B.eq(Ledger.format_compact(0), "—")
    B.eq(Ledger.format_compact(45), "0分", "under a minute shows 0分")
    B.eq(Ledger.format_compact(120), "2分")
    B.eq(Ledger.format_compact(3900), "1小时5分")
end

function T.test_handles_bad_input()
    B.eq(Ledger.today(nil), 0)
    B.eq(Ledger.week(nil), 0)
    local ledger = Ledger.add({days = {}}, -5, local_monday_noon())
    B.ok(Ledger.today(ledger, local_monday_noon()) >= 0, "negative clamped")
end

return T