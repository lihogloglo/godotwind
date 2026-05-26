# OpenMW-Style Controlled Refraction Source Plan

Date: 2026-05-23
Status: Amended after researcher review; cleared for Ocean Lab/clone vertical slice

2026-05-23 implementation update: the Ocean Lab vertical slice now has the
controlled half-resolution source, renderer-native source matrices, and a
bounded depth-guided receiver ray/depth solve in `surface_refraction.glsl`.
This replaces the fixed `max_refr_thickness * refraction_strength` candidate
projection. The path remains experimental/off-by-default because Phase 2
half-submerged receiver clipping/masking is not implemented and the final
compositor pass is still above the opaque-ocean budget target.

## Decision

The current full-screen surface-refraction compositor should not be promoted as
the production refraction architecture. It proved the correct problem class, but
it is now patching screen-space source-ownership failures after the main scene
has already been rendered. In Ocean Lab it still showed a foreground-boundary
outline and refraction cost around 13 ms where the target ocean budget is about
6 ms.

The production direction should be an OpenMW-style controlled refraction source:
a named color source, paired depth source, and explicit water/receiver ownership
contract produced before the water shader/compositor samples it. The visible
ocean mesh stays opaque and keeps the existing FFT, clipmap/projected-grid,
shore Gerstner, foam, Fresnel/specular, and SSR responsibilities.

SSR is not a replacement for refraction. SSR gives reflected visible scene
color; refraction needs transmitted scene color and depth for objects behind or
under the water surface. SSR can remain part of surface reflection, but the
refraction source must be separately owned.

## Why The Current Path Stops Here

The current path uses a `POST_TRANSPARENT` compositor to read main color/depth,
classify visible water by reconstructing world position and intersecting
dynamic water, then test a shifted candidate UV. That shape is defensible as a
diagnostic, but it is too fragile and expensive as the final solution:

- Foreground/above-water silhouettes are a known screen-space refraction
  limitation. Godot documents the screen texture as a 3D opaque-scene copy and
  recommends a Viewport when the back-buffer contract is not enough.
- GPU Gems 2 describes the same artifact class: perturbed refraction UVs can
  sample objects in front of the refractive surface unless the refraction source
  is masked.
- Our Ownership RGB diagnostic confirmed the halo was a recoverable ownership
  boundary, but the unshifted-source fallback and later edge-collapse attempt
  still produced a visible outline and failed the performance budget.
- Continuing with more probes, stepped searches, or binary searches would
  compound the wrong approach. The source/mask ownership needs to move earlier.

## Architecture Target

Introduce a first-class `ControlledRefractionSource` subsystem for water.

Responsibilities:

1. Maintain a refraction color target at a configurable resolution.
2. Maintain a paired refraction depth target in the same depth space.
3. Render or generate only water-valid/transmitted receiver content.
4. Publish source RIDs/textures, size, frame age, resolution scale, and ownership
   status to the water renderer.
5. Keep the source contract generic: no Morrowind-specific formats,
   coordinates, NIF assumptions, or ESM logic.

Consumers:

- Surface refraction compositor or surface overlay samples the controlled color
  and depth source.
- Underwater medium can later consume the same source contract if useful, but
  this plan does not merge underwater/waterline/wetness into one mega pass.
- Receiver-waterline remains diagnostic until separately accepted.

Current systems to reuse or supersede:

- Reuse `PrewaterCaptureRenderer` concepts: synced camera, SubViewport,
  resolution scale, source RIDs, frame-age contract.
- Phase 1 depth transport is not open-ended: reuse or refactor the existing
  `PrewaterCaptureRenderer` plus `PrewaterCaptureEffect` copy path first. That
  path already owns a synced SubViewport/camera/compositor, copies resolved
  color into a sampleable RGBA16F target, copies raw normalized depth into a
  sampleable R32F target, and reports frame age/copy timing. Do not assume
  `SubViewport.get_texture()` provides the paired depth source.
- Phase 1 depth-space contract: the copied depth source remains raw normalized
  capture-view depth. Consumers reconstruct with renderer-native projection and
  transform matrices captured from the same SubViewport render pass as the
  color/depth copy, not with `Camera3D.get_camera_projection()` and not with the
  main viewport matrices. A later change may choose linear view depth, but that
  is a deliberate contract change, not an implementation detail.
- Replace fixed-travel `surface_refraction.glsl` ownership recovery with
  sampling from the controlled source plus a bounded receiver ray/depth solve
  and cheap mask/depth confidence guard.

## Godot 4.6 Feasibility

Supported pieces:

- `SubViewport` can be used as a render target and exposes textures.
- `Camera3D.cull_mask` can restrict visible render layers.
- `CompositorEffect` can access resolved color/depth and run custom render
  work, though the API is experimental.
- Screen/depth texture reads are screen-space copies and are not enough when
  controlled source ownership is required.

Known gap:

OpenMW uses a refraction camera with a clip/cull plane around the water plane.
Stock Godot 4.6 `Camera3D` does not appear to expose an equivalent arbitrary
clip-plane API. The Godotwind design must choose a Godot-native substitute
before implementation expands beyond Ocean Lab.

Candidate clip/mask strategies:

1. **Layer-partitioned SubViewport source**
   - Render only water-refraction-eligible receivers.
   - Lowest implementation risk, but does not solve half-submerged clipping by
     itself.
   - Good first prototype for terrain/static seabed and explicit test receivers.

2. **Capture-only material clip/discard**
   - Render capture proxies or capture material variants that discard fragments
     above the water source plane.
   - Closest stock-Godot equivalent to OpenMW's clipped refraction camera.
   - Hard part: arbitrary material preservation. This should start with Ocean
     Lab primitives and terrain, not the whole world.

3. **Generated ownership/depth mask**
   - Produce a water-owned/transmitted mask and depth texture at reduced
     resolution, then use it to gate the refraction sample.
   - Matches GPU Gems mask logic and OpenMW distortion occlusion logic.
   - Useful if material clipping is too invasive.

4. **RenderingServer/compositor source path**
   - Only consider if the above cannot produce a clean color/depth contract.
   - Must avoid returning to full-screen dynamic water ray ownership as the
     primary solution.

## Prototype Plan

### Phase 0 - Freeze Current Path

- Mark current `SurfaceRefractionLayer` as experimental in Ocean Lab/status.
- Gate the expensive fallback/recovery behavior off by default.
- Update `docs/systems/ocean/architecture.md` and `docs/STATUS.md` immediately
  so they no longer describe the current full-screen recovery compositor as the
  accepted production surface-refraction path.
- Keep diagnostics: Final Mask, Reject Reason, Pre Absorb, Ownership RGB, source
  validity, source frame age, dispatch size, and `surface_refract_ms`.
- Do not integrate current surface refraction into `world_explorer` as a
  production default.

### Phase 1 - Controlled Source Vertical Slice

Build an Ocean Lab-only prototype first.

Scope:

- One `ControlledRefractionSource` node using a half-resolution SubViewport.
- Camera synchronized from the main Ocean Lab camera.
- Explicit refraction render layer(s).
- Water excluded from the source.
- Terrain/seabed and a small set of refraction receiver canaries included.
- Paired color/depth source copied through the existing
  `PrewaterCaptureEffect`-style path for main water sampling.
- Raw normalized capture-depth reconstruction uses the synced source camera
  projection contract described above.
- Source frame-age tolerance reported in HUD.

Acceptance:

- Foreground leakage is gone when the controlled source excludes that
  foreground and includes terrain/seabed/canary receivers.
- The same halo test no longer shows above-water foreground copy or outline for
  layer-only eligible receivers.
- Refraction On cost is near the ocean budget target and materially below the
  previous 13 ms path.
- Source size, frame age, and source validity are visible in HUD/log.
- No shader cache/import rule is skipped for changed `.glsl` or `.gdshader`
  files.
- Half-submerged receiver clipping is not a Phase 1 pass/fail gate unless Phase
  1 also implements one of the Phase 2 clip/mask strategies.

2026-05-23 Phase 1 evidence in Ocean Lab smoke:

- Controlled source renderer matrices are present and fresh (`age=1`).
- Normal source/main candidate mismatch is `0`.
- Zero-travel ownership collapses to zero offset/mismatch.
- Normal `candidate_offset_gt_two_px_pixels` fell from essentially all visible
  water pixels in the fixed-travel model to about 16% with the receiver solve.
- Final surface-refraction compositor timing measured about 5.94 ms in the
  smoke, with total controlled refraction about 6.30 ms. This is materially
  below the rejected ~13 ms path but still needs budget review before
  production promotion.

### Phase 2 - Clip/Mask Strategy Test

If layer-only source cannot handle half-submerged objects:

- Prototype capture-only clipped materials/proxies for Ocean Lab primitives.
- Clip initially against mean sea level, not dynamic wave height. This matches
  classic water RTT practice and avoids rebuilding per-pixel wave clipping into
  the source pass.
- Add a cheap confidence fade for dynamic wave mismatch at the final water pass.
- If material clipping proves too invasive, prototype a reduced-resolution
  ownership/depth mask instead.

Acceptance:

- Half-submerged object has no above-water leakage in Final or Pre Absorb.
- Boundary remains stable while the wave surface moves up/down.
- Cost stays within the agreed budget at half resolution.

### Phase 3 - Replace Experimental Compositor Logic

Once the controlled source works:

- Remove or quarantine dynamic per-pixel source recovery from
  `surface_refraction.glsl`.
- Keep only cheap depth/mask confidence guards, edge attenuation, and
  Beer-Lambert absorption using the controlled source depth.
- Preserve the visible opaque ocean surface and SSR reflection path.
- Update `docs/systems/ocean/architecture.md` with the accepted production
  source contract.

## Performance Budget

Measurements must use the same camera and same Ocean Lab view:

- Refraction Off frame/ocean ms.
- Current experimental refraction ms.
- Controlled source render ms.
- `PrewaterCaptureEffect` copy ms.
- Controlled source final sampling/compositor ms.
- Total Refraction On ms.

Acceptance target:

- Ocean should remain around the 6 ms target where practical.
- If full controlled refraction necessarily costs more, the plan must define
  quality tiers: off, half-res, quarter-res, and debug/full-res.
- Any path around 13 ms for surface refraction alone is not accepted.

## Open Questions

1. Can Godotwind render enough terrain/static receiver content into a SubViewport
   without duplicating unacceptable scene cost?
2. What is the least invasive way to clip half-submerged receiver geometry in
   Godot 4.6?
3. Can generated water ownership/depth masks replace material clipping for most
   outdoor cases?
4. How should dynamic FFT/Gerstner displacement influence the source contract?
   Proposed answer for prototype: source clips to mean sea level, final pass
   handles dynamic wave confidence.
5. Which renderer resources should be owned by `ControlledRefractionSource`
   versus `SurfaceRefractionLayer`?
6. How much of `PrewaterCaptureRenderer` should be generalized instead of
   adding a second similar capture stack?

## Sources

- Godotwind rules: `docs/systems/ocean/godot_4_6_water_rendering_rules.md`
- Godotwind current architecture: `docs/systems/ocean/architecture.md`
- Godot 4.6 screen-reading shaders:
  https://docs.godotengine.org/en/4.6/tutorials/shaders/screen-reading_shaders.html
- Godot 4.6 Viewports:
  https://docs.godotengine.org/en/4.6/tutorials/rendering/viewports.html
- Godot 4.6 Camera3D cull masks:
  https://docs.godotengine.org/en/4.6/classes/class_camera3d.html#class-camera3d-property-cull-mask
- Godot 4.6 CompositorEffect:
  https://docs.godotengine.org/en/4.6/classes/class_compositoreffect.html
- Godot 4.6 depth texture and reverse-Z reconstruction:
  https://docs.godotengine.org/en/4.6/tutorials/shaders/advanced_postprocessing.html
- GPU Gems 2, Chapter 19, Generic Refraction Simulation:
  https://developer.nvidia.com/gpugems/gpugems2/part-ii-shading-lighting-and-shadows/chapter-19-generic-refraction-simulation
- OpenMW water renderer:
  https://github.com/OpenMW/openmw/blob/master/apps/openmw/mwrender/water.cpp
- OpenMW water shader:
  https://github.com/OpenMW/openmw/blob/master/files/shaders/compatibility/water.frag
- OpenMW internal distortion pass:
  https://github.com/OpenMW/openmw/blob/master/files/data/shaders/internal_distortion.omwfx
