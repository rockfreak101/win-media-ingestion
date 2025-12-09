# Windows Media Ingestion System

Automated physical media ingestion system for Windows with optical drive monitoring, video game ISO backup, and hardware-accelerated encoding.

## Overview

This system provides complete automation for:
- **Optical disc detection** - Monitors 7 optical drives (6 DVD + 1 Blu-ray)
- **Video game ISO backup** - Automatically creates ISOs for PlayStation, Xbox, Nintendo, and PC games
- **DVD/Blu-ray ripping** - MakeMKV integration for video content
- **Hardware encoding** - AMD AMF AV1 encoding at 7.7x realtime speed
- **Network storage** - High-speed SMB mounting (10Gb/s fiber, 1034 MB/s throughput)

## Features

### Optical Drive Monitoring
- **Auto-detection** of disc types (DVD, Blu-ray, Audio CD, Video Games)
- **Concurrent processing** with configurable limits
- **Duplicate prevention** via disc inventory tracking
- **Auto-eject** when processing completes
- **Queue management** for overflow handling

### Video Game Platform Support
- PlayStation: PS2, PS3, PS4, PS5, PSP
- Xbox: Original, 360, One
- Nintendo: Wii, GameCube
- PC Games

### Video Encoding
- **AMD AMF hardware acceleration** (av1_amf, h264_amf, hevc_amf)
- **Directory structure preservation** from rip to encode
- **Automatic cleanup** of source files after successful encoding
- **Progress monitoring** and error handling

## Hardware

**Server:** Baremetal Windows 10 Pro
- **GPU:** AMD Radeon PRO W7600 (AMD AMF encoding support)
- **Optical Drives:** 7 total (6 DVD + 1 Blu-ray)
- **Network:** 10Gb/s fiber to NAS (10.0.0.0/24 network)
- **Storage:** SMB mount at `X:\` (\\10.0.0.1\media)

## Quick Start

### Prerequisites
- Windows 10 Pro
- MakeMKV installed (`C:\Program Files (x86)\MakeMKV\makemkvcon64.exe`)
- FFmpeg installed (`C:\ffmpeg\bin\ffmpeg.exe`)
- dd for Windows or ImgBurn for ISO creation
- Ansible control node with WinRM connectivity

### Deployment

```bash
# Clone this repository
git clone https://github.com/rockfreak101/win-media-ingestion.git
cd win-media-ingestion

# Update inventory with your server IP
nano ansible/inventory/hosts.yml

# Deploy optical drive monitoring
ansible-playbook ansible/playbooks/deploy-game-iso-backup.yml

# Deploy video encoding
ansible-playbook ansible/playbooks/deploy-existing-media-script.yml
```

### Verify Deployment

```bash
# Check scheduled tasks
ansible windows_servers -m win_shell -a "Get-ScheduledTask -TaskName '*Optical*' | Select-Object TaskName, State"

# Check logs
ansible windows_servers -m win_shell -a "Get-Content C:\Scripts\Logs\optical-monitor.log -Tail 20"
```

## Directory Structure

```
win-media-ingestion/
├── README.md                           # This file
├── scripts/                            # PowerShell scripts
│   ├── Watch-OpticalDrives-Games.ps1   # Optical drive monitoring with game ISO support
│   └── Process-VideoRips-Fixed.ps1     # AMD AMF encoding with directory preservation
├── ansible/                            # Ansible automation
│   ├── inventory/
│   │   └── hosts.yml                   # Windows server inventory
│   └── playbooks/
│       ├── deploy-game-iso-backup.yml  # Deploy optical monitoring
│       ├── deploy-existing-media-script.yml  # Deploy encoding automation
│       ├── setup-filebot-automation.yml      # FileBot integration
│       ├── mount-windows-smb-simple.yml      # SMB mount setup
│       └── configure-arr-watch-folders.yml   # *arr integration
└── docs/                               # Documentation
    ├── VIDEO-GAME-ISO-BACKUP-GUIDE.md  # Game ISO backup complete guide
    ├── MEDIA-INGESTION-SETUP.md        # Initial setup documentation
    ├── WINDOWS-PERFORMANCE-ANALYSIS.md # Performance tuning guide
    └── ...
```

## Workflows

### Video Game ISO Backup
1. Insert game disc into any drive
2. Script detects platform (PS2, Xbox360, etc.)
3. dd creates ISO: `C:\MediaProcessing\rips\games\<Platform>\<GameName>.iso`
4. Disc auto-ejects when complete
5. Ready for next disc

### DVD/Blu-ray Ripping
1. Insert video disc
2. MakeMKV extracts to: `C:\MediaProcessing\rips\video\movies\` or `tv\`
3. AMD encoding converts to AV1: `C:\MediaProcessing\Encoding\<type>\<name>\`
4. Encoded files transferred to NAS via SMB
5. Source files cleaned up after successful encoding

## Performance

- **Game ISO creation**: 10-15 min (DVD), 30-60 min (Blu-ray)
- **Video encoding**: 7.7x realtime (AMD AMF AV1)
- **Network throughput**: 1034 MB/s (10Gb fiber to NAS)
- **Concurrent operations**: 2 DVD + 1 Blu-ray + 1 CD + 1 Game ISO

## Documentation

Comprehensive guides available in `docs/`:
- [VIDEO-GAME-ISO-BACKUP-GUIDE.md](docs/VIDEO-GAME-ISO-BACKUP-GUIDE.md) - Complete game ISO backup documentation
- [MEDIA-INGESTION-SETUP.md](docs/MEDIA-INGESTION-SETUP.md) - Initial setup and configuration
- [RADARR-SONARR-CONFIGURATION-GUIDE.md](docs/RADARR-SONARR-CONFIGURATION-GUIDE.md) - *arr integration
- [WINDOWS-PERFORMANCE-ANALYSIS.md](docs/WINDOWS-PERFORMANCE-ANALYSIS.md) - Performance optimization

## Configuration

### Optical Drive Monitoring

Edit `scripts/Watch-OpticalDrives-Games.ps1` parameters:
```powershell
param(
    [int]$MaxDVDRips = 2,       # Concurrent DVD rips
    [int]$MaxBluRayRips = 1,    # Concurrent Blu-ray rips
    [int]$MaxCDRips = 1,        # Concurrent CD rips
    [int]$MaxGameRips = 1,      # Concurrent game ISO rips
    [string]$LocalRipBase = "C:\MediaProcessing\rips"
)
```

### Video Encoding

Edit `scripts/Process-VideoRips-Fixed.ps1` parameters:
```powershell
param(
    [string]$WatchPath = "C:\MediaProcessing\rips\video",
    [string]$EncodedBase = "C:\MediaProcessing\Encoding",
    [string]$FFmpegPath = "C:\ffmpeg\bin\ffmpeg.exe"
)
```

## Monitoring

### Logs
```powershell
# Optical monitoring log
Get-Content C:\Scripts\Logs\optical-monitor.log -Tail 50 -Wait

# Encoding log
Get-Content C:\Scripts\Logs\video-processing.log -Tail 50 -Wait

# Disc inventory
Get-Content C:\Scripts\Logs\disc-inventory.log
```

### Status
```powershell
# Check scheduled tasks
Get-ScheduledTask -TaskName "*Media*" | Select-Object TaskName, State, LastRunTime

# Check running processes
Get-Process | Where-Object {$_.Name -match "makemkv|ffmpeg|dd"}
```

## Troubleshooting

### Common Issues

**Duplicate disc detection:**
- Fixed in v1.1 - disc marked as processed immediately
- Check logs for "Detected ... in drive" appearing multiple times

**FFmpeg exit code -40:**
- Fixed - removed extra quotes in argument array
- Verify AMD GPU drivers are up to date

**ISO creation fails:**
- Ensure dd or ImgBurn is installed
- Check write permissions to `C:\MediaProcessing\rips\games\`

**MakeMKV can't find titles:**
- Game discs won't have video titles (expected)
- Verify disc is detected as VideoGame type first

## Integration

### Parent Repository
This repository is designed to be used as a git submodule in the [home_lab_media](https://github.com/rockfreak101/home_lab_media) infrastructure repository.

```bash
# In home_lab_media repo
git submodule add https://github.com/rockfreak101/win-media-ingestion.git windows-ingestion
git submodule update --init --recursive
```

### *arr Stack Integration
See [RADARR-SONARR-CONFIGURATION-GUIDE.md](docs/RADARR-SONARR-CONFIGURATION-GUIDE.md) for:
- Radarr/Sonarr watch folder configuration
- FileBot automation setup
- Quality profiles and naming schemes

## License

MIT License - See LICENSE file for details

## Author

Created and maintained by rockfreak101

## Support

For issues, questions, or contributions:
- Open an issue on GitHub
- Check documentation in `docs/` directory
- Review logs in `C:\Scripts\Logs\`
