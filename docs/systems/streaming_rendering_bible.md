# Streaming And Rendering Bible

Date: 2026-05-01  
Owners: researcher1, researcher2  
Scope: Godotwind open-world streaming and rendering, with NEAR stabilization as the active priority

This is the consolidated source of truth for Godotwind's NEAR + MID + HLOD +
FAR streaming/rendering architecture. It folds the durable parts of the recent
research, audits, trackers, and Phase 2B design notes into one document.

This document operationalizes the project rules in `AGENTS.md`:
industry-standard first, no kludges, and simplicity over over-engineering.

Older research remains useful as historical evidence, but new implementation
work should start here.

## Source And Archive Status

This document consolidates the durable NEAR streaming/rendering rules from the
recent audit stack, but it does not replace every referenced system or active
plan doc.

Archived with forwarding notes to this bible:

- `docs/archive/audit/godot_46_streaming_research_2026_05_01_claude.md`
- `docs/archive/reference/how to streaming.md`
- `docs/archive/audit/near_streaming_lifecycle_audit_2026_04_30_coder.md`
- `docs/archive/plans/near_streaming_p0_fix_tracker_2026_04_29_codex.md`

Keep alive:

- `docs/reference/near_streaming_industry_patterns.md`: future CellPreloader
  design details, prediction math, LRU mechanics, and abort-on-teleport plan.
- `docs/reference/server_direct_pattern.md`: generic server-direct reference
  beyond streaming, with reduz context, caveats, and debug guidance.
- `docs/plans/near_streaming_phase_2b_design_2026_05_01.md`: active Phase 2B
  implementation design until Phase 2B ships.
- `docs/systems/distance_rendering.md`: shipped MID/HLOD/FAR system details,
  LOD console commands, ObjectPaging, and impostor specifics.
- `docs/systems/model_loading.md`: shipped model/cache/collision sidecar
  details, including carry held-body carve-out references.

If an archived source disagrees with this file, this file wins. If a keep-alive
system or active plan doc disagrees with this file, resolve the conflict in the
more specific doc and update this bible when the decision is accepted.

## Current Verdict

Godotwind's target shape is sound for Godot 4.6:

- static visuals use `RenderingServer` and never enter the scene tree;
- interactive/gameplay objects use sparse `Node3D` instances;
- cell payloads own streaming queues and resource handles;
- heavy static collision uses one server-direct body per cell;
- MID uses Godot's embedded mesh LOD cascade instead of hand-written LOD bands;
- HLOD and FAR stay parked until NEAR is stable.

The project has not been blocked by a fundamental Godot limitation. The
historical failures came from lifetime ownership and scheduling complexity:
global queues crossing cell lifetimes, cache entries pretending to be owners,
RIDs outliving the resources behind them, and hide/free loops that could still
iterate freed render state.

The next load-bearing implementation is Phase 2B: replace the transitional
per-transform RS bucket with a spatially local MultiMesh bucket that owns the
resources behind its RIDs and frees them in a provable order.

## Status As Of 2026-05-01

Accepted:

- `StreamedResourceHandle` exists in `src/core/streaming/` and pins a
  `PackedScene` plus extracted `Mesh` / `Material` resources.
- `CellPayload` owns model callbacks, static prepare entries, resource handles,
  and static collision worker/body state.
- Completed cell nodes receive streamed resource handles in metadata so live
  scene nodes do not outlive their resources.
- Phase 2A routes heavy static refs into renderer-owned `CellStaticBucket`
  objects instead of the child-attach path.
- P0.4 removed the stale collision finalize frame-defer bridge and proved the
  unload-limbo reclaim path with a boomerang stress route.
- `StaticShapeCache` sidecar loading is single-flight.
- `PHASE_A_OFFTHREAD_INSTANTIATE = false`.
- `StaticObjectRenderer.USE_PROTOTYPE_REGISTRY = false`.
- `StreamingConfig.STATIC_CULL_NATIVE_ENABLED = false`.
- `StreamingConfig.DEBUG_DISABLE_PHASE_F_PREREG = true`.
- `project.godot` does not set `rendering/driver/threads/thread_model`.
- `project.godot` does not set `physics/3d/run_on_separate_thread`.

Outstanding:

- Phase 2B material/RID lifetime and bucket cleanup implementation.
- Per-cell/per-area MultiMesh buckets to replace the transitional
  RS-instance-per-transform bucket.
- `_mesh_types` must stop being the hidden resource lifetime owner for live
  cell buckets.
- Residual east-route 50ms+ outlier attribution.
- Frame budget split needs to move from 60-FPS-era 8ms shared budget toward
  the NEAR target of roughly 1ms streaming publish per frame at 150 FPS.
- Distant rendering, HLOD, and FAR re-enable remain parked until NEAR Phase 2B
  passes runtime gates.

## Primary-Source Facts

Use the tags below when extending this document:

- `D`: directly documented by Godot/OpenMW/source.
- `I`: inference from documented behavior and project evidence.
- `P`: Godotwind policy or accepted local design.

### Server RIDs Do Not Own Resources

`D`: Godot's server docs state that references to a resource's RID are not
counted when determining whether the resource is still in use. Code that passes
`mesh.get_rid()` or `material.get_rid()` to `RenderingServer` must keep a strong
`Mesh` / `Material` reference outside the server.

Source:
https://docs.godotengine.org/en/4.6/tutorials/performance/using_servers.html

`P`: In Godotwind, a raw RID, cache key, queue entry, or `_mesh_types` lookup is
not an ownership proof. A live render object must be backed by a live owner
token.

### Scene Tree Is Main-Thread-Owned

`D`: Godot documents that interacting with the active scene tree is not
thread-safe. `add_child` from a worker is unsafe; `call_deferred` is the
documented safe pattern. Creating scene chunks outside the active tree is
allowed, but Godot warns that loading or creating scene chunks from multiple
threads can crash if shared resources are tweaked concurrently.

Source:
https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html

`P`: Godotwind publishes to the scene tree on the main thread. Worker lanes
prepare pure data, transforms, triangle arrays, and load results.

### Server Calls From Threads Are Conditional

`D`: Godot says global singletons are thread-safe by default, but rendering and
physics server thread-safe operation require project settings. The same page
warns that the separate rendering thread model has known bugs and that GPU
touching calls can stall.

Source:
https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html

`P`: Treat main-thread server publication as the default for streaming. Only
move `RenderingServer` or `PhysicsServer3D` calls to workers after verifying the
exact project setting and the exact call pattern in a harness. Do not put Jolt
body creation on a worker as a speculative optimization.

`P`: This project currently uses Godot defaults for both render and physics
threading. Because `project.godot` does not opt into the separate render thread
or separate 3D physics thread, do not describe current worker-issued
`RenderingServer` or `PhysicsServer3D` calls as "safe via command queue." That
framing only applies after the relevant project setting is enabled and
verified. In the current project configuration, server publication belongs on
the main thread.

### WorkerThreadPool Tasks Must Be Awaited

`D`: Godot's `WorkerThreadPool` docs state that every task must eventually be
waited on with `wait_for_task_completion()` or
`wait_for_group_task_completion()` so allocated resources can be cleaned up.

Source:
https://docs.godotengine.org/en/4.6/classes/class_workerthreadpool.html

`P`: Every new worker lane needs an owner and a drain path. Cancellation that
drops task-bound data before `wait_for_task_completion()` is invalid.

### ResourceLoader Is A Loader, Not A Lifetime Owner

`D`: `ResourceLoader.load_threaded_request`, `load_threaded_get_status`, and
`load_threaded_get` are documented. `load_threaded_get` blocks if the resource
is not finished, and `use_sub_threads` can affect the main thread.

Source:
https://docs.godotengine.org/en/4.6/classes/class_resourceloader.html

`D`: The docs do not specify what happens when a logical requester dies before
`load_threaded_get`, nor do they define per-caller ownership semantics.

`P`: A `CellPayload` or `StreamedResourceHandle` owns the request state and the
loaded resource lifetime. `ResourceLoader` is not the owner.

### MultiMesh Must Be Spatially Local

`D`: Godot's `MultiMesh` class docs state that a MultiMesh is spatially indexed
as one object; if instances are far apart, every instance may render when the
whole object is visible.

Source:
https://docs.godotengine.org/en/4.6/classes/class_multimesh.html

`D`: Godot's MultiMesh optimization tutorial recommends creating several
MultiMeshes for different world areas. It also states that `instance_count`
resizes/clears buffers, while `visible_instance_count` is the normal way to
vary visible count after allocating capacity. The tutorial says the packed
buffer can be created with multiple threads and set in one call.

Source:
https://docs.godotengine.org/en/4.6/tutorials/performance/using_multimesh.html

`P`: A world-scoped per-prototype MultiMesh is the wrong shape for Godotwind.
Use per-cell or per-cell-area buckets.

### Visibility Ranges Are Per GeometryInstance, Not Per MultiMesh Slot

`D`: Godot visibility ranges apply to nodes that inherit from
`GeometryInstance3D`, including `MultiMeshInstance3D`. Fade mode `Disabled`
uses hysteresis; `Self` and `Dependencies` use the margins as fade transition
distances and force transparent rendering during the transition.

Sources:
https://docs.godotengine.org/en/4.6/tutorials/3d/visibility_ranges.html  
https://docs.godotengine.org/en/4.6/classes/class_geometryinstance3d.html

`D`: The docs describe visibility behavior for the whole
`GeometryInstance3D`. They do not document per-instance visibility fade inside
one `MultiMesh`.

`P`: Keep Godotwind's custom `lod_crossfade_multimesh.gdshader` or an
equivalent per-slot shader path for per-instance MultiMesh fades. Do not delete
it on the assumption that engine `visibility_range_fade_mode` replaces
per-instance MultiMesh fade; engine fade applies to the `MultiMeshInstance3D`
as one object.

### Off-Thread PackedScene Instancing Is Not Accepted Yet

`D`: Godot issue #79194 is still open in the public GitHub page. It reports
thread-guard problems when loading a `PackedScene` on one thread and
instantiating it on another, and it is labeled `discussion`, `documentation`,
`needs testing`, and `topic:core`.

Source:
https://github.com/godotengine/godot/issues/79194

`P`: Do not enable `PHASE_A_OFFTHREAD_INSTANTIATE` until either the issue closes
with a documented fix or Godotwind lands an isolated harness that proves the
exact Godot 4.6 shape we use. Older notes that call #79194 "resolved" are
stale.

### Godot Does Not Define A Full RID Free Order

`D`: Godot documents that RIDs must be freed when finished, and that source
resources must be strongly referenced. It does not document a complete
streaming-cell free order for render instances, MultiMeshes, materials, and
meshes.

`D`: Godot issue #69910 and PR #69972 show that leaked server RIDs and server
teardown ordering have caused engine-exit crashes. PR #69972 added safety
checks; it did not define a project-level free order.

Sources:
https://github.com/godotengine/godot/issues/69910  
https://github.com/godotengine/godot/pull/69972

`P`: Godotwind owns the free order. The canonical local order is:

1. Stop all project iteration that can discover the bucket.
2. Stop drawing by hiding instances if needed.
3. Free RS instance RIDs.
4. Free MultiMesh RIDs/resources.
5. Drop material strong references.
6. Drop mesh strong references.
7. Drop cache lookup state.

### Automated Quit Crash Is Parked, Not A Streaming Blocker

`D`: Godot has open or recent quit/access-violation issues on Windows and
rendering teardown paths, including #118354, #84265, and #106228.

Sources:
https://github.com/godotengine/godot/issues/118354  
https://github.com/godotengine/godot/issues/84265  
https://github.com/godotengine/godot/issues/106228

`P`: A post-`READY_QUIT` or post-`BENCH_QUIT` native access violation is parked
only if the benchmark summary or ready marker already wrote, `LOG_EXIT done`
appears, tracked worker tasks are zero, and there is no new pre-summary
GDScript/render/material error. Live traversal crashes are never parked.

### OpenMW Validates Prefetch, Not Godot RID Lifetime

`D`: OpenMW's `Scene::preloadCells(float dt)` computes a predicted player
position using velocity and `mPredictionTime`, then preloads exterior grids,
teleport destinations, and terrain around that predicted position.

Local source:
`inspos/openmw/apps/openmw/mwworld/scene.cpp`

`D`: OpenMW's `CellPreloader` keeps a bounded `mPreloadCells` map, updates
timestamps on duplicate preload requests, evicts old entries, aborts work items
on load/clear/expiry, and runs resource cache cleanup through a work item.

Local source:
`inspos/openmw/apps/openmw/mwworld/cellpreloader.cpp`

`D`: OpenMW unloads cells atomically and uses OSG reference counting rather
than Godot `RenderingServer` RIDs.

`P`: Godotwind should keep velocity-based predictive preload. Godotwind's
unload-limbo reclaim path is a local extension justified by P0.4 verification,
not something inherited from OpenMW.

## Tier Architecture

An object belongs to exactly one visual tier at a time.

| Tier | Range | Runtime Technique | Current Status |
| --- | --- | --- | --- |
| NEAR | 0-150m | Sparse `Node3D` only for interactives, static visuals server-direct, cell static collision server-direct | Active stabilization |
| MID | 0-300m with HLOD, 0-500m fallback | One RS instance per object with embedded `ArrayMesh` LOD chain; Godot C++ chooses sub-LOD | Working, HLOD parked while NEAR stabilizes |
| HLOD | 300-1000m | Runtime-merged static geometry per chunk, one RS instance per chunk | Implemented, not priority |
| FAR | 1000-5000m | Octahedral impostors in MultiMesh | Working, parked during NEAR stabilization |

Rules:

- The cell is the data unit because Morrowind exterior records are cell-keyed.
  That is adapter-layer reality; the core framework should still express the
  concept generically as a world tile/streaming cell.
- Static clutter is not a scene-tree workload. It is transform data plus
  prototype resources.
- Interactives are sparse and worth the `Node3D` cost because their scripts,
  signals, animation, physics, inventory, and UI hooks are the feature.
- Hysteresis prevents oscillation at tier boundaries.
- Engine visibility ranges and embedded LOD are preferred over per-frame
  GDScript distance checks.

## Static vs Interactive Split

Static refs:

- rocks, architecture, clutter, flora, purely visual props;
- rendered by `StaticObjectRenderer`;
- collision from per-cell merged static collision;
- no per-instance `_process`, no scene-tree child, no script.

Interactive refs:

- NPCs, creatures, carryables, doors, containers, activators, animated lights,
  dynamic objects;
- spawned as `Node3D` only when they need gameplay behavior;
- attached on the main thread under budget;
- own or inherit a `StreamedResourceHandle` while alive.

This split is the most important performance rule in NEAR. Tuning budgets will
not fix a design that sends static clutter through `PackedScene.instantiate()`
and `add_child()`.

## Ownership Model

The owner token is the truth.

Current owner-token chain:

```text
ResourceLoader / cache lookup
  non-owning; may answer "where is this resource?"

StreamedResourceHandle
  strong owner of PackedScene plus extracted Mesh/Material refs

CellPayload
  owns handles while the cell is loading/publishing

Live cell node metadata
  owns handles after async request completion

CellStaticBucket / future StaticPrototypeToken
  must own or pin resources while render RIDs exist

RenderingServer / PhysicsServer RIDs
  never own source Resources
```

Phase 2B owner-token contract:

1. Cache lookup is non-owning. It may answer "where is this resource?" but is
   not proof the resource is still alive for rendering.
2. `StreamedResourceHandle` is the strong owner-token for a loaded model.
3. `CellPayload` pins handles while the cell is loading or publishing.
4. A live cell node keeps handles in metadata after the payload result is
   accepted.
5. `CellStaticBucket` pins the same owner-token, or a direct bucket resource
   token derived from it, while the bucket has live render IDs.
6. Render IDs are derived on the main thread from still-live resources.
7. Unload releases owners in reverse order: bucket render IDs first,
   bucket-held resource refs next, payload/node handles next, cache lookup
   state last.

Forbidden reasoning:

- "The RID is valid, so the mesh is alive."
- "The cache key exists, so the resource is alive."
- "`_mesh_types` lives until `clear()`, so buckets are safe."
- "The stress summary wrote, so traversal is stable."

Required reasoning:

- Which object owns the strong resource reference?
- Which collection can still iterate the owner?
- Which method frees the RID?
- Which method drops the resource token?
- What proves the worker task cannot still touch the payload?

## Cleanup Order

Every unload, hard cancel, and shutdown path follows this order:

1. Mark the request/payload/bucket as unloading or frozen.
2. Stop new publish work.
3. Remove the object from every registry, queue, cursor, and iterator source
   that could discover it on a later tick.
4. Await owned `WorkerThreadPool` tasks.
5. Hide render instances if a visual stop is needed before cleanup.
6. Free server RIDs while source resources are still strongly referenced.
7. Queue-free detached or scene-tree nodes.
8. Drop resource handles and cache pins.
9. Erase bookkeeping.

The key rule is iteration-stop before free. Hiding is not iteration-stop. A
hidden bucket can still be reached by a cull/upload/hide cursor; a frozen and
detached bucket cannot.

## Phase 2B Bucket Contract

Phase 2A is a transitional state:

- `CellStaticBucket` owns RS instance RIDs only.
- Mesh/material resources are still held by `StaticObjectRenderer._mesh_types`.
- Each transform x submesh can create an RS instance.
- Cleanup currently walks bucket arrays directly.

Phase 2B target:

- bucket key: `(cell_grid, payload_key)`;
- `payload_key = CellPayload.make_model_key(model_path, item_id)`;
- bucket owns render RIDs and the resource owner-token behind them;
- bucket contains one or more spatially local MultiMeshes;
- one MultiMesh per submesh/material group inside one cell-local bucket;
- `instance_count` set once at construction;
- `visible_instance_count` only for steady-state visible count changes;
- transform/custom-data buffers may be prepared off-thread as pure arrays;
- server publication and scenario/base assignment happen on the main thread
  unless a dedicated harness proves otherwise;
- cleanup detaches the bucket from all registries before freeing any RID.

Suggested bucket shape:

```gdscript
class_name CellStaticBucket
extends RefCounted

class DrawGroup:
    var multimesh: MultiMesh
    var multimesh_rid: RID
    var instance_rid: RID
    var material_resource: Material

var cell_grid: Vector2i
var type_name: String
var payload_key: String
var prototype_token: RefCounted
var draw_groups: Array[DrawGroup]
var visible: bool
var frozen: bool
```

The `prototype_token` can initially wrap `StreamedResourceHandle`, but the
bucket must hold it directly. `_mesh_types` can remain a lookup table, not the
live bucket owner.

Cleanup for a bucket:

1. `frozen = true`.
2. Remove from `_cell_buckets`, `_cell_bucket_hide_progress`, hide queues,
   cleanup queues, publish queues, cull/upload queues, and payload active
   records.
3. Every loop checks `frozen` at the top and skips.
4. Confirm no future tick can discover the bucket from a renderer or manager
   collection.
5. Hide instance RIDs if needed. This is draw-stop, not iteration-stop.
6. Free instance RIDs.
7. Free MultiMesh RIDs or drop MultiMesh resources.
8. Clear bucket-owned RID arrays.
9. Drop bucket-owned strong refs and handle owner-token.
10. Update stats and erase bookkeeping.

No code may free a bucket while another same-frame cursor can still discover
it.

## `_mesh_types` Rule

Final invariant:

`_mesh_types` is a prototype descriptor table, not the lifetime owner for live
cell render IDs.

Allowed:

- immutable descriptor metadata;
- normalized type name / model path;
- token lookup key;
- debug stats;
- lock-protected insert/clear.

Not allowed after Phase 2B:

- relying on `_mesh_types` strong refs to keep live bucket resources alive;
- clearing `_mesh_types` while buckets can still be discovered;
- mutating published descriptor fields while workers or publishers can read
  them.

Temporary allowance:

- legacy direct RS instances may depend on current `_mesh_types` ownership
  until they are deleted. This allowance is not the final architecture.

## Single-Flight Rules

For each resource/prototype/bucket key:

- one owner loads or publishes;
- duplicate callers wait, reuse, or skip;
- no second owner publishes the same key in the same lifetime window.

Already aligned:

- `StreamedResourceHandle` for loaded model resources.
- `StaticShapeCache` for collision sidecar shape packs. Single-flight plus
  Phase F render-prototype-registration-before-shape-warm landed 2026-05-01.
- `CellPayload` ownership of model waiter/completion queues.

Phase 2B must add:

- single-flight static prototype publication per type/token key;
- single-flight bucket creation per `(cell_grid, payload_key)`;
- no second bucket for the same key while one is publishing, visible, hiding,
  frozen, or pending cleanup.

## Threading Model

Main thread:

- active scene tree mutation;
- `add_child`, `queue_free`;
- `RenderingServer` publication in the current project thread model;
- `PhysicsServer3D` body/shape publication in the current project thread model;
- `ConcavePolygonShape3D.set_faces`;
- cell lifecycle state transitions;
- visible/collision handoff.

WorkerThreadPool:

- ESM/data classification that does not touch the active tree;
- model load request bookkeeping;
- pure transform buffer construction;
- static collision triangle gathering;
- C# hot-path math kernels;
- cache lookup work that does not mutate shared resources without a lock.

Avoid:

- worker mutation of active scene tree;
- multiple workers loading/modifying the same Godot `Resource`;
- worker `PackedScene.instantiate()` in production before the Phase A harness;
- worker RenderingServer/PhysicsServer/Jolt publication in the current project
  settings;
- unawaited WorkerThreadPool tasks.

## Cell Preload Pattern

Keep the data unit as a cell. Improve timing with predictive preload, not
per-object streaming.

OpenMW's useful pattern:

- predict player position from velocity and prediction time;
- preload the outer grid around the predicted position;
- preload door/teleport destinations;
- keep a bounded preload cache;
- update timestamps on reuse;
- abort work when the cell becomes loaded or cache entries expire.

Godotwind adaptation:

- `CellPreloader` should warm model resources and prototype data before the
  cell enters active radius.
- It must not instantiate active scene-tree nodes.
- It must have max cache size, min cache size, expiry delay, and task drains.
- Door/interior preloads should use the same path.
- Fast teleports abort irrelevant preloads and seed around the destination.

Do not build an octree or per-object streamer for this problem. The cell is the
right data unit; the old bottleneck was per-ref scene-tree publication, not
cell granularity.

## Reclaim And Unload Limbo

Godotwind keeps cells in unload limbo so fast backtracking can reclaim partially
loaded work instead of throwing it away and rebuilding it. This is a local
design, not an OpenMW pattern: OpenMW unloads cells atomically.

P0.4 accepted this path with the reclaim boomerang route. The proven sequence
is: park request, pause publish, reclaim cell before finalize, resume publish,
re-arm collision, re-dispatch collision if needed, and finalize only when the
cell truly leaves. The observable boundary for Phase 2B buckets is `frozen`: a
bucket that has been frozen/detached for cleanup must not be reclaimed; a
bucket that has not entered frozen cleanup may continue with the same owner
token.

Do not delete `_unloading_cells` or `_unloading_request_ids` as "extra state"
without replacing the reclaim behavior and re-running the boomerang proof.

## Static Collision Example

The shipped physics-side example of the static/interactive split is
`cell_static_collision.gd`:

- worker lane gathers static triangles into a payload;
- main thread builds one `ConcavePolygonShape3D` and one server-direct
  `PhysicsServer3D` body per cell;
- `CellPayload.collision_body` owns the finalized body and strong shape ref;
- closest-ready cells finalize first;
- unload/cancel/shutdown drain the worker before freeing the body or dropping
  shape resources.

This is the canonical pattern for high-count static collision in Godotwind:
pure data off-thread, server publication on the main thread, one explicit
owner, and no `StaticBody3D` node storm.

## Code Recipes

These are starter shapes, not copy-paste final implementations. Match current
code before editing, and keep Phase 2B changes surgical.

### Resource Handle

`StreamedResourceHandle` is the pin. It owns the `PackedScene` and extracted
resources so RID consumers never depend on cache lookup lifetime.

```gdscript
class_name StreamedResourceHandle
extends RefCounted

var cache_key: String
var packed_scene: PackedScene
var meshes: Array[Mesh] = []
var materials: Array[Material] = []

func _init(p_key: String, p_scene: PackedScene) -> void:
	cache_key = p_key
	packed_scene = p_scene
	_collect_scene_state_resources()
```

The cache should become a lookup to a handle/token, not the owner. The current
`ModelLoader` compatibility pin APIs can remain only as a migration bridge
until all consumers use the handle/token directly.

### Payload Publish Step

`CellPayload.publish_step(budget_usec)` is the seam for moving work out of the
mega-driver and into per-cell ownership.

```gdscript
func publish_step(budget_usec: int) -> int:
	if budget_usec <= 0 or state == State.UNLOADING:
		return 0
	if not publish_driver.is_valid():
		return 0
	return maxi(0, int(publish_driver.call(self, budget_usec)))
```

Target direction: each payload owns classification, model completions, static
prepare, child attach, collision publish, and unload cleanup. The streaming
manager rotates payloads and enforces the global frame budget.

### Cell Static Bucket

Phase 2B bucket constructor shape:

```gdscript
class_name CellStaticBucket
extends RefCounted

var payload_key: String
var prototype_token: RefCounted
var draw_groups: Array[DrawGroup] = []
var frozen: bool = false

func configure(token: RefCounted, transforms: Array[Transform3D]) -> bool:
	prototype_token = token
	# Build per-submesh/material MultiMesh groups from still-live resources.
	return true

func cleanup() -> int:
	frozen = true
	# Caller must detach from registries before this frees RIDs.
	_free_draw_groups()
	prototype_token = null
	return 0
```

Never let `cleanup()` walk and mutate `_cell_buckets[cell]` in place. Detach a
local list first, then free detached buckets.

### Off-Thread Build, Main-Thread Publish

Worker task:

```gdscript
func _build_static_buffers(payload: CellPayload) -> Dictionary:
	# Pure data only: transforms, custom data, triangle arrays, counts.
	return {"transforms": PackedFloat32Array()}
```

Main thread:

```gdscript
func _publish_static_buffers(result: Dictionary) -> void:
	# Create RS/MultiMesh/Physics objects here in the current project settings.
	# Do not touch the active scene tree from the worker.
	pass
```

Every worker task must be awaited before task-bound data is dropped.

### Diagnostic Bridge

Temporary bridges are allowed only as explicit diagnostics:

```gdscript
# DIAGNOSTIC BRIDGE (YYYY-MM-DD, owner)
# Symptom: <what this papers over>
# Canonical replacement: <standard pattern this stands in for>
# Follow-up: <commit/PR that removes it>
# TODO(owner, YYYY-MM-DD): remove by YYYY-MM-DD.
```

A bridge without symptom, canonical replacement, follow-up, owner, and expiry
date is a kludge.

## Frame Budget Targets

The historical shared 8ms streaming budget was a 60 FPS-era setting.

Target NEAR budget at 150 FPS:

| Lane | Target |
| --- | --- |
| render | 3-4ms |
| physics | about 1ms amortized |
| streaming publish | about 1ms |
| animation/gameplay/UI | remaining budget |

Practical rules:

- A single non-preemptible `add_child()` or `set_faces()` can break the budget.
- Count-limiting is not enough if one item is huge.
- Heavy static-looking refs must leave the Node3D path.
- Main-thread publication should be sliced by lane, not one mega-driver.
- P99 and max-frame matter more than average FPS for streaming work.

## Verification Gates

For any streaming/rendering/performance code change:

1. If C# changed, run `dotnet build Godotwind.sln`.
2. Run `git diff --check`.
3. Run an automated smoke that exercises the changed path.
4. Launch `scenes/Godotwind.tscn` interactively with the documented Godot 4.6
   binary, or explain exactly why this could not be done.

Documented launch:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn
```

Phase 2B automated gates:

- dense route with collision enabled;
- east route with collision enabled;
- reclaim boomerang route with collision enabled;
- targeted material/RID iteration-order stress;
- no `SCRIPT ERROR`;
- no parse error;
- no `ERROR:`;
- no `material_set_shader`;
- no stale bucket discovered after detach;
- no collision finalize errors.

Manual gate:

- user-visible traversal through dense exterior cells;
- no live traversal crash;
- no severe FPS collapse;
- no queue runaway;
- no missing static visuals or collision regression.

Automated stress alone is not enough. It missed prior user-visible traversal
failures.

## Cross-Engine Sanity Check

Use this table as a smell test. If a proposed architecture diverges from all
reference engines and the Godot docs, it needs a written design rationale.

| Engine | Streaming Unit | Static Clutter | Interactive Objects | Prefetch |
| --- | --- | --- | --- | --- |
| UE5 World Partition | grid runtime cell | HLOD / instanced static mesh actors | actors in activated cells | streaming sources |
| Decima | tile | GPU instance buffers | limited actor hierarchy | active grid expansion |
| Unity DOTS/BRG | scene/group/chunk | BatchRendererGroup buffers | GameObjects where needed | Addressables priorities |
| RAGE | sector | drawable/resource bundles | scene entities | priority queues |
| OpenMW | exterior cell | object paging / merged geometry | MWWorld objects | velocity prediction |
| Bevy-style ECS | chunk | instance buffer component | entities with gameplay components | app-defined |
| Godotwind target | cell + distance tier | per-cell/per-area server-direct buckets | sparse `Node3D` | velocity `CellPreloader` |

## Parked vs Blocking Failures

Blocking:

- crash during live traversal;
- `material_set_shader` before benchmark summary;
- stale bucket found after detach;
- GDScript parse/runtime error;
- worker task left unawaited before payload/resource free;
- resource eviction crash;
- 50ms+ outlier caused by the changed path;
- missing visuals/collision in the active cell.

Parkable:

- post-`BENCH_QUIT` or post-`READY_QUIT` native access violation after summary
  or ready marker, after `LOG_EXIT done`, with zero tracked worker tasks, and
  no pre-summary errors.

Do not use the parked quit crash to justify ignoring a live traversal bug. Do
not patch the parked quit crash with another defer-frame bridge unless a new
project-owned cause is proven.

## Anti-Patterns

Do not:

- add a new permanent `*_DEFER_FRAMES_*` or `*_DEFER_TICKS_*` constant;
- add a permanent `DEBUG_DISABLE_*` around a crashy system and call it fixed;
- create a new global queue crossing cell lifetime boundaries;
- clear resources because a cache says they are unused while a payload/bucket
  can still own them;
- rely on a RID as a refcount;
- use world-scoped MultiMeshes for a large open world;
- re-enable `PrototypeRegistry` without making it spatially local;
- enable off-thread `PackedScene.instantiate()` without a harness;
- call `get_node()` or RenderingServer getters every frame in hot paths;
- skip `wait_for_task_completion()`;
- default new hot streaming logic to GDScript when C# is the better fit.

Do:

- use Godot engine features first: embedded mesh LOD, visibility ranges,
  MultiMesh, WorkerThreadPool, ResourceLoader, server-direct APIs;
- keep framework code game-agnostic;
- put Morrowind-specific conversion/format logic in adapters;
- use `StreamedResourceHandle` or successor owner tokens for lifetime;
- detach first, free second, drop resources third;
- write small targeted tests for math/lifetime utilities;
- run runtime verification before claiming a gameplay/rendering change done.

## Implementation Order

1. Finish Phase 2B design review.
2. Implement bucket owner-token and detach-before-free cleanup.
3. Replace transitional RS-instance-per-transform buckets with per-cell
   MultiMesh draw groups.
4. Convert `_mesh_types` to descriptor/non-owning lookup for buckets.
5. Delete legacy direct RS static bucket assumptions.
6. Attribute and remove east-route 50ms+ outliers.
7. Split streaming budgets by lane for the 150 FPS target.
8. Only then resume HLOD/FAR/distant rendering re-enable.

## Minimum Acceptance For Phase 2B

Phase 2B is accepted when:

- each live `CellStaticBucket` owns or pins the resources behind its render
  RIDs;
- cleanup stops all iteration before any RID free;
- `_mesh_types` is no longer the hidden lifetime owner for live buckets;
- per-cell/per-area MultiMesh buckets replace per-transform RS instances;
- duplicate bucket publication is single-flight;
- dense/east/reclaim/material-RID stress gates pass with collision enabled;
- the old `material_set_shader` failure is reproduced by a targeted stress
  before the fix and absent after the fix;
- interactive launch is performed for visual verification.

## Glossary

- **Bucket**: spatially scoped set of instances for one prototype/payload key.
  Phase 2B buckets are per cell or per cell-local area.
- **Cell**: streaming data unit. For Morrowind data this is the exterior cell;
  framework code should treat it as a generic world tile.
- **CellPayload**: per-cell owner of publish queues, model callbacks, resource
  handles, static prepare state, and collision state.
- **Detached subtree**: a node tree not attached to the active scene tree.
- **Handle**: shorthand for `StreamedResourceHandle`, the resource owner token.
- **Hysteresis**: different promotion/demotion thresholds that prevent
  oscillation at distance boundaries.
- **Instance**: a `RenderingServer` render object RID or a slot in a MultiMesh,
  depending on context.
- **MID**: distance tier using server-direct RS objects with embedded mesh LOD.
- **MultiMesh slot**: one transform/custom-data entry inside a MultiMesh.
- **NEAR**: closest gameplay tier; only interactives should become `Node3D`.
- **Owner token**: strong refcounted object that proves resources are alive.
- **Pin**: lifetime extension. In the target design, the handle/token is the
  pin, not a cache-key side table.
- **Prototype**: unique mesh/material identity shared by many placed instances.
- **RID**: opaque server handle. It is not a resource reference and not a
  refcount owner.
- **Scenario**: `RenderingServer` world context for render instances.
- **Static clutter**: visual-only refs that should bypass the scene tree.
- **Tier**: distance band such as NEAR, MID, HLOD, or FAR.
- **Unload limbo**: Godotwind's temporary parked-unload state that supports
  fast backtracking reclaim.

## Sources

Godot:

- Optimization using Servers:
  https://docs.godotengine.org/en/4.6/tutorials/performance/using_servers.html
- Thread-safe APIs:
  https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html
- Optimization using MultiMeshes:
  https://docs.godotengine.org/en/4.6/tutorials/performance/using_multimesh.html
- MultiMesh class:
  https://docs.godotengine.org/en/4.6/classes/class_multimesh.html
- Visibility ranges:
  https://docs.godotengine.org/en/4.6/tutorials/3d/visibility_ranges.html
- GeometryInstance3D class:
  https://docs.godotengine.org/en/4.6/classes/class_geometryinstance3d.html
- WorkerThreadPool class:
  https://docs.godotengine.org/en/4.6/classes/class_workerthreadpool.html
- ResourceLoader class:
  https://docs.godotengine.org/en/4.6/classes/class_resourceloader.html
- PackedScene threading issue #79194:
  https://github.com/godotengine/godot/issues/79194
- RID/server teardown issue #69910:
  https://github.com/godotengine/godot/issues/69910
- Server free safety PR #69972:
  https://github.com/godotengine/godot/pull/69972
- Windows/headless quit crash #118354:
  https://github.com/godotengine/godot/issues/118354
- Rendering close crash #84265:
  https://github.com/godotengine/godot/issues/84265
- Crash on quit issue #106228:
  https://github.com/godotengine/godot/issues/106228

Local OpenMW source:

- `inspos/openmw/apps/openmw/mwworld/scene.cpp`
- `inspos/openmw/apps/openmw/mwworld/cellpreloader.cpp`
- `inspos/openmw/apps/openmw/mwworld/cellpreloader.hpp`

Godotwind code:

- `src/core/streaming/streamed_resource_handle.gd`
- `src/core/world/cell_payload.gd`
- `src/core/world/cell_static_bucket.gd`
- `src/core/world/streaming_config.gd`
- `src/core/world/static_object_renderer.gd`
- `src/core/world/cell_static_collision.gd`
- `src/core/world/cell_manager.gd`
- `src/core/world/native_streaming_manager.gd`
- `src/core/world/distance_utils.gd`
