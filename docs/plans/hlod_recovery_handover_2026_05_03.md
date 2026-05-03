# HLOD Recovery Handover - 2026-05-03

## Purpose

This is the handover note for bringing HLOD/object paging back into shape after
the NEAR/MID/impostor re-enable exposed a large FPS regression.

The key conclusion from the research pass: the tier architecture is directionally
canonical, but the current ownership and tuning are not where they need to be.
MID is carrying too much of the distant-rendering job. HLOD/object paging should
become the scalable distant-static tier, with MID reduced to a short bridge band.

## Current Mental Model

Cells are storage/gameplay lifetime buckets. Distance tiers are visual
representations.

A cell may have several representations alive at once:

- Full NEAR Node3D/gameplay representation.
- MID render-only static buckets.
- HLOD/object-paging chunk that includes the same cell.
- FAR impostors for refs beyond detailed rendering.

This is not inherently wrong. The important rule is that only one visual
representation should normally own a given ref at a given distance, aside from a
small transition margin.

## Target Tier Shape

Proposed target:

- `0-150m`: NEAR. Full Node3D where needed, actors, interaction, lights, physics
  and collision.
- `150-300m`: MID. Short render-only bridge for individual static objects using
  Godot mesh LOD and spatially local buckets.
- `300-1000m`: HLOD/object paging. Quadtree/power-of-two chunks, merged or
  simplified static geometry.
- `1000m+`: FAR impostors/billboards, with HLOD coverage allowed to delay
  impostors when the HLOD replacement is complete.

These numbers are initial tuning targets, not sacred constants. The important
part is the shape: MID should be narrow and fixed; HLOD should scale; impostors
own the horizon.

## Slider Policy

The user-facing "MID depth" slider is probably the wrong control.

The current code derives `_distant_render_end_m` from `load_radius_cells`, then
uses it for both MID visibility end and impostor visibility begin:

- `StreamingConfig.distant_render_end_for_load_radius_cells()`
- `NativeStreamingManager._apply_distant_render_distance_for_load_radius()`

That makes the most expensive distant tier expand with view distance. The next
implementation should strongly consider separating:

- Active gameplay cell radius.
- MID bridge distance.
- HLOD/impostor view distance.

Suggested behavior:

- Keep MID fixed at about `300m`.
- Let the user-facing distant-view slider control HLOD/FAR reach, not raw MID
  depth.
- If HLOD is disabled, impostors may begin at the MID cap as fallback.

## HLOD Should Be Quadtree-Like

OpenMW does not treat object paging as "one merged mesh per active cell." It uses
`Terrain::QuadTreeWorld::ChunkManager`; object-paging chunks have a center, size,
and active-grid flag. Chunks collect refs from all cells they cover, then decide
which refs are worth paging/merging.

Relevant OpenMW anchors:

- `inspos/openmw/apps/openmw/mwrender/objectpaging.hpp`
- `inspos/openmw/apps/openmw/mwrender/objectpaging.cpp`
- `inspos/openmw/components/terrain/quadtreeworld.cpp`
- `inspos/openmw/apps/openmw/mwworld/scene.cpp`

Godotwind already has a fixed quadtree-like version:

- `size_level 0`: `1x1` cells, nominal `[150, 300)m`
- `size_level 1`: `2x2` cells, nominal `[300, 600)m`
- `size_level 2`: `4x4` cells, nominal `[600, 1000)m`

Relevant Godotwind anchors:

- `src/core/world/distance_utils.gd`
- `src/core/world/object_paging.gd`

This is a good direction. It does not need to become a perfect OpenMW clone on
day one. The immediate goal is to make HLOD the normal owner after MID, not a
parked optional overlay.

## Ownership Contract

This is the most important implementation point.

OpenMW asks object paging which refnums are already paged. When active cells are
loaded, those refs skip their individual visual insertion while gameplay/physics
can still be added. See the `pagedRefs` flow in `scene.cpp`.

Godotwind has similar ingredients:

- HLOD coverage manifest in `object_paging.gd`.
- MID bucket override path in `static_object_renderer.gd`.
- FAR per-page coverage path in `native_impostor_renderer.gd`.

Current Godotwind behavior is conservative: MID remains fallback unless HLOD
coverage proves a bucket/page is fully represented. That avoids holes, but it can
leave MID paying too much cost.

Target behavior:

- HLOD publishes a reliable source-ref/source-bucket coverage manifest.
- Covered MID buckets stop drawing past the HLOD handoff.
- Covered impostor pages can begin at HLOD end instead of MID end.
- Partial/incomplete coverage falls back to MID/FAR deliberately and visibly in
  diagnostics.
- No global HLOD enable should create holes; fallback remains until coverage is
  proven.

## Why Not Delete MID?

MID still has a job. A whole-cell or multi-cell merged proxy can be visibly too
coarse at `150-300m`: silhouettes, parallax, material detail, and object
separation still matter. MID should be the close visual bridge from full NEAR to
chunked HLOD.

The problem is not that MID exists. The problem is MID acting as a scalable
horizon tier.

## Why Not Use Terrain3D For This?

Terrain3D helps with terrain surface rendering and simple terrain-attached
instances. It does not replace object paging for arbitrary Morrowind statics.

Good Terrain3D candidates:

- Terrain clipmap/LOD.
- Grass and groundcover.
- Simple repeated foliage/rocks/debris.
- Terrain3DInstancer LOD/shadow-impostor features during the grass pass.

Poor Terrain3D candidates:

- Buildings, ships, caves, doors, multi-mesh architecture.
- Anything needing per-ref visual ownership tied to Morrowind refs.
- Gameplay/interactable objects.

Keep Terrain3D in mind for the future grass/groundcover implementation, not for
the HLOD recovery itself.

## Suggested Next-Agent Plan

1. Add a clean benchmark ladder:
   - NEAR only.
   - NEAR + MID capped at `300m`.
   - NEAR + MID + impostors.
   - NEAR + MID + HLOD + impostors.
2. Decouple MID cap from `load_radius_cells`.
3. Make MID cap a fixed bridge constant or quality-preset value.
4. Re-enable HLOD behind diagnostics and verify coverage manifests.
5. Make HLOD coverage suppress MID after the handoff when exact.
6. Make incomplete HLOD coverage explicit in HUD/log stats.
7. Only after stability, expose a user-facing distant view slider that extends
   HLOD/impostor range rather than raw MID range.

## Verification Expectations

This work affects rendering, streaming, and performance. Do not call it done
from static inspection alone.

Before declaring success:

- Run `dotnet build Godotwind.sln` if any C# changed.
- Launch `scenes/Godotwind.tscn` interactively for visual inspection, or run an
  automated benchmark/crash smoke that exercises NEAR/MID/HLOD/FAR transitions.
- Check for holes at the `300m` and `1000m` handoffs.
- Check for double-render overlap at handoffs.
- Record FPS/draw/object counts for each benchmark ladder rung.

## Open Questions

- Should the `1x1` HLOD level remain parked below `300m`, or should it become a
  fallback for sparse scenes where MID is too expensive?
- Should HLOD chunks be runtime-merged only, or should common chunks eventually
  have a prebake/cache path?
- Should MID and HLOD share one source-ref ownership registry instead of passing
  bucket-count manifests?
- Should the current `load_radius_cells` UI be renamed to avoid implying it is
  purely cell lifetime?

