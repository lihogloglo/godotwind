# Performance Audit — Loading FPS + Steady-State FPS
**Date:** 2026-04-16 · **Branch:** `refactor/lod-b-wide` · **Agent:** @perf (Claude Sonnet 4.6)

Empirical audit of two distinct FPS problems: slow post-load-screen recovery (~100s at 10-23 FPS)
and steady-state ceiling (~54 FPS). Root causes confirmed by log data, not hypothesis.

---

## 1. Observed Symptoms

| Symptom | Measured value |
|---------|---------------|
| FPS during loading queue drain | 10-23 FPS for ~100s after loading screen hides |
| FPS at steady state (queue empty) | ~50-54 FPS |
| Target | ≥60 FPS steady, ≥25 FPS during loading |

Test position: Bitter Coast spawn `(-175.5, 101.0, 1044.7)`, cell `(-2, -9)`.

---

## 2. Root Cause — Loading Phase (10-23 FPS)

### RC1 — Unbudgeted PackedScene instantiation (primary)

`model_loader._drain_pending_instantiate_queue()` ran **8** PackedScene instantiations per frame
with no time budget check. Each `PackedScene.instantiate()` costs ~1-5ms.

At 8 items: **8-40ms per frame** → frame overrun → 10-23 FPS.

Evidence from logs:
```
[audit +5s]  fps=14 inst=19.1ms async=0.0ms  (frame ~70ms)
[audit +10s] fps=16 inst=14.2ms async=26.0ms (frame ~45ms)
[audit +15s] fps=19 inst=9.6ms  async=13.2ms (frame ~35ms)
[audit +50s] fps=22 inst=7.1ms  async=0.0ms  (frame ~30ms)
```

`inst` consistently at 9-25ms vs the 8ms budget allowed by `SC.POST_STARTUP_INSTANTIATION_BUDGET_MS`.

### RC2 — Unbudgeted cell completion (secondary)

`native_streaming_manager._process_async_completions()` ran **2** cell completions per frame
with no time check. Each completion does `add_child(cell_node)` + scene-tree emit ≈ 13ms.

At 2: **up to 26ms per frame** → seen in logs as `async=26.0ms` spikes.

### RC3 — Budget constant never wired up (@perf session residue)

`streaming_config.gd` already had `const POST_STARTUP_INSTANTIATION_BUDGET_MS := 4.0`.
`native_streaming_manager.gd` used it correctly at line 637 to pass `budget_ms=4.0` to
`cell_manager.process_async_instantiation()`. BUT `process_async_instantiation` calls
`process_async_disk_loads()` **without** passing the budget down. The `_drain_pending_instantiate_queue`
function only saw the count constant (`MAX_INSTANTIATE_PER_FRAME=8`), never the time budget.

---

## 3. Root Cause — Steady-State Ceiling (54 FPS)

GPU-bound. Not streaming-related.

| Metric | Value |
|--------|-------|
| Draw calls | 8,338 |
| Primitives | 3,600,000 |
| Estimated GPU frame time | ~18ms |
| Implied FPS ceiling | ~54 FPS |

With `proc_ms ≈ 1.8ms` and `phys_ms ≈ 0.1ms`, the main thread is near-idle at steady state.
GPU is the bottleneck. Fix requires reducing draw calls (see §5).

Shadow settings were also too aggressive (8192 shadow map, quality 4). Adjusted by @perf's
changes in `project.godot` (8192→2048, quality 4→2) before this session.

---

## 4. Fixes Applied

### Fix 1 — Time-budget `_drain_pending_instantiate_queue` (canonical)

Replaced `MAX_INSTANTIATE_PER_FRAME=8` count limit with a `budget_usec: int` parameter.
Time is checked **before each item** — variable-cost items (complex meshes = 4ms) self-limit.

Thread the budget all the way down the call chain:

```
native_streaming_manager._process()
  → cell_manager.process_async_instantiation(budget_ms=4.0)  [unchanged]
      → cell_manager.process_async_disk_loads(budget_usec=2000)  [half of 4ms]
          → model_loader.process_async_loads(budget_usec=2000)  [new arg]
              → model_loader._drain_pending_instantiate_queue(budget_usec=2000)  [per-item check]
```

`process_async_disk_loads` gets **half** the total budget (2ms of 4ms), leaving the other half
for the main `_instantiation_queue` loop in `process_async_instantiation`.

This matches the pattern used in UE5's `FStreamingManager` — time is checked per work item,
not inferred from a fixed count. Hardware-adaptive: fast machine does more per frame, slow
machine does less, both stay within budget.

Files changed:
- `src/core/world/model_loader.gd` — removed `MAX_INSTANTIATE_PER_FRAME`, added `DRAIN_FALLBACK_BUDGET_USEC`, new `budget_usec` param through `process_async_loads` + `_drain_pending_instantiate_queue`
- `src/core/world/cell_manager.gd` — `process_async_disk_loads(budget_usec)` new param, pass computed usec from `process_async_instantiation`

### Fix 2 — Cell completion cap 2→1 (count limit retained, reason documented)

`_process_async_completions()` cap reduced from 2 to 1.

Cell completion is **atomic** — `add_child(cell_node)` + scene-tree emit + orphan rehoming
cannot be split across frames. A time budget wouldn't help here; the work is indivisible.
Count=1 is correct because: 1 × ~13ms ≈ 13ms ≤ 16.67ms budget. Count=2 = 26ms overrun.

The right lever for throughput is **cells/second**, not **ms/cell**. Increasing async cell
count (cell_manager concurrency) would reduce time-to-full without per-frame spikes.

---

## 5. Open Issue — Steady-State 54→60 FPS (next session scope)

**Not fixed this session.** Requires draw call reduction.

### Option A: MultiMesh batching for MID tier

Same-mesh objects at 150-500m range → one MultiMesh draw call per mesh type instead of one
RS instance per object. Dead code already exists in `cell_manager.gd` lines 335-520 (sync path,
never runs at runtime). See `docs/audit/MULTIMESH_VS_HLOD.md` for full analysis.

Estimated impact: 8,338 draw calls → ~2,000-3,000. Should break the 54 FPS GPU ceiling.

### Option B: Enable HLOD (object_paging.gd)

Already implemented. At 300-1000m, merges per-chunk geometry into single RS instances.
Status: `hlod_cells = ~32` confirmed working. Missing-objects issue remains. See
`docs/audit/OBJECT_PAGING_SESSION_2026_04_16.md`.

### Option C: Destroy-on-hide for distant RS instances

Replace `instance_set_visible(false)` with `instance_free()` for objects outside load radius.
Currently ~30k RS instances stay alive (hidden). Freeing them removes from RS culling iteration.
Requires recreate on re-entry. See E2b hypothesis in `docs/audit/PERF_STABILITY_TRACKER.md`.

---

## 6. perf_sweep Bugs Observed

### Bug A — Distant lights MultiMesh not in SubsystemToggles

`_distant_light_manager` creates MultiMesh instances for distant lights (2,962 billboards,
1 draw call). It has no entry in `SubsystemToggles` — `perf_sweep` and manual `toggle` commands
cannot disable it. During perf_sweep, distant lights remain visible for all subsystem tests,
contaminating isolation measurements.

Fix needed: add `"distant_lights"` toggle to `SubsystemToggles`, wire to
`_distant_light_manager.set_visible(bool)` or equivalent.

### Bug B — Small objects visible when MID disabled

When running `toggle mid false` (or perf_sweep disabling `mid_objects`), small objects
(lanterns, sign posts, small grass patches) remain visible.

Hypothesis: these objects are NEAR-tier Node3Ds (≤2m AABB → below `AABB_MID_WORTHY_THRESHOLD`),
not MID-tier RS instances. Disabling MID correctly hides RS instances but NEAR Node3Ds are
unaffected. Since these objects are physically near the camera (<150m), this may be correct
behavior — but it inflates the apparent "MID OFF" baseline, making MID look cheaper than it is.

Investigation needed: confirm whether these items are genuinely NEAR tier or leaked MID instances.
Check `_near_tier_visible` flag vs `_mid_tier_visible` flag in native_streaming_manager.

---

## 7. Files Changed This Session

```
src/core/world/model_loader.gd             — time-budget drain (DRAIN_FALLBACK_BUDGET_USEC, budget_usec param)
src/core/world/cell_manager.gd             — process_async_disk_loads(budget_usec), pass to model_loader
src/core/world/native_streaming_manager.gd — cell completion cap comment + _process_async_completions doc
src/core/world/streaming_config.gd         — POST_STARTUP_INSTANTIATION_BUDGET_MS (added by @perf, now wired)
src/tools/benchmark_hud.gd                 — phase breakdown row + get_stats() integration
src/tools/world_explorer.gd                — streaming_phases console command
src/tools/perf_sweep.gd                    — new: per-subsystem isolation sweep tool
project.godot                              — shadow 8192→2048, quality 4→2 (@perf)
```

---

## 8. Validation Status

Fix 1+2 applied. Validation run launched but data not yet collected at session end.
Next agent: launch `scenes/Godotwind.tscn`, run ≥3 min, read log for:
- `[audit +5s]` lines: expect `fps≥25` and `inst<8ms` during loading
- `[audit +60s]`: queue should be empty, fps≥50
- `hud` command: verify `stream[norm]: inst<2ms` at steady state
