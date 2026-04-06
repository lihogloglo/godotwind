# Ocean Improvements Plan

**Agent:** oceanfix
**Started:** 2026-04-03
**Goal:** Upgrade ocean system — opaque rendering, FFT buoyancy sync, production buoyancy physics

---

## Phase 1: Opaque Ocean Shader (GodotOceanWaves approach)
**Status:** DONE (superseded by Phase 5 — see below)
**Files:** `src/core/water/shaders/ocean_fft.gdshader`

Fully opaque ocean — no ALPHA. Original implementation had no SCREEN_TEXTURE, no refraction.
Fixes "hollow wave crests" caused by transparent rendering pipeline. Phase 5 added back real
refraction + absorption at the cost of native SSR (see Phase 0 verdict in Phase 5).

**Changes:**
- [x] Removed ALPHA entirely — ocean stays in opaque render queue
- [x] `depth_draw_opaque` render mode (correct for opaque)
- [x] GodotOceanWaves-style Fresnel: roughness-dependent power `5.0 * exp(-2.69 * roughness)`
- [x] Roughness increases at grazing angles (hides horizon aliasing)
- [x] SPECULAR modulated by fresnel
- [x] Shore transition via color blending (lighten toward `color_shallow` near shore)
- [x] `v_flat_pos` (undisplaced) for depth comparison — fixes false discard at wave crests
- [x] Foam distance fade: `1.0 - smoothstep(500, 2000, dist)`
- [x] Distance-based normal flattening: `normal_y_scale = max(1.0, dist * 0.002)`
- [x] Shore mask retained in vertex for wave displacement dampening only

---

## Phase 2: GPU Readback Buoyancy
**Status:** DONE
**Files:** `src/core/water/wave_generator.gd`, `src/core/water/ocean_manager.gd`

GPU readback for exact visual-physics sync. Replaces broken hash-based CPU evaluator.

**Changes:**
- [x] `wave_generator.gd`: Added `CAN_COPY_FROM_BIT` to displacement texture + `read_displacement()` method
- [x] `ocean_manager.gd`: Reads cascade 0 displacement once per frame via `texture_get_data()`
- [x] Bilinear sampling from RGBA16F CPU data (`_sample_displacement_readback()`)
- [x] Normal via finite differences from readback
- [x] Fallback chain: GPU readback → OceanPhysicsEvaluator → GerstnerMath
- [x] Cost: 512KB readback/frame, constant regardless of query count

---

## Phase 3: Production Buoyancy Physics
**Status:** DONE
**Files:** `src/core/water/buoyancy_body.gd` (NEW), `src/core/water/buoyancy_probe.gd` (NEW)

Probe-based buoyancy using Jolt physics (standard Godot API).

**BuoyancyBody3D** (extends RigidBody3D):
- [x] Multi-point probe sampling (forces at probe positions → natural torque)
- [x] Non-linear depth response: `pow(depth, buoyancy_power)` (default 1.5)
- [x] Hydrodynamic drag: linear + angular velocity damping proportional to submersion
- [x] Distributed gravity mode for boats (mass distribution creates listing)
- [x] Configurable: buoyancy_force, buoyancy_power, fluid_density, drag coefficients

**BuoyancyProbe3D** (extends Marker3D):
- [x] Lightweight wave sampling point
- [x] Per-probe buoyancy_multiplier
- [x] Tracks depth and submersion state

---

## Phase 5: Depth-driven Refraction + Beer-Lambert Absorption (2026-04-06)
**Status:** PARTIAL — shipped with known artifacts, user accepted "not perfect, move on"
**Agent:** water
**Files:** `src/core/water/shaders/ocean_fft.gdshader`, `tests/visual/test_reflections.gd`

Added real depth-driven absorption and refraction UV offset so submerged geometry
is visible through the water from above-water camera — the thing Phase 1 explicitly
deferred. Scope was Step 0 (test scene bathymetry), Step 1 (real Beer-Lambert from
view-space thickness), Step 2 (refraction UV offset via `refract()`).

### Phase 0 verdict — native SSR cost of refraction

Discovered (via 2×2 DEPTH/SCREEN matrix test in `test_reflections.tscn`, 2026-04-06):
**declaring `hint_depth_texture` + `hint_screen_texture` as uniforms in `ocean_fft.gdshader`
disables Godot 4.6 native SSR on that material, even without any actual sampling.**
ReflectionProbe + sky-cube contributions via `SPECULAR` still reach the surface, verified
by toggling the probe and observing ocean color change. Pipeline-ordering issue; cannot
be configured around.

**Architectural consequence:** native SSR and real refraction are mutually exclusive
on a single material in Forward+. Current state pays the cost for refraction. Phase 6
(not done) will port a custom in-shader SSR raymarch from `inspos/GodotSSRWater-main/
shaders/water.gdshader` to restore object reflections.

### Step 0 — Bathymetry test bed

`tests/visual/test_reflections.gd:_setup_test_geometry()` now has:
- Deep base seafloor at `y=-25` (25m water column), checker-textured
- Mesa box with top at `y=-8` (8m column), pillars sit on it
- Shallow shelf at `y=-3` (3m column)
- Fully submerged rock at `y=-1` (invisibility canary — only visible via refraction)
- Half-submerged monolith spanning `y=-5` to `y=+5` (waterline cut test)
- Procedural `_make_checker_texture()` so refraction distortion is visually obvious

### Step 1 — Real Beer-Lambert absorption

Replaced the shore-mask proxy depth block (`v_shore_factor * 10.0` as fake thickness)
with actual view-space thickness from `DEPTH_TEXTURE`:
- Canonical Godot reversed-Z depth → view-space Z: `bg_view_z = -PROJECTION_MATRIX[3][2] / max(bg_ndc_z, 1e-5)`
  (NOT full `INV_PROJECTION_MATRIX * clip` — that pattern blows up near the near plane
  with a `max(abs(w), 1e-6) * sign(w)` clamp, producing nonsense values that push
  `raw_thickness > max_visible_depth` and cause seafloor clipping close to camera).
- Per-channel Beer-Lambert: `transmittance = exp(-thickness * absorption_rate * absorption_density)`
- Sky-depth guard: when `raw_thickness >= max_visible_depth`, skip SCREEN_TEXTURE sample
  entirely and use `color_deep` (otherwise sky color bleeds through refraction term)
- Deleted `absorption_coeff`, `min_absorption`, `color_shore` uniforms (superseded)

### Step 2 — Refraction UV offset (PARTIAL)

View-space ray stepping with six rejection guards (in cheapest-first order):
1. Total internal reflection (refract() returns zero)
2. Off-screen candidate UV
3. Sky reject (candidate depth near far plane)
4. Above-surface view-Z check
5. Silhouette depth-contrast rejection (`|cand_view_z - bg_view_z| < 1.5m`)
6. **World-Y < sea_level** reconstruction via full `INV_PROJECTION_MATRIX` + `INV_VIEW_MATRIX`

Guard (6) is the key fix from shader-specialist review (2026-04-06): view-space
"behind the water surface" is NOT the same as world-space "below sea_level". Tall
objects poking above the waterline (pillar tops, monolith top) were being view-space-
behind but world-space-above, letting refraction drag their above-water pixels into
underwater regions. This was the root cause of the "wobble overlaid on straight mesh"
double-vision artifact.

Uniforms:
- `refraction_strength: 0.6`
- `max_refr_thickness: 1.5m`
- `refraction_silhouette_threshold: 1.5m`
- `max_visible_depth: 20m`
- `sea_level: 0.0` (default — OceanManager wiring deferred, see Known Limitations)

### Known Limitations (shipped)

User accepted "not perfect, move on" on 2026-04-06. Residual artifacts:

1. **Waterline discontinuity on half-submerged objects.** Above-water portions of
   submerged objects (pillar tops, monolith top half) are drawn directly by the opaque
   pass without refraction. Below-water portions are shown via the refracted
   SCREEN_TEXTURE sample. At the waterline, the two don't align perfectly. This is
   physically correct ("straw in a glass" effect) but can read as a visible seam.
   Mitigation: possibly fade refraction toward zero near the waterline, or apply
   matching refraction to the meniscus. Not investigated.

2. ~~**OceanManager does NOT push `sea_level` to the shader.**~~ **FIXED 2026-04-06.**
   `_update_shader_parameters()` in `ocean_manager.gd` now calls
   `mat.set_shader_parameter(&"sea_level", sea_level)` on init. Guard (6) now
   works for any scene regardless of its sea level.

3. **Underwater POV of ocean surface is flat dark `color_deep`.** When camera is below
   the water looking up, the ocean surface fragment's Beer-Lambert sees sky at
   `DEPTH_TEXTURE`, sky-guard fires, falls back to `color_deep`. Should be a Snell's-
   window bright-spot-where-sun-refracts-through. Backlog item; coordinated with
   `underwater` track — their volume shader's slab test leaves these pixels alone
   so the fix drops in independently.

4. **Object reflections via custom SSR trace** (Phase 6 landed 2026-04-06). Not a
   limitation anymore — pillars, sphere, monolith all reflect on the water surface.

5. **Refraction tuning is a balance act.** Defaults (0.6 strength, 1.5m max thickness)
   were picked by shader-specialist after user reported rev 1 (strength 1.0) was
   "disastrous" (ghost + halo + checker clipping) and rev 2 (strength 0.25) was
   "invisible". Current is visible but subtle. Larger values reintroduce silhouette
   artifacts even with the 6-guard chain.

### Test scene

`tests/visual/test_reflections.tscn` — launch interactively:
```
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" res://tests/visual/test_reflections.tscn
```
WASD + mouse to fly. `1` toggles SSR env (doesn't affect ocean), `2` toggles
ReflectionProbe (DOES affect ocean via SPECULAR), `3` toggles lights, `4` cycles
time-of-day presets.

### Not automated
Per CLAUDE.md anti-pattern: no `--auto-capture` or `--headless` verification for
visual tests. User drives the camera, agent reads the report.

---

## Phase 4: Archive Gerstner
**Status:** NOT STARTED

- [ ] Move `ocean_standard.gdshader` to `src/core/water/archive/`
- [ ] Move `gerstner_math.gd` to `src/core/water/archive/`
- [ ] `ocean_physics_evaluator.gd` kept as fallback but GPU readback is primary

---

## Architecture Decisions
- **Fully opaque ocean**: No ALPHA anywhere. Shore transition via color blend + discard. Follows GodotOceanWaves.
- **Reflections via ReflectionProbe + sky cube ONLY** (Phase 5 consequence): native Godot 4.6 SSR is disabled on this material because declaring `hint_depth_texture`+`hint_screen_texture` for refraction breaks SSR pipeline ordering (Phase 0 verdict, 2026-04-06). Custom in-shader SSR raymarch planned for Phase 6.
- **Refraction via view-space ray-step-and-project-back** (Phase 5): `refract(-VIEW, NORMAL, 1/1.333)` with six rejection guards including the critical world-Y-below-sea_level check. Do NOT switch to the simpler "normal XY as SCREEN_UV offset" technique used by `visual_water.gdshader` — shader-specialist confirmed our technique is correct for steep FFT wave slopes. The simpler one tears at crests.
- **Canonical Godot reversed-Z formula** for depth→view-space-Z reconstruction: `-PROJECTION_MATRIX[3][2] / max(bg_ndc_z, 1e-5)`. NOT full `INV_PROJECTION_MATRIX * clip` — that pattern blows up near the near plane even with an `abs(w)*sign(w)` clamp.
- **GPU readback for buoyancy**: `texture_get_data()` on cascade 0. Exact match with visual. ManickYoj rate-limits to 10Hz; we do 60Hz since cost is acceptable on RTX 4060.
- **Jolt via standard API**: `RigidBody3D.apply_force(force, offset)` works with Jolt. Jolt's `ApplyBuoyancyImpulse` is NOT exposed to GDScript in 4.6.
- **Shore mask retained**: Vertex-stage wave dampening + CPU `is_in_ocean()` queries.
- **v_flat_pos for depth**: Undisplaced sea-level position avoids false shore detection at wave crests.
- **OceanPhysicsEvaluator kept as fallback**: Hash mismatch means it doesn't perfectly match GPU, but still useful if readback fails or is disabled.

## Future Improvements

### Phase 6 — Custom in-shader SSR trace (DONE 2026-04-06)
Ported `get_ssr_color()` verbatim from `inspos/GodotSSRWater-main/shaders/water.gdshader`
to restore object reflections (pillars, submerged rocks, metallic sphere, monolith top)
on the water surface. Single-reference faithful port, no mixing.

**Helpers added** (all prefixed `ssr_`, all in `ocean_fft.gdshader`):
- `ssr_in_screen(uv)` — boundary check
- `ssr_view_to_uv(view_pos, proj)` — view→screen projection
- `ssr_uv_to_view(uv, depth, inv_proj)` — screen→view reconstruction
- `ssr_edge_alpha(uv)` — screen-border fadeout
- `ssr_trace(surf_view, normal, view_vec, proj, inv_proj, steps)` — the raymarch loop

**Uniforms** in `group_uniforms ssr`:
- `ssr_max_steps = 24` (4-64 range)
- `ssr_resolution = 1.5` (view-space meters per step)
- `ssr_max_travel = 30.0` (view-space meters total)
- `ssr_max_diff = 4.0` (per-step depth tolerance)
- `ssr_mix_strength = 0.7` (master reflection knob)
- `ssr_screen_border_fadeout = 0.3`

**Distance LOD**: full step count near, quartered past 500m via smoothstep(50, 500, dist).
**Fresnel weighting**: grazing angles show more reflection, steep angles dominated by
refraction. `mix(water_col, ssr_result.rgb, ssr_result.a * ssr_mix_strength * fresnel)`.
**SPECULAR = 0.5 retained**: ReflectionProbe + sky cube contributions still reach the
surface via the native path. Custom SSR is additive on top.

User-verified 2026-04-06 in `test_reflections.tscn`. Pillar reflections, sphere
reflection, monolith reflection all visible.

### Phase 5 residual fixups (deferred, user accepted "not perfect, move on")
- ~~**Wire OceanManager → shader `sea_level` uniform**~~ **DONE 2026-04-06** as the
  session wrap-up. `_update_shader_parameters()` pushes `sea_level` to the material.
- **Waterline discontinuity** on half-submerged objects (straw-in-glass effect at the
  waterline). Physically correct but reads as a seam. Potential mitigations: fade
  refraction to zero approaching the waterline, apply matching refraction to the
  above-water meniscus.
- **Underwater POV of ocean surface** — currently renders as flat dark `color_deep`
  because the Beer-Lambert path doesn't know about "camera below water looking up".
  Add a branch on `surf_view.y > 0` (or equivalent) to switch to a Snell's-window
  pass. Coordinated with the `underwater` track — their volume shader's slab test
  leaves these pixels alone so the fix drops in independently.
- **Shared absorption via OceanManager typed getters** — `get_absorption_tint()`,
  `get_absorption_sigma()`, `get_absorption_depth_falloff()` so the surface shader
  and the underwater compositor effect use the same values and the waterline
  transition is continuous. Pre-agreed with @underwater (chat id 3589).

### Buoyancy / physics
- `texture_get_data_async()` (Godot 4.4+) for non-blocking readback
- 6-axis hydrodynamic drag model (ManickYoj's axial/lateral/vertical/yaw/pitch/roll)
- Volumetric cell mode for large ships (partial submersion based on cell volume)
- Horizontal displacement correction (iterative, from tessarakkt)
- Cascade filtering: large boats ignore small detail cascades
