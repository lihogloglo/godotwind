# Ocean Option C Render-Order Audit

Date: 2026-05-07
Owner: Codex
Status: diagnostic launched; architecture conclusion established from Godot 4.6 render order

## Question

Can the current late transparent `UnderwaterVolume` solve above-water
waterline distortion for half-submerged objects while the opaque FFT ocean mesh
is visible?

## Godot 4.6 Constraints

- The FFT ocean surface is intentionally opaque. This gives it depth authority,
  stable reflection/foam/absorption behavior, and avoids the native transparent
  water path.
- `UnderwaterVolume` is a spatial screen-reading volume:
  `render_mode blend_mix, cull_front, depth_test_disabled, unshaded`, writes
  `ALPHA`, and samples `hint_screen_texture` / `hint_depth_texture`.
- Godot 4.6 documents that writing `ALPHA` moves a spatial shader into the
  transparent pipeline, and transparent materials are drawn after opaque
  materials.
- Godot 4.6 documents that the 3D screen texture is copied after opaque
  geometry and before transparent geometry. Screen-reading materials are
  transparent themselves, and the 3D screen texture is only captured once.
- Godot 4.6's native material refraction is also screen-space and subject to
  transparent sorting / visibility limitations.

References:

- https://docs.godotengine.org/en/4.6/tutorials/shaders/shader_reference/spatial_shader.html
- https://docs.godotengine.org/en/4.6/tutorials/shaders/screen-reading_shaders.html
- https://docs.godotengine.org/en/4.6/tutorials/3d/3d_rendering_limitations.html
- https://docs.godotengine.org/en/4.6/tutorials/3d/standard_material_3d.html
- https://docs.godotengine.org/en/4.6/classes/class_compositoreffect.html

## Diagnostic

Ocean Lab was launched interactively with:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab.tscn
```

Use this state:

- `Surf Refract: Off`
- `Underwater: On`
- `UW Mode: AllCam`
- Compare `Ocean Mesh: On` versus `Ocean Mesh: Off` on the half-submerged
  monolith and submerged rock.

Expected result from the render-order constraints: with the ocean mesh visible,
the volume's depth/screen sample for water-covered pixels is dominated by the
opaque ocean surface. With the ocean mesh hidden, the volume can see submerged
opaque geometry and its wobble/absorption/caustics become visible on those
objects.

User observation: in final shading there was no visible difference between
`Ocean Mesh: On` and `Ocean Mesh: Off` on the half-submerged object, except for
the ocean-surface waterline/foam line when the mesh was visible.

Follow-up: Ocean Lab now has a `UW Debug` control. Use `Slab Mask` and
`Big Wobble` to separate "the volume cannot see the object" from "the final
volume shading is too subtle or being rejected by its slab/guard logic."

## Decision

The final-shading observation means the original "opaque ocean mesh hides the
needed depth" hypothesis is incomplete. A late transparent `UnderwaterVolume`
still should not be treated as the production owner for above-water
half-submerged-object distortion until the debug modes prove exactly what it
sees. It remains useful as:

- an underwater-camera volume for fog, absorption, caustics, and wobble;
- a lab diagnostic for tuning the effect itself;
- a source shader for the eventual waterline compositor.

The production Option C path should be a compositor or pre-ocean/subpass design
that owns waterline/submerged-object distortion before the opaque ocean surface
hides the object depth that the effect needs.

## Recommended Path

1. Keep `surface_refraction_enabled` default-off in Ocean Lab while Option C is
   being built.
2. Keep the FFT ocean surface opaque and responsible only for surface water:
   waves, foam, surface color, Beer-Lambert tint, SSR/probe/sky reflections,
   and wave-tip SSS.
3. Prototype a `CompositorEffect`-backed waterline pass at
   `EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT` or, if needed, a custom pre-ocean
   capture path. Godot exposes this stage after sky/back-buffer creation and
   before transparent rendering; it is the canonical engine hook for a full
   screen render pipeline effect.
4. Feed that pass the camera, sea level, water normal, absorption constants,
   and eventually a water coverage/mask source. It should distort/tint only
   pixels whose reconstructed world position lies below the water surface or
   inside a narrow waterline band.
5. Reuse the existing underwater shader's world-space normal wobble,
   Beer-Lambert absorption, and caustic texture logic, but port it into the
   compositor shader once the capture order is proven.
6. Leave `UnderwaterVolume` enabled for below-camera underwater view until the
   compositor path replaces it cleanly.

## Non-Goals

- Do not push more silhouette guards into `ocean_fft_common.gdshaderinc` to
  solve half-submerged object distortion.
- Do not make the main FFT ocean surface transparent.
- Do not rely on `render_priority` to reorder a transparent screen-reading
  volume ahead of opaque ocean rendering; that is not what `render_priority`
  controls.
