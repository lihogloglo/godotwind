# Underwater

Current-state reference for underwater camera/compositor behavior.

Production underwater rendering is compositor-owned. The old
`UnderwaterVolume` diagnostic box was deleted on 2026-05-11 so the project no
longer has a second spatial-volume underwater renderer competing with the
final path.

**Active effects:** `WaterlineCompositorEffect` owns the underwater path, but
effects are quality-gated. Low quality is absorption/path fog plus
meniscus/refraction, medium adds Snell-window transmission, FFT-normal
wobble, and the cheap underwater ray shafts, and high adds sparse particulate
and caustics. As of
2026-05-11, user Ocean Lab testing still reports no visible underwater
particles or caustics, so those high-tier effects are not accepted art yet.

---

## Architecture

| File | Purpose |
|------|---------|
| `src/core/shaders/effects/waterline_compositor_effect.gd` | Production underwater/waterline compositor wrapper. Runs at `POST_TRANSPARENT`, owns feature flags, debug modes, GPU timings, source buffers, sun direction, and `WaterSurfaceState` sync. |
| `src/core/shaders/compute/waterline_probe.glsl` | Production compute shader for waterline receiver refraction and underwater camera optics. |
| `src/core/water/prewater_capture_renderer.gd` | Optional receiver-only SubViewport capture for objects that need waterline refraction. |
| `src/core/water/water_surface_state.gd` | Shared water-surface/optics contract consumed by the compositor, surface shaders, wetness, and future water bodies. |
| `src/core/water/ocean_manager.gd` | Publishes `WaterSurfaceState` and optical constants. It no longer exposes or loads retired underwater effect paths. |
| Ocean Lab `Underwater` tab | Interactive controls for the production compositor: feature toggles, waterline debug modes, waterline resolution, GPU timings, and profile runs. |
| `assets/water/caustics_noise.png` | paddy-exe's `caustics-generator.png`, MIT. Used by the compositor caustics path. |
| `assets/water/caustics_luma_gradient.tres` | Archived paddy-exe luma ramp reference. The compositor uses equivalent ramp values analytically because GradientTexture2D does not bind cleanly as an RD compute texture. |
| `assets/water/water_normal.png` | openmw `water_nm.png`, MIT. Must be imported as a normal map; otherwise sRGB decode biases `wobble_offset` to a constant non-zero state. |

### Deleted Legacy Paths

| File | Status |
|------|--------|
| `src/core/shaders/compute/underwater.glsl` | Deleted 2026-05-09. Retired compute compositor shader. |
| `src/core/shaders/effects/underwater_compositor_effect.gd` | Deleted 2026-05-09. Retired ShaderManager-loaded wrapper. |
| `src/core/water/shaders/underwater.gdshader` | Deleted 2026-05-09. Retired full-screen quad shader. |
| `src/core/water/underwater_effect.gd` | Deleted 2026-05-09. Retired quad script. |
| `src/core/water/underwater_volume.gd` | Deleted 2026-05-11. Retired diagnostic spatial-volume wrapper. |
| `src/core/water/shaders/underwater_volume.gdshader` | Deleted 2026-05-11. Retired diagnostic slab/depth/wobble shader. |
| `tests/visual/test_underwater.gd` + `.tscn` | Deleted 2026-05-11. Retired standalone diagnostic scene for the removed volume. |

---

## Gotchas

1. **`Basis[i]` returns columns, not rows.** Same as `basis.x/y/z`.
   Regression test at `tests/unit/test_basis_packing.gd`. Misreading this as
   rows corrupts any matrix packed into a push-constant or storage buffer from
   GDScript.
2. **Do not use procedural FBM for wobble.** FBM sampled at screen-space UV
   frequencies produces visible horizontal banding locked to the camera. The
   production compositor samples the FFT normal texture from
   `WaterSurfaceState` at world-space water-surface XZ, with a finite-difference
   height normal fallback.
3. **`sea_level` / water-body wiring must stay coherent.** The compositor uses
   stable water level for whole-pass activation and `WaterSurfaceState` for
   animated per-pixel water height. Production scenes must keep those values in
   sync with the active water body.
4. **No spatial-volume fallback.** Do not reintroduce a transparent diagnostic
   box to patch underwater rendering gaps. Final above-water waterline,
   submerged-object distortion, and underwater camera optics belong to
   pre-water capture plus `WaterlineCompositorEffect`.
5. **Shared absorption constants.** The compositor uses `WaterSurfaceState`
   optical values and dynamic surface lookup so crossing the waterline does not
   jump between unrelated water colors or surface classifications.

---

## Known Remaining Issues / Tuning

1. **Wobble edge guard needs human visual tuning.** Ocean Lab's
   `WL Debug: Wobble Guard` shows rejected shifted samples in red, accepted
   samples in green, and final guard strength in blue.
2. **High-tier effects are not visually accepted.** Particles and
   caustics are masked out unless `WL Q` is High. On 2026-05-11, Ocean Lab
   testing reported no visible underwater particles or caustics even with the
   compositor loaded, so treat those as broken/unverified until an interactive
   check proves otherwise.
3. **Quarter-res receiver refraction exposes edge artifacts.** `WL Res 25%`
   showed duplicated/blocky underwater outlines around receiver objects. The
   shader now disables quarter-res receiver edge dilation, but the fix still
   needs interactive validation.
4. **Underwater POV is compositor-owned, but not final art.** The compositor
   now brightens the underwater ceiling with Snell-window transmission and
   applies underwater absorption, edge-aware FFT-normal wobble, and high-tier
   optional effects. The visual tuning and performance thresholds still need
   production passes.

---

## Effects Status - Port vs Reference

Reference: `inspos/RafaelsShaderPack/Shaders/DIVE.omwfx` (OpenMW omwfx format).

| Effect | DIVE source | Current status |
|--------|------------|----------------|
| Voronoi caustics | `ComputeCaustics()` + `GetCausticEdge()` | Compositor-owned. Current caustics use paddy-exe's sampled noise texture with panned light-projected UVs in `waterline_probe.glsl`, not DIVE's procedural voronoi. |
| Beer-Lambert absorption | Lines 424-435 | Ported into the compositor path with per-channel optical constants from `WaterSurfaceState`. |
| Screen wobble | Lines 397-400 | Ported via the Godotwind water contract. The compositor samples active FFT normals at world-space water-surface XZ. |
| Shell-based light rays | Lines 477-500 | Compositor-owned. `waterline_probe.glsl` samples the underwater segment of the view ray, projects each sample back to the dynamic water surface along the sun vector, and evaluates sparse waterline-anchored shafts in Godotwind meters/Y-up. |
| Backscattering | Lines 509-520 | Partially ported. Path fog and water-color convergence live in the compositor; normal-facing surface backscatter remains deferred. |
| Water boundary highlight | Custom (not DIVE) | Not ported. Deferred. |
| Anti-banding dithering | Lines 524-527 | Not ported. Deferred. |

---

## Visual Verification

Use Ocean Lab for current underwater checks:

```powershell
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" res://tests/visual/test_ocean_lab.tscn
```

Relevant controls live under the `Underwater` tab: feature toggles, waterline
debug modes, waterline resolution, `WL Q`, and the GPU timing/profile panel.
Use `WL Q: Medium` or higher when checking rays. Use `WL Q: High` when checking
particles or caustics; medium intentionally masks those heavier effects for cost.

Do not use automated screenshot or auto-capture harnesses for final visual
verification. Launch interactively and inspect while piloting the camera.
