#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAIN_SCRIPT="$SCRIPT_DIR/playlist-to-audiobook.sh"
TEST_URL="https://www.youtube.com/playlist?list=PLTTyjqCYL18SZ7KGzttmuhjrWl2eb6SjY"
TEST_ROOT="$SCRIPT_DIR/test-output"
VERBOSE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [-v|--verbose]

Runs a small integration test suite against:
  $TEST_URL

Options:
  -v, --verbose   Show command output and assertion details
  -h, --help      Show this help message

The suite covers:
  - input validation (missing URL, bad bitrate, bad chapter-gap, missing dir/cover, help)
  - dry-run behavior (combined and split modes)
  - normalized end-to-end conversion with chapter gaps
  - no-normalize conversion path
  - split mode (one M4B per item, per-item cover art)
  - M4B output verification (metadata tags, chapters, cover art)
  - custom cover image and bitrate
  - workdir cleanup when -k is not used
  - single-video URL (non-playlist code path)
  - expected properties of kept temp files

Outputs are written under:
  $TEST_ROOT
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -v|--verbose) VERBOSE=1; shift ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

verbose() {
    [[ "$VERBOSE" -eq 1 ]] && echo "    $*" || true
}

info() {
    echo "==> $*"
}

assert_file_exists() {
    local path="$1"
    [[ -f "$path" ]] || fail "Expected file to exist: $path"
    verbose "OK: file exists: $path"
}

assert_dir_exists() {
    local path="$1"
    [[ -d "$path" ]] || fail "Expected directory to exist: $path"
    verbose "OK: dir exists: $path"
}

assert_not_exists() {
    local path="$1"
    [[ ! -e "$path" ]] || fail "Expected path to be absent: $path"
    verbose "OK: absent: $path"
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [[ "$expected" == "$actual" ]] || fail "$message (expected '$expected', got '$actual')"
    verbose "OK: $message ('$actual')"
}

assert_contains() {
    local needle="$1"
    local file="$2"
    grep -Fq -- "$needle" "$file" || fail "Expected '$file' to contain: $needle"
    verbose "OK: '$file' contains: $needle"
}

assert_all_list_entries_absolute() {
    local file="$1"

    while IFS= read -r line; do
        [[ "$line" =~ ^file\ \'/.+\'$ ]] || fail "Expected absolute concat entry in $file, got: $line"
    done < "$file"
    verbose "OK: all concat entries absolute in $file"
}

assert_ffprobe_value() {
    local file="$1"
    local entry="$2"
    local expected="$3"
    local actual

    actual=$(ffprobe -v error -select_streams a:0 -show_entries "stream=$entry" -of default=noprint_wrappers=1:nokey=1 -- "$file")
    [[ -n "$actual" ]] || fail "ffprobe returned no value for $entry on $file"
    assert_eq "$expected" "$actual" "ffprobe $entry for $(basename "$file")"
}

assert_chapter_count() {
    local file="$1"
    local expected="$2"
    local actual

    actual=$(grep -c '^\[CHAPTER\]$' "$file")
    assert_eq "$expected" "$actual" "chapter count in $file"
}

assert_m4b_count() {
    local dir="$1"
    local expected="$2"
    local actual
    actual=$(find "$dir" -maxdepth 1 -name "*.m4b" | wc -l | tr -d '[:space:]')
    assert_eq "$expected" "$actual" "M4B count in $dir"
}

assert_m4b_audio_valid() {
    local file="$1"
    local codec
    codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 -- "$file" 2>/dev/null)
    [[ "$codec" == "aac" ]] || fail "Expected AAC audio in $file, got: $codec"
    verbose "OK: valid AAC audio in $(basename "$file")"
}

assert_prep_marker_pairs() {
    local marker="$1"
    local expected_audio_files="$2"
    local lines

    lines=$(wc -l < "$marker" | tr -d '[:space:]')
    assert_eq "$(( expected_audio_files * 2 ))" "$lines" "prep marker entry count in $marker"
}

assert_m4b_metadata() {
    local file="$1"
    local key="$2"
    local expected="$3"
    local actual
    actual=$(ffprobe -v error -show_entries format_tags="$key" \
        -of default=noprint_wrappers=1:nokey=1 -- "$file" 2>/dev/null)
    [[ -n "$actual" ]] || fail "No metadata tag '$key' found in $file"
    assert_eq "$expected" "$actual" "metadata '$key' in $(basename "$file")"
}

assert_m4b_has_cover() {
    local file="$1"
    local vstreams
    vstreams=$(ffprobe -v error -select_streams v -show_entries stream=codec_type \
        -of default=noprint_wrappers=1:nokey=1 -- "$file" 2>/dev/null | wc -l | tr -d '[:space:]')
    [[ "$vstreams" -ge 1 ]] || fail "Expected cover art (video stream) in $file"
    verbose "OK: cover art present in $(basename "$file")"
}

assert_m4b_chapter_count() {
    local file="$1"
    local expected="$2"
    local actual
    actual=$(ffprobe -v error -show_chapters -- "$file" 2>/dev/null \
        | grep -c '^\[CHAPTER\]' || true)
    assert_eq "$expected" "$actual" "M4B chapter count in $(basename "$file")"
}

assert_no_workdir() {
    local dir="$1"
    local output_name="$2"
    local matches=()

    shopt -s nullglob
    matches=("$dir"/"${output_name}.work."*)
    shopt -u nullglob

    [[ ${#matches[@]} -eq 0 ]] || fail "Expected workdir to be cleaned up, but found: ${matches[*]}"
    verbose "OK: workdir cleaned up for $output_name in $dir"
}

find_workdir() {
    local case_dir="$1"
    local output_name="$2"
    local matches=()

    shopt -s nullglob
    matches=("$case_dir"/"${output_name}.work."*)
    shopt -u nullglob

    [[ ${#matches[@]} -eq 1 ]] || fail "Expected exactly one workdir for $output_name in $case_dir"
    printf '%s\n' "${matches[0]}"
}

run_expect_success() {
    local logfile="$1"
    shift

    verbose "RUN: $*"
    if ! "$@" >"$logfile" 2>&1; then
        cat "$logfile" >&2
        fail "Command failed: $*"
    fi
    if [[ "$VERBOSE" -eq 1 ]]; then
        sed 's/^/    | /' "$logfile"
    fi
}

run_expect_failure() {
    local logfile="$1"
    shift

    verbose "RUN (expect fail): $*"
    if "$@" >"$logfile" 2>&1; then
        cat "$logfile" >&2
        fail "Command unexpectedly succeeded: $*"
    fi
    if [[ "$VERBOSE" -eq 1 ]]; then
        sed 's/^/    | /' "$logfile"
    fi
}

if [[ ! -x "$MAIN_SCRIPT" ]]; then
    fail "Main script is not executable: $MAIN_SCRIPT"
fi

for cmd in yt-dlp ffmpeg ffprobe python3; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Missing dependency: $cmd"
done

rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT"

info "Dry-run should report the plan and not create output files"
DRY_RUN_DIR="$TEST_ROOT/dry-run"
mkdir -p "$DRY_RUN_DIR"
DRY_RUN_LOG="$DRY_RUN_DIR/run.log"
run_expect_success "$DRY_RUN_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$DRY_RUN_DIR" \
    -o "dry-run-check" \
    --dry-run
assert_contains "Dry run" "$DRY_RUN_LOG"
assert_contains "Output:     $DRY_RUN_DIR/dry-run-check.m4b" "$DRY_RUN_LOG"
assert_not_exists "$DRY_RUN_DIR/dry-run-check.m4b"

info "Invalid bitrate should fail before any network work"
INVALID_BITRATE_DIR="$TEST_ROOT/invalid-bitrate"
mkdir -p "$INVALID_BITRATE_DIR"
INVALID_BITRATE_LOG="$INVALID_BITRATE_DIR/run.log"
run_expect_failure "$INVALID_BITRATE_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$INVALID_BITRATE_DIR" \
    -o "invalid-bitrate" \
    -b 0
assert_contains "Bitrate (-b) must be a positive integer" "$INVALID_BITRATE_LOG"

info "Missing cover file should fail validation"
MISSING_COVER_DIR="$TEST_ROOT/missing-cover"
mkdir -p "$MISSING_COVER_DIR"
MISSING_COVER_LOG="$MISSING_COVER_DIR/run.log"
run_expect_failure "$MISSING_COVER_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$MISSING_COVER_DIR" \
    -o "missing-cover" \
    -c "$MISSING_COVER_DIR/does-not-exist.jpg"
assert_contains "Cover image not found" "$MISSING_COVER_LOG"

info "Missing URL should fail with usage hint"
MISSING_URL_DIR="$TEST_ROOT/missing-url"
mkdir -p "$MISSING_URL_DIR"
MISSING_URL_LOG="$MISSING_URL_DIR/run.log"
run_expect_failure "$MISSING_URL_LOG" \
    "$MAIN_SCRIPT"
assert_contains "url" "$MISSING_URL_LOG"

info "Non-numeric bitrate should fail validation"
STRING_BITRATE_DIR="$TEST_ROOT/string-bitrate"
mkdir -p "$STRING_BITRATE_DIR"
STRING_BITRATE_LOG="$STRING_BITRATE_DIR/run.log"
run_expect_failure "$STRING_BITRATE_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -b "abc"
assert_contains "Bitrate (-b) must be a positive integer" "$STRING_BITRATE_LOG"

info "Invalid chapter-gap should fail validation"
BAD_GAP_DIR="$TEST_ROOT/bad-chapter-gap"
mkdir -p "$BAD_GAP_DIR"
BAD_GAP_LOG="$BAD_GAP_DIR/run.log"
run_expect_failure "$BAD_GAP_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    --chapter-gap "abc"
assert_contains "Chapter gap (--chapter-gap) must be a non-negative number" "$BAD_GAP_LOG"

info "Non-existent output directory should fail validation"
BAD_DIR_LOG="$TEST_ROOT/bad-dir.log"
run_expect_failure "$BAD_DIR_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "/tmp/playlist-to-audiobook-nonexistent-dir-$$"
assert_contains "Output directory does not exist" "$BAD_DIR_LOG"

info "--help should exit successfully and show usage"
HELP_LOG="$TEST_ROOT/help.log"
run_expect_success "$HELP_LOG" \
    "$MAIN_SCRIPT" --help
assert_contains "Usage:" "$HELP_LOG"
assert_contains "--url" "$HELP_LOG"

info "Normalized run should create concat-safe WAV temp files, cover art, silence gap, and chapters"
NORMALIZED_DIR="$TEST_ROOT/normalized"
mkdir -p "$NORMALIZED_DIR"
NORMALIZED_LOG="$NORMALIZED_DIR/run.log"
run_expect_success "$NORMALIZED_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$NORMALIZED_DIR" \
    -o "normalized-case" \
    -t "Normalized Case" \
    -l "Normalized Case" \
    -i "1-2" \
    --chapter-gap 1 \
    -k
NORMALIZED_OUT="$NORMALIZED_DIR/normalized-case.m4b"
NORMALIZED_WORKDIR=$(find_workdir "$NORMALIZED_DIR" "normalized-case")
assert_file_exists "$NORMALIZED_OUT"
assert_dir_exists "$NORMALIZED_WORKDIR"
assert_file_exists "$NORMALIZED_WORKDIR/list.txt"
assert_file_exists "$NORMALIZED_WORKDIR/chapters.txt"
assert_file_exists "$NORMALIZED_WORKDIR/cover.jpg"
assert_file_exists "$NORMALIZED_WORKDIR/_silence.wav"
assert_file_exists "$NORMALIZED_WORKDIR/.prep_done"
assert_chapter_count "$NORMALIZED_WORKDIR/chapters.txt" 2
assert_contains "_silence.wav" "$NORMALIZED_WORKDIR/list.txt"
assert_all_list_entries_absolute "$NORMALIZED_WORKDIR/list.txt"
assert_prep_marker_pairs "$NORMALIZED_WORKDIR/.prep_done" 2
for wav in "$NORMALIZED_WORKDIR"/*.wav; do
    [[ "$(basename "$wav")" == "_silence.wav" ]] && continue
    assert_ffprobe_value "$wav" sample_rate 48000
    assert_ffprobe_value "$wav" channels 2
done
assert_m4b_metadata "$NORMALIZED_OUT" "title" "Normalized Case"
assert_m4b_metadata "$NORMALIZED_OUT" "album" "Normalized Case"
assert_m4b_metadata "$NORMALIZED_OUT" "genre" "Audiobook"
assert_m4b_has_cover "$NORMALIZED_OUT"
assert_m4b_chapter_count "$NORMALIZED_OUT" 2

info "No-normalize run should still create WAV intermediates and chapters without silence gaps"
NO_NORM_DIR="$TEST_ROOT/no-normalize"
mkdir -p "$NO_NORM_DIR"
NO_NORM_LOG="$NO_NORM_DIR/run.log"
run_expect_success "$NO_NORM_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$NO_NORM_DIR" \
    -o "no-normalize-case" \
    -t "No Normalize Case" \
    -l "No Normalize Case" \
    -i "1-2" \
    -n \
    -k
NO_NORM_OUT="$NO_NORM_DIR/no-normalize-case.m4b"
NO_NORM_WORKDIR=$(find_workdir "$NO_NORM_DIR" "no-normalize-case")
assert_file_exists "$NO_NORM_OUT"
assert_dir_exists "$NO_NORM_WORKDIR"
assert_file_exists "$NO_NORM_WORKDIR/list.txt"
assert_file_exists "$NO_NORM_WORKDIR/chapters.txt"
assert_file_exists "$NO_NORM_WORKDIR/.prep_done"
assert_chapter_count "$NO_NORM_WORKDIR/chapters.txt" 2
assert_not_exists "$NO_NORM_WORKDIR/_silence.wav"
assert_all_list_entries_absolute "$NO_NORM_WORKDIR/list.txt"
assert_prep_marker_pairs "$NO_NORM_WORKDIR/.prep_done" 2
assert_not_exists "$NO_NORM_WORKDIR/001 - Edvard Grieg – Lyric Pieces.opus"
assert_not_exists "$NO_NORM_WORKDIR/002 - J. S. Bach – Prelude in C Major.opus"
for wav in "$NO_NORM_WORKDIR"/*.wav; do
    assert_ffprobe_value "$wav" sample_rate 48000
    assert_ffprobe_value "$wav" channels 2
done
assert_m4b_metadata "$NO_NORM_OUT" "title" "No Normalize Case"
assert_m4b_metadata "$NO_NORM_OUT" "album" "No Normalize Case"
assert_m4b_metadata "$NO_NORM_OUT" "genre" "Audiobook"
assert_m4b_chapter_count "$NO_NORM_OUT" 2

info "Relative output directories should also produce absolute concat paths and a valid M4B"
RELATIVE_DIR="test-output/relative-output"
mkdir -p "$RELATIVE_DIR"
RELATIVE_LOG="$RELATIVE_DIR/run.log"
run_expect_success "$RELATIVE_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$RELATIVE_DIR" \
    -o "relative-case" \
    -i "1-2" \
    -n \
    -k
RELATIVE_OUT="$RELATIVE_DIR/relative-case.m4b"
RELATIVE_WORKDIR=$(find_workdir "$RELATIVE_DIR" "relative-case")
assert_file_exists "$RELATIVE_OUT"
assert_file_exists "$RELATIVE_WORKDIR/list.txt"
assert_file_exists "$RELATIVE_WORKDIR/chapters.txt"
assert_all_list_entries_absolute "$RELATIVE_WORKDIR/list.txt"
assert_chapter_count "$RELATIVE_WORKDIR/chapters.txt" 2

info "Split dry-run should report split mode and output dir, not a single output file"
SPLIT_DRY_DIR="$TEST_ROOT/split-dry-run"
mkdir -p "$SPLIT_DRY_DIR"
SPLIT_DRY_LOG="$SPLIT_DRY_DIR/run.log"
run_expect_success "$SPLIT_DRY_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$SPLIT_DRY_DIR" \
    -s \
    --dry-run
assert_contains "split (one M4B per item)" "$SPLIT_DRY_LOG"
assert_contains "Output dir:" "$SPLIT_DRY_LOG"
assert_m4b_count "$SPLIT_DRY_DIR" 0

info "Split normalized run should produce one M4B per item with per-item thumbnails"
SPLIT_NORM_DIR="$TEST_ROOT/split-normalized"
mkdir -p "$SPLIT_NORM_DIR"
SPLIT_NORM_LOG="$SPLIT_NORM_DIR/run.log"
run_expect_success "$SPLIT_NORM_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$SPLIT_NORM_DIR" \
    -o "split-norm-case" \
    -i "1-2" \
    -s \
    -k
assert_m4b_count "$SPLIT_NORM_DIR" 2
SPLIT_NORM_WORKDIR=$(find_workdir "$SPLIT_NORM_DIR" "split-norm-case")
# Per-item thumbnails should have been downloaded into workdir
THUMB_COUNT=$(find "$SPLIT_NORM_WORKDIR" -maxdepth 1 -name "*.jpg" | wc -l | tr -d '[:space:]')
[[ "$THUMB_COUNT" -ge 1 ]] || fail "Expected at least one per-item thumbnail in $SPLIT_NORM_WORKDIR"
# Each M4B should contain valid AAC audio with metadata and cover
for m4b in "$SPLIT_NORM_DIR"/*.m4b; do
    assert_m4b_audio_valid "$m4b"
    assert_m4b_metadata "$m4b" "genre" "Audiobook"
    assert_m4b_has_cover "$m4b"
done

info "Split no-normalize run should also produce one M4B per item"
SPLIT_NONORM_DIR="$TEST_ROOT/split-no-normalize"
mkdir -p "$SPLIT_NONORM_DIR"
SPLIT_NONORM_LOG="$SPLIT_NONORM_DIR/run.log"
run_expect_success "$SPLIT_NONORM_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$SPLIT_NONORM_DIR" \
    -i "1-2" \
    -s \
    -n
assert_m4b_count "$SPLIT_NONORM_DIR" 2
for m4b in "$SPLIT_NONORM_DIR"/*.m4b; do
    assert_m4b_audio_valid "$m4b"
done

info "Split mode should avoid overwriting an existing sanitized output filename"
SPLIT_COLLISION_DIR="$TEST_ROOT/split-collision"
mkdir -p "$SPLIT_COLLISION_DIR"
PREEXISTING_SPLIT_OUT="$SPLIT_COLLISION_DIR/Edvard Grieg – Lyric Pieces.m4b"
printf 'placeholder\n' > "$PREEXISTING_SPLIT_OUT"
SPLIT_COLLISION_LOG="$SPLIT_COLLISION_DIR/run.log"
run_expect_success "$SPLIT_COLLISION_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$SPLIT_COLLISION_DIR" \
    -i "1" \
    -s \
    -n
assert_file_exists "$PREEXISTING_SPLIT_OUT"
assert_file_exists "$SPLIT_COLLISION_DIR/Edvard Grieg – Lyric Pieces (2).m4b"
assert_m4b_audio_valid "$SPLIT_COLLISION_DIR/Edvard Grieg – Lyric Pieces (2).m4b"
assert_contains "filename collision" "$SPLIT_COLLISION_LOG"

info "Split mode should fail the run if per-item encoding fails"
SPLIT_FAIL_DIR="$TEST_ROOT/split-failure"
mkdir -p "$SPLIT_FAIL_DIR"
BAD_SPLIT_COVER="$SPLIT_FAIL_DIR/bad-cover.jpg"
printf 'not an image\n' > "$BAD_SPLIT_COVER"
SPLIT_FAIL_LOG="$SPLIT_FAIL_DIR/run.log"
run_expect_failure "$SPLIT_FAIL_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$SPLIT_FAIL_DIR" \
    -i "1" \
    -s \
    -n \
    -c "$BAD_SPLIT_COVER"
assert_contains "Failed to encode 1 playlist item(s) in split mode" "$SPLIT_FAIL_LOG"

info "Workdir should be cleaned up when -k is not used"
CLEANUP_DIR="$TEST_ROOT/cleanup"
mkdir -p "$CLEANUP_DIR"
CLEANUP_LOG="$CLEANUP_DIR/run.log"
run_expect_success "$CLEANUP_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$CLEANUP_DIR" \
    -o "cleanup-case" \
    -i "1" \
    -n
assert_file_exists "$CLEANUP_DIR/cleanup-case.m4b"
assert_no_workdir "$CLEANUP_DIR" "cleanup-case"

info "Custom cover image should be embedded in the output M4B"
CUSTOM_COVER_DIR="$TEST_ROOT/custom-cover"
mkdir -p "$CUSTOM_COVER_DIR"
CUSTOM_COVER_IMG="$CUSTOM_COVER_DIR/test-cover.jpg"
# Generate a minimal valid JPEG via ffmpeg
ffmpeg -y -f lavfi -i "color=c=red:s=2x2:d=1" -frames:v 1 -update 1 "$CUSTOM_COVER_IMG" >/dev/null 2>&1
CUSTOM_COVER_LOG="$CUSTOM_COVER_DIR/run.log"
run_expect_success "$CUSTOM_COVER_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$CUSTOM_COVER_DIR" \
    -o "custom-cover-case" \
    -i "1" \
    -c "$CUSTOM_COVER_IMG" \
    -n
CUSTOM_COVER_OUT="$CUSTOM_COVER_DIR/custom-cover-case.m4b"
assert_file_exists "$CUSTOM_COVER_OUT"
assert_m4b_has_cover "$CUSTOM_COVER_OUT"

info "Custom bitrate should be reflected in the output M4B"
BITRATE_DIR="$TEST_ROOT/custom-bitrate"
mkdir -p "$BITRATE_DIR"
BITRATE_LOG="$BITRATE_DIR/run.log"
run_expect_success "$BITRATE_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$BITRATE_DIR" \
    -o "bitrate-case" \
    -i "1" \
    -b 64 \
    -n
BITRATE_OUT="$BITRATE_DIR/bitrate-case.m4b"
assert_file_exists "$BITRATE_OUT"
# AAC bitrate varies, but 64k should be noticeably less than default 160k
BITRATE_ACTUAL=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate \
    -of default=noprint_wrappers=1:nokey=1 -- "$BITRATE_OUT" 2>/dev/null)
# ffprobe reports bits/s; 64kbps = 64000 bps, allow up to 96000 to account for VBR overhead
if [[ -n "$BITRATE_ACTUAL" && "$BITRATE_ACTUAL" =~ ^[0-9]+$ ]]; then
    [[ "$BITRATE_ACTUAL" -le 96000 ]] || fail "Expected bitrate near 64kbps, got ${BITRATE_ACTUAL}bps"
fi

info "Comma-syntax item range should work"
COMMA_DIR="$TEST_ROOT/comma-range"
mkdir -p "$COMMA_DIR"
COMMA_LOG="$COMMA_DIR/run.log"
run_expect_success "$COMMA_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$COMMA_DIR" \
    -o "comma-case" \
    -i "1,2" \
    -n
COMMA_OUT="$COMMA_DIR/comma-case.m4b"
assert_file_exists "$COMMA_OUT"
assert_m4b_chapter_count "$COMMA_OUT" 2

info "Quiet mode should suppress non-error output"
QUIET_DIR="$TEST_ROOT/quiet"
mkdir -p "$QUIET_DIR"
QUIET_LOG="$QUIET_DIR/run.log"
run_expect_success "$QUIET_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$QUIET_DIR" \
    -o "quiet-case" \
    -i "1" \
    -n \
    -q
QUIET_OUT="$QUIET_DIR/quiet-case.m4b"
assert_file_exists "$QUIET_OUT"
# Quiet mode should produce no stdout output
QUIET_LINES=$(wc -l < "$QUIET_LOG" | tr -d '[:space:]')
assert_eq "0" "$QUIET_LINES" "Expected no output in quiet mode"

info "Resolving a single video URL from the test playlist..."
TEST_VIDEO_URL=$(yt-dlp --ignore-config --flat-playlist --playlist-items 1 \
    --print webpage_url -- "$TEST_URL" 2>/dev/null) || {
    fail "Could not resolve a single video URL from the test playlist"
}

info "Single video URL should use the non-playlist code path"
SINGLE_DIR="$TEST_ROOT/single-video"
mkdir -p "$SINGLE_DIR"
SINGLE_LOG="$SINGLE_DIR/run.log"
run_expect_success "$SINGLE_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_VIDEO_URL" \
    -d "$SINGLE_DIR" \
    -o "single-video-case" \
    -t "Single Video Test" \
    -n
SINGLE_OUT="$SINGLE_DIR/single-video-case.m4b"
assert_file_exists "$SINGLE_OUT"
assert_m4b_audio_valid "$SINGLE_OUT"
assert_m4b_metadata "$SINGLE_OUT" "title" "Single Video Test"
assert_m4b_metadata "$SINGLE_OUT" "genre" "Audiobook"

info "Single video dry-run should report 'single video' type"
SINGLE_DRY_LOG="$TEST_ROOT/single-dry.log"
run_expect_success "$SINGLE_DRY_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_VIDEO_URL" \
    --dry-run
assert_contains "single video" "$SINGLE_DRY_LOG"

# ==================== Evil edge cases ====================

info "EVIL: Output name with spaces should survive the entire pipeline"
EVIL_SPACES_DIR="$TEST_ROOT/evil-spaces"
mkdir -p "$EVIL_SPACES_DIR"
EVIL_SPACES_LOG="$EVIL_SPACES_DIR/run.log"
run_expect_success "$EVIL_SPACES_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$EVIL_SPACES_DIR" \
    -o "my audio book (vol 1)" \
    -i "1" \
    -n \
    -k
EVIL_SPACES_OUT="$EVIL_SPACES_DIR/my audio book (vol 1).m4b"
assert_file_exists "$EVIL_SPACES_OUT"
assert_m4b_audio_valid "$EVIL_SPACES_OUT"
# Verify the concat list works with spaces in the workdir path
EVIL_SPACES_WORKDIR=$(find_workdir "$EVIL_SPACES_DIR" "my audio book (vol 1)")
assert_all_list_entries_absolute "$EVIL_SPACES_WORKDIR/list.txt"

info "EVIL: Output name starting with -e should not be swallowed by echo"
EVIL_DASH_DIR="$TEST_ROOT/evil-dash"
mkdir -p "$EVIL_DASH_DIR"
EVIL_DASH_LOG="$EVIL_DASH_DIR/run.log"
run_expect_success "$EVIL_DASH_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$EVIL_DASH_DIR" \
    -o "-evil-name" \
    -i "1" \
    -n
EVIL_DASH_OUT="$EVIL_DASH_DIR/-evil-name.m4b"
assert_file_exists "$EVIL_DASH_OUT"
assert_m4b_audio_valid "$EVIL_DASH_OUT"

info "EVIL: Output directory with spaces and single quote in path"
EVIL_QUOTEDIR="$TEST_ROOT/it's a dir with spaces"
mkdir -p "$EVIL_QUOTEDIR"
EVIL_QUOTEDIR_LOG="$EVIL_QUOTEDIR/run.log"
run_expect_success "$EVIL_QUOTEDIR_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$EVIL_QUOTEDIR" \
    -o "quote-dir-case" \
    -i "1" \
    -n \
    -k
EVIL_QUOTEDIR_OUT="$EVIL_QUOTEDIR/quote-dir-case.m4b"
assert_file_exists "$EVIL_QUOTEDIR_OUT"
assert_m4b_audio_valid "$EVIL_QUOTEDIR_OUT"
# The concat list entries contain the workdir path, which is inside
# the single-quote directory — this breaks naive quote escaping
EVIL_QUOTEDIR_WORKDIR=$(find_workdir "$EVIL_QUOTEDIR" "quote-dir-case")
assert_all_list_entries_absolute "$EVIL_QUOTEDIR_WORKDIR/list.txt"

info "EVIL: Shell metacharacters in metadata should not be executed"
EVIL_SHELL_DIR="$TEST_ROOT/evil-shell"
mkdir -p "$EVIL_SHELL_DIR"
EVIL_SHELL_LOG="$EVIL_SHELL_DIR/run.log"
EVIL_TITLE='$(whoami) & `date` | rm -rf / ; echo pwned'
EVIL_ARTIST='O'\''Brien "The $USER"'
EVIL_ALBUM='album `id` $(cat /etc/passwd)'
run_expect_success "$EVIL_SHELL_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$EVIL_SHELL_DIR" \
    -o "evil-shell-case" \
    -t "$EVIL_TITLE" \
    -a "$EVIL_ARTIST" \
    -l "$EVIL_ALBUM" \
    -i "1" \
    -n
EVIL_SHELL_OUT="$EVIL_SHELL_DIR/evil-shell-case.m4b"
assert_file_exists "$EVIL_SHELL_OUT"
# Metadata should contain the literal strings, not executed results
assert_m4b_metadata "$EVIL_SHELL_OUT" "title" "$EVIL_TITLE"
assert_m4b_metadata "$EVIL_SHELL_OUT" "artist" "$EVIL_ARTIST"
assert_m4b_metadata "$EVIL_SHELL_OUT" "album" "$EVIL_ALBUM"

info "EVIL: ffmetadata special chars (= ; # \\) in title should round-trip through chapters"
EVIL_META_DIR="$TEST_ROOT/evil-ffmeta"
mkdir -p "$EVIL_META_DIR"
EVIL_META_LOG="$EVIL_META_DIR/run.log"
run_expect_success "$EVIL_META_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$EVIL_META_DIR" \
    -o "evil-ffmeta-case" \
    -t 'key=value;comment#hash\\backslash' \
    -i "1-2" \
    -n \
    -k
EVIL_META_OUT="$EVIL_META_DIR/evil-ffmeta-case.m4b"
assert_file_exists "$EVIL_META_OUT"
assert_m4b_audio_valid "$EVIL_META_OUT"
# Title metadata goes through -metadata flag (no ffmetadata escaping needed)
assert_m4b_metadata "$EVIL_META_OUT" "title" 'key=value;comment#hash\\backslash'
# Verify chapters.txt has properly escaped chapter titles (they come from filenames,
# so special chars may appear if yt-dlp produces them)
EVIL_META_WORKDIR=$(find_workdir "$EVIL_META_DIR" "evil-ffmeta-case")
assert_file_exists "$EVIL_META_WORKDIR/chapters.txt"
assert_chapter_count "$EVIL_META_WORKDIR/chapters.txt" 2
# Verify the chapter file starts with the required magic header
FIRST_LINE=$(head -n1 "$EVIL_META_WORKDIR/chapters.txt")
assert_eq ";FFMETADATA1" "$FIRST_LINE" "Chapter file must start with ;FFMETADATA1"
# Chapters should have survived into the actual M4B
assert_m4b_chapter_count "$EVIL_META_OUT" 2

info "EVIL: Cover image path with spaces and special chars"
EVIL_COVER_DIR="$TEST_ROOT/evil-cover path (special)"
mkdir -p "$EVIL_COVER_DIR"
EVIL_COVER_IMG="$EVIL_COVER_DIR/my cover (1).jpg"
ffmpeg -y -f lavfi -i "color=c=blue:s=2x2:d=1" -frames:v 1 -update 1 "$EVIL_COVER_IMG" >/dev/null 2>&1
EVIL_COVER_LOG="$EVIL_COVER_DIR/run.log"
run_expect_success "$EVIL_COVER_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$EVIL_COVER_DIR" \
    -o "evil-cover-case" \
    -i "1" \
    -c "$EVIL_COVER_IMG" \
    -n
EVIL_COVER_OUT="$EVIL_COVER_DIR/evil-cover-case.m4b"
assert_file_exists "$EVIL_COVER_OUT"
assert_m4b_has_cover "$EVIL_COVER_OUT"

info "EVIL: Output name that is all special chars should sanitize to underscores"
EVIL_ALLSPECIAL_DIR="$TEST_ROOT/evil-allspecial"
mkdir -p "$EVIL_ALLSPECIAL_DIR"
EVIL_ALLSPECIAL_LOG="$EVIL_ALLSPECIAL_DIR/run.log"
run_expect_success "$EVIL_ALLSPECIAL_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$EVIL_ALLSPECIAL_DIR" \
    -o "***" \
    -i "1" \
    -n
# *** sanitizes to ___
EVIL_ALLSPECIAL_OUT="$EVIL_ALLSPECIAL_DIR/___.m4b"
assert_file_exists "$EVIL_ALLSPECIAL_OUT"
assert_m4b_audio_valid "$EVIL_ALLSPECIAL_OUT"

info "EVIL: Backslash-n and backslash-t in metadata should be literal, not interpreted"
EVIL_BS_DIR="$TEST_ROOT/evil-backslash"
mkdir -p "$EVIL_BS_DIR"
EVIL_BS_LOG="$EVIL_BS_DIR/run.log"
EVIL_BS_TITLE='line1\nline2\ttab'
run_expect_success "$EVIL_BS_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$EVIL_BS_DIR" \
    -o "evil-bs-case" \
    -t "$EVIL_BS_TITLE" \
    -i "1" \
    -n
EVIL_BS_OUT="$EVIL_BS_DIR/evil-bs-case.m4b"
assert_file_exists "$EVIL_BS_OUT"
# The literal backslash-n should be in the metadata, not a newline
assert_m4b_metadata "$EVIL_BS_OUT" "title" "$EVIL_BS_TITLE"

info "EVIL: Split mode with spaces in output name should produce correct per-item M4Bs"
EVIL_SPLIT_DIR="$TEST_ROOT/evil-split-spaces"
mkdir -p "$EVIL_SPLIT_DIR"
EVIL_SPLIT_LOG="$EVIL_SPLIT_DIR/run.log"
run_expect_success "$EVIL_SPLIT_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$EVIL_SPLIT_DIR" \
    -o "evil split case" \
    -i "1-2" \
    -s \
    -n
assert_m4b_count "$EVIL_SPLIT_DIR" 2
for m4b in "$EVIL_SPLIT_DIR"/*.m4b; do
    assert_m4b_audio_valid "$m4b"
done

info "EVIL: Output name starting with -- (long-option lookalike) should not confuse any tool"
EVIL_LONGOPT_DIR="$TEST_ROOT/evil-longopt"
mkdir -p "$EVIL_LONGOPT_DIR"
EVIL_LONGOPT_LOG="$EVIL_LONGOPT_DIR/run.log"
run_expect_success "$EVIL_LONGOPT_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$EVIL_LONGOPT_DIR" \
    -o "--output-format" \
    -i "1" \
    -n
# -- gets sanitized: < > : " / \ | ? * ' all become _; dashes survive
EVIL_LONGOPT_OUT="$EVIL_LONGOPT_DIR/--output-format.m4b"
assert_file_exists "$EVIL_LONGOPT_OUT"
assert_m4b_audio_valid "$EVIL_LONGOPT_OUT"

info "EVIL: Output name with glob patterns * ? [ ] should be sanitized"
EVIL_GLOB_DIR="$TEST_ROOT/evil-glob"
mkdir -p "$EVIL_GLOB_DIR"
EVIL_GLOB_LOG="$EVIL_GLOB_DIR/run.log"
run_expect_success "$EVIL_GLOB_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$EVIL_GLOB_DIR" \
    -o '?file[0]*' \
    -i "1" \
    -n
# ? and * are sanitized to _, but [ and ] pass through
EVIL_GLOB_OUT="$EVIL_GLOB_DIR/_file[0]_.m4b"
assert_file_exists "$EVIL_GLOB_OUT"
assert_m4b_audio_valid "$EVIL_GLOB_OUT"

info "EVIL: Output name containing newline should have it stripped"
EVIL_NEWLINE_DIR="$TEST_ROOT/evil-newline"
mkdir -p "$EVIL_NEWLINE_DIR"
EVIL_NEWLINE_LOG="$EVIL_NEWLINE_DIR/run.log"
# shellcheck disable=SC2016
EVIL_NEWLINE_NAME=$'before\nafter'
run_expect_success "$EVIL_NEWLINE_LOG" \
    "$MAIN_SCRIPT" \
    -u "$TEST_URL" \
    -d "$EVIL_NEWLINE_DIR" \
    -o "$EVIL_NEWLINE_NAME" \
    -i "1" \
    -n
# Newline is stripped by tr -d '\n\r', so the name becomes "beforeafter"
EVIL_NEWLINE_OUT="$EVIL_NEWLINE_DIR/beforeafter.m4b"
assert_file_exists "$EVIL_NEWLINE_OUT"
assert_m4b_audio_valid "$EVIL_NEWLINE_OUT"

info "All tests passed"
