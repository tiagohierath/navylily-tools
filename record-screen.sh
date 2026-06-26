#!/usr/bin/env bash
#
# record-screen.sh — record the screen + mic on Hyprland/Wayland, then run the
# mic through the SAME voice cleanup as audio-clean.sh / make_videos.sh and
# produce a YouTube-ready .mp4. Post-the-output-file-straight-to-YouTube simple.
#
# What it does:
#   1. Records the focused monitor with wf-recorder (wlroots screencopy), using
#      Intel VAAPI hardware H.264 encoding so it's light on the CPU, while
#      capturing your default mic into the same raw .mkv.
#   2. You stop it with Ctrl-C (or `q` + Enter).
#   3. AFTER recording, it demuxes the raw mic track and runs it through the
#      shared voice cleanup chain (lib/voice-chain.sh: highpass 80, lowpass 16k,
#      arnndn RNNoise, EQ de-box + presence, acompressor) followed by a two-pass
#      EBU R128 loudnorm to -14 LUFS (YouTube), identical to make_videos.sh.
#   4. Remuxes the cleaned audio over the video with -c:v copy (video is NEVER
#      re-encoded) → videos/output/<name>.mp4 (+faststart). The raw .mkv is kept.
#
# Output:
#   videos/recordings/recording-<timestamp>.mkv   raw (kept)
#   videos/output/recording-<timestamp>.mp4       final, upload this to YouTube
#
# Usage:
#   ./record-screen.sh                 # record focused monitor
#   ./record-screen.sh my-lesson       # name it -> ...my-lesson.mp4
#   MONITOR=DP-1 ./record-screen.sh    # force a specific output
#   MIC="alsa_input.usb-..." ./record-screen.sh   # force a specific mic source
#
# ── NixOS ────────────────────────────────────────────────────────────────────
#   Needs wf-recorder + ffmpeg (with the arnndn filter). Nothing is installed
#   system-wide: if any tool is missing the script re-execs itself inside
#   `nix shell nixpkgs#wf-recorder nixpkgs#ffmpeg` automatically. A leaked
#   LD_LIBRARY_PATH is stripped first (it breaks nix binaries with
#   GLIBC_ABI_DT_X86_64_PLT errors).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BASE_DIR="${VIDEO_BASE_DIR:-$HERE/videos}"
OUTPUT_DIR="$BASE_DIR/output"          # final mp4 — same place make_videos.sh uses
RAW_DIR="$BASE_DIR/recordings"         # raw mkv recordings (kept)

# YouTube loudness target (EBU R128, two-pass). Same as make_videos.sh.
LOUDNORM_I="${LOUDNORM_I:--14}"
LOUDNORM_TP="${LOUDNORM_TP:--1.5}"
LOUDNORM_LRA="${LOUDNORM_LRA:-11}"

# VAAPI render node for Intel hardware H.264 encoding. Override or set HWENC=0
# to fall back to software x264 (more CPU, but no GPU needed).
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"
HWENC="${HWENC:-1}"

# Monitor to capture (wf-recorder -o). Empty = auto-detect the focused output
# via hyprctl. Override with MONITOR=DP-1 etc.
MONITOR="${MONITOR:-}"

# Mic source. Empty = wf-recorder's default audio device (-a with no value).
# Override with the PipeWire/Pulse source name (pactl list short sources).
MIC="${MIC:-}"

# Shared voice-cleanup filter chain — kept in sync with audio-clean.sh and
# make_videos.sh so the cleanup never drifts.
source "$HERE/lib/voice-chain.sh"

# ---------------------------------------------------------------------------
# Ensure wf-recorder + an arnndn-capable ffmpeg are available; re-exec inside
# nix's copies if not (same pattern as the other scripts).
# ---------------------------------------------------------------------------
_need_nix=0; _need_reason=""
if ! command -v wf-recorder >/dev/null 2>&1; then
    _need_nix=1; _need_reason="wf-recorder not found on PATH"
elif ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    _need_nix=1; _need_reason="ffmpeg/ffprobe not found on PATH"
elif ! voice_ffmpeg_has_arnndn; then
    _need_nix=1; _need_reason="audio cleaning needs the arnndn filter, missing from this ffmpeg"
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

# RNNoise model must exist (arnndn fails without it).
if [[ ! -f "$VOICE_RNNOISE_MODEL" ]]; then
    echo "RNNoise model not found: $VOICE_RNNOISE_MODEL" >&2
    echo "Restore models/sh.rnnn, or set RNNOISE_MODEL=/path/to/model.rnnn." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR" "$RAW_DIR"

# ---------------------------------------------------------------------------
# Pick the monitor to record. wf-recorder needs an output name; default to the
# focused one from Hyprland.
# ---------------------------------------------------------------------------
if [[ -z "$MONITOR" ]] && command -v hyprctl >/dev/null 2>&1; then
    # Focused monitor: the one with focused:true. Parse without jq (not assumed).
    MONITOR="$(hyprctl monitors -j 2>/dev/null \
        | tr -d '\n' \
        | grep -oE '\{[^{}]*"focused": *true[^{}]*\}' \
        | grep -oE '"name": *"[^"]*"' | head -n1 \
        | sed -E 's/.*"name": *"([^"]*)".*/\1/')" || true
    # Fall back to the first monitor name if focus parsing turned up nothing.
    if [[ -z "$MONITOR" ]]; then
        MONITOR="$(hyprctl monitors -j 2>/dev/null | grep -oE '"name": *"[^"]*"' | head -n1 | sed -E 's/.*"([^"]*)".*/\1/')" || true
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
final="$OUTPUT_DIR/${name}.mp4"

# ---------------------------------------------------------------------------
# Build the wf-recorder command. VAAPI hw H.264 by default (Intel UHD), with a
# software x264 fallback. Mic captured into the same file via -a.
# ---------------------------------------------------------------------------
rec_cmd=(wf-recorder -f "$raw")
[[ -n "$MONITOR" ]] && rec_cmd+=(-o "$MONITOR")
if [[ "$HWENC" == "1" && -e "$VAAPI_DEVICE" ]]; then
    rec_cmd+=(-c h264_vaapi -d "$VAAPI_DEVICE")
fi
# Audio: -a with the source name, or bare -a for the default device.
if [[ -n "$MIC" ]]; then
    rec_cmd+=(--audio="$MIC")
else
    rec_cmd+=(-a)
fi

echo "================================================================"
echo " Recording monitor : ${MONITOR:-<wf-recorder default>}"
echo " Mic source        : ${MIC:-<default>}"
echo " Encoder           : $([[ "$HWENC" == "1" && -e "$VAAPI_DEVICE" ]] && echo "VAAPI h264 ($VAAPI_DEVICE)" || echo "software x264")"
echo " Raw file          : $raw"
echo " Final (YouTube)   : $final"
echo "----------------------------------------------------------------"
echo " ▶ Recording... press Ctrl-C (or 'q' then Enter) to STOP."
echo "================================================================"

# ---------------------------------------------------------------------------
# Record. We DON'T want Ctrl-C to abort the script before post-processing — it
# should just stop wf-recorder and let it finalize the file.
#
# `set -m` runs wf-recorder in its OWN process group, so the terminal's Ctrl-C
# is NOT delivered to it directly — only our trap forwards a single, clean
# SIGINT, which lets it flush and finalize the mkv exactly once. (Without this,
# job control is off and the bg job shares our process group, so it would get
# BOTH the tty's SIGINT and our kill — a redundant double-signal racing the
# shutdown.)
# ---------------------------------------------------------------------------
set -m
"${rec_cmd[@]}" &
rec_pid=$!
set +m

stop_recording() {
    # wf-recorder flushes and finalizes the mkv on SIGINT.
    kill -INT "$rec_pid" 2>/dev/null || true
}
trap 'stop_recording' INT TERM

# Also allow stopping by typing q + Enter (handy if Ctrl-C is awkward).
( while read -r key; do [[ "$key" == "q" ]] && { stop_recording; break; }; done ) &
reader_pid=$!

# Wait for the recorder to FULLY exit. A trapped Ctrl-C interrupts `wait` while
# wf-recorder is still finalizing the mkv, so a single `wait` would return early
# and we'd race post-processing against a half-written file. Loop until the
# process is really gone.
while kill -0 "$rec_pid" 2>/dev/null; do
    wait "$rec_pid" 2>/dev/null || true
done
kill "$reader_pid" 2>/dev/null || true
trap - INT TERM

if [[ ! -s "$raw" ]]; then
    echo "ERROR: no recording was produced ($raw is missing/empty)." >&2
    exit 1
fi
echo ""
echo "Recording stopped. Raw saved: $raw"

# Scratch dir for the post-processing intermediates + ffmpeg logs.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Run ffmpeg quietly, but on failure print its captured output and bail with a
# clear message instead of dying silently. The raw recording is always kept, so
# nothing is lost — the user can fix the issue and re-run.
run_ffmpeg() {
    local log="$work/ffmpeg.log"
    if ! ffmpeg "$@" >"$log" 2>&1; then
        echo "" >&2
        echo "ERROR: ffmpeg failed:" >&2
        cat "$log" >&2
        echo "" >&2
        echo "Your raw recording is safe at: $raw" >&2
        echo "Fix the issue and re-run, or process it by hand." >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Does the raw actually have an audio track? (No mic / muted source -> none.)
# ---------------------------------------------------------------------------
has_audio="$(ffprobe -v error -select_streams a -show_entries stream=index \
    -of csv=p=0 "$raw" 2>/dev/null | head -n1)" || true

if [[ -z "$has_audio" ]]; then
    echo "WARNING: no audio track in the recording — muxing video only." >&2
    run_ffmpeg -y -i "$raw" -map 0:v:0 -c:v copy -movflags +faststart "$final"
    echo "Done -> $final"
    exit 0
fi

# ---------------------------------------------------------------------------
# Clean the mic: shared cleanup chain baked into an intermediate wav FIRST, then
# two-pass EBU R128 loudnorm on that fixed signal (RNNoise runs once; both passes
# measure/apply against an identical signal). Same approach as make_videos.sh.
# ---------------------------------------------------------------------------
clean="$work/clean.wav"
echo "Cleaning mic (RNNoise denoise + EQ + compression)..."
run_ffmpeg -y -i "$raw" -map 0:a:0 -af "$(voice_cleanup_chain)" \
    -ar 48000 -ac 2 -c:a pcm_s16le "$clean"

echo "Measuring loudness (pass 1/2)..."
measured="$(ffmpeg -hide_banner -i "$clean" \
    -af "loudnorm=I=${LOUDNORM_I}:TP=${LOUDNORM_TP}:LRA=${LOUDNORM_LRA}:print_format=json" \
    -f null - 2>&1 | awk '/^\{/{c=1} c{print} /^\}/{c=0}')" || true

mi="$(awk -F'"' '/input_i/{print $4}' <<<"$measured")"
mtp="$(awk -F'"' '/input_tp/{print $4}' <<<"$measured")"
mlra="$(awk -F'"' '/input_lra/{print $4}' <<<"$measured")"
mthresh="$(awk -F'"' '/input_thresh/{print $4}' <<<"$measured")"

ln="loudnorm=I=${LOUDNORM_I}:TP=${LOUDNORM_TP}:LRA=${LOUDNORM_LRA}"
if [[ -n "$mi" && -n "$mtp" && -n "$mlra" && -n "$mthresh" ]]; then
    ln="${ln}:measured_I=${mi}:measured_TP=${mtp}:measured_LRA=${mlra}:measured_thresh=${mthresh}:linear=true"
fi

norm="$work/audio_norm.wav"
echo "Applying loudness (pass 2/2)..."
run_ffmpeg -y -i "$clean" -af "$ln" -ar 48000 -ac 2 -c:a pcm_s16le "$norm"

# ---------------------------------------------------------------------------
# Remux: video copied (never re-encoded), cleaned audio encoded to AAC 320k,
# +faststart for streaming. -shortest guards against tiny track-length drift.
# ---------------------------------------------------------------------------
echo "Muxing (video copied, audio encoded)..."
tmp_out="$work/final.mp4"
run_ffmpeg -y -i "$raw" -i "$norm" \
    -map 0:v:0 -map 1:a:0 \
    -c:v copy -c:a aac -b:a 320k -shortest \
    -movflags +faststart \
    "$tmp_out"

mv -f "$tmp_out" "$final"
echo ""
echo "Done. Upload this to YouTube:"
echo "  $final"
echo "Raw kept at:"
echo "  $raw"
