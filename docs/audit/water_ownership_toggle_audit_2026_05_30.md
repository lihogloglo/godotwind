# Water Ownership and Toggle Audit - 2026-05-30

Status: current audit of the post-river water refactor. This document describes
what the main Godotwind scene does today, why the current behavior produces
overlapping water and stutter, and what the clean target architecture should be.

Scope: read-only source audit of the main scene water ownership paths, UI
toggles, generated river/lake publishing, and likely stutter sources. No code or
shader behavior was changed by this document.

## Executive Summary

The current main-scene water stack has split visual ownership and split runtime
ownership.

The `Ocean` toggle in the Godotwind UI controls the FFT ocean surface path, but
it does not control generated rivers, generated lakes, the hydrology provider,
registered water-body queries, or the `WaterWorld` process loop. That is why
turning off `Ocean` can still leave another water surface visible underneath.

The deeper architectural issue is that the water refactor introduced
`WaterSystem` and `WaterWorld`, but `OceanFFTProvider` still carries large
chunks of the previous `OceanManager` responsibilities. At the same time,
`world_explorer.gd` directly creates generated water render nodes. The result is
not one clean owner with layer toggles; it is several partial owners that happen
to meet in the main scene.

The clean direction is:

1. `WaterSystem` is the only public water autoload.
2. `WaterWorld` is the single runtime owner for water body registration,
   provider registration, body-type toggles, water queries, interaction state,
   body atlas state, and generated water render lifetime.
3. `OceanFFTProvider` becomes an ocean-only renderer and wave evaluator.
4. Main-scene UI and console commands call one owner-level water toggle API.
5. Generated rivers/lakes, ocean surface, gameplay water queries, interactions,
   underwater, spray, and wetness are independently toggleable without
   unregister/register churn or UI-side reach-arounds.

## What We Have At The Moment

### Scene Ownership

`scenes/Godotwind.tscn` does not contain authored water nodes. The main scene
uses `src/tools/world_explorer.gd`, and water is created at runtime.

Current water creators:

- `project.godot` autoloads `WaterSystem` from
  `src/core/water/water_system.gd` and `WetnessManager` from
  `src/core/water/wetness_manager.gd`.
- `WaterSystem` creates `WaterWorld` and `OceanFFTProvider`.
- `OceanFFTProvider` creates the visible ocean `OceanMesh`,
  `ShoreMaskGenerator`, FFT resources, sea spray, and some legacy/dormant
  interaction and water-body state.
- `WaterWorld` owns the active water body registry path, world-water provider,
  water interaction sim, underwater particles, body atlas, and query surface
  state.
- `WaterVolume`, `PolygonWaterVolume`, and `RiverWaterBody3D` create visible
  inland water surfaces and optionally register descriptors with `WaterSystem`.
- `world_explorer.gd` creates a `GeneratedWaterBodies` node and publishes
  Morrowind hydrology payloads as `RiverWaterBody3D` or `PolygonWaterVolume`
  nodes.
- `MorrowindHydrologyProvider` supplies the generated river/lake query data and
  render payloads.

Practical effect: there is no single render tree named "water" and no single
owner that can truthfully answer "show me only ocean" or "turn off every water
body."

### UI Toggle Behavior

The main UI is built at runtime by `ExplorerPanels._build_water_tab()` and wired
through `WorldExplorer._setup_visibility_toggles()`.

The visible water controls today are:

- `Ocean`
- underwater `Medium`
- underwater `Absorption Fog`
- underwater `Snell Window`
- underwater `Wobble`
- underwater `Caustics`
- underwater `Particles`
- `Surface SSR`
- `Sea Spray`
- quality/sliders/color controls

The `Ocean` toggle calls:

`ExplorerPanels` -> `OceanControls.on_show_ocean_toggled()` ->
`OceanControls.set_enabled()` -> `WaterSystem.set_enabled()` ->
`OceanFFTProvider.set_enabled()`

That path disables or releases the ocean provider runtime. It does not disable
all water.

Things left active or visible when `Ocean` is turned off:

- generated river/lake render nodes under `GeneratedWaterBodies`;
- the world hydrology provider;
- water provider async processing from `world_explorer.gd`;
- `WaterWorld` processing and physics processing;
- registered water-body query participation;
- registered `WaterVolume` / `RiverWaterBody3D` nodes unless individually
  hidden or freed;
- water interaction/body atlas systems when enabled elsewhere.

Practical effect: "Ocean off" means "FFT ocean off", not "all visible water
off." That mismatch is the user's visible bug.

### Runtime Duplication

The refactor has duplicated responsibility between `WaterWorld` and
`OceanFFTProvider`.

Both contain concepts for:

- water body registry;
- world-water provider registration;
- water body atlas state;
- water interaction sim plumbing;
- underwater particles;
- query/runtime status paths.

The active autoload path mostly routes generic water registry and query work
through `WaterWorld`, but `OceanFFTProvider` still carries old `OceanManager`
surface-area. This makes it hard to know which class owns a given state and
invites future patches to mutate the wrong owner.

Practical effect: the code can look modular while still behaving like two
overlapping water managers.

### Visual Overlap

Generated rivers and lakes are render-only scene nodes created by
`world_explorer.gd`. The global ocean mesh remains a broad sea-level surface.

CPU water queries can prefer registered/generated hydrology via `WaterWorld`,
but the visible ocean mesh is not currently suppressed under generated river or
lake surfaces. Visual ownership and query ownership are therefore not the same
contract.

Practical effect: local water and ocean can render at the same height or near
the same height, producing layered/overlapping water.

### Stutter Sources

The highest-risk stutter sources found in the audit are:

- `WaterWorld._rebuild_water_body_atlas()` rebuilds a `128x128` atlas
  synchronously after camera movement, samples the registry per pixel, updates
  an `ImageTexture`, and asks `RenderingServer` for the RD texture RID. With
  multiple rivers, this can become a large GDScript spike.
- `RiverWaterBody3D._ready()` immediately rebuilds the river surface. Generated
  water publication can therefore do mesh generation and ArrayMesh creation as
  scene-tree side effects.
- `RiverWaterBody3D._process()` and `WaterVolume._process()` push material time
  uniforms per water node every frame.
- `WaterInteractionSim` can dispatch compute while the atlas scrolls even when
  there are no new impulses.
- Generated inland water has no distance-tier policy comparable to the existing
  NEAR/MID/HLOD/FAR rendering architecture.

Practical effect: stutters are not surprising. The current architecture has
several unbudgeted main-thread and per-frame scaling paths.

## How It Should Be

### Ownership Model

The target architecture should have one public coordinator and one runtime owner:

- `WaterSystem`: public autoload facade. UI, console commands, gameplay systems,
  tests, and tools call this API.
- `WaterWorld`: runtime owner. Owns body registration, body providers,
  body-type toggle state, water queries, water interaction state, body atlas
  state, generated render lifetimes, and diagnostics.
- `OceanFFTProvider`: ocean-only renderer/evaluator. Owns FFT, ocean mesh,
  ocean material, ocean wave CPU queries, shore mask, spray hooks, and ocean
  render resources. It does not own generic water registries or generated water
  lifetime.
- `MorrowindHydrologyProvider`: adapter. Provides generic water descriptors and
  render payloads from Morrowind data. It does not decide global runtime policy.
- `WorldExplorer`: scene/tool shell. Builds UI and passes callbacks to
  `WaterSystem`. It does not directly own generated water body lifetime.

This keeps Morrowind-specific hydrology in the adapter layer and keeps generic
water runtime policy in `src/core/water/`.

### Toggle Model

Water toggles should be layer/state controls on `WaterSystem` or `WaterWorld`,
not ad hoc UI callbacks.

Recommended public shape:

```gdscript
enum WaterLayer {
	ALL,
	OCEAN_SURFACE,
	RIVERS,
	LAKES,
	POOLS,
	WATER_QUERIES,
	WATER_INTERACTIONS,
	UNDERWATER_MEDIUM,
	UNDERWATER_PARTICLES,
	SEA_SPRAY,
	WETNESS,
	DEBUG
}

func set_water_layer_enabled(layer: WaterLayer, enabled: bool) -> void
func is_water_layer_enabled(layer: WaterLayer) -> bool
func get_water_toggle_state() -> Dictionary
signal water_layer_enabled_changed(layer: WaterLayer, enabled: bool)
```

The main scene UI should expose at least:

- `All Water`
- `Ocean Surface`
- `Rivers`
- `Lakes/Pools`
- `Queries/Gameplay`
- `Interactions`
- `Underwater`
- `Spray`
- `Wetness`

These toggles should have clear semantics:

- `All Water = off`: no visible water, no water gameplay queries, no water
  interaction simulation, no underwater medium, no spray, no wetness.
- `Ocean Surface = off`: the FFT ocean surface is hidden/disabled, but rivers
  and lakes can remain visible if their toggles are on.
- `Rivers = off`: river render nodes are hidden and river query participation is
  disabled if query toggles require it.
- `Lakes/Pools = off`: still inland water render nodes are hidden and their
  query participation is disabled if query toggles require it.
- `Queries/Gameplay = off`: `WaterWorld.sample_*` behaves as dry/no-water for
  gameplay consumers.
- `Interactions = off`: ripple/wake/dynamic-flow simulation is paused and stops
  syncing textures.
- `Underwater`, `Spray`, and `Wetness` control only their own effects.

The toggles should be state gates, not destruction/recreation paths. Toggling a
layer should not cause water bodies to unregister and re-register unless the
body is actually unloaded by streaming.

### Render Ownership

All generated water render nodes should be owned by `WaterWorld` or a
`WaterWorld` child publisher, not by `world_explorer.gd`.

Recommended internal shape:

```text
WaterSystem
  WaterWorld
    GeneratedWaterBodies
      Rivers
      Lakes
      Pools
    WaterInteractionSim
    UnderwaterParticulates
  OceanFFTProvider
    OceanMesh
    OceanSpray
```

The important rule is that the same owner that knows body priority and body type
also owns visibility and lifetime of generated render nodes.

### Query Ownership

Queries should flow through `WaterWorld`:

1. Check layer toggles.
2. Check registered/generated body providers by priority and coverage.
3. Fall back to ocean only when the ocean layer and query layer are enabled.
4. Return one coherent `WaterSurfaceState`.

No generic gameplay code should query `OceanFFTProvider` directly for
non-ocean/body-dispatched behavior.

### Overlap Prevention

The renderer and query system need one shared body ownership contract.

If a generated river/lake covers a world position, the ocean surface should not
also visually own that pixel. There are two clean ways to do this:

1. Use the water body atlas/priority mask to suppress ocean pixels under higher
   priority local water.
2. Use distance/body-type render partitioning so local water and ocean never
   draw the same ownership region.

The first path is more direct for the current architecture, but it must be
budgeted and implemented as a render ownership mask, not as a UI-side hide
hack.

### Performance Budgeting

The water stack should follow the existing open-world rendering rules:

- generated river/lake publication must be frame-budgeted;
- atlas rebuilds must be amortized, cached, moved out of per-frame GDScript
  hot paths, or replaced with provider-side prebaked data;
- per-water-node `_process()` material writes should be eliminated or batched;
- generated inland water needs distance culling/tiering;
- interaction compute should be idle when there are no impulses and no visible
  active water that needs scrolling.

The target behavior is not "it works in one view." The target behavior is that
dense water cells stream without violating the frame budget.

## Implementation Order

1. Add `WaterSystem`/`WaterWorld` layer state and diagnostics.
2. Wire the UI to the new owner-level API while preserving existing controls.
3. Move generated water render root/lifetime behind `WaterWorld` or a
   `WaterWorld` child publisher.
4. Make `Ocean` and generated inland water independent visible layers.
5. Gate water queries and interaction simulation from the same layer state.
6. Remove or delegate duplicate registry/atlas/interaction ownership from
   `OceanFFTProvider`.
7. Add overlap prevention using the shared body ownership contract.
8. Profile atlas rebuilds, river publish time, material update counts, and
   interaction dispatch before expanding the feature set.

## Verification Requirements For The Fix

Because this is a gameplay/rendering/performance path, static inspection is not
enough when implementation begins.

Minimum verification for the implementation pass:

- run `dotnet build Godotwind.sln` if any C# changes are made;
- run relevant unit tests for water registry, river body, hydrology provider,
  subsystem toggles, and ocean controls;
- launch the main Godotwind scene interactively because the bug is visible in
  the main scene:

```powershell
<godot-executable> --path <project-path> scenes/Godotwind.tscn
```

Manual acceptance checks:

- `All Water` off shows no water surfaces and stops water-specific interaction
  work.
- `Ocean Surface` off hides only the ocean surface.
- `Rivers` off hides generated rivers while ocean/lakes can remain visible.
- `Lakes/Pools` off hides generated still inland water while ocean/rivers can
  remain visible.
- Ocean and generated local water do not visibly overlap at the same ownership
  region.
- Flying through loaded river/lake cells does not introduce obvious stutter.
- Runtime diagnostics show bounded atlas rebuild time, publish time, generated
  water node count, and interaction dispatch state.

Shader cache/import clearing is only required if `.glsl`, `.gdshader`, or
`.gdshaderinc` files change during the implementation pass.
