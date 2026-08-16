# youtube_upload.sh

Uploads exactly one video per run from `videos/output/` to a pinned YouTube
channel. Queue order is persisted, so later filename/mtime changes cannot reorder it.

Every video uploads privately at 09:00 São Paulo and is scheduled to go public
at 18:00 the same day. That window is your time to set the thumbnail in YouTube
Studio. A run with less than two hours remaining safely waits until the next morning.

Titles are required from a `<video>.title.txt` sidecar. Missing titles block the
upload instead of publishing under an accidental random title.

## The three guards

1. Cadence state: if today's or this month's cap already posted, the run exits.
2. One video per run: it picks the first durable queued item, nothing else.
3. A lock file stops two runs from overlapping.

State writes and staged upload bytes are fsynced. OAuth is pinned to one channel,
and the 18:15 verifier blocks advancement and alerts if a due video is not public.
A video that no longer exists at all is the one exception: it can never become
public, so it is recorded as `missing` and skipped instead of blocking forever.

On top of that, every uploaded byte sequence is remembered by SHA-256, so an
identical video cannot post twice even if renamed. An uncertain API result
stops for reconciliation instead of retrying blindly.

## Commands

```bash
./youtube_upload.sh --authorize   # Google login + pin/verify channel
./youtube_upload.sh --status      # last upload, cooldown, count
./youtube_upload.sh --cadence daily    # every day
./youtube_upload.sh --cadence weekly   # Sundays
./youtube_upload.sh --cadence monthly  # 1st of the month
./youtube_upload.sh --dry-run     # show what it WOULD do, upload nothing
./youtube_upload.sh --verify-publications  # verify due videos; never upload
./youtube_upload.sh               # upload one video if allowed
```

## Queue a Milklily render

From a Milklily project, render normally and then queue the last render:

```bash
milklily export filme exports/video/filme.mp4
milklily youtube --title "Título do vídeo"
nl-queue
```

Milklily places an immutable handoff in this shared queue, including the
title sidecar. The selected cadence above applies normally. Use
`milklily youtube --now` only for an intentional immediate private upload.

## First-time setup

1. Google Cloud Console: enable YouTube Data API v3, create an OAuth client of type "Desktop app", download the JSON.
2. ```bash
   mkdir -p ~/.local/state/navylily-youtube
   cp ~/Downloads/client_secret_*.json ~/.local/state/navylily-youtube/client_secret.json
   ./youtube_upload.sh --authorize
   ```

Secrets and state live in `~/.local/state/navylily-youtube/`, never in the repo.
After this hardening upgrade, run `--authorize` once again: the uploader now
needs read-only access to verify and pin the exact destination channel.

## Useful settings (env vars)

```bash
YT_PUBLIC_HOUR=18          # local hour when the private upload becomes public
YT_MIN_SCHEDULE_LEAD_HOURS=2
YT_REQUIRE_TITLE_SIDECAR=true
YT_MADE_FOR_KIDS=false
YT_CONTAINS_SYNTHETIC_MEDIA=false
YT_MIN_HOURS_BETWEEN=...   # override the daily cooldown, if needed
YT_OUTPUT_DIR=...          # look for videos somewhere else
# Optional remote failure alert (Slack/Discord-compatible webhook):
YT_ALERT_WEBHOOK_URL=...
```

Put timer settings in `~/.config/navylily-youtube.env`, then rerun
`./install_timer.sh`. Failures are always written to `health.json` and the
systemd journal; `notify-send` and the optional webhook are best-effort alerts.

The private-upload timer runs at 09:00 São Paulo, publication is at 18:00, and
the verification timer checks it at 18:15.
Switch the persistent cadence with
`--cadence daily`, `--cadence weekly`, or `--cadence monthly`. Weekly mode
posts on Sundays; monthly mode posts on the first day. The hard same-day,
weekly, and monthly guards prevent double-posting.

## State and resets

`~/.local/state/navylily-youtube/state.json` holds upload history, the pinned
channel, and durable queue order. `state.json.bak` preserves the prior valid
generation. Do not hand-edit either file: malformed or inconsistent state
fails closed specifically to prevent duplicates.

Before an upload request, the script records a pending entry. This prevents a
crash or lost network response from causing a duplicate post. If it reports a
pending upload, check YouTube Studio: use `--resolve-pending VIDEO_ID` if the
video exists. `--discard-pending` scans recent channel uploads and requires an
interactive exact-filename confirmation; use it only after checking Studio.

## Common messages

- "Already uploaded today": normal, the same-day guard.
- "Already uploaded this month": normal, the monthly guard already fired.
- "A previous upload is pending reconciliation": check YouTube Studio before
  choosing `--resolve-pending` or `--discard-pending`; this avoids duplicates
  after an uncertain network failure.
- "MISSING from YouTube": the video no longer exists (deleted in Studio, or
  removed by YouTube). It can never become public, so it is recorded as
  `missing`, alerted once, and never checked again. Uploads continue normally.
  `--verify-publications` exits 5 on the run that discovers it.
- "Cooldown active": guard 1, hours not elapsed yet.
- "No new videos, nothing to do": the queue is empty, also normal.
- "Another upload run is already in progress": guard 3, two runs overlapped.
- "Missing OAuth client secret": do the first-time setup above.
