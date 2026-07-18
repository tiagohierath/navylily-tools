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
#      public automatically after YT_PUBLISH_AFTER_DAYS days (default 7).
#
# This script never uploads anything itself; the daily timer does the posting.
#
# Usage:
#   ./record_lessons.sh                # work through un-recorded lessons
#   ./record_lessons.sh "maos"         # jump to / re-record a specific article
#   ./record_lessons.sh --list         # show every lesson and its recorded mark
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

# Lessons skipped in THIS session (declined re-record). Without this the picker
# would offer the same first-unrecorded lesson again immediately.
SKIP_SLUGS=""
export SKIP_SLUGS

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

# --- --list just prints the roster and exits. --------------------------------
if [[ "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
    py list
    exit 0
fi

SEARCH="${1:-}"

echo "Navy Lily lesson recorder"
echo "  mic:        $MIC   (override with MIC=...)"
echo "  min length: ${MIN_MINUTES} min   (shorter takes are discarded)"
echo "  clean:      $CLEAN"
echo "  output:     $OUTPUT_DIR"
systemctl --user is-active navylily-youtube.timer >/dev/null 2>&1 \
    || echo "  NOTE: posting timer not active. Videos will queue but not post." \
       "Arm it with ./youtube_upload.sh --authorize (once) + ./install_timer.sh"
echo

while :; do
    # Pick the lesson: the search term (if any) on the first pass, then always
    # the next un-recorded, minus the ones skipped this session.
    if line="$(py next ${SEARCH:+"$SEARCH"})"; then
        :
    else
        rc=$?
        if [[ $rc -eq 3 ]]; then
            [[ -n "$SEARCH" ]] && echo "No lesson matches: $SEARCH" \
                               || echo "Nothing left to pick (all recorded, or skipped this session)."
            exit 0
        fi
        exit $rc
    fi
    SEARCH=""   # only honor the search term once

    IFS=$'\t' read -r slug title md_path html_path <<<"$line"

    echo "────────────────────────────────────────────────────────"
    echo "Lesson:  $title"
    echo "Slug:    $slug"
    echo "Article: opening in your browser to read while you speak…"
    open_in_browser "file://$html_path"
    echo

    raw="$RAW_DIR/${slug}.raw.wav"

    while :; do
        read -r -p "Press ENTER to START recording (then press 'q' in ffmpeg to stop)… " _ || exit 0
        echo "● Recording. Speak now; press 'q' to stop."
        # -c:a pcm_s16le so the wave module can read the header for the length
        # check; -ac 1 mono voice; pulse default mic. 'q' on stdin stops cleanly.
        "${FFMPEG[@]}" -hide_banner -f pulse -i "$MIC" \
            -ac 1 -ar 48000 -c:a pcm_s16le -y "$raw" || true

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
    [[ -f "$raw" ]] || { rm -f "$html_path"; continue; }

    echo "Processing voice (CLEAN=$CLEAN)…"
    dest="$AUDIO_DIR/${slug}.wav"
    case "$CLEAN" in
        full) "$HERE/audio-clean.sh" "$raw" "$dest" ;;
        raw)  cp -f "$raw" "$dest" ;;
        *)    "${FFMPEG[@]}" -hide_banner -loglevel error -y -i "$raw" \
                  -af "$CLEAN_AF" -ar 48000 "$dest" ;;
    esac

    # Title sidecar next to the eventual mp4; youtube_upload.py reads this and
    # posts under the real wiki title instead of a random one.
    printf '%s\n' "$title" > "$OUTPUT_DIR/${slug}.title.txt"

    # Render in the background, serialized by a lock so recording several in a
    # row doesn't spawn a pile of parallel ffmpeg renders.
    #   trap '' INT HUP    a committed take must render even if you Ctrl-C the
    #                      recorder or close the terminal (same process group).
    #   rm stale mp4       make_videos skips existing outputs, so a re-recorded
    #                      lesson must drop its old video to get a new render.
    #   VOICE_DENOISE=     skip make_videos' own denoise (voice already done).
    #   MUSIC_ROTATION     random start track; per-slug runs would otherwise
    #                      all open the video on the same song.
    echo "Rendering video with images + navylily.tv watermark (in background)…"
    (
        trap '' INT HUP
        flock 9
        rm -f "$OUTPUT_DIR/${slug}.mp4"
        echo "=== $(date '+%F %T')  render $slug ===" >>"$RENDER_LOG"
        if VOICE_DENOISE= MUSIC_ROTATION=$((RANDOM % 100)) \
            "$HERE/make_videos.sh" "$slug" >>"$RENDER_LOG" 2>&1; then
            echo "    OK $OUTPUT_DIR/${slug}.mp4" >>"$RENDER_LOG"
            notify "Navy Lily" "Rendered: $title"
        else
            echo "    FAILED render for $slug (see above)" >>"$RENDER_LOG"
            notify "Navy Lily" "RENDER FAILED: $title (see render.log)"
        fi
    ) 9>"$RENDER_LOCK" &

    echo "✓ '$title' saved. It will render, then auto-post PRIVATE (1/day),"
    echo "   going public 7 days after upload. Render log: $RENDER_LOG"
    rm -f "$html_path"
    echo
    read -r -p "Record the next lesson? [Y/n] " a || exit 0
    [[ "$a" =~ ^[Nn] ]] && { echo "Done for now. 👋"; exit 0; }
    echo
done
