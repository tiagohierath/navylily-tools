# navylily-tools — DOCS

Practical reference for the two scripts in this repo. Each page lists **what it
does**, **commands you can run**, and **the exact knobs you can edit in the
source**.

| Tool | File | Doc |
|------|------|-----|
| Clean raw mic audio into broadcast-ish voice | `audio-clean.sh` | [audio-clean.md](audio-clean.md) |
| Make YouTube-ready videos from audio + images | `make_videos.sh` | [make-videos.md](make-videos.md) |

## 30-second quick start

```bash
cd ~/projects/navylily-tools

# 1. drop inputs in — RAW mic audio is fine, make_videos cleans it for you
cp ~/audio/*.wav  videos/audio/      # raw FIFINE recordings
cp ~/photos/*.jpg videos/images/

# 2. render every audio file into videos/output/*.mp4
#    (auto: RNNoise denoise + EQ + compression + loudness, then video)
./make_videos.sh

#    (standalone audio cleanup, e.g. for a podcast cut, is also available:)
#    ./audio-clean.sh raw.wav clean.wav
```

## NixOS note

Nothing is installed system-wide. The scripts pull `ffmpeg` into an ephemeral
`nix shell` on demand and strip a leaked `LD_LIBRARY_PATH` first (it otherwise
breaks nix binaries with `GLIBC_ABI_DT_X86_64_PLT` errors). So
`./make_videos.sh` "just works" with no setup.

## Where things live

```
navylily-tools/
  audio-clean.sh          mic audio cleanup (RNNoise + EQ + loudness)
  models/sh.rnnn          bundled RNNoise model (public domain)
  wireplumber/            optional FIFINE capture drop-in (not auto-installed)
  make_videos.sh          video maker
  videos/
    audio/   input audio   (you add these — gitignored)
    images/  input images  (you add these — gitignored)
    output/  finished .mp4  (generated — gitignored)
    fonts/   Cormorant.ttf  (watermark font, committed)
  DOCS/      this folder
```
