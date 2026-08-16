local B = require("tests.lua.bootstrap")
local TZ = require("miuread.timezone")

local T = {}

function T.test_normalize_defaults_and_fallback()
    local normalized = TZ.normalize(nil)
    B.eq(normalized.mode, "device", "default mode device")
    B.eq(normalized.zone, "Asia/Shanghai", "default zone")
    B.eq(normalized.offset_minutes, 480, "default offset")

    normalized = TZ.normalize({mode = "bogus", zone = "Not/AZone", offset_minutes = 9999})
    B.eq(normalized.mode, "device", "bad mode falls back")
    B.eq(normalized.zone, "Asia/Shanghai", "bad zone falls back")
    B.eq(normalized.offset_minutes, 840, "offset clamped to +14:00")
end

function T.test_zone_lookup()
    local row = TZ.zone("Asia/Shanghai")
    B.ok(row ~= nil, "Shanghai zone exists")
    B.eq(row.label, "中国 · 北京")
    B.eq(row.offset, 480)
    B.ok(TZ.zone("Not/AZone") == nil, "unknown zone is nil")
end

function T.test_fixed_offset()
    local settings = {mode = "fixed", offset_minutes = -330}
    B.eq(TZ.offset_minutes(settings, os.time()), -330, "fixed offset honored")
    B.contains(TZ.label(settings), "-05:30", "label renders negative offset")
end

function T.test_parse_offset()
    B.eq(TZ.parse_offset("+8"), 480)
    B.eq(TZ.parse_offset("UTC+08:00"), 480)
    B.eq(TZ.parse_offset("utc-5:30"), -330)
    B.ok(TZ.parse_offset("not an offset") == nil, "garbage rejected")
end

function T.test_offset_text()
    B.eq(TZ.offset_text(480), "UTC+08:00")
    B.eq(TZ.offset_text(480, true), "UTC+8")
    B.eq(TZ.offset_text(-330, true), "UTC-5:30")
    B.eq(TZ.offset_text(0, true), "UTC+0")
end

return T
