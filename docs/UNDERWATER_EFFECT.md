# Underwater Effect — Development Log

## Status: PARTIALLY WORKING (2026-04-06)

Volume-based spatial shader using a camera-following BoxMesh, ported from
[paddy-exe/Godot-RealTimeCaustics](https://github.com/paddy-exe/Godot-RealTimeCaustics) (MIT).
Replaced an earlier compute-shader CompositorEffect approach that was
misdiagnosed as having a depth-reconstruction bug (it didn't — the effects
were tuned too faint).

**What works:** Caustics projected in world space (voronoi noise texture panned
along the sun direction plane), Beer-Lambert absorption driven by real view-
space distance with the proper `transmittance` re-use for caustics on their
return path, wobble via a sampled normal texture (openmw `water_nm.png`)
sampled at world XZ with time animation, above-water/sky guards on the wobble
sample to prevent above-water color bleed into the submerged region.

**What is partial / left hanging:** wobble visual quality. The guards prevent
most of the "straight mesh + wobble overlay ghost" artifact the user observed
in rev 2, but the final state (rev 3) is still not fully clean at every
viewing angle — user explicitly said "still not perfect nor fixed, but I want
to move on". Deferred rather than fixed.

**What was never implemented:** light rays, backscatter, boundary highlight,
OceanManager-driven absorption params, wave-driven caustic scaling.

---

## Architecture

### Current implementation (volume-based spatial shader)

| File | Purpose |
|------|---------|
| `src/core/water/shaders/underwater_volume.gdshader` | Spatial shader on a BoxMesh volume. `render_mode blend_mix, cull_front, depth_test_disabled, unshaded`. Reconstructs world pos from DEPTH_TEXTURE, slabs to `[sea_level - volume_depth, sea_level]` in Y, applies wobble + absorption + caustics. |
| `src/core/water/underwater_volume.gd` | Node3D wrapper. 500×40×500 BoxMesh, camera-position-follow (NOT rotation), hides above water, updates `sea_level` each frame. Ported from paddy-exe with documented blend_mix deviation. |
| `assets/water/caustics_noise.png` | paddy-exe's `caustics-generator.png`, MIT-licensed. |
| `assets/water/caustics_luma_gradient.tres` | paddy-exe's luma ramp. |
| `assets/water/water_normal.png` | openmw's `water_nm.png`, MIT-licensed. **Must be imported with `compress/normal_map=1` (Normal Map mode)** or the sRGB decode biases `wobble_offset` to a constant non-zero state. |
| `tests/visual/test_underwater.gd` + `.tscn` | Interactive test scene. Hits the volume via the `_setup_underwater_volume()` method; the old `UnderwaterCompositorEffect` path is force-disabled at runtime. |

### Dead code (compute shader, pre-pivot)

| File | Status |
|------|--------|
| `src/core/shaders/compute/underwater.glsl` | **Dead.** Compute-shader CompositorEffect with push-constant matrices, wobble via procedural FBM, caustics via voronoi math. Runtime disabled but file still present. Delete in a future cleanup commit. |
| `src/core/shaders/effects/underwater_compositor_effect.gd` | **Dead.** Companion GDScript. Delete in the same commit. |
| `src/core/water/shaders/underwater.gdshader` | **Dead.** Earlier quad-based approach. Delete in the same commit. |
| `src/core/water/underwater_effect.gd` | **Dead.** Companion script. Delete in the same commit. |

### Historical false leads (for future agents)

1. **`Basis[i]` was assumed to return rows** — it returns columns (same as
   `basis.x/y/z`). Regression test now lives at
   `tests/unit/test_basis_packing.gd`.
2. **"Depth reconstruction was broken"** — it wasn't. The compute shader's
   matrix packing was correct, storage buffer binding worked, effects were
   running. The symptom was compound attenuation crushing effects into
   invisibility. Diagnostic debug modes 7–10 in the old `underwater.glsl`
   were added during this investigation and correctly showed world-pos
   reconstruction working. The debug modes were useful but the diagnostic
   approach (auto-capture screenshot harness) missed the motion-in-context
   problems that user interactive testing would have caught immediately.
3. **"Wobble via FBM is fine"** — it isn't. Procedural FBM at screen-space UV
   frequencies produces visible horizontal banding locked to the camera. A
   sampled normal texture at world-space XZ is the only approach that
   actually looks right. Don't regress to FBM.

---

## Known remaining issues (user-accepted "move on")

1. **Wobble waterline ghosting.** Even with the above-water guard, at some
   camera angles the wobble's screen-UV offset pulls content across the
   waterline visibly. The hard-switch fall-back (`wobbled_uv = SCREEN_UV`
   when the neighbor is above water) kills most of the artifact but not
   all. Specialist's contingency (widen the guard by 0.1m below sea level)
   was not applied — user did not want further iteration on Step 2.
2. **Wobble looks "subtle" on flat seafloor.** Correct behavior — there are
   no features to refract on a uniformly-colored region. A normal-mapped
   seafloor texture would make the wobble more obvious. Not my scope.
3. **`sea_level` is currently pulled from `OceanManager.get_sea_level()` in
   the test scene's `_process()`.** Production scenes should do the same
   wiring. If `sea_level` is wrong (e.g., default 0 when the scene uses a
   different water plane), the slab test will reject the wrong pixels and
   effects will appear in the wrong place.
4. **Ocean surface seen from below (the "ceiling" when the camera is
   submerged) is unaffected by my shader.** My slab test rejects pixels
   where `scene_world_pos.y ≥ sea_level`, which includes the ocean surface
   mesh's fragments. That's by design — @water owns the above-to-below
   transition and plans a separate "underwater POV" fix for their
   `ocean_fft.gdshader`. When that lands, my shader needs zero changes.
5. **Wave-driven caustic scaling.** The caustic noise texture is panned at a
   fixed `caustics_scale` and `caustics_speed`. Physically, caustic cell
   size is driven by the dominant wave wavelength (big swell = big cells).
   Proposed Phase C interface: `OceanManager.get_dominant_wavelength()` +
   `get_surface_variance()` to drive `caustics_scale` and `caustics_speed`
   as per-frame uniforms. Not implemented.
6. **Shared absorption constants.** My shader has its own `water_tint` and
   `absorption_sigma` uniforms. @water's ocean surface shader has its own.
   These should eventually be pulled from a single source
   (`OceanManager.get_absorption_tint/sigma/depth_falloff()`) so the
   visual transition across the waterline stays continuous as weather /
   daytime / fog changes. Proposed but not implemented.
7. **Boundary highlight.** The Rafael DIVE.omwfx shader has a boundary
   highlight effect (bright shimmer right at the waterline when the camera
   is close to the surface). Never implemented in the volume shader port.

---

## Effects status — Port vs Reference

Reference: `inspos/RafaelsShaderPack/Shaders/DIVE.omwfx` (OpenMW omwfx format).

| Effect | DIVE source | Current status |
|--------|------------|----------------|
| Voronoi caustics | `ComputeCaustics()` + `GetCausticEdge()` | **Not ported.** Current caustics use paddy-exe's sampled noise texture with panned UVs, not DIVE's procedural voronoi. Different technique, similar visual result. |
| Beer-Lambert absorption | Lines 424-435 | **Ported.** Uses `exp(-sigma * length(scene_pos - cam_pos))` applied via `mix(water_tint, scene_color, transmittance)`. `sigma` is per-channel; DIVE had per-channel `SIGMA = 0.001196 * (1 - WATER_COLOR_0)` that gives nicer wavelength-dependent absorption but we hardcoded a uniform scalar. |
| Screen wobble | Lines 397-400 | **Ported with guards.** DIVE uses a 3D water normal texture sampled with `(screen_uv, 0.2*time)`. We use a 2D water normal at `world_pos.xz / tiling + time * speed`. World-space sampling avoids the camera-locked banding the FBM implementation had. |
| Shell-based light rays | Lines 477-500 | **NOT ported.** Deferred. |
| Backscattering | Lines 509-520 | **NOT ported.** Deferred. |
| Water boundary highlight | Custom (not DIVE) | **NOT ported.** Deferred. |
| Anti-banding dithering | Lines 524-527 | **NOT ported.** Deferred. |

---

## Next phase (queued, not yet reviewed)

Revised vs original 5-step plan:

- **Step 3** (light rays) — **blocked on user decision.** Original plan said
  "if user wants rays, do a second research pass, don't fall back to DIVE
  math". User has not asked for rays yet. Leave it alone.
- **Step 4** (backscatter) — same. Not asked for.
- **Step 5** (cleanup) — **ready to execute.** Delete the dead compute
  shader + its companion GD files + the old .gdshader quad approach +
  their `.uid` entries. Rewrite this doc. Remove the force-disable hack
  in `test_underwater.gd`.

**Recommendation:** proceed directly to Step 5 cleanup. The volume-based
shader is the canonical path going forward, leaving the broken compute path
in-tree is a trap for future agents, and the cleanup is a pure deletion
with no shader logic risk.

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

Launch: `"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" res://tests/visual/test_underwater.tscn`

**Anti-pattern (per `.claude/CLAUDE.md`):** DO NOT re-introduce automated
screenshot/auto-capture harnesses for verification. User drives the camera,
agent watches the report.
