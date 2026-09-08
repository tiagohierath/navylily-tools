#!/usr/bin/env bash
#
# record_lessons.sh, record Navy Lily videos from the terminal, all
# from the terminal. No Audacity, no DAW: ffmpeg records, make_videos.sh
# renders (images + navylily.tv watermark), youtube_upload.py posts.
#
# What one run does, looping until you stop:
#   1. Takes the video title from the command line or asks for it.
#   2. Shows the title in the terminal.
#   3. Records the mic with ffmpeg (press Enter, then confirm, to stop).
#   4. Guards the take: under MIN_MINUTES (default 0, off) or near-silent peaks are
#      treated as misfires and discarded, then you re-record or skip. A kept
#      take can be played back first ([L]isten).
#   5. Processes the voice with the shared AM8 narration chain and
#      renders the video in the background, serialized by a lock.
#   6. Writes your title next to the mp4 and uploads that exact finished
#      video to YouTube as PRIVATE. YouTube flips it public at 18:00 the next day
#      (YT_PUBLISH_DELAY_DAYS, default 1).
#
# One-time setup, then usage from any directory:
#   ./record_lessons.sh --install
#   record                             # record a free video; asks for its title
#   record "Title"                     # record a video with this title
#   record new "Title"                 # compatibility spelling of the same
#
# Env overrides:
#   MIC=default          pulse source (default = system default mic, the FIFINE)
#   MIN_MINUTES=0        reject recordings shorter than this (0 = no minimum)
#   CLEAN=light          light (default) / full (audio-clean.sh) / raw (none)
#   VIDEO_BASE_DIR=...   where audio, recordings, output, and logs live
#   AUTO_UPLOAD=1        upload each kept take after rendering (0 = queue only)
#
set -euo pipefail

# Follow symlinks before resolving the repo directory. This is what lets the
# ~/.local/bin/record command find make_videos.sh, fonts,
# and videos regardless of the caller's current working directory.
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do
    SOURCE_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    [[ "$SCRIPT_SOURCE" == /* ]] || SCRIPT_SOURCE="$SOURCE_DIR/$SCRIPT_SOURCE"
done
HERE="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
SCRIPT_PATH="$HERE/$(basename "$SCRIPT_SOURCE")"
COMMAND_NAME="record"

usage() {
    cat <<EOF
Navy Lily recorder

Install once, from the navylily-tools repository:
  ./record_lessons.sh --install

Then run from any directory:
  $COMMAND_NAME                  Record a free-form video (asks for its title)
  $COMMAND_NAME "Title"          Record a video with this title
  $COMMAND_NAME new "Title"      Same (older spelling)
  $COMMAND_NAME youtube reauth   Open a fresh Google/YouTube OAuth flow
  $COMMAND_NAME youtube verify   Verify due videos became public

Setup:
  --install                      Add $COMMAND_NAME to ~/.local/bin
  --uninstall                    Remove that command
  -h, --help                     Show this help

The older --new spelling still works. Media stays under
the repository's videos/ directory by default. Set VIDEO_BASE_DIR=/some/path
to use a different media directory, from anywhere.

Common environment overrides:
  MIC=default                    PulseAudio/PipeWire microphone source
  MIN_MINUTES=0                  Reject shorter takes (0 disables the minimum)
  CLEAN=light                    light, full, or raw voice processing
  VIDEO_BASE_DIR=/path/to/media  Audio, recordings, output, and render log root
  AUTO_UPLOAD=1                  Upload after rendering (0 leaves it queued)
EOF
}

install_command() {
    local bin_dir="${NAVYLILY_BIN_DIR:-${HOME:?HOME is not set}/.local/bin}"
    local command_path="$bin_dir/$COMMAND_NAME"

    mkdir -p "$bin_dir"
    if [[ -L "$command_path" ]]; then
        if [[ "$(readlink "$command_path")" == "$SCRIPT_PATH" ]]; then
            echo "$COMMAND_NAME is already installed: $command_path"
            return
        fi
        echo "ERROR: $command_path is already a different symbolic link." >&2
        echo "Remove or rename it first, then run --install again." >&2
        return 1
    elif [[ -e "$command_path" ]]; then
        echo "ERROR: $command_path already exists and was left untouched." >&2
        return 1
    fi

    ln -s "$SCRIPT_PATH" "$command_path"
    echo "Installed $COMMAND_NAME -> $SCRIPT_PATH"
    if [[ ":${PATH:-}:" != *":$bin_dir:"* ]]; then
        echo
        echo "$bin_dir is not currently on PATH. Add it to your shell setup."
        if [[ "$bin_dir" == "$HOME/.local/bin" ]]; then
            echo 'For Bash/Zsh: export PATH="$HOME/.local/bin:$PATH"'
        fi
    else
        echo "Run '$COMMAND_NAME' from any directory."
    fi
}

uninstall_command() {
    local bin_dir="${NAVYLILY_BIN_DIR:-${HOME:?HOME is not set}/.local/bin}"
    local command_path="$bin_dir/$COMMAND_NAME"

    if [[ -L "$command_path" && "$(readlink "$command_path")" == "$SCRIPT_PATH" ]]; then
        rm "$command_path"
        echo "Removed $command_path (the repository and recordings were untouched)."
    elif [[ -e "$command_path" || -L "$command_path" ]]; then
        echo "ERROR: $command_path does not point to this checkout; left untouched." >&2
        return 1
    else
        echo "$COMMAND_NAME is not installed at $command_path."
    fi
}

youtube_command() {
    local action="${1:-status}"
    case "$action" in
        authorize|auth) exec "$HERE/youtube_upload.sh" --authorize ;;
        reauthorize|reauth) exec "$HERE/youtube_upload.sh" --reauthorize ;;
        verify|verify-publications) exec "$HERE/youtube_upload.sh" --verify-publications ;;
        status) exec "$HERE/youtube_upload.sh" --status ;;
        *)
            echo "Unknown YouTube action: $action" >&2
            echo "Use: $COMMAND_NAME youtube [status|authorize|reauthorize|verify]" >&2
            return 2
            ;;
    esac
}

if [[ "${1:-}" == "youtube" ]]; then
    shift
    youtube_command "$@"
fi

# Friendly word-based subcommands; keep the useful existing flags compatible.
case "${1:-}" in
    help) shift; set -- --help "$@" ;;
    install) shift; set -- --install "$@" ;;
    uninstall) shift; set -- --uninstall "$@" ;;
    new) shift; set -- --new "$@" ;;
esac

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --install)
        install_command
        exit 0
        ;;
    --uninstall)
        uninstall_command
        exit 0
        ;;
esac

MIC="${MIC:-default}"   # pulse default source (the FIFINE AM8 on this machine)
MIN_MINUTES="${MIN_MINUTES:-0}"
MIN_SECONDS="$(awk -v m="$MIN_MINUTES" 'BEGIN{printf "%.0f", m*60}')"

# Voice processing. Default is LIGHT: high-pass the desk rumble, gentle
# low-pass, loudness normalize. No denoise, no EQ, no compression, so the mic's
# own sound is kept and never over-processed. make_videos.sh runs with its
# denoise disabled (below), so this is the ONLY processing the voice gets.
#   CLEAN=full   the heavier audio-clean.sh (RNNoise + EQ + compressor)
#   CLEAN=raw    no processing at all, the capture is used as-is
#   CLEAN_PRE_AF=...  override the shared filters before loudness normalization
#   CLEAN_LOUDNORM_I=-13  override the loudnorm target (YouTube standard is -14
#                         LUFS; targeting -13 gives margin since the true-peak
#                         ceiling below still caps it from ever clipping, and
#                         quiet is worse than loud here)
#
# loudnorm runs two-pass (measure, then apply with the measured values):
# single-pass loudnorm only estimates loudness from a short analysis window and
# on this FIFINE AM8 (quiet output level) it was undercorrecting by 6-8 dB
# (measured -22 LUFS on output vs a -16 target), which is why the voice sounded
# too low on YouTube. Two-pass measures the whole file first, so it actually
# hits the target.
CLEAN="${CLEAN:-light}"
source "$HERE/lib/voice-chain.sh"
CLEAN_PRE_AF="${CLEAN_PRE_AF:-$(voice_cleanup_chain)}"
CLEAN_LOUDNORM_I="${CLEAN_LOUDNORM_I:-$VOICE_LOUDNORM_I}"
AUTO_UPLOAD="${AUTO_UPLOAD:-1}"

# Two-pass loudnorm: $1 input wav, $2 output wav. Uses $FFMPEG/$CLEAN_PRE_AF/
# $CLEAN_LOUDNORM_I from the enclosing scope.
two_pass_loudnorm() {
    local in="$1" out="$2" tp="$VOICE_LOUDNORM_TP" lra="$VOICE_LOUDNORM_LRA"
    local measure_af="${CLEAN_PRE_AF},loudnorm=I=${CLEAN_LOUDNORM_I}:TP=${tp}:LRA=${lra}:print_format=json"
    local json; json="$("${FFMPEG[@]}" -hide_banner -nostats -loglevel info -i "$in" -af "$measure_af" -f null - 2>&1)"
    local mi mtp mlra mthresh moffset
    mi="$(printf '%s\n' "$json" | sed -n 's/.*"input_i" *: *"\(-\?[0-9.]*\)".*/\1/p' | head -1)"
    mtp="$(printf '%s\n' "$json" | sed -n 's/.*"input_tp" *: *"\(-\?[0-9.]*\)".*/\1/p' | head -1)"
    mlra="$(printf '%s\n' "$json" | sed -n 's/.*"input_lra" *: *"\(-\?[0-9.]*\)".*/\1/p' | head -1)"
    mthresh="$(printf '%s\n' "$json" | sed -n 's/.*"input_thresh" *: *"\(-\?[0-9.]*\)".*/\1/p' | head -1)"
    moffset="$(printf '%s\n' "$json" | sed -n 's/.*"target_offset" *: *"\(-\?[0-9.]*\)".*/\1/p' | head -1)"
    if [[ -z "$mi" || -z "$mtp" || -z "$mlra" || -z "$mthresh" || -z "$moffset" ]]; then
        echo "two_pass_loudnorm: measure pass failed, falling back to single-pass" >&2
        "${FFMPEG[@]}" -hide_banner -loglevel error -y -i "$in" \
            -af "${CLEAN_PRE_AF},loudnorm=I=${CLEAN_LOUDNORM_I}:TP=${tp}:LRA=${lra}" -ar 48000 "$out"
        return
    fi
    "${FFMPEG[@]}" -hide_banner -loglevel error -y -i "$in" \
        -af "${CLEAN_PRE_AF},loudnorm=I=${CLEAN_LOUDNORM_I}:TP=${tp}:LRA=${lra}:measured_I=${mi}:measured_TP=${mtp}:measured_LRA=${mlra}:measured_thresh=${mthresh}:offset=${moffset}:linear=true" \
        -ar 48000 "$out"
}

VIDEOS_DIR="${VIDEO_BASE_DIR:-$HERE/videos}"
AUDIO_DIR="${AUDIO_DIR:-$VIDEOS_DIR/audio}"
OUTPUT_DIR="${OUTPUT_DIR:-$VIDEOS_DIR/output}"
RAW_DIR="$VIDEOS_DIR/recordings"
RENDER_LOG="$VIDEOS_DIR/render.log"
RENDER_LOCK="$VIDEOS_DIR/.render.lock"
export AUDIO_DIR OUTPUT_DIR

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

video_slug() {
    python3 - "$1" <<'PY'
import re
import sys
import unicodedata

text = unicodedata.normalize("NFKD", sys.argv[1])
text = "".join(c for c in text if not unicodedata.combining(c)).lower()
text = re.sub(r"[^a-z0-9]+", "_", text).strip("_")
print(text or "video")
PY
}

# Short, stable per-video id: first 6 hex of sha256(slug), git-short-SHA style,
# so every published mp4 gets a unique handle you can match a thumbnail to later
# (e.g. b32b11_zona_de_conforto.mp4). It's a pure function of the slug, so a
# re-record or a crash-recovery render of the SAME video reuses the SAME id
# (same filename) and overwrites in place, never leaving a second file that would
# get posted twice. The slug stays in the name too, so even a hash collision
# can't make two different videos collide on one filename.
lesson_id() { printf '%s' "$1" | sha256sum | cut -c1-6; }

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

# Drop any tracked pgid whose process is already gone. Without this,
# freeze_renders could STOP a finished job's now-recycled PID — an unrelated
# process that happens to reuse it — since only thaw_renders used to prune.
prune_dead_renders() {
    (( ${#RENDER_PIDS[@]} )) || return 0
    local p live=()
    for p in "${RENDER_PIDS[@]}"; do
        kill -0 -"$p" 2>/dev/null && live+=("$p")
    done
    RENDER_PIDS=("${live[@]}")
}

freeze_renders() {
    prune_dead_renders
    (( ${#RENDER_PIDS[@]} )) || return 0
    local p
    for p in "${RENDER_PIDS[@]}"; do kill -STOP -"$p" 2>/dev/null || true; done
}

thaw_renders() {
    (( ${#RENDER_PIDS[@]} )) || return 0
    local p
    for p in "${RENDER_PIDS[@]}"; do kill -CONT -"$p" 2>/dev/null || true; done
    prune_dead_renders
}

# A recording in progress freezes every render (see below). If this script
# dies mid-recording — Ctrl-C is the common case — nothing would otherwise
# ever SIGCONT those jobs: they'd sit SIGSTOP'd forever at 0% CPU with no
# parent left to thaw them. The EXIT trap fires even on an uncaught signal
# death, so this guarantees a thaw no matter how the script exits.
trap thaw_renders EXIT

SESSION_RECORDED=0   # takes committed this run, for the summary

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
    local id; id="$(lesson_id "$slug")"
    local final="$OUTPUT_DIR/${id}_${slug}.mp4"
    set -m
    (
        trap '' INT HUP
        renice -n 19 -p "$BASHPID" >/dev/null 2>&1 || true
        command -v ionice >/dev/null 2>&1 && ionice -c3 -p "$BASHPID" >/dev/null 2>&1 || true
        flock 9
        # Another recorder process may have queued recovery for this same wav
        # while its first render was still waiting/running. Re-check only
        # recovery jobs after taking the global lock: a deliberate new take
        # (raw is non-empty) is still allowed to replace an existing render.
        if [[ -z "$raw" && -f "$final" ]]; then
            echo "=== $(date '+%F %T')  skip duplicate recovery $slug (already rendered) ===" >>"$RENDER_LOG"
            exit 0
        fi
        echo "=== $(date '+%F %T')  render $slug ===" >>"$RENDER_LOG"
        clean_ok=1
        if [[ -n "$raw" ]]; then
            {
                case "$CLEAN" in
                    full) "$HERE/audio-clean.sh" "$raw" "$dest" ;;
                    raw)  cp -f "$raw" "$dest" ;;
                    *)    two_pass_loudnorm "$raw" "$dest" ;;
                esac
            } >>"$RENDER_LOG" 2>&1 || clean_ok=0
        fi
        if (( clean_ok )) \
           && rm -f "$OUTPUT_DIR/${slug}.mp4" \
           && VOICE_PROCESSING=0 "$HERE/make_videos.sh" "$slug" >>"$RENDER_LOG" 2>&1 \
           && mv -f "$OUTPUT_DIR/${slug}.mp4" "$final"; then
            echo "    OK $final" >>"$RENDER_LOG"
            notify "Navy Lily" "Rendered: $title"
            if [[ "$AUTO_UPLOAD" == "1" ]]; then
                echo "=== $(date '+%F %T')  upload $slug ===" >>"$RENDER_LOG"
                if YT_OUTPUT_DIR="$OUTPUT_DIR" "$HERE/youtube_upload.sh" \
                    --upload-now "$final" >>"$RENDER_LOG" 2>&1; then
                    notify "Navy Lily" "Uploaded to YouTube: $title"
                else
                    echo "    FAILED upload for $slug (video remains queued)" >>"$RENDER_LOG"
                    notify "Navy Lily" "YOUTUBE UPLOAD FAILED: $title (video is still queued)"
                fi
            fi
        else
            echo "    FAILED render for $slug (see above)" >>"$RENDER_LOG"
            notify "Navy Lily" "RENDER FAILED: $title (see render.log)"
        fi
    ) 9>"$RENDER_LOCK" &
    RENDER_PIDS+=("$!")   # its pgid == its pid; freeze_renders signals the group
    set +m
}

# Resolve MIC=default to the actual pulse source name, so the banner shows which
# device you're really about to record several videos on (e.g. FIFINE, not the
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
        echo "⏳ ${pending} still rendering/uploading in the background — they keep going"
        echo "   even if you close this, and auto-post PRIVATE. Log: $RENDER_LOG"
    fi
    echo "👋"
    exit 0
}

# Every recording is free-form. `new`/`--new` remain accepted for muscle memory,
# but a plain positional argument is now the title.
FREE_TITLE="${*:-}"
if [[ "${1:-}" == "--new" || "${1:-}" == "-n" ]]; then
    shift || true
    FREE_TITLE="${*:-}"
fi

echo "Navy Lily · recorder"
echo "  mic $(resolved_mic) · min ${MIN_MINUTES}m · clean $CLEAN"
if [[ "$AUTO_UPLOAD" == "1" ]] && systemctl --user is-active navylily-youtube.timer >/dev/null 2>&1; then
    echo "  posting  ✓ uploads after each render; timer also watches the queue"
elif [[ "$AUTO_UPLOAD" == "1" ]]; then
    echo "  posting  ✓ uploads after each render (timer fallback is off)"
    echo "           authorize once: $HERE/youtube_upload.sh --authorize"
elif systemctl --user is-active navylily-youtube.timer >/dev/null 2>&1; then
    echo "  posting  ✓ direct upload off; timer watches the queue"
else
    echo "  posting  ✗ OFF: AUTO_UPLOAD=0 and the timer is inactive"
fi

# Self-heal: a cleaned wav with no finished mp4 is an interrupted/failed render
# (crash, disk full, laptop slept mid-render). Re-queue those so a video that
# counts as "recorded" never silently sits un-published. No raw arg => render
# straight from the wav that already exists.
_healed=0
shopt -s nullglob
for _wav in "$AUDIO_DIR"/*.wav; do
    _s="$(basename "$_wav" .wav)"
    _id="$(lesson_id "$_s")"
    # Finished already? Skip if the id-named mp4 exists, OR a legacy slug-named
    # one from before the id scheme (never re-render/re-post those).
    [[ -f "$OUTPUT_DIR/${_id}_${_s}.mp4" || -f "$OUTPUT_DIR/${_s}.mp4" ]] && continue
    _t="$_s"; [[ -f "$OUTPUT_DIR/${_id}_${_s}.title.txt" ]] && _t="$(cat "$OUTPUT_DIR/${_id}_${_s}.title.txt")"
    launch_render "$_s" "$_t"
    _healed=$(( _healed + 1 ))
done
# A raw take whose cleaned wav was never produced (the recorder was killed —
# e.g. Ctrl-C — before launch_render's clean step ran) has no file in
# AUDIO_DIR, so the loop above can't see it: it would otherwise sit in
# recordings/ forever, invisible to every future run. Pick those up too, same
# as a fresh take (raw arg triggers the clean step).
for _raw in "$RAW_DIR"/*.raw.wav; do
    _s="$(basename "$_raw" .raw.wav)"
    _id="$(lesson_id "$_s")"
    [[ -f "$AUDIO_DIR/${_s}.wav" ]] && continue
    [[ -f "$OUTPUT_DIR/${_id}_${_s}.mp4" || -f "$OUTPUT_DIR/${_s}.mp4" ]] && continue
    _t="$_s"; [[ -f "$OUTPUT_DIR/${_id}_${_s}.title.txt" ]] && _t="$(cat "$OUTPUT_DIR/${_id}_${_s}.title.txt")"
    launch_render "$_s" "$_t" "$_raw"
    _healed=$(( _healed + 1 ))
done
shopt -u nullglob
(( _healed > 0 )) && echo "  ↻ re-queued ${_healed} unfinished render(s) from before"
echo

while :; do
    while [[ -z "$FREE_TITLE" ]]; do
        read -r -p "Video title: " FREE_TITLE || exit 0
    done
    title="$FREE_TITLE"
    slug="$(video_slug "$title")"
    FREE_TITLE=""   # next round asks again
    if [[ -f "$OUTPUT_DIR/$(lesson_id "$slug")_${slug}.mp4" || -f "$OUTPUT_DIR/${slug}.mp4" || -f "$AUDIO_DIR/${slug}.wav" ]]; then
        read -r -p "'$slug' already exists. Overwrite it? [y/N] " a || exit 0
        [[ "$a" =~ ^[Yy] ]] || continue
    fi
    echo "────────────────────────────────────────────────────────"
    echo "▶ Video:  $title"
    echo

    raw="$RAW_DIR/${slug}.raw.wav"

    while :; do
        read -r -p "ENTER to record · 's' skip this video · 'q' quit… " _ans || exit 0
        case "${_ans,,}" in
            q|quit) goodbye ;;
            s|skip)
                # Skip for good: remember it so it's never offered again, and
                echo "  ↷ skipped."
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
            if (( MIN_SECONDS > 0 && e < MIN_SECONDS )); then
                printf '\r%-72s' "  ● REC  $(fmt_mmss "$e")   need ${MIN_MINUTES}min, keep going…"
            else
                printf '\r%-72s' "  ● REC  $(fmt_mmss "$e")   press ENTER to stop"
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
            read -r -p "Re-record this video? [Y/n] " a || exit 0
            [[ "$a" =~ ^[Nn] ]] && { echo "Skipping '$title' for now."; break; }
            continue
        fi

        # Length passed, but is it actually audio? Catch a muted mic / wrong
        # pulse source that would otherwise become a dead-air video.
        peak="$(peak_dbfs "$raw")"
        if awk -v p="$peak" -v t="$PEAK_SILENCE_DBFS" 'BEGIN{exit !(p<t)}'; then
            echo "⚠  Peak level ${peak} dBFS is near-silent (threshold ${PEAK_SILENCE_DBFS} dBFS)."
            echo "   The mic may be muted or set to the wrong source. Discarding this take."
            rm -f "$raw"
            read -r -p "Re-record this video? [Y/n] " a || exit 0
            [[ "$a" =~ ^[Nn] ]] && { echo "Skipping '$title' for now."; break; }
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
    # raw file is gone and no audio exists: move on to the next video.
    [[ -f "$raw" ]] || continue

    # Title sidecar next to the eventual mp4 (same id-prefixed basename the mp4
    # will get), so youtube_upload.py posts exactly the title you supplied.
    printf '%s\n' "$title" > "$OUTPUT_DIR/$(lesson_id "$slug")_${slug}.title.txt"

    # Hand off to the background: voice-clean this raw take, then render. You're
    # back at the next prompt instantly; the job runs niced and freezes while you
    # record the next take. Passing "$raw" means "clean it first".
    launch_render "$slug" "$title" "$raw"

    SESSION_RECORDED=$(( SESSION_RECORDED + 1 ))
    if [[ "$AUTO_UPLOAD" == "1" ]]; then
        echo "✓ '$title' saved · rendering, then posting PRIVATE to YouTube"
    else
        echo "✓ '$title' saved · rendering in background · left in the upload queue"
    fi
    echo
    read -r -p "Record another video? [Y/n] " a || exit 0
    [[ "$a" =~ ^[Nn] ]] && goodbye
    echo
done
