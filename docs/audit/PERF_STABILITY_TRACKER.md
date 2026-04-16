# Performance + Stability Tracker

**Date:** 2026-04-16 (merges STABILITY_PERF_2026_04_15.md + STREAMING_ARCHITECTURE_PLAN.md)
**Owner:** @roaster (diagnosis), @coder (implementation)
**Status:** Active investigation. Stability fixes pending commit. Performance hypotheses under test.

---

## 1. Current State

**FPS:** ~15 steady-state at Bitter Coast spawn `(-175.5, 101.0, 1044.7)`, cell `(-2, -9)`. Target: ≥60.
**Crashes:** 0% after F3a + F3b-lite (was 66%). Fixes uncommitted.
**Tests:** 104/104 gdUnit4 green.

---

## 2. Measured Data

### Isolation Matrix (2026-04-16)

Subsystem toggle A/B testing at Bitter Coast spawn, post-crash-fix.

| Config | FPS | Frame time | Notes |
|--------|-----|-----------|-------|
| All ON (baseline) | ~16 | 62ms | 117 cells, 30k renderer objects |
| Terrain OFF | ~16 | 62ms | Terrain cost ≈ 0% |
| MID OFF | ~18 | 55ms | MID ≈ 17-20% of frame |
| Toggle NONE (pre-E1-fix) | ~24 | 41ms | NEAR toggle was broken |
| Toggle NONE (post-E1-fix) | **~280** | **3.6ms** | True floor after duplicate call removed |
| + sky | ~150 | 6.7ms | Sky shader ≈ 3ms |
| + ocean | ~90 | 11ms | Ocean shader ≈ 4.3ms |
| Skip RS creation entirely | ~21 | 47ms | 70% fewer draws, only 31% FPS gain — CPU-bound |

### Profiler Snapshot (steady state, 117 cells, loading=0)

| Metric | Value |
|--------|-------|
| proc (main thread total) | 103-141ms |
| phys | 0.3ms |
| draw calls | 7,003 |
| renderer objects | 29,997 |
| primitives | 3,038k |
| MID RS instances | 14,386 |
| NEAR promoted objects | 368 |
| distant light billboards | 2,962 (1 MultiMesh draw) |

### Benchmark CSV (2026-04-15, pre-fix)

| Metric | Stationary | Flyby |
|--------|-----------|-------|
| avg FPS | 14.5 | 41.3 |
| avg frame | 69ms | 24ms |
| p95 / p99 / max | 93 / 131 / 146ms | 50 / 136 / 145ms |
| draw calls | 7,853 | 6,845 |
| VRAM | 2,200 MB | 2,464 MB |

---

## 3. Hypothesis Table

All entries are hypotheses until verified by measurement. Status: CONFIRMED / LIKELY / UNTESTED / REJECTED / FIXED.

### Performance Hypotheses

| # | Hypothesis | Status | Evidence | Estimated impact |
|---|-----------|--------|----------|-----------------|
| **E1** | Duplicate `process_async_instantiation()` call from both `native_streaming_manager._process` and `world_explorer._process` | **CONFIRMED** | Toggle-none: 41ms → 3.6ms after removal | ~37ms/frame savings |
| **E2** | 30k RS instances iterated for AABB culling at ~3μs each even when hidden | **LIKELY (dominant)** | `objs=29,997`, `proc=103-141ms` at steady state with loading=0. Skip-RS-creation test: 70% fewer draws but only 31% FPS gain (CPU-bound, not GPU) | ~90ms/frame. Fix hypothesis: reduce RS count via MultiMesh, HLOD, or destroy-on-hide |
| **E2a** | MultiMesh batching (14k individual → ~1k batched) reduces culling from 30k to ~17k objects | **UNTESTED** | Code exists in dead sync path (`cell_manager.gd:335-520`). Industry pattern: Unreal HISM | Est. 90ms → 51ms (~40% reduction) |
| **E2b** | Destroy hidden RS instances instead of hiding them (free from scenario entirely) | **UNTESTED** | Canonical Unreal pattern — streaming range exit = instance destroy, not hide. Recreate on re-entry. | Est. 30k → ~8k (only visible objects remain) |
| **E2c** | Enable ObjectPaging HLOD (merge cell geometry into single RS instances) | **UNTESTED** | 934-line system already built (`object_paging.gd`), disabled. Merges per-chunk. | Est. 14k → ~200 HLOD instances |
| **E3** | Sky shader costs ~3ms/frame | **CONFIRMED** | 280 → 150 FPS when toggling sky ON | 3ms. Optimization: reduce cloud noise octaves, conditional complexity |
| **E4** | Ocean shader costs ~4.3ms/frame | **CONFIRMED** | 150 → 90 FPS when toggling ocean ON | 4.3ms. Optimization: reduce Gerstner wave eval, shore sampling |
| **A1** | 14k visible MID RS instances cause high draw calls (7,853) | **DEPRIORITIZED** | MID-off toggle = only 17-20% FPS improvement. Draw call count is secondary to RS culling iteration (E2) | ~7ms of the frame |
| **C4** | NEAR-tier promotion loop overshoots 1ms budget (measured 3.3ms) | **LIKELY (tertiary)** | `phase_promo_us=3290` oscillating every 2 frames. Budget check is reactive, not preemptive | ~2ms savings |
| **C1** | Diagnostic systems (DiagnosticOverlay, CrashReporter, DebugSystem, BatchDebugHUD) added unconditionally | **LIKELY (secondary)** | `[TIMING] diagnostic systems: 183-248ms` at startup. Per-frame cost unquantified | Unknown — needs profiling |
| **D3** | weather_manager._process ticks every frame (should be 1-2 Hz) | **UNTESTED** | Minor | <1ms |
| **D4** | light_animator._process iterates all lights every frame | **UNTESTED** | O(n_lights) per frame | <1ms |

### Stability Hypotheses

| # | Hypothesis | Status | Evidence |
|---|-----------|--------|----------|
| **A2** | `packed_scene.instantiate()` segfault from THREAD_LOAD_LOADED sub-resource race | **MITIGATED (F3b-lite)** | sig 11 at `model_loader.gd:548`. Rate-limited drain to 8/frame reduced crash rate from 66% to 0%. Root cause: Godot 4.6 fires THREAD_LOAD_LOADED before sub-resources fully resolved |
| **A3** | Silent native crash — no GDScript trace, no shutdown sentinel | **OPEN** | @roaster's 43.5s launch, @coder's 32s F3a-verify launch. Candidate vectors: A2 race, corrupt OccluderInstance3D in .res, Terrain3D native path |
| **B1** | mesh_rid RID lifecycle hazard in static_object_renderer | **FIXED (F3a)** | Dropped cached mesh_rid, derive at use-time, is_valid() guard. Zero errors post-fix |
| **S1** | OccluderInstance3D nodes in .res files with null/invalid shape RIDs crash `packed_scene.instantiate()` | **HYPOTHESIS (coder)** | `_strip_occluders` runs AFTER instantiate — too late if occluder triggers crash during instantiate. Fix: strip at prebake time before `PackedScene.pack()`. Applied in prebaker, pending cache rebuild. |
| **S2** | Old .res cache files persist crash-inducing data (removed DirAccess.remove_absolute calls) | **CONFIRMED (@roaster audit)** | Old code had 17 cache-deletion calls on failure; new code keeps files by design. Fix: cache rebuild with clean prebaker, or quarantine-on-failure |

---

## 4. Investigation Priority

Ordered by expected impact. Each step should be MEASURED before proceeding to the next.

1. **Commit stability fixes** (F3a + F3b-lite + E1 duplicate-call removal). Verified working, just uncommitted.
2. **Clean model cache + rebake** — eliminates S1 (occluder corruption) and S2 (stale .res files) in one pass.
3. **Measure post-commit baseline** — verify steady-state FPS with clean cache. If significantly better, remaining hypotheses may be moot.
4. **Test E2b (destroy-on-hide)** — simplest test of the RS culling hypothesis. Comment out the `instance_set_visible(false)` path, replace with `instance_free()`. Measure object count + FPS.
5. **Test E2a (MultiMesh)** — if E2b confirms RS count is the bottleneck, MultiMesh batching is the production-quality fix.
6. **Profile E3 + E4 (sky + ocean shaders)** — 7.3ms combined. Worth optimizing after CPU bottleneck is resolved.

---

## 5. Fix Status

| Fix | What | Status |
|-----|------|--------|
| F3a | Derive mesh_rid at use-time, is_valid() guard | Applied, pending commit |
| F3b-lite | Rate-limit drain to 8/frame + can_instantiate() guard | Applied, pending commit |
| E1 fix | Remove duplicate process_async_instantiation() from world_explorer | Applied, pending commit |
| Toggle fixes | MID + NEAR toggle timing bug fixed | Applied, pending commit |
| Occluder strip | Strip OccluderInstance3D at prebake time | Applied in prebaker, pending cache rebuild |
| Quarantine | Move crash-inducing .res to quarantine dir | NOT STARTED |

---

## 6. Architecture Notes (for future sessions)

**Streaming pipeline:** 9,106 lines across 9 files. Not spaghetti — file boundaries are clean, naming is clear. The issue is architectural drift: each session optimized a different axis without fixing the core rendering strategy (individual RS instances per object).

**cell_manager.gd (2,359 lines):** God object with 8+ responsibilities. Should eventually split into cell_loader + mid_tier_manager + promotion_manager. Not blocking perf fixes.

**model_loader.gd (1,160 lines):** Has 4 queues (`_model_cache`, `_pending_async_loads`, `_deferred_async_queue`, `_pending_instantiate_queue`). Each queue was added to solve a real problem, but the stack is fragile. Simplify after stability is solid.

**object_paging.gd (934 lines):** Disabled HLOD merge system. Decide its fate after E2 hypotheses are tested — enable, replace with MultiMesh, or delete.

**Dead code:** ~200 lines of MultiMesh batching in cell_manager sync path (lines 335-520) never runs at runtime (async is default). Port or delete.

---

## 7. Related Documents

- `docs/audit/MODEL_LOADER_RACE.md` — PackedScene race condition deep-dive
- `docs/audit/OBJECT_PAGING_PLAN.md` — HLOD merger design
- `docs/audit/LOD_REFACTOR_B_WIDE.md` — B-wide LOD refactor
- `docs/DISTANCE_RENDERING.md` — tier system reference
