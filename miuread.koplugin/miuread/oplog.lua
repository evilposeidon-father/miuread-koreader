-- MiuRead operation log: bounded ring buffer of recent background operations
-- (sync / download / annotation / auth / crash-report). Pure logic, no
-- KOReader dependency, so it runs headless in the Lua 5.1 test suite.
--
-- Entries are flat records:
--   { t=os.time(), cat="sync", op="progress_pull", status="fail",
--     code="remote progress unavailable", detail="...", ms=123 }
-- status is one of "ok" | "fail" | "warn".
--
-- Namespace rule: instance methods live on the internal Methods table, while
-- module-level OpLog.push/list/text/last/clear are singleton helpers. Keeping
-- the two apart avoids the classic pitfall of a module function shadowing a
-- method of the same name (which would make log:push() recurse through the
-- singleton wrapper forever).

local OpLog = {}

local Methods = {}
Methods.__index = Methods

local function default_time(t)
    t = tonumber(t) or 0
    if t <= 0 then return "-" end
    return os.date("%Y-%m-%d %H:%M:%S", t)
end

function Methods:push(entry)
    entry = entry or {}
    self.seq = self.seq + 1
    local rec = { seq = self.seq }
    for key, value in pairs(entry) do
        if type(key) == "string" then rec[key] = value end
    end
    self.head = self.head % self.cap + 1
    self.entries[self.head] = rec
    if self.count < self.cap then self.count = self.count + 1 end
    return rec
end

function Methods:len()
    return self.count
end

-- Newest first; limit clamps to available entries.
function Methods:list(limit)
    local n = self.count
    if n == 0 then return {} end
    local take = tonumber(limit)
    if take == nil or take < 0 then take = n end
    if take > n then take = n end
    local out = {}
    for i = 0, take - 1 do
        local idx = (self.head - 1 - i) % self.cap + 1
        out[#out + 1] = self.entries[idx]
    end
    return out
end

function Methods:clear()
    self.entries = {}
    self.head = 0
    self.count = 0
end

-- Most recent entry matching optional category and status.
function Methods:last(cat, status)
    for _, entry in ipairs(self:list()) do
        if (cat == nil or entry.cat == cat) and (status == nil or entry.status == status) then
            return entry
        end
    end
    return nil
end

function OpLog.new(cap)
    local n = tonumber(cap) or 200
    if n < 1 then n = 1 end
    return setmetatable({ cap = n, entries = {}, head = 0, count = 0, seq = 0 }, Methods)
end

-- One-line rendering for diagnostics; time_fn lets tests inject a formatter.
function OpLog.render(entry, time_fn)
    entry = entry or {}
    local t = (time_fn or default_time)(entry.t)
    local code = entry.code ~= nil and (" code=" .. tostring(entry.code)) or ""
    local ms = entry.ms ~= nil and (" ms=" .. tostring(math.floor(tonumber(entry.ms) + 0.5))) or ""
    local detail = entry.detail ~= nil and (" " .. tostring(entry.detail)) or ""
    return table.concat({
        tostring(t),
        "[" .. tostring(entry.cat or "?") .. "]",
        tostring(entry.op or "?"),
        tostring(entry.status or "?"),
        code,
        ms,
        detail,
    }, " ")
end

-- Multi-line rendering; newest first.
function Methods:text(limit, time_fn)
    local lines = {}
    for _, entry in ipairs(self:list(limit)) do
        lines[#lines + 1] = OpLog.render(entry, time_fn)
    end
    return table.concat(lines, "\n")
end

-- Module-level singleton used by plugin wiring. Tests use OpLog.new directly
-- so the shared buffer never leaks between suites.
local singleton
function OpLog.singleton()
    if not singleton then singleton = OpLog.new(200) end
    return singleton
end
function OpLog.push(entry) return OpLog.singleton():push(entry) end
function OpLog.list(limit) return OpLog.singleton():list(limit) end
function OpLog.text(limit, time_fn) return OpLog.singleton():text(limit, time_fn) end
function OpLog.last(cat, status) return OpLog.singleton():last(cat, status) end
function OpLog.clear() return OpLog.singleton():clear() end

return OpLog
