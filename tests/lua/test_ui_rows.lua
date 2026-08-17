local B = require("tests.lua.bootstrap")
local Stubs = require("tests.lua.koreader_stubs")

Stubs.install()

local Rows = require("miuread.ui_rows")

local T = {}

function T.test_normalize_defaults()
    local cfg = Rows.normalize({label = "设置"})
    B.eq(cfg.icon, "", "no icon default")
    B.eq(cfg.label, "设置")
    B.eq(cfg.subtitle, "", "no subtitle default")
    B.eq(cfg.value, "", "no value default")
    B.ok(cfg.enabled == true, "enabled default true")
    B.ok(cfg.arrow == false, "no arrow without callback")
    B.ok(cfg.bold == false)
end

function T.test_normalize_arrow_rules()
    B.ok(Rows.normalize({label="A", callback=function() end}).arrow == true, "callback implies arrow")
    B.ok(Rows.normalize({label="A", arrow=true}).arrow == true, "explicit arrow")
    B.ok(Rows.normalize({label="A", arrow=false, callback=function() end}).arrow == false, "arrow=false wins")
    B.ok(Rows.normalize({label="A", enabled=false, arrow=true}).enabled == false)
end

function T.test_normalize_alias_fields()
    local cfg = Rows.normalize({text = "行", detail = "说明", value = "v", icon = "i"})
    B.eq(cfg.label, "行", "text alias")
    B.eq(cfg.subtitle, "说明", "detail alias")
    B.eq(cfg.value, "v")
    B.eq(cfg.icon, "i")
end

function T.test_normalize_checked()
    B.ok(Rows.normalize({label="A", checked=true}).checked == true)
    B.ok(Rows.normalize({label="A"}).checked == false)
end

function T.test_geometry_explicit_overrides_are_exact()
    -- All values explicit: geometry must be deterministic regardless of screen.
    local cfg = Rows.normalize({icon="i", label="L", subtitle="S", value="V", callback=function() end})
    local geo = Rows.geometry(cfg, 600, 64, {
        pad = 8, icon_w = 30, value_w = 100, chevron_w = 16, gap = 5,
        icon_gap = 5, label_basis = "height",
    })
    -- inner_w = 600 - 2*8 - 30 - 100 - 16 - 5*2 (value+chevron gaps) = 600-16-30-100-16-10 = 428
    B.eq(geo.icon_w, 30)
    B.eq(geo.value_w, 100)
    B.eq(geo.chevron_w, 16)
    B.eq(geo.icon_gap, 5)
    B.eq(geo.inner_w, 428, "inner width exact")
    B.eq(geo.inner_h, 48, "inner height = 64 - 2*8")
    -- label_basis height: label_h = floor(64*.52) = 33, subtitle_h = 31
    B.eq(geo.label_h, 33, "label height uses full row height")
    B.eq(geo.subtitle_h, 31)
end

function T.test_geometry_inner_basis_default()
    local cfg = Rows.normalize({icon="", label="L", value="V"})
    local geo = Rows.geometry(cfg, 300, 50, {pad = 6, value_w = 90, chevron_w = 0, gap = 4})
    B.eq(geo.icon_w, 0, "no icon")
    -- inner_h = 50 - 12 = 38; single-line label_h = inner_h
    B.eq(geo.inner_h, 38)
    B.eq(geo.label_h, 38, "single line fills inner height")
    B.eq(geo.inner_w, 300 - 12 - 90 - 4, "inner width (value gap included)")
end

return T