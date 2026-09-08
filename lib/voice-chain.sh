# Shared conservative FIFINE AM8 narration chain. Loudness normalization stays
# separate because some callers mix system audio after processing the voice.
VOICE_DENOISE="${VOICE_DENOISE-afftdn=nr=6:nf=-50}"
VOICE_LOUDNORM_I="${VOICE_LOUDNORM_I:--14}"
VOICE_LOUDNORM_TP="${VOICE_LOUDNORM_TP:--1}"
VOICE_LOUDNORM_LRA="${VOICE_LOUDNORM_LRA:-11}"

# light denoise -> high-pass -> corrective EQ -> compressor -> de-esser ->
# -1 dB peak limiter. EQ moves are intentionally small and easy to retune.
voice_cleanup_chain() {
    local denoise=""
    [[ -n "$VOICE_DENOISE" ]] && denoise="${VOICE_DENOISE},"
    printf '%s' "${denoise}highpass=f=80,equalizer=f=220:t=q:w=1:g=-2,equalizer=f=550:t=q:w=1:g=-1,equalizer=f=3200:t=q:w=1:g=1.5,equalizer=f=9000:t=q:w=0.7:g=0.75,acompressor=threshold=-18dB:ratio=3:attack=20:release=100:knee=2.8:makeup=1.5,deesser=i=0.25:m=0.5:f=0.6,alimiter=limit=0.891251:attack=5:release=50:level=false:latency=true"
}

voice_loudnorm_filter() {
    printf 'loudnorm=I=%s:TP=%s:LRA=%s' "$VOICE_LOUDNORM_I" "$VOICE_LOUDNORM_TP" "$VOICE_LOUDNORM_LRA"
}

voice_full_chain() {
    printf '%s,%s' "$(voice_cleanup_chain)" "$(voice_loudnorm_filter)"
}
