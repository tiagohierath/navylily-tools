#!/usr/bin/env python3
"""
twitter_upload.py

Posts exactly ONE image per run to X/Twitter, picked from the local image
pools (thumb_from_youtube/ and video_images/), same idea as youtube_upload.py:
one post a day, with hard guards so it's physically incapable of over-posting.

Guards (any one alone stops a bad run):
  1. Persistent daily state, a JSON state file records the date of the last
     post and which files have already been posted. If today already has a
     post (or the cooldown hasn't elapsed), the run exits at once.
  2. Hard single-item rule, each run posts exactly ONE image.
  3. Run lock, an exclusive flock so overlapping cron/timer fires can't
     double-post.

A file is never posted twice (tracked by content hash + name in state).

Credentials (NOT in the repo), X/Twitter's v2 tweet-create endpoint needs a
user-context OAuth1 app (Free tier does not support OAuth2-only posting).
Create a Project + App at developer.x.com with Read+Write permissions, then
set these via env or a .env-style file at $TW_STATE_DIR/credentials.json:
  TW_API_KEY, TW_API_SECRET, TW_ACCESS_TOKEN, TW_ACCESS_SECRET

Usage:
  ./twitter_upload.py                # live: post one image if allowed
  ./twitter_upload.py --dry-run      # exercise all guards, no API call
  ./twitter_upload.py --status       # print state and exit

Scheduling (once a day) is handled outside this script (cron/systemd timer);
the guards above hold even if triggered more often.
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
HERE = Path(__file__).resolve().parent

DEFAULT_STATE_DIR = HOME / ".local" / "state" / "navylily-twitter"
STATE_DIR = Path(os.environ.get("TW_STATE_DIR", str(DEFAULT_STATE_DIR)))
STATE_FILE = STATE_DIR / "state.json"
LOCK_FILE = STATE_DIR / "upload.lock"
CREDENTIALS_FILE = Path(os.environ.get(
    "TW_CREDENTIALS_FILE", str(STATE_DIR / "credentials.json")))

# Where images are picked from, both pools are treated equally.
IMAGE_DIRS = [
    Path(os.environ.get("TW_THUMBS_DIR", str(HERE / "thumb_from_youtube"))),
    Path(os.environ.get("TW_IMAGES_DIR", str(HERE / "video_images"))),
]
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp"}

UPLOAD_TZ = os.environ.get("TW_TZ", "America/Sao_Paulo")

# Same fence-post reasoning as youtube_upload.py: keep this below 24h so a
# same-time-daily timer can never slip a day.
MIN_HOURS_BETWEEN = float(os.environ.get("TW_MIN_HOURS_BETWEEN", "12"))

# Tweet text pool, one is picked at random per post. Edit freely.
CAPTIONS = [
    "Curso gratuito de desenho: https://navylily.tv/",
    "https://navylily.tv/ 🎨",
    "Aula nova em breve. https://navylily.tv/",
    "Desenho e pintura, de graça: https://navylily.tv/",
]


# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------
def now_local() -> dt.datetime:
    try:
        from zoneinfo import ZoneInfo
        return dt.datetime.now(ZoneInfo(UPLOAD_TZ))
    except Exception:
        return dt.datetime.now().astimezone()


def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    return {"last_post_iso": None, "posted": []}


def save_state(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2, ensure_ascii=False))
    tmp.replace(STATE_FILE)  # atomic


def file_key(path: Path) -> str:
    """Stable identity for an image: size + a hash of its bytes + name."""
    h = hashlib.sha256()
    h.update(path.name.encode())
    try:
        h.update(str(path.stat().st_size).encode())
        h.update(path.read_bytes())
    except OSError:
        pass
    return h.hexdigest()


def already_posted_keys(state: dict) -> set[str]:
    return {e["key"] for e in state.get("posted", []) if "key" in e}


def cooldown_remaining(state: dict) -> float:
    last = state.get("last_post_iso")
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


def posted_today(state: dict) -> bool:
    last = state.get("last_post_iso")
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
# Selection, exactly one not-yet-posted image, oldest first.
# ---------------------------------------------------------------------------
def pick_image(state: dict) -> Path | None:
    done = already_posted_keys(state)
    candidates = [
        p for d in IMAGE_DIRS if d.is_dir()
        for p in sorted(d.glob("*"))
        if p.is_file() and p.suffix.lower() in IMAGE_EXTS
    ]
    for p in sorted(candidates, key=lambda p: p.stat().st_mtime):
        if file_key(p) not in done:
            return p
    return None


# ---------------------------------------------------------------------------
# X/Twitter API (imported lazily so --dry-run/--status work without tweepy).
# ---------------------------------------------------------------------------
def load_credentials() -> dict:
    creds = {
        "api_key": os.environ.get("TW_API_KEY"),
        "api_secret": os.environ.get("TW_API_SECRET"),
        "access_token": os.environ.get("TW_ACCESS_TOKEN"),
        "access_secret": os.environ.get("TW_ACCESS_SECRET"),
    }
    if all(creds.values()):
        return creds
    if CREDENTIALS_FILE.exists():
        try:
            file_creds = json.loads(CREDENTIALS_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            file_creds = {}
        for k in creds:
            creds[k] = creds[k] or file_creds.get(k)
    missing = [k for k, v in creds.items() if not v]
    if missing:
        sys.exit(
            f"Missing X/Twitter credentials: {', '.join(missing)}. Set them "
            f"as env vars (TW_API_KEY, TW_API_SECRET, TW_ACCESS_TOKEN, "
            f"TW_ACCESS_SECRET) or in {CREDENTIALS_FILE} as JSON."
        )
    return creds


def post_image(path: Path, text: str) -> str:
    import tweepy

    creds = load_credentials()

    # Media upload is still v1.1-only, tweet creation goes through v2.
    auth = tweepy.OAuth1UserHandler(
        creds["api_key"], creds["api_secret"],
        creds["access_token"], creds["access_secret"],
    )
    api_v1 = tweepy.API(auth)
    media = api_v1.media_upload(filename=str(path))

    client = tweepy.Client(
        consumer_key=creds["api_key"], consumer_secret=creds["api_secret"],
        access_token=creds["access_token"], access_token_secret=creds["access_secret"],
    )
    resp = client.create_tweet(text=text, media_ids=[media.media_id])
    return str(resp.data["id"])


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description="Post one image/day to X/Twitter.")
    ap.add_argument("--dry-run", action="store_true",
                    help="run all guards and selection, but do not post")
    ap.add_argument("--status", action="store_true",
                    help="print current state and exit")
    args = ap.parse_args()

    STATE_DIR.mkdir(parents=True, exist_ok=True)

    # ---- Safety #3: run lock (taken first, held for the whole run). -------
    lock_fd = os.open(str(LOCK_FILE), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("Another post run is already in progress, exiting.")
        return 0

    state = load_state()

    if args.status:
        print(json.dumps({
            "now_local": now_local().isoformat(),
            "last_post_iso": state.get("last_post_iso"),
            "posted_today": posted_today(state),
            "min_hours_between": MIN_HOURS_BETWEEN,
            "cooldown_remaining_h": round(cooldown_remaining(state), 2),
            "posted_count": len(state.get("posted", [])),
            "image_dirs": [str(d) for d in IMAGE_DIRS],
        }, indent=2, ensure_ascii=False))
        return 0

    # ---- Safety #1: persistent daily / cooldown state. ---------------------
    if posted_today(state):
        print("Already posted today, exiting (hard daily cap).")
        return 0
    remaining = cooldown_remaining(state)
    if remaining > 0:
        print(f"Cooldown active: {remaining:.1f}h left before next post, "
              "exiting.")
        return 0

    # ---- Safety #2: select exactly one image. ------------------------------
    image = pick_image(state)
    if image is None:
        print("No new (not-yet-posted) images found, nothing to do.")
        return 0

    text = random.choice(CAPTIONS)
    print(f"Selected: {image}")
    print(f"Caption: {text}")

    if args.dry_run:
        print("Dry run, not posting.")
        return 0

    tweet_id = post_image(image, text)
    print(f"Posted: https://x.com/tiagohierath/status/{tweet_id}")

    state.setdefault("posted", []).append({
        "key": file_key(image),
        "name": image.name,
        "tweet_id": tweet_id,
        "posted_iso": now_local().isoformat(),
    })
    state["last_post_iso"] = now_local().isoformat()
    save_state(state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
