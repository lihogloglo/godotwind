# Console Commands for Debugging Distance Rendering

Quick reference for troubleshooting impostors, LODs, and stuttering.

---

## Quick Start

Press `` ` `` (backtick) to open console, then run:

### **See all debug info:**
```
debug_streaming
```

### **Enable debug mode:**
```
toggle_debug
```

### **Check impostor stats:**
```
impostor_stats
```

---

## Detailed Commands

### `debug_streaming`
Prints comprehensive diagnostic information:
- Initialization status
- Camera position and cell
- All settings (load radius, frame budget, etc.)
- Current stats (loaded cells, impostors, etc.)
- Impostor renderer status

**Example output:**
```
========== NATIVE STREAMING DEBUG INFO ==========
Initialized: true
Camera: <Camera3D#12345>
Camera Cell: (3, -2)
Camera Position: (1234.5, 100.0, -5678.9)

Settings:
  load_radius_cells: 3
  impostor_radius_cells: 40
  frame_budget_ms: 8
  use_native_visibility: true
  debug_enabled: true

Stats:
  loaded_cells: 19
  total_objects: 3456
  load_queue_size: 0
  total_impostors: 234
  ...
```

---

### `toggle_debug`
Enables/disables debug logging for:
- NativeStreamingManager (cell loading)
- NativeImpostorRenderer (impostor loading)

When ON, console will show:
```
[NativeStreamingManager] Queueing 7 cells for loading...
[NativeStreamingManager] Loaded 7 cells in 42.3ms
[NativeImpostorRenderer] Loading impostors for 12 cells...
[NativeImpostorRenderer] After loading: 156 active impostors
```

**Toggle:** Run command again to turn off

---

### `impostor_stats`
Shows impostor-specific statistics:
- `total_impostors`: Number of active impostors
- `unique_textures`: Number of unique impostor textures loaded
- `pending_loads`: Textures waiting to load
- `texture_array_size`: Size of texture array

**Expected when working:**
```
Impostor Stats:
  total_impostors: 234
  unique_textures: 67
  pending_loads: 3
  texture_array_size: 67
```

**If broken:**
```
Impostor Stats:
  total_impostors: 0
  unique_textures: 0
  pending_loads: 0
  texture_array_size: 0
```
→ Impostor system not loading anything

---

## Advanced Usage (Direct Access)

You can also access the streaming manager directly via `world`:

### Check specific stats:
```
world.get_stats()
```
Returns dictionary with all stats.

### Check if initialized:
```
world._initialized
```
Should be `true`.

### Check camera cell:
```
world._camera_cell
```
Returns `Vector2i` like `(3, -2)`.

### Check loaded cells count:
```
world._loaded_cells.size()
```
Should be > 0 when playing.

### Check impostor renderer exists:
```
world._impostor_renderer != null
```
Should be `true`.

### Check impostor candidates:
```
world._impostor_renderer.impostor_candidates != null
```
Should be `true`.

---

## Troubleshooting Workflow

### 1. Basic Check
```
debug_streaming
```
Look for:
- ✅ `Initialized: true`
- ✅ `Camera: <Camera3D#...>` (not null)
- ✅ `loaded_cells: >0`
- ✅ `ImpostorCandidates: true`

### 2. Enable Detailed Logging
```
toggle_debug
```
Then fly around and watch console output.

### 3. Check Impostor Status
```
impostor_stats
```
If `total_impostors: 0` → Check:
- Are impostor textures baked? (`C:\Users\metzo\Documents\Godotwind\cache\impostors`)
- Is `impostor_radius_cells` large enough? (default 40)
- Are you far enough from objects? (impostors start at 500m)

### 4. Check LOD Configuration
After loading cells, look for these debug messages:
```
[NativeStreamingManager] Configured LOD1: model_LOD1 (range: 150-250m)
[NativeStreamingManager] Configured LOD2: model_LOD2 (range: 250-375m)
```
If you don't see these → Models don't have LOD nodes.

---

## Expected Behavior

### When Flying Around:
- Console shows cell loading messages (if debug ON)
- `loaded_cells` count changes (use `debug_streaming` to check)
- No stuttering (FPS stays stable)

### When Far from Objects:
- `impostor_stats` shows `total_impostors > 0`
- You can see billboard impostors at distance
- Smooth crossfade as you approach (impostors → LOD3 → LOD2 → LOD1 → LOD0)

### When Close to Objects:
- Full detail meshes (LOD0) visible
- LODs transition smoothly as you back away
- No white overlapping meshes
- No popping

---

## Still Having Issues?

Run `debug_streaming` and `impostor_stats`, then provide:

1. **Console output** from both commands
2. **What you expect to see** (e.g., "impostors at distance")
3. **What you actually see** (e.g., "nothing past 150m")
4. **Your position** (shown in debug output)
5. **Specific model name** you're testing with

This will help identify the exact issue!

---

*Last updated: 2026-01-08*
*See also: [DEBUGGING_DISTANCE_RENDERING.md](./DEBUGGING_DISTANCE_RENDERING.md) for detailed troubleshooting*
