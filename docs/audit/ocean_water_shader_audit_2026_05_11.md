# Ocean Water Shader Audit - 2026-05-11

## Executive Verdict

The current FFT ocean surface is broadly pointed in the right direction for Godot 4.6. The best part of the system is the decision to keep the main ocean surface opaque, feed it FFT displacement/normal textures, and move screen-color bending, waterline splitting, and underwater effects into a post-transparent compositor. That matches Godot's renderer constraints better than a transparent `SCREEN_TEXTURE` water material.

Do not restart the ocean surface from zero. Keep the opaque FFT surface, `WaterSurfaceState`, projected-grid option, shore mask contract, CPU wave-query concept, and force-at-point buoyancy.

Do restart the inland/local water architecture. `WaterVolume` is a separate transparent screen-texture shader path, has its own buoyancy model, is not connected to `WaterSurfaceState`, and still uses stale Godot 3 style `SCREEN_TEXTURE` / `DEPTH_TEXTURE` names in its inline shader. It should not become the basis for lakes, puddles, rivers, or multi-elevation water.

The biggest gap is not a missing shader trick. It is that the production game currently has an ocean surface, while the full water system lives mostly in Ocean Lab. Underwater Snell window, rays, particles, wobble, caustics, receiver refraction, prewater capture, and wetness compositing exist as lab paths, but they are not yet integrated as the production water stack in `scenes/Godotwind.tscn`.

## Scope

This audit used:

- Actual repo code and shader inspection.
- Three read-only subagents: code architecture, Ocean Lab/perf hooks, and external Godot/industry research.
- Current Godot 4.6 documentation and industry references, not project docs as authority.
- Existing automated smokes and the main-scene perf sweep.

I did not change shaders, C# code, or gameplay code. This document is the only repo edit from this audit pass.

## External Research Baseline

### Godot 4.6 constraints

Godot 4.6 Forward+ is the correct target renderer for this water ambition. Forward+ is where SSR, SDFGI, volumetric fog, CompositorEffects, and the fullest post-processing stack live. Godot's renderer feature matrix shows SSR, SDFGI, volumetric fog, TAA/FSR2, and custom post-processing with `CompositorEffect` as Forward+ features.

Godot screen-reading shaders are a trap for production 3D water. The current docs require explicit uniforms such as `hint_screen_texture` and `hint_depth_texture`. In 3D, materials using `hint_screen_texture` are considered transparent-like and do not appear in other screen textures. Godot's spatial shader docs also say that reading or writing `ALPHA` moves the material into the transparent pipeline, with sorting risks. For a large water plane that must reflect terrain/sky/objects and work with depth, this strongly supports the current opaque-ocean-plus-compositor strategy.

Godot's advanced post-processing docs reconstruct view/world position from depth using `INV_PROJECTION_MATRIX` and `INV_VIEW_MATRIX`. The current ocean surface shader does not follow that pattern everywhere; this is one of the concrete fixes recommended below.

Godot's `RenderingDevice.texture_get_data()` is documented as blocking the GPU until the data is retrieved; `texture_get_data_async()` exists for a more performant path. The current GPU wave readback mode is correctly disabled by default.

### Industry water pattern

The standard architecture in modern engines is a unified water-body system, not separate ad hoc shaders per water use case.

Unreal's Water System is organized around water bodies for oceans, lakes, rivers, and custom water. Those bodies share a meshing/shading pipeline, provide underwater post-processing, contain depth/flow information, and expose gameplay queries for physics interaction.

Unity HDRP's Water System similarly supports multiple water surfaces simultaneously, with Pool, River, and Ocean/Sea/Lake types. It exposes underwater rendering, wind/current, foam, caustics, material properties, masking, and scripting hooks for gameplay such as buoyancy.

For simulation, the standard split is:

- Open ocean: spectral/FFT wave simulation, multi-scale displacement and normals.
- Shoreline and near-field waves: Gerstner/sum-of-sines style waves, shore masks, dampening, swash, foam, and eventually breaking-wave approximations.
- Rivers: spline or flowmap driven surface motion, current velocity, and transitions into lakes/ocean.
- Gameplay physics: deterministic CPU-side queries for height, normal, velocity, depth, and body identity; do not rely on blocking GPU readback.
- Underwater: full-screen/post or volume-driven effects using surface state, depth, camera-water relation, scattering/absorption, caustics, rays, particles, and waterline treatment.

## What We Currently Have

### Production ocean surface

`OceanManager` is the runtime center. It is autoloaded in `project.godot:24`, but `project.godot` sets `[ocean] enabled=false`, so the game starts with the ocean off unless the UI or a test forces it on.

`OceanManager` creates and owns:

- `OceanMesh`
- `WaveGenerator`
- `OceanPhysicsEvaluator`
- `ShoreMaskGenerator`
- `OceanSpray`
- A published `WaterSurfaceState`

`OceanMesh` has two high-quality surface modes:

- `CLIPMAP`, the current default.
- `PROJECTED`, a single projected grid whose vertex shader unprojects screen-space grid points onto the water plane.

The projected-grid path is the cleaner camera-facing ocean-mesh pattern. The clipmap path still carries an explicit overlap workaround for T-junction holes in `src/core/water/ocean_mesh.gd:215`. That workaround may be acceptable as a bridge, but the long-term choice should be either projected grid as the main path or a real CDLOD-style clipmap fix.

### FFT compute

`src/core/water/wave_generator.gd` is a real GPU FFT pipeline:

- JONSWAP/TMA spectrum generation.
- Stockham FFT.
- Two cascades by default.
- `Texture2DArrayRD` displacement and normal maps.
- One cascade updated per frame for load balancing.

This is in the right family for open ocean. It should stay.

The biggest caution is the optional GPU readback path. `WaveGenerator.read_displacement()` calls `rd.texture_get_data()` in `src/core/water/wave_generator.gd:171`. Godot documents this as a blocking GPU readback. `OceanManager.use_gpu_wave_readback` defaults to false, which is correct. If exact gameplay sync is needed later, use async/delayed readback or deterministic CPU evaluation, not per-frame blocking readback.

### Surface shader

`src/core/water/shaders/ocean_fft_common.gdshaderinc` is intentionally opaque. It declares `hint_depth_texture` but avoids `hint_screen_texture` and avoids `ALPHA`. The file even states that scene-color bending belongs to the compositor, not the surface material.

That is the correct Godot 4.6 direction.

Current surface features include:

- FFT displacement and normals.
- Shore mask sampling.
- Depth/thickness driven shallow/deep color.
- Fresnel.
- Foam.
- SSS-like crest tint/emission.
- Weather-driven roughness, foam, normal strength, and color.
- Debug modes 0-8.

Concrete shader issues found during the audit:

- `smith_masking_shadowing(cos_theta, alpha)` was called with swapped argument order in `src/core/water/shaders/ocean_fft_common.gdshaderinc:416` and `:417`. Fixed 2026-05-11 by passing `dot_nl/dot_nv` as `cos_theta` and `spec_alpha` as `alpha`.
- The surface shader reconstructed background depth with a reversed-Z shortcut in `src/core/water/shaders/ocean_fft_common.gdshaderinc:226`. Fixed 2026-05-11 by using Godot's documented `INV_PROJECTION_MATRIX` depth-to-view reconstruction path with a sky/far-depth guard.
- Ocean Lab's surface debug labels were stale. `tests/visual/test_ocean_lab.gd:31` labeled mode 6 as `SSR hit`, but shader mode 6 is foam. Fixed 2026-05-11 by removing the stale label so modes 0-8 match the shader.

### Shore handling

The shore-mask contract is good:

- Red: shore/water factor.
- Green/blue: direction.
- Alpha: body coverage/distance.

The C# shore-mask baker and runtime GDScript generator exist. However, the current smoke logs showed a stale v3 shore mask being ignored and then no prebaked v4 mask available, leaving waves undampened at shore. `_load_shore_mask()` warns and proceeds; runtime generation exists only through explicit regenerate flows.

Practical effect: the architecture can support shore dampening, but the current default data path is fragile. If shore masks are missing or stale, the visual system silently degrades to wrong shore behavior after a warning.

### Underwater and waterline

The waterline/underwater compositor is ambitious and directionally correct:

- `src/core/shaders/effects/waterline_compositor_effect.gd`
- `src/core/shaders/compute/waterline_probe.glsl`
- `src/core/water/prewater_capture_renderer.gd`

It runs as `EFFECT_CALLBACK_TYPE_POST_TRANSPARENT`, with resolved color/depth access, which is the right Godot hook for post-transparent waterline and underwater work.

It already has feature bits for:

- Absorption/fog.
- Snell.
- Rays.
- Wobble.
- Particles.
- Meniscus/refraction.
- Caustics.

It also has GPU timestamp reporting through `get_underwater_perf_snapshot()`, and Ocean Lab exposes `scene_copy_ms`, `probe_ms`, and `total_ms`.

The problem is production integration and cost:

- `WorldExplorer` wires `OceanControls` and `OceanManager`, but I found no main-game setup for `PrewaterCaptureRenderer` or the waterline compositor. Ocean Lab wires them at `tests/visual/test_ocean_lab.gd:414` and `:428`.
- `WaterlineCompositorEffect._render_view()` frees and recreates a storage buffer every view every frame at `src/core/shaders/effects/waterline_compositor_effect.gd:415-416`.
- It also creates and frees uniform sets every dispatch at `:518` and `:532`, and may do a full-scene color copy at `:535`.
- `WetCompositorEffect` has the same per-frame buffer/uniform-set pattern at `src/core/shaders/effects/wet_compositor_effect.gd:250` and `:313`.
- Interactive refraction debugging on 2026-05-11 showed the source capture, receiver mask, and final mask are correct, but final rendering still has a double-outline artifact. The likely cause is architectural: opt-in receiver objects still contribute to the main opaque ocean depth/thickness footprint before the compositor draws the refracted receiver copy. Shader-side replacement/erase attempts reduced symptoms but did not produce one unified contour.
- User-observed empty Ocean Lab cost on 2026-05-11: compositor off about 4 ms, compositor on about 16 ms / roughly 60 FPS. That is too expensive for an always-on production path.

This is acceptable as lab instrumentation, but not as a final always-on AAA underwater stack. It needs persistent buffers, cached or reusable uniform sets where Godot allows it, strict feature tiers, and low-resolution/upscaled modes.

### Receiver-only prewater capture

`PrewaterCaptureRenderer` is a reasonable Godot workaround for receiver refraction:

- It uses a `SubViewport`.
- It renders only an opt-in receiver layer.
- It defaults to 50 percent resolution.
- It activates only near water.
- It tolerates one-frame latency and avoids GPU readback.

This should remain optional and layer-gated. It should not become a full-scene duplicate render every frame unless there is a measured hero-water mode that justifies it.

### Inland water, lakes, rivers, puddles

`src/core/water/water_volume.gd` should be treated as stale/prototype code, not production architecture.

Problems:

- It creates an inline transparent shader with `render_mode blend_mix`.
- It writes `ALPHA` at `water_volume.gd:265`, forcing Godot's transparent pipeline.
- It samples `SCREEN_TEXTURE` and `DEPTH_TEXTURE` at `water_volume.gd:252` and `:255` without declaring Godot 4 hint sampler uniforms. This is not the current Godot 4 screen-reading pattern.
- It has its own simple sine waves, its own flow scroll, its own `Area3D`, and its own buoyancy.
- It does not publish into `WaterSurfaceState`.
- It does not feed the waterline compositor, underwater compositor, wetness, or shared physics query path.

`PolygonWaterVolume` extends this model, so it inherits the same architectural problem.

For the user's goal - lakes, puddles, rivers with flowmaps, multiple elevations - this path should be replaced by a unified water-body system.

### Buoyancy

The current `BuoyancyBody3D` / `BuoyancyProbe3D` path is the right basic physics shape:

- `BuoyancyBody3D` extends `RigidBody3D`.
- It samples at child probes.
- It applies force at probe positions in physics tick, generating torque naturally.
- It uses OceanManager height queries.

This is the correct Jolt-friendly pattern for small and medium floating objects.

Current gaps:

- `OceanManager.get_wave_velocity()` returns `Vector3.ZERO` in `src/core/water/ocean_manager.gd:822`. Objects cannot drift with waves, current, or river flow yet.
- `get_wave_gradient()` computes four height samples in GDScript, and each height sample may loop over up to 256 CPU spectrum components. This is fine for a handful of probes, not for many floating actors.
- There are multiple buoyancy implementations: `BuoyancyBody3D`, legacy `BuoyantBody`, and `WaterVolume`'s simple force model. These should collapse to one production model.

### Weather and per-body water color

`OceanManager.apply_weather()` already drives wind, displacement scale, foam, whitecaps, spread, swell, roughness, SSS, normal strength, and water color. This is useful.

The limitation is that it is global ocean weather, not per-body water data. The colors and optical constants are hardcoded in `ocean_manager.gd`. For the target system, water color, absorption, turbidity, caustic strength, foam, and roughness should come from a `WaterOpticsProfile` per body, with weather blending layered on top.

## Verification Run

### Ocean Lab mesh smoke

Command:

```powershell
& "D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" "res://tests/visual/test_ocean_lab_mesh_toggle_smoke.tscn"
```

Result: exit code 0. The smoke toggled CLIPMAP -> PROJECTED -> CLIPMAP and completed.

Observed log details:

- Projected grid was rebuilt successfully.
- Clipmap was rebuilt successfully.
- The run warned that the shore mask is stale/missing, so shore dampening was not active.
- The waterline compositor fired and warned once that receiver source buffers were missing before external prewater buffers became available.

### Ocean spray smoke

Command:

```powershell
& "D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" "res://tests/visual/test_ocean_spray_smoke.tscn"
```

Result: exit code 0. The smoke enabled storm spray, verified particle activation, toggled spray off/on, and completed.

Observed log detail:

- Spray activated with energy about 0.986 and 9216 particles.

### Main-scene perf sweep

Command:

```powershell
& "D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" "scenes/Godotwind.tscn" -- --perf-sweep=ocean_audit_2026_05_11
```

Result: exit code 0. JSON was written to:

```text
C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/perf_sweep_ocean_audit_2026_05_11.json
```

Important limitation: this did not measure ocean cost, because the main scene starts with `"ocean": false` in `initial_toggle_state`, and the sweep only tests active subsystems. Baseline was about 51.3 FPS, but the active sweep order was only near gameplay, static visuals, distant lights, far impostors, and terrain.

Practical result: the main-scene audit confirms ocean is not on by default and therefore cannot currently represent production underwater/ocean performance without a dedicated ocean-on benchmark path.

### Cache/build notes

No shader files changed in this audit, so shader import/cache clearing was not applicable.

No C# files changed in this audit, so `dotnet build Godotwind.sln` was not required.

### Follow-up shader correctness slice - 2026-05-11

Files changed:

- `src/core/water/shaders/ocean_fft_common.gdshaderinc`
- `tests/visual/test_ocean_lab.gd`

Practical effect:

- Direct sun/specular highlights now use the Smith masking-shadowing helper with the intended argument order.
- Water thickness now comes from Godot's inverse-projection depth reconstruction pattern instead of the previous shortcut, keeping the surface path closer to the compositor and current Godot 4.6 documentation.
- Ocean Lab surface debug labels now match the actual shader debug modes; mode 6 is foam, mode 7 is `Normal.y`, and mode 8 is SSS scatter.

Verification:

- Cleared `.godot/shader_cache/SceneForwardClusteredShaderRD` before checking the changed `.gdshaderinc`.
- Ran `res://tests/visual/test_ocean_lab_mesh_toggle_smoke.tscn`; result was exit code 0. This exercised both clipmap and projected ocean shader paths after shader cache clearing.
- Launched `res://tests/visual/test_ocean_lab.tscn` interactively for visual inspection. Visual follow-up found that projected grid and clipmap still have noticeably different water aspect/texture character from the same camera pose. That predates this correctness slice and remains a projected-grid evaluation item, not a resolved issue.

No C# files changed, so `dotnet build Godotwind.sln` was not required.

### Follow-up receiver-refraction debug - 2026-05-11

Interactive Ocean Lab debugging found:

- `WL Debug: Source` showed valid source color/depth over the water and correct submerged receiver transitions.
- `WL Debug: Receiver Mask` and `Final Mask` produced the expected submerged receiver shapes.
- `WL Debug: Refract`, `Refract Offset`, and `Final` still showed two outlines / silhouettes, especially at lower `WL Res`.
- A near-replacement compositor blend and an attempted original-footprint erase did not fully remove the duplicate outline.
- Cycling waterline resolution no longer produced the earlier `Texture (binding: 5) is not a valid texture` error after adding receiver-source RID validity checks and delayed prewater texture retirement.

Conclusion: do not keep tuning the current shader as the final fix. The next pass should solve receiver refraction architecture so receiver objects do not also imprint the opaque ocean depth/thickness pass that the compositor later tries to bend.

### Follow-up receiver-layer contract fix - 2026-05-11 (superseded)

Files changed:

- `tests/visual/test_ocean_lab.gd`
- `src/core/shaders/compute/waterline_probe.glsl`
- `src/core/shaders/effects/waterline_compositor_effect.gd`
- `docs/systems/ocean.md`

Original intended effect:

- Ocean Lab receiver meshes were moved to receiver-layer ownership while the waterline compositor was active, and the main camera excluded `WATER_REFRACTION_RECEIVER_LAYER_MASK`.
- The compositor drew one receiver result from the receiver capture: direct current-UV receiver pixels above the dynamic waterline, and refracted offset receiver samples below the waterline.
- The shader-side original-footprint erase experiment was removed rather than tuned further.
- The waterline effect now reuses its state storage buffer with `RenderingDevice.buffer_update()` instead of freeing and recreating that buffer every view every frame, and it skips the above-water final pass when no receiver source exists.

Superseding correction from later 2026-05-11 Ocean Lab testing:

- That receiver-layer-only contract made `WL Res` affect the above-water part of receiver meshes, because final above-water pixels came from the reduced receiver capture.
- The current recovery contract keeps receivers visible in the main camera for above-water pixels and uses the receiver capture only for underwater/refraction samples.
- The double-outline artifact is still not accepted. User testing at `WL Res 25%` showed a duplicated/blocky underwater silhouette; the shader now disables quarter-res edge dilation, but this requires interactive validation.
- User testing also reported no visible underwater caustics or particles. High-tier effects must be treated as unverified/broken until checked in Ocean Lab with `WL Q: High`.

Canonical Godot basis:

- `Camera3D.cull_mask` selects which `VisualInstance3D.layers` the camera renders.
- A `SubViewport` can render the same shared `World3D` through a different camera/cull mask.
- `CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT` runs after transparent rendering and before built-in post-processing/output, which is the correct slot for the final receiver overlay after opaque water has drawn.

## Architecture Recommendation

### Keep

Keep these pieces:

- Opaque FFT ocean surface.
- GPU FFT displacement/normal texture arrays.
- `WaterSurfaceState` as the shared render/gameplay contract.
- `OceanPhysicsEvaluator` concept for CPU-side deterministic queries.
- `BuoyancyBody3D` and probe-based force application.
- `PrewaterCaptureRenderer` as optional receiver-only capture.
- Waterline/underwater as a `POST_TRANSPARENT` compositor.
- Ocean Lab as the visual/perf testbed.
- GPU spray particles.

### Replace

Replace these pieces:

- `WaterVolume` as the production local-water model.
- `PolygonWaterVolume` as a production lake/river model.
- Multiple independent buoyancy implementations.
- Global-only water color/optics.
- Main-scene ocean toggle that only controls the surface while underwater remains lab-only.

### New canonical shape

Do this under the existing water singleton/autoload rather than adding another autoload casually.

Recommended model:

```text
OceanManager or renamed WaterManager
  WaterBodyRegistry
    WaterBodyResource / WaterBody3D
      id
      type: ocean | lake | river | puddle | custom
      elevation / plane / polygon / spline
      optics profile
      weather response profile
      surface provider
      flow provider
      physics query provider
      render layers
      underwater/post settings
```

Surface providers:

- `SpectralOceanProvider`: FFT/JONSWAP for open ocean.
- `ShoreWaveProvider`: shore mask plus Gerstner/swash/breaker approximation.
- `InlandWaterProvider`: flat or gentle Gerstner/ripple bodies at arbitrary elevations.
- `RiverFlowProvider`: spline/flowmap current, visual flow, and velocity output.

Query contract:

```gdscript
sample_surface(world_pos) -> {
    body_id,
    coverage,
    height,
    displacement,
    normal,
    velocity,
    flow_velocity,
    depth,
    optics_profile,
}
```

The renderer, underwater compositor, wetness, buoyancy, floating debris, swimming, and particle systems should all consume this contract.

## Priority Findings

### P0 - Production underwater is not integrated

The current game path is surface ocean only. The lab path has the interesting underwater tech. Production should get a real water compositor setup that owns:

- Waterline split.
- Underwater fog/absorption.
- Snell window.
- Rays.
- Wobble.
- Particles.
- Caustics.
- Receiver refraction.
- Quality/perf tiers.

This should be a real system, not copied lab setup code.

### P0 - Receiver refraction still has a render-architecture conflict

Ocean Lab now proves that receiver capture and masks can be correct while the final image remains wrong. The submerged receiver is represented twice: once as the current main-scene/depth footprint affecting the opaque ocean surface, and once as the compositor's offset receiver sample. The proper fix is to change the render path or layer/depth contract, not keep adding shader-side eraser logic.

### P0 - Inland water architecture is wrong

Do not extend `WaterVolume` into lakes/rivers. It is not Godot 4.6 correct, not shared-state based, and not tied into the ocean/underwater/physics stack.

The correct next step is a unified `WaterBody` model with per-body elevation, shape, optics, wave provider, flow provider, and query provider.

### P1 - Add water velocity and current to gameplay queries

Floating objects, river drift, spray inheritance, swimming, and wakes need water velocity. `get_wave_velocity()` currently returns zero. The query API should return:

- Wave orbital velocity for ocean/shore.
- Flowmap/spline current for rivers.
- Wind/current drift for surface objects.

The implementation should be C# or batched native-side if used by many probes.

### P1 - Harden compositor performance

The waterline and wetness compositors should not allocate/free buffers and uniform sets every view every frame if this becomes production. Recommended changes:

- Persistent storage/uniform buffers with `buffer_update`.
- Reused uniform sets when RIDs are stable.
- Separate quality tiers for absorption-only, medium underwater, and full AAA underwater.
- Optional half/quarter-res underwater pass with upscale.
- Disable receiver capture unless refraction receivers exist and camera is near/under water.
- Ocean Lab perf thresholds for scene copy, waterline probe, spray, and wetness.
- Treat the 2026-05-11 Ocean Lab measurement, compositor off about 4 ms versus on about 16 ms, as a blocking performance target failure until the architecture is simplified or split into cheaper feature tiers.

### P1 - Fix shader correctness issues

Small but important:

- Done 2026-05-11: swap the `smith_masking_shadowing()` call arguments.
- Done 2026-05-11: replace the surface depth reconstruction shortcut with Godot's inverse-projection pattern, guarded for sky/far depth.
- Done 2026-05-11: fix Ocean Lab surface debug labels.
- Make `OceanMesh.set_debug_shore_mask()` actually drive a shader debug mode or remove that UI path.

### P1 - Shore-mask fallback

The current smoke run warned about stale/missing shore mask data. The production system needs one of:

- Automatic v4 prebake generation when stale/missing and terrain is available.
- A clear blocking validation error for water tests that require shore dampening.
- A migration path from v3 to v4 if the data is reusable.

Silently running undampened shore waves is not acceptable for shore/ocean quality decisions.

### P2 - Make projected grid the main candidate

The projected grid already exists and matches the standard camera-projected ocean mesh pattern. It should be evaluated as the production default against clipmap:

- Vertex count.
- Horizon stability.
- Shore intersection quality.
- Waterline stability.
- Reflections/SSR stability.
- Near-camera tessellation adequacy.

If clipmap remains, replace the overlap workaround with a real LOD seam solution.

### P2 - Per-body optics and weather

Move hardcoded water colors and absorption constants into resources:

- `WaterOpticsProfile`
- `WaterWeatherResponse`
- `WaterFoamProfile`

Weather should blend these profiles per body. A swamp puddle, a clear lake, a river, and ocean water should not share one global albedo/absorption model.

### P2 - Dedicated ocean-on benchmark

The existing `perf_sweep` only tests active subsystems, and ocean is off by default. Add a water-specific benchmark/lab profile:

- Surface only.
- Surface + spray.
- Surface + waterline absorption.
- Surface + full underwater.
- Surface + receiver prewater capture.
- Surface + wetness.
- Main scene ocean on.
- Ocean Lab at 100/75/50/25 percent waterline resolution.

This should record GPU timestamps from the waterline effect plus whole-frame metrics.

## Feature Matrix

| Goal | Current state | Verdict |
| --- | --- | --- |
| Open-ocean FFT waves | GPU FFT with two cascades | Good base, needs perf targets and more cascade/body design |
| Shore waves | Masked shore factor plus swash/breaker approximation | Promising, but shore-mask data path fragile |
| Inland lakes/puddles | `WaterVolume` prototype | Replace |
| Rivers/flowmaps | `WaterVolume` has visual scroll only | Missing production architecture |
| Above-water reflections | Opaque surface can use Godot lighting/reflection path; SSR/probe lab exists | Good baseline, no planar/hero reflection strategy yet |
| Refraction | Surface does not do true scene-color refraction; compositor has receiver refraction, but Ocean Lab still shows duplicate receiver outlines | Architecture conflict remains; fix render/depth layering before more shader tuning |
| Absorption | Surface depth tint and compositor absorption | Partial |
| Waterline split | Waterline compositor in lab | Not production-integrated |
| Underwater particles/rays/wobble/caustics/Snell | Snell/wobble/fog are medium-tier compositor paths; rays/particles/caustics are high-tier and not visually accepted after 2026-05-11 Ocean Lab testing | Needs repair/validation, perf hardening, production integration |
| Foam | FFT foam plus shore foam | Present, needs visual tuning |
| SSS on wave tips | Present as approximate crest tint/emission | Present, small shader bug may affect lighting |
| Spray particles | GPU spray smoke passes | Good base |
| Weather changes ocean | Global ocean weather hooks exist | Good start, not per-body |
| Per-body water color | Not real yet | Missing |
| Buoyancy with Jolt | Probe forces on `RigidBody3D` | Good base, missing velocity/current and unified body support |
| Fast performance | Some gates exist; no ocean-on benchmark | Unknown until measured properly |

## What To Test Visually Next

Use Ocean Lab:

```powershell
& "D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" "res://tests/visual/test_ocean_lab.tscn"
```

Recommended debug checks:

- Surface debug `Water thickness`, `Foam`, `Normal.y`, `SSS scatter`.
- Waterline debug `Pipeline`, `Camera Split`, `Source`, `Refract`, `Body Coverage`, `Final Mask`, `Wobble Guard`.
- Toggle waterline resolution 100/75/50/25 percent and watch `scene_copy_ms`, `probe_ms`, `total_ms`.
- Toggle Snell/rays/wobble/particles/caustics one at a time to identify which effect dominates.
- Switch CLIPMAP/PROJECTED and inspect the waterline crossing, horizon, shore edge, and near-camera wave detail.
- Test with the shore mask fixed or regenerated; current stale/missing mask warnings make shore judgment unreliable.

## Recommended First Implementation Slice

The first production slice should not be "make a nicer water shader." It should be:

1. Create the unified `WaterBody`/`WaterSurfaceState` production contract under the existing water singleton.
2. Mark `WaterVolume` as legacy/prototype and stop using it for new lakes/rivers.
3. Wire the waterline/prewater compositor into the main scene behind quality flags.
4. Add `velocity` to ocean CPU queries and move hot query paths toward C# or batched evaluation.
5. Fix the small shader/debug bugs.
6. Add an ocean-on benchmark ladder that actually measures the water stack.

After that, build rivers/lakes/puddles on the same contract. That avoids the exact failure mode this project is trying to avoid: separate systems that all look like water but do not share rendering, physics, weather, or underwater behavior.

## Source Links

- Godot 4.6 renderer feature matrix: https://docs.godotengine.org/en/4.6/tutorials/rendering/renderers.html
- Godot 4.6 `CompositorEffect`: https://docs.godotengine.org/en/4.6/classes/class_compositoreffect.html
- Godot 4.6 screen-reading shaders: https://docs.godotengine.org/en/4.6/tutorials/shaders/screen-reading_shaders.html
- Godot 4.6 advanced post-processing/depth reconstruction: https://docs.godotengine.org/en/4.6/tutorials/shaders/advanced_postprocessing.html
- Godot 4.6 spatial shader transparency behavior: https://docs.godotengine.org/en/4.6/tutorials/shaders/shader_reference/spatial_shader.html
- Godot 4.6 `Environment` SSR notes: https://docs.godotengine.org/en/4.6/classes/class_environment.html
- Godot 4.6 compute shaders: https://docs.godotengine.org/en/4.6/tutorials/shaders/compute_shaders.html
- Godot 4.6 `RenderingDevice.texture_get_data`: https://docs.godotengine.org/en/4.6/classes/class_renderingdevice.html
- Unreal Water System: https://dev.epicgames.com/documentation/en-us/unreal-engine/water-system-in-unreal-engine
- Unreal Water Body Actors: https://dev.epicgames.com/documentation/en-us/unreal-engine/water-body-actors-in-unreal-engine
- Unity HDRP Water System overview: https://docs.unity.cn/Packages/com.unity.render-pipelines.high-definition@16.0/manual/WaterSystem-Overview.html
- GPU Gems Chapter 1, water simulation: https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-1-effective-water-simulation-physical-models
- GPU Gems Chapter 2, water caustics: https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-2-rendering-water-caustics
- Tessendorf, Simulating Ocean Water: https://people.computing.clemson.edu/~jtessen/reports/papers_files/coursenotes2002.pdf
- Ocean rendering survey: https://arxiv.org/abs/1109.6494
