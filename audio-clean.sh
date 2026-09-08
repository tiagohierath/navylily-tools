#!/usr/bin/env bash
#
# audio-clean.sh — deterministic "broadcast-ish" voice cleanup for a FIFINE
# (or any) USB mic. Record raw, then run this and you always get a consistent,
# platform-ready voice file.
#
# Chain: light denoise, 80 Hz high-pass, subtle corrective EQ, 3:1 compressor,
# gentle de-esser, -1 dB limiter, then -14 LUFS normalization.
#
# Usage:
#   ./audio-clean.sh raw.wav final.wav
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

# Keep this usable on the repository's declarative/NixOS setup even when ffmpeg
# is not in the caller's PATH. Nothing is installed system-wide.
if ! command -v ffmpeg >/dev/null 2>&1; then
    if command -v nix >/dev/null 2>&1; then
        echo "ffmpeg not found — re-executing inside 'nix shell nixpkgs#ffmpeg' ..."
        exec env -u LD_LIBRARY_PATH nix shell nixpkgs#ffmpeg --command bash "$0" "$@"
    elif command -v nix-shell >/dev/null 2>&1; then
        echo "ffmpeg not found — re-executing inside 'nix-shell -p ffmpeg' ..."
        exec env -u LD_LIBRARY_PATH nix-shell -p ffmpeg --run "$(printf '%q ' bash "$0" "$@")"
    else
        echo "ERROR: ffmpeg not found, and nix is unavailable to provide it." >&2
        exit 1
    fi
fi

echo "Cleaning : $INPUT"
echo "Output   : $OUTPUT"
echo "Voice FX : $(voice_cleanup_chain)"

# Shared cleanup chain + a single-pass YouTube loudness normalization.
# NOTE: loudnorm internally upsamples to 192 kHz for its true-peak limiter and
# does NOT come back down on its own, so we pin the output to 48 kHz with -ar
# (otherwise every file lands at a bloated 192 kHz).
ffmpeg -y -i "$INPUT" \
    -af "$(voice_full_chain)" \
    -ar 48000 "$OUTPUT"

echo "Done -> $OUTPUT"
