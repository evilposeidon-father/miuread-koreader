local B = require("tests.lua.bootstrap")

local T = {}

-- ---------------------------------------------------------------------------
-- Build a minimal KOReader-shaped fake world so main.lua and every eager
-- controller dependency can load headlessly. The fake classes only need to
-- survive top-level loading; behavioural tests stay in the pure-logic suites.
-- ---------------------------------------------------------------------------

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
    ["device"] = require("device"),
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

-- miuread.json delegates to KOReader's json/rapidjson. Give the headless
-- runtime a small but real encoder/decoder instead of a null stub.
local function json_escape(value)
    return (value:gsub("[%z\1-\31\\\"]", function(char)
        return string.format("\\u%04x", char:byte())
    end))
end
local json = {}
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
json.encode = json_encode
json.decode = json_decode
package.preload["json"] = function() return json end
package.preload["rapidjson"] = function() return json end

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

local function test_method(plugin, name)
    B.ok(type(plugin[name]) == "function", "Plugin." .. name .. " installed")
end

function T.test_load_main_and_controllers()
    local plugin = require("main")
    B.ok(type(plugin) == "table", "main.lua returns the Plugin class")
    test_method(plugin, "init")
    test_method(plugin, "export_diagnostic_bundle")
    test_method(plugin, "check_update")
    test_method(plugin, "manual_sync")
    test_method(plugin, "download")
    test_method(plugin, "show_reader_quick_panel")
    test_method(plugin, "search")
    test_method(plugin, "open_or_download_mp_article")
    test_method(plugin, "repair_current_book")
    test_method(plugin, "settings_menu")
    test_method(plugin, "_close_miuread_transients")
    test_method(plugin, "onReaderReady")
    test_method(plugin, "onCloseDocument")
end

function T.test_load_lazy_ui_modules()
    for _, name in ipairs({
        "miuread.full_shelf_view",
        "miuread.local_browser_view",
        "miuread.screenshot_mode",
        "miuread.thought_native_popup",
        "miuread.reader_list_dialog",
        "miuread.reader_control_center",
        "miuread.reader_progress_dialog",
        "miuread.reader_settings_dialog",
        "miuread.reader_typography_dialog",
        "miuread.reader_toc_dialog",
        "miuread.reader_frontlight_dialog",
    }) do
        local ok, module = pcall(require, name)
        B.ok(ok and module ~= nil, "lazy module loads: " .. name
            .. (ok and "" or ("\n  " .. tostring(module))))
    end
end

return T
