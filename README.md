# playlist-to-audiobook

Converts a YouTube playlist to a single M4B audiobook file with per-video chapter markers and cover art.

## Features

- Downloads best available audio via `yt-dlp`
- Encodes to AAC M4B with configurable bitrate
- Embeds chapter markers (one per video)
- Embeds playlist thumbnail as cover art
- Cleans up intermediate files after encoding

## Dependencies

- [yt-dlp](https://github.com/yt-dlp/yt-dlp)
- [ffmpeg](https://ffmpeg.org/) (includes `ffprobe`)

Both must be on your `PATH`.

## Usage

```bash
./playlist-to-audiobook.sh -u <playlist-url> [options]
```

## Options

| Flag | Default           | Description                        |
|------|-------------------|------------------------------------|
| `-u` | *(required)*      | YouTube playlist URL               |
| `-o` | Playlist title    | Output filename (no extension)     |
| `-t` | Playlist title    | Title metadata tag                 |
| `-a` | Playlist uploader | Artist metadata tag                |
| `-l` | Playlist title    | Album metadata tag                 |
| `-b` | `160`             | Audio bitrate in kbps              |
| `-k` | off               | Keep intermediate downloaded files |

## Examples

```bash
# Minimal
./playlist-to-audiobook.sh -u "https://www.youtube.com/playlist?list=PLxxxxx"

# Custom metadata, 128 kbps, keep files
./playlist-to-audiobook.sh -u "https://..." -o "my-book" -t "My Book" -a "Author" -b 128 -k
```

## Output

The `.m4b` file is written to the current working directory using the playlist title (or `-o`) as the filename. Intermediate files are placed in a same-named subdirectory and removed after encoding unless `-k` is set.
