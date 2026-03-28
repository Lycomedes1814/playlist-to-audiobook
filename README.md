# playlist-to-audiobook

Converts a YouTube playlist (or single video) into a single M4B audiobook file with per-video chapter markers and cover art.

## Features

- Downloads best available audio via `yt-dlp`
- Supports playlists and single videos
- EBU R128 loudness normalization (two-pass)
- Encodes to AAC M4B with configurable bitrate
- Embeds chapter markers (one per video, or uses YouTube chapter markers for single videos)
- Embeds playlist thumbnail or custom cover art
- Optional silence gaps between chapters
- Resumable downloads and normalization
- Dry-run mode to preview without downloading
- Cleans up intermediate files after encoding

## Dependencies

- [yt-dlp](https://github.com/yt-dlp/yt-dlp)
- [ffmpeg](https://ffmpeg.org/) (includes `ffprobe`)
- `python3` (used for parsing YouTube chapter metadata)

All must be on your `PATH`.

## Usage

```bash
./playlist-to-audiobook.sh -u <url> [options]
```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `-u, --url` | *(required)* | YouTube playlist or video URL |
| `-o, --output` | Playlist title | Output filename (no extension) |
| `-d, --output-dir` | Current directory | Directory for the output M4B |
| `-t, --title` | Playlist title | Title metadata tag |
| `-a, --artist` | Playlist uploader | Artist metadata tag |
| `-l, --album` | Playlist title | Album metadata tag |
| `-b, --bitrate` | `160` | Audio bitrate in kbps |
| `-c, --cover` | Playlist thumbnail | Path to a local cover image |
| `-i, --items` | All | Playlist item range (e.g. `1-5`, `2,4,6`) |
| `--chapter-gap` | `0` | Seconds of silence between chapters |
| `-k, --keep` | off | Keep intermediate downloaded files |
| `-n, --no-normalize` | off | Skip EBU R128 audio normalization |
| `-v, --verbose` | off | Show detailed yt-dlp and ffmpeg output |
| `-q, --quiet` | off | Suppress all non-error output |
| `--dry-run` | off | Show what would be done, then exit |
| `-h, --help` | | Show help message |

## Examples

```bash
# Minimal — full playlist
./playlist-to-audiobook.sh -u "https://www.youtube.com/playlist?list=PLxxxxx"

# Single video
./playlist-to-audiobook.sh -u "https://www.youtube.com/watch?v=xxxxx"

# Custom metadata, 128 kbps, keep files
./playlist-to-audiobook.sh -u "https://..." -o "my-book" -t "My Book" -a "Author" -b 128 -k

# First 5 videos, custom cover, 2s chapter gaps, output to ~/audiobooks
./playlist-to-audiobook.sh -u "https://..." -i "1-5" -c cover.jpg --chapter-gap 2 -d ~/audiobooks

# Preview without downloading
./playlist-to-audiobook.sh -u "https://..." --dry-run
```

## Output

The `.m4b` file is written to the current directory (or the directory specified with `-d`) using the playlist title (or `-o`) as the filename. Intermediate files are placed in a unique temporary work directory alongside the output file and removed after encoding unless `-k` is set.
