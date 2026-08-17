local B = require("tests.lua.bootstrap")
local LAD = require("miuread.local_annotation_database")

local T = {}

-- Regression for the device crash: recent_all called database_paths before
-- its local declaration, making it a global lookup (nil) on 我的批注 open.
-- An empty store must return an empty list without touching SQLite.
function T.test_recent_all_empty_store_returns_empty()
    local results, err = LAD.recent_all({}, 100)
    B.ok(type(results) == "table" and #results == 0,
        "empty store -> empty list, err=" .. tostring(err))
end

function T.test_recent_all_cache_reused_empty_store()
    local first = LAD.recent_all({}, 100)
    local second = LAD.recent_all({}, 100)
    B.ok(type(first) == "table" and type(second) == "table", "cache returns tables")
end

return T