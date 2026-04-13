# Benchmark & Profiling Framework Plan

**Goal:** Properly benchmark Godotwind to identify performance regressions and isolate per-subsystem costs. Target: 140 FPS on modern laptop hardware.

**Current state:** ~40 FPS during flyby. Multiple systems added recently (shoreline, ocean shader, buoyancy, LOD changes, dialogues, clouds) without performance regression tracking.

---

## Phase 1 — Loading Screen Overhaul

**Problem:** Current loading overlay is semi-transparent (`Color(0.05, 0.05, 0.08, 0.95)`), no branding, and the 3D world renders behind it during loading — polluting early frame times and giving no clean separation between "loading" and "gameplay".

**Canonical pattern:** Opaque splash screen with progress bar (every shipped game does this). Godot's `CanvasLayer` at layer 100 already exists — just needs to be fully opaque + block rendering.

**Changes:**

1. **Make loading overlay fully opaque** — `Color(0.05, 0.05, 0.08, 1.0)` in `Godotwind.tscn`
2. **Add Morrowind branding** — centered logo image above the progress bar. Use existing `assets/ui/` directory for the logo texture. If no logo available, use a styled text "GODOTWIND" as placeholder.
3. **Measure and report loading time** — capture `Time.get_ticks_msec()` at start of `_init_async()`, report total at the end. Already partially done (prints `[TIMING] _init_async() total: N ms`), but should also:
   - Store `_loading_time_ms` on world_explorer for the benchmark harness to read
   - Print loading time in the console on completion
   - Include per-phase breakdown (BSA, ESM, terrain, models, streaming) — already has `_log_timing()` calls, just needs to accumulate into a dictionary
4. **Ensure streaming startup blocks the overlay** — `_on_streaming_startup_complete()` already handles this. But we need the overlay to persist through the streaming warmup (cell loading + impostor generation) until the first N cells around the player are loaded. Current behavior looks correct: `_is_loading` blocks input until `_on_streaming_startup_complete()`.
5. **Suppress 3D rendering during loading** — set `camera.current = false` during loading (no active camera = nothing to render), restore when loading completes. This prevents GPU work during data loading and gives a clean loading time measurement.

**Files touched:**
- `scenes/Godotwind.tscn` — overlay color alpha 1.0, add logo TextureRect
- `src/tools/world_explorer.gd` — loading time accumulation, camera suppression during load

**Estimate:** Small. ~30 lines changed.

---

## Phase 2 — Subsystem Toggle System

**Problem:** Need to disable individual subsystems to A/B test their performance cost. Some toggles exist (N=characters, O=ocean, K=sky via UI checkboxes + keyboard) but missing: terrain, impostors, MID-tier objects, HLOD, shadows, post-processing effects. No unified console interface.

**Canonical pattern:** Feature flag dictionary. Unreal has `showflag.*` console commands, Source has `r_draw*` cvars. We do the same: a `SubsystemToggles` RefCounted class with a `Dictionary[String, bool]` and console commands.

**Design:**

```
# Toggle registry — single source of truth
var _flags: Dictionary = {
    "terrain": true,
    "ocean": false,       # default OFF (lazy-loaded)
    "sky": true,
    "weather": true,
    "characters": false,  # default OFF
    "impostors": true,    # FAR tier
    "mid_objects": true,  # MID tier RS instances
    "near_objects": true, # NEAR tier Node3D
    "hlod": true,         # HLOD merged geometry
    "shadows": true,
    "postfx": true,       # TAA + SSAO + SSIL + glow + godrays + volumetric fog
    "terrain_grass": true, # Terrain3D instancer (if applicable)
}
```

**Console commands:**
- `toggle <name>` — flip a subsystem on/off
- `toggle list` — print all flags with current state
- `toggle only <name>` — disable everything EXCEPT named subsystem (for isolation testing)
- `toggle all` — enable everything
- `toggle none` — disable everything (baseline: just camera + empty world)

**Implementation per subsystem:**

| Subsystem | Toggle mechanism |
|-----------|-----------------|
| terrain | `terrain_3d.visible = flag` |
| ocean | Route through existing `_ocean_controls.on_show_ocean_toggled(flag)` |
| sky | Route through existing `_on_show_sky_toggled(flag)` |
| weather | `WeatherManager.set_enabled(flag)` (rain particles, etc.) |
| characters | Route through existing `_on_show_characters_toggled(flag)` |
| impostors | `native_streaming_manager.set_impostors_enabled(flag)` (new method needed — hides impostor MultiMesh) |
| mid_objects | `native_streaming_manager.set_mid_tier_enabled(flag)` (new — hides/unhides MID RS instances) |
| near_objects | `native_streaming_manager.set_near_tier_enabled(flag)` (new — hides NEAR Node3D cells) |
| hlod | `native_streaming_manager.set_hlod_enabled(flag)` (new — hides HLOD RS instances) |
| shadows | `RenderingServer.directional_light_set_shadow(light_rid, flag)` + cascades |
| postfx | Toggle each effect via Environment resource (TAA, SSAO, SSIL, glow, godrays, volumetric fog). Batch toggle using existing `_env_controls` methods. |

**Wire-up:** `SubsystemToggles` holds the dict + apply logic. Console commands registered in `_setup_console()`. Keyboard shortcuts for common ones (existing N/O/K stay). `toggle` command is the unified API — the benchmark harness uses it programmatically.

**Files touched:**
- `src/tools/subsystem_toggles.gd` — NEW, ~150 lines
- `src/tools/world_explorer.gd` — register console commands, wire toggle callbacks
- `src/core/world/native_streaming_manager.gd` — add `set_*_enabled()` methods for impostor/mid/near/hlod visibility

**Estimate:** Medium. ~200 lines new, ~40 lines modified.

---

## Phase 3 — Benchmark Harness

**Problem:** No standardized, repeatable benchmark run. The existing `StreamingBenchmark` does scripted camera paths with CSV output, but doesn't do per-subsystem isolation or A/B comparisons.

**Canonical pattern:** Game benchmark suites (like Unreal's `FPS Chart`, Source's `timedemo`, or any AAA settings screen benchmark). Scripted camera path, fixed conditions, CSV output, per-subsystem cost breakdown.

**Design:**

### 3a. Standardized Benchmark Run

Extend existing `StreamingBenchmark` with:
- **Fixed seed location:** Seyda Neen (already default)
- **Warm-up phase:** Wait for all cells in view to finish loading before starting measurement (prevents loading spikes from polluting results)
- **Fixed duration segments:** idle (5s), approach (10s), orbit (10s), sprint (10s) — already defined in existing waypoints
- **Summary output:** min/avg/p95/p99/max FPS, draw calls, memory, per-segment breakdown

### 3b. Per-Subsystem Cost Isolation

New console command: `benchmark isolate`

Runs the standard benchmark path N+1 times:
1. **Baseline:** All subsystems ON → measure FPS
2. **For each subsystem:** disable ONE subsystem, re-run the same path → measure FPS
3. **Report:** "disabling X improved FPS by Y (Z%)" for each subsystem, sorted by impact

This gives the user a clear ranking: "terrain costs 15ms/frame, ocean costs 8ms, shadows cost 5ms..."

### 3c. Quick A/B Mode

Console command: `benchmark ab <subsystem>`

1. Run 10-second benchmark with subsystem ON
2. Run 10-second benchmark with subsystem OFF
3. Print diff: FPS delta, draw call delta, memory delta

### 3d. Historical Comparison

CSV output path: `user://benchmark_results/benchmark_YYYY-MM-DD_HH-MM-SS.csv` (already exists in StreamingBenchmark). Add a summary `.json` alongside each CSV with:
- Date, git commit hash, toggle state, hardware info
- Aggregate metrics (avg FPS, p95, draw calls, memory)

Console command: `benchmark compare` — loads the two most recent summary JSONs and prints the diff.

**Files touched:**
- `src/tools/streaming_benchmark.gd` — extend with warm-up, isolation mode, A/B mode, JSON summary
- `src/tools/subsystem_toggles.gd` — `set_flag()` / `get_flag()` / `set_all()` API used by benchmark
- `src/tools/world_explorer.gd` — register `benchmark isolate`, `benchmark ab`, `benchmark compare` commands

**Estimate:** Medium-large. ~300 lines new/modified in streaming_benchmark.gd, ~30 lines in world_explorer.

---

## Implementation Order

1. **Phase 2 first** (toggles) — the benchmark harness depends on programmatic toggles
2. **Phase 1** (loading screen) — independent, can be done in parallel or after
3. **Phase 3** (benchmark) — depends on Phase 2 toggles

Within a session: Phase 2 → Phase 1 → Phase 3a (standard run) → Phase 3b-d (isolation/AB/compare).

---

## What We're NOT Building

- No custom profiler GUI — Godot's built-in profiler (F5 → Debugger → Profiler) already does per-function timing. We use `Performance` singleton + `PerformanceProfiler` for automated runs.
- No GPU profiler — use RenderDoc / Godot's GPU debugger for draw-call-level analysis.
- No memory leak detector — Godot's ObjectDB snapshots (4.6 feature) handle this.
- No "debug menu framework" — just a dict of bools + console commands. The UI checkboxes in ExplorerPanels stay as-is for the ones that already exist.

---

## Success Criteria

- Can run `benchmark` in console → get reproducible FPS numbers
- Can run `benchmark isolate` → see per-subsystem cost ranking
- Can run `toggle terrain` → terrain disappears, FPS changes visible immediately
- Loading screen is fully opaque, shows progress, reports total loading time
- Two runs on same hardware/commit produce FPS within 5% of each other (reproducibility)
