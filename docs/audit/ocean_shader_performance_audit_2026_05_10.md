# Ocean Shader Performance Audit - 2026-05-10

## Original Verdict (Pre-Recovery)

The ocean slowdown looked architectural, not like one bad constant. The
pre-recovery path had accumulated several full-resolution passes and one
duplicate scene render around the water shader:

1. The FFT ocean surface still declares `hint_screen_texture` and runs a
   per-fragment custom SSR raymarch.
2. Ocean Lab runs an always-updating receiver `SubViewport` at 100% resolution
   by default.
3. The receiver viewport output is copied into RD textures every active frame.
4. `WetCompositorEffect` runs a full-screen `PRE_TRANSPARENT` compute pass and
   requests resolved color, resolved depth, and Forward+ normal/roughness.
5. `WaterlineCompositorEffect` runs a full-screen color-copy pass.
6. `WaterlineCompositorEffect` then runs a second full-screen compute pass for
   waterline/underwater composition.

At 1080p that is millions of extra invocations per pass. At 1440p or 4K it
scales brutally. Hitting 25 ms is plausible even before streaming, terrain, or
scene complexity are blamed.

## Recovery Note - 2026-05-10

Current intended logic is:

- The FFT ocean surface is the visible opaque water: waves, foam, depth tint,
  sky/probe reflection, and no screen-color ownership.
- `PrewaterCaptureRenderer` captures only opt-in receiver objects, at reduced
  resolution, near the water.
- `WaterlineCompositorEffect` owns receiver refraction plus underwater camera
  optics. Heavy meniscus/underwater scene sampling is opt-in or underwater-only.
- `WetCompositorEffect` is experimental/debug quality work and stays off unless
  explicitly enabled.

Issues found:

- Surface SSR had reintroduced `hint_screen_texture` and a per-pixel raymarch on
  the whole ocean.
- Ocean Lab was capturing almost the whole scene instead of receiver-only
  objects.
- The capture and waterline activation band was too large for a live
  SubViewport.
- Wetness could silently add a full-screen pre-transparent pass.
- Snell was sampling the receiver buffer as if it were the sky/above-water
  source.

Recovery verification:

- Cleared waterline/wet/prewater/screen-copy compute imports and relevant water
  shader cache entries, then ran Godot `--import`.
- `dotnet build Godotwind.sln`: passed.
- `test_ocean_spray_smoke.tscn`: passed.
- `test_ocean_lab_mesh_toggle_smoke.tscn`: passed.
- Launched `test_ocean_lab.tscn` interactively for human visual inspection.

## Canonical Godot Constraints

- Godot's screen-reading shader docs state that 3D materials using
  `hint_screen_texture` are treated as transparent and that the 3D screen copy
  happens once after opaque rendering and before transparent rendering.
- Godot `CompositorEffect.access_resolved_color` and `access_resolved_depth`
  trigger MSAA resolves when MSAA is enabled.
- Godot `SubViewport.UPDATE_ALWAYS` always re-renders the target. The docs call
  out `UPDATE_ONCE` / disabled update modes as the way to avoid paying every
  frame for reusable render textures.

The intended Godotwind architecture says "opaque ocean surface, compositor owns
receiver refraction." The recovery patch restores that surface contract and
keeps heavyweight receiver/wetness/underwater work gated.

Sources:

- Godot 4.6 `CompositorEffect`: https://docs.godotengine.org/en/4.6/classes/class_compositoreffect.html
- Godot screen-reading shaders: https://docs.godotengine.org/en/stable/tutorials/shaders/screen-reading_shaders.html
- Godot 4.6 `SubViewport`: https://docs.godotengine.org/en/4.6/classes/class_subviewport.html
- Godot 4.6 compute shaders: https://docs.godotengine.org/en/4.6/tutorials/shaders/compute_shaders.html

## Findings (Original Audit)

### 1. The Ocean Surface Is Not Actually The Cheap Opaque Surface The Docs Describe

Evidence:

- `src/core/water/shaders/ocean_fft_common.gdshaderinc` declares
  `SCREEN_TEXTURE` at line 72.
- The same include runs `ssr_trace()` from the fragment path at lines 408-421.
- `ssr_trace()` loops up to `ssr_max_steps` and samples depth/screen textures
  per step.

Practical effect:

The visible ocean covers a large portion of the frame. Every water pixel can pay
for normal-map work, foam samples, Beer-Lambert depth, lighting, and custom SSR.
The `hint_screen_texture` declaration also violates the "opaque surface avoids
screen-color ownership" decision in `docs/systems/ocean.md`.

Recommended fix:

Revert the FFT surface to the true opaque contract:

- Remove `SCREEN_TEXTURE` from the surface shader.
- Disable/remove custom surface SSR as the default path.
- Keep sky/probe/Godot reflection contribution through normal spatial material
  outputs.
- If object reflections are required later, reintroduce them as a quality-gated,
  measured path, not as mandatory per-fragment SSR over the whole ocean.

### 2. Receiver Capture Is Rendering Far Too Much, Too Often

Evidence:

- `tests/visual/test_ocean_lab.gd` defaults `_waterline_resolution_index = 0`,
  so prewater capture starts at 100% resolution.
- `PrewaterCaptureRenderer._apply_active_state()` sets
  `render_target_update_mode = SubViewport.UPDATE_ALWAYS` while active.
- Ocean Lab now configures the prewater mask as
  `(_camera.cull_mask | WATER_REFRACTION_RECEIVER_LAYER_MASK) & ~WATER_RENDER_LAYER_MASK`,
  which is effectively the main camera minus water rather than a narrow
  opt-in receiver layer.

Practical effect:

The waterline system is no longer just capturing half-submerged receiver
objects. In Ocean Lab it can pay for a second near-full scene render every frame,
then copy that viewport's color and depth into RD textures.

Recommended fix:

- Restore receiver-only capture as the default mask.
- Default capture to 50% or 25% resolution while the effect is being rebuilt.
- Keep `UPDATE_ALWAYS` only inside a tight active band and only for scenes that
  genuinely need live receiver refraction.
- Make "full scene receiver capture" a debug option, not the production default.

### 3. The Compositor Stack Has Too Many Full-Screen Passes

Evidence:

- `WetCompositorEffect` runs at `PRE_TRANSPARENT`, requests resolved color/depth
  and normal/roughness, then dispatches over the whole internal viewport.
- `WaterlineCompositorEffect` requests resolved color/depth at
  `POST_TRANSPARENT`, copies scene color into `_scene_color_copy_rid`, then
  dispatches `waterline_probe.glsl` over the whole viewport.
- `PrewaterCaptureEffect` copies receiver color and depth from the capture
  viewport into sampleable textures.

Practical effect:

The active Ocean Lab path can do:

- second scene render;
- receiver color/depth copy;
- wetness full-screen compute;
- main scene color copy;
- waterline/underwater full-screen compute.

Early returns inside compute shaders help arithmetic cost but do not remove the
dispatch, resolves, texture bandwidth, or per-pixel classification overhead.

Recommended fix:

- Add explicit per-pass timing for prewater capture, wet compositor, waterline
  scene copy, and waterline probe.
- Treat wetness as optional until measured. It should not silently enable a
  full-screen normal/roughness pass in production.
- Move expensive underwater-only work behind a camera-underwater branch before
  doing receiver/object work.
- Consider splitting underwater rays/particles/caustics into a lower-resolution
  pass if they remain production features.

### 4. Dynamic Water Classification Is Recomputed Too Many Times Per Pixel

Evidence:

- `wet_compositor.glsl` and `waterline_probe.glsl` both mirror the water surface
  contract instead of sharing generated code.
- `get_dynamic_water_level()` does two inverse-horizontal-displacement
  iterations and then samples the surface again.
- Each `sample_surface()` loops cascades, samples displacement, samples the
  shore mask, and evaluates shore-wave math.
- `waterline_probe.glsl` calls the dynamic water query repeatedly from
  receiver classification, camera split, refraction fallback, water ray tracing,
  normals, rays, caustics, and Snell/wobble code.

Practical effect:

The compositor is doing expensive water-surface reconstruction in screen space
for many pixels and often several times for the same pixel. The cost grows with
resolution and with enabled underwater features.

Recommended fix:

- Compute one `WaterSurfaceContractSample` per relevant pixel and reuse it.
- Use stable mean sea level + alpha body mask for broad activation/gating.
- Use full FFT dynamic height/normal only where the pixel has already passed a
  cheap water-body/near-surface test.
- Keep rays/particles/caustics out of above-water receiver refraction unless
  the camera is underwater.

### 5. Wetness Can Enable Itself In Production

Evidence:

- `project.godot` now autoloads `WetnessManager`.
- `ShaderManager` loads every `.gd` effect in `src/core/shaders/effects`.
- `WetnessManager._sync_shader_manager_effect()` enables `wet_compositor`
  whenever it finds the effect and wetness is enabled.

Practical effect:

The full-screen wetness compositor can become a hidden production cost as soon
as active water state exists and ShaderManager is attached to a
`WorldEnvironment`.

Recommended fix:

- Put wetness behind an explicit quality setting/subsystem toggle.
- Default broad screen-space wetness off until measured.
- Prefer material hooks or receiver/object-scoped wetness for the common case.

### 6. Current GPU Timing Does Not Measure The Whole Water Cost

Evidence:

- `WaterlineCompositorEffect` exposes timing for scene copy and waterline probe.
- It does not include the prewater SubViewport render, prewater capture copy,
  wet compositor, ocean surface shader cost, or GPU cost from screen-texture
  surface SSR.

Practical effect:

The HUD can say the waterline probe is cheap while the frame is still blown up
by the receiver viewport, wet pass, or surface SSR.

Recommended fix:

- Add timing snapshots for wet compositor and prewater capture.
- Add an Ocean Lab perf ladder: ocean surface only, +prewater capture,
  +waterline, +wetness, +spray, +underwater features.
- Use the existing main-scene `--bench-ladder` as the production acceptance
  gate once the path is integrated.

## Recovery Order

1. Instrument first, but only enough to see the cost split.
2. Remove `SCREEN_TEXTURE` and default custom SSR from the FFT surface.
3. Restore prewater capture to receiver-only, lower-resolution, tightly gated.
4. Disable or quality-gate `WetCompositorEffect` by default.
5. Reuse water-surface samples inside `waterline_probe.glsl`; cheap body gate
   first, dynamic FFT details second.
6. Move rays, particles, and caustics to quality tiers or lower-resolution
   passes.
7. Only after the budget is under control, tune Snell/wobble/rays artistically.

Target budget suggestion for a 5-6 ms ocean stack:

- visible FFT surface: 1.0-2.0 ms;
- FFT simulation/readback: under 1.0 ms;
- receiver capture: 0.5-1.0 ms active, 0 ms inactive;
- waterline/underwater compositor: 0.5-1.5 ms active;
- wetness: 0 ms default or under 0.3 ms when explicitly enabled;
- spray: under 0.5 ms at normal quality.

## Verification Done For This Audit

- `dotnet build Godotwind.sln`: passed.
- Checked for imported compute shader artifacts matching
  `waterline_probe`, `wet_compositor`, `prewater_capture`, and
  `screen_color_copy`: none were present.
- Ran Godot `--import` with the documented 4.6 Mono binary.
- Ran `tests/visual/test_ocean_spray_smoke.tscn`: exit code 0.

No interactive visual approval pass was performed for this audit, and no
rendering code was changed.
