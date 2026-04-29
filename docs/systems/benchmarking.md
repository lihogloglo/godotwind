# Benchmarking System

Operator manual for Godotwind's v2 benchmark + subsystem-toggle framework. Use this before touching `streaming_benchmark.gd`, `benchmark_hud.gd`, `progressive_benchmark.gd`, `subsystem_toggles.gd`, or the benchmark command wiring in `world_explorer.gd`.

Plan of record: `docs/plans/benchmark_v2.md`. This doc is the operator manual — how to run it, read results, extend it — not the design rationale.

---

## Goals

Target: 140 FPS on modern laptop hardware. Current baseline (pre-optimization): ~40 FPS during flyby.

The v2 framework answers three questions in one session, live:

1. **Standard run** — "what FPS do we get on the canonical scripted path?" (regression tracking). Command: `benchmark`.
2. **Per-subsystem cost** — "how much does each subsystem cost under realistic play?" (what to optimize first). Commands: `bench_progressive` for an automated additive sweep, or `hud` + `toggle <name>` for live investigation.
3. **A/B** — "did this change help?" (validate an optimization). Commands: `bench_start <label>` / `bench_stop` around the gameplay moment you care about, or manual toggle + `hud_reset` + `hud` for interactive read.

All three work in a single `scenes/Godotwind.tscn` launch. No CLI flags, no process restarts, no cross-session isolation.

---

## Components

### `src/tools/subsystem_toggles.gd` (`SubsystemToggles`, RefCounted)
Dictionary of feature flags + apply callbacks. One public toggle per major rendering subsystem. Each flag routes through the owning subsystem's own API — never reaches into internals.

Current flags (defaults in parens):
- `terrain` (ON), `ocean` (OFF, lazy-loaded), `sky` (ON), `weather` (ON)
- `characters` (matches `_show_characters`, usually OFF)
- `impostors` (ON), `mid_objects` (ON), `near_objects` (ON), `hlod` (ON)
- `shadows` (ON), `postfx` (ON — TAA/SSAO/SSIL/glow/godrays/vfog batch)

API used by benchmark harnesses:
- `set_flag(name, bool)`, `get_flag(name)`, `toggle_flag(name)`
- `enable_all()`, `disable_all()`, `isolate(name)`, `reset()`
- `get_flag_names()`, `get_state()` (for JSON metadata)

### `src/tools/streaming_benchmark.gd` (`StreamingBenchmark`, Node3D)
Scripted camera path + per-frame metric capture around Seyda Neen (`SPAWN_CELL = Vector2i(-2, -9)`). Drives the `benchmark` / `bench_start` / `bench_stop` commands. v2 flyby is realistic player-speed, 85s total:

| Segment | Duration | Motion | Purpose |
|---|---|---|---|
| settle | 10s | teleport to village + still (5m altitude) | drain streaming queue post-launch |
| idle | 15s | still at village center, ground-level | pure render cost in dense geometry |
| walk | 25s | 7 m/s north, 175m straight-line | steady streaming at walking pace |
| vista | 10s | teleport to 80m overlook + still | FAR-tier / impostor render load |
| pan | 10s | 360° look-at rotation, camera fixed, 16 sub-waypoints | frustum-culling cost |
| run | 15s | teleport to ground + 15 m/s south, 225m into fresh cells | stressed streaming |

Linear interpolation (no smoothstep) on position + look_at so "7 m/s" and "15 m/s" measurement claims actually match the camera's velocity.

### `src/tools/benchmark_hud.gd` (`BenchmarkHUD`, CanvasLayer)
Live performance overlay — replaces v1's cross-session isolation with the Unreal `stat` / Unity Profiler pattern. Default hidden, toggled with `hud`. Reveals: instantaneous FPS/ms/draws, 5s rolling avg FPS + p95 ms, VRAM + texture + node count, streaming queue + loaded cells + async requests, and the list of currently-disabled subsystem toggles. Rolling window is timestamp-based (5 real seconds, not a fixed frame count) so it stays honest under variable framerate.

UI rebuild throttled to 10Hz while visible; fully skipped while hidden so the HUD can't perturb the measurement it's reporting. Mouse events pass through (`MOUSE_FILTER_IGNORE` on the panel) so clicks/drags over the HUD rect still reach the fly-cam.

### `src/tools/progressive_benchmark.gd` (`ProgressiveBenchmark`, Node)
Drives the `bench_progressive` command — 10 × 85s scripted flybys in one session, enabling subsystems additively (baseline first, then each of terrain → near_objects → mid_objects → impostors → shadows → postfx → sky → weather → characters). Wall-clock ~14.5 min. Order: hardcoded in `PROGRESSIVE_ORDER`; `hlod` deliberately omitted while HLOD is unused. Writes one aggregate `progressive_<timestamp>.csv` with `delta_ms` column showing each subsystem's marginal rendering cost.

**Important:** progressive is additive-on-a-hot-session, NOT cross-session isolation. VRAM atlases and other allocations persist across passes, so the delta column measures RENDERING cost only. Allocation cost (launch-time) is not captured by this protocol.

### `src/tools/world_explorer.gd` wiring
- `_setup_subsystem_toggles()` — creates SubsystemToggles, BenchmarkHUD, and ProgressiveBenchmark command wiring. Fires during `_init_async` after the streaming manager is up.
- `StreamingBenchmark.register_console_commands` fires earlier, in `_setup_native_streaming_manager` — so `benchmark` / `bench_start` / `bench_stop` are available even if the progressive / HUD path fails to init.

---

## Console Commands

Press `` ` `` (backtick) to open the console in-game.

| Command | Alias | Description |
|---------|-------|-------------|
| `benchmark` | `bench` | Run the scripted 85s realistic-flyby benchmark |
| `benchmark_streaming` | `bench_stream` | Same as `benchmark` |
| `bench_start [label]` | | Begin a user-driven measurement block (drive the camera yourself) |
| `bench_stop` | | Finalize the active `bench_start` block, write CSV + JSON with the label embedded in filenames |
| `bench_progressive` | | Additive subsystem sweep, 10 × 85s flyby (~15 min) |
| `hud` | | Toggle the live benchmark HUD overlay |
| `hud_reset` | | Clear the HUD's rolling 5s window (fresh measurement after a toggle change) |
| `toggle <name>` | `t` | Flip one subsystem on/off |
| `toggle list` | | Print all flags + current state |
| `toggle all` / `toggle none` | | Enable / disable every subsystem |
| `toggle only <name>` | | Disable everything EXCEPT `<name>` |
| `toggle reset` | | Restore defaults |

---

## Typical Workflows

### 1. Regression tracking ("did last week's work regress anything?")

```
` (open console)
benchmark
(wait 85s)
```

Look for the summary table and compare `avg_fps` / `p95_ms` against the previous baseline JSON under `user://benchmark_results/`.

### 2. Interactive investigation ("what's expensive right now?")

```
` hud
` toggle none   (black screen baseline)
(wait 3s for HUD rolling window to fill)
` hud_reset
` toggle terrain
(watch HUD for ~5s, note avg FPS)
` hud_reset
` toggle near_objects
(watch HUD, note FPS drop — that's near-object marginal cost)
... repeat toggle-on-one-at-a-time ...
```

The `hud_reset` between toggles matters — without it the rolling 5s window still contains pre-toggle samples and the new number takes 5s to stabilize.

### 3. A/B measurement ("did this change help at location X?")

Before the change:
```
(fly to location X)
` bench_start loc_x_before
(stand still 30s, or do representative gameplay)
` bench_stop
```

Make the code change, rebuild, relaunch.

```
(fly to same location X)
` bench_start loc_x_after
(same duration, same camera pose)
` bench_stop
```

Diff the two JSON summaries under `user://benchmark_results/summary_loc_x_{before,after}_<ts>.json` manually. Consistent pose matters — arrange the camera by teleport if possible.

### 4. Progressive sweep (formal subsystem cost report)

```
` bench_progressive
(walk away for ~15 min)
```

The summary table prints once it's done. `progressive_<timestamp>.csv` under `user://benchmark_results/` has one row per toggle state with the `delta_ms` column showing each subsystem's marginal rendering cost under realistic-play conditions. For cold-launch cost (allocation time), a separate measurement regime is needed — `bench_progressive` does not capture that.

---

## Output Files

**Path:** `user://benchmark_results/` (Windows: `%APPDATA%/Godot/app_userdata/Godotwind/benchmark_results/`)

**Scripted flyby (`benchmark`):**
- `benchmark_<timestamp>.csv` — 30 per-frame columns (see `CSV_HEADERS` in `streaming_benchmark.gd`)
- `events_<timestamp>.csv` — cell load/unload lifecycle log
- `summary_<timestamp>.json` — aggregates + toggle state snapshot

**Manual blocks (`bench_start <label>` / `bench_stop`):**
- `benchmark_<label>_<timestamp>.csv` — label sanitized via `String.validate_filename()`
- `events_<label>_<timestamp>.csv`
- `summary_<label>_<timestamp>.json` — also contains `"label"`, `"mode": "manual"`, `"manual_duration_s"` (wall-clock, for post-hoc "did the game hang during this block?" diagnostics — diverges from `total_time_s` (frame-log-derived) under a hang)

**Progressive sweep (`bench_progressive`):**
- `progressive_<timestamp>.csv` — one row per pass, 14 columns including `delta_ms` and `enabled_subsystems`
- Per-pass StreamingBenchmark also writes its own `benchmark_<ts>.csv` / `events_<ts>.csv` / `summary_<ts>.json` under the same dir, so the user has per-frame data for any pass they want to dig into

---

## Metrics Captured (per frame)

Full CSV columns (`CSV_HEADERS`):

`frame, time_ms, fps, node_count, draw_calls, rendered_objects, primitives, queue_size, loaded_cells, async_requests, cam_x, cam_y, cam_z, memory_static, segment, mid_instances, mid_mesh_types, vram_mb, texture_mem_mb, promoted_objects, stream_total_ms, phase_unload_us, phase_async_us, phase_inst_us, phase_promo_us, phase_coll_us, phase_defer_us, phase_queue_us, phase_cellupd_us, phase_static_cull_us`

Aggregate results (in `_calculate_results()`): avg/min/max/p50/p95/p99/p99.9 FPS + ms, frames over 16.67 ms, avg/peak draw calls, peak VRAM, total frames, total time, per-segment breakdown.

---

## HUD Labels

The HUD (`hud` command) shows five lines, updated at 10Hz while visible:

- `frame: 14.3ms (70 FPS) | draws: 842`
- `5s avg: 68.2 FPS | p95: 22.1ms (298 samples)`
- `vram: 1247MB | tex: 384MB | nodes: 12384`
- `cells: 28 | queue: 0 | async: 0`
- `toggles: [OFF: ocean, weather]` — or `[ALL ON]` if nothing disabled

`nodes` is `Performance.OBJECT_NODE_COUNT` across the whole scene tree, not just the gameplay subtree.

---

## Extending the System

### Adding a new subsystem toggle
1. Add the flag to the `callbacks` dict in `world_explorer.gd::_setup_subsystem_toggles()`, with a `Callable(bool)` that routes through the subsystem's public API. NEVER toggle internals directly — if the subsystem doesn't expose a setter, add one.
2. Add the default to the `defaults` dict.
3. `toggle list` + the HUD's `[OFF: ...]` list will pick it up automatically.
4. If you want it in the progressive sweep, append the flag name to `PROGRESSIVE_ORDER` in `src/tools/progressive_benchmark.gd`. Order matters — it's strictly additive, so put cheaper subsystems first.

### Toggle contract
`Node3D.visible = bool` does **NOT** hide raw `RenderingServer.instance_create()` RIDs. If the subsystem uses raw RS instances (MID tier, HLOD), it needs its own `set_all_visible(bool)` that iterates the RID dict and calls `RS.instance_set_visible()`. See `static_object_renderer.gd` and `runtime_hlod_merger.gd` for the canonical pattern. Public API on `NativeStreamingManager` then delegates.

### Adding a new waypoint segment
Edit `_build_waypoints()` in `streaming_benchmark.gd`. Append to `_segment_starts` with a name in the matching slot of `SEGMENT_NAMES`. Adjust `FLYBY_TOTAL_S` derivation if needed; the console command descriptions read from it dynamically so they auto-update.

### Adding aggregate metrics
Extend `_calculate_results()` in `streaming_benchmark.gd`. Mirror into `_save_json_summary()` if you want it persisted. `_print_summary` pulls from the results dict directly so it shows up in the console table with minimal glue.

### Adding a HUD label
Edit `_build_ui()` to create a new `Label`, then `_rebuild_labels()` to populate it at 10Hz. If the label reads an expensive source, cache the value on the every-frame `_process` path and have `_rebuild_labels` format-only.

---

## Pitfalls That Have Bitten Us

1. **Settled state ≠ loading screen done.** The loading overlay hides when the scene tree is ready; it does NOT mean the streaming queue is drained. Wait 10-20s after the loading screen hides before running `benchmark` — otherwise the settle + idle segments reflect streaming throughput, not steady-state rendering cost. The scripted flyby's 10s `settle` segment is sized for normal drain after a short warm-up; heavier setups may need longer.

2. **Dictionary type mismatch crash:** Godot 4.6 rejects untyped `Dictionary` → typed `Dictionary[K, V]` assignment with SCRIPT ERROR → state corruption → signal 11. Any benchmark crash with silent exit: check for untyped local dict assigned to typed field. Canonical case was `native_impostor_renderer.gd::_compact_texture_array()` (2026-04-14).

3. **Headless FPS is not trustworthy** — the null renderer inflates tween/alloc spikes. Always use the real renderer for performance acceptance. See memory note `feedback_headless_framerates.md`.

4. **GPU TDR (D3D12 2s timeout)** — if a single frame stalls during the flyby, Windows kills the GPU context and the game silently exits. Check Event Viewer → System for "Display driver stopped responding". Reproduces more on laptop iGPU than desktop.

5. **`VILLAGE_ALTITUDE = 5.0` is a flat constant, not terrain-probed.** If Seyda Neen's ground at the spawn-cell center exceeds 5m, the flyby's idle segment spawns the camera underground and the "dense village render cost" measurement becomes a dirt-black frustum. Smoke-test: during a `benchmark` run, during the t=10-25s idle segment, visually confirm village geometry is visible. If not, `VILLAGE_ALTITUDE` needs a `Terrain3D.get_height()` probe (follow-up).

6. **HUD + progressive concurrency.** The HUD + scripted flyby observe the same `Performance.*` monitors independently — running both is fine. But `bench_progressive` spawns 10 sequential `StreamingBenchmark` instances, each of which writes its own `_setup_ui()` overlay. If the HUD is visible during a progressive run, you'll see the HUD + the per-pass overlay stacked. Cosmetic only; measurement numbers are unaffected.

7. **Progressive vs cold-launch cost.** `bench_progressive`'s `delta_ms` column captures RENDERING cost only — VRAM atlases, prebaked meshes, and other allocations made during earlier passes persist when a subsystem re-enables later. To measure allocation cost (launch-time), you need distinct process launches, which v2 deliberately doesn't automate. Use a manual A/B with `bench_start` in two separate sessions.

8. **`bench_start` + `bench_stop` in rapid succession leaves no frames to aggregate.** If the user stops before `_process` has fired even once (console dispatch on a paused / hung frame, immediate start+stop while the editor is frozen), `_frame_log` stays empty. `stop_manual()` detects this and returns with a `Log.warn("bench_stop: no frames recorded, nothing to save ...")` instead of crashing in `_print_summary`. The hard-fail used to exist before 2026-04-14 as an unguarded dereference of `results.total_time_s`. If you see the warn line in the log and no CSV/JSON appeared, that's why.

---

## Related Files

- `src/tools/streaming_benchmark.gd` — scripted flyby + manual blocks
- `src/tools/benchmark_hud.gd` — live HUD overlay
- `src/tools/progressive_benchmark.gd` — additive sweep orchestrator
- `src/tools/subsystem_toggles.gd` — flag registry
- `src/tools/world_explorer.gd` — `_setup_subsystem_toggles()` + command wiring
- `src/core/world/native_streaming_manager.gd` — `set_*_visible()` public API + `get_stats()`
- `docs/plans/benchmark_v2.md` — v2 design + rationale (plan of record)
