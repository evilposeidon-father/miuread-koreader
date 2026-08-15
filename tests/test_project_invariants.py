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

    def test_changelog_current_version_records_controller_splits(self):
        changelog = read_text("CHANGELOG.md")
        meta = read_text("miuread.koplugin/_meta.lua")
        version = re.search(r'version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', meta).group(1)
        section = changelog.split(f"## {version}")[1].split("\n## ")[0]
        for name in ["plugin_update", "plugin_sync", "plugin_download", "plugin_reader"]:
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
    def test_lazy_modules_exist(self):
        sources = ["miuread.koplugin/main.lua"]
        sources += [
            f"miuread.koplugin/miuread/{name}"
            for name in [
                "plugin_maintenance.lua",
                "plugin_update.lua",
                "plugin_sync.lua",
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
            ("PluginDownload", "plugin_download.lua", ["download", "show_downloads", "show_download_cleanup_dialog"]),
            ("PluginReader", "plugin_reader.lua", ["show_reader_quick_panel", "show_reader_control_center", "reader_quick_actions_menu"]),
        ]:
            module_path = f"miuread.koplugin/miuread/{file_name}"
            self.assertIn(f'local {module_name}=require("miuread.{file_name[:-4]}")', main)
            self.assertIn(f"{module_name}.install(Plugin)", main)
            module = read_text(module_path)
            self.assertIn("function M.install(target)", module)
            for method in methods:
                self.assertIn(f"function Plugin:{method}(", module)

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


class LegacyNetworkBoundaryTests(unittest.TestCase):
    def test_only_adapter_requires_legacy_modules(self):
        offenders = []
        for path in sorted((PLUGIN / "miuread").glob("*.lua")):
            text = path.read_text(encoding="utf-8")
            if 'require("miuread.legacy.' in text or 'require("miuread.legacy")' in text:
                if path.name != "legacy_adapter_worker.lua":
                    offenders.append(path.name)
        self.assertEqual([], offenders)

    def test_legacy_readme_documents_decision(self):
        readme = (PLUGIN / "miuread" / "legacy" / "README.md").read_text(encoding="utf-8")
        self.assertIn("保留", readme)
        self.assertIn("边界", readme)
        self.assertIn("迁移方向", readme)


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
