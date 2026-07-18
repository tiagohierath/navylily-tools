#!/usr/bin/env bash
#
# make_videos.sh
#
# Converts every audio file in videos/audio into a high-quality, YouTube-ready
# video using a randomly shuffled slideshow of videos/images. Each image is shown
# as a static frame (no zoom, pan, or animation) and the first 30 seconds carry a
# watermark set in a classic serif font (Garamond).
#
# The audio gets a single denoise filter (afftdn) to knock down steady mic hiss /
# white noise, and nothing else — no EQ, compression, or loudness normalization.
# It's otherwise at its original level; optional background music (left untouched)
# is mixed subtly underneath.
#
# Layout (created automatically if missing):
#   videos/audio/    -> input audio files (wav, mp3, m4a, flac, ...)
#   videos/images/   -> input images (jpg, jpeg, png)
#   videos/music/    -> optional background music, cycled + mixed very subtly
#   videos/output/   -> generated videos land here
#   videos/fonts/    -> bundled EBGaramond.ttf (serif watermark font)
#
# AUDIO gets only a single afftdn denoise pass (to remove steady mic hiss) — no
# EQ, no compression, no loudness normalization — and is otherwise at its
# original level. VIDEO is tuned for speed at the same visual quality: 1080p only
# (never 4k), static frames (no zoom/pan/animation), and each frame encoded
# exactly ONCE (crf 17, preset fast). Per-image clips are rendered straight to
# final quality with the watermark baked in, then concatenated with -c copy and
# the audio muxed on top (+faststart for streaming) — so nothing is ever
# re-encoded.
#
# ── How to run on NixOS ──────────────────────────────────────────────────────
#   The script needs ffmpeg + ffprobe. It does NOT install anything system-wide
#   (this machine is declarative/ephemeral only). If ffmpeg isn't on PATH it
#   re-execs itself inside an ephemeral nix-shell automatically. So just:
#
#       ./video
#
#   ...or, to be explicit / pin the tools yourself:
#
#       nix-shell -p ffmpeg --run ./video
#
#   Nothing is left installed afterwards.
#
#   Render just ONE file (matches by name fragment — good for a quick test):
#
#       ./make_videos.sh bitcoin
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config — tweak these as needed
# ---------------------------------------------------------------------------
# Resolve this script's REAL directory, following symlinks, so it works when
# invoked via a symlink on PATH from any directory — lib/, models/, fonts/ and
# videos/ all resolve to the repo, not to the symlink's location. Override the
# media root with VIDEO_BASE_DIR=... to put it elsewhere.
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BASE_DIR="${VIDEO_BASE_DIR:-$HERE/videos}"
AUDIO_DIR="$BASE_DIR/audio"
IMAGES_DIR="$BASE_DIR/images"
OUTPUT_DIR="$BASE_DIR/output"
FONTS_DIR="$BASE_DIR/fonts"
MUSIC_DIR="$BASE_DIR/music"   # background music bed; cycled across renders
WORK_DIR="$(mktemp -d)"

WIDTH=1440          # 4:3 at 1080p height (always 1080p, never 4k)
HEIGHT=1080
FPS=60              # output frame rate (frames are static — no motion)

# Image on-screen durations (still random per image). For roughly the first
# FAST_PHASE_SECONDS of the video the images flash by to open with energy; after
# that the pace settles right down. Both ranges are randomized per image.
FAST_PHASE_SECONDS=30
FAST_MIN_SECONDS=1
FAST_MAX_SECONDS=3
REST_MIN_SECONDS=10
REST_MAX_SECONDS=20

# Background music bed. Drop any number of tracks in videos/music/ and they're
# cycled across renders: each video starts on the next track in the folder and
# the rotation loops to fill the whole timeline, so a short loop never runs out
# and consecutive videos don't all open on the same song. The bed is used at its
# original level and then pulled WAY down by MUSIC_GAIN_DB so it sits *very*
# subtly under the narration — felt more than heard. Empty/missing folder => no
# music, audio path is unchanged.
#   MUSIC_GAIN_DB: attenuation applied to the bed before it's mixed under the
#   narration. -24 dB keeps it as barely-there ambience.
#   Set MUSIC=0 to disable, or raise MUSIC_GAIN_DB toward 0 to bring it forward.
MUSIC="${MUSIC:-1}"
MUSIC_GAIN_DB="${MUSIC_GAIN_DB:--24}"  # duck the bed this far under the voice
MUSIC_ROTATION="${MUSIC_ROTATION:-0}"   # track the NEXT video starts on (cycles; env overridable so single-video callers can still vary it)

WATERMARK_TEXT="Aulas completas em navylily.tv"
WATERMARK_SECONDS=30

# Serif font for the navylily.tv watermark. Defaults to the bundled
# Garamond. Override with: FONTFILE=/path/to/font.ttf ./video
FONTFILE="${FONTFILE:-}"

# Outro card shown (static, full-frame) at the very end of EVERY video: a 4:3
# black frame with centered white "Navylily.tv" in Garamond. Generated once with
# ImageMagick if missing. Override the path with OUTRO_IMAGE=..., the text with
# OUTRO_TEXT=..., or the on-screen time with OUTRO_SECONDS=...
OUTRO_IMAGE="${OUTRO_IMAGE:-$BASE_DIR/outro.png}"
OUTRO_TEXT="${OUTRO_TEXT:-Navylily.tv}"
OUTRO_SECONDS="${OUTRO_SECONDS:-3}"

# Single denoise filter on the narration to knock down steady mic hiss / white
# noise — afftdn (FFT denoiser). It's deliberately gentle so the voice itself is
# untouched; nothing else is processed. Raise nf (noise floor, e.g. -20) for more
# reduction, lower it (e.g. -40) for less, or set VOICE_DENOISE= empty to disable.
# NOTE: no colon in the expansion. ${VOICE_DENOISE-...} keeps a set-but-empty
# value empty (denoise disabled, as documented above); ${VOICE_DENOISE:-...}
# would silently re-enable the default when callers pass VOICE_DENOISE=.
VOICE_DENOISE="${VOICE_DENOISE-afftdn=nr=12:nf=-25}"

# ---------------------------------------------------------------------------
# Make sure ffmpeg/ffprobe are available. Auto-wrap with nix's ffmpeg if not.
# ---------------------------------------------------------------------------
_need_nix=0; _need_reason=""
if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    _need_nix=1; _need_reason="ffmpeg/ffprobe not found on PATH"
fi
if [[ "$_need_nix" == "1" ]]; then
    # A leaked LD_LIBRARY_PATH (e.g. host alsa-lib built against a newer glibc)
    # makes nix-provided binaries fail with GLIBC_ABI_DT_X86_64_PLT errors, so
    # we strip it before handing off to the ephemeral ffmpeg.
    if command -v nix >/dev/null 2>&1; then
        echo "$_need_reason — re-executing inside 'nix shell nixpkgs#ffmpeg' ..."
        exec env -u LD_LIBRARY_PATH nix shell nixpkgs#ffmpeg --command bash "$0" "$@"
    elif command -v nix-shell >/dev/null 2>&1; then
        echo "$_need_reason — re-executing inside nix-shell -p ffmpeg ..."
        exec env -u LD_LIBRARY_PATH nix-shell -p ffmpeg --run "bash '$0' $*"
    else
        echo "ERROR: $_need_reason, and nix is not available to fetch ffmpeg." >&2
        echo "Run inside a shell that has ffmpeg, e.g.:" >&2
        echo "  nix shell nixpkgs#ffmpeg --command ./make_videos.sh" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Locate the serif font for the watermark.
# ---------------------------------------------------------------------------
find_font() {
    if [[ -n "$FONTFILE" && -f "$FONTFILE" ]]; then
        echo "$FONTFILE"; return
    fi
    # Prefer the bundled Garamond (serif).
    local c
    for c in "$FONTS_DIR/EBGaramond.ttf" "$FONTS_DIR/Garamond.ttf" "$FONTS_DIR"/*.ttf; do
        [[ -f "$c" ]] && { echo "$c"; return; }
    done
    # Fall back to any serif fontconfig can resolve.
    if command -v fc-match >/dev/null 2>&1; then
        local f
        f="$(fc-match -f '%{file}' serif 2>/dev/null || true)"
        [[ -n "$f" && -f "$f" ]] && { echo "$f"; return; }
    fi
    echo ""
}

FONTFILE="$(find_font)"
if [[ -z "$FONTFILE" ]]; then
    echo "WARNING: no font found for the watermark. Drop a .ttf in $FONTS_DIR" >&2
    echo "or set FONTFILE=/path/to/font.ttf. Continuing without watermark text." >&2
fi

# ---------------------------------------------------------------------------
# Ensure the outro card exists. It's a 4:3 black frame with centered white text
# in the same Garamond as the watermark. Generated once with ImageMagick (falls
# back to nix if magick isn't on PATH); reused on every later run.
# ---------------------------------------------------------------------------
ensure_outro() {
    [[ -f "$OUTRO_IMAGE" ]] && return 0
    local mk=()
    if command -v magick >/dev/null 2>&1; then
        mk=(magick)
    elif command -v convert >/dev/null 2>&1; then
        mk=(convert)
    elif command -v nix >/dev/null 2>&1; then
        mk=(env -u LD_LIBRARY_PATH nix run nixpkgs#imagemagick -- magick)
    else
        echo "WARNING: $OUTRO_IMAGE missing and ImageMagick/nix unavailable to" >&2
        echo "generate it. Videos will render WITHOUT the outro card." >&2
        return 1
    fi
    echo "Generating outro card -> $OUTRO_IMAGE"
    "${mk[@]}" -size "${WIDTH}x${HEIGHT}" canvas:black \
        ${FONTFILE:+-font "$FONTFILE"} -fill white -pointsize 130 -gravity center \
        -annotate +0+0 "$OUTRO_TEXT" "$OUTRO_IMAGE"
}
ensure_outro || true

# ---------------------------------------------------------------------------
# Setup folders
# ---------------------------------------------------------------------------
mkdir -p "$AUDIO_DIR" "$IMAGES_DIR" "$OUTPUT_DIR" "$FONTS_DIR" "$MUSIC_DIR"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

shopt -s nullglob nocaseglob

audio_files=("$AUDIO_DIR"/*.wav "$AUDIO_DIR"/*.mp3 "$AUDIO_DIR"/*.m4a "$AUDIO_DIR"/*.flac "$AUDIO_DIR"/*.aac "$AUDIO_DIR"/*.ogg)
image_files=("$IMAGES_DIR"/*.jpg "$IMAGES_DIR"/*.jpeg "$IMAGES_DIR"/*.png)
music_files=("$MUSIC_DIR"/*.wav "$MUSIC_DIR"/*.mp3 "$MUSIC_DIR"/*.m4a "$MUSIC_DIR"/*.flac "$MUSIC_DIR"/*.aac "$MUSIC_DIR"/*.ogg)

if [[ ${#audio_files[@]} -eq 0 ]]; then
    echo "No audio files found in $AUDIO_DIR. Drop some in and re-run." >&2
    exit 1
fi

# Optional filter: pass a name (or fragment) to render only matching audio
# file(s) — handy for testing one before committing to the whole batch:
#   ./make_videos.sh bitcoin
if [[ $# -ge 1 ]]; then
    filter="$1"
    filtered=()
    for a in "${audio_files[@]}"; do
        [[ "$(basename "$a")" == *"$filter"* ]] && filtered+=("$a")
    done
    if [[ ${#filtered[@]} -eq 0 ]]; then
        echo "No audio file in $AUDIO_DIR matches '$filter'." >&2
        echo "Available:" >&2
        printf '  %s\n' "${audio_files[@]##*/}" >&2
        exit 1
    fi
    audio_files=("${filtered[@]}")
fi
if [[ ${#image_files[@]} -eq 0 ]]; then
    echo "No image files found in $IMAGES_DIR. Drop some in and re-run." >&2
    exit 1
fi

echo "Found ${#audio_files[@]} audio file(s) and ${#image_files[@]} image(s)."
if [[ "$MUSIC" == "1" && ${#music_files[@]} -gt 0 ]]; then
    echo "Background music: ${#music_files[@]} track(s) cycled at ${MUSIC_GAIN_DB} dB (very subtle)."
else
    echo "Background music: none."
fi
echo "Watermark font: ${FONTFILE:-<none>}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Random float between MIN and MAX with 4 decimal places.
random_float() {
    awk -v min="$1" -v max="$2" -v seed="$RANDOM$RANDOM$$" 'BEGIN{
        srand(seed); printf "%.4f", min + rand() * (max - min)
    }'
}

# Fisher-Yates shuffle of [0, n).
shuffle_sequence() {
    local n="$1"; local -a idx=()
    for ((i = 0; i < n; i++)); do idx+=("$i"); done
    for ((i = n - 1; i > 0; i--)); do
        j=$((RANDOM % (i + 1)))
        tmp="${idx[i]}"; idx[i]="${idx[j]}"; idx[j]="$tmp"
    done
    printf '%s\n' "${idx[@]}"
}

# Build a non-repeating-adjacent sequence of image indices long enough to
# cover $needed_seconds, picking each image's on-screen duration randomly.
build_sequence() {
    local needed_seconds="$1" seq_file="$2" dur_file="$3"
    local n_images=${#image_files[@]}
    local total=0 last_idx=-1
    : > "$seq_file"; : > "$dur_file"

    while (( $(awk -v t="$total" -v need="$needed_seconds" 'BEGIN{print (t < need)}') )); do
        mapfile -t shuffled < <(shuffle_sequence "$n_images")
        for pick in "${shuffled[@]}"; do
            if [[ "$pick" == "$last_idx" && $n_images -gt 1 ]]; then continue; fi
            # Images that START within the first FAST_PHASE_SECONDS flash by
            # (1-3s); everything after settles into a slow pace (10-20s).
            if (( $(awk -v t="$total" -v f="$FAST_PHASE_SECONDS" 'BEGIN{print (t < f)}') )); then
                dur="$(random_float "$FAST_MIN_SECONDS" "$FAST_MAX_SECONDS")"
            else
                dur="$(random_float "$REST_MIN_SECONDS" "$REST_MAX_SECONDS")"
            fi
            echo "$pick" >> "$seq_file"
            echo "$dur" >> "$dur_file"
            total="$(awk -v t="$total" -v d="$dur" 'BEGIN{printf "%.4f", t+d}')"
            last_idx="$pick"
            if (( $(awk -v t="$total" -v need="$needed_seconds" 'BEGIN{print (t >= need)}') )); then break; fi
        done
    done
}

get_audio_duration() {
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1"
}

# ---------------------------------------------------------------------------
# Per-image clip — a static frame (no zoom, pan, or animation).
#
# Encoded ONCE, straight to the final delivery settings (crf 17, yuv420p,
# High@4.2) with its slice of the watermark baked in. The clips are then
# concatenated with -c copy and the audio muxed on top, so no frame is ever
# re-encoded.
#
# Args: <image> <duration_s> <timeline_offset_s> <out.mp4>
# ---------------------------------------------------------------------------
make_image_clip() {
    local img="$1" duration="$2" offset="$3" out="$4"

    # Watermark: bake it onto the part of THIS clip that lands within the first
    # WATERMARK_SECONDS of the whole video. offset = this clip's start time, and
    # t is the clip-local time, so the cutoff is (WATERMARK_SECONDS - offset).
    local dt=""
    if [[ -n "$FONTFILE" ]]; then
        local wleft
        wleft=$(awk -v w="$WATERMARK_SECONDS" -v o="$offset" 'BEGIN{printf "%.4f", w-o}')
        if (( $(awk -v x="$wleft" 'BEGIN{print (x>0)}') )); then
            local enable=""
            if (( $(awk -v x="$wleft" -v d="$duration" 'BEGIN{print (x<d)}') )); then
                enable=":enable='lt(t,${wleft})'"   # watermark stops mid-clip
            fi
            dt=",drawtext=fontfile='${FONTFILE}':text='${WATERMARK_TEXT}':fontcolor=black:fontsize=44:box=1:boxcolor=white@0.5:boxborderw=14:x=36:y=h-th-36${enable}"
        fi
    fi

    # Show the WHOLE image inside the 4:3 frame, always fully visible, with NO
    # distortion, whatever the source shape:
    #   - scale ...:force_original_aspect_ratio=decrease  -> fit the image inside
    #     the frame, keeping its aspect ratio (so it's never stretched/cropped);
    #   - pad ...                                          -> center it and fill
    #     any leftover space with black bars (letterbox/pillarbox);
    #   - setsar=1                                         -> square pixels, so a
    #     non-square source SAR can't make it look stretched on playback.
    # The frame is static — no zoom, pan, or animation.
    ffmpeg -y -loop 1 -i "$img" -t "$duration" -r "$FPS" \
        -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1${dt},format=yuv420p" \
        -c:v libx264 -preset fast -crf 17 -pix_fmt yuv420p -profile:v high -level 4.2 -an "$out" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Audio for the video: the source narration is transcoded to a consistent 48kHz
# stereo wav (so the mux has a uniform format to work with) and gets a single
# afftdn denoise pass to remove steady mic hiss — nothing else is processed.
# Set VOICE_DENOISE= empty to skip the denoise. Writes the wav to $2.
# ---------------------------------------------------------------------------
prepare_audio() {
    local in="$1" out="$2"
    local af=()
    [[ -n "$VOICE_DENOISE" ]] && af=(-af "$VOICE_DENOISE")
    ffmpeg -y -i "$in" "${af[@]}" -ar 48000 -ac 2 -c:a pcm_s16le "$out" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Background music bed. Cycles through videos/music/, starting on the track at
# MUSIC_ROTATION (which advances by one per video) and looping the folder until
# the bed is at least $needed seconds long, then trims to exactly that. The bed
# is used at its original level — no normalization, no fades. The big
# MUSIC_GAIN_DB attenuation happens later, in the mux, so the bed sits *very*
# subtly under the narration. Writes a 48kHz stereo wav to $2 and returns
# non-zero (no bed written) when there's no music.
#
# Args: <needed_seconds> <out.wav>
# ---------------------------------------------------------------------------
build_music_bed() {
    local needed="$1" out="$2"
    local n=${#music_files[@]}
    (( n == 0 )) && return 1

    # Cycle the folder (looping) until we've queued enough audio to cover the
    # whole timeline. Starting offset rotates per video so consecutive renders
    # don't all open on the same song.
    local list="$out.concat.txt"; : > "$list"
    local total=0 i=0
    while (( $(awk -v t="$total" -v need="$needed" 'BEGIN{print (t < need)}') )); do
        local idx=$(( (MUSIC_ROTATION + i) % n ))
        local f="${music_files[$idx]}"
        printf "file '%s'\n" "$f" >> "$list"
        local d
        d="$(get_audio_duration "$f")"
        total="$(awk -v t="$total" -v d="$d" 'BEGIN{printf "%.4f", t+d}')"
        i=$((i + 1))
    done
    # Next video starts on the next track in the folder.
    MUSIC_ROTATION=$(( (MUSIC_ROTATION + 1) % n ))

    ffmpeg -y -f concat -safe 0 -i "$list" \
        -t "$needed" -ar 48000 -ac 2 -c:a pcm_s16le "$out" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Main render loop
# ---------------------------------------------------------------------------
for audio in "${audio_files[@]}"; do
    base="$(basename "$audio")"
    name="${base%.*}"
    out_video="$OUTPUT_DIR/${name}.mp4"

    # Don't ever render the same thing twice.
    if [[ -f "$out_video" ]]; then
        echo "Skipping '$name' — output already exists: $out_video"
        continue
    fi

    echo "=== Processing: $base ==="
    duration="$(get_audio_duration "$audio")"
    echo "  audio duration: ${duration}s"

    run_dir="$WORK_DIR/$name"
    mkdir -p "$run_dir"
    seq_file="$run_dir/seq.txt"
    dur_file="$run_dir/dur.txt"

    build_sequence "$duration" "$seq_file" "$dur_file"

    mapfile -t seq < "$seq_file"
    mapfile -t durs < "$dur_file"
    echo "  slideshow will use ${#seq[@]} image slot(s)"

    concat_list="$run_dir/concat.txt"
    : > "$concat_list"

    offset=0
    for i in "${!seq[@]}"; do
        idx="${seq[$i]}"; dur="${durs[$i]}"; img="${image_files[$idx]}"
        clip="$run_dir/clip_$(printf '%04d' "$i").mp4"
        echo "  [$i] $(basename "$img") for ${dur}s"
        make_image_clip "$img" "$dur" "$offset" "$clip"
        echo "file '$clip'" >> "$concat_list"
        offset=$(awk -v o="$offset" -v d="$dur" 'BEGIN{printf "%.4f", o+d}')
    done

    # Outro card: append a static OUTRO_SECONDS clip (no watermark — pass an
    # offset >= WATERMARK_SECONDS) so EVERY video ends on the Navylily.tv frame.
    # total_video is the exact final length (slideshow + outro) we pad audio to.
    total_video="$offset"
    if [[ -f "$OUTRO_IMAGE" ]]; then
        outro_clip="$run_dir/clip_outro.mp4"
        echo "  [outro] $(basename "$OUTRO_IMAGE") for ${OUTRO_SECONDS}s"
        make_image_clip "$OUTRO_IMAGE" "$OUTRO_SECONDS" "$WATERMARK_SECONDS" "$outro_clip"
        echo "file '$outro_clip'" >> "$concat_list"
        total_video=$(awk -v o="$offset" -v e="$OUTRO_SECONDS" 'BEGIN{printf "%.4f", o+e}')
    fi

    # Prepare the narration audio (no processing — used at its original level,
    # just transcoded to a uniform wav for the mux).
    audio_wav="$run_dir/audio.wav"
    prepare_audio "$audio" "$audio_wav"

    # Optional very-subtle background music bed, cycled across renders and
    # stretched (looped) to the full timeline length.
    music_bed=""
    if [[ "$MUSIC" == "1" ]]; then
        bed="$run_dir/music_bed.wav"
        echo "  building background music bed (${MUSIC_GAIN_DB} dB under voice)..."
        if build_music_bed "$total_video" "$bed"; then
            music_bed="$bed"
        fi
    fi

    # Mux: the clips are already final-quality H.264 with the watermark baked in,
    # so the VIDEO IS COPIED (never re-encoded) and only the audio is encoded.
    # Each frame is therefore encoded exactly once — the main speed win.
    #
    # apad + -t total_video pads the speech with trailing silence so the audio
    # spans the full timeline: the outro card (and any slideshow overshoot past
    # the speech) plays over silence instead of being cut by -shortest.
    echo "  muxing (video copied, audio encoded)..."
    tmp_out="$run_dir/final.mp4"
    if [[ -n "$music_bed" ]]; then
        # Mix the subtle music bed under the narration. apad keeps the voice
        # spanning the full timeline; the music is attenuated by MUSIC_GAIN_DB
        # and amix runs with normalize=0 so the voice stays at its full level
        # (default amix would halve both). -t trims to the exact video length.
        music_vol="$(awk -v g="$MUSIC_GAIN_DB" 'BEGIN{printf "%.6f", 10^(g/20)}')"
        ffmpeg -y -f concat -safe 0 -i "$concat_list" -i "$audio_wav" -i "$music_bed" \
            -filter_complex "[1:a]apad[v];[2:a]volume=${music_vol}[m];[v][m]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[a]" \
            -map 0:v:0 -map "[a]" -t "$total_video" \
            -c:v copy -c:a aac -b:a 320k \
            -movflags +faststart \
            "$tmp_out" >/dev/null 2>&1
    else
        ffmpeg -y -f concat -safe 0 -i "$concat_list" -i "$audio_wav" \
            -map 0:v:0 -map 1:a:0 \
            -af apad -t "$total_video" \
            -c:v copy -c:a aac -b:a 320k \
            -movflags +faststart \
            "$tmp_out" >/dev/null 2>&1
    fi

    # Publish in two steps: WORK_DIR usually lives on another filesystem
    # (/tmp), where a direct mv degrades to a non-atomic copy that the daily
    # uploader could catch half-written. Stage the copy next to the final name,
    # then rename inside the same directory, which IS atomic. The .partial
    # suffix is not a video extension, so the uploader never selects it.
    cp "$tmp_out" "${out_video}.partial"
    mv -f "${out_video}.partial" "$out_video"
    echo "  done -> $out_video"
done

echo "All videos generated in $OUTPUT_DIR"
