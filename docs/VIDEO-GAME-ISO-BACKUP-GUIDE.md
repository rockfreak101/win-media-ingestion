# Video Game ISO Backup Guide

## Overview

The enhanced optical drive monitoring script (`Watch-OpticalDrives-Games.ps1`) now supports automatic detection and ISO backup creation for video game discs in addition to the existing DVD/Blu-ray ripping and audio CD functionality.

## What's New

### Video Game Disc Detection

The script can now automatically detect video game discs from various platforms:

**Supported Platforms:**
- **PlayStation**: PS2, PS3, PS4, PS5, PSP
- **Xbox**: Original Xbox, Xbox 360, Xbox One
- **Nintendo**: Wii, GameCube
- **PC Games**

### Detection Methods

The script uses multiple detection strategies:

1. **Volume Label Matching**
   - PlayStation: `PS2`, `PS3`, `PS4`, `PS5`, `SCUS`, `SCES`, `SLUS`, `SLES`
   - Xbox: `XBOX`, `XBOX360`, `XBOXONE`, `X360`
   - Nintendo: `WII`, `GAMECUBE`, `NGC`
   - Generic: `GAME`, `INSTALL`, `SETUP`

2. **File System Analysis**
   - PlayStation 3: Checks for `PS3_GAME` directory or `EBOOT.BIN`
   - PlayStation Portable: Checks for `PSP_GAME` directory
   - Xbox: Checks for `*.xbe` (Original) or `*.xex` (360) files
   - Game executables: `*.exe` files

### ISO Creation Tools

The script supports two ISO creation tools (in order of preference):

1. **dd for Windows** (Recommended)
   - Creates exact bit-for-bit disc copies
   - Best for preservation and emulation
   - Download: https://chrysocome.net/dd
   - Install path: `C:\Program Files\dd\dd.exe`

2. **ImgBurn** (Fallback)
   - Popular GUI/CLI tool for ISO creation
   - Download: https://www.imgburn.com/
   - Install path: `C:\Program Files\ImgBurn\ImgBurn.exe`

## Installation

### Step 1: Install ISO Creation Tool

**Option A: dd for Windows (Recommended)**
```powershell
# Download from https://chrysocome.net/dd
# Extract dd.exe to C:\Program Files\dd\
New-Item -ItemType Directory -Path "C:\Program Files\dd" -Force
# Copy dd.exe to this directory
```

**Option B: ImgBurn**
```powershell
# Download installer from https://www.imgburn.com/
# Run installer (default path: C:\Program Files\ImgBurn\)
```

### Step 2: Create Output Directory

```powershell
# Create games directory structure
New-Item -ItemType Directory -Path "C:\MediaProcessing\rips\games" -Force
```

### Step 3: Deploy Script

Copy `Watch-OpticalDrives-Games.ps1` to `C:\Scripts\`:

```powershell
# Copy the script
Copy-Item "Watch-OpticalDrives-Games.ps1" -Destination "C:\Scripts\" -Force
```

### Step 4: Configure as Scheduled Task

Run as Administrator:

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Scripts\Watch-OpticalDrives-Games.ps1"'
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "Media Ingestion - Optical Monitor (Games)" -Action $action -Trigger $trigger -Principal $principal
```

## Usage Workflow

### Automatic Video Game Backup

1. **Insert game disc** into any optical drive (D-J)
2. **Script detects** the disc type automatically
3. **Platform identified** (PS2, Xbox 360, etc.)
4. **ISO created** using dd or ImgBurn
5. **ISO saved** to `C:\MediaProcessing\rips\games\<Platform>\<GameName>.iso`
6. **Disc auto-ejects** when complete
7. **Ready for next disc**

### Example Workflow

```
Insert PlayStation 2 game disc "GRAN_TURISMO_4"
↓
Script detects volume label "SCUS-97328"
↓
Platform identified: PS2
↓
dd creates ISO: C:\MediaProcessing\rips\games\PS2\SCUS-97328.iso
↓
Disc ejects automatically
↓
Ready for next disc
```

## Directory Structure

After running the script with various game discs, you'll have:

```
C:\MediaProcessing\rips\games\
├── PS2\
│   ├── GRAN_TURISMO_4.iso
│   └── FINAL_FANTASY_X.iso
├── PS3\
│   ├── THE_LAST_OF_US.iso
│   └── UNCHARTED_2.iso
├── Xbox360\
│   ├── HALO_3.iso
│   └── GEARS_OF_WAR.iso
├── XboxOne\
│   └── FORZA_HORIZON_4.iso
└── PC\
    ├── STARCRAFT_II.iso
    └── CIVILIZATION_VI.iso
```

## Configuration Parameters

The script accepts several parameters for customization:

```powershell
param(
    [int]$PollIntervalSeconds = 5,        # How often to check for discs
    [int]$MaxDVDRips = 2,                 # Max concurrent DVD rips
    [int]$MaxBluRayRips = 1,              # Max concurrent Blu-ray rips
    [int]$MaxCDRips = 1,                  # Max concurrent CD rips
    [int]$MaxGameRips = 1,                # Max concurrent game ISO rips
    [string]$LocalRipBase = "C:\MediaProcessing\rips",
    [string]$LogsDir = "C:\Scripts\Logs",
    [string]$ddPath = "C:\Program Files\dd\dd.exe",
    [string]$ImgBurnPath = "C:\Program Files\ImgBurn\ImgBurn.exe"
)
```

### Custom Configuration Example

```powershell
# Run with custom settings
C:\Scripts\Watch-OpticalDrives-Games.ps1 `
    -MaxGameRips 2 `
    -LocalRipBase "D:\GameBackups" `
    -ddPath "C:\Tools\dd\dd.exe"
```

## Monitoring and Logs

### View Real-Time Logs

```powershell
# Monitor optical drive detection log
Get-Content C:\Scripts\Logs\optical-monitor.log -Tail 50 -Wait
```

### Check for Game ISOs

```powershell
# List all game ISOs created
Get-ChildItem "C:\MediaProcessing\rips\games" -Recurse -Filter *.iso |
    Select-Object Name, Length, DirectoryName, LastWriteTime |
    Format-Table -AutoSize
```

### View Disc Inventory

```powershell
# See all processed discs (including games)
Get-Content C:\Scripts\Logs\disc-inventory.log | Where-Object { $_ -like "*VideoGame*" }
```

## Platform Detection Details

### PlayStation Detection

**PS2:**
- Volume labels: `SCUS`, `SCES`, `SLUS`, `SLES`, `PS2`
- Platform code in volume label (e.g., `SCUS-97328`)

**PS3:**
- Volume labels: `PS3`, `PLAYSTATION_3`
- Directory: `PS3_GAME`
- File: `EBOOT.BIN`

**PS4/PS5:**
- Volume labels: `PS4`, `PS5`, `PLAYSTATION_4`, `PLAYSTATION_5`

**PSP:**
- Directory: `PSP_GAME`

### Xbox Detection

**Original Xbox:**
- Volume labels: `XBOX` (without numbers)
- Executable: `default.xbe`

**Xbox 360:**
- Volume labels: `XBOX360`, `X360`
- Executables: `*.xex` files

**Xbox One:**
- Volume labels: `XBOXONE`, `XBOX_ONE`

### Nintendo Detection

**Wii:**
- Volume labels: `WII`, `RVL`

**GameCube:**
- Volume labels: `GAMECUBE`, `NGC`

### PC Games

**Generic Detection:**
- Volume labels: `GAME`, `INSTALL`, `SETUP`
- Presence of game executables (`.exe` files)
- Fallback category for unidentified discs

## Concurrency Control

The script implements concurrency limits to prevent overwhelming the system:

- **DVD rips**: 2 concurrent (configurable via `$MaxDVDRips`)
- **Blu-ray rips**: 1 concurrent (configurable via `$MaxBluRayRips`)
- **Audio CD rips**: 1 concurrent (configurable via `$MaxCDRips`)
- **Video game ISO rips**: 1 concurrent (configurable via `$MaxGameRips`)

If limits are reached, new discs are queued and processed when slots become available.

## Duplicate Detection

The script prevents re-processing the same disc:

**Disc Hash Generation:**
- Combines: Drive ID + Volume Label + Current Date
- Example: `IDE\CDROM\MATSHITA_DVD-RAM_UJ8E2___1.00_SCUS-97328_20241207`

**Inventory Tracking:**
- Processed discs logged to: `C:\Scripts\Logs\disc-inventory.log`
- Format: `Timestamp | DiscHash | MediaType | DiscName | Drive Letter`

**Behavior:**
- If disc already in inventory: Skip and auto-eject
- To re-process: Eject, re-insert, or remove from inventory log

## Troubleshooting

### Game Disc Not Detected

**Check volume label:**
```powershell
# View volume label of drive E:
Get-Volume -DriveLetter E | Select-Object DriveLetter, FileSystemLabel, FileSystem
```

**Check for game indicators:**
```powershell
# List root directory contents
Get-ChildItem E:\ -Force | Select-Object Name
```

**Manually add detection pattern:**
Edit the script and add your volume label pattern to the `$GamePatterns` array in `Test-VideoGameDisc` function.

### ISO Creation Fails

**Check tool installation:**
```powershell
# Verify dd is installed
Test-Path "C:\Program Files\dd\dd.exe"

# Verify ImgBurn is installed
Test-Path "C:\Program Files\ImgBurn\ImgBurn.exe"
```

**Check permissions:**
- Run script as Administrator
- Ensure write access to `C:\MediaProcessing\rips\games\`

**Manual ISO creation test:**
```powershell
# Test dd manually
& "C:\Program Files\dd\dd.exe" if=\\.\E: of=C:\test.iso bs=2048

# Test ImgBurn manually
& "C:\Program Files\ImgBurn\ImgBurn.exe" /MODE IBUILD /SRC E:\ /DEST C:\test.iso /START /CLOSE
```

### Disc Classified as Wrong Type

If a game disc is detected as DVD instead of VideoGame:

**Manual override:**
Edit `Get-DiscType` function priority - game detection happens FIRST, but you can add explicit volume label patterns.

**Check logs:**
```powershell
# See what type was detected
Get-Content C:\Scripts\Logs\optical-monitor.log | Select-String "Detected.*drive"
```

### ISO Size Issues

**Copy-protected discs:**
- Some game discs have copy protection that may prevent accurate ISO creation
- dd should create exact copy including protection sectors
- For troublesome discs, research platform-specific tools (e.g., DiscImageCreator for PlayStation)

**Verify ISO integrity:**
```powershell
# Check ISO file size matches disc size
$Disc = Get-Volume -DriveLetter E:
$ISO = Get-Item "C:\MediaProcessing\rips\games\PS2\GAME_DISC.iso"

Write-Host "Disc Size: $($Disc.Size / 1GB) GB"
Write-Host "ISO Size: $($ISO.Length / 1GB) GB"
```

## Advanced Usage

### Custom Platform Detection

To add custom platform detection patterns, edit the script:

```powershell
function Get-GamePlatform {
    param([string]$VolumeLabel, [string]$DriveLetter)

    # Add your custom detection here
    if ($VolumeLabel -match "YOUR_PATTERN") { return "YourPlatform" }

    # ... existing code ...
}
```

### Network Storage for Game ISOs

To save ISOs directly to network share:

```powershell
# Mount network share
net use G: \\192.168.1.116\games /user:jluczani /persistent:yes

# Run script with network path
C:\Scripts\Watch-OpticalDrives-Games.ps1 -LocalRipBase "G:\rips"
```

### Multiple Optical Drives

The script automatically monitors all drives D-J:
- Insert different discs in multiple drives
- Script processes each drive independently
- Respects concurrency limits (e.g., max 1 game ISO at a time)

## Performance Expectations

### ISO Creation Speed

**DVD-based games (4.7 GB):**
- dd: ~10-15 minutes (depending on drive speed)
- ImgBurn: ~10-15 minutes

**Blu-ray games (25-50 GB):**
- dd: ~30-60 minutes
- ImgBurn: ~30-60 minutes

**Speed depends on:**
- Optical drive read speed
- Disc condition
- Hard drive write speed
- USB vs SATA connection

## Use Cases

### 1. Game Preservation
Back up physical game collection for archival purposes.

### 2. Emulation
Create ISOs for use with emulators:
- **PCSX2** (PlayStation 2)
- **RPCS3** (PlayStation 3)
- **Xenia** (Xbox 360)
- **Dolphin** (Wii/GameCube)

### 3. Convenience
Store ISOs on hard drive for faster loading than physical discs.

### 4. Disc Rot Prevention
Preserve games before optical media degrades over time.

## Legal Considerations

**Important:**
- Only create ISOs of games you legally own
- ISOs are for personal backup and archival purposes only
- Do not distribute copyrighted game ISOs
- Check local laws regarding backup copies
- Some jurisdictions allow backup copies under fair use

## Integration with Existing Workflow

The enhanced script is **fully backward compatible** with existing functionality:

**Existing Features (Unchanged):**
- ✅ DVD/Blu-ray ripping with MakeMKV
- ✅ TV show multi-episode support
- ✅ Audio CD ripping with dBpoweramp
- ✅ Duplicate detection
- ✅ Auto-eject
- ✅ Concurrency controls

**New Features (Added):**
- ✅ Video game disc detection
- ✅ Platform identification
- ✅ ISO creation
- ✅ Platform-organized output

## Migration from Old Script

To upgrade from `Watch-OpticalDrives-TV-Fixed.ps1`:

1. **Stop old script:**
   ```powershell
   Get-ScheduledTask -TaskName "*Optical*" | Unregister-ScheduledTask -Confirm:$false
   ```

2. **Deploy new script:**
   ```powershell
   Copy-Item "Watch-OpticalDrives-Games.ps1" -Destination "C:\Scripts\" -Force
   ```

3. **Install ISO tool** (dd or ImgBurn)

4. **Create new scheduled task** (see Installation section)

5. **Test with a game disc**

## Future Enhancements

Potential future improvements:

- [ ] MD5/SHA1 checksum generation for ISOs
- [ ] Integration with game databases (IGDB, TheGamesDB)
- [ ] Automatic metadata fetching (cover art, game info)
- [ ] Multi-disc game set detection
- [ ] Verification against known good dumps (Redump, No-Intro)
- [ ] Compression options (CSO for PSP, WBFS for Wii)
- [ ] Direct upload to game library managers (Launchbox, Playnite)

## References

**ISO Creation Tools:**
- dd for Windows: https://chrysocome.net/dd
- ImgBurn: https://www.imgburn.com/

**Game Preservation:**
- Redump: http://redump.org/ (verified disc dumps database)
- No-Intro: https://www.no-intro.org/ (cartridge preservation)

**Emulators:**
- PCSX2: https://pcsx2.net/ (PS2)
- RPCS3: https://rpcs3.net/ (PS3)
- Xenia: https://xenia.jp/ (Xbox 360)
- Dolphin: https://dolphin-emu.org/ (Wii/GameCube)

## Summary

The enhanced `Watch-OpticalDrives-Games.ps1` script now provides:

✅ **Automatic detection** of video game discs from multiple platforms
✅ **Platform identification** (PS2, Xbox 360, PC, etc.)
✅ **ISO backup creation** using dd or ImgBurn
✅ **Organized storage** by platform
✅ **Duplicate prevention** via disc hash tracking
✅ **Queue management** with concurrency limits
✅ **Auto-eject** when complete
✅ **Full backward compatibility** with existing DVD/CD functionality

**Questions or Issues?**
- Check logs: `C:\Scripts\Logs\optical-monitor.log`
- Review inventory: `C:\Scripts\Logs\disc-inventory.log`
- Test tools manually before relying on automation
