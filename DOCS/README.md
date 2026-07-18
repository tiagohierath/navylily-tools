# navylily-tools — DOCS

Practical reference for the two scripts in this repo. Each page lists **what it
does**, **commands you can run**, and **the exact knobs you can edit in the
source**.

| Tool | File | Doc |
|------|------|-----|
| Clean raw mic audio into broadcast-ish voice | `audio-clean.sh` | [audio-clean.md](audio-clean.md) |
| Make YouTube-ready videos from audio + images | `make_videos.sh` | [make-videos.md](make-videos.md) |
| Upload one video/day to YouTube (private, safe) | `youtube_upload.py` / `youtube_upload.sh` | [youtube-upload.md](youtube-upload.md) |
| Run the uploader daily at 18:00 São Paulo | `install_timer.sh` | [scheduling.md](scheduling.md) |

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

# 3. one-time YouTube auth (opens a browser)
mkdir -p ~/.local/state/navylily-youtube
cp ~/Downloads/client_secret_*.json ~/.local/state/navylily-youtube/client_secret.json
./youtube_upload.sh --authorize

# 4. post one video, private, with a random working title
./youtube_upload.sh            # add --dry-run first to see what it'd pick

# 5. (optional) let it post one/day at 18:00 São Paulo automatically
./install_timer.sh
loginctl enable-linger "$USER"
```

## NixOS note

Nothing is installed system-wide. The scripts pull `ffmpeg` / Python + Google
libs into an ephemeral `nix shell` on demand and strip a leaked
`LD_LIBRARY_PATH` first (it otherwise breaks nix binaries with
`GLIBC_ABI_DT_X86_64_PLT` errors). So `./make_videos.sh` and
`./youtube_upload.sh` "just work" with no setup.

## Where things live

```
navylily-tools/
  audio-clean.sh          mic audio cleanup (RNNoise + EQ + loudness)
  models/sh.rnnn          bundled RNNoise model (public domain)
  wireplumber/            optional FIFINE capture drop-in (not auto-installed)
  make_videos.sh          video maker
  youtube_upload.py       uploader (the logic)
  youtube_upload.sh       nix wrapper for the uploader
  install_timer.sh        systemd --user timer installer
  videos/
    audio/   input audio   (you add these — gitignored)
    images/  input images  (you add these — gitignored)
    output/  finished .mp4  (generated — gitignored)
    fonts/   Cormorant.ttf  (watermark font, committed)
  DOCS/      this folder

~/.local/state/navylily-youtube/   (NOT in the repo — secrets + state)
  client_secret.json   OAuth client you download from Google
  token.json           created on first --authorize
  state.json           last upload date + uploaded-video hashes
  upload.lock          flock used to stop overlapping runs
```
