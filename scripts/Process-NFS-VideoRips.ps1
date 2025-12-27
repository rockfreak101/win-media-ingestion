# Process-NFS-VideoRips.ps1
# Watches NFS/SMB shares for video files, downloads to local, encodes, uploads back
#
# PARALLEL PROCESSING VERSION:
#   - Buffered downloads: Pre-downloads next files while encoding
#   - Parallel encoding: Runs multiple FFmpeg instances simultaneously
#
# Workflow:
#   1. Watch NFS shares (More_Movies, TV) for MKV/M2TS files
#   2. Check if file is already compressed (H.265/HEVC, AV1, VP9) - skip if so
#   3. Download files to local buffer (pre-download next files)
#   4. Encode in parallel with AMD AMF AV1 (multiple streams)
#   5. Upload encoded files to appropriate NFS destination
#   6. Delete original from NFS and both local copies
#
# 2025-12-23: Initial creation - NFS pull/encode/push workflow
# 2025-12-26: Added bitrate detection to skip already-efficient files
# 2025-12-27: Added buffered downloads and parallel encoding
# 2025-12-27: Improved SMB session handling for better connection reliability

param(
    # NFS/SMB share path - use UNC with explicit credential management
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
    [int]$PollIntervalSeconds = 30,
    [int]$FileReadyAgeSeconds = 30,
    [int]$FileSizeCheckWaitSeconds = 5,

    # Minimum file size (skip small files like samples)
    [int]$MinFileSizeMB = 500,

    # Target encoding bitrate in Mbps - skip files already at or below this
    [int]$TargetBitrateMbps = 6,

    # Bitrate threshold multiplier - skip if source <= target * multiplier
    [double]$BitrateThresholdMultiplier = 1.3,

    # PARALLEL PROCESSING SETTINGS
    # Number of files to buffer (pre-download while encoding)
    [int]$DownloadBufferSize = 3,

    # Number of parallel FFmpeg encoding jobs
    [int]$ParallelEncodes = 2
)

$LogFile = "C:\Scripts\Logs\nfs-video-processing.log"
$SkippedFilesLog = "C:\Scripts\Logs\nfs-skipped-already-compressed.log"

# Calculate skip threshold: skip files at or below this bitrate (in kbps)
$SkipBitrateKbps = $TargetBitrateMbps * 1000 * $BitrateThresholdMultiplier

# Codecs that are considered "already compressed" and should be skipped
$CompressedCodecs = @("hevc", "h265", "av1", "vp9")

# State tracking for parallel processing
$script:DownloadQueue = [System.Collections.Concurrent.ConcurrentQueue[PSObject]]::new()
$script:EncodeQueue = [System.Collections.Concurrent.ConcurrentQueue[PSObject]]::new()
$script:ActiveDownloads = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
$script:ActiveEncodes = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
$script:ProcessedFiles = [System.Collections.Concurrent.ConcurrentDictionary[string, bool]]::new()

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "$Timestamp [$Level] $Message"

    # Ensure log directory exists
    $LogDir = Split-Path -Path $LogFile -Parent
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    # Thread-safe logging
    $mutex = New-Object System.Threading.Mutex($false, "NfsVideoLogMutex")
    try {
        $mutex.WaitOne() | Out-Null
        $LogMessage | Add-Content -Path $LogFile
        Write-Host $LogMessage
    } finally {
        $mutex.ReleaseMutex()
    }
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

            if ($output2) {
                $json2 = $output2 | ConvertFrom-Json
                if ($json2.format.bit_rate) {
                    $bitrateKbps = [math]::Round([int64]$json2.format.bit_rate / 1000, 0)
                }
            }
        }

        $isCompressed = $CompressedCodecs -contains $codec
        $isLowBitrate = ($bitrateKbps -gt 0) -and ($bitrateKbps -le $SkipBitrateKbps)

        return @{
            IsCompressed = $isCompressed
            IsLowBitrate = $isLowBitrate
            Codec = $codec
            BitrateKbps = $bitrateKbps
        }
    } catch {
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
        # First check if already accessible
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

        # Remove any existing session
        net use $Path /delete /y 2>$null | Out-Null
        Start-Sleep -Milliseconds 500

        # Create new session with explicit credentials
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

function Test-FileReady {
    param([System.IO.FileInfo]$File)

    $FileAge = (Get-Date) - $File.LastWriteTime
    if ($FileAge.TotalSeconds -lt $FileReadyAgeSeconds) {
        return $false
    }

    try {
        $stream = [System.IO.File]::Open($File.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $stream.Close()
        $stream.Dispose()
    } catch {
        return $false
    }

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

function Get-LocalDownloadPath {
    param([System.IO.FileInfo]$SourceFile)

    $mediaType = Get-MediaType -SourcePath $SourceFile.FullName
    $fileName = $SourceFile.Name
    $parentFolder = $SourceFile.Directory.Name

    if ($parentFolder -in $WatchFolders) {
        return Join-Path $LocalDownloadPath (Join-Path $mediaType $fileName)
    } else {
        return Join-Path $LocalDownloadPath (Join-Path $mediaType (Join-Path $parentFolder $fileName))
    }
}

function Start-BackgroundDownload {
    param([System.IO.FileInfo]$SourceFile)

    $localPath = Get-LocalDownloadPath -SourceFile $SourceFile
    $localDir = Split-Path -Path $localPath -Parent

    # Create directory if needed
    if (-not (Test-Path $localDir)) {
        New-Item -ItemType Directory -Path $localDir -Force | Out-Null
    }

    # Start download as background job
    $job = Start-Job -ScriptBlock {
        param($source, $dest)
        $startTime = Get-Date
        Copy-Item -Path $source -Destination $dest -Force
        $duration = (Get-Date) - $startTime
        $size = (Get-Item $dest).Length
        $speedMBps = [math]::Round(($size / 1MB) / $duration.TotalSeconds, 1)
        return @{
            Success = $true
            LocalPath = $dest
            SpeedMBps = $speedMBps
            SizeGB = [math]::Round($size / 1GB, 2)
        }
    } -ArgumentList $SourceFile.FullName, $localPath

    return @{
        Job = $job
        SourceFile = $SourceFile
        LocalPath = $localPath
        StartTime = Get-Date
    }
}

function Start-BackgroundEncode {
    param(
        [string]$InputFile,
        [string]$OutputFile,
        [string]$OriginalNfsPath
    )

    # Ensure output directory exists
    $outputDir = Split-Path -Path $OutputFile -Parent
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    $ffmpegPath = $FFmpegPath

    $job = Start-Job -ScriptBlock {
        param($ffmpeg, $input, $output)

        $Arguments = @(
            "-hide_banner",
            "-y",
            "-i", "`"$input`"",
            "-map", "0:v:0",
            "-map", "0:a?",
            "-map", "0:s?",
            "-c:v", "av1_amf",
            "-quality", "balanced",
            "-rc", "vbr_peak",
            "-b:v", "6M",
            "-maxrate", "10M",
            "-bufsize", "20M",
            "-usage", "transcoding",
            "-pix_fmt", "yuv420p",
            "-c:a", "copy",
            "-c:s", "copy",
            "`"$output`""
        ) -join ' '

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ffmpeg
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        $startTime = Get-Date
        $process.Start() | Out-Null

        try {
            $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
        } catch { }

        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $duration = (Get-Date) - $startTime

        $inputSize = (Get-Item $input).Length / 1GB
        $outputSize = if (Test-Path $output) { (Get-Item $output).Length / 1GB } else { 0 }

        return @{
            Success = ($process.ExitCode -eq 0)
            ExitCode = $process.ExitCode
            DurationMin = [math]::Round($duration.TotalMinutes, 1)
            InputSizeGB = [math]::Round($inputSize, 2)
            OutputSizeGB = [math]::Round($outputSize, 2)
            Reduction = if ($inputSize -gt 0) { [math]::Round((($inputSize - $outputSize) / $inputSize) * 100, 1) } else { 0 }
            Stderr = $stderr
            OutputFile = $output
        }
    } -ArgumentList $ffmpegPath, $InputFile, $OutputFile

    return @{
        Job = $job
        InputFile = $InputFile
        OutputFile = $OutputFile
        OriginalNfsPath = $OriginalNfsPath
        StartTime = Get-Date
    }
}

function Complete-Upload {
    param(
        [string]$LocalEncodedFile,
        [string]$OriginalNfsFile
    )

    $mediaType = Get-MediaType -SourcePath $OriginalNfsFile

    if ($mediaType -eq "TV") {
        $destBase = Join-Path $NfsSharePath $TVEncodedFolder
    } else {
        $destBase = Join-Path $NfsSharePath $MoviesEncodedFolder
    }

    $fileName = Split-Path $LocalEncodedFile -Leaf
    $parentFolder = Split-Path (Split-Path $LocalEncodedFile -Parent) -Leaf

    if ($parentFolder -in @("Movies", "TV")) {
        $NfsDestFile = Join-Path $destBase $fileName
    } else {
        $NfsDestFile = Join-Path $destBase (Join-Path $parentFolder $fileName)
    }

    $NfsDestDir = Split-Path -Path $NfsDestFile -Parent

    if (-not (Test-Path $NfsDestDir)) {
        New-Item -ItemType Directory -Path $NfsDestDir -Force | Out-Null
        Write-Log "Created NFS directory: $NfsDestDir"
    }

    Write-Log "Uploading to NFS ($mediaType): $NfsDestFile"

    try {
        $FileSize = (Get-Item $LocalEncodedFile).Length
        $startTime = Get-Date
        Copy-Item -Path $LocalEncodedFile -Destination $NfsDestFile -Force
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

    try {
        Remove-Item -Path $NfsOriginal -Force -ErrorAction Stop
        Write-Log "Deleted NFS original: $NfsOriginal" -Level "SUCCESS"
    } catch {
        Write-Log "Could not delete NFS original: $($_.Exception.Message)" -Level "WARNING"
    }

    try {
        if (Test-Path $LocalDownload) {
            Remove-Item -Path $LocalDownload -Force
            Write-Log "Deleted local download: $LocalDownload"
        }
    } catch { }

    try {
        if (Test-Path $LocalEncoded) {
            Remove-Item -Path $LocalEncoded -Force
            Write-Log "Deleted local encoded: $LocalEncoded"
        }
    } catch { }

    # Cleanup empty directories
    foreach ($path in @($LocalDownload, $LocalEncoded)) {
        if ($path) {
            $parentDir = Split-Path -Path $path -Parent
            try {
                if ((Test-Path $parentDir) -and ((Get-ChildItem -Path $parentDir -Force -ErrorAction SilentlyContinue).Count -eq 0)) {
                    Remove-Item -Path $parentDir -Force -Recurse -ErrorAction SilentlyContinue
                }
            } catch { }
        }
    }
}

# ============================================================================
# MAIN LOOP - PARALLEL PROCESSING
# ============================================================================

Write-Log "============================================" -Level "SUCCESS"
Write-Log "NFS Video Processing Monitor Started" -Level "SUCCESS"
Write-Log "PARALLEL MODE: $ParallelEncodes concurrent encodes, $DownloadBufferSize file buffer" -Level "SUCCESS"
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
Write-Log "Workflow: Buffer downloads -> Parallel encode -> Upload -> Cleanup"

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

# Track active jobs
$activeDownloads = @{}
$activeEncodes = @{}
$downloadedQueue = [System.Collections.Queue]::new()

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

    # Filter to files not already processed or in progress
    $availableFiles = $allVideoFiles | Where-Object {
        $filePath = $_.FullName
        -not $script:ProcessedFiles.ContainsKey($filePath) -and
        -not $activeDownloads.ContainsKey($filePath) -and
        -not ($downloadedQueue.ToArray() | Where-Object { $_.OriginalNfsPath -eq $filePath }) -and
        -not $activeEncodes.ContainsKey($filePath)
    }

    # =========================================================================
    # STEP 1: Check completed downloads
    # =========================================================================
    $completedDownloads = @()
    foreach ($key in @($activeDownloads.Keys)) {
        $dl = $activeDownloads[$key]
        if ($dl.Job.State -eq 'Completed') {
            $result = Receive-Job -Job $dl.Job
            Remove-Job -Job $dl.Job -Force

            if ($result.Success) {
                Write-Log "Download complete: $($dl.SourceFile.Name) ($($result.SizeGB) GB @ $($result.SpeedMBps) MB/s)" -Level "SUCCESS"
                $downloadedQueue.Enqueue(@{
                    LocalPath = $result.LocalPath
                    OriginalNfsPath = $dl.SourceFile.FullName
                    SourceFile = $dl.SourceFile
                })
            } else {
                Write-Log "Download failed: $($dl.SourceFile.Name)" -Level "ERROR"
                $script:ProcessedFiles[$dl.SourceFile.FullName] = $true  # Mark as processed to skip
            }
            $completedDownloads += $key
        } elseif ($dl.Job.State -eq 'Failed') {
            Write-Log "Download job failed: $($dl.SourceFile.Name)" -Level "ERROR"
            Remove-Job -Job $dl.Job -Force
            $script:ProcessedFiles[$dl.SourceFile.FullName] = $true
            $completedDownloads += $key
        }
    }
    foreach ($key in $completedDownloads) {
        $activeDownloads.Remove($key)
    }

    # =========================================================================
    # STEP 2: Check completed encodes
    # =========================================================================
    $completedEncodes = @()
    foreach ($key in @($activeEncodes.Keys)) {
        $enc = $activeEncodes[$key]
        if ($enc.Job.State -eq 'Completed') {
            $result = Receive-Job -Job $enc.Job
            Remove-Job -Job $enc.Job -Force

            $fileName = Split-Path $enc.InputFile -Leaf

            if ($result.Success) {
                Write-Log "Encoding complete: $fileName in $($result.DurationMin) min" -Level "SUCCESS"
                Write-Log "Size: $($result.InputSizeGB)GB -> $($result.OutputSizeGB)GB ($($result.Reduction)% reduction)" -Level "SUCCESS"

                # Upload to NFS
                $nfsResult = Complete-Upload -LocalEncodedFile $result.OutputFile -OriginalNfsFile $enc.OriginalNfsPath

                if ($nfsResult) {
                    # Cleanup all files
                    Remove-ProcessedFiles -NfsOriginal $enc.OriginalNfsPath -LocalDownload $enc.InputFile -LocalEncoded $result.OutputFile
                    Write-Log "Processing complete: $fileName" -Level "SUCCESS"
                } else {
                    Write-Log "Upload failed, keeping files: $fileName" -Level "ERROR"
                }
            } else {
                Write-Log "Encoding failed: $fileName (exit code: $($result.ExitCode))" -Level "ERROR"
                # Cleanup local download only
                Remove-Item -Path $enc.InputFile -Force -ErrorAction SilentlyContinue
            }

            $script:ProcessedFiles[$enc.OriginalNfsPath] = $true
            $completedEncodes += $key
        } elseif ($enc.Job.State -eq 'Failed') {
            Write-Log "Encode job failed: $(Split-Path $enc.InputFile -Leaf)" -Level "ERROR"
            Remove-Job -Job $enc.Job -Force
            Remove-Item -Path $enc.InputFile -Force -ErrorAction SilentlyContinue
            $script:ProcessedFiles[$enc.OriginalNfsPath] = $true
            $completedEncodes += $key
        }
    }
    foreach ($key in $completedEncodes) {
        $activeEncodes.Remove($key)
    }

    # =========================================================================
    # STEP 3: Start new encodes from downloaded queue
    # =========================================================================
    while ($activeEncodes.Count -lt $ParallelEncodes -and $downloadedQueue.Count -gt 0) {
        $item = $downloadedQueue.Dequeue()

        # Determine output path
        $relativePath = $item.LocalPath.Substring($LocalDownloadPath.Length).TrimStart('\')
        $localEncodedFile = Join-Path $LocalEncodedPath $relativePath

        $fileName = Split-Path $item.LocalPath -Leaf
        Write-Log "Starting encode [$($activeEncodes.Count + 1)/$ParallelEncodes]: $fileName" -Level "INFO"

        $encodeJob = Start-BackgroundEncode -InputFile $item.LocalPath -OutputFile $localEncodedFile -OriginalNfsPath $item.OriginalNfsPath
        $activeEncodes[$item.OriginalNfsPath] = $encodeJob
    }

    # =========================================================================
    # STEP 4: Start new downloads to fill buffer
    # =========================================================================
    $totalBuffered = $activeDownloads.Count + $downloadedQueue.Count
    $neededDownloads = $DownloadBufferSize - $totalBuffered

    if ($neededDownloads -gt 0 -and $availableFiles.Count -gt 0) {
        $filesToDownload = $availableFiles | Select-Object -First $neededDownloads

        foreach ($file in $filesToDownload) {
            # Check if file is ready and should be encoded
            if (-not (Test-FileReady -File $file)) {
                continue
            }

            $fileSizeGB = $file.Length / 1GB

            # Check codec/bitrate
            $codecCheck = Test-AlreadyCompressed -FilePath $file.FullName
            if ($codecCheck) {
                if ($codecCheck.IsCompressed) {
                    Write-SkippedFile -FilePath $file.FullName -Codec $codecCheck.Codec -SizeGB $fileSizeGB -Reason "Already compressed"
                    $script:ProcessedFiles[$file.FullName] = $true
                    continue
                }
                if ($codecCheck.IsLowBitrate) {
                    $bitrateMbps = [math]::Round($codecCheck.BitrateKbps / 1000, 1)
                    Write-SkippedFile -FilePath $file.FullName -Codec $codecCheck.Codec -SizeGB $fileSizeGB -Reason "Low bitrate ($bitrateMbps Mbps)"
                    $script:ProcessedFiles[$file.FullName] = $true
                    continue
                }
            }

            $bitrateInfo = if ($codecCheck -and $codecCheck.BitrateKbps -gt 0) { " @ $([math]::Round($codecCheck.BitrateKbps/1000, 1)) Mbps" } else { "" }
            $mediaType = Get-MediaType -SourcePath $file.FullName

            Write-Log "Queuing download [$mediaType]: $($file.Name) ($([math]::Round($fileSizeGB, 2)) GB)$bitrateInfo" -Level "INFO"

            $downloadJob = Start-BackgroundDownload -SourceFile $file
            $activeDownloads[$file.FullName] = $downloadJob
        }
    }

    # =========================================================================
    # STEP 5: Status update
    # =========================================================================
    if ($activeDownloads.Count -gt 0 -or $activeEncodes.Count -gt 0 -or $downloadedQueue.Count -gt 0) {
        $status = "Active: $($activeEncodes.Count) encoding, $($activeDownloads.Count) downloading, $($downloadedQueue.Count) queued"
        # Only log status every few cycles to reduce noise
    }

    Start-Sleep -Seconds $PollIntervalSeconds
}
