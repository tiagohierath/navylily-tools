# make_videos.sh

Turns every audio file in `videos/audio/` into a YouTube-ready video in `videos/output/`. The picture is a shuffled slideshow of `videos/images/` (4:3, 1080p, subtle slow zoom) with a "navylily.tv" watermark over the first 30 seconds. Background music from `videos/music/` is mixed very quietly underneath, if there is any.

The audio gets the full voice cleanup (same as `audio-clean.sh`) plus YouTube loudness normalization, so raw mic recordings are fine as input.

## Commands

```bash
./make_videos.sh            # render everything that doesn't have an mp4 yet
./make_videos.sh bitcoin    # render only files whose name contains "bitcoin"

# re-render one: delete its output first, existing mp4s are skipped
rm videos/output/bitcoin.mp4 && ./make_videos.sh bitcoin
```

An interrupted run never leaves a broken half-file, and finished videos are never re-rendered.

## What goes where

```
videos/audio/    input: wav, mp3, m4a, flac, aac, ogg
videos/images/   input: jpg, jpeg, png
videos/music/    optional background music
videos/output/   result: one mp4 per audio file
```

## Main knobs (top of the script)

- Pace: the first 10 images flash by fast (1 to 3s each), the rest are calm (3 to 5s). Change `FAST_*` and `REST_*`.
- Zoom: 3 to 6% travel per image, random in or out. Change `ZOOM_MIN_AMOUNT` / `ZOOM_MAX_AMOUNT`.
- Watermark: `WATERMARK_TEXT` and `WATERMARK_SECONDS`. Font via `FONTFILE=` (bundled Cormorant by default).
- Music level: `MUSIC_GAIN_DB` (default -24, barely there). `MUSIC=0` turns it off.
- Loudness: `LOUDNORM_I` (default -14, YouTube's reference).
- Skip audio cleanup: `AUDIO_CLEAN=0` (faster, raw sound).

## Slow?

Drop `FPS` from 60 to 30, that roughly halves render time and the slow zoom looks the same. Lowering `SUPERSAMPLE` helps a bit more.

## Troubleshooting

- "No audio/image files found": put files in `videos/audio/` and `videos/images/`.
- Everything says "Skipping": the mp4s already exist, delete the ones you want rebuilt.
- No watermark font: drop a `.ttf` in `videos/fonts/` or set `FONTFILE=`.
- No ffmpeg: the script gets it from nix by itself; nothing to install.
