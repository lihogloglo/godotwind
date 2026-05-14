# Ocean Shader Rendering Architecture

Status: current as of 2026-05-14, verified from source. This is the project
truth for the ocean surface, underwater medium, screen/depth sampling, and
waterline/refraction ownership.

This document replaces the older split between `docs/systems/ocean.md`,
`docs/systems/underwater.md`, and the underwater overhaul plan. Those files are
history unless they point back here.

## Executive Summary

The active code is not the receiver-only waterline architecture described by
older docs.

Current runtime is:

1. `OceanManager` publishes water state and FFT textures.
2. `OceanMesh` draws the visible ocean as a spatial shader using either a
   clipmap mesh or projected grid mesh.
3. The ocean surface shader samples Godot's screen and depth textures directly
   for above-water thickness, absorption, refraction, foam, and custom SSR.
4. Ocean Lab uses `UnderwaterCompositorEffect` for underwater camera medium and
   bounded wobble.
5. The receiver-only `WaterlineStack` / `PrewaterCaptureRenderer` /
   `WaterlineCompositorEffect` path still exists in source, but it is not the
   normal Ocean Lab path and is skipped by `ShaderManager` effect discovery.

Practical effect: a "straight object plus refracted duplicate" should be
debugged as a source/guard/composition problem. It is not solved by sampling the
same main `SCREEN_TEXTURE` harder inside the ocean surface shader.

## Active Runtime Path

### Ocean Manager

Main file: `src/core/water/ocean_manager.gd`

`OceanManager` owns:

- The `OceanMesh` node.
- FFT compute setup through `WaveGenerator`.
- Global shader parameters for displacement and normal texture arrays.
- Shore mask texture and bounds.
- Surface optical constants: absorption tint, absorption sigma, surface SSR
  toggle, underwater caustics strength.
- `WaterSurfaceState`, the shared data contract consumed by compositor and
  water-adjacent systems.

The important contract is `get_water_surface_state()`. It packages:

- `sea_level`, `wave_scale`, `ocean_time`.
- `map_scales`, `cascade_count`.
- RD RIDs for displacement and normal texture arrays.
- Shore mask texture/RID, bounds, fade distance, shore wave parameters.
- Absorption tint/sigma and underwater caustics strength.
- CPU query callables for height, displacement, normal, coverage, shore side,
  and water body ID.
- Render mesh metadata, including clipmap origin and projected-grid settings.

New water systems should consume `WaterSurfaceState` instead of reaching into
`OceanManager` private fields.

### Visible Ocean Surface

Main files:

- `src/core/water/ocean_mesh.gd`
- `src/core/water/shaders/ocean_fft.gdshader`
- `src/core/water/shaders/ocean_fft_projected.gdshader`
- `src/core/water/shaders/ocean_fft_common.gdshaderinc`

`OceanMesh` has two mesh modes:

- `CLIPMAP`: concentric world-space rings snapped around the camera.
- `PROJECTED`: Sea-of-Thieves/Wicked-style screen projected grid that writes
  `POSITION` from a vertex-stage ray/water-plane intersection.

Both mesh modes include `ocean_fft_common.gdshaderinc`; only the vertex path
differs. The shared fragment path is the production surface shader.

Current render modes:

- `ocean_fft.gdshader`: `world_vertex_coords, cull_disabled, shadows_disabled,
  depth_draw_always`
- `ocean_fft_projected.gdshader`: `cull_disabled, shadows_disabled,
  depth_draw_always`

The shared fragment shader declares:

- `SCREEN_TEXTURE : hint_screen_texture`
- `DEPTH_TEXTURE : hint_depth_texture`
- FFT displacement and normal arrays as global shader parameters
- `refraction_strength`, `max_refr_thickness`, and rejection/diagnostic
  controls
- custom SSR controls

By Godot's renderer rules, declaring `hint_screen_texture` means this surface
is constrained to the opaque screen copy even though the shader writes
`ALPHA = 1.0` and uses `depth_draw_always`. Those settings can help the ocean's
own surface ordering, but they do not make screen refraction see transparent or
later-rendered content.

The surface path does this per fragment:

1. Reconstructs the displaced water surface in view space.
2. Samples `DEPTH_TEXTURE` at `SCREEN_UV`.
3. Computes water thickness from water surface depth to opaque scene depth.
4. Reads FFT normals and shore waves.
5. Builds foam and Fresnel.
6. Attempts one bounded refracted UV by `refract(-VIEW, NORMAL, 0.7509)`.
7. Rejects the candidate if it is off-screen, has no depth, is in front of the
   water surface, or is above the mean sea-level guard. Large straight-vs-
   candidate depth deltas remain diagnostic-only so silhouettes can refract
   outside the original straight screen footprint.
8. Samples `SCREEN_TEXTURE` at either the refracted UV or straight `SCREEN_UV`.
9. Applies Beer-Lambert absorption over the chosen optical path.
10. Optionally raymarches a small custom SSR trace against the same screen/depth
    sources.
11. Writes an opaque result with `ALPHA = 1.0`.

Current surface refraction is therefore screen-space, single-source, and
limited to the opaque screen copy Godot exposes to a screen-reading spatial
material.

### Underwater Camera Medium

Main files:

- `src/core/shaders/effects/underwater_compositor_effect.gd`
- `src/core/shaders/compute/underwater.glsl`

Ocean Lab currently instantiates this effect directly. It runs as a
`CompositorEffect` at `POST_TRANSPARENT`.

The effect:

- Skips normal rendering while the camera is above `sea_level`.
- Reconstructs scene hit positions from the depth buffer.
- Computes water path length from camera to hit or camera to surface exit.
- Applies absorption with the tint/sigma from `WaterSurfaceState`.
- Optionally copies scene color and applies a guarded wobble sample.

Important limitation: this shader is a cheap underwater medium. It does not use
the dynamic FFT water surface contract; it uses `sea_level` for camera
submersion and exit tests. It is much simpler than `waterline_probe.glsl`.

### Receiver-Only Waterline Path

Main files still present:

- `src/core/water/waterline_stack.gd`
- `src/core/water/prewater_capture_renderer.gd`
- `src/core/shaders/effects/prewater_capture_effect.gd`
- `src/core/shaders/effects/waterline_compositor_effect.gd`
- `src/core/shaders/compute/prewater_capture.glsl`
- `src/core/shaders/compute/waterline_probe.glsl`
- `src/core/shaders/compute/water_surface_contract.glslinc`

This path is not deleted, but it is not the active Ocean Lab path.

What it was designed to do:

- Render opt-in receiver objects into a receiver-only SubViewport.
- Copy that capture's color and depth into RD textures.
- Run a `POST_TRANSPARENT` compositor.
- Use `WaterSurfaceState` plus mirrored GLSL water-surface math to classify
  receiver pixels against the dynamic water surface.
- Replace water pixels with refracted/tinted receiver samples.
- Also attempt richer underwater camera treatment, including Snell-window,
  wobble, particles, and caustics.

Current code facts:

- `WaterlineStack` defaults to disabled.
- `WaterlineStack.set_receiver_source_mode()` forces
  `RECEIVER_SOURCE_MAIN_ABOVE_CAPTURE_UNDER`.
- `WaterlineCompositorEffect.set_receiver_source_mode()` ignores caller input
  and keeps the same replacement path.
- `ShaderManager` explicitly skips `prewater_capture_effect.gd` and
  `waterline_compositor_effect.gd` during built-in effect discovery.
- `Ocean Lab` currently preloads `UnderwaterCompositorEffect`, not
  `WaterlineStack`.

Treat this receiver path as experimental/quarantined until it is deliberately
re-integrated and visually accepted.

## Current Contradictions Resolved

Older docs claimed:

- The FFT ocean surface must not declare `hint_screen_texture`.
- Refraction must be compositor-owned.
- `WaterlineCompositorEffect` owns production underwater behavior.
- `underwater.glsl` and `underwater_compositor_effect.gd` were deleted.

Current source says the opposite:

- `ocean_fft_common.gdshaderinc` declares both screen and depth textures and
  owns surface refraction/custom SSR.
- `underwater.glsl` and `underwater_compositor_effect.gd` exist and are loaded
  by Ocean Lab.
- The receiver-only compositor files exist but are not the normal runtime path.

The docs must follow source, not earlier plans.

## Likely Cause Of The Double-Shape Artifact

There are two distinct mechanisms that can produce "straight plus refracted":

1. Surface shader source ownership:
   `ocean_fft_common.gdshaderinc` keeps both `straight_source_col` and
   `refr_source_col`, then chooses with `refr_sample_weight`. That weight must
   stay binary in final rendering. Fractional weights near silhouettes preserve
   both the original and shifted object in the same pixel neighborhood.

2. Separate compositor/source paths:
   Any path that draws the normal main scene and then overlays a shifted
   receiver/copy sample can create a duplicate if the replacement mask is not
   binary enough or does not cover the original footprint.

The surface path keeps the color-delta guard as an optional hard reject only.
It must not fade between straight and refracted source colors.

Debug in this order:

1. Surface debug `13`: straight source color.
2. Surface debug `14`: refracted candidate source color.
3. Surface debug `15`: accepted/rejected refraction mask.
4. Surface debug `16` and `18`: Godot-style depth-weighted UV preview.
5. Disable surface refraction (`refraction_strength = 0`).
6. Disable custom surface SSR (`ssr_enabled = false`).
7. Disable `UnderwaterCompositorEffect`.
8. If the receiver path is re-enabled, run `waterline_probe.glsl` debug modes
   `5`, `6`, `7`, `9`, and `14` to separate source validity, receiver mask, and
   final replacement mask.

Acceptance signal: in final rendering, a submerged opaque object should appear
either straight or refracted/tinted for a given visible water pixel, never both
as two readable silhouettes.

## Debug Controls

`OceanManager.set_debug_mode()` drives surface shader modes `0..20`.

Most relevant surface modes:

- `6`: refraction validity and offset.
- `7`: refraction depth/guard rejection.
- `8`: custom SSR hit mask.
- `12`: color delta between straight and refracted source.
- `13`: straight source color.
- `14`: refracted candidate source color.
- `15`: refraction classifier/mask.
- `16`: Godot PR-style depth weight.
- `17`: depth edge/disocclusion strength.
- `18`: Godot-style source preview.
- `19`: final refraction sample weight, black for straight source and white
  for refracted source. Gray means an unwanted fractional blend has returned.
- `20`: Source Blend, the raw straight/refracted source mix before absorption,
  Fresnel, SSR, foam, or surface lighting.

`UnderwaterCompositorEffect.set_debug_mode()` drives underwater medium modes
`0..5`.

Most relevant underwater modes:

- `1`: path length.
- `2`: transmittance.
- `3`: underwater hit mask.
- `4`: wobble delta.
- `5`: wobble guard.

## Documentation Ownership

Keep only two living ocean shader docs:

- This file: what the project currently does.
- `docs/systems/godot_water_shader_bible.md`: what Godot's renderer allows and
  how future water shader work should fit it.

Plans and archives may keep historical detail, but they must not be treated as
current truth unless they point to these two files.
