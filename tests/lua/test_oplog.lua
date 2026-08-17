local B = require("tests.lua.bootstrap")
local OpLog = require("miuread.oplog")

local T = {}

local function fixed_time()
    return function(t) return "T" .. tostring(t or 0) end
end

function T.test_ring_cap_drops_oldest()
    local log = OpLog.new(3)
    for i = 1, 5 do log:push{ cat = "sync", op = "op" .. i, status = "fail", code = tostring(i) } end
    B.eq(log:len(), 3)
    local list = log:list()
    B.eq(#list, 3)
    B.eq(list[1].code, "5")
    B.eq(list[3].code, "3")
end

function T.test_list_newest_first_and_limit()
    local log = OpLog.new(10)
    for i = 1, 4 do log:push{ cat = "sync", op = "op", status = "ok", code = tostring(i) } end
    local list = log:list(2)
    B.eq(#list, 2)
    B.eq(list[1].code, "4")
    B.eq(list[2].code, "3")
    B.eq(#log:list(), 4)
    B.eq(#log:list(99), 4)
    B.eq(#log:list(-1), 4)
end

function T.test_last_filters_by_category_and_status()
    local log = OpLog.new(10)
    log:push{ cat = "sync", op = "a", status = "fail", code = "e1" }
    log:push{ cat = "download", op = "b", status = "fail", code = "e2" }
    log:push{ cat = "sync", op = "c", status = "ok" }
    B.eq(log:last("sync", "fail").code, "e1")
    B.eq(log:last("sync").op, "c")
    B.ok(log:last("auth") == nil)
end

function T.test_clear_empties_buffer()
    local log = OpLog.new(3)
    log:push{ cat = "sync" }
    log:clear()
    B.eq(log:len(), 0)
    B.eq(#log:list(), 0)
end

function T.test_render_omits_empty_fields()
    local line = OpLog.render({ t = 5, cat = "sync", op = "pull", status = "fail", code = "boom" }, fixed_time())
    B.contains(line, "T5")
    B.contains(line, "[sync]")
    B.contains(line, "pull")
    B.contains(line, "fail")
    B.contains(line, "code=boom")
    B.ok(not line:find("ms=", 1, true))
end

function T.test_render_includes_ms_and_detail()
    local line = OpLog.render({ t = 1, cat = "sync", op = "pull", status = "fail", code = "x", ms = 12.6, detail = "book=1" }, fixed_time())
    B.contains(line, "ms=13")
    B.contains(line, "book=1")
end

function T.test_singleton_push_and_text()
    OpLog.clear()
    OpLog.push{ cat = "sync", op = "s", status = "fail", code = "x" }
    B.eq(OpLog.last("sync").op, "s")
    local text = OpLog.text(10, fixed_time())
    B.contains(text, "code=x")
    OpLog.clear()
end

return T
