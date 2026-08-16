local B = require("tests.lua.bootstrap")
local UiScale = require("miuread.ui_scale")

local T = {}

function T.test_display_mode_roundtrip_and_fallback()
    UiScale.setDisplayMode("large")
    B.eq(UiScale.getDisplayMode(), "large", "mode stored")
    UiScale.setDisplayMode("bogus")
    B.eq(UiScale.getDisplayMode(), "standard", "unknown mode falls back")
    UiScale.setDisplayMode("compact")
    B.eq(UiScale.getDisplayMode(), "compact")
    UiScale.setDisplayMode("standard")
end

function T.test_font_name_roundtrip()
    UiScale.setFontName("  Noto Serif  ")
    B.eq(UiScale.getFontName(), "Noto Serif", "trimmed and stored")
    UiScale.setFontName("")
    B.ok(UiScale.getFontName() == nil, "empty clears font")
end

function T.test_metrics_on_fake_screen()
    local m = UiScale.metrics()
    B.eq(m.sw, 1072)
    B.eq(m.sh, 1448)
    B.eq(m.portrait, true)
    B.almost(m.density, 1, 0.01)
    B.almost(m.ratio, 1.30, 0.01, "ratio clamped to comfort cap")
end

function T.test_dp_scales_and_clamps()
    UiScale.setDisplayMode("standard")
    local scaled = UiScale.dp(100)
    B.eq(scaled, 133, "dp scales by ratio * spacing")
    B.eq(UiScale.dp(1000, 0, 500), 500, "maximum clamps")
    B.eq(UiScale.dp(-10, 20), 20, "minimum clamps")
    B.ok(UiScale.dp(0) == 0, "zero stays zero")
end

function T.test_raw_and_radius()
    B.eq(UiScale.raw(100), 133, "raw scales the same nominal")
    B.ok(UiScale.radius(10) > 0, "radius returns a device pixel value")
    B.ok(UiScale.line("thin") >= 2, "thin line keeps at least 2px")
    B.ok(UiScale.line("thick") >= 3, "thick line keeps at least 3px")
end

function T.test_face_uses_stubbed_font()
    local face = UiScale.face("noto", 20, 60, 8)
    B.ok(type(face) == "table", "face returns the fake font table")
    B.ok(face.size >= 8, "font size respects minimum")
end

return T
