# Process-VideoRips-Fixed.ps1
# Monitors rip directory, encodes to AV1 with AMD hardware
# FIXES:
# - Preserves source directory structure in encoded output
# - Uses C:\MediaProcessing\Encoding\ instead of final\
# - Fixed FFmpeg argument handling

param(
    [string]$WatchPath = "C:\MediaProcessing\rips\video",
    [string]$EncodedBase = "C:\MediaProcessing\Encoding",
    [string]$FFmpegPath = "C:\ffmpeg\bin\ffmpeg.exe",
    [int]$PollIntervalSeconds = 30,
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
        [string]$OutputFile
    )

    Write-Log "Encoding with AMD AMF: $InputFile -> $OutputFile"

    # Create FFmpeg argument array (no quotes in array elements)
    $Arguments = @(
        "-hide_banner",
        "-y",                      # Overwrite output file
        "-i", $InputFile,          # Input file (NO quotes here)
        "-c:v", "av1_amf",         # AMD AMF AV1 hardware encoder
        "-quality", "balanced",     # Balanced quality/speed mode
        "-rc", "cqp",              # Constant Quality mode
        "-qp_i", "26",             # I-frame quality (26 = very good)
        "-qp_p", "28",             # P-frame quality
        "-usage", "transcoding",   # Optimize for transcoding
        "-pix_fmt", "yuv420p",     # Standard color format
        "-map", "0",               # Map all streams
        "-c:a", "copy",            # Copy audio streams
        "-c:s", "copy",            # Copy subtitle streams
        $OutputFile                # Output file (NO quotes here)
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
            if (Test-Path $OutputFile) {
                $InputSize = (Get-Item $InputFile).Length / 1GB
                $OutputSize = (Get-Item $OutputFile).Length / 1GB
                $Reduction = [math]::Round((($InputSize - $OutputSize) / $InputSize) * 100, 1)
                Write-Log "Size: $([math]::Round($InputSize, 2))GB -> $([math]::Round($OutputSize, 2))GB ($Reduction% reduction)" -Level "SUCCESS"
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
Write-Log "Encoded base: $EncodedBase"
Write-Log "Encoder: FFmpeg with AMD AMF AV1 (hardware accelerated)"
Write-Log "FFmpeg path: $FFmpegPath"
Write-Log "Poll interval: $PollIntervalSeconds seconds"
Write-Log "Directory structure: PRESERVED from source"

# Establish SMB session and override output base when requested
if ($UseSMB) {
    if (-not (Ensure-SmbSession -Path $SmbPath -User $SmbUser -Password $SmbPassword)) {
        Write-Log "Exiting because SMB session could not be established for $SmbPath" -Level "ERROR"
        exit 1
    }
    $EncodedBase = $SmbPath
    Write-Log "Using SMB output path: $EncodedBase" -Level "INFO"
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
        Write-Log "Found $($VideoFiles.Count) video file(s) to process"
    }

    foreach ($File in $VideoFiles) {
        # Get output path preserving directory structure
        $OutputFile = Get-EncodedOutputPath -SourceFile $File

        # Ensure output directory exists
        $OutputDir = Split-Path -Path $OutputFile -Parent
        if (-not (Test-Path $OutputDir)) {
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            Write-Log "Created output directory: $OutputDir"
        }

        # Encode
        $Success = Invoke-FFmpegEncode -InputFile $File.FullName -OutputFile $OutputFile

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
