# Docker Direct CIFS Mount Configuration

**Purpose**: Mount Windows SMB share directly in Docker containers instead of using host-level mounts
**Date**: 2025-12-05
**Status**: Recommended approach

---

## Why Direct CIFS Mounts?

**Advantages**:
1. ✅ **Simpler architecture** - No intermediate Linux mount needed
2. ✅ **Better isolation** - Container-specific mount management
3. ✅ **Self-contained** - docker-compose.yml has all configuration
4. ✅ **Easier troubleshooting** - Mount issues isolated to container
5. ✅ **More portable** - Works across different Docker hosts

**Comparison**:

| Approach | Host Mount | Direct CIFS |
|----------|------------|-------------|
| Configuration | /etc/fstab + docker-compose.yml | docker-compose.yml only |
| Troubleshooting | Check host + container | Check container only |
| Portability | Requires host setup | Self-contained |
| Security | Credentials in /root/.smb/ | Credentials in .env file |
| Isolation | Shared across containers | Per-container |

---

## Prerequisites

1. **CIFS utilities** (usually pre-installed in linuxserver.io images)
2. **Windows SMB share** configured and accessible
3. **Credentials** for SMB access
4. **Network connectivity** between Docker host and Windows server

---

## Configuration

### Step 1: Create Environment File

Create `.env` file in the same directory as `docker-compose.yml`:

```bash
# Windows SMB credentials
WIN_SMB_HOST=192.168.1.80
WIN_SMB_USER=jluczani
WIN_SMB_PASSWORD=your_password_here

# Docker user/group IDs
PUID=1000
PGID=1000
```

**Security**: Add `.env` to `.gitignore`:
```bash
echo ".env" >> .gitignore
```

---

### Step 2: Update docker-compose.yml

```yaml
version: "3.8"

services:
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=America/New_York
    volumes:
      - ./docker-compose/radarr/config:/config
      - /mnt/media/movies:/movies           # Final destination (NFS)
      # Direct CIFS mount for Windows-encoded movies
      - type: volume
        source: windows_movies
        target: /incoming-windows
        read_only: false  # Radarr needs write to delete after import
    ports:
      - 7878:7878
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=America/New_York
    volumes:
      - ./docker-compose/sonarr/config:/config
      - /mnt/media/tv:/tv                    # Final destination (NFS)
      # Direct CIFS mount for Windows-encoded TV shows
      - type: volume
        source: windows_tv
        target: /incoming-windows
        read_only: false  # Sonarr needs write to delete after import
    ports:
      - 8989:8989
    restart: unless-stopped

  lidarr:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: lidarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=America/New_York
    volumes:
      - ./docker-compose/lidarr/config:/config
      - /mnt/media/music-lossless:/music     # Final destination (NFS)
      # Direct CIFS mount for Windows-ripped music
      - type: volume
        source: windows_music
        target: /incoming-windows
        read_only: false  # Lidarr needs write to delete after import
    ports:
      - 8686:8686
    restart: unless-stopped

# Volume definitions for CIFS mounts
volumes:
  windows_movies:
    driver: local
    driver_opts:
      type: cifs
      o: "addr=${WIN_SMB_HOST},username=${WIN_SMB_USER},password=${WIN_SMB_PASSWORD},uid=${PUID},gid=${PGID},file_mode=0644,dir_mode=0755,vers=3.0"
      device: "//${WIN_SMB_HOST}/MediaProcessing/encoded/movies"

  windows_tv:
    driver: local
    driver_opts:
      type: cifs
      o: "addr=${WIN_SMB_HOST},username=${WIN_SMB_USER},password=${WIN_SMB_PASSWORD},uid=${PUID},gid=${PGID},file_mode=0644,dir_mode=0755,vers=3.0"
      device: "//${WIN_SMB_HOST}/MediaProcessing/encoded/tv"

  windows_music:
    driver: local
    driver_opts:
      type: cifs
      o: "addr=${WIN_SMB_HOST},username=${WIN_SMB_USER},password=${WIN_SMB_PASSWORD},uid=${PUID},gid=${PGID},file_mode=0644,dir_mode=0755,vers=3.0"
      device: "//${WIN_SMB_HOST}/MediaProcessing/encoded/music-lossless"
```

---

## CIFS Mount Options Explained

```
o: "addr=${WIN_SMB_HOST},username=${WIN_SMB_USER},password=${WIN_SMB_PASSWORD},uid=${PUID},gid=${PGID},file_mode=0644,dir_mode=0755,vers=3.0"
```

| Option | Value | Purpose |
|--------|-------|---------|
| `addr` | `192.168.1.80` | Windows server IP |
| `username` | `jluczani` | SMB username |
| `password` | `***` | SMB password |
| `uid` | `1000` | File owner UID (matches PUID) |
| `gid` | `1000` | File owner GID (matches PGID) |
| `file_mode` | `0644` | File permissions (rw-r--r--) |
| `dir_mode` | `0755` | Directory permissions (rwxr-xr-x) |
| `vers` | `3.0` | SMB protocol version (3.0 or 2.1) |

**Optional parameters**:
- `rsize=131072` - Read buffer size (128KB, improves performance)
- `wsize=131072` - Write buffer size (128KB, improves performance)
- `cache=loose` - Caching mode (better performance, less strict consistency)
- `nobrl` - Disable byte-range locks (better performance)

**Performance-optimized version**:
```
o: "addr=${WIN_SMB_HOST},username=${WIN_SMB_USER},password=${WIN_SMB_PASSWORD},uid=${PUID},gid=${PGID},file_mode=0644,dir_mode=0755,vers=3.0,rsize=131072,wsize=131072,cache=loose,nobrl"
```

---

## Deployment Steps

### 1. Stop Existing Services

```bash
cd ~/git/jlucznai/home_lab_media
docker-compose down
```

### 2. Create .env File

```bash
cat > .env << 'EOF'
# Windows SMB credentials
WIN_SMB_HOST=192.168.1.80
WIN_SMB_USER=jluczani
WIN_SMB_PASSWORD=your_actual_password

# Docker user/group IDs
PUID=1000
PGID=1000
EOF

# Secure the file
chmod 600 .env
```

### 3. Update docker-compose.yml

Add the volume definitions shown above to your `docker-compose.yml`.

### 4. Test Configuration

```bash
# Validate docker-compose.yml syntax
docker-compose config

# Start services
docker-compose up -d radarr sonarr lidarr
```

### 5. Verify Mounts

```bash
# Check if volumes are created
docker volume ls | grep windows

# Verify mount inside container
docker exec radarr ls -la /incoming-windows

# Should show files from Windows share
```

---

## Troubleshooting

### Issue: Volume Mount Fails

**Check logs**:
```bash
docker-compose logs radarr | grep -i cifs
journalctl -xe | grep -i cifs
```

**Common errors**:

#### "Host is down" or "Connection refused"
**Cause**: Network connectivity issue
**Fix**:
```bash
# Test SMB connectivity from Docker host
smbclient -L //192.168.1.80 -U jluczani
```

#### "Permission denied"
**Cause**: Invalid credentials or Windows share permissions
**Fix**:
1. Verify credentials in `.env`
2. Check Windows share permissions (see below)
3. Verify SMB is enabled on Windows

#### "Invalid argument" or "CIFS not supported"
**Cause**: CIFS kernel module not loaded
**Fix**:
```bash
# Load CIFS module
sudo modprobe cifs

# Verify
lsmod | grep cifs
```

#### "Operation not supported"
**Cause**: SMB version mismatch
**Fix**: Try different SMB versions:
```yaml
vers=2.1   # Try SMB 2.1
vers=3.0   # Try SMB 3.0
vers=3.1.1 # Try SMB 3.1.1
```

---

### Issue: Files Not Visible in Container

**Check mount point**:
```bash
docker exec radarr mount | grep incoming-windows
docker exec radarr df -h | grep incoming-windows
```

**Verify Windows share**:
```bash
# From Docker host
smbclient //192.168.1.80/MediaProcessing -U jluczani -c "ls encoded/movies/"
```

---

### Issue: Permission Denied Inside Container

**Check UID/GID**:
```bash
# Inside container
docker exec radarr id

# Should show uid=1000(abc) gid=1000(abc)
```

**Fix**: Ensure `uid` and `gid` in CIFS mount options match container's PUID/PGID.

---

### Issue: Slow Performance

**Optimize mount options**:
```yaml
o: "...,rsize=131072,wsize=131072,cache=loose,nobrl"
```

**Check network speed**:
```bash
# Inside container, copy a test file
docker exec radarr dd if=/incoming-windows/testfile of=/dev/null bs=1M count=100
```

---

## Windows Share Configuration

Ensure Windows share is properly configured:

### 1. Share Permissions

**File Explorer → Right-click MediaProcessing → Properties → Sharing → Advanced Sharing**:
- Share name: `MediaProcessing`
- Permissions: `Everyone` → `Full Control` (internal network only)

### 2. NTFS Permissions

**Right-click MediaProcessing → Properties → Security → Edit**:
- Add user: `jluczani`
- Permissions: `Full Control`

### 3. Firewall Rules

Ensure SMB is allowed:
```powershell
# On Windows server
Get-NetFirewallRule -DisplayName "*File and Printer Sharing*" | Enable-NetFirewallRule
```

### 4. Test from Linux

```bash
# Install smbclient
sudo apt install smbclient

# Test connection
smbclient //192.168.1.80/MediaProcessing -U jluczani

# List files
smb: \> ls encoded/movies/
```

---

## Migration from Host Mounts

If you're currently using host-level CIFS mounts (`/mnt/win-encoded`), here's how to migrate:

### Before (Host Mount):
```yaml
volumes:
  - /mnt/win-encoded/encoded/movies:/incoming-windows
```

```bash
# /etc/fstab
//192.168.1.80/MediaProcessing/encoded/movies /mnt/win-encoded cifs credentials=/root/.smb/credentials,uid=1000,gid=1000 0 0
```

### After (Direct CIFS):
```yaml
volumes:
  - type: volume
    source: windows_movies
    target: /incoming-windows
```

```yaml
volumes:
  windows_movies:
    driver: local
    driver_opts:
      type: cifs
      o: "addr=192.168.1.80,username=jluczani,password=***,..."
      device: "//192.168.1.80/MediaProcessing/encoded/movies"
```

**Migration steps**:
1. Stop containers: `docker-compose down`
2. Update `docker-compose.yml` with new volumes
3. Create `.env` with credentials
4. Remove `/etc/fstab` entry: `sudo nano /etc/fstab`
5. Unmount host mount: `sudo umount /mnt/win-encoded`
6. Start containers: `docker-compose up -d`
7. Verify: `docker exec radarr ls /incoming-windows`

---

## Security Best Practices

1. **Never commit `.env` to git**:
   ```bash
   echo ".env" >> .gitignore
   git add .gitignore
   git commit -m "Ignore .env file"
   ```

2. **Restrict .env permissions**:
   ```bash
   chmod 600 .env
   chown $(whoami):$(whoami) .env
   ```

3. **Use strong passwords** for SMB access

4. **Limit SMB access** to internal network only (Windows Firewall)

5. **Consider SMB encryption** (SMB 3.0+):
   ```yaml
   o: "...,seal"  # Enables SMB encryption
   ```

6. **Regular credential rotation** - Update Windows password and `.env` periodically

---

## Performance Tuning

### For Large Files (Blu-ray Rips):

```yaml
o: "addr=${WIN_SMB_HOST},username=${WIN_SMB_USER},password=${WIN_SMB_PASSWORD},uid=${PUID},gid=${PGID},vers=3.0,rsize=1048576,wsize=1048576,cache=loose,nobrl,mfsymlinks"
```

| Option | Value | Benefit |
|--------|-------|---------|
| `rsize=1048576` | 1MB read buffer | Faster large file reads |
| `wsize=1048576` | 1MB write buffer | Faster large file writes |
| `cache=loose` | Relaxed caching | Better performance |
| `nobrl` | No byte-range locks | Fewer lock operations |
| `mfsymlinks` | Symlink support | Compatibility |

### Benchmark Performance:

```bash
# Test read speed
docker exec radarr dd if=/incoming-windows/testfile of=/dev/null bs=1M count=1000

# Test write speed (if not read-only)
docker exec radarr dd if=/dev/zero of=/incoming-windows/testfile bs=1M count=1000

# Expected: 100-110 MB/s on 1Gbps network
```

---

## Complete Example

**docker-compose.yml** (complete, production-ready):

```yaml
version: "3.8"

services:
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=America/New_York
    volumes:
      - ./docker-compose/radarr/config:/config
      - /mnt/media/movies:/movies
      - type: volume
        source: windows_movies
        target: /incoming-windows
        read_only: false
    ports:
      - 7878:7878
    restart: unless-stopped
    networks:
      - media-network

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=America/New_York
    volumes:
      - ./docker-compose/sonarr/config:/config
      - /mnt/media/tv:/tv
      - type: volume
        source: windows_tv
        target: /incoming-windows
        read_only: false
    ports:
      - 8989:8989
    restart: unless-stopped
    networks:
      - media-network

volumes:
  windows_movies:
    driver: local
    driver_opts:
      type: cifs
      o: "addr=${WIN_SMB_HOST},username=${WIN_SMB_USER},password=${WIN_SMB_PASSWORD},uid=${PUID},gid=${PGID},file_mode=0644,dir_mode=0755,vers=3.0,rsize=131072,wsize=131072,cache=loose,nobrl"
      device: "//${WIN_SMB_HOST}/MediaProcessing/encoded/movies"

  windows_tv:
    driver: local
    driver_opts:
      type: cifs
      o: "addr=${WIN_SMB_HOST},username=${WIN_SMB_USER},password=${WIN_SMB_PASSWORD},uid=${PUID},gid=${PGID},file_mode=0644,dir_mode=0755,vers=3.0,rsize=131072,wsize=131072,cache=loose,nobrl"
      device: "//${WIN_SMB_HOST}/MediaProcessing/encoded/tv"

networks:
  media-network:
    external: true
```

**.env**:
```bash
WIN_SMB_HOST=192.168.1.80
WIN_SMB_USER=jluczani
WIN_SMB_PASSWORD=your_secure_password
PUID=1000
PGID=1000
```

---

## Summary

**Recommended approach**: ✅ Direct CIFS mounts in docker-compose.yml

**Advantages**:
- Self-contained configuration
- Better isolation
- Easier troubleshooting
- More portable

**Migration effort**: ~15 minutes

**Impact**: Same functionality, simpler architecture

---

**Last Updated**: 2025-12-05
**Status**: Production-ready
**Next Steps**: Update docker-compose.yml and test with one service first
