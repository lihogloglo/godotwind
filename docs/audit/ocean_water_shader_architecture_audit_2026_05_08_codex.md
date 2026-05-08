# Ocean Water Shader Architecture Audit

Date: 2026-05-08
Owner: Codex
Status: read-only architecture audit; no files edited during audit

Related docs:

- `docs/plans/ocean_quality_tracker_2026_05_07.md`
- `docs/audit/ocean_option_c_render_order_2026_05_07_codex.md`
- `docs/plans/wetness_system.md`

Related commits:

- `e13ee7de28efcfc8efbd815a53639f181d3c3f88` - older refraction pass that looked clearer but was not a robust architecture.
- `34346d3b29f54e52e704f1f2b0d22e5ea2e482c6` - made surface refraction/visibility more transparent and introduced new visual instability.

## Summary

The current ocean stack is mixing two different architectures:

1. An opaque FFT ocean surface, which is the stable architecture for open-world
   water in this project.
2. A screen-reading transparent/refraction surface path, which is useful for
   experiments but is fighting Godot's 3D render order and the Option C plan.

The correct direction is still Option C:

- Keep the FFT ocean surface opaque.
- Let the surface own waves, normals, foam, spray, Fresnel, reflection, surface
  color, Beer-Lambert tint, and wave-tip translucency.
- Move submerged-object distortion, waterline, underwater fog, underwater
  wobble, caustics, light rays, particles, and half-underwater camera effects
  into a compositor/pre-water-buffer path.
- Drive wetness, buoyancy, waterline, underwater classification, and spray from
  one canonical water-surface contract instead of several copied shader
  formulas.

The practical player-facing failures come from that split:

- Wetness is not water contact. It is mostly a flat sea-level band plus partial
  shore-wave logic, so it does not follow larger FFT/weather waves.
- Landscape wetness can leak far beyond the beach because terrain wetness lacks
  a reliable signed shore/water coverage mask and has unsafe fallback behavior.
- Refraction is broken because the production ocean surface is trying to do
  screen-space refraction in a pass where Godot cannot provide the data this
  effect needs robustly.
- Underwater and waterline effects are unfinished because the compositor path is
  still prototype/lab scaffolding rather than the production owner.

## Godot 4.6 Constraints

These are the engine constraints that matter most:

- Godot's 3D screen texture is copied after opaque geometry and before
  transparent geometry.
- Spatial shaders that write `ALPHA` enter the transparent pipeline.
- Screen-reading spatial materials are themselves transparent and cannot see
  later transparent objects behind them.
- Godot's native material refraction is screen-space and inherits those
  ordering and visibility limits.
- `CompositorEffect` is the intended hook for full-screen render pipeline
  effects in Forward+.
- `RenderingDevice.texture_get_data()` is a blocking readback. Godot 4.6 offers
  async texture readback for paths that must read GPU texture data.

References:

- https://docs.godotengine.org/en/4.6/tutorials/shaders/screen-reading_shaders.html
- https://docs.godotengine.org/en/4.6/tutorials/shaders/shader_reference/spatial_shader.html
- https://docs.godotengine.org/en/4.6/classes/class_compositoreffect.html
- https://docs.godotengine.org/en/4.6/classes/class_renderingdevice.html
- https://docs.godotengine.org/en/4.6/classes/class_rigidbody3d.html

## Desired Production Architecture

### 1. Opaque FFT Ocean Surface

The ocean surface should stay opaque and be responsible for surface water only:

- FFT/projected or clipmap displacement.
- Wave normals/gradients.
- Jacobian foam and shore intersection foam.
- Spray spawn masks.
- Fresnel reflection.
- SSR/probe/sky fallback reflection.
- Beer-Lambert surface tint.
- Wave-tip translucency / SSS approximation.

The production surface should not own:

- Submerged-object refraction.
- Half-underwater camera waterline.
- Underwater fog.
- Underwater wobble.
- Underwater particles.
- Object/terrain wetness memory.

Those belong in water interaction state and compositor passes.

### 2. Shared Water-Surface Contract

Every water-adjacent system needs one shared definition of the water surface:

```text
dynamic_water_height =
  sea_level
  + FFT displacement * wave_scale * shore_dampening
  + analytical shore swash/runup
```

The contract should also expose:

- water normal / gradient;
- horizontal displacement or inverse-horizontal query where needed;
- water velocity;
- foam / breaking signal;
- water coverage or water body id;
- signed shore distance on both land and water sides;
- beach/runup eligibility;
- optional min/max water envelope for cheap wetness and culling.

Consumers:

- ocean surface shader;
- terrain wetness;
- object wetness;
- waterline compositor;
- underwater compositor;
- buoyancy;
- spray;
- visual debug tools.

The current code has multiple partial copies of this logic. That divergence is
now a major source of bugs.

### 3. Waterline / Underwater Compositor

The production owner for waterline and underwater effects should be a
`CompositorEffect` path, fed by a pre-water source buffer where needed.

Responsibilities:

- Distort/tint submerged opaque objects.
- Draw the moving half-underwater camera line.
- Apply underwater fog and absorption.
- Apply underwater wobble.
- Apply caustics, masked by surface/scene normals where possible.
- Add low-resolution light rays.
- Support particles or volume sprites for floating underwater matter.

The current `UnderwaterVolume` remains useful as a diagnostic and temporary
below-camera effect, but it should not be the production owner for
half-submerged objects while the opaque ocean mesh is visible.

### 4. Wetness System

Wetness should be driven by actual water contact and water memory, not flat
global height.

Wetness should not be primarily screen-space. The authoritative state should be
world/object state:

- terrain receives wetness from terrain/water contact maps and renders it in
  the terrain material;
- carryable objects receive wetness uniforms or material-overlay state such as
  `wet_amount`, `wet_line_y`, `last_contact_time`, and decay;
- characters and creatures receive wetness through their material groups or
  masks;
- a screen-space pass can add extra rain sheen or broad visible glints, but it
  should not decide what is wet.

The reason to keep wetness as object/material state is memory and material
identity. If an NPC, crate, or rock sits in surf while the camera looks away,
it should still appear wet when visible again. A screen-space-only pass can
shade only visible pixels and cannot be the source of truth for drying, carried
items, material-specific roughness/specular response, or persistent high-water
marks.

Production wetness should use:

- signed shoreline/water coverage data;
- dynamic surface height or dynamic water envelope;
- slope/material gating;
- wetness memory/decay;
- object high-water marks driven by the same dynamic water contract;
- Lagarde-style PBR wet material response: darker diffuse, lower roughness,
  stronger specular, puddle/film where applicable.

Terrain wetness can remain in the terrain shader for cheap ground response, but
the state feeding it should come from a proper `WetnessManager` or water-state
service, not `HorizonMapManager` guessing from a partial mask.

## Findings

### Critical: Wetness Does Not Follow The Visual Water

Current terrain wetness uses flat sea-level data plus analytical shore-wave
uniforms in `src/core/world/terrain_horizon.gdshader`.

The visible ocean surface uses FFT displacement, `wave_scale`, shore dampening,
and shore wave/runup logic in:

- `src/core/water/shaders/ocean_fft.gdshader`
- `src/core/water/shaders/ocean_fft_projected.gdshader`
- `src/core/water/shaders/ocean_fft_common.gdshaderinc`

Because terrain wetness does not sample the same surface, larger weather waves
can visually reach higher up the shore while the wetness remains at the old
height.

Practical effect: waves and wetness visibly disagree.

Required fix: wetness must consume the canonical dynamic water height/envelope,
not a separate flat sea-level approximation.

### Critical: Wetness Can Leak Across The Landscape

The mountain/whole-landscape wetness bug has a concrete cause:

- `src/core/water/shore_mask_generator.gd` encodes land pixels without a robust
  signed land-side distance.
- `src/core/world/terrain_horizon.gdshader` tries to recover land distance by
  searching from partial shore-mask data.
- The no-direction/fallback path can still return a distance that falls inside
  the wet footprint width.
- The footprint branch lacks a strong height/slope/water-coverage gate.
- Static wetness still uses a broad world-height band:
  `sea_level_wet` to `sea_level_wet + wet_margin`.

Practical effect: terrain that was never touched by surf can be treated as wet.
This does not require a mountain peak to be literally below sea level. The
problem is that the current classification is not strict water contact:
low-lying terrain can be hit by the broad height band, and other terrain can be
hit by unsafe shore-mask fallback/footprint logic if it is not gated by shore
coverage, dynamic water height, and slope.

Required fix: do not patch this with more terrain-fragment search. Replace the
mask contract with signed shore/water coverage data.

Short-term containment:

- Make the no-direction fallback return "not wet."
- Gate footprint wetness by dynamic water height plus a small margin.
- Gate shore wetness by water coverage/shore eligibility.
- Consider disabling `shore_wave_wetness_enabled` outside Ocean Lab until the
  mask contract is fixed.

### Critical: Surface Refraction Is Fighting Godot Render Order

`src/core/water/shaders/ocean_fft_common.gdshaderinc` declares screen/depth
textures and performs screen-space refraction in the ocean surface material.

This is fragile in Godot 4.6 because:

- the ocean should be opaque for depth authority and stable large-water
  rendering;
- screen-reading 3D materials are transparent;
- the 3D screen texture is captured once, after opaque and before transparent;
- this path cannot robustly own submerged-object distortion, half-camera
  waterlines, or transparent interactions.

Commit `34346d3b29f54e52e704f1f2b0d22e5ea2e482c6` made this worse by turning
surface refraction default-on and allowing the disabled/invalid path to sample
raw screen color. That makes the water behave like accidental transparency.

Commit `e13ee7de28efcfc8efbd815a53639f181d3c3f88` looked better because it bent
the screen more aggressively and rejected fewer samples. That produced a more
visible refraction effect, but it was not a robust general solution.

Required fix:

- Production default should be `surface_refraction_enabled = false`.
- When disabled or invalid, the surface should use water color/tint, not raw
  `SCREEN_TEXTURE`.
- Keep screen-space surface refraction only as an Ocean Lab diagnostic or
  high-risk experimental quality mode.
- Move production submerged-object bending to the pre-water/compositor path.

### Critical: FFT Spectrum Format Mismatch

`src/core/water/wave_generator.gd` allocates the `spectrum` texture as
`R32G32B32A32_SFLOAT`, while these compute shaders declare the image as
`rgba16f`:

- `src/core/water/shaders/compute/spectrum_compute.glsl`
- `src/core/water/shaders/compute/spectrum_modulate.glsl`

Required fix: align the RenderingDevice texture format and GLSL image layout.
Use either `rgba16f` everywhere or `rgba32f` everywhere, intentionally.

### Critical: Buoyancy Readback Can Stall The GPU

`src/core/water/ocean_manager.gd` reads every cascade every process frame, and
`src/core/water/wave_generator.gd` uses blocking `texture_get_data()`.

Practical effect: buoyancy can create GPU/CPU sync stalls and undermine open
world frame pacing.

Required fix options:

- Use `texture_get_data_async()`.
- Lower readback cadence.
- Read back smaller regions.
- Use a CPU-side water evaluator for buoyancy.
- Track completed frame ids/cascade masks so consumers know data freshness.

### High: Water Height Logic Is Duplicated And Divergent

Different systems compute water height differently:

- Surface shaders apply cascade fade, `wave_scale`, shore dampening, and shore
  runup.
- CPU buoyancy samples cached displacement but omits several visual modifiers.
- `underwater_volume.gdshader` has another copy.
- `waterline_probe.glsl` has a more complete inverse-horizontal version.
- Terrain wetness samples only flat sea level plus shore wave uniforms.

Practical effect: water, wetness, buoyancy, underwater slab masks, and
waterline effects disagree.

Required fix: create one authoritative water-surface provider and generate or
share the shader logic/constants from that provider.

### High: Main Scene Wetness Sync Is Incomplete

The per-frame surf/wetness sync exists in Ocean Lab, but main runtime wetness is
still mostly driven by `push_wet_map()` from `world_explorer.gd`.

Practical effect: the lab can look closer to correct than the real main scene.

Required fix: production scene wiring must push the same dynamic shore/water
state used by Ocean Lab, or better, move that state into a manager/service that
both scenes consume.

### High: Object Wetness Is Flat-Water Only

`src/core/shaders/object_wet.gdshader` supports a wet line, but the visual tests
drive that line from flat `_sea_level`, not the dynamic wave/surf surface.

Practical effect: objects can be visibly hit by larger waves while their wet
line remains too low.

Required fix: update object wet lines from the canonical dynamic water height
or a high-water memory value derived from it.

### High: UnderwaterVolume Is Not The Production Waterline Owner

`src/core/water/shaders/underwater_volume.gdshader` is a transparent
screen/depth-reading spatial pass. It can be useful for underwater-camera tint,
fog, caustics, and diagnostics, but it cannot reliably own above-water
half-submerged-object distortion behind the opaque ocean surface.

Required fix: promote the pre-water-buffer plus `PRE_TRANSPARENT` compositor
architecture. Keep `UnderwaterVolume` as a temporary/diagnostic path until the
compositor replaces it.

### High: Water Classification Needs Coverage, Not Height Alone

The current underwater/waterline paths classify pixels by reconstructed height
against the global dynamic ocean surface.

That is not general-purpose water logic. It can affect any visible geometry
below a global water height, even if that geometry is not inside this water
body.

Required fix: add water coverage/body information:

- coverage mask;
- water body id;
- signed shore distance;
- water depth buffer;
- or another explicit body/coverage contract.

### High: Half-Underwater Camera Is Not Architecturally Present

The current implementation has below-camera underwater behavior and slab-style
pixel classification, but it does not compute the moving near-plane waterline
for a half-submerged camera.

Required fix:

- In the compositor, compute per-pixel camera rays.
- Intersect those rays with the dynamic water surface or a water-surface
  approximation.
- Use that intersection to split above-water and underwater shading.
- Draw a meniscus/waterline band with foam, distortion, and temporal smoothing.

### High: Prewater Capture Is Correct But Still Lab Scaffolding

Ocean Lab renders a second SubViewport without the water layer and copies it
for the waterline compositor prototype.

This is the right workaround family, but production needs:

- resolution scaling;
- enable only near/under water;
- per-view buffers;
- explicit render-order/latency rules;
- performance toggles;
- benchmark coverage.

### High: Projected Grid Needs Separate Acceptance Tests

`src/core/water/shaders/ocean_fft_projected.gdshader` intersects a flat
`sea_level` plane before displacement, then applies waves afterward. It also
uses a very large AABB/cull margin.

This is risky near the camera, at the horizon, and for half-submerged views.

Required fix: treat projected grid as a separate renderer path with its own
visual/performance acceptance tests. Keep clipmap as the stable default until
projected-grid clipping and depth contracts are proven.

### Medium: Waterline Compute Is Too Expensive For Full-Screen Production

`src/core/shaders/compute/waterline_probe.glsl` recomputes FFT/shore water
height and normal data repeatedly per pixel.

Required fix options:

- Promote a cheaper water height/coverage/normal buffer.
- Run the expensive classifier only in debug.
- Run at half resolution.
- Tile or mask the pass near waterline regions.

### Medium: Underwater Effects Are Still Incomplete

Current underwater shading has absorption, wobble, and caustics, but lacks the
full target look:

- underwater fog / backscatter;
- underwater light rays;
- floating particles;
- richer depth tint;
- half-submerged camera transition.

The Rafael `DIVE` reference in `inspos/RafaelsShaderPack/Shaders/DIVE.omwfx`
contains useful references for noisy fog, phytoplankton, shell rays,
backscatter, caustics, and dithering.

Recommended implementation order:

1. Fog/absorption/backscatter in compositor.
2. Wobble/refraction in compositor.
3. Normal-aware caustics.
4. Low-res light rays.
5. GPU particles or volume sprites for suspended matter.

### Medium: Caustics Need Normal Masking

Current caustics are mostly luma/travel masked, not scene-normal aware.

Required fix:

- Request Godot's normal/roughness buffer in the compositor if available for
  the target render path.
- Otherwise reconstruct normals from depth.
- Mask caustics by surface orientation and water depth.

### Medium: Sampler Contracts Are Implicit

Several shaders do not make repeat/filter/mipmap behavior explicit:

- FFT displacement/normal textures in `ocean_fft_common.gdshaderinc`;
- spray sampling in `ocean_spray_particles.gdshader`;
- underwater depth sampling in `underwater_volume.gdshader`;
- legacy compositor samplers.

Required fix: make sampler hints explicit everywhere. Depth should generally be
nearest. Periodic FFT maps should declare intentional repeat/filter behavior.

### Medium: The "Normals" Texture Is Not Actually A Normal Texture

`src/core/water/shaders/compute/fft_unpack.glsl` stores gradient/foam data in
the texture currently named/declared as `normals`.

Required fix:

- Rename/document this as gradient/foam data, for example
  `wave_gradient_foam`.
- Remove misleading `hint_normal` if it is not a normal map.

### Medium: Spray Needs A Performance And Signal Audit

Spray visually works okay, but high quality can spawn thousands of GPU
particles, and each particle samples all cascades.

The current `normal_mask` appears to favor flatter water instead of steep
crests. Foam or gradient magnitude may be a better spawn signal.

Required fix:

- Benchmark spray quality levels.
- Drive spawn from foam/gradient/breaking signal.
- Keep quality toggles and density tied to weather/wind.

### Medium: Buoyancy Force Uses Delta With apply_force

`src/core/water/buoyancy_body.gd` multiplies force vectors by `delta` before
calling `apply_force()`.

Godot's `RigidBody3D.apply_force()` applies a time-dependent force during the
physics update. Multiplying by `delta` can under-apply forces.

Required fix: remove the extra `delta` factor unless a local test proves a
different integration contract.

### Low: Diagnostic Artifacts Are In Production Paths

Examples:

- `WaterlineCompositorEffect` is still labelled a probe/prototype.
- It prints directly from `src/core`.
- `waterline_probe.glsl` draws a magenta corner marker.

Required fix: gate diagnostics behind debug uniforms or remove them from the
production path.

## Staged Fix Plan

### Phase A: Stabilize Current Visuals

Goal: stop the newest visual bugs before deeper architecture work.

Tasks:

- Set production `surface_refraction_enabled` default to `false`.
- When surface refraction is disabled or invalid, use water color/tint instead
  of raw `SCREEN_TEXTURE`.
- Keep surface refraction only as an Ocean Lab diagnostic toggle.
- Remove or debug-gate magenta markers and direct prints.
- Fix the FFT spectrum texture format mismatch.
- Make sampler hints explicit in touched shaders.
- Contain wetness leak:
  - no-direction shore fallback returns not wet;
  - wet footprint is height-gated against dynamic water height;
  - wetness is shore/coverage-gated;
  - broad static height wetness is disabled or restricted to actual water
    coverage.

Verification:

- Clear relevant shader/import cache after shader edits.
- Launch Ocean Lab interactively.
- Check large-wave weather, beach runup, distant terrain, cliffs/mountains,
  half-submerged objects, and refraction toggles.

### Phase B: Canonical Water State

Goal: make every system agree on where the water is.

Tasks:

- Add a shared water-surface provider/contract.
- Centralize sea level, wave scale, cascade scales, shore dampening, shore
  swash, water coverage, and water envelope.
- Generate/share shader include code or constants where possible.
- Add explicit freshness/cascade-completion state for GPU data.
- Move object wet lines and buoyancy queries to the shared surface contract.

Verification:

- Visual debug mode that draws canonical water height against surface waves.
- Buoyancy probes match visible crest/trough movement.
- Terrain/object wetness follows weather-scaled waves.

### Phase C: Signed Shore And Wetness Data

Goal: replace shader-side shoreline guessing.

Tasks:

- Replace the current shore mask with a signed shore SDF/depth cache:
  - land-side distance;
  - water-side distance;
  - shoreline gradient;
  - water coverage;
  - runup eligibility;
  - optional slope/material information.
- Add wetness memory/decay state.
- Move wetness ownership out of `HorizonMapManager` toward a dedicated
  `WetnessManager` or water-state service.

Verification:

- Wetness appears only where water can plausibly contact terrain.
- Wetness follows changing weather/wave scale.
- Mountains and inland terrain remain dry.

### Phase D: Production Waterline Compositor

Goal: make Option C the actual production path.

Tasks:

- Promote pre-water capture from lab scaffold to production component.
- Add resolution scale and near-water enabling.
- Add water coverage/body mask.
- Implement submerged-object refraction/tint in compositor.
- Implement half-underwater camera waterline via per-pixel ray/water
  intersection.
- Port useful absorption/wobble/caustic logic from `UnderwaterVolume`.

Verification:

- Half-submerged objects distort/tint correctly with the opaque ocean visible.
- Half-underwater camera shows a moving waterline.
- Disabling the ocean mesh is no longer required to see submerged-object
  effects.

### Phase E: Underwater Atmosphere And Polish

Goal: reach the Rafael-reference feature set without blowing the frame budget.

Tasks:

- Add underwater fog/backscatter.
- Add underwater wobble in compositor.
- Add normal-aware caustics.
- Add low-resolution light rays.
- Add floating particles or volume sprites.
- Add debug/perf toggles for each effect.

Verification:

- Underwater view has depth, haze, movement, and particles.
- Effects scale with weather/time of day where appropriate.
- Feature toggles expose clear GPU cost.

### Phase F: Performance Hardening

Goal: make the ocean viable in the open-world runtime.

Tasks:

- Replace blocking GPU readback with async/readback cadence/CPU evaluator.
- Benchmark spray quality levels.
- Benchmark waterline compositor at full/half/quarter res.
- Track GPU and CPU cost per feature toggle.
- Add crash/perf smoke coverage for mesh mode, weather changes, and underwater
  transitions.

Verification:

- `scenes/Godotwind.tscn` launches interactively after shader cache clear when
  shader files change.
- Ocean Lab has a repeatable perf matrix.
- Main scene frame pacing does not regress from water readback/compositor work.

## Non-Goals

- Do not make the main ocean surface transparent as the production solution.
- Do not keep adding silhouette guards to `ocean_fft_common.gdshaderinc` to
  solve half-submerged-object refraction.
- Do not rely on `UnderwaterVolume` as the final owner for above-water
  submerged-object distortion.
- Do not patch mountain wetness with more per-fragment shoreline search.
- Do not hand-roll separate water height formulas in each shader.

## Verification Status

This audit was read-only. No files were edited during the audit pass, no shader
cache/import artifacts were cleared, and no Godot scene was launched.

Any implementation follow-up that touches `.glsl`, `.gdshader`, or
`.gdshaderinc` must clear the relevant shader/import cache before visual
verification, then launch an interactive scene according to the project
verification rule.
