# navylily-tools docs

Simple guides for each script in this repo. These tools sit beside Pictogrep
and milklily in the short-film workflow: Pictogrep helps gather/redraw
images, milklily owns the text EDL and render, and navylily-tools handles
recording/upload support.

- [record-lessons.md](record-lessons.md): record narration videos from the terminal (wiki articles or any topic)
- [make-videos.md](make-videos.md): turn audio + images into YouTube-ready videos
- [audio-clean.md](audio-clean.md): clean raw mic audio by itself
- [youtube-upload.md](youtube-upload.md): upload queued videos to YouTube, private
- [scheduling.md](scheduling.md): selectable daily, weekly, or monthly posting

## The whole pipeline in one line

Run `record`; it captures and cleans the voice, renders the video, and uploads
that exact result privately. YouTube makes it public at the configured time the
next day, and the verification timer checks the publication afterward.

## Quick start

```bash
cd ~/projects/navylily-tools

# one-time command setup
./record_lessons.sh --install

# one-time YouTube setup (opens a browser)
mkdir -p ~/.local/state/navylily-youtube
cp ~/Downloads/client_secret_*.json ~/.local/state/navylily-youtube/client_secret.json
./youtube_upload.sh --authorize
./install_timer.sh

# then just record
record                            # record, render, and post, from anywhere
record new "X"                    # or record a video about anything
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

For a milklily film project, use its clearer project folders instead:

```
scripts/                  writing and shot notes
storyboards/              rough boards
images/                   stills and visual assets
refs/                     references
audio/dialogue/           narration and dialogue
audio/music/              music beds
fxs/                      overlays and texture plates
sequences/                plain-text cuts
exports/video/            rendered movies
exports/storyboard-books/ printable storyboard PDFs
```

## NixOS note

Nothing gets installed system-wide. If a script needs ffmpeg or Python libs, it runs them in a temporary `nix shell` by itself.
