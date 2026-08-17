local B = require("tests.lua.bootstrap")
local Stubs = require("tests.lua.koreader_stubs")

Stubs.install()

local Reader = require("miuread.plugin_reader")

local T = {}

function T.test_default_visible_has_eight()
    local order = Reader.QUICK_DEFAULT_VISIBLE()
    B.eq(#order, 8, "eight visible quick actions")
    B.eq(order[1], "more", "first group is 更多")
    B.eq(order[2], "toc", "second group is 目录")
    B.eq(order[3], "progress", "third group is 进度")
end

function T.test_default_visible_no_duplicates()
    local order = Reader.QUICK_DEFAULT_VISIBLE()
    local seen = {}
    for _, key in ipairs(order) do
        B.ok(seen[key] == nil, "no duplicate key: " .. tostring(key))
        seen[key] = true
    end
end

function T.test_default_within_max()
    B.ok(Reader.QUICK_ACTION_MAX >= #Reader.QUICK_DEFAULT_VISIBLE(), "defaults within max")
end

function T.test_migrate_preserves_user_order_and_leads_with_more()
    local reader = {
        quick_actions_layout_version = 2,
        quick_actions = {search = true, back = true, comments = true, edge_guard = true},
        quick_action_order = {"edge_guard", "search", "back", "comments"},
    }
    local changed = Reader.migrate_quick_actions(reader)
    B.ok(changed == true, "v2 must migrate")
    B.eq(reader.quick_actions_layout_version, 3, "version stamped")
    B.eq(reader.quick_action_order[1], "more", "更多 leads")
    B.ok(reader.quick_actions.more == true, "more enabled")
    B.ok(reader.quick_actions.edge_guard == true, "user visible key preserved")
    -- original relative order preserved after 更多
    local idx = {}
    for i, key in ipairs(reader.quick_action_order) do idx[key] = i end
    B.ok(idx.edge_guard < idx.search and idx.search < idx.back and idx.back < idx.comments,
        "user ordering preserved")
end

function T.test_migrate_second_call_is_noop()
    local reader = {
        quick_actions_layout_version = 3,
        quick_actions = {more = true, toc = true},
        quick_action_order = {"more", "toc"},
    }
    B.ok(Reader.migrate_quick_actions(reader) == false, "v3 no-op")
end

function T.test_highlight_selection_policy()
    B.eq(Reader.highlight_selection_policy(false), "auto_underline", "default auto underline")
    B.eq(Reader.highlight_selection_policy(true), "native_menu", "enabled native menu")
    B.eq(Reader.highlight_selection_policy(nil), "auto_underline")
end

function T.test_highlight_styles()
    B.eq(#Reader.STYLES, 3, "three styles")
    B.eq(Reader.style_label("underscore"), "下划线")
    B.eq(Reader.style_label("lighten"), "浅底")
    B.eq(Reader.style_label("invert"), "反白")
    B.eq(Reader.style_label("bogus"), "下划线", "unknown falls back")
    B.ok(Reader.is_style("lighten"))
    B.ok(not Reader.is_style("bogus"))
end

function T.test_migrate_falls_back_when_shape_invalid()
    local reader = {
        quick_actions_layout_version = 2,
        quick_actions = {bogus = true},
        quick_action_order = {"bogus"},
    }
    local changed = Reader.migrate_quick_actions(reader)
    B.ok(changed == true, "invalid shape migrates to defaults")
    B.eq(reader.quick_actions_layout_version, 3)
    B.eq(#reader.quick_action_order, 8, "defaults visible count")
end

return T