# NEAR-tier optimization — Next steps handoff

**Date:** 2026-04-22
**Branch:** `perf/distant-rendering-2026-04-17`
**Predecessor:** [near_tier_refactor.md](distant_rendering_2026_04/near_tier_refactor.md) §15.4–15.7 (Phase 1 / 3 / 4 shipped)
**Priority:** high — user-visible pop-in + shadow-dominated frame budget
**Status:** investigation + recommendations; no code changes yet

---

## Where we are

Commits on this branch (newest first):
- `c0e7b32` — heartbeat draws/objs split by visible vs shadow + shadow handoff
- `ed61cc5` — T.2 collision fix (per-frame tick, not `_finalize_request`)
- `3acd4bd` — Phase 4 T.2 per-cell merged trimesh collision
- `3174154` — Phase 3 CellPreloader (velocity-extrapolated preload)
- `6b1221d` — Phase 1 bespoke fade pool deletion

Already-shipped upstream (pre-handoff): Phase A off-thread `PackedScene.instantiate` (`4de77ed`), Phase E static precompute, Phase F prototype prereg.

**Current benchmark baseline** (see `autobench_p4_post_t2_collision` in `user://benchmark_results/`):

| Scenario | avg FPS | median | notes |
|---|---|---|---|
| `bench_tiers` (Seyda Neen steady) | 220.8 | 222 | healthy |
| `bench_teleport` | 189.4 | 234 | healthy |
| `bench_hlod_off` | 90.6 | 28 | synthetic stress; 3s recovery transient from T.2 build |

**Draws audit** (steady state, Seyda Neen): `draws=1560 (vis=331 shad=1125)` — 72% shadow pass. See [shadow_pass_optimization_2026_04_22.md](shadow_pass_optimization_2026_04_22.md) for that followup.

---

## User-reported remaining issues

From the Phase 1–4 interactive pilots:

1. **Spawn pop-in** visible at all speeds. Objects pop into existence rather than fading. Engine `VISIBILITY_RANGE_FADE_SELF` handles range crossings (walking away from existing content) but NOT newly-instantiated objects inside the visible range. [Research §4.3](../research/near_streaming_industry_patterns.md) anticipated this and sanctions a simple `RenderingServer.instance_geometry_set_transparency` time-based fade as the specific fix, **only if** user reports pop — which they did.
2. **Fast-body tunneling** through T.2 trimesh + Terrain3D — see [physics_tunneling_2026_04_22.md](physics_tunneling_2026_04_22.md).
3. **HLOD-off transient hitches** — P4 takes 3 seconds to recover from HLOD toggle (vs P3's 1s). Cell-load cold-cache shape extraction runs main-thread inside `_tick_static_collision_build` at ~20-50ms per cell on first visit.
4. **Median FPS dips** in dense areas (Balmora/Pelagiad): `draws=3582 (vis=712, shad=2766)` — shadow pass dominates.

Shadow (#4) is already written up in its own handoff. Tunneling (#2) ditto. This handoff covers #1 and #3 plus some smaller items.

---

## Priorities for the next NEAR pass

### P1. Spawn-pop transparency fade (research §4.3 — the sanctioned fallback)

**Why:** user-visible, user-reported. CellPreloader (Phase 3) reduced the FREQUENCY of pops (cells load earlier) but didn't change the MECHANISM (new MeshInstance3D appears fully opaque instantly). Engine FADE_SELF only fires on range transitions.

**Canonical approach** per [research doc §4.3](../research/near_streaming_industry_patterns.md#43-recommendation):

> For the "just-spawned, not yet at steady state" brief window, use a single RS call `instance_geometry_set_transparency(rid, 1.0)` and animate down via a shared `Time.get_ticks_msec`-driven shader uniform — **only if** user reports a visible pop after the engine-native fade; otherwise don't add the complexity.

**Do NOT re-add a bespoke fade-material pool.** Phase 1 deleted that at 50 FPS cost. The canonical approach is the RS-level transparency API, animated via a shared time uniform on the object's MATERIAL (not material_override). Far less code than the old pool (~50 LOC total).

**Implementation sketch:**

```gdscript
# On spawn (in reference_instantiator or static_object_renderer):
#   RS.instance_geometry_set_transparency(instance_rid, 1.0)   # fully transparent
#   RS.instance_geometry_set_custom_aabb(...)                   # already done
#
# Per-frame tick in native_streaming_manager._process (cheap —
# iterate "recently spawned" list bounded by fade duration):
#   for (rid, spawn_time) in _fade_in_set:
#     var t := clampf((now - spawn_time) / FADE_IN_SEC, 0.0, 1.0)
#     RS.instance_geometry_set_transparency(rid, 1.0 - t)
#     if t >= 1.0: _fade_in_set.erase(rid)
```

FADE_IN_SEC ≈ 0.25s. Research says only apply to static-renderer RS instances; Node3D interactives already have `tree_entered` connects that could mirror the same pattern but are lower priority (doors/containers don't pop as obviously).

**Estimate:** 50–100 LOC. Highest user-visible-quality ROI remaining.

### P2. Move static-shape extraction off the main thread

**Why:** T.2's cold-cache miss inside `_tick_static_collision_build` synchronously instantiates a `PackedScene` to walk for `CollisionShape3D` nodes. On first visit to a cell with 50 unique prototypes, that's ~20ms × 50 = 1000ms of main-thread stall spread across cell activation. User observed the hlod_off recovery transient directly.

**Canonical approach:** extend Phase F's `_worker_preregister_prototype` to ALSO extract the collision shape entries off-thread, storing them in the (now thread-safe) `StaticShapeCache`. By the time `_tick_static_collision_build` runs for a cell, the cache is warm because Phase F walked the same prototypes on the worker pool.

**Thread-safety notes:**
- `PackedScene.instantiate(EDIT_STATE_DISABLED)` is thread-safe (Godot 4.1+).
- Extracting `CollisionShape3D.shape` off-thread is safe — Shape3D resources are RefCounted and immutable once built.
- Insertion into `StaticShapeCache._cache` (a Dictionary) needs a Mutex or a per-prototype atomic swap pattern. Follow `static_object_renderer.gd`'s `_mesh_types_mutex` pattern from Phase E for precedent.

**Estimate:** 100–150 LOC touching `reference_instantiator.gd` (Phase F worker) + `static_shape_cache.gd` (mutex-guard the Dictionary). Eliminates the transient observed in `bench_hlod_off` P4 recovery window.

### P3. Tune CellPreloader for Godotwind-specific numbers

**Why:** Phase 3 defaults are OpenMW's (baseline `t_cache_warm = 1.0s`, max 20 cells, min 12 cells). Godotwind's actual ResourceLoader warm time is per-prototype, not per-cell, and varies with disk cache state. After Phase F is shipped, much of the "warm" cost is eliminated; the preloader may be overshooting.

**Instrumentation needed** (doesn't exist yet): add to the streaming heartbeat:
- `preload_stats` from `CellPreloader.get_stats_snapshot()` — kicked/ready/activated/evictions/cache_hits_on_load counts.
- If `cache_hits_on_load == 0` over a long run, the preloader is warming cells that never get activated → wasted worker time. Tune `PRELOAD_PREDICTION_TIME_S` downward.
- If `cache_hits_on_load >> evictions`, preload is perfectly sized for the workload.

**Estimate:** 10 LOC for the heartbeat extension + 30 minutes of pilot data. Then tune the four constants in `streaming_config.gd` (PRELOAD_EXPIRY_DELAY_MS, MIN/MAX cells, PREDICTION_TIME_S).

### P4. Unload-storm crash instrumentation (tracker §12.2 carry-over)

**Why:** an unresolved SIGSEGV at sec ≈ 183 during rapid unload churn remains on the tracker. Not triggered in recent pilots but the hazard is still in the code. The Phase 4 T.2 body adds one more Jolt broadphase registration per cell, which could compound the §12.2 unload race.

**Approach:** add `CrashBreadcrumb.write` calls inside the hazard paths listed in [near_tier_refactor.md §12.2](distant_rendering_2026_04/near_tier_refactor.md#122-second-crash-site-at-sec183--outside-_instantiate_from_scene):
- `reference_instantiator._enable_collision_shapes_in_tree` (per-node)
- `cell_manager.process_async_instantiation` batch `add_child` (per-child)
- `native_streaming_manager._process_budgeted_unloading` (per `queue_free`)
- NEW: T.2 build body attach + destroy paths
Run for > 15 minutes under unattended auto-bench to reproduce, read last breadcrumb, fix the actual site.

**Estimate:** 20 LOC for breadcrumb additions. Multi-session effort to pin the root cause.

### P5. MID tier verification + tuning (deferred — confirm state first)

User questioned whether MID is "a thing" since visible model density past NEAR_END seemed thin in pilot. Heartbeat shows `reg_slots=904, reg_batches=125` which CONFIRMS MID IS rendering — 904 static instances across 125 batches, range 0-500m default.

**But:** that doesn't mean it's tuned. The 125 batches produce ~125 draws in the visible pass (out of 331 total), and MID-tier visibility cutoff at 500m is a debatable default. Worth a dedicated pass:
- Profile which prototype types dominate MID draws (is there a long tail of unique geometries that should be HLOD-merged?).
- Verify HLOD path works post-toggle (tracker §15.2 said "visual verification pending"; still pending).
- Consider lowering `visibility_range_end` for specific ref types (e.g. clutter under 2m disappears at 200m, not 500m).

This is lower priority because MID is working. Tune only if shadow + pop-in fixes land and there's still FPS room to find.

### P6. (Speculative) Node3D interactive fade-on-spawn

After P1 (static fade) ships, the same mechanism could be wired to Node3D interactives (doors, containers, NPCs) via `tree_entered` hooks. Less user-visible than statics (interactives are sparser) but completes the pop-in elimination story.

---

## What NOT to build (anti-patterns — CLAUDE.md alignment)

- **Don't resurrect the fade-material pool.** Phase 1 deleted it for measured reasons. If spawn-pop fade needs a shader uniform, use RS `instance_geometry_set_transparency` with a time-based formula per §4.3 — no pool, no `material_override` swap.
- **Don't bake collision data into prebake sidecars yet** (statics_no_node3d T.6). P2 above (extract shapes on Phase F worker) gets most of the same win without rebaking. T.6 is a 300+ LOC effort for a marginal additional gain — defer.
- **Don't add more subsystem toggles** "for benchmarking." The existing `SubsystemToggles` set covers ablation needs. Adding flags for every new concern fragments the ablation surface.
- **Don't widen `load_radius_cells` from 1 back to 3.** Tracker §12.3 documented that user-vetoed the 3 → larger path; 1 is the tuned value matching NEAR_END visible footprint.

---

## Measurement protocol

Per change:

1. `--bench-auto=<phase_tag>` (see `auto_bench_runner.gd`) — three scenarios (`bench_tiers`, `bench_teleport`, `bench_hlod_off`).
2. Interactive pilot of 3+ minutes, read heartbeat log. Eyeball pop-in, framerate hitches.
3. Compare against the baseline in `autobench_p4_post_t2_collision/`. Regression > 5% → investigate before committing.

---

## Reference

- Research: [`docs/research/near_streaming_industry_patterns.md`](../research/near_streaming_industry_patterns.md) — §4 pop-in, §5 flight streaming, §8 CellPreloader design.
- Tracker: [`docs/plans/distant_rendering_2026_04/near_tier_refactor.md`](distant_rendering_2026_04/near_tier_refactor.md) — §15.4–15.7 for shipped phases, §12 for unresolved hazards.
- Spec (statics collision): [`docs/plans/distant_rendering_2026_04/statics_no_node3d.md`](distant_rendering_2026_04/statics_no_node3d.md) — §3.2-3.4 for T.2 (shipped), §7 for T.6 prebake sidecar (deferred).
- Other followups: [shadow_pass_optimization_2026_04_22.md](shadow_pass_optimization_2026_04_22.md), [physics_tunneling_2026_04_22.md](physics_tunneling_2026_04_22.md).

---

## CLAUDE.md principles in effect

- **Industry Standard, Never Kludge** — every P-item above names its canonical pattern (RS-level transparency fade, WorkerThreadPool shape extraction, per-body CCD). If you find yourself writing a bespoke alternative, stop and re-reach for the canonical.
- **Simplicity Over Over-Engineering** — P1 is the §4.3 "simple transparency fade" specifically BECAUSE the research doc called out that this should be the only thing built here if pop-in is reported. Don't build the shader-dither crossfade pool again.
- **Reviewer engagement scope** — this handoff is the plan-review point. Implementer: write a plan, post for review ONCE, then implement. Don't ping the reviewer mid-implementation unless you hit a canonical-pattern fork.
