# Wetness Screen-Space Architecture Audit - 2026-05-09

## Verdict

The old terrain-specific shore/runup wetness was the wrong authority. It had a
separate model with `shore_wet_runup_width`, `footprint_tail`, and
`trailing_wet`, which could smear wetness away from the actual water/surface
contact. Terrain3D still needs a shader hook because Terrain3D owns its own
material plumbing, but the waterline decision belongs to the shared water
contract.

The adopted model is:

- Use `WaterSurfaceState` as the single source of water height/body coverage.
- Reconstruct visible world position from depth in a compositor.
- Apply live wetness only to exposed contact bands.
- Let underwater/waterline optics handle submerged surfaces.
- Keep retained material wetness for objects/characters that can leave water.
- Run the live wetness compositor at `PRE_TRANSPARENT` so its depth and
  normal/roughness inputs describe opaque receivers, not the visible FFT ocean
  sheet.

## Godot Constraint

Godot 4.6 `CompositorEffect` supports resolved color/depth and Forward+
normal/roughness buffers, including `needs_normal_roughness`. That makes the
screen-space contact mask canonical for broad world wetness.

The callback slot matters. `POST_TRANSPARENT` sees the rendered ocean surface in
the resolved depth buffer, which turns the water clipmap/projected-grid
footprint into a fake wet receiver and produces broad dark bands. `PRE_TRANSPARENT`
keeps the mask on the opaque scene and lets the later waterline compositor own
water optics.

A compositor runs after material lighting, so it cannot literally change every
surface's pre-light BRDF roughness. The practical split is:

- screen-space compositor: shared live-contact mask and post-lit fallback;
- material shader hooks: real `ALBEDO`/`ROUGHNESS` response where needed;
- retained memory: per-object material shader state.

Stencil carve-outs were deferred because the v1 split avoids double wetting:
live contact is compositor-owned and retained memory is material-owned. If a
future material also owns live contact, stencil or another explicit mask should
be prototyped against Godot 4.6 first.

## Implementation Notes

- `terrain_horizon.gdshader` no longer evaluates terrain shore-wave wetness.
- `HorizonMapManager.push_shore_wave_wetness*()` is compatibility plumbing only.
- `object_wet.gdshader` defaults to `live_contact_from_compositor = true`.
- `wet_compositor.glsl` mirrors the compute-side water surface contract used by
  `waterline_probe.glsl`, because RD compute shader imports do not share spatial
  `.gdshaderinc` includes.

References:

- Godot 4.6 `CompositorEffect`:
  https://docs.godotengine.org/en/4.6/classes/class_compositoreffect.html
- Godot 4.6 `RenderSceneBuffersRD`:
  https://docs.godotengine.org/en/4.6/classes/class_renderscenebuffersrd.html
- Sebastien Lagarde wet-surface model:
  https://seblagarde.wordpress.com/2013/03/19/water-drop-3a-physically-based-wet-surfaces/
  https://seblagarde.wordpress.com/2013/04/14/water-drop-3b-physically-based-wet-surfaces/
