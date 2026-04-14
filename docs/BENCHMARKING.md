# Benchmarking System

Reference for how Godotwind's benchmark + subsystem-toggle framework works. Use this before touching `streaming_benchmark.gd`, `subsystem_toggles.gd`, or the benchmark command wiring in `world_explorer.gd`.

**Status: v1 rip-out complete (2026-04-14), v2 under construction.** Plan of record: `docs/audit/BENCHMARK_V2_PLAN.md`. This doc is the *operator manual* — how to run what exists today, read results, extend it — not the design rationale. As v2 features land (HUD overlay, realistic waypoints, manual measurement blocks, progressive auto-run), update this doc alongside.

---

## Goals

Target: 140 FPS on modern laptop hardware. Current baseline (pre-optimization): ~40 FPS during flyby.

After v1 rip-out the framework answers one question directly, with two more coming in v2:
1. **Standard run** — "what FPS do we get on the canonical scripted path?" (regression tracking). Works today via `benchmark`.
2. **In-session per-subsystem cost** — "how much does each subsystem cost?" (v2, live HUD + toggle workflow).
3. **A/B** — "did this change help?" (v2, manual measurement blocks via `bench_start` / `bench_stop`).

---

## Components

### 1. `src/tools/subsystem_toggles.gd` (`SubsystemToggles`, RefCounted)
Dictionary of feature flags + apply callbacks. One public toggle per major rendering subsystem. Each flag routes through the owning subsystem's own API — never reaches into internals.

Current flags (defaults in parens):
- `terrain` (ON), `ocean` (OFF, lazy-loaded), `sky` (ON), `weather` (ON)
- `characters` (matches `_show_characters`, usually OFF)
- `impostors` (ON), `mid_objects` (ON), `near_objects` (ON), `hlod` (ON)
- `shadows` (ON), `postfx` (ON — TAA/SSAO/SSIL/glow/godrays/vfog batch)

API used by the benchmark harness:
- `set_flag(name, bool)`, `get_flag(name)`, `toggle_flag(name)`
- `enable_all()`, `disable_all()`, `isolate(name)`, `reset()`
- `get_flag_names()`, `get_state()` (for JSON metadata)

### 2. `src/tools/streaming_benchmark.gd` (`StreamingBenchmark`, Node3D)
Scripted camera path + per-frame metric capture around Seyda Neen (`SPAWN_CELL = Vector2i(-2, -9)`, camera height 100m).

Single mode: idle(3s) + approach(5s) + orbit(10s) + sprint(5s) + teleport(3s × 3 jumps) + return(4s) = **~30s**. v2 will replace this with realistic player-speed waypoints.

**Output path:** `user://benchmark_results/` (Windows: `%APPDATA%/Godot/app_userdata/Godotwind/benchmark_results/`)
- Full CSV per frame: `benchmark_<timestamp>.csv` (29 columns — see `CSV_HEADERS`)
- Events CSV: `events_<timestamp>.csv` (cell load/unload lifecycle)
- JSON summary: `summary_<timestamp>.json` (aggregate metrics + toggle state)

### 3. `world_explorer.gd` wiring
- `_setup_subsystem_toggles()` — builds the callback dict, calls `SubsystemToggles.setup()`, registers console commands.
- `StreamingBenchmark.register_console_commands(console, streaming_manager, cell_manager, camera)` — registers `benchmark` / `bench` / `benchmark_streaming` / `bench_stream`.

---

## Console Commands

Press `` ` `` (backtick) to open the console in-game.

| Command | Alias | Description |
|---------|-------|-------------|
| `benchmark` | `bench` | Run streaming benchmark (~30s) |
| `benchmark_streaming` | `bench_stream` | Same as `benchmark` |
| `toggle <name>` | `t` | Flip one subsystem on/off |
| `toggle list` | | Print all flags + current state |
| `toggle all` / `toggle none` | | Enable / disable every subsystem |
| `toggle only <name>` | | Disable everything EXCEPT `<name>` |
| `toggle reset` | | Restore defaults |

v2 will add: `hud` / `hud_reset`, `bench_start [label]` / `bench_stop`, `bench_progressive`.

---

## Metrics Captured (per frame)

Full CSV columns (`CSV_HEADERS`):

`frame, time_ms, fps, node_count, draw_calls, rendered_objects, primitives, queue_size, loaded_cells, async_requests, cam_x, cam_y, cam_z, memory_static, segment, mid_instances, mid_mesh_types, vram_mb, texture_mem_mb, promoted_objects, stream_total_ms, phase_unload_us, phase_async_us, phase_inst_us, phase_promo_us, phase_coll_us, phase_defer_us, phase_queue_us, phase_cellupd_us`

Aggregate results (in `_calculate_results()`): avg/min/max/p50/p95/p99 FPS + ms, avg/peak draw calls, peak VRAM, total frames, total time, per-segment breakdown.

---

## Interpreting JSON summaries

Each run writes `summary_<timestamp>.json` with:
- `timestamp`, `toggle_state` (dict of flags at run time)
- Aggregates: `avg_fps`, `avg_ms`, `p50_ms`, `p95_ms`, `p99_ms`, `max_ms`, `avg_draw_calls`, `peak_draw_calls`, `peak_vram_mb`
- `total_frames`, `total_time_s`

For historical comparison: diff two JSONs manually.

---

## Extending the System

### Adding a new subsystem toggle
1. Add the flag to the `callbacks` dict in `world_explorer.gd::_setup_subsystem_toggles()`, with a `Callable(bool)` that routes through the subsystem's public API. NEVER toggle internals directly — if the subsystem doesn't expose a setter, add one.
2. Add the default to the `defaults` dict.
3. `toggle list` will pick it up automatically.

### Toggle contract
`Node3D.visible = bool` does **NOT** hide raw `RenderingServer.instance_create()` RIDs. If the subsystem uses raw RS instances (MID tier, HLOD), it needs its own `set_all_visible(bool)` that iterates the RID dict and calls `RS.instance_set_visible()`. See `static_object_renderer.gd` and `runtime_hlod_merger.gd` for the canonical pattern. Public API on `NativeStreamingManager` then delegates.

### Adding a new waypoint segment
Edit `_build_waypoints()` in `streaming_benchmark.gd`. Append to `_segment_starts` with a name in the matching slot of `SEGMENT_NAMES`.

### Adding aggregate metrics
Extend `_calculate_results()` in `streaming_benchmark.gd`. Mirror into `_save_json_summary()` if you want it persisted.

---

## Pitfalls That Have Bitten Us

1. **Dictionary type mismatch crash:** Godot 4.6 rejects untyped `Dictionary` → typed `Dictionary[K, V]` assignment with SCRIPT ERROR → state corruption → signal 11. Any benchmark crash with silent exit: check for untyped local dict assigned to typed field. Canonical case was `native_impostor_renderer.gd::_compact_texture_array()` (2026-04-14).

2. **Headless FPS is not trustworthy** — the null renderer inflates tween/alloc spikes. Always use the real renderer for performance acceptance. See memory note `feedback_headless_framerates.md`.

3. **GPU TDR (D3D12 2s timeout)** — if a single frame stalls during orbit, Windows kills the GPU context and the game silently exits. Check Event Viewer → System for "Display driver stopped responding". Reproduces more on laptop iGPU than desktop.

4. **Settled state ≠ loading screen done.** The loading overlay hides when the scene tree is ready; it does NOT mean the streaming queue is drained. When running `benchmark`, wait a few seconds after the loading screen hides so the streaming queue can drain — otherwise numbers reflect streaming throughput, not steady-state rendering cost. v2 will gate on queue drain automatically.

---

## Related Files

- `src/tools/streaming_benchmark.gd` — harness (894 lines after v1 rip-out)
- `src/tools/subsystem_toggles.gd` — flag registry (170 lines)
- `src/tools/world_explorer.gd` — `_setup_subsystem_toggles()` + console command wiring
- `src/core/world/native_streaming_manager.gd` — `set_*_visible()` public API
- `docs/audit/BENCHMARK_V2_PLAN.md` — v2 design + rationale (current plan of record)
- `docs/audit/BENCHMARK_FRAMEWORK_PLAN.md` — v1 design (superseded, retained for history)
