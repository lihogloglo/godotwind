# Ocean Architecture

Status: current Godotwind ocean architecture as of 2026-05-23. Source-checked
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
3. `SurfaceRefractionLayer` is the separate above-water refraction owner. It
   maintains a water-excluded `PrewaterCaptureRenderer` color/depth source and
   drives `SurfaceRefractionCompositorEffect`, a `POST_TRANSPARENT` compute
   pass that replaces only pixels classified as the visible water surface. The
   classifier intersects the camera ray with the dynamic water surface and
   requires that hit to agree with the main depth buffer for both the output
   pixel and the shifted candidate UV, so nearby object silhouettes are not
   accepted just because they are close to the water level or because a
   refracted lookup crosses onto them.
   Ocean Lab wires the `Refraction` button to this compositor path; the old
   spatial overlay shaders are diagnostic fallback only and disabled by
   default.
4. `ocean_fft_common.gdshaderinc` is the shared visible-surface shader include.
   In the active opaque variants, `OCEAN_OPAQUE_BASELINE` excludes Godot
   `hint_screen_texture` / `hint_depth_texture` uniforms so the main surface
   stays out of the screen-reading transparent path.
5. `UnderwaterCompositorEffect` is the accepted underwater-camera medium path.
   It runs at `POST_TRANSPARENT` and owns absorption plus bounded wobble. The
   current shader also consumes the shared dynamic water-surface contract
   when a valid displacement texture is bound, with shore-mask data supplied to
   the same contract. It falls back to the cached camera water level when
   dynamic surface sampling is disabled.
6. `WaterlineStack`, `PrewaterCaptureRenderer`, and
   `WaterlineCompositorEffect` are present as a receiver-waterline path, but
   Ocean Lab treats that path as opt-in/diagnostic rather than production
   default.
7. `WetnessManager` owns retained object wetness and can push water-state data
   to the live wetness compositor. Ocean Lab currently enables retained wetness
   while keeping the live compositor off by default, and also keeps a few local
   manual wetness canaries for visual/debug coverage.

This matches the Godot 4.6 renderer constraints in the water rendering rules:
screen-texture surface refraction is useful but limited, while controlled
source buffers, final-frame treatments, and receiver-specific effects need
explicit compositor/capture ownership.

## Source Evidence

| Current claim | Source evidence |
| --- | --- |
| The active clipmap ocean shader defines `OCEAN_OPAQUE_BASELINE` before including the common surface code. | `src/core/water/shaders/ocean_fft_opaque.gdshader:1-9` |
| The active projected-grid ocean shader defines `OCEAN_OPAQUE_BASELINE` before including the common surface code. | `src/core/water/shaders/ocean_fft_projected.gdshader:1-40` |
| The common visible-surface include only declares Godot screen/depth texture uniforms when `OCEAN_OPAQUE_BASELINE` is not defined. | `src/core/water/shaders/ocean_fft_common.gdshaderinc:72-75` |
| The separate surface refraction layer owns the water-excluded source capture, compositor handoff, diagnostic overlay fallback, and runtime status. | `src/core/water/surface_refraction_layer.gd:1-343` |
| The production surface refraction compositor runs at `POST_TRANSPARENT`, requests resolved color/depth, consumes explicit source color/depth RIDs, and exposes mask/reject/debug status. | `src/core/shaders/effects/surface_refraction_compositor_effect.gd:1-563` |
| The surface refraction compute shader samples explicit source color/depth plus the shared water-surface contract, proves output and shifted-candidate visible-water ownership by camera-ray/dynamic-surface depth agreement, and writes one final owner color for accepted visible-water pixels. | `src/core/shaders/compute/surface_refraction.glsl:1-350`; `src/core/shaders/compute/water_surface_contract.glslinc:1-214` |
| Surface refraction overlay shaders sample `source_color_texture`, not Godot `hint_screen_texture`, but are now diagnostic fallback rather than the production path. | `src/core/water/shaders/ocean_surface_refraction_clipmap.gdshader:1-102`; `src/core/water/shaders/ocean_surface_refraction_projected.gdshader:1-134` |
| `OceanManager` creates/owns `OceanMesh` and `ShoreMaskGenerator`. | `src/core/water/ocean_manager.gd:88-100`, `:162-168`, `:1494-1508` |
| `OceanManager.get_water_surface_state()` publishes water body ID, shore mask, shore bounds, FFT/mesh metadata, and callable query contracts. | `src/core/water/ocean_manager.gd:1183-1256`; `src/core/water/water_surface_state.gd:1-76` |
| `OceanMesh` supports clipmap and projected-grid paths and can push shore masks to the material. | `src/core/water/ocean_mesh.gd:56-66`, `:355`, `:494-520` |
| `UnderwaterCompositorEffect` runs at `POST_TRANSPARENT` with resolved color/depth access, exposes absorption/wobble toggles, and pushes dynamic FFT/shore water-surface data to `underwater.glsl`. | `src/core/shaders/effects/underwater_compositor_effect.gd:70-75`, `:121-141`, `:149-171`, `:285-360`; `src/core/shaders/compute/underwater.glsl:9-48`, `:67-80`, `:151-166` |
| `WaterlineCompositorEffect` runs at `POST_TRANSPARENT`, is receiver-waterline code, and carries binary receiver/refraction/medium/film switches. | `src/core/shaders/effects/waterline_compositor_effect.gd:1-12`, `:116-123`, `:347-360`, `:436-559` |
| `PrewaterCaptureRenderer` owns explicit capture viewport/camera paths and can expose the viewport texture for spatial overlay consumers or RIDs for compositor consumers. | `src/core/water/prewater_capture_renderer.gd:1-13`, `:99-170`, `:319-376` |
| `WetCompositorEffect` runs at `PRE_TRANSPARENT` with resolved color/depth access. | `src/core/shaders/effects/wet_compositor_effect.gd:58-60`, `:243-253` |
| `WetnessManager` pulls `WaterSurfaceState` and pushes wetness material/compositor parameters. | `src/core/water/wetness_manager.gd:261-334` |
| Ocean Lab instantiates `SurfaceRefractionLayer`, `WaterlineStack`, wires the underwater effect, keeps live wetness off when retained wetness is enabled, and also spawns local manual wetness canaries plus a managed `WettableObject` canary. | `tests/visual/test_ocean_lab.gd:416-553`, `:595-620`, `:1210-1221`, `:2142-2147` |
| World Explorer can force-initialize OceanManager through `OceanControls`, so ocean is tool-accessible from the editor/tool UI. | `src/tools/ui/ocean_controls.gd:50-79`, `:125-144` |

## Accepted Production Policy

The accepted architecture is:

- Visible ocean surface: production path, opaque by default.
- Surface refraction: opt-in compositor path. It must remain a separate layer
  with explicit water-excluded color/depth capture and `POST_TRANSPARENT`
  compute ownership; do not move it back into the main ocean material. The
  production path chooses one final visible owner per accepted water-surface
  pixel: either refracted submerged source or untouched opaque ocean. The old
  transparent overlay remains only as a diagnostic fallback.
- Underwater camera medium: production direction, but still gated by Ocean Lab
  and visual acceptance.
- Receiver waterline: experimental/quarantined until promoted by a dedicated
  plan with measured source-buffer, mask, latency, and performance contracts.
- Wetness: separate system. Retained object wetness is the current object-first
  integration path; broad live wetness remains gated. Ocean Lab's hand-managed
  wet test objects are diagnostics, not a framework integration pattern.
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
- Surface refraction now owns source and pixel selection, but still needs
  visual/performance tuning. The compositor classifies visible water pixels by
  matching the main depth buffer against a dynamic camera-ray water hit, then
  repeats that ownership test at the shifted candidate UV before sampling the
  explicit source color/depth. Candidate UVs that land on already-visible
  foreground/object pixels are rejected, so the final pass does not preserve a
  straight object silhouette and a shifted copy.
- Wettable object material replacement is intentionally narrow. Do not broadly
  replace arbitrary materials unless material semantics are preserved.

## Debug Controls

`OceanManager.set_debug_mode()` drives visible-surface shader modes `0..20`.
On the active opaque baseline, modes that historically sampled screen/depth
source data are retained as legacy diagnostics but no longer prove production
surface refraction. Use Ocean Lab's `Refraction` button and the logged
`surface_refract_*` status rows to verify the separate compositor source and
mask path.

The useful opaque surface modes are:

- `8`: custom SSR hit mask.

Ocean Lab reports the separate surface refraction compositor as two status rows:

- `surface_refract_source_valid`, `depth_valid`, `size`, and `frame_age`:
  whether the water-excluded source color/depth capture is bound, its
  resolution, and its latency in process frames.
- `surface_refract_mask_mode`, `reject`, `overlay`, and `dispatch`: the
  compositor debug/mask mode, high-level reject/source status, whether the
  diagnostic spatial overlay is visible, and the dispatched render size.

For the production compositor path, `overlay` should be `false`.

`Refract Debug: Pre Absorb` maps to surface-refraction debug mode `5` and shows
the accepted raw candidate source color before Beer-Lambert absorption. It
should no longer show shifted object silhouettes where the shifted candidate UV
is not water-owned; those pixels should instead appear in the reject color for
"shifted candidate UV is not water-owned."

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
4. Stabilize the accepted surface path: measured custom SSR, consistent sun
   direction, shore fade preservation, projected/clipmap parity for the
   compositor-owned refraction path, mask-quality tuning, and removal or
   population of unused contract fields.
5. Promote underwater medium through `UnderwaterCompositorEffect`, not through
   the dormant advanced branches in `waterline_probe.glsl`.
6. Integrate only accepted pieces into `world_explorer`: surface first,
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
