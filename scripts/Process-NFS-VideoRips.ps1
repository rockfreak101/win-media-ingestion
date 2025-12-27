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

param(
    # NFS/SMB share path
    [string]$NfsSharePath = "\\10.0.0.1\media",
    [string]$NfsUser = "jluczani",
    [string]$NfsPassword = "password",

    # Watch folders (relative to share)
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

    # Minimum file size (skip small files like samples)
    [int]$MinFileSizeMB = 500,

    # Target encoding bitrate in Mbps
    [int]$TargetBitrateMbps = 6,

    # Bitrate threshold multiplier - skip if source <= target * multiplier
    [double]$BitrateThresholdMultiplier = 1.3
)

$LogFile = "C:\Scripts\Logs\nfs-video-processing.log"
$SkippedFilesLog = "C:\Scripts\Logs\nfs-skipped-already-compressed.log"

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
    Write-Log "SKIPPED (already $Codec): $FilePath" -Level "SKIP"
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

function Ensure-SmbSession {
    param(
        [string]$Path,
        [string]$User,
        [string]$Password
    )

    try {
        $testResult = $null
        try {
            $testResult = Test-Path $Path -ErrorAction Stop
        } catch {
            $testResult = $false
        }

        if ($testResult) {
            return $true
        }

        Write-Log "SMB path $Path not accessible, reconnecting..." -Level "WARNING"

        net use $Path /delete /y 2>$null | Out-Null
        Start-Sleep -Milliseconds 500

        $netResult = net use $Path /user:$User $Password /persistent:no 2>&1

        Start-Sleep -Milliseconds 500
        try {
            $connected = Test-Path $Path -ErrorAction Stop
            if ($connected) {
                Write-Log "SMB session established for $Path" -Level "SUCCESS"
                return $true
            }
        } catch {
            Write-Log "SMB test failed after connect: $($_.Exception.Message)" -Level "WARNING"
        }

        Write-Log "Could not access $Path - net use result: $netResult" -Level "ERROR"
        return $false
    } catch {
        Write-Log "SMB session failed: $($_.Exception.Message)" -Level "ERROR"
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
        $watchPath = Join-Path $NfsSharePath $folder

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

    if ($processResult.ExitCode -ne 0) {
        $stderr = if (Test-Path $stderrFile) { Get-Content $stderrFile -Tail 20 -Raw } else { "No stderr captured" }
        Write-Log "Encoding failed with exit code: $($processResult.ExitCode)" -Level "ERROR"
        Write-Log "FFmpeg error: $stderr" -Level "ERROR"

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
    $nfsDestDir = Join-Path $NfsSharePath (Join-Path $destFolder $parentFolder)
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
    return $true
}

# ============================================================================
# MAIN LOOP
# ============================================================================

Write-Log "============================================" -Level "SUCCESS"
Write-Log "NFS Video Processing Monitor Started" -Level "SUCCESS"
Write-Log "SEQUENTIAL MODE" -Level "SUCCESS"
Write-Log "============================================" -Level "SUCCESS"
Write-Log "NFS Base: $NfsSharePath"
Write-Log "Watch folders: $($WatchFolders -join ', ')"
Write-Log "Movies output: $NfsSharePath\$MoviesEncodedFolder"
Write-Log "TV output: $NfsSharePath\$TVEncodedFolder"
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

# Establish SMB session
if (-not (Ensure-SmbSession -Path $NfsSharePath -User $NfsUser -Password $NfsPassword)) {
    Write-Log "FATAL: Could not establish SMB session to $NfsSharePath" -Level "ERROR"
    exit 1
}

Write-Log "Monitoring NFS for video files..."

while ($true) {
    # Re-establish SMB session if needed
    try {
        $nfsAccessible = Test-Path $NfsSharePath -ErrorAction Stop
    } catch {
        $nfsAccessible = $false
    }

    if (-not $nfsAccessible) {
        Write-Log "NFS path not accessible, reconnecting..." -Level "WARNING"
        if (-not (Ensure-SmbSession -Path $NfsSharePath -User $NfsUser -Password $NfsPassword)) {
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
            $nfsAccessible = Test-Path $NfsSharePath -ErrorAction Stop
        } catch {
            $nfsAccessible = $false
        }

        if (-not $nfsAccessible) {
            Write-Log "NFS connection lost after processing, reconnecting..." -Level "WARNING"
            Ensure-SmbSession -Path $NfsSharePath -User $NfsUser -Password $NfsPassword
        }
    }

    # Wait before next poll
    Write-Log "Scan complete. Waiting $PollIntervalSeconds seconds..."
    Start-Sleep -Seconds $PollIntervalSeconds
}
