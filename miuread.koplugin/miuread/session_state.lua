-- Shared navigation/session state for MiuRead.
--
-- ReaderUI and FileManager create separate plugin instances, so state that
-- must survive document open/close lives in _G. This module is the single
-- owner of those tables: it creates them with the exact defaults and
-- normalizes fields that older plugin versions may have written as strings or
-- left unset. Everything else reads through the accessors below instead of
-- touching rawget(_G, ...) directly.

local Session = {}

local HOME_KEY = "__MIUREAD_HOME_SESSION"
local READER_CLOSE_KEY = "__MIUREAD_READER_CLOSE"
local READER_REBUILD_KEY = "__MIUREAD_READER_REBUILD"
local NAVIGATION_KEY = "__MIUREAD_NAVIGATION"
local NATIVE_MENU_GUARD_KEY = "__MIUREAD_NATIVE_MENU_GUARD"

local function ensure_table(key, defaults)
    local table_value = rawget(_G, key)
    if type(table_value) ~= "table" then
        table_value = defaults()
        rawset(_G, key, table_value)
    end
    return table_value
end

function Session.home()
    return ensure_table(HOME_KEY, function()
        return {
            suppressed = false,
            native_visit = false,
            expected_close = false,
            exiting = false,
            return_file = nil,
            reader_origin = false,
            reader_file = nil,
            foreground = "native",
            suspended = false,
            reader_session_generation = 0,
            reader_session_file = nil,
            reader_session_active = false,
            return_requested = false,
            return_session_generation = 0,
            return_request_file = nil,
            home_interaction_generation = 0,
            post_reader_work_interaction_generation = 0,
        }
    end)
end

function Session.reader_close()
    local table_value = ensure_table(READER_CLOSE_KEY, function()
        return {
            state = "idle",
            generation = 0,
            session_generation = 0,
            reader_file = nil,
            requested_at = 0,
            requested_clock = 0,
            close_event_received = false,
            native_requested = false,
            stable_samples = 0,
            fallback_attempted = false,
            reason = nil,
            watch_token = 0,
            poll_state = nil,
            poll_count = 0,
            close_attempts = 0,
            close_command_sent_at = 0,
            foreground_stop_attempted = false,
            native_fallback_attempted = false,
        }
    end)
    table_value.close_attempts = tonumber(table_value.close_attempts) or 0
    table_value.close_command_sent_at = tonumber(table_value.close_command_sent_at) or 0
    table_value.foreground_stop_attempted = table_value.foreground_stop_attempted == true
    table_value.native_fallback_attempted = table_value.native_fallback_attempted == true
    return table_value
end

function Session.reader_rebuild()
    local table_value = ensure_table(READER_REBUILD_KEY, function()
        return {
            state = "idle",
            generation = 0,
            session_generation = 0,
            reader_file = nil,
            started_at = 0,
            started_clock = 0,
            max_wait = 0,
            reason = nil,
            owner = nil,
            recent_book = nil,
            recent_started_at = 0,
            recent_count = 0,
            safe_until = 0,
            pending_width = nil,
            pending_height = nil,
            pending_rotation = nil,
            internal_hint = false,
        }
    end)
    table_value.generation = tonumber(table_value.generation) or 0
    table_value.session_generation = tonumber(table_value.session_generation) or 0
    table_value.started_at = tonumber(table_value.started_at) or 0
    table_value.started_clock = tonumber(table_value.started_clock) or 0
    table_value.max_wait = tonumber(table_value.max_wait) or 0
    table_value.recent_started_at = tonumber(table_value.recent_started_at) or 0
    table_value.recent_count = tonumber(table_value.recent_count) or 0
    table_value.safe_until = tonumber(table_value.safe_until) or 0
    return table_value
end

function Session.native_menu_guard()
    return ensure_table(NATIVE_MENU_GUARD_KEY, function()
        return { token = 0, active = false, finishing = false, menu = nil, container = nil, watch = nil }
    end)
end

Session.NAVIGATION_STATES = {
    native = true,
    home = true,
    opening_reader = true,
    reader = true,
    closing_reader = true,
    native_menu = true,
    suspended = true,
    recovering = true,
    exiting = true,
}

function Session.navigation_state_from_foreground(owner)
    owner = tostring(owner or "native")
    if owner == "home" then return "home" end
    if owner == "reader" then return "reader" end
    if owner == "reader_pending" then return "opening_reader" end
    if owner == "reader_transition" or owner == "home_pending" then return "closing_reader" end
    if owner == "suspended" then return "suspended" end
    if owner == "exiting" then return "exiting" end
    return "native"
end

function Session.navigation()
    local home = Session.home()
    local navigation = rawget(_G, NAVIGATION_KEY)
    if type(navigation) ~= "table" then
        local initial = home.suspended == true and "suspended"
            or Session.navigation_state_from_foreground(home.foreground)
        navigation = {
            state = initial,
            generation = 0,
            reason = "startup",
            changed_at = os.time(),
            reader_session_generation = tonumber(home.reader_session_generation) or 0,
        }
        rawset(_G, NAVIGATION_KEY, navigation)
    else
        if not Session.NAVIGATION_STATES[tostring(navigation.state or "")] then
            navigation.state = Session.navigation_state_from_foreground(home.foreground)
        end
        navigation.generation = tonumber(navigation.generation) or 0
        navigation.changed_at = tonumber(navigation.changed_at) or os.time()
        navigation.reader_session_generation = tonumber(navigation.reader_session_generation) or 0
    end
    return navigation
end

function Session.sync_home_navigation_fields()
    local home = Session.home()
    local navigation = Session.navigation()
    home.navigation_state = navigation.state
    home.navigation_generation = navigation.generation
    home.home_restore_generation = tonumber(home.home_restore_generation) or 0
end

function Session.reader_close_active()
    local close_state = Session.reader_close()
    local state = tostring(close_state.state or "idle")
    return state ~= "idle" and state ~= "completed" and state ~= "failed"
end

function Session.reader_rebuild_active()
    local rebuild = Session.reader_rebuild()
    local state = tostring(rebuild.state or "idle")
    return state == "pending" or state == "suspended_pending"
end

function Session.home_exiting()
    return Session.home().exiting == true
end

return Session
