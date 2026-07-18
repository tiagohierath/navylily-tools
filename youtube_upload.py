#!/usr/bin/env python3
"""
youtube_upload.py

Uploads exactly ONE video per run from the output folder to YouTube, as a
PRIVATE video with a randomly chosen title, so you can set the real title and
thumbnail and publish manually later.

It is built to be *physically incapable* of over-posting, with three
independent safety mechanisms (any one of them alone stops a bad run):

  1. Persistent daily state, a JSON state file records the date of the last
     upload and which files have already been uploaded. If today already has an
     upload (or the per-upload cooldown hasn't elapsed), the run exits at once.

  2. Hard single-item rule, each run selects exactly ONE video and uploads
     only that one. There is no batch/loop over the folder in live mode. Leftover
     videos simply wait for the next scheduled run.

  3. Run lock, an exclusive flock is taken before doing anything.
     If another instance (cron overlap, retry, manual mistake) is already
     running, this one exits immediately.

Plus: a file is never uploaded twice, every successful upload is appended to
the state's "uploaded" list (keyed by content hash + name), and such files are
skipped forever.

Credentials (NOT in the repo):
  - client_secret.json : OAuth client (Desktop app) from Google Cloud Console.
  - token.json         : created on first interactive run, refreshed after.
Paths are configurable via env / flags; see CONFIG below.

Usage:
  ./youtube_upload.py                # live: upload one video if allowed
  ./youtube_upload.py --dry-run      # exercise all guards, no API call
  ./youtube_upload.py --status       # print state and exit
  ./youtube_upload.py --authorize    # just run the OAuth flow and store token

Scheduling (6pm America/Sao_Paulo, once a day) is handled outside this script;
see install_timer.sh / the README. The script itself does not trust the
scheduler, the guards above hold even if it's triggered 20 times.
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

# Timezone for "one upload per calendar day".
UPLOAD_TZ = os.environ.get("YT_TZ", "America/Sao_Paulo")

# Minimum hours between two uploads. This is only a floor to stop an accidental
# double-post (e.g. a manual run plus the timer on the same evening); the real
# "one per calendar day" cap is uploaded_today(). It MUST stay well under 24, or
# a fixed-time daily timer skips every other day: the timestamp is recorded when
# the upload *finishes* (a few minutes past 18:00), so next day's 18:00 fire is
# <24h later and a 24h floor would block it. 12h can never block the next day.
MIN_HOURS_BETWEEN = float(os.environ.get("YT_MIN_HOURS_BETWEEN", "12"))

VIDEO_EXTS = {".mp4", ".mov", ".mkv", ".webm", ".m4v"}

# Scheduled auto-publish. Each video is uploaded PRIVATE with a `publishAt` this
# many days out; YouTube then flips it to PUBLIC on its own at that moment. That
# gives a fixed window to set the real title + thumbnail in YouTube Studio while
# it's still private, with no separate timer to run. Set to 0 to upload plain
# private (no schedule) and publish by hand.
PUBLISH_AFTER_DAYS = float(os.environ.get("YT_PUBLISH_AFTER_DAYS", "7"))

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
NavyLilyWorks:
https://navylily.tv/

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
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    return {"last_upload_iso": None, "uploaded": []}


def save_state(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2, ensure_ascii=False))
    tmp.replace(STATE_FILE)  # atomic


def file_key(path: Path) -> str:
    """Stable identity for a video: size + a hash of head/tail + name."""
    h = hashlib.sha256()
    h.update(path.name.encode())
    try:
        size = path.stat().st_size
        h.update(str(size).encode())
        with path.open("rb") as f:
            h.update(f.read(1 << 20))           # first 1 MiB
            if size > (1 << 20):
                f.seek(-(1 << 20), os.SEEK_END)
                h.update(f.read(1 << 20))       # last 1 MiB
    except OSError:
        pass
    return h.hexdigest()


def already_uploaded_keys(state: dict) -> set[str]:
    return {e["key"] for e in state.get("uploaded", []) if "key" in e}


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
    return max(0.0, MIN_HOURS_BETWEEN - elapsed_h)


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


# ---------------------------------------------------------------------------
# Selection, exactly one not-yet-uploaded video, oldest first.
# ---------------------------------------------------------------------------
def pick_video(state: dict) -> Path | None:
    done = already_uploaded_keys(state)
    candidates = [
        p for p in sorted(OUTPUT_DIR.glob("*"))
        if p.is_file() and p.suffix.lower() in VIDEO_EXTS
    ]
    for p in sorted(candidates, key=lambda p: p.stat().st_mtime):
        if file_key(p) not in done:
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
            # refresh token so unattended daily runs never need re-login.
            creds = flow.run_local_server(
                port=0,
                access_type="offline",
                prompt="select_account consent",
            )
        else:
            sys.exit("No valid token and OAuth disabled.")
        STATE_DIR.mkdir(parents=True, exist_ok=True)
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
    ap = argparse.ArgumentParser(description="Upload one video/day to YouTube.")
    ap.add_argument("--dry-run", action="store_true",
                    help="run all guards and selection, but do not upload")
    ap.add_argument("--status", action="store_true",
                    help="print current state and exit")
    ap.add_argument("--authorize", action="store_true",
                    help="run the OAuth flow, store the token, and exit")
    args = ap.parse_args()

    STATE_DIR.mkdir(parents=True, exist_ok=True)

    # ---- Safety #3: run lock (taken first, held for the whole run). --------
    lock_fd = os.open(str(LOCK_FILE), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("Another upload run is already in progress, exiting.")
        return 0

    state = load_state()

    if args.status:
        print(json.dumps({
            "now_local": now_local().isoformat(),
            "last_upload_iso": state.get("last_upload_iso"),
            "uploaded_today": uploaded_today(state),
            "cooldown_remaining_h": round(cooldown_remaining(state), 2),
            "uploaded_count": len(state.get("uploaded", [])),
            "publish_after_days": PUBLISH_AFTER_DAYS,
            "output_dir": str(OUTPUT_DIR),
        }, indent=2, ensure_ascii=False))
        return 0

    if args.authorize:
        get_service(run_oauth=True)
        print(f"Token stored at {TOKEN_FILE}")
        return 0

    # ---- Safety #1: persistent daily / cooldown state. --------------------
    if uploaded_today(state):
        print("Already uploaded today, exiting (hard daily cap).")
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

    service = get_service(run_oauth=False if TOKEN_FILE.exists() else True)
    video_id = upload(service, video, title)
    url = f"https://youtu.be/{video_id}"
    print(f"Uploaded (private): {url}")

    # Record success, date stamp (caps the day) + file identity (never twice).
    state["last_upload_iso"] = now_local().isoformat()
    state.setdefault("uploaded", []).append({
        "key": file_key(video),
        "name": video.name,
        "video_id": video_id,
        "url": url,
        "uploaded_iso": now_local().isoformat(),
    })
    save_state(state)
    print("State updated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
