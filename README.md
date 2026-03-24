# PlaylistToM4b

Converts a YouTube playlist to a single M4B audiobook file with per-video chapter markers and cover art. Available in three flavors: **Bash**, **Python**, and **PowerShell**.

## Features

- Downloads best available audio via `yt-dlp`
- Encodes to AAC M4B with configurable bitrate
- Embeds chapter markers (one per video)
- Embeds playlist thumbnail as cover art
- Cleans up intermediate files after encoding

## Dependencies

- [yt-dlp](https://github.com/yt-dlp/yt-dlp)
- [ffmpeg](https://ffmpeg.org/) (includes `ffprobe`)

All three must be on your `PATH`.

## Usage

### Bash

```bash
./convert-yt-playlist-to-m4b.sh -u <playlist-url> [options]
```

### Python

```bash
python convert_yt_playlist_to_m4b.py -u <playlist-url> [options]
```

### PowerShell

```powershell
Import-Module .\ConvertYtPlaylistToM4b.psd1
Convert-YtPlaylistToM4b -Url <playlist-url> [options]
```

## Options

| Bash/Python flag | PowerShell parameter    | Default            | Description                        |
|------------------|-------------------------|--------------------|------------------------------------|
| `-u`             | `-Url`                  | *(required)*       | YouTube playlist URL               |
| `-o`             | `-OutputName`           | Playlist title     | Output filename (no extension)     |
| `-t`             | `-Title`                | Playlist title     | Title metadata tag                 |
| `-a`             | `-Artist`               | Playlist uploader  | Artist metadata tag                |
| `-l`             | `-Album`                | Playlist title     | Album metadata tag                 |
| `-b`             | `-AudioBitrateKbps`     | `160`              | Audio bitrate in kbps              |
| `-k`             | `-KeepDownloadedFiles`  | off                | Keep intermediate downloaded files |

## Examples

```bash
# Bash — minimal
./convert-yt-playlist-to-m4b.sh -u "https://www.youtube.com/playlist?list=PLxxxxx"

# Bash — custom metadata, 128 kbps, keep files
./convert-yt-playlist-to-m4b.sh -u "https://..." -o "my-book" -t "My Book" -a "Author" -b 128 -k
```

```bash
# Python — minimal
python convert_yt_playlist_to_m4b.py -u "https://www.youtube.com/playlist?list=PLxxxxx"
```

```powershell
# PowerShell — minimal
Convert-YtPlaylistToM4b -Url "https://www.youtube.com/playlist?list=PLxxxxx"

# PowerShell — custom metadata
Convert-YtPlaylistToM4b -Url "https://..." -OutputName "my-book" -Title "My Book" -Artist "Author" -AudioBitrateKbps 128 -KeepDownloadedFiles
```

## Output

The `.m4b` file is written to the current working directory using the playlist title (or `-o`/`-OutputName`) as the filename. Intermediate files are placed in a same-named subdirectory and removed after encoding unless `-k`/`-KeepDownloadedFiles` is set.
