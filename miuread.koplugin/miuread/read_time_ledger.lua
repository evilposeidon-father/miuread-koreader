-- Pure read-time ledger. Accumulates the same seconds that are uploaded to
-- WeRead so the 我的页 card can show the cloud-mirror duration for today and
-- the Monday-based current week, without needing a WeRead stats API.
local M = {}

local function day_key(now)
    return os.date("%Y-%m-%d", now)
end

-- Seconds since the Monday 00:00 of the week containing now (wday: 1=Sunday).
-- Single source for the week boundary: home_data.reading_stats delegates here
-- so the 我的页 card and the ledger can never disagree about 本周.
function M.week_start(now)
    local t = os.date("*t", now)
    local wday = t.wday or 1
    local days_back = (wday + 5) % 7
    local monday = now - days_back * 86400
    local mt = os.date("*t", monday)
    return os.time({year = mt.year, month = mt.month, day = mt.day, hour = 0})
end

function M.add(ledger, seconds, now)
    now = now or os.time()
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    ledger = type(ledger) == "table" and ledger or {days = {}}
    ledger.days = type(ledger.days) == "table" and ledger.days or {}
    local today = day_key(now)
    ledger.days[today] = (tonumber(ledger.days[today]) or 0) + seconds
    return ledger
end

function M.today(ledger, now)
    now = now or os.time()
    local days = type(ledger) == "table" and ledger.days or {}
    return tonumber(days[day_key(now)]) or 0
end

function M.week(ledger, now)
    now = now or os.time()
    local start = M.week_start(now)
    local days = type(ledger) == "table" and ledger.days or {}
    local out = 0
    for date, seconds in pairs(days) do
        local y, m, d = tostring(date):match("^(%d+)-(%d+)-(%d+)$")
        if y and m and d then
            local ts = os.time({year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0})
            if ts >= start then out = out + (tonumber(seconds) or 0) end
        end
    end
    return out
end

-- Pure: whether a deferred ledger flush is due (default 60s). Keeps the
-- read-report hot path from full-file store:flush on every upload.
function M.flush_due(last_flush_at, now, interval)
    now = tonumber(now) or os.time()
    interval = tonumber(interval) or 60
    local last = tonumber(last_flush_at) or 0
    return last <= 0 or now - last >= interval
end

function M.format(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then return tostring(hours) .. " 小时 " .. tostring(minutes) .. " 分" end
    return tostring(minutes) .. " 分钟"
end

-- Compact form for narrow status rows: "1小时5分" / "45分" / "—".
function M.format_compact(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    if seconds <= 0 then return "—" end
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then return tostring(hours) .. "小时" .. tostring(minutes) .. "分" end
    return tostring(minutes) .. "分"
end

return M