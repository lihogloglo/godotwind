# Ocean Underwater Architecture Audit - 2026-05-09

## Decision

Use one production underwater path:

- `WaterSurfaceState` is the water contract for height, displacement, normals,
  water-body coverage, optical constants, readiness, and query provenance.
- The opaque FFT ocean surface owns visible surface rendering, surface color,
  foam, sky/probe/native reflections, and opaque-scene depth thickness.
- `PrewaterCaptureRenderer` owns the receiver-only color/depth capture for
  objects that opt into waterline refraction.
- `WaterlineCompositorEffect` owns waterline composition, submerged receiver
  refraction, underwater camera optics, Snell's window, fog/absorption,
  backscatter, rays, wobble, caustics, and particles.
- `UnderwaterVolume` is diagnostic/support only. It no longer draws caustics;
  it is not the production owner for the underwater view or half-immersed
  camera split.

Legacy files from the old compute/quad attempts must remain deleted. They were
useful experiments, but keeping them in-tree makes it too easy for a later
session to patch the wrong architecture.

## Current Path Audit

| Path | Status | Rationale |
|------|--------|-----------|
| `src/core/water/water_surface_state.gd` | Production | Single shared snapshot/API for wave state, masks, optics, and query metadata. |
| `src/core/water/ocean_manager.gd` | Production owner for state | Owns water state and surface resources; no longer loads the legacy underwater compositor. |
| `src/core/water/shaders/ocean_fft*.gdshader*` | Production | Opaque visible water surface; not the underwater-camera compositor. |
| `src/core/water/prewater_capture_renderer.gd` | Production support | Owns receiver-only SubViewport capture and exposes texture RIDs to the compositor. |
| `src/core/shaders/effects/prewater_capture_effect.gd` + `prewater_capture.glsl` | Production support | Copies receiver color/depth from the capture viewport into sampleable RD textures. |
| `src/core/shaders/effects/waterline_compositor_effect.gd` + `waterline_probe.glsl` | Production, needs rebuild phases | Correct owner for the waterline and underwater camera path, but Snell/rays/wobble need the later overhaul phases. |
| `src/core/water/underwater_volume.gd` + `underwater_volume.gdshader` | Diagnostic/support | Useful for visualizing underwater slab/depth/wobble behavior. It must not own caustics or production camera optics. |
| `tests/visual/test_ocean_lab.gd` | Production lab | Interactive lab for the compositor, prewater capture, debug views, and perf snapshots. |
| `tests/visual/test_underwater.gd` | Diagnostic/reference | Legacy visual scene now limited to `UnderwaterVolume` diagnosis; not a production path. |
| `src/core/shaders/compute/underwater.glsl` | Deleted | Retired compute compositor shader. |
| `src/core/shaders/effects/underwater_compositor_effect.gd` | Deleted | Retired ShaderManager-loaded compositor wrapper. |
| `src/core/water/shaders/underwater.gdshader` | Deleted | Retired full-screen quad shader. |
| `src/core/water/underwater_effect.gd` | Deleted | Retired quad script. |

## Research Notes

- Godot 4.6 `CompositorEffect` supports render-stage callbacks, including
  `POST_TRANSPARENT`, and explicit resolved color/depth access. That makes it
  the right Godot-side owner for a final waterline/underwater composition pass
  that needs rendered scene color and depth.
- Godot 4.6 depth reconstruction must respect reverse-Z. The docs state depth
  values map near to `1.0` and far to `0.0`, and reconstruction should use the
  inverse projection path for world/view positions.
- Godot viewports are render targets that can be sampled as textures. This
  supports `PrewaterCaptureRenderer` as a receiver-only capture owner, with the
  known one-frame-latency contract and without GPU readback.
- Godot `RenderingDevice` inserts barriers automatically for the deprecated
  public barrier APIs, but compute passes that write then sample their own
  intermediate textures should still keep command-list ordering explicit and
  avoid binding the same texture as read/write in one pass.
- Unreal's water bodies expose underwater post-process settings on the water
  body, which confirms the industry ownership split: water body/state selects
  the optical context; a post/compositor material applies camera-underwater
  treatment.
- Unity HDRP treats underwater view and caustics as water-system features tied
  to water body type, collider/volume depth, absorption, and simulation band.
  Caustic visibility depends on water clarity and wave band scale, not a single
  fixed texture scale.
- GPU Gems' real-time caustic chapter grounds caustics in Snell/refraction and
  surface normals, then permits an aesthetics-driven approximation for runtime
  cost. This matches the planned Godot adaptation: physically grounded gates
  and units, with real-time approximations clearly documented.

## Selected Godot Adaptation

Godotwind cannot lean on a built-in HDRP/Unreal-style water renderer, so the
canonical adaptation is:

1. `OceanManager` publishes one `WaterSurfaceState`.
2. The visible ocean stays opaque and avoids screen-color ownership.
3. `PrewaterCaptureRenderer` captures only opt-in receivers into a SubViewport.
4. `WaterlineCompositorEffect` runs at `POST_TRANSPARENT`, samples main
   color/depth plus receiver color/depth, and applies per-pixel water-body and
   surface classification.
5. The compositor uses distinct buffers for receiver refraction and
   above-water/Snell transmission. Receiver capture is not assumed to be the sky
   or above-water source.
6. All distances and tuning constants are Godotwind meters, Y-up.

## Source Anchors

- Godot 4.6 CompositorEffect:
  https://docs.godotengine.org/en/4.6/classes/class_compositoreffect.html
- Godot 4.6 advanced post-processing and reverse-Z depth:
  https://docs.godotengine.org/en/4.6/tutorials/shaders/advanced_postprocessing.html
- Godot 4.6 compute shaders:
  https://docs.godotengine.org/en/4.6/tutorials/shaders/compute_shaders.html
- Godot 4.6 Viewports:
  https://docs.godotengine.org/en/4.6/tutorials/rendering/viewports.html
- Godot 4.6 RenderingDevice:
  https://docs.godotengine.org/en/4.6/classes/class_renderingdevice.html
- Unity HDRP water overview:
  https://docs.unity.cn/Packages/com.unity.render-pipelines.high-definition%4016.0/manual/WaterSystem-Overview.html
- Unity HDRP underwater view:
  https://docs.unity.cn/Packages/com.unity.render-pipelines.high-definition%4015.0/manual/WaterSystem-underwater.html
- Unity HDRP caustics:
  https://docs.unity.cn/Packages/com.unity.render-pipelines.high-definition%4017.0/manual/WaterSystem-caustics.html
- Unreal Water Body actors:
  https://dev.epicgames.com/documentation/en-us/unreal-engine/water-body-actors-in-unreal-engine
- NVIDIA GPU Gems, Chapter 2, Rendering Water Caustics:
  https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-2-rendering-water-caustics
