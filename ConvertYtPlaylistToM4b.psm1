function Convert-YtPlaylistToM4b {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [string]$OutputName,

        [string]$Title,

        [string]$Artist,

        [string]$Album,

        [int]$AudioBitrateKbps = 160,

        [switch]$KeepDownloadedFiles
    )

    $ErrorActionPreference = "Stop"

    # Fetch playlist metadata
    Write-Host "[1/5] Fetching playlist metadata..." -ForegroundColor Cyan
    $meta = yt-dlp --flat-playlist --print "%(playlist_title)s	%(uploader)s" $Url 2>$null | Select-Object -First 1
    $metaParts = ($meta -split "`t")
    $playlistTitle = $metaParts[0]
    $uploader      = if ($metaParts.Count -gt 1) { $metaParts[1] } else { "" }
    if (-not $playlistTitle) { $playlistTitle = "audiobook" }
    if (-not $uploader)      { $uploader      = "Unknown Artist" }

    if (-not $OutputName) { $OutputName = $playlistTitle }
    if (-not $Title)      { $Title      = $playlistTitle }
    if (-not $Album)      { $Album      = $playlistTitle }
    if (-not $Artist)     { $Artist     = $uploader }

    # Sanitize filename for Windows
    $safeOutputName = $OutputName -replace '[<>:"/\\|?*]', '_'
    $workdir = Join-Path (Get-Location) $safeOutputName

    if (-not (Test-Path $workdir)) {
        New-Item -ItemType Directory -Path $workdir | Out-Null
    }

    $listTxt    = Join-Path $workdir "list.txt"
    $chapterTxt = Join-Path $workdir "chapters.txt"
    $coverJpg   = Join-Path $workdir "cover.jpg"
    $outM4b     = Join-Path (Get-Location) ($safeOutputName + ".m4b")

    # Download playlist audio (accept any audio format)
    Write-Host "[2/5] Downloading playlist audio..." -ForegroundColor Cyan
    yt-dlp `
        --yes-playlist `
        --no-overwrites `
        --retries infinite `
        --fragment-retries infinite `
        -x `
        -f "bestaudio" `
        -o (Join-Path $workdir "%(playlist_index)03d - %(title)s.%(ext)s") `
        $Url
    if ($LASTEXITCODE -ne 0) {
        throw "yt-dlp download failed with exit code $LASTEXITCODE."
    }

    # Collect all downloaded audio files regardless of extension
    $audioFiles = Get-ChildItem -LiteralPath $workdir -File |
        Where-Object { $_.Extension -match '^\.(webm|opus|m4a|mp3|ogg|wav|flac|aac)$' } |
        Sort-Object Name
    if (-not $audioFiles) {
        throw "No audio files were downloaded."
    }
    Write-Host "  Found $($audioFiles.Count) audio file(s)." -ForegroundColor Gray

    # Build concat list and chapter metadata
    Write-Host "[3/5] Building concat list and chapter metadata..." -ForegroundColor Cyan
    $concatLines = @()
    $chapterLines = @()
    $cumulativeMs = 0

    foreach ($file in $audioFiles) {
        $p = $file.FullName -replace '\\','/'
        $p = $p -replace "'", "'\''"
        $concatLines += "file '$p'"

        # Get duration with ffprobe for chapter markers (use InvariantCulture since ffprobe always outputs '.' decimals)
        $durationStr = & ffprobe -v error -show_entries format=duration -of csv=p=0 $file.FullName 2>$null
        $durationSec = 0
        $parsed = [double]::TryParse(
            $durationStr.Trim(),
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$durationSec
        )
        if (-not $parsed -or $durationSec -le 0) {
            Write-Host "  Warning: Could not determine duration for $($file.Name), skipping chapter markers." -ForegroundColor Yellow
            $chapterLines = @()
            break
        }

        $startMs = [long]$cumulativeMs
        $endMs   = [long]($cumulativeMs + ($durationSec * 1000))

        # Extract chapter title from filename (strip index prefix and extension)
        $chapterTitle = $file.BaseName -replace '^\d+\s*-\s*', ''
        $chapterLines += "[CHAPTER]"
        $chapterLines += "TIMEBASE=1/1000"
        $chapterLines += "START=$startMs"
        $chapterLines += "END=$endMs"
        $chapterLines += "title=$chapterTitle"

        $cumulativeMs = $endMs
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($listTxt, $concatLines, $utf8NoBom)

    $hasChapters = $chapterLines.Count -gt 0
    if ($hasChapters) {
        $chapterContent = @(";FFMETADATA1") + $chapterLines
        [System.IO.File]::WriteAllLines($chapterTxt, $chapterContent, $utf8NoBom)
        Write-Host "  Generated $($audioFiles.Count) chapter marker(s)." -ForegroundColor Gray
    }

    # Download thumbnail
    Write-Host "[4/5] Downloading thumbnail..." -ForegroundColor Cyan
    yt-dlp `
        --skip-download `
        --write-thumbnail `
        --convert-thumbnails jpg `
        --playlist-items 1 `
        -o (Join-Path $workdir "cover") `
        $Url
    $hasCover = Test-Path $coverJpg
    if (-not $hasCover) {
        Write-Host "  No thumbnail found, proceeding without cover art." -ForegroundColor Yellow
    }

    # Encode M4B
    Write-Host "[5/5] Encoding M4B..." -ForegroundColor Cyan
    $ffmpegArgs = @("-y", "-f", "concat", "-safe", "0", "-i", $listTxt)

    if ($hasChapters) {
        $ffmpegArgs += @("-i", $chapterTxt)
    }

    if ($hasCover) {
        $ffmpegArgs += @("-i", $coverJpg)
    }

    if ($hasChapters) {
        $ffmpegArgs += @("-map_metadata", "1", "-map_chapters", "1")
    }

    if ($hasCover) {
        $coverStreamIndex = if ($hasChapters) { 2 } else { 1 }
        $ffmpegArgs += @("-map", "0:a", "-map", "${coverStreamIndex}:v")
        $ffmpegArgs += @("-c:v", "mjpeg", "-disposition:v:0", "attached_pic")
    } else {
        $ffmpegArgs += @("-map", "0:a")
    }

    $ffmpegArgs += @(
        "-c:a", "aac", "-b:a", "$($AudioBitrateKbps)k",
        "-metadata", "title=$Title",
        "-metadata", "artist=$Artist",
        "-metadata", "album=$Album",
        "-metadata", "genre=Audiobook",
        $outM4b
    )

    & ffmpeg @ffmpegArgs
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg encoding failed with exit code $LASTEXITCODE."
    }

    # Cleanup
    if (-not $KeepDownloadedFiles) {
        Write-Host "Cleaning up work files..." -ForegroundColor Gray
        Remove-Item -LiteralPath $workdir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Done: $outM4b" -ForegroundColor Green
}

Export-ModuleMember -Function Convert-YtPlaylistToM4b
