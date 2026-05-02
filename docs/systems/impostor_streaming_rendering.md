# Impostor Streaming And Rendering

Date: 2026-05-02
Owner: impostors
Scope: FAR-tier impostor loading, streaming, rendering, and its handoff with MID/HLOD

This document is the focused FAR-tier companion to
`docs/systems/streaming_rendering_bible.md`. The general bible remains the
project-wide source of truth for NEAR/MID/HLOD/FAR lifetime ownership and
streaming policy. This file answers the narrower question: how should
Godotwind load, stream, and render impostors in Godot 4.6 without fighting the
engine?

## Verdict

Godot 4.6 does not provide a complete open-world impostor system. It provides
the correct low-level pieces:

- `MultiMesh` / `MultiMeshInstance3D` for high-count instanced drawing.
- `GeometryInstance3D.visibility_range_*` for tier visibility and HLOD handoff.
- `RenderingServer` for server-direct high-volume render publication.
- `ResourceLoader.load_threaded_request` and `WorkerThreadPool` for native
  background work.
- shader billboarding primitives and custom shaders for camera-facing quads.

Therefore the canonical Godotwind shape is hybrid:

- Use Godot-native rendering, LOD, visibility, server, and thread primitives.
- Keep custom code only for the missing open-world layer: candidate selection,
  offline octahedral baking, texture-array packing, per-cell streaming policy,
  and the shader-side octahedral frame selection.

The current FAR path is directionally right in three ways: it uses
spatially paged `MultiMeshInstance3D` batches with a custom shader, it uses
Godot visibility ranges for the render-to-impostor handoff, and it uploads
per-page transforms through `MultiMesh.set_buffer()`. The two main remaining
architectural risks are:

1. FAR impostor work runs in its own node budget, so texture-array uploads and
   full MultiMesh rebuilds can bypass the central streaming frame budget.
2. Texture-array commits are still whole-array GPU uploads, so startup and
   layer-table churn need explicit budget windows.

## Primary-Source Facts

Use these tags when extending this document:

- `D`: directly documented by Godot/source.
- `I`: inference from documented behavior plus project evidence.
- `P`: Godotwind policy or accepted local design.

### Godot Has HLOD And Billboard Primitives, Not A Full Impostor Pipeline

`D`: Godot's visibility range docs describe visibility ranges as a performance
tool for large 3D scenes, usable on `GeometryInstance3D` subclasses including
`MultiMeshInstance3D`. They explicitly describe replacing close meshes with
distant sprite impostors and replacing multiple small meshes with one larger
HLOD mesh or `MultiMeshInstance3D`.

Source: https://docs.godotengine.org/en/4.6/tutorials/3d/visibility_ranges.html

`D`: Godot has native billboard-facing pieces (`BaseMaterial3D.billboard_mode`,
`SpriteBase3D.billboard`, `VisualShaderNodeBillboard`, `PointMesh`) but these
are orientation/display primitives, not an atlas baker, octahedral sampler, or
world-cell streaming system.

Sources:
https://docs.godotengine.org/en/4.6/classes/class_basematerial3d.html
https://docs.godotengine.org/en/4.6/classes/class_spritebase3d.html
https://docs.godotengine.org/en/4.6/classes/class_visualshadernodebillboard.html
https://docs.godotengine.org/en/4.6/classes/class_pointmesh.html

`P`: `NativeImpostorRenderer` remains a legitimate custom system because Godot
does not provide octahedral impostor baking, texture array packing, per-object
atlas metadata, or per-cell impostor streaming policy.

### MultiMesh Is Fast But Spatially One Object

`D`: Godot's `MultiMesh` docs say it draws thousands of mesh instances with one
draw call, but if instances are far apart every instance may render because the
whole MultiMesh is spatially indexed as one object. The user must provide the
AABB used for visibility.

Source: https://docs.godotengine.org/en/4.6/classes/class_multimesh.html

`D`: Godot's MultiMesh optimization docs recommend several MultiMeshes for
different world areas when instances are spread out.

Source: https://docs.godotengine.org/en/4.6/tutorials/performance/using_multimesh.html

`I`: One global FAR `MultiMeshInstance3D` is acceptable as a first proof of a
single draw path, but it is not the production culling shape for a 5 km open
world. A chunked FAR batch grid is the Godot-native direction.

`P`: FAR impostors should be partitioned into spatially local batches. The
batch size can be coarser than MID cells because impostors are distant and
cheap, but it must remain small enough that the MultiMesh AABB, visibility
range distance, light limit, and frustum tests represent the instances inside.

### Visibility Range Is Per GeometryInstance, Not Per MultiMesh Slot

`D`: `visibility_range_begin/end` and their margins are properties of
`GeometryInstance3D`. Margins are either hysteresis or fade transition distances
depending on fade mode.

Sources:
https://docs.godotengine.org/en/4.6/classes/class_geometryinstance3d.html
https://docs.godotengine.org/en/4.6/tutorials/3d/visibility_ranges.html

`I`: A `MultiMeshInstance3D.visibility_range_begin = 480m` fades the entire
MultiMesh instance. It does not independently fade or cull each impostor slot.

`P`: Keep shader-side per-slot distance/transition logic if the design needs
per-impostor behavior inside one batch. Use engine visibility range only for
whole-batch tier admission and final far cull.

### Mesh LOD And HLOD Should Remain Engine-Driven

`D`: Godot supports mesh LOD generation and screen-space LOD selection. The
`ImporterMesh.generate_lods()` API generates LODs for an `ImporterMesh`, and
Godot's mesh LOD documentation describes automatic LOD usage and tuning.

Sources:
https://docs.godotengine.org/en/4.6/tutorials/3d/mesh_lod.html
https://docs.godotengine.org/en/4.6/classes/class_importermesh.html

`P`: FAR impostors should not reintroduce manual per-LOD visibility bands. MID
and HLOD geometry should continue to use embedded LOD chains plus
`visibility_range` for tier boundaries.

### Server RIDs Need Strong Resource Owners

`D`: Godot's server docs state that references to a resource's RID are not
counted when deciding whether the resource is still in use. Code that passes a
mesh, material, or texture RID to a server must keep a strong resource
reference outside the server.

Source: https://docs.godotengine.org/en/4.6/tutorials/performance/using_servers.html

`P`: FAR batch objects must own the `MultiMesh`, quad mesh, material, texture
arrays, and any active resources behind RIDs until the batch is fully hidden,
detached, and cleaned up.

### Threading: Use Engine Pools And Main-Thread Publication

`D`: Godot's thread-safe API docs state that the active scene tree is not
thread-safe. Rendering/physics server thread-safe operation requires project
settings, and GPU-touching calls can stall because they synchronize with
`RenderingServer`.

Source: https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html

`D`: `WorkerThreadPool` tasks must eventually be waited on with
`wait_for_task_completion()` or `wait_for_group_task_completion()`.

Source: https://docs.godotengine.org/en/4.6/classes/class_workerthreadpool.html

`D`: `ResourceLoader.load_threaded_request`, `load_threaded_get_status`, and
`load_threaded_get` are the native threaded loading API. `load_threaded_get`
blocks if called before completion, so status should be polled over frames.

Source: https://docs.godotengine.org/en/4.6/classes/class_resourceloader.html

`P`: FAR worker lanes prepare CPU-only data: cell ref lists, transforms,
metadata decisions, and image decode/format copies. Main thread owns texture
array creation, `MultiMesh.set_buffer()`, scene-tree attachment, and
RenderingServer publication unless a dedicated harness proves a narrower
threaded server path.

## Current Implementation

### Runtime Path

Current files:

- `src/core/world/native_impostor_renderer.gd`
- `src/core/world/impostor_candidates.gd`
- `src/core/world/native_streaming_manager.gd`
- `src/tools/prebaking/impostor_baker_v3.gd`
- `docs/plans/impostor_rebuild.md`

Current flow:

1. `NativeStreamingManager` creates `NativeImpostorRenderer` as
   `ImpostorManager` and passes it an `ImpostorCandidates` helper.
2. On camera cell changes, `NativeStreamingManager` defers the FAR area update
   to a later frame, then calls `update_impostor_area(_camera_cell,
   impostor_radius_cells)`.
3. `NativeImpostorRenderer.update_impostor_area()` computes desired cells.
   Normal movement uses differential border strips; first load, teleport, or
   large moves use a full ring recalculation.
4. `_process_pending_impostor_cells()` consumes queued cells under a time
   budget with intra-cell resume.
5. `_load_impostors_from_cell_record_budgeted()` scans ESM refs, maps ref IDs
   to model paths, filters through `ImpostorCandidates`, reads bake metadata,
   and creates pending or live impostors.
6. Texture and normal assets are loaded through `BackgroundJobSystem`, then
   copied into albedo/normal `Texture2DArray` inputs.
7. `_rebuild_texture_array()` moves CPU image conversion to a worker task, but
   `Texture2DArray.create_from_images()` still happens on the main thread.
8. `_rebuild_page()` repacks dirty page-local impostors into a
   `PackedFloat32Array`, sets page `instance_count`, and calls `set_buffer()`.
9. Spatial `ImpostorPage_*` `MultiMeshInstance3D` nodes render FAR impostors
   with custom data: albedo layer, yaw, normal layer, and bake variant.

### Current Strengths

- The octahedral shader is the right custom layer. Runtime should fail closed
  on stale data: complete v5 bakes render; legacy v4 data and incomplete v5
  bake sets are skipped.
- `Texture2DArray` plus custom data is the correct non-bindless fallback.
- `MultiMesh.set_buffer()` is the right upload API; per-slot setter loops would
  be worse.
- Spatial pages align the runtime shape with Godot's documented MultiMesh
  culling model instead of one world-scale batch.
- Differential cell updates avoid rescanning the whole FAR ring on normal
  one-cell movement.
- Texture-array and MultiMesh rebuilds are debounced and rate-limited.
- FAR can be toggled off as a full pipeline gate, not just hidden.

### Current Risks

#### Spatial Page Tuning

`NativeImpostorRenderer` now owns one `ImpostorPage` per aligned FAR page
instead of one world-scale master MultiMesh. This fixes the largest culling
shape mismatch, but the page size is still a measured tuning parameter.

Accepted direction: keep page-local buffers dirty-only, benchmark 4x4-cell
against 8x8-cell pages, and select the smallest page count that still gives
stable frustum and distance culling in dense/east/reclaim stress runs.

#### Separate Budget Ownership

`NativeStreamingManager` has per-phase overrun logs and a shared streaming
budget, but `NativeImpostorRenderer._process()` runs as a child node with its
own 4 ms / 15 ms budget. The main-thread parts of texture-array creation and
full MultiMesh upload are not centrally scheduled.

Accepted direction: route FAR publication work through the same frame-budget
arbiter as NEAR/MID/HLOD. FAR can keep internal queues, but the main-thread
publish operations need explicit slices:

- cell scan/metadata budget;
- completed texture result budget;
- texture-array upload budget;
- MultiMesh buffer upload budget;
- cleanup/compaction budget.

#### Full Rebuilds For Incremental Changes

`_rebuild_page()` repacks only dirty page-local impostors. The remaining risk is
keeping dirty-page queues bounded while texture layers are still committing.

Accepted direction: loading or unloading a border strip should rebuild only
touched pages, and pages waiting for uncommitted texture layers must not spin in
the current frame's rebuild loop.

#### Texture Array Rebuild Cost

The CPU copy/convert stage is off-thread, but `Texture2DArray.create_from_images`
is an unavoidable main-thread GPU upload. Rebuilding large albedo and normal
arrays during startup is visible in benchmarks as early-frame spikes.

Accepted direction:

- Keep the 256-layer cap until a measured reason changes it.
- Pre-sort/prime the highest-value nearby atlas layers first.
- Bound `create_from_images()` to startup screens or explicit budget windows.
- Avoid repeated whole-array rebuilds when a layer table can be staged into
  fewer larger commits.
- Treat a texture-array rebuild as a GPU upload, not as cheap bookkeeping.

#### Bespoke BackgroundJobSystem

`native_impostor_renderer.gd` uses `src/core/threading/background_job_system.gd`,
which starts raw `Thread` workers. The project rule and Godot-native path prefer
`WorkerThreadPool` and `ResourceLoader` where practical.

Accepted direction: new FAR work should not extend `BackgroundJobSystem`.
Migrate image/resource loading and CPU image copy tasks to either:

- `ResourceLoader.load_threaded_request()` for Godot resources; or
- `WorkerThreadPool.add_task()` for CPU-only decode/copy work that cannot use
  ResourceLoader cleanly.

Keep the old job system only as a time-boxed compatibility bridge until the FAR
worker lanes are migrated and benchmarked.

#### Candidate Policy Is Too Pattern-Centric

`ImpostorCandidates` uses model-name pattern sets, plus metadata when available.
This is useful for bootstrapping, but FAR eligibility should eventually be
driven by data:

- object bounds and projected size at the FAR start;
- silhouette importance or authored category;
- frequency/benefit in a spatial cell;
- bake availability and texture-layer cost;
- whether HLOD already covers the object acceptably.

Pattern lists can remain as adapter-layer hints for Morrowind data. The core
FAR architecture should not depend on Morrowind-specific names.

## Target Architecture

### Ownership Model

Use three layers:

1. `ImpostorWorldIndex`
   Immutable or mostly immutable world-space metadata: cell -> impostor refs,
   model hash, transform, bounds, bake metadata path, and priority. For
   Morrowind, this is built by an adapter from ESM refs and
   `ImpostorCandidates`.

2. `FARBatch`
   Runtime render owner for a spatial chunk. Owns one or more
   `MultiMeshInstance3D` objects, their `MultiMesh` resources, local buffers,
   strong texture/material references, dirty flags, and cleanup state.

3. `ImpostorAtlasRegistry`
   Owns texture-array layers, reference counts, pending layer uploads, and the
   model-hash -> layer mapping. It should be independent of cell streaming so a
   batch can die without invalidating the atlas used by neighboring batches.

### Spatial Batching

Recommended first production shape:

- batch key: aligned 4x4 or 8x8 exterior-cell chunk;
- one `MultiMeshInstance3D` per material/shader family if needed;
- one quad mesh and one shared shader material, with per-slot custom data;
- visibility range begin/end on the batch;
- custom AABB set from the chunk bounds plus billboard extents;
- dirty only batches touched by load/unload/texture-index changes.

Do not split per object. Do not keep one global batch. The target is spatially
local enough for engine culling but coarse enough that FAR draw calls stay low.

### Streaming Policy

Normal movement:

- Use differential border-strip updates for desired batch keys.
- Queue new batches nearest-first or screen-importance-first.
- Evict batches outside retention radius with hysteresis.
- Rebuild only dirty batch buffers.

Teleport/startup:

- Load the inner visual ring first.
- Gate expensive texture-array commits behind loading-screen or startup budget.
- Prefer visible approximate coverage over waiting for every FAR object.
- Defer low-priority distant clutter until steady state.

HLOD handoff:

- HLOD off: MID 0-500 m, FAR begins at `DU.MID_END`.
- HLOD on: MID remains the 0-500 m fallback, fully covered MID buckets cap at 300 m, HLOD is visible 300-1000 m, and FAR remains available from 500 m until exact coverage gating replaces the fallback safely.
- The same FAR batch system should support both by changing batch
  `visibility_range_begin`, not by rebuilding all impostor data.

### Threading And Publication

Worker-safe:

- compute desired batch keys;
- read immutable world index data;
- build transform/custom-data arrays for a batch;
- load/decode image bytes if using APIs proven safe for that file type;
- copy/convert `Image` data.

Main-thread:

- scene-tree attachment and detachment;
- `Texture2DArray.create_from_images()`;
- `MultiMesh.instance_count` changes;
- `MultiMesh.set_buffer()`;
- material/shader parameter swaps;
- any RenderingServer call unless the exact call path is separately proven.

Every worker task needs an owner and a drain path.

## Performance Contract

FAR should be measured separately from HLOD because the May 2 verification
showed different failure modes:

- FAR without HLOD recovered to high steady FPS but failed early-frame gates.
- HLOD plus FAR failed from persistent draw-call/surface count in chunk meshes.

FAR gates:

- Normal one-cell crossing: impostor area update <= 2 ms.
- Differential scan: <= 500 cells.
- No full-ring MultiMesh upload on a one-cell crossing after chunking lands.
- No `Texture2DArray.create_from_images()` outside startup or an explicit
  budget window.
- No frame over 50 ms caused by FAR work in dense/east/reclaim runs.
- Final steady-state FAR draw count is chunk-count bounded, not object-count
  bounded.

Telemetry to add:

- FAR active batch count.
- Dirty FAR batch count per frame.
- FAR instances uploaded per frame.
- Texture layers live/pending/evicted.
- Texture-array upload time.
- MultiMesh buffer upload time per batch and total per frame.
- FAR work included in the same overrun log as NEAR/MID/HLOD.

## Implementation Roadmap

1. Instrument before changing architecture.
   Add FAR-specific timings and report them through the central streaming
   profiler. The first benchmark must distinguish cell scan, texture result
   handling, texture-array upload, and MultiMesh upload.

2. Harden `ImpostorPage` as the FAR batch ownership unit.
   It already owns page-local buffers and one `MultiMeshInstance3D` per page
   using the shared shader/material path; remaining work is benchmark tuning
   and acceptance under dense/east/reclaim routes.

3. Prove dirty-page rebuild acceptance.
   The acceptance criterion is that one-cell movement does not rebuild
   unrelated pages and pages waiting for uncommitted texture layers do not spin
   in the rebuild queue.

4. Bring FAR publication under the central budget.
   The renderer can keep queues, but main-thread upload work must be granted by
   `NativeStreamingManager` or a shared streaming scheduler.

5. Migrate background work to native APIs.
   Use `WorkerThreadPool` for CPU-only tasks and ResourceLoader's threaded API
   for resources. Retire `BackgroundJobSystem` from the FAR path after parity.

6. Make candidate selection data-driven.
   Keep Morrowind model-name patterns in the adapter, but feed core FAR with
   model bounds, projected size, priority, and bake availability.

7. Re-run verification.
   Run dense/east/reclaim stress with FAR on and HLOD off first. Then rerun with
   `hlod_enable` only after HLOD chunk material/surface reduction is fixed.

## Anti-Patterns

- Do not replace the octahedral impostor shader with a plain Sprite3D pipeline;
  Godot's billboard helpers do not solve view-dependent octahedral sampling.
- Do not use one world-scoped MultiMesh as the final architecture.
- Do not assume `visibility_range` gives per-slot MultiMesh culling.
- Do not rebuild a full 5 km MultiMesh ring for a one-cell movement.
- Do not call GPU-touching texture or RenderingServer operations from worker
  threads without a focused harness proving the exact Godot 4.6 path.
- Do not extend `BackgroundJobSystem` for new FAR work; use Godot's native
  `WorkerThreadPool` or `ResourceLoader` path.
- Do not move Morrowind model-name pattern logic into generic world systems.

## Related Docs

- `docs/systems/streaming_rendering_bible.md`
- `docs/systems/distance_rendering.md`
- `docs/systems/object_paging.md`
- `docs/audit/distant_rendering_reenable_2026_05_02_codex.md`
- `docs/plans/impostor_rebuild.md`
- `docs/reference/godot_wishlist.md`
