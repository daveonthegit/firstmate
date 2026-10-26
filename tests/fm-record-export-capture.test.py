#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import resource
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "record_export", Path(__file__).resolve().parents[1] / "bin/fm-record-export.py"
)
exporter = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = exporter
spec.loader.exec_module(exporter)


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.home = self.base / "home"
        for name in ("config", "data", "state"):
            (self.home / name).mkdir(parents=True)
        self.output = self.base / "export"
        (self.home / "config/record-export-root").write_text(str(self.output) + "\n")
        self.args = tuple(str(self.home / name) for name in ("config", "data", "state"))
        (self.home / "data/projects.md").write_text("prior\n")
        self.sync()
        self.prior = os.readlink(self.output / "live")

    def sync(self):
        exporter.sync_records(str(self.home), *self.args)

    def assert_prior(self):
        self.assertEqual(os.readlink(self.output / "live"), self.prior)
        self.assertEqual((self.output / "live/data/projects.md").read_text(), "prior\n")

    def test_acknowledgement_during_collection_retains_prior_generation(self):
        inbox = self.home / "state/task.inbox"
        (inbox / "handled").mkdir(parents=True)
        (inbox / "001.msg").write_text("message\n")
        original = exporter.open_regular_at
        moved = False

        def open_and_ack(parent, name, label):
            nonlocal moved
            result = original(parent, name, label)
            if label == "state/task.inbox/001.msg" and not moved:
                moved = True
                (inbox / "001.msg").rename(inbox / "handled/001.msg")
            return result

        with patch.object(exporter, "open_regular_at", open_and_ack):
            with self.assertRaises((exporter.ExportError, OSError)):
                self.sync()
        self.assertTrue(moved)
        self.assert_prior()
        self.sync()
        self.assertFalse((self.output / "live/state/task.inbox/001.msg").exists())
        self.assertEqual((self.output / "live/state/task.inbox/handled/001.msg").read_text(), "message\n")

    def test_changes_after_copy_retain_prior_generation(self):
        for change in ("replace", "add", "rewrite"):
            with self.subTest(change=change):
                original = exporter.copy_source

                def copy_and_change(source, stage, fd):
                    original(source, stage, fd)
                    if change == "replace":
                        replacement = self.home / "data/replacement"
                        replacement.write_text("replacement\n")
                        replacement.replace(self.home / "data/projects.md")
                    elif change == "add":
                        (self.home / "state/task.status").write_text("new\n")
                    else:
                        (self.home / "data/projects.md").write_text("changed\n")

                with patch.object(exporter, "copy_source", copy_and_change):
                    with self.assertRaises(exporter.ExportError):
                        self.sync()
                self.assert_prior()
                (self.home / "data/projects.md").write_text("prior\n")
                (self.home / "state/task.status").unlink(missing_ok=True)

    def test_large_live_and_archive_captures_under_low_descriptor_limit(self):
        for index in range(150):
            task = f"task{index}"
            folder = self.home / "data" / task
            folder.mkdir()
            (folder / "brief.md").write_text("brief\n")
            (folder / "report.md").write_text("report\n")
            (self.home / f"state/{task}.meta").write_text("spawn_gen=one\n")
            (self.home / f"state/{task}.status").write_text("done\n")
        inbox = self.home / "state/task0.inbox"
        (inbox / "handled").mkdir(parents=True)
        for index in range(150):
            (inbox / f"{index:03}.msg").write_text("pending\n")
            (inbox / f"handled/{index:03}.msg").write_text("handled\n")
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, (min(64, soft), hard))
            self.sync()
            exporter.archive_task(str(self.home), *self.args, "task0")
            exporter.archive_task(str(self.home), *self.args, "task0")
        finally:
            resource.setrlimit(resource.RLIMIT_NOFILE, (soft, hard))
        self.assertEqual((self.output / "live/data/task149/report.md").read_text(), "report\n")
        manifest = json.loads((self.output / "archive/task0/one/manifest.v1.json").read_text())
        self.assertTrue(manifest)
        self.assertEqual((self.output / "archive/task0/one/inbox/handled/149.msg").read_text(), "handled\n")


if __name__ == "__main__":
    unittest.main()
