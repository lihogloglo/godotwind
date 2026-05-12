# Wetness System - Screen-Space Contact + Retained Memory

**Status:** Phase 1 implementation landed 2026-05-09. This supersedes the older
"submersion + terrain wet map" plan.

**Industry basis:** Sebastien Lagarde, *Water drop 3a/3b - Physically based wet
surfaces* (2013). Wet surfaces darken porous diffuse response and become
glossier. In Godot Forward+, the screen-space path can provide a shared
post-lit approximation; true pre-light `ALBEDO`/`ROUGHNESS` changes require
material shader hooks.

---

## 1. Model

Wetness means an **exposed surface with a water film**, not any surface below
the water. Submerged terrain, rocks, and building parts are handled by the
waterline/underwater optics path: absorption, refraction, fog, Snell window,
rays, wobble, and caustics.

Phase 1 has two paths:

- **Live contact:** `WetCompositorEffect` reconstructs visible world position
  from depth, compares it against `WaterSurfaceState`, skips submerged pixels,
  and applies a conservative Lagarde-style post-lit response.
- **Retained memory:** `object_wet.gdshader` uses `wet_line_y` pushed by
  `WetnessManager` for carry objects/characters that stay wet after leaving
  water.

Rain exposure, puddles, splashes, and long-term ground saturation remain future
work. Do not add those by extending the terrain shore/runup model.

---

## 2. Ownership

`WetnessManager` is the single driver:

- Autoload: `WetnessManager="*res://src/core/water/wetness_manager.gd"`.
- Owns defaults: `wet_margin=0.3`, `wet_albedo_darken=0.6`,
  `wet_roughness_target=0.05`, `retained_wetness_strength=0.35`,
  `wet_dry_rate=0.1`.
- Pulls `OceanManager.get_water_surface_state()` on the main thread and pushes
  render-thread-safe values into registered compositor effects.
- Updates retained-memory holders with CPU water samples at center and four XZ
  offsets.

Public API:

```gdscript
func set_enabled(enabled: bool) -> void
func set_debug_mask(enabled: bool) -> void
func register_compositor(effect: PostProcessEffect) -> void
func unregister_compositor(effect: PostProcessEffect) -> void
func register_memory_holder(root: Node3D, material_rids: Array[RID], bottom_local_y: float, sample_radius: float) -> void
func unregister_memory_holder(root: Node3D) -> void
```

`WaterSurfaceState` remains the single water/body contract. RD compute shaders
cannot include the spatial `ocean_surface_common.gdshaderinc`, so
`wet_compositor.glsl` mirrors the waterline compute contract block directly.
Keep those copies aligned when the contract changes.

---

## 3. Rendering Paths

### Screen-Space Compositor

Files:

- `src/core/shaders/effects/wet_compositor_effect.gd`
- `src/core/shaders/compute/wet_compositor.glsl`

Godot requirements:

- `effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT`
- `access_resolved_color = true`
- `access_resolved_depth = true`
- `needs_normal_roughness = true`
- `render_priority = 7`.

The wet pass intentionally runs before transparent water rendering. That keeps
the depth/normal inputs scoped to opaque receiver surfaces instead of the
visible ocean sheet. The waterline/underwater compositor remains
`POST_TRANSPARENT`, after the water surface has rendered.

Per visible pixel:

1. Read resolved depth and reconstruct world position.
2. Decode Forward+ normal/roughness with Godot's
   `normal_roughness_compatibility()` helper.
3. Query the same dynamic FFT + shore water surface/body gate used by the ocean.
4. Wet only the exposed contact band: above-water capillary band through very
   shallow contact.
5. Fade out once `water_depth > submerged_optics_depth` (`0.10m` default).
6. Keep the near-surface glossy/up-normal rejection as a defensive guard for
   any water-like opaque receiver, but do not rely on it to separate the ocean
   sheet from contact surfaces.

The compositor must not become a terrain-only shore/runup model. It never uses
`shore_wet_runup_width`, `footprint_tail`, or `trailing_wet`.

### Terrain3D

`terrain_horizon.gdshader` is now only a Terrain3D material/fallback hook:

- Production wetness comes from the screen-space compositor.
- The terrain shader keeps a tight fallback band behind
  `terrain_wet_fallback_enabled`.
- `HorizonMapManager.push_shore_wave_wetness*()` remains as a compatibility
  no-op for shore mask/bounds plumbing only.

### Retained Object Wetness

`object_wet.gdshader` defaults to `live_contact_from_compositor = true`.

- Live contact no longer happens inside the object shader by default.
- Retained wetness applies Lagarde-style material response from `wet_line_y`.
- The old dynamic water shader path is a fallback for explicit non-compositor
  uses only.

This avoids double darkening/gloss where both the screen-space compositor and
the material shader see the same water contact.

---

## 4. Tests And Verification

Unit coverage:

- `tests/unit/test_wetness_manager.gd` verifies dunking raises retained wetness,
  drying decays it at `wet_dry_rate`, and unregister removes holder state.

Visual coverage:

- `tests/visual/test_ocean_lab.gd` now runs wet compositor before transparent
  water rendering and before the waterline compositor. It exposes the wet debug
  mask through the existing Wetness tab.
- Acceptance: wetness hugs actual water contact, no smeared band inland or
  downshore, submerged terrain is handled by underwater optics, and carried
  test objects stay wet briefly after leaving water.

Shader verification requirements:

1. Delete `.godot/imported/wet_compositor-*.res` and `.md5` after compute
   shader changes.
2. Run Godot `--import`.
3. If visual shader edits appear stale, clear relevant `.godot/shader_cache/`
   entries.
4. Launch visual verification interactively; do not use screenshot automation.

Useful references:

- Godot 4.6 `CompositorEffect`:
  https://docs.godotengine.org/en/4.6/classes/class_compositoreffect.html
- Godot 4.6 `RenderSceneBuffersRD`:
  https://docs.godotengine.org/en/4.6/classes/class_renderscenebuffersrd.html
- Lagarde wet surfaces:
  https://seblagarde.wordpress.com/2013/03/19/water-drop-3a-physically-based-wet-surfaces/
  https://seblagarde.wordpress.com/2013/04/14/water-drop-3b-physically-based-wet-surfaces/
