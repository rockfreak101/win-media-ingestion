# TV Show Ripping Guide

## Automatic Detection and Handling

The media ingestion system automatically detects whether a disc is a **movie** or **TV show** based on the volume label, and adjusts ripping behavior accordingly.

---

## Detection Logic

### TV Show Patterns (triggers multi-episode ripping):
- `SEASON` - e.g., "FRIENDS_SEASON_1"
- `DISC` followed by number - e.g., "BREAKING_BAD_DISC_1"
- `S##E##` - e.g., "SHOW_S01E01"
- `EPISODES` or `EPISODE`
- `TV`
- `SERIES`

### Movie Pattern (triggers single-file ripping):
- Anything else - e.g., "THE_MATRIX", "INCEPTION", "AVATAR_2009"

---

## Ripping Behavior

### Movies (Blu-ray/DVD)
```
Input:  Movie disc (e.g., "THE_MATRIX")
Action: Query disc → Find largest title → Rip ONLY that title
Output: 1 file (main feature)

Example:
C:\MediaProcessing\rips\video\movies\The Matrix\
  └── title_t00.mkv  (136 minutes, main feature)
```

### TV Shows (DVD)
```
Input:  TV show disc (e.g., "FRIENDS_SEASON_1_DISC_1")
Action: Query disc → Find ALL titles >= 10 minutes → Rip ALL
Output: Multiple files (one per episode)

Example:
C:\MediaProcessing\rips\video\tv\Friends\Season 01\
  ├── title_t00.mkv  (22 minutes, Episode 1)
  ├── title_t01.mkv  (22 minutes, Episode 2)
  ├── title_t02.mkv  (22 minutes, Episode 3)
  └── title_t03.mkv  (22 minutes, Episode 4)
```

---

## File Naming

### Initial Rip (MakeMKV output)
Files are named by MakeMKV as `title_t##.mkv`:
- `title_t00.mkv` = First/longest title on disc
- `title_t01.mkv` = Second title
- `title_t02.mkv` = Third title
- etc.

### After Encoding (FFmpeg output)
The encoding script (`Process-VideoRips-Local.ps1`) detects S##E## patterns and routes files:

**If filename has S##E## pattern** (e.g., `Show.S01E05.mkv`):
- Destination: `C:\MediaProcessing\encoded\tv\`

**If no S##E## pattern** (e.g., `title_t00.mkv`):
- Destination: `C:\MediaProcessing\encoded\movies\`

---

## Workflow Example

### TV Show Disc Workflow

1. **Insert disc**: "BREAKING_BAD_SEASON_1_DISC_1"
2. **Detection**: Script detects "SEASON" → TV show mode
3. **Query disc**:
   ```
   Found 4 qualifying titles:
   - Title 0: 47 minutes
   - Title 1: 48 minutes
   - Title 2: 47 minutes
   - Title 3: 48 minutes
   ```
4. **Rip ALL titles**:
   ```
   MakeMKV rips 4 files to:
   C:\MediaProcessing\rips\video\tv\Breaking Bad\Season 01\
   ```
5. **Auto-eject**: Disc ejects when complete
6. **Encoding**: FFmpeg encodes each file separately
7. **Naming**: Manual renaming needed for episode numbers

### Movie Disc Workflow

1. **Insert disc**: "THE_DARK_KNIGHT"
2. **Detection**: No TV patterns → Movie mode
3. **Query disc**:
   ```
   Found 3 qualifying titles:
   - Title 0: 152 minutes (THEATRICAL)
   - Title 1: 8 minutes (trailer)
   - Title 2: 3 minutes (trailer)
   ```
4. **Rip LARGEST title**:
   ```
   MakeMKV rips title 0 (152 min) to:
   C:\MediaProcessing\rips\video\movies\The Dark Knight\title_t00.mkv
   ```
5. **Auto-eject**: Disc ejects when complete
6. **Encoding**: FFmpeg encodes the single file
7. **Transfer**: Moves to NAS as `The Dark Knight.mkv`

---

## Episode Naming

### Current State
After ripping, TV show files need manual renaming:
```
title_t00.mkv  →  Show.Name.S01E01.1080p.mkv
title_t01.mkv  →  Show.Name.S01E02.1080p.mkv
title_t02.mkv  →  Show.Name.S01E03.1080p.mkv
```

### Naming Tools/Scripts (Future Enhancement)
Options for bulk renaming:
1. **Sonarr**: Import and auto-rename based on metadata
2. **FileBot**: Batch rename with episode detection
3. **Custom script**: PowerShell rename based on disc metadata

---

## Logs and Verification

### Check What Was Detected

```powershell
# View log to see detection
Get-Content C:\Scripts\Logs\optical-monitor.log -Tail 50

# Look for these lines:
# "TV SHOW detected - will rip ALL episodes"
# "MOVIE detected - will rip largest title only"
```

### Verify Ripped Files

```powershell
# Count files ripped per disc
Get-ChildItem C:\MediaProcessing\rips\video -Recurse -Include *.mkv |
    Group-Object Directory |
    Select-Object Name, Count

# Example output:
# Name                                                Count
# ----                                                -----
# C:\MediaProcessing\rips\video\tv\Friends\Season 01    4
# C:\MediaProcessing\rips\video\movies\The Matrix       1
```

---

## Troubleshooting

### Issue: TV show disc only ripped 1 file (should be multiple)

**Cause**: Volume label didn't match TV show patterns, treated as movie

**Fix**:
1. Check volume label: `Get-Volume -DriveLetter D`
2. If label is ambiguous (e.g., "DISC_1"), manually rename or use manual rip
3. Or add to detection patterns in script (edit `Test-TVShowDisc` function)

### Issue: Movie disc ripped multiple files (should be 1)

**Cause**: Volume label matched TV show pattern incorrectly

**Fix**:
1. Check volume label - does it contain "SEASON", "DISC", etc.?
2. If false positive, manually delete extra files (keep largest)
3. Or refine detection patterns in script

### Issue: Episodes have wrong order

**Cause**: Titles on disc aren't in episode order

**Solution**:
- Check file durations: `Get-ChildItem *.mkv | Select Name, @{N='Size(GB)';E={[math]::Round($_.Length/1GB,2)}}`
- Use duration patterns to determine correct episode order
- Compare with episode guide (IMDB, TVDB)

---

## Best Practices

### TV Show Disc Naming
Ensure disc volume labels contain TV show indicators:
- ✅ "SHOW_SEASON_1"
- ✅ "SHOW_S01_DISC_1"
- ✅ "SHOW_EPISODES_1-4"
- ❌ "SHOW_VOLUME_1" (ambiguous)

### Verification Steps
After each TV show disc:
1. Count files ripped (should match episode count)
2. Check durations (episodes usually similar length)
3. Spot-check first and last episode files (playback test)

### Episode Renaming Workflow
1. Rip full season (all discs)
2. Batch rename all at once (easier than per-disc)
3. Use episode guide for accurate numbering
4. Import to Sonarr for automatic metadata

---

## Summary

| Disc Type | Detection | Rip Strategy | Output |
|-----------|-----------|--------------|--------|
| **Movie** | No TV patterns in volume label | Rip ONLY largest title | 1 file per disc |
| **TV Show** | Contains SEASON, DISC, S##E##, etc. | Rip ALL titles >= 10 min | Multiple files (episodes) |
| **Blu-ray Movie** | No TV patterns | Rip ONLY largest title | 1 file per disc |
| **Blu-ray TV** | Contains TV patterns | Rip ALL titles >= 10 min | Multiple files (episodes) |

**Subtitles**: All subtitle tracks copied automatically (English prioritized if available)

**Concurrency**: Still limited to 2 DVD + 1 Blu-ray regardless of movie/TV status

---

**Last Updated**: 2025-12-02
