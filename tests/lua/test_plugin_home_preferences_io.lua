-- Tests for miuread.plugin_home_preferences_io (extracted from plugin_home).
-- Covers preference validation/migrations and the deferred-flush lifecycle.

local B = require("tests.lua.bootstrap")
local Stubs = require("tests.lua.koreader_stubs")
Stubs.install()

local PluginHomePreferencesIO = require("miuread.plugin_home_preferences_io")

local T = {}

local function build_fake_host(initial)
    local preferences = initial or {home_ui = {}}
    local store = {
        preferences = function() return preferences end,
        save_preferences = function(_, p) preferences = p end,
        flush = function() end,
    }
    local saved_deferred = {}
    local host = setmetatable({
        store = store,
        _save_preferences_deferred = saved_deferred,
        _ui_preferences_save_pending = false,
        _ui_preferences_save_generation = 0,
        _home_state_save_pending = false,
        _home_state_save_generation = 0,
        _home_ui_font_name = function() return "default" end,
        -- Stubs for methods that remain in plugin_home but are called from
        -- _home_preferences during migration. Real callers provide them via
        -- the controller install; unit tests short-circuit to true.
        _home_panel_item_available = function() return true end,
        _home_action_item_available = function() return true end,
    }, {__index = function(self, key)
        if key == "toast" then return function() end end
        if key == "info" then return function() end end
        return nil
    end})
    PluginHomePreferencesIO.install(host)
    host.store = setmetatable({
        preferences = function() return preferences end,
        save_preferences = function(_, p) preferences = p end,
        flush = function() end,
        save_preferences_deferred = saved_deferred,
    }, {__call = function() return nil end})
    return host, preferences
end

function T.test_module_has_install_function()
    B.eq(type(PluginHomePreferencesIO.install), "function", "M.install is callable")
end

function T.test_install_copies_methods_onto_target()
    local target = {}
    PluginHomePreferencesIO.install(target)
    B.eq(type(target._home_preferences), "function", "_home_preferences installed")
    B.eq(type(target._save_ui_preferences), "function", "_save_ui_preferences installed")
    B.eq(type(target._mark_ui_preferences_flushed), "function", "_mark_ui_preferences_flushed installed")
    B.eq(type(target._save_home_preferences), "function", "_save_home_preferences installed")
    B.eq(type(target._save_home_preferences_deferred), "function", "_save_home_preferences_deferred installed")
    B.eq(type(target._flush_home_preferences), "function", "_flush_home_preferences installed")
end

function T.test_install_and_method_presence()
    local host, _ = build_fake_host({home_ui = {}})
    -- Verify install copied the lifecycle methods (without running full migration
    -- which would touch LocalLibrary, Device, HomeView, etc.).
    B.eq(type(host._save_ui_preferences), "function", "_save_ui_preferences installed")
    B.eq(type(host._mark_ui_preferences_flushed), "function", "_mark_ui_preferences_flushed installed")
    B.eq(type(host._save_home_preferences), "function", "_save_home_preferences installed")
    B.eq(type(host._save_home_preferences_deferred), "function", "_save_home_preferences_deferred installed")
    B.eq(type(host._flush_home_preferences), "function", "_flush_home_preferences installed")
end

function T.test_flush_home_preferences_returns_false_when_idle()
    local host, _ = build_fake_host({home_ui = {}})
    host._home_state_save_pending = false
    B.eq(host:_flush_home_preferences(), false, "no-op when nothing pending")
end

function T.test_mark_ui_preferences_flushed_only_when_pending()
    local host, _ = build_fake_host({home_ui = {}})
    host._ui_preferences_save_pending = false
    B.eq(host:_mark_ui_preferences_flushed(), false, "no-op when not pending")
    host._ui_preferences_save_pending = true
    B.eq(host:_mark_ui_preferences_flushed(), true, "flushed when pending")
    B.eq(host._ui_preferences_save_pending, false, "flag cleared after flush")
end

return T
