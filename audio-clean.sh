#!/usr/bin/env bash
#
# audio-clean.sh — deterministic "broadcast-ish" voice cleanup for a FIFINE
# (or any) USB mic. Record raw, then run this and you always get a consistent,
# platform-ready voice file.
#
# Chain (in order):
#   highpass 80      remove low rumble / desk & handling thumps
#   lowpass 16000    shave the harsh hiss ceiling
#   arnndn           RNNoise neural noise suppression (needs a .rnnn model)
#   eq 250 -2dB      tame boxy mids (small room "honk")
#   eq 3500 +2dB     lift speech presence / intelligibility
#   acompressor      even out the dynamics
#   loudnorm -16     normalize to podcast/YouTube loudness (EBU R128)
#
# Usage:
#   ./audio-clean.sh raw.wav final.wav
#
# Model: defaults to the bundled models/sh.rnnn (somnolent-hogwash — trained for
# recorded speech). Override with:  RNNOISE_MODEL=/path/to/model.rnnn ./audio-clean.sh ...
#
# NixOS note: the stock system ffmpeg here is built WITHOUT the arnndn filter, so
# if arnndn is missing this script re-execs itself inside `nix shell nixpkgs#ffmpeg`
# (which has it). Nothing is installed system-wide. A leaked LD_LIBRARY_PATH is
# stripped first (it breaks nix binaries with GLIBC_ABI_DT_X86_64_PLT errors).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT="${1:-}"
OUTPUT="${2:-}"
if [[ -z "$INPUT" || -z "$OUTPUT" ]]; then
    echo "Usage: $(basename "$0") <input> <output>   e.g.  $(basename "$0") raw.wav final.wav" >&2
    exit 1
fi
if [[ ! -f "$INPUT" ]]; then
    echo "Input file not found: $INPUT" >&2
    exit 1
fi

# The denoise/EQ/compression chain is shared with make_videos.sh (one source of
# truth), so the cleanup is identical whether you run this standalone or render
# straight to a video.
source "$HERE/lib/voice-chain.sh"

# RNNoise model (the original chain was missing this — arnndn fails without it).
if [[ ! -f "$VOICE_RNNOISE_MODEL" ]]; then
    echo "RNNoise model not found: $VOICE_RNNOISE_MODEL" >&2
    echo "Restore models/sh.rnnn, or set RNNOISE_MODEL=/path/to/model.rnnn." >&2
    exit 1
fi

# Need an ffmpeg that actually has the arnndn filter. The stock NixOS system
# ffmpeg often doesn't, so re-exec inside nix's ffmpeg if it's missing.
if ! voice_ffmpeg_has_arnndn; then
    if command -v nix >/dev/null 2>&1; then
        echo "This ffmpeg has no arnndn filter — re-executing inside 'nix shell nixpkgs#ffmpeg' ..."
        exec env -u LD_LIBRARY_PATH nix shell nixpkgs#ffmpeg --command bash "$0" "$@"
    else
        echo "ERROR: ffmpeg lacks the 'arnndn' filter and nix is unavailable to provide one." >&2
        exit 1
    fi
fi

echo "Cleaning : $INPUT"
echo "Output   : $OUTPUT"
echo "RNNoise  : $VOICE_RNNOISE_MODEL"

# Shared cleanup chain + a single-pass loudnorm to -16 (podcast-ish).
# NOTE: loudnorm internally upsamples to 192 kHz for its true-peak limiter and
# does NOT come back down on its own, so we pin the output to 48 kHz with -ar
# (otherwise every file lands at a bloated 192 kHz).
ffmpeg -y -i "$INPUT" \
    -af "$(voice_cleanup_chain),loudnorm=I=-16:TP=-1.5:LRA=11" \
    -ar 48000 "$OUTPUT"

echo "Done -> $OUTPUT"
