# Media Ingestion VM Setup Guide

## Overview

Automated physical media ingestion system running on Windows VM with GPU passthrough for hardware-accelerated AV1 encoding.

**VM Name**: media-ingestion
**Host**: pve-01 (192.168.1.116)
**Purpose**: Rip and encode physical media (Blu-ray, DVD, CD, photos) with full automation

## Architecture

```
Physical Media → Optical Drives → Auto-Detection Scripts
                                         ↓
                    ┌────────────────────┴────────────────────┐
                    ↓                                          ↓
            Video/DVD/Blu-ray                              Audio CDs
                    ↓                                          ↓
              MakeMKV (rip)                          dBpoweramp (rip)
                    ↓                                          ↓
            Lossless MKV                              FLAC/MP3
                    ↓                                          ↓
        HandBrake (AV1 encode)                      Perfect Tunes (metadata)
                    ↓                                          ↓
            Radeon Pro GPU                                     ↓
                    ↓                                          ↓
                    └────────────────────┬────────────────────┘
                                         ↓
                            SMB Share (Z:\)
                                         ↓
                            192.168.1.116:/tank/media/media
                                         ↓
                        ┌────────────────┼────────────────┐
                        ↓                ↓                ↓
                    movies/             tv/            music/
                        ↓                ↓                ↓
                    Radarr           Sonarr           Lidarr
```

## Hardware Configuration

### GPU Passthrough
- **GPU**: AMD Radeon Pro (passed through from Proxmox)
- **Drivers**: AMD Radeon Pro Workstation drivers (installed)
- **Purpose**: Hardware-accelerated AV1 encoding via AMD VCE

### Optical Drives
- **USB-attached**: Multiple USB CD/DVD/Blu-ray drives
- **SATA-attached**: 2x SATA optical drives
- **Passthrough**: USB controller + SATA controller passed through to VM

### Network Storage
- **NFS Server**: 192.168.1.116:/tank/media/media
- **Windows Mount**: SMB/CIFS mapped as Z:\
- **Directories**:
  - `Z:\movies\` - Movie output
  - `Z:\tv\` - TV show output
  - `Z:\music\` - Music output
  - `Z:\temp\rips\` - Temporary ripping workspace

## Software Stack

### Video/DVD/Blu-ray Ripping
**MakeMKV** (https://www.makemkv.com/)
- Free while in beta
- Automatic copy protection removal
- Preserves all tracks, audio, and subtitles
- Lossless MKV output

**Configuration**:
- Destination: `Z:\temp\rips\video\`
- Auto-save titles
- Minimum title length: 120 seconds (filters out menus/extras)
- Enable expert mode for batch processing

### Audio CD Ripping
**dBpoweramp CD Ripper** (Licensed)
- Bit-perfect ripping with C2 error detection
- AccurateRip verification
- Metadata from multiple sources (MusicBrainz, GD3, freedb)
- Batch ripping with multiple drives

**Perfect Tunes** (Licensed)
- Album art fetcher
- Metadata verification and correction
- AccurateRip verification
- De-duplication

**Configuration**:
- Output format: FLAC (lossless) for archival
- Destination: `Z:\music\`
- Naming: `[artist]\[album]\[track] [title]`
- Embed album art (500x500 minimum)
- Enable AccurateRip verification

### Video Encoding
**HandBrake** (https://handbrake.fr/)
- AV1 encoding via SVT-AV1 or hardware acceleration
- GPU-accelerated when possible
- Batch queue processing
- Watch folder automation

**Configuration**:
- Input: `Z:\temp\rips\video\`
- Output: `Z:\movies\` or `Z:\tv\`
- Encoder: AV1 (SVT-AV1 or AMD VCE if supported)
- Quality: RF 22-24 for high quality, RF 26-28 for balanced
- Audio: Opus or AAC passthrough
- Subtitles: Burn-in or soft subs

## AV1 Encoding Strategy

### Hardware Support Check
**AMD Radeon Pro AV1 Support**:
- VCE 4.0+ required for AV1 hardware encoding
- Check GPU specs to confirm AV1 encoding support
- If not supported: Use software encoding (SVT-AV1)

### Hardware Encoding (if supported)
**HandBrake settings**:
```
Encoder: AMD VCN AV1 (hardware)
Quality: CQ 24-28
Encoder Preset: Quality (slower = better compression)
Encoder Profile: Main
Encoder Level: Auto
```

### Software Encoding (fallback)
**HandBrake settings**:
```
Encoder: SVT-AV1
Quality: RF 22-26 (lower = higher quality)
Encoder Preset: 6-8 (0=slowest/best, 12=fastest/worst)
Speed: Preset 6 (good balance)
```

**Encoding speed expectations**:
- Hardware: 60-100+ FPS (real-time or faster)
- Software: 5-15 FPS (slow, overnight jobs)

### Quality Recommendations
- **4K Blu-ray**: RF 20-22, Preset 4-6 (archival quality)
- **1080p Blu-ray**: RF 22-24, Preset 6 (high quality)
- **DVD**: RF 24-26, Preset 6-8 (balanced)
- **Old/SD content**: RF 26-28, Preset 8 (smaller size)

## Automation Workflow

### Phase 1: Disc Detection and Initial Rip

**PowerShell script**: `Watch-OpticalDrives.ps1`
```powershell
# Monitors all optical drives
# Detects disc insertion
# Determines media type (Blu-ray/DVD/CD)
# Launches appropriate ripper
# Logs all operations
```

### Phase 2: Video Processing

**PowerShell script**: `Process-VideoRips.ps1`
```powershell
# Monitors Z:\temp\rips\video\
# Detects completed MakeMKV rips
# Determines movie vs TV show
# Adds to HandBrake queue
# Monitors encoding progress
# Moves completed files to Z:\movies\ or Z:\tv\
# Cleans up temp files
```

### Phase 3: Audio Processing

**dBpoweramp automation**:
```
# Batch ripping mode
# Auto-eject when complete
# Perfect Tunes post-processing:
  1. Verify AccurateRip
  2. Fetch album art
  3. Fix metadata
  4. Move to Z:\music\
```

### Phase 4: Import to Media Stack

**Radarr/Sonarr/Lidarr**:
- Configure import folders pointing to Z:\movies\, Z:\tv\, Z:\music\
- Enable automatic import on file detection
- Rename and organize files per library standards
- Fetch metadata and artwork
- Trigger Plex library refresh

## Network Storage Setup

### SMB/CIFS Mount Configuration

**Step 1: Ensure SMB server is enabled on NAS**
```bash
# On pve-01 or NAS host
sudo apt install samba
sudo systemctl enable smbd
sudo systemctl start smbd
```

**Step 2: Create SMB share for media directory**
Edit `/etc/samba/smb.conf` on NAS:
```ini
[media]
    path = /tank/media/media
    browseable = yes
    writable = yes
    guest ok = no
    valid users = jluczani
    create mask = 0644
    directory mask = 0755
```

Restart Samba:
```bash
sudo smbpasswd -a jluczani  # Set SMB password
sudo systemctl restart smbd
```

**Step 3: Mount on Windows VM**
```powershell
# Map network drive persistently
net use Z: \\192.168.1.116\media /user:jluczani /persistent:yes

# Or via GUI: File Explorer → Map Network Drive
# Drive: Z:
# Folder: \\192.168.1.116\media
# Check "Reconnect at sign-in"
```

**Step 4: Create directory structure**
```powershell
# On Windows VM (Z: drive)
New-Item -ItemType Directory -Path "Z:\temp\rips\video" -Force
New-Item -ItemType Directory -Path "Z:\temp\rips\audio" -Force
```

## Automation Scripts

### Script 1: Disc Detection Monitor

**File**: `C:\Scripts\Watch-OpticalDrives.ps1`

```powershell
# Watch-OpticalDrives.ps1
# Monitors optical drives for disc insertion and triggers appropriate ripping software

param(
    [int]$PollIntervalSeconds = 5
)

$LogFile = "C:\Scripts\Logs\optical-monitor.log"
$MakeMKVPath = "C:\Program Files (x86)\MakeMKV\makemkvcon64.exe"
$dBpowerampPath = "C:\Program Files\dBpoweramp\BatchRipper.exe"

function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$Timestamp - $Message" | Add-Content -Path $LogFile
    Write-Host "$Timestamp - $Message"
}

function Get-OpticalDrives {
    Get-WmiObject Win32_CDROMDrive | Where-Object {$_.MediaLoaded -eq $true}
}

function Get-DiscType {
    param([string]$DriveLetter)

    $Drive = Get-WmiObject Win32_CDROMDrive | Where-Object {$_.Drive -eq "$DriveLetter`:"}

    # Check for Blu-ray
    if ($Drive.MediaType -like "*Blu-ray*") {
        return "BluRay"
    }

    # Check volume label for DVD
    $Volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    if ($Volume.FileSystemLabel -match "DVD") {
        return "DVD"
    }

    # Check for audio CD (no filesystem)
    if ($Volume.FileSystem -eq $null -or $Volume.FileSystem -eq "") {
        return "AudioCD"
    }

    return "DVD" # Default to DVD for video discs
}

function Start-VideoRip {
    param([string]$DriveLetter, [string]$DiscType)

    Write-Log "Starting $DiscType rip from drive $DriveLetter"

    $OutputDir = "Z:\temp\rips\video\$DiscType-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    # MakeMKV command: rip all titles longer than 120 seconds
    $Arguments = "mkv disc:0 all $OutputDir --minlength=120 --progress=-stdout"

    Start-Process -FilePath $MakeMKVPath -ArgumentList $Arguments -NoNewWindow -Wait

    Write-Log "Completed rip to $OutputDir"

    # Eject disc
    (New-Object -ComObject "Shell.Application").NameSpace(17).ParseName("$DriveLetter`:").InvokeVerb("Eject")
}

function Start-AudioRip {
    param([string]$DriveLetter)

    Write-Log "Starting audio CD rip from drive $DriveLetter"

    # Launch dBpoweramp Batch Ripper (will handle the rip automatically)
    Start-Process -FilePath $dBpowerampPath -ArgumentList "-drive=$DriveLetter`: -auto"

    Write-Log "dBpoweramp launched for drive $DriveLetter"
}

# Track drives that have already been processed
$ProcessedDiscs = @{}

Write-Log "Optical drive monitor started"

while ($true) {
    $CurrentDrives = Get-OpticalDrives

    foreach ($Drive in $CurrentDrives) {
        $DriveLetter = $Drive.Drive.TrimEnd(':')

        # Skip if already processed
        if ($ProcessedDiscs.ContainsKey($DriveLetter)) {
            continue
        }

        $DiscType = Get-DiscType -DriveLetter $DriveLetter
        Write-Log "Detected $DiscType in drive $DriveLetter"

        if ($DiscType -eq "AudioCD") {
            Start-AudioRip -DriveLetter $DriveLetter
        } else {
            Start-VideoRip -DriveLetter $DriveLetter -DiscType $DiscType
        }

        # Mark as processed
        $ProcessedDiscs[$DriveLetter] = $true
    }

    # Clear processed drives that no longer have media
    $ProcessedDiscs.Keys | ForEach-Object {
        $DriveLetter = $_
        $StillLoaded = Get-WmiObject Win32_CDROMDrive |
            Where-Object {$_.Drive -eq "$DriveLetter`:" -and $_.MediaLoaded -eq $true}

        if (-not $StillLoaded) {
            $ProcessedDiscs.Remove($DriveLetter)
            Write-Log "Drive $DriveLetter ejected, ready for next disc"
        }
    }

    Start-Sleep -Seconds $PollIntervalSeconds
}
```

### Script 2: Video Encoding Automation

**File**: `C:\Scripts\Process-VideoRips.ps1`

```powershell
# Process-VideoRips.ps1
# Monitors rip directory, encodes to AV1, moves to final destination

param(
    [string]$WatchPath = "Z:\temp\rips\video",
    [string]$HandBrakeCLI = "C:\Program Files\HandBrake\HandBrakeCLI.exe",
    [int]$PollIntervalSeconds = 30
)

$LogFile = "C:\Scripts\Logs\video-processing.log"

function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$Timestamp - $Message" | Add-Content -Path $LogFile
    Write-Host "$Timestamp - $Message"
}

function Get-VideoFiles {
    Get-ChildItem -Path $WatchPath -Recurse -Include *.mkv,*.m2ts |
        Where-Object {$_.Length -gt 100MB} # Skip small files (menus, extras)
}

function Invoke-HandBrakeEncode {
    param(
        [string]$InputFile,
        [string]$OutputFile
    )

    Write-Log "Encoding: $InputFile -> $OutputFile"

    # HandBrake AV1 encoding arguments
    $Arguments = @(
        "-i", "`"$InputFile`"",
        "-o", "`"$OutputFile`"",
        "--encoder", "svt_av1",  # Use SVT-AV1 encoder (change to 'av1_amf' for AMD hardware if supported)
        "--encoder-preset", "6",  # Preset 6 = balanced speed/quality
        "--quality", "24",        # RF 24 = high quality
        "--encoder-level", "auto",
        "--audio-lang-list", "eng,jpn",
        "--all-audio",
        "--aencoder", "copy:aac,opus",  # Copy existing audio
        "--all-subtitles",
        "--subtitle-default", "1"
    )

    $ProcessArgs = $Arguments -join " "

    $Process = Start-Process -FilePath $HandBrakeCLI -ArgumentList $ProcessArgs -NoNewWindow -PassThru -Wait

    if ($Process.ExitCode -eq 0) {
        Write-Log "Encoding completed successfully"
        return $true
    } else {
        Write-Log "Encoding failed with exit code: $($Process.ExitCode)"
        return $false
    }
}

function Get-MediaDestination {
    param([string]$FileName)

    # Simple heuristic: if filename contains SxxExx pattern, it's TV
    if ($FileName -match "S\d{2}E\d{2}") {
        return "Z:\tv"
    } else {
        return "Z:\movies"
    }
}

Write-Log "Video processing monitor started"

while ($true) {
    $VideoFiles = Get-VideoFiles

    foreach ($File in $VideoFiles) {
        $OutputDir = Get-MediaDestination -FileName $File.Name
        $OutputFile = Join-Path $OutputDir $File.Name

        # Encode
        $Success = Invoke-HandBrakeEncode -InputFile $File.FullName -OutputFile $OutputFile

        if ($Success) {
            # Delete original rip after successful encode
            Remove-Item -Path $File.FullName -Force
            Write-Log "Deleted original file: $($File.FullName)"

            # Cleanup empty directories
            $ParentDir = $File.Directory
            if ((Get-ChildItem -Path $ParentDir).Count -eq 0) {
                Remove-Item -Path $ParentDir -Force
                Write-Log "Removed empty directory: $ParentDir"
            }
        }
    }

    Start-Sleep -Seconds $PollIntervalSeconds
}
```

### Script 3: Service Startup

**File**: `C:\Scripts\Start-IngestionServices.ps1`

```powershell
# Start-IngestionServices.ps1
# Launches all automation scripts on VM startup

$ScriptPath = "C:\Scripts"

# Create logs directory
New-Item -ItemType Directory -Path "$ScriptPath\Logs" -Force | Out-Null

# Start optical drive monitor
Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$ScriptPath\Watch-OpticalDrives.ps1`"" -WindowStyle Minimized

# Start video processing monitor
Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$ScriptPath\Process-VideoRips.ps1`"" -WindowStyle Minimized

Write-Host "Media ingestion services started"
```

**Auto-start on boot**:
1. Press Win+R, type `shell:startup`
2. Create shortcut to `Start-IngestionServices.ps1`
3. Or create scheduled task:

```powershell
$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\Scripts\Start-IngestionServices.ps1"
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "MediaIngestionServices" -Action $Action -Trigger $Trigger -Principal $Principal
```

## Installation Steps

### 1. Install Software

**Required**:
- MakeMKV: https://www.makemkv.com/download/
- HandBrake: https://handbrake.fr/downloads.php
- dBpoweramp CD Ripper (licensed)
- Perfect Tunes (licensed)

**Optional**:
- VLC Media Player (for preview/testing)
- MediaInfo (for file analysis)

### 2. Configure Network Storage

```powershell
# Mount SMB share
net use Z: \\192.168.1.116\media /user:jluczani /persistent:yes

# Create directories
New-Item -ItemType Directory -Path "Z:\temp\rips\video" -Force
New-Item -ItemType Directory -Path "Z:\temp\rips\audio" -Force
```

### 3. Configure MakeMKV

1. Launch MakeMKV
2. Go to: File → Preferences
3. **General**:
   - Expert mode: Enabled
   - Default output folder: `Z:\temp\rips\video\`
4. **Video**:
   - Minimum title length: 120 seconds
5. **Advanced**:
   - Default selection rule: all titles
6. **Integration**:
   - Enable expert mode features

### 4. Configure dBpoweramp

1. Launch dBpoweramp CD Ripper
2. **Options → CD Ripper Options**:
   - Rip to: `Z:\music\[artist]\[album]\`
   - Naming: `[track] [title]`
   - Format: FLAC (Level 5)
3. **Options → DSP Effects**:
   - Enable: ReplayGain
   - Enable: ID Tag Processing (embed album art)
4. **Options → Secure Settings**:
   - Enable AccurateRip
   - Enable C2 error pointers
   - Re-rip insecure frames: 4 times

### 5. Configure Perfect Tunes

1. Launch Perfect Tunes
2. **Album Art**:
   - Minimum size: 500x500
   - Embed into files: Yes
3. **AccurateRip**:
   - Check all files after ripping
4. **De-Dup**:
   - Scan music library for duplicates

### 6. Configure HandBrake

1. Launch HandBrake GUI
2. **Tools → Preferences**:
   - **General**:
     - When Done: Do Nothing
   - **Output Files**:
     - Default Path: `Z:\movies\`
     - Format: MP4 (M4V)
3. **Create AV1 Preset**:
   - Dimensions: Original
   - Video:
     - Encoder: SVT-AV1 (or av1_amf for AMD hardware)
     - Framerate: Same as source
     - Quality: RF 24
   - Audio:
     - Codec: Auto Passthrough or Opus
   - Subtitles: All tracks, Foreign Audio Scan
4. Save preset as "AV1 High Quality"

### 7. Install Automation Scripts

```powershell
# Create scripts directory
New-Item -ItemType Directory -Path "C:\Scripts" -Force
New-Item -ItemType Directory -Path "C:\Scripts\Logs" -Force

# Copy scripts to C:\Scripts\
# - Watch-OpticalDrives.ps1
# - Process-VideoRips.ps1
# - Start-IngestionServices.ps1

# Set execution policy
Set-ExecutionPolicy RemoteSigned -Scope LocalMachine

# Create startup task
$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\Scripts\Start-IngestionServices.ps1"
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName "MediaIngestionServices" -Action $Action -Trigger $Trigger -Principal $Principal
```

### 8. Configure *arr Apps for Import

**Radarr (Movies)**:
1. Settings → Media Management
2. Root Folders: `/mnt/media/movies`
3. Settings → Download Clients
4. Add → Manual Import
   - Name: "Ripped Movies"
   - Path: `/mnt/media/movies`
   - Enable: Yes

**Sonarr (TV)**:
1. Settings → Media Management
2. Root Folders: `/mnt/media/tv`
3. Configure manual import for `/mnt/media/tv`

**Lidarr (Music)**:
1. Settings → Media Management
2. Root Folders: `/mnt/media/music`
3. Configure import for `/mnt/media/music`

Enable automatic scanning in each app:
- Settings → Media Management → File Management
- Check "Enable" for Automatic Import
- Rescan folder interval: 1 minute (for fast imports)

## Daily Operation Workflow

### Automated Process
1. Insert disc into any optical drive
2. Script detects disc type automatically
3. Appropriate ripper launches (MakeMKV or dBpoweramp)
4. Disc rips to temp directory
5. Disc automatically ejects when complete
6. For video: HandBrake encodes to AV1
7. For audio: Perfect Tunes processes metadata and album art
8. Files move to final destinations (Z:\movies\, Z:\tv\, Z:\music\)
9. *arr apps detect new files and import
10. Plex library refreshes automatically

### Manual Intervention (when needed)
- **Movie/TV identification**: Radarr/Sonarr may need help with ambiguous titles
- **Disc error handling**: Some copy-protected discs may require manual intervention
- **Quality checks**: Spot-check encoded files for quality/errors

## Monitoring and Logs

### Check automation status
```powershell
# View optical drive monitor log
Get-Content C:\Scripts\Logs\optical-monitor.log -Tail 50

# View video processing log
Get-Content C:\Scripts\Logs\video-processing.log -Tail 50

# Check running services
Get-Process -Name powershell | Where-Object {$_.CommandLine -like "*Watch-Optical*"}
```

### Check encoding progress
- HandBrake GUI: Open → View Queue
- Or check log file: `C:\Users\<username>\AppData\Roaming\HandBrake\logs\`

### Check *arr app import
- Radarr: Activity → Queue
- Sonarr: Activity → Queue
- Lidarr: Activity → Queue

## Performance Optimization

### Parallel Processing
- **Multiple optical drives**: Run several rips simultaneously
- **Encoding queue**: HandBrake will process sequentially, queue builds automatically
- **Separate drives for different media types**: Dedicated drives for CD vs DVD/Blu-ray

### Storage Optimization
- **Temp directory cleanup**: Automation scripts delete originals after successful encode
- **Monitor disk space**: Ensure adequate space on Z:\ for rips and encodes
- **Compressed intermediates**: MakeMKV creates lossless files (large), encoded AV1 files are much smaller

### GPU Optimization
- **Check AMD GPU utilization**: Task Manager → Performance → GPU
- **AV1 hardware support**: Verify with `HandBrakeCLI --help | Select-String av1_amf`
- **If hardware encoding not available**: Software (SVT-AV1) works but is slower

## Troubleshooting

### Optical Drive Not Detected
```powershell
# Check drives
Get-WmiObject Win32_CDROMDrive

# Verify PCI passthrough in Proxmox
# On Proxmox host:
qm config <vmid> | grep hostpci
```

### SMB Mount Issues
```powershell
# Test connectivity
Test-NetConnection -ComputerName 192.168.1.116 -Port 445

# Remount
net use Z: /delete
net use Z: \\192.168.1.116\media /user:jluczani
```

### MakeMKV Copy Protection Errors
- Update MakeMKV to latest version
- Check for beta keys: https://www.makemkv.com/forum/viewtopic.php?f=5&t=1053
- Some discs require specific firmware updates on drives

### HandBrake Encoding Failures
```powershell
# Check HandBrake CLI manually
& "C:\Program Files\HandBrake\HandBrakeCLI.exe" -i "path\to\input.mkv" -o "test.mp4" --encoder svt_av1 --quality 24

# Check GPU support
& "C:\Program Files\HandBrake\HandBrakeCLI.exe" --help | Select-String av1
```

### Script Not Running
```powershell
# Check execution policy
Get-ExecutionPolicy

# View scheduled task status
Get-ScheduledTask -TaskName "MediaIngestionServices"

# Run script manually for debugging
powershell -ExecutionPolicy Bypass -File "C:\Scripts\Watch-OpticalDrives.ps1"
```

## Future Enhancements

### Planned Improvements
- [ ] Multi-disc Blu-ray set handling (auto-detect disc 1/2/3)
- [ ] Intelligent quality presets based on source (4K, 1080p, DVD)
- [ ] Duplicate detection (skip re-ripping same disc)
- [ ] Web dashboard for monitoring rip/encode progress
- [ ] Email/notification alerts on completion or errors
- [ ] Photo import automation (from camera SD cards)
- [ ] Vinyl record capture workflow (USB turntable → audio processing)

### Advanced Features
- **Hardware acceleration**: Verify and enable AMD AV1 hardware encoding
- **Quality analysis**: Automated VMAF scoring to validate encode quality
- **Storage tiering**: Keep original lossless MKVs on archive storage, AV1 encodes on fast storage
- **Metadata enrichment**: Automatic fetching of detailed movie/TV metadata, artwork, subtitles

## References

- MakeMKV Documentation: https://www.makemkv.com/
- MakeMKV Forum: https://www.makemkv.com/forum/
- HandBrake Documentation: https://handbrake.fr/docs/
- HandBrake AV1 Guide: https://handbrake.fr/docs/en/latest/technical/video-svt-av1.html
- dBpoweramp: https://www.dbpoweramp.com/
- Perfect Tunes: https://www.dbpoweramp.com/perfecttunes.htm
- AV1 Encoding Guide: https://wiki.x266.mov/docs/encoding/av1
