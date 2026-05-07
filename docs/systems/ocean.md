# Ocean

Current-state reference for the FFT ocean + buoyancy stack. Source of truth for
what is actually active in code.

---

## Shipped

- **Opaque rendering** — `src/core/water/shaders/ocean_fft.gdshader`. Fully
  opaque render queue (no ALPHA). GodotOceanWaves-style roughness-dependent
  Fresnel `5.0 * exp(-2.69 * roughness)`, roughness increases at grazing angles
  to hide horizon aliasing, SPECULAR modulated by Fresnel, shore transition via
  color blend, `v_flat_pos` (undisplaced) for depth comparisons so wave crests
  don't false-discard, foam distance fade, distance-based normal flattening.
- **GPU-readback buoyancy** — `src/core/water/wave_generator.gd`
  `read_displacement(cascade_index)` copies the cascade-0 displacement texture
  out via `texture_get_data()`. `src/core/water/ocean_manager.gd` bilinearly
  samples the RGBA16F CPU copy and derives normals by finite differences.
  Constant 512KB readback per frame regardless of query count. Fallback chain:
  GPU readback → `OceanPhysicsEvaluator` → `GerstnerMath`.
- **BuoyancyBody3D** — `src/core/water/buoyancy_body.gd`, extends `RigidBody3D`.
  Multi-probe sampling (forces at probe positions yield natural torque),
  non-linear depth response (`pow(depth, buoyancy_power)`), hydrodynamic linear
  and angular drag proportional to submersion, distributed-gravity mode for
  boats so mass distribution creates listing. Jolt-compatible — uses the
  standard `apply_force(force, offset)` API (Jolt's `ApplyBuoyancyImpulse` is
  not exposed to GDScript in 4.6).
- **BuoyancyProbe3D** — `src/core/water/buoyancy_probe.gd`, extends `Marker3D`.
  Lightweight sampling point with per-probe `buoyancy_multiplier`, tracks depth
  and submersion state.
- **Real Beer-Lambert absorption** — view-space thickness reconstructed from
  `DEPTH_TEXTURE` via the canonical Godot reversed-Z formula
  `bg_view_z = -PROJECTION_MATRIX[3][2] / max(bg_ndc_z, 1e-5)`. Per-channel
  transmittance `exp(-thickness * absorption_rate * absorption_density)`.
  Sky-depth guard skips the SCREEN_TEXTURE sample when
  `raw_thickness >= max_visible_depth` so sky doesn't bleed through refraction.
- **Refraction UV offset with six rejection guards** — view-space ray stepping
  with `refract(-VIEW, NORMAL, 1/1.333)`. Guards, cheapest-first:
  1. Total internal reflection (refract() returned zero).
  2. Off-screen candidate UV.
  3. Sky reject (candidate depth near far plane).
  4. Above-surface view-Z check.
  5. Silhouette depth-contrast rejection (`|cand_view_z - bg_view_z| < 1.5m`).
  6. **World-Y < sea_level** via full `INV_PROJECTION_MATRIX *
     INV_VIEW_MATRIX` reconstruction. This is the load-bearing guard —
     view-space "behind the water surface" is NOT the same as world-space
     "below sea_level". Tall objects poking above the waterline (pillar tops,
     monolith tops) were otherwise view-space-behind-surface but
     world-space-above, so the refracted sample dragged their above-water
     pixels into underwater regions. This was the root cause of the "wobble
     overlaid on straight mesh" double-vision artifact. `sea_level` is pushed
     by `OceanManager._update_shader_parameters()` via
     `mat.set_shader_parameter(&"sea_level", sea_level)`.
- **Option C refraction split started** — `surface_refraction_enabled` now gates
  only the UV offset in the FFT surface shader. Beer-Lambert transmission still
  samples the unshifted scene color behind the water when refraction is disabled,
  so underwater objects remain readable without reintroducing surface-owned
  wobble. Submerged-object wobble, waterline transition, underwater fog, and
  caustics are moving to the underwater volume / compositor path.
- **Custom in-shader SSR trace** — ported verbatim from
  `inspos/GodotSSRWater-main/shaders/water.gdshader`. Helpers all prefixed
  `ssr_` and live in `ocean_fft_common.gdshaderinc` (included by `ocean_fft.gdshader`): `ssr_in_screen`, `ssr_view_to_uv`,
  `ssr_uv_to_view`, `ssr_edge_alpha`, `ssr_trace`. Uniforms in
  `group_uniforms ssr`: `ssr_max_steps=24`, `ssr_resolution=1.5`,
  `ssr_max_travel=30.0`, `ssr_max_diff=4.0`, `ssr_mix_strength=0.7`,
  `ssr_screen_border_fadeout=0.3`. Distance LOD quarters the step count past
  500m via `smoothstep(50, 500, dist)`. Fresnel-weighted mix, additive on top
  of `SPECULAR = 0.5` (ReflectionProbe + sky cube contributions still reach
  the surface via the native path).

Native Godot 4.6 SSR is disabled on this material because declaring
`hint_depth_texture` + `hint_screen_texture` as uniforms kills SSR pipeline
ordering — the custom in-shader SSR trace replaces it.

---

## Architecture Decisions

- **Fully opaque ocean.** No ALPHA anywhere. Shore transition via color blend +
  discard. Follows GodotOceanWaves.
- **Reflections via custom SSR trace + ReflectionProbe + sky cube.** Native
  SSR is mutually exclusive with refraction sampling on a single Forward+
  material. We pay the cost for refraction and restore object reflections via
  a raymarched custom SSR pass.
- **Refraction via view-space ray-step-and-project-back.** Six-guard chain
  including the critical world-Y-below-sea_level reconstruction. Do NOT switch
  to the simpler "normal XY as SCREEN_UV offset" technique used by
  `visual_water.gdshader` — it tears at the steep slopes of FFT crests.
- **Canonical Godot reversed-Z formula** for depth→view-space-Z reconstruction:
  `-PROJECTION_MATRIX[3][2] / max(bg_ndc_z, 1e-5)`. NOT full
  `INV_PROJECTION_MATRIX * clip` — that pattern blows up near the near plane
  even with an `abs(w)*sign(w)` clamp, producing nonsense values that push
  `raw_thickness > max_visible_depth` and cause seafloor clipping close to
  camera.
- **GPU readback for buoyancy.** `texture_get_data()` on cascade 0. Exact
  match with the visual. ManickYoj rate-limits to 10Hz; we do 60Hz because the
  cost is acceptable on an RTX 4060.
- **Jolt via standard API.** `RigidBody3D.apply_force(force, offset)` works
  with Jolt. Jolt's `ApplyBuoyancyImpulse` is not exposed to GDScript in 4.6.
- **Shore mask retained.** Vertex-stage wave dampening + CPU `is_in_ocean()`
  queries.
- **`v_flat_pos` for depth.** Undisplaced sea-level position avoids false
  shore detection at wave crests.
- **`OceanPhysicsEvaluator` kept as fallback.** Hash mismatch means it doesn't
  perfectly match the GPU, but still useful if readback fails or is disabled.

---

## Known Limitations (shipped)

1. **Waterline discontinuity on half-submerged objects.** Above-water portions
   of submerged objects (pillar tops, monolith top half) are drawn directly by
   the opaque pass without refraction; below-water portions are shown via the
   refracted SCREEN_TEXTURE sample. At the waterline, the two don't align
   perfectly. This is physically correct ("straw in a glass") but reads as a
   visible seam. Mitigations possibly: fade refraction to zero near the
   waterline, or apply matching refraction to the meniscus. Not investigated.
2. **Underwater POV of ocean surface is flat dark `color_deep`.** When the
   camera is below the water looking up, the ocean-surface fragment's
   Beer-Lambert path sees sky at `DEPTH_TEXTURE`, the sky-guard fires, and the
   fallback is `color_deep`. Should be a Snell's-window bright-spot. Backlog;
   coordinated with the `underwater` track — their volume shader's slab test
   leaves these pixels alone so the fix drops in independently.
3. **Refraction tuning is a balance act.** Defaults (`refraction_strength=0.6`,
   `max_refr_thickness=1.5m`, `refraction_silhouette_threshold=1.5m`,
   `max_visible_depth=20m`) were picked after higher strengths reintroduced
   silhouette artifacts even with the six-guard chain, and lower strengths
   were "invisible". Current is visible but subtle.

---

## Future Improvements

### Buoyancy
- Hydrodynamic drag improvements: 6-axis model
  (axial/lateral/vertical/yaw/pitch/roll) per ManickYoj.
- `texture_get_data_async()` (Godot 4.4+) for non-blocking readback.
- Volumetric cell mode for large ships (partial submersion based on cell
  volume).
- Horizontal displacement correction (iterative, per tessarakkt).
- Cascade filtering: large boats ignore small detail cascades.

### Shared absorption via OceanManager typed getters
`get_absorption_tint()`, `get_absorption_sigma()`,
`get_absorption_depth_falloff()` so the surface shader and the underwater
compositor effect read the same values — keeps the waterline transition
continuous as weather / time-of-day / fog change. Pre-agreed with the
`underwater` track.

2026-05-07 update: Ocean Lab's `UnderwaterVolume` now consumes these getters
for tint, extinction sigma, and caustic strength. The eventual compositor
prototype should use the same typed API rather than introducing another
water-color stack.
