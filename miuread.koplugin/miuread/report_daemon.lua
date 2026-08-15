-- Report-daemon filesystem layout helpers for MiuRead sync.
--
-- sync.lua still owns the daemon lifecycle/state machine; this module owns
-- the pure layout decisions: versioned path tables, status stamps, legacy
-- retirement specs and file cleanup. Everything is testable without FFI or
-- a running worker.

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

local function remove_lock_dir(path)
    local ok, lfs = pcall(require, "lfs")
    if ok and lfs and type(lfs.rmdir) == "function" then pcall(lfs.rmdir, path) end
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
