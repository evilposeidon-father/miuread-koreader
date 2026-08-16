-- Minimal TAP-ish Lua test runner for MiuRead.
--
-- Usage:
--   lua5.1 tests/lua/run.lua            # runs every suite listed below
--   lua5.1 tests/lua/run.lua test_util  # runs one suite
--
-- Each suite file returns a table of test functions; every `test_*` function
-- is executed with a fresh pcall so one failure does not hide the rest.

local script = arg and arg[0] or "tests/lua/run.lua"
local script_root = script:gsub("tests[/\\]lua[/\\]run%.lua$", "")
if script_root == "" then script_root = "." end

dofile(script_root .. "/tests/lua/bootstrap.lua")

local suites = {
    "test_digests",
    "test_protocol",
    "test_read_report_transport",
    "test_sync_response",
    "test_home_network_metadata",
    "test_content_classify",
    "test_annotation_text",
    "test_chapter_title",
    "test_download_coordinator",
    "test_util",
    "test_codec",
    "test_timezone",
    "test_ui_scale",
    "test_lazy",
    "test_progress_decision",
    "test_progress_position",
    "test_report_daemon",
    "test_session_state",
    "test_store_downloads",
    "test_store_auth_sessions",
    "test_store_library_pending",
    "test_store_identity",
    "test_store_meta",
    "test_sync_center",
    "test_sync_scheduler",
    "test_external_chapter_and_highlight",
    "test_smoke",
}

-- main.lua relies on Lua 5.1 loop-variable semantics. The pure-logic suites
-- also run under LuaJIT/lupa, but the smoke suite needs a real 5.1 runtime.
if _VERSION ~= "Lua 5.1" then
    print("# skipping test_smoke: _VERSION is " .. tostring(_VERSION) .. ", expected Lua 5.1")
    for index, name in ipairs(suites) do
        if name == "test_smoke" then table.remove(suites, index) end
    end
end

local requested = arg and arg[1]
if requested and requested ~= "" then
    suites = { requested }
end

local root = rawget(_G, "__MIUREAD_TEST_ROOT") or "."

local tests, failures, count = {}, 0, 0

for _, name in ipairs(suites) do
    local path = root .. "/tests/lua/" .. name .. ".lua"
    local chunk, load_error = loadfile(path)
    if not chunk then
        error("cannot load suite " .. path .. ": " .. tostring(load_error))
    end
    local suite = chunk()
    if type(suite) ~= "table" then
        error("suite " .. name .. " must return a table, got " .. type(suite))
    end
    local names = {}
    for key in pairs(suite) do
        if key:sub(1, 5) == "test_" and type(suite[key]) == "function" then
            names[#names + 1] = key
        end
    end
    table.sort(names)
    for _, test_name in ipairs(names) do
        count = count + 1
        local ok, err = pcall(suite[test_name])
        local label = name .. " " .. test_name
        if ok then
            print("ok " .. count .. " - " .. label)
        else
            failures = failures + 1
            print("not ok " .. count .. " - " .. label)
            print("  " .. tostring(err):gsub("\n", "\n  "))
        end
    end
end

print(string.format("1..%d", count))
print(string.format("# %d passed, %d failed", count - failures, failures))

if failures > 0 then
    os.exit(1)
end
