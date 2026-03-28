#!/usr/bin/env bash
# playlist-to-audiobook.sh
# Converts a YouTube playlist to a single M4B audiobook file with chapters and cover art.
#
# Dependencies: yt-dlp, ffmpeg, ffprobe
#
# Usage:
#   playlist-to-audiobook.sh -u <url> [-o <output-name>] [-d <output-dir>]
#                            [-t <title>] [-a <artist>] [-l <album>]
#                            [-b <bitrate-kbps>] [-c <cover-image>]
#                            [--items <range>] [--chapter-gap <seconds>]
#                            [-k] [-n] [-v] [-q] [--dry-run]
#
# Options:
#   -u, --url            URL of the YouTube playlist or single video (required)
#   -o, --output         Output filename (without extension); defaults to playlist title
#   -d, --output-dir     Directory for the output M4B; defaults to current directory
#   -t, --title          Title metadata tag; defaults to playlist title
#   -a, --artist         Artist metadata tag; defaults to playlist uploader
#   -l, --album          Album metadata tag; defaults to playlist title
#   -b, --bitrate        Audio bitrate in kbps; defaults to 160
#   -c, --cover          Path to a local image file to use as cover art
#   --items              Playlist item range (e.g. "1-5", "2,4,6"); passed to yt-dlp
#   --chapter-gap        Seconds of silence to insert between chapters; defaults to 0
#   -k, --keep           Keep downloaded files after encoding
#   -n, --no-normalize   Skip per-file audio normalization (EBU R128)
#   -v, --verbose        Show detailed yt-dlp and ffmpeg output
#   -q, --quiet          Suppress all non-error output
#   --dry-run            Show what would be done without downloading or encoding

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: playlist-to-audiobook.sh -u <url> [options]

Converts a YouTube playlist (or single video) into an M4B audiobook.

Options:
  -u, --url URL          YouTube playlist or video URL (required)
  -o, --output NAME      Output filename without extension (default: playlist title)
  -d, --output-dir DIR   Directory for the output M4B (default: current directory)
  -t, --title TITLE      Title metadata tag (default: playlist title)
  -a, --artist ARTIST    Artist metadata tag (default: playlist uploader)
  -l, --album ALBUM      Album metadata tag (default: playlist title)
  -b, --bitrate KBPS     Audio bitrate in kbps (default: 160)
  -c, --cover FILE       Local image to use as cover art
  --items RANGE           Playlist items to download (e.g. "1-5", "2,4,6")
  --chapter-gap SECONDS   Silence to insert between chapters (default: 0)
  -k, --keep             Keep intermediate files after encoding
  -n, --no-normalize     Skip EBU R128 audio normalization
  -v, --verbose          Show detailed yt-dlp and ffmpeg output
  -q, --quiet            Suppress all non-error output
  --dry-run              Show what would be done, then exit
  -h, --help             Show this help message

Dependencies: yt-dlp, ffmpeg, ffprobe
EOF
    exit 0
}

# ---------- defaults ----------
URL=""
OUTPUT_NAME=""
OUTPUT_DIR=""
TITLE=""
ARTIST=""
ALBUM=""
BITRATE=160
KEEP=0
NORMALIZE=1
COVER=""
ITEMS=""
VERBOSE=0
QUIET=0
DRY_RUN=0
CHAPTER_GAP=0

# ---------- parse args ----------
PARSED=$(getopt -o u:o:d:t:a:l:b:c:knvqh \
    --long url:,output:,output-dir:,title:,artist:,album:,bitrate:,cover:,items:,chapter-gap:,keep,no-normalize,verbose,quiet,dry-run,help \
    -n "$(basename "$0")" -- "$@") || exit 1
eval set -- "$PARSED"

while true; do
    case "$1" in
        -u|--url)          URL="$2";         shift 2 ;;
        -o|--output)       OUTPUT_NAME="$2"; shift 2 ;;
        -d|--output-dir)   OUTPUT_DIR="$2";  shift 2 ;;
        -t|--title)        TITLE="$2";       shift 2 ;;
        -a|--artist)       ARTIST="$2";      shift 2 ;;
        -l|--album)        ALBUM="$2";       shift 2 ;;
        -b|--bitrate)      BITRATE="$2";     shift 2 ;;
        -c|--cover)        COVER="$2";       shift 2 ;;
        --items)           ITEMS="$2";       shift 2 ;;
        --chapter-gap)     CHAPTER_GAP="$2"; shift 2 ;;
        -k|--keep)         KEEP=1;           shift ;;
        -n|--no-normalize) NORMALIZE=0;      shift ;;
        -v|--verbose)      VERBOSE=1;        shift ;;
        -q|--quiet)        QUIET=1;          shift ;;
        --dry-run)         DRY_RUN=1;        shift ;;
        -h|--help)         usage ;;
        --) shift; break ;;
        *)  echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$URL" ]]; then
    echo "Usage: $(basename "$0") -u|--url <url> [options]" >&2
    echo "Run with --help or see script header for full option list." >&2
    exit 1
fi

if ! [[ "$BITRATE" =~ ^[0-9]+$ ]] || [[ "$BITRATE" -eq 0 ]]; then
    echo "Error: Bitrate (-b) must be a positive integer." >&2
    exit 1
fi

if ! [[ "$CHAPTER_GAP" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Error: Chapter gap (--chapter-gap) must be a non-negative number." >&2
    exit 1
fi

if [[ -n "$COVER" && ! -f "$COVER" ]]; then
    echo "Error: Cover image not found: $COVER" >&2
    exit 1
fi

if [[ -n "$OUTPUT_DIR" && ! -d "$OUTPUT_DIR" ]]; then
    echo "Error: Output directory does not exist: $OUTPUT_DIR" >&2
    exit 1
fi

for cmd in yt-dlp ffmpeg ffprobe; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' is not installed or not in PATH." >&2
        exit 1
    fi
done

# ---------- helpers ----------
# Logging helpers that respect -q/--quiet
log_step() { [[ $QUIET -eq 0 ]] && echo -e "\033[0;36m$1\033[0m" || true; }
log_info() { [[ $QUIET -eq 0 ]] && echo -e "  \033[0;37m$1\033[0m" || true; }
log_warn() { echo -e "  \033[0;33mWarning: $1\033[0m" >&2; }
log_ok()   { [[ $QUIET -eq 0 ]] && echo -e "\033[0;32m$1\033[0m" || true; }

# Redirect target for yt-dlp/ffmpeg output based on verbosity
if [[ $VERBOSE -eq 1 ]]; then
    REDIR="/dev/stdout"
else
    REDIR="/dev/null"
fi

# ---------- Step 1: playlist/video metadata ----------
log_step "[1/6] Fetching metadata..."

# Detect whether URL is a single video or a playlist
IS_PLAYLIST=1
META=$(yt-dlp --flat-playlist --playlist-items 1 --print "%(playlist_title)s	%(uploader)s" -- "$URL" 2>/dev/null) || {
    META=""
}
PLAYLIST_TITLE=$(echo "$META" | head -n1 | cut -f1)
UPLOADER=$(echo "$META" | head -n1 | cut -f2)

# If no playlist title, treat as a single video
if [[ -z "$PLAYLIST_TITLE" || "$PLAYLIST_TITLE" == "NA" ]]; then
    IS_PLAYLIST=0
    META=$(yt-dlp --skip-download --print "%(title)s	%(uploader)s" -- "$URL" 2>/dev/null) || {
        log_warn "Could not fetch video metadata, using defaults."
        META=""
    }
    PLAYLIST_TITLE=$(echo "$META" | head -n1 | cut -f1)
    UPLOADER=$(echo "$META" | head -n1 | cut -f2)
fi

[[ -z "$PLAYLIST_TITLE" ]] && PLAYLIST_TITLE="audiobook"
[[ -z "$UPLOADER"       ]] && UPLOADER="Unknown Artist"

[[ -z "$OUTPUT_NAME" ]] && OUTPUT_NAME="$PLAYLIST_TITLE"
[[ -z "$TITLE"       ]] && TITLE="$PLAYLIST_TITLE"
[[ -z "$ALBUM"       ]] && ALBUM="$PLAYLIST_TITLE"
[[ -z "$ARTIST"      ]] && ARTIST="$UPLOADER"

# Sanitize filename
SAFE_OUTPUT_NAME=$(echo "$OUTPUT_NAME" | tr '<>:"/\\|?*'"'" '_')
WORKDIR="$(pwd)/$SAFE_OUTPUT_NAME"
mkdir -p "$WORKDIR"

BASE_DIR="${OUTPUT_DIR:-$(pwd)}"
LIST_TXT="$WORKDIR/list.txt"
CHAPTER_TXT="$WORKDIR/chapters.txt"
COVER_JPG="$WORKDIR/cover.jpg"
OUT_M4B="${BASE_DIR}/${SAFE_OUTPUT_NAME}.m4b"

# ---------- trap cleanup ----------
cleanup() {
    if [[ $KEEP -eq 0 && -d "$WORKDIR" ]]; then
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

# ---------- dry-run: show plan and exit ----------
if [[ $DRY_RUN -eq 1 ]]; then
    echo "Dry run — would perform the following:"
    echo "  URL:        $URL"
    echo "  Type:       $([[ $IS_PLAYLIST -eq 1 ]] && echo "playlist" || echo "single video")"
    [[ -n "$ITEMS" ]] && echo "  Items:      $ITEMS"
    echo "  Title:      $TITLE"
    echo "  Artist:     $ARTIST"
    echo "  Album:      $ALBUM"
    echo "  Bitrate:    ${BITRATE}k"
    echo "  Normalize:  $([[ $NORMALIZE -eq 1 ]] && echo "yes (two-pass EBU R128)" || echo "no")"
    echo "  Chapter gap: ${CHAPTER_GAP}s"
    echo "  Cover:      ${COVER:-<playlist thumbnail>}"
    echo "  Output:     $OUT_M4B"
    exit 0
fi

# ---------- Step 2: download audio ----------
log_step "[2/6] Downloading audio..."

YTDLP_ARGS=(
    --no-overwrites
    --retries infinite
    --fragment-retries infinite
    -x
    -f "bestaudio"
)

if [[ $IS_PLAYLIST -eq 1 ]]; then
    YTDLP_ARGS+=(--yes-playlist)
    YTDLP_ARGS+=(-o "$WORKDIR/%(playlist_index)03d - %(title).200B.%(ext)s")
    [[ -n "$ITEMS" ]] && YTDLP_ARGS+=(--playlist-items "$ITEMS")
else
    YTDLP_ARGS+=(-o "$WORKDIR/001 - %(title).200B.%(ext)s")
fi

yt-dlp "${YTDLP_ARGS[@]}" -- "$URL" > "$REDIR" 2>&1 || true

# ---------- Step 3: normalize audio (two-pass EBU R128) ----------
if [[ $NORMALIZE -eq 1 ]]; then
    log_step "[3/6] Normalizing audio (two-pass EBU R128)..."
    NORM_DONE_MARKER="$WORKDIR/.norm_done"
    shopt -s nullglob
    for FILE in "$WORKDIR"/*.{webm,opus,m4a,mp3,ogg,wav,flac,aac}; do
        BASENAME=$(basename "$FILE")
        # Resume: skip files already normalized in a previous run
        if [[ -f "$NORM_DONE_MARKER" ]] && grep -qxF "$BASENAME" "$NORM_DONE_MARKER"; then
            log_info "Already normalized: $BASENAME"
            continue
        fi

        EXT="${FILE##*.}"
        TMPFILE="${FILE%.${EXT}}.norm.${EXT}"

        # Probe source bitrate so the normalized file doesn't lose quality
        # Try stream-level first, fall back to format-level (opus reports N/A at stream level)
        SRC_BR=$(ffprobe -v error -show_entries stream=bit_rate -of csv=p=0 -- "$FILE" 2>/dev/null | tr -d '[:space:]')
        if [[ -z "$SRC_BR" || "$SRC_BR" == "N/A" ]]; then
            SRC_BR=$(ffprobe -v error -show_entries format=bit_rate -of csv=p=0 -- "$FILE" 2>/dev/null | tr -d '[:space:]')
        fi
        BR_ARGS=()
        if [[ -n "$SRC_BR" && "$SRC_BR" =~ ^[0-9]+$ && "$SRC_BR" -gt 0 ]]; then
            BR_ARGS+=(-b:a "${SRC_BR}")
        fi

        # Pass 1: measure loudness stats
        STATS=$(ffmpeg -y -i "$FILE" -af loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json -f null /dev/null 2>&1 \
            | tail -n 12) || true
        INPUT_I=$(echo "$STATS" | grep -o '"input_i" *: *"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
        INPUT_TP=$(echo "$STATS" | grep -o '"input_tp" *: *"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
        INPUT_LRA=$(echo "$STATS" | grep -o '"input_lra" *: *"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
        INPUT_THRESH=$(echo "$STATS" | grep -o '"input_thresh" *: *"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')

        if [[ -z "$INPUT_I" || -z "$INPUT_TP" || -z "$INPUT_LRA" || -z "$INPUT_THRESH" ]]; then
            # Fallback to single-pass if measurement fails
            log_warn "Two-pass measurement failed for $BASENAME, trying single-pass."
            if ffmpeg -y -i "$FILE" -af loudnorm=I=-16:TP=-1.5:LRA=11 "${BR_ARGS[@]}" "$TMPFILE" > "$REDIR" 2>&1; then
                mv "$TMPFILE" "$FILE"
                echo "$BASENAME" >> "$NORM_DONE_MARKER"
                log_info "Normalized (single-pass): $BASENAME"
            else
                log_warn "Could not normalize $BASENAME, keeping original."
                rm -f "$TMPFILE"
            fi
            continue
        fi

        # Pass 2: apply measured values
        if ffmpeg -y -i "$FILE" -af \
            "loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=${INPUT_I}:measured_TP=${INPUT_TP}:measured_LRA=${INPUT_LRA}:measured_thresh=${INPUT_THRESH}:linear=true" \
            "${BR_ARGS[@]}" "$TMPFILE" > "$REDIR" 2>&1; then
            mv "$TMPFILE" "$FILE"
            echo "$BASENAME" >> "$NORM_DONE_MARKER"
            log_info "Normalized: $BASENAME"
        else
            log_warn "Could not normalize $BASENAME, keeping original."
            rm -f "$TMPFILE"
        fi
    done
    shopt -u nullglob
else
    log_step "[3/6] Skipping audio normalization."
fi

# ---------- Step 4: concat list + chapter metadata ----------
log_step "[4/6] Building concat list and chapter metadata..."

# Generate silence file for chapter gaps if needed
GAP_MS=0
SILENCE_FILE=""
if [[ $(awk -v g="$CHAPTER_GAP" 'BEGIN { print (g > 0) }') -eq 1 ]]; then
    GAP_MS=$(awk -v g="$CHAPTER_GAP" 'BEGIN { printf "%d", g * 1000 }')
    SILENCE_FILE="$WORKDIR/_silence.wav"
    ffmpeg -y -f lavfi -i "anullsrc=r=44100:cl=mono" -t "$CHAPTER_GAP" "$SILENCE_FILE" > "$REDIR" 2>&1
fi

# Collect audio files sorted by name
mapfile -t AUDIO_FILES < <(find "$WORKDIR" -maxdepth 1 -type f \
    \( -name "*.webm" -o -name "*.opus" -o -name "*.m4a" \
       -o -name "*.mp3"  -o -name "*.ogg"  -o -name "*.wav" \
       -o -name "*.flac" -o -name "*.aac" \) \
    ! -name "_silence.wav" | sort)

if [[ ${#AUDIO_FILES[@]} -eq 0 ]]; then
    echo "Error: No audio files were downloaded." >&2
    exit 1
fi
log_info "Found ${#AUDIO_FILES[@]} audio file(s)."

> "$LIST_TXT"
CHAPTER_LINES=()
CUMULATIVE_MS=0
HAS_CHAPTERS=1

for i in "${!AUDIO_FILES[@]}"; do
    FILE="${AUDIO_FILES[$i]}"

    # Insert silence gap between chapters (not before the first)
    if [[ -n "$SILENCE_FILE" && $i -gt 0 ]]; then
        FORWARD_SIL="${SILENCE_FILE//\\//}"
        ESCAPED_SIL="${FORWARD_SIL//\'/\'\\\'\'}"
        echo "file '${ESCAPED_SIL}'" >> "$LIST_TXT"
        CUMULATIVE_MS=$((CUMULATIVE_MS + GAP_MS))
    fi

    FORWARD_FILE="${FILE//\\//}"
    ESCAPED_FILE="${FORWARD_FILE//\'/\'\\\'\'}"
    echo "file '${ESCAPED_FILE}'" >> "$LIST_TXT"

    DURATION_STR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 -- "$FILE" 2>/dev/null || true)
    DURATION_STR=$(echo "$DURATION_STR" | tr -d '[:space:]')

    if [[ -z "$DURATION_STR" ]] || ! [[ "$DURATION_STR" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_warn "Could not determine duration for $(basename "$FILE"), skipping chapter markers."
        HAS_CHAPTERS=0
        CHAPTER_LINES=()
        break
    fi

    START_MS=$CUMULATIVE_MS
    END_MS=$(awk -v cum="$CUMULATIVE_MS" -v dur="$DURATION_STR" 'BEGIN { printf "%d", cum + dur * 1000 }')
    CUMULATIVE_MS=$END_MS

    # Strip leading index and extension to get chapter title
    BASENAME=$(basename "$FILE")
    CHAPTER_TITLE="${BASENAME%.*}"
    CHAPTER_TITLE=$(echo "$CHAPTER_TITLE" | sed 's/^[0-9]\+[[:space:]]*-[[:space:]]*//')
    # Escape special characters for ffmetadata format
    CHAPTER_TITLE="${CHAPTER_TITLE//\\/\\\\}"
    CHAPTER_TITLE="${CHAPTER_TITLE//=/\\=}"
    CHAPTER_TITLE="${CHAPTER_TITLE//;/\\;}"
    CHAPTER_TITLE="${CHAPTER_TITLE//#/\\#}"

    CHAPTER_LINES+=("[CHAPTER]")
    CHAPTER_LINES+=("TIMEBASE=1/1000")
    CHAPTER_LINES+=("START=$START_MS")
    CHAPTER_LINES+=("END=$END_MS")
    CHAPTER_LINES+=("title=$CHAPTER_TITLE")
done

if [[ $HAS_CHAPTERS -eq 1 && ${#CHAPTER_LINES[@]} -gt 0 ]]; then
    {
        echo ";FFMETADATA1"
        printf '%s\n' "${CHAPTER_LINES[@]}"
    } > "$CHAPTER_TXT"
    log_info "Generated ${#AUDIO_FILES[@]} chapter marker(s)."
fi

# ---------- Step 5: thumbnail / cover art ----------
log_step "[5/6] Preparing cover art..."

HAS_COVER=0
if [[ -n "$COVER" ]]; then
    # Use user-provided cover image
    cp "$COVER" "$COVER_JPG"
    HAS_COVER=1
    log_info "Using custom cover: $COVER"
else
    yt-dlp \
        --skip-download \
        --write-thumbnail \
        --convert-thumbnails jpg \
        --playlist-items 1 \
        -o "$WORKDIR/cover" \
        -- "$URL" > "$REDIR" 2>&1 || true

    [[ -f "$COVER_JPG" ]] && HAS_COVER=1
    if [[ $HAS_COVER -eq 0 ]]; then
        log_warn "No thumbnail found, proceeding without cover art."
    fi
fi

# ---------- Step 6: encode M4B ----------
log_step "[6/6] Encoding M4B..."

# Build inputs first, then output options (ffmpeg requires all -i before output flags)
FFMPEG_ARGS=(-y -f concat -safe 0 -i "$LIST_TXT")
CHAPTERS_INPUT=0

if [[ $HAS_CHAPTERS -eq 1 && -f "$CHAPTER_TXT" ]]; then
    FFMPEG_ARGS+=(-i "$CHAPTER_TXT")
    CHAPTERS_INPUT=1
fi

if [[ $HAS_COVER -eq 1 ]]; then
    FFMPEG_ARGS+=(-i "$COVER_JPG")
fi

# Output options
if [[ $CHAPTERS_INPUT -eq 1 ]]; then
    FFMPEG_ARGS+=(-map_metadata 1 -map_chapters 1)
fi

if [[ $HAS_COVER -eq 1 ]]; then
    COVER_STREAM_INDEX=$(( CHAPTERS_INPUT == 1 ? 2 : 1 ))
    FFMPEG_ARGS+=(-map 0:a -map "${COVER_STREAM_INDEX}:v")
    FFMPEG_ARGS+=(-c:v mjpeg -disposition:v:0 attached_pic)
else
    FFMPEG_ARGS+=(-map 0:a)
fi

FFMPEG_ARGS+=(
    -c:a aac -b:a "${BITRATE}k"
    -metadata "title=$TITLE"
    -metadata "artist=$ARTIST"
    -metadata "album=$ALBUM"
    -metadata "genre=Audiobook"
    "$OUT_M4B"
)

ffmpeg "${FFMPEG_ARGS[@]}" > "$REDIR" 2>&1

# ---------- cleanup ----------
# Trap handler covers workdir removal; disable it if -k was given
if [[ $KEEP -eq 1 ]]; then
    trap - EXIT
    log_info "Keeping work files in: $WORKDIR"
else
    log_info "Cleaning up work files..."
    # Let the EXIT trap handle it
fi

log_ok "Done: $OUT_M4B"
