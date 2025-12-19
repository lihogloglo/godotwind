# Distant Rendering Asset Prebaking Guide

**Purpose:** Generate pre-baked merged meshes and impostor textures for distant rendering (MID and FAR tiers)

**Required:** Must be run before enabling `distant_rendering_enabled = true`

**Estimated Time:** 35-70 minutes total (mostly automated)

---

## Overview

The distant rendering system requires two types of pre-generated assets:

1. **Merged Cell Meshes** (MID tier, 500m-2km)
   - Combines all static objects in a cell into a single mesh
   - Drastically reduces draw calls (1 per cell instead of 100+)
   - Runtime loading: ~1ms per cell (essentially instant)
   - Runtime merging: 50-100ms per cell (**too slow for production**)

2. **Impostor Textures** (FAR tier, 2km-5km)
   - Pre-rendered billboards of landmarks from multiple angles
   - Allows visibility at extreme distances with minimal cost
   - Single quad per object instead of 1000+ polygons

---

## Prerequisites

### 1. Ensure Data Files Loaded

The prebaking tools require access to Morrowind ESM/BSA data:

```bash
# Verify ESMManager is configured
# Should see "Morrowind.esm" loaded in console at startup
```

If ESM data is not loaded, configure `BSAManager` and `ESMManager` in project settings.

### 2. Verify Tool Files Exist

```bash
# Check prebaking tools are present
ls src/tools/mesh_prebaker.gd
ls src/tools/impostor_baker.gd
ls src/core/world/impostor_candidates.gd
```

### 3. Ensure Output Directories Exist

```bash
# These should already exist (with .gitkeep files)
ls -la assets/merged_cells/
ls -la assets/impostors/
```

---

## Part 1: Mesh Prebaking (30-60 minutes)

### What This Does

Processes all exterior cells from (-50,-50) to (50,50) - approximately 10,000 cells - and generates merged static meshes for the MID tier.

**Output:** `res://assets/merged_cells/cell_X_Y.res` (ArrayMesh resources)

### Method 1: Headless (Recommended)

**Advantages:**
- Runs in background
- Can be automated
- No need to open editor

**Steps:**

```bash
# Navigate to project directory
cd /home/user/godotwind

# Run headless prebaking
godot --headless --script src/tools/mesh_prebaker.gd

# You should see progress output every 5 seconds:
# Progress: 10.0% (1000/10000) - Merged: 450, Empty: 550, ETA: 540s
```

**Expected Output:**
```
============================================================
MeshPrebaker - Generating merged meshes for MID tier
============================================================
Processing 10000 cells (100 x 100)

Progress: 5.0% (500/10000) - Merged: 225, Empty: 275, ETA: 1800s
Progress: 10.0% (1000/10000) - Merged: 450, Empty: 550, ETA: 1620s
...
============================================================
MeshPrebaker Complete
============================================================
Time: 1845.2 seconds (30.8 minutes)
Total cells: 10000
Merged cells: 4523 (with geometry)
Empty cells: 5477 (ocean/no objects)
Skipped cells: 0 (already pre-baked)
Failed cells: 0
Total vertices: 12458932
Total objects merged: 156783

Output: res://assets/merged_cells/
```

**Performance Expectations:**
- **Fast cells** (ocean, sparse): 0.1-1 second
- **Medium cells** (typical land): 2-5 seconds
- **Dense cells** (cities): 5-10 seconds
- **Average:** 1.8-6 seconds per cell
- **Total time:** 30-60 minutes for full world

### Method 2: Editor Script (Alternative)

**Advantages:**
- Can see visual progress in editor
- Easier to debug issues

**Steps:**

1. Open Godot editor
2. Open `src/tools/mesh_prebaker.gd`
3. Menu: **Script > Run** (or press Ctrl+Shift+X)
4. Watch console for progress

### Troubleshooting Mesh Prebaking

**Issue: "ESMManager autoload not found"**
```
Solution: Ensure ESMManager is enabled in Project > Project Settings > Autoload
```

**Issue: "Failed to create output directory"**
```
Solution: Manually create directory:
mkdir -p assets/merged_cells
```

**Issue: Process hangs on specific cell**
```
Solution: Check console for last processed cell, may have corrupt data
Add cell to skip list in mesh_prebaker.gd if needed
```

**Issue: High memory usage (>4GB)**
```
Solution: Normal for large cells. If system runs out of memory:
1. Reduce cell range in mesh_prebaker.gd (process in batches)
2. Set skip_existing = true
3. Run multiple passes for different regions
```

### Incremental Rebaking

If you need to update only specific cells:

```bash
# Edit mesh_prebaker.gd, change cell range:
const CELL_RANGE := {
    "min_x": 0,   # Only process Balmora region
    "max_x": 10,
    "min_y": -15,
    "max_y": -5,
}

# Set skip_existing to avoid redoing work:
var skip_existing: bool = true
```

---

## Part 2: Impostor Baking (5-10 minutes)

### What This Does

Renders ~70 landmark models from multiple angles to create octahedral impostor textures for the FAR tier.

**Output:**
- `res://assets/impostors/[hash]_impostor.png` (texture atlas)
- `res://assets/impostors/[hash]_impostor.json` (metadata)

### Method: Editor Console (Required)

**Note:** Impostor baking requires the editor's rendering context and cannot run headless.

**Steps:**

1. **Open Godot editor**
2. **Open the Editor Console** (View > Tool > Output)
3. **Run the following in the script debugger/console:**

```gdscript
# Create impostor baker instance
var baker = load("res://src/tools/impostor_baker.gd").new()
add_child(baker)

# Optional: Set baker properties
baker.frame_size = 256        # Resolution per frame (default: 256)
baker.frame_count = 16        # Viewing angles (default: 16)
baker.use_alpha = true        # Transparency support

# Start batch baking all landmarks
baker.bake_all_candidates()
```

4. **Monitor progress in console:**
```
ImpostorBaker: Starting batch bake of 72 models
ImpostorBaker: [1/72] Baking meshes/x/ex_vivec_canton_01.nif
ImpostorBaker: Saved impostor for meshes/x/ex_vivec_canton_01.nif
  Texture: res://assets/impostors/1234567890_impostor.png
  Size: 85.3 x 120.7 x 85.3
ImpostorBaker: [2/72] Baking meshes/x/ex_vivec_canton_02.nif
...
ImpostorBaker: Batch complete - 68 succeeded, 4 failed
```

**Expected Time:**
- ~5-15 seconds per landmark (rendering from multiple angles)
- 72 landmarks × 8 seconds average = **~10 minutes total**

### Customizing Impostor Settings

Edit `src/core/world/impostor_candidates.gd` to:

**Add new landmarks:**
```gdscript
const LANDMARK_MODELS := [
    # ... existing models ...
    "meshes/x/my_custom_landmark.nif",  # Add here
]
```

**Adjust quality per model:**
```gdscript
# In ImpostorCandidates class, add custom settings:
func get_impostor_settings(model_path: String) -> Dictionary:
    # Very important landmarks get higher quality
    if model_path.contains("vivec_palace"):
        return {
            "texture_size": 1024,  # High res
            "frames": 24,          # More angles
        }
    # Default settings for others
    return DEFAULT_SETTINGS
```

### Troubleshooting Impostor Baking

**Issue: "Failed to load model"**
```
Solution: Model may not exist or path is incorrect
Check model path against BSA contents
Some models may not have been converted to .nif yet
```

**Issue: "Model has no geometry"**
```
Solution: Model exists but has no renderable mesh
This is expected for some placeholder models - skip it
```

**Issue: Impostors look wrong (black/distorted)**
```
Solution: Adjust lighting and camera settings in impostor_baker.gd:
- Increase light energy
- Adjust camera near/far planes
- Check background_color setting
```

**Issue: Memory leak / editor crash**
```
Solution: Baker may not be cleaning up properly
Restart editor between batches
Process in smaller groups by editing LANDMARK_MODELS
```

### Verifying Impostor Output

```bash
# Check generated files
ls -lh assets/impostors/

# Should see pairs of files:
# 1234567890_impostor.png  (texture)
# 1234567890_impostor.json (metadata)

# Check metadata format:
cat assets/impostors/1234567890_impostor.json
```

**Expected JSON:**
```json
{
    "model_path": "meshes/x/ex_vivec_canton_01.nif",
    "width": 85.3,
    "height": 120.7,
    "depth": 85.3,
    "center_x": 0.0,
    "center_y": 60.35,
    "center_z": 0.0,
    "texture_size": 512,
    "frame_count": 16,
    "use_alpha": true,
    "baked_at": "2025-12-19T14:32:15"
}
```

---

## Part 3: Enabling Distant Rendering

After both prebaking processes complete:

### 1. Verify Assets Generated

```bash
# Check merged meshes
ls assets/merged_cells/*.res | wc -l
# Should show 4000-5000 files (cells with geometry)

# Check impostor textures
ls assets/impostors/*.png | wc -l
# Should show 60-70 files (landmarks)
```

### 2. Enable Distant Rendering

Edit `src/core/world/world_streaming_manager.gd`:

```gdscript
# Line 61 (approximately):
@export var distant_rendering_enabled: bool = true  # Change from false
```

### 3. Test in Editor

1. **Launch game in editor**
2. **Load a test location** (e.g., Seyda Neen)
3. **Monitor performance:**
   - Open Debug > Monitor
   - Check FPS (should remain 60)
   - Check memory usage (should be stable)

4. **Visual verification:**
   - Look at distant terrain (500m+)
   - Should see buildings/structures appear as simplified meshes
   - At 2km+, major landmarks should appear as impostors

### 4. Debug Output

Enable debug output to monitor system:

```gdscript
# In world_streaming_manager.gd:
@export var debug_enabled: bool = true
```

**Console output:**
```
[WorldStreamingManager] MID tier cell loaded: (5, -9) (pre-baked)
[WorldStreamingManager] FAR tier cell loaded: (12, -15) (8 impostors)
[DistantStaticRenderer] Loaded cells: 45, Total vertices: 1253849
[ImpostorManager] Active impostors: 23
```

---

## Part 4: Performance Monitoring

### Key Metrics to Monitor

**FPS:**
- Target: 60 FPS
- Acceptable: 45-60 FPS
- If <45 FPS: Reduce cell limits in `distance_tier_manager.gd`

**Memory:**
- Baseline (no distant rendering): ~1.5-2GB
- With distant rendering: ~2-3GB
- If >4GB: Reduce MAX_CELLS_PER_TIER limits

**Queue Stats:**
- Queue size: Should stay <100 most of the time
- If queue frequently hits max: Increase max_load_queue_size

**Cell Counts per Tier:**
- NEAR: 30-80 cells
- MID: 50-150 cells
- FAR: 100-300 cells

### Debug Overlay (Optional)

Add a debug overlay to visualize stats:

```gdscript
# In your HUD/debug UI:
func _process(_delta):
    if world_streaming_manager:
        var stats = world_streaming_manager.get_stats()
        $DebugLabel.text = """
        NEAR: %d cells
        MID: %d cells
        FAR: %d cells
        Queue: %d
        FPS: %d
        """ % [
            stats.get("near_cells", 0),
            stats.get("mid_cells", 0),
            stats.get("far_cells", 0),
            stats.get("queue_size", 0),
            Engine.get_frames_per_second()
        ]
```

---

## Part 5: Maintenance & Updates

### When to Rebake

**Merged Meshes:**
- After adding new models to the world
- After moving/editing static objects in cells
- After changing mesh simplification settings

**Impostors:**
- After adding new landmark models
- After updating existing landmark meshes
- After changing impostor quality settings

### Incremental Updates

If only a few cells changed:

```gdscript
# Edit mesh_prebaker.gd:
var skip_existing: bool = true  # Skip already-baked cells

# Only rebake specific region:
const CELL_RANGE := {
    "min_x": 2,
    "max_x": 8,
    "min_y": -12,
    "max_y": -6,
}
```

### Git Integration

**What to commit:**
```bash
# Commit the prebaked assets (they're binary but necessary)
git add assets/merged_cells/*.res
git add assets/impostors/*.png
git add assets/impostors/*.json

# Commit with descriptive message:
git commit -m "chore: Add prebaked distant rendering assets

- Generated 4523 merged cell meshes for MID tier
- Generated 68 impostor textures for FAR tier
- Enables distant rendering up to 5km view distance"
```

**Note:** These assets are large (merged_cells ~500MB-1GB, impostors ~50-100MB).
Consider using Git LFS for binary assets if repository size becomes an issue.

---

## Troubleshooting Reference

### Common Issues & Solutions

| Issue | Cause | Solution |
|-------|-------|----------|
| No distant objects appear | Assets not generated | Run prebaking tools |
| Distant objects are black | Material/texture issue | Check merged mesh materials |
| Performance drops | Too many cells loaded | Reduce MAX_CELLS_PER_TIER |
| Pop-in visible | Instantiation too slow | Increase instantiation_budget_ms |
| Memory leak | Cache not clearing | Restart after long sessions |
| Editor crashes during baking | GPU memory exhaustion | Process in smaller batches |

### Emergency Disable

If distant rendering causes issues:

```gdscript
# world_streaming_manager.gd:61
@export var distant_rendering_enabled: bool = false  # Disable
```

System will fall back to NEAR tier only (~500m view distance).

---

## Summary Checklist

### Before Enabling Distant Rendering:

- [ ] Run mesh_prebaker.gd (30-60 min)
- [ ] Verify 4000+ .res files in assets/merged_cells/
- [ ] Run impostor_baker.gd (5-10 min)
- [ ] Verify 60+ .png files in assets/impostors/
- [ ] Set distant_rendering_enabled = true
- [ ] Test at multiple locations (Seyda Neen, Balmora, Vivec)
- [ ] Monitor FPS (target: 60)
- [ ] Monitor memory (target: <3GB)
- [ ] Verify distant objects appear correctly

### For Production Deployment:

- [ ] Run full prebaking on production assets
- [ ] Commit prebaked assets to repository
- [ ] Document any custom impostor candidates
- [ ] Create performance baseline measurements
- [ ] Test on minimum spec hardware
- [ ] Add quality preset options (Low/Med/High)

---

**Guide Version:** 1.0
**Last Updated:** 2025-12-19
**Status:** Production Ready

