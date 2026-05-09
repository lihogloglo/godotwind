# Waterline / Underwater Handoff - 2026-05-09

## Goal

Build the production waterline and underwater rendering path for Godotwind's
ocean.

The target architecture is:

- The opaque FFT ocean surface remains the owner of the visible water surface,
  reflections, foam, and surface color.
- A dedicated waterline / underwater compositor owns submerged-object bending,
  half-underwater camera transition, underwater fog/backscatter, caustics,
  rays, wobble, and volume matter.
- `UnderwaterVolume` remains diagnostic / temporary support. Do not bolt final
  waterline visuals onto it.
- `WaterSurfaceState` / `OceanManager` are the shared water contract. Do not
  create a parallel water API.

In practical terms, the player should eventually be able to look at
half-submerged objects, cross the water surface, and swim underwater without the
scene turning into a flat dark overlay or a debug-colored screen-space hack.

## Current Status

Update later on 2026-05-09: the waterline compositor path is now visually
working in Ocean Lab at the ownership / ordering level, but it is still not
production complete.

What changed after this handoff was written:

- `WaterlineCompositorEffect` now runs at `POST_TRANSPARENT`, so the visible
  opaque ocean surface no longer overdraws the receiver waterline result.
- Ocean Lab starts with `Waterline: On` and `WL Res: 100%`.
- `WL Debug: Pipeline` was added to prove source buffers, depth, gates, and
  final image writes.
- `WL Debug: Receiver Mask` now shows the active gate used by Final mode.
- Final / Refract modes can pull a submerged receiver from a neighboring UV,
  so waterline refraction can bend the receiver silhouette instead of only
  tinting same-pixel object coverage.
- Refraction strength was intentionally nudged above purely subtle physical
  scale for readable game-art feedback.

The user visually confirmed:

- receiver masks draw over the real ocean surface with `Ocean Mesh: On`;
- Final/Refract mode now works, but still needs polish;
- moving away can make the effects stop abruptly and later reappear;
- in the main Godotwind scene a square-ish area around the camera appears to
  bound where waterline/underwater effects work.

Audit note for the abrupt cutoff / square footprint:

- `PrewaterCaptureRenderer.near_water_capture_distance_m` is hard-coded to
  `120.0`; the receiver capture disables when the camera is more than this
  vertical distance above the sampled water level.
- `WaterlineCompositorEffect._near_water_activation_distance` is also
  hard-coded to `120.0`; Final mode skips work when the camera is above that
  band.
- The current Final mask still depends on main-view ocean depth / visible-water
  coverage for some cases. Where the ocean mesh/depth is absent, clipped, or
  falls outside a square clipmap footprint, the compositor gate closes hard.
- The ocean mesh in clipmap mode is square-ring geometry snapped around the
  camera (`OceanMesh.update_position()` snaps in 40 m steps for current HIGH
  settings). That square geometry can become visible in any effect that uses
  the rendered ocean depth as its coverage source.

Treat this as the next architecture problem, not as a refraction-strength
tuning bug. The proper fix is to replace hard activation/coverage gates with a
stable water-coverage contract: receiver capture/compositor activation should
fade or be driven by the camera frustum/water body, and waterline eligibility
should come from `WaterSurfaceState` / water body coverage rather than the
finite square ocean mesh depth alone.

Previous status from the start of this handoff follows.

The waterline compositor path was still not working visually in Final mode.

The debug classifier showed signs of being conceptually close:

- Red / magenta appeared on object portions below the water.
- Blue appeared on the above-water / visible-gate side.
- Green appeared mainly around the transition, likely where the camera ray
  crosses water before hitting the object.

However, the final visual result still does not read correctly. Treat the most
recent shader tuning as experimental, not production-ready.

## What Was Done

### Removed partial production underwater visuals

Earlier partial underwater visuals were removed from default / production
behavior. The project should not present that old first-pass effect as the
shipping solution.

### Added pre-water receiver capture component

`src/core/water/prewater_capture_renderer.gd` now owns the reusable receiver-only
capture path for waterline / underwater compositors.

It manages:

- a `SubViewport`;
- a matching camera;
- receiver-only render layers;
- resolution scaling;
- near-water / underwater activation;
- passing color/depth buffers to the waterline compositor.

This is the right Godot-family workaround for needing receiver color/depth before
the opaque ocean surface participates in the main view.

### Extended WaterSurfaceState

`src/core/water/water_surface_state.gd` was expanded as the central water
contract.

It now carries:

- water body id / index;
- coverage source and coverage query;
- signed shore distance query;
- shore side query;
- normal texture readiness;
- normal / gradient CPU sample callables;
- explicit velocity slot;
- snapshot / surface / readback frame ids;
- GPU and CPU cascade readiness masks.

Important: velocity is intentionally exposed but not faked. It remains
unavailable until the wave pipeline publishes real `dDisplacement/dt`.

### Extended OceanManager as producer

`src/core/water/ocean_manager.gd` now fills the expanded
`WaterSurfaceState`.

It also exposes:

- `get_normal_texture_rd()`;
- `get_wave_gradient()`;
- `get_wave_velocity()` as a truthful zero placeholder until real velocity data
  exists;
- `get_water_coverage()`;
- `get_signed_shore_distance()`;
- `get_shore_side()`;
- `get_water_body_id_at()`.

### Fixed object wetness behavior

Object wetness was changed so live dynamic contact dominates. `wet_line_y` is
now weaker retained drying memory, not the primary current water contact source.

Practical effect: wetness should follow actual FFT / shore water contact more
closely instead of hanging onto stale waterline values too strongly.

### Ocean Lab controls and HUD

`tests/visual/test_ocean_lab.gd` now has:

- `Waterline: On/Off`;
- `WL Debug` modes;
- `WL Res` resolution scale cycling;
- HUD display for prewater capture active / idle state and source size;
- HUD display for water coverage source and cascade readiness masks.

### Waterline compositor changes

`src/core/shaders/effects/waterline_compositor_effect.gd` now:

- receives dynamic camera water level;
- can skip work when far above water in Final mode;
- allows debug mode 8;
- no longer relies only on the lab toggle for activation policy.

`src/core/shaders/compute/waterline_probe.glsl` was changed experimentally to:

- remove the underwater-camera early return;
- estimate ray / dynamic-water crossing;
- expose `Camera Split` debug mode;
- add a shore-mask / runup-based water coverage gate;
- tune Final mode toward absorption / backscatter instead of proof colors.

This shader work needs more debugging. The user reported: "It doesn't work."

## Verification Done

For shader changes:

- Deleted `.godot/imported/waterline_probe.glsl-*`.
- Ran:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind --import
```

- Confirmed waterline shader import artifacts regenerated.
- Ran Ocean Lab crash smoke successfully:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --headless --path D:/Gamedev/Godotwind/godotwind --quit-after 5 res://tests/visual/test_ocean_lab.tscn
```

- Launched Ocean Lab interactively after changes.

No C# files changed in this slice, so `dotnet build Godotwind.sln` was not
required.

## What Is Known Broken / Unfinished

### Final waterline visual does not work yet

The compositor's debug classification gives useful signals, but Final mode still
does not produce the desired waterline / underwater result.

Do not assume the current `waterline_probe.glsl` Final-mode tuning is correct.
Use it as a diagnostic starting point.

### Waterline compute still duplicates ocean surface reconstruction

`waterline_probe.glsl` still reconstructs FFT / shore water height itself.

This is a duplication risk because `ocean_surface_common.gdshaderinc` is the
surface shader source of truth, but imported `.glsl` compute shaders do not have
a verified safe include path in current project usage.

Next proper step is either:

- verify a Godot 4.6-supported include / preprocessing route for imported
  compute shaders, or
- generate shared GLSL snippets / constants from a small script so the shader
  math is not hand-copied.

Do not silently hand-sync this forever.

### Coverage is still approximate

`WaterSurfaceState` now has coverage/body concepts, but the compute shader only
uses shore-mask/runup coverage. There is not yet a robust water body id buffer,
water depth buffer, or per-pixel coverage mask.

### Half-underwater camera is only classifier-level

The shader now tries ray / water crossing classification, but it does not yet
produce a polished half-underwater screen transition:

- no proper Snell's window;
- no meniscus foam line;
- no temporal smoothing;
- no dedicated underwater fog volume;
- no rays / caustics integration.

### Underwater compositor proper has not started

Still remaining:

- DIVE-style absorption and backscatter/fog;
- broad normal wobble;
- normal-aware caustics;
- low-res light rays;
- particles / volume matter.

## Recommended Next Steps

### 1. Debug why Final mode does not work

Start in Ocean Lab only. The user said Godotwind main scene does not need to be
launched for every water iteration right now.

Use:

- `Waterline: On`;
- `WL Debug: Camera Split`;
- `WL Debug: Receiver Mask`;
- `WL Debug: Final`;
- `WL Res` at 100% first to remove resolution-scaling ambiguity.

Check whether the problem is:

- source color/depth is missing or one frame stale;
- the coverage gate is zeroing the effect;
- the visible-water gate is too strict;
- the refraction sample fallback rejects too many pixels;
- the shader is writing but too subtly;
- the composited pixels are hidden by opaque ocean order.

### 2. Add explicit diagnostic meters before more beauty work

Before adding prettier underwater optics, add a simple debug mode or HUD signal
that proves:

- source buffers are valid;
- receiver depth is nonzero;
- main depth is nonzero;
- water body gate is nonzero;
- final mask is nonzero;
- final imageStore is actually reached.

This is more useful than continuing to tune color constants blindly.

### 3. Consider simplifying the shader path temporarily

If Final mode remains opaque, temporarily reduce the compute shader to:

- classify receiver underwater;
- apply a strong obvious tint only where the final mask is nonzero;
- no refraction;
- no backscatter;
- no meniscus.

Once the write path is proven, add refraction / absorption back one at a time.
This should be a diagnostic simplification, not the final feature.

### 4. Promote shared water reconstruction

Once the compositor visibly works, reduce duplicated water-height logic. The
clean target is a shared generated shader helper or another verified Godot 4.6
supported method, not another hand-copied math block.

### 5. Then build underwater optics

Only after waterline ownership is proven:

- underwater absorption / backscatter;
- normal wobble;
- caustics;
- rays;
- particles / volume matter.

## Files Touched In This Track

- `src/core/water/water_surface_state.gd`
- `src/core/water/ocean_manager.gd`
- `src/core/water/prewater_capture_renderer.gd`
- `src/core/shaders/effects/waterline_compositor_effect.gd`
- `src/core/shaders/compute/waterline_probe.glsl`
- `tests/visual/test_ocean_lab.gd`
- `docs/systems/ocean.md`

## Notes For The Next Agent

- Do not use `UnderwaterVolume` as the final waterline owner.
- Do not create a parallel water contract.
- Do not call the current waterline shader production-complete.
- If `waterline_probe.glsl` changes, clear
  `.godot/imported/waterline_probe.glsl-*` and run Godot `--import` before
  visual testing.
- Use Ocean Lab as the main interactive verification target for now.
- If C# changes, run `dotnet build Godotwind.sln` before launching Godot.
