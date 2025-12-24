# Process-NFS-VideoRips.ps1
# Watches NFS/SMB shares for video files, downloads to local, encodes, uploads back
# Workflow:
#   1. Watch NFS shares (More_Movies, TV) for MKV/M2TS files
#   2. Check if file is already compressed (H.265/HEVC, AV1, VP9) - skip if so
#   3. Download file to local F: drive
#   4. Encode locally with AMD AMF AV1
#   5. Upload encoded file to appropriate NFS destination (Movies_Encoded or TV_Encoded)
#   6. Delete original from NFS and both local copies
#
# 2025-12-23: Initial creation - NFS pull/encode/push workflow
# 2025-12-23: Updated to watch More_Movies and TV folders
# 2025-12-24: Skip already-compressed files (H.265/HEVC, AV1, VP9) and log them for review

param(
    # NFS/SMB base path (10Gb network) - this is the SMB share
    [string]$NfsSharePath = "\\10.0.0.1\media",
    [string]$NfsUser = "jluczani",
    [string]$NfsPassword = "password",

    # Watch folders (relative to share - share already maps to /tank/media/media)
    [string[]]$WatchFolders = @("More_Movies", "TV"),

    # Destination folders (relative to share)
    [string]$MoviesEncodedFolder = "Movies_Encoded",
    [string]$TVEncodedFolder = "TV_Encoded",

    # Local paths
    [string]$LocalDownloadPath = "F:\MediaProcessing\nfs-downloads",
    [string]$LocalEncodedPath = "F:\MediaProcessing\nfs-encoded",

    # FFmpeg settings
    [string]$FFmpegPath = "C:\ffmpeg\bin\ffmpeg.exe",
    [string]$FFprobePath = "C:\ffmpeg\bin\ffprobe.exe",

    # Timing
    [int]$PollIntervalSeconds = 60,
    [int]$FileReadyAgeSeconds = 30,
    [int]$FileSizeCheckWaitSeconds = 5,

    # Minimum file size (skip small files like samples)
    [int]$MinFileSizeMB = 500
)

$LogFile = "C:\Scripts\Logs\nfs-video-processing.log"
$SkippedFilesLog = "C:\Scripts\Logs\nfs-skipped-already-compressed.log"

# Codecs that are considered "already compressed" and should be skipped
$CompressedCodecs = @("hevc", "h265", "av1", "vp9")

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "$Timestamp [$Level] $Message"

    # Ensure log directory exists
    $LogDir = Split-Path -Path $LogFile -Parent
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    $LogMessage | Add-Content -Path $LogFile
    Write-Host $LogMessage
}

function Write-SkippedFile {
    param(
        [string]$FilePath,
        [string]$Codec,
        [double]$SizeGB,
        [string]$Reason
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "$Timestamp | $Codec | $([math]::Round($SizeGB, 2)) GB | $Reason | $FilePath"

    # Ensure log directory exists
    $LogDir = Split-Path -Path $SkippedFilesLog -Parent
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    $LogEntry | Add-Content -Path $SkippedFilesLog
    Write-Log "SKIPPED (already $Codec): $FilePath" -Level "SKIP"
}

function Test-AlreadyCompressed {
    <#
    .SYNOPSIS
    Checks if a video file is already encoded with an efficient codec (H.265/HEVC, AV1, VP9).

    .DESCRIPTION
    Uses ffprobe to detect the video codec. Files already compressed with modern codecs
    would likely increase in size if re-encoded, so they should be skipped.

    .RETURNS
    Returns a hashtable with 'IsCompressed' boolean and 'Codec' string, or $null on error.
    #>
    param([string]$FilePath)

    try {
        # Use ffprobe to get video codec
        $ffprobeArgs = @(
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_name",
            "-of", "default=noprint_wrappers=1:nokey=1",
            "`"$FilePath`""
        ) -join ' '

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FFprobePath
        $psi.Arguments = $ffprobeArgs
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        $process.Start() | Out-Null

        $codec = $process.StandardOutput.ReadToEnd().Trim().ToLower()
        $process.WaitForExit()

        if ($process.ExitCode -ne 0 -or [string]::IsNullOrEmpty($codec)) {
            Write-Log "Could not detect codec for: $FilePath" -Level "WARNING"
            return $null
        }

        $isCompressed = $CompressedCodecs -contains $codec

        return @{
            IsCompressed = $isCompressed
            Codec = $codec
        }
    } catch {
        Write-Log "ffprobe error for $FilePath : $($_.Exception.Message)" -Level "ERROR"
        return $null
    }
}

function Ensure-SmbSession {
    param(
        [string]$Path,
        [string]$User,
        [string]$Password
    )

    try {
        # Test if already connected
        if (Test-Path $Path) {
            return $true
        }

        # Establish connection
        net use $Path $Password /user:$User /persistent:no 2>$null | Out-Null

        if (Test-Path $Path) {
            Write-Log "SMB session established for $Path" -Level "SUCCESS"
            return $true
        }

        Write-Log "Could not access $Path after connection attempt" -Level "ERROR"
        return $false
    } catch {
        Write-Log "SMB session failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Test-FileReady {
    param([System.IO.FileInfo]$File)

    # Check file age
    $FileAge = (Get-Date) - $File.LastWriteTime
    if ($FileAge.TotalSeconds -lt $FileReadyAgeSeconds) {
        return $false
    }

    # Try to open file
    try {
        $stream = [System.IO.File]::Open($File.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $stream.Close()
        $stream.Dispose()
    } catch {
        return $false
    }

    # Check size stability
    $InitialSize = $File.Length
    Start-Sleep -Seconds $FileSizeCheckWaitSeconds
    $File.Refresh()

    if ($InitialSize -ne $File.Length) {
        return $false
    }

    return $true
}

function Get-MediaType {
    param([string]$SourcePath)

    # Determine if this is a movie or TV based on source folder
    if ($SourcePath -like "*\TV\*" -or $SourcePath -like "*\TV") {
        return "TV"
    } else {
        return "Movies"
    }
}

function Get-NfsVideoFiles {
    $allFiles = @()

    foreach ($folder in $WatchFolders) {
        $watchPath = Join-Path $NfsSharePath $folder

        if (-not (Test-Path $watchPath)) {
            Write-Log "Watch path not accessible: $watchPath" -Level "WARNING"
            continue
        }

        $files = Get-ChildItem -Path $watchPath -Recurse -Include *.mkv,*.m2ts -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt ($MinFileSizeMB * 1MB) }

        if ($files) {
            $allFiles += $files
        }
    }

    return $allFiles
}

function Copy-FromNfs {
    param(
        [System.IO.FileInfo]$SourceFile
    )

    # Determine media type for folder structure
    $mediaType = Get-MediaType -SourcePath $SourceFile.FullName

    # Create local path preserving some structure
    $fileName = $SourceFile.Name
    $parentFolder = $SourceFile.Directory.Name

    # If parent folder is just "More_Movies" or "TV", use file name directly
    # Otherwise preserve the show/movie folder
    if ($parentFolder -in $WatchFolders) {
        $LocalFile = Join-Path $LocalDownloadPath (Join-Path $mediaType $fileName)
    } else {
        $LocalFile = Join-Path $LocalDownloadPath (Join-Path $mediaType (Join-Path $parentFolder $fileName))
    }

    $LocalDir = Split-Path -Path $LocalFile -Parent

    # Create local directory
    if (-not (Test-Path $LocalDir)) {
        New-Item -ItemType Directory -Path $LocalDir -Force | Out-Null
    }

    Write-Log "Downloading from NFS: $($SourceFile.Name) ($([math]::Round($SourceFile.Length/1GB, 2)) GB)"

    try {
        $startTime = Get-Date
        Copy-Item -Path $SourceFile.FullName -Destination $LocalFile -Force
        $duration = (Get-Date) - $startTime
        $speedMBps = [math]::Round(($SourceFile.Length / 1MB) / $duration.TotalSeconds, 1)

        Write-Log "Download complete: $speedMBps MB/s" -Level "SUCCESS"
        return $LocalFile
    } catch {
        Write-Log "Download failed: $($_.Exception.Message)" -Level "ERROR"
        return $null
    }
}

function Invoke-FFmpegEncode {
    param(
        [string]$InputFile,
        [string]$OutputFile
    )

    Write-Log "Encoding with AMD AMF AV1: $(Split-Path $InputFile -Leaf)"

    # Ensure output directory exists
    $OutputDir = Split-Path -Path $OutputFile -Parent
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    # Build FFmpeg arguments with proper quoting
    $Arguments = @(
        "-hide_banner",
        "-y",
        "-i", "`"$InputFile`"",
        "-c:v", "av1_amf",
        "-quality", "balanced",
        "-rc", "vbr_peak",
        "-b:v", "6M",
        "-maxrate", "10M",
        "-bufsize", "20M",
        "-usage", "transcoding",
        "-pix_fmt", "yuv420p",
        "-map", "0",
        "-c:a", "copy",
        "-c:s", "copy",
        "`"$OutputFile`""
    ) -join ' '

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FFmpegPath
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        $startTime = Get-Date
        $process.Start() | Out-Null

        # Set High priority
        try {
            $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
            Write-Log "FFmpeg started with High priority (PID: $($process.Id))"
        } catch {
            Write-Log "Could not set High priority" -Level "WARNING"
        }

        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $duration = (Get-Date) - $startTime

        if ($process.ExitCode -eq 0) {
            $InputSize = (Get-Item $InputFile).Length / 1GB
            $OutputSize = (Get-Item $OutputFile).Length / 1GB
            $Reduction = [math]::Round((($InputSize - $OutputSize) / $InputSize) * 100, 1)

            Write-Log "Encoding complete in $([math]::Round($duration.TotalMinutes, 1)) min" -Level "SUCCESS"
            Write-Log "Size: $([math]::Round($InputSize, 2))GB -> $([math]::Round($OutputSize, 2))GB ($Reduction% reduction)" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "Encoding failed with exit code: $($process.ExitCode)" -Level "ERROR"
            # Log last few lines of stderr for debugging
            $lastLines = ($stderr -split "`n" | Select-Object -Last 5) -join "; "
            Write-Log "FFmpeg error: $lastLines" -Level "ERROR"
            return $false
        }
    } catch {
        Write-Log "Encoding exception: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Copy-ToNfs {
    param(
        [string]$LocalFile,
        [string]$OriginalNfsFile
    )

    # Determine media type and destination
    $mediaType = Get-MediaType -SourcePath $OriginalNfsFile

    if ($mediaType -eq "TV") {
        $destBase = Join-Path $NfsSharePath $TVEncodedFolder
    } else {
        $destBase = Join-Path $NfsSharePath $MoviesEncodedFolder
    }

    # Get just the filename and parent folder for destination
    $fileName = Split-Path $LocalFile -Leaf
    $parentFolder = Split-Path (Split-Path $LocalFile -Parent) -Leaf

    # If parent is just "Movies" or "TV", use file directly
    if ($parentFolder -in @("Movies", "TV")) {
        $NfsDestFile = Join-Path $destBase $fileName
    } else {
        $NfsDestFile = Join-Path $destBase (Join-Path $parentFolder $fileName)
    }

    $NfsDestDir = Split-Path -Path $NfsDestFile -Parent

    # Create destination directory
    if (-not (Test-Path $NfsDestDir)) {
        New-Item -ItemType Directory -Path $NfsDestDir -Force | Out-Null
        Write-Log "Created NFS directory: $NfsDestDir"
    }

    Write-Log "Uploading to NFS ($mediaType): $NfsDestFile"

    try {
        $FileSize = (Get-Item $LocalFile).Length
        $startTime = Get-Date
        Copy-Item -Path $LocalFile -Destination $NfsDestFile -Force
        $duration = (Get-Date) - $startTime
        $speedMBps = [math]::Round(($FileSize / 1MB) / $duration.TotalSeconds, 1)

        Write-Log "Upload complete: $speedMBps MB/s" -Level "SUCCESS"
        return $NfsDestFile
    } catch {
        Write-Log "Upload failed: $($_.Exception.Message)" -Level "ERROR"
        return $null
    }
}

function Remove-ProcessedFiles {
    param(
        [string]$NfsOriginal,
        [string]$LocalDownload,
        [string]$LocalEncoded
    )

    # Delete NFS original
    try {
        Remove-Item -Path $NfsOriginal -Force
        Write-Log "Deleted NFS original: $NfsOriginal" -Level "SUCCESS"
    } catch {
        Write-Log "Could not delete NFS original: $($_.Exception.Message)" -Level "WARNING"
    }

    # Delete local download
    try {
        if (Test-Path $LocalDownload) {
            Remove-Item -Path $LocalDownload -Force
            Write-Log "Deleted local download: $LocalDownload"
        }
    } catch {
        Write-Log "Could not delete local download: $($_.Exception.Message)" -Level "WARNING"
    }

    # Delete local encoded
    try {
        if (Test-Path $LocalEncoded) {
            Remove-Item -Path $LocalEncoded -Force
            Write-Log "Deleted local encoded: $LocalEncoded"
        }
    } catch {
        Write-Log "Could not delete local encoded: $($_.Exception.Message)" -Level "WARNING"
    }

    # Cleanup empty directories
    foreach ($path in @($LocalDownload, $LocalEncoded)) {
        if ($path) {
            $parentDir = Split-Path -Path $path -Parent
            try {
                if ((Test-Path $parentDir) -and ((Get-ChildItem -Path $parentDir -Force).Count -eq 0)) {
                    Remove-Item -Path $parentDir -Force -Recurse -ErrorAction SilentlyContinue
                }
            } catch { }
        }
    }
}

# ============================================================================
# MAIN LOOP
# ============================================================================

Write-Log "============================================" -Level "SUCCESS"
Write-Log "NFS Video Processing Monitor Started" -Level "SUCCESS"
Write-Log "============================================" -Level "SUCCESS"
Write-Log "NFS Base: $NfsSharePath"
Write-Log "Watch folders: $($WatchFolders -join ', ')"
Write-Log "Movies output: $NfsSharePath\$MoviesEncodedFolder"
Write-Log "TV output: $NfsSharePath\$TVEncodedFolder"
Write-Log "Local Download: $LocalDownloadPath"
Write-Log "Local Encoded: $LocalEncodedPath"
Write-Log "Encoder: FFmpeg AMD AMF AV1 (6 Mbps target, 10 Mbps max)"
Write-Log "Min file size: $MinFileSizeMB MB"
Write-Log "Poll interval: $PollIntervalSeconds seconds"
Write-Log "Skip codecs: $($CompressedCodecs -join ', ') (already compressed)"
Write-Log "Skipped files log: $SkippedFilesLog"
Write-Log ""
Write-Log "Workflow: Check codec -> Download from NFS -> Encode local -> Upload to NFS -> Cleanup"

# Ensure local directories exist
foreach ($dir in @($LocalDownloadPath, $LocalEncodedPath)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Log "Created directory: $dir"
    }
}

# Establish SMB session
if (-not (Ensure-SmbSession -Path $NfsSharePath -User $NfsUser -Password $NfsPassword)) {
    Write-Log "FATAL: Could not establish SMB session to $NfsSharePath" -Level "ERROR"
    exit 1
}

Write-Log "Monitoring NFS for video files..."

while ($true) {
    # Re-establish SMB session if needed
    if (-not (Test-Path $NfsSharePath)) {
        Write-Log "NFS connection lost, reconnecting..." -Level "WARNING"
        Ensure-SmbSession -Path $NfsSharePath -User $NfsUser -Password $NfsPassword
    }

    $VideoFiles = Get-NfsVideoFiles

    if ($VideoFiles.Count -gt 0) {
        Write-Log "Found $($VideoFiles.Count) video file(s) on NFS to process"
    }

    foreach ($File in $VideoFiles) {
        # Check if file is ready
        if (-not (Test-FileReady -File $File)) {
            continue
        }

        $mediaType = Get-MediaType -SourcePath $File.FullName
        $fileSizeGB = $File.Length / 1GB

        # Check if file is already compressed with efficient codec
        $codecCheck = Test-AlreadyCompressed -FilePath $File.FullName
        if ($codecCheck -and $codecCheck.IsCompressed) {
            Write-SkippedFile -FilePath $File.FullName -Codec $codecCheck.Codec -SizeGB $fileSizeGB -Reason "Already compressed - would increase in size"
            continue
        }

        # Log the detected codec for files we will process
        $codecInfo = if ($codecCheck) { " [Source: $($codecCheck.Codec)]" } else { "" }

        Write-Log "========================================" -Level "SUCCESS"
        Write-Log "Processing [$mediaType]: $($File.Name) ($([math]::Round($fileSizeGB, 2)) GB)$codecInfo" -Level "SUCCESS"
        Write-Log "Source: $($File.DirectoryName)" -Level "INFO"
        Write-Log "========================================" -Level "SUCCESS"

        # Step 1: Download from NFS to local
        $LocalDownloadFile = Copy-FromNfs -SourceFile $File
        if (-not $LocalDownloadFile) {
            Write-Log "Failed to download, skipping file" -Level "ERROR"
            continue
        }

        # Step 2: Determine local encoded path (mirror download structure)
        $RelativePath = $LocalDownloadFile.Substring($LocalDownloadPath.Length).TrimStart('\')
        $LocalEncodedFile = Join-Path $LocalEncodedPath $RelativePath

        # Step 3: Encode locally
        $EncodeSuccess = Invoke-FFmpegEncode -InputFile $LocalDownloadFile -OutputFile $LocalEncodedFile
        if (-not $EncodeSuccess) {
            Write-Log "Encoding failed, keeping original on NFS" -Level "ERROR"
            # Clean up local download only
            Remove-Item -Path $LocalDownloadFile -Force -ErrorAction SilentlyContinue
            continue
        }

        # Step 4: Upload to NFS (routed to correct folder based on media type)
        $NfsEncodedFile = Copy-ToNfs -LocalFile $LocalEncodedFile -OriginalNfsFile $File.FullName
        if (-not $NfsEncodedFile) {
            Write-Log "Upload failed, keeping local encoded file: $LocalEncodedFile" -Level "ERROR"
            Remove-Item -Path $LocalDownloadFile -Force -ErrorAction SilentlyContinue
            continue
        }

        # Step 5: Cleanup - delete original from NFS and both local copies
        Remove-ProcessedFiles -NfsOriginal $File.FullName -LocalDownload $LocalDownloadFile -LocalEncoded $LocalEncodedFile

        Write-Log "Processing complete for: $($File.Name)" -Level "SUCCESS"
    }

    Start-Sleep -Seconds $PollIntervalSeconds
}
