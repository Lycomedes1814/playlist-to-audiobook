# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Converts a YouTube playlist (or single video) into one or more M4B audiobooks with chapter markers and cover art. Single Python implementation.

## Architecture

The script follows a 6-step pipeline:

1. **Fetch metadata** — `yt-dlp -J` to distinguish playlists from single videos and extract title/uploader reliably; for single videos, a separate `yt-dlp --print %(chapters)j` call fetches YouTube chapter markers
2. **Download audio** — `yt-dlp -x -f bestaudio` with indexed filenames (`%(playlist_index)03d - %(title).200B.%(ext)s`); `--no-overwrites` enables resume
3. **Prepare audio** — two-pass EBU R128 loudness normalization via ffmpeg `loudnorm` filter, or (with `-n`) conversion to a concat-safe WAV intermediate format; always runs, tracks completed files for resume
4. **Build concat list + chapters** — ffmpeg concat demuxer `list.txt` and `;FFMETADATA1` chapter file, using `ffprobe` for per-file durations; for single videos, YouTube chapter markers are used if available; optional silence gaps between chapters
5. **Cover art** — `yt-dlp --write-thumbnail --convert-thumbnails jpg`, or user-provided image via `-c`
6. **Encode M4B** — `ffmpeg` concat → AAC with chapters, cover art, and metadata

**Split mode (`-s`):** steps 4–6 are replaced by a per-file loop that encodes each normalized audio file directly to its own M4B. Per-item thumbnails are downloaded during step 2 via `--write-thumbnail`. Output filename collisions are resolved by suffixing ` (2)`, ` (3)`, etc. Any per-item encode failure makes the overall run fail. Steps 4–6 of the normal path are skipped entirely.

External dependencies: `yt-dlp`, `ffmpeg`, `ffprobe`, `python3` (must be on PATH).

## File Map

- `playlist-to-audiobook.py` — Python implementation

## Key Conventions

- ffmpeg concat list entries escape single quotes as `'\''`
- Chapter metadata files must start with exactly `;FFMETADATA1` on the first byte
- Filenames are sanitized by stripping newlines and replacing `<>:"/\|?*'` and control characters (`\x00-\x1f`) with `_`; empty results fall back to `audiobook`

## Testing

Integration coverage lives in `test-playlist.sh`. It exercises validation, dry-run behavior, combined and split outputs, metadata, chapters, cover art, cleanup, and hostile filename/metadata edge cases against a real playlist URL.

```bash
./test-playlist.sh
```
