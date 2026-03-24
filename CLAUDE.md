# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Converts a YouTube playlist into a single M4B audiobook with per-video chapter markers and cover art. Single Bash implementation.

## Architecture

The script follows a 5-step pipeline:

1. **Fetch metadata** — `yt-dlp --flat-playlist` to get playlist title and uploader
2. **Download audio** — `yt-dlp -x -f bestaudio` with indexed filenames (`%03d - title.ext`)
3. **Build concat list + chapters** — ffmpeg concat demuxer `list.txt` and `;FFMETADATA1` chapter file, using `ffprobe` for per-file durations
4. **Download thumbnail** — `yt-dlp --write-thumbnail --convert-thumbnails jpg`
5. **Encode M4B** — `ffmpeg` concat → AAC with chapters, cover art, and metadata

External dependencies: `yt-dlp`, `ffmpeg`, `ffprobe` (must be on PATH).

## File Map

- `convert-yt-playlist-to-m4b.sh` — Bash implementation

## Key Conventions

- ffmpeg concat list paths must use **forward slashes** and escape single quotes as `'\''`
- Chapter metadata files must start with exactly `;FFMETADATA1` on the first byte
- Filenames are sanitized by replacing `<>:"/\|?*` with `_`

## Testing

No test suite. Manual testing requires a real YouTube playlist URL and the external tools installed.

```bash
./convert-yt-playlist-to-m4b.sh "<playlist-url>"
```
