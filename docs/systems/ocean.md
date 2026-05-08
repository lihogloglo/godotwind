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
  GPU readback → `OceanPhysicsEvaluator` → flat sea level plus analytical shore swash.
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
- **Real Beer-Lambert absorption tint** — view-space thickness reconstructed from
  `DEPTH_TEXTURE` via the canonical Godot reversed-Z formula
  `bg_view_z = -PROJECTION_MATRIX[3][2] / max(bg_ndc_z, 1e-5)`. Per-channel
  transmittance `exp(-thickness * absorption_rate * absorption_density)` drives
  water color only. The FFT surface no longer declares `hint_screen_texture`;
  submerged-object bending is not owned by this material.
- **Receiver-only waterline refraction split** — above-water
  half-submerged-object distortion is owned by an opt-in
  `WaterlineCompositorEffect` receiver pass. The FFT surface stays opaque and
  uses scene depth only for thickness, shore foam, and tint. Terrain, sky,
  water, spray, UI, and broad seafloor helpers are not receiver inputs unless a
  future system explicitly opts them in. `UnderwaterVolume` is
  underwater-camera/diagnostic support only.
- **Pre-water receiver capture component** —
  `src/core/water/prewater_capture_renderer.gd` owns the receiver-only
  SubViewport, matching camera, capture compositor, resolution scale, and
  near-water activation used by waterline/underwater compositor work. Consumers
  sample the most recent completed capture texture; the contract allows up to
  one rendered frame of latency and intentionally avoids forced GPU syncs.
- **Water-surface state contract** —
  `src/core/water/water_surface_state.gd` is the shared water-surface snapshot
  produced by `OceanManager.get_water_surface_state()`. It carries the GPU
  shader inputs plus typed CPU query callables for height, displacement, and
  normal sampling, along with the current query source (`gpu_readback`,
  `cpu_spectrum`, `shore_analytical`, `flat`, or `disabled`) and readback
  budget metadata. New water-adjacent systems should consume this state before
  reaching directly into OceanManager internals.
- **Native/probe/sky reflections** — the FFT surface remains opaque and avoids
  sampling scene color directly. Reflections come through Godot's normal opaque
  reflection path (`SPECULAR`, ReflectionProbe, and sky), while waterline
  refraction is owned by the receiver compositor.
- **Sea spray layer** — `src/core/water/ocean_spray.gd` owns a camera-centered
  `GPUParticles3D` system with shader-driven spawn/cull. The particle shader
  samples the existing FFT displacement and normal/foam texture arrays: foam is
  the primary spawn signal, normal slope filters out broad flat foam, and a
  lower-weight choppiness/height fallback keeps extreme crests from going dead.
  Candidate particles are distributed in a world-space square around the
  camera, rejected on the GPU, wind-biased, distance-faded, and disabled when
  FFT or weather energy is unavailable. The draw shader uses
  `src/core/water/textures/sea_spray.png` from GodotOceanWaves when present,
  with a procedural fallback, and dissolves particles over their lifetime so
  they atomize instead of popping. Particle size now varies per candidate:
  mostly small wisps, some medium sheets, and rare larger bursts, with
  independent width/height aspect variation.

Native Godot 4.6 SSR is not relied on for the ocean material. Declaring both
depth and screen textures on the surface caused fragile ordering, so the
surface owns opaque water color and the waterline compositor owns receiver
refraction.

---

## Architecture Decisions

- **Fully opaque ocean.** No ALPHA anywhere. Shore transition via color blend +
  discard. Follows GodotOceanWaves.
- **Reflections via custom SSR trace + ReflectionProbe + sky cube.** Native
  SSR is brittle on the ocean material once depth/screen textures are involved,
  so nearby reflections use the custom raymarched trace.
- **Refraction via receiver compositor.** Do not reintroduce surface-owned
  `SCREEN_TEXTURE` bending in `ocean_fft_common.gdshaderinc`. Submerged-object
  distortion belongs to the receiver compositor path, where opt-in object
  color/depth can be captured separately without repainting terrain or the
  whole ocean surface.
- **Pre-water capture as a reusable component.** Scenes should use
  `PrewaterCaptureRenderer` instead of building ad-hoc SubViewport/camera
  chains. It disables the capture viewport when the compositor is off or the
  camera is outside the near-water band, and it preserves the explicit
  render-order/latency contract for later production underwater passes.
- **Godot transparent screen-texture constraint.** Godot copies 3D screen
  textures after opaque rendering and before transparent rendering. Transparent
  screen-reading water is therefore not the production architecture for
  Godotwind; the opaque ocean owns the surface, and the receiver compositor
  owns the narrow submerged-object overlay.
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
- **Spray is a separate toggleable layer.** It does not add new FFT generation
  work, but it does add particle-shader texture sampling and draw cost. Use
  Ocean Lab's `Spray` / `Spray Q` buttons or the main console command
  `ocean_spray [on|off|status]` (`spray` alias) for visual and performance
  A/B testing. Status reports enabled/emitting state, quality, candidate count,
  weather energy, and FFT availability.

---

## Known Limitations (shipped)

1. **Waterline compositor still prototype-quality.** Above-water
   half-submerged-object bending now comes from the receiver-only compositor
   path, not the FFT surface shader. `Final` mode requires valid receiver
   depth and visible water in the main view, so empty ocean pixels and terrain
   stay as the opaque surface rendered them. The compositor runs at
   `PRE_TRANSPARENT`: after opaque rendering and before transparent spray or
   diagnostic volumes.
2. **Underwater POV of ocean surface is flat dark `color_deep`.** When the
   camera is below the water looking up, the ocean-surface fragment's
   Beer-Lambert path sees sky at `DEPTH_TEXTURE`, the sky-guard fires, and the
   fallback is `color_deep`. Should be a Snell's-window bright-spot. Backlog;
   coordinated with the `underwater` track — their volume shader's slab test
   leaves these pixels alone so the fix drops in independently.
3. **UnderwaterVolume is not the above-water refraction owner.** It is kept for
   underwater-camera tint/caustics and debug visualizations. Ocean Lab prevents
   its final mode from drawing above water and uses dynamic camera water height
   for activation, so it cannot hide or compete with the receiver compositor.
4. **Sea spray cost is candidate-count driven.** The foam-driven spawn path is
   more expensive than the earlier choppiness-only prototype because each
   candidate samples normal/foam data as well as displacement, and active
   particles follow the surface for their lifetime. The normal/foam maps are
   already produced for the ocean, so the added cost is particle shader work,
   not extra FFT compute. First tuning knob is `Spray Q` / candidate count.

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
