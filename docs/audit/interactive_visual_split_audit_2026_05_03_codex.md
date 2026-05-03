# Interactive Visual Split Audit

Date: 2026-05-03
Owner: Codex
Channel: #hlod

## Problem

Godotwind currently lets some visible world objects exist only as near-range
gameplay `Node3D` instances. Exterior doors are the clearest failure: a door can
be absent visually until the camera enters the interactive lazy-spawn radius,
then appear after the deferred queue wakes and the instantiation budget drains.

That is the wrong architecture for an open-world renderer. A world object's
visual presence and its full gameplay actor lifetime are different concerns.

The desired invariant is:

> If an object matters to scene readability, a cheap visual representation must
> exist before the full interactive actor is needed.

## Canonical Pattern

AAA open-world engines split persistent source data into multiple runtime
representations:

- A persistent placed reference/record owns identity and mutable state.
- Far and mid distance use cheap visual-only forms: HLOD proxies, merged mesh
  pages, impostors, instanced static meshes, or LOD renderers.
- Near distance promotes to full gameplay actors with scripts, collision,
  inventory, animation, AI, interaction, and transition hooks.
- Mutable state invalidates or overrides visual proxies so opened, picked up,
  disabled, moved, or quest-swapped objects do not reappear from stale batches.

References:

- Unreal World Partition streams world cells, while World Partition HLOD builds
  simplified/merged/instanced proxy content for distant unloaded content:
  https://dev.epicgames.com/documentation/en-us/unreal-engine/world-partition-in-unreal-engine
  and
  https://dev.epicgames.com/documentation/en-us/unreal-engine/world-partition---hierarchical-level-of-detail-in-unreal-engine
- Unity `LODGroup` switches renderers by screen-space size, and Unity
  scene/SubScene workflows separate render data from loaded GameObjects:
  https://docs.unity.cn/2023.2/Documentation/Manual/class-LODGroup.html
- Godot's own visibility-range HLOD documentation describes replacing groups of
  nearby meshes with a larger distant mesh, and uses visibility parents to avoid
  pop during transitions:
  https://docs.godotengine.org/en/latest/tutorials/3d/visibility_ranges.html
- Godot explicitly supports disabling shadows for small geometry where the
  shadow is unlikely to matter:
  https://docs.godotengine.org/en/stable/classes/class_geometryinstance3d.html
- OpenMW doors are authored as door records with an associated model rendered in
  the world, while OpenMW object paging merges nearby objects to reduce distant
  draw calls:
  https://openmw.readthedocs.io/en/latest/reference/modding/doors-and-teleports.html
  and https://openmw.org/2020/openmw-spotlight-turning-the-pages/

## Current Godotwind Behavior

The bug comes from treating "needs gameplay behavior" as "must have no distant
visual representation."

Current code paths:

- `src/core/world/reference_instantiator.gd`
  - `INTERACTIVE_PROXIMITY_THRESHOLD_M = 25.0`.
  - `_is_proximity_gated()` returns true for `door`, `activator`,
    `container`, and every registered carryable.
  - `_instantiate_model_object()` returns `null` and marks
    `last_proximity_deferred` when those refs are farther than 25m.
  - `_should_route_to_renderer()` explicitly excludes doors, activators, and
    containers from the static/MID renderer path.
  - `_attach_door_interactable()` adds the door gameplay adapter and
    interaction Area3D only after the full Node3D is spawned.
- `src/core/world/cell_manager.gd`
  - `_proximity_deferred` stores deferred doors/containers/activators/carryables.
  - `PROXIMITY_TICK_INTERVAL_MSEC = 250`.
  - `PROXIMITY_REQUEUE_MAX_PER_TICK = 4`.
  - `tick_proximity_deferred()` requeues only nearby deferred refs.
  - Several comments still say 80m, but the actual threshold is 25m.
- `src/core/interaction/morrowind/mw_carryable_registry.gd`
  - MW carryables include weapons, armor, clothing, books, potions,
    ingredients, misc items, apparatus, lockpicks, probes, repair tools, and
    carryable lights.
- `src/core/world/reference_instantiator.gd`
  - small non-carryable lights use a separate 60m light proximity gate.
  - NPCs and creatures use `max_actor_distance = 150.0`, not the same deferred
    interactive queue.
  - The light branch runs before model-object/carryable routing, so carryable
    light records do not currently reach `CarryableBodyFactory`.
- `src/core/interaction/morrowind/container_interactable.gd` and
  `src/core/interaction/morrowind/activator_interactable.gd`
  - Adapter classes exist, but current grep audit found no production spawn
    wiring equivalent to door attachment.
- `src/core/world/reference_instantiator.gd`
  - All `door` refs are proximity-gated, but only teleport doors
    (`ref.is_teleport`) get `DoorInteractable`.

Observed result:

- Doors can visibly pop close to the player.
- Containers, activators, carryables, and carryable lights are exposed to the
  same class of pop-in.
- Some deferred categories may currently be delayed visuals without fully wired
  gameplay interaction.
- The optimization is valid for expensive gameplay actors, but invalid for
  important visual silhouettes.

## Target Architecture

Introduce a split representation contract:

1. Source reference
   - Stable identity: cell/grid, ref id, ref num, model path, transform,
     type/category, adapter metadata.
   - Owns mutable state or can query the state layer.

2. Visual proxy
   - Cheap render-only representation.
   - Uses RenderingServer, `CellStaticBucket`, HLOD, impostor, or another
     render-only tier.
   - No scripts, no inventory, no interaction, no gameplay authority.
   - Can be hidden or punched out by source identity when a full actor is active
     or state says the object changed.

3. Gameplay actor
   - Full `Node3D` representation for interaction range.
   - Owns scripts, signals, physics, interaction Area3D, door transitions,
     inventory UI, carry physics, animations, and local state.
   - On spawn, suppresses the visual proxy for the same source reference.
   - On despawn, restores the visual proxy only if state allows it.

This keeps core framework code generic. Morrowind-specific record decisions
belong in an adapter/policy layer, not in `src/core/world/` string heuristics.

## Category Policy

Doors:

- Must have a distance visual representation. Doors are architectural entrance
  markers.
- Full `DoorInteractable` can remain near-only.
- Teleport metadata, lock/trap state, activation signal, and interaction Area3D
  belong only to the gameplay actor.
- Door visual proxy is valid only for closed/default visual state. Opened,
  disabled, swapped, or scripted doors must invalidate the proxy.

Containers:

- Closed static visual proxy is acceptable for barrels, crates, chests, sacks,
  and similar objects.
- Inventory, ownership, lock/trap, and open/looted state belong to the gameplay
  actor.
- If opened/looted state becomes visible later, proxy needs per-ref state
  invalidation or replacement.

Activators:

- Default to conservative opt-in.
- Some activators are visual static objects; others are scripted state surfaces.
- Adapter policy should classify "proxy-safe activator" versus "near-only
  activator."

Carryables:

- Small carryables may have distance visual proxies, but the proxy must be
  source-id backed.
- When picked up, moved, disabled, or physics-simulated, the proxy is invalid.
- Full rigid-body carryable stays near-only.

Lights:

- Separate the fixture mesh from the light source.
- Fixture mesh can be a visual proxy if not carryable/stateful.
- Real Omni/RS light remains near-range; distant glow remains
  `DistantLightManager`.
- Carryable lights follow carryable state invalidation.

NPCs and creatures:

- Not the same 25m bug.
- They are actor-gated at 150m. Before changing them, audit whether skipped
  actors are requeued/promoted correctly on approach.
- Future distant actor impostors are a separate feature, not part of the door
  fix.

## Implementation Plan

Phase 0: Document and measure

- Fix stale comments that say 80m when the code uses 25m.
- Add perf/debug counters for deferred entries by type:
  `door`, `container`, `activator`, `carryable`, `light`, `actor`.
- Audit and fix category wiring mismatches:
  - all doors gated, only teleport doors interactive;
  - container/activator adapters present but not spawned;
  - carryable lights intercepted by the light branch before carryable routing;
  - actors beyond 150m skipped rather than proximity-deferred.
- Add a visual pop smoke around a known door-heavy exterior cell.

Phase 1: Door-first threshold bridge

- Give doors a separate spawn threshold larger than generic interactives.
- Keep containers/activators/carryables at 25m.
- This is a time-boxed bridge, not the final architecture.
- Verify by launching `scenes/Godotwind.tscn` and approaching doors from
  outside the old 25m radius.

Phase 2: Source-id visual proxy registry

- Add a generic source identity key for visual/gameplay handoff.
- Track active visual proxies by source key.
- Track active gameplay actors by source key.
- Provide API:
  - `suppress_proxy(source_key)`
  - `restore_proxy_if_clean(source_key)`
  - `mark_proxy_dirty(source_key, reason)`
- Preferred hook points from the code audit:
  - `cell_manager.gd` classification/payload routing, where static,
    interactive, and light refs are already split;
  - `reference_instantiator.gd` as the authoritative per-type spawn router;
  - `cell_manager.gd::tick_proximity_deferred()` as the near promotion broker;
  - `interaction_shape_cache.gd` for reusable passive interaction bounds.

Phase 3: Door visual proxies

- Generate/render closed door meshes through a visual proxy path at MID range.
- Spawn full `DoorInteractable` only near the player.
- Suppress the door proxy while the full actor is alive.
- Add dirty-state hooks for opened/disabled/scripted doors.

Phase 4: Extend by category

- Containers next, because many are visually important and numerous.
- Activators only through an adapter allowlist.
- Carryables after state invalidation is proven.
- Lights only after fixture mesh and actual light source are clearly separated.

Phase 5: HLOD/FAR integration

- Let HLOD/object paging consume proxy-safe references.
- Keep exact-coverage and source-key invalidation as hard gates.
- Do not merge stateful objects into HLOD without a punch-out path.

## Non-Goals

- Do not spawn all interactive `Node3D`s at 500m.
- Do not route gameplay actors into `CellStaticBucket`.
- Do not hardcode Morrowind path/category strings in generic core systems.
- Do not hide the bug with a bigger single threshold as the final answer.
- Do not include activators/carryables in merged HLOD until state invalidation
  works.

## Acceptance Criteria

- A door visible at 80m does not pop into existence at 25m.
- Approaching a visible door produces one full `DoorInteractable`, not duplicate
  overlapping meshes.
- The visual proxy disappears or is hidden while the full actor is active.
- A dirty/moved/opened/picked-up object cannot reappear from a proxy batch.
- Perf counters show deferred gameplay actors separately from visual proxies.
- `dotnet build Godotwind.sln` is run if C# changes are introduced.
- `scenes/Godotwind.tscn` is launched interactively, or an automated smoke
  exercises the proxy-to-actor handoff.

## Decision

The current architecture is wrong for doors and other visible interactives
because it couples visibility to gameplay actor lifetime. The systematic fix is
not "spawn interactives earlier everywhere." The systematic fix is source-id
backed split representation: visual proxy first, full gameplay actor near,
state invalidation between them.
