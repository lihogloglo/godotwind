# Underwater

Current-state reference for the underwater volume effect.

Implementation: volume-based spatial shader on a camera-following BoxMesh,
ported from
[paddy-exe/Godot-RealTimeCaustics](https://github.com/paddy-exe/Godot-RealTimeCaustics)
(MIT). An earlier compute-shader CompositorEffect path is dead code targeted
for deletion — see the "Dead code" row in the file table below.

**Active effects:** world-space caustics (voronoi noise texture panned along
the sun-direction plane, with the proper `transmittance` re-use on the return
path), Beer-Lambert absorption driven by real view-space distance, wobble via
a sampled normal texture (openmw `water_nm.png`) at world XZ with time
animation, above-water/sky guards on the wobble sample to prevent above-water
color bleeding into the submerged region.

---

## Architecture

| File | Purpose |
|------|---------|
| `src/core/water/shaders/underwater_volume.gdshader` | Spatial shader on a BoxMesh volume. `render_mode blend_mix, cull_front, depth_test_disabled, unshaded`. Reconstructs world pos from DEPTH_TEXTURE, slabs to `[sea_level - volume_depth, sea_level]` in Y, applies wobble + absorption + caustics. |
| `src/core/water/underwater_volume.gd` | Node3D wrapper. 500×40×500 BoxMesh, follows camera position (NOT rotation), hides above water, updates `sea_level` each frame. Documented `blend_mix` deviation vs paddy-exe source. |
| `src/core/water/ocean_manager.gd` | Owns the legacy ShaderManager compositor switch. Ocean Lab calls `set_underwater_compositor_enabled(false)` so the old compositor does not race the volume diagnostic. |
| Ocean Lab `UW Debug` | Interactive-only diagnostic control for the volume shader. `Slab Mask` paints water-classified pixels cyan, `Depth/Y` colors reconstructed underwater depth, and `Big Wobble` exaggerates the volume contribution. |
| Ocean Lab wave sync | `UnderwaterVolume.sync_wave_surface_from_ocean_material()` copies FFT cascade scales, wave scale, shore mask, and shore-wave uniforms from the active ocean material so the volume's waterline follows the displaced FFT surface instead of a flat `sea_level` plane. |
| `assets/water/caustics_noise.png` | paddy-exe's `caustics-generator.png`, MIT. |
| `assets/water/caustics_luma_gradient.tres` | paddy-exe's luma ramp. |
| `assets/water/water_normal.png` | openmw `water_nm.png`, MIT. **Must be imported with `compress/normal_map=1` (Normal Map mode)** — otherwise sRGB decode biases `wobble_offset` to a constant non-zero state. |
| `tests/visual/test_underwater.gd` + `.tscn` | Interactive test scene. Hits the volume via `_setup_underwater_volume()`; the old `UnderwaterCompositorEffect` path is force-disabled at runtime. |

### Dead code (compute-shader pre-pivot, targeted for deletion)

| File | Status |
|------|--------|
| `src/core/shaders/compute/underwater.glsl` | Dead. Compute-shader CompositorEffect with push-constant matrices, procedural FBM wobble, voronoi caustic math. |
| `src/core/shaders/effects/underwater_compositor_effect.gd` | Dead. Companion GDScript — still loaded by `OceanManager._load_underwater_effect()` via `ShaderManager.load_effect()`, then force-disabled at scene startup by `test_underwater.gd`. Full removal requires unwiring `OceanManager.get_underwater_effect()` + `ShaderManager` hooks. |
| `src/core/water/shaders/underwater.gdshader` | Dead. Earlier quad-based approach. |
| `src/core/water/underwater_effect.gd` | Dead. Companion script. |

---

## Gotchas (load-bearing warnings for future agents)

1. **`Basis[i]` returns columns, not rows.** Same as `basis.x/y/z`. Regression
   test at `tests/unit/test_basis_packing.gd`. Misreading this as rows
   corrupts any matrix packed into a push-constant / storage buffer from
   GDScript.
2. **Do not use procedural FBM for wobble.** FBM sampled at screen-space UV
   frequencies produces visible horizontal banding locked to the camera.
   A sampled normal texture at world-space XZ is the only technique that
   looks right under motion. Do not regress to FBM.

---

## Known remaining issues (user-accepted "move on")

1. **Wobble waterline ghosting.** Even with the above-water guard, at some
   camera angles the wobble's screen-UV offset pulls content across the
   waterline visibly. The hard-switch fall-back (`wobbled_uv = SCREEN_UV`
   when the neighbor is above water) kills most of the artifact but not all.
   The contingency of widening the guard by 0.1m below sea level was not
   applied.
2. **`sea_level` wiring.** The test scene pulls from
   `OceanManager.get_sea_level()` in `_process()`. Production scenes must do
   the same. If `sea_level` is wrong (e.g. default 0 when the scene uses a
   different water plane), the slab test rejects the wrong pixels and
   effects appear in the wrong place.
   In Ocean Lab, the flat `sea_level` plane is only the fallback. The volume
   shader receives the active ocean material's FFT/shore uniforms and computes
   the displaced water height per pixel, matching moving wave crests/troughs.
3. **Above-water diagnostic mode is not a production solution.**
   `UnderwaterVolume.set_active_above_water(true)` exists for Ocean Lab
   render-order diagnosis. With the opaque ocean mesh visible, the depth
   texture may reconstruct the ocean surface rather than submerged objects
   behind it. If this is confirmed, above-water waterline/submerged-object
   distortion needs a compositor/pre-ocean/subpass design instead of only a
   late transparent volume. See
   `docs/audit/ocean_option_c_render_order_2026_05_07_codex.md`.
   Use Ocean Lab's `UW Debug` modes before drawing conclusions from subtle
   final shading: `Slab Mask` paints water-classified pixels cyan, and
   `Big Wobble` makes the volume contribution obvious if it is running.
4. **Ocean surface seen from below (the "ceiling") is unaffected by this
   shader.** The slab test rejects pixels where `scene_world_pos.y ≥
   sea_level`, which includes the ocean-surface mesh's fragments. By design —
   owned by `@water` as a separate "underwater POV" fix to
   `ocean_fft.gdshader` (Snell's-window bright-spot). When that lands, this
   shader needs zero changes.
5. **Wave-driven caustic scaling.** The caustic noise texture is panned at a
   fixed `caustics_scale` and `caustics_speed`. Physically, caustic cell size
   is driven by the dominant wave wavelength (big swell = big cells).
   Proposed interface: `OceanManager.get_dominant_wavelength()` +
   `get_surface_variance()` to drive `caustics_scale` and `caustics_speed`
   as per-frame uniforms. Not implemented.
6. **Shared absorption constants.** Ocean Lab now calls
   `UnderwaterVolume.sync_optical_constants_from_ocean_manager()`, which copies
   `OceanManager.get_absorption_tint()`, `get_absorption_sigma()`, and
   `get_underwater_caustics_strength()` into the volume. The compositor
   prototype should use the same typed getters so crossing the waterline does
   not jump between unrelated surface/underwater water colors.

---

## Effects status — Port vs Reference

Reference: `inspos/RafaelsShaderPack/Shaders/DIVE.omwfx` (OpenMW omwfx format).

| Effect | DIVE source | Current status |
|--------|------------|----------------|
| Voronoi caustics | `ComputeCaustics()` + `GetCausticEdge()` | **Not ported.** Current caustics use paddy-exe's sampled noise texture with panned UVs, not DIVE's procedural voronoi. Different technique, similar visual result. |
| Beer-Lambert absorption | Lines 424-435 | **Ported.** `exp(-sigma * length(scene_pos - cam_pos))` applied via `mix(water_tint, scene_color, transmittance)`. Per-channel `sigma`; DIVE had `SIGMA = 0.001196 * (1 - WATER_COLOR_0)` giving nicer wavelength-dependent absorption but we hardcoded a uniform scalar. |
| Screen wobble | Lines 397-400 | **Ported with guards.** DIVE uses a 3D water normal sampled at `(screen_uv, 0.2*time)`. We use a 2D normal at `world_pos.xz / tiling + time * speed`. World-space sampling avoids the camera-locked banding the FBM implementation had. |
| Shell-based light rays | Lines 477-500 | **Not ported.** Deferred. |
| Backscattering | Lines 509-520 | **Not ported.** Deferred. |
| Water boundary highlight | Custom (not DIVE) | **Not ported.** Deferred. |
| Anti-banding dithering | Lines 524-527 | **Not ported.** Deferred. |

---

## Test scene controls (interactive only — no automated captures)

```
RMB         = Hold to look, ZQSD to move, Space/Ctrl up/down
Shift       = Fast move
U           = Toggle underwater volume on/off
1-5         = Toggle individual features (legacy CompositorEffect flags,
              ignored by the volume shader)
6           = Cycle debug modes on the OLD compute shader (no-op now)
R           = Reset camera to underwater (y=-8)
G           = Reset camera to surface (y=-0.2, boundary view)
+/-         = Legacy absorption rate adjust (on the old shader, no-op now)
O           = Toggle ocean visibility
```

Launch:
```
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" res://tests/visual/test_underwater.tscn
```

**Anti-pattern (per `.claude/CLAUDE.md`):** do NOT re-introduce automated
screenshot / auto-capture harnesses for verification. User drives the camera,
agent watches the report.
