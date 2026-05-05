# HLOD / MID Streaming And Rendering Research

Date: 2026-05-02
Owner: hlod
Scope: MID, HLOD, FAR, and the streaming scheduler around them

This document is a focused research and audit pass for Godotwind's distant
rendering stack after the NEAR refactor. It does not replace
`docs/systems/streaming_rendering_bible.md`; it is the working evidence and
decision map for the next HLOD pass.

## Executive Verdict

The canonical architecture is:

1. NEAR stays sparse scene-tree `Node3D` content with physics and gameplay.
2. MID uses spatially local, cell-owned render buckets with Godot automatic
   mesh LOD and native visibility ranges.
3. HLOD uses chunk proxy meshes for unloaded / distant static geometry, with
   aggressive material and surface reduction.
4. FAR uses impostors, but should move toward spatially local impostor buckets
   if the current world-scale MultiMesh remains a culling or rebuild bottleneck.
5. Streaming work is budgeted by elapsed time and by ownership generation, not
   only by item count.

Godotwind is mostly pointed in the right direction. The weak points are not
"Godot cannot do this"; they are:

- HLOD chunk proxies still produce too many surfaces/materials, so draw calls
  stay high even though object count is lower.
- HLOD merge submission and completion are count-budgeted, not time-budgeted.
- HLOD cancellation has a stale-completion risk: a running worker can append a
  completed mesh after its chunk was cancelled or left range.
- Runtime `hlod_enable` changes future MID bucket ranges but does not retune
  existing MID bucket RIDs.
- FAR impostors use one world-scale MultiMesh, which defeats per-region engine
  culling and pushes range control into shader/discard and rebuild logic.

## Canonical Patterns

### Godot 4.6

Godot's native distant-rendering toolbox is clear:

- `RenderingServer` is the correct low-level path when the scene tree overhead
  is too high. Godot documents the scene system as optional and server APIs as
  the low-level foundation underneath nodes.
- `GeometryInstance3D.visibility_range_*` is Godot's manual LOD / HLOD switch.
  It works on `MeshInstance3D`, `MultiMeshInstance3D`, particles, labels, and
  other geometry instances. It can be combined with automatic mesh LOD.
- `ImporterMesh.generate_lods()` and `Viewport.mesh_lod_threshold` are the
  native automatic mesh LOD path. Higher viewport thresholds choose lower-detail
  mesh LODs earlier; this is independent from visibility ranges.
- `MultiMesh` is the correct instancing tool for many copies of one mesh, but
  Godot culls it as one spatial object. Godot's class docs explicitly warn that
  far-apart instances may all render when the MultiMesh is visible.
- `WorkerThreadPool` tasks must eventually be awaited. Server and scene-tree
  publication should remain main-thread work in this project until the project
  opts into and verifies the relevant thread settings.

Primary sources:

- Godot 4.6 server APIs: https://docs.godotengine.org/en/4.6/tutorials/performance/using_servers.html
- Godot 4.6 thread-safe APIs: https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html
- Godot 4.6 visibility ranges: https://docs.godotengine.org/en/4.6/tutorials/3d/visibility_ranges.html
- Godot 4.6 mesh LOD: https://docs.godotengine.org/en/4.6/tutorials/3d/mesh_lod.html
- Godot 4.6 `ImporterMesh.generate_lods`: https://docs.godotengine.org/en/4.6/classes/class_importermesh.html
- Godot 4.6 `Viewport.mesh_lod_threshold`: https://docs.godotengine.org/en/4.6/classes/class_viewport.html
- Godot 4.6 `MultiMesh`: https://docs.godotengine.org/en/4.6/classes/class_multimesh.html
- Godot 4.6 `WorkerThreadPool`: https://docs.godotengine.org/en/4.6/classes/class_workerthreadpool.html

### Other Engines

Unreal World Partition HLOD is the closest canonical reference. Its HLOD
system exists to display distant non-interactive world content from unloaded
grid cells, and it reduces draw calls through HLOD layers such as instancing,
merged mesh, and simplified mesh. That maps directly to Godotwind's needs:
MID buckets for repeated local instances, HLOD merged proxies for far static
chunks, and impostors for the final band.

Unity gives the same split from another angle: LOD reduces triangle work for
distant meshes, GPU instancing reduces draw-call overhead for repeated
mesh/material pairs, and BatchRendererGroup is the custom high-performance
renderer shape for many environment objects with explicit culling.

Primary sources:

- Unreal World Partition HLOD: https://dev.epicgames.com/documentation/en-us/unreal-engine/world-partition---hierarchical-level-of-detail-in-unreal-engine
- Unity mesh LOD: https://docs.unity3d.com/6000.0/Documentation/Manual/LevelOfDetail.html
- Unity GPU instancing: https://docs.unity3d.com/6000.0/Documentation/Manual/GPUInstancing.html
- Unity BatchRendererGroup: https://docs.unity.cn/Manual/batch-renderer-group.html

## Current Godotwind Shape

| Tier | Current Runtime Shape | Status |
| --- | --- | --- |
| NEAR | Scene-tree cells, gameplay nodes, physics/collision | Recently refactored; performant by itself |
| MID | `CellStaticBucket`: cell-owned direct RS instances or local MultiMeshes, using embedded mesh LOD | Correct direction |
| HLOD | `ObjectPaging`: runtime chunk merge, worker mesh concat, main-thread LOD and RS publish | Implemented, opt-in; not performant enough |
| FAR | `NativeImpostorRenderer`: one master impostor MultiMesh plus texture arrays | Default-on; steady-state acceptable, startup spikes remain |

Important current files:

- `src/core/world/distance_utils.gd`: tier distances, paging bands, size/cost constants.
- `src/core/world/native_streaming_manager.gd`: per-frame scheduler and tier toggles.
- `src/core/world/cell_manager.gd`: cell payload classification, static prepare, NEAR publication.
- `src/core/world/static_object_renderer.gd`: prototype descriptors, MID buckets, cell cleanup.
- `src/core/world/cell_static_bucket.gd`: MID RS / MultiMesh draw groups and resource pins.
- `src/core/world/object_paging.gd`: HLOD desired chunks, worker queue, completion queue, RS publish.
- `src/core/world/object_paging_kernel.gd`: HLOD merge kernel wrapper and `ImporterMesh` LOD generation.
- `src/native/NativeObjectPagingKernel.cs`: hot HLOD surface concatenation and material grouping.
- `src/core/world/native_impostor_renderer.gd`: FAR impostor loading, texture arrays, MultiMesh rebuilds.

## What Is Already Right

MID uses the right Godot primitive now. The old per-LOD RID fan-out is gone
from the accepted path; mesh detail is delegated to the engine's embedded LOD
selector. `CellStaticBucket` keeps MultiMeshes cell-local and pins the mesh /
material resources that back its RIDs.

HLOD uses the right high-level strategy: a chunk proxy mesh for a distance band,
not world-scoped instancing and not per-object GDScript distance polling. The
worker/main split is also directionally right: pure geometry concatenation goes
off-thread, while `ImporterMesh.generate_lods()` and `RenderingServer` publish
stay on the main thread.

The streaming manager now treats many toggles as dual-purpose gates: hide the
output and stop producer work. That is the right pattern for benchmarking
because "dark but still streaming" does not measure the subsystem being off.

The docs already correctly state that HLOD is opt-in after the 2026-05-02
default-on run failed with persistent draw-call and frame-time problems. See
`docs/audit/distant_rendering_reenable_2026_05_02_codex.md`.

## Architecture Findings

### P0: HLOD Can Publish Stale Completed Chunks

`ObjectPaging.update_for_camera()` cancels pending merge tasks and erases
`_pending_merges` when a chunk leaves the desired set. However,
`_merge_chunk_worker()` always appends its output to `_completed_queue`, and
`process_completions()` only rejects chunks already in `_active_chunks`.

If `BackgroundProcessor.cancel_task()` is cooperative, or the worker is already
running, a chunk can publish after it was cancelled or after the camera left
range. `cleanup()` has a similar shape: it clears state and the completion
queue, but does not visibly wait for running work before a worker can append
again.

Canonical fix:

- Give each merge request a generation token.
- Store active desired generations in a main-thread dictionary.
- Worker results include `key` and `generation`.
- `process_completions()` publishes only if the generation is still current.
- `cleanup()` invalidates all generations and waits/drains through the
  background processor's documented completion path.

This is correctness work before performance work. A draw-call optimization that
still allows stale chunks is not shippable.

### P0: HLOD Surface / Material Reduction Is The Main Performance Failure

The 2026-05-02 default-on run failed with high draw calls and frame spikes, not
with a crash. That points at the HLOD proxy content: one chunk instance is not
enough if the chunk mesh still carries many material surfaces. In Godot, each
surface/material still matters for draw submission.

Canonical fix:

- Add chunk stats first: active chunks by tier, surfaces per chunk, materials
  per chunk, vertices/indices per chunk, and visible/shadow draw calls.
- Then reduce material/surface count in the proxy itself:
  - material identity deduplication;
  - texture atlas or material bake for chunk proxies;
  - optional simplified proxy material for far HLOD;
  - shadow policy per tier.

Do not resurrect world-scoped per-prototype MultiMesh as the HLOD fix. Godot's
own MultiMesh constraints say spatially broad MultiMeshes are culling-hostile,
and Godotwind already disabled that path for MID.

### P1: HLOD Work Is Count-Budgeted, Not Time-Budgeted

`MERGES_PER_FRAME = 2` limits how many chunk submissions happen per call, but
`_request_chunk_merge()` performs main-thread ESM scans, base-record lookups,
AABB queries, slow-path prototype loads, and registration before it submits
the worker. Two cheap chunks and two cold dense chunks are not equivalent.

`COMPLETIONS_PER_FRAME = 1` has the same issue. One completion can run
`ImporterMesh.generate_lods()`, cache eviction, and RS creation for a pathological
chunk.

Canonical fix:

- Convert merge submission to an elapsed-time budget with resumable per-chunk
  collection state.
- Convert completion to elapsed-time budget where possible; if
  `generate_lods()` stays indivisible, record its cost and cap accepted chunk
  complexity before completion.
- Emit per-phase HLOD timings into the same benchmark summaries as NEAR.

### P1: Runtime HLOD Toggle Leaves Existing MID Ranges Stale

`NativeStreamingManager.set_hlod_visible()` changes
`StaticObjectRenderer.visibility_range_end` to `300m` or `500m`, which affects
future MID buckets. Existing `CellStaticBucket` RIDs were created with their
own `instance_geometry_set_visibility_range()` calls and do not automatically
inherit the new value.

Observed risk:

- Enabling HLOD can leave already-loaded MID buckets visible to 500m while
  HLOD chunks also render from 300m.
- Disabling HLOD can leave already-loaded MID buckets capped at 300m while FAR
  begins at 500m, creating a 300-500m hole until cells recycle.

Canonical fix:

- Add a bucket-level `set_visibility_range_end()` that iterates draw groups and
  calls `RenderingServer.instance_geometry_set_visibility_range()` for live
  RIDs.
- Have `StaticObjectRenderer` retune all live buckets when the global MID cap
  changes.
- Add a transition test for toggling `hlod_enable` / `hlod_disable` without
  moving the camera.

### P1: FAR World-Scale MultiMesh Is A Culling Compromise

The FAR renderer uses one master `MultiMeshInstance3D`. It is excellent for draw
count, but it is one spatial object for culling. Native visibility ranges apply
to the whole instance, not per impostor. The renderer compensates with
deferred cell queues, shader-side rules, and bulk MultiMesh rebuilds.

This can remain acceptable if benchmarked steady-state and startup costs are
bounded. If it remains a bottleneck, the Godot-native evolution is spatially
local impostor MultiMeshes, grouped by world area and texture-set/material
constraints.

### P2: Some Docs Were Stale Before Consolidation

Superseded note, 2026-05-02: the live system docs have since been consolidated
around `docs/systems/distance_rendering.md` and `docs/systems/object_paging.md`.
Those files now own the current MID/HLOD/FAR tier contract.

- `docs/systems/benchmarking.md` was updated to point at the current
  `CellStaticBucket` and ObjectPaging visibility patterns.
- `docs/systems/distance_rendering.md` was reduced to the current tier
  contract and no longer describes a retired HLOD cache pipeline as current.
- `docs/reference/server_direct_pattern.md` still names parked
  `PrototypeRegistry` paths and older collision/threading claims.
- `docs/plans/near_streaming_phase_2b_design_2026_05_01.md` is now historical
  ordering context; FAR has already been re-enabled by default.

Future agents should start from the system docs above and treat this audit as
historical evidence.

## Target Runtime Contract

Default path today:

| Mode | MID | HLOD | FAR |
| --- | --- | --- | --- |
| Default | 0-500m | Off | 500-5000m |
| `hlod_enable` | 0-500m fallback; fully HLOD-covered buckets cap at 300m | visible 300-1000m | 500-5000m fallback |
| `hlod_disable` | 0-500m | Off | 500-5000m |
| `--near-only` | MID fallback may remain for static visibility only if intended by the test | Off | Off |
| `--no-impostors` | 0-500m safety fallback | Optional | Off |

The accepted HLOD path should guarantee:

- no overlap where existing MID buckets still render beyond the active MID cap;
- no hole between MID, HLOD, and FAR after toggles;
- no stale chunk publish after cancellation or cleanup;
- no `RenderingServer` publication from workers under the current project
  thread settings;
- every worker task is eventually waited/drained;
- every live RID has a strong `Mesh` / `Material` owner until after the RID is
  freed.

## Required Instrumentation

Add these before changing the HLOD merge algorithm:

- Per HLOD chunk: `surface_count`, distinct material count, vertex count,
  index count, estimated bytes, size level, generation.
- Per frame / benchmark sample: active HLOD chunks by size level, HLOD surfaces
  total, HLOD visible draw calls, HLOD shadow draw calls, merge-queue depth,
  completion-queue depth, cancelled-generation discard count.
- Per phase timing: desired-chunk walk, chunk input collection, prototype
  warmup, worker merge, LOD generation, RS publish, cache eviction.

The acceptance gate should stop using draw-call total alone. It needs to tie
draw calls back to the surfaces and materials in HLOD chunks.

## Recommended Work Order

1. Fix HLOD generation-token cancellation and cleanup drain.
2. Retune live MID bucket visibility ranges when HLOD toggles.
3. Add HLOD surface/material/timing instrumentation to benchmark summaries.
4. Run `hlod_enable` stress and confirm the measured failure is chunk surface
   count, material count, publish cost, or a different source.
5. Implement HLOD material/surface reduction in the chunk proxy path.
6. Re-run dense/east/reclaim stress with HLOD on and FAR on.
7. Only then consider making HLOD default-on.
8. Clean stale docs once the new HLOD contract is accepted.

## Acceptance Gates

HLOD is not accepted until all are true in an automated benchmark or interactive
session that exercises HLOD:

- no changed-path frame over 50ms;
- no stale chunk publish after cancellation, teleport, `hlod_disable`, or
  cleanup;
- no worker task leak or un-awaited task;
- bounded HLOD chunk surface count and material count;
- bounded visible and shadow draw calls with HLOD enabled;
- stable visual transitions at 300m and 1000m;
- no MID/HLOD/FAR holes or duplicate overlap after toggling HLOD at runtime;
- FAR startup no longer causes the default path to fail the full-run gate.

Because this document changes docs only, it does not require launching
`scenes/Godotwind.tscn`. Any code change that touches the runtime paths above
must follow the project verification rule: build C# if touched, then launch the
main scene interactively or run an automated benchmark/crash smoke that
exercises the changed path.
