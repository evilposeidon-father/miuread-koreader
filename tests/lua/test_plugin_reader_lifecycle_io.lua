-- Tests for miuread.plugin_reader_lifecycle_io (extracted from main.lua).
-- Covers the interactive_child_store child-store facade and the install wiring.

local B = require("tests.lua.bootstrap")
local Stubs = require("tests.lua.koreader_stubs")
Stubs.install()

local PluginReaderLifecycleIO = require("miuread.plugin_reader_lifecycle_io")

local T = {}

function T.test_module_has_install_function()
    B.eq(type(PluginReaderLifecycleIO.install), "function", "M.install is callable")
end

function T.test_install_copies_lifecycle_methods()
    local target = {}
    PluginReaderLifecycleIO.install(target)
    B.eq(type(target._run_interactive_network), "function", "_run_interactive_network installed")
    B.eq(type(target._request_catalog), "function", "_request_catalog installed")
    B.eq(type(target._wait_for_network), "function", "_wait_for_network installed")
    B.eq(type(target._cancel_network_waits), "function", "_cancel_network_waits installed")
    B.eq(type(target._finalize_reader_instance_close), "function", "_finalize_reader_instance_close installed")
    B.eq(type(target._start_reader_rebuild_candidate), "function", "_start_reader_rebuild_candidate installed")
    B.eq(type(target._finish_reader_rebuild_candidate), "function", "_finish_reader_rebuild_candidate installed")
    B.eq(type(target._reader_rebuild_ready_state), "function", "_reader_rebuild_ready_state installed")
    B.eq(type(target._reader_rebuild_cancel), "function", "_reader_rebuild_cancel installed")
end

function T.test_cancel_network_waits_resets_tokens()
    local target = {}
    PluginReaderLifecycleIO.install(target)
    target._network_wait_tokens = {default = 3, sync = 5}
    target:_cancel_network_waits()
    B.eq(type(target._network_wait_tokens), "table", "tokens table reset")
    B.eq(next(target._network_wait_tokens), nil, "tokens table is empty after cancel")
end

function T.test_interactive_auth_applies_known_session()
    -- Build a host with a store that records save_auth calls.
    local saved = nil
    local target = {
        store = {
            auth = function()
                return {login_session_id = "S1", account = {vid = "V1"}}
            end,
            save_auth = function(_, value) saved = value end,
        },
    }
    PluginReaderLifecycleIO.install(target)
    local ok = target:_apply_interactive_auth{
        changed = true,
        auth = {login_session_id = "S1", account = {vid = "V1"}},
    }
    B.eq(ok, true, "auth applied")
    B.eq(saved.login_session_id, "S1", "saved auth has same session")
end

function T.test_interactive_auth_rejects_stale_session()
    local saved = nil
    local target = {
        store = {
            auth = function()
                return {login_session_id = "S1", account = {vid = "V1"}}
            end,
            save_auth = function(_, value) saved = value end,
        },
    }
    PluginReaderLifecycleIO.install(target)
    local ok = target:_apply_interactive_auth{
        changed = true,
        auth = {login_session_id = "OTHER", account = {vid = "V2"}},
    }
    B.eq(ok, false, "stale session rejected")
    B.eq(saved, nil, "nothing saved")
end

return T
