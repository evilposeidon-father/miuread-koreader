-- Headless startup benchmark for MiuRead.
--
-- Loads main.lua with the shared KOReader stubs and reports:
--   1. per-module first-load CPU cost (top 20)
--   2. average total plugin load cost across runs
--
-- Run:  lua5.1 tests/lua/bench_startup.lua [runs]
--
-- The absolute numbers are only meaningful as a same-machine baseline; the
-- goal is to see which modules dominate the startup path and whether Lazy
-- conversions actually move cost off it.

local script = arg and arg[0] or "tests/lua/bench_startup.lua"
local script_root = script:gsub("tests[/\\]lua[/\\]bench_startup%.lua$", "")
if script_root == "" then script_root = "." end
rawset(_G, "__MIUREAD_TEST_ROOT", script_root)
dofile(script_root .. "/tests/lua/bootstrap.lua")

local Stubs = require("tests.lua.koreader_stubs")
Stubs.install()

local runs = tonumber(arg and arg[1]) or 5
local timings = {}
local real_require = require

-- Time only the first successful load of each module.
require = function(name)
    local start = os.clock()
    local module, err = real_require(name)
    if timings[name] == nil then
        timings[name] = (os.clock() - start) * 1000
    end
    if module == nil then
        error(err, 2)
    end
    return module
end

local function clear_loaded()
    for key in pairs(package.loaded) do
        if key == "main" or key:match("^miuread") or key:match("^ui/") or key:match("^ffi/")
            or key == "json" or key == "rapidjson" or key == "socket"
            or key == "ltn12" or key == "socketutil" then
            package.loaded[key] = nil
        end
    end
    timings = {}
end

local totals = {}
for run = 1, runs do
    clear_loaded()
    local start = os.clock()
    local plugin = real_require("main")
    local elapsed = (os.clock() - start) * 1000
    totals[#totals + 1] = elapsed
    io.write(string.format("run %d: %.2f ms\n", run, elapsed))
    if plugin == nil then
        error("main.lua did not load")
    end
end

local sum = 0
for _, value in ipairs(totals) do sum = sum + value end
print(string.format("average: %.2f ms over %d runs", sum / #totals, #totals))

local rows = {}
for name, ms in pairs(timings) do
    rows[#rows + 1] = { name = name, ms = ms }
end
table.sort(rows, function(a, b) return a.ms > b.ms end)
print("\ntop first-load costs (ms):")
for index = 1, math.min(20, #rows) do
    print(string.format("  %5.2f  %s", rows[index].ms, rows[index].name))
end
print("modules loaded: " .. tostring(#rows))
