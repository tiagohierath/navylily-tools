import contextlib
import io
import os
import tempfile
import unittest
from pathlib import Path

import lilydrop


class LilydropTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.old_state = os.environ.get("LILYDROP_STATE")
        os.environ["LILYDROP_STATE"] = str(Path(self.temp_dir.name) / "shares.json")

    def tearDown(self):
        if self.old_state is None:
            os.environ.pop("LILYDROP_STATE", None)
        else:
            os.environ["LILYDROP_STATE"] = self.old_state
        self.temp_dir.cleanup()

    def run_command(self, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            lilydrop.main(list(args))
        return output.getvalue().strip().splitlines()

    def test_publish_and_reshare_keep_one_delivery(self):
        workspace = Path(__file__).resolve().parents[2]
        project_root = workspace / "alvorada2026"
        source = project_root / "manifest.json"
        if not source.is_file():
            self.skipTest("Alvorada project is not present in this workspace")

        first = self.run_command(
            "publish",
            str(source),
            "--project",
            "alvorada",
            "--project-name",
            "Alvorada",
            "--delivery",
            "1",
            "--allow-root",
            str(project_root),
            "--yes",
            "--base-url",
            "https://files.example.test",
        )[-1]
        second = self.run_command(
            "reshare",
            "alvorada",
            "1",
            "--base-url",
            "https://files.example.test",
        )[-1]

        state = lilydrop.load_state()
        self.assertEqual(set(state["deliveries"]), {"alvorada:1"})
        self.assertEqual(len(state["shares"]), 2)
        self.assertIn("/alvorada/1/", first)
        self.assertIn("/alvorada/1/", second)
        self.assertNotEqual(first, second)

    def test_broad_roots_are_rejected(self):
        workspace = Path(__file__).resolve().parents[2]
        project_root = workspace / "alvorada2026"
        with self.assertRaises(ValueError):
            lilydrop.approved_source(project_root / "manifest.json", workspace)
        with self.assertRaises(ValueError):
            lilydrop.approved_source(project_root / "manifest.json", Path.home())


if __name__ == "__main__":
    unittest.main()
