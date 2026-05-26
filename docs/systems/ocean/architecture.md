# Ocean Architecture

Status: current Godotwind ocean architecture as of 2026-05-26. Source-checked
against the files named in the source-evidence table below.

Scope: this document describes the current project architecture. For stable
Godot renderer rules, use `docs/systems/ocean/godot_4_6_water_rendering_rules.md`.

Update policy: update this file whenever the active ocean surface,
underwater-medium, receiver-waterline, wetness, shore, or ocean verification
architecture changes. Do not preserve stale plan language here if source has
changed.

## Current Shape

Godotwind's water renderer is split into separate responsibilities:

1. `OceanManager` owns the water runtime and publishes `WaterSurfaceState`.
2. `OceanMesh` draws the visible ocean surface as an opaque depth-writing
   surface with either the clipmap or projected-grid mesh path. The active
   clipmap shader is `ocean_fft_opaque.gdshader`; projected mode defines the
   same opaque baseline before including `ocean_fft_common.gdshaderinc`.
3. `SurfaceRefractionLayer` is the quarantined exact-receiver refraction
   prototype. It maintains a water-excluded `PrewaterCaptureRenderer`
   color/depth source and drives `SurfaceRefractionCompositorEffect`, a
   `POST_TRANSPARENT` compute pass that replaces only pixels classified as the
   visible water surface. The compositor samples a controlled receiver
   color/depth source, reconstructs it with renderer-native matrices captured
   from that SubViewport render pass, and uses a waterline-style
   depth-guided receiver ray/depth solve. Ocean Lab still exposes this through
   the `Refraction` diagnostics, but the Godot 4.6 water rendering rules now
   treat it as an exact receiver-waterline tool, not the default open-ocean
   surface-refraction direction. The old spatial overlay shaders are diagnostic
   fallback only and disabled by default.
4. `ocean_fft_common.gdshaderinc` is the shared visible-surface shader include.
   In the active opaque variants, `OCEAN_OPAQUE_BASELINE` excludes Godot
   `hint_screen_texture` / `hint_depth_texture` uniforms so the main surface
   stays out of the screen-reading transparent path.
5. Ocean Lab has a lab-only `Shader: Boujie High` surface option that swaps
   the visible ocean material to the Boujie-derived transparent screen-reading
   shader while keeping Godotwind FFT displacement, shore waves, SSS, foam, and
   spray. It is default-off, disables the separate `SurfaceRefractionLayer`
   while active to avoid double refraction, and is the current practical
   production direction for the next surface-refraction refactor.
   `Boujie Full` is an Ocean Lab preset for evaluating that surface path with
   high-quality underwater medium settings, underwater particulates, live
   contact wetness, spray, and SSR together; it is a visual/test preset, not a
   main-scene default. Receiver waterline is kept out of Boujie Full so the
   underwater medium has one runtime owner.
6. `UnderwaterCompositorEffect` is the accepted water-volume medium path. It
   runs at `POST_TRANSPARENT` and owns absorption, bounded wobble, Snell window
   tinting, and additive caustics. For underwater cameras it shades until the
   ray exits the FFT surface; for above-water cameras it shades only pixels
   whose depth ray enters the FFT water surface before hitting terrain or an
   object. The shader consumes the shared dynamic water-surface contract when a
   valid displacement texture is bound, with shore-mask data supplied to the
   same contract. It falls back to the cached camera water level when dynamic
   surface sampling is disabled. Ocean Lab exposes Snell, particles, and
   caustics toggles alongside absorption and wobble. Particles are a real
   `OceanManager`-owned `UnderwaterParticulates` layer, not a compositor fake.
7. `WaterlineStack`, `PrewaterCaptureRenderer`, and
   `WaterlineCompositorEffect` are present as the receiver-waterline path.
   Ocean Lab keeps direct `WL Inspect`/`WL Replace` controls for diagnosis.
   Waterline can capture receiver source/mask data and expose debug modes, but
   it does not own underwater fog, Snell, wobble, caustics, or Boujie Full
   production visuals.
8. `WetnessManager` owns retained object wetness and can push water-state data
   to the live wetness compositor. When live compositor contact is enabled,
   object wet materials suppress their shader-side live-contact fallback and
   only add retained drying memory. Ocean Lab test objects opt into wetness
   through `WettableObject`/`WetnessManager` and enable the live compositor as
   part of the Boujie Full visual preset. Retained terrain wetness is not accepted
   yet; the production version should use a GPU render-target or compute
   accumulation mask rather than a CPU-side image sweep from gameplay script.

This matches the Godot 4.6 renderer constraints in the water rendering rules:
Boujie-style screen/emission refraction is the practical default direction for
the visible ocean surface, while controlled source buffers remain reserved for
exact receiver-waterline ownership and full-frame underwater treatments remain
compositor-owned.

## Current Water Shader State

There are three visible-surface shader paths in source today:

- `Default` high-quality ocean uses `ocean_fft_opaque.gdshader` in clipmap mode
  and `ocean_fft_projected.gdshader` in projected-grid mode. These are the
  current main-scene/default shaders. They include `ocean_fft_common.gdshaderinc`
  with `OCEAN_OPAQUE_BASELINE`, so they keep FFT displacement, normals, foam,
  shore waves, SSS/Fresnel/specular, debug modes, and lighting in the opaque
  depth-writing path. They do not declare or sample Godot
  `hint_screen_texture` / `hint_depth_texture`.
- `Boujie High` is the current Ocean Lab high-feature surface shader. It uses
  `ocean_boujie_experimental_clipmap.gdshader` or
  `ocean_boujie_experimental_projected.gdshader`, both backed by
  `ocean_boujie_experimental_common.gdshaderinc`. The enum is still named
  `BOUJIE_EXPERIMENTAL` for compatibility, but UI/logging now presents it as
  `Boujie High`. This path keeps the Godotwind FFT mesh/displacement contract
  but switches the fragment optics to Boujie-style perceptual screen-space
  refraction: `hint_screen_texture` / `hint_depth_texture`, distance-faded UV
  offset, depth/roughness mip blur, Beer-Lambert-style absorption, transmitted
  screen color through `EMISSION`, inverse darkening in `ALBEDO`, and foam/contact
  suppression around shore and silhouettes. `ALPHA` is for intentional near/far
  surface fade only, not for refraction opacity.
- `ocean_surface_refraction_clipmap.gdshader` and
  `ocean_surface_refraction_projected.gdshader` are no longer the intended
  surface-refraction path. They are retained as diagnostic fallback for the
  quarantined controlled-source compositor path.

Ocean Lab exposes two separate controls for these states:

- `Shader: Default/Boujie High` is a surface-only toggle. When Boujie High is
  active, Ocean Lab disables `SurfaceRefractionLayer` so the screen-reading
  material and controlled compositor do not double-refract the same surface.
- `Boujie Full: Enable/Disable` is a reversible evaluation preset. Enabling it
  captures the current lab state, switches to Boujie High, disables only the
  separate controlled surface-refraction layer, then enables live contact
  wetness, high underwater quality, absorption, Snell, wobble, caustics, real
  `UnderwaterParticulates`, spray, surface SSR, and environment SSR. Receiver
  waterline remains disabled in Boujie Full; the visible split comes from the
  water surface plus `UnderwaterCompositorEffect`. Disabling it restores the
  previously captured lab state.

Underwater is not owned by the surface shader. The accepted underwater-camera
path is `UnderwaterCompositorEffect` plus `underwater.glsl`, running at
`POST_TRANSPARENT`. It owns absorption fog, bounded wobble, Snell window tinting,
and additive caustics, with caustics gated by a real texture/RID and the active
sun direction. Particles are not faked in that compositor; they are the separate
camera-followed `UnderwaterParticulates` layer owned by `OceanManager`.

Water fog uses the shared `WaterOpticalProfile`: base visibility sets the
artist-facing Beer-Lambert extinction range, while turbidity represents
suspended particle load. Higher turbidity increases the extinction coefficient
and shifts the medium toward the scattering color, so the underwater compositor,
surface absorption, and receiver-waterline diagnostics share the same murkiness
model instead of separate fog sliders.

The controlled-source surface refraction stack remains present but quarantined:
`SurfaceRefractionLayer`, `PrewaterCaptureRenderer`,
`SurfaceRefractionCompositorEffect`, and `surface_refraction.glsl` are exactness
tools for receiver-waterline cases that need explicit color/depth ownership.
They are not the current open-ocean shader direction.

## Source Evidence

| Current claim | Source evidence |
| --- | --- |
| The active clipmap ocean shader defines `OCEAN_OPAQUE_BASELINE` before including the common surface code. | `src/core/water/shaders/ocean_fft_opaque.gdshader:1-9` |
| The active projected-grid ocean shader defines `OCEAN_OPAQUE_BASELINE` before including the common surface code. | `src/core/water/shaders/ocean_fft_projected.gdshader:1-40` |
| The common visible-surface include only declares Godot screen/depth texture uniforms when `OCEAN_OPAQUE_BASELINE` is not defined. | `src/core/water/shaders/ocean_fft_common.gdshaderinc:72-75` |
| The separate surface refraction layer owns the water-excluded source capture, compositor handoff, diagnostic overlay fallback, and runtime status. | `src/core/water/surface_refraction_layer.gd:1-343` |
| The experimental surface refraction compositor runs at `POST_TRANSPARENT`, requests resolved color/depth, consumes explicit source color/depth RIDs plus renderer-native source matrices from the SubViewport capture pass, and exposes mask/reject/debug status. | `src/core/shaders/effects/surface_refraction_compositor_effect.gd:1-563` |
| The experimental surface refraction compute shader samples explicit source color/depth plus the shared water-surface contract, solves a refracted receiver hit against the controlled source depth, proves output and candidate visible-water ownership by camera-ray/dynamic-surface depth agreement, and writes one final owner color for accepted visible-water pixels. | `src/core/shaders/compute/surface_refraction.glsl:1-560`; `src/core/shaders/compute/water_surface_contract.glslinc:1-214` |
| Surface refraction overlay shaders sample `source_color_texture`, not Godot `hint_screen_texture`, but are now diagnostic fallback rather than the production path. | `src/core/water/shaders/ocean_surface_refraction_clipmap.gdshader:1-102`; `src/core/water/shaders/ocean_surface_refraction_projected.gdshader:1-134` |
| The Boujie High Ocean Lab shader is the accepted high-feature surface direction under test: a transparent screen-reading material option backed by MIT-licensed imported textures, compatibility enum naming, and reversible Ocean Lab preset controls that include live wetness and high underwater medium in the full-stack preset. | `src/core/water/shaders/ocean_boujie_experimental_common.gdshaderinc`; `src/core/water/ocean_mesh.gd`; `tests/visual/test_ocean_lab.gd`; `tests/visual/test_ocean_lab_boujie_full_stack_smoke.gd` |
| `OceanManager` creates/owns `OceanMesh` and `ShoreMaskGenerator`. | `src/core/water/ocean_manager.gd:88-100`, `:162-168`, `:1494-1508` |
| `OceanManager.get_water_surface_state()` publishes water body ID, shore mask, shore bounds, FFT/mesh metadata, and callable query contracts. | `src/core/water/ocean_manager.gd:1183-1256`; `src/core/water/water_surface_state.gd:1-76` |
| `OceanMesh` supports clipmap and projected-grid paths and can push shore masks to the material. | `src/core/water/ocean_mesh.gd:56-66`, `:355`, `:494-520` |
| `UnderwaterCompositorEffect` runs at `POST_TRANSPARENT` with resolved color/depth access, exposes absorption/Snell/wobble/caustics feature flags, binds a caustics texture, and pushes dynamic FFT/shore water-surface data to `underwater.glsl`. | `src/core/shaders/effects/underwater_compositor_effect.gd`; `src/core/shaders/compute/underwater.glsl` |
| `OceanManager` owns the separate underwater particulate layer and exposes enable/quality/count/status methods used by Ocean Lab. | `src/core/water/ocean_manager.gd:1382-1461`; `src/core/water/underwater_particulates.gd:1-224` |
| `WaterlineCompositorEffect` runs at `POST_TRANSPARENT`, is receiver-waterline diagnostic code, and hard-disables its underwater-medium feature switches so `UnderwaterCompositorEffect` remains the only water-volume pass. | `src/core/shaders/effects/waterline_compositor_effect.gd`; `src/core/shaders/compute/waterline_probe.glsl` |
| `PrewaterCaptureRenderer` owns explicit capture viewport/camera paths and can expose the viewport texture for spatial overlay consumers or RIDs for compositor consumers. | `src/core/water/prewater_capture_renderer.gd:1-13`, `:99-170`, `:319-376` |
| `WetCompositorEffect` runs at `PRE_TRANSPARENT` with resolved color/depth access. | `src/core/shaders/effects/wet_compositor_effect.gd:58-60`, `:243-253` |
| `WetnessManager` pulls `WaterSurfaceState` and pushes wetness material/compositor parameters. | `src/core/water/wetness_manager.gd:261-334` |
| Retained terrain wetness remains a planned GPU accumulation-mask feature; no CPU terrain wetness map is accepted in the current lab path. | `docs/plans/wetness_system.md`; `src/core/world/terrain_horizon.gdshader`; `src/core/world/horizon_map_manager.gd` |
| Ocean Lab instantiates `SurfaceRefractionLayer`, `WaterlineStack`, wires the underwater effect, exposes Boujie High and Boujie Full controls, enables live wetness in the full-stack preset, and spawns wetness canaries through `WettableObject`/`WetnessManager`. | `tests/visual/test_ocean_lab.gd` |
| World Explorer can force-initialize OceanManager through `OceanControls`, so ocean is tool-accessible from the editor/tool UI. | `src/tools/ui/ocean_controls.gd:50-79`, `:125-144` |

## Accepted Production Policy

The accepted architecture is:

- Visible ocean surface: opaque default remains the current main-scene default
  until the refactor is accepted.
- Boujie High surface shader: lab-only implementation of the accepted practical
  production direction for open-ocean surface refraction. It is useful for
  judging the visual target before promoting a Boujie-style screen/emission
  material path out of Ocean Lab.
- Surface refraction: the current `SurfaceRefractionLayer` plus
  `SurfaceRefractionCompositorEffect` path is experimental/off-by-default, not
  the accepted open-ocean surface architecture. It remains the path to study
  exact receiver-waterline replacement where explicit controlled color/depth
  ownership is required. The old transparent overlay remains only as a
  diagnostic fallback.
- Underwater camera medium: production direction, but still gated by Ocean Lab
  and visual acceptance. Absorption, Snell window tinting, bounded wobble, and
  caustics are implemented in the compositor; underwater particulates are
  implemented as a separate camera-followed particle layer.
- Receiver waterline: diagnostic only. It still requires measured
  source-buffer, mask, latency, and performance contracts before any
  production visual-stack promotion.
- Wetness: separate system. Retained object wetness is the current object-first
  integration path; broad live wetness is enabled in the Ocean Lab full-stack
  preset but remains gated for main-scene promotion. Retained terrain wetness
  still needs a GPU accumulation-mask implementation. Ocean Lab's wet test
  objects use `WettableObject`/`WetnessManager`, not a hand-managed wet-line
  loop.
- Shore: data-driven through shore/depth-mask style data, not fragment discard
  or z-fighting bias.

Do not revive the older "one mega waterline compositor owns surface,
underwater, caustics, particles, wetness, and receiver refraction" architecture
without a new ADR.

## Current Risks

These risks are preserved from the 2026-05-22 "correct way forward" audit and
checked against current source shape where possible:

- Receiver waterline is diagnostic, not accepted final optics. The code still
  contains richer branches, but Ocean Lab should treat binary receiver
  replacement and local receiver medium/film as inspection tools until accepted.
- Receiver path cost is not production-budgeted. It can involve receiver and
  occlusion captures plus a compute compositor.
- Layer contracts are fragile. Receiver, water, and occlusion layers must be
  named and tested before the receiver path can become a default feature.
- Water-surface evaluation exists in multiple places: opaque surface shader,
  surface-refraction overlay shaders, compute shaders, CPU callbacks, shore
  queries, and optional readbacks. New work should
  narrow drift through `WaterSurfaceState`, not add a new independent water
  classifier.
- The current surface-refraction compositor has moved beyond fixed-travel
  shifted-UV recovery and now uses controlled source depth plus a bounded
  receiver ray/depth solve. It is still experimental and no longer the default
  open-ocean surface-refraction direction. Do not tune visual offset constants
  or `refraction_strength` to hide limits that the Boujie-style path avoids by
  using a smaller perceptual screen-space contract.
- Wettable object material replacement is intentionally narrow. Do not broadly
  replace arbitrary materials unless material semantics are preserved.

## Debug Controls

`OceanManager.set_debug_mode()` drives visible-surface shader modes `0..20`.
On the active opaque baseline, modes that historically sampled screen/depth
source data are retained as legacy diagnostics but no longer prove production
surface refraction. Ocean Lab's `Refraction` button and the logged
`surface_refract_*` status rows verify the current experimental compositor
source and mask path only.

Ocean Lab's surface shader row now reports `Default` or `Boujie High`.
`Boujie Full` is reversible: `Enable` captures the current lab state and applies
the high-feature stack, including Boujie surface, live wetness, high underwater
medium, particles, caustics, spray, and SSR; `Disable` restores the captured
state. Receiver waterline remains disabled in this preset. The HUD/log rows
report the preset state plus individual underwater feature flags, caustics
validity, particle status, and compositor timing.

The useful opaque surface modes are:

- `8`: custom SSR hit mask.

Ocean Lab reports the separate surface refraction compositor as two status rows:

- `surface_refract_source_valid`, `depth_valid`, `size`, and `frame_age`:
  whether the water-excluded source color/depth capture is bound, its
  resolution, and its latency in process frames.
- `surface_refract_mask_mode`, `reject`, `overlay`, and `dispatch`: the
  compositor debug/mask mode, high-level reject/source status, whether the
  diagnostic spatial overlay is visible, and the dispatched render size.

For the experimental compositor path, `overlay` should be `false` unless the
diagnostic spatial fallback is being inspected.

`Refract Debug: Pre Absorb` maps to surface-refraction debug mode `5` and shows
the accepted raw candidate source color before Beer-Lambert absorption. It is a
useful diagnostic for the current compositor, but it is not the acceptance gate
for production refraction after the 2026-05-23 controlled-source decision.

`UnderwaterCompositorEffect.set_debug_mode()` drives underwater modes `0..5`:

- `1`: path length.
- `2`: transmittance.
- `3`: underwater hit mask.
- `4`: wobble delta.
- `5`: wobble guard.

`WaterlineCompositorEffect.set_debug_mode()` drives receiver-waterline modes
`0..15`. The useful diagnostic modes are:

- `5`: receiver refraction status.
- `6`: receiver offset and accepted mask.
- `7`: receiver source/depth binding validity.
- `9`: pipeline source/water/mask status.
- `14`: final receiver replacement mask and water gates.

Ocean Lab's `WL Inspect` uses receiver debug mode `14`; `WL Replace` uses debug
mode `0` while leaving the isolated receiver-waterline setup active.

## Next Work

1. Keep this doc and the Godot 4.6 rules doc as the only ocean authority docs.
2. Fix stale references in status/architecture/lighting/audit docs so they
   point here.
3. Keep receiver waterline disabled by default until a dedicated receiver
   waterline ADR answers source buffers, masks, layers, frame age, resolution,
   occlusion depth, and performance budget.
4. Implement the controlled refraction source ADR in Ocean Lab or an Ocean Lab
   clone only for exact receiver-waterline replacement: reuse/refactor the
   existing `PrewaterCaptureRenderer` and `PrewaterCaptureEffect` copy path,
   keep the depth-space contract explicit, and measure source render/copy/final
   sampling costs separately.
5. Promote underwater medium through `UnderwaterCompositorEffect`, not through
   the dormant advanced branches in `waterline_probe.glsl`; keep refining Snell
   and caustics there against visual quality and budget.
6. Promote the Boujie-style surface refraction path from Ocean Lab once free-fly
   visual acceptance and performance are good enough.
7. Integrate only accepted pieces into `world_explorer`: surface first,
   underwater medium second, wetness and receiver waterline only after explicit
   acceptance.

## Verification Requirements

- C# changes: run `dotnet build Godotwind.sln` before launching Godot.
- `.glsl` compute shader changes: delete matching
  `.godot/imported/<shader-name>-*.res` and `.md5`, then run Godot with
  `--import` before visual verification.
- `.gdshader` / `.gdshaderinc` changes: clear relevant shader cache entries if
  edits appear stale before visual verification.
- Visual water changes: run an interactive Ocean Lab or main-scene launch that
  exercises the changed path. Screenshot-only acceptance is not enough.
