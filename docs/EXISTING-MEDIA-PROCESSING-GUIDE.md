# Existing Media Processing Guide

**Date**: 2025-12-05
**Purpose**: Process existing media library with AV1 encoding
**Status**: Ready for deployment

---

## Overview

This guide covers processing your existing media library from `/tank/media/media/More_Movies` and `/tank/media/media/TV` with your preferred AV1 encoding settings.

**Key Features**:
- ✅ Preserves directory structure (movie/show name folders)
- ✅ Uses your preferred AV1 settings (CQP 26/28, AMD AMF)
- ✅ Skips already-encoded files
- ✅ Comprehensive logging and progress tracking
- ✅ Dry-run mode for testing

---

## Your AV1 Encoding Settings

Based on your current configuration, here are your encoding preferences:

```powershell
# Video codec: AMD AMF AV1 hardware acceleration
-c:v av1_amf
-quality balanced           # Balanced quality/speed
-rc cqp                     # Constant Quantization Parameter
-qp_i 26                    # I-frame quality (26 = high quality)
-qp_p 28                    # P-frame quality (28 = very good)
-usage transcoding          # Optimize for transcoding
-pix_fmt yuv420p           # Maximum compatibility

# Audio/Subtitles: Copy all streams (no re-encoding)
-c:a copy
-c:s copy
```

**Quality Assessment**:
- **CQP 26/28**: High to very good quality
- **File size reduction**: Typically 60-80% compared to original
- **Encoding speed**: ~7.7x realtime on AMD Radeon PRO W7600

**Comparison Table**:

| Setting | Your Choice | Alternative | Impact |
|---------|-------------|-------------|--------|
| QP I-frames | 26 | 22 (higher quality) | Larger files, better quality |
| QP P-frames | 28 | 24 (higher quality) | Larger files, better quality |
| Quality | balanced | quality (slower) | Faster encoding, slight quality loss |
| Usage | transcoding | lowlatency | Better for batch encoding |

**Recommendation**: Your settings are excellent for archival quality with good compression.

---

## Solution Components

### 1. PowerShell Processing Script

**Location**: `files/Process-Existing-Media.ps1`

**What it does**:
- Scans source directories for video files
- Preserves folder structure (e.g., `More_Movies/The Matrix/` → `Movies_Encoded/The Matrix/`)
- Encodes with your AV1 settings
- Logs progress to CSV
- Skips already-encoded files
- Supports dry-run mode

**Usage**:
```powershell
# Run from Windows server (win-ingest-01)

# Dry run (test without encoding)
powershell -File C:\Scripts\Process-Existing-Media.ps1 -WhatIf

# Process both movies and TV
powershell -File C:\Scripts\Process-Existing-Media.ps1

# Process only movies
powershell -File C:\Scripts\Process-Existing-Media.ps1 -SkipTV

# Process only TV shows
powershell -File C:\Scripts\Process-Existing-Media.ps1 -SkipMovies
```

---

### 2. Docker CIFS Mount Configuration

**Your Question**: "Why wouldn't I add the CIFS mount on the docker container(s) standard source libraries?"

**Answer**: You're absolutely right! Direct CIFS mounts are the better approach.

**Location**: `DOCKER-CIFS-MOUNT-GUIDE.md` (complete guide)

**Benefits**:
- ✅ Simpler architecture (no intermediate Linux mount)
- ✅ Better isolation (container-specific)
- ✅ Self-contained in docker-compose.yml
- ✅ Easier troubleshooting

**Quick Implementation**:

Add to `docker-compose.yml`:

```yaml
services:
  radarr:
    volumes:
      - type: volume
        source: windows_movies
        target: /incoming-windows
        read_only: false

volumes:
  windows_movies:
    driver: local
    driver_opts:
      type: cifs
      o: "addr=192.168.1.80,username=jluczani,password=${WIN_PASSWORD},uid=1000,gid=1000"
      device: "//192.168.1.80/MediaProcessing/encoded/movies"
```

Create `.env` file:
```bash
WIN_PASSWORD=your_password
PUID=1000
PGID=1000
```

See `DOCKER-CIFS-MOUNT-GUIDE.md` for complete configuration.

---

### 3. *arr Quality Profiles

**Location**: `ansible/playbooks/configure-arr-quality-profiles.yml`

**What it does**:
- Creates "HD for Re-encoding (AV1)" quality profile
- Accepts 720p and 1080p content
- Rejects SD and 4K (you're encoding to 1080p AV1)
- Upgrade target: Bluray-1080p

**Why this works**:
- Higher quality source → better AV1 encode
- 1080p max makes sense for AV1 storage efficiency
- Accepts Remux for best possible encodes

**Run when media-server is online**:
```bash
cd ~/git/jlucznai/home_lab_media/ansible
ansible-playbook playbooks/configure-arr-quality-profiles.yml
```

---

## Deployment Plan

### Phase 1: Script Deployment (Windows Server)

**Prerequisites**:
1. Windows server (win-ingest-01) is online
2. NFS share accessible via UNC path `\\10.0.0.1\media`
3. FFmpeg installed at `C:\ffmpeg\bin\ffmpeg.exe`
4. AMD GPU drivers installed

**Steps**:

1. **Deploy script to Windows server**:
   ```bash
   # From Linux host
   cd ~/git/jlucznai/home_lab_media/ansible

   # Create playbook to deploy script
   ansible-playbook playbooks/deploy-existing-media-script.yml
   ```

2. **Verify script on Windows**:
   ```powershell
   # Check script exists
   Test-Path C:\Scripts\Process-Existing-Media.ps1

   # View help
   Get-Help C:\Scripts\Process-Existing-Media.ps1
   ```

3. **Test with dry run**:
   ```powershell
   # Dry run (no actual encoding)
   powershell -File C:\Scripts\Process-Existing-Media.ps1 -WhatIf
   ```

---

### Phase 2: Stop Watch Drives (Critical!)

**IMPORTANT**: You must stop the watch drive services before running the batch processing script to avoid conflicts.

**On Windows server**:
```powershell
# Check running tasks
Get-ScheduledTask -TaskName "Media Ingestion*" | Format-Table

# Stop optical monitoring
Stop-ScheduledTask -TaskName "Media Ingestion - Optical Monitor (Fixed)"

# Stop video encoding
Stop-ScheduledTask -TaskName "Media Ingestion - Video Encoding (Fixed)"

# Verify they're stopped
Get-ScheduledTask -TaskName "Media Ingestion*" | Select Name, State
```

**Why this is important**:
- Prevents dual encoding of same files
- Avoids resource contention (GPU, CPU, disk I/O)
- Ensures consistent processing

---

### Phase 3: Run Batch Processing

**Recommended workflow**:

1. **Process a test batch first** (dry run):
   ```powershell
   powershell -File C:\Scripts\Process-Existing-Media.ps1 -WhatIf
   ```

2. **Review dry run output**:
   - Check detected files
   - Verify directory structure
   - Confirm paths look correct

3. **Process a single category** (movies only):
   ```powershell
   powershell -File C:\Scripts\Process-Existing-Media.ps1 -SkipTV
   ```

4. **Monitor progress**:
   ```powershell
   # Watch log in real-time
   Get-Content C:\Scripts\Logs\process-existing-media.log -Tail 50 -Wait

   # View progress CSV
   Import-Csv C:\Scripts\Logs\process-existing-media-progress.csv | Format-Table
   ```

5. **After movies complete, process TV**:
   ```powershell
   powershell -File C:\Scripts\Process-Existing-Media.ps1 -SkipMovies
   ```

---

### Phase 4: Update *arr Profiles (When media-server is online)

**Deploy quality profiles**:
```bash
cd ~/git/jlucznai/home_lab_media/ansible
ansible-playbook playbooks/configure-arr-quality-profiles.yml
```

**Manual configuration** (in Radarr/Sonarr web UI):
1. Navigate to Settings → Profiles
2. Find "HD for Re-encoding (AV1)" profile
3. Set as default for new content

---

### Phase 5: Configure Docker CIFS Mounts

**Follow**: `DOCKER-CIFS-MOUNT-GUIDE.md`

**Quick steps**:
1. Create `.env` file with Windows credentials
2. Update `docker-compose.yml` with CIFS volume definitions
3. Restart services: `docker-compose up -d`
4. Verify mounts: `docker exec radarr ls /incoming-windows`

---

## Directory Structure

### Before Processing

```
/tank/media/media/
├── More_Movies/
│   ├── The Matrix/
│   │   └── movie.mkv
│   ├── Akira/
│   │   └── akira.mkv
│   └── ...
└── TV/
    ├── Breaking Bad/
    │   ├── Season 01/
    │   │   ├── episode01.mkv
    │   │   └── episode02.mkv
    │   └── ...
    └── ...
```

### After Processing

```
/tank/media/media/
├── Movies_Encoded/
│   ├── The Matrix/
│   │   └── movie.mkv (AV1, ~60% smaller)
│   ├── Akira/
│   │   └── akira.mkv (AV1, ~60% smaller)
│   └── ...
└── TV_Encoded/
    ├── Breaking Bad/
    │   ├── Season 01/
    │   │   ├── episode01.mkv (AV1, ~60% smaller)
    │   │   └── episode02.mkv (AV1, ~60% smaller)
    │   └── ...
    └── ...
```

**Key Points**:
- ✅ Folder structure preserved exactly
- ✅ Original files untouched (separate destination)
- ✅ Encoded files have same names
- ✅ Can compare side-by-side

---

## Performance Expectations

### Based on Current Hardware

**Windows Server** (win-ingest-01):
- CPU: Dual Intel Xeon E5-2630L v3 (16 cores, 32 threads)
- GPU: AMD Radeon PRO W7600 (AV1 hardware encoding)
- Storage: Intel NVMe SSD (fast I/O)
- Network: 10 Gbps available

**Encoding Speed** (actual tested):
- ~7.7x realtime on AMD GPU
- 90-minute movie: ~12 minutes to encode
- 1 hour TV episode: ~8 minutes to encode

**Throughput Estimates**:

| Content Type | Source Size | Encoded Size | Time per File | Files per Hour | Files per Day (24h) |
|--------------|-------------|--------------|---------------|----------------|---------------------|
| DVD (4GB) | 4 GB | 1.5 GB (~60%) | 10 min | 6 | 144 |
| Blu-ray (20GB) | 20 GB | 7 GB (~65%) | 30 min | 2 | 48 |
| TV Episode (2GB) | 2 GB | 0.8 GB (~60%) | 5 min | 12 | 288 |

**Example Workload**:
- 100 movies (mixed DVD/Blu-ray, avg 10GB): ~25 hours
- 500 TV episodes (avg 2GB): ~40 hours
- **Total**: ~65 hours (~2.7 days) of continuous encoding

**Optimization**:
- Process movies and TV separately (monitor progress)
- Run overnight/weekends
- Monitor GPU temperature (should stay cool with workstation card)

---

## Monitoring and Logs

### Log Files

```powershell
# Main processing log
C:\Scripts\Logs\process-existing-media.log

# Progress CSV (importable to Excel)
C:\Scripts\Logs\process-existing-media-progress.csv

# FFmpeg error details
C:\Scripts\Logs\ffmpeg-stderr-temp.log
```

### Real-Time Monitoring

```powershell
# Watch main log
Get-Content C:\Scripts\Logs\process-existing-media.log -Tail 50 -Wait

# View progress CSV
Import-Csv C:\Scripts\Logs\process-existing-media-progress.csv | Format-Table

# Check GPU usage
# Open Task Manager → Performance → GPU
```

### Progress CSV Fields

| Field | Description |
|-------|-------------|
| Timestamp | When encoding completed |
| MediaName | File name |
| InputFile | Source file path |
| OutputFile | Encoded file path |
| InputSizeGB | Source file size |
| OutputSizeGB | Encoded file size |
| ReductionPercent | Space saved (%) |
| DurationMinutes | Encoding time |
| Status | Success/Failed |

**Import to Excel**:
```powershell
# Open in Excel
Invoke-Item C:\Scripts\Logs\process-existing-media-progress.csv
```

---

## Troubleshooting

### Issue: Script Can't Find FFmpeg

**Error**: `FFmpeg not found at C:\ffmpeg\bin\ffmpeg.exe`

**Fix**:
```powershell
# Check FFmpeg location
where.exe ffmpeg

# Update script path parameter
powershell -File C:\Scripts\Process-Existing-Media.ps1 -FFmpegPath "C:\path\to\ffmpeg.exe"
```

---

### Issue: NFS Mount Not Accessible

**Error**: `NAS not accessible at \\10.0.0.1\media`

**Fix**:
```powershell
# Check network connectivity
Test-NetConnection -ComputerName 10.0.0.1 -Port 2049

# Verify UNC path access
Test-Path "\\10.0.0.1\media"

# List contents
Get-ChildItem "\\10.0.0.1\media"

# If authentication needed, map temporarily
net use \\10.0.0.1\media /user:jluczani
```

---

### Issue: Encoding Fails

**Error**: `Encoding failed with exit code: 1`

**Check**:
```powershell
# View FFmpeg error log
Get-Content C:\Scripts\Logs\ffmpeg-stderr-temp.log -Tail 50

# Common causes:
# - Corrupted source file
# - Insufficient disk space
# - AMD GPU driver issue
```

**Test encoding manually**:
```powershell
C:\ffmpeg\bin\ffmpeg.exe -i "X:\More_Movies\TestMovie\movie.mkv" -c:v av1_amf -quality balanced -rc cqp -qp_i 26 -qp_p 28 -c:a copy -c:s copy "C:\temp\test.mkv"
```

---

### Issue: Already-Encoded Files Re-Processed

**Symptom**: Script re-encodes files that already exist in destination

**Cause**: Output file is < 100MB or doesn't exist

**Fix**: Script automatically skips files > 100MB in destination. Check log for "SKIPPED: Already encoded" messages.

---

### Issue: Disk Space Running Low

**Monitor disk space**:
```powershell
# Check SSD space (encoded output)
Get-PSDrive C

# Check NFS space (final destination)
Get-PSDrive X
```

**Free up space**:
- Delete temporary files: `C:\MediaProcessing\rips\`
- Clean up failed transfers: `C:\MediaProcessing\failed-transfers\`

---

## Restart Watch Drives After Completion

**When batch processing is complete**, restart the watch drive services:

```powershell
# Start optical monitoring
Start-ScheduledTask -TaskName "Media Ingestion - Optical Monitor (Fixed)"

# Start video encoding
Start-ScheduledTask -TaskName "Media Ingestion - Video Encoding (Fixed)"

# Verify they're running
Get-ScheduledTask -TaskName "Media Ingestion*" | Select Name, State
```

---

## Summary

### What You Have Now

1. ✅ **PowerShell script** to process existing media with your AV1 settings
2. ✅ **Directory structure preservation** (movie/show name folders)
3. ✅ **Direct CIFS mount guide** for docker containers (better architecture)
4. ✅ **Quality profile configuration** for *arr apps
5. ✅ **Comprehensive monitoring** and progress tracking

### Deployment Checklist

- [ ] Deploy `Process-Existing-Media.ps1` to Windows server
- [ ] Stop watch drive scheduled tasks
- [ ] Run dry-run test (`-WhatIf`)
- [ ] Process movies (`-SkipTV`)
- [ ] Monitor progress and logs
- [ ] Process TV shows (`-SkipMovies`)
- [ ] Wait for media-server to come online
- [ ] Configure docker-compose.yml with CIFS mounts
- [ ] Deploy *arr quality profiles
- [ ] Restart watch drive tasks
- [ ] Verify end-to-end workflow

### Next Steps

1. **Now**: Review this guide and `Process-Existing-Media.ps1`
2. **Next**: Deploy script to Windows server and run dry-run
3. **Then**: Process existing media (movies first, then TV)
4. **Later**: When media-server is online, configure CIFS mounts and *arr profiles

---

## Reference Files

- **Processing Script**: `files/Process-Existing-Media.ps1`
- **CIFS Mount Guide**: `DOCKER-CIFS-MOUNT-GUIDE.md`
- **Quality Profile Playbook**: `ansible/playbooks/configure-arr-quality-profiles.yml`
- **Current Encoding Settings**: `ansible/playbooks/deploy-local-processing.yml` (lines 200-214)

---

**Last Updated**: 2025-12-05
**Status**: Ready for deployment
**Estimated Time**: 2-3 days for full library processing (depends on size)
