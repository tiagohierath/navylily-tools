# Navy Lily recorder

Record narration videos entirely from the terminal. It records your mic, cleans
the voice, renders the video (images + navylily.tv watermark) in the background,
uploads it privately to YouTube, and schedules it to become public the next day.

Every recording is yours: give it a title on the command line, or run the
command by itself and enter the title when asked.

## Install the command once

From the `navylily-tools` checkout:

```bash
./record_lessons.sh --install
```

This adds a `record` command in `~/.local/bin`. It is a symbolic link,
so edits and `git pull` updates to this checkout take effect immediately. If the
installer says `~/.local/bin` is not on `PATH`, add the line it prints to your
shell setup and open a new terminal.

After that, the command works from any directory; recordings still go to this
checkout's `videos/` tree by default.

## Commands

```bash
record                # record a free video; asks for the title
record "Title"        # record a video with this title
record new "Title"    # older spelling; still works
record --help         # all commands and common settings
record youtube reauth # fresh Google login + YouTube channel verification
record youtube verify # verify due videos became public
```

The old `./record_lessons.sh --new` form remains compatible. To
remove only the global command, run `record --uninstall`; the checkout
and recordings are not removed.

## How a recording goes

1. Press ENTER to start. Press ENTER again and confirm to stop.
2. Bad takes are caught automatically: shorter than `MIN_MINUTES` (off by default), or near-silent (muted mic), and it offers a re-record.
3. Then you choose: Keep (just press ENTER), Listen to it first, or Re-record.
4. The voice gets a light cleanup and the video renders in the background (log: `videos/render.log`). You can already record the next one.
5. As soon as rendering finishes, that exact video uploads privately under your
   title. YouTube makes it public at the configured time the next day.

## Title and file notes

- The file name comes from the title: "Como cuidar das mãos" becomes `como_cuidar_das_maos.mp4`.
- If that name already exists it asks before overwriting.
- After each video it asks for the next title, so you can record several in a row.
- Short video? `MIN_MINUTES=1 record new "Aviso rápido"`

## Options (env vars)

```bash
MIC=default        # which pulse mic to record
MIN_MINUTES=6      # discard takes shorter than this
CLEAN=light        # light (default) / full (heavy audio-clean.sh) / raw (nothing)
VIDEO_BASE_DIR=... # put audio, recordings, output, and logs somewhere else
AUTO_UPLOAD=0      # render and queue only; default 1 posts after rendering
```

## Good to know

- Posting after a render does not depend on the timer. The timer remains useful
  as a fallback for anything already waiting in the queue.
- Re-recording a title replaces its old video automatically.
- A take you kept will finish rendering even if you close the terminal.
- Ctrl-C during Listen only stops the playback, not the script.
