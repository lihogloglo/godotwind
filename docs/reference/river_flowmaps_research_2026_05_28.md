# River Flow Maps Research - 2026-05-28

This note summarizes a research pass on Godot Waterways, comparable river
flow-map implementations, and the broader industry pattern. It also compares
that pattern with the current Godotwind river work in this workspace.

## Executive Summary

The canonical game-engine solution for rivers is not full runtime fluid
simulation. The standard shape is authored or generated water-body geometry,
usually spline or polygon based, plus a sampled velocity field that drives
normal-map advection, foam, debris/detail motion, and gameplay current queries.
Runtime simulation is reserved for local interactions, selective high-end
effects, or offline bake tooling.

Godotwind is already aligned with that direction: it has a unified
`WaterBodyDescriptor` / `WaterBodyRegistry` / `WaterSurfaceState` contract,
native spline river mesh generation, vertex-color flow for authored rivers, and
a native Morrowind hydrology baker that outputs regional RGBA flow maps.
Generated river nodes now bind those flow maps into the river shader; the main
remaining gap is richer river graph continuity and auxiliary masks for
transitions, foam, pressure, and branch/confluence behavior.

## Godot Waterways

Original Waterways is a Godot 3.2 add-on by Arnklit/Kasper Frandsen. The Godot
Asset Library describes it as a tool that generates river meshes with flow and
foam maps from Bezier curves, including water/lava shaders and buoyant-object
support:

- Godot Asset Library: https://godotengine.org/asset-library/asset/805
- GitHub repository: https://github.com/Arnklit/Waterways

Its workflow is spline-first:

1. Add a River node.
2. Shape it with path controls.
3. Set width and material/bake parameters.
4. Use the River menu to generate flow and foam maps.
5. Optionally use a WaterSystem node to generate global height/flow maps for
   shader and buoyancy use.

Waterways' README says it was motivated by replacing hand-painted or
externally generated flow maps with flow maps generated directly inside Godot.
The same README documents a WaterSystem map path where shaders can sample a
global water map for height/flow effects. Its shader/data contract, from the
source and community notes, is roughly:

- flow map: RG = flow vector, B = foam, A = noise or auxiliary modulation;
- distance map: distance-to-bank and pressure-like data;
- shader flow strength modulated by base flow, slope/steepness, shore distance,
  and pressure;
- foam from baked foam masks plus shader-side shaping.

That makes Waterways valuable as an authoring and bake-pipeline reference. It
is less attractive as a direct dependency for Godotwind because it is Godot
3-era code, its renderer assumptions predate Godotwind's current ocean optics
stack, and it was not designed around Godotwind's streaming/world-source
adapter boundary.

## Waterways.NET

Waterways.NET is a Godot 4 / .NET 8 port:

- GitHub: https://github.com/tshmofen/waterways-net
- Asset mirror/docs: https://www.gadgetgodot.com/u/tshmofen/waterways-net-river-generation-tool-3d

The port is especially useful because it intentionally moves away from the
original bake-heavy path. Its README states that baking was removed because
flow baking often produced messy results, and that default curve-following flow
was more useful for the maintained Godot 4 version. It keeps the strong parts:
C# implementation, Bezier river mesh generation, width editing, flow settings,
and public water-height / flow-direction query methods.

Practical takeaway: for authored spline rivers, curve-derived flow is a strong
baseline. Flow-map baking is justified when it is driven by real source data,
terrain masks, obstacles, or artist paint, not as a mandatory step for every
river.

## Industry Pattern

Valve's Portal 2 / Left 4 Dead 2 flow-map presentation remains the cleanest
canonical reference:

- PDF: https://cdn.cloudflare.steamstatic.com/apps/valve/2010/siggraph2010_vlachos_waterflow.pdf
- Mirror: https://www.gamedevs.org/uploads/water-flow-in-portal2.pdf

Valve used low-resolution 2D vector textures for every point on the water
surface, generated with Houdini tools, then advected normal and color maps in
the shader. The goals were practical game goals: flow around obstacles, vary
speed and bump strength, hide repeating texture artifacts, and stay within
strict console-era performance limits. The important lesson for Godotwind is
the separation of concerns: flow data is authored/generated offline, while the
runtime shader performs cheap advection.

The standard shader pattern is well documented by Catlike Coding:

- Texture distortion / dual-phase advection:
  https://catlikecoding.com/unity/tutorials/flow/texture-distortion/
- Directional/tiled flow:
  https://catlikecoding.com/unity/tutorials/flow/directional-flow/

The common implementation is:

1. Store a signed 2D flow vector in RG, usually encoded from `[-1, 1]` to
   `[0, 1]`.
2. Sample tiled normal/detail textures.
3. Offset UVs by flow vector and phase time.
4. Reset periodically to avoid infinite stretching.
5. Blend two half-cycle phases to hide the reset.
6. Use noise, phase jumps, or cell offsets to reduce visible pulsing and tiling.
7. For readable calm water, align anisotropic ripple patterns to the local
   direction instead of only distorting isotropic noise.

Modern engines package the same idea into water-body systems. Unreal's Water
system uses spline-defined water bodies and a Water Zone mesh. Epic documents
river bodies as spline-based water that can connect lakes, oceans, and other
rivers, with river-specific material parameters such as velocity and flow
control:

- Water system overview:
  https://dev.epicgames.com/documentation/unreal-engine/water-system-in-unreal-engine
- Water meshing and surface rendering:
  https://dev.epicgames.com/documentation/unreal-engine/water-meshing-system-and-surface-rendering-in-unreal-engine

Unity HDRP exposes pool, river, and ocean/lake water surface types, with current
values contributing to water motion and river/ocean foam support:

- HDRP water capabilities:
  https://docs.unity.cn/Packages/com.unity.render-pipelines.high-definition%4016.0/manual/WaterSystem-Overview.html
- Unity HDRP water overview/blog:
  https://unity.com/blog/engine-platform/new-hdrp-water-system-in-2022-lts-and-2023-1

Crest is also relevant for shore handling: it uses depth/shore data to drive
shallow-water behavior, shoreline foam, and wave attenuation instead of relying
only on local fragment tricks:

- Crest shorelines and shallows:
  https://crest.readthedocs.io/en/4.21.3/user/shallows-and-shorelines.html

## Other Project Patterns

Public river tools converge on the same design:

- Unreal-style river tools use spline systems, update/generate mesh segments
  from spline points, support branching workflows, and expose vertex painting or
  maps for water warping and foam. Example: ShaderSource Branching River Tool
  docs: https://docs.shadersource.io/assets-and-plugins/branching-river-tool/how-to-use
- Unity HDRP sample/project practice commonly treats a current map as a texture
  where channels encode direction and speed, then layers decals, Shader Graph,
  and VFX Graph for visual richness rather than simulating all river motion.
- Lightweight shader examples, including Godot flow-map shaders, follow the
  same 0.5-neutral RG encoding and dual-layer advection pattern:
  https://godotassetlibrary.com/asset/6EdJ3t/flow-map-shader

The practical split is:

- authored curves: use spline tangent/width/depth/velocity as the reliable
  source of truth;
- generated terrain rivers: bake regional flow/coverage maps from terrain or
  source masks;
- visual turbulence: add bank distance, pressure/constriction, slope, obstacle,
  and foam masks as auxiliary data;
- gameplay: query the same body registry/velocity field rather than reading
  render-only material state.

## Godotwind Current State

The current workspace already contains a rivers plan and uncommitted river
implementation. This comparison reflects that working tree, not only committed
mainline code.

Strong alignment:

- `docs/plans/flowing_rivers_architecture.md` already states the right
  architectural target: generic water bodies, generated surfaces, flow
  maps/vector fields, shader advection, and one gameplay query contract.
- `src/core/water/water_body_descriptor.gd` exposes coverage, height, normal,
  gradient, velocity, water-body-id queries, plus texture/metadata fields.
- `src/core/water/water_body_registry.gd` chooses the active water source by
  priority/coverage and provides unified sampling for height, normal, gradient,
  velocity, and body id.
- `src/core/water/water_surface_state.gd` is the right runtime-facing contract
  for swimming, buoyancy, wetness, underwater effects, waterline, and renderer
  consumers.
- `src/native/NativeRiverMeshBuilder.cs` generates a curved river ribbon mesh
  from Godot-space `Curve3D` data and encodes flow direction in vertex color
  RG, bank distance in B, and foam in A.
- `src/core/water/river_water_body.gd` wraps a source-owned river node around a
  curve, widths, flow speed, generated mesh, material, and descriptor queries.
- `src/core/water/shaders/river_surface.gdshader` already implements
  dual-phase `flow_uvw()` advection, bank pressure, bank foam, streak foam, and
  water interaction ripples.
- `src/native/NativeRiverFlowBaker.cs` bakes an RGBA8 flow map where RG is
  direction, B is normalized speed, and A is water coverage.
- `src/core/world/morrowind/morrowind_hydrology_provider.gd` keeps Morrowind
  terrain/sea-level interpretation in the adapter layer, prepares/caches
  regional flow maps, exposes gameplay sampling, and produces generic renderable
  river payloads.

Main gaps:

- Generated river render nodes consume `flowmap_image` / `flowmap_region_bounds`,
  but the broader generated-river path still needs river-graph continuity,
  branch/confluence treatment, and transition material zones.
- The rendered river surface now uses both curve-following flow and sampled
  velocity-field flow; future work should add richer authored/baked auxiliary
  masks rather than overloading the base RGBA flowmap.
- The baked hydrology map carries direction, speed, and coverage, but no
  separate depth, bank distance, pressure/constriction, slope, turbulence, foam,
  or body-id atlas layer yet.
- Foam is currently mostly bank-derived, streak/noise-derived, or interaction
  driven. It is not yet derived from a source/baked foam field, obstacle field,
  confluence model, or slope/depth turbulence model.
- Generated centerlines are extracted from distance-to-bank maxima, but there is
  no mature branching/confluence treatment or transition material path for
  river-to-lake/ocean blending.
- Debug tooling is still early: there is no production flow-vector view,
  coverage/speed/channel inspector, current-map preview, per-region cache view,
  or spline width/depth/velocity authoring UI.

## Recommended Direction

Keep the current architecture. It is the right industry shape for Godotwind:
source adapters produce generic Godot-space water data; core water systems own
sampling/render contracts; renderers consume water bodies through a shared
surface state instead of knowing about Morrowind formats.

The next production step should be to make flow maps first-class in
`RiverWaterBody3D` rendering:

1. Keep `RiverWaterBody3D` flowmap texture/bounds inputs as the production
   river velocity override contract.
2. Keep generated river nodes binding the Morrowind payload's `flowmap_image` /
   `flowmap_region_bounds`.
3. In `river_surface.gdshader`, sample world/region UVs to get per-pixel flow
   direction, speed, and coverage.
4. Fall back to vertex-color tangent flow when no flowmap is present.
5. Preserve the existing dual-phase advection path, but drive normals, foam
   streaks, and optional debris/detail motion from sampled flow.
6. Keep channel ownership stable: `RG = signed flow`, `B = normalized speed`,
   `A = coverage`. Put foam/depth/pressure/bank distance in separate textures or
   atlas layers instead of overloading alpha.
7. Add debug views before adding complexity: direction, speed, coverage, bank
   distance, foam, and final advection vector.

For authored rivers, do not force baking. Spline tangent plus per-point
width/depth/velocity is the simplest and most robust baseline. Optional painted
or baked overrides can come later for special features.

For generated Morrowind rivers, baked maps are justified because the source data
is terrain/sea-level coverage, not authored curves. The current adapter boundary
is correct: Morrowind-specific classification stays in
`src/core/world/morrowind/`, while `src/core/water/` only sees generic water
descriptors, flow maps, coverage, and velocity.

## Practical Effect For Godotwind

The current implementation is not a wrong turn. It is a good first half of the
canonical solution: the registry/query layer, C# mesh builder, C# flow baker,
and river shader already match the standard pattern. What remains is to connect
the generated flow field to the visual river material and enrich the auxiliary
maps needed for believable bank turbulence, foam, joins, and debug authoring.

That means the correct follow-up is not "port Waterways." It is "borrow the
useful Waterways authoring/debug ideas, keep Godotwind's architecture, and make
our existing flowmap data actually drive rendering."
