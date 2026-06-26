# navylily-tools

Small tools for the [navylily.tv](https://navylily.tv) workflow:

1. **`audio-clean.sh`** — clean a raw mic recording (RNNoise denoise + EQ +
   compression + loudness) into a consistent, broadcast-ish voice file. Tuned
   for a FIFINE USB mic.
2. **`make_videos.sh`** — turn audio + a folder of images into high-quality,
   YouTube-ready 4:3 1080p videos with a subtle, smooth 60fps zoom and a
   condensed-serif watermark.

Designed for a declarative/ephemeral NixOS machine: nothing is installed
system-wide. The scripts fetch their dependencies (`ffmpeg`) into an ephemeral
`nix shell` on demand.

> **Practical, command-first docs** (every knob you can edit, every command you
> can run) live in [`DOCS/`](DOCS/README.md).

> A leaked `LD_LIBRARY_PATH` can break nix-provided binaries with
> `GLIBC_ABI_DT_X86_64_PLT` errors. Both scripts strip it before invoking nix.

---

## 1. make_videos.sh

```
videos/
  audio/    input audio (wav, mp3, m4a, flac, ...)
  images/   input images (jpg, jpeg, png)
  music/    optional background music, cycled + mixed very subtly (optional)
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
- Audio is used **as-is — no processing** (no denoise/EQ, compression, or
  loudness normalization); each file is muxed at its original level.
- Drop tracks in `videos/music/` for an optional **very subtle background bed**:
  tracks are cycled across renders (each video starts on the next one) and
  looped to fill the timeline, then ducked ≈24 dB under the narration. Tune with
  `MUSIC_GAIN_DB` (toward 0 = louder), or `MUSIC=0` to disable.
- Watermark "Aulas completas em navylily.tv" in **Cormorant** (condensed serif)
  for the first 30s.
- **Never renders the same output twice** — skips if the `.mp4` exists, and
  writes atomically so an interrupted run can't leave a half file.

The font is bundled (`videos/fonts/Cormorant.ttf`, OFL — see
`videos/fonts/Cormorant-OFL.txt`).

## License

Code: MIT. Bundled font Cormorant: SIL Open Font License (see
`videos/fonts/Cormorant-OFL.txt`).
