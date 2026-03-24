#!/usr/bin/env python3
"""
convert_yt_playlist_to_m4b.py
Converts a YouTube playlist to a single M4B audiobook file with chapters and cover art.

Dependencies: yt-dlp, ffmpeg, ffprobe (must be on PATH)

Usage:
    python convert_yt_playlist_to_m4b.py -u <url> [-o <output-name>] [-t <title>]
                                          [-a <artist>] [-l <album>] [-b <bitrate>] [-k]
"""

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path


AUDIO_EXTENSIONS = {".webm", ".opus", ".m4a", ".mp3", ".ogg", ".wav", ".flac", ".aac"}


def check_dependencies():
    for cmd in ("yt-dlp", "ffmpeg", "ffprobe"):
        if not shutil.which(cmd):
            sys.exit(f"Error: '{cmd}' is not installed or not in PATH.")


def run(*args, **kwargs):
    """Run a subprocess, raising on non-zero exit."""
    return subprocess.run(args, check=True, **kwargs)


def fetch_playlist_meta(url):
    result = subprocess.run(
        ["yt-dlp", "--flat-playlist", "--print", "%(playlist_title)s\t%(uploader)s", url],
        capture_output=True, text=True,
    )
    first_line = result.stdout.splitlines()[0] if result.stdout.strip() else ""
    parts = first_line.split("\t", 1)
    title    = parts[0].strip() or "audiobook"
    uploader = parts[1].strip() if len(parts) > 1 else ""
    return title, uploader or "Unknown Artist"


def get_duration(path):
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", str(path)],
        capture_output=True, text=True,
    )
    try:
        return float(result.stdout.strip())
    except ValueError:
        return None


def sanitize(name):
    return re.sub(r'[<>:"/\\|?*]', "_", name)


def main():
    parser = argparse.ArgumentParser(
        description="Convert a YouTube playlist to an M4B audiobook."
    )
    parser.add_argument("-u", "--url",        required=True, help="YouTube playlist URL")
    parser.add_argument("-o", "--output",     default="",   help="Output filename (no extension)")
    parser.add_argument("-t", "--title",      default="",   help="Title metadata tag")
    parser.add_argument("-a", "--artist",     default="",   help="Artist metadata tag")
    parser.add_argument("-l", "--album",      default="",   help="Album metadata tag")
    parser.add_argument("-b", "--bitrate",    default=160,  type=int, help="Audio bitrate kbps (default: 160)")
    parser.add_argument("-k", "--keep",       action="store_true", help="Keep downloaded files")
    args = parser.parse_args()

    check_dependencies()

    # Step 1: playlist metadata
    print("\033[0;36m[1/5] Fetching playlist metadata...\033[0m")
    playlist_title, uploader = fetch_playlist_meta(args.url)

    output_name = args.output or playlist_title
    title       = args.title  or playlist_title
    album       = args.album  or playlist_title
    artist      = args.artist or uploader

    safe_name = sanitize(output_name)
    workdir   = Path.cwd() / safe_name
    workdir.mkdir(exist_ok=True)

    list_txt    = workdir / "list.txt"
    chapter_txt = workdir / "chapters.txt"
    cover_jpg   = workdir / "cover.jpg"
    out_m4b     = Path.cwd() / (safe_name + ".m4b")

    # Step 2: download audio
    print("\033[0;36m[2/5] Downloading playlist audio...\033[0m")
    run(
        "yt-dlp", "--yes-playlist", "--no-overwrites",
        "--retries", "infinite", "--fragment-retries", "infinite",
        "-x", "-f", "bestaudio",
        "-o", str(workdir / "%(playlist_index)03d - %(title)s.%(ext)s"),
        args.url,
    )

    # Step 3: concat list + chapter metadata
    print("\033[0;36m[3/5] Building concat list and chapter metadata...\033[0m")
    audio_files = sorted(
        f for f in workdir.iterdir()
        if f.is_file() and f.suffix.lower() in AUDIO_EXTENSIONS
    )
    if not audio_files:
        sys.exit("Error: No audio files were downloaded.")
    print(f"\033[0;37m  Found {len(audio_files)} audio file(s).\033[0m")

    concat_lines  = []
    chapter_lines = []
    cumulative_ms = 0
    has_chapters  = True

    for f in audio_files:
        escaped = f.as_posix().replace("'", r"'\''")
        concat_lines.append(f"file '{escaped}'")

        duration = get_duration(f)
        if duration is None or duration <= 0:
            print(f"\033[0;33m  Warning: Could not determine duration for {f.name}, skipping chapter markers.\033[0m")
            has_chapters = False
            chapter_lines = []
            break

        start_ms = cumulative_ms
        end_ms   = cumulative_ms + int(duration * 1000)
        cumulative_ms = end_ms

        chapter_title = re.sub(r"^\d+\s*-\s*", "", f.stem)
        chapter_lines += [
            "[CHAPTER]",
            "TIMEBASE=1/1000",
            f"START={start_ms}",
            f"END={end_ms}",
            f"title={chapter_title}",
        ]

    list_txt.write_text("\n".join(concat_lines), encoding="utf-8")

    if has_chapters and chapter_lines:
        chapter_txt.write_text(
            ";FFMETADATA1\n" + "\n".join(chapter_lines), encoding="utf-8"
        )
        print(f"\033[0;37m  Generated {len(audio_files)} chapter marker(s).\033[0m")

    # Step 4: thumbnail
    print("\033[0;36m[4/5] Downloading thumbnail...\033[0m")
    subprocess.run(
        ["yt-dlp", "--skip-download", "--write-thumbnail",
         "--convert-thumbnails", "jpg", "--playlist-items", "1",
         "-o", str(workdir / "cover"), args.url],
        check=False,
    )
    has_cover = cover_jpg.exists()
    if not has_cover:
        print("\033[0;33m  No thumbnail found, proceeding without cover art.\033[0m")

    # Step 5: encode M4B
    print("\033[0;36m[5/5] Encoding M4B...\033[0m")
    ffmpeg_args = [
        "ffmpeg", "-y",
        "-f", "concat", "-safe", "0", "-i", str(list_txt),
    ]

    if has_chapters and chapter_txt.exists():
        ffmpeg_args += ["-i", str(chapter_txt)]

    if has_cover:
        ffmpeg_args += ["-i", str(cover_jpg)]

    if has_chapters and chapter_txt.exists():
        ffmpeg_args += ["-map_metadata", "1", "-map_chapters", "1"]

    if has_cover:
        cover_idx = 2 if (has_chapters and chapter_txt.exists()) else 1
        ffmpeg_args += ["-map", "0:a", "-map", f"{cover_idx}:v",
                        "-c:v", "mjpeg", "-disposition:v:0", "attached_pic"]
    else:
        ffmpeg_args += ["-map", "0:a"]

    ffmpeg_args += [
        "-c:a", "aac", "-b:a", f"{args.bitrate}k",
        "-metadata", f"title={title}",
        "-metadata", f"artist={artist}",
        "-metadata", f"album={album}",
        "-metadata", "genre=Audiobook",
        str(out_m4b),
    ]

    run(*ffmpeg_args)

    # Cleanup
    if not args.keep:
        print("\033[0;37m  Cleaning up work files...\033[0m")
        shutil.rmtree(workdir)

    print(f"\033[0;32mDone: {out_m4b}\033[0m")


if __name__ == "__main__":
    main()
