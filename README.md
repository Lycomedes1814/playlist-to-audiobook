# playlist-to-audiobook

Converts a YouTube playlist (or single video) into one or more M4B audiobook files with chapter markers and cover art.

Two implementations are included:

- `playlist-to-audiobook.sh` for the original Bash pipeline
- `playlist-to-audiobook.py` as a Python alternative with the same feature set and CLI flags

## Features

- Downloads best available audio via `yt-dlp`
- Supports playlists and single videos
- EBU R128 loudness normalization (two-pass)
- Encodes to AAC M4B with configurable bitrate
- Embeds chapter markers (one per video, or uses YouTube chapter markers for single videos)
- Embeds playlist thumbnail or custom cover art
- **Split mode** — encode each playlist item as its own M4B with per-video cover art
- Avoids split-mode filename collisions by auto-suffixing duplicates
- Optional silence gaps between chapters
- Resumable downloads and normalization
- Dry-run mode to preview without downloading
- Cleans up intermediate files after encoding
- Immune to user yt-dlp config files interfering with format or output settings

## Dependencies

- [yt-dlp](https://github.com/yt-dlp/yt-dlp)
- [ffmpeg](https://ffmpeg.org/) (includes `ffprobe`)
- `python3` (used for parsing YouTube chapter metadata)

All must be on your `PATH`.

## Usage

```bash
./playlist-to-audiobook.sh -u <url> [options]

# Python alternative
python3 ./playlist-to-audiobook.py -u <url> [options]
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
| `-s, --split` | off | Encode each playlist item as its own M4B file |
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

# Split — one M4B per playlist item, output to ~/audiobooks
./playlist-to-audiobook.sh -u "https://..." -s -d ~/audiobooks
```

## Output

**Combined mode (default):** a single `.m4b` is written to the current directory (or `-d`) using the playlist title (or `-o`) as the filename. Each video becomes a chapter.

**Split mode (`-s`):** one `.m4b` per playlist item, named after each video's title, all written to the output directory. If two items would sanitize to the same filename, later files are suffixed as ` (2)`, ` (3)`, and so on instead of overwriting earlier outputs. Per-video thumbnails are automatically downloaded and embedded as cover art. The `-o` and `-t` flags are ignored in split mode; use `-a`/`-l` to set shared artist and album tags. If any per-item encode fails, the overall run exits with an error.

In both modes, intermediate files are placed in a temporary work directory and removed after encoding unless `-k` is set.

## Testing

Run the integration suite against the Bash implementation:

```bash
./test-playlist.sh
```

Run the same suite against the Python implementation:

```bash
./test-playlist.sh --python
```
