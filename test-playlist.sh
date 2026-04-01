#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAIN_SCRIPT="$SCRIPT_DIR/playlist-to-audiobook.sh"
TEST_URL="https://www.youtube.com/playlist?list=PLTTyjqCYL18SZ7KGzttmuhjrWl2eb6SjY"
TEST_ROOT="$SCRIPT_DIR/test-output"

usage() {
    cat <<EOF
Usage: $(basename "$0")

Runs a small integration test suite against:
  $TEST_URL

The suite covers:
  - dry-run behavior (combined and split modes)
  - invalid argument failures
  - normalized end-to-end conversion with chapter gaps
  - no-normalize conversion path
  - split mode (one M4B per item, per-item cover art)
  - expected properties of kept temp files

Outputs are written under:
  $TEST_ROOT
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

assert_file_exists() {
    local path="$1"
    [[ -f "$path" ]] || fail "Expected file to exist: $path"
}

assert_dir_exists() {
    local path="$1"
    [[ -d "$path" ]] || fail "Expected directory to exist: $path"
}

assert_not_exists() {
    local path="$1"
    [[ ! -e "$path" ]] || fail "Expected path to be absent: $path"
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [[ "$expected" == "$actual" ]] || fail "$message (expected '$expected', got '$actual')"
}

assert_contains() {
    local needle="$1"
    local file="$2"
    grep -Fq -- "$needle" "$file" || fail "Expected '$file' to contain: $needle"
}

assert_all_list_entries_absolute() {
    local file="$1"

    while IFS= read -r line; do
        [[ "$line" =~ ^file\ \'/.+\'$ ]] || fail "Expected absolute concat entry in $file, got: $line"
    done < "$file"
}

assert_ffprobe_value() {
    local file="$1"
    local entry="$2"
    local expected="$3"
    local actual

    actual=$(ffprobe -v error -select_streams a:0 -show_entries "stream=$entry" -of default=noprint_wrappers=1:nokey=1 -- "$file")
    [[ -n "$actual" ]] || fail "ffprobe returned no value for $entry on $file"
    assert_eq "$expected" "$actual" "Unexpected ffprobe $entry for $file"
}

assert_chapter_count() {
    local file="$1"
    local expected="$2"
    local actual

    actual=$(grep -c '^\[CHAPTER\]$' "$file")
    assert_eq "$expected" "$actual" "Unexpected chapter count in $file"
}

assert_m4b_count() {
    local dir="$1"
    local expected="$2"
    local actual
    actual=$(find "$dir" -maxdepth 1 -name "*.m4b" | wc -l | tr -d '[:space:]')
    assert_eq "$expected" "$actual" "Unexpected M4B count in $dir"
}

assert_m4b_audio_valid() {
    local file="$1"
    local codec
    codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 -- "$file" 2>/dev/null)
    [[ "$codec" == "aac" ]] || fail "Expected AAC audio in $file, got: $codec"
}

assert_prep_marker_pairs() {
    local marker="$1"
    local expected_audio_files="$2"
    local lines

    lines=$(wc -l < "$marker" | tr -d '[:space:]')
    assert_eq "$(( expected_audio_files * 2 ))" "$lines" "Unexpected prep marker entry count in $marker"
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

    if ! "$@" >"$logfile" 2>&1; then
        cat "$logfile" >&2
        fail "Command failed: $*"
    fi
}

run_expect_failure() {
    local logfile="$1"
    shift

    if "$@" >"$logfile" 2>&1; then
        cat "$logfile" >&2
        fail "Command unexpectedly succeeded: $*"
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
    assert_ffprobe_value "$wav" sample_rate 48000
    assert_ffprobe_value "$wav" channels 2
done

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
# Each M4B should contain valid AAC audio
for m4b in "$SPLIT_NORM_DIR"/*.m4b; do
    assert_m4b_audio_valid "$m4b"
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

info "All tests passed"
