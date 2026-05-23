# Ocean History Since f0b5192 - 2026-05-22

Status: historical audit. Use `docs/systems/ocean/architecture.md` for current
Godotwind architecture and
`docs/systems/ocean/godot_4_6_water_rendering_rules.md` for fact-checked Godot
4.6 renderer guidance. This file is retained for chronology and archaeology,
not as implementation authority.

Scope: all ocean, waterline, underwater, wetness-adjacent, and ocean shader
changes from `f0b51924198af713f3849466964cea04050e8060` through `HEAD`
(`7e678e4`), plus the current uncommitted working tree.

This is a historical/source audit only. It does not change shader or runtime
behavior.

## Executive Summary

The history is not one ocean shader being refined. It is three renderer
responsibilities repeatedly moving between different implementations:

1. **Visible ocean surface**: FFT/projected ocean mesh, foam, Fresnel,
   Beer-Lambert tint, surface refraction, and custom SSR.
2. **Receiver waterline/refraction**: objects that cross the water surface and
   need one owner for straight vs refracted pixels.
3. **Underwater camera medium**: whole-frame color, absorption, wobble, Snell
   window, caustics, and particles when the camera is below water.

The baseline commit, `f0b5192`, was the last clear marker saying ocean water
thickness was solved. Immediately after it, the work entered a refraction loop.
Responsibility first moved from the surface shader toward a receiver-only
waterline compositor, then toward a larger waterline/underwater mega-compositor,
then back toward a simpler surface shader plus separate underwater compositor.

Current source is a hybrid:

- `OceanManager` publishes FFT and water optical state through
  `WaterSurfaceState`.
- `OceanMesh` draws `ocean_fft.gdshader` or `ocean_fft_projected.gdshader`.
- `ocean_fft_common.gdshaderinc` still samples Godot `SCREEN_TEXTURE` and
  `DEPTH_TEXTURE` for above-water surface refraction, absorption, and custom
  SSR.
- `UnderwaterCompositorEffect` is the active Ocean Lab underwater medium path,
  but it is deliberately simpler than the earlier mega-compositor.
- `WaterlineStack` / `PrewaterCaptureRenderer` /
  `WaterlineCompositorEffect` still exist, but in the current lab they are an
  off-by-default receiver-waterline experiment, not the default production
  baseline.
- Wetness is now partly its own system through `WetnessManager`, optional
  compositor integration, and uncommitted `WettableObject` work.

Practical effect: many features that look "implemented" in source are not all
active in the same path. Snell window, receiver-only replacement, compositor
caustics, underwater particles, wetness, surface refraction, and custom SSR
belong to different generations unless deliberately wired together.

## Current Authority

Treat these as current:

- `docs/systems/ocean/architecture.md`: current source truth for the ocean
  rendering architecture.
- `docs/systems/ocean/godot_4_6_water_rendering_rules.md`: Godot rendering
  constraints and debug workflow.

Treat these as historical/superseded unless they point back to the two docs
above:

- `docs/systems/ocean.md`
- `docs/systems/underwater.md`
- `docs/plans/ocean_underwater_overhaul_2026_05_09.md`
- deleted `docs/plans/ocean_quality_tracker_2026_05_07.md`
- older ocean audits deleted or superseded during the May 14 pivot

Resolved stale doc claim: before the 2026-05-22 cleanup, `docs/STATUS.md`
said the surface shader no longer sampled screen color or owned custom SSR.
Current source contradicts that:
`src/core/water/shaders/ocean_fft_common.gdshaderinc` still declares
screen/depth textures and custom SSR uniforms. `docs/STATUS.md` now points to
the consolidated ocean authority docs.

## Baseline

`f0b5192` - `correct terrain textures, ocean "water thickness" solved`

Files touched:

- `docs/plans/ocean_quality_tracker_2026_05_07.md`
- `src/core/water/ocean_manager.gd`
- `src/core/water/shaders/ocean_fft_common.gdshaderinc`
- `tests/visual/test_ocean_lab.gd`

This is the baseline before the loop. The important marker is not that the
whole ocean was done; it is that depth-derived water thickness had a known
working state before refraction and waterline ownership were repeatedly moved.

## Chronological Commit Account

| Commit | Date | Subject | What happened |
| --- | --- | --- | --- |
| `e13ee7d` | 2026-05-07 | `refraction on the way` | First big surface-refraction push after the baseline. `ocean_fft_common.gdshaderinc` started experimenting harder with refracted depth/source sampling, Beer-Lambert thickness, and debug modes. Ocean Lab gained refraction and SSR controls. |
| `bf406ee` | 2026-05-07 | `refactor water option c` | Introduced the Option C idea: move waterline/refraction ownership away from the visible surface shader toward `waterline_probe.glsl`, `WaterlineCompositorEffect`, and `UnderwaterVolume`. Docs started describing a compositor architecture. |
| `389083b` | 2026-05-07 | `fix gerstner wave speed + refactor on the way` | Added shared ocean timing so surface, underwater volume, and compositor paths could use one clock. Shore/Gerstner motion was adjusted toward more plausible gravity-wave timing and better runup/breaker behavior. |
| `97fac3c` | 2026-05-07 | `shore wave is fixed-ish` | Improved shore-wave direction fallback from the shore mask and added more shore-wave shaping. Ocean Lab received more wireframe/debug controls. |
| `34346d3` | 2026-05-07 | `lol full circle` | Added pre-water color/depth capture and a Godot SSR reference scene. This is the first concrete external-source move: waterline refraction could sample a prewater capture instead of only the already-composited main frame. |
| `e8c819e` | 2026-05-08 | `wave spray` | Added a mostly independent GPU spray system: `OceanSpray`, spray particle/billboard shaders, spray texture, and a smoke scene. This is separable from the refraction churn. |
| `09ce68a` | 2026-05-08 | `SSR fixed ! also waterline is fixed (best setting : margin = 0.05)` | Added `WaterSurfaceState`, one of the most durable outputs of the whole sequence. The surface shader backed away from owning everything; waterline compositing carried more object-bending responsibility. |
| `277b15e` | 2026-05-08 | `gerstner waves a better, water line is better, refraction is still not good` | Moved waterline compositing to post-transparent and improved shore wave shape, wetness alignment, CPU shore displacement, and projected mesh behavior. Commit subject explicitly says refraction was still not solved. |
| `48e38dd` | 2026-05-08 | `back to square one` | Narrowed the compositor back toward receiver-only prewater capture. This is a key history marker: the broader approach had produced enough artifacts that the path was reduced again. |
| `a44a289` | 2026-05-09 | `cleaned up ocean` | Deleted legacy Gerstner/standard-water files and introduced reusable shore/surface shader includes. This simplified the ocean stack around FFT/projected mesh modes but also removed old fallback/reference code. |
| `92d0074` | 2026-05-09 | `water line better, refactor cleanling on the way` | Extracted `PrewaterCaptureRenderer` and expanded `WaterSurfaceState`. The capture setup moved from lab-local code toward reusable infrastructure. |
| `799ff59` | 2026-05-09 | `waterline bis` | Deleted earlier audits, added `waterline_underwater_handoff_2026_05_09.md`, and expanded waterline compositing with water-body coverage, underwater-camera handling, fog/backscatter, and activation rules. |
| `ad67dce` | 2026-05-09 | `finally, the compositing works` | Got the waterline compositor visibly working in post-transparent and added pipeline debug output. Ocean Lab enabled this stack by default at full resolution during this generation. |
| `bdbd6f6` | 2026-05-09 | `SSR is back, phew` | Reintroduced custom screen-space reflections in the surface shader while compositor-based waterline work stayed alive. Responsibility was now split again. |
| `6f6b191` | 2026-05-09 | `snell window and rays not working. particles okay.` | The compositor grew into a large underwater experiment: Snell window, rays, wobble, particles, absorption fog, meniscus/refraction, scene color copy, and lab profiling. The subject is important: Snell/rays were known not working. |
| `4056e48` | 2026-05-09 | `snell a bit better` | Simplified Snell logic and sampled real scene color instead of a fake sky path. This was a tuning patch, not a final underwater architecture. |
| `055753f` | 2026-05-09 | `caustics are fixed (compositor based)` | Moved caustics into `waterline_probe.glsl` and deleted the old standalone underwater shader/effect stack. Added the May 9 underwater overhaul plan. This made the waterline compositor the center of underwater-caustics work. |
| `ab0bf11` | 2026-05-10 | `better perfs ocean` | Added `WetCompositorEffect`, `wet_compositor.glsl`, `WetnessManager`, and performance/debug instrumentation. Wetness began splitting out of ocean rendering into its own manager/compositor path. |
| `0fc44e7` | 2026-05-10 | `wobble fixed` | Reworked underwater wobble/refraction guards in the waterline shader: edge checks, depth checks, underwater gates, and stricter shifted-scene sampling. This is the useful wobble-fix reference commit. |
| `d0ed0ba` | 2026-05-11 | `audits` | Added `ocean_water_shader_audit_2026_05_11.md`. Runtime behavior did not change. |
| `69b7864` | 2026-05-11 | `refraction almost almosttttt` | Receiver refraction became stronger and cleaner. Also included safer RD texture lifetime handling and surface shader/depth fixes. Still an iteration inside the receiver-waterline generation. |
| `393be60` | 2026-05-11 | `refraction is better but still some visual artifacts` | Moved closer to replacing straight receiver pixels instead of tinting over them. Ocean Lab camera masks were adjusted so receiver-layer objects could be hidden from main view and supplied through compositor capture. Artifacts still known. |
| `8ca7cdc` | 2026-05-11 | `snell window` | Added `WaterlineStack`, deleted `UnderwaterVolume` and `test_underwater.*`, and moved lab-local waterline wiring into a wrapper. Snell/window logic became more physically grounded inside the compositor. |
| `16d642b` | 2026-05-11 | `underwater particles + removed the rays` | Removed underwater ray logic from the compositor and added a separate GPU underwater particle system owned/configured by `OceanManager`. |
| `ea642a2` | 2026-05-14 | `refraction is a bit less borked, SSR back, much faster, need to re-wire the other features though` | Major pivot. Added `godot_water_shader_bible.md`, `ocean_optics_current_architecture.md`, new `underwater.glsl`, `water_surface_contract.glslinc`, and `UnderwaterCompositorEffect`. Surface shader took back screen/depth refraction and SSR for speed/stability; the richer waterline/underwater feature set became partly unwired. |
| `7e678e4` | 2026-05-14 | `muddiness` | Added `WaterOpticalProfile` and shared visibility/extinction/tint/turbidity controls. Surface shader, underwater compositor, and waterline compositor now use a shared optical/muddiness model. |

## Architecture Generations

### Generation 0: Baseline Thickness

Commit: `f0b5192`

The surface shader had a working depth-derived water-thickness model. This was
not yet a stable answer for receiver ownership, refraction outside silhouettes,
or underwater camera effects.

### Generation 1: Surface Shader Refraction

Commit: `e13ee7d`

The visible ocean shader tried to own more refraction directly through
`SCREEN_TEXTURE` and `DEPTH_TEXTURE`. This matched Godot's cheap screen-space
water model, but it ran into the known Godot constraint: 3D screen textures are
an opaque scene copy, not a live post-transparent framebuffer.

### Generation 2: Option C / Receiver Waterline Compositor

Commits: `bf406ee` through `48e38dd`

Responsibility moved toward a receiver-only prewater capture and
`WaterlineCompositorEffect`. This was the right family of solution for
half-submerged receivers, because it gives waterline replacement an explicit
source buffer and mask. The implementation kept shifting, though: prewater vs
post-transparent, global vs receiver-only, and surface vs compositor ownership.

### Generation 3: Cleanup And Shared Contracts

Commits: `a44a289` through `bdbd6f6`

Legacy Gerstner/standard-water code was deleted, shared shore/surface includes
were added, `PrewaterCaptureRenderer` was extracted, and `WaterSurfaceState`
became the common contract. This is the most useful architectural salvage from
the loop: systems should consume `WaterSurfaceState` instead of reaching into
OceanManager internals.

### Generation 4: Mega Waterline/Underwater Compositor

Commits: `6f6b191` through `16d642b`

`waterline_probe.glsl` became a large post-process shader trying to own
receiver refraction, underwater fog, Snell window, caustics, particles, wobble,
and source replacement. Some pieces improved, but the commit messages and docs
show this generation never became a clean final state. Rays were removed,
Snell remained fragile, and particles were split into their own system.

### Generation 5: Current Hybrid Pivot

Commits: `ea642a2`, `7e678e4`, plus current uncommitted work

The active baseline pivoted back to a simpler shape:

- surface shader owns visible water optics, refraction, and SSR again;
- `UnderwaterCompositorEffect` owns a cheap underwater medium;
- receiver waterline remains present but experimental/off by default;
- optical muddiness is shared through `WaterOpticalProfile` /
  `WaterSurfaceState`.

This is faster and easier to reason about, but it means earlier "finished"
features are not all wired into the active path.

## Current Source Map

- `src/core/water/ocean_manager.gd`: main owner, FFT setup, shader params,
  spray/particles, optical profile, and `get_water_surface_state()`.
- `src/core/water/ocean_mesh.gd`: clipmap/projected mesh selection and surface
  material parameter application.
- `src/core/water/water_surface_state.gd`: shared runtime contract for
  sea level, FFT RIDs, shore data, optics, render mesh metadata, and sampling
  callables.
- `src/core/water/water_optical_profile.gd`: shared water visibility,
  extinction, medium color, scattering, and turbidity presets.
- `src/core/water/shaders/ocean_fft_common.gdshaderinc`: active surface
  shader logic; samples screen/depth textures and owns custom SSR.
- `src/core/shaders/effects/underwater_compositor_effect.gd` and
  `src/core/shaders/compute/underwater.glsl`: active Ocean Lab underwater
  medium pass.
- `src/core/water/waterline_stack.gd`,
  `src/core/water/prewater_capture_renderer.gd`,
  `src/core/shaders/effects/prewater_capture_effect.gd`,
  `src/core/shaders/effects/waterline_compositor_effect.gd`, and
  `src/core/shaders/compute/waterline_probe.glsl`: receiver-waterline path,
  currently opt-in/experimental in Ocean Lab.
- `src/core/water/wetness_manager.gd`, `src/core/shaders/object_wet.gdshader`,
  and untracked `src/core/water/wettable_object.gd`: wetness path.
- `tests/visual/test_ocean_lab.gd`: main interactive lab and the real place
  where active vs quarantined paths are easiest to see.

## Uncommitted Ocean/Water Changes

Modified water/ocean-related files:

- `docs/systems/ocean/architecture.md`
- `src/core/shaders/compute/underwater.glsl`
- `src/core/shaders/compute/water_surface_contract.glslinc`
- `src/core/shaders/compute/waterline_probe.glsl`
- `src/core/shaders/effects/prewater_capture_effect.gd`
- `src/core/shaders/effects/underwater_compositor_effect.gd`
- `src/core/shaders/effects/waterline_compositor_effect.gd`
- `src/core/shaders/object_wet.gdshader`
- `src/core/water/prewater_capture_renderer.gd`
- `src/core/water/waterline_stack.gd`
- `src/core/water/wetness_manager.gd`
- `src/tools/ui/ocean_controls.gd`
- `src/tools/world_explorer.gd`
- `tests/unit/test_wetness_manager.gd`
- `tests/visual/test_ocean_lab.gd`

Untracked water/ocean-related files:

- `docs/audit/ocean_recovery_audit_2026_05_14.md`
- `src/core/water/wettable_object.gd`
- `src/core/water/wettable_object.gd.uid`
- `tests/visual/test_ocean_lab_underwater_smoke.gd`
- `tests/visual/test_ocean_lab_underwater_smoke.gd.uid`
- `tests/visual/test_ocean_lab_underwater_smoke.tscn`
- `tests/visual/test_ocean_lab_waterline_smoke.gd`
- `tests/visual/test_ocean_lab_waterline_smoke.gd.uid`
- `tests/visual/test_ocean_lab_waterline_smoke.tscn`

The current uncommitted work appears to do three things:

1. Rewire `UnderwaterCompositorEffect` so it can use the dynamic FFT/shore
   water-surface contract instead of only mean sea level for submersion and
   path length.
2. Bring the receiver-waterline stack back into Ocean Lab as an explicit,
   off-by-default inspection/replacement path with `Receiver WL`, `WL Inspect`,
   and `WL Replace` controls.
3. Improve wetness separation: live compositor can be disabled independently,
   retained material wetness is managed by `WetnessManager`, and
   `WettableObject` adapts scene objects into the wetness shader path.

Important uncommitted receiver-waterline details:

- `WaterlineCompositorEffect` now has external occlusion depth plumbing.
- `PrewaterCaptureRenderer` now keeps a synchronized occlusion capture. Current
  Ocean Lab passes the water layer as the exclusion mask, so this capture is not
  yet guaranteed to be terrain/world-only; receiver self-depth can still be
  present unless the layer contract is tightened.
- Ocean Lab forces the receiver path into a safer binary receiver replacement
  mode: receiver refraction off, receiver-local medium/film on, and advanced
  underwater waterline features off.
- The waterline debug HUD reports source validity, occlusion validity,
  dispatch size, and frame ages.

Important shader/import detail:

- `.godot/imported` currently contains generated imports for `underwater.glsl`
  and `waterline_probe.glsl`.
- Because `underwater.glsl`, `waterline_probe.glsl`, and
  `water_surface_contract.glslinc` are modified in the working tree, those
  shader imports may be stale until the matching `.res`/`.md5` files are
  cleared and Godot is run with `--import`.

## Current Contradictions And Risks

1. **Historical docs vs source**: pre-cleanup docs said the surface shader no
   longer owned screen color or custom SSR; current source says it does.
2. **Waterline fallback gap**: `WaterlineStack` can activate capture from
   water coverage, but `WaterlineCompositorEffect` returns early unless
   displacement and shore RIDs are valid. Flat/no-FFT water has less fallback
   support than the underwater compositor.
3. **Underwater pre-skip may be too static**: current uncommitted work improves
   dynamic surface sampling inside `underwater.glsl`, but the GDScript effect
   can still skip before shader dispatch if its cached camera water level says
   the camera is above water.
4. **Sun direction may differ by path**: surface code and waterline stack appear
   to use opposite sun basis signs.
5. **Shore fade cache risk**: `OceanMesh` caches shore mask and bounds, but a
   quality/mode restore can call `set_shore_mask()` without preserving a
   non-default fade distance.
6. **Unused contract field**: `WaterSurfaceState.velocity_query` exists, but
   `OceanManager.get_water_surface_state()` does not appear to assign it.

## What To Keep

- Keep `WaterSurfaceState` as the shared water contract.
- Keep the Godot rule doc. The `hint_screen_texture` limitation is the root
  constraint behind many duplicate/refraction failures.
- Keep spray separate from refraction recovery.
- Keep wetness separate from ocean optical ownership.
- Keep `WaterlineStack` quarantined until it is intentionally accepted as the
  receiver-waterline architecture.
- Keep Ocean Lab as the interactive authority for visual verification.

## Plain-English Takeaway

The ocean is currently understandable if you stop thinking of it as one shader.
The visible ocean sheet is one system, underwater camera color is another, and
half-submerged object replacement is a third. The commit history repeatedly
blurred those boundaries, which is why the docs read like different ruins from
different civilizations.

The most recent direction is reasonable: use the surface shader for the visible
water look and cheap screen-space effects, use a post-transparent compositor
for camera-underwater medium, and keep receiver-only waterline replacement as a
separate opt-in path until it is visually proven. The next cleanup should be
documentation and ownership cleanup, not another round of piling features into
whichever shader happened to work last.
