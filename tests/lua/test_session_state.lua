local B = require("tests.lua.bootstrap")

local T = {}

local KEYS = {
    "__MIUREAD_HOME_SESSION",
    "__MIUREAD_READER_CLOSE",
    "__MIUREAD_READER_REBUILD",
    "__MIUREAD_NAVIGATION",
}

local saved = {}
for _, key in ipairs(KEYS) do
    saved[key] = rawget(_G, key)
    rawset(_G, key, nil)
end

local Session = require("miuread.session_state")

function T.test_home_creates_defaults_once()
    local home = Session.home()
    B.ok(type(home) == "table", "home table created")
    B.eq(home.foreground, "native")
    B.eq(home.suspended, false)
    B.eq(home.reader_session_generation, 0)
    B.ok(Session.home() == home, "same table on second access")
    B.ok(rawget(_G, "__MIUREAD_HOME_SESSION") == home, "published to _G")
end

function T.test_reader_close_normalizes_legacy_fields()
    local close_state = Session.reader_close()
    close_state.close_attempts = "3"
    close_state.foreground_stop_attempted = 1
    close_state.native_fallback_attempted = true
    local again = Session.reader_close()
    B.eq(again.close_attempts, 3, "numeric string normalized")
    B.eq(again.foreground_stop_attempted, false, "non-true collapses to false")
    B.eq(again.native_fallback_attempted, true, "explicit true preserved")
    B.eq(again.state, "idle")
end

function T.test_reader_close_active()
    local close_state = Session.reader_close()
    close_state.state = "idle"
    B.eq(Session.reader_close_active(), false, "idle is inactive")
    close_state.state = "closing"
    B.eq(Session.reader_close_active(), true, "closing is active")
    close_state.state = "completed"
    B.eq(Session.reader_close_active(), false, "completed is inactive")
    close_state.state = "idle"
end

function T.test_reader_rebuild_active()
    local rebuild = Session.reader_rebuild()
    rebuild.state = "pending"
    B.eq(Session.reader_rebuild_active(), true, "pending rebuild")
    rebuild.state = "suspended_pending"
    B.eq(Session.reader_rebuild_active(), true, "suspended pending rebuild")
    rebuild.state = "idle"
    B.eq(Session.reader_rebuild_active(), false, "idle rebuild")
end

function T.test_home_exiting()
    Session.home().exiting = false
    B.eq(Session.home_exiting(), false)
    Session.home().exiting = true
    B.eq(Session.home_exiting(), true)
    Session.home().exiting = false
end

function T.test_navigation_initial_state()
    local home = Session.home()
    home.foreground = "reader_pending"
    rawset(_G, "__MIUREAD_NAVIGATION", nil)
    local navigation = Session.navigation()
    B.eq(navigation.state, "opening_reader", "foreground maps to navigation state")
    B.eq(navigation.generation, 0)

    home.foreground = "native"
    navigation.state = "bogus"
    Session.navigation()
    B.eq(navigation.state, "native", "invalid persisted state repaired")
end

function T.test_sync_home_navigation_fields()
    local home = Session.home()
    local navigation = Session.navigation()
    navigation.state = "reader"
    navigation.generation = 7
    Session.sync_home_navigation_fields()
    B.eq(home.navigation_state, "reader")
    B.eq(home.navigation_generation, 7)
end

-- Restore whatever the surrounding process had (after all other tests in this
-- suite have run); the smoke suite recreates fresh state through the module.
function T.test_z_restore_previous_state()
    for _, key in ipairs(KEYS) do
        rawset(_G, key, saved[key])
    end
end

return T
