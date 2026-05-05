# HLOD OpenMW And Industry Comparison

Date: 2026-05-02
Owner: hlod
Scope: HLOD architecture, MID handoff, OpenMW ObjectPaging comparison

## Executive Verdict

Godotwind's current direction is broadly aligned with the canonical HLOD
pattern:

- near and mid distance keep culling local with individual objects or local
  instancing;
- far static content is replaced by chunk-level proxy geometry;
- visibility handoff is engine-owned through Godot visibility ranges;
- mesh LOD is delegated to Godot's native meshoptimizer-backed LOD path;
- merge work is scheduled asynchronously and published on the main thread.

The largest remaining gap is not the shape of the system. It is the quality of
the HLOD proxy output. A chunk published as one `RenderingServer` instance can
still be many draw surfaces if the combined `ArrayMesh` keeps many material
surfaces. Unreal and OpenMW both make the same underlying point: HLOD is only a
win when the proxy reduces draw/state changes, not just object count.

## Sources Rechecked

- Godot visibility ranges / HLOD:
  https://docs.godotengine.org/en/4.6/tutorials/3d/visibility_ranges.html
- Godot mesh LOD:
  https://docs.godotengine.org/en/4.6/tutorials/3d/mesh_lod.html
- Godot MultiMesh:
  https://docs.godotengine.org/en/4.6/classes/class_multimesh.html
- Unreal World Partition HLOD:
  https://dev.epicgames.com/documentation/en-us/unreal-engine/world-partition---hierarchical-level-of-detail-in-unreal-engine
- Unreal HLOD overview:
  https://dev.epicgames.com/documentation/en-us/unreal-engine/hierarchical-level-of-detail-overview-in-unreal-engine
- Unity GPU instancing:
  https://docs.unity3d.com/6000.0/Documentation/Manual/GPUInstancing.html
- Unity BatchRendererGroup:
  https://docs.unity.cn/Manual/batch-renderer-group.html
- OpenMW ObjectPaging:
  https://gitlab.com/OpenMW/openmw/-/blob/master/apps/openmw/mwrender/objectpaging.cpp
- OpenMW terrain quadtree:
  https://gitlab.com/OpenMW/openmw/-/blob/master/components/terrain/quadtreeworld.cpp
- OpenMW terrain settings:
  https://gitlab.com/OpenMW/openmw/-/blob/master/docs/source/reference/modding/settings/terrain.rst

## Canonical Pattern

Godot's HLOD docs describe visibility ranges as the native manual LOD/HLOD
handoff. They explicitly call out the key HLOD benefit: a larger mesh can
replace several smaller meshes at distance, reducing draw calls while preserving
near-camera culling.

Godot's mesh LOD docs point to automatic mesh decimation using meshoptimizer.
That is the correct primitive for per-mesh triangle reduction inside a proxy,
but it does not solve material/surface count by itself.

Godot's MultiMesh and Unity's GPU instancing guidance agree on the same
constraint: instancing is for many copies of the same mesh/material. It is a
MID-tier tool for repeated objects, not a general replacement for merged HLOD
proxies. Godot also treats a MultiMesh as one object for culling and lighting,
so broad world-scale MultiMeshes trade draw overhead for culling precision.

Unreal World Partition HLOD splits the solution into layer types:

- Instancing, for repeated static meshes using the source mesh LODs;
- Merged Mesh, for a single merged proxy mesh;
- Simplified Mesh, for a merged proxy with simplification.

Its older HLOD overview states the same target more directly: combine static
mesh actors into a proxy mesh and material, often with atlased textures, so the
result trends toward one draw per proxy rather than one draw per source object.
That is the bar Godotwind should use for accepting HLOD as default-on.

## OpenMW ObjectPaging Findings

OpenMW ObjectPaging is useful as a content heuristic reference, not as a direct
engine architecture to copy. It is built on OpenSceneGraph, not Godot's
`ArrayMesh` / `RenderingServer` model.

Important OpenMW behaviors:

- ObjectPaging plugs into `QuadTreeWorld` as a chunk manager. The terrain
  quadtree decides chunk size and center; ObjectPaging builds/caches content for
  that chunk.
- The terrain quadtree avoids chunks crossing the active-grid boundary and
  stops subdivision based on distance, view range, and native LOD suitability.
- Record type filtering is distance-aware. Large/far chunks keep durable static
  categories and reject some interactive categories.
- The projected-size rejection is the familiar form:
  `radius^2 * scale^2 < distance^2 * min_size^2`.
- Merge eligibility is cost/benefit based, not unconditional. OpenMW compares
  approximate vertex cost against a merge benefit derived from shared render
  state usage.
- Merged objects are fed through an OSG optimizer using static transform
  flattening, redundant-node removal, and geometry merge passes.
- OpenMW has a second-pass min-size relaxation for objects that are cheap and
  high-benefit when merged.

The non-portable part is the final optimizer. OpenMW's win comes from
`StateSet` reuse analysis plus OSG geometry merging. Godotwind must make the
equivalent decision in terms of `ArrayMesh` surfaces, materials, textures,
vertices, indices, and shadow participation.

## Current Godotwind Architecture

Local references after today's HLOD pass:

- MID buckets: `src/core/world/static_object_renderer.gd:963`,
  `src/core/world/cell_static_bucket.gd:82`
- HLOD queue and completion budgets:
  `src/core/world/object_paging.gd:60`,
  `src/core/world/object_paging.gd:65`,
  `src/core/world/object_paging.gd:324`,
  `src/core/world/object_paging.gd:364`
- HLOD chunk request and worker merge:
  `src/core/world/object_paging.gd:738`,
  `src/core/world/object_paging.gd:889`
- HLOD stale-completion guard:
  `src/core/world/object_paging.gd:405`,
  `src/core/world/object_paging.gd:997`
- MID range retune on HLOD toggle:
  `src/core/world/native_streaming_manager.gd:2086`,
  `src/core/world/static_object_renderer.gd:1012`,
  `src/core/world/cell_static_bucket.gd:82`
- HLOD surface/material stats:
  `src/core/world/object_paging.gd:189`,
  `src/core/world/object_paging.gd:1064`

Current architecture by tier:

| Tier | Current shape | Verdict |
| --- | --- | --- |
| NEAR | Scene tree objects plus physics | Correct separation of gameplay and render tiers |
| MID | Cell-owned `CellStaticBucket`s with direct RS draws or local MultiMeshes | Correct for local repeated instances and resource lifetime |
| HLOD | `ObjectPaging` adaptive chunks, worker merge, main-thread LOD and RS publish | Correct shape, proxy content still not accepted |
| FAR | Impostor renderer owned by `#impostors` lane | Outside this pass |

## Match Against OpenMW

| OpenMW idea | Godotwind status | Notes |
| --- | --- | --- |
| Terrain/quadtree driven chunk selection | Partially matched | Godotwind uses explicit distance bands and chunk sizes rather than a general quadtree. This is acceptable because Morrowind cells are regular and tier ranges are fixed. |
| Type filtering | Matched | Godotwind filters HLOD candidates before merge. Keep game-specific categorization in adapter/data layers. |
| Projected-size filtering | Matched | Same mathematical form. Constants must be tuned in Godot meters, not copied from OpenMW. |
| Merge cost/benefit | Partially matched | The policy exists, but acceptance must be based on resulting Godot surface/material and vertex/index counts. |
| State/material batching | Not yet accepted | OpenMW's `StateSet` optimizer does not map directly. Godotwind needs material/surface reduction in the chunk proxy path. |
| Active-grid object paging | Not a fit | Godotwind NEAR uses Node3D and physics. MID/HLOD/FAR are render tiers, not active-cell gameplay paging. |
| Ref-counted renderer lifetime | Not portable | Godotwind must explicitly own/free `RID`s and pin resources. |

## Findings

### Closed Since The First Audit

The previous audit listed stale completed HLOD workers as a P0. Today's code now
uses chunk generation tokens and rejects non-current completions before
`generate_lods()` and RS publication. This closes the visible stale-publish bug,
though it does not make worker lifetime fully drained.

The previous audit also listed live MID bucket retune as a P1. Today's code now
retunes existing `CellStaticBucket` draw groups through
`StaticObjectRenderer.set_visibility_range_end()` when HLOD is toggled. The
remaining edge is legacy direct `_instances` created through debug/compatibility
paths.

### Still Open

1. HLOD proxy draw reduction is not proven.

   `total_chunk_surfaces` and `total_chunk_materials` are now tracked, which is
   the right first instrument. The next acceptance gate needs per-chunk vertex
   count, index count, material histogram, visible draw attribution, and shadow
   draw attribution. Without that, a single dense chunk can look architecturally
   correct while still expanding into too many render passes.

2. `generate_lods()` is still an indivisible main-thread step.

   The queue and completion loops are time-budgeted, but once a dense chunk
   reaches LOD generation the frame owns that cost. If runtime HLOD remains the
   target, chunk complexity caps or a resumable/offline proxy cache are the
   canonical solutions.

3. Cancellation is generation-safe but not lifetime-drained.

   A background worker can still finish after cleanup and append a result that
   later gets rejected. That is acceptable for correctness if the completion
   payload owns only safe data, but it is not the same as a fully joined task
   lifecycle. Stress tests should keep watching shutdown/toggle paths.

4. Material/surface reduction needs a real plan.

   OpenMW's optimizer effectively merges by shared render state. Unreal's
   HLOD path commonly bakes a proxy material/atlas for merged or simplified
   proxies. Godotwind needs an equivalent:

   - conservative first pass: group by material family and cap surfaces per
     chunk;
   - stronger pass: bake a simplified far proxy material/atlas for static HLOD;
   - reject or split chunks whose resulting surface/material count exceeds the
     accepted budget.

5. Documentation was partially stale before consolidation.

   Superseded note, 2026-05-02: `docs/systems/distance_rendering.md` and
   `docs/systems/object_paging.md` now own the current tier contract and HLOD
   deep dive. This audit remains useful as historical evidence, not as the
   current instruction source.

## Recommended Next Pass

1. Add HLOD acceptance instrumentation:
   per chunk `surface_count`, distinct material count, vertex count, index
   count, source-ref count, largest material bucket, and shadow-enabled surface
   count.

2. Add benchmark summary gates:
   active chunks by level, total active HLOD surfaces/materials/vertices,
   max chunk surfaces/materials, HLOD publish milliseconds, stale completions,
   and visible/shadow draw deltas with HLOD on.

3. Use the measurements to choose one proxy-reduction path:
   material-family grouping plus hard chunk splits if enough, or proxy material
   baking/atlas if surfaces remain high.

4. Keep MID as cell-owned local buckets. Do not replace MID with a world-scale
   MultiMesh, and do not use FAR impostor batching as the HLOD fix.

5. Re-run dense/east/reclaim stress with HLOD and FAR on. HLOD should remain
   opt-in until the benchmark shows bounded frame time, bounded proxy
   surfaces/materials, no stale publishes, and no MID/HLOD/FAR handoff holes.

## Verification Note

This pass changed documentation only. No C# changed, and I did not launch Godot
because `#impostors` had an active FAR stress probe and asked for engine launches
to be held. Runtime verification is required before any follow-up code change is
called done.
