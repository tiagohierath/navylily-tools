#!/usr/bin/env python3
"""
youtube_upload.py

Uploads exactly ONE video per run from the output folder to YouTube, as a
PRIVATE video with a randomly chosen title, so you can set the real title and
thumbnail and publish manually later.

It is built to be *physically incapable* of over-posting, with three
independent safety mechanisms (any one of them alone stops a bad run):

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
  ./youtube_upload.py --authorize    # just run the OAuth flow and store token

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
import os
import random
import sys
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
LOCK_FILE = STATE_DIR / "upload.lock"

CLIENT_SECRET = Path(os.environ.get(
    "YT_CLIENT_SECRET", str(STATE_DIR / "client_secret.json")))
TOKEN_FILE = Path(os.environ.get("YT_TOKEN", str(STATE_DIR / "token.json")))

# Timezone for the calendar-based upload guards.
UPLOAD_TZ = os.environ.get("YT_TZ", "America/Sao_Paulo")

# The selected cadence is persisted in state.json by --cadence.
DEFAULT_CADENCE = os.environ.get("YT_CADENCE_DEFAULT", "daily")
VALID_CADENCES = {"daily", "weekly", "monthly"}


def cadence(state: dict) -> str:
    value = state.get("cadence", DEFAULT_CADENCE)
    return value if value in VALID_CADENCES else DEFAULT_CADENCE


def min_hours_between(state: dict) -> float:
    """Avoid a daily fence-post failure when one run finishes slightly late."""
    override = os.environ.get("YT_MIN_HOURS_BETWEEN")
    if override is not None:
        return float(override)
    return 20.0 if cadence(state) == "daily" else 0.0


def cadence_schedule_block(state: dict) -> str | None:
    """Return a reason when a weekly/monthly schedule blocks the current day."""
    now = now_local()
    if cadence(state) == "weekly" and now.weekday() != 6:
        return "Weekly schedule: uploads run only on Sundays."
    if cadence(state) == "monthly" and now.day != 1:
        return "Monthly schedule: uploads run only on the first day of each month."
    return None

VIDEO_EXTS = {".mp4", ".mov", ".mkv", ".webm", ".m4v"}

# Scheduled auto-publish. Each video is uploaded PRIVATE with a `publishAt` this
# many days out; YouTube then flips it to PUBLIC on its own at that moment. That
# gives a fixed window to set the real title + thumbnail in YouTube Studio while
# it's still private, with no separate timer to run. Set to 0 to upload plain
# private (no schedule) and publish by hand.
PUBLISH_AFTER_DAYS = float(os.environ.get("YT_PUBLISH_AFTER_DAYS", "1"))

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
    try:
        from zoneinfo import ZoneInfo
        return dt.datetime.now(ZoneInfo(UPLOAD_TZ))
    except Exception:
        # Fall back to system local time if tz database is unavailable.
        return dt.datetime.now().astimezone()


def load_state() -> dict:
    if not STATE_FILE.exists():
        return {"last_upload_iso": None, "uploaded": []}
    try:
        state = json.loads(STATE_FILE.read_text())
    except (json.JSONDecodeError, OSError) as e:
        raise RuntimeError(
            f"Cannot safely read upload state at {STATE_FILE}: {e}. "
            "Refusing to upload because treating it as empty could repost videos."
        ) from e
    if not isinstance(state, dict) or not isinstance(state.get("uploaded", []), list):
        raise RuntimeError(
            f"Invalid upload state at {STATE_FILE}. Refusing to upload safely.")
    return state


def save_state(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(STATE_DIR, 0o700)
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2, ensure_ascii=False))
    os.chmod(tmp, 0o600)
    tmp.replace(STATE_FILE)  # atomic


def file_key(path: Path) -> str:
    """Stable identity for video bytes, unchanged if the file is renamed."""
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


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
    return {e["key"] for e in state.get("uploaded", []) if "key" in e}


def was_uploaded(path: Path, state: dict) -> bool:
    """Recognize both current content-only and older filename-based records."""
    done = already_uploaded_keys(state)
    return file_key(path) in done or legacy_file_key(path) in done


def pending_upload(state: dict) -> dict | None:
    pending = state.get("pending_upload")
    return pending if isinstance(pending, dict) else None


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
    })
    state.pop("pending_upload", None)


def cooldown_remaining(state: dict) -> float:
    """Hours still to wait before another upload is permitted (0 if allowed)."""
    last = state.get("last_upload_iso")
    if not last:
        return 0.0
    try:
        last_dt = dt.datetime.fromisoformat(last)
    except ValueError:
        return 0.0
    if last_dt.tzinfo is None:
        last_dt = last_dt.astimezone()
    elapsed_h = (now_local() - last_dt).total_seconds() / 3600.0
    return max(0.0, min_hours_between(state) - elapsed_h)


def uploaded_today(state: dict) -> bool:
    last = state.get("last_upload_iso")
    if not last:
        return False
    try:
        last_dt = dt.datetime.fromisoformat(last)
    except ValueError:
        return False
    if last_dt.tzinfo is None:
        last_dt = last_dt.astimezone()
    return last_dt.date() == now_local().date()


def uploaded_this_month(state: dict) -> bool:
    """True if an upload already happened in the current local calendar month."""
    last = state.get("last_upload_iso")
    if not last:
        return False
    try:
        last_dt = dt.datetime.fromisoformat(last)
    except ValueError:
        return False
    if last_dt.tzinfo is None:
        last_dt = last_dt.astimezone()
    now = now_local()
    return (last_dt.year, last_dt.month) == (now.year, now.month)


def uploaded_this_week(state: dict) -> bool:
    last = state.get("last_upload_iso")
    if not last:
        return False
    try:
        last_dt = dt.datetime.fromisoformat(last)
    except ValueError:
        return False
    if last_dt.tzinfo is None:
        last_dt = last_dt.astimezone()
    return last_dt.isocalendar()[:2] == now_local().isocalendar()[:2]


# ---------------------------------------------------------------------------
# Selection, exactly one not-yet-uploaded video, oldest first.
# ---------------------------------------------------------------------------
def pick_video(state: dict) -> Path | None:
    candidates = [
        p for p in sorted(OUTPUT_DIR.glob("*"))
        if p.is_file() and p.suffix.lower() in VIDEO_EXTS
    ]
    for p in sorted(candidates, key=lambda p: p.stat().st_mtime):
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
    return t[:100] if t else random_title()


# ---------------------------------------------------------------------------
# YouTube API (imported lazily so --dry-run/--status work without the libs).
# ---------------------------------------------------------------------------
def get_service(run_oauth: bool = True):
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build

    scopes = ["https://www.googleapis.com/auth/youtube.upload"]
    creds = None
    if TOKEN_FILE.exists():
        creds = Credentials.from_authorized_user_file(str(TOKEN_FILE), scopes)
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        elif run_oauth:
            if not CLIENT_SECRET.exists():
                sys.exit(f"Missing OAuth client secret at {CLIENT_SECRET}. "
                         "Download a Desktop OAuth client from Google Cloud "
                         "Console and place it there.")
            flow = InstalledAppFlow.from_client_secrets_file(
                str(CLIENT_SECRET), scopes)
            # prompt="select_account consent" forces Google's account picker
            # every time (otherwise it silently reuses whichever account the
            # browser is signed into). access_type="offline" guarantees a
            # refresh token so unattended scheduled runs never need re-login.
            creds = flow.run_local_server(
                port=0,
                access_type="offline",
                prompt="select_account consent",
            )
        else:
            sys.exit("No valid token and OAuth disabled.")
        STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(STATE_DIR, 0o700)
        TOKEN_FILE.write_text(creds.to_json())
        os.chmod(TOKEN_FILE, 0o600)
    return build("youtube", "v3", credentials=creds)


def upload(service, path: Path, title: str) -> str:
    import http.client as httplib
    import time

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
    RETRIABLE_STATUS_CODES = {500, 502, 503, 504}
    MAX_RETRIES = 10

    status = {
        "privacyStatus": "private",
        "selfDeclaredMadeForKids": False,
    }
    # publishAt only takes effect on a private video: YouTube keeps it private
    # until this instant, then makes it public automatically. Must be RFC 3339 /
    # ISO 8601 in UTC, an aware UTC datetime's isoformat() is exactly that.
    if PUBLISH_AFTER_DAYS > 0:
        publish_at = (dt.datetime.now(dt.timezone.utc)
                      + dt.timedelta(days=PUBLISH_AFTER_DAYS)).replace(microsecond=0)
        status["publishAt"] = publish_at.isoformat()
        print(f"  scheduled public: {publish_at.isoformat()} "
              f"(+{PUBLISH_AFTER_DAYS:g} days)")

    body = {
        "snippet": {
            "title": title,
            "description": VIDEO_DESCRIPTION,
            "tags": VIDEO_TAGS,
            "categoryId": "27",  # Education
        },
        "status": status,
    }
    media = MediaFileUpload(str(path), chunksize=8 * 1024 * 1024,
                            resumable=True, mimetype="video/*")
    req = service.videos().insert(
        part="snippet,status", body=body, media_body=media)

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
            else:
                raise
        except RETRIABLE_EXCEPTIONS as e:
            err = f"retriable transport error: {e}"
        else:
            continue  # no error this chunk, keep going (or finish)

        retry += 1
        if retry > MAX_RETRIES:
            raise RuntimeError(f"gave up after {MAX_RETRIES} retries")
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
    ap.add_argument("--dry-run", action="store_true",
                    help="run all guards and selection, but do not upload")
    ap.add_argument("--status", action="store_true",
                    help="print current state and exit")
    ap.add_argument("--authorize", action="store_true",
                    help="run the OAuth flow, store the token, and exit")
    ap.add_argument("--cadence", choices=sorted(VALID_CADENCES),
                    help="persistently switch between daily, weekly, and monthly")
    ap.add_argument("--resolve-pending", metavar="VIDEO_ID",
                    help="record a verified pending upload, then resume the queue")
    ap.add_argument("--discard-pending", action="store_true",
                    help="discard a verified-not-uploaded pending record")
    args = ap.parse_args()

    if args.resolve_pending and args.discard_pending:
        ap.error("--resolve-pending and --discard-pending cannot be used together")

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

    if args.status:
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
            "pending_upload": pending,
            "publish_after_days": PUBLISH_AFTER_DAYS,
            "output_dir": str(OUTPUT_DIR),
        }, indent=2, ensure_ascii=False))
        return 0

    if args.authorize:
        get_service(run_oauth=True)
        print(f"Token stored at {TOKEN_FILE}")
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
        record_uploaded(state, pending, args.resolve_pending)
        save_state(state)
        print(f"Pending upload recorded: https://youtu.be/{args.resolve_pending}")
        return 0

    if args.discard_pending:
        if not pending:
            print("No pending upload to discard.")
            return 0
        state.pop("pending_upload", None)
        save_state(state)
        print("Pending upload discarded; the video may be retried on the next run.")
        return 0

    if pending:
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

    # ---- Safety #2: select exactly one video. -----------------------------
    video = pick_video(state)
    if video is None:
        print("No new (not-yet-uploaded) videos in output folder, nothing "
              "to do.")
        return 0

    title = title_for(video)
    sched = (f"private, auto-public in {PUBLISH_AFTER_DAYS:g}d"
             if PUBLISH_AFTER_DAYS > 0 else "private")
    print(f"Selected: {video.name}")
    print(f"Title:    {title}  ({sched})")

    if args.dry_run:
        print("[dry-run] would upload the above; state NOT modified.")
        return 0

    # Persist intent before the non-transactional YouTube request. A power loss
    # after YouTube accepts it leaves this record behind and fails closed next
    # time, rather than uploading the same video again.
    pending = {
        "key": file_key(video),
        "name": video.name,
        "title": title,
        "started_iso": now_local().isoformat(),
    }
    state["pending_upload"] = pending
    save_state(state)

    try:
        service = get_service(run_oauth=False if TOKEN_FILE.exists() else True)
    except Exception:
        # Authentication failed before an upload request was issued, so retrying
        # later is safe.
        state.pop("pending_upload", None)
        save_state(state)
        raise

    # Deliberately do not catch upload exceptions. A timeout or dropped response
    # may happen after YouTube accepted the video, so leaving the pending record
    # is safer than automatically retrying and creating a duplicate.
    video_id = upload(service, video, title)

    record_uploaded(state, pending, video_id)
    save_state(state)
    print(f"Uploaded (private): https://youtu.be/{video_id}")
    print("State updated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
