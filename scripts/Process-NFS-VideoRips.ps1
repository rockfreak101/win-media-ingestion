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
# 2025-12-28: Added single instance mode (mutex) and queue tracking to prevent duplicates

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

# ============================================================================
# SINGLE INSTANCE MODE - Prevent multiple instances from running
# ============================================================================
$MutexName = "Global\NFS-VideoRips-Encoder"
$script:Mutex = $null
$script:MutexOwned = $false

try {
    $script:Mutex = New-Object System.Threading.Mutex($false, $MutexName)

    # Try to acquire mutex with 0 timeout (don't wait)
    $script:MutexOwned = $script:Mutex.WaitOne(0)

    if (-not $script:MutexOwned) {
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [ERROR] Another instance is already running. Exiting."
        exit 1
    }
} catch [System.Threading.AbandonedMutexException] {
    # Previous instance crashed, we now own the mutex
    $script:MutexOwned = $true
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WARNING] Acquired abandoned mutex from crashed instance."
} catch {
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [ERROR] Failed to create mutex: $($_.Exception.Message)"
    exit 1
}

# Cleanup mutex on script exit
$exitHandler = {
    if ($script:MutexOwned -and $script:Mutex) {
        try {
            $script:Mutex.ReleaseMutex()
            $script:Mutex.Dispose()
        } catch { }
    }
}
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $exitHandler | Out-Null

# ============================================================================
# FILE PATHS AND QUEUE TRACKING
# ============================================================================
$LogFile = "C:\Scripts\Logs\nfs-video-processing.log"
$SkippedFilesLog = "C:\Scripts\Logs\nfs-skipped-already-compressed.log"
$ProgressFile = "C:\Scripts\Logs\nfs-encoding-progress.json"
$QueueFile = "C:\Scripts\Logs\nfs-encoding-queue.json"

# NFS mount base path (the mounted drive letter)
$NfsBasePath = "${NfsDriveLetter}:\"

# Calculate skip threshold: skip files at or below this bitrate (in kbps)
$SkipBitrateKbps = $TargetBitrateMbps * 1000 * $BitrateThresholdMultiplier

# Codecs that are considered "already compressed" and should be skipped
$CompressedCodecs = @("hevc", "h265", "av1", "vp9")

# Anime folder patterns - these get special audio/subtitle handling
$AnimeFolderPatterns = @(
    "*Dragon_Ball*",
    "*Made_in_Abyss*",
    "*One-Punch_Man*",
    "*Attack_on_Titan*",
    "*Naruto*",
    "*Bleach*",
    "*Death_Note*",
    "*Fullmetal*",
    "*My_Hero_Academia*",
    "*Demon_Slayer*",
    "*Jujutsu*",
    "*Chainsaw*",
    "*Spy_x_Family*",
    "*Anime*",
    # Release group patterns - brackets escaped for literal matching
    "*``[Sokudo``]*",
    "*``[SubsPlease``]*",
    "*``[Erai-raws``]*",
    "*``[HorribleSubs``]*",
    "*``[CR``]*",
    "*``[Judas``]*"
)

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

# ============================================================================
# QUEUE TRACKING - Prevent duplicate file processing
# ============================================================================
# Queue states: "queued", "downloading", "encoding", "uploading", "completed", "failed"

function Get-Queue {
    if (-not (Test-Path $QueueFile)) {
        return @{}
    }
    try {
        $jsonObj = Get-Content $QueueFile -Raw -ErrorAction Stop | ConvertFrom-Json
        $queue = @{}
        if ($jsonObj) {
            $jsonObj.PSObject.Properties | ForEach-Object {
                $queue[$_.Name] = $_.Value
            }
        }
        return $queue
    } catch {
        return @{}
    }
}

function Save-Queue {
    param([hashtable]$Queue)
    try {
        $Queue | ConvertTo-Json -Depth 5 | Set-Content $QueueFile -Force
    } catch {
        Write-Log "Failed to save queue: $($_.Exception.Message)" -Level "WARNING"
    }
}

function Add-ToQueue {
    param(
        [string]$FilePath,
        [string]$Status = "queued"
    )
    $queue = Get-Queue
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Check if already in queue
    if ($queue.ContainsKey($FilePath)) {
        $existing = $queue[$FilePath]
        # If completed or failed more than 1 hour ago, allow re-processing
        if ($existing.status -in @("completed", "failed")) {
            $existingTime = [DateTime]::ParseExact($existing.updated_at, "yyyy-MM-dd HH:mm:ss", $null)
            if ((Get-Date) - $existingTime -lt [TimeSpan]::FromHours(1)) {
                return $false  # Recently processed, skip
            }
        } elseif ($existing.status -in @("queued", "downloading", "encoding", "uploading")) {
            # Check if stale (more than 4 hours old - possible crash)
            $existingTime = [DateTime]::ParseExact($existing.updated_at, "yyyy-MM-dd HH:mm:ss", $null)
            if ((Get-Date) - $existingTime -lt [TimeSpan]::FromHours(4)) {
                return $false  # Still being processed (or recently queued)
            }
            Write-Log "Stale queue entry found for $FilePath (last update: $($existing.updated_at)), re-processing" -Level "WARNING"
        }
    }

    $queue[$FilePath] = @{
        status = $Status
        added_at = $timestamp
        updated_at = $timestamp
    }
    Save-Queue -Queue $queue
    return $true
}

function Update-QueueStatus {
    param(
        [string]$FilePath,
        [string]$Status,
        [string]$Details = ""
    )
    $queue = Get-Queue
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    if ($queue.ContainsKey($FilePath)) {
        # Convert PSCustomObject to hashtable if needed
        $entry = $queue[$FilePath]
        if ($entry -is [PSCustomObject]) {
            $newEntry = @{}
            $entry.PSObject.Properties | ForEach-Object { $newEntry[$_.Name] = $_.Value }
            $entry = $newEntry
        }
        $entry["status"] = $Status
        $entry["updated_at"] = $timestamp
        if ($Details) {
            $entry["details"] = $Details
        }
        $queue[$FilePath] = $entry
    } else {
        $queue[$FilePath] = @{
            status = $Status
            added_at = $timestamp
            updated_at = $timestamp
            details = $Details
        }
    }
    Save-Queue -Queue $queue
}

function Remove-FromQueue {
    param([string]$FilePath)
    $queue = Get-Queue
    if ($queue.ContainsKey($FilePath)) {
        $queue.Remove($FilePath)
        Save-Queue -Queue $queue
    }
}

function Test-InQueue {
    param([string]$FilePath)
    $queue = Get-Queue

    if (-not $queue.ContainsKey($FilePath)) {
        return $false
    }

    $entry = $queue[$FilePath]
    $status = if ($entry -is [PSCustomObject]) { $entry.status } else { $entry["status"] }

    # If completed or failed, check if we should allow re-processing
    if ($status -in @("completed", "failed")) {
        $updatedAt = if ($entry -is [PSCustomObject]) { $entry.updated_at } else { $entry["updated_at"] }
        $existingTime = [DateTime]::ParseExact($updatedAt, "yyyy-MM-dd HH:mm:ss", $null)
        if ((Get-Date) - $existingTime -gt [TimeSpan]::FromHours(1)) {
            return $false  # Old entry, allow re-processing
        }
    }

    # If actively processing, check for stale entries
    if ($status -in @("queued", "downloading", "encoding", "uploading")) {
        $updatedAt = if ($entry -is [PSCustomObject]) { $entry.updated_at } else { $entry["updated_at"] }
        $existingTime = [DateTime]::ParseExact($updatedAt, "yyyy-MM-dd HH:mm:ss", $null)
        if ((Get-Date) - $existingTime -gt [TimeSpan]::FromHours(4)) {
            return $false  # Stale entry (crashed process), allow re-processing
        }
    }

    return $true
}

function Clean-StaleQueueEntries {
    $queue = Get-Queue
    $cleaned = 0
    $staleFiles = @()

    foreach ($key in @($queue.Keys)) {
        $entry = $queue[$key]
        $status = if ($entry -is [PSCustomObject]) { $entry.status } else { $entry["status"] }
        $updatedAt = if ($entry -is [PSCustomObject]) { $entry.updated_at } else { $entry["updated_at"] }

        try {
            $existingTime = [DateTime]::ParseExact($updatedAt, "yyyy-MM-dd HH:mm:ss", $null)
            $ageHours = ((Get-Date) - $existingTime).TotalHours

            # Remove completed/failed entries older than 24 hours
            if ($status -in @("completed", "failed") -and $ageHours -gt 24) {
                $queue.Remove($key)
                $cleaned++
            }
            # Remove stale "encoding" entries older than 2 hours (likely crashed)
            elseif ($status -eq "encoding" -and $ageHours -gt 2) {
                $queue.Remove($key)
                $staleFiles += $key
                $cleaned++
                Write-Log "Removed stale encoding entry ($([math]::Round($ageHours, 1))h old): $key" -Level "WARNING"
            }
            # Remove stale processing entries older than 4 hours
            elseif ($status -in @("queued", "downloading", "uploading") -and $ageHours -gt 4) {
                $queue.Remove($key)
                $cleaned++
            }
        } catch {
            # Invalid timestamp, remove entry
            $queue.Remove($key)
            $cleaned++
        }
    }

    # Also clear stale files from in-memory cache so they can be re-processed
    foreach ($file in $staleFiles) {
        if ($script:ProcessedFiles.ContainsKey($file)) {
            $script:ProcessedFiles.Remove($file)
            Write-Log "Cleared in-memory cache for stale file: $file" -Level "INFO"
        }
    }

    if ($cleaned -gt 0) {
        Save-Queue -Queue $queue
        Write-Log "Cleaned $cleaned stale queue entries" -Level "INFO"
    }
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
            # ConvertFrom-Json returns PSCustomObject, convert to hashtable manually (PS 5.1 compatible)
            $jsonObj = Get-Content $ProgressFile -Raw | ConvertFrom-Json
            if ($jsonObj) {
                $jsonObj.PSObject.Properties | ForEach-Object {
                    $progress[$_.Name] = $_.Value
                }
            }
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
                $progress["total_encoded"] = $(if ($null -eq $progress["total_encoded"]) { 0 } else { $progress["total_encoded"] }) + 1
            }
            "skipped" {
                $progress["last_skipped"] = $FilePath
                $progress["last_skipped_at"] = $timestamp
                $progress["last_skipped_reason"] = $Details
                $progress["total_skipped"] = $(if ($null -eq $progress["total_skipped"]) { 0 } else { $progress["total_skipped"] }) + 1
            }
            "failed" {
                $progress["last_failed"] = $FilePath
                $progress["last_failed_at"] = $timestamp
                $progress["last_failed_reason"] = $Details
                $progress["total_failed"] = $(if ($null -eq $progress["total_failed"]) { 0 } else { $progress["total_failed"] }) + 1
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

function Test-IsAnime {
    param([string]$FilePath)

    foreach ($pattern in $AnimeFolderPatterns) {
        if ($FilePath -like $pattern) {
            return $true
        }
    }
    return $false
}

function Get-StreamInfo {
    param([string]$FilePath)

    try {
        $ffprobeArgs = @(
            "-v", "error",
            "-show_entries", "stream=index,codec_type,codec_name:stream_tags=language,title",
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
        return $json.streams
    } catch {
        return $null
    }
}

function Get-AnimeFFmpegMaps {
    param([string]$FilePath)

    # For anime: Keep first audio (original), English audio, and English subtitles
    $streams = Get-StreamInfo -FilePath $FilePath
    if (-not $streams) {
        # Fallback: keep first audio, try to add English, and all subtitles
        return "-map 0:v:0 -map 0:a:0 -map 0:a:m:language:eng? -map 0:s?"
    }

    $maps = @("-map 0:v:0")
    $firstAudioIndex = $null
    $englishAudioIndices = @()

    # Find audio streams
    $audioStreams = $streams | Where-Object { $_.codec_type -eq "audio" }
    foreach ($stream in $audioStreams) {
        $lang = $stream.tags.language
        $title = $stream.tags.title

        # Track first audio stream (original/default)
        if ($null -eq $firstAudioIndex) {
            $firstAudioIndex = $stream.index
        }

        # Track English audio streams
        if ($lang -in @("eng", "en") -or $title -like "*English*" -or $title -like "*Dub*") {
            $englishAudioIndices += $stream.index
        }
    }

    # Always include first audio track (original)
    if ($null -ne $firstAudioIndex) {
        $maps += "-map 0:$firstAudioIndex"
    }

    # Add English audio if different from first track
    foreach ($engIdx in $englishAudioIndices) {
        if ($engIdx -ne $firstAudioIndex) {
            $maps += "-map 0:$engIdx"
        }
    }

    $audioMapped = ($null -ne $firstAudioIndex)
    $subMapped = $false

    # If no specific audio found, keep first audio
    if (-not $audioMapped -and $audioStreams) {
        $maps += "-map 0:a:0"
    }

    # Find subtitle streams
    $subStreams = $streams | Where-Object { $_.codec_type -eq "subtitle" }
    foreach ($stream in $subStreams) {
        $lang = $stream.tags.language
        $title = $stream.tags.title

        # Keep English subtitles
        if ($lang -in @("eng", "en") -or $title -like "*English*") {
            $maps += "-map 0:$($stream.index)"
            $subMapped = $true
        }
        # Also keep "signs" or "songs" tracks (common in anime)
        elseif ($title -like "*Sign*" -or $title -like "*Song*" -or $title -like "*Full*") {
            $maps += "-map 0:$($stream.index)"
            $subMapped = $true
        }
    }

    # If no specific subs found but subs exist, keep all subs
    if (-not $subMapped -and $subStreams) {
        $maps += "-map 0:s?"
    }

    return $maps -join " "
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

    # Update progress and queue: starting to process
    Update-Progress -Event "processing" -FilePath $SourceFile.FullName -Details "$codec @ $bitrateMbps Mbps"
    Update-QueueStatus -FilePath $SourceFile.FullName -Status "downloading" -Details "$codec @ $bitrateMbps Mbps"

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

    # Update progress and queue: download complete, starting encode
    Update-Progress -Event "downloaded" -FilePath $SourceFile.FullName
    Update-QueueStatus -FilePath $SourceFile.FullName -Status "encoding"

    # Check if this is anime content for special audio/subtitle handling
    $isAnime = Test-IsAnime -FilePath $SourceFile.FullName

    # Encode with FFmpeg AMD AMF AV1
    if ($isAnime) {
        Write-Log "Encoding with AMD AMF AV1 (ANIME MODE - keeping original+ENG audio, ENG subs): $fileName"
        $streamMaps = Get-AnimeFFmpegMaps -FilePath $localDownloadFile
    } else {
        Write-Log "Encoding with AMD AMF AV1: $fileName"
        $streamMaps = "-map 0:v:0 -map 0:a:0 -map 0:s?"
    }

    # Use temp file for stderr to avoid buffer deadlock
    $stderrFile = Join-Path $env:TEMP "ffmpeg_stderr_$([guid]::NewGuid().ToString('N').Substring(0,8)).log"

    $encodeStart = Get-Date

    # Use System.Diagnostics.Process for proper process tracking
    # Start-Process with -PassThru has known issues with WaitForExit()
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FFmpegPath
    $psi.Arguments = "-y -i `"$localDownloadFile`" -c:v av1_amf -quality quality -rc vbr_peak -b:v ${TargetBitrateMbps}M -maxrate 10M $streamMaps -c:a copy -c:s copy `"$localEncodedFile`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $ffmpegProcess = New-Object System.Diagnostics.Process
    $ffmpegProcess.StartInfo = $psi

    try {
        $ffmpegProcess.Start() | Out-Null

        # Set high priority
        try {
            $ffmpegProcess.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
            Write-Log "FFmpeg started with High priority (PID: $($ffmpegProcess.Id))"
        } catch {
            Write-Log "FFmpeg started (PID: $($ffmpegProcess.Id))"
        }

        # Read stderr asynchronously to prevent buffer deadlock
        $stderrTask = $ffmpegProcess.StandardError.ReadToEndAsync()

        # Wait for process to complete
        $ffmpegProcess.WaitForExit()
        $encodeTime = (Get-Date) - $encodeStart

        # Get stderr content
        $stderrContent = $stderrTask.Result
        if ($stderrContent) {
            $stderrContent | Set-Content $stderrFile -Force
        }

        $exitCode = $ffmpegProcess.ExitCode
    } catch {
        Write-Log "FFmpeg process error: $($_.Exception.Message)" -Level "ERROR"
        $exitCode = -999
    } finally {
        if ($ffmpegProcess) {
            $ffmpegProcess.Dispose()
        }
    }

    $encodingSuccess = $false

    # Check if output file exists and has content as backup verification
    $outputExists = (Test-Path $localEncodedFile) -and ((Get-Item $localEncodedFile -ErrorAction SilentlyContinue).Length -gt 1MB)

    if ($exitCode -eq 0) {
        $encodingSuccess = $true
    } elseif ($outputExists -and $encodeTime.TotalMinutes -gt 1) {
        # FFmpeg sometimes returns non-zero but encoding was successful
        Write-Log "FFmpeg exit code $exitCode but output file exists ($([math]::Round((Get-Item $localEncodedFile).Length/1GB, 2)) GB) - treating as success" -Level "WARNING"
        $encodingSuccess = $true
    } else {
        Write-Log "Encoding failed with exit code: $exitCode" -Level "ERROR"
    }

    if (-not $encodingSuccess) {
        $stderr = if (Test-Path $stderrFile) { Get-Content $stderrFile -Tail 20 -Raw } else { "No stderr captured" }
        Write-Log "FFmpeg error: $stderr" -Level "ERROR"

        # Update progress and queue: encoding failed
        Update-Progress -Event "failed" -FilePath $SourceFile.FullName -Details "Exit code: $exitCode"
        Update-QueueStatus -FilePath $SourceFile.FullName -Status "failed" -Details "Exit code: $exitCode"

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
    Update-QueueStatus -FilePath $SourceFile.FullName -Status "uploading"
    $uploadStart = Get-Date
    try {
        Copy-Item -Path $localEncodedFile -Destination $nfsDestFile -Force
    } catch {
        Write-Log "Upload failed: $($_.Exception.Message)" -Level "ERROR"
        Update-QueueStatus -FilePath $SourceFile.FullName -Status "failed" -Details "Upload failed: $($_.Exception.Message)"
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

    # Update progress and queue: encoding successful
    Update-Progress -Event "encoded" -FilePath $SourceFile.FullName -Details "Reduced $sizeGB GB to $encodedSizeGB GB ($reduction%)"
    Update-QueueStatus -FilePath $SourceFile.FullName -Status "completed" -Details "Reduced $sizeGB GB to $encodedSizeGB GB ($reduction%)"

    return $true
}

# ============================================================================
# MAIN LOOP
# ============================================================================

Write-Log "============================================" -Level "SUCCESS"
Write-Log "NFS Video Processing Monitor Started" -Level "SUCCESS"
Write-Log "SINGLE INSTANCE MODE (Mutex acquired)" -Level "SUCCESS"
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
Write-Log "Queue file: $QueueFile"
Write-Log "Anime patterns: $($AnimeFolderPatterns.Count) patterns (JPN+ENG audio, ENG subs)"
Write-Log ""
Write-Log "Workflow: Download -> Encode -> Upload -> Cleanup"

# Clean stale queue entries on startup
Clean-StaleQueueEntries

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

    # Clean stale queue entries periodically (every scan cycle)
    Clean-StaleQueueEntries

    # Process files sequentially
    foreach ($file in $allVideoFiles) {
        $filePath = $file.FullName

        # Skip already processed files (in-memory cache)
        if ($script:ProcessedFiles.ContainsKey($filePath)) {
            continue
        }

        # Check queue - skip if already being processed or recently completed
        if (Test-InQueue -FilePath $filePath) {
            continue
        }

        # Try to add to queue (returns false if already queued by another instance)
        if (-not (Add-ToQueue -FilePath $filePath -Status "queued")) {
            Write-Log "Skipping $($file.Name) - already in queue" -Level "INFO"
            continue
        }

        # Mark as processed in memory (even if we skip it)
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
