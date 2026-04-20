# Phase A — Off-thread PackedScene.instantiate (DRAFT)

**Status:** DRAFT 2026-04-20. Approved by @researcher 2026-04-20; awaiting @user plan-boundary go-ahead before implementation. No code changes authorized.
**Author:** @coder
**Plan-boundary gate:** @user (no `@reviewer` agent exists — user owns both plan-boundary and implementation-review gates per CLAUDE.md §Reviewer Engagement Scope)
**Supersedes:** the half-shipped `model_loader.gd`-only Phase A attempt reverted on 2026-04-20 after it delivered only ~10% `inst:` reduction (partial Phase A missed the hot path — cache-hit refs kept calling main-thread `.instantiate()` through sync `get_model()`).
**Source:** `docs/research/near_streaming_industry_patterns.md` (researcher, 2026-04-20) — Phase A section.

---

## 0. Why this plan exists

The steady-state `inst:` slice is the last binding ceiling on NEAR FPS. Data from diag #8 (`commits 042d97c` + `6b8991e`):

| Metric | Cell-cross frame |
|---|---|
| `cellupd:` | 4-10 ms (was 22-41 ms, fixed 2026-04-20) |
| `unload:` (budgeted) | 2-5 ms |
| `inst:` | **18-78 ms** ← this doc |
| Per-container `.instantiate()` | ~11 ms avg |
| Cell content: `container(n=79 tot=872ms avg=11ms)` in dense city | |

The 11 ms/container is `PackedScene.instantiate()` itself — NOT load, NOT setup. It is thread-safe since Godot 4.1 (issue #79194 resolved). Every AAA engine surveyed does this split. We are currently leaving ~600-900ms/cell of parallelizable main-thread work on the table.

---

## 1. Scope & Non-Goals

### In scope
- Move `PackedScene.instantiate(GEN_EDIT_STATE_DISABLED)` call in the **cache-hit path** (the 80%+ hot path) from main thread to `WorkerThreadPool`.
- Split `reference_instantiator.instantiate_reference()` at the canonical boundary: worker does the detached-subtree work, main thread does the scene-root / autoload / signal work.
- Preserve every current behavior: carryable conversion, door attachment, interior collision fallback, fade-in, metadata, VR override, proximity deferral, pool lookup.
- Keep the sync-API surface of `instantiate_reference()` — callers (`cell_manager.process_async_instantiation`) should not need a full rewrite, just a dispatch/drain pattern analogous to what already exists for async disk loads.

### Not in scope (separate phases)
- Phase B (velocity preload / `CellPreloader`) — researcher doc §Phase B.
- Phase C (delete bespoke fade shader, use engine VR_FADE_SELF) — researcher doc §Phase C.
- Phase D (impostor stand-in during streaming gaps) — researcher doc §Phase D.
- T.2 (statics cell-level merged collision) — separate plan `statics_no_node3d.md`.
- Any refactor of `model_loader.gd`'s disk-load path — that's working fine (cellupd diag confirms).

### Explicit non-goals
- Not changing the sync `get_model()` return contract. It still returns Node3D synchronously. Callers who need async use the new dispatch path.
- Not introducing a general green-threading / coroutine layer. Just a two-phase split.
- Not retrying worker failures — if instantiate returns null on worker, fire callback with null, let caller fall back to `_create_placeholder`.

---

## 2. The hot path (what we're splitting)

`cell_manager.process_async_instantiation()` drains `_instantiation_queue` each frame:

```
while queue not empty and budget not hit:
    entry = queue.pop_back()
    obj = _instantiator.instantiate_reference(ref, cell_grid)  ← 11 ms for containers
    if obj:
        pending_children.append({parent, child: obj, fade_in})
        ...
```

`instantiate_reference` (reference_instantiator.gd:260-610, ~350 lines of actual logic in the hot path):

```
1. proximity/pool checks                     # cheap, pure data
2. model_loader.get_model(model_path)        ← PackedScene.instantiate() lives here
3. instance.name = ...                       # thread-safe
4. _enable_collision_shapes_in_tree(instance) if near  # tree walk, sets property
5. _hide_lod_nodes(instance)                 # tree walk, sets visible=false
6. _apply_transform(instance, ref, true)     # thread-safe, detached node
7. _apply_metadata(instance, ref, base, ...) # thread-safe, detached node
8. if is_carryable: carryable conversion     # ★ touches SceneTree via queue_free + add_child
9. if type_name == "door": _attach_door      # ★ connects signals, touches autoloads
10. interior collision fallback (if needed)  # ★ touches InteriorPocketManager
11. return instance
```

Steps 1-7 are **worker-safe** (pure data ops on the detached node — no tree ops, no signals, no autoload access). Steps 8-10 touch scene root, signals, and autoloads — **main-thread only**.

---

## 3. Target shape (two-phase dispatch/drain)

New entry schema in `_instantiation_queue`:
```gdscript
class InstantiationEntry:
    var request_id: int
    var ref: CellReference
    var model_path: String
    var item_id: String
    var position: Vector3
    var load_profile: ...
    var interior_priority: bool
    # --- NEW for Phase A ---
    var worker_instance: Node3D = null    # populated by worker; null = not-yet-dispatched
    var worker_dispatched: bool = false   # guards double-dispatch
    var worker_task_id: int = -1          # for cancellation (see §4)
```

### 3.1 Dispatch pass (main thread, new)

Replaces the synchronous `_instantiator.instantiate_reference(...)` call inside the drain loop:

```
for entry in _instantiation_queue (from back):
    if budget exhausted: break
    if entry.worker_instance != null:       # ready → drain path handles
        continue
    if entry.worker_dispatched:             # in-flight → skip
        continue
    if entry is proximity-deferred: skip (unchanged)
    if entry pool-hit: handle inline (pool instance is already ready, no worker)
    # --- new: dispatch worker ---
    var packed_scene = model_loader.get_cached_packed_scene(model_path, item_id)
    if packed_scene == null:
        # Not cached yet — fall back to async disk load + re-queue (existing path)
        continue
    entry.worker_dispatched = true
    entry.worker_task_id = WorkerThreadPool.add_task(
        _instantiator._worker_instantiate.bind(entry, packed_scene),
        false, "cell_manager:instantiate")
```

### 3.2 Worker function (new — lives on `reference_instantiator.gd` as static method)

```
static func _worker_instantiate(entry: InstantiationEntry, packed_scene: PackedScene) -> void:
    var instance: Node3D = packed_scene.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED) as Node3D
    if instance == null:
        entry.worker_instance = null
        return
    # Thread-safe detached-node ops:
    _strip_occluders(instance)
    _disable_collision_shapes_in_tree(instance)  # already main-thread in current code, but pure property set
    instance.name = str(entry.ref.ref_id) + "_" + str(entry.ref.ref_num)
    _apply_transform(instance, entry.ref, true)
    _apply_metadata(instance, entry.ref, entry.base_record, entry.model_path, entry.type_name)
    _hide_lod_nodes(instance)
    entry.worker_instance = instance
    # No mutex — main thread reads worker_instance only after WorkerThreadPool confirms task completion.
```

### 3.3 Drain pass (main thread, replaces current synchronous instantiate)

```
for entry in _instantiation_queue (from back):
    if budget exhausted: break
    if entry.worker_dispatched and not WorkerThreadPool.is_task_completed(entry.worker_task_id):
        continue  # worker still running — skip, try next
    var instance: Node3D = entry.worker_instance
    if instance == null:
        # Worker failed or not-yet-dispatched — dispatch path handles
        continue
    # Main-thread tail of instantiate_reference:
    if is_near: _enable_collision_shapes_in_tree(instance)  # still detached, safe either thread, kept here for symmetry
    if is_carryable: carryable conversion
    if type_name == "door" and ref.is_teleport: _attach_door_interactable(...)
    if needs_interior_collision_fallback: _generate_interior_static_body(...)
    pending_children.append({parent, child: instance, fade_in})
    instantiated += 1
    # entry gets popped at the bottom of this iteration
```

### 3.4 Invariants

- Worker NEVER touches: autoloads (Log, ESMManager, etc.), `add_child`, `connect(signal)`, scene-root nodes.
- Worker NEVER allocates resources that require RenderingServer queueing outside `.instantiate()`. Property sets on detached Node3D are buffered correctly.
- `entry.worker_instance` is ONLY read by main thread AFTER `WorkerThreadPool.is_task_completed(task_id)` returns true. This is the implicit mutex.
- `entry.worker_instance` is ONLY written by worker. Main thread sets it back to null only on cancellation (§4).

---

## 4. Cancellation path

When a cell unloads mid-flight, any queue entries for that cell must discard their worker results. Current code already has `request.pending_instantiations -= 1` + `request.cell_node` validity check. Phase A adds:

```
# In _unload_cell (or finalize_unloaded_cell):
for entry in queue where entry.request_id == cancelled_request:
    if entry.worker_dispatched and not is_task_completed(entry.worker_task_id):
        # Wait briefly so the worker doesn't leak memory writing to a dead entry
        WorkerThreadPool.wait_for_task_completion(entry.worker_task_id)  # sync, ~11ms worst case
    if entry.worker_instance:
        entry.worker_instance.queue_free()  # thread-safe, deferred destruct
        entry.worker_instance = null
```

Worst case: 1-2 stalls per cell unload × 11ms per stall = bounded. Acceptable because unload is already budgeted (`_process_budgeted_unloading`).

**Alternative (safer, more complex):** mark entry as cancelled; worker checks the flag before writing `worker_instance`; if cancelled, worker queue_frees its own result. Deferred to follow-up if wait_for_task_completion shows hitches in §6 measurement.

---

## 5. Ops audit — what moves to worker, what stays

Enumerated against `reference_instantiator.gd:260-610` (the `instantiate_reference` body):

| Line range | Op | Thread |
|---|---|---|
| 260-286 | type_name / record_id / base_record resolution | main (calls ESMManager) |
| 287-314 | proximity deferral + pool lookup | main (touches object_pool singleton) |
| 299-307 | static-renderer routing (`_should_route_to_renderer`) | main (stays, different code path anyway) |
| 328-334 | `model_loader.get_model()` + `instance.name = ...` | **WORKER** (the `get_model` cache-hit becomes `get_cached_packed_scene` + worker does instantiate) |
| 336-345 | `_enable_collision_shapes_in_tree` + `_hide_lod_nodes` | WORKER (both pure property sets on detached subtree) |
| 347-348 | `_apply_transform` | WORKER |
| 350-351 | `_apply_metadata` | WORKER (only sets meta dict on node) |
| 353-374 | **carryable conversion** | main (queue_free old StaticBody + add_child new RigidBody) |
| 376-383 | **door attachment** | main (connect signals, touches InteriorPocketManager) |
| 385-410 | **interior collision fallback** | main (instantiates StaticBody3D, add_child) |

Pool-hit path (line 319-326) stays entirely on main thread — pooled instances are already-instantiated, just reset.

### 5.1 Autoload grep

Grep for autoload refs inside the proposed worker section (lines 328-351):

```
grep -nE "Log\.|ESMManager|BSAManager|SettingsManager|ShaderManager|OceanManager" src/core/world/reference_instantiator.gd | head
```

Expected: zero matches in the 328-351 range. Pre-implementation check: if ANY autoload reference is found in that range, either move it out or keep it on main.

### 5.2 Autoload grep — inside helper tree-walk functions

`_strip_occluders`, `_disable_collision_shapes_in_tree`, `_hide_lod_nodes`, `_apply_transform`, `_apply_metadata` — each must be grep'd. All touch only node properties/children. No autoload refs expected.

If grep finds a match, the helper CANNOT run on worker → refactor OR keep on main (move out of worker task).

---

## 6. Measurement plan

Following the pattern of `cellupd` diag (2026-04-20):

### 6.1 Baseline (pre-Phase-A = current `6b8991e`)

Already captured in diag #8 + #12:
- `inst:` avg 27-30 ms, p95 34-44 ms, max 78 ms (cell-cross frames)
- container avg: 11 ms / ref
- cell load time: 11682-12077 ms

### 6.2 Target (post-Phase-A)

Per researcher: ~35× reduction on the `.instantiate()` portion. Realistic target:
- `inst:` avg ≤ 6 ms, p95 ≤ 12 ms (main thread only does carryable/door/add_child + the 20% setup tail)
- container avg on main thread: ≤ 1 ms / ref (the `.instantiate()` 11ms moved off-thread)
- cell load time: 8-10s (initial disk load unchanged, but parallelism should help)
- FPS during cell-cross: 80-140 fps (was 23-50)

### 6.3 Acceptance gate

1. Interactive pilot for ≥3 min in Seyda Neen / Bitter Coast. Cell-cross `inst:` log shows p95 ≤ 12 ms.
2. No new SIGSEGV — breadcrumb stays `cm::batch_done` (pre-existing §12.2 crash is orthogonal).
3. No visual regressions: carryables still droppable, doors still teleport, containers still openable.
4. Shape cache warmup (the per-prototype instantiate-to-inspect path in `has_animation`) still works.
5. All 13 existing gdUnit4 tests pass.

### 6.4 Rollback plan

If acceptance gate fails:
- `git reset --hard HEAD~1` if the Phase A commit is on top.
- Partial failures (some refs not rendering) → quarantine commit, revisit entry schema.
- Crash regression → breadcrumb tells us where; revert + analyze.

---

## 7. Implementation order (tight slices)

Each slice is committable independently. If we stop mid-way, the branch still works.

1. **Ops audit commit** (no code change): add `# PHASE_A:WORKER_SAFE` / `# PHASE_A:MAIN_ONLY` comments above each helper function in `reference_instantiator.gd`. Annotation-only. No behavior change.
2. **Entry schema slice:** extend `InstantiationEntry` with `worker_instance`, `worker_dispatched`, `worker_task_id`. Unused by consumers — no behavior change.
3. **Worker function + API:** add `_worker_instantiate(entry, packed_scene)` in `reference_instantiator.gd`. Add `model_loader.get_cached_packed_scene(...)` that returns the cached PackedScene without instantiating (factored out of `get_model`'s cache-hit branch). Still no behavior change because nobody calls these yet.
4. **Dispatch slice:** in `cell_manager.process_async_instantiation`, before the synchronous `instantiate_reference` call, check if `entry.worker_instance == null and not entry.worker_dispatched and cache-hit → WorkerThreadPool.add_task(_worker_instantiate.bind(...))`. On first iteration, no workers have completed, so all entries still go through the synchronous fallback. No behavior change.
5. **Drain slice:** in the same loop, check `entry.worker_dispatched and is_task_completed(task_id) and entry.worker_instance != null → run main-thread tail, skip synchronous call`. Now some entries go through the worker path. Behavior change.
6. **Synchronous fallback retirement:** once §7.5 is stable, remove the synchronous `instantiate_reference` call for cache-hit refs. All cache-hit refs must go worker-path. Cache-miss refs still use the async disk-load pipeline (already worker-backed after §7.3).
7. **Cancellation slice:** wire `_unload_cell` to wait_for_task_completion + queue_free. Tested by sprinting across 5+ cells rapidly.
8. **Measurement commit:** add the 2 benchmark lines from §6.2 to `measurement log` table in parent plan (`near_tier_refactor.md §9`).

If §7.4-7.6 measure less than 2× `inst:` improvement at §7.6 sign-off, revert `§7.4`-`§7.6` and revisit the ops audit — we missed a main-thread-only op that's still on the hot path.

---

## 8. Risks & open questions

### 8.1 Risks

- **Sub-resource finalization race.** `model_loader.gd:586-592` comment says async-loaded PackedScenes have deferred c2 sub-resource init that MUST be finalized on main thread via `CACHE_MODE_REUSE` sync reload. Phase A dispatches instantiate from CACHE-HIT path, where the PackedScene is already fully loaded (initial disk load went through `_drain_pending_instantiate_queue` which did the main-thread reload). So sub-resources ARE finalized before any worker sees the scene. Verification gate: check `_model_cache[cache_key]` is only populated AFTER the sync reload (yes, see line 609-610). Pass.
- **Jolt body registration timing.** `_disable_collision_shapes_in_tree` sets `disabled = true` on CollisionShape3D BEFORE worker returns. When main thread later does `add_child`, `_enter_tree` fires → CollisionShape3D registers its shape with the parent StaticBody3D in Jolt broadphase → shape is `disabled` so Jolt tracks but doesn't test. When main thread calls `_enable_collision_shapes_in_tree` (for near refs), Jolt flips the flag to test-active. This is the current flow, unchanged. Pass.
- **RenderingServer instance registration timing.** MeshInstance3D's `_enter_tree` fires on main thread at `add_child` time (post-worker). RS queues its buffer. No worker thread touches RS. Pass.
- **Script attachments on prebaked .res nodes.** Researcher-flagged hazard. `grep -nE "func _init" src/core/nif/` = 0. If ANY prebaked script adds `_init` in the future, this plan's §5.1 audit catches it.

### 8.2 Open questions

1. Does `WorkerThreadPool.add_task` allocate a new Thread per call or reuse a pool? (Affects burst cost.) Godot docs: fixed pool of N threads, add_task queues onto existing threads. N = max(os_cores - 1, 1) default. Our setup: 4-thread pool via BackgroundJobSystem (`"BackgroundJobSystem started with 2 worker threads"` in logs — only 2 threads). Will 2 threads be enough for 79 containers? 79/2 × 11ms = 434ms total worker time; spread across 7 frames at 60fps (116ms real-time), 50% of worker-thread-time is used. Acceptable.
2. `has_animation()` currently calls `get_model()` synchronously for inspection. Does it need to move to worker too? Called once per unique prototype (~500 calls). Total ~500×2ms = 1s startup cost, amortized. Leave on main for v1.
3. `_create_placeholder()` (line 1111) is called when model_loader returns null. Currently runs on main thread. Should stay main (creates ImmediateMesh + Node3D — needs scene tree eventually anyway). Pass.
4. Should `strip_occluders`'s `remove_child`+`queue_free` on worker-thread detached subtrees actually fire correctly? Godot 4 docs: `queue_free()` is thread-safe, uses atomic flag. `remove_child` on not-in-tree parent is parent.children array mutation, no notifications fire. Empirically should be fine, but pre-ship smoke test with 1 ref type required (§6.3).

---

## 9. What this plan is NOT

- Not a rewrite of `instantiate_reference`. The 600-line function stays. Only the call boundary moves.
- Not a replacement for `model_loader.gd`'s async disk-load pipeline. That stays. Phase A only affects what happens AFTER a PackedScene is cached.
- Not Phase B / C / D. Those are separate docs.
- Not T.2 statics collision. Orthogonal.

---

## 10. Review checklist (for @user plan-boundary review)

- [ ] §1 scope correctly limits to the cache-hit hot path (not a full async refactor).
- [ ] §3 dispatch/drain architecture preserves sync-API semantics from caller's view.
- [ ] §4 cancellation path is bounded and correct.
- [ ] §5 ops audit accurately splits worker-safe vs main-only.
- [ ] §5.1, §5.2 grep-before-code is non-negotiable.
- [ ] §6 measurement gate is specific enough to catch regressions.
- [ ] §7 slice ordering keeps branch runnable at every commit.
- [ ] §8.1 sub-resource race analysis is correct.
- [ ] §8.2 open questions are tracked and resolvable.
- [ ] No kludges per CLAUDE.md §Industry Standard. Pattern matches UE5 / Unity BRG / Decima split.

---

## 11. After @user sign-off

@user checks boxes above, posts plan-approved in chat. Implementer (@researcher, per 2026-04-20 handoff) runs §7 slices 1-8, pushes single commit or series. @user does implementation-review pass. Then we measure + sign off.
