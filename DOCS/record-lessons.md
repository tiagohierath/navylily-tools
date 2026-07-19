# record_lessons.sh

Record narration videos entirely from the terminal. It records your mic, cleans the voice, renders the video (images + navylily.tv watermark) in the background, and leaves it for the daily timer to post on YouTube (private, public after 7 days). You never touch a DAW or an editor.

Two ways to use it:

1. **Wiki mode (just run it).** Goes through the Navy Lily wiki, one article per video. It picks the next article you haven't recorded, opens a clean reading page in the browser, and titles the video with the article's heading.
2. **Free mode (`--new`).** Any video about anything. You give the title, it starts recording, and everything after that is the same pipeline.

## Commands

```bash
./record_lessons.sh                # next un-recorded wiki article, loops
./record_lessons.sh "maos"         # jump to / re-record a specific article
./record_lessons.sh --list         # show all articles, [x] = recorded
./record_lessons.sh --new "Title"  # record a free video with this title
./record_lessons.sh --new          # same, but it asks for the title first
```

## How a recording goes

1. Press ENTER to start, press `q` to stop.
2. Bad takes are caught automatically: shorter than 6 minutes, or near-silent (muted mic), and it offers a re-record.
3. Then you choose: Keep (just press ENTER), Listen to it first, or Re-record.
4. The voice gets a light cleanup and the video renders in the background (log: `videos/render.log`). You can already record the next one.
5. The daily timer posts one video per day, private, under your exact title. YouTube flips it public 7 days after upload.

## Free mode notes

- The file name comes from the title: "Como cuidar das mãos" becomes `como_cuidar_das_maos.mp4`.
- If that name already exists it asks before overwriting.
- After each video it asks for the next title, so you can record several in a row.
- Short video? `MIN_MINUTES=1 ./record_lessons.sh --new "Aviso rápido"`

## Options (env vars)

```bash
MIC=default        # which pulse mic to record
MIN_MINUTES=6      # discard takes shorter than this
CLEAN=light        # light (default) / full (heavy audio-clean.sh) / raw (nothing)
NO_BROWSER=1       # don't open the article page (wiki mode)
```

## Good to know

- If the posting timer isn't set up, the script warns at startup. Videos still render and queue, they just don't post. Fix: `./youtube_upload.sh --authorize` once, then `./install_timer.sh`.
- Re-recording an article replaces its old video automatically.
- A take you kept will finish rendering even if you close the terminal.
- Ctrl-C during Listen only stops the playback, not the script.
