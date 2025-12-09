# Media Ingestion VM - Test Summary

## Status: Ready for End-to-End Testing

### Infrastructure Setup Complete ✓

**VM Details:**
- **Hostname**: win-11-iot (media-ingestion)
- **IP Address**: 192.168.1.78
- **OS**: Windows 11 IoT Enterprise LTSC
- **GPU**: AMD Radeon PRO W7600 (Navi 33) - PCIe Passthrough
- **Storage**: Y: drive mounted to \\192.168.1.116\media

**Software Installed:**
- ✓ MakeMKV (Blu-ray/DVD ripping)
- ✓ HandBrake GUI (manual encoding)
- ✓ HandBrakeCLI 1.10.2 (command-line encoding)
- ✓ FFmpeg 8.0.1 with AMD AMF support (hardware encoding)
- ✓ PowerShell automation scripts

### Hardware Encoding Status ✓

**HandBrake VCE**: ❌ FAILED
- HandBrake detects AMD VCE encoder ("vcn: is available")
- Encoding initialization succeeds
- **Encoding fails immediately at 0.00%**
- Tested both vce_av1 and vce_h264 - both fail
- Root cause: HandBrake VCE implementation bug with Navi 33 in VM environment

**FFmpeg AMD AMF**: ✅ SUCCESS
- H.264 AMF: Working at 5.31x realtime speed
- **AV1 AMF: Working at 7.71x realtime speed** (production encoder)
- Verified with 10-second test clips
- Full hardware acceleration confirmed

**Encoding Configuration:**
```
Encoder: av1_amf (AMD AMF AV1)
Quality Mode: CQP (Constant Quality)
I-frame Quality: 26 (very good)
P-frame Quality: 28
Usage Profile: transcoding
Speed: balanced
```

### Deployed Scripts

**Location**: `C:\Scripts\` on media-ingestion VM

1. **End-To-End-Test.ps1** (Console Version)
   - Comprehensive workflow test
   - Uses Y: drive (mounted SMB share)
   - Tests: mount → copy → encode → cleanup
   - **Run from Windows console**
   - Expected duration: ~12 minutes for 90-minute movie

2. **Process-VideoRips.ps1** (Production Automation)
   - Monitors: `Y:\temp\rips\video`
   - Encodes with FFmpeg AMD AMF AV1
   - Moves to: `Y:\movies` or `Y:\tv` (auto-detects)
   - Cleans up source files after successful encode
   - Logs to: `C:\Scripts\Logs\video-processing.log`

3. **Watch-OpticalDrives.ps1** (Optical Drive Monitor)
   - Monitors drives: D, E, F, G, H, J (DVD), I (Blu-ray)
   - Auto-rips inserted discs with MakeMKV
   - Saves to: `Y:\temp\rips\video`

4. **Mount-YDrive.ps1** (SMB Mount Helper)
   - Mounts \\192.168.1.116\media as Y:
   - Stores credentials securely
   - Persistent mount across reboots

5. **Start-IngestionServices.ps1** (Service Launcher)
   - Starts both monitoring scripts
   - Runs in background
   - Full automation stack

### Test File Ready

**Location**: `C:\temp\test-input.mp4`
- **Source**: Split-Second (1992) movie
- **Size**: 2.0 GB
- **Format**: HDTV-1080p
- **Duration**: ~90 minutes (estimated)

### WinRM/Ansible Limitations Discovered

**Issue**: Windows "double hop" authentication prevents file operations on network shares via WinRM.

**What Works via Ansible/WinRM:**
- ✓ Local file operations (C:\ drive)
- ✓ SMB authentication (`net use` command)
- ✓ Directory creation on UNC paths
- ✓ Software installation
- ✓ Service management

**What Fails via Ansible/WinRM:**
- ❌ File copy to/from UNC paths
- ❌ File operations on mapped network drives
- ❌ Running scripts that access network shares

**Workaround**: Run scripts from Windows console where Y: drive is already mounted and accessible.

## Next Steps

### 1. Run End-to-End Test from Windows Console

**Steps:**
1. Log into media-ingestion VM console (Proxmox VE console or RDP)
2. Verify Y: drive is mounted: `Test-Path Y:\`
3. Open PowerShell as Administrator
4. Run test: `C:\Scripts\End-To-End-Test.ps1`
5. Monitor progress (~12 minutes)

**Expected Output:**
- ✓ Y: drive accessible
- ✓ Directories created
- ✓ 2GB test file copied to `Y:\temp\rips\video\Test-E2E.mp4`
- ✓ FFmpeg encoding with AMD AMF
- ✓ Output file: `Y:\movies\Test-E2E.mkv`
- ✓ Compression metrics and speed reported
- ✓ Source file cleaned up

**Log File**: `C:\Scripts\Logs\end-to-end-test.log`

### 2. Verify Output File

After test completes:
1. Check output file exists: `Y:\movies\Test-E2E.mkv`
2. Verify file size (should be significantly smaller than 2GB)
3. Test playback to verify quality
4. Compare input vs output size and quality

### 3. Start Production Automation

Once test succeeds:
```powershell
# Start automated monitoring
C:\Scripts\Process-VideoRips.ps1

# Or start full automation stack
C:\Scripts\Start-IngestionServices.ps1
```

### 4. Test Optical Drive Automation

1. Insert a disc into one of the drives (D-J for DVD, I for Blu-ray)
2. Verify MakeMKV auto-rips to `Y:\temp\rips\video`
3. Verify automation picks up rip and encodes
4. Check final output in `Y:\movies` or `Y:\tv`

## Performance Expectations

Based on FFmpeg test results:

**Encoding Speed**: ~7.7x realtime for AV1
- 90-minute movie: ~12 minutes encoding time
- 2-hour movie: ~15-16 minutes encoding time

**Compression**: Expected 40-60% size reduction
- Input: 2.0 GB
- Output: ~0.8-1.2 GB (estimated for AV1)

**Quality**: "Very good" (CQP 26/28)
- Excellent for streaming and archival
- Visually transparent for most content
- Good balance between quality and file size

## Optical Drive Configuration

**DVD Drives**: D, E, F, G, H, J (6 drives)
**Blu-ray Drive**: I (1 drive)

Total: 7 optical drives ready for automated ripping

## Documentation

**Reference Scripts**: `ansible/playbooks/media-ingestion-tests/`
- End-To-End-Test-Console.ps1
- Process-VideoRips-FFmpeg.ps1
- test-ffmpeg-amf.cmd
- test-automation.ps1

**Setup Guide**: `MEDIA-INGESTION-SETUP.md`
**Playbook**: `ansible/playbooks/deploy-media-ingestion.yml`

## Troubleshooting

### Y: Drive Not Accessible
```powershell
# Remount Y: drive
C:\Scripts\Mount-YDrive.ps1

# Or manually
net use Y: \\192.168.1.116\media /user:jluczani new1-Sys
```

### FFmpeg Not Found
```powershell
# Verify installation
Test-Path C:\ffmpeg\bin\ffmpeg.exe

# Reinstall if needed
C:\Scripts\Install-FFmpeg.ps1
```

### Encoding Fails
```powershell
# Check FFmpeg log
type C:\Scripts\Logs\video-processing.log

# Test hardware encoder
C:\Scripts\test-ffmpeg-amf.cmd
```

### Permission Issues
- Ensure scripts run as Administrator
- Verify Y: drive has read/write permissions
- Check SMB credentials are correct

## Success Criteria

End-to-end test passes when:
- ✓ All 6 test steps complete successfully
- ✓ Output file exists and is playable
- ✓ File size reduced by 40-60%
- ✓ Encoding completes in ~12 minutes
- ✓ No errors in log file
- ✓ Source file cleaned up automatically

---

**Status**: All prerequisites met, ready for console testing.
**Last Updated**: 2025-11-25
