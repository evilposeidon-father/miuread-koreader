local B = require("tests.lua.bootstrap")
local DC = require("miuread.diagnostic_context")

local T = {}

function T.test_redact_sensitive_keys()
    local value = {
        name = "miuread",
        auth = { token = "abc", cookie = "x=1", vid = "ok-keep" },
        list = { { api_key = "k" }, { title = "book" } },
    }
    local out = DC.redact(value)
    B.eq(out.name, "miuread")
    B.eq(out.auth.token, "[redacted]")
    B.eq(out.auth.cookie, "[redacted]")
    B.eq(out.auth.vid, "ok-keep")
    B.eq(out.list[1].api_key, "[redacted]")
    B.eq(out.list[2].title, "book")
end

function T.test_redact_cyclic_safe()
    local value = { a = 1 }
    value.self = value
    local out = DC.redact(value)
    B.eq(out.a, 1)
    B.eq(out.self, "[cyclic]")
end

function T.test_collect_normalizes_provider()
    local ctx = DC.collect({
        version = "4.5.50", schema = 112, channel = "stable",
        runtime = "desktop", logged_in = true,
        time = "2026-08-17", device = { model = "Kindle", firmware = "1.2" },
        preferences = { token = "x", download_dir = "/books" },
    })
    B.eq(ctx.version, "4.5.50")
    B.eq(ctx.logged_in, "true")
    B.eq(ctx.preferences.token, "[redacted]")
    B.eq(ctx.preferences.download_dir, "/books")
    B.eq(ctx.device.model, "Kindle")
end

function T.test_render_text_flat_lines()
    local text = DC.render_text(DC.collect({
        version = "4.5.50", device = { model = "Kindle" }, preferences = {},
    }))
    B.contains(text, "version=4.5.50")
    B.contains(text, "device.model=Kindle")
    B.contains(text, "logged_in=false")
end

function T.test_default_markers_cover_common_secrets()
    local out = DC.redact({ passwd = "x", password = "y", secret_key = "z", ordinary = "ok" })
    B.eq(out.passwd, "[redacted]")
    B.eq(out.password, "[redacted]")
    B.eq(out.secret_key, "[redacted]")
    B.eq(out.ordinary, "ok")
end

return T
