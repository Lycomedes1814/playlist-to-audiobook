#!/usr/bin/env bash
# playlist-to-audiobook.sh
# Converts a YouTube playlist to a single M4B audiobook file with chapters and cover art.
#
# Dependencies: yt-dlp, ffmpeg, ffprobe
#
# Usage:
#   playlist-to-audiobook.sh -u <url> [-o <output-name>] [-t <title>]
#                                  [-a <artist>] [-l <album>] [-b <bitrate-kbps>]
#                                  [-k] [-n]
#
# Options:
#   -u, --url            URL of the YouTube playlist (required)
#   -o, --output         Output filename (without extension); defaults to playlist title
#   -t, --title          Title metadata tag; defaults to playlist title
#   -a, --artist         Artist metadata tag; defaults to playlist uploader
#   -l, --album          Album metadata tag; defaults to playlist title
#   -b, --bitrate        Audio bitrate in kbps; defaults to 160
#   -k, --keep           Keep downloaded files after encoding
#   -n, --no-normalize   Skip per-file audio normalization (EBU R128)

set -euo pipefail

# ---------- defaults ----------
URL=""
OUTPUT_NAME=""
TITLE=""
ARTIST=""
ALBUM=""
BITRATE=160
KEEP=0
NORMALIZE=1

# ---------- parse args ----------
PARSED=$(getopt -o u:o:t:a:l:b:kn \
    --long url:,output:,title:,artist:,album:,bitrate:,keep,no-normalize \
    -n "$(basename "$0")" -- "$@") || exit 1
eval set -- "$PARSED"

while true; do
    case "$1" in
        -u|--url)     URL="$2";         shift 2 ;;
        -o|--output)  OUTPUT_NAME="$2"; shift 2 ;;
        -t|--title)   TITLE="$2";       shift 2 ;;
        -a|--artist)  ARTIST="$2";      shift 2 ;;
        -l|--album)   ALBUM="$2";       shift 2 ;;
        -b|--bitrate) BITRATE="$2";     shift 2 ;;
        -k|--keep)         KEEP=1;           shift ;;
        -n|--no-normalize) NORMALIZE=0;      shift ;;
        --) shift; break ;;
        *)  echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$URL" ]]; then
    echo "Usage: $(basename "$0") -u|--url <url> [-o|--output <name>] [-t|--title <title>] [-a|--artist <artist>] [-l|--album <album>] [-b|--bitrate <kbps>] [-k|--keep] [-n|--no-normalize]" >&2
    exit 1
fi

if ! [[ "$BITRATE" =~ ^[0-9]+$ ]] || [[ "$BITRATE" -eq 0 ]]; then
    echo "Error: Bitrate (-b) must be a positive integer." >&2
    exit 1
fi

for cmd in yt-dlp ffmpeg ffprobe; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' is not installed or not in PATH." >&2
        exit 1
    fi
done

# ---------- Step 1: playlist metadata ----------
echo -e "\033[0;36m[1/6] Fetching playlist metadata...\033[0m"
META=$(yt-dlp --flat-playlist --playlist-items 1 --print "%(playlist_title)s	%(uploader)s" -- "$URL" 2>/dev/null) || {
    echo -e "  \033[0;33mWarning: Could not fetch playlist metadata, using defaults.\033[0m"
}
PLAYLIST_TITLE=$(echo "$META" | head -n1 | cut -f1)
UPLOADER=$(echo "$META" | head -n1 | cut -f2)
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

LIST_TXT="$WORKDIR/list.txt"
CHAPTER_TXT="$WORKDIR/chapters.txt"
COVER_JPG="$WORKDIR/cover.jpg"
OUT_M4B="$(pwd)/${SAFE_OUTPUT_NAME}.m4b"

# ---------- Step 2: download audio ----------
echo -e "\033[0;36m[2/6] Downloading playlist audio...\033[0m"
yt-dlp \
    --yes-playlist \
    --no-overwrites \
    --retries infinite \
    --fragment-retries infinite \
    -x \
    -f "bestaudio" \
    -o "$WORKDIR/%(playlist_index)03d - %(title)s.%(ext)s" \
    -- "$URL"

# ---------- Step 3: normalize audio ----------
if [[ $NORMALIZE -eq 1 ]]; then
    echo -e "\033[0;36m[3/6] Normalizing audio (EBU R128)...\033[0m"
    shopt -s nullglob
    for FILE in "$WORKDIR"/*.{webm,opus,m4a,mp3,ogg,wav,flac,aac}; do
        EXT="${FILE##*.}"
        TMPFILE="${FILE%.${EXT}}.norm.${EXT}"
        if ffmpeg -y -i "$FILE" -af loudnorm=I=-16:TP=-1.5:LRA=11 "$TMPFILE" 2>/dev/null; then
            mv "$TMPFILE" "$FILE"
            echo -e "  \033[0;37mNormalized: $(basename "$FILE")\033[0m"
        else
            echo -e "  \033[0;33mWarning: Could not normalize $(basename "$FILE"), keeping original.\033[0m"
            rm -f "$TMPFILE"
        fi
    done
    shopt -u nullglob
else
    echo -e "\033[0;36m[3/6] Skipping audio normalization.\033[0m"
fi

# ---------- Step 4: concat list + chapter metadata ----------
echo -e "\033[0;36m[4/6] Building concat list and chapter metadata...\033[0m"

# Collect audio files sorted by name
mapfile -t AUDIO_FILES < <(find "$WORKDIR" -maxdepth 1 -type f \
    \( -name "*.webm" -o -name "*.opus" -o -name "*.m4a" \
       -o -name "*.mp3"  -o -name "*.ogg"  -o -name "*.wav" \
       -o -name "*.flac" -o -name "*.aac" \) | sort)

if [[ ${#AUDIO_FILES[@]} -eq 0 ]]; then
    echo "Error: No audio files were downloaded." >&2
    exit 1
fi
echo -e "  \033[0;37mFound ${#AUDIO_FILES[@]} audio file(s).\033[0m"

> "$LIST_TXT"
CHAPTER_LINES=()
CUMULATIVE_MS=0
HAS_CHAPTERS=1

for FILE in "${AUDIO_FILES[@]}"; do
    FORWARD_FILE="${FILE//\\//}"
    ESCAPED_FILE="${FORWARD_FILE//\'/\'\\\'\'}"
    echo "file '${ESCAPED_FILE}'" >> "$LIST_TXT"

    DURATION_STR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 -- "$FILE" 2>/dev/null || true)
    DURATION_STR=$(echo "$DURATION_STR" | tr -d '[:space:]')

    if [[ -z "$DURATION_STR" ]] || ! [[ "$DURATION_STR" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo -e "  \033[0;33mWarning: Could not determine duration for $(basename "$FILE"), skipping chapter markers.\033[0m"
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
    echo -e "  \033[0;37mGenerated ${#AUDIO_FILES[@]} chapter marker(s).\033[0m"
fi

# ---------- Step 5: thumbnail ----------
echo -e "\033[0;36m[5/6] Downloading thumbnail...\033[0m"
yt-dlp \
    --skip-download \
    --write-thumbnail \
    --convert-thumbnails jpg \
    --playlist-items 1 \
    -o "$WORKDIR/cover" \
    -- "$URL" || true

HAS_COVER=0
[[ -f "$COVER_JPG" ]] && HAS_COVER=1
if [[ $HAS_COVER -eq 0 ]]; then
    echo -e "  \033[0;33mNo thumbnail found, proceeding without cover art.\033[0m"
fi

# ---------- Step 6: encode M4B ----------
echo -e "\033[0;36m[6/6] Encoding M4B...\033[0m"

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

ffmpeg "${FFMPEG_ARGS[@]}"

# ---------- cleanup ----------
if [[ $KEEP -eq 0 ]]; then
    echo -e "  \033[0;37mCleaning up work files...\033[0m"
    rm -rf "$WORKDIR"
fi

echo -e "\033[0;32mDone: $OUT_M4B\033[0m"
