# Phase E — Per-Cell Bulk Static Upload (DRAFT)

**Status:** DRAFT 2026-04-21. Authored @coder, reviewed @builder.
**Supersedes:** nothing — Phase A targeted containers, this targets statics.
**Source:** 179s pilot 2026-04-21 — see §2 data.

---

## 0. Why

Phase A shipped the off-thread split for `container / door / activator` — their `inst:` cost dropped from 4-14ms avg (session 14 dense-city) to 10-408µs (100-1000× reduction confirmed).

But the 179s pilot 2026-04-21 showed `inst:` p95 = 36.5ms, max = 60.3ms — still 3× over target. The hot path moved. **`static` now dominates:** 200-2074µs avg × 500-1000 refs / 5s window = ~260ms/s of main-thread static work during movement. That's the 25fps stutter the user flagged.

`static` is the routed-to-RS path (`_instantiate_static_object` → `StaticObjectRenderer.add_instance` → `PrototypeRegistry.add_instance`). It never went through Phase A's worker because Phase A's gate explicitly excluded STAT refs (they don't use `PackedScene.instantiate` at cache-hit; they use MultiMesh slot allocation).

---

## 1. Scope & Non-Goals

### In scope
- Move the worker-safe portion of `_instantiate_static_object` + `StaticObjectRenderer.add_instance` off the main thread.
- Pre-compute `world_transform`, `world_transform * local_transform` (per sub-mesh), `Color(spawn_time, fade_duration, 0, 0)` on worker.
- Main thread then calls a narrow API — `static_renderer.add_instance_precomputed(precomputed_data)` — that only does the MultiMesh buffer writes + dict bookkeeping.
- Same dispatch/drain pattern as Phase A — unit of work is one ref; no per-cell batching in this slice.

### Not in scope (separate phases)
- **Phase E.2** — Bulk `RS.multimesh_set_buffer` per cell per prototype. Thread-safe, one RS call uploads N transforms. Bigger refactor of `PrototypeRegistry` + `PrototypeBatch`. Deferred until E.1 measures.
- **Phase F** — T.2 merged per-cell trimesh collision from `statics_no_node3d.md`. Orthogonal.
- **Phase B** — velocity preload. Already planned; blocked on E.1 measurement.
- **`light` off-thread** — smaller contributor; defer until E.1 lands.

### Explicit non-goals
- Not changing `PrototypeRegistry` / `PrototypeBatch` internals. Their API stays.
- Not touching `model_loader.get_model` cache-hit path. Cold prototype load stays synchronous (one-time per unique prototype, amortized).
- No changes to `_instantiate_light` / `_instantiate_actor`. Separate paths.

---

## 2. Measured Data (2026-04-21 pilot, 179s)

| Metric | Value | Plan §6.2 target | Delta |
|---|---|---|---|
| `inst:` p50 | 13.0 ms | 6 ms | +117% |
| `inst:` p95 | 36.5 ms | 12 ms | +204% |
| `inst:` max | 60.3 ms | — | — |
| Frame overruns | 1160 in 179s (6.5/s) | — | — |
| `container` avg µs | 10-408 | 1000 | **5×-100× BELOW target ✓** |
| `static` avg µs | 200-2074 (cold 38050) | — | — |
| `light` avg µs | 3000-9000 | — | — |

`static` is routed to `_instantiate_static_object` → `StaticObjectRenderer.add_instance` → `PrototypeRegistry.add_instance`. Main-thread cost breakdown (warm path):
- Transform math (`CS.vector_to_godot`, `scale`, `esm_rotation_to_godot_basis`): ~50-100µs
- `_build_registry_sub_meshes` dict build: ~50-100µs × N sub-meshes
- `PrototypeRegistry.add_instance` loop × N sub-meshes:
  - `get_or_create_batch` hash lookup: ~10µs
  - `batch.acquire_slot`: ~50-200µs
  - MultiMesh `set_slot_transform` via RS: ~50-200µs (thread-local marshalling)
  - MultiMesh `set_slot_custom_data`: ~50-200µs

Worker-safe portion: transform math + local xform pre-multiplication + sub-mesh dict array. ~150-300µs per ref.
Main-thread-bound: MultiMesh slot acquire + slot write + dict bookkeeping.

Expected E.1 saving: **~150-300µs per ref × 1000 refs/5s = 30-60ms/s main thread freed**. Not enough alone to hit the plan §6.2 p95 target (needs E.2 bulk upload for that) — but ~30-50% improvement measurable, derisks E.2.

---

## 3. Target shape

### 3.1 Precomputed-data schema

New inner class in `static_object_renderer.gd`:

```gdscript
class PrecomputedInstance:
    var type_name: String              # lowercased normalized model path
    var world_transform: Transform3D
    var sub_mesh_world_xforms: PackedInt32Array  # indices into sub_meshes
    var sub_mesh_combined_xforms: Array[Transform3D]  # world * sub.local
    var custom_data: Color
    var aabb: AABB
    var cell_grid: Vector2i
    var ref_id: StringName
    var ref_num: int
```

### 3.2 Two new APIs on `StaticObjectRenderer`

```gdscript
# Worker-safe: reads _mesh_types (set once at register_from_prototype, no writes
# after). Returns null on unregistered / missing-mesh prototype — caller falls
# back to sync path (cold register_from_prototype must stay main-thread).
func precompute_instance(
    type_name: String,
    ref: CellReference,
    cell_grid: Vector2i,
) -> PrecomputedInstance:
    ...

# Main-thread: consumes the precomputed struct, does only the MultiMesh +
# dict bookkeeping that can't run off-thread.
func add_instance_precomputed(precomp: PrecomputedInstance) -> int:
    ...
```

### 3.3 Dispatch pass (extends Phase A)

`cell_manager._phase_a_dispatch_pass` currently dispatches entries whose `should_dispatch_to_worker` says "yes" and the cache has the PackedScene. For STAT refs (which `should_dispatch_to_worker` returns false for today), we add a parallel gate: `should_dispatch_static_precompute(entry, type_name)`.

The gate returns true if:
1. Ref would route to `_instantiate_static_object` (`_should_route_to_renderer` returns true)
2. Prototype is already `register_from_prototype`-ed (cold register stays main-thread — it has to walk the Node3D tree, no avoiding it)
3. Not proximity-deferred

### 3.4 Worker function

```gdscript
func _worker_precompute_static(entry: InstantiationEntry) -> void:
    var precomp = static_renderer.precompute_instance(
        entry.phase_a_static_type_name,
        entry.ref,
        entry.cell_grid_for_static,
    )
    entry.worker_static_precomp = precomp  # written last, read by drain
```

### 3.5 Drain pass

Mirrors Phase A: if `entry.worker_static_precomp != null` and task completed, call `static_renderer.add_instance_precomputed(precomp)` on main thread, record for diag, skip sync path.

### 3.6 Invariants

- Worker NEVER mutates `_mesh_types`, `_instances`, `_cell_index`, `_prototype_registry`.
- Worker NEVER calls `RenderingServer.*` (except whitelisted thread-safe reads — none needed here).
- Worker reads `_mesh_types[type_name]` which is set-once-read-many after `register_from_prototype`. Any cold-register race is avoided by the §3.3 gate (dispatch only if already registered).
- Cold register path on `_instantiate_static_object` stays synchronous main-thread — runs once per unique prototype per session, amortized.

---

## 4. Cancellation path

Identical to Phase A's `_phase_a_cancel_workers_for_request` — on cell unload / request cancel:
1. `wait_for_task_completion` for in-flight tasks
2. Discard `entry.worker_static_precomp` (no scene-tree ops yet so no leak)

No Node3D to queue_free since statics are RS-only.

---

## 5. Ops audit — worker-safe vs main-only

`_instantiate_static_object` (referenced by line, `reference_instantiator.gd:627-665`):

| Line | Op | Thread |
|---|---|---|
| 628 | `model_path.to_lower().replace("/", "\\\\")` | WORKER — pure string |
| 631 | `static_renderer.has_type(normalized)` | WORKER — read _mesh_types dict |
| 633 | `model_loader.get_model(path)` | **MAIN** — cold register path only, dispatcher gates on has_type already |
| 635 | `static_renderer.register_from_prototype(...)` | **MAIN** — same, cold only |
| 640-644 | `CS.vector_to_godot`, `scale_to_godot`, `esm_rotation_to_godot_basis`, `Transform3D` compose | WORKER — pure Vector/Basis math |
| 647-648 | `get_mesh_type_stats` read | WORKER — read _mesh_types |
| 651 | `add_instance(normalized, transform, cell_grid)` | **split** — see 5.1 |
| 656-661 | `last_static_data` dict update | **MAIN** — side-channel for GPU SDB (drain writes this post-add) |

### 5.1 Inside `StaticObjectRenderer.add_instance`

| Line | Op | Thread |
|---|---|---|
| 357 | `if type_name not in _mesh_types: return -1` | WORKER (guard) |
| 360 | `_scenario.is_valid()` | read-only RID check, WORKER |
| 364 | `_mesh_types[type_name]` | WORKER |
| 366-367 | `_next_id` increment | **MAIN** — shared counter, needs atomic or main-only |
| 369-378 | `InstanceData.new()` + field writes | split — struct alloc is thread-safe, but caller decides when to publish |
| 385-410 | registry path `add_instance` + `_instances` mutation + `_cell_index` mutation | **MAIN** — shared dict writes, MultiMesh writes |

**Compromise for E.1:** worker prepares `PrecomputedInstance` with transform math + sub_mesh xforms + custom_data; main thread does the `_next_id` increment + all dict writes + all MultiMesh calls. Saves the ~150-300µs worker portion per ref.

**Deferred to E.2:** refactor `PrototypeRegistry.add_instance` to accept a `PackedFloat32Array` bulk buffer. Worker builds per-batch buffer; main thread calls `RS.multimesh_set_buffer(rid, buffer)` once. Saves the ~500-1500µs main-thread portion per ref.

---

## 6. Measurement plan

### 6.1 Baseline (pre-E.1 = commit `4de77ed`)
- Captured 2026-04-21 pilot — see §2.

### 6.2 Target (post-E.1)
- `static` avg µs: 200-2074 → 100-1000 (transform math moved off-thread). Prediction: ~50% reduction on warm path.
- `inst:` p95: 36.5ms → 20-25ms
- Frame overruns/s: 6.5 → 3-4

### 6.3 E.1 acceptance gate

1. Interactive pilot ≥3 min, Seyda Neen + Bitter Coast, mix walk + sprint.
2. `[inst-breakdown 5s]` shows `static` avg at ≤ half the 2026-04-21 baseline.
3. `inst:` p95 ≤ 25ms.
4. No new crashes.
5. No visual regressions — statics render correctly, LOD transitions clean.
6. All gdunit4 tests pass.

### 6.4 Rollback
Same as Phase A — `git reset --hard HEAD~N` if gate fails.

---

## 7. Implementation order

Each slice committable independently.

1. **Ops audit** (no code) — `# PHASE_E:WORKER_SAFE` / `# PHASE_E:MAIN_ONLY` comments above `_instantiate_static_object` + `add_instance` helpers.
2. **Precomputed schema** — add `PrecomputedInstance` inner class to `static_object_renderer.gd` with fields.
3. **Precompute API** — implement `precompute_instance(type_name, ref, cell_grid) -> PrecomputedInstance`. Unit test it (thread-local call, no side effects).
4. **Main-thread consumer** — implement `add_instance_precomputed(precomp) -> int`. Refactor existing `add_instance` to call it after computing precomp synchronously (behavior unchanged).
5. **Entry schema extension** — add `worker_static_precomp`, `worker_static_type_name`, `worker_static_dispatched`, `worker_static_task_id` to `InstantiationEntry`.
6. **Dispatch pass extension** — add `should_dispatch_static_precompute(entry, type_name)` gate + WorkerThreadPool submission in `_phase_a_dispatch_pass`. Keep dual-path: statics that pass the gate go worker; static cold register stays sync.
7. **Drain pass extension** — when `entry.worker_static_precomp != null` and task complete, call `static_renderer.add_instance_precomputed(precomp)` instead of sync path.
8. **Cancellation path** — extend `_phase_a_cancel_workers_for_request` to include static-precomp tasks.
9. **Measurement commit** — populate §9 near_tier_refactor.md.

If §7.3-§7.7 measures < 30% reduction, stop and reassess — likely missed a main-thread-only op on the hot path. Escalate to E.2 bulk upload.

---

## 8. Risks

- **`_next_id` increment race.** Currently `_next_id` is incremented in `add_instance`. Worker doesn't touch this — precompute returns a struct with no ID. Main thread assigns ID in `add_instance_precomputed`. No race.
- **`_mesh_types[type_name]` read-during-register race.** Cold register path writes `_mesh_types` on main thread; worker reads `_mesh_types` for precompute. Dispatcher gate (§3.3 item 2) ensures register is complete before dispatch, so worker sees the fully-written entry or skips.
- **Transform math uses `CS.vector_to_godot`** — reads `CoordinateSystem` singleton. If `CS` is a static class with no mutable state, worker-safe. Must verify — pre-ship grep.
- **Sub-mesh xform composition** — `world * entry.local_transform` is pure Transform3D math, thread-safe.
- **PrecomputedInstance struct ownership** — allocated on worker, read on main. Same pattern as Phase A's `entry.worker_instance`; implicit mutex = `WorkerThreadPool.is_task_completed`.

---

## 9. After E.1 lands
Decision tree:
- If measurements hit §6.3 targets — declare E.1 done, either ship E.2 (bulk upload) OR move to T.2 (merged collision) based on whichever slice has the biggest remaining headroom.
- If measurements miss — ops audit (§5) has missed a main-thread-only op. Escalate to E.2 directly (skipping the incremental step since the worker-safe slice wasn't enough).
