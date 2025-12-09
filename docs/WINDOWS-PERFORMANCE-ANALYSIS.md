## Windows Server Performance Analysis and Optimization

**Server**: win-ingest-01 (192.168.1.80)
**Date**: 2025-12-03
**Current Status**: High-performance configuration, running well

---

## Hardware Summary

### CPU: Dual Intel Xeon E5-2630L v3
- **Model**: Intel Xeon E5-2630L v3 @ 1.80GHz (x2)
- **Total Cores**: 16 physical cores (8 per CPU)
- **Total Threads**: 32 logical processors (16 per CPU)
- **Base Clock**: 1.8 GHz
- **Current Load**: 1% (very low, excellent)
- **Architecture**: Server-grade dual-socket Xeon

**Rating**: ✅ **Excellent** - Professional server CPU with plenty of cores for parallel encoding

---

### GPU: AMD Radeon PRO W7600
- **Model**: AMD Radeon PRO W7600 (Professional workstation card)
- **VRAM**: 4 GB
- **Driver**: 32.0.22029.1019
- **Status**: OK
- **Hardware Encoding**: AV1, H.264, HEVC support via AMD AMF

**Rating**: ✅ **Excellent** - Professional GPU with hardware encoding acceleration

---

### Memory: 32 GB DDR3/DDR4
- **Total**: 31.91 GB
- **Used**: 5.87 GB (18.4%)
- **Free**: 26.04 GB (81.6%)
- **Pagefile**: 5120 MB allocated, barely used (1 MB peak)

**Rating**: ✅ **Excellent** - Plenty of RAM for media processing

---

### Storage: Intel NVMe SSD
- **Model**: Intel SSDPEKKF512G8L
- **Type**: NVMe SSD (fastest consumer interface)
- **Capacity**: 512 GB (476.31 GB formatted)
- **Used**: 270.21 GB (56.7%)
- **Free**: 206.11 GB (43.3%)
- **Health**: Healthy
- **Bus**: NVMe (PCIe)

**Rating**: ✅ **Excellent** - Enterprise-grade NVMe SSD for fast I/O

---

### Network: Dual Network Adapters
**Adapter 1**: Ethernet
- **Speed**: 1 Gbps
- **Status**: Up
- **Usage**: Primary network connection

**Adapter 2**: Slot06 x16 Port 1 (10GbE)
- **Speed**: 10 Gbps
- **Status**: Up
- **RSS**: Enabled (8 queues)
- **Offloading**: TCP/UDP checksum offload enabled (Rx & Tx)

**Rating**: ✅ **Excellent** - 10 Gbps network available for high-speed transfers

---

## Power Configuration

### Active Power Plan: ChrisTitus - Ultimate Power Plan
**Status**: ✅ **Optimized for Performance**

This is a custom high-performance power plan with aggressive settings:

#### Key Settings (On AC Power):
- **Processor Min State**: 100% (always at full power)
- **Processor Max State**: 100% (no throttling)
- **Hard Disk**: Never turn off (0 seconds)
- **Sleep**: Never (0 seconds)
- **Hibernate**: Never (0 seconds)
- **Display**: Turn off after 15 minutes (900s)
- **USB Selective Suspend**: Enabled
- **PCI Express Link State**: Off (no power saving)
- **Wireless Adapter**: Maximum Performance
- **Video Playback**: Performance bias

**Comparison to Standard Plans**:
- ✅ Better than "Balanced" (balances power/performance)
- ✅ Better than "High Performance" (allows some throttling)
- ✅ Similar to "Ultimate Performance" (Windows Server exclusive)
- ✅ ChrisTitus plan is tuned for maximum throughput

---

## Performance Optimizations Already Applied

### ✅ What's Already Optimized:

1. **Power Plan**: Ultra-high performance configuration
2. **CPU**: No throttling, always at 100%
3. **Storage**: NVMe SSD for maximum I/O speed
4. **Memory**: 32 GB with plenty of headroom
5. **GPU**: Professional workstation card with hardware encoding
6. **Network**: 10 Gbps capable adapter with RSS enabled
7. **Visual Effects**: Custom settings (not "Best appearance" bloat)
8. **Scheduled Tasks**: Running continuously (optical monitor, video encoding)
9. **Network Offloading**: TCP/UDP checksum offload enabled

---

## Recommended Optimizations

### 1. ⚠️ Consider Switching to Native High Performance Plan (Optional)

**Current**: ChrisTitus - Ultimate Power Plan (custom)
**Recommendation**: Windows built-in "High performance" or "Ultimate Performance"

**Why**:
- ChrisTitus plan is good but third-party
- Native Windows plans are tested and supported by Microsoft
- "Ultimate Performance" is identical to your current settings

**How to switch**:
```powershell
# Switch to High Performance
powercfg /setactive SCHEME_MIN

# OR switch to Ultimate Performance (if available)
powercfg /setactive e9a42b02-d5df-448d-aa00-03f14749eb61
```

**Impact**: Minimal - your current plan is already excellent

**Priority**: LOW (current plan is fine)

---

### 2. ✅ 10 Gbps Network Optimization (ALREADY GOOD)

Your 10 Gbps adapter is already well-configured:
- ✅ RSS (Receive Side Scaling) enabled with 8 queues
- ✅ Checksum offloading enabled
- ✅ Link speed at full 10 Gbps

**Recommendation**: Consider using the 10 Gbps adapter for NAS transfers

**Current NAS mapping**: Uses 1 Gbps adapter
**Potential**: 10x faster NAS transfers (10 Gbps vs 1 Gbps)

**How to verify which adapter is used**:
```powershell
Get-SmbMapping | Format-Table LocalPath, RemotePath, Status
Get-NetRoute -DestinationPrefix "10.0.0.0/8" | Format-Table
```

**Benefit**:
- 1 Gbps = ~125 MB/s theoretical (100-110 MB/s real)
- 10 Gbps = ~1250 MB/s theoretical (900-1100 MB/s real)
- Transfer a 6 GB file in 6 seconds instead of 60 seconds

**Priority**: MEDIUM (only matters when NAS is accessible)

---

### 3. ⚠️ Windows Updates Pending (78 updates)

**Status**: 78 pending updates detected

**Recommendation**: Install Windows updates during maintenance window

**Why**:
- Security patches
- Performance improvements
- Driver updates (including AMD GPU drivers)
- Bug fixes

**How**:
```powershell
# Check for updates
Get-WindowsUpdate

# Install all updates
Install-WindowsUpdate -AcceptAll -AutoReboot
```

**When to do this**: During off-hours when no encoding is running

**Priority**: MEDIUM (security important, but system is stable)

---

### 4. ⚡ Disable Unnecessary Startup Programs

**Current startup items**:
- ❌ OneDriveSetup (runs twice)
- ❌ Microsoft Edge AutoLaunch
- ❌ Steam (runs silently in background)
- ⚠️  AMD Noise Suppression (may not be needed for server)
- ⚠️  Wondershare UniConverter Update Helper

**Recommendation**: Disable non-essential startup programs

**How**:
```powershell
# Disable Steam auto-start
Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Run
Remove-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Run -Name "Steam"

# Or use Task Manager -> Startup tab -> Disable unwanted items
```

**Benefit**:
- Faster boot time
- Less background CPU/RAM usage
- Fewer potential conflicts

**Priority**: LOW (system has plenty of resources)

---

### 5. 💾 Optimize Pagefile (Currently Underutilized)

**Current**: 5120 MB allocated, only 1 MB peak usage

**Recommendation**: Reduce or manage pagefile size

**Options**:

**Option A**: Let Windows manage it automatically
```powershell
# Allow Windows to manage pagefile
wmic computersystem set AutomaticManagedPagefile=True
```

**Option B**: Set to recommended size (1.5x RAM)
```powershell
# For 32 GB RAM: 48 GB (49152 MB) pagefile
wmic pagefileset where name="C:\\pagefile.sys" set InitialSize=49152,MaximumSize=49152
```

**Option C**: Minimal pagefile (system requirement)
```powershell
# Set to minimum 2 GB
wmic pagefileset where name="C:\\pagefile.sys" set InitialSize=2048,MaximumSize=2048
```

**Current Status**: Your system barely uses pagefile (1 MB peak)

**Priority**: VERY LOW (system is not paging, plenty of RAM)

---

### 6. 🔧 Scheduled Task Optimization

**Current tasks**:
- ✅ **Optical Monitor**: Running continuously (good)
- ✅ **Video Encoding**: Running continuously (good)
- ✅ **NAS Transfer**: Every 30 minutes (good frequency)

**Recommendation**: Tasks are well-configured, no changes needed

**Priority**: N/A (already optimized)

---

### 7. 🎨 Visual Effects (Already Optimized)

**Current**: Custom visual effects settings

**Status**: ✅ Already optimized

No changes needed - you're not using "Best appearance" which would waste resources.

---

### 8. 🔊 AMD Noise Suppression (Optional)

**Current**: Running at startup

**Recommendation**: Disable if not using microphone input

**Why**: Server doesn't typically need audio noise suppression

**How**: Disable in Task Manager -> Startup tab

**Priority**: VERY LOW (minimal impact)

---

## Performance Bottleneck Analysis

### Current Workload: Media Encoding

**Typical workflow**:
1. MakeMKV rips disc (I/O + optical drive speed)
2. FFmpeg encodes video (GPU + CPU)
3. Transfer to NAS (Network bandwidth)

### Bottleneck Assessment:

**✅ CPU**: NOT a bottleneck
- 16 cores / 32 threads
- Current load: 1%
- Headroom: 99%

**✅ RAM**: NOT a bottleneck
- 32 GB total
- 18.4% used
- Headroom: 81.6%

**✅ GPU**: NOT a bottleneck
- AMD Radeon PRO W7600
- Hardware AV1 encoding supported
- Headroom: Excellent

**✅ Storage**: NOT a bottleneck
- NVMe SSD (fastest available)
- Read/Write speeds: 2000+ MB/s typical
- Headroom: Excellent

**⚠️  Network**: POTENTIAL bottleneck (only when NAS is accessible)
- Current: 1 Gbps (~100-110 MB/s)
- Available: 10 Gbps (~900-1100 MB/s)
- **Recommendation**: Use 10 Gbps adapter for NAS transfers

**🔴 Optical Drive**: ACTUAL bottleneck
- Blu-ray read speed: 36 Mbps (4.5 MB/s) for 1x speed
- Typical rip speed: 2-8x = 9-36 MB/s
- **This is unavoidable** - limited by disc format

---

## Performance Benchmarks (Theoretical)

### Current Configuration:

**Ripping** (MakeMKV):
- Blu-ray 25 GB: ~15-30 minutes (depends on disc drive speed)
- Blu-ray 50 GB: ~30-60 minutes

**Encoding** (FFmpeg with AMD AMF):
- 1080p AV1: ~0.5-1.5x realtime (90-minute movie in 60-180 minutes)
- 4K AV1: ~0.3-0.8x realtime (slower due to resolution)

**Transfer to NAS** (when accessible):
- 1 Gbps: 6 GB file in ~60 seconds
- 10 Gbps: 6 GB file in ~6 seconds

**Total time for one disc**:
- Rip: 15-30 minutes
- Encode: 60-180 minutes
- Transfer: <1 minute (10 Gbps) or ~1 minute (1 Gbps)
- **Total**: ~1.5-3.5 hours per disc

---

## Recommended Actions (Priority Order)

### High Priority:
1. ✅ **None** - System is already well-optimized

### Medium Priority:
1. **Install Windows Updates** (78 pending)
   - Do during maintenance window
   - Reboot may be required
   - Estimated time: 1-2 hours

2. **Verify 10 Gbps network is used for NAS** (when NAS is accessible)
   - Check routing table
   - Test transfer speeds
   - Potential 10x improvement

### Low Priority:
1. **Disable unnecessary startup programs**
   - Steam, OneDrive, Edge AutoLaunch
   - Saves ~100-200 MB RAM
   - Faster boot time

2. **Consider switching to native Windows power plan**
   - "Ultimate Performance" is equivalent to current
   - More official support

### Very Low Priority:
1. Optimize pagefile size (minimal benefit)
2. Disable AMD Noise Suppression (minimal impact)

---

## Performance Monitoring

### Tools to Monitor Performance:

**Task Manager**:
- CPU usage per process
- RAM usage
- Disk I/O
- Network throughput

**Resource Monitor** (`resmon`):
- Detailed I/O per process
- Network activity
- Disk queue length

**Performance Monitor** (`perfmon`):
- Create custom counters
- Track encoding performance over time
- Monitor GPU utilization

### Key Metrics to Watch:

**During Encoding**:
- GPU utilization (should be high with AMD AMF)
- CPU usage (should be low with hardware encoding)
- Disk queue length (should be low on NVMe)

**During NAS Transfer**:
- Network throughput (should be near 100 MB/s on 1 Gbps, 900+ MB/s on 10 Gbps)
- SMB protocol overhead

---

## Power Consumption Estimates

### ChrisTitus Ultimate Power Plan:
- **Idle**: ~100-150W (dual Xeon CPUs always at 100%)
- **Under Load**: ~250-350W (encoding with GPU)

### If Switched to Balanced Plan:
- **Idle**: ~60-80W (CPUs throttle down)
- **Under Load**: ~250-350W (same as ultimate)

**Recommendation**: Keep current power plan for server workload

**Why**:
- Server should prioritize performance over power savings
- Difference: ~50W idle (~$5/month at $0.12/kWh)
- Benefit: No throttling delays

---

## Network Performance Optimization

### Current Network Setup:
- **Adapter 1**: 1 Gbps Ethernet (primary)
- **Adapter 2**: 10 Gbps (Slot06 x16 Port 1)

### Verify Which Adapter is Used for NAS:

```powershell
# Check routing table for 10.0.0.0/8 network
Get-NetRoute -DestinationPrefix "10.0.0.0/8" | Format-Table

# Check which interface has the route
Get-NetIPAddress | Where-Object { $_.IPAddress -like "192.168.*" } | Format-Table
```

### If 1 Gbps adapter is used:

**Option 1**: Reconfigure SMB mapping to use 10 Gbps adapter
```powershell
# Remove old mapping
Remove-SmbMapping -RemotePath "\\10.0.0.1\media" -Force

# Add new mapping with specific network adapter
# (requires knowing the 10GbE adapter IP)
New-SmbMapping -RemotePath "\\10.0.0.1\media" -LocalPath "X:"
```

**Option 2**: Set routing priority to prefer 10GbE adapter
```powershell
# Lower metric = higher priority
Set-NetIPInterface -InterfaceAlias "Slot06 x16 Port 1" -InterfaceMetric 10
Set-NetIPInterface -InterfaceAlias "Ethernet" -InterfaceMetric 20
```

---

## Storage Optimization

### Current: Intel NVMe SSD
- ✅ Already optimal
- ✅ TRIM enabled (automatic on Windows)
- ✅ 43% free space (healthy)

### Maintenance:

**Check TRIM status**:
```powershell
fsutil behavior query DisableDeleteNotify
# Should return: DisableDeleteNotify = 0 (TRIM enabled)
```

**Defragmentation** (not needed for SSD):
- Windows automatically optimizes SSDs
- No manual defrag required

---

## GPU Encoding Optimization

### Current: AMD Radeon PRO W7600

**Verify AMD AMF is being used**:
```powershell
# Check FFmpeg logs for AMF
Get-Content "C:\Scripts\Logs\video-encoding.log" -Tail 100 | Select-String "amf|h264_amf|hevc_amf|av1_amf"
```

**Expected output**:
```
Encoder: av1_amf
Hardware acceleration: AMD AMF
```

### If software encoding is detected:

**Update AMD drivers**:
- Current: 32.0.22029.1019
- Latest: Check AMD website for PRO drivers

**Verify FFmpeg is compiled with AMF support**:
```powershell
ffmpeg -hwaccels
# Should list: amf
```

---

## Summary

### Overall Rating: ⭐⭐⭐⭐⭐ (5/5)

Your server is **exceptionally well-configured**:

✅ **Hardware**: Enterprise-grade (dual Xeon, 32GB RAM, NVMe SSD, professional GPU)
✅ **Power Plan**: Optimized for maximum performance
✅ **Storage**: Fastest available (NVMe SSD)
✅ **Network**: 10 Gbps capable
✅ **Configuration**: Well-tuned for media encoding workload

### Actual Bottlenecks:
1. 🔴 **Optical drive speed** (unavoidable, hardware limitation)
2. ⚠️  **Network** (only if using 1 Gbps instead of 10 Gbps for NAS)

### Recommended Next Steps:
1. Install Windows Updates (78 pending) - **Medium priority**
2. Verify 10 Gbps network is used for NAS transfers - **Medium priority**
3. Clean up startup programs - **Low priority**

### Performance Gains Possible:
- **Windows Updates**: Security + stability (no performance gain expected)
- **10 Gbps Network**: 10x faster NAS transfers (IF not already using it)
- **Startup Cleanup**: Minimal (~100 MB RAM saved)

**Bottom Line**: Your system is already running at peak performance for media encoding. No major optimizations needed.

---

**Last Updated**: 2025-12-03
**Next Review**: After Windows Updates are installed
