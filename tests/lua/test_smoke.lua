local B = require("tests.lua.bootstrap")
local Stubs = require("tests.lua.koreader_stubs")

local T = {}

-- Install the KOReader-shaped fake world once for this suite.
Stubs.install()

local function test_method(plugin, name)
    B.ok(type(plugin[name]) == "function", "Plugin." .. name .. " installed")
end

function T.test_load_main_and_controllers()
    local plugin = require("main")
    B.ok(type(plugin) == "table", "main.lua returns the Plugin class")
    test_method(plugin, "init")
    test_method(plugin, "export_diagnostic_bundle")
    test_method(plugin, "check_update")
    test_method(plugin, "manual_sync")
    test_method(plugin, "download")
    test_method(plugin, "show_reader_quick_panel")
    test_method(plugin, "_close_miuread_transients")
    test_method(plugin, "onReaderReady")
    test_method(plugin, "onCloseDocument")
    test_method(plugin, "search")
    test_method(plugin, "open_or_download_mp_article")
    test_method(plugin, "repair_current_book")
    test_method(plugin, "settings_menu")
    test_method(plugin, "_setup_thought_tap")
    test_method(plugin, "show_home_quick_panel")
    test_method(plugin, "book_menu")
    test_method(plugin, "onShowMiuRead")
    test_method(plugin, "_begin_koreader_exit")
    test_method(plugin, "_reader_file")
    test_method(plugin, "return_to_miuread_home")
    test_method(plugin, "_guard_native_koreader_menu")
    test_method(plugin, "onReaderReady")
    test_method(plugin, "onSetDimensions")
end

function T.test_load_lazy_ui_modules()
    for _, name in ipairs({
        "miuread.full_shelf_view",
        "miuread.local_browser_view",
        "miuread.screenshot_mode",
        "miuread.thought_native_popup",
        "miuread.reader_list_dialog",
        "miuread.reader_control_center",
        "miuread.reader_progress_dialog",
        "miuread.reader_settings_dialog",
        "miuread.reader_typography_dialog",
        "miuread.reader_toc_dialog",
        "miuread.reader_frontlight_dialog",
    }) do
        local ok, module = pcall(require, name)
        B.ok(ok and module ~= nil, "lazy module loads: " .. name
            .. (ok and "" or ("\n  " .. tostring(module))))
    end
end

return T
