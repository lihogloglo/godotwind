# Ocean Water System — Session Handoff (2026-04-09 → 2026-04-10)

## Scope

This session worked the FFT ocean pipeline end-to-end: buoyancy sync,
weather coupling, clipmap seams, debug tooling, SSS tuning, and a
render-mode diagnosis. It also scoped a projected-grid port for a
future session after confirming that's what Wicked Engine and
Sea of Thieves use.

The key running artifact is **`tests/visual/test_buoyancy_debug.tscn`** —
a minimal scene that forces the FFT ocean online, spawns buoyant
spheres, and exposes a 9-mode shader debug pipeline + weather presets
+ sun angle toggle. Everything ocean-related should be iterated there,
not in the main Godotwind scene.

## Fixes shipped this session

### 1. Buoyancy CPU sampler — cascade 0 displacement_scale missing

**Symptom:** buoyant bodies floated ~1.67× above visible crests in
stormy weather; massive mismatch against the debug grid.

**Root cause:** `OceanManager._sample_displacement_readback` returned
the raw FFT texture values without applying the per-cascade
`displacement_scale`. The vertex shader multiplies by `scales.z`
per-cascade, so CPU was reading an unscaled amplitude.

**Fix:** added `_cascade0_displacement_scale()` helper in
`src/core/water/ocean_manager.gd`, applied in `get_wave_height` /
`get_wave_displacement` / `get_wave_normal`. Later superseded by the
multi-cascade path (item 2).

### 2. Buoyancy CPU sampler — cascade 1 not sampled

**Symptom:** after fix 1, a visible residual in very bad weather —
the "muuuch higher" CPU sample.

**Root cause:** the readback only ran `_wave_generator.read_displacement(0)`
once per frame, so cascade 1 (medium chop, 50m tile) was missing from
the CPU sum entirely. In stormy weather both cascades are equally
amplified and cascade 1 contributes meaningfully to vertical height.

**Fix:** `OceanManager._displacement_cpu_per_cascade: Array[PackedByteArray]`
— one buffer per cascade, read every frame. New `_sum_cascade_displacement`
method sums each cascade's contribution with its own `tile_length` and
`displacement_scale`, mirroring the shader's per-cascade loop exactly.
`_sample_displacement_readback_cascade` + `_read_displacement_texel_from_buf`
helpers support per-cascade sampling.

### 3. Shader cascade scale update — weather path missed it

**Symptom:** visible ocean stuck at calm/lake amplitude regardless of
weather. CPU buoyancy correctly scaled with weather, but the shader
mesh showed tiny waves even in blizzard. Ratio ~6-10× CPU over visible.

**Root cause:** `_apply_weather_fft` mutates
`cascade.displacement_scale` on the WaveCascadeParameters instances
(which the CPU path reads correctly) but did NOT call
`_update_cascade_scales()` to re-push the new values into the shader's
`map_scales[i].z` uniform array. `_update_cascade_scales` only ran
once, in `_init_fft_pipeline`, so the shader kept the init-time
values forever.

**Fix:** call `_update_cascade_scales()` at the end of both
`_apply_weather_fft` and `reset_weather` in `ocean_manager.gd`.

**Diagnosis method:** the `SAMPLER DUMP` diagnostic in
`test_buoyancy_debug.gd::_dump_cpu_sampler_state` printed per-cascade
raw.y, scaled.y, displacement_scale, wind, and expected-vs-actual
height. Comparing the numbers against the visible mesh revealed the
shader was stuck while CPU tracked runtime.

### 4. Far-over-near depth artifact — render_mode

**Symptom:** big waves showed geometry from FAR sections drawing IN
FRONT of NEAR sections. Debug sweep mode-by-mode eliminated shore
mask, SSR, refraction, fresnel — none of the false-color modes showed
the artifact. Remaining suspect = depth test path.

**Root cause theory:** `render_mode world_vertex_coords, cull_disabled,
shadows_disabled, depth_draw_opaque;`. With `cull_disabled`, Godot's
depth prepass writes depth from BOTH front and back faces of every
triangle. At clipmap ring boundaries this creates ambiguous depth
writes, and whichever draw fires last wins the compare — producing
the far-over-near ordering.

**Fix:** changed `depth_draw_opaque` → `depth_draw_always`. This
forces the main pass to write depth authoritatively bypassing the
prepass. Kept `cull_disabled` — a quick test confirmed that removing
it kills the ocean entirely (clipmap winding renders as the back face
from above, a load-bearing quirk that needs retopology to untangle).

**Reference comparison:** tessarakkt's CDLOD ocean and Wicked Engine's
projected-grid ocean both use `depth_draw_always` without
`cull_disabled`. Our current state is a compromise — `depth_draw_always`
is the canonical answer, `cull_disabled` remains because we can't
flip the winding without also rewriting the mesh generator.

### 5. Clipmap ring seams — interim overlap fix

**Symptom:** after the depth fix, T-junction gaps between clipmap
rings became visible as "massive holes" at ring boundaries.

**Root cause:** the concentric clipmap in `ocean_mesh.gd` has 11 rings
where each ring doubles `quad_size` (2m → 4m → 8m → ...). Inner ring's
outer edge has 2× the vertex density of the outer ring's inner edge.
The triangles on each side don't connect across the boundary —
classic T-junctions. Previously masked by the depth-test bug.

**Fix:** **interim overlap**. Each annular ring (ring 1+) has
`inner_radius = prev_outer_radius - quad_size`. Successive rings
overlap by one outer-ring quad; both rings sample the FFT displacement
at the same world XZ so the vertices land at the same Y (no
z-fighting, just 2× triangle work in a thin strip). Minimal change
in `_create_clipmap_mesh`.

**Canonical fix — NOT YET DONE:** switch to a **projected grid** for
the water mesh. Section 7 below details the plan.

### 6. Test scene shore-mask discard

**Symptom:** the buoyancy debug scene and the I.5 buoyancy test scene
showed NO visible ocean even though the FFT pipeline initialized
correctly.

**Root cause:** `OceanManager` loads a prebaked shore mask from
`%APPDATA%/Godotwind/cache/ocean/shore_mask.png` which is baked against
the Morrowind world bounds. At the test scenes' origin (0,0,0), the
mask reads "land" so the shader's `if (v_shore_factor < 0.01) discard`
killed every fragment.

**Fix:** both `test_buoyancy_debug.gd` and
`tests/visual/test_interaction_phase_I5.gd` now set
`OceanManager.use_prebaked_shore_mask = false` BEFORE calling
`force_initialize()`. Falls back to the shader's `hint_default_white`
sampler which returns 1.0 everywhere. In the buoyancy debug scene the
quality is also forced to HIGH (FFT) via
`ProjectSettings.set_setting("ocean/quality", 2)` before init, because
`_deferred_init` overwrites the manual `water_quality` assignment.

### 7. First-person force on player switch (reverted + replaced)

Initially forced `camera_mode = FIRST_PERSON` + locked
`allow_camera_mode_switch = false` in `_switch_to_player_controller`
to make the InteractionRaycaster reach targets. This was a bridge, not
a fix — the `@character-debug` agent reverted it and shipped the
canonical solution: `InteractionRaycaster.ray_origin_node` override so
the ray origin comes from `player_controller.camera_pivot` (eye
height) while direction still comes from the camera. Works in both
first and third-person.

See `src/core/interaction/interaction_raycaster.gd` and
`src/tools/world_explorer.gd::_setup_cameras` for the current wiring.

## Debug tooling shipped

### `tests/visual/test_buoyancy_debug.tscn`

Standalone buoyancy + ocean diagnostic scene. Minimal setup:
- sun + sky + small beach + FlyCamera
- `OceanManager.force_initialize()` with `water_quality = 2` (HIGH/FFT)
- prebaked shore mask disabled (shader default white)
- no Morrowind ESM load, no streaming

**Hotkeys:**
- `1`-`5` — weather preset (Calm → Breeze → Moderate → Storm → Blizzard)
- `B` — launch a 25 cm buoyant sphere forward from the camera
- `V` — toggle 40×40 magenta marker grid showing
  `OceanManager.get_wave_height()` at every point
- `D` — cycle shader `debug_mode` (10 modes, see below)
- `L` — toggle sun angle (high noon ↔ 8° sunset)
- `RMB + WASD` — fly camera
- `ESC` — quit

**UI labels:**
- top-left: hotkey legend
- top-right: current preset, debug mode, wave_scale, per-cascade
  (tile, disp_scale, wind)

**`_dump_cpu_sampler_state` diagnostic:** every time a weather preset
fires, after a 0.3s FFT settle, dumps a `[buoyancy-debug] SAMPLER DUMP`
to the log with shore_factor, per-cascade raw.y / scaled.y / buf size,
expected_final_y vs actual `get_wave_height()` delta. Pair with a
screenshot of the visible mesh at the same position to diagnose
CPU-vs-shader amplitude mismatches.

### Shader debug modes (`ocean_fft.gdshader`)

`uniform int debug_mode : hint_range(0, 9) = 0;` switched at the end
of `fragment()`. Set via `OceanManager.set_debug_mode(int)`. The
shore-mask discard is gated on `debug_mode == 0` so all debug modes
can see the normally-discarded geometry.

- **0** — Normal (production)
- **1** — Shore factor (red=0 → green=1)
- **2** — Shore discard zone (red = would discard in production)
- **3** — Water thickness / max_visible_depth (blue thin → red thick,
  magenta = sky/far)
- **4** — Transmittance (gray; bright = light passes unfiltered)
- **5** — Fresnel (gray)
- **6** — SSR hit alpha (green = hit + tinted by hit sample)
- **7** — Refraction UV offset magnitude (red = large)
- **8** — World normal.y (white = flat, dark = steep)
- **9** — SSS crest factor (cyan emission, light-independent) — shows
  the height × slope selector isolated from the light-direction terms

## Open issues → hand to next session

### A. SSS wave-tip translucency STILL doesn't look right

**User feedback (2026-04-10 00:27):** after tuning the crest selector
(height × slope gate), user reports "mostly yellowish" glow, no
visible green/cyan. The sun direction procedure in the handoff was
ambiguous — for SSS to fire the sun has to backlight the wave tips
(sun on FAR side of the wave from camera, camera looks toward sun).

**Current formula in `ocean_fft.gdshader::light()`:**
```glsl
const vec3 sss_tint = vec3(0.85, 1.25, 1.15);
vec3 view_up = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
float world_n_y = dot(NORMAL, view_up);
float crest_height = smoothstep(0.8, 2.0, wave_height);
float crest_slope = 1.0 - smoothstep(0.4, 0.85, world_n_y);
float crest_factor = crest_height * crest_slope;
float backlight = pow(max(dot(LIGHT, -VIEW), 0.0), 4.0);
float rim = pow(max(0.5 - 0.5 * dot(LIGHT, NORMAL), 0.0), 3.0);
float sss_height = sss_strength * crest_factor * backlight * rim;
```

**Hypothesis for why it looks yellowish:** tonemapping + lambertian
additive + default sun color mixing. The final DIFFUSE_LIGHT mix is:
```glsl
DIFFUSE_LIGHT += mix(
    (sss_height + sss_near) * sss_tint / (1.0 + light_mask) + lambertian,
    foam_color, foam_factor
) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
```
The final multiply by `LIGHT_COLOR` tints the entire output by the
sun's color. At sunset the sun color is warm `(1.0, 0.7, 0.45)` so
the cyan sss_tint gets tinted yellow-orange. At noon the sun is white
so the tint passes through cleaner.

**Next session suggestions:**
1. Move the SSS contribution to `EMISSION` in fragment() instead of
   `DIFFUSE_LIGHT` in light(). Emission bypasses the LIGHT_COLOR
   multiply so the cyan tint survives. Approximate the backlight
   factor in fragment using the sun direction from a global uniform
   (Godot can expose `DIRECTIONAL_LIGHT_DIRECTION` or similar).
2. Or, pre-multiply `sss_tint` by the inverse of `LIGHT_COLOR` (hack).
3. Or, study tessarakkt/godot4-oceanfft's SSS shader — they have it
   working; port their formula.
4. Port the Wicked Engine / Sea of Thieves approach: use
   `oceanSurfacePS.hlsl`'s extinction + refraction path, which tints
   the transmitted light through water depth instead of doing a
   crest-factor hack.
5. First verify with the user: face TOWARD the sun (not away), camera
   looking at a wave that has the sun behind it. That is the
   backlight condition.

### B. Projected grid port (Wicked / Sea of Thieves canonical)

**Confirmed:** Wicked Engine uses projected grid. Vertex shader source
quoted in the session chat. The approach:

```glsl
// Grid coord (vertex id) → clip space
Out.pos = float4(grid_coord / float2(dim - 1), 1, 1);
Out.pos.xy = uv_to_clipspace(Out.pos.xy);

// Clip space → world via ray-to-water-plane intersection
float4 unprojNEAR = mul(camera.inverse_view_projection, float4(Out.pos.xy, 1, 1));
float4 unprojFAR  = mul(camera.inverse_view_projection, float4(Out.pos.xy, 0, 1));
const float3 d = normalize(unprojNEAR.xyz - unprojFAR.xyz);
const float3 o = unprojNEAR.xyz;

float3 worldPos = intersectPlaneClampInfinite(o, d, float3(0, 1, 0), xOceanWaterHeight);
// ... apply FFT displacement ...
```

This replaces `_create_clipmap_mesh` + `_create_ring` + `update_position`
with a single screen-space uniform grid that's always 100% in view.
Zero seams by construction. Grid density is uniform in NDC regardless
of camera distance.

**Scope:** ~150 lines rewrite of `ocean_mesh.gd`. The existing FFT
pipeline, shore mask, cascade setup, and all debug tooling stay
unchanged — only the vertex positioning changes. The existing
`depth_draw_always` + `cull_disabled` render_mode works for a
projected grid too.

**Gotcha:** the projected grid needs a uniform grid MESH to use as
vertex source (dim × dim quads). It's a single ArrayMesh built once.
The vertex shader does the projection via `INV_VIEW_PROJECTION_MATRIX`.

**Migration path:**
1. New file `ocean_mesh_projected.gd` that builds a flat N×N grid and
   exposes the same public API as `ocean_mesh.gd`
2. New shader `ocean_fft_projected.gdshader` with the projected grid
   vertex function (most of the fragment code copies over as-is)
3. Toggle via `OceanManager.water_mesh_mode` or similar
4. Keep `ocean_mesh.gd` as the fallback for a while
5. Once validated, delete the clipmap code

### C. Shore waves (small waves breaking on beach)

**User wants:** "I would also like this ocean system to produce small
waves on the shores (like moving up the beach)"

**Wicked Engine does NOT solve this** — their ocean is deep-water
only, no shore interaction. Sea of Thieves presumably has a
dedicated system on top of the main ocean.

**Options for Godotwind:**
1. **Animated foam offset** — use the shore mask gradient direction
   to drive a wash-in texture that scrolls toward the beach. Cheap.
2. **Gerstner shore waves** — second wave system layered on top,
   direction = shore normal, frequency = short. Medium.
3. **Wet-sand darkening** — terrain shader reacts to wave reach.
   Needs a hook in the terrain shader, not just the ocean shader.

Filed as task 26. Needs a dedicated design pass.

### D. Interior "fly→P floats in void" bug

Pre-existing bug, not interaction-related. When the player switches
from fly camera to player controller INSIDE an interior pocket
(`_pocket_manager.is_inside() == true`), the player teleport
logic in `world_explorer._switch_to_player_controller` raycasts
Terrain3D for `ground_y`, but terrain is hidden inside interiors →
ground_y = 0 → player teleports to (cam_x, 0, cam_z) which is outside
the interior shell (interiors sit at Y=-500 via the pocket offset).

Not assigned — separate from this session's ocean work. Triage as
`@character-debug`-style.

### E. "Stair clipping" / terrain drop-into-swim

Pre-existing character controller bug. `@character-debug` is
triaging with `--debug-collisions` per their last message. Not part
of this session's scope.

## Files touched this session

### `src/core/water/ocean_manager.gd`
- Added `_cascade0_displacement_scale()` helper (superseded by next item)
- Added `_displacement_cpu_per_cascade: Array[PackedByteArray]` with
  per-cascade readback loop in `_process`
- Added `_sum_cascade_displacement` + `_sample_displacement_readback_cascade`
  + `_read_displacement_texel_from_buf` — multi-cascade CPU sampling
- Rewrote `get_wave_height` / `get_wave_displacement` / `get_wave_normal`
  to use the summation path
- Added `_update_cascade_scales()` call at the end of `_apply_weather_fft`
  + `reset_weather` (THE critical fix for the "6-10× mismatch")
- Added `set_debug_mode(int)` public API for the shader debug uniform

### `src/core/water/shaders/ocean_fft.gdshader`
- `render_mode` changed: `depth_draw_opaque` → `depth_draw_always`
  (kept `cull_disabled` per load-bearing mesh winding)
- Added `uniform int debug_mode : hint_range(0, 9) = 0;`
- Added 10-mode debug override block at the end of `fragment()` (all
  modes use `if/else if` chain, no `return` — Godot shader forbids it)
- Shore-mask `discard` gated on `debug_mode == 0`
- SSS formula in `light()` reworked:
  - `sss_strength` default 0.8 → 2.0, range 0-2 → 0-4
  - `crest_factor = smoothstep(0.8, 2.0, wave_height) * (1.0 - smoothstep(0.4, 0.85, world_n_y))`
    (height × slope gate)
  - `world_n_y` computed via view-space world-up transform
  - `sss_tint` changed `(0.95, 1.25, 0.9)` → `(0.85, 1.25, 1.15)`
    (blue-green scatter)

### `src/core/water/ocean_mesh.gd`
- `_create_clipmap_mesh`: annular rings (ring ≥ 1) now use
  `inner_radius = prev_outer_radius - quad_size` so successive rings
  overlap by one outer-ring quad — interim T-junction seam fix
- Comment block marks this as temporary and tracks CDLOD / projected
  grid as the canonical replacement

### `src/tools/world_explorer.gd`
- Early in the session: added `InteractionRaycaster` + `CarryController`
  wiring in `_setup_cameras`, `KEY_B` spawn-buoyant-sphere,
  `KEY_V` debug grid. Later MOVED all the buoyancy debug out of this
  file into `test_buoyancy_debug.gd` per user direction.
- The interaction wiring stays. The buoyancy debug is gone.

### `tests/visual/test_buoyancy_debug.gd` (NEW)
- Created from scratch. Minimal ocean + fly camera scene.
- 5 weather presets (KEY_1-5) via fake `WeatherResult` → `OceanManager.apply_weather()`
- `KEY_B` spawn-sphere
- `KEY_V` debug grid
- `KEY_D` cycle shader debug mode
- `KEY_L` toggle sun angle
- Top-right cascade state label
- `_dump_cpu_sampler_state` diagnostic called after each preset change

### `tests/visual/test_interaction_phase_I5.gd`
- Added `OceanManager.use_prebaked_shore_mask = false` before
  `force_initialize()` so the I.5 test also shows visible water

## Reference findings

- **Wicked Engine water** uses projected grid. Confirmed via
  `WickedEngine/shaders/oceanSurfaceVS.hlsl`. Basic SSS via extinction +
  refraction path, no wave-tip crest factor. No shore waves.
- **tessarakkt/godot4-oceanfft** uses CDLOD quadtree + vertex morphing.
  Works but "early stage". Less universal than projected grid for
  water. Has subsurface scattering implementation worth studying.
- **Sea of Thieves** (per GDC talks) uses projected grid + FFT + shore
  wave system (separate from main ocean).
- **Claes Johanson, 2004** is the origin paper for projected grid
  water rendering.
- **Filip Strugar, 2010** is the origin of CDLOD (designed for
  terrain, adapted for water by some engines).

## Next-session starting point

1. Read this doc, `docs/INTERACTION_SYSTEM.md`, `.claude/CLAUDE.md`
2. Launch `tests/visual/test_buoyancy_debug.tscn` — press `D` a few
   times to confirm the debug modes work
3. Pick up open issue A (SSS yellowish) — recommend the EMISSION path
   (bypasses LIGHT_COLOR multiply) as the first attempt
4. After A is resolved, scope the projected grid port (issue B)
5. Shore waves (issue C) is a separate feature, not urgent
