-- Regression test: the 4.6.3 device crash on user's Kindle.
-- _home_preferences used to index a global 'LocalLibrary' because Lazy
-- was forgotten during the Step 4 split. The new module now declares
-- local LocalLibrary = Lazy("miuread.local_library") at the top.
local B = require("tests.lua.bootstrap")
local Stubs = require("tests.lua.koreader_stubs")
Stubs.install()

-- koreader_stubs already exposes miuread.local_library via fake_modules,
-- so the Lazy("miuread.local_library") in plugin_home_preferences_io.lua
-- resolves to a working fake with normalize / basename / is_likely_dictionary.
local PluginHomePreferencesIO = require("miuread.plugin_home_preferences_io")

local T = {}

local function build_realistic_host()
    local preferences = {
        home_ui = {
            enabled = true,
            layout_version = 24,
            page = "shelf",
            local_roots = {
                {path = "/nonexistent_a", enabled = true},
            },
        }
    }
    local store = {
        preferences = function() return preferences end,
        save_preferences = function(_, p) preferences = p end,
        flush = function() end,
        get = function(_, key, default) return default end,
    }
    return setmetatable({
        store = store,
        _ui_preferences_save_pending = false,
        _ui_preferences_save_generation = 0,
        _home_state_save_pending = false,
        _home_state_save_generation = 0,
        _home_ui_font_name = function() return "default" end,
        _home_panel_item_available = function() return true end,
        _home_action_item_available = function() return true end,
    }, {__index = function(self, key)
        if key == "toast" or key == "info" then return function() end end
        return nil
    end})
end

-- The original crash: _home_preferences() called without LocalLibrary loaded
-- raised "attempt to index global 'LocalLibrary' (a nil value)" on real device.
-- With the Lazy import in place, it must complete without raising.
function T.test_home_preferences_runs_without_local_library_global()
    local host = build_realistic_host()
    PluginHomePreferencesIO.install(host)
    local ok, err = pcall(function() return host:_home_preferences() end)
    B.ok(ok, "_home_preferences must not raise on real-device input shape: " .. tostring(err))
end

function T.test_home_preferences_normalizes_nonexistent_root()
    local host = build_realistic_host()
    PluginHomePreferencesIO.install(host)
    local home, preferences = host:_home_preferences()
    B.ok(type(home) == "table", "home is a table")
    B.ok(type(preferences) == "table", "preferences is a table")
    B.eq(#home.local_roots or 0, 0, "nonexistent root is dropped during normalization")
end

return T
