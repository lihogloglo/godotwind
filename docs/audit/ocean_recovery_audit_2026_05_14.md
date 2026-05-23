# Ocean Recovery Audit - 2026-05-14

Status: historical audit. Use `docs/systems/ocean/architecture.md` for current
Godotwind architecture and
`docs/systems/ocean/godot_4_6_water_rendering_rules.md` for fact-checked Godot
4.6 renderer guidance. This file is retained for lineage, not as current
implementation authority.

Scope: source and git-history audit from `e13ee7de28efcfc8efbd815a53639f181d3c3f88`
through `7e678e4`, plus the current dirty worktree. No shader/code behavior is
changed by this document.

The short version: this is not one broken ocean shader. It is two and a half
water architectures partially stacked on top of each other.

## Executive Summary

Since `e13ee7d`, ocean work repeatedly moved ownership between:

- visible FFT ocean surface shader;
- receiver-only prewater capture plus waterline compositor;
- underwater compositor / underwater volume paths;
- wetness and terrain/object contact systems.

The current Ocean Lab path is:

1. `OceanManager` owns FFT state and publishes `WaterSurfaceState`.
2. `OceanMesh` draws the visible ocean.
3. `ocean_fft_common.gdshaderinc` directly samples Godot screen/depth textures
   for above-water refraction, Beer-Lambert absorption, and custom SSR.
4. `tests/visual/test_ocean_lab.gd` instantiates `UnderwaterCompositorEffect`
   for a cheap underwater absorption/wobble pass.
5. The `WaterlineStack` / `PrewaterCaptureRenderer` /
   `WaterlineCompositorEffect` path is now available in Ocean Lab behind an
   off-by-default receiver waterline toggle. It is still skipped by
   `ShaderManager` effect discovery and is not part of the default baseline.

Session update 2026-05-14:

- `tests/visual/test_ocean_lab.gd` now starts with surface refraction disabled
  and the underwater medium disabled.
- `src/core/shaders/effects/underwater_compositor_effect.gd` now receives FFT
  displacement, shore mask, map scales, wave scale, ocean time, shore bounds,
  and shore wave parameters from `WaterSurfaceState`.
- `src/core/shaders/compute/underwater.glsl` now includes
  `water_surface_contract.glslinc` and uses dynamic water-level queries for
  camera submersion, hit classification, and surface-exit path length.
- `WaterlineStack` is now wired into Ocean Lab as an off-by-default receiver
  waterline toggle. The lab forces this path into binary direct-receiver
  replacement: no Snell, no caustics, no wobble, no particles, and no receiver
  refraction.

Practical effect: several features that look "implemented" are not part of the
default baseline. Snell window, compositor caustics, advanced underwater
wobble, and receiver refraction mostly live in `waterline_probe.glsl`, while
the lab starts on the simpler surface-only view unless the receiver or
underwater toggles are enabled.

## The Core Problem

The project has been trying to solve three different problems in one place:

- Surface water: what the ocean sheet itself looks like.
- Receiver waterline/refraction: how opaque objects crossing water are bent,
  tinted, hidden, or revealed.
- Underwater camera medium: what the whole frame looks like when the camera is
  below the water surface.

Those are separate renderer responsibilities. The churn began when the surface
shader was asked to solve receiver waterline and underwater medium problems
using only Godot's screen/depth textures.

Godot 4.6 constraints matter here:

- Official screen-reading shader docs say the 3D screen texture is copied after
  opaque geometry and before transparent geometry. It does not capture
  transparent objects, and can include opaque objects in front of the
  screen-reading material.
  Reference: https://docs.godotengine.org/en/4.6/tutorials/shaders/screen-reading_shaders.html
- The same docs say 3D materials using `hint_screen_texture` are themselves
  treated specially and cannot force a second useful 3D screen copy.
- Depth texture reads are non-linear and must be reconstructed with
  `INV_PROJECTION_MATRIX`.
- Godot's compositor is the right family for custom full-screen render stages,
  but it runs on the render thread and must be treated as render-pipeline code,
  not ordinary gameplay glue.
  Reference: https://docs.godotengine.org/en/4.6/classes/class_compositoreffect.html

So the surface shader can do good bounded screen-space tricks, but it cannot be
the final authority for every waterline/underwater effect.

## Commit Timeline

### Baseline Before The Loop

`f0b5192` - "correct terrain textures, ocean water thickness solved"

Useful baseline for depth-derived water thickness. This is the last clear
"thickness solved" marker before the refraction loop.

`e13ee7d` - "refraction on the way"

The surface shader already had `SCREEN_TEXTURE`, `DEPTH_TEXTURE`, custom SSR,
Beer-Lambert, SSS, shore dampening, and depth-driven foam. This commit is not a
clean pre-refraction state; it is the beginning of surface-shader refraction
experimentation.

### First Waterline/Refraction Loop

`bf406ee`, `389083b`, `97fac3c`, `34346d3`, `09ce68a`, `277b15e`,
`48e38dd`

What changed:

- `waterline_probe.glsl` and `WaterlineCompositorEffect` appeared.
- Prewater capture experiments started.
- SSR and waterline were repeatedly fixed, broken, and re-fixed.
- Commit message `48e38dd` says "back to square one", which is an important
  history marker.

Salvage:

- `09ce68a` is a useful "SSR fixed, waterline fixed" reference.
- `277b15e` is the best shore-wave shape reference: skewed crest, broad trough,
  shore-aligned push, modulation, slope contribution, and `v_shore_choppiness`.

### Spray

`e8c819e` - "wave spray"

This is mostly independent and still worth keeping. The spray stack is
well-isolated:

- `src/core/water/ocean_spray.gd`
- `src/core/water/shaders/ocean_spray_particles.gdshader`
- `src/core/water/shaders/ocean_spray_billboard.gdshader`
- `tests/visual/test_ocean_spray_smoke.tscn`

Do not mix spray recovery with refraction recovery unless the shared water
surface state changes.

### Major Cleanup / Gerstner Removal

`a44a289` - "cleaned up ocean"

What changed:

- Deleted old `gerstner_math.gd`.
- Deleted `ocean_standard.gdshader`.
- Added `ocean_shore_common.gdshaderinc`.
- Added `ocean_surface_common.gdshaderinc`.
- Moved the better shore-wave shape into reusable include files.

Good part:

- This removed a parallel old ocean path and kept the FFT/projected mesh path
  as the main ocean.

Bad side effect:

- Old Gerstner fallback/reference code disappeared. The feature "Gerstner near
  shore, FFT in open ocean" now exists only as analytical shore swash layered
  onto FFT, not as a separate old-standard ocean path.

### Receiver-Only Compositor Push

`92d0074`, `799ff59`, `ad67dce`, `bdbd6f6`

What changed:

- Added `PrewaterCaptureRenderer`.
- Expanded `WaterSurfaceState`.
- Got waterline compositing working.
- Restored SSR in the compositor/surface era.

Salvage:

- `WaterSurfaceState` is one of the best outcomes of the whole sequence.
- `PrewaterCaptureRenderer` and `WaterlineStack` are the right shape if the
  project chooses a receiver-only waterline architecture.
- `bdbd6f6` is the clean historical custom SSR restore.

Warning:

- This path is not active in Ocean Lab now.

### Underwater Pivot And Deletion

`6f6b191`, `4056e48`, `055753f`

What changed:

- Snell and rays were attempted.
- Commit text says Snell/rays were not working, particles were okay.
- `055753f` deleted the older underwater shader/effect stack and moved caustics
  into the waterline compositor path.

Salvage:

- `compute_receiver_caustics()` in `waterline_probe.glsl`.
- Snell helpers in `waterline_probe.glsl`, especially `compute_snell_sample`,
  `refract_water_to_air`, and `sample_atmosphere_color`.

Warning:

- These are not active in the current lab path.

### Wetness And Refraction Loop

`ab0bf11`, `0fc44e7`, `69b7864`, `393be60`

What changed:

- Added `WetCompositorEffect`.
- Added `WetnessManager`.
- Moved wetness toward screen-space contact plus retained object memory.
- Improved underwater wobble.
- Refraction improved but still had visible artifacts.

Salvage:

- Keep wetness separate from ocean shader recovery.
- Keep `WaterSurfaceState` as the shared input contract.
- `0fc44e7` is a useful wobble reference.

### Stack Consolidation And Particle Pivot

`8ca7cdc`, `16d642b`

What changed:

- Added `WaterlineStack`.
- Deleted `UnderwaterVolume`.
- Added cloud shadow compositor.
- Removed underwater rays.
- Added `UnderwaterParticulates`.

Salvage:

- `WaterlineStack` is a good wrapper shape, but should not be called production
  truth until it is actually wired and visually accepted.
- `UnderwaterParticulates` is useful as an optional particle layer, default off.

### Current Pivot

`ea642a2`, `7e678e4`

What changed:

- Reintroduced a much smaller `underwater.glsl` and
  `UnderwaterCompositorEffect`.
- Ocean Lab moved away from the direct prewater/waterline compositor wiring.
- Surface shader again owns screen/depth refraction and custom SSR.
- Added `WaterOpticalProfile` / muddiness tuning.

Practical state:

- This is faster and simpler.
- It is also missing the richer underwater features unless they are re-wired.
- The commit message explicitly says the other features need re-wiring.

## Current Architecture Truth

### Active In Ocean Lab

- `src/core/water/ocean_manager.gd`
- `src/core/water/ocean_mesh.gd`
- `src/core/water/shaders/ocean_fft.gdshader`
- `src/core/water/shaders/ocean_fft_projected.gdshader`
- `src/core/water/shaders/ocean_fft_common.gdshaderinc`
- `src/core/shaders/effects/underwater_compositor_effect.gd`
- `src/core/shaders/compute/underwater.glsl`
- `tests/visual/test_ocean_lab.gd`

The active visible surface is still an opaque ocean sheet, but it declares
`hint_screen_texture` and `hint_depth_texture` for refraction/SSR. That means
it is constrained by Godot's one opaque-screen-copy model.

The active underwater compositor is deliberately small: absorption plus bounded
wobble. Its `set_underwater_feature_enabled()` accepts names like `snell`,
`particles`, and `caustics`, but those are stubs/no-ops in the current path.

Session update 2026-05-14:

- The active underwater compositor remains the small absorption/wobble pass.
- Its submersion and path-length tests now use the same GPU-side water surface
  contract used by the receiver/wetness compute paths when water state textures
  are available.
- The CPU-side compositor early-out now receives a sampled camera water level
  from Ocean Lab through `set_camera_water_level()`.
- The lab UI still forces Snell, compositor particles, and caustics off for this
  active underwater path.
- The lab also has a separate `Receiver WL` toggle for the receiver-only
  waterline path. It remains disabled by default and is configured as a
  direct-replacement recovery mode, not as accepted final waterline optics.

### Present But Not Product Path

- `src/core/water/waterline_stack.gd`
- `src/core/water/prewater_capture_renderer.gd`
- `src/core/shaders/effects/prewater_capture_effect.gd`
- `src/core/shaders/effects/waterline_compositor_effect.gd`
- `src/core/shaders/compute/prewater_capture.glsl`
- `src/core/shaders/compute/waterline_probe.glsl`
- `src/core/shaders/compute/water_surface_contract.glslinc`

This is where much of the advanced work lives: Snell, receiver caustics,
receiver refraction replacement, richer wobble, underwater particles as a
compute idea. Ocean Lab now instantiates this stack only for the opt-in
`Receiver WL` experiment, with the advanced features held off.

### Dirty Worktree Notes

There are existing uncommitted changes at the time of this audit:

- `docs/plans/wetness_system.md`
- `src/core/interaction/carryable_body_factory.gd`
- `src/core/shaders/object_wet.gdshader`
- `src/core/water/wetness_manager.gd`
- `src/tools/ui/ocean_controls.gd`
- `tests/unit/test_wetness_manager.gd`
- `tests/visual/test_ocean_lab.gd`
- untracked `src/core/water/wettable_object.gd`

Session update 2026-05-14:

- Additional session edits touched
  `src/core/shaders/effects/underwater_compositor_effect.gd`,
  `src/core/shaders/compute/underwater.glsl`,
  `docs/systems/ocean/architecture.md`, and
  `tests/visual/test_ocean_lab.gd`.
- Added `tests/visual/test_ocean_lab_underwater_smoke.gd` and
  `tests/visual/test_ocean_lab_underwater_smoke.tscn` as a compositor crash
  smoke for the active underwater path.
- Godot generated `src/core/water/wettable_object.gd.uid` because the dirty
  Ocean Lab script already preloads `wettable_object.gd`.

Risk:

- `carryable_body_factory.gd` now references an untracked file. A partial
  commit or branch switch can break script loading.
- Wetness changes are entangled with Ocean Lab but should not drive the ocean
  recovery.

## Salvage Map

| Feature | Best source | Reuse guidance |
| --- | --- | --- |
| Water thickness | `f0b5192`, current surface shader | Keep the depth reconstruction idea. Verify against Godot 4.6 reversed-Z behavior. |
| Shore FFT dampening | current `ocean_fft.gdshader` / `ocean_shore_common.gdshaderinc` | Keep. This is the right data-driven shoreline shape. |
| Shore swash / Gerstner-like behavior | `277b15e`, then include form in `a44a289` | Reuse `water_surface_shore_offset()` / slope / choppiness. Do not restore the old separate Gerstner ocean path. |
| Shore mask semantics | `ab0bf11+` | Keep encoded distance/coverage contract. Do not regress to raw alpha distance. |
| SSS | `09ce68a`, `277b15e`, current `ocean_fft_common.gdshaderinc` | Keep wave peak mask plus shore choppiness feeding SSS. |
| Surface SSR | `bdbd6f6` or current `ea642a2` path | Keep as optional bounded screen-space reflection, not a correctness pillar. |
| Spray | `e8c819e` files, still intact | Keep isolated. Verify after surface state changes. |
| Receiver refraction/waterline | `ad67dce`, `WaterlineStack`, `waterline_probe.glsl` | Worth reusing only if the project chooses compositor-owned receiver replacement. Needs a real reintegration pass. |
| Caustics | `055753f`, `compute_receiver_caustics()` | Salvage into the chosen underwater/receiver compositor, not the surface shader. |
| Snell window | `8ca7cdc`, `compute_snell_sample()` | Salvage math, but do not assume it works until re-integrated into active path. |
| Wobble | `0fc44e7` advanced guard, current simple underwater pass | Prefer the simpler pass unless the advanced waterline compositor is revived. |
| Underwater particles | `16d642b` GPUParticles layer | Keep as optional world-space particles. Avoid duplicating with compute fake particles. |
| Wetness | `ab0bf11+` and dirty worktree | Keep separate: live contact plus retained object memory consumes water state but does not define ocean rendering. |

## What Not To Do Next

Do not keep patching the surface shader to solve every symptom.

Specifically, avoid:

- adding more color/depth heuristics to hide double silhouettes;
- making Snell, caustics, particles, and contact lines all branches inside
  `ocean_fft_common.gdshaderinc`;
- treating `WaterlineStack` comments as truth while it is not wired;
- reviving terrain wet maps as an ocean-waterline authority;
- bundling wetness, clouds, spray, mud, and refraction in the same recovery pass.

Those are how the loop restarts.

## Recommended Recovery Plan

### Phase 0 - Freeze The Ownership Decision

Pick one production ownership model before coding.

Recommended model:

- Surface shader owns only the visible ocean sheet: FFT, shore swash, foam,
  SSS, optional surface SSR, and shallow/deep color.
- A compositor owns receiver waterline/refraction/contact replacement.
- A compositor owns underwater camera medium.
- Wetness consumes the shared water state but remains separate.

This matches Godot's exposed renderer tools better than trying to make the
surface shader solve receiver replacement from a single opaque screen copy.

Session update 2026-05-14:

- Ocean Lab was left on the split described above for the active paths: visible
  ocean surface in the surface shader, underwater medium in
  `UnderwaterCompositorEffect`, wetness as a separate compositor, and
  receiver-only waterline outside the normal lab path.
- No code was added to make the surface shader own Snell, caustics, particles,
  or receiver replacement.

### Phase 1 - Stabilize The Surface

Goal: recover the nice visible ocean first.

Keep:

- FFT displacement.
- Shore dampening.
- `ocean_shore_common.gdshaderinc`.
- SSS.
- Spray.

Temporarily disable or make visually non-authoritative:

- surface refraction;
- underwater compositor;
- wet compositor;
- receiver waterline stack.

Acceptance:

- open ocean waves look right;
- shore has calm FFT dampening plus visible analytical swash;
- no weird contact-line behavior because contact-line effects are off;
- SSR can be toggled independently without changing waterline behavior.

Session update 2026-05-14:

- `tests/visual/test_ocean_lab.gd` now starts with `_surface_refraction_enabled`
  set to `false`.
- `tests/visual/test_ocean_lab.gd` now starts with `_underwater_effect_enabled`
  set to `false`.
- Existing wet compositor defaults were left off; wetness code was not changed
  as part of this recovery pass.
- Surface SSR remains independently toggleable through the existing lab control.

### Phase 2 - Reintroduce Receiver Waterline As One Path

Choose whether to revive `WaterlineStack`.

If yes:

- Wire `WaterlineStack` deliberately in Ocean Lab.
- Restore waterline debug UI from pre-`ea642a2` history.
- Use `WaterSurfaceState` and `water_surface_contract.glslinc`.
- Treat `waterline_probe.glsl` as salvage, not trusted product.
- Start with binary receiver replacement only: no Snell, no caustics, no wobble.

Acceptance:

- half-submerged opaque objects show one readable silhouette, not straight plus
  refracted duplicates;
- waterline mask is stable while moving camera across waves;
- turning the receiver compositor off returns to the clean surface-only view.

Session update 2026-05-14:

- Ocean Lab now creates a `WaterlineStack` after the reflection canaries are
  created. It is off by default and controlled by a `Receiver WL` button.
- The half-submerged and submerged optics canaries are opted into the receiver
  capture layer so the prewater capture has explicit test receivers.
- `waterline_probe.glsl` now has push-constant controls for binary replacement
  and receiver refraction. Ocean Lab enables the binary mask and disables
  receiver refraction for this recovery mode.
- `tests/visual/test_ocean_lab_waterline_smoke.gd` and `.tscn` were added as a
  crash smoke that turns on the receiver path and debug mask mode.
- This is crash-smoked plumbing, not visual acceptance of final waterline
  quality.

### Phase 3 - Underwater Camera Medium

Use the current `UnderwaterCompositorEffect` as the simple baseline, but make it
consume the same dynamic water surface contract as the surface and waterline
paths. Its current sea-level-only gate is why it can disagree with waves.

Then add features one at a time:

1. absorption/fog;
2. wobble;
3. Snell;
4. caustics;
5. particles.

Acceptance:

- camera crossing the wave surface does not pop or disagree with the visible
  ocean;
- underwater can be evaluated with all optional features off;
- each feature has a debug mode and a single owner.

Session update 2026-05-14:

- `UnderwaterCompositorEffect.sync_from_water_state()` now copies the water
  surface data needed by the compute shader: displacement RID, shore mask RID,
  map scales, wave scale, ocean time, shore bounds, and shore wave parameters.
- `UnderwaterCompositorEffect` now creates fallback shore and dummy displacement
  textures for cases where a full water state is not available.
- `underwater.glsl` now samples `water_surface_contract.glslinc` for dynamic
  water-level queries and uses those queries for camera-underwater gating,
  underwater hit classification, and water-path length.
- Ocean Lab now pushes the sampled camera water level into
  `UnderwaterCompositorEffect.set_camera_water_level()`.
- Snell, caustics, and compositor-side fake particles remain stubbed/off in the
  active underwater path.

### Phase 4 - Wetness And Spray Reattachment

Only after surface, waterline, and underwater ownership is stable:

- re-enable spray;
- re-enable retained object wetness;
- re-enable live contact wetness if needed;
- leave terrain wet maps as legacy/fallback plumbing.

Session update 2026-05-14:

- Wetness recovery was not folded into this pass.
- Existing dirty wetness files were left as inherited worktree state.
- Spray settings and spray code were not changed.

## Files To Treat As Current Starting Points

Use these as source of truth:

- `docs/systems/ocean/architecture.md`
- `src/core/water/water_surface_state.gd`
- `src/core/water/ocean_manager.gd`
- `src/core/water/ocean_mesh.gd`
- `src/core/water/shaders/ocean_fft.gdshader`
- `src/core/water/shaders/ocean_fft_projected.gdshader`
- `src/core/water/shaders/ocean_fft_common.gdshaderinc`
- `src/core/water/shaders/ocean_shore_common.gdshaderinc`
- `src/core/water/shaders/ocean_surface_common.gdshaderinc`
- `src/core/shaders/compute/water_surface_contract.glslinc`

Use these as salvage, not truth:

- `src/core/shaders/compute/waterline_probe.glsl`
- `src/core/shaders/effects/waterline_compositor_effect.gd`
- `src/core/water/waterline_stack.gd`
- `src/core/water/prewater_capture_renderer.gd`
- deleted/old underwater shader paths from history

## Verification Notes

For any future shader behavior change:

1. Clear matching `.godot/imported/<shader-name>-*.res` and `.md5` files for
   edited compute shaders.
2. Run Godot import:
   `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind --import`
3. Launch Ocean Lab interactively:
   `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab.tscn`
4. Do not use automated screenshot/auto-capture for final visual confidence.

For this audit document itself, no shader cache was cleared and no visual
verification was required because no runtime rendering code changed.

Session update 2026-05-14:

- Deleted `.godot/imported/underwater.glsl-*.res` and
  `.godot/imported/underwater.glsl-*.md5`.
- Deleted `.godot/imported/waterline_probe.glsl-*.res` and
  `.godot/imported/waterline_probe.glsl-*.md5`.
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind --import`
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab_underwater_smoke.tscn`
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab_waterline_smoke.tscn`
- Launched Ocean Lab interactively:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab.tscn`

Follow-up launch 2026-05-14:

- Launched the same Ocean Lab scene interactively again after the receiver
  waterline toggle/doc updates:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab.tscn`
- No shader files were changed in this follow-up, so no additional shader cache
  clear/import was required.
- Expected starting state remains surface refraction off, underwater medium off,
  and receiver waterline off. The `Receiver WL` button is available for manual
  inspection of the crash-smoked binary receiver replacement path.

Follow-up recovery instrumentation 2026-05-15:

- `WaterlineCompositorEffect.get_underwater_perf_snapshot()` now reports
  receiver source color/depth validity, source size, dispatch size, effect
  state, blend factor, camera height, and camera water level.
- `tests/visual/test_ocean_lab_waterline_smoke.gd` now fails the smoke if the
  receiver capture buffers are not bound, binary receiver replacement is not
  active, receiver refraction is active, or advanced waterline underwater
  features are active.
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab_waterline_smoke.tscn`
- No shader files changed in this follow-up, so no additional shader cache
  clear/import was required.
- This is still crash-smoked receiver-path instrumentation, not visual
  acceptance of the final waterline image.

Follow-up receiver inspection workflow 2026-05-15:

- Added a `WL Inspect` control to Ocean Lab's Debug tab. It enables the
  receiver-only waterline path, sets the waterline debug view to `Final Mask`,
  disables surface refraction, surface SSR, underwater medium, and live wetness,
  and moves the camera to the shore canaries.
- Ocean Lab's HUD now reports receiver source-buffer validity when the
  waterline effect has a perf snapshot.
- Follow-up clarification: the HUD now reports `wl_source=warming` for the
  first inspection frames before reporting `ok` or `missing`, and the `Final
  Mask` help text describes red as the receiver replacement mask that should
  cover only submerged receiver-canary pixels in this recovery view.
- Additional clarification: the HUD now separates receiver-source status from
  prewater-capture status, so `wl_source` can identify `capture-off`,
  `capture-empty`, or `handoff-missing` instead of collapsing every failure
  into `missing`.
- `tests/visual/test_ocean_lab_waterline_smoke.gd` now enters the same
  inspection state before checking the receiver capture and recovery-mode
  flags.
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab_waterline_smoke.tscn`
- No shader files changed in this follow-up, so no additional shader cache
  clear/import was required.
- This is a diagnostic workflow and crash/plumbing check; visual acceptance of
  the receiver waterline still requires interactive inspection.
- Launched Ocean Lab interactively for manual inspection:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab.tscn`
- Relaunched Ocean Lab interactively after the `wl_source=warming/ok/missing`
  HUD clarification:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab.tscn`

Follow-up shader import/plumbing check 2026-05-15:

- The `wl_source=missing` report was traced to the receiver waterline compute
  shader not producing a usable pipeline. A temporary RDShaderFile diagnostic
  showed a `waterline_probe.glsl` compile error in the dormant advanced medium
  branch: the shader called a 5-argument `apply_water_medium()` overload that
  did not exist.
- `src/core/shaders/compute/water_surface_contract.glslinc` and
  `src/core/shaders/compute/waterline_probe.glsl` now use explicit
  `textureLod(..., 0.0)` for compute sampler reads.
- `src/core/shaders/compute/waterline_probe.glsl` now includes the
  5-argument `apply_water_medium()` overload referenced by the dormant branch.
  This keeps the receiver recovery mode compiling without enabling Snell,
  caustics, particles, or receiver refraction.
- Deleted `.godot/imported/waterline_probe.glsl-*.res` and
  `.godot/imported/waterline_probe.glsl-*.md5`. Because the shared compute
  water-surface include changed, also deleted `.godot/imported/underwater.glsl-*`
  and `.godot/imported/wet_compositor.glsl-*` generated artifacts.
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind --import`
  The import process returned non-zero in this workspace while still
  regenerating shader bytecode; the console output also contained unrelated
  editor/plugin cleanup noise.
- A temporary RDShaderFile diagnostic then reported no shader compile error and
  non-zero waterline SPIR-V bytecode. The temporary diagnostic script was
  removed after use.
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab_waterline_smoke.tscn`
- The crash smoke exercised the `WL Inspect` path with
  `external_source_color_valid=true`, `external_source_depth_valid=true`,
  `external_source_valid=true`, `binary_receiver_mask=true`,
  `receiver_refraction_enabled=false`, and `feature_flags=0`.
- No automated screenshots or auto-capture were used. This is shader import and
  receiver-source plumbing verification; visual acceptance of the waterline
  image still requires interactive inspection.

Follow-up final-mask visualization 2026-05-15:

- User visual feedback showed `wl_source=ok` in `WL Inspect`, but the `Final
  Mask` debug view showed valid receiver silhouettes as white because the debug
  color added full-strength red mask, green water-body gate, and blue visible
  water gate in the same pixels.
- `src/core/shaders/compute/waterline_probe.glsl` debug mode 14 now renders
  dim gate context and pure red for the final receiver silhouette. The mask
  uses the binary output mask when binary receiver mode is enabled.
- `tests/visual/test_ocean_lab.gd` HUD help for `WL Final Mask` now describes
  red as the final binary receiver silhouette and dim green/blue as water-gate
  context.
- Deleted `.godot/imported/waterline_probe.glsl-*.res` and
  `.godot/imported/waterline_probe.glsl-*.md5`.
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind --import`
  The import process again returned non-zero with the same editor/plugin cleanup
  noise, while regenerating the waterline shader artifact.
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab_waterline_smoke.tscn`
- The waterline smoke exited successfully and again reported valid receiver
  source color/depth buffers, binary receiver mask enabled, receiver refraction
  disabled, and advanced waterline feature flags off.
- No automated screenshots or auto-capture were used. Visual acceptance of the
  updated color-coded debug view still requires interactive inspection.
- User-provided interactive Ocean Lab feedback after relaunch showed
  `wl_source=ok` and red receiver silhouettes in `WL Debug: Final Mask`. This
  visually confirms the diagnostic mask color mapping. It does not accept final
  production waterline optics.

Follow-up replacement inspection workflow 2026-05-15:

- Added a `WL Replace` Debug-tab button to
  `tests/visual/test_ocean_lab.gd`. It uses the same isolated setup as
  `WL Inspect` but sets `WL Debug` to `Off`, so the scene shows the normal
  binary receiver replacement composite instead of debug colors.
- Shared the setup through `_start_waterline_receiver_isolated_view()` so both
  inspection buttons keep surface refraction, surface SSR, underwater medium,
  and live wetness off while the receiver waterline path is active.
- Updated `tests/visual/test_ocean_lab_waterline_smoke.gd` to exercise both
  states: `WL Inspect` with debug mode 14 and `WL Replace` with debug mode 0.
  The first smoke attempt exposed a smoke-sequencing check that still expected
  debug mode 14 after switching to replacement mode; the smoke script was then
  adjusted and rerun.
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab_waterline_smoke.tscn`
- The smoke exited successfully. Both phases reported valid receiver
  source color/depth buffers, binary receiver mask enabled, receiver refraction
  disabled, and advanced waterline feature flags off.
- No shader files changed in this follow-up, so no shader cache clear/import
  was required. No automated screenshots or auto-capture were used.
- User-provided interactive Ocean Lab feedback after relaunch showed
  `WL Replace` with `wl_source=ok`, `WL Debug: Off`, and no debug colors. This
  visually exercises the raw binary receiver replacement composite. It does not
  accept final production waterline optical quality.
- `WaterlineCompositorEffect.get_underwater_perf_snapshot()` now also reports
  the effect-side waterline debug mode. The waterline smoke checks that the
  compositor receives debug mode 14 for `WL Inspect`, debug mode 0 for
  `WL Replace`, and receiver source mode 1 for both phases.
- Reran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab_waterline_smoke.tscn`
- The rerun exited successfully. No shader files changed for the perf/smoke
  guard, so no shader cache clear/import was required.

Follow-up receiver source resolution/latency 2026-05-15:

- User-provided interactive Ocean Lab feedback on `WL Replace` showed no debug
  colors, no double shape, no popping, and a matching `WL Inspect` mask, but
  also showed visible pixelation on receiver pixels and a ghost while moving
  around underwater receiver parts.
- The pixelation was traced to the receiver prewater capture running below the
  main viewport resolution. `WaterlineStack` quality-to-resolution mapping now
  uses full resolution for high quality, 0.75x for medium, and 0.5x for low.
  Ocean Lab's receiver-waterline inspection path now defaults to high quality.
- The fly camera now has an earlier process priority in Ocean Lab so its
  transform updates before the lab pushes camera state into the receiver
  capture and waterline stack.
- `PrewaterCaptureEffect`, `PrewaterCaptureRenderer`, and
  `WaterlineCompositorEffect` now report receiver source process-frame age in
  their perf snapshots. The Ocean Lab HUD shows `wl_frame_age`, dispatch size,
  and receiver-waterline quality.
- `tests/visual/test_ocean_lab_waterline_smoke.gd` now fails if the receiver
  source is not full resolution for the current dispatch size or if the reported
  receiver source frame age is outside `0..1`.
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab_waterline_smoke.tscn`
- The smoke exited successfully with `source_size=(1920, 1080)`,
  `dispatch_size=(1920, 1080)`, `quality_tier=2`, and
  `external_source_frame_age=1` in both `WL Inspect` and `WL Replace` phases.
- No shader files changed in this follow-up, so no shader cache clear/import
  was required. No automated screenshots or auto-capture were used.
- Interpretation: full-resolution receiver source should address the visible
  pixelation. The reported one-frame source age confirms that the remaining
  ghosting is receiver capture/compositor scheduling latency; addressing it
  beyond this guard likely requires same-frame receiver capture, reprojection,
  or a different receiver ownership path rather than another surface-shader
  patch.
- User follow-up on `WL Replace` confirmed the visible pixelation and ghosting
  were no longer present after this pass.

Follow-up receiver optical quality pass 2026-05-15:

- `src/core/shaders/compute/waterline_probe.glsl` now keeps the binary receiver
  ownership mask but shades the already-replaced receiver pixels with
  receiver-local Beer-Lambert water medium and a small near-surface film cue.
  This improves the `WL Replace` image beyond raw source-color replacement
  without enabling receiver refraction, Snell, caustics, particles, or moving
  any of those features into the surface shader.
- `WaterlineCompositorEffect` now exposes separate receiver medium and receiver
  surface-film switches through `receiver_options.zw` and reports both in its
  perf snapshot.
- Ocean Lab enables those two receiver-local optical switches in the isolated
  `WL Inspect` / `WL Replace` workflow while still forcing surface refraction,
  surface SSR, underwater medium, live wetness, receiver refraction, Snell,
  wobble, particles, caustics, and the waterline underwater feature flags off.
- `tests/visual/test_ocean_lab_waterline_smoke.gd` now fails if the receiver
  medium or surface film are not enabled, while still requiring
  `feature_flags=0`.
- Deleted `.godot/imported/waterline_probe.glsl-*.res` and
  `.godot/imported/waterline_probe.glsl-*.md5`.
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind --import`
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab_waterline_smoke.tscn`
- Launched Ocean Lab interactively:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab.tscn`
- The smoke exited successfully with the optical switches active, advanced
  waterline underwater feature flags still off, receiver refraction still off,
  and the receiver source path still full-resolution.

Follow-up receiver foreground-occlusion fix 2026-05-15:

- User feedback showed a closer above-water foreground object failed to occlude
  an underwater receiver replacement behind it in `WL Replace`.
- `src/core/shaders/compute/waterline_probe.glsl` now applies a main-scene
  foreground-depth visibility gate to direct and refracted receiver masks
  before the binary output mask is computed. A closer non-water foreground pixel
  suppresses receiver replacement; a main-depth pixel classified as the water
  surface still allows receiver replacement through the water.
- This keeps the fix in the receiver compositor ownership path. The surface
  shader was not changed and Snell, caustics, particles, receiver refraction,
  and advanced waterline underwater feature flags remain off.
- Deleted `.godot/imported/waterline_probe.glsl-*.res` and
  `.godot/imported/waterline_probe.glsl-*.md5`.
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind --import`
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab_waterline_smoke.tscn`
- Launched Ocean Lab interactively:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab.tscn`

Follow-up receiver terrain-occlusion fix 2026-05-15:

- User feedback showed receiver-layer cubes hidden below terrain in the normal
  above-water view but visible through the waterline replacement when water was
  between the camera and those cubes.
- Root cause: the receiver source capture is intentionally receiver-only, so
  its depth buffer cannot know that terrain in the normal world should occlude
  a receiver. The main scene depth at those pixels is often the water surface,
  which must still allow through-water receiver replacement.
- `PrewaterCaptureRenderer` now maintains a second synchronized pre-water
  capture viewport that renders normal world depth with the ocean/water render
  layer excluded. `WaterlineStack` passes the water layer as the occlusion
  exclusion layer in Ocean Lab.
- `WaterlineCompositorEffect` now accepts this external occlusion depth texture
  on binding 10, exposes its validity/size/frame age in the perf snapshot, and
  the waterline shader uses it as an additional receiver visibility test.
  Terrain or other non-water world geometry in front of a receiver suppresses
  the receiver replacement, while the visible water surface itself still allows
  the replacement.
- `tests/visual/test_ocean_lab_waterline_smoke.gd` now fails if the occlusion
  depth buffer is not bound at full resolution or is older than one process
  frame.
- Deleted `.godot/imported/waterline_probe.glsl-*.res` and
  `.godot/imported/waterline_probe.glsl-*.md5`.
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind --import`
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab_waterline_smoke.tscn`
- Launched Ocean Lab interactively:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab.tscn`

Follow-up receiver ownership-mask stability fix 2026-05-15:

- User feedback showed white/water-colored holes punched through receiver
  cubes that were already underwater, even though the visible waterline was
  higher than those holes.
- Root cause: the binary receiver ownership mask was using the fully dynamic
  FFT/shore water level as a hard inclusion test. Wave troughs could classify
  isolated receiver pixels as dry, leaving the opaque water surface visible
  through those holes.
- `waterline_probe.glsl` now uses a stable receiver-ownership water level for
  the binary replacement mask: dynamic crests can raise the receiver waterline,
  but troughs are clamped no lower than `sea_level`. This keeps already
  submerged receiver pixels solid while still letting dynamic waves cover
  higher receiver pixels.
- Ocean Lab now reports occlusion status on the visible waterline HUD lines as
  `occ` and `occ_age`, in addition to the existing detailed occlusion line.
- Deleted `.godot/imported/waterline_probe.glsl-*.res` and
  `.godot/imported/waterline_probe.glsl-*.md5`.
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind --import`
- Ran:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab_waterline_smoke.tscn`
- Launched Ocean Lab interactively:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_ocean_lab.tscn`
