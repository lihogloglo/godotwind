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

## Streaming Benchmark

Automated performance measurement for the streaming pipeline. Runs a scripted camera path through the world, logs per-frame metrics, and outputs results as CSV + summary.

### `benchmark_streaming` (alias: `bench_stream`)

Full benchmark run (~30 seconds). Moves the camera through 6 phases designed to stress-test every aspect of the streaming system:

| Phase | Duration | What It Tests |
|-------|----------|---------------|
| **idle** | 3s | Time-to-stable after initial spawn |
| **approach** | 5s | Impostor→MID→NEAR transitions (800m → center at 160m/s) |
| **orbit** | 10s | Steady-state streaming, cell boundary crossings (200m radius circle) |
| **sprint** | 5s | High-speed loading pressure (600m north at 120m/s) |
| **teleport** | 3s | Worst-case teardown + rebuild (3 jumps, 500m apart) |
| **return** | 4s | Re-loading previously cached area |

**Starting location:** Seyda Neen (cell -2, -9)

### `benchmark_streaming_quick` (alias: `bench_quick`)

Quick benchmark (~18 seconds). Only runs idle + approach + orbit phases. Useful for fast iteration.

### Output

**Real-time overlay:** FPS, frame time, node count, draw calls, queue size, current phase, progress bar.

**CSV file:** Saved to `user://benchmark_results/benchmark_YYYY-MM-DD_HH-MM-SS.csv` with 15 columns per frame:

```
frame, time_ms, fps, node_count, draw_calls, rendered_objects, primitives,
queue_size, loaded_cells, async_requests, cam_x, cam_y, cam_z, memory_static, segment
```

**Console summary** (printed on completion):

```
========== STREAMING BENCHMARK RESULTS ==========
Duration: 30.2s (1812 frames)

Frame Time:
  Average: 11.2ms (89 FPS)
  P50: 9.8ms
  P95: 18.4ms
  P99: 34.2ms
  Max: 52.1ms (frame 847, segment: teleport)

Time to Stable 60 FPS: 198 frames (3.3s)

Loading:
  Peak instantiation queue: 8432
  Peak loaded cells: 49
  Peak node count: 14203

Rendering:
  Average draw calls: 1247
  Peak draw calls: 2103

Per-Segment Breakdown:
  idle:      avg  14.2ms  p99  22.1ms  (180 frames)
  approach:  avg  12.1ms  p99  28.3ms  (300 frames)
  orbit:     avg   9.8ms  p99  15.2ms  (600 frames)
  sprint:    avg  13.4ms  p99  38.7ms  (300 frames)
  teleport:  avg  18.9ms  p99  52.1ms  (180 frames)
  return:    avg   8.2ms  p99  11.4ms  (240 frames)

CSV saved to: user://benchmark_results/benchmark_2026-02-06_14-30-22.csv
==================================================
```

### Standalone Mode

The benchmark can also run as a standalone scene without the world explorer:

1. Open `src/tools/streaming_benchmark.tscn` in Godot
2. Run it directly (F5 or Ctrl+F5)
3. It will auto-initialize BSA/ESM data, create its own streaming manager, and run the benchmark

This is useful for isolated testing without the overhead of the full world explorer scene.

### Key Metrics to Watch

| Metric | What It Means | Healthy Value |
|--------|---------------|---------------|
| Time to 60 FPS | How long initial loading takes | < 1.0s (target) |
| P99 frame time | Worst 1% of frames | < 16.7ms (60 FPS) |
| Max frame time | Single worst frame | < 33ms (30 FPS floor) |
| Peak queue | Max objects waiting to instantiate | Lower = faster loading |
| Peak nodes | Scene tree size | Lower = less overhead |

### Before/After Comparison

Run the benchmark before and after making streaming changes. Compare CSV files to verify improvements:

```
# Run benchmark, note the CSV path
benchmark_streaming

# Make streaming changes...

# Run again
benchmark_streaming

# Compare the two CSV files (frame time columns, queue size, etc.)
```

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

*Last updated: 2026-02-06*
*See also: [DEBUGGING_DISTANCE_RENDERING.md](./DEBUGGING_DISTANCE_RENDERING.md) for detailed troubleshooting*
