# Streaming + Rendering Audit Against The Bible

Date: 2026-05-01
Auditor: auditor1 (claude)
Slice: NEAR-tier ownership / threading / benchmarks / preload
Bible: `docs/systems/streaming_rendering_bible.md`

This document scores Godotwind's current NEAR + MID + FAR streaming + rendering
code against the bible. Findings are grouped: PASS / RISK / VIOLATION / GAP.
Companion slice (MID + HLOD + FAR + LOD chain + impostors + visibility ranges
deep dive) is auditor2's piece. This file is auditor1's piece.

The headline is short. The body is long because the user asked for depth.

---

## Headline Verdict

**The architecture matches the bible at the high level.** Static visuals route
server-direct, interactives are sparse `Node3D`, payload+handle owner-token chain
is in place, threading boundaries are clean, the canonical static collision
pattern is shipped, and every `WorkerThreadPool` task is tracked and awaited.

**The architecture does NOT match the bible at the Phase 2B level.** Static
buckets are still the transitional Phase 2A shape (per-(transform × submesh) RS
instance, `_mesh_types` is the hidden lifetime owner, no `frozen` gate). This
is exactly the work the bible flags as "Outstanding" — the audit confirms it
is genuinely outstanding, not silently done.

**Benchmarks are not trustworthy as gates.** They are loggers. Every numeric
threshold the bible defines (3-4ms render, ~1ms streaming publish, p99,
max-frame, 50ms+ outliers as blocking) is captured in CSV/JSON and reported,
but no benchmark file asserts any of them as a pass/fail. `benchmark_thresholds.gd`
is unused stale 60-FPS-era constants. Stress routes exist but lack
collision-enabled variants, and there's no `material_set_shader` regression
guard. The user's intuition that benchmarks "might be returning wrong data" is
half-right — the data is sound, the validation is missing.

**Predictive preload is half-wired.** `CellPreloader` exists, uses player
velocity, has bounded LRU, expiry, cooperative cancellation. But the load
*priority* in `native_streaming_manager._update_loaded_cells` is pure
Chebyshev ring-radius, not velocity-direction-biased. So the warm cache is
predictive, the load order is not. No door/teleport destination pre-warm.

---

## Bible Rule → Score Matrix

Every accepted/outstanding/anti-pattern claim from the bible, scored against
current code with file:line cites. PASS = matches bible. RISK = matches but
fragile. VIOLATION = breaks the rule. GAP = bible says "should" and we don't.

### Bible "Accepted" claims — verifying these are still true

| Bible claim | Verdict | Evidence |
|---|---|---|
| `StreamedResourceHandle` exists and pins resources | PASS | `src/core/streaming/streamed_resource_handle.gd:1-87` — RefCounted, owner ref-count map, `add_owner`/`remove_owner`/`is_owned` all present |
| `CellPayload` owns model callbacks, prepare entries, handles, collision state | PASS | `src/core/world/cell_payload.gd:18-55` — full inventory matches bible §"Ownership Model" |
| Completed cell nodes receive handles in metadata | PASS | `cell_payload.gd:309-317` `bind_resource_handles_to_node` sets `_streamed_resource_handles` meta |
| Phase 2A routes heavy refs into `CellStaticBucket` | PASS | `static_object_renderer.gd:779-814` `create_cell_bucket` + `cell_static_bucket.gd:15-50` |
| P0.4 unload-limbo reclaim path proven | PASS | `native_streaming_manager.gd:156` `_unloading_cells`, `:175` `_unloading_request_ids`, reclaim @ `:1047-1074` |
| `StaticShapeCache` sidecar loading is single-flight | PASS (per threading subagent — `_pack_load_semaphores` mutex-protected) |
| `PHASE_A_OFFTHREAD_INSTANTIATE = false` | PASS | `cell_manager.gd:103` |
| `StaticObjectRenderer.USE_PROTOTYPE_REGISTRY = false` | PASS | `static_object_renderer.gd:76` — gate locked, no bypass found by anti-pattern subagent |
| `StreamingConfig.STATIC_CULL_NATIVE_ENABLED = false` | PASS | `streaming_config.gd:203` |
| `StreamingConfig.DEBUG_DISABLE_PHASE_F_PREREG = true` | PASS | `streaming_config.gd:432` |
| `project.godot` does not set `rendering/driver/threads/thread_model` | PASS | grep confirmed by threading subagent |
| `project.godot` does not set `physics/3d/run_on_separate_thread` | PASS | grep confirmed by threading subagent |

All bible "Accepted" claims hold. None have silently regressed.

### Bible "Outstanding" items — confirming these are still outstanding

| Bible item | Verdict | Evidence |
|---|---|---|
| Phase 2B material/RID lifetime + bucket cleanup | OUTSTANDING (confirmed) | `cell_static_bucket.gd:13-14` self-describes as "Phase 2A bucket primitive: this owns RS instance RIDs only. Mesh/material resources are still held by StaticObjectRenderer._mesh_types." |
| Per-cell/per-area MultiMesh buckets vs RS-instance-per-transform | OUTSTANDING (confirmed) | `cell_static_bucket.gd:32-46` builds one RS instance per (transform × submesh). No `MultiMesh` allocation anywhere in `CellStaticBucket`. |
| `_mesh_types` must stop being hidden lifetime owner | OUTSTANDING (confirmed) | `static_object_renderer.gd:128-130` `MeshType.mesh_resource: Mesh` + `material_resource: Material` are strong refs; `cell_static_bucket.gd` holds only RIDs |
| Frame budget split for 150 FPS | OUTSTANDING (confirmed) | `streaming_config.gd:108` `INSTANTIATION_BUDGET_MS = 8.0` — bible §"Frame Budget Targets" calls this 60-FPS-era and demands ~1ms publish split. No lane-split. `POST_STARTUP_INSTANTIATION_BUDGET_MS = 4.0` is closer but still not 1ms. |
| East-route 50ms+ outlier attribution | UNVERIFIED | No automated guard for this; would need a benchmark run + log scan |
| HLOD/FAR re-enable parked | PASS (still parked) | auditor2's slice |

All bible "Outstanding" items are still genuinely outstanding. No false advertising.

### Bible "Primary-Source Facts" — application checks

| Bible rule | Verdict | Evidence |
|---|---|---|
| Server RIDs do not own resources — strong refs required | PASS | `MeshType.mesh_resource`/`material_resource` strong refs (`static_object_renderer.gd:128-130`); `StreamedResourceHandle.extracted_meshes`/`extracted_materials` (`streamed_resource_handle.gd:6-7`); `FinalizedBody.shape: Shape3D` strong ref (`cell_static_collision.gd:132`). All three correct. |
| Scene tree main-thread-owned — `add_child` from worker is unsafe | PASS | Threading subagent verified zero worker `add_child` callsites. |
| Server calls from threads conditional on project setting | PASS | Project doesn't enable separate render/physics thread; all `RenderingServer`/`PhysicsServer3D` publication is on main. Threading subagent confirmed zero off-thread RS/Physics writes. |
| `WorkerThreadPool` tasks must be awaited | PASS (one RISK) | All Phase A/E/F + collision tasks tracked via `is_task_completed` or `wait_for_task_completion`. RISK: `native_impostor_renderer.gd:1811` rebuild task — threading subagent flagged the await gate as not explicitly visible. **Auditor2 should verify in their MID/FAR slice.** |
| `ResourceLoader` is loader, not lifetime owner | PASS | `CellPayload`/`StreamedResourceHandle` own; `ResourceLoader` is used only as the request transport |
| MultiMesh must be spatially local (per-cell, not world-scoped) | PASS at runtime, RISK in code | `USE_PROTOTYPE_REGISTRY = false` gates the world-scoped path off (`static_object_renderer.gd:76`). The world-scoped `prototype_registry.gd` code itself still exists and would be spatially wrong if re-enabled. Bible explicitly says don't re-enable without a per-cell rewrite — gate is the only thing protecting this. |
| Visibility ranges per `GeometryInstance3D`, not per MultiMesh slot | PASS | Per-instance `instance_geometry_set_visibility_range` calls in `static_object_renderer.gd:938-943` and `cell_static_bucket.gd:97-104`. Per-slot fades use the custom shader as the bible recommends. |
| Off-thread `PackedScene.instantiate` not accepted yet | PASS | Both gates `PHASE_A_OFFTHREAD_INSTANTIATE = false` and `DEBUG_DISABLE_PHASE_F_PREREG = true` enforce this. Code paths exist but are inert. |
| Godot does not define full RID free order — Godotwind owns it | PARTIAL PASS | The static collision side (`cell_static_collision.gd:439-451` `free_body`) follows the canonical "free RID first, drop strong ref second" order. The static visual bucket side (`cell_static_bucket.gd:62-70` `cleanup`) frees RIDs but does NOT first detach from `_cell_buckets` registry — the `static_object_renderer.gd:1004-1027` `remove_cell_instances` calls `cleanup()` then erases the dict. Bible §"Cleanup Order" rule 3 says "Remove the object from every registry... that could discover it on a later tick" BEFORE freeing. Order is currently reversed for buckets. |
| OpenMW validates prefetch, not RID lifetime | PASS — prefetch exists | `cell_preloader.gd` mirrors OpenMW's bounded preload + LRU + expiry + cooperative cancel. Limbo reclaim is local, justified by P0.4. |

### Bible "Anti-Patterns" — what we DO

| Anti-pattern | Verdict | Evidence |
|---|---|---|
| New permanent `*_DEFER_FRAMES_*` / `*_DEFER_TICKS_*` | RISK | 3 existing constants: `prototype_batch.gd:53,58` `UPLOAD_DEFER_TICKS_AFTER_*` (gated by `USE_PROTOTYPE_REGISTRY = false` so currently inert); `streaming_config.gd:194` `STATIC_CULL_UPLOAD_DEFER_FRAMES_AFTER_UNLOAD = 4` (referenced live in `native_streaming_manager.gd:1314, 1464, 1489`). The latter is a kludge papering over Godot 4.6 world-MultiMesh sensitivity. Bible bans NEW permanent ones; these pre-date the bible. The whole world-scoped registry is parked, so once the per-cell MultiMesh refactor lands these can go. **Action: tie removal commit to Phase 2B completion. Retrofit the comments to the new bible "Code Recipes :: Diagnostic Bridge" template (Symptom + Canonical replacement + Follow-up commit + Owner + Expiry date).** |
| Permanent `DEBUG_DISABLE_*` around a crashy system | RISK | Anti-pattern subagent found 3 live (`DEBUG_DISABLE_JOLT_ATTACH`, `DEBUG_DISABLE_CELL_STATIC_COLLISION`, `DEBUG_DISABLE_PHASE_F_PREREG`) + 1 dead (`DEBUG_DISABLE_FADE_POOL`). `DEBUG_DISABLE_PHASE_F_PREREG = true` is justified by issue #79194 still being open — bible explicitly accepts this. The other two are time-boxed Phase 0 ablation flags. None of them carry the new Diagnostic Bridge template fields (owner + expiry date). The dead one (`DEBUG_DISABLE_FADE_POOL`) should be deleted. **Action: retrofit live time-boxed flags to the bridge template, delete the dead one.** |
| Global queues crossing cell lifetimes | PASS | Anti-pattern subagent verified all relevant queues are per-request or per-cell-grid-keyed; nothing global crosses lifetimes. `_pending_child_attaches`, `_instantiation_queue`, `_pending_rs_hide_cells`, `_pending_rs_cleanup_cells` are all properly scoped. |
| World-scoped MultiMeshes for large open world | PASS (gated off) | `USE_PROTOTYPE_REGISTRY = false` |
| `PrototypeRegistry` re-enable without spatial rewrite | RISK | Bible bans this; gate is the only enforcement. No comment in the gate cites the bible — a future agent could flip it without reading the rule. **Action: add the bible reference + a runtime guard that refuses to enable without per-cell shape.** |
| Off-thread `PackedScene.instantiate` without harness | PASS (gated off) | |
| `get_node()` / RS getters every frame in hot paths | PASS | Anti-pattern subagent found zero hits. |
| Skip `wait_for_task_completion` | PASS (one RISK) | Threading subagent confirmed all paths award/cancel correctly except the impostor rebuild RISK. |
| `pop_front()` / `push_front()` on plain `Array` in hot loops | PASS | Existing uses are guard paths or per-cell drains, not hot per-frame. |
| `Area3D` `monitoring=true` without tight `collision_mask` | INVESTIGATE (out of scope) | `water_volume.gd:148`, `polygon_water_volume.gd:57`. Water system, not streaming. Flag for whoever owns water. |
| Trimesh where primitive fits | PASS | The only `ConcavePolygonShape3D` use in streaming is the canonical per-cell merged collision (`cell_static_collision.gd:330, 405`). |
| Default new hot streaming code to GDScript when C# is the better fit | RISK | Project policy in `CLAUDE.md` is "C# is the default." The streaming pipeline is mostly GDScript today. `cell_manager.gd` is 3000+ lines GDScript; `cell_static_collision.gd` triangulators are GDScript loops doing per-frame transform math. Some of this is properly scoped (engine API glue, signal handlers — GDScript is fine). Some is hot (the per-vertex `world_xf * triangles[i]` triple-push at `cell_static_collision.gd:283-287` runs on a worker, GDScript per-vertex). Auditor2 should profile MID-tier per-frame costs to see if the C# crossing matters there. |
| Raw `print()` inside `src/core/` | VIOLATION (low) | `cell_preloader.gd:324, 373` — anti-pattern subagent flagged. Should use `Log.debug("streaming", ...)`. **Action: 5-minute cleanup.** |
| `push_error`/`push_warning` for expected conditions | RISK (low) | `cell_manager.gd:631, 1604, 1635` `push_warning("No background processor")` for the legitimate fallback-to-sync path. Should be `Log.info`. **Action: minor cleanup.** |

### Bible "Cleanup Order" — applied to current code

The bible §"Cleanup Order" (and the expanded 10-step §"Phase 2B Bucket Contract :: Cleanup for a bucket") demands per unload/cancel/shutdown:

> 1. Mark request/payload/bucket as unloading or frozen.
> 2. Stop new publish work.
> 3. Remove from every registry, queue, cursor, iterator source.
> 4. (bucket version, NEW in 2026-05-01 update) Confirm no future tick can discover the bucket from a renderer or manager collection.
> 5. Await owned `WorkerThreadPool` tasks.
> 6. Hide render instances if visual stop needed (draw-stop, NOT iteration-stop).
> 7. Free server RIDs while source resources still strongly referenced.
> 8. Queue-free detached or scene-tree nodes.
> 9. Drop resource handles and cache pins.
> 10. Erase bookkeeping.

Verdict per system:

- **Cell payload unload (`cell_manager.gd::cancel_async_request` ⇒ `_drain_collision_worker_for_request`)**: PASS — order is mark unloading, stop publish, drain worker (4), then free body, then drop handles. Matches bible.
- **Static collision body free (`cell_static_collision.gd:439-451`)**: PASS — frees RID first, drops Shape3D strong ref second. Matches bible §"Server RIDs do not own resources" + free-order.
- **Static visual bucket free (`cell_static_bucket.gd::cleanup` + `static_object_renderer.gd::remove_cell_instances`)**: VIOLATION (low severity) — order is currently `cleanup() → erase from _cell_buckets`. Bible's bucket cleanup recipe (now 10 steps as of the 2026-05-01 update) says set `frozen = true` first, detach from `_cell_buckets` + hide queues + cleanup queues + publish queues + cull/upload queues + payload active records (step 2), confirm no future tick can discover (step 4), THEN free RIDs (step 7). In practice this is on the main thread and same-frame, so no other cursor can discover the bucket between the two steps today. But bible's whole point is "iteration-stop before free" because some FUTURE cursor (cull thread, upload tick) might discover it. Also: there is no `frozen` field on `CellStaticBucket` (only `visible: bool` at `cell_static_bucket.gd:10`), so even if a future cursor stumbled on it during free, no top-of-loop check exists. Phase 2B will rebuild this anyway, so the fix is to bake the new 10-step order into the new bucket cleanup, not patch the Phase 2A one. **Spec for Phase 2B implementer is now in the bible's "Code Recipes :: Cell Static Bucket" recipe.**
- **Renderer `clear()` (`static_object_renderer.gd:1280-1326`)**: RISK — also clears `_mesh_types` strong refs at the end. If any cell bucket still iterating, its RIDs become "dangling" because the underlying `Mesh`/`Material` strong ref drops. Mitigated by `_mesh_types_mutex` covering the clear, but this is exactly the bible's "_mesh_types is the hidden lifetime owner" hazard. Phase 2B fixes this by moving ownership into the bucket itself.

### Bible "Single-Flight Rules"

| Resource | Single-flight? | Evidence |
|---|---|---|
| Loaded model resources | PASS | `StreamedResourceHandle` per `cache_key` |
| Static collision sidecar shape packs | PASS | `StaticShapeCache._pack_load_semaphores` (per threading subagent) |
| Model waiter/completion queues per cell | PASS | `CellPayload.pending_model_loads_by_key` keys dedupe |
| Static prepare per cell-key | PASS | `CellPayload.static_prepare_enqueued` flag prevents double-enqueue (`cell_payload.gd:120, 131, 145`) |
| Static prototype publication per type/token | PASS (locked) | `register_from_prototype` re-checks under `_mesh_types_mutex` (`static_object_renderer.gd:225-262`) |
| Bucket creation per `(cell_grid, payload_key)` | RISK | `CellPayload.has_static_bucket(key)` guards within one payload (`cell_payload.gd:164`), but two payloads for the same cell-grid (e.g., reclaim path racing a fresh load) could each call `create_cell_bucket`. The current `_unloading_cells`/`_unloading_request_ids` reclaim guarantee is supposed to prevent this — it works today but Phase 2B should bake the (cell_grid, key) → bucket index as a hard single-flight at the renderer level, not rely on the payload-level guard. |

### Bible "Frame Budget Targets" vs current values

| Lane | Bible target (150 FPS) | Current value | File:line | Verdict |
|---|---|---|---|---|
| Render | 3-4ms | not enforced | n/a | GAP — no benchmark assertion |
| Physics | ~1ms amortized | not enforced | n/a | GAP |
| Streaming publish | ~1ms | `INSTANTIATION_BUDGET_MS = 8.0`, post-startup `4.0` | `streaming_config.gd:108, 120` | OUTSTANDING |
| Animation/gameplay/UI | remaining | n/a | n/a | not auditor1's slice |

The `8.0`/`4.0` ms budget pre-dates the 150 FPS target and was justified at 60 FPS. Bible
explicitly flags it as outstanding; this audit confirms.

### Bible "Verification Gates" vs benchmarks

Subagent-verified mapping:

| Bible Phase 2B gate | Covered by benchmark? | Status |
|---|---|---|
| dense route with collision | route exists in `streaming_stress_runner.gd`, no collision-enabled variant | NOT COVERED |
| east route with collision | route exists, no collision-enabled variant | NOT COVERED |
| reclaim boomerang route with collision | "p04-reclaim" route exists, no collision-enabled variant | NOT COVERED |
| material/RID iteration-order stress | logged, no assertion | NOT COVERED |
| no `material_set_shader` errors | logged, no assertion | NOT COVERED |
| no stale bucket discovered after detach | not tested | NOT COVERED |
| no collision finalize errors | not asserted | NOT COVERED |
| p99 / max-frame under budget | recorded, NOT asserted | NOT COVERED |

Eight bible gates, zero asserted gates today. Every one of them is logged
to CSV/JSON but no script fails the run. This is the single biggest leverage
point in the whole audit: **make the benchmarks gate, not just record.**

### Bible "Cell Preload Pattern" gaps

| Bible item | Status | Evidence |
|---|---|---|
| `CellPreloader` exists | PASS | `src/core/world/cell_preloader.gd` |
| Predict from velocity + prediction time | PASS | `cell_preloader.gd:115-259`, velocity from `native_streaming_manager.gd:743-748` |
| Preload outer grid around predicted position | PARTIAL | Preloader warms ahead-of-velocity; load *priority* in `native_streaming_manager._update_loaded_cells` is pure Chebyshev radius, not direction-biased. Cells warm but the load queue still loads farthest-cardinal first. |
| Preload door/teleport destinations | NOT IMPLEMENTED | No door-destination/interior-pocket pre-warm path found |
| Bounded cache: max + min + expiry | PASS | `streaming_config.gd:390, 394, 398` `PRELOAD_EXPIRY_DELAY_MS=5000`, `MIN=12`, `MAX=20` |
| Update timestamps on reuse | PASS | `cell_preloader.gd:125` |
| Abort work on load/clear/expiry | PASS | Cooperative cancel `cell_preloader.gd:435-438` |
| Fast teleports abort + reseed | PASS (abort), PARTIAL (reseed) | abort_all on teleport `cell_preloader.gd:735`, reset to new anchor `:736`. No destination pre-warm, just radius-around-new-anchor. |

---

## Recommended Action List

Priorities are auditor1's call; user decides what ships when. Listed roughly
in order of return-on-effort.

**Tier 1 — high leverage, mechanical work, would prove out the bible**

1. **Make benchmarks gate, not log.** Add assertions to `streaming_benchmark.gd` for `p99_ms < 16.67` (60 FPS floor) or `< 6.67` (150 FPS target), `max_time_ms < 50.0` (bible's blocking-failure threshold). Replace `benchmark_thresholds.gd` constants with bible's actual targets (`STREAMING_PUBLISH_BUDGET_MS = 1.0`, `RENDER_BUDGET_MS = 3.5`, `FRAME_BUDGET_MS = 6.67`). Wire the constants into the benchmark drivers.
2. **Wire collision-enabled stress variants** into `streaming_stress_runner.gd` (`--stress-collision` flag). Run boomerang/dense/east routes with collision enabled, assert no `material_set_shader` errors in the log, no collision finalize errors.
3. **Check in baseline JSONs** for streaming/auto/ladder benchmarks under `docs/benchmark_baselines/`. Per-commit regression detection beats "the user remembers what the FPS was last week."
4. **Phase 2B implementation** (the bible's whole point). Per-cell MultiMesh draw groups, bucket owns mesh+material strong refs directly, `frozen` flag, detach-before-free order. The whole §"Phase 2B Bucket Contract" + §"Minimum Acceptance" sections of the bible become the spec.

**Tier 2 — quality cleanups**

5. Replace `print()` in `cell_preloader.gd:324, 373` with `Log.debug("streaming", ...)`.
6. Replace `push_warning("No background processor")` in `cell_manager.gd:631, 1604, 1635` with `Log.info` — it's a fallback path, not an error.
7. Delete dead `DEBUG_DISABLE_FADE_POOL` (`streaming_config.gd:422`) — pool is gone, no callers.
8. Add a runtime guard at `static_object_renderer.gd:76`: if a future caller flips `USE_PROTOTYPE_REGISTRY = true`, push an error referencing the bible §"MultiMesh must be spatially local" and refuse to instantiate. Right now nothing prevents a future agent from flipping this.
9. Retrofit live time-boxed `DEBUG_DISABLE_*` and `*_DEFER_TICKS_*` constant comments to the bible's new "Code Recipes :: Diagnostic Bridge" template — Symptom + Canonical replacement + Follow-up commit + Owner + Expiry date. Anything that does not fit the template is a kludge per the bible's own definition.

**Tier 3 — research / measure first**

10. Velocity-direction-biased load priority in `native_streaming_manager._update_loaded_cells`. This is the gap between the warm cache and the load queue. Probably worth ~50-150ms of cell-cross stall reduction at high speed. But measure first — if cells already warm by the time they enter radius, this doesn't matter.
11. Door/interior-pocket destination pre-warm. Currently the first interior portal load after a teleport eats a cold cache. Wire `cell_preloader` into the teleport path to pre-stage the destination cell BEFORE the camera jumps.
12. Profile MID-tier per-frame work. The render side is GDScript-heavy in places; bible policy is C# default. Don't rewrite without numbers, but get the numbers.
13. Investigate threading-subagent's RISK on `native_impostor_renderer.gd:1811` rebuild task — explicit await gate not visible in the code I (auditor1) read; auditor2 should confirm.

**Tier 4 — Phase 2B prereqs the bible already lists**

14. Build the targeted material/RID iteration-order stress test that reproduces the historical `material_set_shader` failure before fix. Bible §"Minimum Acceptance For Phase 2B" requires this.
15. East-route 50ms+ outlier attribution. No automated guard today; need a stress run with frame-time histogram + cell-transition log alignment.

---

## What I'm NOT Saying

- I am NOT saying the architecture should be rewritten. The architecture is right. The Phase 2B implementation is just half-done.
- I am NOT saying benchmarks are wrong. The data they collect is real. The problem is they don't validate that data against bible thresholds.
- I am NOT saying we should re-enable the world-scoped `PrototypeRegistry`. The bible bans it without a per-cell rewrite, and current code correctly gates it off.
- I am NOT recommending we delete `_unloading_cells`/`_unloading_request_ids`. Bible explicitly warns against this, and the boomerang reclaim path depends on it.

---

## Confidence

- Threading boundary findings: HIGH. Subagent enumerated all worker dispatches and traced await gates; matches bible rules end-to-end.
- Anti-pattern findings: HIGH. Subagent grep coverage of `src/`.
- Benchmark findings: HIGH. Subagent read every benchmark file; confirmed no assertions.
- Predictive preload findings: HIGH. Subagent verified `CellPreloader` + `native_streaming_manager` integration.
- Phase 2B implementation gap (the central finding): HIGH. I read `cell_static_bucket.gd`, `cell_payload.gd`, `static_object_renderer.gd` end-to-end; the gap is self-described in the code.
- MID/HLOD/FAR specifics: LOW. Auditor2's slice — I deliberately did not deep-dive the LOD chain, impostor rebuild lifecycle, or HLOD chunk merger.

End of report.
