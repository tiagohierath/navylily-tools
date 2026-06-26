#!/usr/bin/env bash
#
# record-screen.sh — record the screen + mic (+ optional system/desktop audio)
# on Hyprland/Wayland, then mux the audio and produce a YouTube-ready .mp4.
# Built for talking over song snippets: the audio is left UNPROCESSED and the
# music simply sits a bit under your voice in the mix.
# Post-the-output-file-straight-to-YouTube simple.
#
# What it does:
#   1. Records the focused monitor with wf-recorder (wlroots screencopy), using
#      Intel VAAPI hardware H.264 encoding so it's light on the CPU, capturing
#      your mic into the raw .mkv. In parallel pw-record captures the system
#      output (default sink monitor) into a separate raw .wav.
#   2. You stop it with Ctrl-C (or `q` + Enter); both captures finalize.
#   3. AFTER recording, the audio is NOT processed at all — no denoise, EQ,
#      highpass, compression or loudness normalization. Voice and system audio
#      are used exactly as captured.
#   4. Mixes the music a bit UNDER the voice (SYS_GAIN_DB, normalize=0 so the
#      voice stays at full level) and muxes over the video with -c:v copy (video
#      is NEVER re-encoded) → videos/output/<name>.mp4 (+faststart). Raws kept.
#
# Output:
#   videos/recordings/recording-<timestamp>.mkv          raw video+mic (kept)
#   videos/recordings/recording-<timestamp>.system.wav   raw system audio (kept)
#   videos/output/recording-<timestamp>.mp4              final, upload to YouTube
#
# Usage:
#   ./record-screen.sh                 # record focused monitor + mic + system
#   ./record-screen.sh my-lesson       # name it -> ...my-lesson.mp4
#   MONITOR=DP-1 ./record-screen.sh    # force a specific output
#   MIC="alsa_input.usb-..." ./record-screen.sh   # force a specific mic source
#   SYSTEM=0 ./record-screen.sh        # mic only, no system audio
#   SYS_GAIN_DB=-12 ./record-screen.sh # push the music further under the voice
#
# ── NixOS ────────────────────────────────────────────────────────────────────
#   Needs wf-recorder + ffmpeg; system audio also needs
#   pw-record (ships with PipeWire, already on PATH here). Nothing is installed
#   system-wide: if wf-recorder/ffmpeg are missing the script re-execs itself
#   inside `nix shell nixpkgs#wf-recorder nixpkgs#ffmpeg` automatically (the
#   system pw-record stays reachable through the inherited PATH). A leaked
#   LD_LIBRARY_PATH is stripped first (it breaks nix binaries with
#   GLIBC_ABI_DT_X86_64_PLT errors).
#
set -euo pipefail

# Resolve this script's REAL directory, following symlinks, so it works when
# invoked via a symlink on PATH from any directory — lib/, models/ and videos/
# all resolve to the repo, not to the symlink's location (e.g. ~/.local/bin).
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BASE_DIR="${VIDEO_BASE_DIR:-$HERE/videos}"
OUTPUT_DIR="$BASE_DIR/output"          # final mp4 — same place make_videos.sh uses
RAW_DIR="$BASE_DIR/recordings"         # raw mkv recordings (kept)

# VAAPI render node for Intel hardware H.264 encoding. Override or set HWENC=0
# to fall back to software x264 (more CPU, but no GPU needed).
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"
HWENC="${HWENC:-1}"

# Monitor to capture (wf-recorder -o). Empty = auto-detect the focused output
# via hyprctl. Override with MONITOR=DP-1 etc.
MONITOR="${MONITOR:-}"

# Mic source. Empty = wf-recorder's default audio device (-a with no value).
# Override with the PipeWire/Pulse source name (wpctl status / pw-cli ls Node).
MIC="${MIC:-}"

# ── System / desktop audio (e.g. song snippets you talk over) ────────────────
# Captured separately with pw-record from the default sink's monitor, used
# unprocessed and mixed a bit UNDER your voice.
SYSTEM="${SYSTEM:-1}"               # 0 = mic only, no system audio
# How far under the voice the music sits, in dB. "A bit lower" — present but
# secondary; more negative = quieter music.
SYS_GAIN_DB="${SYS_GAIN_DB:--8}"
# Override the system-audio source (a PipeWire node name/id). Empty = the default
# sink's monitor via pw-record's stream.capture.sink property.
SYSTEM_AUDIO="${SYSTEM_AUDIO:-}"
# The audio is NOT processed: no denoise, EQ, highpass, compression or loudness
# normalization. Voice and system audio are used exactly as captured and only
# mixed (the music ducked SYS_GAIN_DB under the voice).

# ---------------------------------------------------------------------------
# Ensure wf-recorder + ffmpeg are available; re-exec inside nix's copies if not
# (same pattern as the other scripts).
# ---------------------------------------------------------------------------
_need_nix=0; _need_reason=""
if ! command -v wf-recorder >/dev/null 2>&1; then
    _need_nix=1; _need_reason="wf-recorder not found on PATH"
elif ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    _need_nix=1; _need_reason="ffmpeg/ffprobe not found on PATH"
fi
if [[ "$_need_nix" == "1" ]]; then
    if command -v nix >/dev/null 2>&1; then
        echo "$_need_reason — re-executing inside 'nix shell nixpkgs#wf-recorder nixpkgs#ffmpeg' ..."
        exec env -u LD_LIBRARY_PATH nix shell nixpkgs#wf-recorder nixpkgs#ffmpeg --command bash "$0" "$@"
    elif command -v nix-shell >/dev/null 2>&1; then
        echo "$_need_reason — re-executing inside nix-shell ..."
        exec env -u LD_LIBRARY_PATH nix-shell -p wf-recorder ffmpeg --run "bash '$0' $*"
    else
        echo "ERROR: $_need_reason, and nix is unavailable to fetch the tools." >&2
        exit 1
    fi
fi

mkdir -p "$OUTPUT_DIR" "$RAW_DIR"

# ---------------------------------------------------------------------------
# Pick the monitor to record. wf-recorder needs an output name; default to the
# focused one from Hyprland.
# ---------------------------------------------------------------------------
if [[ -z "$MONITOR" ]] && command -v hyprctl >/dev/null 2>&1; then
    # Focused monitor = the block in `hyprctl monitors` that says "focused: yes".
    # Parsed from the text output (robust; no jq, and no fragile JSON regex that
    # trips over hyprctl's nested objects).
    MONITOR="$(hyprctl monitors 2>/dev/null | awk '/^Monitor /{m=$2} /focused: yes/{print m; exit}')" || true
    # Fall back to the first monitor if focus parsing turned up nothing.
    if [[ -z "$MONITOR" ]]; then
        MONITOR="$(hyprctl monitors 2>/dev/null | awk '/^Monitor /{print $2; exit}')" || true
    fi
fi

# ---------------------------------------------------------------------------
# Filenames
# ---------------------------------------------------------------------------
ts="$(date +%Y%m%d-%H%M%S)"
name="${1:-}"
if [[ -n "$name" ]]; then
    name="recording-${ts}-${name}"
else
    name="recording-${ts}"
fi
raw="$RAW_DIR/${name}.mkv"
sysraw="$RAW_DIR/${name}.system.wav"
final="$OUTPUT_DIR/${name}.mp4"

# ---------------------------------------------------------------------------
# Scratch dir + helpers (set up before recording so the system-audio capture
# can log here too).
# ---------------------------------------------------------------------------
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Run ffmpeg quietly, but on failure print its captured output and bail with a
# clear message instead of dying silently. The raws are always kept, so nothing
# is lost — fix the issue and re-run, or process by hand.
run_ffmpeg() {
    local log="$work/ffmpeg.log"
    if ! ffmpeg "$@" >"$log" 2>&1; then
        echo "" >&2
        echo "ERROR: ffmpeg failed:" >&2
        cat "$log" >&2
        echo "" >&2
        echo "Your raw recording is safe at: $raw" >&2
        [[ -s "$sysraw" ]] && echo "Raw system audio at: $sysraw" >&2
        echo "Fix the issue and re-run, or process it by hand." >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Build the wf-recorder command. VAAPI hw H.264 by default (Intel UHD), with a
# software x264 fallback. Mic captured into the same file via -a.
# ---------------------------------------------------------------------------
# Use VAAPI hw H.264 only if the device exists AND a working VAAPI driver can
# actually spin up an h264_vaapi encoder. On NixOS the Intel driver is often
# missing (add intel-media-driver to hardware.graphics.extraPackages), and
# trying to encode without it makes wf-recorder die outright — so probe with a
# tiny throwaway encode first and fall back to software x264 instead of crashing.
use_vaapi=0
if [[ "$HWENC" == "1" && -e "$VAAPI_DEVICE" ]]; then
    if ffmpeg -hide_banner -loglevel error -y \
            -vaapi_device "$VAAPI_DEVICE" \
            -f lavfi -i color=c=black:s=64x64:d=0.1 \
            -vf 'format=nv12,hwupload' -c:v h264_vaapi -f null - >/dev/null 2>&1; then
        use_vaapi=1
    else
        echo "WARNING: VAAPI hw encoding unavailable on $VAAPI_DEVICE (no working driver)" >&2
        echo "         — using software x264. Install intel-media-driver for HW accel." >&2
    fi
fi

rec_cmd=(wf-recorder -f "$raw")
[[ -n "$MONITOR" ]] && rec_cmd+=(-o "$MONITOR")
if [[ "$use_vaapi" == "1" ]]; then
    rec_cmd+=(-c h264_vaapi -d "$VAAPI_DEVICE")
fi
# Audio: -a with the source name, or bare -a for the default device.
if [[ -n "$MIC" ]]; then
    rec_cmd+=(--audio="$MIC")
else
    rec_cmd+=(-a)
fi

# ---------------------------------------------------------------------------
# Build the system-audio capture (pw-record from the default sink's monitor).
# stream.capture.sink=true makes the capture stream pull from the output sink's
# monitor (i.e. what you hear) rather than the mic. Disabled if SYSTEM=0 or
# pw-record is unavailable — recording then falls back to mic only.
# ---------------------------------------------------------------------------
capture_system=0
sys_cmd=()
if [[ "$SYSTEM" == "1" ]]; then
    if command -v pw-record >/dev/null 2>&1; then
        capture_system=1
        sys_cmd=(pw-record --rate 48000 --channels 2 --format s16)
        if [[ -n "$SYSTEM_AUDIO" ]]; then
            sys_cmd+=(--target "$SYSTEM_AUDIO")
        else
            sys_cmd+=(--properties '{ stream.capture.sink=true }')
        fi
        sys_cmd+=("$sysraw")
    else
        echo "WARNING: pw-record not found — recording mic only (no system audio)." >&2
    fi
fi

echo "================================================================"
echo " Recording monitor : ${MONITOR:-<wf-recorder default>}"
echo " Mic source        : ${MIC:-<default>}"
echo " System audio      : $([[ "$capture_system" == "1" ]] && echo "${SYSTEM_AUDIO:-default sink monitor} (mixed ${SYS_GAIN_DB} dB under voice)" || echo "off")"
echo " Encoder           : $([[ "$use_vaapi" == "1" ]] && echo "VAAPI h264 ($VAAPI_DEVICE)" || echo "software x264")"
echo " Raw file          : $raw"
echo " Final (YouTube)   : $final"
echo "----------------------------------------------------------------"
echo " ▶ Recording... press Ctrl-C (or 'q' then Enter) to STOP."
echo "================================================================"

# ---------------------------------------------------------------------------
# Record. Ctrl-C should NOT abort the script before post-processing — it should
# just stop the captures and let them finalize their files.
#
# Each capture runs in its OWN process group (set -m), so the terminal's Ctrl-C
# is NOT delivered to it directly — our trap forwards a single, clean SIGINT to
# each, which lets them flush and finalize their files exactly once. (Without
# this, job control is off and the bg jobs share our process group, so they'd
# get BOTH the tty's SIGINT and our kill — a redundant double-signal racing the
# shutdown.)
# ---------------------------------------------------------------------------
rec_pids=()
set -m
"${rec_cmd[@]}" &
rec_pids+=("$!")
if [[ "$capture_system" == "1" ]]; then
    "${sys_cmd[@]}" >"$work/pw-record.log" 2>&1 &
    rec_pids+=("$!")
fi
set +m

stop_recording() {
    # wf-recorder finalizes the mkv and pw-record closes the wav on SIGINT.
    local p
    for p in "${rec_pids[@]}"; do kill -INT "$p" 2>/dev/null || true; done
}
trap 'stop_recording' INT TERM

# Also allow stopping by typing q + Enter (handy if Ctrl-C is awkward).
( while read -r key; do [[ "$key" == "q" ]] && { stop_recording; break; }; done ) &
reader_pid=$!

# Wait for every capture to FULLY exit. A trapped Ctrl-C interrupts `wait` while
# a capture is still finalizing its file, so a single `wait` would return early
# and we'd race post-processing against a half-written file. Loop until each
# process is really gone.
for p in "${rec_pids[@]}"; do
    while kill -0 "$p" 2>/dev/null; do
        wait "$p" 2>/dev/null || true
    done
done
kill "$reader_pid" 2>/dev/null || true
trap - INT TERM

if [[ ! -s "$raw" ]]; then
    echo "ERROR: no recording was produced ($raw is missing/empty)." >&2
    exit 1
fi
echo ""
echo "Recording stopped."
echo "  raw video+mic : $raw"
[[ -s "$sysraw" ]] && echo "  raw system    : $sysraw"

# ---------------------------------------------------------------------------
# What audio did we actually capture?
#   voice = mic track inside the mkv (wf-recorder)
#   music = system/desktop audio captured separately by pw-record
# ---------------------------------------------------------------------------
voice_wav=""
music_wav=""

has_mic="$(ffprobe -v error -select_streams a -show_entries stream=index \
    -of csv=p=0 "$raw" 2>/dev/null | head -n1)" || true
has_sys=""
if [[ -s "$sysraw" ]]; then
    has_sys="$(ffprobe -v error -select_streams a -show_entries stream=index \
        -of csv=p=0 "$sysraw" 2>/dev/null | head -n1)" || true
fi

# ---- Voice: no processing — just extract the mic track to a uniform wav ------
if [[ -n "$has_mic" ]]; then
    voice_wav="$work/voice.wav"
    echo "Extracting voice (no processing)..."
    run_ffmpeg -y -i "$raw" -map 0:a:0 -ar 48000 -ac 2 -c:a pcm_s16le "$voice_wav"
else
    echo "No mic track in the recording — skipping voice." >&2
fi

# ---- Music: no processing — just transcode the system capture to a uniform wav
if [[ -n "$has_sys" ]]; then
    music_wav="$work/music.wav"
    echo "Extracting system audio (no processing)..."
    run_ffmpeg -y -i "$sysraw" -ar 48000 -ac 2 -c:a pcm_s16le "$music_wav"
fi

# ---------------------------------------------------------------------------
# Mux: video copied (never re-encoded), audio encoded to AAC 320k, +faststart.
# When both voice and music are present, the music is ducked SYS_GAIN_DB under
# the voice and amix runs with normalize=0 so the voice stays at full level.
# -shortest trims to the (copied) video length.
# ---------------------------------------------------------------------------
echo "Muxing (video copied, audio encoded)..."
tmp_out="$work/final.mp4"
if [[ -n "$voice_wav" && -n "$music_wav" ]]; then
    sys_vol="$(awk -v g="$SYS_GAIN_DB" 'BEGIN{printf "%.6f", 10^(g/20)}')"
    run_ffmpeg -y -i "$raw" -i "$voice_wav" -i "$music_wav" \
        -filter_complex "[2:a]volume=${sys_vol}[m];[1:a][m]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0[a]" \
        -map 0:v:0 -map "[a]" \
        -c:v copy -c:a aac -b:a 320k -shortest -movflags +faststart "$tmp_out"
elif [[ -n "$voice_wav" ]]; then
    run_ffmpeg -y -i "$raw" -i "$voice_wav" \
        -map 0:v:0 -map 1:a:0 \
        -c:v copy -c:a aac -b:a 320k -shortest -movflags +faststart "$tmp_out"
elif [[ -n "$music_wav" ]]; then
    run_ffmpeg -y -i "$raw" -i "$music_wav" \
        -map 0:v:0 -map 1:a:0 \
        -c:v copy -c:a aac -b:a 320k -shortest -movflags +faststart "$tmp_out"
else
    echo "WARNING: no usable audio — muxing video only." >&2
    run_ffmpeg -y -i "$raw" -map 0:v:0 -c:v copy -movflags +faststart "$tmp_out"
fi

mv -f "$tmp_out" "$final"
echo ""
echo "Done. Upload this to YouTube:"
echo "  $final"
echo "Raws kept at:"
echo "  $raw"
[[ -s "$sysraw" ]] && echo "  $sysraw"
