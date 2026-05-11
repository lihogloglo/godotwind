# Ocean

Current-state reference for the FFT ocean + buoyancy stack. Source of truth for
what is actually active in code.

---

## Render Pipeline (load-bearing)

This is the order future agents must preserve. Commit
`ad67dcecab2764ab3ef38ec1bf0ac46512aa0142` fixed receiver refraction by
letting the receiver compositor run after the visible ocean, instead of trying
to bend screen color from inside the FFT surface.

1. **FFT ocean surface draws visible water only.**
   `src/core/water/shaders/ocean_fft*.gdshader*` stays fully opaque. It may use
   scene depth for thickness/foam/tint, FFT displacement/normal/foam textures,
   the shore mask, ReflectionProbes, sky, and normal opaque lighting. It must
   not declare `hint_screen_texture`, sample `SCREEN_TEXTURE`, write `ALPHA`, or
   own receiver refraction / custom SSR raymarching.
2. **Pre-water capture records only opt-in receivers.**
   `PrewaterCaptureRenderer` owns the SubViewport/camera/copy path for objects
   that need waterline bending. Ocean Lab's intended mask is
   `WATER_REFRACTION_RECEIVER_LAYER_MASK`, not the main camera mask. When the
   receiver compositor is active, receiver visuals live only on that layer and
   the main camera excludes it. This prevents receiver meshes from writing the
   main viewport depth that the opaque FFT surface uses for thickness. The
   current near-water default band is 80-140m vertical camera-to-water distance,
   reduced resolution by default, and consumers accept up to one rendered frame
   of latency.
3. **The normal scene renders.**
   Terrain, sky, ocean surface, spray, and ordinary objects render through the
   main viewport. They are not receiver-capture inputs unless a future system
   explicitly opts them in.
4. **`WaterlineCompositorEffect` runs at `POST_TRANSPARENT`.**
   This is the `ad67dce` win. The compositor must run after visible water so
   receiver refraction is not buried by the ocean surface. Its receiver
   refraction output domain is visible water pixels: each water pixel samples
   the receiver color/depth capture at a perturbed UV and draws only when that
   sampled receiver point is underwater. Current-UV receiver depth also draws
   the receiver's above-water portion directly from the receiver capture, so the
   object is represented once: direct above the waterline, refracted below it.
   The same compositor combines main scene depth/color and `WaterSurfaceState`
   for underwater-camera optics.
5. **Underwater scene color is a separate source from receiver color.**
   Snell-window / wobble sampling uses post-scene color when needed. The
   receiver capture is only for opt-in receiver objects and must not be treated
   as sky, terrain, or broad above-water scene color.
6. **Wetness is optional/debug quality.**
   `WetCompositorEffect` and wet-line work are not part of the default ocean
   cost. Enable them deliberately for debugging or tuning; do not silently add a
   full-screen wet pass to the normal ocean path.

Do not regress these invariants: no surface `hint_screen_texture`, no surface
`SCREEN_TEXTURE` refraction, no custom SSR in the FFT material by default, no
main-camera prewater capture, no broad wetness pass by default, and no move of
the waterline compositor back before transparent rendering.

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
  `WaterlineCompositorEffect` receiver pass. The pass shades visible water
  pixels and fetches opt-in receiver color/depth from offset UVs, so submerged
  silhouettes can move outside the receiver mesh's original screen footprint.
  Ocean Lab now keeps active receivers off the main camera cull mask and lets
  the compositor draw their direct above-water portion from the receiver capture.
  The FFT surface stays opaque and uses scene depth only for thickness, shore
  foam, and tint. Terrain, sky, water, spray, UI, and broad seafloor helpers are
  not receiver inputs unless a future system explicitly opts them in. The same
  compositor now owns the first
  underwater-camera screen treatment: Snell-window transmission using the
  water-to-air critical angle, path fog/absorption, world-surface-anchored
  faint rays, normal-driven screen wobble, and sparse suspended particulate.
  `UnderwaterVolume` is underwater-camera / diagnostic
  support only.
- **Pre-water receiver capture component** —
  `src/core/water/prewater_capture_renderer.gd` owns the receiver-only
  SubViewport, matching camera, capture compositor, resolution scale, and
  near-water activation used by waterline/underwater compositor work. Activation
  now fades from 80-140m vertical camera-to-sea-level delta instead of using
  animated wave height as a binary pass switch. Consumers sample the most
  recent completed capture texture; the
  contract allows up to one rendered frame of latency and intentionally avoids
  forced GPU syncs.
- **Water-surface state contract** —
  `src/core/water/water_surface_state.gd` is the shared water-surface snapshot
  produced by `OceanManager.get_water_surface_state()`. It carries the GPU
  shader inputs plus typed CPU query callables for height, displacement, and
  normal/gradient sampling, coverage/body classification, shoreline side and
  distance metadata, along with the current query source (`gpu_readback`,
  `cpu_spectrum`, `shore_analytical`, `flat`, or `disabled`) and freshness /
  cascade-readiness metadata. Surface velocity is part of the contract but is
  deliberately unavailable until the wave pipeline publishes true
  dDisplacement/dt data. New water-adjacent systems should consume this state
  before reaching directly into OceanManager internals. Shader consumers use
  the shared final-surface lookup, including horizontal displacement inversion,
  so wetness, waterline, caustics, Snell, rays, particles, and diagnostic
  underwater volume checks classify against the same moving surface.
- **Stable coarse water volume, dynamic optical surface** -- waterline capture
  activation and coarse camera-ray water entry use the mean sea-level/body mask.
  The animated FFT/shore surface is applied after that for height, normals, and
  refraction detail. This prevents low-angle distant waves from toggling the
  whole refraction pass on and off.
- **Shore mask v4 channel contract** -- `shore_mask.r` is only shore/wave
  dampening. `shore_mask.a` stores body membership plus water-side raw distance:
  land is `0.0`, water is `0.5..1.0`, and consumers decode distance with
  `alpha * 2.0 - 1.0`. Waterline, wetness, underwater rays, and CPU coverage
  gates must use alpha-derived body coverage, not the red dampening ramp.
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
- **Reflections via opaque Godot paths, not surface SSR.** The ocean material
  stays in the opaque path and relies on `SPECULAR`, ReflectionProbes, sky, and
  the engine's normal opaque lighting inputs. The old custom in-surface SSR
  trace was removed because it reintroduced `hint_screen_texture`, made the
  surface screen-color-owned again, and added a per-fragment raymarch to the
  hottest water path.
- **Refraction via receiver compositor.** Do not reintroduce surface-owned
  `SCREEN_TEXTURE` bending in `ocean_fft_common.gdshaderinc`. Submerged-object
  distortion belongs to the receiver compositor path, where visible water pixels
  sample opt-in object color/depth from the receiver capture without repainting
  terrain or the whole ocean surface.
- **Pre-water capture as a reusable component.** Scenes should use
  `PrewaterCaptureRenderer` instead of building ad-hoc SubViewport/camera
  chains. It disables the capture viewport when the compositor is off or the
  camera is outside the near-water band, while staying active for underwater
  cameras that need the receiver buffer. It preserves the explicit
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

1. **Waterline compositor still needs visual tuning.** Above-water
   half-submerged-object bending now comes from the receiver-only compositor
   path, not the FFT surface shader. Active receivers no longer imprint the
   main ocean depth/thickness footprint in Ocean Lab; the main camera excludes
   the receiver layer while the compositor writes one coherent receiver result.
   `Final` mode writes direct receiver pixels above the dynamic waterline and
   visible-water pixels with a valid offset sample below it. The compositor runs
   at `POST_TRANSPARENT` so its receiver result is not buried by the visible
   ocean surface.
2. **Underwater POV is compositor-owned, but not final art.** The compositor
   now brightens the underwater ceiling with Snell-window transmission and
   applies underwater absorption, receiver-depth caustics, surface-anchored
   rays, edge-aware FFT-normal wobble, and particulate. Wobble samples are
   guarded against waterline, sky, and depth-edge pulls so high-contrast scene
   edges do not get blindly doubled. The FFT surface shader can still produce a
   flat dark surface color by itself; the compositor is the production owner of
   the underwater camera view.
3. **UnderwaterVolume is not the caustics or refraction owner.** It is kept for
   diagnostic underwater slab/depth/wobble checks only. Ocean Lab prevents its
   final mode from drawing above water and uses dynamic camera water height for
   activation, so it cannot hide or compete with the receiver compositor.
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

2026-05-09 update: Ocean Lab's `UnderwaterVolume` consumes these getters for
tint and extinction sigma only. Caustic strength is compositor-owned through
`WaterSurfaceState` / `WaterlineCompositorEffect`.
