## Radarr/Sonarr Configuration Guide for Windows-Encoded Media

**Purpose**: Configure Radarr and Sonarr to monitor Windows-encoded files via SMB mount
**Created**: 2025-12-03
**Prerequisites**: SMB share mounted at /mnt/win-encoded (see MEDIA-SERVER-SMB-MOUNT-GUIDE.md)

---

## Overview

This guide configures Radarr (movies) and Sonarr (TV shows) to automatically detect, identify, rename, and organize media files encoded on the Windows ingestion server.

### Workflow Recap

```
Windows Server (win-ingest-01)
├── MakeMKV rips disc → C:\MediaProcessing\rips\video\movies\
├── FFmpeg encodes → C:\MediaProcessing\encoded\movies\
└── SMB share exposes → \\192.168.2.96\MediaProcessing
          ↓
Linux Server (media-server)
├── CIFS mount → /mnt/win-encoded/encoded/movies/
├── Docker volume → /incoming-windows/ (inside container)
├── Radarr detects file → C1_t02.mkv
├── Radarr identifies → "Akira (1988)"
├── Radarr renames → "Akira (1988).mkv"
└── Radarr moves → /mnt/media/Movies/Akira (1988)/Akira (1988).mkv
```

---

## Part 1: Radarr Configuration (Movies)

### Step 1: Access Radarr Web Interface

```bash
# Local access
http://192.168.1.83:7878

# External access (if Cloudflare Tunnel configured)
https://radarr.jluczani.com
```

Default credentials (if first-time setup):
- No authentication by default
- **IMPORTANT**: Set up authentication immediately in Settings → General → Security

---

### Step 2: Configure Media Management

Navigate to: **Settings → Media Management**

#### 2.1 Root Folders

Click **Add Root Folder**:
- **Path**: `/movies` (this is the final destination on NAS)
- This corresponds to `/mnt/media/Movies` on the host

**Note**: Do NOT add `/incoming-windows/` as a root folder. This is a temporary staging area.

#### 2.2 File Management Settings

Enable/configure the following:

**Importing**:
- ✅ **Use Hardlinks instead of Copy**: OFF (cross-filesystem move required)
- ✅ **Delete empty folders**: ON
- ✅ **Watch Root Folder for file changes**: ON

**File Naming**:
- ✅ **Rename Movies**: ON
- **Standard Movie Format**: `{Movie Title} ({Release Year})`
- **Movie Folder Format**: `{Movie Title} ({Release Year})`

**Permissions**:
- **Set Permissions**: ON
- **chmod Folder**: `755`
- **chmod File**: `644`
- **chown Group**: Leave blank (uses PUID/PGID from Docker)

---

### Step 3: Add Quality Profiles (if needed)

Navigate to: **Settings → Profiles**

Default profiles should be fine, but verify:
- **Any**: Accepts any quality
- **HD-1080p**: Prefers 1080p
- **Ultra-HD**: Prefers 4K

Since your files are AV1-encoded at high quality, ensure the profile includes:
- ✅ AV1
- ✅ Bluray-1080p
- ✅ Bluray-2160p

---

### Step 4: Manual Import from Windows Share

This is the primary method for processing files from win-ingest-01.

#### 4.1 Navigate to Manual Import

**Movies** → **Library Import** (or **Manual Import** depending on version)

#### 4.2 Select Directory

Browse to: `/incoming-windows/`

You should see files like:
- `C1_t02.mkv`
- `AKIRA-E1_t00.mkv`
- etc.

#### 4.3 Match Files to Movies

Radarr will attempt to identify movies automatically. For each file:

**If Radarr identifies correctly**:
- ✅ Shows movie poster and title
- ✅ Quality detected
- Click **Import**

**If Radarr can't identify**:
- Click **Manual Import**
- Search for movie title
- Select correct movie
- Choose quality profile
- Click **Import**

#### 4.4 Radarr Processing

Once imported, Radarr will:
1. Rename file: `C1_t02.mkv` → `Akira (1988).mkv`
2. Create directory: `/movies/Akira (1988)/`
3. Move file to: `/movies/Akira (1988)/Akira (1988).mkv`
4. Delete original from `/incoming-windows/` (deletes from Windows via SMB)
5. Update Plex library

---

### Step 5: Automate with Import Lists (Optional)

For fully automated processing, configure an Import List that watches `/incoming-windows/`.

⚠️ **Warning**: This requires files to have identifiable names. With generic MakeMKV names, manual import is more reliable.

---

## Part 2: Sonarr Configuration (TV Shows)

### Step 1: Access Sonarr Web Interface

```bash
# Local access
http://192.168.1.83:8989

# External access
https://sonarr.jluczani.com
```

---

### Step 2: Configure Media Management

Navigate to: **Settings → Media Management**

#### 2.1 Root Folders

Click **Add Root Folder**:
- **Path**: `/tv` (final destination on NAS)
- Corresponds to `/mnt/media/TV` on host

#### 2.2 Episode Naming

Enable **Rename Episodes**: ON

**Standard Episode Format**:
```
{Series Title} - S{season:00}E{episode:00} - {Episode Title}
```

**Season Folder Format**:
```
Season {season:00}
```

**Series Folder Format**:
```
{Series Title}
```

Example output:
```
/tv/G Gundam/Season 01/G Gundam - S01E02 - Episode Title.mkv
```

---

### Step 3: Manual Import for TV Shows

Navigate to: **Series → Manual Import**

#### 3.1 Select Directory

Browse to: `/incoming-windows/`

#### 3.2 Detect Series and Episodes

Sonarr will analyze files and attempt to:
- Identify series name (from directory structure or filename)
- Detect season and episode numbers
- Match to existing series or prompt to add new series

#### 3.3 Import Process

For each file:

**If series exists**:
- Sonarr shows series name, season, episode
- Verify correctness
- Click **Import**

**If series doesn't exist**:
- Click **Add Series**
- Search for series name (e.g., "Mobile Fighter G Gundam")
- Select correct series
- Choose quality profile
- Set monitored seasons
- Click **Add & Import**

#### 3.4 Multi-Episode Detection

For multi-disc series (like G Gundam):
- Sonarr can process multiple episodes at once
- Uses filename patterns to detect season/episode
- May require manual episode matching for generic names

---

### Step 4: Configure Quality Profiles

Navigate to: **Settings → Profiles**

Ensure profile includes:
- ✅ AV1
- ✅ Bluray-1080p
- ✅ WEB-DL 1080p

---

## Part 3: Integration with Download Clients (Future)

Once Prowlarr and download clients are configured, *arr apps can automatically download content.

**Current setup**: Manual import only (processing physical media rips)

**Future setup**: Automatic downloads + manual imports

---

## Part 4: Troubleshooting

### Issue: Radarr/Sonarr Can't See /incoming-windows/

**Check Docker volume mapping**:
```bash
docker inspect radarr | grep -A 10 Mounts
```

Should show:
```
"/mnt/win-encoded/encoded/movies": "/incoming-windows"
```

**Fix**: Update docker-compose.yml and recreate container
```bash
docker-compose up -d --force-recreate radarr
```

---

### Issue: Permission Denied When Accessing Files

**Check mount permissions**:
```bash
ls -la /mnt/win-encoded/encoded/movies/
```

Should show:
```
-rw-r--r-- 1 jluczani jluczani [size] [date] C1_t02.mkv
```

**Fix**: Remount with correct uid/gid
```bash
sudo umount /mnt/win-encoded
sudo mount -a
```

**Verify inside container**:
```bash
docker exec radarr ls -la /incoming-windows/
```

---

### Issue: Radarr Won't Identify Movie

**Possible causes**:
1. Filename too generic (C1_t02.mkv provides no metadata)
2. Movie not in TheMovieDB database
3. Year mismatch

**Solutions**:
- Use Manual Import and search by movie title
- Add year to search: "Akira 1988"
- Check alternate titles if movie has multiple releases

---

### Issue: Files Not Moving to Final Destination

**Check logs**:
```bash
docker-compose logs radarr | grep -i error
```

**Common causes**:
- Insufficient disk space on `/mnt/media`
- NFS mount issues
- Permission problems

**Verify NFS mount**:
```bash
df -h | grep media
touch /mnt/media/Movies/test.txt
rm /mnt/media/Movies/test.txt
```

---

### Issue: Sonarr Can't Detect Episodes

**Problem**: Generic filenames like `C1_t02.mkv` provide no episode information

**Solutions**:
1. **Directory structure**: Place files in directories matching series name
   ```
   /incoming-windows/G Gundam/C1_t02.mkv
   ```

2. **Manual matching**: Use Sonarr's interactive import
   - Select file
   - Choose series
   - Select season
   - Match to specific episode

3. **Batch import**: Select all files for one series, Sonarr will attempt to sequence them

---

### Issue: Duplicate Files or Import Loops

**Symptom**: Radarr keeps re-importing the same file

**Cause**: Original file not deleted from `/incoming-windows/`

**Check**:
```bash
ls -la /mnt/win-encoded/encoded/movies/
```

**Fix**: Ensure SMB mount is read-write (remove `:ro` from docker-compose.yml if present)

---

## Part 5: Monitoring and Verification

### Check Import Activity

**Radarr**: Activity → Queue
**Sonarr**: Activity → Queue

Shows files being processed, renamed, and moved.

---

### Verify Final File Locations

```bash
# Check movie was moved
ls -lh /mnt/media/Movies/Akira\ \(1988\)/

# Check TV show was moved
ls -lh /mnt/media/TV/G\ Gundam/Season\ 01/
```

---

### Check Plex Library Updates

Once files are moved to `/mnt/media`, Plex should automatically detect and add them.

**Force Plex scan** (if needed):
- Plex → Settings → Library → Scan Library Files

---

## Part 6: Advanced Configuration

### Remote Path Mappings

If Radarr/Sonarr report incorrect paths, configure remote path mappings.

**Settings → Download Clients → Remote Path Mappings**

This is rarely needed with proper Docker volume configuration.

---

### Custom Scripts

**Post-Import Scripts**: Run custom commands after successful import

Example use cases:
- Send notifications
- Update metadata
- Trigger additional processing

**Configure**: Settings → Connect → Add Connection → Custom Script

---

### Quality Upgrades

Configure Radarr/Sonarr to replace existing files with higher quality versions.

**Settings → Profiles**: Set quality upgrade cutoffs

Example:
- Current: Bluray-1080p
- Upgrade to: Bluray-2160p (4K)

---

## Part 7: Batch Processing Workflow

For processing large numbers of discs:

### Radarr (Movies)

1. Insert disc → wait for rip + encode
2. Repeat for all discs
3. Once complete, use Radarr Manual Import:
   - Select `/incoming-windows/`
   - Radarr shows all files
   - Review and import in batch
4. Radarr processes all files sequentially

### Sonarr (TV Series)

1. Rip all discs for one series
2. All episodes appear in `/incoming-windows/`
3. Sonarr Manual Import:
   - Select `/incoming-windows/`
   - Choose series
   - Sonarr auto-detects episodes (if filenames have patterns)
   - Manually match any unidentified episodes
4. Import entire season at once

---

## Part 8: Testing the Complete Workflow

### End-to-End Test

1. **Insert disc into win-ingest-01**
   - Optical monitor detects disc
   - MakeMKV rips to `C:\MediaProcessing\rips\video\movies\`

2. **Encoding completes**
   - FFmpeg encodes to `C:\MediaProcessing\encoded\movies\`
   - File appears as generic name (e.g., `C1_t02.mkv`)

3. **Verify file on Linux**
   ```bash
   ls -lh /mnt/win-encoded/encoded/movies/
   ```

4. **Radarr Manual Import**
   - Navigate to Movies → Library Import
   - Select `/incoming-windows/`
   - Identify movie
   - Import

5. **Verify rename and move**
   ```bash
   ls -lh /mnt/media/Movies/
   ```

6. **Check Plex**
   - Movie should appear in library
   - Metadata and poster populated

7. **Verify cleanup**
   ```bash
   # Original file should be gone
   ls -lh /mnt/win-encoded/encoded/movies/
   ```

---

## Part 9: Best Practices

### 1. Process Movies and TV Separately

Keep rips organized:
```
C:\MediaProcessing\rips\video\movies\Movie Name\
C:\MediaProcessing\rips\video\tv\Series Name\
```

This helps Radarr/Sonarr distinguish content types.

---

### 2. Use Descriptive Directory Names

Even if filenames are generic, directory names help:
```
Bad:  /incoming-windows/C1_t02.mkv
Good: /incoming-windows/Akira/C1_t02.mkv
```

---

### 3. Process in Batches

Don't mix different series/movies in the same import session.

---

### 4. Monitor Activity Logs

Check logs after import to catch issues early:
```bash
docker-compose logs -f radarr
docker-compose logs -f sonarr
```

---

### 5. Regular Cleanup

Periodically verify `/incoming-windows/` is empty:
```bash
find /mnt/win-encoded/encoded/ -type f
```

If files remain, investigate why they weren't imported.

---

## Part 10: Summary Checklist

**Radarr Configuration**:
- ✅ Root folder set to `/movies`
- ✅ File naming enabled
- ✅ Permissions configured
- ✅ Manual import tested

**Sonarr Configuration**:
- ✅ Root folder set to `/tv`
- ✅ Episode naming enabled
- ✅ Series folder structure configured
- ✅ Manual import tested

**Workflow Verification**:
- ✅ Files visible at `/incoming-windows/`
- ✅ *arr apps can read files
- ✅ Files successfully renamed
- ✅ Files moved to final destination
- ✅ Original files deleted from Windows
- ✅ Plex library updated

---

## Related Documentation

- **SMB Mount Setup**: MEDIA-SERVER-SMB-MOUNT-GUIDE.md
- **Windows SMB Share**: `ansible/playbooks/setup-windows-smb-share.yml`
- **Main Docker Compose**: `docker-compose.yml`
- **Infrastructure Overview**: INFRASTRUCTURE.md

---

**Last Updated**: 2025-12-03
**Status**: Ready for implementation when media-server comes online
**Next Steps**:
1. Bring media-server online
2. Mount SMB share (follow MEDIA-SERVER-SMB-MOUNT-GUIDE.md)
3. Update docker-compose.yml with new volumes
4. Follow this guide to configure Radarr/Sonarr
