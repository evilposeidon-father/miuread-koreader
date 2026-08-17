local B = require("tests.lua.bootstrap")
local RD = require("miuread.report_daemon")

local T = {}

function T.test_stamp()
    B.eq(RD.stamp(nil), nil)
    B.eq(RD.stamp({ generation = 7, seq = 2, state = "running", written_at = 99 }), "7:2:running:99")
end

function T.test_paths()
    local paths = RD.paths("/tmp/miuread", 15)
    B.contains(paths.job, "/readtime-service-v15.job.json")
    B.contains(paths.lock, ".lock")
end

function T.test_retired_specs()
    local specs = RD.retired_specs("/tmp/miuread")
    B.eq(#specs, 10)
    B.contains(specs[1].job, "/readtime-service.job.json")
    B.contains(specs[10].job, "/readtime-service-v9.job.json")
end

function T.test_delete_paths_tolerates_missing_files()
    local paths = RD.paths(".", 999)
    B.eq(RD.delete_paths(paths), true, "missing files are safe to delete")
end

function T.test_read_json_roundtrip()
    -- The headless harness decodes JSON with a Lua-style table parser
    -- (loadstring("return "..text)), so fixtures use that dialect; the
    -- device runtime parses the same files with rapidjson.
    local path = os.tmpname()
    local f = io.open(path, "w")
    f:write('{a=1,b={true,false}}')
    f:close()
    local value = RD.read_json(path)
    B.eq(value.a, 1)
    B.eq(value.b[1], true)
    B.eq(value.b[2], false)
    os.remove(path)
end

function T.test_read_json_missing_or_invalid()
    local path = os.tmpname()
    os.remove(path)
    B.eq(RD.read_json(path), nil, "missing file reads nil")
    local f = io.open(path, "w")
    f:write("not json {")
    f:close()
    B.eq(RD.read_json(path), nil, "invalid content reads nil")
    os.remove(path)
end

function T.test_pid_alive_guards()
    B.eq(RD.pid_alive(nil), false)
    B.eq(RD.pid_alive(0), false)
    B.eq(RD.pid_alive(1), false)
    B.eq(RD.pid_alive("abc"), false)
end

function T.test_process_helpers_are_ffi_optional()
    local pid = RD.current_pid()
    B.ok(pid == nil or type(pid) == "number", "current_pid returns number or nil")
    local alive = RD.pid_alive(999999)
    B.ok(alive == nil or type(alive) == "boolean", "pid_alive returns tri-state")
    RD.lower_priority() -- must not raise
end

function T.test_acquire_and_remove_lock()
    local path = os.tmpname() .. ".miuread-lock"
    os.remove(path)
    B.eq(RD.acquire_lock(path), true)
    RD.remove_lock(path) -- must not raise
end

return T
