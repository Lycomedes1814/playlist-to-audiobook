#!/usr/bin/env python3
"""Convert a YouTube playlist or single video into one or more M4B files."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


OUTPUT_SAMPLE_RATE = 48000
OUTPUT_CHANNELS = 2
INTERMEDIATE_AUDIO_SUFFIX = ".w64"
INTERMEDIATE_PREP_SUFFIX = ".prep.w64"
INTERMEDIATE_FORMAT = "w64"
AUDIO_EXTENSIONS = (".webm", ".opus", ".m4a", ".mp3", ".ogg", ".wav", ".w64", ".flac", ".aac")


@dataclass(frozen=True)
class Config:
    url: str
    output: str
    output_dir: str
    title: str
    artist: str
    album: str
    bitrate: int
    cover: str
    items: str
    chapter_gap: float
    split: bool
    keep: bool
    normalize: bool
    verbose: bool
    quiet: bool
    dry_run: bool


@dataclass
class PipelineState:
    config: Config
    # Runtime flags live directly on the main state to avoid a second wrapper object.
    cleanup_enabled: bool = True
    playlist_title: str = ""
    uploader: str = ""
    output_name: str = ""
    title: str = ""
    artist: str = ""
    album: str = ""
    expected_item_count: int | None = None
    is_playlist: bool = True
    video_chapters_json: str = ""
    base_dir: Path | None = None
    workdir: Path | None = None
    list_txt: Path | None = None
    chapter_txt: Path | None = None
    cover_jpg: Path | None = None
    out_m4b: Path | None = None


def usage_text() -> str:
    return """Usage: playlist-to-audiobook.py -u <url> [options]

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
  -i, --items RANGE      Playlist items to download (e.g. "1-5", "2,4,6")
  --chapter-gap SECONDS   Silence to insert between chapters (default: 0)
  -s, --split            Encode each playlist item as its own M4B file
  -k, --keep             Keep intermediate files after encoding
  -n, --no-normalize     Skip EBU R128 audio normalization
  -v, --verbose          Show detailed yt-dlp and ffmpeg output
  -q, --quiet            Suppress all non-error output
  --dry-run              Show what would be done, then exit
  -h, --help             Show this help message

Dependencies: yt-dlp, ffmpeg, ffprobe, python3
"""


def sanitize_output_name(name: str) -> str:
    sanitized = name.replace("\n", "").replace("\r", "")
    sanitized = re.sub(r'[<>:"/\\|?*\'\x00-\x1f]', "_", sanitized)
    return sanitized or "audiobook"


def extract_json_field(text: str, field: str) -> str | None:
    if not text.strip():
        return None
    data = json.loads(text)
    if not isinstance(data, dict):
        return None
    value = data.get(field, "")
    if value in ("", None):
        return None
    return str(value)


def json_is_playlist(text: str) -> bool:
    if not text.strip():
        return False
    data = json.loads(text)
    if not isinstance(data, dict):
        return False
    return data.get("_type") == "playlist"


def count_requested_items(spec: str) -> int:
    total = 0
    for raw_part in spec.split(","):
        part = "".join(raw_part.split())
        if not part:
            raise ValueError("empty playlist items token")
        if re.fullmatch(r"\d+", part):
            total += 1
            continue
        match = re.fullmatch(r"(\d+)-(\d+)", part)
        if not match:
            raise ValueError("invalid playlist items token")
        start, end = int(match.group(1)), int(match.group(2))
        if end < start:
            raise ValueError("reverse playlist range")
        total += end - start + 1
    return total


def unique_output_path(directory: Path, stem: str, ext: str) -> Path:
    candidate = directory / f"{stem}{ext}"
    suffix = 2
    while candidate.exists():
        candidate = directory / f"{stem} ({suffix}){ext}"
        suffix += 1
    return candidate


def require_path(path: Path | None) -> Path:
    if path is None:
        raise RuntimeError("Missing required pipeline path")
    return path


def log_step(state: PipelineState, message: str) -> None:
    if not state.config.quiet:
        print(f"\033[0;36m{message}\033[0m")


def log_info(state: PipelineState, message: str) -> None:
    if not state.config.quiet:
        print(f"  \033[0;37m{message}\033[0m")


def log_warn(state: PipelineState, message: str) -> None:
    if not state.config.quiet:
        print(f"  \033[0;33mWarning: {message}\033[0m", file=sys.stderr)


def log_ok(state: PipelineState, message: str) -> None:
    if not state.config.quiet:
        print(f"\033[0;32m{message}\033[0m")


def run_command(
    state: PipelineState,
    command: list[str],
    *,
    capture_output: bool = False,
    allow_failure: bool = False,
    text: bool = True,
) -> subprocess.CompletedProcess[str]:
    if state.config.quiet and not capture_output:
        stdout = subprocess.DEVNULL
        stderr = subprocess.DEVNULL
    elif state.config.verbose and not capture_output:
        stdout = None
        stderr = None
    elif capture_output:
        stdout = subprocess.PIPE
        stderr = subprocess.PIPE
    else:
        stdout = subprocess.DEVNULL
        stderr = subprocess.DEVNULL

    try:
        completed = subprocess.run(
            command,
            check=not allow_failure,
            stdout=stdout,
            stderr=stderr,
            text=text,
        )
    except KeyboardInterrupt:
        print("Error: Interrupted.", file=sys.stderr)
        raise SystemExit(130) from None
    except subprocess.CalledProcessError as exc:
        if capture_output:
            return subprocess.CompletedProcess(
                exc.cmd, exc.returncode, stdout=exc.stdout or "", stderr=exc.stderr or "",
            )
        raise
    return completed


def cleanup(state: PipelineState) -> None:
    workdir = state.workdir
    if state.cleanup_enabled and not state.config.keep and workdir and workdir.is_dir():
        shutil.rmtree(workdir, ignore_errors=True)


def resolve_metadata(state: PipelineState) -> None:
    log_step(state, "[1/6] Fetching metadata...")

    meta = run_command(
        state,
        ["yt-dlp", "--ignore-config", "--flat-playlist", "--playlist-items", "1", "-J", "--", state.config.url],
        capture_output=True,
        allow_failure=True,
    )
    meta_json = meta.stdout or ""

    is_playlist = json_is_playlist(meta_json)
    if is_playlist:
        playlist_title = extract_json_field(meta_json, "title") or ""
        uploader = extract_json_field(meta_json, "uploader") or ""
    else:
        playlist_title = ""
        uploader = ""

    video_chapters_json = ""
    if not playlist_title or playlist_title == "NA":
        is_playlist = False
        meta = run_command(
            state,
            ["yt-dlp", "--ignore-config", "--skip-download", "-J", "--", state.config.url],
            capture_output=True,
            allow_failure=True,
        )
        if meta.returncode != 0:
            log_warn(state, "Could not fetch video metadata, using defaults.")
            meta_json = ""
        else:
            meta_json = meta.stdout or ""
        playlist_title = extract_json_field(meta_json, "title") or ""
        uploader = extract_json_field(meta_json, "uploader") or ""

        chapters = run_command(
            state,
            ["yt-dlp", "--ignore-config", "--skip-download", "--print", "%(chapters)j", "--", state.config.url],
            capture_output=True,
            allow_failure=True,
        )
        video_chapters_json = (chapters.stdout or "").strip()
        if video_chapters_json in {"null", "NA"}:
            video_chapters_json = ""

    playlist_title = playlist_title or "audiobook"
    uploader = uploader or "Unknown Artist"
    # Mutate the shared pipeline state directly instead of rebuilding it each step.
    state.is_playlist = is_playlist
    state.playlist_title = playlist_title
    state.uploader = uploader
    state.video_chapters_json = video_chapters_json


def derive_output_metadata(state: PipelineState) -> None:
    state.output_name = state.config.output or state.playlist_title
    state.title = state.config.title or state.playlist_title
    state.album = state.config.album or state.playlist_title
    state.artist = state.config.artist or state.uploader
    state.expected_item_count = None
    if state.is_playlist and state.config.items:
        try:
            state.expected_item_count = count_requested_items(state.config.items)
        except ValueError:
            state.expected_item_count = None


def ensure_paths(state: PipelineState) -> None:
    base_dir = Path(state.config.output_dir or os.getcwd()).resolve()
    safe_output_name = sanitize_output_name(state.output_name)
    workdir = Path(tempfile.mkdtemp(prefix=f"{safe_output_name}.work.", dir=base_dir))
    state.base_dir = base_dir
    state.workdir = workdir
    state.list_txt = workdir / "list.txt"
    state.chapter_txt = workdir / "chapters.txt"
    state.cover_jpg = workdir / "cover.jpg"
    state.out_m4b = base_dir / f"{safe_output_name}.m4b"


def iter_audio_files(state: PipelineState, *, exclude_silence: bool = False) -> list[Path]:
    workdir = require_path(state.workdir)
    files = [path for path in sorted(workdir.iterdir()) if path.is_file() and path.suffix.lower() in AUDIO_EXTENSIONS]
    return [
        path
        for path in files
        if not path.name.endswith(INTERMEDIATE_PREP_SUFFIX) and not (exclude_silence and path.name == f"_silence{INTERMEDIATE_AUDIO_SUFFIX}")
    ]


def download_audio(state: PipelineState) -> None:
    log_step(state, "[2/6] Downloading audio...")
    workdir = require_path(state.workdir)

    args = [
        "yt-dlp",
        "--ignore-config",
        "--no-overwrites",
        "--retries",
        "infinite",
        "--fragment-retries",
        "infinite",
        "-x",
        "-f",
        "bestaudio",
    ]

    if state.is_playlist:
        args += ["--yes-playlist", "-o", str(workdir / "%(playlist_index)03d - %(title).200B.%(ext)s")]
        if state.config.items:
            args += ["--playlist-items", state.config.items]
    else:
        if state.config.items:
            log_warn(state, "--items ignored for single-video URLs.")
        args += ["-o", str(workdir / "001 - %(title).200B.%(ext)s")]

    if state.config.split:
        args += ["--write-info-json"]
        if not state.config.cover:
            args += ["--write-thumbnail", "--convert-thumbnails", "jpg"]

    completed = run_command(state, args + ["--", state.config.url], allow_failure=True)
    if completed.returncode == 0:
        return
    if completed.returncode in {130, 143}:
        print("Error: Download interrupted.", file=sys.stderr)
        raise SystemExit(130)

    partial = iter_audio_files(state)
    if not partial:
        print("Error: yt-dlp failed before downloading any audio files.", file=sys.stderr)
        raise SystemExit(completed.returncode)

    log_warn(
        state,
        f"yt-dlp reported errors; continuing with {len(partial)} downloaded file(s). Some playlist items may be unavailable.",
    )


def extract_loudnorm_field(text: str, field: str) -> str | None:
    match = re.search(r"\{[\s\S]*\}", text)
    if not match:
        return None
    try:
        data = json.loads(match.group(0))
    except json.JSONDecodeError:
        return None
    value = data.get(field, "")
    if value in ("", None):
        return None
    return str(value)


def append_prep_done(marker_path: Path, basename: str, wav_name: str) -> None:
    with marker_path.open("a", encoding="utf-8") as handle:
        handle.write(f"{basename}\n{wav_name}\n")


def prep_done_entries(marker_path: Path) -> set[str]:
    if not marker_path.exists():
        return set()
    return set(marker_path.read_text(encoding="utf-8").splitlines())


def mark_prepared(marker_path: Path, basename: str, wav_name: str, done_entries: set[str]) -> set[str]:
    append_prep_done(marker_path, basename, wav_name)
    return done_entries | {basename, wav_name}


def prepare_audio_file(
    state: PipelineState,
    file_path: Path,
    marker_path: Path,
    done_entries: set[str],
) -> set[str]:
    basename = file_path.name
    ext = file_path.suffix.lstrip(".")
    intermediate_file = file_path.with_suffix(INTERMEDIATE_AUDIO_SUFFIX)
    tmpfile = file_path.with_suffix(INTERMEDIATE_PREP_SUFFIX)

    if ext != INTERMEDIATE_AUDIO_SUFFIX.lstrip(".") and intermediate_file.exists():
        log_info(state, f"Removing re-downloaded {basename} (prepared intermediate exists)")
        file_path.unlink()
        return done_entries

    if marker_path.exists() and basename in done_entries:
        log_info(state, f"Already prepared: {basename}")
        return done_entries

    if state.config.normalize:
        stats = run_command(
            state,
            [
                "ffmpeg",
                "-y",
                "-i",
                str(file_path),
                "-af",
                "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json",
                "-f",
                "null",
                "/dev/null",
            ],
            capture_output=True,
            allow_failure=True,
        )
        input_i = extract_loudnorm_field(stats.stderr or "", "input_i")
        input_tp = extract_loudnorm_field(stats.stderr or "", "input_tp")
        input_lra = extract_loudnorm_field(stats.stderr or "", "input_lra")
        input_thresh = extract_loudnorm_field(stats.stderr or "", "input_thresh")

        if not all([input_i, input_tp, input_lra, input_thresh]):
            log_warn(state, f"Two-pass measurement failed for {basename}, trying single-pass.")
            result = run_command(
                state,
                [
                    "ffmpeg",
                    "-y",
                    "-i",
                    str(file_path),
                    "-af",
                    "loudnorm=I=-16:TP=-1.5:LRA=11",
                    "-ar",
                    str(OUTPUT_SAMPLE_RATE),
                    "-ac",
                    str(OUTPUT_CHANNELS),
                    "-f",
                    INTERMEDIATE_FORMAT,
                    "-c:a",
                    "pcm_s16le",
                    str(tmpfile),
                ],
                allow_failure=True,
            )
            if result.returncode != 0:
                tmpfile.unlink(missing_ok=True)
                print(f"Error: Could not normalize {basename}.", file=sys.stderr)
                raise SystemExit(1)
            tmpfile.replace(intermediate_file)
            if file_path != intermediate_file:
                file_path.unlink(missing_ok=True)
            log_info(state, f"Normalized (single-pass): {basename}")
            return mark_prepared(marker_path, basename, intermediate_file.name, done_entries)

        filter_text = (
            "loudnorm=I=-16:TP=-1.5:LRA=11:"
            f"measured_I={input_i}:measured_TP={input_tp}:measured_LRA={input_lra}:"
            f"measured_thresh={input_thresh}:linear=true"
        )
        result = run_command(
            state,
            [
                "ffmpeg",
                "-y",
                "-i",
                str(file_path),
                "-af",
                filter_text,
                "-ar",
                str(OUTPUT_SAMPLE_RATE),
                "-ac",
                str(OUTPUT_CHANNELS),
                "-f",
                INTERMEDIATE_FORMAT,
                "-c:a",
                "pcm_s16le",
                str(tmpfile),
            ],
            allow_failure=True,
        )
        if result.returncode != 0:
            tmpfile.unlink(missing_ok=True)
            print(f"Error: Could not normalize {basename}.", file=sys.stderr)
            raise SystemExit(1)
        tmpfile.replace(intermediate_file)
        if file_path != intermediate_file:
            file_path.unlink(missing_ok=True)
        log_info(state, f"Normalized: {basename}")
        return mark_prepared(marker_path, basename, intermediate_file.name, done_entries)

    result = run_command(
        state,
        [
            "ffmpeg",
            "-y",
            "-i",
            str(file_path),
            "-ar",
            str(OUTPUT_SAMPLE_RATE),
            "-ac",
            str(OUTPUT_CHANNELS),
            "-f",
            INTERMEDIATE_FORMAT,
            "-c:a",
            "pcm_s16le",
            str(tmpfile),
        ],
        allow_failure=True,
    )
    if result.returncode != 0:
        tmpfile.unlink(missing_ok=True)
        print(f"Error: Could not convert {basename} to the intermediate audio format.", file=sys.stderr)
        raise SystemExit(1)
    tmpfile.replace(intermediate_file)
    if file_path != intermediate_file:
        file_path.unlink(missing_ok=True)
    log_info(state, f"Prepared: {basename}")
    return mark_prepared(marker_path, basename, intermediate_file.name, done_entries)


def prepare_audio(state: PipelineState) -> None:
    if state.config.normalize:
        log_step(state, "[3/6] Normalizing audio (two-pass EBU R128)...")
    else:
        log_step(state, "[3/6] Converting audio to a concat-safe intermediate format...")

    marker_path = require_path(state.workdir) / ".prep_done"
    done_entries = prep_done_entries(marker_path)
    for file_path in iter_audio_files(state):
        done_entries = prepare_audio_file(state, file_path, marker_path, done_entries)


def disable_cleanup(state: PipelineState) -> None:
    state.cleanup_enabled = False


def split_cover_for_file(state: PipelineState, file_path: Path) -> str:
    if state.config.cover:
        return state.config.cover

    image_exts = (".jpg", ".jpeg", ".png", ".webp")
    workdir = require_path(state.workdir)
    stem = file_path.stem

    candidate_stems = [stem]
    if stem.endswith(".prep"):
        candidate_stems.append(stem[:-5])

    for candidate_stem in candidate_stems:
        for ext in image_exts:
            candidate = workdir / f"{candidate_stem}{ext}"
            if candidate.exists():
                return str(candidate)

    prefix_match = re.match(r"^([0-9]+)\s*-\s*", stem)
    if prefix_match:
        prefix = prefix_match.group(1)
        for ext in image_exts:
            matches = sorted(workdir.glob(f"{prefix} - *{ext}"))
            if matches:
                return str(matches[0])

    return ""


def chapters_from_info_json(state: PipelineState, file_path: Path) -> list[dict]:
    workdir = require_path(state.workdir)
    stem = file_path.stem

    candidate_stems = [stem]
    if stem.endswith(".prep"):
        candidate_stems.append(stem[:-5])

    for candidate_stem in candidate_stems:
        info_path = workdir / f"{candidate_stem}.info.json"
        if info_path.exists():
            try:
                data = json.loads(info_path.read_text(encoding="utf-8"))
                chapters = data.get("chapters")
                if chapters:
                    return chapters
            except (json.JSONDecodeError, KeyError):
                pass

    prefix_match = re.match(r"^([0-9]+)\s*-\s*", stem)
    if prefix_match:
        prefix = prefix_match.group(1)
        matches = sorted(workdir.glob(f"{prefix} - *.info.json"))
        if matches:
            try:
                data = json.loads(matches[0].read_text(encoding="utf-8"))
                chapters = data.get("chapters")
                if chapters:
                    return chapters
            except (json.JSONDecodeError, KeyError):
                pass

    return []


def build_split_chapter_file(state: PipelineState, file_path: Path, chapters: list[dict]) -> Path | None:
    duration_str = ffprobe_duration(state, file_path)
    try:
        total_duration_ms = int(float(duration_str) * 1000)
    except (ValueError, TypeError):
        return None

    chapter_lines: list[str] = []
    for chapter in chapters:
        start_ms = int(float(chapter["start_time"]) * 1000)
        end_ms = min(int(float(chapter["end_time"]) * 1000), total_duration_ms)
        chapter_lines.extend(
            [
                "[CHAPTER]",
                "TIMEBASE=1/1000",
                f"START={start_ms}",
                f"END={end_ms}",
                f"title={escape_ffmetadata_value(str(chapter['title']))}",
            ]
        )

    if not chapter_lines:
        return None

    chapter_file = file_path.with_suffix(".chapters.txt")
    with chapter_file.open("w", encoding="utf-8") as handle:
        handle.write(";FFMETADATA1\n")
        for line in chapter_lines:
            handle.write(f"{line}\n")

    log_info(state, f"Using {len(chapters)} chapter marker(s) for {file_path.name}")
    return chapter_file


def encode_split_mode(state: PipelineState) -> None:
    log_step(state, "[4-6/6] Encoding individual M4B files...")

    split_files = iter_audio_files(state, exclude_silence=True)
    if not split_files:
        print("Error: No audio files were downloaded.", file=sys.stderr)
        raise SystemExit(1)

    base_dir = require_path(state.base_dir)
    split_count = 0
    split_failed = 0

    for file_path in split_files:
        basename = file_path.name
        item_title = re.sub(r"^[0-9]+\s*-\s*", "", file_path.stem)
        safe_item_title = sanitize_output_name(item_title)
        item_m4b = unique_output_path(base_dir, safe_item_title, ".m4b")
        default_item_m4b = base_dir / f"{safe_item_title}.m4b"
        if item_m4b != default_item_m4b:
            log_warn(state, f"Output filename collision for '{item_title}'; using {item_m4b.name} instead.")

        item_cover = split_cover_for_file(state, file_path)
        chapters = chapters_from_info_json(state, file_path)
        chapter_file = build_split_chapter_file(state, file_path, chapters) if chapters else None

        ffmpeg_args = ["ffmpeg", "-y", "-i", str(file_path)]
        if chapter_file:
            ffmpeg_args += ["-i", str(chapter_file)]
        if item_cover:
            ffmpeg_args += ["-i", item_cover]

        ffmpeg_args += ["-map", "0:a"]
        if chapter_file:
            ffmpeg_args += ["-map_metadata", "1", "-map_chapters", "1"]
        cover_stream = "2" if chapter_file else "1"
        if item_cover:
            ffmpeg_args += ["-map", f"{cover_stream}:v", "-c:v", "mjpeg", "-disposition:v:0", "attached_pic"]

        ffmpeg_args += [
            "-c:a",
            "aac",
            "-ar",
            str(OUTPUT_SAMPLE_RATE),
            "-b:a",
            f"{state.config.bitrate}k",
            "-metadata",
            f"title={item_title}",
            "-metadata",
            f"artist={state.artist}",
            "-metadata",
            f"album={state.album}",
            "-metadata",
            "genre=Audiobook",
            str(item_m4b),
        ]

        result = run_command(state, ffmpeg_args, allow_failure=True)
        if result.returncode == 0:
            log_info(state, f"Encoded: {item_m4b.name}")
            split_count += 1
        else:
            log_warn(state, f"Failed to encode: {basename}")
            split_failed += 1

    if split_failed > 0:
        print(f"Error: Failed to encode {split_failed} playlist item(s) in split mode.", file=sys.stderr)
        raise SystemExit(1)

    if state.config.keep:
        disable_cleanup(state)
        log_info(state, f"Keeping work files in: {state.workdir}")
    log_ok(state, f"Done: {split_count} file(s) in {state.base_dir}")


def write_concat_entry(handle, path: Path) -> None:
    escaped = str(path).replace("'", "'\\''")
    handle.write(f"file '{escaped}'\n")


def ffprobe_duration(state: PipelineState, path: Path) -> str:
    result = run_command(
        state,
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "csv=p=0",
            "--",
            str(path),
        ],
        capture_output=True,
        allow_failure=True,
    )
    return (result.stdout or "").strip()


def escape_ffmetadata_value(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace("=", r"\=").replace(";", r"\;").replace("#", r"\#")
    return escaped.replace("\n", " ").replace("\r", "")


def build_file_based_chapter_lines(
    state: PipelineState,
    audio_files: list[Path],
    silence_file: Path | None,
    gap_ms: int,
) -> tuple[bool, list[str], int]:
    list_txt = require_path(state.list_txt)
    chapter_lines: list[str] = []
    cumulative_ms = 0
    has_chapters = True

    with list_txt.open("w", encoding="utf-8") as handle:
        for index, file_path in enumerate(audio_files):
            if silence_file is not None and index > 0:
                write_concat_entry(handle, silence_file)
                cumulative_ms += gap_ms

            write_concat_entry(handle, file_path)
            duration_str = ffprobe_duration(state, file_path)
            if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", duration_str):
                log_warn(state, f"Could not determine duration for {file_path.name}, skipping chapter markers.")
                has_chapters = False
                chapter_lines = []
                continue

            if not has_chapters:
                continue

            start_ms = cumulative_ms
            end_ms = int(cumulative_ms + float(duration_str) * 1000)
            cumulative_ms = end_ms
            chapter_title = re.sub(r"^[0-9]+\s*-\s*", "", file_path.stem)
            chapter_lines.extend(
                [
                    "[CHAPTER]",
                    "TIMEBASE=1/1000",
                    f"START={start_ms}",
                    f"END={end_ms}",
                    f"title={escape_ffmetadata_value(chapter_title)}",
                ]
            )

    return has_chapters, chapter_lines, cumulative_ms


def youtube_chapter_lines(state: PipelineState, total_duration_ms: int) -> list[str]:
    try:
        chapters = json.loads(state.video_chapters_json)
    except json.JSONDecodeError:
        return []
    if not chapters:
        return []

    chapter_lines: list[str] = []
    for chapter in chapters:
        start_ms = int(float(chapter["start_time"]) * 1000)
        end_ms = min(int(float(chapter["end_time"]) * 1000), total_duration_ms)
        chapter_lines.extend(
            [
                "[CHAPTER]",
                "TIMEBASE=1/1000",
                f"START={start_ms}",
                f"END={end_ms}",
                f"title={escape_ffmetadata_value(str(chapter['title']))}",
            ]
        )
    log_info(state, f"Using {len(chapters)} video chapter marker(s) from YouTube.")
    return chapter_lines


def build_chapter_file(state: PipelineState) -> None:
    log_step(state, "[4/6] Building concat list and chapter metadata...")
    workdir = require_path(state.workdir)
    chapter_txt = require_path(state.chapter_txt)

    gap_ms = 0
    silence_file: Path | None = None
    if state.config.chapter_gap > 0:
        gap_ms = int(state.config.chapter_gap * 1000)
        silence_file = workdir / f"_silence{INTERMEDIATE_AUDIO_SUFFIX}"
        run_command(
            state,
            [
                "ffmpeg",
                "-y",
                "-f",
                "lavfi",
                "-i",
                f"anullsrc=r={OUTPUT_SAMPLE_RATE}:cl=stereo",
                "-t",
                str(state.config.chapter_gap),
                "-ar",
                str(OUTPUT_SAMPLE_RATE),
                "-ac",
                str(OUTPUT_CHANNELS),
                "-f",
                INTERMEDIATE_FORMAT,
                "-c:a",
                "pcm_s16le",
                str(silence_file),
            ],
        )

    audio_files = iter_audio_files(state, exclude_silence=True)
    if not audio_files:
        print("Error: No audio files were downloaded.", file=sys.stderr)
        raise SystemExit(1)

    log_info(state, f"Found {len(audio_files)} audio file(s).")
    if state.expected_item_count is not None and len(audio_files) < state.expected_item_count:
        log_warn(
            state,
            f"Requested {state.expected_item_count} playlist item(s), but only found {len(audio_files)} downloaded audio file(s). Some items may be unavailable.",
        )

    has_chapters, chapter_lines, total_duration_ms = build_file_based_chapter_lines(state, audio_files, silence_file, gap_ms)
    using_youtube_chapters = False
    if not state.is_playlist and state.video_chapters_json and has_chapters:
        youtube_lines = youtube_chapter_lines(state, total_duration_ms)
        if youtube_lines:
            chapter_lines = youtube_lines
            using_youtube_chapters = True

    if has_chapters and chapter_lines:
        with chapter_txt.open("w", encoding="utf-8") as handle:
            handle.write(";FFMETADATA1\n")
            for line in chapter_lines:
                handle.write(f"{line}\n")
        if not using_youtube_chapters:
            log_info(state, f"Generated {len(chapter_lines) // 5} chapter marker(s).")


def prepare_cover_art(state: PipelineState) -> bool:
    log_step(state, "[5/6] Preparing cover art...")
    workdir = require_path(state.workdir)
    cover_jpg = require_path(state.cover_jpg)

    if state.config.cover:
        shutil.copyfile(state.config.cover, cover_jpg)
        log_info(state, f"Using custom cover: {state.config.cover}")
        return True

    run_command(
        state,
        [
            "yt-dlp",
            "--ignore-config",
            "--skip-download",
            "--write-thumbnail",
            "--convert-thumbnails",
            "jpg",
            "--playlist-items",
            "1",
            "-o",
            str(workdir / "cover"),
            "--",
            state.config.url,
        ],
        allow_failure=True,
    )
    if cover_jpg.exists():
        return True

    log_warn(state, "No thumbnail found, proceeding without cover art.")
    return False


def encode_combined(state: PipelineState, has_cover: bool) -> None:
    log_step(state, "[6/6] Encoding M4B...")
    list_txt = require_path(state.list_txt)
    out_m4b = require_path(state.out_m4b)
    chapter_txt = require_path(state.chapter_txt)
    cover_jpg = require_path(state.cover_jpg)

    ffmpeg_args = ["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(list_txt)]
    chapters_input = False
    if chapter_txt.exists():
        ffmpeg_args += ["-i", str(chapter_txt)]
        chapters_input = True
    if has_cover:
        ffmpeg_args += ["-i", str(cover_jpg)]
    if chapters_input:
        ffmpeg_args += ["-map_metadata", "1", "-map_chapters", "1"]
    if has_cover:
        cover_stream_index = "2" if chapters_input else "1"
        ffmpeg_args += ["-map", "0:a", "-map", f"{cover_stream_index}:v", "-c:v", "mjpeg", "-disposition:v:0", "attached_pic"]
    else:
        ffmpeg_args += ["-map", "0:a"]

    ffmpeg_args += [
        "-c:a",
        "aac",
        "-ar",
        str(OUTPUT_SAMPLE_RATE),
        "-b:a",
        f"{state.config.bitrate}k",
        "-metadata",
        f"title={state.title}",
        "-metadata",
        f"artist={state.artist}",
        "-metadata",
        f"album={state.album}",
        "-metadata",
        "genre=Audiobook",
        str(out_m4b),
    ]
    run_command(state, ffmpeg_args)

    if state.config.keep:
        disable_cleanup(state)
        log_info(state, f"Keeping work files in: {state.workdir}")
    else:
        log_info(state, "Cleaning up work files...")
    log_ok(state, f"Done: {out_m4b}")


def print_dry_run(state: PipelineState) -> None:
    print("Dry run — would perform the following:")
    print(f"  URL:        {state.config.url}")
    print(f"  Type:       {'playlist' if state.is_playlist else 'single video'}")
    if state.config.items:
        print(f"  Items:      {state.config.items}")
    print(f"  Mode:       {'split (one M4B per item)' if state.config.split else 'combined'}")
    print(f"  Title:      {'<per-item title>' if state.config.split else state.title}")
    print(f"  Artist:     {state.artist}")
    print(f"  Album:      {state.album}")
    print(f"  Bitrate:    {state.config.bitrate}k")
    print(f"  Normalize:  {'yes (two-pass EBU R128)' if state.config.normalize else 'no'}")
    print(f"  Chapter gap: {state.config.chapter_gap}s")
    if state.config.cover:
        cover_label = state.config.cover
    elif state.config.split:
        cover_label = "<per-item thumbnail>"
    else:
        cover_label = "<auto-detected from playlist>"
    print(f"  Cover:      {cover_label}")
    if state.config.split:
        print(f"  Output dir: {state.base_dir}")
    else:
        print(f"  Output:     {state.out_m4b}")


def build_initial_state(config: Config) -> PipelineState:
    return PipelineState(config=config)


def run_pipeline(state: PipelineState) -> PipelineState:
    resolve_metadata(state)
    derive_output_metadata(state)
    ensure_paths(state)

    if state.config.dry_run:
        print_dry_run(state)
        return state

    download_audio(state)
    prepare_audio(state)

    if state.config.split:
        encode_split_mode(state)
        return state

    build_chapter_file(state)
    has_cover = prepare_cover_art(state)
    encode_combined(state, has_cover)
    return state


def validate_dependencies() -> None:
    for command in ("yt-dlp", "ffmpeg", "ffprobe", "python3"):
        if shutil.which(command) is None:
            print(f"Error: '{command}' is not installed or not in PATH.", file=sys.stderr)
            raise SystemExit(1)


def parse_args(argv: list[str]) -> Config:
    parser = argparse.ArgumentParser(add_help=False, usage=argparse.SUPPRESS)
    parser.add_argument("-u", "--url")
    parser.add_argument("-o", "--output", default="")
    parser.add_argument("-d", "--output-dir", default="")
    parser.add_argument("-t", "--title", default="")
    parser.add_argument("-a", "--artist", default="")
    parser.add_argument("-l", "--album", default="")
    parser.add_argument("-b", "--bitrate", default="160")
    parser.add_argument("-c", "--cover", default="")
    parser.add_argument("-i", "--items", default="")
    parser.add_argument("--chapter-gap", default="0")
    parser.add_argument("-s", "--split", action="store_true")
    parser.add_argument("-k", "--keep", action="store_true")
    parser.add_argument("-n", "--no-normalize", action="store_true")
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("-q", "--quiet", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("-h", "--help", action="store_true")
    args = parser.parse_args(argv)

    if args.help:
        print(usage_text(), end="")
        raise SystemExit(0)
    if not args.url:
        print("Usage: playlist-to-audiobook.py -u|--url <url> [options]", file=sys.stderr)
        print("Run with --help or see script header for full option list.", file=sys.stderr)
        raise SystemExit(1)
    if not re.fullmatch(r"[0-9]+", str(args.bitrate)) or int(args.bitrate) == 0:
        print("Error: Bitrate (-b) must be a positive integer.", file=sys.stderr)
        raise SystemExit(1)
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", str(args.chapter_gap)):
        print("Error: Chapter gap (--chapter-gap) must be a non-negative number.", file=sys.stderr)
        raise SystemExit(1)
    if args.cover and not Path(args.cover).is_file():
        print(f"Error: Cover image not found: {args.cover}", file=sys.stderr)
        raise SystemExit(1)
    if args.output_dir and not Path(args.output_dir).is_dir():
        print(f"Error: Output directory does not exist: {args.output_dir}", file=sys.stderr)
        raise SystemExit(1)

    validate_dependencies()
    return Config(
        url=args.url,
        output=args.output,
        output_dir=args.output_dir,
        title=args.title,
        artist=args.artist,
        album=args.album,
        bitrate=int(args.bitrate),
        cover=args.cover,
        items=args.items,
        chapter_gap=float(args.chapter_gap),
        split=args.split,
        keep=args.keep,
        normalize=not args.no_normalize,
        verbose=args.verbose,
        quiet=args.quiet,
        dry_run=args.dry_run,
    )


def install_signal_handlers() -> None:
    def handle_interrupt(signum: int, frame) -> None:  # noqa: ANN001
        del signum, frame
        print("Error: Interrupted.", file=sys.stderr)
        raise SystemExit(130)

    signal.signal(signal.SIGINT, handle_interrupt)
    signal.signal(signal.SIGTERM, handle_interrupt)


def main(argv: list[str]) -> int:
    config = parse_args(argv)
    state = build_initial_state(config)
    install_signal_handlers()
    try:
        state = run_pipeline(state)
        return 0
    finally:
        cleanup(state)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
