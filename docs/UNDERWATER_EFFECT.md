# Underwater Effect — Development Log

## Status: PARTIALLY WORKING (2026-04-06)

**What works:** Wobble (screen UV distortion), absorption tint, blue-tint forced overlay.
**What doesn't work:** Caustics, light rays, backscattering, boundary highlight — all depth-dependent effects are invisible despite the compute pipeline functioning correctly.

---

## Architecture

### Current implementation (CompositorEffect)

| File | Purpose |
|------|---------|
| `src/core/shaders/compute/underwater.glsl` | GLSL compute shader (single pass) |
| `src/core/shaders/effects/underwater_compositor_effect.gd` | Extends PostProcessEffect, dispatches compute |
| `src/core/water/ocean_manager.gd` | Loads/enables/disables effect based on camera submersion |
| `tests/visual/test_underwater.tscn` + `.gd` | Visual test scene with underwater geometry |

### Dead code (quad-based approach, superseded)

| File | Status |
|------|--------|
| `src/core/water/shaders/underwater.gdshader` | Dead — spatial shader approach abandoned |
| `src/core/water/underwater_effect.gd` | Dead — quad-based controller abandoned |

These files are no longer referenced by OceanManager but haven't been deleted.

---

## What was tried (chronological)

### Approach 1: Full-screen quad with spatial shader (FAILED)

**Idea:** MeshInstance3D (QuadMesh) child of camera with `render_mode unshaded, depth_test_disabled`. Reads `hint_screen_texture` and `hint_depth_texture`.

**What worked:** Wobble (UV distortion from SCREEN_TEXTURE).

**What failed:** All depth-dependent effects (caustics, rays, scatter).

**Root cause debate:**
- One theory: `INV_PROJECTION_MATRIX` in a spatial shader on a camera-child quad gives the quad's projection context, not the camera's. This was disputed — Godot's built-in matrices should always be the camera's.
- Alternative theory: The effects were computed correctly but too faint due to compound attenuation (absorption * depth_fade * surface_factor * dist_fade * sun_fade — each ~0.7, product ~0.17).
- The quad approach was abandoned in favor of CompositorEffect regardless.

**Key issues encountered:**
1. `return` in `fragment()` is illegal in Godot spatial shaders — must use if/else structure
2. `INV_PROJECTION_MATRIX` is NOT accessible in custom helper functions (Godot scopes them to entry points) — must pass as parameters
3. Wobble at depth discontinuities (water surface horizon) creates blocky artifacts — needs depth-discontinuity fade

### Approach 2: CompositorEffect + compute shader (CURRENT)

**Idea:** Follow the proven GodraysEffect pattern. Single-pass compute shader, depth + color access, camera matrices from RenderSceneDataRD.

**What works:**
- Shader compiles to SPIRV: ✓
- Pipeline creates successfully: ✓
- `_render_callback()` fires every frame: ✓ (confirmed via diagnostic logging)
- `imageStore()` writes to color buffer: ✓ (confirmed via forced blue tint test)
- Push constants received: ✓ (128-byte limit respected)
- Auto-enable/disable on submersion: ✓
- Effect toggles: ✓ (wobble visible when toggling)
- ShaderManager integration: ✓ (7th effect in the pipeline)

**What doesn't work:**
- Depth reconstruction → world position is wrong
- All effects that depend on `get_world_position()` produce invisible results
- Debug modes that visualize depth/world_pos don't show correct values

**Remaining bug: depth reconstruction**

The `get_world_position()` function uses the same `inv_projection * clip → view, inv_view * view → world` pattern as `volumetric_fog.glsl`. But the matrices are passed differently:
- Volumetric fog: push constants (240 bytes — **this also exceeds the 128-byte limit**, meaning volumetric fog's depth reconstruction is likely also broken, just less noticeable because fog doesn't require pixel-accurate world positions)
- Underwater: storage buffer (binding 2)

The storage buffer approach is untested in this codebase — it's possible the `mat4` data isn't being read correctly by the GLSL (alignment issues, column-major vs row-major, std430 layout padding).

**Specific suspects:**
1. `Transform3D → mat4` conversion in GDScript may produce wrong column order. Godot's `Transform3D.basis[col]` gives basis column vectors, but the mat4 layout in std430 may expect row-major data.
2. The `Projection.inverse()` may not account for Godot 4.6's reversed-Z depth buffer.
3. The `inv_view` is constructed from `cam_transform` (which IS the inverse view matrix), but the basis-to-mat4 packing may have wrong column/row ordering.

---

## Key constraints discovered

1. **Godot enforces 128-byte push constant limit** regardless of GPU capability. The error is: `"Push constants can't be bigger than 128 bytes to maintain compatibility."` This fires at `compute_list_set_push_constant()`. The push constants are silently not set, and the shader uses uninitialized/garbage values.

2. **`volumetric_fog.glsl` passes 240 bytes of push constants** — this means it also exceeds the limit. It either works because the error is non-fatal (push constants partially set?) or volumetric fog's world position reconstruction is also broken but masked by the fog algorithm being less sensitive to exact positions.

3. **ShaderManager auto-discovers effects** in `src/core/shaders/effects/` on startup. OceanManager also loads the underwater effect explicitly → double-load warning. Fix: check `ShaderManager.get_effect("underwater")` before calling `load_effect()`.

4. **`.glsl` files need Godot import** to compile to SPIRV. Running `--import` creates the `.glsl.import` file and compiled `.res`. Without this, `load()` returns null.

5. **Test scenes must call `ShaderManager.attach_to(_world_env)`** or CompositorEffects won't render. The compositor object exists in ShaderManager but isn't connected to the viewport until attached to a WorldEnvironment or Camera3D.

---

## Effects ported from DIVE.omwfx

All effect math is implemented and ready in `underwater.glsl`. Once depth reconstruction works, these should become visible:

| Effect | DIVE source | Status |
|--------|------------|--------|
| Voronoi caustics | `ComputeCaustics()` + `GetCausticEdge()` | Math ported, invisible (depth) |
| Beer-Lambert absorption | Lines 424-435 | Works (doesn't need depth) |
| Screen wobble | Lines 397-400 | Works |
| Shell-based light rays | Lines 477-500 | Math ported, invisible (depth) |
| Backscattering | Lines 509-520 | Math ported, invisible (depth) |
| Water boundary | Custom (not from DIVE) | Invisible (depth) |
| Anti-banding dithering | Lines 524-527 | Ported |

---

## Next steps for future agents

1. **Fix depth reconstruction.** The most likely issue is the `Transform3D → mat4` packing in the storage buffer. Write a minimal test: in the compute shader, reconstruct world position for center pixel, write `world_pos.y` as red channel intensity. If it matches the expected geometry height (-15m for floor), depth works. If it's 0 or NaN, the matrix data is wrong.

2. **Verify matrix data on CPU.** Before dispatching, print the first few floats of `matrix_data` in GDScript and compare with known values. The inverse projection diagonal should have values like 1.0-2.0, not 0 or inf.

3. **Check std430 alignment.** In GLSL `std430`, a `mat4` is stored as 4 × `vec4` columns (no extra padding). Verify that the GDScript packs data in the same column-major order that GLSL expects.

4. **Alternative: pass proj params + camera basis in push constants.** Instead of full matrices, pass the 4 diagonal projection elements + 3 basis vectors + camera position (28 floats = 112 bytes). Reconstruct view-space position from proj params, then world position from basis vectors. This fits in push constants and avoids the storage buffer entirely.

5. **Wobble quality.** The current wobble uses FBM noise at 18x frequency with quintic interpolation. Users describe it as "awful" — likely needs artistic tuning (lower strength, different frequency, or a proper water normal texture instead of procedural noise).

6. **Delete dead files** once the compositor approach is stable: `src/core/water/underwater_effect.gd`, `src/core/water/shaders/underwater.gdshader`.

---

## Test scene controls

```
RMB         = Hold to look, ZQSD to move, Space/Ctrl up/down
Shift       = Fast move
U           = Toggle underwater effect
1-5         = Toggle individual effects (caustics/rays/wobble/scatter/boundary)
6           = Cycle debug modes (water_depth, world_pos.y, underwater_mask, caustic_raw, world_normal, linear_depth)
R           = Reset camera to underwater (y=-8)
G           = Reset camera to surface (y=-0.2, boundary view)
+/-         = Adjust absorption rate
O           = Toggle ocean visibility
```

Launch: `"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" res://tests/visual/test_underwater.tscn`
