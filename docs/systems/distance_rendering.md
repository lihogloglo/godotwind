# Distance Rendering

Current contract for Godotwind's distance tiers. This is the concise source of
truth for tier ownership and handoff policy; implementation details live in the
system docs linked below.

## Tier Contract

| Tier | Runtime range | Owner | Technique | Status |
| --- | --- | --- | --- | --- |
| NEAR gameplay | 0-150m visual/gameplay band | `cell_manager.gd`, `native_streaming_manager.gd` | Sparse `Node3D` for gameplay/interactives, static collision, physics, and scene-tree behavior. Toggle disables visibility, processing, and collision/area activation. | Working |
| Static visuals | Fixed 150-400m bridge | `static_object_renderer.gd`, `cell_static_bucket.gd` | Cell-local `CellStaticBucket` draw groups. Groups use local MultiMeshes; singleton groups use the single-slot transform API instead of a bulk buffer upload. Mesh detail uses embedded Godot LOD chains. | Working |
| CHUNK | 400-1200m (target) | Baker: `src/tools/prebaking/` (runner); runtime consumer TBD | **OFFLINE-baked** merged + simplified chunk proxies (MGE XE / OpenMW pattern: merged low-poly real geometry, min-size 0.01 gate, meshoptimizer LOD chain at bake, 1 RS instance per chunk) | Decision locked 2026-07-05 (user); baker in development. Plan: `docs/plans/distant_rendering_recovery_2026_07.md` Phase 2 (revised) |
| FAR impostors | Interim 400-5000m; retreats to **1200-5000m** when CHUNK ships | `native_impostor_renderer.gd` | Octahedral impostors in spatial `MultiMeshInstance3D` pages from generic impostor-capable records. Wrong tool below ~1.2km for architecture (baked lighting vs dynamic sun, parallax flatness) | Working |
| ~~HLOD~~ | ~~Optional 400-1000m experiment~~ | `object_paging.gd` | Runtime merged chunk proxies — merge-without-simplify, stall + segfault class. Superseded by CHUNK; parked default-off; DELETE when CHUNK is verified (the merge kernel + `object_paging_kernel.gd` survive — the CHUNK baker uses them) | Deprecated |

All tier modules are fed through `WorldObjectSource` manifests. The Morrowind
implementation lives in `src/core/world/morrowind/morrowind_world_object_source.gd`;
core render tiers consume stable object ids, transforms, model paths,
categories, and capability flags rather than querying `ESMManager` directly.

The user-facing distance slider is an object view-distance cap in meters. If
the cap is at or below 400m, FAR does not load.

`hlod_enable`: HLOD work starts at the 400m handoff and is capped by the
current view distance up to 1000m. MID remains fixed at 400m, and FAR still
starts at 400m during this experiment.

`hlod_disable`: HLOD chunks are parked/cleaned up. This is the default
production posture for the 400m MID/FAR experiment.

`--near-only`: focused test override that parks distant tiers according to the
runtime toggle policy. Do not treat it as the production tier contract.

## Canonical Boundaries

Distance constants live in `src/core/world/distance_utils.gd`:

- `NEAR_END = 150`
- `MID_END = 400`
- `CHUNK_START = 400`, `CHUNK_END = 1200` (offline chunk tier, in development)
- `HLOD_START = 400`, `HLOD_END = 1000` (deprecated, deleted with object_paging)
- `FAR_START = 400` (interim — moves to `CHUNK_END` when the chunk tier ships)
- `FAR_END = 5000`

`FAR_START` is the fixed post-MID boundary until the CHUNK tier ships; it
was deliberately NOT moved to 1200 early because that would leave 400-1200m
fully empty in the interim (decision 2026-07-05). Runtime view distance can
cap FAR visibility/loading, but does not move the handoff.

MID to NEAR streaming promotion is separate from render-tier visibility:

- promotion starts at 250m;
- demotion happens at 280m;
- the 20m hysteresis prevents promotion churn.

## MID Contract

MID is not a scene-tree workload. Static refs render through
`CellStaticBucket`, keyed by cell/payload ownership. A bucket owns the draw
groups, render RIDs, local `MultiMesh` resources, strong
Mesh/Material refs, and the resource handle pin behind those RIDs.

Draw group policy:

- repeated transforms sharing submesh/material become a cell-local `MultiMesh`
  uploaded with `set_buffer()`;
- singleton groups use the same local `MultiMesh` ownership path with
  `set_instance_transform(0, ...)`, avoiding both direct mesh-RID lifetime
  hazards and one-slot bulk buffer uploads;
- each bucket remains spatially local so Godot culling stays useful;
- cleanup detaches/freeze-stops the bucket before any RID is freed.

Mesh detail policy:

- prebaked static meshes carry embedded LOD chains from
  `ImporterMesh.generate_lods()`;
- Godot's C++ renderer chooses the sub-LOD from projected screen-space size,
  `Viewport.mesh_lod_threshold`, and per-instance `lod_bias`;
- there are no manual `_LOD0` / `_LOD1` / `_LOD2` / `_LOD3` visibility bands.

## HLOD Contract

HLOD is ObjectPaging, not a prebaked cache command and not the retired
cell-merge helper path.

Current HLOD rules:

- HLOD is default-off in `Godotwind.tscn`; `hlod_enable`/`hlod_disable` remain
  runtime comparison controls.
- Runtime visibility begins at 400m.
- MID stays capped at 400m.
- HLOD still must reduce surfaces/materials in chunk proxies; one chunk
  instance is not enough if it still expands into many draw surfaces.

Deep dive: `docs/systems/object_paging.md`.

## FAR Contract

FAR impostors begin at 400m when the view-distance cap is above 400m.

Deep dive: `docs/systems/impostor_streaming_rendering.md`.

## Toggle Contract

Canonical runtime toggle names:

- `near_gameplay`
- `static_visuals`
- `hlod`
- `far_impostors`
- `distant_lights`

Phase 0 (2026-07-05): `static_visuals` is a PURE render toggle. It hides all
static-renderer output (buckets, direct instances, visual proxies) and touches
nothing else — the loaded-cell ring, load profiles, and publish keep running,
so benchmark ablations isolate rendering cost. The streaming policy that used
to piggyback on this toggle lives in
`NativeStreamingManager.set_static_streaming_enabled()` and is parked only by
mode isolation (`--near-only`, `--far-only`, `--hlod-only`). Range clamping
moved to the `static_range <end_m> [begin_m]` console command
(`static_range off` restores the view-distance default).

Temporary compatibility aliases remain for benchmark scripts and console muscle
memory: `near_objects -> near_gameplay`, `mid_objects -> static_visuals`, and
`impostors -> far_impostors`. New docs, HUDs, benchmark ladders, and CLI
messages should use the canonical names.

## Anti-Patterns

- Do not reference retired HLOD merger scripts or prebake console commands as
  the active pipeline; current HLOD is runtime ObjectPaging.
- Do not describe MID as one raw RS instance per object. Current MID ownership
  is `CellStaticBucket` draw groups with local MultiMesh or singleton RS draws.
- Do not reintroduce manual per-LOD visibility ranges for MID. Use embedded LOD
  chains plus Godot's mesh LOD selector.
