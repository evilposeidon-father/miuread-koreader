-- Tests for miuread.highlight_policy (controller install + pure helpers).
-- Verifies the policy helpers (M.policy, M.is_style, M.style_label, M.STYLES)
-- and the M.install wiring onto a target Plugin table.

local B = require("tests.lua.bootstrap")
local Stubs = require("tests.lua.koreader_stubs")
Stubs.install()

local HighlightPolicy = require("miuread.highlight_policy")

local T = {}

function T.test_pure_policy_selects_underline_by_default()
    B.eq(HighlightPolicy.policy(false), "auto_underline", "false → auto_underline")
    B.eq(HighlightPolicy.policy(nil), "auto_underline", "nil → auto_underline")
    B.eq(HighlightPolicy.policy(true), "native_menu", "true → native_menu")
end

function T.test_styles_constants_are_complete()
    B.eq(type(HighlightPolicy.STYLES), "table", "STYLES is a table")
    B.eq(#HighlightPolicy.STYLES, 3, "three base styles")
    B.eq(HighlightPolicy.STYLE_LABELS.underscore, "下划线", "underscore label")
    B.eq(HighlightPolicy.STYLE_LABELS.lighten, "浅底", "lighten label")
    B.eq(HighlightPolicy.STYLE_LABELS.invert, "反白", "invert label")
end

function T.test_style_label_returns_known_labels()
    B.eq(HighlightPolicy.style_label("underscore"), "下划线", "underscore")
    B.eq(HighlightPolicy.style_label("lighten"), "浅底", "lighten")
    B.eq(HighlightPolicy.style_label("invert"), "反白", "invert")
    B.eq(HighlightPolicy.style_label("unknown"), "下划线", "unknown falls back to underscore")
    B.eq(HighlightPolicy.style_label(nil), "下划线", "nil falls back to underscore")
end

function T.test_is_style_recognizes_known_styles()
    B.eq(HighlightPolicy.is_style("underscore"), true, "underscore is a style")
    B.eq(HighlightPolicy.is_style("lighten"), true, "lighten is a style")
    B.eq(HighlightPolicy.is_style("invert"), true, "invert is a style")
    B.eq(HighlightPolicy.is_style("underline_wave"), false, "underline_wave is not a style")
    B.eq(HighlightPolicy.is_style(nil), false, "nil is not a style")
    B.eq(HighlightPolicy.is_style(""), false, "empty string is not a style")
end

function T.test_install_copies_plugin_methods()
    local target = {}
    HighlightPolicy.install(target)
    B.eq(type(target.highlight_selection_policy), "function", "highlight_selection_policy installed")
    B.eq(type(target._selection_menu_enabled), "function", "_selection_menu_enabled installed")
    B.eq(type(target._apply_miuread_highlight_action_policy), "function", "_apply_miuread_highlight_action_policy installed")
    B.eq(type(target._restore_miuread_highlight_action_policy), "function", "_restore_miuread_highlight_action_policy installed")
    B.eq(type(target._apply_miuread_highlight_defaults), "function", "_apply_miuread_highlight_defaults installed")
end

function T.test_highlight_selection_policy_delegate_uses_module_helper()
    local target = {}
    HighlightPolicy.install(target)
    B.eq(target:highlight_selection_policy(true), "native_menu", "delegate to M.policy(true)")
    B.eq(target:highlight_selection_policy(false), "auto_underline", "delegate to M.policy(false)")
end

return T
