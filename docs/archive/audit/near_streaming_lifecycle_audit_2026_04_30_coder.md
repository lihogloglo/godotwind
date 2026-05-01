# NEAR Streaming Lifecycle Audit

Archived: durable lifecycle rules were consolidated into
`docs/systems/streaming_rendering_bible.md` on 2026-05-01. Keep this file only
as P0.4 forensic source material.

Date: 2026-04-30  
Owner: coder  
Scope: P0.4 first pass, focused on scene-tree child attach / unload lifecycle

## Current Verdict

The static descriptor slice moves the old `SceneState` material-RID crash site
out of the observed failure path. The current blocker is scene-tree publication:
a stationary `--quit-after-ready=20` probe crashed natively after a
`981.3ms` instantiation overrun dominated by `addc=976.4ms`, with the last
breadcrumb at:

```text
cm::inst_tail_done :: queue=54 child=0 cfin=0
```

This means the child attach queue drained to zero and the crash happened after
or during native processing triggered by a very expensive `add_child()` publish.
The time budget did not protect the frame because one scene-tree attach is not
preemptible.

## Canonical Pattern

Godot's documented threading model keeps scene-tree mutation on the main
thread. The production pattern is:

- worker/threaded lanes prepare resources and pure data only
- main-thread publish is explicit and budgeted
- each publish record has one owner
- unload either cancels unowned detached records or pauses payload-owned
  records through a state-reversal window
- static clutter stays server-direct; only sparse interactive/gameplay objects
  enter the scene tree

For heavy refs, a count-limited `add_child()` queue is not enough. If one
attached subtree contains hundreds of nodes, the proper fix is to avoid
publishing that subtree as a `Node3D` in NEAR unless it is truly interactive.

## Ownership Map

| Object | Current Owner | Release Point | Risk |
|--------|---------------|---------------|------|
| `AsyncCellRequest` | `CellManager._async_requests` | `get_async_result()`, `cancel_async_request()`, `finalize_unloaded_cell()` | split state with `NativeStreamingManager._async_requests` grid map |
| `CellPayload` | `AsyncCellRequest.payload` | request erase / finalization | correct direction, but owns only static-prepare slice so far |
| loaded `cell_node` | `NativeStreamingManager._loaded_cells` after `get_async_result()` | `_process_budgeted_unloading()` | state-reversal limbo means it can be hidden but still valid |
| unloading `cell_node` | `NativeStreamingManager._unloading_cells` | `_process_budgeted_unloading()` | request remains parked in `_unloading_request_ids` |
| detached child `Node3D` | `CellManager._pending_child_attaches` | `_drain_pending_child_attaches()`, request discard, fast cleanup | global queue crosses cell lifetime boundaries |
| child attach record | `CellManager._pending_child_attaches` | popped in drain or filtered by request | not payload-owned; previous payload move crashed visibly |
| scene-tree child after attach | `cell_node` subtree | cell unload child `queue_free()` | one `add_child()` can spike/crash natively |
| `StreamedResourceHandle` | `CellPayload`, then bound to `cell_node` meta | node free / owner release | accepted P0.2 path |
| static prepare record | `CellPayload` plus `CellManager` selector | pop/requeue/discard | accepted first P0.3 slice |
| static RS instance | `StaticObjectRenderer` | `remove_cell_instances()` / clear | owner is clear, but still needs full RID audit later |
| collision worker/result | `AsyncCellRequest` | drain/cancel/finalize | mostly explicit, but publish/free still needs full RID audit |

## Child Attach Lifecycle

Current flow:

1. `process_async_instantiation()` creates a detached `Node3D`.
2. `_queue_child_attach(request_id, request.cell_node, obj)` stores it in the
   global `_pending_child_attaches` queue.
3. `_drain_pending_child_attaches()` pops at most one record per drain call and
   calls `parent.add_child(child)` if the request/cell is still active.
4. `_unload_cell()` pauses request publish and hides the cell node, but keeps
   the request and queues alive for possible state reversal.
5. `finalize_unloaded_cell()` discards leftover attach records only after the
   unload limbo closes.

The guard logic prevents obvious use-after-free cases. The remaining problem is
not primarily a missing `is_instance_valid()` check. The observed spike shows a
single valid attach can be too large and can trigger native instability.

## Failed Prior Approach

Moving `_pending_child_attaches` into `CellPayload` without changing the
publication semantics passed automated smoke but crashed visibly around unload.
That proves queue ownership alone is not enough. The next attempt must include
an owner/free-point proof for detached nodes and must address the size of what
is being attached.

## Required Next Slice

Before retrying payload-owned child attach:

1. Add per-attach diagnostics for slow `add_child()` calls:
   request id, grid, type, model path, ref id, child root class, child count,
   descendant count, and elapsed ms.
2. Use the diagnostics to identify which ref type is creating the 900ms attach.
3. For heavy static-looking refs, route visuals through `StaticObjectRenderer`
   and attach only a lightweight interaction/collision root if needed.
4. Only after heavy subtree publication is reduced, move child attach records
   into `CellPayload`.

Acceptance for the diagnostics slice:

- Stationary `--quit-after-ready=20` either reaches `READY_QUIT` or logs the
  exact child attach that causes the native crash/spike.
- Dense-loop stress still completes.
- No new defer-frame constants or permanent disable flags.

## Diagnostics Slice Result

Implemented in `src/core/world/cell_manager.gd`:

- `_queue_child_attach()` records source metadata with each detached child:
  request id, grid, type, model path, item id, ref id, and ref num.
- `_drain_pending_child_attaches()` brackets each `add_child()` with
  `cm::attach_one_begin` / `cm::attach_one_done` breadcrumbs.
- attaches over 16ms log `[child-attach-spike]` with direct child and
  descendant counts.

Verification after instrumentation:

- Stationary hidden `--quit-after-ready=20` reached `READY_QUIT`, drained queue
  and child attach counts to zero, then hit the known post-quit native signal
  11. No individual child attach crossed the 16ms slow log threshold.
- Dense-loop stress `child_attach_diag_dense_2026_04_30_coder` completed and
  wrote benchmark artifacts, then hung after `BENCH_QUIT` in the known
  null-material/native finalization loop until killed by the watchdog.
- No script parse errors or invalid calls were observed.

Interpretation:

The earlier 976ms `addc` stationary spike did not reproduce with diagnostics
enabled. Child attach remains architecturally split across a global queue, but
there is not yet a named heavy child to rewrite. The immediate repeatable
failure is still automated shutdown/finalization, while traversal completed.

## Open Risks

- `CellManager` and `NativeStreamingManager` both keep request state maps. This
  is the broader P0.3 split-brain the payload scheduler must remove. This is
  not permanent architecture: the follow-up lane is request-state ownership
  consolidation, where one owner exposes request lookup/state to the other
  systems instead of maintaining parallel dictionaries.
- `add_child()` cost is currently counted after the fact. The budget can limit
  how many records are attempted, but not the cost of one record.
- Automated hidden quit still has a known post-teardown native signal 11; keep
  it tracked separately from the child-attach startup crash signature.

## P0.4 Full Lifecycle Map Draft

Date: 2026-05-01
Scope: accepted payload ownership lanes after checkpoint `1836d97`

Canonical ordering for every cancel/unload/shutdown path:

1. Stop new publish work and pause or mark the request `UNLOADING`.
2. Drain owned `WorkerThreadPool` tasks before dropping task-bound payloads.
3. Free server RIDs while their source `Resource` / `Shape3D` owners are still
   strongly referenced.
4. Queue-free detached or scene-tree nodes.
5. Drop payload resource handles and cache pins.
6. Erase request/payload bookkeeping.

### Owner / Release Map

| State | Runtime owner | Release point | P0.4 verdict |
| --- | --- | --- | --- |
| Static prepare entries | `CellPayload.static_prepare_entries_by_key` | `CellPayload.pop_static_prepare_entry`, `discard_static_prepare_queue`, request erase | Correct owner. Driver still lives in `CellManager._publish_payload_step`, rotated by `NativeStreamingManager._process_payload_publish_steps`. |
| Model waiter lists | `CellPayload.pending_model_loads_by_key` | `pop_model_load_completion`, `discard_pending_model_load`, `discard_model_load_callbacks` | Correct owner. Completion pins handle before publish-draining callbacks. |
| Completed model notifications | `CellPayload.completed_model_loads` | `pop_model_load_completion`, request discard | Correct owner. Queue is payload-scoped and stops when payload enters `UNLOADING`. |
| Streamed resources / cache pins | `CellPayload.resource_handles_by_key` plus temporary `ModelLoader` cache owner pin | Completed cell: handles are copied to `cell_node` metadata, then payload owner releases. Cancel/finalize: `_unpin_payload_cached_scenes` releases cache pin and payload owner. | Correct ordering: strong handles survive on live `cell_node`; canceled requests release after workers/RIDs drain. |
| Static RS bucket RIDs | `StaticObjectRenderer._cell_buckets` through `CellStaticBucket` | Hard cancel: `remove_cell_instances(grid)`. Exterior unload: hide through `hide_cell_instances_budgeted`, then `remove_cell_instances(grid)`. Shutdown: `StaticObjectRenderer.clear`. | Transitional but coherent. `CellPayload.static_buckets_by_key` is only an active-request record and must not free live buckets after completion. |
| Static collision worker payload/task/body | `CellPayload.collision_payload`, `collision_task_id`, `collision_body` | `_drain_collision_worker_for_request` from hard cancel, unload start, soft finalize, and fast cleanup | Correct owner. Drain waits task first, drops worker payload, frees PhysicsServer bodies before clearing Shape3D strong refs. |
| Pending child attaches | `CellManager._pending_child_attaches` | Drain attach; hard cancel/soft finalize/fast cleanup filters request and queue-frees detached child | Still legacy/global. Guarded enough for current accepted slice; do not move to payload until heavy Node3D publish is further reduced or a named attach failure is captured. |
| Live cell nodes | `NativeStreamingManager._loaded_cells` | `_unload_cell` moves to `_unloading_cells`; `_process_budgeted_unloading` queue-frees children, finalizes parked request, then queue-frees cell root | Correct state-reversal shape. Request stays parked in `_unloading_request_ids` until the limbo window closes. |

### Cleanup Path Trace

Hard async cancel (`CellManager.cancel_async_request`):

- mark request/payload `UNLOADING`
- cancel parse tasks
- drain Phase A worker-instantiates
- drain collision worker/body
- filter legacy instantiation queue
- queue-free detached child attaches
- discard static prepare
- remove renderer-owned cell RS instances/buckets
- queue-free cell node
- release resource handles/cache pins
- erase request

Exterior unload start (`NativeStreamingManager._unload_cell`):

- move request id from active grid map to `_unloading_request_ids`
- pause payload publish
- drain collision worker/body immediately
- schedule renderer RS hide then cleanup
- evacuate persistent nodes
- hide cell node and enter `_unloading_cells`
- notify preloader/stats

Exterior unload finalize (`NativeStreamingManager._process_budgeted_unloading`
then `CellManager.finalize_unloaded_cell`):

- budgeted queue-free child nodes until the cell is empty
- mark request/payload `UNLOADING`
- cancel parse tasks
- drain Phase A worker-instantiates
- drain collision worker/body idempotently
- release resource handles/cache pins
- filter remaining instantiation entries
- queue-free detached child attaches
- discard static prepare
- erase request
- queue-free cell root in the streaming manager

Fast cleanup / shutdown:

- `NativeStreamingManager.fast_cleanup` stops the background processor, drains
  cell preloader tasks, calls `CellManager.fast_cleanup`, clears static
  renderer/impostor/distant resources.
- `CellManager.fast_cleanup` drains prereg tasks, drains every payload collision
  worker/body, releases payload cache pins/handles, queue-frees detached child
  attaches, and discards static prepare.
- `StaticObjectRenderer.clear` frees registry resources, direct RS instances,
  renderer-owned cell buckets, and finally mesh/material RIDs under the
  `_mesh_types_mutex`.

### P0.4 Implementation Plan

Minimal code changes only:

1. Delete `CELL_STATIC_COLLISION_FINALIZE_DEFER_FRAMES_AFTER_UNLOAD` and
   `_collision_finalize_defer_frames`.
   - Reason: payload-owned collision now drains at unload start via
     `cancel_collision_build_for_request`, and finalize is already gated by
     `_unloading_cells`, `_pending_rs_hide_cells`, and `_pending_rs_cleanup_cells`.
     The extra 30-frame timer is now a stale timing bridge.
   - Verification target: collision-enabled dense/east stress still completes
     with no script/material errors and no live-traversal crash.
2. Delete the unused `CellPayload.release_static_buckets()` helper.
   - Reason: Phase 2A explicitly made live bucket lifetime renderer-owned.
     Leaving an unused payload cleanup method advertises a second possible
     owner and invites future double-free mistakes.
   - Verification target: no callers remain; renderer-owned cleanup still runs
     through `remove_cell_instances` / `clear`.
3. Update stale docs/comments that still say collision body lifetime is tracked
   on `AsyncCellRequest`.
   - Reason: current owner is `CellPayload.collision_body`.
4. If verification exposes worker-side shape-pack duplicate-load errors,
   serialize `StaticShapeCache` sidecar miss/load/publish under its existing
   mutex.
   - Reason: `ResourceLoader.load` is thread-safe, but concurrent loads of the
     same `.shapes.res` can duplicate subresource paths. A single-flight cache
     publish is the canonical cache-owner fix and keeps collision worker output
     deterministic.
5. Do not alter Phase 2B bucket granularity, material lifetime, or hide/free
   ordering in P0.4.
   - Reason: reviewer hard gate requires a written material/RID lifetime design
     before touching that lane.

Explicit follow-up after P0.4:

- East-route 90ms-class max-frame outlier attribution. P0.4 names lifecycle
  owners but does not explain the remaining outlier because prior summaries
  show it outside the measured stream/inst hot path. Treat this as the next
  performance lane before any claim that NEAR is "flawless".
- P0.3 request-state ownership consolidation for the
  `CellManager._async_requests` / `NativeStreamingManager._async_requests`
  split-brain.

### P0.4 Verification Plan

- `git diff --check`
- If only GDScript/docs changed: no `dotnet build` required.
- Ready smoke with collision disabled:
  `scenes/Godotwind.tscn -- --quit-after-ready=1 --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision`
- Collision-enabled dense stress, 30 seconds:
  `--bench-stress=p04_lifecycle_dense_2026_05_01_coder --stress-duration=30 --stress-route=dense-loop`
- Collision-enabled east stress, 30 seconds:
  `--bench-stress=p04_lifecycle_east_2026_05_01_coder --stress-duration=30 --stress-route=east`
- Log gate: no `SCRIPT ERROR`, parse error, `ERROR:`, `material_set_shader`,
  or `child-attach-spike` before benchmark summary.
- Park post-`READY_QUIT` / post-`BENCH_QUIT` signal 11 only if the summary or
  ready marker is already written and the crash remains after project teardown.

### P0.4 Implementation Result

Status: accepted by reviewer 2026-05-01

Implemented 2026-05-01:

- Deleted `CELL_STATIC_COLLISION_FINALIZE_DEFER_FRAMES_AFTER_UNLOAD` and
  `_collision_finalize_defer_frames`. Collision finalization is now gated only
  by explicit lifecycle state: no active unload cells, no pending RS hide cells,
  and no pending RS cleanup cells.
- Deleted unused `CellPayload.release_static_buckets()`. Phase 2A bucket
  cleanup remains renderer-owned through `StaticObjectRenderer`.
- Updated docs that still claimed collision body lifetime lived on
  `AsyncCellRequest`; the owner is now `CellPayload.collision_body`.
- Added a single-flight sidecar load in `StaticShapeCache` after east-route
  verification exposed concurrent worker loads of the same `.shapes.res`.
  One worker now loads a pack key, same-key waiters block on a semaphore, and
  cache state changes remain under `_cache_mutex`.
- Follow-up after implementation review: Phase F now registers the render
  prototype before warming the collision shape sidecar, and main-thread
  `get_shapes()` does not wait behind an in-flight worker sidecar load. This
  keeps collision-cache serialization from delaying visual prototype
  registration.

Verification:

- `git diff --check`: passed, CRLF warnings only.
- Ready smoke with collision disabled:
  `--quit-after-ready=0.5 --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision`
  exited cleanly with code 0.
- Dense final gate `p04_lifecycle_dense_v3_2026_05_01_coder`: completed 30s,
  avg 112.939 FPS, p95 16.145 ms, p99 18.057 ms, max stream 32.451 ms, max
  inst 18.161 ms, max queue 19, 3 frames over 33.33 ms, 0 frames over 50 ms.
- East gate before shape-order follow-up
  `p04_lifecycle_east_v3_2026_05_01_coder`: completed 30s, avg 127.364 FPS,
  p95 16.017 ms, p99 19.692 ms, max stream 196.713 ms, max inst 196.613 ms,
  max queue 8, 3 frames over 33.33 ms, 2 frames over 50 ms. Implementation
  review rejected this as a regression against the prior collision lane.
- East controlled no-collision run
  `p04_east_no_collision_control_2026_05_01_coder`: completed 30s, avg
  206.560 FPS, p99 16.025 ms, max stream 28.755 ms, max inst 21.563 ms,
  max queue 8, 1 frame over 50 ms. This isolated the regression to the
  collision/shape-cache enabled path.
- East after shape-order follow-up:
  `p04_east_shape_order_2026_05_01_coder` completed 30s, avg 132.320 FPS,
  p95 15.261 ms, p99 17.203 ms, max stream 34.122 ms, max inst 18.478 ms,
  max queue 8, 2 frames over 33.33 ms, 1 frame over 50 ms.
- East repeat after shape-order follow-up:
  `p04_east_shape_order_repeat2_2026_05_01_coder` completed 30s, avg
  127.396 FPS, p95 16.134 ms, p99 19.118 ms, max stream 38.983 ms, max inst
  19.891 ms, max queue 12, 3 frames over 33.33 ms, 1 frame over 50 ms.
- Targeted reclaim proof
  `p04_reclaim_boomerang_2026_05_01_coder`: route `p04-reclaim`, 8s
  boomerang, 180 m/s, verification-only `--stress-limbo-hold-frames=300`.
  Completed summary with avg 105.918 FPS, p99 16.281 ms, max frame 27.046 ms,
  max stream 23.114 ms, max inst 14.445 ms, 0 frames over 50 ms. Lifecycle
  event counts before summary: `park_request=7`, `publish_paused=7`,
  `collision_rearmed=7`, `reclaim_cell=5`, `publish_resumed=5`,
  `collision_dispatched=6`, `collision_finalized=2`, `finalize_unloaded=2`.
  The event CSV shows reclaimed requests `1`, `2`, `3`, `5`, and `6` resumed
  before finalize; collision re-dispatched after reclaim and finalized for
  requests `1` and `2` before summary.
- Instrumentation cleanup after implementation review: lifecycle capture is
  disabled by default and bounded to 256 events when enabled. The stress
  harness turns it on only for the explicit reclaim/limbo-hold verification.
- Gated targeted reclaim proof
  `p04_reclaim_boomerang_gated_2026_05_01_coder`: same route and limbo hold.
  Completed summary with avg 97.143 FPS, p99 18.822 ms, max frame 41.603 ms,
  max stream 27.194 ms, max inst 24.094 ms, 0 frames over 50 ms. Lifecycle
  event counts before summary: `park_request=7`, `publish_paused=7`,
  `collision_rearmed=7`, `reclaim_cell=5`, `publish_resumed=5`,
  `collision_dispatched=6`, `collision_finalized=1`, `finalize_unloaded=2`.
  The event CSV shows reclaimed requests `1`, `2`, `3`, `5`, and `6` resumed
  before finalize; collision re-dispatched after reclaim and finalized for
  request `1` before summary.
- Fresh dense/east logs had no `SCRIPT ERROR`, parse error, `ERROR:`,
  `material_set_shader`, `child-attach-spike`, `collision-finalize`, or
  `CellStaticCollision` errors before summary.
- Both final stress runs still exited with the parked post-`BENCH_QUIT` native
  access violation after the summary was written.

Interpretation:

P0.4 cleanup ordering now has a gated targeted reclaim proof in addition to
dense/east traversal. The stale collision frame-defer bridge is gone, the
controlled shape-order follow-up removed the 196/875 ms east-route instantiate
regression, and the boomerang harness shows unload-limbo request park,
publish pause, request restore, publish resume, collision re-arm, collision
re-dispatch, and post-reclaim collision finalization without pre-summary
errors. Lifecycle capture is not always-on in production.

The remaining east-route 80-100 ms max-frame outlier is outside the measured
stream/inst hot path in the latest summaries and remains the next performance
lane before NEAR can be called flawless.
