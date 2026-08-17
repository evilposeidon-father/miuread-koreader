local B = require("tests.lua.bootstrap")
local Http = require("miuread.http")

local T = {}

function T.test_auth_error_message_is_recognized()
    local text = Http.auth_error_message(-2012, "续期被拒绝")
    B.ok(Http.is_auth_error(text), "marker text must be an auth error")
end

function T.test_auth_error_code_roundtrip()
    B.eq(Http.auth_error_code(Http.auth_error_message(-2012, "x")), "-2012")
    B.eq(Http.auth_error_code(Http.auth_error_message(-2041, "y")), "-2041")
end

function T.test_plain_renewal_rejection_not_auth_error()
    -- Raw text from the renewal endpoint is NOT classified as auth by itself;
    -- the marker normalization in _recover_login_session is what upgrades it.
    B.ok(not Http.is_auth_error("微信读书未接受本次登录续期"))
end

function T.test_marker_suffix_recognized()
    B.ok(Http.is_auth_error("微信读书未接受本次登录续期 " .. "[MiuReadAuth] error_code=-2012"))
end

function T.test_http_401_and_session_text_detected()
    B.ok(Http.is_auth_error("HTTP 401"))
    B.ok(Http.is_auth_error("login expired"))
    B.ok(Http.is_auth_error("登录过期"))
end

function T.test_notify_auth_error_calls_host_handler()
    local calls = {}
    local host = {
        on_auth_required = function(self, channel, err)
            calls[#calls + 1] = { channel = channel, err = err }
        end,
    }
    B.eq(Http.notify_auth_error(host, "progress", "boom"), true)
    B.eq(#calls, 1)
    B.eq(calls[1].channel, "progress")
    B.eq(calls[1].err, "boom")
end

function T.test_notify_auth_error_without_handler()
    B.eq(Http.notify_auth_error({}, "progress", "x"), false)
    B.eq(Http.notify_auth_error(nil, "progress", "x"), false)
    B.eq(Http.notify_auth_error("not-a-host", "progress", "x"), false)
end

function T.test_notify_auth_error_tolerates_throwing_handler()
    local host = {
        on_auth_required = function() error("handler failed") end,
    }
    B.eq(Http.notify_auth_error(host, "read_report", "x"), false)
end

return T
