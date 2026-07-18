# navylily-tools

Just stuff, disposable uhh scripts i use for my youtube channel, to record, edit, post videos, etc, mostly bash scripts or python

Small tools for the [navylily.tv](https://navylily.tv) workflow:

1. **`audio-clean.sh`**, clean a raw mic recording (RNNoise denoise + EQ +
   compression + loudness) into a consistent, broadcast-ish voice file. Tuned
   for a FIFINE USB mic.
2. **`make_videos.sh`**, turn audio + a folder of images into high-quality,
   YouTube-ready 4:3 1080p videos with a subtle, smooth 60fps zoom and a
   condensed-serif watermark.
3. **`record_lessons.sh`**, narrate each navylily.tv wiki article into one
   video from the terminal (light voice cleanup + `make_videos.sh`), auto-
   detecting which articles you've already done. Feeds `youtube_upload.py`.

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
  (lossless intermediate clips, single quality-first final pass, `crf 17`,
  `preset veryslow`).
- Audio gets **only a single `afftdn` denoise** pass to remove steady mic hiss /
  white noise, no EQ, compression, or loudness normalization, and is otherwise
  at its original level. Tune with `VOICE_DENOISE` (or set it empty to disable).
- Drop tracks in `videos/music/` for an optional **very subtle background bed**:
  tracks are cycled across renders (each video starts on the next one) and
  looped to fill the timeline, then ducked ≈24 dB under the narration. Tune with
  `MUSIC_GAIN_DB` (toward 0 = louder), or `MUSIC=0` to disable.
- Watermark "Aulas completas em navylily.tv" in **Cormorant** (condensed serif)
  for the first 30s.
- **Never renders the same output twice**, skips if the `.mp4` exists, and
  writes atomically so an interrupted run can't leave a half file.

The font is bundled (`videos/fonts/Cormorant.ttf`, OFL, see
`videos/fonts/Cormorant-OFL.txt`).

## 3. record_lessons.sh

Record one video per wiki article, from the terminal:

```bash
./record_lessons.sh            # next un-recorded article
./record_lessons.sh --list     # roster with [x]/[_] recorded marks
./record_lessons.sh "maos"     # jump to / re-record one by title
```

Per lesson it opens the article in your browser to read aloud, records your mic
(FIFINE via the pulse **default** source; press `q` to stop), then:

- **Rejects** takes under `MIN_MINUTES` (6) or near-silent (muted/wrong mic).
- **Light** voice cleanup only: `highpass=80, lowpass=14000, loudnorm`, no
  denoise/EQ/compression, so the mic isn't over-processed. `CLEAN=full` uses the
  heavier `audio-clean.sh`; `CLEAN=raw` does nothing.
- Renders with `make_videos.sh` (its own denoise disabled to avoid double
  processing) into `videos/output/`.

The daily `youtube_upload.py` timer then posts one/day **private**, titled with
the real article title, scheduled to go **public** after `YT_PUBLISH_AFTER_DAYS`
(default 7), a window to set the title + thumbnail. Recorded state is detected
from disk (a `videos/audio/*.wav` or `videos/output/*.mp4`), so there's nothing
to track by hand.

## License

Code: MIT. Bundled font Cormorant: SIL Open Font License (see
`videos/fonts/Cormorant-OFL.txt`).
