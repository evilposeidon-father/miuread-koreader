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

return T
