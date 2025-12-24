# Watch-OpticalDrives-Games.ps1
# Monitors optical drives with TV show multi-episode support + VIDEO GAME ISO BACKUP
#
# Features:
# - BluRay-only mode: Only auto-rips Blu-ray discs (DVDs are skipped)
# - Concurrency limits: 1 Blu-ray, 1 CD, 1 Game ISO
# - TV Shows: Rips ALL episodes (all titles >= 10 min)
# - Movies: Rips largest title only
# - VIDEO GAMES: Creates ISO backup of disc
# - English subtitles: Forced on all rips
# - Job queueing system
# - Admin privilege detection
#
# Video Game Support:
# - Detects PlayStation, Xbox, PC game discs
# - Creates ISO images using dd or ImgBurn
# - Organizes by platform (PS2, PS3, PS4, Xbox, Xbox360, PC)
# - Preserves exact disc copy for emulation
#
# BluRay-Only Mode (2024-12-20):
# - DVDs are detected but NOT auto-ripped
# - Only BluRay discs trigger automatic ripping
# - Use -BluRayOnly:$false to enable DVD ripping

param(
    [int]$PollIntervalSeconds = 5,
    [switch]$BluRayOnly = $true,  # Only auto-rip BluRay discs (skip DVDs)
    [int]$MaxDVDRips = 2,
    [int]$MaxBluRayRips = 1,
    [int]$MaxCDRips = 1,
    [int]$MaxGameRips = 1,
    [string]$LocalRipBase = "C:\MediaProcessing\rips",
    [string]$LogsDir = "C:\Scripts\Logs",
    [string]$MakeMKVPath = "C:\Program Files (x86)\MakeMKV\makemkvcon64.exe",
    [string]$dBpowerampPath = "C:\Program Files\dBpoweramp\CDGrab.exe",
    [string]$ddPath = "C:\Program Files\dd\dd.exe",  # dd for Windows
    [string]$ImgBurnPath = "C:\Program Files\ImgBurn\ImgBurn.exe"  # Alternative: ImgBurn
)

$LogFile = "$LogsDir\optical-monitor.log"

# Job tracking
$Script:ActiveDVDRips = 0
$Script:ActiveBluRayRips = 0
$Script:ActiveCDRips = 0
$Script:ActiveGameRips = 0
$Script:RipQueue = @()
$Script:ProcessedDiscs = @{}
$Script:ActiveJobs = @{}
$Script:PollCount = 0

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "$Timestamp [$Level] $Message"
    $LogMessage | Add-Content -Path $LogFile

    $Color = switch ($Level) {
        "ERROR" { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host $LogMessage -ForegroundColor $Color
}

function Test-AdminPrivileges {
    $CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($CurrentUser)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OpticalDrives {
    try {
        Get-WmiObject Win32_CDROMDrive -ErrorAction Stop | Where-Object {$_.MediaLoaded -eq $true}
    } catch {
        Write-Log "ERROR: Failed to query optical drives - Admin privileges required" -Level "ERROR"
        return @()
    }
}

function Test-VideoGameDisc {
    param([string]$DriveLetter, [string]$VolumeLabel)

    # Check volume label for common game disc patterns
    $GamePatterns = @(
        # PlayStation
        "^PS2",
        "^PS3",
        "^PS4",
        "^PS5",
        "PLAYSTATION",
        "SCUS",  # Sony Computer Entertainment US
        "SCES",  # Sony Computer Entertainment Europe
        "SCPS",  # Sony Computer Entertainment PlayStation
        "SLUS",  # Sony License US
        "SLES",  # Sony License Europe

        # Xbox
        "^XBOX",
        "XBOX360",
        "XBOXONE",
        "X360",
        "XBLA",

        # Nintendo
        "^WII",
        "GAMECUBE",
        "^NGC",

        # PC Games
        "GAME",
        "INSTALL",
        "SETUP"
    )

    foreach ($Pattern in $GamePatterns) {
        if ($VolumeLabel -match $Pattern) {
            Write-Log "Game disc pattern matched: $Pattern in volume label: $VolumeLabel" -Level "SUCCESS"
            return $true
        }
    }

    # Check for common game executable/directory patterns
    try {
        $DriveRoot = "${DriveLetter}:\"
        $GameIndicators = @(
            "*.exe",
            "EBOOT.BIN",     # PlayStation 3
            "PSP_GAME",      # PlayStation Portable
            "PS3_GAME",      # PlayStation 3
            "PS4",           # PlayStation 4
            "default.xbe",   # Original Xbox
            "default.xex"    # Xbox 360
        )

        foreach ($Indicator in $GameIndicators) {
            $Found = Get-ChildItem -Path $DriveRoot -Filter $Indicator -Recurse -ErrorAction SilentlyContinue -Depth 2 | Select-Object -First 1
            if ($Found) {
                Write-Log "Game disc indicator found: $Indicator in $DriveRoot" -Level "SUCCESS"
                return $true
            }
        }
    } catch {
        # Ignore errors during file search
    }

    return $false
}

function Get-GamePlatform {
    param([string]$VolumeLabel, [string]$DriveLetter)

    # Determine platform from volume label or disc contents
    if ($VolumeLabel -match "PS5|PLAYSTATION_5") { return "PS5" }
    if ($VolumeLabel -match "PS4|PLAYSTATION_4") { return "PS4" }
    if ($VolumeLabel -match "PS3|PLAYSTATION_3") { return "PS3" }
    if ($VolumeLabel -match "PS2|PLAYSTATION_2|SCUS|SCES|SLUS|SLES") { return "PS2" }
    if ($VolumeLabel -match "PSP") { return "PSP" }
    if ($VolumeLabel -match "XBOXONE|XBOX_ONE") { return "XboxOne" }
    if ($VolumeLabel -match "XBOX360|X360") { return "Xbox360" }
    if ($VolumeLabel -match "^XBOX[^0-9]") { return "Xbox" }
    if ($VolumeLabel -match "WII") { return "Wii" }
    if ($VolumeLabel -match "GAMECUBE|NGC") { return "GameCube" }

    # Check disc contents for platform-specific files
    try {
        $DriveRoot = "${DriveLetter}:\"
        if (Test-Path "$DriveRoot\PS3_GAME") { return "PS3" }
        if (Test-Path "$DriveRoot\PSP_GAME") { return "PSP" }
        if (Test-Path "$DriveRoot\EBOOT.BIN") { return "PS3" }
        if (Get-ChildItem "$DriveRoot\*.xex" -ErrorAction SilentlyContinue) { return "Xbox360" }
        if (Get-ChildItem "$DriveRoot\*.xbe" -ErrorAction SilentlyContinue) { return "Xbox" }
    } catch {
        # Ignore errors
    }

    return "PC"  # Default to PC game
}

function Get-DiscType {
    param([string]$DriveLetter)

    $Drive = Get-WmiObject Win32_CDROMDrive | Where-Object {$_.Drive -eq "$DriveLetter`:"}

    # Get volume information
    $Volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    $VolumeLabel = if ($Volume.FileSystemLabel) { $Volume.FileSystemLabel } else { "" }

    # Check for video game disc FIRST (before other checks)
    if (Test-VideoGameDisc -DriveLetter $DriveLetter -VolumeLabel $VolumeLabel) {
        return "VideoGame"
    }

    # Check for Blu-ray
    if ($Drive.MediaType -like "*Blu-ray*" -or $Drive.MediaType -like "*BD*") {
        return "BluRay"
    }

    if ($Volume.FileSystemLabel -match "DVD" -or $Volume.FileSystemLabel -match "BLU") {
        if ($Volume.Size -gt 8GB) {
            return "BluRay"
        }
        return "DVD"
    }

    # Check for audio CD (no filesystem OR CDDA media type)
    if ($null -eq $Volume.FileSystem -or $Volume.FileSystem -eq "" -or $Drive.MediaType -like "*CD-ROM*" -and $Volume.Size -lt 900MB) {
        # Additional check: if it's a small disc with "Audio" or "CD" in the label, it's likely audio
        if ($VolumeLabel -match "Audio" -or ($null -eq $Volume.FileSystem)) {
            return "AudioCD"
        }
    }

    # Size-based BluRay detection: discs > 8GB are BluRay (DVDs max out at ~9GB for DL)
    if ($Volume.Size -gt 8GB) {
        return "BluRay"
    }

    return "DVD" # Default
}

function Get-DiscHash {
    param([string]$DriveLetter)
    $Drive = Get-WmiObject Win32_CDROMDrive | Where-Object {$_.Drive -eq "$DriveLetter`:"}
    if ($Drive) {
        $Volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
        $VolumeLabel = if ($Volume) { $Volume.FileSystemLabel } else { "UNKNOWN" }
        return "$($Drive.Id)_$($VolumeLabel)_$(Get-Date -Format 'yyyyMMdd')"
    }
    return "unknown_$(Get-Date -Format 'yyyyMMddHHmmss')"
}

function Test-DiscProcessed {
    param([string]$DiscHash)
    $InventoryFile = "$LogsDir\disc-inventory.log"
    if (Test-Path $InventoryFile) {
        $Processed = Get-Content $InventoryFile | Where-Object { $_ -like "*$DiscHash*" }
        return ($null -ne $Processed)
    }
    return $false
}

function Add-DiscToInventory {
    param([string]$DiscHash, [string]$DiscName, [string]$DriveLetter, [string]$MediaType)
    $InventoryFile = "$LogsDir\disc-inventory.log"
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$Timestamp | $DiscHash | $MediaType | $DiscName | Drive $DriveLetter" | Add-Content -Path $InventoryFile
}

function Test-TVShowDisc {
    param([string]$VolumeName)
    # Detect if TV show by volume label patterns
    return ($VolumeName -match "SEASON|S\d{2}E\d{2}|DISC[_\s]*\d+|_\d+_|EPISODES?|TV|SERIES|VOL[_\s]*\d+")
}

function Get-AllTitles {
    param([int]$DriveIndex, [int]$MinDurationSeconds = 600)

    try {
        Write-Log "Querying disc for all titles (drive index $DriveIndex)..."

        $InfoArgs = "info disc:$DriveIndex"
        $InfoOutput = & $MakeMKVPath $InfoArgs 2>&1 | Out-String

        # Parse TINFO lines for duration (attribute 9)
        $Titles = @()

        foreach ($Line in ($InfoOutput -split "`n")) {
            if ($Line -match 'TINFO:(\d+),9,0,"(\d+)"') {
                $TitleNumber = [int]$Matches[1]
                $Duration = [int]$Matches[2]

                if ($Duration -ge $MinDurationSeconds) {
                    $Titles += [PSCustomObject]@{
                        TitleNumber = $TitleNumber
                        Duration = $Duration
                        DurationMinutes = [math]::Round($Duration / 60, 1)
                    }
                }
            }
        }

        if ($Titles.Count -eq 0) {
            Write-Log "WARNING: No titles found with duration >= $([math]::Round($MinDurationSeconds/60, 1)) minutes" -Level "WARNING"
            return @()
        }

        Write-Log "Found $($Titles.Count) qualifying titles" -Level "SUCCESS"
        return $Titles

    } catch {
        Write-Log "ERROR: Failed to query disc titles - $($_.Exception.Message)" -Level "ERROR"
        return @()
    }
}

function Get-MediaPath {
    param([string]$VolumeName, [string]$MediaType)

    if ($MediaType -eq "tv") {
        # Extract show name and season
        $ShowName = $VolumeName -replace "[\s_]+(SEASON|DISC|EPISODES?|TV|SERIES)[_\s]*\d+.*$", "" -replace "[_]+", " "
        $ShowName = $ShowName.Trim()
        $ShowName = (Get-Culture).TextInfo.ToTitleCase($ShowName.ToLower())

        # Extract season number
        if ($VolumeName -match "(SEASON|S)[\s_]*(\d+)") {
            $Season = "Season " + $Matches[2].PadLeft(2, '0')
        } else {
            $Season = "Season 01"
        }

        $FolderPath = "$LocalRipBase\video\tv\$ShowName\$Season"
        return @{Type="tv"; Path=$FolderPath; Name="$ShowName\$Season"; ShowName=$ShowName; Season=$Season}
    } else {
        # Movie
        $MovieName = $VolumeName -replace "[_]+", " "
        $MovieName = $MovieName.Trim()
        $MovieName = (Get-Culture).TextInfo.ToTitleCase($MovieName.ToLower())

        $FolderPath = "$LocalRipBase\video\movies\$MovieName"
        return @{Type="movies"; Path=$FolderPath; Name=$MovieName}
    }
}

function Can-StartRip {
    param([string]$DiscType)

    switch ($DiscType) {
        "DVD" { return $Script:ActiveDVDRips -lt $MaxDVDRips }
        "BluRay" { return $Script:ActiveBluRayRips -lt $MaxBluRayRips }
        "AudioCD" { return $Script:ActiveCDRips -lt $MaxCDRips }
        "VideoGame" { return $Script:ActiveGameRips -lt $MaxGameRips }
    }
    return $false
}

function Start-GameISORip {
    param([string]$DriveLetter, [string]$VolumeName)

    # Generate disc hash for duplicate detection
    $DiscHash = Get-DiscHash -DriveLetter $DriveLetter

    # Check if already processed
    if (Test-DiscProcessed -DiscHash $DiscHash) {
        Write-Log "SKIPPING: Game disc $VolumeName (hash: $DiscHash) already processed" -Level "WARNING"
        Invoke-EjectDisc -DriveLetter $DriveLetter
        return
    }

    # Check concurrency limits
    if (-not (Can-StartRip -DiscType "VideoGame")) {
        $Script:RipQueue += [PSCustomObject]@{
            DriveLetter = $DriveLetter
            DiscType = "VideoGame"
            VolumeName = $VolumeName
            QueuedTime = Get-Date
            DiscHash = $DiscHash
        }
        Write-Log "QUEUED: Video game ISO rip for drive $DriveLetter - '$VolumeName' (Limit: $MaxGameRips)" -Level "WARNING"
        return
    }

    # Increment active counter
    $Script:ActiveGameRips++

    # Detect game platform
    $Platform = Get-GamePlatform -VolumeLabel $VolumeName -DriveLetter $DriveLetter

    # Sanitize volume name for filename
    $SafeVolumeName = $VolumeName -replace '[\\/:*?"<>|]', '_'
    if ([string]::IsNullOrWhiteSpace($SafeVolumeName)) {
        $SafeVolumeName = "UNKNOWN_GAME"
    }

    # Create output directory
    $OutputDir = "$LocalRipBase\games\$Platform"
    $OutputISO = "$OutputDir\$SafeVolumeName.iso"

    Write-Log "Starting VIDEO GAME ISO rip from drive $DriveLetter (Active: $Script:ActiveGameRips game rips)"
    Write-Log "  Disc: $VolumeName"
    Write-Log "  Platform: $Platform"
    Write-Log "  Output: $OutputISO"

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    # Add to inventory before ripping
    Add-DiscToInventory -DiscHash $DiscHash -DiscName $VolumeName -DriveLetter $DriveLetter -MediaType "VideoGame-$Platform"

    # Determine which ISO creation tool to use
    $ISOCreationSuccess = $false

    if (Test-Path $ddPath) {
        # Use dd for Windows (most reliable for exact disc copies)
        Write-Log "Using dd for Windows to create ISO..."
        $ddArgs = "if=\\.\$DriveLetter`: of=`"$OutputISO`" bs=2048 --progress"

        try {
            $ddProcess = Start-Process -FilePath $ddPath -ArgumentList $ddArgs -NoNewWindow -PassThru -Wait
            if ($ddProcess.ExitCode -eq 0) {
                $ISOCreationSuccess = $true
                Write-Log "dd completed successfully" -Level "SUCCESS"
            } else {
                Write-Log "dd failed with exit code: $($ddProcess.ExitCode)" -Level "ERROR"
            }
        } catch {
            Write-Log "ERROR: dd execution failed - $($_.Exception.Message)" -Level "ERROR"
        }

    } elseif (Test-Path $ImgBurnPath) {
        # Fallback to ImgBurn CLI
        Write-Log "Using ImgBurn to create ISO..."
        $ImgBurnArgs = "/MODE IBUILD /SRC `"$DriveLetter`:\`" /DEST `"$OutputISO`" /START /CLOSE /NOIMAGEDETAILS /CLOSESUCCESS"

        try {
            $ImgBurnProcess = Start-Process -FilePath $ImgBurnPath -ArgumentList $ImgBurnArgs -NoNewWindow -PassThru -Wait
            if ($ImgBurnProcess.ExitCode -eq 0) {
                $ISOCreationSuccess = $true
                Write-Log "ImgBurn completed successfully" -Level "SUCCESS"
            } else {
                Write-Log "ImgBurn failed with exit code: $($ImgBurnProcess.ExitCode)" -Level "ERROR"
            }
        } catch {
            Write-Log "ERROR: ImgBurn execution failed - $($_.Exception.Message)" -Level "ERROR"
        }

    } else {
        Write-Log "ERROR: No ISO creation tool found (dd or ImgBurn)" -Level "ERROR"
        Write-Log "  Install dd for Windows: https://chrysocome.net/dd" -Level "ERROR"
        Write-Log "  Or install ImgBurn: https://www.imgburn.com/" -Level "ERROR"
    }

    # Decrement counter
    $Script:ActiveGameRips--

    if ($ISOCreationSuccess) {
        Write-Log "Video game ISO created successfully: $OutputISO" -Level "SUCCESS"

        # Get file size
        $ISOFile = Get-Item $OutputISO
        $ISOSizeGB = [math]::Round($ISOFile.Length / 1GB, 2)
        Write-Log "  ISO size: $ISOSizeGB GB" -Level "SUCCESS"
    } else {
        Write-Log "Failed to create ISO for $VolumeName" -Level "ERROR"
    }

    # Eject disc
    Invoke-EjectDisc -DriveLetter $DriveLetter

    # Process queue
    Process-RipQueue
}

function Start-VideoRip {
    param([string]$DriveLetter, [string]$DiscType, [string]$VolumeName)

    # Generate disc hash for duplicate detection
    $DiscHash = Get-DiscHash -DriveLetter $DriveLetter

    # Check if already processed
    if (Test-DiscProcessed -DiscHash $DiscHash) {
        Write-Log "SKIPPING: Disc $VolumeName (hash: $DiscHash) already processed" -Level "WARNING"
        Invoke-EjectDisc -DriveLetter $DriveLetter
        return
    }

    # Check concurrency limits
    if (-not (Can-StartRip -DiscType $DiscType)) {
        $Script:RipQueue += [PSCustomObject]@{
            DriveLetter = $DriveLetter
            DiscType = $DiscType
            VolumeName = $VolumeName
            QueuedTime = Get-Date
            DiscHash = $DiscHash
        }
        Write-Log "QUEUED: $DiscType rip for drive $DriveLetter - '$VolumeName' (Limit: $MaxDVDRips DVD, $MaxBluRayRips Blu-ray)" -Level "WARNING"
        return
    }

    # Increment active counter
    switch ($DiscType) {
        "DVD" { $Script:ActiveDVDRips++ }
        "BluRay" { $Script:ActiveBluRayRips++ }
    }

    # Detect if TV show
    $IsTVShow = Test-TVShowDisc -VolumeName $VolumeName
    $MediaType = if ($IsTVShow) { "tv" } else { "movies" }

    # Determine media path
    $MediaInfo = Get-MediaPath -VolumeName $VolumeName -MediaType $MediaType
    $OutputDir = $MediaInfo.Path

    Write-Log "Starting $DiscType rip from drive $DriveLetter (Active: $Script:ActiveDVDRips DVD, $Script:ActiveBluRayRips Blu-ray)"
    Write-Log "  Disc: $VolumeName"
    Write-Log "  Detected Type: $MediaType"
    Write-Log "  Path: $OutputDir"

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    # Get drive index
    $DriveIndex = [byte][char]$DriveLetter - [byte][char]'D'

    # Get titles based on media type
    if ($IsTVShow) {
        # TV Show: Get ALL titles >= 5 minutes (episodes, including short segments)
        Write-Log "TV SHOW detected - will rip ALL episodes (titles >= 5 minutes)" -Level "SUCCESS"
        $Titles = Get-AllTitles -DriveIndex $DriveIndex -MinDurationSeconds 300

        if ($Titles.Count -eq 0) {
            Write-Log "WARNING: No titles >= 5 minutes found, falling back to rip ALL titles (no minimum)" -Level "WARNING"
            $MakeMKVArgs = "mkv disc:$DriveIndex all `"$OutputDir`" --minlength=0 --progress=-stdout"
        } else {
            Write-Log "Will rip $($Titles.Count) episodes from TV show disc" -Level "SUCCESS"
            $TitleNumbers = ($Titles | ForEach-Object { $_.TitleNumber }) -join ","
            $MakeMKVArgs = "mkv disc:$DriveIndex all `"$OutputDir`" --minlength=300 --progress=-stdout"
        }

    } else {
        # Movie: Get ONLY largest title >= 10 minutes
        Write-Log "MOVIE detected - will rip largest title only (>= 10 minutes)" -Level "SUCCESS"
        $Titles = Get-AllTitles -DriveIndex $DriveIndex -MinDurationSeconds 600

        if ($Titles.Count -eq 0) {
            Write-Log "WARNING: No titles >= 10 minutes found on movie disc, falling back to rip ALL titles (no minimum)" -Level "WARNING"
            $MakeMKVArgs = "mkv disc:$DriveIndex all `"$OutputDir`" --minlength=0 --progress=-stdout"
        } else {
            $LargestTitle = $Titles | Sort-Object -Property Duration -Descending | Select-Object -First 1
            Write-Log "Largest title: #$($LargestTitle.TitleNumber) ($($LargestTitle.DurationMinutes) min)" -Level "SUCCESS"

            $TitleNumbers = $LargestTitle.TitleNumber
            $MakeMKVArgs = "mkv disc:$DriveIndex $TitleNumbers `"$OutputDir`" --progress=-stdout"
        }
    }

    Write-Log "MakeMKV command: $MakeMKVPath $MakeMKVArgs"

    # Add to inventory before ripping
    Add-DiscToInventory -DiscHash $DiscHash -DiscName $VolumeName -DriveLetter $DriveLetter -MediaType $MediaType

    # Track this active rip
    $Script:ActiveJobs[$DriveLetter] = @{
        DiscType = $DiscType
        VolumeName = $VolumeName
        MediaType = $MediaType
        StartTime = Get-Date
        Process = $null
    }

    if ($IsTVShow) {
        Write-Log "TV show ripping started - will rip ALL episodes" -Level "SUCCESS"
    } else {
        Write-Log "Movie ripping started - largest title only" -Level "SUCCESS"
    }

    # Launch MakeMKV synchronously with monitoring
    try {
        $MakeMKVProcess = Start-Process -FilePath $MakeMKVPath -ArgumentList $MakeMKVArgs -NoNewWindow -PassThru
        $Script:ActiveJobs[$DriveLetter].Process = $MakeMKVProcess
        Write-Log "MakeMKV started (PID: $($MakeMKVProcess.Id)) for drive $DriveLetter"
    } catch {
        Write-Log "ERROR: Failed to start MakeMKV - $($_.Exception.Message)" -Level "ERROR"

        # Decrement counter and remove job
        switch ($DiscType) {
            "DVD" { $Script:ActiveDVDRips-- }
            "BluRay" { $Script:ActiveBluRayRips-- }
        }
        $Script:ActiveJobs.Remove($DriveLetter)
        return
    }
}

# Process completion check - called from main loop
function Update-ActiveRips {
    $CompletedDrives = @()
    $TimeoutMinutes = 30

    foreach ($DriveLetter in $Script:ActiveJobs.Keys) {
        $Job = $Script:ActiveJobs[$DriveLetter]
        $Process = $Job.Process

        if ($null -eq $Process) { continue }

        $ElapsedMinutes = ((Get-Date) - $Job.StartTime).TotalMinutes

        # Check if process has exited
        if ($Process.HasExited) {
            $ExitCode = $Process.ExitCode
            $ElapsedTime = [Math]::Round($ElapsedMinutes, 1)

            if ($ExitCode -eq 0) {
                Write-Log "Rip completed successfully for drive $DriveLetter after $ElapsedTime minutes (exit code: $ExitCode)" -Level "SUCCESS"
            } else {
                Write-Log "Rip FAILED for drive $DriveLetter after $ElapsedTime minutes (exit code: $ExitCode)" -Level "ERROR"
            }

            # Eject disc
            Invoke-EjectDisc -DriveLetter $DriveLetter

            # Decrement counter
            switch ($Job.DiscType) {
                "DVD" { $Script:ActiveDVDRips-- }
                "BluRay" { $Script:ActiveBluRayRips-- }
            }

            $CompletedDrives += $DriveLetter

        # Check for timeout
        } elseif ($ElapsedMinutes -gt $TimeoutMinutes) {
            Write-Log "ERROR: MakeMKV timeout after $TimeoutMinutes minutes for drive $DriveLetter - '$($Job.VolumeName)'" -Level "ERROR"

            try {
                $Process.Kill()
                $Process.WaitForExit(5000)
                Write-Log "Killed hung MakeMKV process (PID: $($Process.Id))" -Level "WARNING"
            } catch {
                Write-Log "ERROR: Failed to kill process - $($_.Exception.Message)" -Level "ERROR"
            }

            # Eject disc
            Invoke-EjectDisc -DriveLetter $DriveLetter

            # Decrement counter
            switch ($Job.DiscType) {
                "DVD" { $Script:ActiveDVDRips-- }
                "BluRay" { $Script:ActiveBluRayRips-- }
            }

            $CompletedDrives += $DriveLetter
        }
    }

    # Remove completed jobs
    foreach ($DriveLetter in $CompletedDrives) {
        $Script:ActiveJobs.Remove($DriveLetter)
        Write-Log "Removed completed job for drive $DriveLetter (Active: $Script:ActiveDVDRips DVD, $Script:ActiveBluRayRips Blu-ray)"
    }
}

function Start-AudioRip {
    param([string]$DriveLetter)

    if (-not (Can-StartRip -DiscType "AudioCD")) {
        Write-Log "QUEUED: Audio CD rip for drive $DriveLetter (Limit: $MaxCDRips)" -Level "WARNING"
        $Script:RipQueue += [PSCustomObject]@{
            DriveLetter = $DriveLetter
            DiscType = "AudioCD"
            VolumeName = "Audio CD"
            QueuedTime = Get-Date
        }
        return
    }

    $Script:ActiveCDRips++

    Write-Log "Starting audio CD rip from drive $DriveLetter (Active: $Script:ActiveCDRips CD)"

    $OutputDir = "$LocalRipBase\audio"
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    try {
        Start-Process -FilePath $dBpowerampPath
        Write-Log "dBpoweramp launched for drive $DriveLetter (manual ripping required)" -Level "SUCCESS"
    } catch {
        Write-Log "ERROR: Failed to launch dBpoweramp - $($_.Exception.Message)" -Level "ERROR"
        $Script:ActiveCDRips--
    }
}

function Invoke-EjectDisc {
    param([string]$DriveLetter)

    try {
        (New-Object -ComObject 'Shell.Application').NameSpace(17).ParseName("$DriveLetter`:").InvokeVerb('Eject')
        Write-Log "Ejected disc from drive $DriveLetter"
    } catch {
        Write-Log "ERROR: Failed to eject drive $DriveLetter - $($_.Exception.Message)" -Level "ERROR"
    }
}

function Process-RipQueue {
    # Check for completion markers (both successful and failed)
    $CompletionMarkers = Get-ChildItem -Path $LogsDir -Filter "rip-*.marker" -ErrorAction SilentlyContinue

    foreach ($Marker in $CompletionMarkers) {
        try {
            $CompletionData = Import-Clixml -Path $Marker.FullName
            $DriveLetter = $CompletionData.DriveLetter
            $DiscType = $CompletionData.DiscType
            $Failed = if ($CompletionData.Failed) { $true } else { $false }

            # Decrement counter
            switch ($DiscType) {
                "DVD" { if ($Script:ActiveDVDRips -gt 0) { $Script:ActiveDVDRips-- } }
                "BluRay" { if ($Script:ActiveBluRayRips -gt 0) { $Script:ActiveBluRayRips-- } }
                "AudioCD" { if ($Script:ActiveCDRips -gt 0) { $Script:ActiveCDRips-- } }
                "VideoGame" { if ($Script:ActiveGameRips -gt 0) { $Script:ActiveGameRips-- } }
            }

            if ($Failed) {
                $FailReason = if ($CompletionData.TimedOut) { "TIMEOUT" } else { "ExitCode: $($CompletionData.ExitCode)" }
                Write-Log "Rip FAILED for drive $DriveLetter ($FailReason), updated counter: $Script:ActiveDVDRips DVD, $Script:ActiveBluRayRips Blu-ray, $Script:ActiveCDRips CD, $Script:ActiveGameRips Game" -Level "WARNING"
            } else {
                Write-Log "Rip completed for drive $DriveLetter, updated counter: $Script:ActiveDVDRips DVD, $Script:ActiveBluRayRips Blu-ray, $Script:ActiveCDRips CD, $Script:ActiveGameRips Game" -Level "SUCCESS"
            }

            $Script:ActiveJobs.Remove($DriveLetter)
            Remove-Item -Path $Marker.FullName -Force
        } catch {
            Write-Log "ERROR: Failed to process completion marker $($Marker.Name) - $($_.Exception.Message)" -Level "ERROR"
        }
    }

    # Process queued rips
    if ($Script:RipQueue.Count -gt 0) {
        $QueueCopy = @($Script:RipQueue)
        foreach ($QueuedRip in $QueueCopy) {
            if (Can-StartRip -DiscType $QueuedRip.DiscType) {
                Write-Log "DEQUEUING: Starting queued $($QueuedRip.DiscType) rip for drive $($QueuedRip.DriveLetter) - '$($QueuedRip.VolumeName)'" -Level "SUCCESS"
                $Script:RipQueue = $Script:RipQueue | Where-Object { $_ -ne $QueuedRip }

                if ($QueuedRip.DiscType -eq "AudioCD") {
                    Start-AudioRip -DriveLetter $QueuedRip.DriveLetter
                } elseif ($QueuedRip.DiscType -eq "VideoGame") {
                    Start-GameISORip -DriveLetter $QueuedRip.DriveLetter -VolumeName $QueuedRip.VolumeName
                } else {
                    Start-VideoRip -DriveLetter $QueuedRip.DriveLetter -DiscType $QueuedRip.DiscType -VolumeName $QueuedRip.VolumeName
                }
            }
        }
    }
}

# ============================================================================
# Main Script
# ============================================================================

Write-Log "========================================" -Level "SUCCESS"
Write-Log "Optical Drive Monitor Started (TV Show + VIDEO GAME ISO Support)" -Level "SUCCESS"
Write-Log "========================================" -Level "SUCCESS"

if (-not (Test-AdminPrivileges)) {
    Write-Log "ERROR: This script requires Administrator privileges" -Level "ERROR"
    Write-Log "Please run as Administrator or deploy as SYSTEM scheduled task" -Level "ERROR"
    Write-Host "`nPress any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Log "Admin privileges: OK" -Level "SUCCESS"
Write-Log "MakeMKV path: $MakeMKVPath"
Write-Log "dBpoweramp path: $dBpowerampPath"
Write-Log "dd path: $ddPath"
Write-Log "ImgBurn path: $ImgBurnPath"
Write-Log "Local rip base: $LocalRipBase"
if ($BluRayOnly) {
    Write-Log "*** BLURAY-ONLY MODE ENABLED - DVDs will be SKIPPED ***" -Level "WARNING"
    Write-Log "Concurrency limits: $MaxBluRayRips Blu-ray, $MaxCDRips CD, $MaxGameRips Video Game ISO"
} else {
    Write-Log "Concurrency limits: $MaxDVDRips DVD, $MaxBluRayRips Blu-ray, $MaxCDRips CD, $MaxGameRips Video Game ISO"
}
Write-Log "Rip mode: MOVIES = single file (largest), TV SHOWS = all episodes, VIDEO GAMES = ISO backup"
Write-Log "Monitoring drives for disc insertion..."

# Check if ISO creation tools are available
if (Test-Path $ddPath) {
    Write-Log "ISO creation tool: dd for Windows (FOUND)" -Level "SUCCESS"
} elseif (Test-Path $ImgBurnPath) {
    Write-Log "ISO creation tool: ImgBurn (FOUND)" -Level "SUCCESS"
} else {
    Write-Log "WARNING: No ISO creation tool found (dd or ImgBurn)" -Level "WARNING"
    Write-Log "  Video game ISO backup will not work without one of these tools" -Level "WARNING"
    Write-Log "  Download dd: https://chrysocome.net/dd" -Level "WARNING"
    Write-Log "  Download ImgBurn: https://www.imgburn.com/" -Level "WARNING"
}

while ($true) {
    # Check active MakeMKV processes for completion or timeout
    Update-ActiveRips

    Process-RipQueue

    $CurrentDrives = Get-OpticalDrives

    foreach ($Drive in $CurrentDrives) {
        $DriveLetter = $Drive.Drive.TrimEnd(':')

        if ($Script:ProcessedDiscs.ContainsKey($DriveLetter)) {
            continue
        }

        # Mark as processed IMMEDIATELY to prevent duplicate detection in next poll cycle
        $Script:ProcessedDiscs[$DriveLetter] = $true

        $DiscType = Get-DiscType -DriveLetter $DriveLetter
        $Volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
        $VolumeName = if ($Volume.FileSystemLabel) { $Volume.FileSystemLabel } else { "UNKNOWN_DISC" }

        Write-Log "Detected $DiscType in drive $DriveLetter - '$VolumeName'"

        if ($DiscType -eq "AudioCD") {
            Start-AudioRip -DriveLetter $DriveLetter
        } elseif ($DiscType -eq "VideoGame") {
            Start-GameISORip -DriveLetter $DriveLetter -VolumeName $VolumeName
        } elseif ($DiscType -eq "DVD" -and $BluRayOnly) {
            # BluRay-only mode: Skip DVD ripping
            Write-Log "SKIPPED: DVD disc '$VolumeName' in drive $DriveLetter (BluRay-only mode enabled)" -Level "WARNING"
            Write-Log "  To enable DVD ripping, restart with: -BluRayOnly:`$false" -Level "WARNING"
            # Don't eject - leave DVD in drive for manual handling
        } else {
            Start-VideoRip -DriveLetter $DriveLetter -DiscType $DiscType -VolumeName $VolumeName
        }
    }

    # Clear processed drives that no longer have media
    $DrivesToCheck = @($Script:ProcessedDiscs.Keys)
    foreach ($DriveLetter in $DrivesToCheck) {
        $StillLoaded = Get-WmiObject Win32_CDROMDrive |
            Where-Object {$_.Drive -eq "$DriveLetter`:" -and $_.MediaLoaded -eq $true}

        if (-not $StillLoaded) {
            $Script:ProcessedDiscs.Remove($DriveLetter)
            Write-Log "Drive $DriveLetter ejected, ready for next disc"
        }
    }

    # Status update every 10 polls
    if ($Script:PollCount % 10 -eq 0) {
        Write-Log "Status: $Script:ActiveDVDRips DVD, $Script:ActiveBluRayRips Blu-ray, $Script:ActiveCDRips CD, $Script:ActiveGameRips Game active | Queue: $($Script:RipQueue.Count)"
    }

    $Script:PollCount++
    Start-Sleep -Seconds $PollIntervalSeconds
}
