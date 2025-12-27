# Process-NFS-VideoRips.ps1
# Watches NFS/SMB shares for video files, downloads to local, encodes, uploads back
#
# Sequential processing workflow:
#   1. Watch NFS shares (More_Movies, TV) for MKV/M2TS files
#   2. Check if file is already compressed (H.265/HEVC, AV1, VP9) - skip if so
#   3. Check bitrate - skip if already efficient (<= 7.8 Mbps for H.264)
#   4. Download file to local drive
#   5. Encode with AMD AMF AV1 (GPU accelerated)
#   6. Upload encoded file to NFS destination
#   7. Delete original from NFS and local copies
#
# 2025-12-23: Initial creation - NFS pull/encode/push workflow
# 2025-12-26: Added bitrate detection to skip already-efficient files
# 2025-12-27: Reverted to sequential encoding for stability
# 2025-12-27: Switched from SMB to native NFS mount (Samba not available)

param(
    # NFS server and export path
    [string]$NfsServer = "10.0.0.1",
    [string]$NfsExport = "/tank/media/media",
    [string]$NfsDriveLetter = "N",

    # Watch folders (relative to NFS mount)
    [string[]]$WatchFolders = @("More_Movies", "TV"),

    # Destination folders (relative to NFS mount)
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

    # Minimum file size (skip small files like samples)
    [int]$MinFileSizeMB = 500,

    # Target encoding bitrate in Mbps
    [int]$TargetBitrateMbps = 6,

    # Bitrate threshold multiplier - skip if source <= target * multiplier
    [double]$BitrateThresholdMultiplier = 1.3
)

$LogFile = "C:\Scripts\Logs\nfs-video-processing.log"
$SkippedFilesLog = "C:\Scripts\Logs\nfs-skipped-already-compressed.log"
$ProgressFile = "C:\Scripts\Logs\nfs-encoding-progress.json"

# NFS mount base path (the mounted drive letter)
$NfsBasePath = "${NfsDriveLetter}:\"

# Calculate skip threshold: skip files at or below this bitrate (in kbps)
$SkipBitrateKbps = $TargetBitrateMbps * 1000 * $BitrateThresholdMultiplier

# Codecs that are considered "already compressed" and should be skipped
$CompressedCodecs = @("hevc", "h265", "av1", "vp9")

# Track processed files to avoid re-processing
$script:ProcessedFiles = @{}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "$Timestamp [$Level] $Message"

    $LogDir = Split-Path -Path $LogFile -Parent
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    $LogMessage | Add-Content -Path $LogFile
    Write-Host $LogMessage
}

# Progress tracking functions
function Update-Progress {
    param(
        [string]$Event,    # "processing", "encoded", "skipped", "failed", "downloaded"
        [string]$FilePath,
        [string]$Details = ""
    )

    try {
        $progress = @{}
        if (Test-Path $ProgressFile) {
            $progress = Get-Content $ProgressFile -Raw | ConvertFrom-Json -AsHashtable
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        switch ($Event) {
            "processing" {
                $progress["current_file"] = $FilePath
                $progress["current_started"] = $timestamp
                $progress["current_status"] = "downloading"
            }
            "downloaded" {
                $progress["current_status"] = "encoding"
                $progress["last_downloaded"] = $FilePath
                $progress["last_downloaded_at"] = $timestamp
            }
            "encoded" {
                $progress["last_encoded"] = $FilePath
                $progress["last_encoded_at"] = $timestamp
                $progress["current_file"] = $null
                $progress["current_status"] = "idle"
                $progress["total_encoded"] = ($progress["total_encoded"] ?? 0) + 1
            }
            "skipped" {
                $progress["last_skipped"] = $FilePath
                $progress["last_skipped_at"] = $timestamp
                $progress["last_skipped_reason"] = $Details
                $progress["total_skipped"] = ($progress["total_skipped"] ?? 0) + 1
            }
            "failed" {
                $progress["last_failed"] = $FilePath
                $progress["last_failed_at"] = $timestamp
                $progress["last_failed_reason"] = $Details
                $progress["total_failed"] = ($progress["total_failed"] ?? 0) + 1
                $progress["current_file"] = $null
                $progress["current_status"] = "idle"
            }
        }

        $progress["updated_at"] = $timestamp

        $progress | ConvertTo-Json -Depth 5 | Set-Content $ProgressFile -Force
    } catch {
        Write-Log "Failed to update progress: $($_.Exception.Message)" -Level "WARNING"
    }
}

function Get-ProgressSummary {
    if (Test-Path $ProgressFile) {
        try {
            $progress = Get-Content $ProgressFile -Raw | ConvertFrom-Json
            return $progress
        } catch {
            return $null
        }
    }
    return $null
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

    $LogDir = Split-Path -Path $SkippedFilesLog -Parent
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    $LogEntry | Add-Content -Path $SkippedFilesLog

    # Show correct reason in main log
    if ($Reason -like "*Low bitrate*") {
        Write-Log "SKIPPED ($Reason): $FilePath" -Level "SKIP"
    } else {
        Write-Log "SKIPPED (already $Codec): $FilePath" -Level "SKIP"
    }

    # Update progress tracking
    Update-Progress -Event "skipped" -FilePath $FilePath -Details "$Codec - $Reason"
}

function Test-AlreadyCompressed {
    param([string]$FilePath)

    try {
        $ffprobeArgs = @(
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_name,bit_rate",
            "-of", "json",
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

        $output = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()

        if ($process.ExitCode -ne 0 -or [string]::IsNullOrEmpty($output)) {
            return $null
        }

        $json = $output | ConvertFrom-Json
        $stream = $json.streams | Select-Object -First 1

        if (-not $stream) {
            return $null
        }

        $codec = $stream.codec_name.ToLower()
        $bitrateKbps = 0

        if ($stream.bit_rate) {
            $bitrateKbps = [math]::Round([int64]$stream.bit_rate / 1000, 0)
        } else {
            # Get bitrate from format if not in stream
            $ffprobeArgs2 = @(
                "-v", "error",
                "-show_entries", "format=bit_rate,duration",
                "-of", "json",
                "`"$FilePath`""
            ) -join ' '

            $psi2 = New-Object System.Diagnostics.ProcessStartInfo
            $psi2.FileName = $FFprobePath
            $psi2.Arguments = $ffprobeArgs2
            $psi2.UseShellExecute = $false
            $psi2.RedirectStandardOutput = $true
            $psi2.RedirectStandardError = $true
            $psi2.CreateNoWindow = $true

            $process2 = New-Object System.Diagnostics.Process
            $process2.StartInfo = $psi2
            $process2.Start() | Out-Null

            $output2 = $process2.StandardOutput.ReadToEnd()
            $process2.WaitForExit()

            if ($process2.ExitCode -eq 0 -and -not [string]::IsNullOrEmpty($output2)) {
                $json2 = $output2 | ConvertFrom-Json
                if ($json2.format.bit_rate) {
                    $bitrateKbps = [math]::Round([int64]$json2.format.bit_rate / 1000, 0)
                }
            }
        }

        return @{
            Codec = $codec
            BitrateKbps = $bitrateKbps
            BitrateMbps = [math]::Round($bitrateKbps / 1000, 1)
        }
    } catch {
        Write-Log "Error probing file: $($_.Exception.Message)" -Level "WARNING"
        return $null
    }
}

function Ensure-NfsMount {
    param(
        [string]$Server,
        [string]$Export,
        [string]$DriveLetter
    )

    $drivePath = "${DriveLetter}:\"

    try {
        # Check if already mounted and accessible
        if (Test-Path $drivePath -ErrorAction SilentlyContinue) {
            return $true
        }

        Write-Log "NFS mount $drivePath not accessible, mounting..." -Level "WARNING"

        # Unmount if exists but inaccessible
        $unmountResult = cmd /c "umount ${DriveLetter}:" 2>&1
        Start-Sleep -Milliseconds 500

        # Mount NFS share
        $mountCmd = "mount -o anon ${Server}:${Export} ${DriveLetter}:"
        $mountResult = cmd /c $mountCmd 2>&1

        Start-Sleep -Milliseconds 500

        if (Test-Path $drivePath -ErrorAction SilentlyContinue) {
            Write-Log "NFS mount established: ${Server}:${Export} -> ${DriveLetter}:" -Level "SUCCESS"
            return $true
        }

        Write-Log "NFS mount failed: $mountResult" -Level "ERROR"
        return $false
    } catch {
        Write-Log "NFS mount error: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Get-MediaType {
    param([string]$SourcePath)

    foreach ($folder in $WatchFolders) {
        if ($SourcePath -like "*\$folder\*") {
            if ($folder -eq "TV") {
                return "TV"
            }
        }
    }
    return "Movies"
}

function Get-NfsVideoFiles {
    $allFiles = @()

    foreach ($folder in $WatchFolders) {
        $watchPath = Join-Path $NfsBasePath $folder

        if (-not (Test-Path $watchPath)) {
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

function Process-VideoFile {
    param([System.IO.FileInfo]$SourceFile)

    $mediaType = Get-MediaType -SourcePath $SourceFile.FullName
    $sizeGB = [math]::Round($SourceFile.Length / 1GB, 2)
    $parentFolder = $SourceFile.Directory.Name
    $fileName = $SourceFile.Name

    # Check codec and bitrate
    $probeResult = Test-AlreadyCompressed -FilePath $SourceFile.FullName
    if (-not $probeResult) {
        Write-Log "Could not probe file, skipping: $fileName" -Level "WARNING"
        return $false
    }

    $codec = $probeResult.Codec
    $bitrateMbps = $probeResult.BitrateMbps

    # Skip already compressed codecs
    if ($codec -in $CompressedCodecs) {
        Write-SkippedFile -FilePath $SourceFile.FullName -Codec $codec -SizeGB $sizeGB -Reason "Already compressed"
        return $false
    }

    # Skip low bitrate H.264
    if ($codec -eq "h264" -and $probeResult.BitrateKbps -le $SkipBitrateKbps) {
        Write-SkippedFile -FilePath $SourceFile.FullName -Codec $codec -SizeGB $sizeGB -Reason "Low bitrate ($bitrateMbps Mbps)"
        return $false
    }

    Write-Log "========================================" -Level "SUCCESS"
    Write-Log "Processing [$mediaType]: $fileName ($sizeGB GB) [Source: $codec @ $bitrateMbps Mbps]" -Level "SUCCESS"
    Write-Log "Source: $($SourceFile.Directory.FullName)" -Level "INFO"
    Write-Log "========================================" -Level "SUCCESS"

    # Update progress: starting to process
    Update-Progress -Event "processing" -FilePath $SourceFile.FullName -Details "$codec @ $bitrateMbps Mbps"

    # Set up paths
    $localDownloadDir = Join-Path $LocalDownloadPath (Join-Path $mediaType $parentFolder)
    $localDownloadFile = Join-Path $localDownloadDir $fileName
    $localEncodedDir = Join-Path $LocalEncodedPath (Join-Path $mediaType $parentFolder)
    $localEncodedFile = Join-Path $localEncodedDir $fileName

    # Create directories
    if (-not (Test-Path $localDownloadDir)) {
        New-Item -ItemType Directory -Path $localDownloadDir -Force | Out-Null
    }
    if (-not (Test-Path $localEncodedDir)) {
        New-Item -ItemType Directory -Path $localEncodedDir -Force | Out-Null
    }

    # Download from NFS
    Write-Log "Downloading from NFS: $fileName ($sizeGB GB)"
    $downloadStart = Get-Date
    try {
        Copy-Item -Path $SourceFile.FullName -Destination $localDownloadFile -Force
    } catch {
        Write-Log "Download failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
    $downloadTime = (Get-Date) - $downloadStart
    $downloadSpeed = [math]::Round(($SourceFile.Length / 1MB) / $downloadTime.TotalSeconds, 1)
    Write-Log "Download complete: $downloadSpeed MB/s" -Level "SUCCESS"

    # Update progress: download complete, starting encode
    Update-Progress -Event "downloaded" -FilePath $SourceFile.FullName

    # Encode with FFmpeg AMD AMF AV1
    Write-Log "Encoding with AMD AMF AV1: $fileName"

    # Build FFmpeg argument string
    $ffmpegArgs = "-y -i `"$localDownloadFile`" -c:v av1_amf -quality quality -rc vbr_peak -b:v ${TargetBitrateMbps}M -maxrate 10M -map 0:v:0 -map 0:a? -map 0:s? -c:a copy -c:s copy `"$localEncodedFile`""

    # Use temp file for stderr to avoid buffer deadlock
    $stderrFile = Join-Path $env:TEMP "ffmpeg_stderr_$([guid]::NewGuid().ToString('N').Substring(0,8)).log"

    $encodeStart = Get-Date

    # Start process without waiting first so we can set priority
    $processResult = Start-Process -FilePath $FFmpegPath -ArgumentList $ffmpegArgs -PassThru -NoNewWindow -RedirectStandardError $stderrFile

    # Set high priority immediately
    try {
        Start-Sleep -Milliseconds 100  # Brief pause for process to initialize
        $processResult.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
        Write-Log "FFmpeg started with High priority (PID: $($processResult.Id))"
    } catch {
        Write-Log "FFmpeg started (PID: $($processResult.Id))"
    }

    # Now wait for process to complete
    $processResult.WaitForExit()
    $encodeTime = (Get-Date) - $encodeStart

    # Handle exit code - null means process may not have completed properly
    $exitCode = $processResult.ExitCode
    $encodingSuccess = $false

    # Check if output file exists and has content as backup verification
    $outputExists = (Test-Path $localEncodedFile) -and ((Get-Item $localEncodedFile -ErrorAction SilentlyContinue).Length -gt 1MB)

    if ($null -eq $exitCode) {
        # ExitCode is null - check if output file exists as backup verification
        if ($outputExists) {
            Write-Log "FFmpeg ExitCode was null but output file exists - treating as success" -Level "WARNING"
            $encodingSuccess = $true
        } else {
            Write-Log "Encoding failed: ExitCode was null and no valid output file" -Level "ERROR"
        }
    } elseif ($exitCode -ne 0) {
        Write-Log "Encoding failed with exit code: $exitCode" -Level "ERROR"
    } else {
        $encodingSuccess = $true
    }

    if (-not $encodingSuccess) {
        $stderr = if (Test-Path $stderrFile) { Get-Content $stderrFile -Tail 20 -Raw } else { "No stderr captured" }
        Write-Log "FFmpeg error: $stderr" -Level "ERROR"

        # Update progress: encoding failed
        Update-Progress -Event "failed" -FilePath $SourceFile.FullName -Details "Exit code: $exitCode"

        # Cleanup
        Remove-Item -Path $stderrFile -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $localDownloadFile -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $localEncodedFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    # Cleanup stderr temp file
    Remove-Item -Path $stderrFile -Force -ErrorAction SilentlyContinue

    $encodeMinutes = [math]::Round($encodeTime.TotalMinutes, 1)
    Write-Log "Encoding complete in $encodeMinutes min" -Level "SUCCESS"

    # Check encoded file size
    $encodedFile = Get-Item $localEncodedFile
    $encodedSizeGB = [math]::Round($encodedFile.Length / 1GB, 2)
    $reduction = [math]::Round((1 - ($encodedFile.Length / $SourceFile.Length)) * 100, 1)
    Write-Log "Size: ${sizeGB}GB -> ${encodedSizeGB}GB ($reduction% reduction)" -Level "SUCCESS"

    # Upload to NFS
    $destFolder = if ($mediaType -eq "TV") { $TVEncodedFolder } else { $MoviesEncodedFolder }
    $nfsDestDir = Join-Path $NfsBasePath (Join-Path $destFolder $parentFolder)
    $nfsDestFile = Join-Path $nfsDestDir $fileName

    if (-not (Test-Path $nfsDestDir)) {
        New-Item -ItemType Directory -Path $nfsDestDir -Force | Out-Null
        Write-Log "Created NFS directory: $nfsDestDir"
    }

    Write-Log "Uploading to NFS ($mediaType): $nfsDestFile"
    $uploadStart = Get-Date
    try {
        Copy-Item -Path $localEncodedFile -Destination $nfsDestFile -Force
    } catch {
        Write-Log "Upload failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
    $uploadTime = (Get-Date) - $uploadStart
    $uploadSpeed = [math]::Round(($encodedFile.Length / 1MB) / $uploadTime.TotalSeconds, 1)
    Write-Log "Upload complete: $uploadSpeed MB/s" -Level "SUCCESS"

    # Cleanup - delete original from NFS
    try {
        Remove-Item -Path $SourceFile.FullName -Force
        Write-Log "Deleted NFS original: $($SourceFile.FullName)" -Level "SUCCESS"
    } catch {
        Write-Log "Could not delete NFS original: $($_.Exception.Message)" -Level "WARNING"
    }

    # Cleanup local files
    Remove-Item -Path $localDownloadFile -Force -ErrorAction SilentlyContinue
    Write-Log "Deleted local download: $localDownloadFile"
    Remove-Item -Path $localEncodedFile -Force -ErrorAction SilentlyContinue
    Write-Log "Deleted local encoded: $localEncodedFile"

    Write-Log "Processing complete for: $fileName" -Level "SUCCESS"

    # Update progress: encoding successful
    Update-Progress -Event "encoded" -FilePath $SourceFile.FullName -Details "Reduced $sizeGB GB to $encodedSizeGB GB ($reduction%)"

    return $true
}

# ============================================================================
# MAIN LOOP
# ============================================================================

Write-Log "============================================" -Level "SUCCESS"
Write-Log "NFS Video Processing Monitor Started" -Level "SUCCESS"
Write-Log "SEQUENTIAL MODE" -Level "SUCCESS"
Write-Log "============================================" -Level "SUCCESS"
Write-Log "NFS Server: ${NfsServer}:${NfsExport}"
Write-Log "NFS Mount: $NfsBasePath"
Write-Log "Watch folders: $($WatchFolders -join ', ')"
Write-Log "Movies output: ${NfsBasePath}$MoviesEncodedFolder"
Write-Log "TV output: ${NfsBasePath}$TVEncodedFolder"
Write-Log "Local Download: $LocalDownloadPath"
Write-Log "Local Encoded: $LocalEncodedPath"
Write-Log "Encoder: FFmpeg AMD AMF AV1 ($TargetBitrateMbps Mbps target, 10 Mbps max)"
Write-Log "Min file size: $MinFileSizeMB MB"
Write-Log "Poll interval: $PollIntervalSeconds seconds"
Write-Log "Skip codecs: $($CompressedCodecs -join ', ') (already compressed)"
Write-Log "Skip bitrate: <= $([math]::Round($SkipBitrateKbps/1000, 1)) Mbps (already efficient)"
Write-Log ""
Write-Log "Workflow: Download -> Encode -> Upload -> Cleanup"

# Create local directories
foreach ($dir in @($LocalDownloadPath, $LocalEncodedPath)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Log "Created directory: $dir"
    }
}

# Mount NFS share
if (-not (Ensure-NfsMount -Server $NfsServer -Export $NfsExport -DriveLetter $NfsDriveLetter)) {
    Write-Log "FATAL: Could not mount NFS share ${NfsServer}:${NfsExport}" -Level "ERROR"
    exit 1
}

Write-Log "Monitoring NFS for video files..."

while ($true) {
    # Re-establish SMB session if needed
    try {
        $nfsAccessible = Test-Path $NfsBasePath -ErrorAction Stop
    } catch {
        $nfsAccessible = $false
    }

    if (-not $nfsAccessible) {
        Write-Log "NFS mount not accessible, remounting..." -Level "WARNING"
        if (-not (Ensure-NfsMount -Server $NfsServer -Export $NfsExport -DriveLetter $NfsDriveLetter)) {
            Start-Sleep -Seconds $PollIntervalSeconds
            continue
        }
    }

    # Get all video files
    $allVideoFiles = Get-NfsVideoFiles

    if ($allVideoFiles.Count -eq 0) {
        Write-Log "No video files found, waiting..."
        Start-Sleep -Seconds $PollIntervalSeconds
        continue
    }

    # Process files sequentially
    foreach ($file in $allVideoFiles) {
        $filePath = $file.FullName

        # Skip already processed files
        if ($script:ProcessedFiles.ContainsKey($filePath)) {
            continue
        }

        # Mark as processed (even if we skip it)
        $script:ProcessedFiles[$filePath] = $true

        # Process the file
        $result = Process-VideoFile -SourceFile $file

        # Re-check SMB connection after each file
        try {
            $nfsAccessible = Test-Path $NfsBasePath -ErrorAction Stop
        } catch {
            $nfsAccessible = $false
        }

        if (-not $nfsAccessible) {
            Write-Log "NFS connection lost after processing, remounting..." -Level "WARNING"
            Ensure-NfsMount -Server $NfsServer -Export $NfsExport -DriveLetter $NfsDriveLetter
        }
    }

    # Wait before next poll
    Write-Log "Scan complete. Waiting $PollIntervalSeconds seconds..."
    Start-Sleep -Seconds $PollIntervalSeconds
}
