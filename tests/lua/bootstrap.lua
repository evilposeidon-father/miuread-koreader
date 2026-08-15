-- Shared bootstrap for MiuRead headless Lua 5.1 tests.
--
-- Sets package.path so `require("miuread.digests")` resolves against the repo,
-- installs minimal KOReader stubs, and exposes a tiny assertion API for the
-- test suites. Every test runs through tests/lua/run.lua.

local M = {}

local root = rawget(_G, "__MIUREAD_TEST_ROOT")
if type(root) ~= "string" or root == "" then
    local script = arg and arg[0] or "tests/lua/run.lua"
    root = script:gsub("tests[/\\]lua[/\\]run%.lua$", "")
end
if root == "" then root = "." end
M.root = root
rawset(_G, "__MIUREAD_TEST_ROOT", root)

package.path = table.concat({
    root .. "/?.lua",
    root .. "/miuread.koplugin/?.lua",
    root .. "/miuread.koplugin/?/init.lua",
    package.path,
}, ";")

-- ---------------------------------------------------------------------------
-- KOReader stubs. Pure modules should never need more than these; the smoke
-- suite extends the list before loading main.lua.
-- ---------------------------------------------------------------------------

local preload = package.preload or {}
package.preload = preload

local function install(name, module)
    preload[name] = function() return module end
end

install("logger", {
    info = function() end,
    warn = function() end,
    err = function() end,
    dbg = function() end,
})

-- Configurable fake screen; ui_scale tests overwrite dimensions per case.
M.screen = {
    getWidth = function() return 1072 end,
    getHeight = function() return 1448 end,
    scaleBySize = function(_, value) return value end,
}

install("device", {
    model = "test",
    firmware_rev = "1.0",
    screen = M.screen,
    hasFrontlight = function() return true end,
    isTouchDevice = function() return true end,
    hasKeys = function() return false end,
})

install("ui/font", {
    getFace = function(_, name, size) return { name = name, size = size } end,
})

local fake_lfs = {}
function fake_lfs.attributes() return nil end
function fake_lfs.dir() return function() return nil end end
function fake_lfs.mkdir() return true end
function fake_lfs.rmdir() return true end
function fake_lfs.currentdir() return "." end
function fake_lfs.chdir() return true end
install("libs/libkoreader-lfs", fake_lfs)

install("datastorage", {
    getDataDir = function() return root .. "/.test-data" end,
})
install("luasettings", {})
install("ffi/blitbuffer", {})

-- LuaJIT normally exposes `bit`; plain Lua 5.1 uses lua-bitop on CI. When
-- neither is available (local lupa builds), install a small pure-Lua 32-bit
-- implementation so digest/codec tests still run anywhere.
local ok_bit = pcall(require, "bit")
if not ok_bit then
    package.preload["bit"] = function()
        local bit = {}
        local MOD = 4294967296
        local function u32(x)
            x = math.floor(tonumber(x) or 0) % MOD
            if x < 0 then x = x + MOD end
            return x
        end
        function bit.band(...)
            local r = 4294967295
            for i = 1, select("#", ...) do
                local a, o = u32(select(i, ...)), 0
                for j = 0, 31 do
                    if r % 2 == 1 and a % 2 == 1 then o = o + 2 ^ j end
                    r = math.floor(r / 2)
                    a = math.floor(a / 2)
                    if r == 0 and a == 0 then break end
                end
                r = o
            end
            return r
        end
        function bit.bor(...)
            local r = 0
            for i = 1, select("#", ...) do
                local a, o = u32(select(i, ...)), 0
                for j = 0, 31 do
                    if r % 2 == 1 or a % 2 == 1 then o = o + 2 ^ j end
                    r = math.floor(r / 2)
                    a = math.floor(a / 2)
                    if r == 0 and a == 0 then break end
                end
                r = o
            end
            return r
        end
        function bit.bxor(...)
            local r = 0
            for i = 1, select("#", ...) do
                local a, o = u32(select(i, ...)), 0
                for j = 0, 31 do
                    if (r % 2 == 1) ~= (a % 2 == 1) then o = o + 2 ^ j end
                    r = math.floor(r / 2)
                    a = math.floor(a / 2)
                    if r == 0 and a == 0 then break end
                end
                r = o
            end
            return r
        end
        function bit.bnot(x)
            return -u32(x) - 1
        end
        function bit.lshift(x, n)
            n = tonumber(n) or 0
            if n < 0 then return bit.rshift(x, -n) end
            return u32(u32(x) * (2 ^ math.floor(n)))
        end
        function bit.rshift(x, n)
            n = tonumber(n) or 0
            if n < 0 then return bit.lshift(x, -n) end
            return math.floor(u32(x) / (2 ^ math.floor(n)))
        end
        function bit.rol(x, n)
            n = u32(n) % 32
            return bit.bor(bit.lshift(x, n), bit.rshift(x, 32 - n))
        end
        function bit.ror(x, n)
            n = u32(n) % 32
            return bit.bor(bit.rshift(x, n), bit.lshift(x, 32 - n))
        end
        return bit
    end
end

-- ---------------------------------------------------------------------------
-- Tiny assertion API. Errors propagate to the runner through pcall.
-- ---------------------------------------------------------------------------

function M.eq(actual, expected, message)
    if actual ~= expected then
        error((message or "eq failed") .. "\n  expected: " .. tostring(expected)
            .. "\n  actual:   " .. tostring(actual), 2)
    end
end

function M.ok(condition, message)
    if not condition then
        error(message or "ok() condition is false", 2)
    end
end

function M.almost(actual, expected, delta, message)
    delta = tonumber(delta) or 0.000001
    actual, expected = tonumber(actual), tonumber(expected)
    if actual == nil or expected == nil or math.abs(actual - expected) > delta then
        error((message or "almost failed") .. "\n  expected: " .. tostring(expected)
            .. "\n  actual:   " .. tostring(actual), 2)
    end
end

function M.contains(text, needle, message)
    text = tostring(text or "")
    needle = tostring(needle or "")
    if not text:find(needle, 1, true) then
        error((message or "contains failed") .. "\n  missing: " .. needle
            .. "\n  in:      " .. text, 2)
    end
end

return M
