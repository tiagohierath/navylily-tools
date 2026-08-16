#!/usr/bin/env python3
"""
queue_view.py — read-only view of the YouTube posting queue.

Shows the videos waiting in videos/output/ (durable enqueue order, the exact order
youtube_upload.py posts them), and projects when each will upload (private)
and auto-flip PUBLIC, using the same selected cadence as the uploader: daily,
weekly on Sundays, or monthly on the first day. Upload is 18:00 and publication
is 18:00 the next day, America/Sao_Paulo.

It NEVER uploads, writes, or touches state. Just reads. Run it anytime:

    nl-queue

Config is read from the installed systemd service so this always matches
reality; falls back to the current live values (daily cadence, upload 18:00,
public 18:00 the next day) if the unit can't be read. Override with
YT_MIN_HOURS_BETWEEN / YT_PUBLIC_HOUR / YT_PUBLISH_DELAY_DAYS / YT_UPLOAD_HOUR /
YT_OUTPUT_DIR / YT_STATE_DIR just like the uploader.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
from pathlib import Path
from zoneinfo import ZoneInfo

from youtube_upload import file_key, legacy_file_key, validate_state

HOME = Path.home()
TZ = ZoneInfo(os.environ.get("YT_TZ", "America/Sao_Paulo"))
OUTPUT_DIR = Path(os.environ.get(
    "YT_OUTPUT_DIR",
    str(Path(__file__).resolve().parent / "videos" / "output")))
STATE_FILE = Path(os.environ.get(
    "YT_STATE_DIR", str(HOME / ".local" / "state" / "navylily-youtube"))) / "state.json"
VIDEO_EXTS = {".mp4", ".mov", ".mkv", ".webm", ".m4v"}


def service_env(key: str) -> str | None:
    """Read an Environment=KEY=... value from the installed user service."""
    try:
        out = subprocess.run(
            ["systemctl", "--user", "cat", "navylily-youtube.service"],
            capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return None
    m = re.search(rf"^Environment={re.escape(key)}=(.+)$", out, re.M)
    return m.group(1).strip() if m else None


def timer_upload_hour() -> float | None:
    """Read the installed timer's own OnCalendar hour, so the projection can
    never drift from the schedule that actually runs."""
    try:
        out = subprocess.run(
            ["systemctl", "--user", "cat", "navylily-youtube.timer"],
            capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return None
    m = re.search(r"^OnCalendar=.*?(\d{1,2}):(\d{2})(?::\d{2})?", out, re.M)
    if not m:
        return None
    hour = int(m.group(1))
    return float(hour) if 0 <= hour <= 23 else None


def cfg_float(env_key: str, live_default: float) -> float:
    for v in (os.environ.get(env_key), service_env(env_key)):
        if v:
            try:
                return float(v)
            except ValueError:
                pass
    return live_default


def main() -> int:
    now = dt.datetime.now(TZ)
    public_hour = int(cfg_float("YT_PUBLIC_HOUR", 18.0))
    if not 0 <= public_hour <= 23:
        raise ValueError("YT_PUBLIC_HOUR must be an integer from 0 through 23")
    from_timer = timer_upload_hour()
    upload_hour = int(cfg_float(
        "YT_UPLOAD_HOUR", 18.0 if from_timer is None else from_timer))
    if not 0 <= upload_hour <= 23:
        raise ValueError("YT_UPLOAD_HOUR must be an integer from 0 through 23")
    publish_delay_days = int(cfg_float("YT_PUBLISH_DELAY_DAYS", 1.0))
    if not 0 <= publish_delay_days <= 30:
        raise ValueError(
            "YT_PUBLISH_DELAY_DAYS must be an integer from 0 through 30")

    try:
        state = validate_state(json.loads(STATE_FILE.read_text()))
    except OSError:
        state = {"uploaded": [], "last_upload_iso": None}
    posting_cadence = state.get("cadence", os.environ.get("YT_CADENCE_DEFAULT", "daily"))
    if posting_cadence not in {"daily", "weekly", "monthly"}:
        posting_cadence = "daily"
    done = {e["key"] for e in state.get("uploaded", [])}

    vids = sorted(
        (p for p in OUTPUT_DIR.glob("*")
         if p.is_file() and p.suffix.lower() in VIDEO_EXTS),
        key=lambda p: (p.stat().st_mtime_ns, p.name))
    by_key: dict[str, Path] = {}
    for path in vids:
        by_key.setdefault(file_key(path), path)
    pending = []
    selected: set[str] = set()
    for entry in state.get("queue", []):
        path = by_key.get(entry["key"])
        if (path is not None and entry["key"] not in done
                and legacy_file_key(path) not in done):
            pending.append(path)
            selected.add(entry["key"])
    pending.extend(
        path for key, path in by_key.items()
        if key not in done and legacy_file_key(path) not in done
        and key not in selected)

    last_iso = state.get("last_upload_iso")
    last = dt.datetime.fromisoformat(last_iso) if last_iso else None

    print()
    print(f"  YouTube queue — {len(done)} posted, {len(pending)} waiting")
    print(f"  current cadence: {posting_cadence}")
    print(f"  schedule: {posting_cadence} upload at {upload_hour:02d}:00 (SP), "
          f"PUBLIC at {public_hour:02d}:00 +{publish_delay_days}d")
    if last:
        print(f"  last upload: {last.astimezone(TZ):%a %d %b %H:%M}")
    print()
    if not pending:
        print("  Queue empty — render a Milklily video, then run:")
        print("  milklily youtube --title \"Your video title\"\n")
        return 0

    # Project the same selected cadence as youtube_upload.py.
    def scheduled_fires(start: dt.datetime):
        d = start.date()
        while True:
            candidate = dt.datetime.combine(d, dt.time(upload_hour), tzinfo=TZ)
            eligible = (
                posting_cadence == "daily"
                or (posting_cadence == "weekly" and d.weekday() == 6)
                or (posting_cadence == "monthly" and d.day == 1)
            )
            if candidate > start and eligible:
                yield candidate
            d += dt.timedelta(days=1)

    fires = scheduled_fires(now)
    prev = last
    rows = []
    for p in pending:
        while True:
            fire = next(fires)
            if prev is None or fire.date() != prev.astimezone(TZ).date():
                break
        pub = (fire + dt.timedelta(days=publish_delay_days)).replace(
            hour=public_hour)
        sc = p.with_suffix(".title.txt")
        title = (sc.read_text(encoding="utf-8").strip()
                 if sc.exists() else "(MISSING TITLE — UPLOAD BLOCKED)")
        rows.append((fire, pub, title))
        prev = fire

    w = max(len(t) for _, _, t in rows)
    print(f"  {'#':<2} {'uploads':<11} {'PUBLIC':<11}  {'title':<{w}}")
    print(f"  {'-'*2} {'-'*11} {'-'*11}  {'-'*w}")
    for i, (fire, pub, title) in enumerate(rows, 1):
        print(f"  {i:<2} {fire.strftime('%a %d %b'):<11} "
              f"{pub.strftime('%a %d %b'):<11}  {title}")

    last_public = rows[-1][1]
    days = (last_public.date() - now.date()).days
    print()
    print(f"  Covered through {last_public:%a %d %b} "
          f"(~{days} days). Record more before then.\n")
    print("  The uploader will post the next item automatically. Use YouTube Studio")
    print("  after upload to set its thumbnail.\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
