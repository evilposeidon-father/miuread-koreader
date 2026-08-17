-- Report-daemon filesystem and process plumbing for MiuRead sync.
--
-- sync.lua owns the daemon lifecycle/state machine; this module owns the
-- shared plumbing that several sync layers used to duplicate: versioned path
-- tables, status stamps, legacy retirement specs, file cleanup, JSON file
-- reads, lock dirs and FFI process helpers. Everything is testable without
-- FFI or a running worker.

local U = require("miuread.util")
local Json = require("miuread.json")

local ReportDaemon = {}

function ReportDaemon.stamp(status)
    if type(status) ~= "table" then return nil end
    return table.concat({
        tostring(status.generation or 0),
        tostring(status.seq or 0),
        tostring(status.state or ""),
        tostring(status.completed_at or status.attempted_at or status.written_at or 0),
    }, ":")
end

function ReportDaemon.paths(temp_dir, version)
    local base = tostring(temp_dir or "") .. "/readtime-service-v" .. tostring(version or 0)
    return {
        job = base .. ".job.json",
        control = base .. ".control.json",
        status = base .. ".status.json",
        context = base .. ".context.json",
        stop = base .. ".stop",
        owner = base .. ".owner.json",
        lock = base .. ".lock",
    }
end

function ReportDaemon.retired_specs(temp_dir)
    local base = tostring(temp_dir or "") .. "/readtime-service"
    local retired = {}
    for _, suffix in ipairs({"", "-v1", "-v2", "-v3", "-v4", "-v5", "-v6", "-v7", "-v8", "-v9"}) do
        local prefix = base .. suffix
        retired[#retired + 1] = {
            job = prefix .. ".job.json",
            control = prefix .. ".control.json",
            status = prefix .. ".status.json",
            context = prefix .. ".context.json",
            stop = prefix .. ".stop",
            owner = prefix .. ".owner.json",
            lock = prefix .. ".lock",
        }
    end
    return retired
end

-- ---------------------------------------------------------------------------
-- Process helpers (FFI). KOReader devices always have FFI; headless tests
-- fall back to nil, and callers apply their own liveness policy.
-- ---------------------------------------------------------------------------

local process_ffi
local function process_helpers()
    if process_ffi ~= nil then return process_ffi or nil end
    local ok, ffi = pcall(require, "ffi")
    if not ok then process_ffi = false; return nil end
    pcall(function()
        ffi.cdef[[
            int getpid(void);
            int kill(int pid, int sig);
            int setpriority(int which, int who, int prio);
        ]]
    end)
    process_ffi = ffi
    return ffi
end

function ReportDaemon.current_pid()
    local ffi = process_helpers()
    if not ffi then return nil end
    local ok, pid = pcall(function() return tonumber(ffi.C.getpid()) end)
    return ok and pid or nil
end

-- Liveness of a process id: true/false with FFI, nil when it cannot be
-- determined (no FFI) so callers pick their own default.
function ReportDaemon.pid_alive(pid)
    pid = tonumber(pid)
    if not pid or pid <= 1 then return false end
    local ffi = process_helpers()
    if not ffi then return nil end
    local ok, result = pcall(function() return ffi.C.kill(pid, 0) end)
    return ok and result == 0
end

function ReportDaemon.lower_priority()
    local ffi = process_helpers()
    if not ffi then return end
    pcall(function() ffi.C.setpriority(0, ffi.C.getpid(), 19) end)
end

-- Read a JSON object file; nil when missing or not a JSON object.
function ReportDaemon.read_json(path)
    local raw = U.read_file(path, true)
    if not raw then return nil end
    local ok, value = pcall(Json.decode, raw)
    if ok and type(value) == "table" then return value end
end

local function remove_lock_dir(path)
    local ok, lfs = pcall(require, "lfs")
    if ok and lfs and type(lfs.rmdir) == "function" then pcall(lfs.rmdir, path) end
end

function ReportDaemon.remove_lock(path)
    return remove_lock_dir(path)
end

function ReportDaemon.acquire_lock(path)
    local ok, lfs = pcall(require, "lfs")
    if not ok or not lfs or type(lfs.mkdir) ~= "function" then return true end
    local made = lfs.mkdir(path)
    return made == true
end

function ReportDaemon.delete_paths(paths)
    if type(paths) ~= "table" then return false end
    os.remove(paths.job)
    os.remove(paths.control)
    os.remove(paths.status)
    os.remove(paths.context)
    os.remove(paths.stop)
    os.remove(paths.owner)
    remove_lock_dir(paths.lock)
    return true
end

return ReportDaemon
