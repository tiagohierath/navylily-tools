# youtube_upload.sh

Uploads exactly one video per run from `videos/output/` to YouTube, always private. Built so it can never over-post: run it as often as you want, it still posts at most one video per day.

Every upload is scheduled to go public automatically 7 days later (`YT_PUBLISH_AFTER_DAYS`, `0` disables). That window is your time to set the thumbnail in YouTube Studio.

Titles: if `record_lessons.sh` left a `<video>.title.txt` next to the mp4, that exact title is used. Otherwise it gets a random working title you rename later.

## The three guards

1. Daily state: if today already posted, the run exits.
2. One video per run: it picks the oldest not-yet-uploaded video, nothing else.
3. A lock file stops two runs from overlapping.

On top of that, every uploaded file is remembered by content hash, so the same video can never post twice, even renamed.

## Commands

```bash
./youtube_upload.sh --authorize   # one-time Google login (opens a browser)
./youtube_upload.sh --status      # last upload, cooldown, count
./youtube_upload.sh --dry-run     # show what it WOULD do, upload nothing
./youtube_upload.sh               # upload one video if allowed
```

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
YT_PUBLISH_AFTER_DAYS=7    # days until a video goes public (0 = stays private)
YT_MIN_HOURS_BETWEEN=24    # 168 = once a week
YT_OUTPUT_DIR=...          # look for videos somewhere else
```

## State and resets

`~/.local/state/navylily-youtube/state.json` holds the last upload time and the list of uploaded videos. To force a test upload today, set `last_upload_iso` to `null`. To let one specific video upload again, remove its entry from `uploaded`.

## Common messages

- "Already uploaded today": normal, guard 1.
- "Cooldown active": guard 1, hours not elapsed yet.
- "No new videos, nothing to do": the queue is empty, also normal.
- "Another upload run is already in progress": guard 3, two runs overlapped.
- "Missing OAuth client secret": do the first-time setup above.
