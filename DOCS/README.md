# navylily-tools docs

Simple guides for each script in this repo.

- [record-lessons.md](record-lessons.md): record narration videos from the terminal (wiki articles or any topic)
- [make-videos.md](make-videos.md): turn audio + images into YouTube-ready videos
- [audio-clean.md](audio-clean.md): clean raw mic audio by itself
- [youtube-upload.md](youtube-upload.md): upload one video per day to YouTube, private
- [scheduling.md](scheduling.md): the daily 18:00 timer that runs the uploader

## The whole pipeline in one line

Record with `record_lessons.sh`, it cleans the voice and renders the video by itself, and the daily timer posts it private on YouTube. Seven days later YouTube makes it public. You only talk.

## Quick start

```bash
cd ~/projects/navylily-tools

# one-time YouTube setup (opens a browser)
mkdir -p ~/.local/state/navylily-youtube
cp ~/Downloads/client_secret_*.json ~/.local/state/navylily-youtube/client_secret.json
./youtube_upload.sh --authorize
./install_timer.sh

# then just record
./record_lessons.sh              # narrate the next wiki article
./record_lessons.sh --new "X"    # or record a video about anything
```

## Where things live

```
videos/audio/    voice recordings (input)
videos/images/   slideshow images (input)
videos/music/    background music, optional
videos/output/   finished .mp4 files
DOCS/            this folder
~/.local/state/navylily-youtube/   YouTube secrets + upload state (never in the repo)
```

## NixOS note

Nothing gets installed system-wide. If a script needs ffmpeg or Python libs, it runs them in a temporary `nix shell` by itself.
