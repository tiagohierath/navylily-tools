# make_videos.sh

Turns each audio file in `videos/audio/` into a YouTube-ready 4:3 **1080p**
video (never 4k), using a randomly shuffled slideshow of `videos/images/` with a
subtle 60fps zoom and a serif watermark. Output lands in
`videos/output/<audioname>.mp4`.

**Effort goes into the audio; video is tuned to be fast at the same quality.**

## What it does (in order)

1. Reads every audio file in `videos/audio/` (`wav mp3 m4a flac aac ogg`).
2. Builds a shuffled image sequence long enough to cover the audio, never
   repeating back-to-back. The **first 10 images flash by (random 1–3s)** to
   open with energy; **everything after is calmer (random 3–5s)**.
3. Renders each image as a lossless clip with a **very subtle** zoom — random
   in or out, 3–6% over the clip, perfectly smooth at 60fps (1.5× oversample,
   enough for the tiny zoom, no 4k blow-up).
4. Normalizes + lightly compresses the audio for YouTube (two-pass EBU R128,
   target ≈ −14 LUFS) — this is where the quality effort goes.
5. Burns a watermark ("Aulas completas em navylily.tv", Cormorant serif) onto
   the first 30s only.
6. Single H.264 encode at `crf 17` (full quality), `preset fast` (much quicker
   than `veryslow`), `+faststart`.
7. **Skips** any audio whose `.mp4` already exists, and writes atomically — an
   interrupted run never leaves a half file that looks finished.

## Commands

```bash
./make_videos.sh                                   # render everything pending
./make_videos.sh bitcoin                           # render ONLY files matching "bitcoin" (test one)
nix shell nixpkgs#ffmpeg --command ./make_videos.sh   # pin ffmpeg explicitly
VIDEO_BASE_DIR=/other/tree ./make_videos.sh        # use a different videos/ dir
FONTFILE=/path/to/Font.ttf ./make_videos.sh        # use a different watermark font

# re-render one file: delete its output first (the skip-check keys on the .mp4)
rm videos/output/bitcoin.mp4 && ./make_videos.sh bitcoin
```

The optional first argument is a **name fragment**: only audio files whose
filename contains it are rendered (`./make_videos.sh aprenda` would do both
`aprenda_*` files). No argument = render everything pending. Unmatched =
it lists what's available and exits.

There is an identical copy at `~/projects/video` (run `./video`); the canonical
one is `make_videos.sh` in this repo.

## Knobs you can edit (top of `make_videos.sh`)

| Line | Variable | Default | What it changes |
|------|----------|---------|-----------------|
| `WIDTH` / `HEIGHT` | `1440` / `1080` | output resolution (1080p, 4:3). For 16:9 use `1920`/`1080`. |
| `FPS` | `60` | frame rate of the zoom motion. |
| `SUPERSAMPLE` | `1.5` | zoom oversample. Higher = sharper zoom but slower; `1.5` is plenty for a ≤6% zoom. Raising it is what would push processing toward 4k. |
| `FAST_COUNT` | `10` | how many opening images use the quick pace. |
| `FAST_MIN_SECONDS` / `FAST_MAX_SECONDS` | `1` / `3` | duration range for the first `FAST_COUNT` images. |
| `REST_MIN_SECONDS` / `REST_MAX_SECONDS` | `3` / `5` | duration range for every image after that. |
| `ZOOM_MIN_AMOUNT` / `ZOOM_MAX_AMOUNT` | `0.03` / `0.06` | zoom travel (3–6%). Lower = even subtler. |
| `LOUDNORM_I` | `-14` | target loudness (LUFS). YouTube's reference. |
| `LOUDNORM_TP` | `-1.5` | true-peak ceiling (dBTP). |
| `LOUDNORM_LRA` | `11` | allowed loudness range. |
| `WATERMARK_TEXT` | `Aulas completas em navylily.tv` | the burned-in text. |
| `WATERMARK_SECONDS` | `30` | how long the watermark shows. |
| `FONTFILE` | bundled Cormorant | watermark font (also settable via env). |

Deeper edits, by section:

- **Speed vs. quality** — the last `ffmpeg` call (`-crf 17 -preset fast`). `crf`
  controls quality (lower = better/bigger); `preset` only trades encode speed
  for file size at the *same* quality. It's `fast` for quick renders; use
  `medium`/`slow` for smaller files, `veryfast` for max speed.
- **Audio compression** — the `acompressor=threshold=-18dB:ratio=3:...` filter
  inside `normalize_audio()`. Soften the ratio for less squashing.
- **Watermark style** — the `drawtext=...` filter (`fontsize=44`,
  `boxcolor=white@0.5`, position `x=36:y=h-th-36`).
- **Zoom math** — `make_image_clip()` builds the `zexpr` (linear in/out). The
  `RANDOM % 2` picks the direction per image.

## Inputs / outputs

```
videos/audio/   *.wav *.mp3 *.m4a *.flac *.aac *.ogg   (you add)
videos/images/  *.jpg *.jpeg *.png                     (you add)
videos/output/  <audioname>.mp4                        (generated)
videos/fonts/   Cormorant.ttf                          (bundled)
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `No audio files found` / `No image files found` | put files in `videos/audio/` and `videos/images/`. |
| Nothing renders, all "Skipping" | outputs already exist — `rm` the ones you want to rebuild. |
| `WARNING: no font found` | drop a `.ttf` in `videos/fonts/` or set `FONTFILE=`. |
| ffmpeg missing and no nix | run inside `nix shell nixpkgs#ffmpeg --command ./make_videos.sh`. |
| Renders feel slow | most time is the per-image encode × frame count. Lower `FPS`, lower `SUPERSAMPLE`, or set the final `-preset` to `veryfast`. Audio's two passes are deliberate. |
