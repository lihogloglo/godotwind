# NEAR Streaming Phase 2B Design

Date: 2026-05-01
Owner: codex
Reviewer: claude
Scope: written design only; no bucket-granularity or free-order code changes land until review signs off

## Plain English Summary

Phase 2A stopped many heavy static objects from being added to the scene tree.
That was good, but it left the renderer in a halfway state: each cell bucket
owns the render IDs it creates, while the meshes and materials those render
IDs point at still live in `StaticObjectRenderer._mesh_types`.

Phase 2B closes that gap. A cell bucket must keep the mesh, material, and
handle references it needs for as long as its render IDs exist. When a cell
unloads, we first remove the bucket from every list that might still loop over
it. Only after nothing can iterate it do we free the render IDs. Only after the
render IDs are gone do we drop the strong mesh/material references.

This is the same rule in plain terms: stop using the thing, then delete the
render-side handle, then let the underlying data go.

## Current State

Accepted baseline:

- `StreamedResourceHandle` exists and is the resource pin for loaded
  `PackedScene` resources and extracted meshes/materials.
- `CellPayload` owns model callbacks, static prepare entries, resource handles,
  and static collision worker/body state for a loading cell.
- Phase 2A added `CellStaticBucket`, which routes static refs into
  renderer-owned per-cell buckets instead of scene-tree child attach.
- P0.4 proved the unload-limbo reclaim path with the boomerang stress route.

Current Phase 2A limitation:

- `CellStaticBucket` owns only `RenderingServer` instance RIDs.
- The meshes and materials used by those RIDs are still kept alive by the
  renderer-wide `_mesh_types` dictionary.
- `_mesh_types` is effectively immortal until `StaticObjectRenderer.clear()`.
- Two Phase 2B code attempts changed bucket hide/free behavior and hit the
  old `material_set_shader` null-material loop, so this design is required
  before any more code in that lane.
- The 2026-05-01 research note listed other possible contributors: the
  cull/upload tick and the prototype-batch fade chain. Those are out of scope
  for this design because the world-scoped registry path is currently disabled
  by `USE_PROTOTYPE_REGISTRY = false` in `static_object_renderer.gd`, so those
  registry iteration paths should not fire in the accepted Phase 2A state.

## Non-Goals

Phase 2B does not:

- re-enable distant rendering, HLOD, FAR impostors, or world-scoped
  `PrototypeRegistry`;
- add new permanent disable flags;
- add new defer-frame or defer-tick constants;
- enable off-thread `PackedScene.instantiate()` while Godot issue #79194 is
  still open;
- chase the parked post-`READY_QUIT` / post-`BENCH_QUIT` native signal 11 when
  the benchmark summary and `LOG_EXIT done` already completed.

## Canonical Pattern

The Godot rule that drives this design is from the server docs: a RID does not
keep the source `Resource` alive. If we hand the renderer a mesh RID or material
RID, project code must keep the `Mesh` and `Material` objects alive until every
render ID that uses them has been freed.

Godot's MultiMesh docs also say a MultiMesh is spatially indexed as one object,
and recommend separate MultiMeshes for different world areas. For Godotwind,
the natural world area is the loaded cell or a smaller cell-local bucket.

OpenMW is useful for the broad streaming shape: per-cell ownership, off-thread
preload, bounded caches, and velocity prediction. It is not proof for our
unload-limbo reclaim path, because OpenMW does not have that path and does not
own Godot `RenderingServer` RIDs.

Sources summarized in:

- `docs/reference/how to streaming.md`
- `docs/audit/godot_46_streaming_research_2026_05_01_claude.md`
- Godot 4.6 `using_servers`, `using_multimesh`, `thread_safe_apis`,
  `WorkerThreadPool`, and `ResourceLoader` docs cited by the research note.

## Owner-Token Contract

Phase 2B uses one owner-token rule everywhere:

1. Cache lookup is non-owning. A cache may answer "where is this resource?"
   but must not be treated as proof the resource is still alive for rendering.
2. A `StreamedResourceHandle` is the strong owner-token for a loaded model.
   It holds the `PackedScene` plus extracted `Mesh` and `Material` references.
3. A `CellPayload` pins handles while the cell is loading or publishing.
4. A live cell node keeps handles in metadata after the payload result is
   accepted, so interactive Node3D objects do not outlive their resources.
5. A `CellStaticBucket` pins the same owner-token, or a direct bucket resource
   token derived from it, for as long as the bucket has live render IDs.
6. Render IDs are derived on the main thread from still-live resources.
7. Unload releases owners in reverse order: bucket render IDs first, then
   bucket-held resource refs, then payload/node handles, then cache lookup
   state.

The owner-token is the truth. Queue membership, cache membership, and raw RIDs
are not ownership.

## Specializations

`StreamedResourceHandle`:

- Already exists.
- Phase 2B keeps it as the model resource owner-token.
- Later cleanup can remove leftover cache-pin APIs once all callers use handle
  ownership directly.
- Delete-by target for the old cache-pin compatibility path:
  2026-05-08, after Phase 2B implementation and verification.

`CellStaticBucket`:

- Phase 2B changes this from "owns only RIDs" to "owns RIDs plus the resource
  owner-token needed by those RIDs."
- The bucket must be able to answer "which meshes/materials stay alive because
  I exist?"
- This is the main Phase 2B migration.

`StaticShapeCache`:

- Already moved to single-flight loading in P0.4.
- It remains a sidecar specialization of the same rule: one owner publishes a
  shape pack key, other waiters share that result.
- No Phase 2B code change required unless verification shows shape lifetime is
  coupled to bucket cleanup.

`StaticObjectRenderer._mesh_types`:

- Phase 2B uses Option B: refcounted owner-token ownership.
- Operational definition of "non-owning lookup": `_mesh_types` no longer stores
  strong `Mesh` or `Material` refs for live bucket lifetime. Phase 2B splits the
  current `MeshType` role into:
  - an immutable lookup descriptor keyed by `type_name` / normalized model path;
  - a refcounted `StaticPrototypeToken` table that owns the `Mesh`, `Material`,
    shader, and sub-mesh resource refs.
- A bucket is keyed by `payload_key` (`CellPayload.make_model_key(model_path,
  item_id)`), then pins the `StaticPrototypeToken` before it creates render IDs.
  The descriptor tells the bucket what token to pin; the descriptor is not the
  owner.
- Delete-by target for immortal `_mesh_types` assumptions:
  2026-05-06 for `CellStaticBucket`; 2026-05-10 for remaining legacy direct
  RS-instance paths.

## Bounded `_mesh_types` Lifetime Invariant

Phase 2B chooses the refcounted owner-token invariant:

`_mesh_types` is a prototype lookup table, not the lifetime owner for live
cell render IDs.

That means:

- `_mesh_types[type_name]` stores immutable prototype metadata and the key for
  a `StaticPrototypeToken`; it does not own the live bucket's resources.
- A live `CellStaticBucket` must hold its own strong token reference.
- `StaticObjectRenderer.clear()` must stop all bucket/direct-instance
  iteration, free all bucket/direct-instance RIDs, and only then clear
  `_mesh_types`.
- No new code may say "this is safe because `_mesh_types` lives until clear"
  for a live cell bucket.

Temporary allowance:

- During the first implementation pass, if legacy direct RS instances still
  depend on `_mesh_types`, they are allowed to keep the old invariant only
  while Phase 2B migrates `CellStaticBucket`.
- That allowance is a dated tail item, not the final design.

## CellStaticBucket Shape

The final bucket is per cell, per `payload_key`, and internally may contain
one or more spatially local MultiMeshes.

Plain version:

- one loaded cell owns a small set of buckets;
- each bucket covers one `payload_key` in that cell. `payload_key` is
  `model_path + item_id`, not just `type_name`; this prevents an item variant
  and the base model from publishing two overlapping buckets;
- the bucket stores transforms for instances of that prototype in that cell;
- the bucket owns the render objects for those instances;
- the bucket owns the resources those render objects point at.

Proposed data:

```gdscript
class_name CellStaticBucket
extends RefCounted

class DrawGroup:
    var multimesh_rid: RID
    var instance_rid: RID
    var material_resource: Material

var cell_grid: Vector2i
var type_name: String
var payload_key: String
var prototype_token: StaticPrototypeToken
var draw_groups: Array[DrawGroup]
var visible: bool
var frozen: bool
```

Each `DrawGroup` contains exactly one MultiMesh RID and exactly one RS instance
RID pointing at that MultiMesh. The array index is the pairing; cleanup frees
`draw_groups[i].instance_rid` before `draw_groups[i].multimesh_rid`.

`StaticPrototypeToken` is the bucket's strong resource owner. It can wrap the
existing `StreamedResourceHandle` at first, but the bucket should hold the
prototype token directly so `_mesh_types` is not the hidden owner.

## MultiMesh Batching Design

Phase 2B replaces the transitional RS-instance-per-submesh bucket with
per-cell/per-area MultiMesh buckets.

Rules:

- Use one MultiMesh per cell-local `payload_key` / submesh / material group.
- Do not use one world-scoped MultiMesh for all loaded cells.
- Set `instance_count` once when the bucket is built.
- Use `visible_instance_count` only if the bucket needs a steady-state visible
  count change.
- Build transform/custom-data buffers off-thread if useful. The docs allow the
  packed MultiMesh buffer to be prepared off-thread and set in one call. The
  main-thread boundary is server publication: create the RS instance, assign
  the scenario, assign the base, and connect it to the world on the main
  thread.
- Keep the project's custom crossfade shader. Godot docs do not document
  per-instance MultiMesh fade as a replacement for it.

Why this is the right shape:

- It follows Godot's documented MultiMesh area-splitting guidance.
- It keeps culling spatially local, so one far-away cell does not force a huge
  world-wide batch to draw.
- It removes thousands of individual RS instances from the static lane.
- Today the bucket creates one RS instance per `transform x submesh`. A bucket
  with 10,000 transforms and three submeshes can create 30,000 RS instances.
  The MultiMesh bucket collapses the transform dimension into slots, so the
  same bucket becomes three MultiMeshes and three RS instances. Verification
  should count this before and after.

## Iteration-Stop Before Free

This is the core safety rule for the `material_set_shader` loop.

Project owns iteration-stop/free ordering regardless of whether the loop is
engine-side or project-side.

For every bucket free path:

1. Mark the bucket `frozen = true`. This is the iteration gate.
2. Remove the bucket from every registry that can iterate it:
   `_cell_buckets`, `_cell_bucket_hide_progress`, hider queues, cleanup queues,
   publisher queues, cull/upload queues, and any payload active records.
3. Every hide/cull/upload/publish loop must check `bucket.frozen` at the top of
   the iteration and skip frozen buckets. This is what makes free safe.
4. Confirm no future tick can discover the bucket from a renderer or manager
   collection.
5. Hide live instance RIDs or make the bucket invisible if that has not already
   happened. This is the draw-stop, not the iteration-stop.
6. Free instance RIDs.
7. Free MultiMesh RIDs.
8. Clear bucket-owned RID arrays.
9. Drop bucket-owned strong refs and handle owner-token.
10. Erase bookkeeping counters and stats.

Forbidden pattern:

- walking `_cell_buckets[cell]` while `bucket.cleanup()` frees RIDs and mutates
  the same ownership structure;
- freeing a RID while another same-frame hider/culler/upload cursor can still
  reach the bucket;
- clearing `_mesh_types` while any bucket that derived RIDs from it remains
  discoverable.

Implementation implication:

- `remove_cell_instances(cell_grid)` should first detach the cell's bucket list
  from `_cell_buckets`, then clean up the detached local list.
- Budgeted hide should not own cleanup. It should only hide and then remove
  its cursor. Cleanup runs only after the cell is no longer in the hide set.
- `clear()` should detach all registries first, then free detached objects.

## Single-Flight Resource Publication

For each mesh, material, and shape key:

- one owner performs the load or publish;
- other callers wait for, reuse, or skip that same in-flight result;
- no caller publishes a duplicate owner for the same key in the same lifetime
  window.

This is an architectural rule, not an optimization detail.

Already aligned:

- `StreamedResourceHandle` gives loaded model resources a shared owner.
- P0.4 `StaticShapeCache` single-flight prevents duplicate sidecar shape loads.

Phase 2B must add:

- single-flight static prototype publication per `type_name`;
- single-flight bucket creation per `(cell_grid, payload_key)`;
- no second bucket for the same `(cell_grid, payload_key)` while one is publishing,
  visible, hiding, or waiting for cleanup.
- `_mesh_types` publication is immutable: once an entry is published, none of
  its fields are rewritten. Later changes replace or remove the whole entry
  under `_mesh_types_mutex`. This preserves the current lockless read pattern
  during bucket creation.

## Reclaim-After-Unload-Limbo

Godotwind keeps a cell in unload limbo so fast backtracking can reclaim the
same partially loaded cell instead of throwing away work and rebuilding it.

This is a Godotwind feature, not an OpenMW feature. OpenMW unloads cells more
atomically and uses OSG reference counting instead of Godot RIDs. So Phase 2B
must justify reclaim locally:

- Morrowind-sized cells are small enough that a player can cross a boundary and
  return almost immediately.
- Throwing away pending queues during that return path caused missing objects
  in earlier work.
- P0.4's boomerang route proved the local reclaim sequence: park request,
  pause publish, reclaim cell, resume publish, re-arm collision, and finalize
  only after the cell truly dies.

Bucket rule under reclaim:

- If a cell is reclaimed before bucket cleanup starts, the bucket remains live,
  exits hide state, and continues using the same owner-token.
- If cleanup has already detached the bucket from all registries, reclaim must
  not reuse that bucket. It must create a new bucket through the normal
  single-flight path.
- The observable signal is `bucket.frozen`. Reclaim checks `bucket.frozen` or
  the equivalent detached-cleanup state; if true, it treats the old bucket as
  gone.
- There is no middle state where a bucket is both detached for cleanup and
  reachable for publish/hide.

## Implementation Plan After Review

Phase 2B.1 - bucket owner-token:

- Add a bucket-owned resource token to `CellStaticBucket`.
- When `StaticObjectRenderer.create_cell_bucket()` creates a bucket, pass the
  resource handle or copied strong resource refs into the bucket before any RID
  is created.
- Bucket cleanup drops this token only after RIDs are freed.

Phase 2B.2 - iteration-stop cleanup:

- Change renderer cleanup paths to detach bucket/direct-instance lists before
  freeing RIDs.
- Make `clear()` follow the same detach-then-free order as cell unload.
- Remove stale bucket hide cursor state before freeing buckets.

Phase 2B.3 - MultiMesh bucket:

- Replace per-transform/per-submesh RS instance creation in `CellStaticBucket`
  with cell-local MultiMesh resources/RIDs.
- Keep server creation and RID assignment on the main thread.
- Use prebuilt buffers only as data, not as owners.

Phase 2B.4 - `_mesh_types` tail cleanup:

- Make `_mesh_types` a prototype lookup table, not a live bucket owner.
- Remove comments and code paths that rely on `_mesh_types` immortality for
  `CellStaticBucket`.
- Delete the legacy direct RS static bucket path by 2026-05-10, after the
  MultiMesh bucket path passes the Phase 2B gates. Until deletion, it may only
  run under the old immortal-`_mesh_types` invariant in tests that explicitly
  name that legacy mode.

## Verification Plan

The verification must prove the old failure first, then prove the new design no
longer has it.

Pre-change reproduction:

- Re-run a controlled version of the prior failing Phase 2B path or a targeted
  material/RID iteration-order stress that intentionally frees buckets while
  hide/cull/upload queues can still see them.
- The run must reproduce the `material_set_shader` null-material loop.
- Diagnostic stale-bucket logging is useful evidence, but it is not a substitute
  for reproducing the old log signature.
- Without seeing the old failure first, a passing run is not enough evidence.

Post-change automated gates:

- `git diff --check`.
- No `dotnet build` unless C# changes.
- Dense route with collision enabled.
- East route with collision enabled.
- Reclaim boomerang route with collision enabled and lifecycle capture enabled
  only for that route.
- Targeted material/RID iteration-order stress.

Log gates before summary:

- no `SCRIPT ERROR`;
- no parse error;
- no `ERROR:`;
- no `material_set_shader`;
- no stale bucket discovered after detach;
- no collision finalize errors.

Known parked result:

- A post-`BENCH_QUIT` or post-`READY_QUIT` native signal 11 remains parked only
  if the benchmark summary or ready marker has already written, `LOG_EXIT done`
  appears, and there is no new GDScript backtrace or pre-summary renderer
  error.

Manual gate:

- Launch `scenes/Godotwind.tscn` interactively with the documented Godot 4.6
  binary.
- The user should traverse dense exterior cells and quit visibly.
- This is required before calling any gameplay/streaming/rendering change done.

## Acceptance Criteria

Phase 2B is accepted when:

- each live `CellStaticBucket` owns or pins the resources behind its render IDs;
- bucket cleanup first stops all iteration, then frees RIDs, then drops
  resources;
- `_mesh_types` is no longer the hidden lifetime owner for live cell buckets;
- per-cell/per-area MultiMesh buckets replace the transitional per-submesh RS
  instance bucket path;
- dense, east, reclaim-boomerang, and targeted material/RID stress all pass
  with collision enabled;
- the targeted stress shows the prior failure mode before the fix and does not
  show it after the fix;
- no distant rendering work is resumed before this lands.
