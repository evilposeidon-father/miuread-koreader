-- KOReader-shaped stubs for headless Lua tests.
--
-- Builds fake widget classes, UIManager, Event, Geometry and a JSON engine,
-- then installs them so main.lua and the lazy UI modules can load without a
-- KOReader runtime. Shared by test_smoke and the startup benchmark.

local M = {}

local function make_class()
    local cls = {}
    function cls.extend(_, props)
        local sub = setmetatable({}, { __index = cls })
        for key, value in pairs(props or {}) do sub[key] = value end
        sub.__index = sub
        return sub
    end
    function cls.new(_, ...)
        return setmetatable({}, cls)
    end
    return cls
end

local WidgetContainer = make_class()
local Blitbuffer = make_class()
local Event = {
    new = function(_, name, ...) return { name = name, args = { ... } } end,
}
local Geometry = {
    new = function(_, props) return props or { w = 0, h = 0 } end,
}
local UIManager = {
    _window_stack = {},
    scheduleIn = function() return 1 end,
    unschedule = function() end,
    nextTick = function(fn) fn() end,
    show = function() return true end,
    close = function() return true end,
    setDirty = function() end,
    broadcastEvent = function() end,
    isWidgetShown = function() return false end,
    quit = function() end,
}

local fake_modules = {
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    ["ffi/blitbuffer"] = Blitbuffer,
    ["ui/event"] = Event,
    ["ui/geometry"] = Geometry,
    ["ui/uimanager"] = UIManager,
    ["fontlist"] = {},
    ["util"] = {},
    ["dispatcher"] = {
        register = function() end,
        execute = function() return true end,
    },
    ["ltn12"] = {
        source = function() end,
        sink = function() end,
        pump = function() return true end,
    },
    ["socketutil"] = {},
    ["socket"] = {
        gettime = function() return 0 end,
        sleep = function() end,
    },
    ["lfs"] = {
        attributes = function() return nil end,
        dir = function() return function() return nil end end,
        mkdir = function() return true end,
        rmdir = function() return true end,
    },
    ["socket.http"] = {
        request = function() return nil, "offline", nil end,
    },
    ["ssl.https"] = {
        request = function() return nil, "offline", nil end,
    },
}

local function json_escape(value)
    return (value:gsub("[%z\1-\31\\\"]", function(char)
        return string.format("\\u%04x", char:byte())
    end))
end

local function json_encode(value)
    local kind = type(value)
    if value == nil then return "null" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        if value ~= value then return "null" end
        return string.format("%.14g", value)
    end
    if kind == "string" then return '"' .. json_escape(value) .. '"' end
    if kind ~= "table" then error("cannot json-encode " .. kind) end
    local is_array = true
    local max = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then is_array = false break end
        if key > max then max = key end
    end
    if is_array and max == 0 then return "[]" end
    local parts = {}
    if is_array then
        for index = 1, max do parts[index] = json_encode(value[index]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for key, item in pairs(value) do
        if type(key) ~= "string" then error("json object keys must be strings") end
        parts[#parts + 1] = json_encode(key) .. ":" .. json_encode(item)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function json_decode(text)
    return loadstring("return " .. tostring(text))()
end

function M.install()
    package.preload["json"] = function()
        return { encode = json_encode, decode = json_decode }
    end
    package.preload["rapidjson"] = function()
        return { encode = json_encode, decode = json_decode }
    end
    local searchers = package.loaders or package.searchers
    table.insert(searchers, function(name)
        if fake_modules[name] ~= nil then
            return function() return fake_modules[name] end
        end
        if name:match("^ui/") or name:match("^ffi/") or name:match("^libs/") then
            return function() return make_class() end
        end
        return "\n\tno fake for " .. name
    end)
end

M.fake_modules = fake_modules
M.UIManager = UIManager
M.make_class = make_class

return M
