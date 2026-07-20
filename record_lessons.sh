#!/usr/bin/env bash
#
# record_lessons.sh, narrate the Navy Lily wiki, one article per video, all
# from the terminal. No Audacity, no DAW: ffmpeg records, make_videos.sh
# renders (images + navylily.tv watermark), youtube_upload.py posts.
#
# What one run does, looping until you stop:
#   1. Picks the next NOT yet recorded wiki article. Recorded state is derived
#      from files on disk (see lessons.py), nothing to track by hand.
#   2. Opens the article in your browser so you can read while you speak.
#   3. Records the mic with ffmpeg (press q in ffmpeg to stop).
#   4. Guards the take: under MIN_MINUTES (default 6) or near-silent peaks are
#      treated as misfires and discarded, then you re-record or skip. A kept
#      take can be played back first ([L]isten).
#   5. Processes the voice (light by default: highpass, lowpass, loudnorm) and
#      renders the video in the background, serialized by a lock.
#   6. Writes the article title next to the mp4; youtube_upload.py posts it
#      under that exact wiki title, PRIVATE, one per day, and YouTube flips it
#      public automatically after YT_PUBLISH_AFTER_DAYS days (default 1).
#
# This script never uploads anything itself; the daily timer does the posting.
#
# Usage:
#   ./record_lessons.sh                # work through un-recorded lessons
#   ./record_lessons.sh "maos"         # jump to / re-record a specific article
#   ./record_lessons.sh --list         # show every lesson and its recorded mark
#   ./record_lessons.sh --new "Title"  # record a free video (any topic, not a
#                                      # wiki article); title given here or asked
#                                      # interactively. Same pipeline after that:
#                                      # clean -> render -> auto-post PRIVATE.
#
# Env overrides:
#   MIC=default          pulse source (default = system default mic, the FIFINE)
#   MIN_MINUTES=6        reject recordings shorter than this
#   CLEAN=light          light (default) / full (audio-clean.sh) / raw (none)
#   WIKI_DIR=...         where the article .md files live
#   NO_BROWSER=1         do not open the article in a browser
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MIC="${MIC:-default}"   # pulse default source (the FIFINE AM8 on this machine)
MIN_MINUTES="${MIN_MINUTES:-6}"
MIN_SECONDS="$(awk -v m="$MIN_MINUTES" 'BEGIN{printf "%.0f", m*60}')"

# Voice processing. Default is LIGHT: high-pass the desk rumble, gentle
# low-pass, loudness normalize. No denoise, no EQ, no compression, so the mic's
# own sound is kept and never over-processed. make_videos.sh runs with its
# denoise disabled (below), so this is the ONLY processing the voice gets.
#   CLEAN=full   the heavier audio-clean.sh (RNNoise + EQ + compressor)
#   CLEAN=raw    no processing at all, the capture is used as-is
#   CLEAN_AF=... override the light filter chain
CLEAN="${CLEAN:-light}"
CLEAN_AF="${CLEAN_AF:-highpass=f=80,lowpass=f=14000,loudnorm=I=-16:TP=-1.5:LRA=11}"

VIDEOS_DIR="$HERE/videos"
AUDIO_DIR="${AUDIO_DIR:-$VIDEOS_DIR/audio}"
OUTPUT_DIR="${OUTPUT_DIR:-$VIDEOS_DIR/output}"
RAW_DIR="$VIDEOS_DIR/recordings"
RENDER_LOG="$VIDEOS_DIR/render.log"
RENDER_LOCK="$VIDEOS_DIR/.render.lock"
export AUDIO_DIR OUTPUT_DIR   # lessons.py reads these

mkdir -p "$AUDIO_DIR" "$OUTPUT_DIR" "$RAW_DIR"

# Lessons skipped in THIS session (declined re-record, or "skip this one" at the
# record prompt). Without this the picker would offer the same lesson again.
SKIP_SLUGS=""
export SKIP_SLUGS

# Persistent skip list: lessons you chose to skip for good (you won't record all
# ~113). One slug per line. Loaded into SKIP_SLUGS every run, so those are never
# offered again. SKIPPED_COUNT (skipped AND not yet recorded) shrinks the goal
# the progress bar counts toward, so "all done" means "all the ones you wanted".
SKIP_FILE="${SKIP_FILE:-$VIDEOS_DIR/skipped.txt}"
SKIPPED_COUNT=0
if [[ -f "$SKIP_FILE" ]]; then
    while read -r _s; do
        [[ -n "$_s" ]] || continue
        SKIP_SLUGS="$SKIP_SLUGS $_s"
        [[ -f "$OUTPUT_DIR/${_s}.mp4" || -f "$AUDIO_DIR/${_s}.wav" ]] || SKIPPED_COUNT=$(( SKIPPED_COUNT + 1 ))
    done < "$SKIP_FILE"
fi

# --- ffmpeg: prefer the system one; fall back to nix (this box is ephemeral). -
if command -v ffmpeg >/dev/null 2>&1; then
    FFMPEG=(ffmpeg)
elif command -v nix >/dev/null 2>&1; then
    FFMPEG=(env -u LD_LIBRARY_PATH nix shell nixpkgs#ffmpeg --command ffmpeg)
else
    echo "ERROR: ffmpeg not found and nix unavailable to provide it." >&2
    exit 1
fi

py() { python3 "$HERE/lessons.py" "$@"; }

# WAV duration in whole seconds, read straight from the header (no ffprobe dep).
wav_seconds() {
    python3 - "$1" <<'PY'
import sys, wave
try:
    with wave.open(sys.argv[1], "rb") as w:
        print(int(w.getnframes() / w.getframerate()))
except Exception:
    print(0)
PY
}

open_in_browser() {
    [[ "${NO_BROWSER:-0}" == "1" ]] && return 0
    local url="$1"
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 &
    else
        echo "Open this to read the article:  $url"
    fi
}

fmt_mmss() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# Peak level in dBFS (0 = full scale, more negative = quieter). Used to catch a
# take that met the length but is essentially silence (muted mic or the wrong
# pulse source), which would otherwise become a dead-air video. On a parse
# failure it prints 0, i.e. fails OPEN: an unreadable level never blocks a take.
# True digital silence still gets caught (volumedetect reports about -91 dB).
PEAK_SILENCE_DBFS="${PEAK_SILENCE_DBFS:--35}"
peak_dbfs() {
    local out
    out="$("${FFMPEG[@]}" -hide_banner -i "$1" -af volumedetect -f null - 2>&1)" || true
    local v
    v="$(printf '%s\n' "$out" | sed -n 's/.*max_volume: \(-\?[0-9.]*\) dB.*/\1/p' | head -1)"
    [[ -n "$v" ]] && printf '%s' "$v" || printf '%s' "0"
}

# Play a wav back so you can hear the take before committing it. pulse's paplay
# first (this box records via pulse), then ffplay if it's around. The INT trap
# makes Ctrl-C stop only the playback, not the whole recorder: bash treats a
# child killed by SIGINT as its own interrupt unless a trap is set.
play_wav() {
    trap : INT
    if command -v paplay >/dev/null 2>&1; then
        paplay "$1" || true
    elif command -v ffplay >/dev/null 2>&1; then
        ffplay -autoexit -nodisp -loglevel error "$1" || true
    elif command -v nix >/dev/null 2>&1; then
        env -u LD_LIBRARY_PATH nix shell nixpkgs#ffmpeg --command \
            ffplay -autoexit -nodisp -loglevel error "$1" || true
    else
        echo "  (no player found, cannot play back)"
    fi
    trap - INT
}

notify() {
    command -v notify-send >/dev/null 2>&1 && notify-send "$1" "$2" >/dev/null 2>&1 || true
}

# --- Render freeze: the mic owns the machine while it's actually capturing. ---
# Each background render is launched in its OWN process group (see `set -m` at
# the launch site), so a single signal freezes the whole job — the subshell AND
# the ffmpeg/x264 children it spawns. While a take is recording we SIGSTOP every
# render (zero cpu, so it can NEVER cause a capture xrun / dropout in your take),
# then SIGCONT the instant recording stops. Renders only advance in the gaps
# between takes: slower renders, but a recording in progress is never at risk.
# (The nice/ionice on each job is a second layer for when renders do run.)
RENDER_PIDS=()

freeze_renders() {
    (( ${#RENDER_PIDS[@]} )) || return 0
    local p
    for p in "${RENDER_PIDS[@]}"; do kill -STOP -"$p" 2>/dev/null || true; done
}

thaw_renders() {
    (( ${#RENDER_PIDS[@]} )) || return 0
    local p live=()
    for p in "${RENDER_PIDS[@]}"; do
        kill -CONT -"$p" 2>/dev/null || true
        kill -0 -"$p" 2>/dev/null && live+=("$p")   # drop groups that finished
    done
    RENDER_PIDS=("${live[@]}")
}

# --- Progress bar over the whole wiki roster. --------------------------------
# TOTAL_LESSONS / BASE_DONE are read once at startup; DONE_THIS_SESSION counts
# takes committed in this run (their wav marker lands later, in the background,
# so we can't re-derive it from disk without a race). Bar = base + session.
TOTAL_LESSONS=0
BASE_DONE=0
DONE_THIS_SESSION=0
SESSION_RECORDED=0   # takes committed this run (wiki + --new), for the summary

repeat() { local i out=""; for ((i=0; i<$2; i++)); do out+="$1"; done; printf '%s' "$out"; }

progress_bar() {
    (( TOTAL_LESSONS > 0 )) || return 0
    # Count toward the GOAL = every lesson minus the ones you skipped for good,
    # so 100% means "recorded all the ones you wanted", not all 113.
    local goal=$(( TOTAL_LESSONS - SKIPPED_COUNT )) width=28
    (( goal < 1 )) && goal=1
    local done=$(( BASE_DONE + DONE_THIS_SESSION ))
    (( done > goal )) && done=$goal
    local filled=$(( done * width / goal ))
    local pct=$(( done * 100 / goal ))
    local extra=""
    (( SKIPPED_COUNT > 0 )) && extra=" · ${SKIPPED_COUNT} skipped"
    printf '  Wiki  [%s%s]  %d/%d lessons  (%d%%%s)\n' \
        "$(repeat '█' "$filled")" "$(repeat '░' $(( width - filled )))" \
        "$done" "$goal" "$pct" "$extra"
}

# --- Background voice-clean + render, serialized/niced/freezable. -------------
# $1 slug  $2 title  $3 (optional) raw wav to voice-clean first. Omit $3 to just
# re-render from an already-cleaned wav (the self-heal path). Launched in its own
# process group (set -m) so freeze_renders can SIGSTOP the whole tree; niced so a
# render never starves the live mic. One && chain under `if` so `set -e` can't
# skip the notify, and the old mp4 is only removed AFTER the clean succeeds (a
# failed re-record's audio never deletes a good video).
launch_render() {
    local slug="$1" title="$2" raw="${3:-}"
    local dest="$AUDIO_DIR/${slug}.wav"
    set -m
    (
        trap '' INT HUP
        renice -n 19 -p "$BASHPID" >/dev/null 2>&1 || true
        command -v ionice >/dev/null 2>&1 && ionice -c3 -p "$BASHPID" >/dev/null 2>&1 || true
        flock 9
        echo "=== $(date '+%F %T')  render $slug ===" >>"$RENDER_LOG"
        clean_ok=1
        if [[ -n "$raw" ]]; then
            {
                case "$CLEAN" in
                    full) "$HERE/audio-clean.sh" "$raw" "$dest" ;;
                    raw)  cp -f "$raw" "$dest" ;;
                    *)    "${FFMPEG[@]}" -hide_banner -loglevel error -y -i "$raw" \
                              -af "$CLEAN_AF" -ar 48000 "$dest" ;;
                esac
            } >>"$RENDER_LOG" 2>&1 || clean_ok=0
        fi
        if (( clean_ok )) \
           && rm -f "$OUTPUT_DIR/${slug}.mp4" \
           && VOICE_DENOISE= "$HERE/make_videos.sh" "$slug" >>"$RENDER_LOG" 2>&1; then
            echo "    OK $OUTPUT_DIR/${slug}.mp4" >>"$RENDER_LOG"
            notify "Navy Lily" "Rendered: $title"
        else
            echo "    FAILED render for $slug (see above)" >>"$RENDER_LOG"
            notify "Navy Lily" "RENDER FAILED: $title (see render.log)"
        fi
    ) 9>"$RENDER_LOCK" &
    RENDER_PIDS+=("$!")   # its pgid == its pid; freeze_renders signals the group
    set +m
}

# Resolve MIC=default to the actual pulse source name, so the banner shows which
# device you're really about to record 10 lessons on (e.g. the FIFINE, not the
# laptop mic). Falls back to the raw value if pactl isn't around.
resolved_mic() {
    if [[ "$MIC" == "default" ]] && command -v pactl >/dev/null 2>&1; then
        pactl get-default-source 2>/dev/null || echo default
    else
        echo "$MIC"
    fi
}

# Session summary + clean exit. Surfaces renders still finishing so you know not
# to be surprised they're using the CPU, and that they'll still post.
goodbye() {
    thaw_renders   # never leave a frozen render behind
    echo
    (( SESSION_RECORDED > 0 )) && echo "Recorded ${SESSION_RECORDED} this session."
    local pending=${#RENDER_PIDS[@]}
    if (( pending > 0 )); then
        echo "⏳ ${pending} still rendering in the background — they keep going"
        echo "   even if you close this, and auto-post PRIVATE. Log: $RENDER_LOG"
    fi
    echo "👋"
    exit 0
}

# --- --list just prints the roster and exits. --------------------------------
if [[ "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
    py list
    exit 0
fi

# --- --unskip: manage the permanent skip list. -------------------------------
#   --unskip           show what you've skipped for good
#   --unskip <slug>    put a skipped lesson back in rotation
if [[ "${1:-}" == "--unskip" ]]; then
    if [[ -z "${2:-}" ]]; then
        echo "Skipped for good:"
        [[ -s "$SKIP_FILE" ]] && sed 's/^/  /' "$SKIP_FILE" || echo "  (none)"
    elif [[ -f "$SKIP_FILE" ]] && grep -qxF "$2" "$SKIP_FILE"; then
        grep -vxF "$2" "$SKIP_FILE" > "$SKIP_FILE.tmp" && mv "$SKIP_FILE.tmp" "$SKIP_FILE"
        echo "Un-skipped '$2' — it'll be offered again."
    else
        echo "Not in the skip list: ${2:-}"
    fi
    exit 0
fi

# --new: free-form mode. Not a wiki article: you name the video, everything
# after the title (record, guard, clean, render, auto-post) is identical.
FREE_MODE=0
FREE_TITLE=""
if [[ "${1:-}" == "--new" || "${1:-}" == "-n" ]]; then
    FREE_MODE=1
    shift || true
    FREE_TITLE="${*:-}"
fi

SEARCH="${1:-}"

# Roster counts for the progress bar (best-effort; stays 0/hidden on any error).
if counts="$(py count 2>/dev/null)"; then
    IFS=$'\t' read -r TOTAL_LESSONS BASE_DONE <<<"$counts"
fi

echo "Navy Lily · lesson recorder"
progress_bar
echo "  mic $(resolved_mic) · min ${MIN_MINUTES}m · clean $CLEAN"
if systemctl --user is-active navylily-youtube.timer >/dev/null 2>&1; then
    echo "  posting  ✓ on — auto-posts PRIVATE, 1/day, public after 24h"
else
    echo "  posting  ✗ OFF — takes will render + queue but NOT post"
    echo "           arm once: ./youtube_upload.sh --authorize && ./install_timer.sh"
fi

# Self-heal: a cleaned wav with no finished mp4 is an interrupted/failed render
# (crash, disk full, laptop slept mid-render). Re-queue those so a lesson that
# counts as "recorded" never silently sits un-published. No raw arg => render
# straight from the wav that already exists.
_healed=0
shopt -s nullglob
for _wav in "$AUDIO_DIR"/*.wav; do
    _s="$(basename "$_wav" .wav)"
    [[ -f "$OUTPUT_DIR/${_s}.mp4" ]] && continue
    _t="$_s"; [[ -f "$OUTPUT_DIR/${_s}.title.txt" ]] && _t="$(cat "$OUTPUT_DIR/${_s}.title.txt")"
    launch_render "$_s" "$_t"
    _healed=$(( _healed + 1 ))
done
shopt -u nullglob
(( _healed > 0 )) && echo "  ↻ re-queued ${_healed} unfinished render(s) from before"
echo

while :; do
    if (( FREE_MODE )); then
        # Free-form: title comes from you, not the wiki.
        while [[ -z "$FREE_TITLE" ]]; do
            read -r -p "Video title: " FREE_TITLE || exit 0
        done
        title="$FREE_TITLE"
        slug="$(py slug "$title")"
        html_path=""
        FREE_TITLE=""   # next round asks again
        if [[ -f "$OUTPUT_DIR/${slug}.mp4" || -f "$AUDIO_DIR/${slug}.wav" ]]; then
            read -r -p "'$slug' already exists. Overwrite it? [y/N] " a || exit 0
            [[ "$a" =~ ^[Yy] ]] || continue
        fi
        echo "────────────────────────────────────────────────────────"
        echo "▶ Video:  $title"
        echo
    else
    # Pick the lesson: the search term (if any) on the first pass, then always
    # the next un-recorded, minus the ones skipped this session.
    if line="$(py next ${SEARCH:+"$SEARCH"})"; then
        :
    else
        rc=$?
        if [[ $rc -eq 3 ]]; then
            if [[ -n "$SEARCH" ]]; then
                echo "No lesson matches: $SEARCH"
            else
                echo
                progress_bar
                if (( TOTAL_LESSONS > 0 && BASE_DONE + DONE_THIS_SESSION >= TOTAL_LESSONS - SKIPPED_COUNT )); then
                    echo "🎉 All done! Recorded every lesson you wanted"
                    (( SKIPPED_COUNT > 0 )) && echo "   (${SKIPPED_COUNT} skipped on purpose)."
                else
                    echo "Nothing left this session — the rest were skipped for now. Re-run to revisit."
                fi
            fi
            goodbye
        fi
        exit $rc
    fi
    SEARCH=""   # only honor the search term once

    IFS=$'\t' read -r slug title md_path html_path <<<"$line"

    echo "────────────────────────────────────────────────────────"
    progress_bar
    echo "▶ Lesson:  $title"
    echo "  script opened in your browser — read it aloud while you record"
    open_in_browser "file://$html_path"
    echo
    fi

    raw="$RAW_DIR/${slug}.raw.wav"

    while :; do
        read -r -p "ENTER to record · 's' skip this lesson · 'q' quit… " _ans || exit 0
        case "${_ans,,}" in
            q|quit) goodbye ;;
            s|skip)
                # Skip for good: remember it so it's never offered again, and
                # (in --new mode there's no slug/file, so guard on FREE_MODE).
                if (( FREE_MODE )); then
                    echo "  ↷ skipped."
                else
                    printf '%s\n' "$slug" >> "$SKIP_FILE"
                    SKIP_SLUGS="$SKIP_SLUGS $slug"
                    SKIPPED_COUNT=$(( SKIPPED_COUNT + 1 ))
                    echo "  ↷ skipped '$title' — won't be offered again."
                fi
                break ;;   # no raw exists, so the guard below moves to the next
        esac
        # Freeze any in-flight render so the capture has the whole CPU (no
        # xruns), and thaw it the moment recording stops — even if ffmpeg errors.
        freeze_renders
        # Record in the BACKGROUND with -nostdin so a stray or bumped key can
        # NEVER stop the take. We own the keyboard here: the loop ticks a live
        # elapsed timer, and stopping takes TWO deliberate actions — press ENTER,
        # then confirm y/N — so nothing ends the recording by accident.
        "${FFMPEG[@]}" -hide_banner -loglevel error -nostats -nostdin \
            -f pulse -i "$MIC" -ac 1 -ar 48000 -c:a pcm_s16le -y "$raw" &
        rec_pid=$!
        start=$SECONDS
        while kill -0 "$rec_pid" 2>/dev/null; do
            e=$(( SECONDS - start ))
            if (( e >= MIN_SECONDS )); then
                printf '\r%-72s' "  ● REC  $(fmt_mmss "$e")   ✓ past ${MIN_MINUTES}min — press ENTER to stop"
            else
                printf '\r%-72s' "  ● REC  $(fmt_mmss "$e")   need ${MIN_MINUTES}min, keep going…"
            fi
            # read completes only on ENTER (a full line); a lone stray key won't
            # trip it. On the ~1s timeout the loop just re-ticks the timer.
            if read -r -t 1 -s _; then
                printf '\n'
                read -r -p "  Stop recording? [y/N] " a || a=""
                [[ "$a" =~ ^[Yy] ]] && break
                echo "  …still recording. (audio kept running the whole time)"
            fi
        done
        printf '\n'
        # Graceful stop: SIGINT makes ffmpeg finalize the wav header cleanly
        # (verified to yield a valid, readable file). No-op if it already exited.
        kill -INT "$rec_pid" 2>/dev/null || true
        wait "$rec_pid" 2>/dev/null || true
        thaw_renders

        [[ -f "$raw" ]] || { echo "No audio captured. Let's try again."; continue; }
        dur="$(wav_seconds "$raw")"
        echo "  captured $(fmt_mmss "$dur")."

        if (( dur < MIN_SECONDS )); then
            echo "⚠  Under ${MIN_MINUTES} min ($(fmt_mmss "$dur")): treating as a"
            echo "   misfire and discarding it (nothing will be posted)."
            rm -f "$raw"
            read -r -p "Re-record this lesson? [Y/n] " a || exit 0
            [[ "$a" =~ ^[Nn] ]] && { echo "Skipping '$title' for now."; SKIP_SLUGS="$SKIP_SLUGS $slug"; break; }
            continue
        fi

        # Length passed, but is it actually audio? Catch a muted mic / wrong
        # pulse source that would otherwise become a dead-air video.
        peak="$(peak_dbfs "$raw")"
        if awk -v p="$peak" -v t="$PEAK_SILENCE_DBFS" 'BEGIN{exit !(p<t)}'; then
            echo "⚠  Peak level ${peak} dBFS is near-silent (threshold ${PEAK_SILENCE_DBFS} dBFS)."
            echo "   The mic may be muted or set to the wrong source. Discarding this take."
            rm -f "$raw"
            read -r -p "Re-record this lesson? [Y/n] " a || exit 0
            [[ "$a" =~ ^[Nn] ]] && { echo "Skipping '$title' for now."; SKIP_SLUGS="$SKIP_SLUGS $slug"; break; }
            continue
        fi

        # Keep / listen / re-record. Enter defaults to keep, so it stays fast.
        retake=0
        while :; do
            read -r -p "Take: $(fmt_mmss "$dur"), peak ${peak} dBFS. [K]eep / [L]isten / [R]e-record? " a || exit 0
            case "${a,,}" in
                l) echo "  playing back… (Ctrl-C stops playback)"; play_wav "$raw" ;;
                r) retake=1; break ;;
                ""|k) break ;;
                *) echo "  answer k, l, or r" ;;
            esac
        done
        (( retake )) && continue
        break
    done
    # If we broke out because the user declined to re-record a bad take, the
    # raw file is gone and no audio exists: move on to the next lesson.
    [[ -f "$raw" ]] || { [[ -n "$html_path" ]] && rm -f "$html_path"; continue; }

    # This take is committed. Mark the slug done for THIS session right away so
    # the picker never offers it again. The on-disk "recorded" marker (the wav
    # in AUDIO_DIR) is now written by the BACKGROUND job, which may be queued
    # behind an earlier render, so it won't exist yet when the loop asks for the
    # next lesson. Without this line `py next` would re-hand-you the lesson you
    # just recorded, and a second take would clobber the raw the background job
    # is still reading. Harmless in --new mode (no picker consults SKIP_SLUGS).
    SKIP_SLUGS="$SKIP_SLUGS $slug"

    # Title sidecar next to the eventual mp4; youtube_upload.py reads this and
    # posts under the real wiki title instead of a random one.
    printf '%s\n' "$title" > "$OUTPUT_DIR/${slug}.title.txt"

    # Hand off to the background: voice-clean this raw take, then render. You're
    # back at the next prompt instantly; the job runs niced and freezes while you
    # record the next take. Passing "$raw" means "clean it first".
    launch_render "$slug" "$title" "$raw"

    SESSION_RECORDED=$(( SESSION_RECORDED + 1 ))
    (( FREE_MODE )) || DONE_THIS_SESSION=$(( DONE_THIS_SESSION + 1 ))
    echo "✓ '$title' saved · rendering in background · auto-posts PRIVATE (1/day, public in 24h)"
    (( FREE_MODE )) || progress_bar
    [[ -n "$html_path" ]] && rm -f "$html_path"
    echo
    if (( FREE_MODE )); then
        read -r -p "Record another video? [Y/n] " a || exit 0
        [[ "$a" =~ ^[Nn] ]] && goodbye
        echo
        continue
    fi
    read -r -p "Record the next lesson? [Y/n] " a || exit 0
    [[ "$a" =~ ^[Nn] ]] && goodbye
    echo
done
