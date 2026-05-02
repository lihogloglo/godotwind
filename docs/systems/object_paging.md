# Object Paging

Current HLOD deep dive. ObjectPaging is the only active HLOD path.

It adapts OpenMW-style object paging to Godot: collect distant static refs by
distance-adaptive chunks, merge eligible geometry off-thread as pure data, then
publish one raw `RenderingServer` chunk instance on the main thread.

## Status

HLOD is implemented but opt-in. FAR impostors are default-on from 500m; HLOD is
not default-on after the 2026-05-02 stress run exposed persistent chunk
surface/material draw-call cost.

Runtime modes:

| Mode | MID | HLOD | FAR |
| --- | --- | --- | --- |
| Default | 0-500m `CellStaticBucket` fallback | Off | 500-5000m |
| `hlod_enable` | 0-500m fallback; covered buckets cap at 300m | Visible 300-1000m | 500-5000m fallback |
| `hlod_disable` | 0-500m safety fallback | Off / cleaned up | 500-5000m |

The nominal constants define `HLOD_START = 300`, `HLOD_END = 1000`, and
`FAR_START = 1000`. Runtime HLOD now uses the 300m visual floor, while FAR
stays at 500m until exact chunk/page coverage ownership exists.

Console surface:

| Command | Effect |
| --- | --- |
| `hlod_enable` | Enables ObjectPaging work and HLOD visibility with MID/FAR safety fallback |
| `hlod_disable` | Disables ObjectPaging and cleans up active chunks |
| `hlod_stats` | Prints live chunk, coverage, queue, rejection, cache, merge timing, and runtime-LOD counters |

## Files

| File | Role |
| --- | --- |
| `src/core/world/object_paging.gd` | HLOD orchestrator: desired chunks, worker queue, completion queue, active chunk lifetime |
| `src/core/world/object_paging_kernel.gd` | GDScript wrapper around the native merge kernel and mesh assembly helpers |
| `src/native/NativeObjectPagingKernel.cs` | Hot merge kernel: packed-array concatenation, material grouping, cost/benefit decisions |
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

1. Type eligibility.
   Static durable refs are eligible in larger chunks. More interactive or
   gameplay-shaped records are restricted to the safety tier or rejected.

2. Projected-size filter.
   Uses the OpenMW form:

   ```text
   radius^2 * scale^2 >= distance^2 * PAGING_MIN_SIZE^2
   ```

   `PAGING_MIN_SIZE` is tuned in Godot meters. Do not copy OpenMW's value
   blindly.

3. Cost/benefit merge decision.
   Merge a mesh type only when the expected draw-state benefit justifies the
   vertex/index cost. The native kernel groups by mesh/material identity and
   rejects poor merge candidates.

4. Second-pass min-size relaxation.
   High-benefit types can keep smaller refs in the merged proxy; marginal
   types are filtered more aggressively.

The goal is not "merge everything." The goal is fewer useful render surfaces
with bounded main-thread publication cost.

## Threading Contract

| Operation | Thread |
| --- | --- |
| `ObjectPositionIndex` reads | worker-safe after build |
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

Current safety handoff:

- MID `CellStaticBucket` owns visible static geometry through 500m.
- HLOD, when enabled, is visible from 300m to 1000m.
- FAR impostors remain visible from 500m to 5000m.

This overlap is intentional. It avoids holes while HLOD lacks exact coverage
ownership. The desired future state is non-overlapping ownership, but only
after HLOD can prove which chunks/pages are complete enough to replace MID/FAR.
Covered MID buckets cap at 300m, but uncovered buckets retain the 500m fallback.

Any change to these ranges must retune live bucket/chunk/page visibility, not
only future instances.

## Acceptance Gaps

HLOD cannot become default-on until these are proven:

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
- rejection counters for type, projected-size, surface, partial-bucket, surface
  cap, stale completion, and size-cache behavior;
- last-frame merge queue and completion publish timings;
- runtime flags, including `runtime_lods=false`.

## Related Docs

- Tier contract: `docs/systems/distance_rendering.md`
- Streaming architecture: `docs/systems/streaming_rendering_bible.md`
- FAR impostors: `docs/systems/impostor_streaming_rendering.md`
- Historical B-wide migration: `docs/archive/plans/lod_refactor_b_wide.md`
