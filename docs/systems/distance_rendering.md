# Distance Rendering

Current contract for Godotwind's distance tiers. This is the concise source of
truth for tier ownership and handoff policy; implementation details live in the
system docs linked below.

## Tier Contract

| Tier | Runtime range | Owner | Technique | Status |
| --- | --- | --- | --- | --- |
| NEAR gameplay | 0-150m visual/gameplay band | `cell_manager.gd`, `native_streaming_manager.gd` | Sparse `Node3D` for gameplay/interactives, static collision, physics, and scene-tree behavior. Toggle disables visibility, processing, and collision/area activation. | Working |
| Static visuals | Fixed 150-300m bridge | `static_object_renderer.gd`, `cell_static_bucket.gd` | Cell-local `CellStaticBucket` draw groups. Groups use local MultiMeshes; singleton groups use the single-slot transform API instead of a bulk buffer upload. Mesh detail uses embedded Godot LOD chains. | Working |
| HLOD | Fixed 300-1000m, capped by view distance | `object_paging.gd` | Runtime ObjectPaging chunk proxies from generic world object records: static-capable objects are merged into chunk meshes and published as raw RS instances. | Working, default-on |
| FAR impostors | Fixed 1000-5000m, capped by view distance | `native_impostor_renderer.gd` | Octahedral impostors in spatial `MultiMeshInstance3D` pages from generic impostor-capable records | Working |

All tier modules are fed through `WorldObjectSource` manifests. The Morrowind
implementation lives in `src/core/world/morrowind/morrowind_world_object_source.gd`;
core render tiers consume stable object ids, transforms, model paths,
categories, and capability flags rather than querying `ESMManager` directly.

The user-facing distance slider is an object view-distance cap in meters. It
does not expand MID. If the cap is below 300m, HLOD and FAR do not load. If the
cap is below 1000m, FAR does not load.

`hlod_enable`: HLOD work starts at the canonical 300m handoff and is capped by
the current view distance up to 1000m. MID remains fixed at 300m.

`hlod_disable`: HLOD chunks are parked/cleaned up for ablation. Production
ownership still expects HLOD to cover 300-1000m.

`--near-only`: focused test override that parks distant tiers according to the
runtime toggle policy. Do not treat it as the production tier contract.

## Canonical Boundaries

Distance constants live in `src/core/world/distance_utils.gd`:

- `NEAR_END = 150`
- `MID_END = 300`
- `HLOD_START = 300`
- `HLOD_END = 1000`
- `FAR_START = 1000`
- `FAR_END = 5000`

`FAR_START` is the fixed post-HLOD design boundary. Runtime view distance can
cap FAR visibility/loading, but cannot move FAR earlier than 1000m.

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

- HLOD is default-on in `Godotwind.tscn`; `hlod_enable`/`hlod_disable` remain
  runtime ablation controls.
- Runtime visibility begins at 300m.
- MID stays capped at 300m; incomplete HLOD coverage is diagnosed rather than
  widening MID.
- HLOD still must reduce surfaces/materials in chunk proxies; one chunk
  instance is not enough if it still expands into many draw surfaces.

Deep dive: `docs/systems/object_paging.md`.

## FAR Contract

FAR impostors begin at 1000m when the view-distance cap is above 1000m.

Deep dive: `docs/systems/impostor_streaming_rendering.md`.

## Toggle Contract

Canonical runtime toggle names:

- `near_gameplay`
- `static_visuals`
- `hlod`
- `far_impostors`
- `distant_lights`

Temporary compatibility aliases remain for benchmark scripts and console muscle
memory: `near_objects -> near_gameplay`, `mid_objects -> static_visuals`, and
`impostors -> far_impostors`. New docs, HUDs, benchmark ladders, and CLI
messages should use the canonical names.

## Anti-Patterns

- Do not reference retired HLOD merger scripts or prebake console commands as
  the active pipeline; current HLOD is runtime ObjectPaging.
- Do not describe MID as one raw RS instance per object. Current MID ownership
  is `CellStaticBucket` draw groups with local MultiMesh or singleton RS draws.
- Do not move FAR earlier than 1000m in docs, tests, or runtime code.
- Do not reintroduce manual per-LOD visibility ranges for MID. Use embedded LOD
  chains plus Godot's mesh LOD selector.
