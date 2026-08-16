#!/usr/bin/env python3
"""
youtube_upload.py

Uploads exactly ONE video per run from the durable queue to the pinned YouTube
channel. It uploads privately at 18:00 America/Sao_Paulo and schedules
publication for 18:00 the next day, so every video sits private for a full day.

It is designed to fail closed under ambiguous state or API results, with
independent safety mechanisms:

  1. Persistent cadence state, a JSON state file records the time of the last
     upload and which files have already been uploaded. If today already has
     an upload (or the per-upload cooldown hasn't elapsed), the run exits at
     once.

  2. Hard single-item rule, each run selects exactly ONE video and uploads
     only that one. There is no batch/loop over the folder in live mode. Leftover
     videos simply wait for the next scheduled run.

  3. Run lock, an exclusive flock is taken before doing anything.
     If another instance (cron overlap, retry, manual mistake) is already
     running, this one exits immediately.

Plus: a file is never uploaded twice, every successful upload is appended to
the state's "uploaded" list (keyed by a full content hash), and such files are
skipped forever. Before an API request, a durable pending-upload record is
written. If the process crashes after YouTube accepts the upload, the next run
stops for reconciliation instead of risking a duplicate.

Credentials (NOT in the repo):
  - client_secret.json : OAuth client (Desktop app) from Google Cloud Console.
  - token.json         : created on first interactive run, refreshed after.
Paths are configurable via env / flags; see CONFIG below.

Usage:
  ./youtube_upload.py                # live: upload one video if allowed
  ./youtube_upload.py --dry-run      # exercise all guards, no API call
  ./youtube_upload.py --status       # print state and exit
  ./youtube_upload.py --authorize    # OAuth, verify, and pin the channel
  ./youtube_upload.py --verify-publications  # verify due videos are public

Scheduling is handled outside this script; see install_timer.sh. Use
`--cadence daily`, `--cadence weekly`, or `--cadence monthly` to switch the
persistent posting cadence. The script itself does not trust the scheduler:
its guards hold even if it is triggered 20 times.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
import random
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# CONFIG, override any of these with environment variables.
# ---------------------------------------------------------------------------
HOME = Path.home()
DEFAULT_STATE_DIR = HOME / ".local" / "state" / "navylily-youtube"

OUTPUT_DIR = Path(os.environ.get(
    "YT_OUTPUT_DIR",
    str(Path(__file__).resolve().parent / "videos" / "output"),
))
STATE_DIR = Path(os.environ.get("YT_STATE_DIR", str(DEFAULT_STATE_DIR)))
STATE_FILE = STATE_DIR / "state.json"
STATE_BACKUP_FILE = STATE_DIR / "state.json.bak"
LOCK_FILE = STATE_DIR / "upload.lock"
HEALTH_FILE = STATE_DIR / "health.json"
STAGING_DIR = STATE_DIR / "staging"

CLIENT_SECRET = Path(os.environ.get(
    "YT_CLIENT_SECRET", str(STATE_DIR / "client_secret.json")))
TOKEN_FILE = Path(os.environ.get("YT_TOKEN", str(STATE_DIR / "token.json")))

# Timezone for the calendar-based upload guards.
UPLOAD_TZ = os.environ.get("YT_TZ", "America/Sao_Paulo")

# The selected cadence is persisted in state.json by --cadence.
DEFAULT_CADENCE = os.environ.get("YT_CADENCE_DEFAULT", "daily")
VALID_CADENCES = {"daily", "weekly", "monthly"}
if DEFAULT_CADENCE not in VALID_CADENCES:
    raise ValueError(
        f"YT_CADENCE_DEFAULT must be one of {sorted(VALID_CADENCES)}")


def cadence(state: dict) -> str:
    value = state.get("cadence", DEFAULT_CADENCE)
    return value if value in VALID_CADENCES else DEFAULT_CADENCE


def min_hours_between(state: dict) -> float:
    """Stop two posts straddling midnight, without skipping a scheduled day.

    The same-day guard already allows only one upload per local date, so this
    floor exists for the 23:50-then-00:10 case alone. It must stay well under
    the gap between a late catch-up run and the next 18:00 slot: at 20h (the
    value tuned for the old 09:00 timer) a boot after 22:00 silently skipped
    the following day."""
    override = os.environ.get("YT_MIN_HOURS_BETWEEN")
    if override is not None:
        value = float(override)
        if not math.isfinite(value) or value < 0:
            raise ValueError("YT_MIN_HOURS_BETWEEN must be finite and non-negative")
        return value
    return 12.0 if cadence(state) == "daily" else 0.0


def cadence_schedule_block(state: dict) -> str | None:
    """Return a reason when a weekly/monthly schedule blocks the current day."""
    now = now_local()
    if cadence(state) == "weekly" and now.weekday() != 6:
        return "Weekly schedule: uploads run only on Sundays."
    if cadence(state) == "monthly" and now.day != 1:
        return "Monthly schedule: uploads run only on the first day of each month."
    return None

VIDEO_EXTS = {".mp4", ".mov", ".mkv", ".webm", ".m4v"}

# Scheduled auto-publish. The evening timer uploads each video PRIVATE, and
# YouTube flips it to PUBLIC at this local hour, PUBLISH_DELAY_DAYS later.
PUBLIC_HOUR = int(os.environ.get("YT_PUBLIC_HOUR", "18"))
if not 0 <= PUBLIC_HOUR <= 23:
    raise ValueError("YT_PUBLIC_HOUR must be an integer from 0 through 23")

# Whole days between the private upload and its publication. 1 means an 18:00
# upload goes public at 18:00 the next day, a full day of private window to set
# the real title and thumbnail. 0 restores same-day publication.
PUBLISH_DELAY_DAYS = int(os.environ.get("YT_PUBLISH_DELAY_DAYS", "1"))
if not 0 <= PUBLISH_DELAY_DAYS <= 30:
    raise ValueError(
        "YT_PUBLISH_DELAY_DAYS must be an integer from 0 through 30")

MIN_SCHEDULE_LEAD_HOURS = float(os.environ.get(
    "YT_MIN_SCHEDULE_LEAD_HOURS", "2"))
if (not math.isfinite(MIN_SCHEDULE_LEAD_HOURS)
        or MIN_SCHEDULE_LEAD_HOURS < 0):
    raise ValueError("YT_MIN_SCHEDULE_LEAD_HOURS must be finite and non-negative")

YOUTUBE_SCOPES = [
    "https://www.googleapis.com/auth/youtube.upload",
    "https://www.googleapis.com/auth/youtube.readonly",
]
VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class PreUploadError(RuntimeError):
    """A known-safe failure that happened before any upload request."""


def env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    normalized = raw.strip().lower()
    if normalized in {"1", "true", "yes"}:
        return True
    if normalized in {"0", "false", "no"}:
        return False
    raise ValueError(f"{name} must be true/false, yes/no, or 1/0")


MADE_FOR_KIDS = env_bool("YT_MADE_FOR_KIDS", False)
CONTAINS_SYNTHETIC_MEDIA = env_bool(
    "YT_CONTAINS_SYNTHETIC_MEDIA", False)
REQUIRE_TITLE_SIDECAR = env_bool("YT_REQUIRE_TITLE_SIDECAR", True)


def scheduled_publish_at() -> dt.datetime:
    """This run's publication time, PUBLISH_DELAY_DAYS out, as aware UTC.

    Days are added to the local wall clock before the hour is attached, so a
    timezone change moves the target to the same 18:00 rather than skewing it."""
    local = (now_local() + dt.timedelta(days=PUBLISH_DELAY_DAYS)).replace(
        hour=PUBLIC_HOUR, minute=0, second=0, microsecond=0)
    return local.astimezone(dt.timezone.utc)


def schedule_label(publish_at: dt.datetime) -> str:
    local = publish_at.astimezone(now_local().tzinfo)
    return f"private, auto-public {local:%a %Y-%m-%d} at {PUBLIC_HOUR:02d}:00"


def ensure_schedule_lead(publish_at: dt.datetime) -> None:
    remaining = publish_at - now_local().astimezone(dt.timezone.utc)
    minimum = dt.timedelta(hours=MIN_SCHEDULE_LEAD_HOURS)
    if remaining < minimum:
        local = publish_at.astimezone(now_local().tzinfo)
        raise PreUploadError(
            f"Less than {MIN_SCHEDULE_LEAD_HOURS:g}h remains before the "
            f"{local:%Y-%m-%d %H:%M} publication. Waiting for the next run "
            "prevents an immediate or partially processed public video.")

# Pool of neutral, random working titles. The real title is set manually later.
TITLE_WORDS_A = [
    "Aula", "Sessão", "Estudo", "Prática", "Encontro", "Capítulo", "Módulo",
]
TITLE_WORDS_B = [
    "de desenho", "de pintura", "de observação", "ao vivo", "tranquila",
    "navylily", "em andamento", "do dia",
]

# Description applied to every uploaded video. Edit freely.
VIDEO_DESCRIPTION = """\
Curso gratuito: https://navylily.tv/

Curso de desenho: https://navylily.tv/navy
Wiki: https://navylily.tv/wiki
Trabalhe conosco: https://navylily.tv/equipe

Newsletter: https://tiagohierath.substack.com/

Twitter/X: https://x.com/tiagohierath
Instagram: https://www.instagram.com/tiagohierath
Pinterest: https://pinterest.com/tiagohierath/

Jesus is King"""

# Tags applied to every uploaded video.
VIDEO_TAGS = [
    "art sovereignty",
    "independent artist",
    "linux for artists",
    "digital art",
    "drawing",
    "self hosting",
]


# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------
def now_local() -> dt.datetime:
    from zoneinfo import ZoneInfo
    return dt.datetime.now(ZoneInfo(UPLOAD_TZ))


def parse_state_time(value: object, field: str) -> dt.datetime | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise RuntimeError(f"Invalid {field} in {STATE_FILE}; refusing safely.")
    try:
        parsed = dt.datetime.fromisoformat(value)
    except ValueError as e:
        raise RuntimeError(
            f"Invalid {field} in {STATE_FILE}; refusing safely.") from e
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise RuntimeError(
            f"Naive {field} in {STATE_FILE}; refusing safely.")
    return parsed


def validate_state(state: object) -> dict:
    if not isinstance(state, dict):
        raise RuntimeError(f"Invalid upload state at {STATE_FILE}; refusing safely.")

    uploaded = state.get("uploaded", [])
    if not isinstance(uploaded, list):
        raise RuntimeError(f"Invalid uploaded list at {STATE_FILE}; refusing safely.")
    for i, entry in enumerate(uploaded):
        if not isinstance(entry, dict):
            raise RuntimeError(
                f"Invalid uploaded[{i}] at {STATE_FILE}; refusing safely.")
        key = entry.get("key")
        if not isinstance(key, str) or not SHA256_RE.fullmatch(key):
            raise RuntimeError(
                f"Invalid uploaded[{i}].key at {STATE_FILE}; refusing safely.")
        if not isinstance(entry.get("name"), str) or not entry["name"]:
            raise RuntimeError(
                f"Invalid uploaded[{i}].name at {STATE_FILE}; refusing safely.")
        parse_state_time(entry.get("uploaded_iso"), f"uploaded[{i}].uploaded_iso")
        expected = entry.get("expected_public_at")
        if expected is not None:
            parse_state_time(expected, f"uploaded[{i}].expected_public_at")
        video_id = entry.get("video_id")
        if video_id is not None and (
                not isinstance(video_id, str) or not VIDEO_ID_RE.fullmatch(video_id)):
            raise RuntimeError(
                f"Invalid uploaded[{i}].video_id at {STATE_FILE}; refusing safely.")
        checked = entry.get("last_checked_iso")
        if checked is not None:
            parse_state_time(checked, f"uploaded[{i}].last_checked_iso")

    queue = state.get("queue", [])
    if not isinstance(queue, list):
        raise RuntimeError(f"Invalid queue at {STATE_FILE}; refusing safely.")
    seen_queue_keys: set[str] = set()
    for i, entry in enumerate(queue):
        if not isinstance(entry, dict):
            raise RuntimeError(f"Invalid queue[{i}] at {STATE_FILE}; refusing safely.")
        key = entry.get("key")
        if (not isinstance(key, str) or not SHA256_RE.fullmatch(key)
                or key in seen_queue_keys):
            raise RuntimeError(
                f"Invalid queue[{i}].key at {STATE_FILE}; refusing safely.")
        seen_queue_keys.add(key)
        if not isinstance(entry.get("name"), str) or not entry["name"]:
            raise RuntimeError(
                f"Invalid queue[{i}].name at {STATE_FILE}; refusing safely.")
        parse_state_time(entry.get("queued_iso"), f"queue[{i}].queued_iso")

    parse_state_time(state.get("last_upload_iso"), "last_upload_iso")
    selected_cadence = state.get("cadence")
    if selected_cadence is not None and selected_cadence not in VALID_CADENCES:
        raise RuntimeError(f"Invalid cadence at {STATE_FILE}; refusing safely.")

    if "pending_upload" in state:
        pending = state["pending_upload"]
        if not isinstance(pending, dict):
            raise RuntimeError(
                f"Invalid pending_upload at {STATE_FILE}; refusing safely.")
        for field in ("key", "name", "title", "started_iso",
                      "expected_public_at", "staged_path"):
            if not isinstance(pending.get(field), str) or not pending[field]:
                raise RuntimeError(
                    f"Invalid pending_upload.{field} at {STATE_FILE}; "
                    "refusing safely.")
        if not SHA256_RE.fullmatch(pending["key"]):
            raise RuntimeError(
                f"Invalid pending_upload.key at {STATE_FILE}; refusing safely.")
        parse_state_time(pending["started_iso"], "pending_upload.started_iso")
        parse_state_time(
            pending["expected_public_at"], "pending_upload.expected_public_at")
        staged = Path(pending["staged_path"])
        try:
            staged.relative_to(STAGING_DIR)
        except ValueError as e:
            raise RuntimeError(
                f"Pending staging path is outside {STAGING_DIR}; refusing safely.") from e
        if not staged.is_file():
            raise RuntimeError(
                f"Pending staged video is missing at {staged}; refusing safely.")

    channel_id = state.get("expected_channel_id")
    if channel_id is not None and (
            not isinstance(channel_id, str) or not channel_id.startswith("UC")):
        raise RuntimeError(
            f"Invalid expected_channel_id at {STATE_FILE}; refusing safely.")
    return state


def load_state() -> dict:
    if not STATE_FILE.exists():
        if STATE_BACKUP_FILE.exists():
            # A real first install has neither file. A missing state file next
            # to a backup means the history was lost, and starting empty would
            # repost every video already public on the channel, one per day.
            raise RuntimeError(
                f"Upload state {STATE_FILE} is missing but its backup "
                f"{STATE_BACKUP_FILE} is still here, so this is not a fresh "
                "install. Refusing to upload because an empty history would "
                f"repost the whole channel. Restore it with:\n"
                f"  cp {STATE_BACKUP_FILE} {STATE_FILE}")
        return {"last_upload_iso": None, "uploaded": []}
    try:
        state = json.loads(STATE_FILE.read_text())
    except (json.JSONDecodeError, OSError) as e:
        raise RuntimeError(
            f"Cannot safely read upload state at {STATE_FILE}: {e}. "
            "Refusing to upload because treating it as empty could repost videos."
        ) from e
    return validate_state(state)


def fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def durable_write_json(path: Path, value: object, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    fd, tmp_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(value, f, indent=2, ensure_ascii=False)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        tmp.replace(path)
        fsync_dir(path.parent)
    except BaseException:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise


def save_state(state: dict) -> None:
    validate_state(state)
    if STATE_FILE.exists():
        try:
            previous = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            validate_state(previous)
        except (OSError, json.JSONDecodeError, RuntimeError) as e:
            raise RuntimeError(
                "Current state changed or became invalid before save; "
                "refusing to overwrite it.") from e
        durable_write_json(STATE_BACKUP_FILE, previous)
    durable_write_json(STATE_FILE, state)


def write_health(status: str, message: str) -> None:
    durable_write_json(HEALTH_FILE, {
        "status": status,
        "message": message,
        "checked_iso": now_local().isoformat(),
    })


def file_key(path: Path) -> str:
    """Stable identity for video bytes, unchanged if the file is renamed."""
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def stage_video(source: Path) -> tuple[Path, str]:
    """Copy stable source bytes into a private, fsynced, read-only staging file."""
    STAGING_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(STAGING_DIR, 0o700)
    fd, tmp_name = tempfile.mkstemp(
        prefix=".upload-", suffix=source.suffix.lower(), dir=STAGING_DIR)
    tmp = Path(tmp_name)
    digest = hashlib.sha256()
    try:
        with source.open("rb") as src, os.fdopen(fd, "wb") as dst:
            before = os.fstat(src.fileno())
            for chunk in iter(lambda: src.read(8 * 1024 * 1024), b""):
                digest.update(chunk)
                dst.write(chunk)
            after = os.fstat(src.fileno())
            dst.flush()
            os.fsync(dst.fileno())
        stable_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns")
        if any(getattr(before, f) != getattr(after, f) for f in stable_fields):
            raise PreUploadError(
                f"Queued file changed while staging: {source}. Refusing safely.")
        key = digest.hexdigest()
        final = STAGING_DIR / f"{key}{source.suffix.lower()}"
        os.chmod(tmp, 0o400)
        tmp.replace(final)
        fsync_dir(STAGING_DIR)
        return final, key
    except BaseException:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise


def remove_staged(path_value: str) -> None:
    path = Path(path_value)
    try:
        path.relative_to(STAGING_DIR)
    except ValueError as e:
        raise RuntimeError(
            f"Refusing to remove staging path outside {STAGING_DIR}: {path}") from e
    try:
        path.unlink()
        fsync_dir(STAGING_DIR)
    except FileNotFoundError:
        pass


def legacy_file_key(path: Path) -> str:
    """Pre-2026-08 identity, retained only to avoid reposting old state."""
    h = hashlib.sha256()
    h.update(path.name.encode())
    size = path.stat().st_size
    h.update(str(size).encode())
    with path.open("rb") as f:
        h.update(f.read(1 << 20))
        if size > (1 << 20):
            f.seek(-(1 << 20), os.SEEK_END)
            h.update(f.read(1 << 20))
    return h.hexdigest()


def already_uploaded_keys(state: dict) -> set[str]:
    return {e["key"] for e in state.get("uploaded", [])}


def was_uploaded(path: Path, state: dict) -> bool:
    """Recognize both current content-only and older filename-based records."""
    done = already_uploaded_keys(state)
    return file_key(path) in done or legacy_file_key(path) in done


def pending_upload(state: dict) -> dict | None:
    return state.get("pending_upload")


def record_uploaded(state: dict, pending: dict, video_id: str) -> None:
    """Finalize a pending record after an upload is known to exist."""
    url = f"https://youtu.be/{video_id}"
    state["last_upload_iso"] = now_local().isoformat()
    state.setdefault("uploaded", []).append({
        "key": pending["key"],
        "name": pending["name"],
        "video_id": video_id,
        "url": url,
        "uploaded_iso": now_local().isoformat(),
        "expected_public_at": pending["expected_public_at"],
        "publication_status": "scheduled",
    })
    state["queue"] = [
        entry for entry in state.get("queue", [])
        if entry["key"] != pending["key"]
    ]
    state.pop("pending_upload", None)


def cooldown_remaining(state: dict) -> float:
    """Hours still to wait before another upload is permitted (0 if allowed)."""
    last = state.get("last_upload_iso")
    if not last:
        return 0.0
    last_dt = parse_state_time(last, "last_upload_iso")
    assert last_dt is not None
    elapsed_h = (now_local() - last_dt).total_seconds() / 3600.0
    return max(0.0, min_hours_between(state) - elapsed_h)


def uploaded_today(state: dict) -> bool:
    last = state.get("last_upload_iso")
    if not last:
        return False
    last_dt = parse_state_time(last, "last_upload_iso")
    assert last_dt is not None
    now = now_local()
    return last_dt.astimezone(now.tzinfo).date() == now.date()


def uploaded_this_month(state: dict) -> bool:
    """True if an upload already happened in the current local calendar month."""
    last = state.get("last_upload_iso")
    if not last:
        return False
    last_dt = parse_state_time(last, "last_upload_iso")
    assert last_dt is not None
    now = now_local()
    last_dt = last_dt.astimezone(now.tzinfo)
    return (last_dt.year, last_dt.month) == (now.year, now.month)


def uploaded_this_week(state: dict) -> bool:
    last = state.get("last_upload_iso")
    if not last:
        return False
    last_dt = parse_state_time(last, "last_upload_iso")
    assert last_dt is not None
    now = now_local()
    return (last_dt.astimezone(now.tzinfo).isocalendar()[:2]
            == now.isocalendar()[:2])


# ---------------------------------------------------------------------------
# Selection, exactly one not-yet-uploaded video, in durable enqueue order.
# ---------------------------------------------------------------------------
def video_files() -> list[Path]:
    return [
        p for p in OUTPUT_DIR.glob("*")
        if p.is_file() and p.suffix.lower() in VIDEO_EXTS
    ]


def sync_queue(state: dict) -> None:
    """Persist current order so later mtime/rename changes cannot reorder it."""
    files = sorted(video_files(), key=lambda p: (p.stat().st_mtime_ns, p.name))
    by_key: dict[str, Path] = {}
    for path in files:
        by_key.setdefault(file_key(path), path)
    uploaded = already_uploaded_keys(state)
    done_current_keys = {
        key for key, path in by_key.items()
        if key in uploaded or legacy_file_key(path) in uploaded
    }
    old_queue = state.get("queue", [])
    queue = [entry for entry in old_queue
             if entry["key"] not in done_current_keys and entry["key"] in by_key]
    queued_keys = {entry["key"] for entry in queue}
    now_iso = now_local().isoformat()
    for key, path in by_key.items():
        if key not in done_current_keys and key not in queued_keys:
            queue.append({"key": key, "name": path.name, "queued_iso": now_iso})
            queued_keys.add(key)
    for entry in queue:
        entry["name"] = by_key[entry["key"]].name
    if queue != old_queue or "queue" not in state:
        state["queue"] = queue
        save_state(state)


def pick_video(state: dict) -> Path | None:
    candidates = video_files()
    by_key: dict[str, Path] = {}
    for path in candidates:
        by_key.setdefault(file_key(path), path)
    for entry in state.get("queue", []):
        path = by_key.get(entry["key"])
        if path is not None and not was_uploaded(path, state):
            return path
    for p in sorted(candidates, key=lambda p: (p.stat().st_mtime_ns, p.name)):
        if not was_uploaded(p, state):
            return p
    return None


def random_title() -> str:
    return f"{random.choice(TITLE_WORDS_A)} {random.choice(TITLE_WORDS_B)}"


def title_for(video: Path) -> str:
    """Real title for a video, if the recorder left one next to it.

    The lesson recorder writes a sidecar '<name>.title.txt' holding the exact
    wiki article title. If present (and non-empty) we use it, trimmed to
    YouTube's 100-char limit. Otherwise we fall back to a neutral random title,
    so this stays a drop-in for the old random-title behaviour."""
    sidecar = video.with_suffix(".title.txt")
    try:
        t = sidecar.read_text(encoding="utf-8").strip()
    except OSError:
        t = ""
    if t:
        return t[:100]
    if REQUIRE_TITLE_SIDECAR:
        raise PreUploadError(
            f"Missing non-empty title sidecar: {sidecar}. Refusing to publish "
            "a business video under a random title.")
    return random_title()


# ---------------------------------------------------------------------------
# YouTube API (imported lazily so --dry-run/--status work without the libs).
# ---------------------------------------------------------------------------
def get_service(run_oauth: bool = True):
    from google.auth.exceptions import RefreshError
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build

    creds = None
    if TOKEN_FILE.exists():
        try:
            token_info = json.loads(TOKEN_FILE.read_text(encoding="utf-8"))
            stored_scopes = token_info.get("scopes", [])
            if isinstance(stored_scopes, str):
                stored_scopes = stored_scopes.split()
            if not set(YOUTUBE_SCOPES).issubset(set(stored_scopes)):
                if not run_oauth:
                    raise PreUploadError(
                        "Stored YouTube authorization lacks channel-verification "
                        "access. Run ./youtube_upload.sh --authorize once.")
                print("YouTube authorization needs channel-verification access.")
            else:
                creds = Credentials.from_authorized_user_info(
                    token_info, YOUTUBE_SCOPES)
        except PreUploadError:
            raise
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as e:
            if not run_oauth:
                raise PreUploadError(
                    "Stored YouTube token is unreadable. Run "
                    "./youtube_upload.sh --authorize.") from e
            creds = None
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            try:
                creds.refresh(Request())
            except RefreshError as e:
                if not run_oauth:
                    raise PreUploadError(
                        "Stored YouTube authorization has expired or been "
                        "revoked. Run ./youtube_upload.sh --authorize, then "
                        "retry the upload."
                    ) from e
                print(f"Stored YouTube authorization is no longer valid ({e}).")
                print("Opening a fresh Google authorization flow...")
                creds = None
        if not creds or not creds.valid:
            if not run_oauth:
                raise PreUploadError(
                    "No valid token. Run ./youtube_upload.sh --authorize.")
            if not CLIENT_SECRET.exists():
                raise PreUploadError(
                    f"Missing OAuth client secret at {CLIENT_SECRET}. "
                    "Download a Desktop OAuth client from Google Cloud "
                    "Console and place it there.")
            flow = InstalledAppFlow.from_client_secrets_file(
                str(CLIENT_SECRET), YOUTUBE_SCOPES)
            # prompt="select_account consent" forces Google's account picker
            # every time (otherwise it silently reuses whichever account the
            # browser is signed into). access_type="offline" guarantees a
            # refresh token so unattended scheduled runs never need re-login.
            creds = flow.run_local_server(
                port=0,
                access_type="offline",
                prompt="select_account consent",
            )
        STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(STATE_DIR, 0o700)
        durable_write_json(TOKEN_FILE, json.loads(creds.to_json()))
    return build("youtube", "v3", credentials=creds)


def authenticated_channel(service) -> tuple[str, str]:
    try:
        response = service.channels().list(
            part="id,snippet", mine=True, maxResults=1).execute()
    except Exception as e:
        status = getattr(getattr(e, "resp", None), "status", None)
        if status in {401, 403}:
            raise PreUploadError(
                "YouTube authorization cannot verify the channel. Run "
                "./youtube_upload.sh --authorize.") from e
        raise
    items = response.get("items", [])
    if len(items) != 1 or not items[0].get("id"):
        raise PreUploadError(
            "The authorized Google account has no unambiguous YouTube channel.")
    channel = items[0]
    return channel["id"], channel.get("snippet", {}).get("title", "(untitled)")


def verify_expected_channel(service, state: dict, *, allow_pin: bool = False) -> str:
    channel_id, channel_title = authenticated_channel(service)
    expected = state.get("expected_channel_id")
    if expected is None:
        if not allow_pin:
            raise PreUploadError(
                "No YouTube channel is pinned. Run "
                "./youtube_upload.sh --authorize once.")
        state["expected_channel_id"] = channel_id
        save_state(state)
        print(f"Pinned YouTube channel: {channel_title} ({channel_id})")
        return channel_id
    if channel_id != expected:
        raise PreUploadError(
            f"WRONG YOUTUBE CHANNEL: authorized {channel_title} ({channel_id}), "
            f"but state is pinned to {expected}. Refusing to upload.")
    print(f"Verified YouTube channel: {channel_title} ({channel_id})")
    return channel_id


def migrate_legacy_publication_state(state: dict) -> None:
    """Track today's pre-hardening upload; label older history explicitly."""
    now = now_local()
    changed = False
    for entry in state.get("uploaded", []):
        if entry.get("expected_public_at"):
            continue
        uploaded = parse_state_time(
            entry.get("uploaded_iso"), f"uploaded[{entry['name']}].uploaded_iso")
        assert uploaded is not None
        local_uploaded = uploaded.astimezone(now.tzinfo)
        if local_uploaded.date() == now.date() and entry.get("video_id"):
            expected_local = (
                local_uploaded + dt.timedelta(days=PUBLISH_DELAY_DAYS)).replace(
                    hour=PUBLIC_HOUR, minute=0, second=0, microsecond=0)
            entry["expected_public_at"] = expected_local.astimezone(
                dt.timezone.utc).isoformat()
            entry["publication_status"] = "scheduled"
        else:
            entry["publication_status"] = "legacy_untracked"
        changed = True
    if changed:
        save_state(state)


def get_video_resource(
        service, video_id: str, *, missing_ok: bool = False) -> dict | None:
    """Fetch a video. With missing_ok, a vanished video returns None.

    A video that YouTube no longer knows about (deleted in Studio, removed by
    a strike) can never reach any expected state, so callers that would
    otherwise retry it forever ask for None and record it as terminal."""
    response = service.videos().list(
        part="snippet,status,processingDetails", id=video_id).execute()
    items = response.get("items", [])
    if len(items) != 1:
        if missing_ok:
            return None
        raise RuntimeError(f"YouTube video {video_id} was not found.")
    return items[0]


def validate_video_resource(
        resource: dict, expected_channel_id: str, *, require_public: bool) -> None:
    video_id = resource.get("id", "(unknown)")
    actual_channel = resource.get("snippet", {}).get("channelId")
    if actual_channel != expected_channel_id:
        raise RuntimeError(
            f"Video {video_id} belongs to channel {actual_channel}, not pinned "
            f"channel {expected_channel_id}.")
    status = resource.get("status", {})
    upload_status = status.get("uploadStatus")
    processing_status = resource.get("processingDetails", {}).get(
        "processingStatus")
    if upload_status in {"deleted", "failed", "rejected"}:
        raise RuntimeError(
            f"Video {video_id} upload status is {upload_status}: "
            f"{status.get('failureReason') or status.get('rejectionReason')}.")
    if processing_status in {"failed", "terminated"}:
        raise RuntimeError(
            f"Video {video_id} processing status is {processing_status}.")
    privacy = status.get("privacyStatus")
    if require_public and privacy != "public":
        raise RuntimeError(
            f"Video {video_id} should be public but is {privacy!r}. "
            "Refusing to advance the queue.")
    if not require_public and privacy not in {"private", "public"}:
        raise RuntimeError(
            f"Video {video_id} has unexpected privacy status {privacy!r}.")


def verify_uploaded_schedule(
        service, state: dict, video_id: str, expected_channel_id: str,
        expected_public_at: dt.datetime) -> None:
    resource = get_video_resource(service, video_id)
    validate_video_resource(
        resource, expected_channel_id, require_public=False)
    returned = resource.get("status", {}).get("publishAt")
    if now_local().astimezone(dt.timezone.utc) < expected_public_at:
        privacy = resource.get("status", {}).get("privacyStatus")
        if privacy != "private":
            raise RuntimeError(
                f"Video {video_id} became {privacy!r} before its expected "
                "publication time. Immediate manual action is required.")
        if returned is None:
            raise RuntimeError(
                f"YouTube accepted {video_id} but did not retain publishAt. "
                "The API project may be restricted to private uploads.")
        returned_dt = dt.datetime.fromisoformat(returned.replace("Z", "+00:00"))
        if returned_dt != expected_public_at:
            raise RuntimeError(
                f"YouTube scheduled {video_id} for {returned}, expected "
                f"{expected_public_at.isoformat()}.")
    for entry in state.get("uploaded", []):
        if entry.get("video_id") == video_id:
            entry["publication_status"] = "schedule_verified"
            entry["last_checked_iso"] = now_local().isoformat()
            break
    save_state(state)


# Publication statuses that can never change again, so they are never re-checked.
TERMINAL_PUBLICATION_STATUSES = {"public_verified", "missing"}

# YouTube flips a scheduled video a few minutes after publishAt, and the upload
# run itself starts at the publication hour. Without this grace period, an
# on-time run would check yesterday's video seconds before YouTube publishes it,
# read it as still private, and abort the whole upload.
PUBLICATION_GRACE_MINUTES = float(os.environ.get(
    "YT_PUBLICATION_GRACE_MINUTES", "30"))
if not math.isfinite(PUBLICATION_GRACE_MINUTES) or PUBLICATION_GRACE_MINUTES < 0:
    raise ValueError(
        "YT_PUBLICATION_GRACE_MINUTES must be finite and non-negative")


def verify_due_publications(
        service, state: dict, expected_channel_id: str) -> list[dict]:
    """Verify due videos are public. Returns entries found missing from YouTube."""
    now_utc = now_local().astimezone(dt.timezone.utc)
    changed = False
    missing: list[dict] = []
    for entry in state.get("uploaded", []):
        expected_raw = entry.get("expected_public_at")
        if (not expected_raw
                or entry.get("publication_status") in TERMINAL_PUBLICATION_STATUSES):
            continue
        expected = parse_state_time(
            expected_raw, f"uploaded[{entry.get('name')}].expected_public_at")
        assert expected is not None
        due_at = expected.astimezone(dt.timezone.utc) + dt.timedelta(
            minutes=PUBLICATION_GRACE_MINUTES)
        if due_at > now_utc:
            continue
        video_id = entry.get("video_id")
        if not isinstance(video_id, str) or not VIDEO_ID_RE.fullmatch(video_id):
            raise RuntimeError(
                f"Cannot verify publication for {entry['name']}: invalid video ID.")
        resource = get_video_resource(service, video_id, missing_ok=True)
        if resource is None:
            # It cannot become public later, so record it once and stop
            # re-checking. Raising here would block every future upload.
            entry["publication_status"] = "missing"
            entry["last_checked_iso"] = now_local().isoformat()
            changed = True
            missing.append(entry)
            print(f"MISSING from YouTube: https://youtu.be/{video_id} "
                  f"({entry['name']}). Recorded as missing; it will not be "
                  "checked again or re-uploaded.")
            continue
        validate_video_resource(resource, expected_channel_id, require_public=True)
        entry["publication_status"] = "public_verified"
        entry["last_checked_iso"] = now_local().isoformat()
        changed = True
        print(f"Verified public: https://youtu.be/{video_id}")
    if changed:
        save_state(state)
    return missing


def recent_upload_candidates(service, pending: dict) -> list[tuple[str, str]]:
    channel_response = service.channels().list(
        part="contentDetails", mine=True, maxResults=1).execute()
    items = channel_response.get("items", [])
    if len(items) != 1:
        raise PreUploadError("Could not inspect the authorized channel uploads.")
    playlist_id = (items[0].get("contentDetails", {})
                   .get("relatedPlaylists", {}).get("uploads"))
    if not playlist_id:
        raise PreUploadError("Could not find the channel's uploads playlist.")
    response = service.playlistItems().list(
        part="snippet,contentDetails", playlistId=playlist_id,
        maxResults=10).execute()
    started = parse_state_time(
        pending["started_iso"], "pending_upload.started_iso")
    assert started is not None
    threshold = started.astimezone(dt.timezone.utc) - dt.timedelta(hours=2)
    candidates: list[tuple[str, str]] = []
    for item in response.get("items", []):
        snippet = item.get("snippet", {})
        added_raw = snippet.get("publishedAt")
        video_id = (item.get("contentDetails", {}).get("videoId")
                    or snippet.get("resourceId", {}).get("videoId"))
        if not added_raw or not video_id:
            continue
        added = dt.datetime.fromisoformat(added_raw.replace("Z", "+00:00"))
        if added >= threshold:
            candidates.append((video_id, snippet.get("title", "(untitled)")))
    return candidates


def upload(
        service, path: Path, title: str, publish_at: dt.datetime) -> str:
    import http.client as httplib
    import httplib2
    from googleapiclient.errors import HttpError
    from googleapiclient.http import MediaFileUpload

    # Retry transient transport errors and 5xx responses with exponential
    # backoff, mirroring Google's reference uploader. A real (non -1) chunk
    # size lets a failed upload resume from where it stopped instead of
    # restarting from zero, and makes the progress line meaningful.
    RETRIABLE_EXCEPTIONS = (
        httplib2.HttpLib2Error, IOError, httplib.NotConnected,
        httplib.IncompleteRead, httplib.ImproperConnectionState,
        httplib.CannotSendRequest, httplib.CannotSendHeader,
        httplib.ResponseNotReady, httplib.BadStatusLine,
    )
    RETRIABLE_STATUS_CODES = {408, 429, 500, 502, 503, 504}
    MAX_RETRIES = 10

    body_status = {
        "privacyStatus": "private",
        "selfDeclaredMadeForKids": MADE_FOR_KIDS,
        "containsSyntheticMedia": CONTAINS_SYNTHETIC_MEDIA,
    }
    # The target is a whole day out, and ensure_schedule_lead re-checks it right
    # before this call, so publishAt stays in the future even when a persistent
    # timer wakes late.
    body_status["publishAt"] = publish_at.isoformat()
    print(f"  scheduled public: {publish_at.isoformat()} "
          f"({PUBLIC_HOUR:02d}:00 {UPLOAD_TZ}, "
          f"+{PUBLISH_DELAY_DAYS}d)")

    body = {
        "snippet": {
            "title": title,
            "description": VIDEO_DESCRIPTION,
            "tags": VIDEO_TAGS,
            "categoryId": "27",  # Education
        },
        "status": body_status,
    }
    media = MediaFileUpload(str(path), chunksize=8 * 1024 * 1024,
                            resumable=True, mimetype="video/*")
    req = service.videos().insert(
        part="snippet,status", body=body, media_body=media,
        notifySubscribers=True)

    response = None
    retry = 0
    while response is None:
        try:
            status, response = req.next_chunk()
            if status:
                print(f"  upload {int(status.progress() * 100)}%")
        except HttpError as e:
            if e.resp.status in RETRIABLE_STATUS_CODES:
                err = f"retriable HTTP {e.resp.status}: {e.content}"
                retry_after = e.resp.get("retry-after")
            else:
                raise
        except RETRIABLE_EXCEPTIONS as e:
            err = f"retriable transport error: {e}"
            retry_after = None
        else:
            continue  # no error this chunk, keep going (or finish)

        retry += 1
        if retry > MAX_RETRIES:
            raise RuntimeError(f"gave up after {MAX_RETRIES} retries")
        try:
            sleep_s = max(float(retry_after), 0.0) if retry_after else 0.0
        except ValueError:
            sleep_s = 0.0
        if sleep_s == 0.0:
            sleep_s = random.random() * (2 ** retry)
        print(f"  {err}\n  sleeping {sleep_s:.1f}s, retry {retry}/{MAX_RETRIES}")
        time.sleep(sleep_s)

    if "id" not in response:
        raise RuntimeError(f"unexpected upload response: {response}")
    return response["id"]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(
        description="Upload one video to YouTube on the configured cadence.")
    action = ap.add_mutually_exclusive_group()
    action.add_argument("--dry-run", action="store_true",
                        help="run all guards and selection, but do not upload")
    action.add_argument("--status", action="store_true",
                        help="print current state and exit")
    action.add_argument("--authorize", action="store_true",
                        help="run OAuth, verify and pin the channel, then exit")
    action.add_argument(
        "--verify-publications", action="store_true",
        help="verify due videos are public; never upload")
    action.add_argument(
        "--cadence", choices=sorted(VALID_CADENCES),
        help="persistently switch between daily, weekly, and monthly")
    action.add_argument(
        "--resolve-pending", metavar="VIDEO_ID",
        help="verify and record a known pending upload, then resume the queue")
    action.add_argument("--discard-pending", action="store_true",
                        help="interactively discard a verified-absent upload")
    args = ap.parse_args()

    # These diagnostic modes are genuinely read-only: no chmod, lock file,
    # health write, API request, or state mutation.
    if args.status:
        state = load_state()
        try:
            health = json.loads(HEALTH_FILE.read_text())
        except (OSError, json.JSONDecodeError):
            health = None
        print(json.dumps({
            "now_local": now_local().isoformat(),
            "last_upload_iso": state.get("last_upload_iso"),
            "uploaded_today": uploaded_today(state),
            "uploaded_this_month": uploaded_this_month(state),
            "uploaded_this_week": uploaded_this_week(state),
            "cadence": cadence(state),
            "min_hours_between": min_hours_between(state),
            "cadence_schedule_block": cadence_schedule_block(state),
            "cooldown_remaining_h": round(cooldown_remaining(state), 2),
            "uploaded_count": len(state.get("uploaded", [])),
            "queued_count": len(state.get("queue", [])),
            "pending_upload": pending_upload(state),
            "public_hour_local": PUBLIC_HOUR,
            "publish_delay_days": PUBLISH_DELAY_DAYS,
            "next_publish_at": scheduled_publish_at().isoformat(),
            "minimum_schedule_lead_hours": MIN_SCHEDULE_LEAD_HOURS,
            "expected_channel_id": state.get("expected_channel_id"),
            "health": health,
            "output_dir": str(OUTPUT_DIR),
        }, indent=2, ensure_ascii=False))
        return 0

    if args.dry_run:
        state = load_state()
        if pending_upload(state):
            print("A previous upload is pending reconciliation; dry run blocked.")
            return 1
        checks = [
            (uploaded_today(state), "Already uploaded today (same-day guard)."),
            (cadence(state) == "weekly" and uploaded_this_week(state),
             "Already uploaded this week (weekly guard)."),
            (cadence(state) == "monthly" and uploaded_this_month(state),
             "Already uploaded this month (monthly guard)."),
        ]
        schedule_reason = cadence_schedule_block(state)
        if schedule_reason:
            print(schedule_reason)
            return 0
        for blocked, message in checks:
            if blocked:
                print(message)
                return 0
        remaining = cooldown_remaining(state)
        if remaining > 0:
            print(f"Cooldown active: {remaining:.1f}h left.")
            return 0
        publish_at = scheduled_publish_at()
        try:
            ensure_schedule_lead(publish_at)
        except PreUploadError as e:
            print(e)
            return 0
        video = pick_video(state)
        if video is None:
            print("No new (not-yet-uploaded) videos in output folder.")
            return 0
        title = title_for(video)
        print(f"Selected: {video.name}")
        print(f"Title:    {title}  ({schedule_label(publish_at)})")
        print("[dry-run] would upload the above; no API call; state NOT modified.")
        return 0

    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(STATE_DIR, 0o700)

    # ---- Safety #3: run lock (taken first, held for the whole run). --------
    lock_fd = os.open(str(LOCK_FILE), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("Another upload run is already in progress, exiting.")
        return 0

    state = load_state()
    pending = pending_upload(state)

    if args.authorize:
        service = get_service(run_oauth=True)
        verify_expected_channel(service, state, allow_pin=True)
        migrate_legacy_publication_state(state)
        write_health("healthy", "Authorization and pinned channel verified.")
        print(f"Token stored at {TOKEN_FILE}")
        return 0

    if args.verify_publications:
        service = get_service(run_oauth=False)
        channel_id = verify_expected_channel(service, state)
        missing = verify_due_publications(service, state, channel_id)
        if missing:
            names = ", ".join(e["name"] for e in missing)
            write_health(
                "error", f"Videos missing from YouTube: {names}")
            print("Some due videos no longer exist on YouTube; they were "
                  "recorded as missing. Uploads continue normally.")
            return 5
        write_health("healthy", "All due YouTube publications verified.")
        print("All due YouTube publications verified.")
        return 0

    if args.cadence:
        state["cadence"] = args.cadence
        save_state(state)
        print(f"Posting cadence set to {args.cadence}.")
        return 0

    if args.resolve_pending:
        if not pending:
            print("No pending upload to resolve.")
            return 0
        if not VIDEO_ID_RE.fullmatch(args.resolve_pending):
            raise PreUploadError("A YouTube video ID must be exactly 11 safe characters.")
        service = get_service(run_oauth=False)
        channel_id = verify_expected_channel(service, state)
        resource = get_video_resource(service, args.resolve_pending)
        validate_video_resource(resource, channel_id, require_public=False)
        record_uploaded(state, pending, args.resolve_pending)
        save_state(state)
        expected = parse_state_time(
            pending["expected_public_at"], "pending_upload.expected_public_at")
        assert expected is not None
        if now_local().astimezone(dt.timezone.utc) < expected:
            verify_uploaded_schedule(
                service, state, args.resolve_pending, channel_id,
                expected.astimezone(dt.timezone.utc))
        else:
            validate_video_resource(resource, channel_id, require_public=True)
        remove_staged(pending["staged_path"])
        print(f"Pending upload recorded: https://youtu.be/{args.resolve_pending}")
        return 0

    if args.discard_pending:
        if not pending:
            print("No pending upload to discard.")
            return 0
        if not sys.stdin.isatty():
            raise PreUploadError(
                "--discard-pending requires an interactive terminal.")
        service = get_service(run_oauth=False)
        verify_expected_channel(service, state)
        candidates = recent_upload_candidates(service, pending)
        if candidates:
            found = "\n".join(
                f"  https://youtu.be/{video_id}  {title}"
                for video_id, title in candidates)
            raise PreUploadError(
                "Recent channel uploads could match the uncertain request. "
                "Inspect these and use --resolve-pending VIDEO_ID instead if "
                f"one matches:\n{found}")
        confirmation = input(
            f"Type the exact queued filename to confirm it is absent from "
            f"YouTube:\n  {pending['name']}\n> ")
        if confirmation != pending["name"]:
            raise PreUploadError("Confirmation did not match; pending upload retained.")
        state.pop("pending_upload")
        save_state(state)
        remove_staged(pending["staged_path"])
        print("Pending upload discarded; the video may be retried on the next run.")
        return 0

    if pending:
        write_health(
            "error", "Pending upload requires manual reconciliation.")
        print("A previous upload is pending reconciliation; refusing to risk a "
              "duplicate. Check YouTube Studio, then run either:\n"
              f"  {Path(__file__).name} --resolve-pending VIDEO_ID\n"
              f"  {Path(__file__).name} --discard-pending")
        return 1

    # ---- Safety #1: persistent same-day + cadence state. ------------------
    if uploaded_today(state):
        print("Already uploaded today, exiting (same-day guard).")
        return 0
    schedule_block = cadence_schedule_block(state)
    if schedule_block:
        print(schedule_block)
        return 0
    if cadence(state) == "weekly" and uploaded_this_week(state):
        print("Already uploaded this week, exiting (weekly guard).")
        return 0
    if cadence(state) == "monthly" and uploaded_this_month(state):
        print("Already uploaded this month, exiting (monthly guard).")
        return 0
    remaining = cooldown_remaining(state)
    if remaining > 0:
        print(f"Cooldown active: {remaining:.1f}h left before next upload, "
              "exiting.")
        return 0

    publish_at = scheduled_publish_at()
    try:
        ensure_schedule_lead(publish_at)
    except PreUploadError as e:
        write_health("error", str(e))
        print(e)
        return 4

    # Authentication and channel verification deliberately happen before a
    # pending record is created: they cannot create a YouTube video.
    service = get_service(run_oauth=False)
    channel_id = verify_expected_channel(service, state)
    verify_due_publications(service, state, channel_id)
    sync_queue(state)

    # ---- Safety #2: select exactly one video. -----------------------------
    video = pick_video(state)
    if video is None:
        write_health("warning", "Upload queue is empty.")
        print("No new (not-yet-uploaded) videos in output folder, nothing "
              "to do.")
        return 3

    title = title_for(video)
    sched = schedule_label(publish_at)
    print(f"Selected: {video.name}")
    print(f"Title:    {title}  ({sched})")

    staged, staged_key = stage_video(video)
    if staged_key in already_uploaded_keys(state):
        remove_staged(str(staged))
        print("Selected bytes were already uploaded; refusing a duplicate.")
        return 0
    ensure_schedule_lead(publish_at)

    # Persist fsynced intent before the non-transactional YouTube request. A power loss
    # after YouTube accepts it leaves this record behind and fails closed next
    # time, rather than uploading the same video again.
    pending = {
        "key": staged_key,
        "name": video.name,
        "title": title,
        "started_iso": now_local().isoformat(),
        "expected_public_at": publish_at.isoformat(),
        "staged_path": str(staged),
    }
    state["pending_upload"] = pending
    save_state(state)

    # Deliberately do not catch upload exceptions. A timeout or dropped response
    # may happen after YouTube accepted the video, so leaving the pending record
    # is safer than automatically retrying and creating a duplicate.
    video_id = upload(service, staged, title, publish_at)

    record_uploaded(state, pending, video_id)
    save_state(state)
    verify_uploaded_schedule(
        service, state, video_id, channel_id, publish_at)
    remove_staged(str(staged))
    write_health(
        "healthy", f"Uploaded and verified schedule for {video_id}.")
    print(f"Uploaded (private): https://youtu.be/{video_id}")
    print("State updated.")
    return 0


def cli() -> int:
    try:
        return main()
    except PreUploadError as e:
        if not any(arg in {"--dry-run", "--status"} for arg in sys.argv[1:]):
            try:
                write_health("error", str(e))
            except Exception:
                pass
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    except Exception as e:
        try:
            write_health("error", f"{type(e).__name__}: {e}")
        except Exception:
            pass
        print(f"CRITICAL: {e}", file=sys.stderr)
        raise


if __name__ == "__main__":
    sys.exit(cli())
