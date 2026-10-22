#!/usr/bin/env python3
"""Regression tests for the KDE VS Code jump-list generator."""

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MANAGER = REPO_ROOT / "scripts" / "code-jumplist-manager.py"


class JumpListManagerTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.home = Path(self.temporary_directory.name)
        self.fake_bin = self.home / "fake-bin"
        self.fake_bin.mkdir()
        self.cache_log = self.home / "kbuildsycoca.log"
        cache_builder = self.fake_bin / "kbuildsycoca6"
        cache_builder.write_text(
            "#!/bin/sh\n"
            "printf 'refresh\\n' >> \"$KBUILDSYCOCA_TEST_LOG\"\n"
        )
        cache_builder.chmod(0o755)
        self.environment = os.environ.copy()
        self.environment.update({
            "HOME": str(self.home),
            "KBUILDSYCOCA_TEST_LOG": str(self.cache_log),
            "PATH": f"{self.fake_bin}:{self.environment['PATH']}",
        })

    def tearDown(self):
        self.temporary_directory.cleanup()

    @property
    def state_file(self):
        return self.home / ".config/vscode-jumplist/state.json"

    @property
    def settings_file(self):
        return self.home / ".config/Code/User/settings.json"

    @property
    def storage_file(self):
        return self.home / ".config/Code/User/globalStorage/storage.json"

    @property
    def desktop_file(self):
        return self.home / ".local/share/applications/code.desktop"

    def write_json(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def run_manager(self, *arguments):
        return subprocess.run(
            [str(MANAGER), *map(str, arguments)],
            env=self.environment,
            text=True,
            capture_output=True,
            check=True,
        )

    def test_first_add_creates_lock_state_and_atomic_desktop(self):
        project = self.home / "Projects/First Project"
        self.run_manager("add", project)

        self.assertTrue((self.home / ".config/vscode-jumplist/.lock").is_file())
        self.assertTrue(self.state_file.is_file())
        self.assertTrue(self.desktop_file.is_file())
        self.assertEqual(self.desktop_file.stat().st_mode & 0o777, 0o755)
        self.assertEqual(
            list(self.desktop_file.parent.glob(".code.desktop.*")),
            [],
            "atomic-write temporary files must be cleaned up",
        )

    def test_refresh_uses_vendor_icon_and_only_rebuilds_cache_on_change(self):
        project = self.home / "Projects/Alpha"
        self.write_json(self.storage_file, {
            "windowsState": {
                "lastActiveWindow": {"folder": project.as_uri()},
                "openedWindows": [],
            },
            "backupWorkspaces": {"folders": []},
        })

        self.run_manager("refresh")
        first_stat = self.desktop_file.stat()
        first_content = self.desktop_file.read_text()
        self.run_manager("refresh")
        second_stat = self.desktop_file.stat()

        self.assertIn("Icon=vscode", first_content)
        self.assertNotIn("Icon=visual-studio-code", first_content)
        self.assertIn("Name=Alpha\n", first_content)
        self.assertIn("Name=Pin Alpha\n", first_content)
        self.assertEqual(first_stat.st_ino, second_stat.st_ino)
        self.assertEqual(first_stat.st_mtime_ns, second_stat.st_mtime_ns)
        self.assertEqual(self.cache_log.read_text().splitlines(), ["refresh"])

    def test_reopened_project_moves_first_pins_are_excluded_and_limit_is_ten(self):
        projects = [self.home / f"Projects/Project{i}" for i in range(12)]
        old_recent = [
            {"uri": str(project), "name": project.name, "timestamp": index}
            for index, project in enumerate(projects)
        ]
        self.write_json(self.state_file, {"recent": old_recent, "pinned": []})
        self.write_json(self.settings_file, {
            "kdeJumplist.pinnedFolders": [str(projects[11])],
        })
        self.write_json(self.storage_file, {
            "windowsState": {
                "lastActiveWindow": {"folder": projects[5].as_uri()},
                "openedWindows": [{"folder": projects[11].as_uri()}],
            },
            "backupWorkspaces": {"folders": []},
        })

        self.run_manager("refresh")
        state = json.loads(self.state_file.read_text())
        recent_paths = [item["uri"] for item in state["recent"]]
        desktop_content = self.desktop_file.read_text()

        self.assertEqual(recent_paths[0], str(projects[5]))
        self.assertNotIn(str(projects[11]), recent_paths)
        self.assertEqual(len(recent_paths), 10)
        self.assertEqual(desktop_content.count("[Desktop Action open-recent-"), 10)
        self.assertNotIn("Name=Pin Project11\n", desktop_content)

    def test_icon_resolver_uses_absolute_packaged_fallback(self):
        module_spec = importlib.util.spec_from_file_location("jumplist", MANAGER)
        module = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(module)

        vendor_desktop = self.home / "vendor-code.desktop"
        fallback = self.home / "vscode.png"
        vendor_desktop.write_text("[Desktop Entry]\nIcon=missing-icon\n")
        fallback.write_bytes(b"not-an-image-needed-for-this-test")

        self.assertEqual(
            module.resolve_vscode_icon((vendor_desktop,), fallback),
            str(fallback),
        )

    def test_icon_resolver_accepts_vendor_desktop_absolute_icon(self):
        module_spec = importlib.util.spec_from_file_location("jumplist_vendor", MANAGER)
        module = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(module)

        vendor_desktop = self.home / "vendor-code.desktop"
        vendor_icon = self.home / "future-vendor-code.png"
        fallback = self.home / "vscode.png"
        vendor_icon.write_bytes(b"vendor-icon")
        fallback.write_bytes(b"fallback-icon")
        vendor_desktop.write_text(
            "[Desktop Entry]\n"
            f"Icon={vendor_icon}\n"
            "[Desktop Action new-empty-window]\n"
            "Icon=wrong-action-icon\n"
        )

        self.assertEqual(
            module.resolve_vscode_icon((vendor_desktop,), fallback),
            str(vendor_icon),
        )


if __name__ == "__main__":
    unittest.main()
