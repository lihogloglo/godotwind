# ModelLoader Async Instantiation Race — Diagnosis

**Status:** open; v1 repro path removed — needs a v2 repro
**Date:** 2026-04-14 (diagnosis), repro-section updated 2026-04-14 after v1 benchmark rip-out
**Author:** @coder
**Reviewer:** @docs (not yet reviewed)

> **Note (2026-04-14):** the original repro used `-- --benchmark` CLI auto-mode + `_wait_for_streaming_idle` gate in `world_explorer.gd`. Both were deleted in the v1 benchmark rip-out (see `docs/audit/BENCHMARK_V2_PLAN.md`). The crash signature below is unchanged — it fires on the normal play path too, intermittently — but the deterministic repro harness no longer exists. A replacement repro tool needs to ship with v2's progressive auto-run or a dedicated streaming-stress command. Until then, use the "normal play path" branch below to trigger it manually.

## Symptom

Segfault (signal 11) during async cell streaming. Reproduces under heavy streaming pressure — historically via the (now-removed) benchmark `_wait_for_streaming_idle` gate (min 20s post-load-screen idle while queues drain) hit the crash ~4/5 launches. Normal play path also exhibits it intermittently (git log references "some instability" on the LOD/HLOD refactor commits).

```
GDScript backtrace (most recent call first):
    [0] process_async_loads (res://src/core/world/model_loader.gd:422)
    [1] process_async_disk_loads (res://src/core/world/cell_manager.gd:1279)
    [2] process_async_instantiation (res://src/core/world/cell_manager.gd:1313)
    [3] _process (res://src/tools/world_explorer.gd:2104)
CrashHandlerException: Program crashed with signal 11
```

Just before the signal, Terrain3D's crash handler prints `Terrain3D#...:_notification:940: NOTIFICATION_CRASH` — Terrain3D's engine hook observing the segfault, not causing it.

Crash site line is `packed_scene.instantiate()`. Existing validity guards at :418–440 (packed_scene truthy, `get_state()` non-null, `get_node_count() > 0`) do not prevent the crash.

## Reproduction

**v1 repro (removed 2026-04-14, retained for history):** `"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" -- --benchmark`. Game booted, hit `_wait_for_streaming_idle` (world_explorer.gd:460), during the 20–60s wait ~10–15 cells loaded and the crash fired during a subsequent `process_async_instantiation` frame (exit 139, no CSV). Success rate in 5 launches: 1/5. Both the `--benchmark` CLI flag and `_wait_for_streaming_idle` no longer exist in the codebase.

**v2 repro (current, interactive, intermittent):**
1. Launch `scenes/Godotwind.tscn` normally (no CLI args).
2. Wait for loading screen to hide, then immediately fly the camera through dense cell boundaries at high speed to force rapid streaming churn. Seyda Neen → Balmora → Vivec traverse at fly-camera max speed tends to trigger it.
3. Watch for the `[0] process_async_loads (model_loader.gd:422)` stack and `Terrain3D#...:_notification:940: NOTIFICATION_CRASH` log line immediately before exit 139.

Repro rate on the v2 interactive path is lower and non-deterministic. A proper replacement will ship with v2's `bench_progressive` or a dedicated streaming-stress console command.

## Differential diagnosis (per CLAUDE.md canonical-pattern litmus)

The `process_async_loads` body at lines 418–440 has accreted four validity guards (`if packed_scene` → `get_state()` null check → `get_node_count() > 0` → `instance == null` → `instance is Node3D`). This matches the CLAUDE.md "Simplicity Over Over-Engineering" smell — each guard papers over a different failure mode of the async pipeline without fixing the pipeline.

Candidate root causes, from least to most likely:

### (a) Threading boundary violation — unlikely

`instantiate()` is main-thread-only (CLAUDE.md anti-pattern #11). Stack trace confirms it IS on main thread: `_process` → `process_async_instantiation` → `process_async_disk_loads` → `process_async_loads`. Godot's `_process` always runs on main thread. Ruled out.

### (b) Shared Node3D instance across callbacks — likely contributor, not root

`_model_cache[cache_key] = model` stores the Node3D directly (model_loader.gd:448). Cache hits at :327 return the same Node3D to subsequent callers:
```gdscript
var model: Node3D = _model_cache[cache_key]
if callback.is_valid():
    callback.call(model_path, item_id, model)
```
If caller A adds this node to its scene and caller B receives the same instance, B's `add_child` reparents from A, firing NOTIFICATION_MOVED_IN_PARENT on A's subtree and potentially leaving A with dangling references. This is a known failure mode that can manifest as a segfault in subsequent frames when the dangling reference is used — but would NOT explain a crash *inside* `instantiate()` on first-load.

Worth fixing regardless (cache should store `PackedScene`, not `Node3D`; callers `instantiate()` on demand) but not the primary explanation for this trace.

### (c) ResourceLoader cache eviction race — most likely

`load_threaded_request(disk_path, "PackedScene")` is called at :365 without specifying `CACHE_MODE`. Default behavior shares Godot's `ResourceCache`. Two suspicious failure modes:

1. **Cache eviction during load**: the "corrupted cache → delete file" branches at :426, :434, :439 call `DirAccess.remove_absolute(disk_path)` for disk_paths whose `instantiate()` failed. If another caller issued a `load_threaded_request` for the same path moments earlier and is still mid-finalization, deleting the disk file while the loader's background thread is reading it is a textbook race. The threaded loader holds a file handle but the state may reference paths resolved later (materials, external scenes, embedded sub-resources). A removed file under an in-flight loader is a well-known segfault vector.

2. **Sub-resource invalidation between status poll and get**: `load_threaded_get_status() == THREAD_LOAD_LOADED` at :410 races with actual finalization of external references (embedded meshes, ArrayMesh surface data). If the worker hasn't fully resolved dependent resources by the time the main thread reads `load_threaded_get` + calls `instantiate()`, the PackedScene's internal node construction can dereference a half-built mesh RID → segfault.

Case (c1) is the primary suspect: the self-healing "delete corrupt cache" logic is also the race trigger. The three `DirAccess.remove_absolute` calls defend against one failure mode (truly corrupt cache files) while creating another (in-flight loader consuming the file).

## Canonical patterns

Godot docs reference for `ResourceLoader.load_threaded_*`:
- https://docs.godotengine.org/en/stable/classes/class_resourceloader.html
- `CACHE_MODE_REPLACE` forces fresh load, bypassing cache coherence games
- `load_threaded_get` returns null (not crash) on failure — the GDScript side should assume null is possible and not rely on `_status == LOADED` implying the result is safe

Industry pattern for async resource pipelines (Unreal StreamableManager, Unity Addressables):
- Cache eviction is a **deferred operation** scheduled on the owning manager, never a synchronous side-effect of a consumer's failure path. Consumers mark resources stale; a single maintenance pass reconciles the cache on frame boundaries when no loads are in flight.
- External caches (disk files) are **never** deleted while a load handle on that file is active. A reference-count or generation counter on the path gates deletion.

## Recommended fix direction (for plan review)

Small, targeted rewrite of `model_loader.gd` async path following canonical ResourceLoader usage. Tentative shape:

1. **Remove the `DirAccess.remove_absolute` calls from `process_async_loads`** (:426, :434, :439). The disk cache file is owned by the prebake pipeline; runtime should not delete cache files mid-load. If a PackedScene fails to instantiate at runtime, log it and continue — the next session's prebake can rebuild.

2. **Change `_model_cache` to store `PackedScene`, not `Node3D`**. Callers receive the `PackedScene` and call `instantiate()` themselves. This eliminates the shared-instance reparent hazard from case (b). Adds one `instantiate()` per cache hit — cheap, and each caller gets a fresh instance.

3. **Use `CACHE_MODE_REUSE`** (default) but ensure no competing `load_threaded_request` is issued for a path already in `_pending_async_loads`. Current code at :334 already dedupes — verify no other code path can double-issue.

4. **Add a single generation counter + "in-flight" guard around cache file deletion elsewhere** (prebake invalidation, if any). Not this PR's scope but noted for the prebake pipeline.

Expected behavior after fix:
- `process_async_loads` shrinks from ~45 lines of branching guards to ~20 lines
- `packed_scene.instantiate()` is called once per cache MISS, not once per callback
- Segfault vector removed (no file deletion while loader active)
- Teardown crash (signal 11 after `BackgroundJobSystem stopped`) is unchanged — distinct issue, tracked separately

## Not in scope

- The **teardown crash** (signal 11 after `BackgroundJobSystem stopped`) — different stack, separate diagnosis needed. Likely RID leak or unjoined WorkerThreadPool task per @docs' earlier review. Tracked separately.
- Prebake pipeline validation — whether any disk cache files are actually corrupt. Current code assumes they might be; we're proposing that runtime shouldn't try to repair them regardless.
- HLOD/impostor instability referenced in recent commit messages — if those are actually the same root cause, the fix above may resolve them too, but confirming requires isolation benchmarks which require the crash to be fixed first. Circular dependency; fix the crash, re-measure.

## Open questions for @docs

1. Is there a pre-existing design doc explaining why `_model_cache` stores `Node3D` instead of `PackedScene`? (git-blame on :448 would tell, but asking in case there's out-of-band rationale.)
2. Acceptable to land fix without isolation-benchmark confirmation? (Isolation run is blocked by this crash; can't measure the fix with the tool the fix unblocks.)
3. Should `DirAccess.remove_absolute` cleanup move to a dedicated eviction pass triggered on idle frames, or be removed entirely and deferred to prebake?
