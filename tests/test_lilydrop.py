import contextlib
import io
import os
import tempfile
import unittest
import threading
import time
import zipfile
from argparse import Namespace
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch, Mock
from urllib.request import urlopen
from urllib.error import HTTPError

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

    def test_directory_deliveries_are_zip_archives(self):
        source = Path(self.temp_dir.name) / "To-deliver-1"
        source.mkdir()
        (source / "art.txt").write_text("approved")
        (source / "empty-folder").mkdir()
        package, file_count, source_size = lilydrop.package_source(source, "vexian", 1)

        self.assertEqual(package.suffix, ".zip")
        self.assertEqual(file_count, 1)
        self.assertEqual(source_size, len("approved"))
        with zipfile.ZipFile(package) as archive:
            self.assertEqual(archive.read("To-deliver-1/art.txt"), b"approved")
            self.assertIn("To-deliver-1/empty-folder/", archive.namelist())

    def test_preview_http_and_share_access(self):
        root = Path(self.temp_dir.name)
        package = root / "delivery.tar.gz"
        package.write_bytes(b"archive")
        cover = root / "lilydrop-preview.jpg"
        cover.write_bytes(b"\xff\xd8\xff\xd9")
        state = lilydrop.empty_state()
        state["deliveries"]["vexian:1"] = {
            "project_id": "vexian", "project_name": 'Vexian & "art"', "number": 1,
            "archive_name": package.name, "package_path": str(package),
            "file_count": 62, "package_size": 7,
        }
        state["shares"]["test-token"] = {"delivery_id": "vexian:1", "expires_at": time.time() + 60}
        lilydrop.save_state(state)
        servers = []

        def start_server(address, handler):
            server = ThreadingHTTPServer(address, handler)
            servers.append(server)
            return Mock()

        with patch.object(lilydrop, "ThreadingHTTPServer", side_effect=start_server):
            lilydrop.serve_command(Namespace(host="127.0.0.1", port=0))
        server = servers[0]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_port}/vexian/1/test-token"
        try:
            with urlopen(url) as response:
                body = response.read().decode()
                self.assertIn('property="og:image"', body)
                self.assertIn('/vexian/1/test-token/preview.jpg', body)
                self.assertIn('Vexian &amp; &quot;art&quot;', body)
            with urlopen(url + "/preview.jpg") as response:
                self.assertEqual(response.headers["Content-Type"], "image/jpeg")
                self.assertEqual(response.read(), cover.read_bytes())
            with urlopen(url + "/delivery.tar.gz") as response:
                self.assertEqual(response.read(), b"archive")
            with self.assertRaises(HTTPError) as error:
                urlopen(url.replace("test-token", "wrong") + "/preview.jpg")
            self.assertEqual(error.exception.code, 404)
            for change in ({"expires_at": 0}, {"expires_at": time.time() + 60, "revoked_at": time.time()}):
                state["shares"]["test-token"].update(change)
                lilydrop.save_state(state)
                with self.assertRaises(HTTPError) as error:
                    urlopen(url + "/preview.jpg")
                self.assertEqual(error.exception.code, 410)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_automatic_preview_prefers_pdf_and_preserves_cover_on_failure(self):
        root = Path(self.temp_dir.name)
        source = root / "source"
        source.mkdir()
        (source / "a.png").write_bytes(b"image")
        (source / "b.pdf").write_bytes(b"pdf")
        self.assertEqual(lilydrop.preview_source(source), source / "b.pdf")
        cover = root / "lilydrop-preview.jpg"
        cover.write_bytes(b"previous cover")
        with patch.object(lilydrop, "render_tool", return_value=["renderer"]), \
             patch.object(lilydrop.subprocess, "run", side_effect=OSError("renderer failed")):
            with self.assertRaises(OSError):
                lilydrop.create_preview(source, root)
        self.assertEqual(cover.read_bytes(), b"previous cover")
        (source / "b.pdf").unlink()
        self.assertEqual(lilydrop.preview_source(source), source / "a.png")

    def test_publish_automatically_attempts_preview(self):
        workspace = Path(__file__).resolve().parents[2]
        source = workspace / "alvorada2026" / "manifest.json"
        if not source.is_file():
            self.skipTest("Alvorada project is not present")
        with patch.object(lilydrop, "create_preview", side_effect=ValueError("missing renderer")) as render:
            with contextlib.redirect_stderr(io.StringIO()) as errors:
                lines = self.run_command("publish", str(source), "--project", "example", "--delivery", "1",
                                         "--allow-root", str(source.parent), "--yes")
            render.assert_called_once()
            self.assertIn("Preview unavailable", errors.getvalue())
            self.assertIn("/example/1/", lines[-1])
            self.assertIn("example:1", lilydrop.load_state()["deliveries"])


if __name__ == "__main__":
    unittest.main()
