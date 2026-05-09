# Underwater

Current-state reference for underwater camera/compositor behavior and the
remaining diagnostic underwater volume.

Production underwater caustics are compositor-owned. The paddy-exe caustics
texture reference has been archived into `WaterlineCompositorEffect`; the old
volume caustic branch was removed on 2026-05-09 so there is one caustics owner.

**Active effects:** the compositor owns Snell-window transmission, underwater
absorption/path fog, receiver caustics, surface-anchored rays, FFT-normal
wobble, and sparse particulate. `UnderwaterVolume` remains a diagnostic spatial
volume for slab/depth/wobble checks and no longer draws caustics.

---

## Architecture

| File | Purpose |
|------|---------|
| `src/core/water/shaders/underwater_volume.gdshader` | Diagnostic spatial shader on a BoxMesh volume. `render_mode blend_mix, cull_front, depth_test_disabled, unshaded`. Reconstructs world pos from DEPTH_TEXTURE, slabs against the shared dynamic water surface with a small top tolerance, and applies diagnostic wobble + absorption only. It does not draw caustics. |
| `src/core/water/underwater_volume.gd` | Node3D wrapper. 500×40×500 BoxMesh, follows camera position (NOT rotation), hides above water in final mode, updates `sea_level` each frame. Above-water visibility is diagnostic-only and requires a non-final debug mode. |
| `src/core/water/ocean_manager.gd` | Publishes `WaterSurfaceState` and optical constants. It no longer exposes or loads the retired ShaderManager underwater compositor. |
| Ocean Lab `UW Debug` | Interactive-only diagnostic control for the volume shader. `Slab Mask` paints water-classified pixels cyan, `Depth/Y` colors reconstructed underwater depth, and `Big Wobble` exaggerates the volume contribution. |
| Ocean Lab wave sync | `UnderwaterVolume.sync_wave_surface_from_ocean_material()` copies FFT cascade scales, wave scale, shore mask, and shore-wave uniforms from the active ocean material so the volume's waterline follows the displaced FFT surface instead of a flat `sea_level` plane. |
| `WaterlineCompositorEffect` underwater view | Production owner for broad underwater camera optics and receiver-waterline shading. It copies the post-transparent scene color into a safe sample texture, classifies receivers against the shared dynamic water surface, then applies Snell-window transmission, absorption/path fog, receiver caustics, world-surface-anchored faint rays, FFT-normal wobble, and sparse suspended particulate. |
| `assets/water/caustics_noise.png` | paddy-exe's `caustics-generator.png`, MIT. Used by the compositor caustics path. |
| `assets/water/caustics_luma_gradient.tres` | Archived paddy-exe luma ramp reference. The compositor uses the same ramp values analytically because GradientTexture2D does not bind cleanly as an RD compute texture. |
| `assets/water/water_normal.png` | openmw `water_nm.png`, MIT. **Must be imported with `compress/normal_map=1` (Normal Map mode)** — otherwise sRGB decode biases `wobble_offset` to a constant non-zero state. |
| `tests/visual/test_underwater.gd` + `.tscn` | Interactive diagnostic scene for `UnderwaterVolume`. It is not the production compositor path. |

### Deleted legacy paths (compute-shader / quad pre-pivot)

| File | Status |
|------|--------|
| `src/core/shaders/compute/underwater.glsl` | Deleted 2026-05-09. Retired compute compositor shader. |
| `src/core/shaders/effects/underwater_compositor_effect.gd` | Deleted 2026-05-09. Retired ShaderManager-loaded wrapper. |
| `src/core/water/shaders/underwater.gdshader` | Deleted 2026-05-09. Retired full-screen quad shader. |
| `src/core/water/underwater_effect.gd` | Deleted 2026-05-09. Retired quad script. |

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
   render-order diagnosis, but it only makes non-final debug modes visible
   above water. Final above-water waterline/submerged-object distortion belongs
   to the pre-water compositor path; the transparent volume must not overwrite
   that result. See
   `docs/audit/ocean_option_c_render_order_2026_05_07_codex.md`.
   Use Ocean Lab's `UW Debug` modes before drawing conclusions from subtle
   final shading: `Slab Mask` paints vertically submerged pixels cyan, and
   `Big Wobble` makes the volume contribution obvious if it is running.
4. **Ocean surface seen from below (the "ceiling") is unaffected by this
   shader.** The slab test rejects pixels where `scene_world_pos.y ≥
   sea_level`, which includes the ocean-surface mesh fragments. By design:
   broad underwater POV is now owned by `WaterlineCompositorEffect`, not by
   this diagnostic volume.
5. **Shared absorption constants.** Ocean Lab now calls
   `UnderwaterVolume.sync_optical_constants_from_ocean_manager()`, which copies
   `OceanManager.get_absorption_tint()` and `get_absorption_sigma()` into the
   volume. The compositor uses the same `WaterSurfaceState` optical values and
   dynamic surface lookup so crossing the waterline does not jump between
   unrelated water colors or surface classifications.

---

## Effects status — Port vs Reference

Reference: `inspos/RafaelsShaderPack/Shaders/DIVE.omwfx` (OpenMW omwfx format).

| Effect | DIVE source | Current status |
|--------|------------|----------------|
| Voronoi caustics | `ComputeCaustics()` + `GetCausticEdge()` | **Compositor-owned.** Current caustics use paddy-exe's sampled noise texture with panned light-projected UVs in `waterline_probe.glsl`, not DIVE's procedural voronoi. The old volume caustic path is removed. |
| Beer-Lambert absorption | Lines 424-435 | **Ported.** `exp(-sigma * length(scene_pos - cam_pos))` applied via `mix(water_tint, scene_color, transmittance)`. Per-channel `sigma`; DIVE had `SIGMA = 0.001196 * (1 - WATER_COLOR_0)` giving nicer wavelength-dependent absorption but we hardcoded a uniform scalar. |
| Screen wobble | Lines 397-400 | **Ported with guards.** DIVE uses a 3D water normal sampled at `(screen_uv, 0.2*time)`. We use a 2D normal at `world_pos.xz / tiling + time * speed`. World-space sampling avoids the camera-locked banding the FBM implementation had. |
| Shell-based light rays | Lines 477-500 | **Compositor-owned.** `waterline_probe.glsl` samples faint shafts along the view ray, projects each underwater sample back to the dynamic water surface along the sun vector, and evaluates the column pattern at that world-space surface footprint. This is not a literal DIVE port, but follows the same shell idea without camera-locked rays. |
| Backscattering | Lines 509-520 | **Partially ported.** Path fog and water-color convergence now live in the compositor; normal-facing surface backscatter remains deferred. |
| Water boundary highlight | Custom (not DIVE) | **Not ported.** Deferred. |
| Anti-banding dithering | Lines 524-527 | **Not ported.** Deferred. |

---

## Test scene controls (interactive only — no automated captures)

```
RMB         = Hold to look, ZQSD to move, Space/Ctrl up/down
Shift       = Fast move
U           = Toggle underwater volume on/off
3           = Toggle volume wobble
6           = Cycle volume debug modes
R           = Reset camera to underwater (y=-8)
G           = Reset camera to surface (y=-0.2, boundary view)
O           = Toggle ocean visibility
```

Launch:
```
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" res://tests/visual/test_underwater.tscn
```

**Anti-pattern (per `.claude/CLAUDE.md`):** do NOT re-introduce automated
screenshot / auto-capture harnesses for verification. User drives the camera,
agent watches the report.
