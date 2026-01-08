# Debugging Distance Rendering - Runtime Diagnostics

**Purpose:** Help diagnose why impostors/LODs aren't visible

---

## Quick Diagnostic Checklist

Run the game and check these in the console/debugger:

### 1. Is NativeStreamingManager initialized?

Look for this message in console:
```
[NativeStreamingManager] Initialized with native visibility_range streaming
```

If NOT present → NativeStreamingManager failed to initialize

### 2. Is ImpostorRenderer initialized?

Look for:
```
[NativeImpostorRenderer] ImpostorCandidates initialized: true
```

If shows `false` → Impostor system won't work

### 3. Are cells loading?

When you move around, you should see:
```
[NativeStreamingManager] Queueing X cells for loading (camera at cell (...))
[NativeStreamingManager] Loaded X cells in Y.Yms (under budget)
```

If NO messages → Camera tracking broken or load_radius_cells = 0

### 4. Are impostors being added?

When flying around, look for:
```
[NativeImpostorRenderer] Loading impostors for X new cells (center: ..., radius: ...)
[NativeImpostorRenderer] After loading: X active impostors, Y pending
```

If "0 active impostors" always → Impostor candidates not finding eligible objects

### 5. Are LODs being configured?

Enable detailed logging and look for:
```
[NativeStreamingManager] Configured LOD1: ex_vivec_canton_01_LOD1 (range: 150-250m)
[NativeStreamingManager] Configured NEAR: ex_vivec_canton_01 (0-150m)
```

If NO LOD messages → Models don't have LOD nodes

---

## Console Commands for Debugging

Open the console (`) and run these:

### Check if impostor renderer exists:
```gdscript
native_streaming_manager._impostor_renderer != null
```
Should return `true`

### Check active impostors:
```gdscript
native_streaming_manager._impostor_renderer.get_stats()
```
Should show `total_impostors` > 0 when far from objects

### Check loaded cells:
```gdscript
native_streaming_manager.get_stats()
```
Look at `loaded_cells`, `load_queue_size`, `load_time_ms`

### Force debug mode:
```gdscript
native_streaming_manager.debug_enabled = true
native_streaming_manager._impostor_renderer.debug_enabled = true
```

### Check a specific object's visibility_range:
Find an object in the scene tree, then:
```gdscript
var obj = get_node("path/to/object")
print("visibility_range_begin: ", obj.visibility_range_begin)
print("visibility_range_end: ", obj.visibility_range_end)
print("visibility_range_fade_mode: ", obj.visibility_range_fade_mode)
```

---

## Common Issues and Solutions

### Issue: "No debug messages at all"

**Cause:** Debug mode not enabled

**Fix:**
```gdscript
# In world_explorer.gd or your startup script
native_streaming_manager.debug_enabled = true
```

---

### Issue: "0 active impostors" always

**Possible causes:**

1. **Impostor textures don't exist**
   - Check: `C:\Users\metzo\Documents\Godotwind\cache\impostors\`
   - Should have `.png` files like `ex_vivec_canton_01_xxxxx.png`
   - If empty → Run impostor baker first

2. **ImpostorCandidates not finding objects**
   - Models need to match patterns in `impostor_candidates.gd`
   - Common patterns: `ex_*`, `in_*_building*`, towers, etc.
   - Check console for "should_have_impostor" debug messages

3. **impostor_radius_cells too small**
   - Default is 40 cells = ~2.8km radius
   - Try increasing: `native_streaming_manager.impostor_radius_cells = 60`

---

### Issue: "LODs not visible / white overlapping meshes"

**Possible causes:**

1. **Models don't have LOD nodes**
   - NIF files need nodes named `_LOD1`, `_LOD2`, `_LOD3`
   - Check console for "Configured LOD" messages
   - If none → Models don't have preprocessed LODs

2. **LOD nodes still hidden**
   - Check `MeshVisibilityUtils.is_lod_node_name()` returns true for LOD nodes
   - Should NOT hide nodes with `_LOD` in name anymore

3. **visibility_range not configured**
   - Check specific LOD node:
     ```gdscript
     var lod1 = get_node("path/to/model_LOD1")
     print(lod1.visibility_range_begin)  # Should be 150.0
     print(lod1.visibility_range_end)    # Should be 250.0
     ```

---

### Issue: "Massive stuttering when moving"

**Possible causes:**

1. **Frame budget too high / being ignored**
   - Check console for "Frame budget exceeded" messages
   - Should see "loaded X cells, Y remaining"
   - If loading 10+ cells per frame → Budget not working

2. **Cells loading synchronously (old code path)**
   - Verify `_process_pending_loads()` is being called
   - Check `_pending_load_queue` size in stats
   - Should be small (0-5 cells)

3. **Too many cells in load_radius**
   - Default `load_radius_cells = 3` loads ~28 cells
   - Try reducing: `native_streaming_manager.load_radius_cells = 2`

4. **Heavy cell content**
   - Some cells have 500+ objects (Vivec, Balmora)
   - Frame budget might need to be lower
   - Try: `native_streaming_manager.frame_budget_ms = 5.0`

---

## Advanced Debugging: Print Full Object Hierarchy

To see what's actually in a loaded cell:

```gdscript
# Get a loaded cell
var cells = native_streaming_manager._loaded_cells
if not cells.is_empty():
    var cell_node = cells.values()[0]
    _print_hierarchy(cell_node, 0)

func _print_hierarchy(node: Node, indent: int):
    var prefix = "  ".repeat(indent)
    var info = node.name
    if node is GeometryInstance3D:
        var geo = node as GeometryInstance3D
        info += " [vis: %.0f-%.0f, fade: %d]" % [
            geo.visibility_range_begin,
            geo.visibility_range_end,
            geo.visibility_range_fade_mode
        ]
    print(prefix + info)
    for child in node.get_children():
        _print_hierarchy(child, indent + 1)
```

This will show you:
- Which meshes exist
- Their visibility_range settings
- Whether LOD nodes are present

---

## Expected Output (Working System)

When everything is working, console should look like this:

```
[NativeStreamingManager] Initialized with native visibility_range streaming
[NativeImpostorRenderer] ImpostorCandidates initialized: true
[NativeImpostorRenderer] Created fallback impostor texture (magenta)

# When moving:
[NativeStreamingManager] Queueing 7 cells for loading (camera at cell (3, -2))
[NativeStreamingManager] Loaded 7 cells in 42.3ms (under budget)
[NativeStreamingManager] Configured LOD1: ex_vivec_canton_01_LOD1 (range: 150-250m)
[NativeStreamingManager] Configured LOD2: ex_vivec_canton_01_LOD2 (range: 250-375m)
[NativeStreamingManager] Configured NEAR: ex_vivec_canton_01 (0-150m)

# When far from objects:
[NativeImpostorRenderer] Loading impostors for 12 new cells (center: (5, 5), radius: 40)
[NativeImpostorRenderer] Checking impostor texture: C:\Users\...\cache\impostors\ex_vivec_...png
[NativeImpostorRenderer] File exists: true
[NativeImpostorRenderer] Submitted async texture load job 42 for hash abc123
[NativeImpostorRenderer] After loading: 156 active impostors, 23 pending
```

---

## Still Not Working?

If you've checked everything and it's still not working, provide:

1. **Console output** (first 100 lines after startup)
2. **Stats output:** Print `native_streaming_manager.get_stats()`
3. **Impostor stats:** Print `native_streaming_manager._impostor_renderer.get_stats()`
4. **A specific model name** you expect to have LODs/impostors
5. **Your current position** in the world

This will help identify the exact issue.

---

*Last updated: 2026-01-08*
