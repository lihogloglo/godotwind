# Distance Rendering

Current contract for Godotwind's distance tiers. This is the concise source of
truth for tier ownership and handoff policy; implementation details live in the
system docs linked below.

## Tier Contract

| Tier | Runtime range | Owner | Technique | Status |
| --- | --- | --- | --- | --- |
| NEAR | 0-150m visual/gameplay band | `cell_manager.gd`, `native_streaming_manager.gd` | Sparse `Node3D` for gameplay/interactives, static collision, physics, and scene-tree behavior | Working |
| MID | 0-500m default fallback | `static_object_renderer.gd`, `cell_static_bucket.gd` | Cell-local `CellStaticBucket` draw groups. Groups use local MultiMeshes; singleton groups use the single-slot transform API instead of a bulk buffer upload. Mesh detail uses embedded Godot LOD chains. | Working |
| HLOD | Opt-in; currently visible 300-1000m | `object_paging.gd` | Runtime ObjectPaging chunk proxies: static refs are merged into chunk meshes and published as raw RS instances. | Implemented, opt-in |
| FAR | 500-5000m default-on | `native_impostor_renderer.gd` | Octahedral impostors in spatial `MultiMeshInstance3D` pages | Working, default-on |

Default mode: MID owns 0-500m and FAR begins at 500m. HLOD is off.

`hlod_enable`: HLOD work starts at the canonical 300m handoff. MID remains the
0-500m safety fallback for uncovered buckets, but buckets fully covered by
active HLOD cap their MID visibility at 300m. HLOD is visible 300-1000m, and
FAR remains available from 500m so uncovered or late chunks do not open holes.

`hlod_disable`: HLOD chunks are parked/cleaned up and the default MID/FAR
fallback remains active.

`--near-only`: focused test override that parks distant tiers according to the
runtime toggle policy. Do not treat it as the production tier contract.

## Canonical Boundaries

Distance constants live in `src/core/world/distance_utils.gd`:

- `NEAR_END = 150`
- `MID_END = 500`
- `HLOD_START = 300`
- `HLOD_END = 1000`
- `FAR_START = 1000`
- `FAR_END = 5000`

`FAR_START` is the nominal post-HLOD design boundary. The current runtime safety
policy deliberately shows FAR from 500m because HLOD does not yet own exact
per-page coverage. Do not infer from the constant alone that runtime FAR starts
at 1000m.

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

- HLOD is opt-in through `hlod_enable` and benchmark toggles.
- Runtime visibility begins at 300m.
- Fully covered MID buckets cap at 300m; partial/uncovered buckets keep their
  500m fallback until coverage is exact.
- HLOD must reduce surfaces/materials in chunk proxies before it can become
  default-on; one chunk instance is not enough if it still expands into many
  draw surfaces.

Deep dive: `docs/systems/object_paging.md`.

## FAR Contract

FAR impostors are default-on from 500m in the current safety configuration.
They provide the visible fallback beyond MID whether HLOD is disabled, late,
sparse, or missing coverage.

Deep dive: `docs/systems/impostor_streaming_rendering.md`.

## Anti-Patterns

- Do not reference retired HLOD merger scripts or prebake console commands as
  the active pipeline; current HLOD is runtime ObjectPaging.
- Do not describe MID as one raw RS instance per object. Current MID ownership
  is `CellStaticBucket` draw groups with local MultiMesh or singleton RS draws.
- Do not move FAR to 1000m in docs or tests until HLOD owns exact coverage.
- Do not reintroduce manual per-LOD visibility ranges for MID. Use embedded LOD
  chains plus Godot's mesh LOD selector.
