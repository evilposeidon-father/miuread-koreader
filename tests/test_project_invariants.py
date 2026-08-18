"""MiuRead static regression tests.

These tests do not require a KOReader runtime. They guard the project's
structural invariants so refactors (TapBox/OffsetContainer extraction,
controller splits, version bumps, package layout) fail CI when they regress.
"""

import pathlib
import re
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "miuread.koplugin"


def read_text(relative_path):
    return (ROOT / relative_path).read_text(encoding="utf-8")


class VersionConsistencyTests(unittest.TestCase):
    def test_plugin_meta_config_and_readme_versions_match(self):
        meta = read_text("miuread.koplugin/_meta.lua")
        config = read_text("miuread.koplugin/miuread/config.lua")
        readme = read_text("README.md")

        meta_version = re.search(r'version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', meta)
        config_version = re.search(r'VERSION\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', config)
        readme_version = re.search(r"当前版本：`([0-9]+\.[0-9]+\.[0-9]+)`", readme)

        self.assertIsNotNone(meta_version, "_meta.lua version missing")
        self.assertIsNotNone(config_version, "config.lua VERSION missing")
        self.assertIsNotNone(readme_version, "README current version missing")
        self.assertEqual(meta_version.group(1), config_version.group(1))
        self.assertEqual(meta_version.group(1), readme_version.group(1))

    def test_changelog_contains_plugin_version(self):
        meta = read_text("miuread.koplugin/_meta.lua")
        changelog = read_text("CHANGELOG.md")
        version = re.search(r'version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', meta).group(1)
        self.assertIn(f"## {version}", changelog)

    def test_changelog_unreleased_is_placeholder(self):
        changelog = read_text("CHANGELOG.md")
        self.assertIn("## Unreleased", changelog)
        self.assertIn("- 暂无。", changelog)

    def test_changelog_current_version_records_lua_suite(self):
        changelog = read_text("CHANGELOG.md")
        meta = read_text("miuread.koplugin/_meta.lua")
        version = re.search(r'version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', meta).group(1)
        section = changelog.split(f"## {version}")[1].split("\n## ")[0]
        self.assertIn("Lua 5.1", section)
        self.assertIn("smoke", section)

    def test_changelog_current_version_records_controller_splits(self):
        changelog = read_text("CHANGELOG.md")
        meta = read_text("miuread.koplugin/_meta.lua")
        version = re.search(r'version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', meta).group(1)
        section = changelog.split(f"## {version}")[1].split("\n## ")[0]
        for name in ["plugin_home_content", "plugin_navigation", "store_defaults", "progress_position"]:
            self.assertIn(name, section)


class UiPrimitiveDedupTests(unittest.TestCase):
    def test_offset_container_definition_is_single_source(self):
        offenders = []
        for path in sorted((PLUGIN / "miuread").glob("*.lua")):
            text = path.read_text(encoding="utf-8")
            if "local OffsetContainer = WidgetContainer:extend" in text:
                if path.name != "ui_components.lua":
                    offenders.append(path.name)
        self.assertEqual([], offenders)

    def test_tapbox_definition_is_single_source(self):
        offenders = []
        for path in sorted((PLUGIN / "miuread").glob("*.lua")):
            text = path.read_text(encoding="utf-8")
            if "local TapBox = InputContainer:extend" in text:
                if path.name != "ui_components.lua":
                    offenders.append(path.name)
        self.assertEqual([], offenders)

    def test_fixed_frame_definition_is_single_source(self):
        offenders = []
        for path in sorted((PLUGIN / "miuread").glob("*.lua")):
            text = path.read_text(encoding="utf-8")
            if "local function fixed_frame" in text:
                if path.name != "reader_skin.lua":
                    offenders.append(path.name)
        self.assertEqual([], offenders)


class MainLuaStructureTests(unittest.TestCase):
    def test_instantiated_modules_are_eager(self):
        # These classes are instantiated via X:new(...) in main.lua and use
        # setmetatable({...}, self) as their instance metatable. A Lazy proxy
        # cannot serve as a metatable, so they MUST stay eager requires.
        main = read_text("miuread.koplugin/main.lua")
        for module in [
            "annotations",
            "annotation_sync",
            "downloader",
            "download_task",
            "cache_cleanup_task",
            "content_reader",
        ]:
            self.assertIn(
                f'require("miuread.{module}")', main,
                f"{module} must be eagerly required (it is instantiated via :new())",
            )
            self.assertNotIn(
                f'Lazy("miuread.{module}")', main,
                f"{module} must not be Lazy (it is instantiated via :new())",
            )

    def test_lazy_modules_exist(self):
        sources = ["miuread.koplugin/main.lua"]
        sources += [
            f"miuread.koplugin/miuread/{name}"
            for name in [
                "plugin_maintenance.lua",
                "plugin_update.lua",
                "plugin_sync.lua",
                "plugin_sync_center.lua",
                "plugin_download.lua",
                "plugin_reader.lua",
            ]
        ]
        modules = []
        for source in sources:
            modules += re.findall(r'Lazy\("([^"]+)"\)', read_text(source))
        self.assertGreaterEqual(len(modules), 10)
        for module in modules:
            path = PLUGIN / (module.replace(".", "/") + ".lua")
            self.assertTrue(path.exists(), f"lazy module missing: {module}")

    def test_maintenance_controller_installed(self):
        main = read_text("miuread.koplugin/main.lua")
        module = read_text("miuread.koplugin/miuread/plugin_maintenance.lua")
        self.assertIn('local PluginMaintenance=require("miuread.plugin_maintenance")', main)
        self.assertIn("PluginMaintenance.install(Plugin)", main)
        for method in [
            "export_diagnostic_bundle",
            "show_cache_health",
            "export_config_backup",
            "restore_config_backup",
            "show_reading_report",
        ]:
            self.assertIn(f"function Plugin:{method}(", module)

    def test_split_controllers_installed(self):
        main = read_text("miuread.koplugin/main.lua")
        for module_name, file_name, methods in [
            ("PluginUpdate", "plugin_update.lua", ["check_update", "maybe_auto_check_update", "show_about"]),
            ("PluginSync", "plugin_sync.lua", ["ensure_read_report_progress", "manual_sync", "show_sync_status"]),
            ("PluginSyncCenter", "plugin_sync_center.lua", ["_ensure_sync_scheduler", "_sync_scheduler_request", "_sync_scheduler_run_now", "_sync_gate_allowed"]),
            ("PluginDownload", "plugin_download.lua", ["download", "show_downloads", "show_download_cleanup_dialog"]),
            ("PluginReader", "plugin_reader.lua", ["show_reader_quick_panel", "show_reader_control_center", "reader_quick_actions_menu", "_reader_panel_active"]),
            ("PluginReaderLifecycleIO", "plugin_reader_lifecycle_io.lua", ["_run_interactive_network", "_request_catalog", "_finalize_reader_instance_close", "_start_reader_rebuild_candidate", "_reader_rebuild_cancel"]),
            ("PluginHighlightPolicy", "highlight_policy.lua", ["_apply_miuread_highlight_defaults", "_apply_miuread_highlight_action_policy", "highlight_selection_policy"]),
            ("PluginSearchMp", "plugin_search_mp.lua", ["search", "search_dialog", "open_or_download_mp_article"]),
            ("PluginRepair", "plugin_repair.lua", ["repair_current_book", "show_repair_history", "redownload_current"]),
            ("PluginPreferences", "plugin_preferences.lua", ["settings_menu", "performance_settings_menu", "local_library_settings_menu"]),
            ("PluginThoughtPopup", "plugin_thought_popup.lua", ["_setup_thought_tap", "_open_thought_info", "_flush_reader_checkpoint"]),
            ("PluginDevice", "plugin_device.lua", ["show_home_quick_panel", "_home_wifi_toggle", "_home_sleep"]),
            ("PluginBook", "plugin_book.lua", ["book_menu", "book_details"]),
            ("PluginEvents", "plugin_events.lua", ["onExit", "onRestart", "onShowMiuRead"]),
            ("PluginExit", "plugin_exit.lua", ["_begin_koreader_exit", "_quit_koreader", "show_home_menu"]),
            ("PluginNavigation", "plugin_navigation.lua", ["_reader_file", "return_to_miuread_home", "_request_reader_close", "onHome", "onReaderReady", "onSetDimensions"]),
            ("PluginNativeMenu", "plugin_native_menu.lua", ["_guard_native_koreader_menu", "_show_native_koreader_menu", "_finish_native_menu_visit"]),
            ("PluginShelf", "plugin_shelf.lua", ["load_shelf", "show_shelf", "show_mp_shelf"]),
            ("PluginHome", "plugin_home.lua", ["_home_begin_resume", "home_mode_menu", "_home_schedule_cover_derivatives"]),
            ("PluginHomeCustomize", "plugin_home_customize.lua", ["home_customization_menu", "home_source_order_menu", "_home_group_settings_menu"]),
            ("PluginUiMenus", "plugin_ui_menus.lua", ["_show_miuread_menu", "_show_home_bubble_menu", "notice_settings_menu"]),
            ("PluginHomeContent", "plugin_home_content.lua", ["_home_all_rows", "show_home_local_library", "_home_scan_local", "_show_miuread_home_now"]),
            ("PluginHomeLocalInline", "plugin_home_local_inline.lua", ["_home_local_inline_rows", "_home_local_inline_navigate", "_home_local_empty_text"]),
            ("PluginHomePreferencesIO", "plugin_home_preferences_io.lua", ["_home_preferences", "_save_ui_preferences", "_flush_home_preferences"]),
        ]:
            module_path = f"miuread.koplugin/miuread/{file_name}"
            self.assertIn(f'local {module_name}=require("miuread.{file_name[:-4]}")', main)
            self.assertIn(f"{module_name}.install(Plugin)", main)
            module = read_text(module_path)
            self.assertIn("function M.install(target)", module)
            for method in methods:
                self.assertIn(f"function Plugin:{method}(", module)

    def test_no_unprefixed_cross_controller_self_fields(self):
        # Self fields assigned by two different controllers share one Plugin
        # instance. An unprefixed name can silently shadow another controller's
        # state (the 4.6.2 crash was a missing-import, but shadowing is the same
        # class of invisible-wiring bug). All multi-controller fields must use a
        # recognized global prefix so ownership is greppable at a glance.
        import collections
        import re
        allowed_prefixes = (
            "_miuread_", "_home_", "_reader_", "_sync_", "_download_",
            "_shelf_", "_thought_", "_progress_", "_annotation_", "_external_",
        )
        owner = collections.defaultdict(set)
        for path in sorted((PLUGIN / "miuread").glob("plugin_*.lua")):
            text = path.read_text(encoding="utf-8")
            for match in re.finditer(r"self\.(\w+)\s*=", text):
                owner[match.group(1)].add(path.name)
        offenders = []
        for field, files in sorted(owner.items()):
            if len(files) > 1 and not field.startswith(allowed_prefixes):
                offenders.append(f"{field} -> {sorted(files)}")
        self.assertEqual([], offenders,
            "unprefixed self fields shared across controllers (shadowing risk):\n"
            + "\n".join(offenders))

    def test_split_controllers_declare_used_modules(self):
        # The controllers moved code out of main.lua but kept the original
        # lexical references. A missing require becomes a nil global on the
        # device (immediate crash), so guard the require surface explicitly.
        module_names = {
            "ActionSheet", "Access", "Annotations", "Api", "Async", "Auth",
            "Blitbuffer", "BookIntegrity", "CacheCleanupTask", "Config",
            "Cookies", "DataMigration", "Device", "DownloadCoordinator",
            "DownloadDatabase",
            "DownloadProgress", "DownloadResult", "DownloadTask", "Downloader",
            "EpubInstaller", "Event", "ExternalAnnotationsDB",
            "ExternalAnnotationSync", "FullShelfView", "GestureBridge",
            "HomeData", "HomeNetworkMetadata", "HomeQuickPanel", "HomeView", "Http", "InputDialog",
            "HOME_SESSION", "unpack_args",
            "Json", "Lazy", "Library", "LocalAnnotationDatabase",
            "LocalBrowserView", "LocalLibrary", "LocalMetadata", "MemoryMode",
            "Menu", "MigrationProgress", "MP", "NetworkMetadata", "Orientation",
            "PathChooser", "PerformanceMode", "PluginMenu", "PluginSettings",
            "ProgressDecision", "Protocol", "Reader", "ReaderControlCenter", "ReaderFrontlightDialog",
            "Session",
            "ReaderListDialog", "ReaderProgressDialog", "ReaderSettingsDialog",
            "ReaderTocDialog", "ReaderToolbar", "ReaderTypographyDialog",
            "ScreenshotMode", "Scheduler", "ShelfView", "StatusToast", "Store", "Sync",
            "Text", "ThoughtNativePopup", "Thoughts", "TimeZone",
            "TransientGuard", "U", "UIManager", "UiScale", "Updater", "WidgetContainer",
            "lfs", "logger",
        }

        def code_only(text):
            out = []
            i, n = 0, len(text)
            while i < n:
                if text[i:i + 2] == "--":
                    j = text.find("\n", i)
                    if j == -1:
                        break
                    out.append("\n")
                    i = j + 1
                    continue
                if text[i] in "'\"":
                    quote = text[i]
                    i += 1
                    while i < n:
                        if text[i] == "\\":
                            i += 2
                            continue
                        if text[i] == quote:
                            i += 1
                            break
                        i += 1
                    out.append(" ")
                    continue
                out.append(text[i])
                i += 1
            return "".join(out)

        for name in [
            "plugin_maintenance.lua",
            "sync_catalog_prepare.lua",
            "sync_inverse_mapping.lua",
            "plugin_update.lua",
            "plugin_sync.lua",
            "plugin_sync_center.lua",
            "plugin_download.lua",
            "plugin_reader.lua",
            "plugin_search_mp.lua",
            "plugin_repair.lua",
            "plugin_preferences.lua",
            "plugin_thought_popup.lua",
            "plugin_device.lua",
            "plugin_book.lua",
            "plugin_events.lua",
            "plugin_exit.lua",
            "plugin_navigation.lua",
            "plugin_native_menu.lua",
            "plugin_shelf.lua",
            "plugin_home.lua",
            "plugin_home_customize.lua",
            "plugin_ui_menus.lua",
            "plugin_home_content.lua",
        ]:
            text = read_text(f"miuread.koplugin/miuread/{name}")
            declared = set(re.findall(r'^local\s+(\w+)\s*=', text, re.M))
            code = code_only(text)
            used = {n for n in module_names if re.search(rf"\b{n}\b", code)}
            missing = sorted(used - declared)
            self.assertEqual([], missing, f"{name} uses modules without require: {missing}")


    def test_home_cards_use_shared_skin_frame(self):
        # R2 unification: the external cards must render through the same
        # frame implementation as the reader dialogs. Reverting to Ui.frame
        # recreates the dual visual baseline and is forbidden.
        cards = read_text("miuread.koplugin/miuread/home_cards.lua")
        self.assertIn("require(\"miuread.reader_skin\")", cards, "home_cards must require reader_skin")
        self.assertIn("local fixed_frame = Skin.frame", cards, "home_cards must alias Skin.frame")
        self.assertNotIn("local fixed_frame = Ui.frame", cards, "Ui.frame alias is forbidden in home_cards")
        self.assertNotIn("UiScale.radius", cards, "home_cards must use Skin.radius")
        self.assertNotIn("UiScale.line", cards, "home_cards must use Skin.line")
        for name in ("action_sheet.lua", "full_shelf_view.lua", "home_view.lua", "home_quick_panel.lua", "local_browser_view.lua"):
            text = read_text(f"miuread.koplugin/miuread/{name}")
            self.assertNotIn("local fixed_frame = Ui.frame", text, f"{name} must use Skin.frame")
            self.assertNotIn("UiScale.radius", text, f"{name} must use Skin.radius")
            self.assertNotIn("UiScale.line", text, f"{name} must use Skin.line")
        # Wrap-up: single week-boundary / duration source + annotation fallbacks.
        home_data = read_text("miuread.koplugin/miuread/home_data.lua")
        self.assertIn('require("miuread.read_time_ledger")', home_data,
            "home_data must delegate duration/week to read_time_ledger")
        reader = read_text("miuread.koplugin/miuread/plugin_reader.lua")
        self.assertNotIn('"书页书签"', reader, "fallback label must come from annotation_kinds")
        self.assertNotIn('"无文字内容"', reader, "fallback label must come from annotation_kinds")

    def test_annotation_kinds_single_source_and_shared_filter(self):
        # Architect wrap-up: UI controllers must require annotation_kinds (no
        # re-declared kind literals at the display layer) and the chapter
        # thoughts feature must route through the shared pure filter only.
        for name in ("plugin_reader.lua", "plugin_home_content.lua"):
            text = read_text(f"miuread.koplugin/miuread/{name}")
            self.assertIn('require("miuread.annotation_kinds")', text,
                f"{name} must require annotation_kinds for display labels")
        self.assertIn('require("miuread.annotation_kinds")',
            read_text("miuread.koplugin/main.lua"),
            "main.lua must require annotation_kinds for display labels")
        reader = read_text("miuread.koplugin/miuread/plugin_reader.lua")
        self.assertIn("ExternalAnnotationParse.filter_records_by_chapter", reader,
            "chapter thoughts must use the shared filter (single implementation)")
        sync = read_text("miuread.koplugin/miuread/external_annotation_sync.lua")
        self.assertNotIn("local function filter_records_by_chapter", sync,
            "a second chapter filter implementation is forbidden")
        ui_rows = read_text("miuread.koplugin/miuread/ui_rows.lua")
        self.assertNotIn("TapBox", ui_rows, "ui_rows must stay a layout-only module")
        self.assertNotIn("tappable", ui_rows, "ui_rows must stay a layout-only module")

    def test_card_token_diff_pinned(self):
        # R4: pin the card-token diff so it cannot drift before the device
        # screenshot pass settles one value. hero card = radius(9,6,15) +
        # max(line thin,1); Skin.paper default = radius(9,6,14) + thick.
        cards = read_text("miuread.koplugin/miuread/home_cards.lua")
        self.assertIn("radius = Skin.radius(9, 6, 15),", cards)
        self.assertIn("bordersize = math.max(Skin.line(\"thin\"), 1),", cards)
        skin = read_text("miuread.koplugin/miuread/reader_skin.lua")
        self.assertIn("radius = options.radius or UiScale.radius(9, 6, 14),", skin)
        self.assertIn("bordersize = options.bordersize or UiScale.line(\"thick\"),", skin)
    def test_new_downloads_use_single_clean_edition(self):
        # New downloads no longer offer a notes/clean version choice. Legacy
        # notes files stay readable and are only updated when they are the sole
        # existing chapter edition.
        download = read_text("miuread.koplugin/miuread/plugin_download.lua")
        body = download.split("function Plugin:choose_download(", 1)[1]
        body = body.split("function Plugin:_download_summary", 1)[0]
        self.assertIn("Single-version policy", body)
        self.assertIn("annotations=false", body)
        self.assertNotIn('"划线与想法版"', body)
        range_body = download.split("function Plugin:_choose_range_version(", 1)[1]
        range_body = range_body.split("function Plugin:_range_count_menu", 1)[0]
        self.assertIn("annotations=annotations==true", range_body)

    def test_store_readers_installed(self):
        store = read_text("miuread.koplugin/miuread/store.lua")
        downloads = read_text("miuread.koplugin/miuread/store_downloads.lua")
        auth = read_text("miuread.koplugin/miuread/store_auth.lua")
        sessions = read_text("miuread.koplugin/miuread/store_sessions.lua")
        library = read_text("miuread.koplugin/miuread/store_library.lua")
        pending = read_text("miuread.koplugin/miuread/store_pending.lua")
        identity = read_text("miuread.koplugin/miuread/store_identity.lua")
        meta = read_text("miuread.koplugin/miuread/store_meta.lua")
        defaults = read_text("miuread.koplugin/miuread/store_defaults.lua")
        for var, module in [
            ("StoreDownloads", "store_downloads"),
            ("StoreAuth", "store_auth"),
            ("StoreSessions", "store_sessions"),
            ("StoreLibrary", "store_library"),
            ("StorePending", "store_pending"),
            ("StoreIdentity", "store_identity"),
            ("StoreMeta", "store_meta"),
        ]:
            self.assertIn(f'local {var}=require("miuread.{module}")', store)
        self.assertNotIn("function Store:download_state(", store)
        self.assertNotIn("function Store:save_session(", store)
        self.assertNotIn("function Store:auth()", store)
        self.assertNotIn("function Store:save_book(", store)
        self.assertNotIn("function Store:add_pending_install(", store)
        self.assertNotIn("function Store:shelf_cache(", store)
        self.assertNotIn("local defaults={", store)
        self.assertIn("local defaults={", defaults)
        for method in ["download_state", "save_download_state", "download_queue", "enqueue_download", "dequeue_download"]:
            self.assertIn(f"function StoreDownloads:{method}(", downloads)
        for method in ["auth", "save_auth", "auth_health", "clear_auth"]:
            self.assertIn(f"function StoreAuth:{method}(", auth)
        for method in ["session", "save_session", "clear_session", "invalidate_book_sync_context", "clear_login_bound_sessions"]:
            self.assertIn(f"function StoreSessions:{method}(", sessions)
        for method in ["library", "save_book", "save_variant", "all_books", "delete_book"]:
            self.assertIn(f"function StoreLibrary:{method}(", library)
        for method in ["pending_installs", "add_pending_install", "prune_pending_installs", "mark_read_report_consumed"]:
            self.assertIn(f"function StorePending:{method}(", pending)
        for method in ["epub_identity_light", "epub_identity", "file_record_fast", "file_record_from_identity", "identify_file", "file_record"]:
            self.assertIn(f"function StoreIdentity:{method}(", identity)
        for method in ["mark_last_read", "recent_reads", "record_recent_read", "shelf_cache", "update_cached_progress", "cover_guard", "cover_path"]:
            self.assertIn(f"function StoreMeta:{method}(", meta)

    def test_home_layout_constants_single_source(self):
        main = read_text("miuread.koplugin/main.lua")
        layouts = read_text("miuread.koplugin/miuread/home_layout_constants.lua")
        preferences = read_text("miuread.koplugin/miuread/plugin_preferences.lua")
        device = read_text("miuread.koplugin/miuread/plugin_device.lua")
        self.assertIn("HOME_ACTION_ITEM_ORDER", layouts)
        self.assertIn("HOME_PANEL_ITEM_ORDER", layouts)
        self.assertIn("HomeLayouts.HOME_ACTION_ITEM_ORDER", main)
        self.assertIn("HomeLayouts.HOME_ACTION_ITEM_ORDER", preferences)
        self.assertIn("HomeLayouts.HOME_PANEL_ITEM_ORDER", main)
        self.assertIn("HomeLayouts.HOME_PANEL_ITEM_ORDER", device)
        self.assertNotIn("local HOME_ACTION_ITEM_ORDER={", preferences)
        self.assertNotIn("local HOME_PANEL_ITEM_ORDER={", device)

    def test_reader_panel_base_usage(self):
        dialogs = [
            "reader_toc_dialog.lua",
            "reader_progress_dialog.lua",
            "reader_settings_dialog.lua",
            "reader_list_dialog.lua",
            "reader_frontlight_dialog.lua",
            "reader_control_center.lua",
            "reader_typography_dialog.lua",
        ]
        for name in dialogs:
            text = (PLUGIN / "miuread" / name).read_text(encoding="utf-8")
            self.assertIn("PanelBase:extend", text, name)
            self.assertIn("finish_close_widget", text, name)

    def test_home_cards_module_used(self):
        home_view = read_text("miuread.koplugin/miuread/home_view.lua")
        self.assertIn('local Cards = require("miuread.home_cards")', home_view)
        self.assertIn("local HomeWidget = InputContainer:extend", home_view)


class LegacyRetirementTests(unittest.TestCase):
    def test_no_legacy_requires_remain(self):
        offenders = []
        for path in sorted((PLUGIN / "miuread").rglob("*.lua")):
            text = path.read_text(encoding="utf-8")
            if 'require("miuread.legacy' in text or "legacy_adapter_worker" in text:
                offenders.append(str(path.relative_to(PLUGIN)))
        self.assertEqual([], offenders)

    def test_legacy_dir_removed(self):
        self.assertFalse((PLUGIN / "miuread" / "legacy").exists())

    def test_read_report_modules_present(self):
        for name in [
            "read_report_transport.lua",
            "read_report_worker.lua",
            "read_report_context.lua",
            "read_report_adapter.lua",
        ]:
            self.assertTrue((PLUGIN / "miuread" / name).exists(), name)

    def test_legacy_retirement_documented(self):
        readme = (ROOT / "docs" / "legacy" / "README.md").read_text(encoding="utf-8")
        self.assertIn("退役", readme)


class PackageStructureTests(unittest.TestCase):
    def test_dist_package_when_present(self):
        dist = ROOT / "dist"
        packages = sorted(dist.glob("miuread-v*-full.zip")) if dist.exists() else []
        if not packages:
            self.skipTest("no local dist package")
        for package in packages:
            with zipfile.ZipFile(package) as archive:
                names = archive.namelist()
                self.assertTrue(names, package.name)
                for name in names:
                    self.assertTrue(
                        name.startswith("miuread.koplugin/"),
                        f"{package.name}: leaked entry {name}",
                    )
                for required in [
                    "miuread.koplugin/_meta.lua",
                    "miuread.koplugin/main.lua",
                    "miuread.koplugin/miuread/config.lua",
                ]:
                    self.assertIn(required, names, package.name)


if __name__ == "__main__":
    unittest.main()
