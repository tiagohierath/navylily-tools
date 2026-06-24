# navylily-tools

Two small tools for the [navylily.tv](https://navylily.tv) workflow:

1. **`make_videos.sh`** — turn audio + a folder of images into high-quality,
   YouTube-ready 4:3 1080p videos with a subtle, smooth 60fps zoom and a
   condensed-serif watermark.
2. **`youtube_upload.py`** (+ `youtube_upload.sh`) — upload **one** video per
   day to YouTube as a **private** video, built so it is *physically incapable*
   of over-posting.

Designed for a declarative/ephemeral NixOS machine: nothing is installed
system-wide. The scripts fetch their dependencies (`ffmpeg`, Python + Google
client libs) into an ephemeral `nix shell` on demand.

> A leaked `LD_LIBRARY_PATH` can break nix-provided binaries with
> `GLIBC_ABI_DT_X86_64_PLT` errors. Both scripts strip it before invoking nix.

---

## 1. make_videos.sh

```
videos/
  audio/    input audio (wav, mp3, m4a, flac, ...)
  images/   input images (jpg, jpeg, png)
  output/   generated .mp4 land here
  fonts/    Cormorant.ttf (condensed serif watermark)
```

Run:

```bash
./make_videos.sh
```

It re-execs itself inside `nix shell nixpkgs#ffmpeg` if `ffmpeg` isn't on PATH.
Point it at a different tree with `VIDEO_BASE_DIR=/path/to/videos ./make_videos.sh`.

What it does:

- 1440×1080 (4:3), **60fps**, `yuv420p`, H.264 high profile, `+faststart`.
- Each image gets a **very subtle** zoom, randomly in or out, perfectly smooth
  (lossless intermediate clips, single quality-first final pass — `crf 17`,
  `preset veryslow`).
- Audio is **normalized + lightly compressed for YouTube** (two-pass EBU R128,
  target ≈ −14 LUFS).
- Watermark "Aulas completas em navylily.tv" in **Cormorant** (condensed serif)
  for the first 30s.
- **Never renders the same output twice** — skips if the `.mp4` exists, and
  writes atomically so an interrupted run can't leave a half file.

The font is bundled (`videos/fonts/Cormorant.ttf`, OFL — see
`videos/fonts/Cormorant-OFL.txt`).

## 2. youtube_upload

Posts **one** video per run from `videos/output/`, **private**, with a random
working title (set the real title + thumbnail and publish manually later).

Three independent guards make over-posting impossible:

1. **Daily state** — a JSON file records the last upload; if today already had
   one (or the cooldown hasn't elapsed) the run exits immediately.
2. **Single-item** — exactly one video per run, no folder loop in live mode.
3. **Run lock** — an exclusive `flock`; overlapping runs exit at once.

And every successful upload is recorded by content hash, so a file is **never
uploaded twice**.

> `YT_MIN_HOURS_BETWEEN` defaults to `24` (at most one per day). Set it to `168`
> to enforce "at most once per week".

### Setup (no secrets in this repo)

1. In Google Cloud Console: enable **YouTube Data API v3**, create an OAuth
   **Desktop** client, download it.
2. Put it where the script looks (default `~/.local/state/navylily-youtube/`):
   ```bash
   mkdir -p ~/.local/state/navylily-youtube
   cp ~/Downloads/client_secret_*.json ~/.local/state/navylily-youtube/client_secret.json
   ```
3. Authorize once (opens a browser):
   ```bash
   ./youtube_upload.sh --authorize
   ```

### Run

```bash
./youtube_upload.sh --dry-run   # exercise guards + selection, no upload
./youtube_upload.sh --status    # show state
./youtube_upload.sh             # live: at most one upload
```

Env overrides: `YT_OUTPUT_DIR`, `YT_STATE_DIR`, `YT_CLIENT_SECRET`, `YT_TOKEN`,
`YT_TZ` (default `America/Sao_Paulo`), `YT_MIN_HOURS_BETWEEN`.

### Schedule — 18:00 São Paulo, daily

```bash
./install_timer.sh              # user systemd timer @ 18:00 America/Sao_Paulo
loginctl enable-linger "$USER"  # so it runs while logged out
```

The script's guards hold regardless of the scheduler, so the timer only has to
be roughly right. To remove: `./install_timer.sh --remove`.

Prefer fully-declarative NixOS? Fold the equivalent into your config:

```nix
systemd.user.services.navylily-youtube = {
  description = "Navylily — upload one video to YouTube (private)";
  serviceConfig.ExecStart = "/path/to/navylily-tools/youtube_upload.sh";
};
systemd.user.timers.navylily-youtube = {
  wantedBy = [ "timers.target" ];
  timerConfig = { OnCalendar = "*-*-* 18:00:00 America/Sao_Paulo"; Persistent = true; };
};
```

## License

Code: MIT. Bundled font Cormorant: SIL Open Font License (see
`videos/fonts/Cormorant-OFL.txt`).
