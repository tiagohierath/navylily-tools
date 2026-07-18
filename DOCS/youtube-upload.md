# youtube_upload.py (run via youtube_upload.sh)

Uploads **exactly one** video per run from `videos/output/` to YouTube as a
**private** video. Built to be physically incapable of over-posting.

Titles: if a sidecar `<video>.title.txt` sits next to the mp4 (written by
`record_lessons.sh`) the upload uses that exact wiki title; otherwise it falls
back to a random working title you replace later.

Publishing: every upload is scheduled with `publishAt` = now +
`YT_PUBLISH_AFTER_DAYS` days (default 7, `0` disables). The video stays private
for that window, you set title + thumbnail in YouTube Studio, then YouTube
flips it public automatically. The clock starts at UPLOAD time, not recording
time.

## The three guards (any one alone stops a bad run)

1. **Persistent daily state** — `state.json` records the last upload's
   timestamp. If today already uploaded (or the cooldown hasn't elapsed), the
   run exits immediately.
2. **Single-item rule** — each run picks exactly ONE video (oldest not-yet-
   uploaded) and uploads only that. No folder loop in live mode.
3. **Run lock** — an exclusive `flock` on `upload.lock`; a second overlapping
   run (cron retry, double-click) exits at once.

Plus: every successful upload is recorded by **content hash**, so the same file
is never uploaded twice even if you rename it or re-run forever.

## Commands

```bash
./youtube_upload.sh --authorize   # one-time OAuth, stores token.json (opens browser)
./youtube_upload.sh --status      # print state: last upload, cooldown, count
./youtube_upload.sh --dry-run     # run all guards + pick a video, but DON'T upload
./youtube_upload.sh               # live: upload one video if allowed
```

`--status` / `--dry-run` work without the Google libraries, so they're safe to
poke at any time.

## First-time setup (no secrets go in the repo)

1. Google Cloud Console → enable **YouTube Data API v3** → create an **OAuth
   client ID** of type **Desktop app** → download the JSON.
2. Put it where the script looks:
   ```bash
   mkdir -p ~/.local/state/navylily-youtube
   cp ~/Downloads/client_secret_*.json ~/.local/state/navylily-youtube/client_secret.json
   ```
3. Authorize once:
   ```bash
   ./youtube_upload.sh --authorize
   ```
   This writes `token.json` (chmod 600) next to the client secret. Refreshes
   automatically after that.

## Knobs you can edit

**Via environment (no code change):**

| Env var | Default | Effect |
|---------|---------|--------|
| `YT_OUTPUT_DIR` | `videos/output` | where to look for videos to upload. |
| `YT_STATE_DIR` | `~/.local/state/navylily-youtube` | holds state, lock, secrets, token. |
| `YT_CLIENT_SECRET` | `$YT_STATE_DIR/client_secret.json` | OAuth client path. |
| `YT_TOKEN` | `$YT_STATE_DIR/token.json` | stored token path. |
| `YT_TZ` | `America/Sao_Paulo` | timezone for "one per calendar day". |
| `YT_MIN_HOURS_BETWEEN` | `24` | min hours between uploads. **Set `168` for once-a-week.** |

Example — enforce weekly and use a different output folder for one run:

```bash
YT_MIN_HOURS_BETWEEN=168 YT_OUTPUT_DIR=~/renders ./youtube_upload.sh
```

**In the source (`youtube_upload.py`):**

- **Random title pool** — `TITLE_WORDS_A` / `TITLE_WORDS_B`. The title is
  `"<A> <B>"`, e.g. "Estudo de observação". Add/remove words freely.
- **Privacy / category / description** — the `body` dict inside `upload()`:
  `privacyStatus: "private"`, `categoryId: "27"` (Education), and the default
  description string. Change `"private"` to `"unlisted"`/`"public"` if you ever
  want that (you don't, per the manual-publish workflow).
- **Accepted extensions** — `VIDEO_EXTS`.
- **Which video gets picked** — `pick_video()` selects the oldest by mtime that
  isn't in the uploaded list. Change the `sorted(..., key=...)` to reorder.

## Reading / resetting state

```bash
cat ~/.local/state/navylily-youtube/state.json     # see last upload + history
./youtube_upload.sh --status                         # same info, summarized
```

`state.json` looks like:

```json
{
  "last_upload_iso": "2026-06-24T18:00:11-03:00",
  "uploaded": [
    { "key": "<hash>", "name": "bitcoin.mp4", "video_id": "abc", "url": "https://youtu.be/abc", "uploaded_iso": "..." }
  ]
}
```

- **Force "today is clear" for a test** — delete `last_upload_iso` (set it to
  `null`) or remove the file. The per-file hash history still prevents
  re-uploading the same video.
- **Let a specific video upload again** — remove its entry from `uploaded`.

## Troubleshooting

| Message | Meaning |
|---------|---------|
| `Already uploaded today — exiting` | guard #1 fired; wait or clear `last_upload_iso`. |
| `Cooldown active: Nh left` | `YT_MIN_HOURS_BETWEEN` not elapsed yet. |
| `No new (...) videos ... nothing to do` | every video in the folder is already uploaded, or the folder is empty. This is the "don't freak out when videos run out" path. |
| `Another upload run is already in progress` | guard #3; a `flock` is held. Normal if two runs overlap. |
| `Missing OAuth client secret at ...` | do the setup step — drop `client_secret.json` in the state dir. |
