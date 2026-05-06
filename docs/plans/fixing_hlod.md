# Fixing HLOD

Date: 2026-05-06  
Status: Phase 1 shipped 2026-05-07; Phase 5 cache-only predictive prefetch in progress

## Progress Log

### 2026-05-07 Phase 1: Stop Broken Output

Implemented:

- `src/native/NativeObjectPagingKernel.cs` no longer publishes overflow HLOD
  surfaces with `Material = null`.
- Source materialless surfaces and overflow-folded surfaces now receive a valid
  neutral HLOD proxy material instead of Godot's default white material.
- `hlod_stats` now reports visible HLOD draw-call estimate, null-material
  surface count, proxy fallback surface count, overflow-folded surface count,
  and chunk surface/material histograms.
- `tests/visual/test_hlod_only.gd` HUD and benchmark CSV expose the new
  material/proxy counters.
- Unit coverage was added for null source materials and >250-surface overflow.

Verification:

- `dotnet build Godotwind.sln` passed.
- `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn`
  passed.
- `scenes/Godotwind.tscn --hlod-only` was launched interactively.
- User visual check confirmed the white/default HLOD objects are solved.

Remaining after Phase 1:

- FPS is still poor: roughly 60 FPS max, around 35 FPS while moving, with
  stutters.
- The next bottleneck is still the expected one from this audit: HLOD chunks
  are too material/surface heavy, so Phase 2 must collapse exact source material
  identity into bounded distant proxy buckets.

### 2026-05-07 Phase 2 Runtime Proxy Attempt: Reverted

Attempted:

- Added a runtime proxy-material bucketing path in the native HLOD merge kernel
  to collapse exact source material identity into coarse color/material classes.

Result:

- User visual check caught a bad regression: HLOD objects became fully white /
  visually wrong.
- The runtime bucketing path was removed. Phase 1's valid fallback material for
  null/overflow surfaces remains.

Decision:

- Do not collapse live HLOD materials by replacing them with coarse generated
  materials in the worker merge path.
- The proxy-material stage needs to happen in a cache/prebuild path with proper
  source texture/material metadata, not as an in-place runtime shortcut.

### 2026-05-07 Phase 5 Partial: Cache-Only Predictive Prefetch

Implemented:

- `ObjectPaging` now estimates camera velocity and computes a future HLOD ring
  in the movement direction.
- Predicted chunks are allowed to warm/merge into the mesh cache, but they are
  not published as visible RenderingServer instances until they enter the
  current desired HLOD ring.
- `hlod_stats` and the HLOD-only HUD now report predictive prefetch chunk count.

Expected effect:

- Normal movement should encounter fewer completely cold HLOD chunks at the
  tier boundary.
- This does not solve first-time runtime merge/upload cost. Cached/prebuilt
  proxy assets remain the needed stutter fix.

### 2026-05-07 Phase 5 Follow-up: Coverage Sync Budget Guard

Implemented:

- HLOD coverage sync now checks a cheap coverage revision before rebuilding the
  full active coverage manifest.
- HLOD-only mode no longer pushes HLOD coverage into disabled MID/FAR consumers.

Verification:

- `dotnet build Godotwind.sln` passed.
- `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn`
  passed.
- `scenes/Godotwind.tscn --hlod-only` was launched and logs were inspected.

Result:

- The prior catastrophic HLOD-manager stalls in the user log, including a
  1040 ms frame and a 716 ms follow-up, did not recur in the follow-up run.
- Smaller HLOD-owned overruns remain, including a 34.8 ms publish frame.
- FPS remains poor in dense views because visible HLOD still reaches thousands
  of surfaces/materials; this is still the Phase 2/3 proxy-material and cached
  proxy-asset problem, not solved by predictive prefetch.

### 2026-05-07 Phase 5 Follow-up: Cached Publish Budgeting

Implemented:

- Cached HLOD chunks no longer create RenderingServer instances directly inside
  `ObjectPaging.update_for_camera`.
- Cache hits now enter a `cached_publish_queue` and publish through
  `process_completions`, sharing the same per-frame HLOD publication budget as
  fresh worker completions.
- The production `NativeStreamingManager` and HLOD-only test scene now update
  the desired HLOD ring before draining merge/publish work for the frame.
- HLOD-only HUD/CSV and `hlod_stats` expose the cached publish queue depth.

Verification:

- `dotnet build Godotwind.sln` passed.
- Targeted `tests/unit/test_object_paging_kernel.gd` passed.
- Full `res://tests/run_tests.tscn` passed.
- `scenes/Godotwind.tscn --hlod-only` was launched interactively.

Result:

- User visual check reports there are still movement spikes and FPS remains
  very poor.
- This confirms cached publish bursts were not the root performance problem.
- The remaining spike source is consistent with the core audit: individual
  runtime HLOD chunks are still too heavy to upload/render. A frame budget can
  decide when to publish a chunk, but it cannot make one oversized mesh upload
  cheap once publication starts.
- Next fix should stop publishing oversized runtime proxies as if they were
  acceptable HLOD. The runtime fallback must either reject/defer them until a
  cached/prebuilt proxy exists, or split/drop content by representation class.

## Goal

Make HLOD the cheap distant-content tier it is supposed to be: stable, low-stutter,
low-draw-call, visually coherent from 300-1000m, and architecturally compatible
with the generic open-world framework.

This is not a threshold-tuning task. The target is the industry-standard HLOD
shape: grouped distant content becomes simplified proxy assets with simplified
proxy materials, streamed predictively and published under a hard frame budget.

## Canonical Pattern

The common pattern across engines is:

1. Cluster distant static content by world-space cells/chunks.
2. Generate proxy meshes for those clusters.
3. Simplify geometry and material state together.
4. Stream and compile those proxies before they are needed.
5. Switch tiers by distance/screen size using engine visibility/LOD features.

References:

- Godot 4.6 3D optimization docs list visibility ranges as the manual HLOD path:
  https://docs.godotengine.org/en/4.6/tutorials/optimization/optimizing_3d_performance.html
- Godot visibility ranges are the engine-level handoff mechanism for manual LOD/HLOD:
  https://docs.godotengine.org/en/4.0/tutorials/3d/visibility_ranges.html
- Unreal's HLOD overview defines HLOD as combining static mesh actors into a
  single proxy mesh and material with atlased textures:
  https://dev.epicgames.com/documentation/en-us/unreal-engine/hierarchical-level-of-detail-overview-in-unreal-engine
- Unreal's HLOD simplification API exposes mesh proxy and material proxy settings
  as first-class concepts:
  https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/HLOD/FHierarchicalSimplification
- OpenMW reference implementation:
  `inspos/openmw/apps/openmw/mwrender/objectpaging.cpp`

## Current Evidence

From the HLOD-only interactive run:

- HLOD-only correctly isolated terrain + HLOD. NEAR/MID/FAR/distant lights were
  off and loaded NEAR cells stayed at 0.
- FPS settled around 50-60 in dense views, with worse dips on transitions.
- Draw calls rose to roughly 2,000-2,600 in HLOD-only views.
- HLOD chunks reached thousands of output surfaces/materials.
- Several chunks published over the nominal surface warning cap.
- The screenshot shows white/default-looking surfaces in HLOD chunks.

The practical read: the tier is structurally isolated, but it is not yet cheap.
It is reducing node/object management, but it is not reducing render state enough.

## Issue 1: HLOD Is Still Material/Surface Heavy

**What is happening**

`ObjectPaging` creates one raw RenderingServer instance per chunk, but the chunk
mesh still contains many surfaces. The C# merge kernel groups by exact material
identity. Morrowind content has highly fragmented material identity, so a merged
chunk can still contain hundreds of surfaces. Godot then still pays many draw
calls.

Relevant code:

- `src/core/world/object_paging.gd`
- `src/core/world/object_paging_kernel.gd`
- `src/native/NativeObjectPagingKernel.cs`

**Why OpenMW can be faster**

OpenMW does not treat "merged vertices" as the whole win. Its object paging
pipeline analyzes render state reuse, merges geometry through the scene
optimizer, and schedules GL object compilation incrementally. The merge is a
render-state optimization, not just a vertex concatenation step.

**Good move**

Build a real HLOD proxy-material stage:

- Generate chunk proxy meshes with a small, bounded material count.
- Replace exact material identity with proxy material classes or texture atlases.
- Keep high-signal landmark materials when needed, but collapse distant clutter
  into coarse material groups.
- Measure success by draw calls/material surfaces per visible HLOD chunk, not by
  "one RS instance per chunk."

Target: a chunk should normally be single-digit surfaces, not hundreds.

## Issue 2: White Objects Are Probably Material Overflow

**What is happening**

`NativeObjectPagingKernel.cs` has an overflow path for chunks with too many
material groups. It keeps the largest surfaces, combines the overflow, and assigns
the combined overflow surface `Material = null`. Godot renders that as a default
white-ish material.

Relevant code:

- `src/native/NativeObjectPagingKernel.cs`

**Good move**

Delete the null-material overflow behavior as part of the proxy-material stage.
When material count exceeds budget, the fallback should be:

- assign a valid simplified proxy material;
- split the chunk into multiple proxy parts if that is cheaper/clearer;
- or route specific content classes to impostors/groundcover instead of geometry.

Never publish a visible HLOD surface with no material. That is not a graceful
degradation; it is broken output.

## Issue 3: Runtime Merging Causes Transition Stutter

**What is happening**

Chunk input prep is budgeted, and vertex transforms happen in C#, but the runtime
path still has live work at cell transitions: model warmup, surface array reads,
worker submission, completed mesh publication, RS instance creation, and GPU
resource upload/compile pressure.

OpenMW has an incremental compile/resource-cache system around this. We have a
good start with warmup and worker tasks, but we are still generating expensive
proxy resources too close to visibility time.

**Good move**

Move HLOD proxy generation out of the live traversal path:

- Primary path: cached/prebuilt HLOD chunk assets on disk.
- Runtime path: stream, upload, and show already-built proxy resources.
- Background path: build missing proxies asynchronously and save them, but do not
  let a missing proxy hitch the frame that needs to render.
- Publish GPU resources under a hard frame budget, with visible old chunks kept
  alive until replacements are ready.

Runtime merging can remain as a development fallback, but not as the shipping
performance path.

## Issue 4: HLOD Is Not Predictively Paged Like NEAR

**What is happening**

NEAR has velocity-aware preloading. HLOD mostly uses current camera position,
chunk-center distance, distance-sorted queueing, and teleport warmup. That helps,
but it is not the same as preloading the chunks the player is heading toward.

**Good move**

After proxy assets are cheap enough, add a predictive HLOD stream source:

- Use camera/player velocity on the XZ plane.
- Preload the next HLOD ring in the movement direction.
- Keep the current distance ring resident until the next ring is ready.
- Treat teleport as a separate loading-state path, not a normal movement case.

Prediction should hide latency. It should not be used to excuse expensive proxy
generation.

## Issue 5: Coverage-First Currently Forces Too Much Geometry

**What is happening**

`RUNTIME_FORCE_MERGE_ELIGIBLE_REFS = true` favors visual coverage. That was a
reasonable corrective move after HLOD holes, but it means the kernel bypasses
some cost-benefit filtering and accepts many refs into surface-heavy chunks.

The result is visually dense but expensive.

**Good move**

Separate three decisions:

1. Should this object appear in distant content at all?
2. Which representation should it use: HLOD geometry, impostor, groundcover,
   distant light, or nothing?
3. Can this HLOD proxy claim complete coverage for suppressing MID/FAR overlap?

Use screen-size and content-class rules:

- Buildings, rocks, large statics: HLOD geometry/proxy.
- Trees and repeated organic clutter: impostors, billboards, or specialized
  vegetation/groundcover renderer.
- Tiny clutter below screen threshold: drop from HLOD.
- Lights: distant-light system, not HLOD geometry.

That keeps coverage intentional without making every accepted object part of an
expensive geometry proxy.

## Issue 6: HLOD Geometry Is Not Simplified Enough

**What is happening**

Runtime HLOD LOD generation is disabled, which is good for avoiding main-thread
ImporterMesh cost, but it also means the currently published HLOD mesh can carry
too many vertices/indices for a distant proxy.

The logs showed millions of visible primitives in HLOD-only views.

**Good move**

Generate simplified HLOD meshes offline or in a cache build step:

- Use decimation targets per distance band.
- Preserve silhouettes for large landmarks.
- Aggressively simplify interiors/backfaces/details not visible at 300-1000m.
- Store proxy meshes with their intended material proxies.
- Do not call runtime LOD generation in the hot path.

The shipping HLOD chunk should be a purpose-built distant mesh, not a merged copy
of near geometry.

## Issue 7: Cache Policy Must Pin Active Chunks

**What is happening**

Previous audit notes flagged that cache pressure can delete active HLOD resources
if active chunks are treated the same as inactive cached entries.

**Good move**

Make residency explicit:

- Active visible chunks are pinned.
- Recently visible chunks are warm-resident for a short grace window.
- Only inactive cached proxies are evictable.
- If memory is over budget, degrade future proxy quality or refuse new inactive
  cache entries before evicting visible chunks.

This matches the standard streaming-resource rule: never evict what the renderer
is actively drawing.

## Issue 8: Metrics Need To Track Proxy Quality, Not Just Chunk Count

**What is happening**

The current stats are useful, but the primary health signal should be whether the
visible HLOD set is cheap enough to render.

**Good move**

Make these first-class acceptance counters:

- visible HLOD chunks;
- surfaces/materials per chunk;
- total visible HLOD draw calls;
- total visible HLOD triangles/primitives;
- proxy memory per chunk;
- chunk build/load/upload time;
- white/default-material surface count;
- missing/negative chunks by reason;
- content-class breakdown: building, rock, tree, clutter, door, activator.

Acceptance should fail if HLOD-only has thousands of draw calls, even if it has
"only" a few chunk instances.

## Recommended Implementation Direction

### Phase 1: Stop Broken Output

- Remove/null-material overflow as an allowed visible result.
- Add telemetry for default-material HLOD surfaces.
- Add per-chunk material/surface histograms to `hlod_stats`.
- Keep HLOD-only launch mode as the visual verification scene.

Expected effect: white objects become diagnosed and bounded instead of silently
published.

### Phase 2: Build Proxy Material Policy

- Define distant proxy material classes or an atlas/texture-array path.
- Bucket source materials into those proxy classes.
- Preserve only the material features that matter at HLOD distance: albedo,
  alpha cutout where necessary, rough normal/color class if needed.
- Avoid per-source-material surfaces in HLOD chunks.

Expected effect: draw calls collapse because surfaces collapse.

### Phase 3: Cached HLOD Proxy Assets

- Add a cache builder for HLOD chunks.
- Output chunk proxy mesh + proxy material metadata.
- Store cache keys by data source, cell/chunk key, content version, and proxy
  settings version.
- Runtime loads proxies instead of generating them during traversal.

Expected effect: cell-transition stutters drop because expensive merge/simplify
work no longer lands on the live frame.

### Phase 4: Representation Split

- Route large statics to HLOD geometry.
- Route repeated trees/organic clutter to impostors or vegetation renderer.
- Route tiny clutter out by projected screen size.
- Route lights to distant-light pages.

Expected effect: HLOD stops trying to be the renderer for every distant thing.

### Phase 5: Predictive Streaming

- Feed HLOD streaming from current camera/player velocity, like NEAR preloading.
- Preload ahead of the current ring.
- Keep old visible chunks until new chunks are resident.

Expected effect: movement through cell boundaries stops exposing HLOD build/load
latency.

## Definition Of Done

HLOD should not be called fixed until:

- HLOD-only can be launched interactively with terrain and no NEAR/MID/FAR.
- Dense views hold the target FPS with no recurring transition hitch.
- Visible HLOD draw calls are bounded and substantially below MID/FAR full-stack
  cost.
- No visible white/default-material proxy surfaces.
- Chunk publication never exceeds the frame budget in normal movement.
- HLOD gaps are measured and intentional, not hidden by widening MID or FAR.
- The system remains data-source agnostic: Morrowind-specific selection rules
  live in the adapter/source layer, while the HLOD framework consumes generic
  object records and proxy metadata.

## Plain-English Summary

The issue is not that HLOD is missing a tiny tweak. The current system is doing
runtime chunk aggregation, but industry-standard HLOD is proxy generation:
fewer meshes, fewer triangles, and especially fewer materials. Our HLOD is still
rendering too many material islands, and sometimes it falls off the edge into
white default material overflow. The clean fix is to build real distant proxies:
simplified chunk meshes with simplified/atlased materials, cached ahead of time,
then streamed predictively.
