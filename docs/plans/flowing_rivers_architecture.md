# Flowing Rivers Architecture

**Status:** implementation plan and source-of-truth design, 2026-05-27.

Godotwind treats flowing rivers as a generic water-body capability, not as a
Morrowind special case and not as a runtime fluid simulation problem. The
production baseline follows the pattern used by modern open-world engines:
spline or polygon water bodies, generated surfaces, flow maps/vector fields,
shader-advection for normals and foam, and one gameplay query contract shared by
swimming, buoyancy, wetness, and underwater effects.

## Canonical Pattern

The reference model is the Unreal Water Body / Water Mesh architecture, Unity
HDRP water surfaces, Crest-style water data layers, and established VFX
flow-map practice. These systems do not simulate every river in the full open
world at runtime. They author or generate stable water body geometry, then drive
the surface with directional data that is cheap to stream, sample, and render.

Waterways.NET is a useful Godot reference for spline river authoring and mesh
generation, but Godotwind should not take a runtime dependency on it. The
framework needs source-provider injection, streaming-aware caches, and the
existing `WaterSurfaceState` query contract; a native implementation keeps those
boundaries clean.

Simulation remains valid for local effects, offline baking, or future specialist
tools, but it is not the baseline for open-world rivers. Jolt is the rigid-body
physics backend, not a replacement for a streamed hydrology/rendering layer.

## Framework Boundary

Core water code accepts only Godot-space water descriptions:

- body id and water type: ocean, lake, river, pool;
- priority and coverage query;
- height, normal, gradient, velocity, and water-body-id queries;
- optional flow/depth/coverage textures for rendering and tooling.

Source-specific records stay behind adapters. Morrowind LAND, CELL, WHGT,
coordinate conversion, and sea-level rules belong under the Morrowind world
source. A non-Morrowind game should be able to provide authored rivers, GIS
hydrology, or procedural water bodies without changing `src/core/water/`.

## Runtime Integration

`OceanManager` remains the existing autoload and compatibility facade. It owns a
`WaterBodyRegistry` rather than adding a new singleton. Ocean water is the
fallback provider; authored volumes and generated rivers register above it by
priority.

`WaterSurfaceState` remains the public sampling contract. Its callables answer
the combined water surface:

- authored `WaterVolume` / `PolygonWaterVolume` bodies first;
- source-provided water bodies such as generated rivers next;
- ocean coverage and waves as fallback.

That means player swimming, buoyancy bodies, wetness memory, waterline effects,
and underwater effects all sample the same surface state. Existing area signals
on water volumes remain for compatibility and broadphase events, but they are no
longer the authoritative gameplay water query.

## Morrowind Adapter Hydrology

Morrowind outdoor water is one sea-level plane, so visually "rivers" are really
terrain channels filled by the same global water level. The adapter still
generates flow for river-looking channels:

1. Sample source terrain heights for a streamed terrain region.
2. Build a sea-level water mask.
3. Segment connected water components.
4. Classify long/narrow components as river-like and leave wide bays/lakes with
   still-water coverage.
5. Extract centerline candidates from local distance-to-bank maxima.
6. Infer flow direction from endpoint bank heights, with a deterministic
   principal-axis fallback for perfectly flat source data.
7. Bake a versioned flowmap cache during terrain/cell streaming preparation:
   - `R/G`: Godot X/Z flow vector encoded from `[-1, 1]` to `[0, 1]`;
   - `B`: normalized flow speed;
   - `A`: water coverage.
8. Gameplay sampling is read-only. If a region has not been prepared, queries
   return no generated river data rather than baking synchronously in a physics
   or rendering path.

This creates flow for recognizable Morrowind rivers without authored assets,
while keeping the generated data generic once it leaves the adapter.

## Rendering Path

Near water bodies use generated meshes or authored volume meshes with flowmap
advection for normals, foam, and detail movement. Mid/far bodies reduce mesh
and material cost, following the existing world renderer's visibility and LOD
principles. River rendering must share water optical settings where practical
and obey Godot 4.6 screen/depth texture constraints documented in the ocean
rendering rules.

The first shipped implementation should make the query/data layer production
ready and keep existing water-volume visuals working. Dedicated river mesh
streaming can then consume the same descriptors rather than inventing another
river representation.

## Verification

Required checks for implementation:

- generic core boundary tests prove no source-specific water logic leaks into
  `src/core/water/`;
- registry tests prove priority and combined sampling;
- authored volume tests prove rectangular and polygon volumes expose descriptor
  coverage correctly;
- hydrology tests cover straight channels, branch-like channels, wide still
  water, ambiguous flat water, missing terrain retries, and terrain-image
  orientation;
- C# builds with `dotnet build Godotwind.sln`;
- visual launch uses an interactive scene and the main world path, with no
  automated screenshot harness.
