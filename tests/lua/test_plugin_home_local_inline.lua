-- Tests for miuread.plugin_home_local_inline (extracted from plugin_home_content).
-- Covers pure helpers that produce local-shelf data without touching the UI.

local B = require("tests.lua.bootstrap")
local Stubs = require("tests.lua.koreader_stubs")
Stubs.install()

local PluginHomeLocalInline = require("miuread.plugin_home_local_inline")

local T = {}

local function build_fake_host(preferences, store_overrides)
    local store = {
        get = function(_, key, default)
            if key == "home_local_index" then return store_overrides and store_overrides.index or {books={}} end
            if key == "home_local_tree_index" then return store_overrides and store_overrides.tree or {version=1,dirs={}} end
            return default
        end,
        library = function() return store_overrides and store_overrides.library or {} end,
        session = function() return store_overrides and store_overrides.session or {} end,
    }
    local host = setmetatable({
        store = store,
        _home_preferences = function() return preferences end,
    }, {__index = function(self, key)
        if key == "toast" then return function() end end
        if key == "info" then return function() end end
        if key == "_home_status_text" then return function() return "" end end
        return nil
    end})
    PluginHomeLocalInline.install(host)
    return host
end

function T.test_module_has_install_function()
    B.eq(type(PluginHomeLocalInline.install), "function", "M.install is callable")
end

function T.test_install_copies_methods_onto_target()
    local target = {}
    PluginHomeLocalInline.install(target)
    B.eq(type(target._home_local_cache), "function", "_home_local_cache installed")
    B.eq(type(target._home_local_roots), "function", "_home_local_roots installed")
    B.eq(type(target._home_local_inline_navigate), "function", "_home_local_inline_navigate installed")
    B.eq(type(target._home_local_empty_text), "function", "_home_local_empty_text installed")
end

function T.test_cache_defaults_are_normalized()
    local host = build_fake_host({local_library_mode="direct"})
    local cache = host:_home_local_cache()
    B.eq(type(cache), "table", "cache is a table")
    B.eq(type(cache.books), "table", "cache.books defaults to empty table")
end

function T.test_tree_cache_defaults_are_normalized()
    local host = build_fake_host({local_library_mode="direct"})
    local tree = host:_home_local_tree_cache()
    B.eq(tree.version, 1, "tree.version pinned to 1")
    B.eq(type(tree.dirs), "table", "tree.dirs defaults to empty table")
end

function T.test_roots_filters_nonexistent_paths()
    local preferences = {
        local_roots = {
            {path="/nonexistent_a", enabled=true},
            {path="/nonexistent_b", enabled=false},
        }
    }
    local host = build_fake_host(preferences)
    local enabled = host:_home_local_roots(true)
    B.eq(#enabled, 0, "nonexistent roots are filtered regardless of enabled flag")
end

function T.test_empty_text_returns_setup_hint_for_no_roots()
    local host = build_fake_host({local_library_mode="direct", local_roots={}})
    local text = host:_home_local_empty_text()
    B.ok(text and text:find("本地书库目录"), "empty_text points to setup")
end

function T.test_empty_text_returns_manual_mode_hint()
    local host = build_fake_host({local_library_mode="manual"})
    local text = host:_home_local_empty_text()
    B.ok(text and text:find("扫描"), "manual mode text mentions scanning")
end

function T.test_inline_title_returns_blank_for_non_direct_mode()
    local host = build_fake_host({local_library_mode="manual"})
    local title = host:_home_local_inline_title()
    B.eq(title, "", "non-direct mode produces blank title")
end

function T.test_inline_title_returns_picker_hint_for_multiple_roots()
    local preferences = {
        local_library_mode = "direct",
        local_roots = {
            {path="/nonexistent_a", enabled=true},
            {path="/nonexistent_b", enabled=true},
        },
    }
    local host = build_fake_host(preferences)
    local title = host:_home_local_inline_title()
    B.ok(title and title:find("选择"), "multi-root picker title returned")
end

function T.test_known_paths_collects_files_and_original_files()
    local store_overrides = {
        library = {
            ["book1"] = {
                variants = {
                    {file="/path/a.epub"},
                    {original_file="/path/a-original.epub"},
                },
            },
            ["book2"] = {
                variants = {
                    {file="/path/b.epub"},
                },
            },
        },
    }
    local host = build_fake_host({local_library_mode="direct"}, store_overrides)
    local known = host:_home_local_known_paths()
    B.eq(known["/path/a.epub"], true, "variant file collected")
    B.eq(known["/path/a-original.epub"], true, "variant original_file collected")
    B.eq(known["/path/b.epub"], true, "second book variant file collected")
end

function T.test_root_for_path_matches_root_or_descendant()
    local host = build_fake_host({local_library_mode="direct"})
    local roots = {{path="/root/sub"}, {path="/other"}}
    local match = host:_home_local_root_for_path("/root/sub/x", roots)
    B.ok(match ~= nil, "descendant path returns a match")
    B.eq(match.path, "/root/sub", "matched root is /root/sub")
end

return T
