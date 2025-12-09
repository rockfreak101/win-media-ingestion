## Media Server SMB Mount Configuration Guide

**Purpose**: Mount Windows encoded files from win-ingest-01 on Linux media-server for *arr app access
**Created**: 2025-12-03
**Status**: Ready to implement when media-server (192.168.1.83) is online

---

## Overview

This guide configures the Linux media-server to access encoded media files from the Windows ingestion server via SMB share.

### Architecture:

```
Windows Server (win-ingest-01 - 192.168.1.80)
├── C:\MediaProcessing\encoded\movies\    ← Radarr monitors this
├── C:\MediaProcessing\encoded\tv\        ← Sonarr monitors this
└── C:\MediaProcessing\encoded\music-lossless\ ← Lidarr monitors this
          ↓
     SMB Share: \\192.168.1.80\MediaProcessing
          ↓
Linux Server (media-server - 192.168.1.83)
├── /mnt/win-encoded/                      ← Mount point
    ├── encoded/movies/                    ← Radarr watches here
    ├── encoded/tv/                        ← Sonarr watches here
    └── encoded/music-lossless/            ← Lidarr watches here
```

---

## Prerequisites

**On win-ingest-01 (Windows):**
- ✅ COMPLETED - SMB share created: `\\192.168.1.80\MediaProcessing`
- ✅ COMPLETED - Firewall rules enabled for SMB
- ✅ COMPLETED - Permissions configured

**On media-server (Linux):**
- ⏳ PENDING - Server must be online (192.168.1.83)
- ⏳ PENDING - cifs-utils package installed
- ⏳ PENDING - Mount point created
- ⏳ PENDING - Credentials file configured

---

## Step 1: Install Required Packages on Linux

SSH into media-server (192.168.1.83):

```bash
ssh jluczani@192.168.1.83
```

Install CIFS utilities:

```bash
sudo apt update
sudo apt install cifs-utils -y
```

---

## Step 2: Create Mount Point

```bash
sudo mkdir -p /mnt/win-encoded
sudo chown jluczani:jluczani /mnt/win-encoded
```

---

## Step 3: Create Credentials File

For security, store SMB credentials in a protected file:

```bash
sudo mkdir -p /root/.smb
sudo nano /root/.smb/win-ingest-credentials
```

Add these lines (replace with actual password):

```
username=jluczani
password=YOUR_WINDOWS_PASSWORD_HERE
domain=WORKGROUP
```

Secure the credentials file:

```bash
sudo chmod 600 /root/.smb/win-ingest-credentials
sudo chown root:root /root/.smb/win-ingest-credentials
```

---

## Step 4: Test Manual Mount

Before adding to fstab, test the mount manually:

```bash
sudo mount -t cifs //192.168.1.80/MediaProcessing /mnt/win-encoded \
  -o credentials=/root/.smb/win-ingest-credentials,uid=1000,gid=1000,file_mode=0644,dir_mode=0755
```

Verify it worked:

```bash
ls -la /mnt/win-encoded/
ls -la /mnt/win-encoded/encoded/movies/
```

You should see files like: `C1_t02.mkv`, `AKIRA-E1_t00.mkv`, etc.

If successful, unmount:

```bash
sudo umount /mnt/win-encoded
```

---

## Step 5: Add to /etc/fstab for Permanent Mount

Edit fstab:

```bash
sudo nano /etc/fstab
```

Add this line at the end:

```
//192.168.1.80/MediaProcessing  /mnt/win-encoded  cifs  credentials=/root/.smb/win-ingest-credentials,uid=1000,gid=1000,file_mode=0644,dir_mode=0755,_netdev,nofail  0  0
```

**Important flags explained:**
- `_netdev` - Wait for network before mounting
- `nofail` - Don't fail boot if mount fails
- `uid=1000,gid=1000` - Files owned by user jluczani (UID 1000)
- `file_mode=0644,dir_mode=0755` - Proper file/directory permissions

---

## Step 6: Mount and Verify

Mount all fstab entries:

```bash
sudo mount -a
```

Verify it mounted:

```bash
mount | grep win-encoded
df -h | grep win-encoded
ls -la /mnt/win-encoded/encoded/
```

Expected output:
```
//192.168.1.80/MediaProcessing on /mnt/win-encoded type cifs (rw,relatime,...)
...
drwxr-xr-x  2 jluczani jluczani  0 Dec  3 14:00 movies
drwxr-xr-x  2 jluczani jluczani  0 Dec  3 14:00 tv
drwxr-xr-x  2 jluczani jluczani  0 Dec  3 14:00 music-lossless
```

---

## Step 7: Update Docker Compose for *arr Apps

Edit the docker-compose.yml for *arr apps to add the new volume:

```bash
cd /home/jluczani/git/jlucznai/home_lab_media
nano docker-compose.yml
```

### For Radarr (Movies):

```yaml
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/Chicago
    volumes:
      - ./docker-compose/radarr/data:/config
      - /mnt/media/Movies:/movies              # Final NAS destination
      - /mnt/media/More_Movies:/more-movies
      - /home/jluczani/Downloads/complete:/downloads
      - /mnt/win-encoded/encoded/movies:/incoming-windows:ro  # NEW: Windows encoded files (read-only)
    ports:
      - 7878:7878
    depends_on:
      - prowlarr
```

### For Sonarr (TV Shows):

```yaml
  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/Chicago
    volumes:
      - ./docker-compose/sonarr/data:/config
      - /mnt/media/TV:/tv                      # Final NAS destination
      - /home/jluczani/Downloads/complete:/downloads
      - /mnt/win-encoded/encoded/tv:/incoming-windows:ro  # NEW: Windows encoded files (read-only)
    ports:
      - 8989:8989
    depends_on:
      - prowlarr
```

### For Lidarr (Music):

```yaml
  lidarr-lossless:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: lidarr-lossless
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/Chicago
    volumes:
      - ./docker-compose/lidarr-lossless/config:/config
      - /mnt/media/Music_Lossless:/music
      - /home/jluczani/Downloads/complete:/downloads
      - /mnt/win-encoded/encoded/music-lossless:/incoming-windows:ro  # NEW: Windows encoded files (read-only)
    ports:
      - 8687:8686
    depends_on:
      - prowlarr
```

**Note**: Using `:ro` (read-only) is safer - *arr apps only need to read files, then move them.

---

## Step 8: Restart Docker Containers

```bash
docker-compose up -d radarr sonarr lidarr-lossless
```

Verify containers restarted:

```bash
docker-compose ps
docker-compose logs radarr | grep -i "incoming-windows"
```

---

## Step 9: Configure Radarr to Monitor Windows Files

1. Access Radarr web interface: `http://192.168.1.83:7878`

2. Go to **Settings → Media Management**

3. Scroll to **Importing**
   - ✅ Enable "Use Hardlinks instead of Copy" (if on same filesystem)
   - ✅ Enable "Delete empty folders"

4. Go to **Settings → Import Lists** or **Settings → Indexers** (depending on version)

5. **Add a new path to monitor** (manually):
   - Go to **Movies** tab
   - Click **Add New**
   - Browse to `/incoming-windows/`
   - Select files you want Radarr to manage

OR use **Manual Import**:
   - Go to **Activity → Queue**
   - Click **Manual Import**
   - Browse to `/incoming-windows/`
   - Select files
   - Radarr will identify, rename, and move them

---

## Step 10: Configure Sonarr to Monitor Windows Files

1. Access Sonarr web interface: `http://192.168.1.83:8989`

2. Go to **Settings → Media Management**

3. Configure similar to Radarr

4. Use **Manual Import** for TV shows:
   - **Series → Manual Import**
   - Browse to `/incoming-windows/`
   - Sonarr will detect episodes and rename them properly

---

## Expected Workflow

### Complete End-to-End Process:

```
1. Insert disc into win-ingest-01
   ↓
2. MakeMKV rips to C:\MediaProcessing\rips\video\
   ↓
3. FFmpeg encodes to C:\MediaProcessing\encoded\movies\
   (Files appear as: C1_t02.mkv, AKIRA-E1_t00.mkv, etc.)
   ↓
4. Files visible on Linux at: /mnt/win-encoded/encoded/movies/
   ↓
5. Radarr detects new file in /incoming-windows/
   ↓
6. Radarr identifies movie (via metadata/filename analysis)
   ↓
7. Radarr renames: C1_t02.mkv → "Akira (1988).mkv"
   ↓
8. Radarr moves to: /mnt/media/Movies/Akira (1988)/Akira (1988).mkv
   ↓
9. Original file deleted from C:\MediaProcessing\encoded\movies\
   ↓
10. Plex detects new file and updates library
```

---

## Troubleshooting

### Issue: Mount fails - "Permission denied"

**Solution**: Check credentials file

```bash
sudo cat /root/.smb/win-ingest-credentials
# Verify username and password are correct
```

### Issue: Mount fails - "Host is down"

**Solution**: Check network connectivity

```bash
ping 192.168.1.80
telnet 192.168.1.80 445  # Test SMB port
```

### Issue: Can see files but permissions denied in Docker

**Solution**: Check UID/GID

```bash
ls -ln /mnt/win-encoded/encoded/movies/
# Should show: uid=1000 gid=1000
```

If not, remount with correct uid/gid:

```bash
sudo umount /mnt/win-encoded
sudo mount -a
```

### Issue: *arr apps can't see /incoming-windows/

**Solution**: Check Docker volume mapping

```bash
docker inspect radarr | grep -A 10 Mounts
# Should see: /mnt/win-encoded/encoded/movies -> /incoming-windows
```

Recreate container if needed:

```bash
docker-compose up -d --force-recreate radarr
```

### Issue: Radarr won't import files

**Possible causes**:
1. File permissions - check with `docker exec radarr ls -la /incoming-windows/`
2. File naming - Radarr needs to identify the movie
3. Quality profile - File might not match configured profiles
4. Missing metadata - Run manual import to assist identification

**Solution**: Use Manual Import
- Radarr → Activity → Manual Import
- Select `/incoming-windows/`
- Manually match files to movies
- Radarr will rename and move

---

## Testing the Complete Workflow

### Test 1: Manual File Placement

```bash
# On media-server, create a test file
touch "/mnt/win-encoded/encoded/movies/test-movie.mkv"

# Check if Radarr can see it
docker exec radarr ls -la /incoming-windows/
```

### Test 2: Actual Disc Rip

1. Insert a disc into win-ingest-01
2. Wait for ripping + encoding to complete
3. On media-server, verify file appears:
   ```bash
   ls -lh /mnt/win-encoded/encoded/movies/
   ```
4. Use Radarr Manual Import to process the file
5. Verify it moved to `/mnt/media/Movies/`

---

## Monitoring

### Check mount status:

```bash
mount | grep win-encoded
df -h | grep win-encoded
```

### Check file count in incoming directory:

```bash
find /mnt/win-encoded/encoded/movies/ -type f | wc -l
```

### Watch for new files:

```bash
watch -n 5 'ls -lht /mnt/win-encoded/encoded/movies/ | head -20'
```

### Check Radarr activity logs:

```bash
docker-compose logs -f --tail=50 radarr
```

---

## Unmounting (if needed)

To unmount the share:

```bash
sudo umount /mnt/win-encoded
```

To prevent auto-mount on boot, comment out the fstab entry:

```bash
sudo nano /etc/fstab
# Add # at the beginning of the MediaProcessing line
```

---

## Security Considerations

1. **Credentials file** is root-only readable ✅
2. **SMB mount is read-only** for *arr apps ✅
3. **No authentication required** from Docker containers (mount handles it) ✅
4. **Network is internal** (192.168.1.0/24) ✅

---

## Performance Notes

### Expected Performance:
- **Network**: 1 Gbps LAN (125 MB/s theoretical max)
- **Typical file**: 2-6 GB (takes 16-48 seconds to copy at full speed)
- **SMB overhead**: ~10-20% reduction from max throughput

### Optimization Tips:
1. *arr apps should **move** files, not copy them
2. Use Radarr's "Remote Path Mappings" if needed
3. Schedule heavy operations during off-peak hours

---

## Summary Checklist

**When media-server (192.168.1.83) comes online:**

- [ ] Install cifs-utils
- [ ] Create mount point `/mnt/win-encoded`
- [ ] Create credentials file
- [ ] Test manual mount
- [ ] Add to `/etc/fstab`
- [ ] Verify mount persists across reboot
- [ ] Update docker-compose.yml volumes
- [ ] Restart *arr containers
- [ ] Configure Radarr/Sonarr to monitor incoming paths
- [ ] Test with actual ripped file
- [ ] Verify complete workflow

---

## Related Files

- **SMB Share Setup**: `ansible/playbooks/setup-windows-smb-share.yml`
- **Radarr/Sonarr Config**: `RADARR-SONARR-CONFIGURATION-GUIDE.md` (see below)
- **Main docker-compose**: `docker-compose.yml`

---

**Last Updated**: 2025-12-03
**Status**: Documentation complete, ready for implementation
**Next Step**: Bring media-server online and follow this guide
