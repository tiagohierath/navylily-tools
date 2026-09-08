import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "youtube_upload.py"
SPEC = importlib.util.spec_from_file_location("youtube_upload_under_test", SCRIPT)
yt = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(yt)


class Call:
    def __init__(self, value):
        self.value = value

    def execute(self):
        return self.value


class Channels:
    def __init__(self, service):
        self.service = service

    def list(self, **kwargs):
        if "contentDetails" in kwargs["part"]:
            return Call({"items": [{"contentDetails": {"relatedPlaylists": {
                "uploads": "uploads-playlist"}}}]})
        return Call({"items": [{
            "id": self.service.channel_id,
            "snippet": {"title": "Pinned business channel"},
        }]})


class Videos:
    def __init__(self, service):
        self.service = service

    def list(self, **kwargs):
        video_id = kwargs["id"]
        if video_id in self.service.missing_ids:
            return Call({"items": []})
        resource = {
            "id": video_id,
            "snippet": {"channelId": self.service.channel_id},
            "status": {
                "privacyStatus": self.service.privacy,
                "publishAt": self.service.publish_at,
                "uploadStatus": "uploaded",
            },
            "processingDetails": {"processingStatus": "processing"},
        }
        return Call({"items": [resource]})


class PlaylistItems:
    def list(self, **kwargs):
        return Call({"items": []})


class Service:
    def __init__(self, channel_id, publish_at, privacy="private",
                 missing_ids=()):
        self.channel_id = channel_id
        self.publish_at = publish_at
        self.privacy = privacy
        self.missing_ids = set(missing_ids)

    def channels(self):
        return Channels(self)

    def videos(self):
        return Videos(self)

    def playlistItems(self):
        return PlaylistItems()


class UploaderSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp_obj = tempfile.TemporaryDirectory(prefix="youtube-test-")
        self.root = Path(self.tmp_obj.name)
        self.out = self.root / "output"
        self.out.mkdir()
        self.state_dir = self.root / "state"
        self.state_dir.mkdir()
        self.channel_id = "UC" + "a" * 22
        self.fixed_now = dt.datetime(
            2026, 8, 10, 9, 0,
            tzinfo=dt.timezone(dt.timedelta(hours=-3)))
        self.state = {
            "last_upload_iso": None,
            "uploaded": [],
            "expected_channel_id": self.channel_id,
        }
        self.write_state(self.state)
        self.saved_globals = {
            name: getattr(yt, name) for name in (
                "STATE_DIR", "STATE_FILE", "STATE_BACKUP_FILE", "LOCK_FILE",
                "HEALTH_FILE", "STAGING_DIR", "OUTPUT_DIR", "TOKEN_FILE",
                "CLIENT_SECRET", "now_local")
        }
        yt.STATE_DIR = self.state_dir
        yt.STATE_FILE = self.state_dir / "state.json"
        yt.STATE_BACKUP_FILE = self.state_dir / "state.json.bak"
        yt.LOCK_FILE = self.state_dir / "upload.lock"
        yt.HEALTH_FILE = self.state_dir / "health.json"
        yt.STAGING_DIR = self.state_dir / "staging"
        yt.OUTPUT_DIR = self.out
        yt.TOKEN_FILE = self.state_dir / "token.json"
        yt.CLIENT_SECRET = self.state_dir / "client_secret.json"
        yt.now_local = lambda: self.fixed_now

    def tearDown(self):
        for name, value in self.saved_globals.items():
            setattr(yt, name, value)
        self.tmp_obj.cleanup()

    def write_state(self, state):
        (self.state_dir / "state.json").write_text(json.dumps(state))

    def make_video(self, name="one.mp4", data=b"stable video bytes"):
        path = self.out / name
        path.write_bytes(data)
        path.with_suffix(".title.txt").write_text("Exact business title")
        return path

    def service(self, privacy="private"):
        # Echo the schedule the uploader actually asks for, so these fakes track
        # the configured publication delay instead of hardcoding one.
        return Service(
            self.channel_id, yt.scheduled_publish_at().isoformat(), privacy)

    def run_main(self, *args):
        # main() holds its flock until process exit, so successive in-process
        # runs need distinct lock files to avoid falsely tripping the overlap
        # guard and making later assertions vacuous.
        self.run_count = getattr(self, "run_count", 0) + 1
        yt.LOCK_FILE = self.state_dir / f"upload-{self.run_count}.lock"
        with mock.patch.object(sys, "argv", ["youtube_upload.py", *args]):
            return yt.main()

    def test_success_is_staged_recorded_verified_and_cleaned(self):
        self.make_video()
        service = self.service()
        captured = {}

        def fake_upload(_service, staged, title, publish_at):
            captured["staged"] = staged
            self.assertEqual(staged.parent, yt.STAGING_DIR)
            self.assertEqual(staged.stat().st_mode & 0o777, 0o400)
            self.assertEqual(title, "Exact business title")
            return "abcdefghijk"

        with mock.patch.object(yt, "get_service", return_value=service), \
             mock.patch.object(yt, "upload", side_effect=fake_upload):
            self.assertEqual(self.run_main(), 0)

        state = yt.load_state()
        self.assertNotIn("pending_upload", state)
        self.assertEqual(len(state["uploaded"]), 1)
        self.assertEqual(state["uploaded"][0]["publication_status"],
                         "schedule_verified")
        self.assertFalse(captured["staged"].exists())
        self.assertTrue(yt.STATE_BACKUP_FILE.exists())
        health = json.loads(yt.HEALTH_FILE.read_text())
        self.assertEqual(health["status"], "healthy")

    def test_upload_now_selects_exact_video_and_bypasses_daily_guard(self):
        self.make_video("older.mp4", b"older queued bytes")
        target = self.make_video("just-recorded.mp4", b"the requested take")
        self.write_state({
            "last_upload_iso": self.fixed_now.isoformat(),
            "uploaded": [],
            "expected_channel_id": self.channel_id,
        })
        captured = {}

        def fake_upload(_service, staged, _title, _publish_at):
            captured["bytes"] = staged.read_bytes()
            return "abcdefghijk"

        with mock.patch.object(yt, "get_service", return_value=self.service()), \
             mock.patch.object(yt, "upload", side_effect=fake_upload):
            self.assertEqual(self.run_main("--upload-now", str(target)), 0)

        self.assertEqual(captured["bytes"], b"the requested take")
        self.assertEqual(yt.load_state()["uploaded"][0]["name"], target.name)

    def test_upload_now_refuses_rerender_with_same_logical_name(self):
        target = self.make_video("lesson.mp4", b"randomized second render")
        self.write_state({
            "last_upload_iso": self.fixed_now.isoformat(),
            "uploaded": [{
                "key": "a" * 64,
                "name": target.name,
                "uploaded_iso": self.fixed_now.isoformat(),
            }],
            "expected_channel_id": self.channel_id,
        })

        with mock.patch.object(yt, "get_service", return_value=self.service()), \
             mock.patch.object(yt, "upload") as upload:
            self.assertEqual(
                self.run_main("--upload-now", str(target)), 0)
            upload.assert_not_called()
        state = yt.load_state()
        self.assertEqual(state.get("queue"), [])
        self.assertEqual(len(state["uploaded"]), 1)

    def test_reauthorize_forces_fresh_oauth(self):
        service = self.service()
        with mock.patch.object(yt, "get_service", return_value=service) as get_service:
            self.assertEqual(self.run_main("--reauthorize"), 0)
        get_service.assert_called_once_with(run_oauth=True, force_oauth=True)

    def test_uncertain_upload_keeps_durable_pending_and_staged_bytes(self):
        self.make_video()
        service = self.service()
        with mock.patch.object(yt, "get_service", return_value=service), \
             mock.patch.object(yt, "upload", side_effect=TimeoutError("lost response")):
            with self.assertRaises(TimeoutError):
                self.run_main()
        state = yt.load_state()
        self.assertIn("pending_upload", state)
        self.assertTrue(Path(state["pending_upload"]["staged_path"]).is_file())
        self.assertEqual(len(state["uploaded"]), 0)

    def test_wrong_channel_fails_before_pending_or_upload(self):
        self.make_video()
        service = self.service()
        service.channel_id = "UC" + "b" * 22
        with mock.patch.object(yt, "get_service", return_value=service), \
             mock.patch.object(yt, "upload") as upload:
            with self.assertRaises(yt.PreUploadError):
                self.run_main()
            upload.assert_not_called()
        self.assertNotIn("pending_upload", yt.load_state())

    def test_auth_failure_cannot_create_false_pending(self):
        self.make_video()
        with mock.patch.object(
                yt, "get_service",
                side_effect=yt.PreUploadError("revoked token")), \
             mock.patch.object(yt, "upload") as upload:
            with self.assertRaises(yt.PreUploadError):
                self.run_main()
            upload.assert_not_called()
        self.assertNotIn("pending_upload", yt.load_state())
        self.assertFalse(yt.STAGING_DIR.exists())

    def test_current_and_legacy_hashes_both_prevent_duplicate(self):
        for legacy in (False, True):
            yt.LOCK_FILE = self.state_dir / f"upload-{legacy}.lock"
            video = self.make_video(data=b"already posted")
            key = yt.legacy_file_key(video) if legacy else yt.file_key(video)
            self.write_state({
                "last_upload_iso": (self.fixed_now - dt.timedelta(days=1)).isoformat(),
                "uploaded": [{
                    "key": key, "name": video.name,
                    "uploaded_iso": (self.fixed_now - dt.timedelta(days=1)).isoformat(),
                }],
                "expected_channel_id": self.channel_id,
            })
            service = self.service()
            with mock.patch.object(yt, "get_service", return_value=service), \
                 mock.patch.object(yt, "upload") as upload:
                self.assertEqual(self.run_main(), 3)
                upload.assert_not_called()
            video.unlink()
            video.with_suffix(".title.txt").unlink()

    def test_due_private_video_blocks_next_upload(self):
        first = self.make_video("first.mp4", b"first")
        key = yt.file_key(first)
        first.unlink()
        first.with_suffix(".title.txt").unlink()
        self.make_video("second.mp4", b"second")
        expected = self.fixed_now - dt.timedelta(hours=1)
        self.write_state({
            "last_upload_iso": (self.fixed_now - dt.timedelta(days=1)).isoformat(),
            "uploaded": [{
                "key": key, "name": "first.mp4", "video_id": "abcdefghijk",
                "uploaded_iso": (self.fixed_now - dt.timedelta(days=1)).isoformat(),
                "expected_public_at": expected.astimezone(dt.timezone.utc).isoformat(),
                "publication_status": "schedule_verified",
            }],
            "expected_channel_id": self.channel_id,
        })
        service = self.service(privacy="private")
        with mock.patch.object(yt, "get_service", return_value=service), \
             mock.patch.object(yt, "upload") as upload:
            with self.assertRaises(RuntimeError):
                self.run_main()
            upload.assert_not_called()

    def deleted_video_state(self, key):
        expected = self.fixed_now - dt.timedelta(hours=1)
        return {
            "last_upload_iso": (self.fixed_now - dt.timedelta(days=1)).isoformat(),
            "uploaded": [{
                "key": key, "name": "first.mp4", "video_id": "abcdefghijk",
                "uploaded_iso": (self.fixed_now - dt.timedelta(days=1)).isoformat(),
                "expected_public_at": expected.astimezone(dt.timezone.utc).isoformat(),
                "publication_status": "schedule_verified",
            }],
            "expected_channel_id": self.channel_id,
        }

    def test_video_deleted_from_youtube_does_not_block_future_uploads(self):
        first = self.make_video("first.mp4", b"first")
        key = yt.file_key(first)
        first.unlink()
        first.with_suffix(".title.txt").unlink()
        self.make_video("second.mp4", b"second")
        self.write_state(self.deleted_video_state(key))
        service = self.service()
        service.missing_ids = {"abcdefghijk"}

        with mock.patch.object(yt, "get_service", return_value=service), \
             mock.patch.object(yt, "upload", return_value="bcdefghijkl") as upload:
            self.assertEqual(self.run_main(), 0)
            upload.assert_called_once()

        state = yt.load_state()
        self.assertEqual(state["uploaded"][0]["publication_status"], "missing")
        self.assertEqual(state["uploaded"][1]["video_id"], "bcdefghijkl")

    def test_missing_video_is_reported_once_then_never_rechecked(self):
        first = self.make_video("first.mp4", b"first")
        key = yt.file_key(first)
        first.unlink()
        first.with_suffix(".title.txt").unlink()
        self.write_state(self.deleted_video_state(key))
        service = self.service()
        service.missing_ids = {"abcdefghijk"}

        with mock.patch.object(yt, "get_service", return_value=service):
            self.assertEqual(self.run_main("--verify-publications"), 5)
            health = json.loads(yt.HEALTH_FILE.read_text())
            self.assertEqual(health["status"], "error")
            # Terminal now, so the next verification run is clean and quiet.
            self.assertEqual(self.run_main("--verify-publications"), 0)

    def test_corrupt_safety_fields_fail_closed(self):
        for update in (
            {"last_upload_iso": "not-a-time"},
            {"cadence": "wekly"},
            {"pending_upload": "corrupt"},
        ):
            state = dict(self.state)
            state.update(update)
            self.write_state(state)
            with self.assertRaises(RuntimeError):
                yt.load_state()

    def test_timezone_is_normalized_before_same_day_guard(self):
        yt.now_local = lambda: dt.datetime(
            2026, 8, 10, 23, 30,
            tzinfo=dt.timezone(dt.timedelta(hours=-3)))
        state = {"last_upload_iso": "2026-08-11T01:00:00+00:00", "uploaded": []}
        self.assertTrue(yt.uploaded_today(state))

    def test_dry_run_is_read_only_and_never_calls_api(self):
        self.make_video()
        before = yt.STATE_FILE.read_bytes()
        with mock.patch.object(yt, "get_service") as get_service:
            self.assertEqual(self.run_main("--dry-run"), 0)
            get_service.assert_not_called()
        self.assertEqual(yt.STATE_FILE.read_bytes(), before)
        self.assertFalse(yt.LOCK_FILE.exists())

    def test_actions_are_mutually_exclusive(self):
        with self.assertRaises(SystemExit):
            self.run_main("--dry-run", "--cadence", "weekly")

    def test_lost_state_next_to_a_backup_refuses_to_start_over(self):
        # Losing state.json while state.json.bak survives is not a fresh
        # install: starting empty would repost every video already public.
        self.make_video()
        yt.save_state(dict(self.state))          # writes state.json.bak
        self.assertTrue(yt.STATE_BACKUP_FILE.exists())
        yt.STATE_FILE.unlink()
        with self.assertRaises(RuntimeError) as caught:
            yt.load_state()
        self.assertIn("repost", str(caught.exception))
        with mock.patch.object(yt, "get_service") as get_service, \
             mock.patch.object(yt, "upload") as upload:
            with self.assertRaises(RuntimeError):
                self.run_main()
            upload.assert_not_called()
            get_service.assert_not_called()

    def test_fresh_install_with_no_state_at_all_still_starts(self):
        yt.STATE_FILE.unlink()
        self.assertFalse(yt.STATE_BACKUP_FILE.exists())
        state = yt.load_state()
        self.assertEqual(state["uploaded"], [])

    def test_late_night_catch_up_does_not_block_the_next_slot(self):
        # A machine that was off at 18:00 catches up at 23:10. The next day's
        # 18:00 run is only 18.8h later, so a cooldown of 20h silently skipped
        # a day. The cooldown must stay under that gap.
        self.make_video()
        late = dt.datetime(2026, 8, 10, 23, 10,
                           tzinfo=dt.timezone(dt.timedelta(hours=-3)))
        self.write_state({
            "last_upload_iso": late.isoformat(),
            "uploaded": [],
            "expected_channel_id": self.channel_id,
        })
        yt.now_local = lambda: late + dt.timedelta(hours=18, minutes=50)
        self.assertEqual(yt.cooldown_remaining(yt.load_state()), 0.0)

    def test_next_day_target_survives_calendar_and_dst_edges(self):
        from zoneinfo import ZoneInfo
        cases = [
            # (zone, upload local time, expected local publication)
            ("America/Sao_Paulo", (2026, 8, 31, 18, 0), (2026, 9, 1, 18, 0)),
            ("America/Sao_Paulo", (2026, 12, 31, 18, 0), (2027, 1, 1, 18, 0)),
            ("America/Sao_Paulo", (2028, 2, 28, 18, 0), (2028, 2, 29, 18, 0)),
            # Clocks jump forward overnight: the target stays 18:00 local, so
            # the UTC instant shifts by an hour instead of the wall clock.
            ("America/New_York", (2026, 3, 7, 18, 0), (2026, 3, 8, 18, 0)),
        ]
        saved_tz = yt.UPLOAD_TZ
        try:
            for zone, upload, expect in cases:
                yt.UPLOAD_TZ = zone
                tz = ZoneInfo(zone)
                yt.now_local = lambda tz=tz, upload=upload: dt.datetime(
                    *upload, tzinfo=tz)
                got = yt.scheduled_publish_at().astimezone(tz)
                self.assertEqual(
                    got, dt.datetime(*expect, tzinfo=tz),
                    f"{zone} {upload} -> {got}")
        finally:
            yt.UPLOAD_TZ = saved_tz

    def test_publication_is_scheduled_for_the_next_day(self):
        self.make_video()
        captured = {}

        def fake_upload(_service, _staged, _title, publish_at):
            captured["publish_at"] = publish_at
            return "abcdefghijk"

        with mock.patch.object(yt, "get_service", return_value=self.service()), \
             mock.patch.object(yt, "upload", side_effect=fake_upload):
            self.assertEqual(self.run_main(), 0)

        expected = (self.fixed_now + dt.timedelta(days=1)).replace(
            hour=yt.PUBLIC_HOUR, minute=0, second=0, microsecond=0)
        self.assertEqual(captured["publish_at"], expected)
        self.assertEqual(
            yt.load_state()["uploaded"][0]["expected_public_at"],
            expected.astimezone(dt.timezone.utc).isoformat())

    def test_video_still_flipping_within_grace_does_not_block(self):
        # The upload run starts at the publication hour, so yesterday's video is
        # due but YouTube may take a few minutes to flip it. That must not abort
        # the run the way a genuinely unpublished video does.
        first = self.make_video("first.mp4", b"first")
        key = yt.file_key(first)
        first.unlink()
        first.with_suffix(".title.txt").unlink()
        self.make_video("second.mp4", b"second")
        just_due = self.fixed_now - dt.timedelta(minutes=5)
        self.write_state({
            "last_upload_iso": (self.fixed_now - dt.timedelta(days=1)).isoformat(),
            "uploaded": [{
                "key": key, "name": "first.mp4", "video_id": "abcdefghijk",
                "uploaded_iso": (self.fixed_now - dt.timedelta(days=1)).isoformat(),
                "expected_public_at": just_due.astimezone(
                    dt.timezone.utc).isoformat(),
                "publication_status": "schedule_verified",
            }],
            "expected_channel_id": self.channel_id,
        })
        service = self.service(privacy="private")
        with mock.patch.object(yt, "get_service", return_value=service), \
             mock.patch.object(yt, "upload", return_value="bcdefghijkl") as upload:
            self.assertEqual(self.run_main(), 0)
            upload.assert_called_once()

        state = yt.load_state()
        # Still not verified, so the next run past the grace re-checks it.
        self.assertEqual(state["uploaded"][0]["publication_status"],
                         "schedule_verified")


if __name__ == "__main__":
    unittest.main()
