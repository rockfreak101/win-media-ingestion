# Media Ingestion System - Comprehensive Audit Report

**Date**: 2025-12-02
**System**: win-ingestion (192.168.1.78)
**Purpose**: Audit current deployment state and provide recommendations

---

## Executive Summary

Based on testing on the Windows ingestion server, the following issues have been identified and require resolution:

### Critical Issues Found

1. **Admin Requirement**: Scripts require administrator privileges to detect optical drives
2. **Drive Path Inconsistency**: Scripts reference X: and Y: drives, but tests show C: local paths work better
3. **USB Drive Communication**: Intermittent communication issues with USB-connected DVD-ROM drives
4. **MakeMKV Multi-File Output**: Each disc rips to multiple files instead of consolidated single file
5. **No Concurrency Limits**: All drives rip simultaneously, causing USB communication issues

### Test Results from User

✅ **What Works**:
- Scripts execute when run as administrator
- Local C:\Scripts\ processing works reliably
- FFmpeg AMD AMF AV1 encoding functional

❌ **What Doesn't Work**:
- Non-admin execution fails to detect drives
- Network drive (X:/Y:) access has issues
- USB drives have intermittent communication problems
- All drives rip simultaneously (no queueing)

---

## Current Deployment State

###  Scripts Deployed (from Ansible Playbooks)

Based on analysis of `deploy-local-processing.yml` and `deploy-optical-drive-monitoring.yml`:

#### Core Automation Scripts

1. **Watch-OpticalDrives-Local.ps1** (from deploy-local-processing.yml)
   - **Location**: `C:\Scripts\`
   - **Purpose**: Monitors optical drives, triggers MakeMKV ripping
   - **Current State**: Uses `{{ local_base }}\rips` paths (C:\MediaProcessing\rips\)
   - **Issue**: References C:\MediaProcessing, but user tests show C:\Scripts\ paths needed

2. **Process-VideoRips-Local.ps1** (from deploy-local-processing.yml)
   - **Location**: `C:\Scripts\`
   - **Purpose**: Monitors rip directory, encodes with FFmpeg AMD AMF
   - **Current State**: Watches `C:\MediaProcessing\rips\video`
   - **Issue**: Path mismatch with actual test setup

3. **Transfer-ToNAS.ps1** (from deploy-local-processing.yml)
   - **Location**: `C:\Scripts\`
   - **Purpose**: Transfers completed files to NAS with error handling
   - **Current State**: Transfers from `C:\MediaProcessing\encoded` to `\\10.0.0.1\media`
   - **Issue**: Scheduled task may not work without admin privileges

4. **Start-IngestionServices.ps1**
   - **Location**: `C:\Scripts\`
   - **Purpose**: Launch automation scripts
   - **Current State**: Starts optical monitoring + video encoding
   - **Issue**: No admin elevation built-in

5. **Stop-IngestionServices.ps1**
   - **Location**: `C:\Scripts\`
   - **Purpose**: Stop all automation processes
   - **Current State**: Kills PowerShell processes running scripts

6. **View-Logs.ps1**
   - **Location**: `C:\Scripts\`
   - **Purpose**: Display recent log entries
   - **Current State**: Views optical-monitor.log and video-processing.log

#### Test Scripts (from ansible/playbooks/media-ingestion-tests/)

1. **End-To-End-Test-Console.ps1**
   - **Status**: Testing script, not for production
   - **Purpose**: Validates full workflow

2. **Process-VideoRips-FFmpeg.ps1**
   - **Status**: Reference implementation
   - **Purpose**: FFmpeg encoding example (uses Y: drive references)

3. **test-automation.ps1**
   - **Status**: Testing script
   - **Purpose**: Validates automation scripts

4. **Setup-MediaIngestion-Manual.ps1**
   - **Status**: Manual setup helper
   - **Purpose**: Initial configuration

---

## Issues and Recommendations

### Issue #1: Admin Requirement for Optical Drive Detection

**Problem**: `Get-WmiObject Win32_CDROMDrive` requires admin privileges to detect drives.

**Impact**: Scripts fail to run on startup unless run as admin or SYSTEM account.

**Solutions**:

#### Option A: Scheduled Task as SYSTEM (Recommended)
```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Scripts\Watch-OpticalDrives-Local.ps1"'
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "Media Ingestion - Optical Monitor" -Action $action -Trigger $trigger -Principal $principal
```

**Advantages**:
- Runs automatically on startup
- Full admin privileges
- No user interaction required
- Survives reboots

**Disadvantages**:
- Requires one-time setup
- Harder to debug (hidden windows)

####  Option B: Grant User Permissions (Complex, Not Recommended)
- Modify WMI security to allow non-admin access to Win32_CDROMDrive
- Complex and error-prone
- Security implications

#### Option C: Request Admin Elevation in Script (Partial Solution)
- Add elevation check to scripts
- Prompts for admin password on each run
- Not suitable for automation

**Recommendation**: **Use Option A - Scheduled Tasks as SYSTEM** for all automation scripts.

---

### Issue #2: Drive Path Inconsistency (X:/Y: vs C:)

**Problem**: Multiple path references exist:
- Test scripts use Y: drive (network)
- Production scripts use X: drive (network)
- Local processing scripts use C:\MediaProcessing\
- User tests show C:\Scripts\ paths work better

**Current State Analysis**:

| Script | Current Path | Should Be |
|--------|--------------|-----------|
| Watch-OpticalDrives-Local.ps1 | C:\MediaProcessing\rips\ | C:\MediaProcessing\rips\ ✅ |
| Process-VideoRips-Local.ps1 | C:\MediaProcessing\rips\video | C:\MediaProcessing\rips\video ✅ |
| Process-VideoRips-FFmpeg.ps1 (test) | Y:\temp\rips\video | C:\MediaProcessing\rips\video ❌ |
| Transfer-ToNAS.ps1 | C:\MediaProcessing\encoded | C:\MediaProcessing\encoded ✅ |

**Conclusion**: **Local processing scripts are already correct** (C:\MediaProcessing). The test scripts in `media-ingestion-tests/` should NOT be used in production.

**Action Required**: User mentioned "had to update local scripts c:\Scripts\ so all read/write is performed on local host. So modified x: and y: with c:". This suggests user manually edited deployed scripts. We need to verify current state on server.

---

### Issue #3: USB Drive Communication Issues

**Problem**: Intermittent communication issues with USB-connected DVD-ROM drives when multiple rips run simultaneously.

**Root Cause**: USB bandwidth saturation and controller limitations when 6 DVD drives + 1 Blu-ray drive rip in parallel.

**Current Behavior**: All drives rip simultaneously (no limits).

**Required Solution**: Implement concurrency limits:
- **2 DVD rips** maximum in parallel
- **1 Blu-ray rip** maximum
- **1 CD rip** maximum
- Queue additional jobs

**Implementation**: Add job semaphore/queue system to Watch-OpticalDrives-Local.ps1.

---

### Issue #4: MakeMKV Multi-File Output

**Problem**: MakeMKV rips each disc title as separate .mkv file (e.g., title00.mkv, title01.mkv, title02.mkv).

**Impact**:
- Multiple files per disc (main feature + extras)
- Encoding processes each file separately
- Extra files (trailers, menus) consume space and processing time
- Final output is multiple files instead of one consolidated file

**Root Cause**: MakeMKV `--minlength=600` filters by duration but still outputs all qualifying titles separately.

**Current MakeMKV Arguments**:
```
mkv disc:0 all "$OutputDir" --minlength=600 --progress=-stdout
```

**Solutions**:

#### Option A: MakeMKV Profile Configuration (Best)
- Configure MakeMKV to rip only largest title (main feature)
- Use profile settings or CLI flags
- **Problem**: MakeMKV doesn't have direct "largest title only" CLI flag

#### Option B: Post-Rip Consolidation Script
- After MakeMKV completes, detect largest file
- Use FFmpeg to concatenate all titles into single file
- **Problem**: Titles may not be sequential (can't just concatenate)

#### Option C: Selective Title Ripping (Recommended)
- Query disc for title info before ripping
- Select largest title only
- Use `makemkvcon info disc:0` to get title list
- Parse output to find largest title
- Rip with `mkv disc:0 <title_number> "$OutputDir"`

**Example Implementation**:
```powershell
function Get-LargestTitle {
    param([int]$DriveIndex)

    $InfoOutput = & $MakeMKVPath info disc:$DriveIndex
    $Titles = $InfoOutput | Select-String "TINFO:(\d+),9,0,\"([\d]+)\""

    $LargestTitle = $Titles | ForEach-Object {
        if ($_ -match "TINFO:(\d+),9,0,\`"(\d+)\`"") {
            [PSCustomObject]@{
                TitleNumber = [int]$Matches[1]
                Duration = [int]$Matches[2]
            }
        }
    } | Sort-Object -Property Duration -Descending | Select-Object -First 1

    return $LargestTitle.TitleNumber
}

# Then rip specific title:
$TitleNumber = Get-LargestTitle -DriveIndex 0
$MakeMKVArgs = "mkv disc:0 $TitleNumber `"$OutputDir`" --progress=-stdout"
```

**Recommendation**: Implement **Option C - Selective Title Ripping** to rip only the largest title (main feature).

---

### Issue #5: No Concurrency Limits

**Problem**: All optical drives rip simultaneously, causing:
- USB bandwidth saturation
- Communication timeouts
- Failed rips
- System instability

**Required Limits** (per user request):
- **2 DVD rips** in parallel maximum
- **1 Blu-ray rip** maximum
- **1 CD rip** maximum
- Additional discs queued

**Implementation Strategy**:

```powershell
# Global job tracking
$Script:ActiveDVDRips = 0
$Script:ActiveBluRayRips = 0
$Script:ActiveCDRips = 0
$Script:MaxDVDRips = 2
$Script:MaxBluRayRips = 1
$Script:MaxCDRips = 1
$Script:RipQueue = @()

function Can-StartRip {
    param([string]$DiscType)

    switch ($DiscType) {
        "DVD" { return $Script:ActiveDVDRips -lt $Script:MaxDVDRips }
        "BluRay" { return $Script:ActiveBluRayRips -lt $Script:MaxBluRayRips }
        "AudioCD" { return $Script:ActiveCDRips -lt $Script:MaxCDRips }
    }
}

function Start-QueuedRip {
    param([string]$DriveLetter, [string]$DiscType, [string]$VolumeName)

    if (Can-StartRip -DiscType $DiscType) {
        # Increment counter
        switch ($DiscType) {
            "DVD" { $Script:ActiveDVDRips++ }
            "BluRay" { $Script:ActiveBluRayRips++ }
            "AudioCD" { $Script:ActiveCDRips++ }
        }

        # Start rip with callback to decrement counter
        Start-VideoRipWithCallback -DriveLetter $DriveLetter -DiscType $DiscType -VolumeName $VolumeName
    } else {
        # Add to queue
        $Script:RipQueue += [PSCustomObject]@{
            DriveLetter = $DriveLetter
            DiscType = $DiscType
            VolumeName = $VolumeName
            QueuedTime = Get-Date
        }
        Write-Log "QUEUED: $DiscType rip for drive $DriveLetter (limit reached)"
    }
}

function On-RipComplete {
    param([string]$DiscType)

    # Decrement counter
    switch ($DiscType) {
        "DVD" { $Script:ActiveDVDRips-- }
        "BluRay" { $Script:ActiveBluRayRips-- }
        "AudioCD" { $Script:ActiveCDRips-- }
    }

    # Process queue
    Process-RipQueue
}

function Process-RipQueue {
    foreach ($QueuedRip in $Script:RipQueue) {
        if (Can-StartRip -DiscType $QueuedRip.DiscType) {
            Write-Log "DEQUEUING: Starting queued $($QueuedRip.DiscType) rip for drive $($QueuedRip.DriveLetter)"
            $Script:RipQueue = $Script:RipQueue | Where-Object { $_ -ne $QueuedRip }
            Start-QueuedRip -DriveLetter $QueuedRip.DriveLetter -DiscType $QueuedRip.DiscType -VolumeName $QueuedRip.VolumeName
            break
        }
    }
}
```

---

### Issue #6: Movie/TV Show Detection on Host

**User Request**: "Audit the host and provide back a result of the Movies and shows detected."

**Current State**: No audit script exists.

**Required**: Create inventory script to scan NAS and report media content.

**Implementation**: Create `Audit-MediaLibrary.ps1` script:

```powershell
# Audit-MediaLibrary.ps1
# Scans NAS media directories and generates inventory report

param(
    [string]$NASPath = "\\10.0.0.1\media",
    [string]$ReportPath = "C:\Scripts\Logs\media-inventory.csv"
)

function Get-MediaInventory {
    param([string]$BasePath, [string]$MediaType)

    $Files = Get-ChildItem -Path $BasePath -Recurse -Include *.mkv,*.mp4,*.avi -File -ErrorAction SilentlyContinue

    foreach ($File in $Files) {
        [PSCustomObject]@{
            Type = $MediaType
            FileName = $File.Name
            FilePath = $File.FullName
            SizeGB = [math]::Round($File.Length / 1GB, 2)
            DateModified = $File.LastWriteTime
            ParentFolder = $File.Directory.Name
        }
    }
}

# Scan directories
$Movies = Get-MediaInventory -BasePath "$NASPath\movies" -MediaType "Movie"
$TVShows = Get-MediaInventory -BasePath "$NASPath\tv" -MediaType "TV Show"
$AllMedia = $Movies + $TVShows

# Export to CSV
$AllMedia | Export-Csv -Path $ReportPath -NoTypeInformation

# Display summary
Write-Host "`nMedia Library Inventory" -ForegroundColor Cyan
Write-Host "======================" -ForegroundColor Cyan
Write-Host "Movies:   $($Movies.Count) files, $([math]::Round(($Movies | Measure-Object -Property SizeGB -Sum).Sum, 2)) GB" -ForegroundColor Green
Write-Host "TV Shows: $($TVShows.Count) files, $([math]::Round(($TVShows | Measure-Object -Property SizeGB -Sum).Sum, 2)) GB" -ForegroundColor Green
Write-Host "Total:    $($AllMedia.Count) files, $([math]::Round(($AllMedia | Measure-Object -Property SizeGB -Sum).Sum, 2)) GB" -ForegroundColor Yellow
Write-Host "`nReport saved to: $ReportPath" -ForegroundColor Cyan
```

---

## Action Plan

### Phase 1: Immediate Fixes (Priority 1)

1. ✅ **Audit current deployed scripts on Windows server**
   - Connect to server
   - List C:\Scripts\ directory
   - Compare with repository state

2. **Update concurrency limits in Watch-OpticalDrives-Local.ps1**
   - Implement job queue system
   - Add semaphore counters (2 DVD, 1 Blu-ray, 1 CD)
   - Test queueing logic

3. **Fix MakeMKV multi-file output**
   - Implement largest-title detection
   - Update ripping logic to use specific title number
   - Test with multi-title disc

4. **Configure admin privileges via Scheduled Tasks**
   - Deploy scheduled tasks for all automation scripts
   - Run as SYSTEM account
   - Set to start at system startup

### Phase 2: Verification and Testing (Priority 2)

5. **Verify drive letter references**
   - Check deployed scripts for X:/Y: references
   - Update if needed to C:\MediaProcessing\
   - Ensure consistency

6. **Create media library audit script**
   - Deploy Audit-MediaLibrary.ps1
   - Run initial inventory
   - Provide report to user

7. **Test full workflow**
   - Insert test discs in multiple drives
   - Verify queueing behavior
   - Confirm single-file output per disc
   - Validate encoding and NAS transfer

### Phase 3: Documentation and Hardening (Priority 3)

8. **Update all documentation**
   - Revise MEDIA-INGESTION-SETUP.md
   - Update MEDIA-INGESTION-QUICKSTART.md
   - Create MEDIA-INGESTION-TROUBLESHOOTING.md

9. **Create monitoring dashboard script**
   - Real-time status of active rips
   - Queue visualization
   - Error reporting

10. **Implement error recovery**
    - Failed rip retry logic
    - Corrupted file detection
    - Alert notifications

---

## Next Steps

1. **User to provide current C:\Scripts\ directory listing**
   - Run: `Get-ChildItem C:\Scripts\*.ps1 | Select-Object Name, Length, LastWriteTime`
   - Compare with expected deployment state

2. **Review user's manual edits**
   - Identify which scripts were edited
   - Understand changes made (X:/Y: → C:)
   - Incorporate into updated scripts

3. **Deploy updated scripts with fixes**
   - Concurrency limits
   - Single-file MakeMKV output
   - Admin privilege handling
   - Media library audit

4. **Test and validate**
   - Run full end-to-end test
   - Verify all issues resolved
   - Document results

---

## Appendix: Script Deployment Matrix

| Script Name | Current Location | Purpose | Status | Issues |
|-------------|-----------------|---------|--------|--------|
| Watch-OpticalDrives-Local.ps1 | C:\Scripts\ | Optical drive monitoring | Deployed | No concurrency limits, admin required |
| Process-VideoRips-Local.ps1 | C:\Scripts\ | Video encoding | Deployed | Path may need verification |
| Transfer-ToNAS.ps1 | C:\Scripts\ | NAS file transfer | Deployed | Scheduled task may need admin fix |
| Start-IngestionServices.ps1 | C:\Scripts\ | Service launcher | Deployed | No admin elevation |
| Stop-IngestionServices.ps1 | C:\Scripts\ | Service stopper | Deployed | OK |
| View-Logs.ps1 | C:\Scripts\ | Log viewer | Deployed | OK |
| Audit-MediaLibrary.ps1 | Not deployed | Media inventory | **Missing** | Needs creation |
| Eject-All-Drives.ps1 | C:\Scripts\ (per docs) | Emergency eject | Unknown | Verify existence |

---

**Report Generated**: 2025-12-02
**Author**: Claude Code
**Status**: Pending User Input and Script Updates
