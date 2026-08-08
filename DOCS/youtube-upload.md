# youtube_upload.sh

Uploads exactly one video per run from `videos/output/` to YouTube, always private. Its persistent cadence can be daily, weekly, or monthly. Record as many as you like; they queue in `videos/output/` oldest first.

Every upload is scheduled to go public automatically 1 day later (`YT_PUBLISH_AFTER_DAYS`, `0` disables). That window is your time to set the thumbnail in YouTube Studio.

Titles: if `record_lessons.sh` left a `<video>.title.txt` next to the mp4, that exact title is used. Otherwise it gets a random working title you rename later.

## The three guards

1. Cadence state: if today's or this month's cap already posted, the run exits.
2. One video per run: it picks the oldest not-yet-uploaded video, nothing else.
3. A lock file stops two runs from overlapping.

On top of that, every uploaded file is remembered by content hash, so the same video can never post twice, even renamed.

## Commands

```bash
./youtube_upload.sh --authorize   # one-time Google login (opens a browser)
./youtube_upload.sh --status      # last upload, cooldown, count
./youtube_upload.sh --cadence daily    # every day at 18:00 São Paulo
./youtube_upload.sh --cadence weekly   # Sundays at 18:00 São Paulo
./youtube_upload.sh --cadence monthly  # 1st of the month at 18:00 São Paulo
./youtube_upload.sh --dry-run     # show what it WOULD do, upload nothing
./youtube_upload.sh               # upload one video if allowed
```

## Queue a Movielily render

From a Movielily project, render normally and then queue the last render:

```bash
movielily export filme exports/video/filme.mp4
movielily youtube --title "Título do vídeo"
nl-queue
```

Movielily places an immutable handoff in this shared queue, including the
title sidecar. The selected cadence above applies normally. Use
`movielily youtube --now` only for an intentional immediate private upload.

## First-time setup

1. Google Cloud Console: enable YouTube Data API v3, create an OAuth client of type "Desktop app", download the JSON.
2. ```bash
   mkdir -p ~/.local/state/navylily-youtube
   cp ~/Downloads/client_secret_*.json ~/.local/state/navylily-youtube/client_secret.json
   ./youtube_upload.sh --authorize
   ```

Secrets and state live in `~/.local/state/navylily-youtube/`, never in the repo.

## Useful settings (env vars)

```bash
YT_PUBLISH_AFTER_DAYS=1    # days until a video goes public (0 = stays private)
YT_MIN_HOURS_BETWEEN=...   # override the daily cooldown, if needed
YT_OUTPUT_DIR=...          # look for videos somewhere else
```

The timer runs at 18:00 São Paulo time. Switch the persistent cadence with
`--cadence daily`, `--cadence weekly`, or `--cadence monthly`. Weekly mode
posts on Sundays; monthly mode posts on the first day. The hard same-day,
weekly, and monthly guards prevent double-posting.

## State and resets

`~/.local/state/navylily-youtube/state.json` holds the last upload time and the list of uploaded videos. To force a test upload today, set `last_upload_iso` to `null`. To let one specific video upload again, remove its entry from `uploaded`.

Before an upload request, the script records a pending entry. This prevents a
crash or lost network response from causing a duplicate post. If it reports a
pending upload, check YouTube Studio: use `--resolve-pending VIDEO_ID` if the
video exists, or `--discard-pending` only after confirming it does not.

## Common messages

- "Already uploaded today": normal, the same-day guard.
- "Already uploaded this month": normal, the monthly guard already fired.
- "A previous upload is pending reconciliation": check YouTube Studio before
  choosing `--resolve-pending` or `--discard-pending`; this avoids duplicates
  after an uncertain network failure.
- "Cooldown active": guard 1, hours not elapsed yet.
- "No new videos, nothing to do": the queue is empty, also normal.
- "Another upload run is already in progress": guard 3, two runs overlapped.
- "Missing OAuth client secret": do the first-time setup above.
