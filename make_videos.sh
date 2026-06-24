#!/usr/bin/env bash
#
# make_videos.sh
#
# Converts every audio file in videos/audio into a high-quality, YouTube-ready
# video using a randomly shuffled slideshow of videos/images. Each image gets a
# very subtle, smooth 60fps zoom (randomly in or out) and the first 30 seconds
# carry a watermark set in a condensed serif font (Cormorant).
#
# The audio is normalized + lightly compressed for YouTube (loudness ~ -14 LUFS,
# EBU R128 two-pass) so every upload sits at a consistent, broadcast-friendly
# level.
#
# Layout (created automatically if missing):
#   videos/audio/    -> input audio files (wav, mp3, m4a, flac, ...)
#   videos/images/   -> input images (jpg, jpeg, png)
#   videos/output/   -> generated videos land here
#   videos/fonts/    -> bundled Cormorant.ttf (condensed serif watermark)
#
# Quality is favoured over speed everywhere: lossless intermediate clips, a
# single final x264 pass at a high quality (crf 17, preset veryslow), 4:4:4 ->
# 4:2:0 only at the very end, and +faststart for streaming.
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
set -euo pipefail

# ---------------------------------------------------------------------------
# Config — tweak these as needed
# ---------------------------------------------------------------------------
BASE_DIR="${VIDEO_BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/videos}"
AUDIO_DIR="$BASE_DIR/audio"
IMAGES_DIR="$BASE_DIR/images"
OUTPUT_DIR="$BASE_DIR/output"
FONTS_DIR="$BASE_DIR/fonts"
WORK_DIR="$(mktemp -d)"

WIDTH=1440          # 4:3 at 1080p height
HEIGHT=1080
FPS=60              # smooth motion for the subtle zoom

MIN_IMG_SECONDS=6
MAX_IMG_SECONDS=11

# Subtle zoom: each image drifts by a random amount in this range, and the
# direction (in or out) is chosen at random per image. Keep these small — the
# whole point is that the motion is barely perceptible but alive.
ZOOM_MIN_AMOUNT=0.03   # +3%  over the clip
ZOOM_MAX_AMOUNT=0.06   # +6%  over the clip

# YouTube loudness target (EBU R128). YouTube normalizes to roughly -14 LUFS.
LOUDNORM_I=-14
LOUDNORM_TP=-1.5
LOUDNORM_LRA=11

WATERMARK_TEXT="Aulas completas em navylily.tv"
WATERMARK_SECONDS=30

# Condensed serif font for the navylily.tv watermark. Defaults to the bundled
# Cormorant. Override with: FONTFILE=/path/to/font.ttf ./video
FONTFILE="${FONTFILE:-}"

# ---------------------------------------------------------------------------
# Make sure ffmpeg/ffprobe are available — auto-wrap with nix-shell if not.
# ---------------------------------------------------------------------------
if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    # A leaked LD_LIBRARY_PATH (e.g. host alsa-lib built against a newer glibc)
    # makes nix-provided binaries fail with GLIBC_ABI_DT_X86_64_PLT errors, so
    # we strip it before handing off to the ephemeral ffmpeg.
    if command -v nix >/dev/null 2>&1; then
        echo "ffmpeg not found on PATH — re-executing inside 'nix shell nixpkgs#ffmpeg' ..."
        exec env -u LD_LIBRARY_PATH nix shell nixpkgs#ffmpeg --command bash "$0" "$@"
    elif command -v nix-shell >/dev/null 2>&1; then
        echo "ffmpeg not found on PATH — re-executing inside nix-shell -p ffmpeg ..."
        exec env -u LD_LIBRARY_PATH nix-shell -p ffmpeg --run "bash '$0' $*"
    else
        echo "ERROR: ffmpeg/ffprobe not found, and nix is not available to fetch it." >&2
        echo "Run inside a shell that has them, e.g.:" >&2
        echo "  nix shell nixpkgs#ffmpeg --command ./video" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Locate the condensed serif font for the watermark.
# ---------------------------------------------------------------------------
find_font() {
    if [[ -n "$FONTFILE" && -f "$FONTFILE" ]]; then
        echo "$FONTFILE"; return
    fi
    # Prefer the bundled Cormorant (condensed serif).
    local c
    for c in "$FONTS_DIR/Cormorant.ttf" "$FONTS_DIR"/*.ttf; do
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
# Setup folders
# ---------------------------------------------------------------------------
mkdir -p "$AUDIO_DIR" "$IMAGES_DIR" "$OUTPUT_DIR" "$FONTS_DIR"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

shopt -s nullglob nocaseglob

audio_files=("$AUDIO_DIR"/*.wav "$AUDIO_DIR"/*.mp3 "$AUDIO_DIR"/*.m4a "$AUDIO_DIR"/*.flac "$AUDIO_DIR"/*.aac "$AUDIO_DIR"/*.ogg)
image_files=("$IMAGES_DIR"/*.jpg "$IMAGES_DIR"/*.jpeg "$IMAGES_DIR"/*.png)

if [[ ${#audio_files[@]} -eq 0 ]]; then
    echo "No audio files found in $AUDIO_DIR. Drop some in and re-run." >&2
    exit 1
fi
if [[ ${#image_files[@]} -eq 0 ]]; then
    echo "No image files found in $IMAGES_DIR. Drop some in and re-run." >&2
    exit 1
fi

echo "Found ${#audio_files[@]} audio file(s) and ${#image_files[@]} image(s)."
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
            dur="$(random_float "$MIN_IMG_SECONDS" "$MAX_IMG_SECONDS")"
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
# Per-image clip with a subtle, smooth zoom (random direction).
#
# Lossless intermediate (x264 -qp 0) so concatenation + the single final encode
# don't stack generation loss. zoompan runs at FPS with a per-output-frame
# linear z so the motion is perfectly smooth rather than stepped.
# ---------------------------------------------------------------------------
make_image_clip() {
    local img="$1" duration="$2" out="$3"
    local frames amount zexpr
    frames=$(awk -v d="$duration" -v f="$FPS" 'BEGIN{printf "%d", d*f}')
    (( frames < 2 )) && frames=2
    amount="$(random_float "$ZOOM_MIN_AMOUNT" "$ZOOM_MAX_AMOUNT")"

    # Random direction: in (start 1.0, grow) or out (start 1+amount, shrink).
    if (( RANDOM % 2 == 0 )); then
        # zoom in: 1.0 -> 1+amount, linear over the clip
        zexpr="1.0+(on/${frames})*${amount}"
    else
        # zoom out: 1+amount -> 1.0, linear over the clip
        zexpr="(1.0+${amount})-(on/${frames})*${amount}"
    fi

    # Supersample to 2x so the zoom crop always has real pixels to work with,
    # keep it centered, then output at exact target size and FPS.
    ffmpeg -y -loop 1 -i "$img" -t "$duration" \
        -vf "scale=${WIDTH}*2:${HEIGHT}*2:force_original_aspect_ratio=increase,crop=${WIDTH}*2:${HEIGHT}*2,zoompan=z='${zexpr}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=${frames}:s=${WIDTH}x${HEIGHT}:fps=${FPS},format=yuv444p" \
        -c:v libx264 -qp 0 -preset veryfast -an "$out" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Two-pass EBU R128 loudness normalization + gentle compression for YouTube.
# Writes a clean 48kHz stereo wav to $2.
# ---------------------------------------------------------------------------
normalize_audio() {
    local in="$1" out="$2"
    echo "  measuring loudness (pass 1/2)..."
    local measured
    measured="$(ffmpeg -hide_banner -i "$in" \
        -af "acompressor=threshold=-18dB:ratio=3:attack=20:release=250,loudnorm=I=${LOUDNORM_I}:TP=${LOUDNORM_TP}:LRA=${LOUDNORM_LRA}:print_format=json" \
        -f null - 2>&1 | awk '/^\{/{c=1} c{print} /^\}/{c=0}')"

    local mi mtp mlra mthresh
    mi="$(awk -F'"' '/input_i/{print $4}' <<<"$measured")"
    mtp="$(awk -F'"' '/input_tp/{print $4}' <<<"$measured")"
    mlra="$(awk -F'"' '/input_lra/{print $4}' <<<"$measured")"
    mthresh="$(awk -F'"' '/input_thresh/{print $4}' <<<"$measured")"

    local ln="loudnorm=I=${LOUDNORM_I}:TP=${LOUDNORM_TP}:LRA=${LOUDNORM_LRA}"
    if [[ -n "$mi" && -n "$mtp" && -n "$mlra" && -n "$mthresh" ]]; then
        ln="${ln}:measured_I=${mi}:measured_TP=${mtp}:measured_LRA=${mlra}:measured_thresh=${mthresh}:linear=true"
    fi

    echo "  applying compression + loudness (pass 2/2)..."
    ffmpeg -y -i "$in" \
        -af "acompressor=threshold=-18dB:ratio=3:attack=20:release=250,${ln}" \
        -ar 48000 -ac 2 -c:a pcm_s16le "$out" >/dev/null 2>&1
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

    for i in "${!seq[@]}"; do
        idx="${seq[$i]}"; dur="${durs[$i]}"; img="${image_files[$idx]}"
        clip="$run_dir/clip_$(printf '%04d' "$i").mp4"
        echo "  [$i] $(basename "$img") for ${dur}s"
        make_image_clip "$img" "$dur" "$clip"
        echo "file '$clip'" >> "$concat_list"
    done

    silent_video="$run_dir/silent.mp4"
    ffmpeg -y -f concat -safe 0 -i "$concat_list" -c copy "$silent_video" >/dev/null 2>&1

    # Normalize + compress audio for YouTube.
    norm_audio="$run_dir/audio_norm.wav"
    normalize_audio "$audio" "$norm_audio"

    # Watermark: condensed serif, black text on a translucent white box,
    # bottom-left, first WATERMARK_SECONDS only.
    if [[ -n "$FONTFILE" ]]; then
        drawtext_filter="drawtext=fontfile='${FONTFILE}':text='${WATERMARK_TEXT}':fontcolor=black:fontsize=44:box=1:boxcolor=white@0.5:boxborderw=14:x=36:y=h-th-36:enable='lt(t,${WATERMARK_SECONDS})'"
        vf_args=(-vf "$drawtext_filter")
    else
        vf_args=()
    fi

    echo "  final encode (quality-first, single pass)..."
    tmp_out="$run_dir/final.mp4"
    ffmpeg -y -i "$silent_video" -i "$norm_audio" \
        "${vf_args[@]}" \
        -c:v libx264 -preset veryslow -crf 17 -pix_fmt yuv420p \
        -profile:v high -level 4.2 -movflags +faststart \
        -c:a aac -b:a 320k \
        -shortest \
        "$tmp_out" >/dev/null 2>&1

    # Atomic publish so an interrupted run never leaves a half-written .mp4
    # that the skip-check would mistake for a finished render.
    mv -f "$tmp_out" "$out_video"
    echo "  done -> $out_video"
done

echo "All videos generated in $OUTPUT_DIR"
