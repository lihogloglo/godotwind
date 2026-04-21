# Phase F — Off-Thread Prototype Pre-Registration

**Status:** SHIPPED 2026-04-21. Commit `032df30` + follow-up shutdown-drain fix (Blocker 1 from @builder's post-ship review).
**Authors:** @coder (implementation), @builder (review + blocker identification).
**Supersedes:** nothing — widens the Phase A/E off-thread pattern to the cold-register path, which neither phase covered.
**Source data:** pilot logs 2026-04-21 15:27 (pre-Phase-F baseline) + 16:41 (post-Phase-F, 53 windows, 224s).

---

## 1. Why

Pilot logs post-E.1 showed `static` per-type avg spiking to 38050µs on first exposure of a new prototype (cold-register), dropping to 130-2264µs warm. In dense areas (Pelagiad, Balmora) a cell's 50+ unique types each pay one cold stall = ~1900ms of main-thread freeze at cell crossing.

Phase A (container off-thread) and Phase E.1 (static transform-math precompute) both assume `_mesh_types[type_name]` is already populated. Cold-register (`register_from_prototype`) walks a newly-instantiated Node3D prototype's sub-mesh tree — and the PackedScene.instantiate that produces the prototype was still on the main thread.

**Phase F moves the cold-register path (prototype PackedScene load + instantiate + walk + register) onto `WorkerThreadPool`.** When a cell enters the async load queue, the instantiator dedupes its unique STAT model paths and dispatches one pre-reg task per unique path. Workers finish before the cell's static refs reach the instantiate queue, so `should_dispatch_static_precompute` returns true (fast path) instead of falling through to sync cold-register.

---

## 2. Scope & Non-Goals

### In scope
- Worker-thread PackedScene load + instantiate for STAT prototypes (thread-safe per Godot 4.1+ resolution of issue #79194).
- Worker-thread `register_from_prototype` call. `_mesh_types_mutex` protects the insert (already added by @builder in Phase E fix-up).
- Main-thread dispatcher that walks `cell_record.references`, dedupes unique STAT model paths, resolves disk paths via `model_loader.resolve_disk_path`.
- Shutdown-drain pattern: track dispatched `WorkerThreadPool.add_task` task_ids in `_prereg_task_ids`, drain via `wait_for_task_completion` in `CellManager.fast_cleanup` (called by `NativeStreamingManager.fast_cleanup` on `WM_CLOSE_REQUEST` BEFORE `_static_renderer.clear()`).

### Not in scope (separate phases)
- **Phase E.3** — light off-thread. `_instantiate_light` uses a Node3D + OmniLight3D construction path, not `register_from_prototype`. Phase F's pattern doesn't apply. Deferred to a separate slice that widens Phase A's dispatcher.
- **Corrected-E.2 bulk static write** — per-cell bulk `PackedFloat32Array` transform / custom_data packing. Orthogonal, real win but not as large as Phase F. Potential follow-up.
- **cellupd:274ms outlier** — separate investigation; not bundled here.
- **Interactive (DOOR/CONT/ACTI) pre-registration** — they use `_instantiate_model_object` (Phase A), not `_instantiate_static_object`. No `_mesh_types` dependency. Pre-reg wouldn't help.

### Explicit non-goals
- Not changing `PrototypeRegistry` / `PrototypeBatch` internals.
- Not changing `ReferenceInstantiator` routing logic (`_should_route_to_renderer`).
- Not introducing a new LRU preload cache — relies on `ResourceLoader`'s built-in reference-count cache + `MeshType`'s strong mesh/material refs for lifetime management.

---

## 3. Main-thread dispatcher (`preregister_cell_statics`)

```gdscript
func preregister_cell_statics(cell_record: Variant) -> int:
    # 1. Walk cell_record.references
    # 2. For each ref:
    #    - Resolve base_record + type_name via ESMManager (autoload, main-only)
    #    - Filter: must be STAT-routed (_should_route_to_renderer true)
    #    - Skip if static_renderer.has_type(normalized) already true
    #    - Dedupe on normalized model_path
    #    - Resolve disk_path via model_loader.resolve_disk_path (worker-safe)
    # 3. Dispatch one WorkerThreadPool.add_task per unique path
    # 4. Track each task_id in _prereg_task_ids for shutdown drain
```

Called by `CellManager.request_exterior_cell_async` and `request_cell_async` immediately after `ESMManager.get_*_cell` returns the `cell_record`. Idempotent across cells — repeat visits dispatch 0 tasks once types are warm.

---

## 4. Worker (`_worker_preregister_prototype`)

```gdscript
func _worker_preregister_prototype(type_name: String, disk_path: String) -> void:
    # 1. Fast-path: static_renderer.has_type(type_name) — mutex-wrapped read.
    #    Another worker may have beaten us to this type; bail on hit.
    # 2. ResourceLoader.load(disk_path, "PackedScene") — thread-safe.
    # 3. scene.instantiate(GEN_EDIT_STATE_DISABLED) — thread-safe since Godot
    #    4.1 (issue #79194 resolution).
    # 4. static_renderer.register_from_prototype(type_name, prototype) —
    #    mutex-protected fast-path + atomic insert. Concurrent workers on
    #    the same type_name dedupe safely.
    # 5. Ephemeral prototype goes out of scope — Godot refcount reaper
    #    collects the detached Node3D subtree.
```

No autoload access, no signal emission, no scene-tree ops, no RS calls that would block main.

---

## 5. Shutdown drain (@builder Blocker 1 fix)

Without a drain, `NativeStreamingManager.fast_cleanup` calls `_static_renderer.clear()` while workers may still be mid-`register_from_prototype`, writing into freed `_mesh_types` storage. Symptom: sig 11 C++ backtrace on quit, matching the pattern @user flagged ("streaming / rendering problems that appear while this peculiar .res file is in the pipeline") extended to the shutdown path.

Fix: dispatched task_ids are stored in `ReferenceInstantiator._prereg_task_ids: Array[int]`. `CellManager.fast_cleanup()` calls `_instantiator.drain_prereg_tasks()`, which iterates the array and calls `WorkerThreadPool.wait_for_task_completion` on each not-yet-completed task. `NativeStreamingManager.fast_cleanup` calls `_cell_manager.fast_cleanup()` BEFORE the existing `_static_renderer.clear()` line.

Pruning: `_prune_completed_prereg_tasks()` runs at the top of each `preregister_cell_statics` call, walking the array with `is_task_completed` (non-blocking O(1) per entry) and dropping finished task_ids. Keeps array size bounded over long sessions.

Bound on shutdown delay: < 50 in-flight tasks × ~20ms worst-case PackedScene.instantiate = < 1s blocked on `fast_cleanup`. Typical: < 10 tasks pending → < 200ms. Acceptable on quit path (user already closed window).

Phase A analog: `cell_manager._phase_a_cancel_workers_for_request` at `cell_manager.gd:1896`. Same `is_task_completed` + `wait_for_task_completion` discipline.

---

## 6. Thread-safety audit

| Op | Thread | Status |
|---|---|---|
| `ResourceLoader.load(path, "PackedScene")` | WORKER | Documented thread-safe. Godot docs "Thread-safe APIs" |
| `PackedScene.instantiate(GEN_EDIT_STATE_DISABLED)` | WORKER | Thread-safe since 4.1 (issue #79194 resolved). Phase A already relies on this |
| `_find_all_mesh_instances(prototype)` (subtree walk) | WORKER | Read-only on a detached tree — no scene-tree ops, no signals |
| `MeshInstance3D.material_override` / `surface_get_material` / `mesh.get_aabb` | WORKER | Read-only resource accessors, thread-safe |
| `RenderingServer.mesh_create` (in register_from_prototype, the `owns_mesh` branch) | WORKER | Command-queued, thread-safe per research doc §2.1 |
| `_mesh_types[type_name] = mesh_type` | MAIN or WORKER under `_mesh_types_mutex` | Mutex-protected atomic insert (builder's Phase E fix-up) |
| `static_renderer.has_type` read | WORKER | Mutex-wrapped (this plan, Blocker 1 same-commit fix) |
| Dispatched `WorkerThreadPool.add_task` return value | — | **Tracked in `_prereg_task_ids`** (this plan §5). Prevents CLAUDE.md anti-pattern |

No new mutex. Concurrent pre-reg of the same type is safe: fast-path check + double-checked locking on insert = first to the mutex wins, second sees the entry already present and bails.

---

## 7. Measurement (§9 per near_tier_refactor.md measurement contract)

| Metric | Pre-Phase-F (15:27 log, 15 windows) | Post-Phase-F (16:41 log, 53 windows) | Delta |
|---|---|---|---|
| `static` avg µs | 130-2264 (cold 38050) | **34-87** | 25-40× reduction |
| `static` sustained ms/5s | 92-1339 | **15-60** | 10-20× reduction |
| Worst 5s static window | 964ms (704 refs × 1369µs) | 59ms (1239 refs × 47µs) | **16× less despite 1.8× MORE refs** |
| `light` avg µs | 3000-8000 | 2710-10843 | unchanged (expected — out of scope) |
| `light` sustained ms/5s | 17-208 | 81-282 | now the dominant cost (follow-up) |

Acceptance gate ≥ 2× sustained reduction on `static`: **MET** (10-20×). Cold-register stalls eliminated as an observed category. Follow-up slice (light off-thread) addresses the now-dominant contributor using the Phase A dispatcher widening.

---

## 8. Rollback

`git revert 032df30` + follow-up shutdown-drain commit would restore the prior Phase E.1 state. No data migration, no schema changes, no cross-system coupling outside the dispatcher wiring in `cell_manager.request_*_async`. Individual-file reverts are also safe (edits are orthogonal additions, no in-place rewrites of existing logic).

Runtime rollback: the dispatcher can be neutered by short-circuiting `preregister_cell_statics` to `return 0` — cold-register then falls back to main-thread sync, matching pre-F behavior. No restart needed. Useful for A/B isolation in benchmark runs.

---

## 9. Follow-ups (not in this phase)

1. **Phase E.3 — widen Phase A dispatcher to include `light`.** Now the dominant remaining contributor (40-56ms/s sustained per post-F data). Same off-thread pattern, drops `"light"` from the type exclusion in `should_dispatch_to_worker`. OmniLight3D construction + light configuration move to `complete_worker_instantiate`'s main-thread tail. Estimated win: ~3 FPS lift under heavy light density.
2. **cellupd:274ms outlier investigation.** Still present post-F in some frames (13-16ms cellupd in overrun log lines). Suspect `DistantLightManager._rebuild_multi_mesh` on cell-grid change. Instrumentation pass before fix.
3. **Corrected-E.2 — bulk per-cell static write.** Worker packs per-batch `PackedFloat32Array`, main calls one bulk-write per batch instead of N per-slot writes. ~30-50% reduction on static's remaining cost. Real but smaller than Phase F.
