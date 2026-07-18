#!/usr/bin/env bash
#
# record_lessons.sh — narrate the Navy Lily wiki, one article per video, from
# the terminal. No Audacity, no browser recorder: just ffmpeg + the existing
# audio-clean.sh / make_videos.sh pipeline.
#
# What one run does, looping until you stop:
#   1. Picks the next NOT-yet-recorded wiki article (recorded state is auto-
#      detected from files on disk — see lessons.py; nothing to track by hand).
#   2. Opens that article in your browser so you can read/speak about it.
#   3. Records your mic with ffmpeg (press  q  in ffmpeg to stop).
#   4. Rejects anything under MIN_MINUTES (default 6) as a likely misfire and
#      lets you re-record — a too-short take never becomes a video.
#   5. Cleans the voice (audio-clean.sh: highpass/lowpass/denoise/loudnorm) and
#      renders the video with images + the navylily.tv watermark (make_videos.sh).
#   6. Writes the article title next to the mp4 so youtube_upload.py posts it
#      under the real wiki title (still PRIVATE, still one upload per day).
#
# The finished mp4 lands in videos/output/. The existing daily YouTube timer
# picks it up and posts it — this script never uploads anything itself.
#
# Usage:
#   ./record_lessons.sh                # work through un-recorded lessons
#   ./record_lessons.sh "maos"         # jump to / re-record a specific article
#   ./record_lessons.sh --list         # show every lesson and its recorded mark
#
# Env overrides:
#   MIC=default            pulse source ('default' = system default mic)
#   MIN_MINUTES=6          reject recordings shorter than this
#   WIKI_DIR=...           where the article .md files live
#   NO_BROWSER=1           don't try to open the article in a browser
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MIC="${MIC:-default}"   # 'default' = the pulse default source = your FIFINE AM8
MIN_MINUTES="${MIN_MINUTES:-6}"
MIN_SECONDS="$(awk -v m="$MIN_MINUTES" 'BEGIN{printf "%.0f", m*60}')"

# Voice processing. Default is LIGHT — exactly what you asked for: high-pass out
# desk rumble, a gentle low-pass, and loudness-normalize. No denoise, no EQ, no
# compression, so the FIFINE's sound is kept and not over-processed. make_videos
# runs with its own denoise disabled (below), so this is the ONLY processing.
#   CLEAN=full   use the heavier audio-clean.sh (RNNoise + EQ + compressor)
#   CLEAN=raw    no processing at all — save the mic capture as-is
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
# take that met the length but is essentially silence — a muted mic or the wrong
# pulse source — which would otherwise become a dead-air video. Prints a big
# negative sentinel if it can't tell, so a parse failure never blocks a take.
PEAK_SILENCE_DBFS="${PEAK_SILENCE_DBFS:--35}"
peak_dbfs() {
    local out
    out="$("${FFMPEG[@]}" -hide_banner -i "$1" -af volumedetect -f null - 2>&1)" || true
    local v
    v="$(printf '%s\n' "$out" | sed -n 's/.*max_volume: \(-\?[0-9.]*\) dB.*/\1/p' | head -1)"
    [[ -n "$v" ]] && printf '%s' "$v" || printf '%s' "-999"
}

# Play a wav back so you can hear the take before committing it. pulse's paplay
# first (this box records via pulse), then ffplay if it's around.
play_wav() {
    if command -v paplay >/dev/null 2>&1; then
        paplay "$1" || true
    elif command -v ffplay >/dev/null 2>&1; then
        ffplay -autoexit -nodisp -loglevel error "$1" || true
    elif command -v nix >/dev/null 2>&1; then
        env -u LD_LIBRARY_PATH nix shell nixpkgs#ffmpeg --command \
            ffplay -autoexit -nodisp -loglevel error "$1" || true
    else
        echo "  (no player found — can't play back)"
    fi
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
echo "  output:     $OUTPUT_DIR"
echo

while :; do
    # Pick the lesson: the search term (if any) on the first pass, then always
    # 'next un-recorded' afterwards.
    if line="$(py next ${SEARCH:+"$SEARCH"})"; then
        :
    else
        rc=$?
        if [[ $rc -eq 3 ]]; then
            [[ -n "$SEARCH" ]] && echo "No lesson matches: $SEARCH" \
                               || echo "🎉 Every wiki article has been recorded."
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
        echo "● Recording — speak now. Press 'q' to stop (Ctrl-C also stops)."
        # -c:a pcm_s16le so the wave module can read the header for the length
        # check; -ac 1 mono voice; pulse default mic. 'q' on stdin stops cleanly.
        "${FFMPEG[@]}" -hide_banner -f pulse -i "$MIC" \
            -ac 1 -ar 48000 -c:a pcm_s16le -y "$raw" || true

        [[ -f "$raw" ]] || { echo "No audio captured. Let's try again."; continue; }
        dur="$(wav_seconds "$raw")"
        echo "  captured $(fmt_mmss "$dur")."

        if (( dur < MIN_SECONDS )); then
            echo "⚠  Under ${MIN_MINUTES} min ($(fmt_mmss "$dur")) — treating as a"
            echo "   misfire and discarding it (nothing will be posted)."
            rm -f "$raw"
            read -r -p "Re-record this lesson? [Y/n] " a || exit 0
            [[ "$a" =~ ^[Nn] ]] && { echo "Skipping '$title' for now."; break; }
            continue
        fi

        # Length passed — but is it actually audio? Catch a muted mic / wrong
        # pulse source that would otherwise become a dead-air video.
        peak="$(peak_dbfs "$raw")"
        if awk -v p="$peak" -v t="$PEAK_SILENCE_DBFS" 'BEGIN{exit !(p<t)}'; then
            echo "⚠  Peak level ${peak} dBFS is near-silent (threshold ${PEAK_SILENCE_DBFS} dBFS)."
            echo "   The mic may be muted or set to the wrong source — discarding this take."
            rm -f "$raw"
            read -r -p "Re-record this lesson? [Y/n] " a || exit 0
            [[ "$a" =~ ^[Nn] ]] && { echo "Skipping '$title' for now."; break; }
            continue
        fi

        # Keep / listen / re-record. Enter defaults to keep, so it stays fast.
        retake=0
        while :; do
            read -r -p "Take: $(fmt_mmss "$dur") @ peak ${peak} dBFS — [K]eep / [L]isten / [R]e-record? " a || exit 0
            case "${a,,}" in
                l) echo "  playing back… (Ctrl-C to stop early)"; play_wav "$raw" ;;
                r) retake=1; break ;;
                ""|k) break ;;
                *) echo "  answer k, l, or r" ;;
            esac
        done
        (( retake )) && continue
        break
    done
    # If we broke out because the user declined to re-record a short take, the
    # raw file is gone and no audio exists — move on to the next lesson.
    [[ -f "$raw" ]] || continue

    echo "Processing voice (CLEAN=$CLEAN)…"
    dest="$AUDIO_DIR/${slug}.wav"
    case "$CLEAN" in
        full) "$HERE/audio-clean.sh" "$raw" "$dest" ;;
        raw)  cp -f "$raw" "$dest" ;;
        *)    "${FFMPEG[@]}" -hide_banner -loglevel error -y -i "$raw" \
                  -af "$CLEAN_AF" -ar 48000 "$dest" ;;
    esac

    # Title sidecar next to the eventual mp4 — youtube_upload.py reads this and
    # posts under the real wiki title instead of a random one.
    printf '%s\n' "$title" > "$OUTPUT_DIR/${slug}.title.txt"

    # Render in the background, serialized by a lock so recording several in a
    # row doesn't spawn a pile of parallel ffmpeg renders. VOICE_DENOISE= tells
    # make_videos.sh to skip its own denoise (audio-clean already did it).
    echo "Rendering video with images + navylily.tv watermark (in background)…"
    (
        flock 9
        echo "=== $(date '+%F %T')  render $slug ===" >>"$RENDER_LOG"
        VOICE_DENOISE= "$HERE/make_videos.sh" "$slug" >>"$RENDER_LOG" 2>&1 \
            && echo "    ✓ $OUTPUT_DIR/${slug}.mp4" >>"$RENDER_LOG" \
            || echo "    ✗ render failed for $slug (see above)" >>"$RENDER_LOG"
    ) 9>"$RENDER_LOCK" &

    echo "✓ '$title' saved. It will render, then auto-post PRIVATE (1/day)."
    echo "   render log: $RENDER_LOG"
    rm -f "$html_path"
    echo
    read -r -p "Record the next lesson? [Y/n] " a || exit 0
    [[ "$a" =~ ^[Nn] ]] && { echo "Done for now. 👋"; exit 0; }
    echo
done
