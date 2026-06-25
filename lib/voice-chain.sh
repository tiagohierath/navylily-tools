# voice-chain.sh — the shared "voice cleanup" ffmpeg filter chain: everything
# BEFORE loudness normalization. Sourced by both audio-clean.sh and
# make_videos.sh so the denoise / EQ / compression stay identical in both and
# never drift. Each caller appends its own loudnorm afterwards:
#   audio-clean.sh -> loudnorm I=-16 (single pass, podcast-ish)
#   make_videos.sh -> loudnorm I=-14 (two-pass, YouTube)
#
# Stages: highpass 80 (rumble) - lowpass 16k (hiss ceiling) - arnndn (RNNoise
# denoise, needs a .rnnn model) - eq -2dB@250 (de-box) - eq +2dB@3500
# (presence) - acompressor (even dynamics).

# Repo root = parent of this lib/ dir.
_VOICE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# RNNoise model (override with RNNOISE_MODEL=/path/to/model.rnnn).
VOICE_RNNOISE_MODEL="${RNNOISE_MODEL:-$_VOICE_ROOT/models/sh.rnnn}"

# Echo the cleanup filter chain — no loudnorm, no trailing comma. Append your
# own loudnorm after it, e.g.  "$(voice_cleanup_chain),loudnorm=I=-14:..."
voice_cleanup_chain() {
    printf '%s' \
"highpass=f=80,lowpass=f=16000,arnndn=m='${VOICE_RNNOISE_MODEL}',equalizer=f=250:t=q:w=1:g=-2,equalizer=f=3500:t=q:w=1:g=2,acompressor=threshold=-18dB:ratio=3:attack=5:release=100"
}

# True if ffmpeg (arg 1, or the one on PATH) has the arnndn filter.
# NOTE: capture the output and string-match instead of piping to `grep -q`.
# `grep -q` closes the pipe on first match (arnndn sorts early in -filters), which
# SIGPIPEs ffmpeg; under `set -o pipefail` that would falsely report "missing"
# and, in make_videos.sh, cause an infinite nix re-exec loop.
voice_ffmpeg_has_arnndn() {
    local out
    out="$("${1:-ffmpeg}" -hide_banner -filters 2>/dev/null)" || true
    [[ "$out" == *arnndn* ]]
}
