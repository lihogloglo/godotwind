# Object Paging

Current HLOD deep dive. ObjectPaging is the only active HLOD path.

It adapts OpenMW-style object paging to Godot: collect distant static-capable
world object records by distance-adaptive chunks, merge eligible geometry
off-thread as pure data, then publish one raw `RenderingServer` chunk instance
on the main thread.

## Status

HLOD is default-off in `Godotwind.tscn` for the 400m MID/FAR experiment. FAR
impostors are default-on from 400m. `--hlod` / `hlod_enable` remain comparison
tools for isolating HLOD cost and coverage issues.

Runtime modes:

| Mode | MID | HLOD | FAR |
| --- | --- | --- | --- |
| Default | 0-400m `CellStaticBucket` bridge | Off / cleaned up | 400-5000m |
| `hlod_enable` | 0-400m bridge | Visible 400-1000m | 400-5000m |
| `hlod_disable` | 0-400m bridge | Off / cleaned up | 400-5000m |

The nominal constants define `HLOD_START = 400`, `HLOD_END = 1000`, and
`FAR_START = 400`. Runtime HLOD uses the 400m visual floor when explicitly
enabled, and FAR uses the fixed 400m handoff.

Console surface:

| Command | Effect |
| --- | --- |
| `hlod_enable` | Enables ObjectPaging work and HLOD visibility |
| `hlod_disable` | Disables ObjectPaging and cleans up active chunks |
| `hlod_stats` | Prints live chunk, coverage, queue, rejection, cache, merge timing, and runtime-LOD counters |

## Files

| File | Role |
| --- | --- |
| `src/core/world/object_paging.gd` | HLOD orchestrator: desired chunks, ModelLoader-backed prototype warmup, worker queue, completion queue, active chunk lifetime |
| `src/core/world/object_paging_kernel.gd` | GDScript wrapper around the native merge kernel and mesh assembly helpers |
| `src/native/NativeObjectPagingKernel.cs` | Hot merge kernel: packed-array concatenation, material grouping, cost/benefit decisions |
| `src/core/world/world_object_source.gd` | Generic manifest/source interface used by HLOD, FAR impostors, distant lights, and streaming orchestration |
| `src/core/world/morrowind/morrowind_world_object_source.gd` | Morrowind adapter that converts ESM cell refs into generic object records |
| `src/core/world/distance_utils.gd` | Paging constants, chunk keys, chunk centers, tier helpers |
| `src/core/world/object_position_index.gd` | Immutable spatial index queried by chunk |
| `tests/unit/test_object_paging_kernel.gd` | Kernel and paging math coverage |
| `tests/visual/test_hlod_benchmark.gd` | Interactive HLOD benchmark scene |

Historical prebake/cache notes and retired HLOD helper names belong in
`docs/archive/`, not current system instructions.

## Chunk Layout

ObjectPaging walks adaptive chunk sizes by distance. These are selection bands;
the current visible HLOD floor is 300m.

| size_level | Chunk footprint | Selection band | Purpose |
| --- | --- | --- | --- |
| 0 | 1x1 cells | [150, 300)m | reserved below the current visual floor; MID owns visuals |
| 1 | 2x2 cells | [300, 600)m | medium HLOD candidates |
| 2 | 4x4 cells | [600, 1000)m | far HLOD candidates |

`ChunkKey = Vector3i(center_cell.x, center_cell.y, size_level)`.

Chunk alignment uses a bitwise mask, `cell & ~(size - 1)`, so negative cells
align correctly. Naive integer division truncates toward zero and misaligns the
negative quadrant.

Desired chunk selection uses chunk-center distance and a top-down anti-overlap
walk. Larger accepted chunks mark their covered 1x1 sub-cells so smaller chunks
do not duplicate coverage.

## Candidate Filters

The filter order is:

1. Capability and category eligibility.
   The source must mark an object `CAP_HLOD`. Static durable categories are
   eligible in larger chunks. More interactive or gameplay-shaped records are
   restricted to the safety tier or rejected.

2. Projected-size filter.
   Uses the OpenMW form:

   ```text
   radius^2 * scale^2 >= distance^2 * PAGING_MIN_SIZE^2
   ```

   `PAGING_MIN_SIZE` is tuned in Godot meters. Do not copy OpenMW's value
   blindly.

3. Runtime surface count.
   Runtime HLOD preserves accepted refs even when a chunk exceeds the current
   surface warning cap. Over-budget chunks are published and counted so visual
   coverage wins over disappearance; later proxy material/atlas work should
   reduce their draw cost.

4. Cost/benefit merge decision.
   Merge a mesh type only when the expected draw-state benefit justifies the
   vertex/index cost. The native kernel groups by mesh/material identity and
   rejects poor merge candidates.

5. Second-pass min-size relaxation.
   High-benefit types can keep smaller refs in the merged proxy; marginal
   types are filtered more aggressively.

The goal is coverage first inside the optional 400-1000m HLOD band, then fewer useful render surfaces
through proxy-material and atlas work.

## Threading Contract

| Operation | Thread |
| --- | --- |
| `ObjectPositionIndex` reads | worker-safe after build |
| Prototype availability checks and async `.res` requests | main thread, via `ModelLoader` indexed cache |
| Candidate math and packed transform/array preparation | worker |
| `NativeObjectPagingKernel` merge | worker |
| `SizeCache` writes | worker with lock |
| `ImporterMesh` / `generate_lods()` | main thread, currently disabled by `RUNTIME_GENERATE_LODS = false` |
| `RenderingServer` instance/scenario/base/free calls | main thread |

Every worker task must be tracked and drained or rejected through the owner
generation path. Runtime `generate_lods()` is intentionally disabled in the hot
path. If it is re-enabled, it must remain on the main thread because
`ImporterMesh` / `RenderingServer` publication is not worker-safe.

## Lifetime Contract

Each chunk request has a generation. Worker results carry that generation.
Completion publishes only if the generation is still current and the chunk is
still desired. Cleanup invalidates active generations before freeing render
state.

Chunk cleanup order:

1. Mark the chunk no longer desired.
2. Invalidate its generation.
3. Remove it from active/pending discovery.
4. Hide/free RS instances while mesh/material resources are still alive.
5. Drop chunk-owned resources and stats.
6. Reject any late completion by generation.

Correctness requires generation rejection even when cancellation is cooperative
and a worker finishes after the camera leaves range.

## MID/HLOD/FAR Handoff

Current handoff:

- MID `CellStaticBucket` owns visible static geometry through 400m.
- FAR impostors are visible from 400m to 5000m.
- HLOD, when enabled, is visible from 400m to 1000m as an overlap comparison.

The default MID/FAR path is intentionally simple and non-overlapping. Optional
HLOD runs may overlap FAR so their cost and visual coverage can be compared
without creating a 400-1000m hole.
The active coverage manifest intentionally separates rendered HLOD object ids
from complete static-bucket counts. Partial buckets still render in HLOD, but
only complete buckets are safe to use for static-visual suppression. FAR
suppression uses rendered object ids/pages, not bucket completeness.

Any change to these ranges must retune live bucket/chunk/page visibility, not
only future instances.

## Acceptance Gaps

HLOD remains performance-sensitive. These gates still matter:

- bounded active chunk surface/material counts;
- bounded visible/shadow draw calls with HLOD enabled;
- no stale chunk publish after cancellation, teleport, disable, or cleanup;
- no worker task leak;
- no MID/HLOD/FAR holes after runtime toggles;
- no changed-path frame over 50ms in dense/east/reclaim stress;
- interactive visual traversal confirms stable transitions.

The next technical focus is chunk proxy reduction: material/surface grouping,
proxy material policy, chunk split/reject thresholds, and benchmark attribution
that ties draw calls back to HLOD chunk contents.

## Observability

`NativeStreamingManager.get_hlod_stats()` is the raw HLOD diagnostic surface.
`NativeStreamingManager.get_stats()` republishes the same values with `hlod_`
prefixes so generic benchmark/debug paths can sample them without reaching into
ObjectPaging directly. The console `hlod_stats` command prints the same groups:

- live chunk tier counts and visual/nonvisual ownership;
- queue depth, preparation depth, pending worker tasks, negative chunks, and
  teleport warmup queue depth;
- total and max chunk surfaces/materials/vertices/indices;
- active coverage manifest counters and FAR page override counters;
- rejection/incomplete-coverage counters for type, projected-size, surface,
  partial-bucket, surface cap, over-budget published chunks, stale completion,
  and size-cache behavior;
- last-frame merge queue and completion publish timings;
- aggregate streaming lane timings in `streaming_phases`: core phases,
  deferred impostor scan, HLOD merger, distant light billboards, and remaining
  unattributed frame time;
- runtime flags, including `runtime_lods=false`.

## Related Docs

- Tier contract: `docs/systems/distance_rendering.md`
- Streaming architecture: `docs/systems/streaming_rendering_bible.md`
- FAR impostors: `docs/systems/impostor_streaming_rendering.md`
- Historical B-wide migration: `docs/archive/plans/lod_refactor_b_wide.md`
