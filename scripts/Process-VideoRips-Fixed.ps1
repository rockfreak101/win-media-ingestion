# Process-VideoRips-Fixed.ps1
# Monitors rip directory, encodes to AV1 with AMD hardware
# FIXES:
# - Preserves source directory structure in encoded output
# - Uses C:\MediaProcessing\Encoding\ instead of final\
# - Fixed FFmpeg argument handling
# - 2025-12-11: Switched from CQP to VBR mode to prevent file size increases
# - 2025-12-12: Use local encoding workflow to prevent SMB crashes
# - 2025-12-14: Added file readiness check to wait for MakeMKV to finish writing

param(
    [string]$WatchPath = "C:\MediaProcessing\rips\video",
    [string]$EncodedBase = "C:\MediaProcessing\Encoding",
    [string]$FFmpegPath = "C:\ffmpeg\bin\ffmpeg.exe",
    [int]$PollIntervalSeconds = 30,
    [int]$FileReadyAgeSeconds = 10,       # Minimum seconds since last write before processing
    [int]$FileSizeCheckWaitSeconds = 3,   # Seconds to wait between file size checks
    [bool]$UseSMB = $false,
    [string]$SmbPath = "\\10.0.0.1\media\Movies_Encoded",
    [string]$SmbUser = "jluczani",
    [string]$SmbPassword = $null
)

$LogFile = "C:\Scripts\Logs\video-processing.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "$Timestamp [$Level] $Message"
    $LogMessage | Add-Content -Path $LogFile
    Write-Host $LogMessage
}

function Test-FileReady {
    <#
    .SYNOPSIS
    Checks if a file is ready for processing (not locked by another process like MakeMKV).

    .DESCRIPTION
    Performs three checks:
    1. File age check - ensures minimum time since last modification
    2. File lock check - tries to open the file for read access
    3. File size stability check - ensures file size is not changing (still being written)

    This prevents attempting to encode files that MakeMKV is still writing.
    #>
    param(
        [System.IO.FileInfo]$File
    )

    # Check 1: File age - must be at least $FileReadyAgeSeconds old
    $FileAge = (Get-Date) - $File.LastWriteTime
    if ($FileAge.TotalSeconds -lt $FileReadyAgeSeconds) {
        Write-Log "  File too new (age: $([math]::Round($FileAge.TotalSeconds, 1))s < ${FileReadyAgeSeconds}s): $($File.Name)" -Level "DEBUG"
        return $false
    }

    # Check 2: Try to open file for read access (detects exclusive locks)
    try {
        $stream = [System.IO.File]::Open($File.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $stream.Close()
        $stream.Dispose()
    } catch {
        Write-Log "  File locked by another process (MakeMKV?): $($File.Name)" -Level "DEBUG"
        return $false
    }

    # Check 3: File size stability - ensure file is not actively being written
    $InitialSize = $File.Length
    Start-Sleep -Seconds $FileSizeCheckWaitSeconds

    # Refresh file info to get current size
    $File.Refresh()
    $CurrentSize = $File.Length

    if ($InitialSize -ne $CurrentSize) {
        $SizeDiff = $CurrentSize - $InitialSize
        Write-Log "  File still being written (size changed by $([math]::Round($SizeDiff / 1MB, 2)) MB): $($File.Name)" -Level "DEBUG"
        return $false
    }

    # All checks passed - file is ready
    return $true
}

function Get-VideoFiles {
    if (-not (Test-Path $WatchPath)) {
        Write-Log "Watch path does not exist: $WatchPath" -Level "WARNING"
        return @()
    }
    Get-ChildItem -Path $WatchPath -Recurse -Include *.mkv,*.m2ts |
        Where-Object {$_.Length -gt 100MB} # Skip small files (menus, extras)
}

function Invoke-FFmpegEncode {
    param(
        [string]$InputFile,
        [string]$LocalOutputFile,
        [string]$FinalOutputFile = $null  # SMB destination (optional)
    )

    Write-Log "Encoding with AMD AMF: $InputFile"
    Write-Log "  Local output:  $LocalOutputFile"
    if ($FinalOutputFile) {
        Write-Log "  Final output:  $FinalOutputFile (will move after encoding)"
    }

    # Create FFmpeg argument array (no quotes in array elements)
    $Arguments = @(
        "-hide_banner",
        "-y",                      # Overwrite output file
        "-i", $InputFile,          # Input file (NO quotes here)
        "-c:v", "av1_amf",         # AMD AMF AV1 hardware encoder
        "-quality", "balanced",     # Balanced quality/speed mode
        "-rc", "vbr_peak",         # Peak Constrained VBR (fixes file size increase bug)
        "-b:v", "2.5M",            # Target bitrate (good quality, reasonable size)
        "-maxrate", "5M",          # Maximum bitrate peak
        "-bufsize", "10M",         # Buffer size for rate control
        "-usage", "transcoding",   # Optimize for transcoding
        "-pix_fmt", "yuv420p",     # Standard color format
        "-map", "0",               # Map all streams
        "-c:a", "copy",            # Copy audio streams
        "-c:s", "copy",            # Copy subtitle streams
        $LocalOutputFile           # Encode to LOCAL disk (fast, no SMB)
    )

    # Log command for debugging (show what will be executed)
    Write-Log "FFmpeg command: $FFmpegPath $($Arguments -join ' ')"

    try {
        # Run FFmpeg and capture output/exit code for better diagnostics
        $ffmpegOutput = & $FFmpegPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Log "Encoding completed successfully (AMD hardware acceleration)" -Level "SUCCESS"

            # Show file sizes for comparison
            if (Test-Path $LocalOutputFile) {
                $InputSize = (Get-Item $InputFile).Length / 1GB
                $OutputSize = (Get-Item $LocalOutputFile).Length / 1GB
                $Reduction = [math]::Round((($InputSize - $OutputSize) / $InputSize) * 100, 1)
                Write-Log "Size: $([math]::Round($InputSize, 2))GB -> $([math]::Round($OutputSize, 2))GB ($Reduction% reduction)" -Level "SUCCESS"
            }

            # If SMB destination specified, move file there
            if ($FinalOutputFile) {
                try {
                    Write-Log "Moving encoded file to SMB: $FinalOutputFile" -Level "PROGRESS"

                    # Ensure destination directory exists
                    $FinalDir = Split-Path -Path $FinalOutputFile -Parent
                    if (-not (Test-Path $FinalDir)) {
                        New-Item -ItemType Directory -Path $FinalDir -Force | Out-Null
                        Write-Log "Created SMB directory: $FinalDir"
                    }

                    # Move to SMB
                    Move-Item -Path $LocalOutputFile -Destination $FinalOutputFile -Force
                    Write-Log "Moved to SMB successfully" -Level "SUCCESS"
                } catch {
                    Write-Log "ERROR: Failed to move to SMB - $($_.Exception.Message)" -Level "ERROR"
                    Write-Log "Encoded file remains at: $LocalOutputFile" -Level "WARNING"
                    return $false
                }
            }

            return $true
        } else {
            Write-Log "Encoding failed with exit code: $exitCode" -Level "ERROR"
            if ($ffmpegOutput) {
                $LastLines = ($ffmpegOutput | Select-Object -Last 10) -join "; "
                Write-Log "FFmpeg output (last lines): $LastLines" -Level "ERROR"
            }
            Write-Log "Check AMD GPU drivers and output path access" -Level "WARNING"
            return $false
        }
    } catch {
        Write-Log "ERROR: Encoding exception - $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Get-EncodedOutputPath {
    param(
        [System.IO.FileInfo]$SourceFile
    )

    # Get the relative path from the watch directory
    # Example: C:\MediaProcessing\rips\video\movies\Beast Wars 1\B1_t02.mkv
    # Relative: movies\Beast Wars 1\B1_t02.mkv
    $RelativePath = $SourceFile.FullName.Substring($WatchPath.Length).TrimStart('\')

    # Split into media type and rest
    # movies\Beast Wars 1\B1_t02.mkv -> Type: movies, SubPath: Beast Wars 1\B1_t02.mkv
    $PathParts = $RelativePath.Split('\')

    if ($PathParts.Length -ge 2) {
        $MediaType = $PathParts[0]  # "movies" or "tv"
        $SubPath = $PathParts[1..($PathParts.Length-1)] -join '\'  # "Beast Wars 1\B1_t02.mkv"

        # Build output path preserving structure
        # Result: C:\MediaProcessing\Encoding\movies\Beast Wars 1\B1_t02.mkv
        $OutputPath = Join-Path $EncodedBase (Join-Path $MediaType $SubPath)

        Write-Log "Path mapping: $RelativePath -> $OutputPath"
        return $OutputPath
    } else {
        # Fallback: use source filename only
        Write-Log "WARNING: Could not parse path structure, using flat output" -Level "WARNING"
        return Join-Path (Join-Path $EncodedBase "movies") $SourceFile.Name
    }
}

function Ensure-SmbSession {
    param(
        [string]$Path,
        [string]$User,
        [string]$Password
    )

    if (-not $User -or -not $Password) {
        Write-Log "SMB credentials missing; cannot mount $Path" -Level "ERROR"
        return $false
    }

    try {
        # Establish UNC session without drive letter
        & net use $Path $Password /user:$User | Out-Null
        if (Test-Path $Path) {
            Write-Log "SMB session established for $Path" -Level "SUCCESS"
            return $true
        }

        Write-Log "SMB session attempt did not validate access to $Path" -Level "ERROR"
        return $false
    } catch {
        Write-Log "SMB session setup failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

Write-Log "============================================" -Level "SUCCESS"
Write-Log "Video Processing Monitor Started" -Level "SUCCESS"
Write-Log "============================================" -Level "SUCCESS"
Write-Log "Watch path: $WatchPath"
Write-Log "Local encoded base: $EncodedBase (always encode here first)"
Write-Log "Encoder: FFmpeg with AMD AMF AV1 (hardware accelerated)"
Write-Log "Rate control: VBR (2.5 Mbps target, 5 Mbps max)"
Write-Log "FFmpeg path: $FFmpegPath"
Write-Log "Poll interval: $PollIntervalSeconds seconds"
Write-Log "File ready age: $FileReadyAgeSeconds seconds (wait after last write)"
Write-Log "File size check wait: $FileSizeCheckWaitSeconds seconds"
Write-Log "Directory structure: PRESERVED from source"

# Establish SMB session if requested (files will be moved to SMB after local encoding)
if ($UseSMB) {
    if (-not (Ensure-SmbSession -Path $SmbPath -User $SmbUser -Password $SmbPassword)) {
        Write-Log "WARNING: SMB session could not be established for $SmbPath" -Level "WARNING"
        Write-Log "Will encode locally but cannot move to SMB" -Level "WARNING"
        $UseSMB = $false
    } else {
        Write-Log "SMB session established: $SmbPath" -Level "SUCCESS"
        Write-Log "Workflow: Encode local -> Move to SMB" -Level "INFO"
    }
}

# Verify FFmpeg exists
if (-not (Test-Path $FFmpegPath)) {
    Write-Log "ERROR: FFmpeg not found at $FFmpegPath" -Level "ERROR"
    Write-Log "Please install FFmpeg or update the path" -Level "ERROR"
    exit 1
}

# Verify watch path exists
if (-not (Test-Path $WatchPath)) {
    Write-Log "ERROR: Watch path does not exist: $WatchPath" -Level "ERROR"
    Write-Log "Creating watch path..." -Level "WARNING"
    New-Item -ItemType Directory -Path $WatchPath -Force | Out-Null
}

Write-Log "Monitoring for video files..."

while ($true) {
    $VideoFiles = Get-VideoFiles

    if ($VideoFiles.Count -gt 0) {
        Write-Log "Found $($VideoFiles.Count) video file(s) to check"
    }

    foreach ($File in $VideoFiles) {
        # Check if file is ready for processing (not locked by MakeMKV, not still being written)
        if (-not (Test-FileReady -File $File)) {
            # File is not ready - skip it this cycle, will retry on next poll
            continue
        }

        Write-Log "File ready for encoding: $($File.Name)" -Level "SUCCESS"

        # Get LOCAL output path preserving directory structure
        $LocalOutputFile = Get-EncodedOutputPath -SourceFile $File

        # Ensure LOCAL output directory exists
        $LocalOutputDir = Split-Path -Path $LocalOutputFile -Parent
        if (-not (Test-Path $LocalOutputDir)) {
            New-Item -ItemType Directory -Path $LocalOutputDir -Force | Out-Null
            Write-Log "Created local output directory: $LocalOutputDir"
        }

        # Calculate SMB destination path if needed
        $SmbOutputFile = $null
        if ($UseSMB) {
            # Replace local base with SMB base in the path
            # Example: C:\MediaProcessing\Encoding\movies\file.mkv -> \\10.0.0.1\media\Movies_Encoded\movies\file.mkv
            $RelativePath = $LocalOutputFile.Substring($EncodedBase.Length).TrimStart('\')
            $SmbOutputFile = Join-Path $SmbPath $RelativePath
        }

        # Encode (always to local first, optionally move to SMB)
        $Success = Invoke-FFmpegEncode -InputFile $File.FullName -LocalOutputFile $LocalOutputFile -FinalOutputFile $SmbOutputFile

        if ($Success) {
            # Delete original rip after successful encode
            try {
                Remove-Item -Path $File.FullName -Force
                Write-Log "Deleted original file: $($File.FullName)" -Level "SUCCESS"

                # Cleanup empty directories
                $ParentDir = $File.Directory
                if ((Get-ChildItem -Path $ParentDir -Force).Count -eq 0) {
                    Remove-Item -Path $ParentDir -Force -Recurse
                    Write-Log "Removed empty directory: $ParentDir"
                }
            } catch {
                Write-Log "WARNING: Could not delete source file - $($_.Exception.Message)" -Level "WARNING"
            }
        } else {
            Write-Log "Encoding failed, keeping source file: $($File.FullName)" -Level "WARNING"
        }
    }

    Start-Sleep -Seconds $PollIntervalSeconds
}
