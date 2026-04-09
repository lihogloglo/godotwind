# Ocean Water System — Session Handoff (2026-04-10)

## Scope

Follow-up to `OCEAN_2026_04_09_SESSION.md`. Two user-facing asks:
1. **SSS rewrite** — the Sea of Thieves–style "lighter water where the waves
   are thinner" that the old height × slope formula was failing to produce.
2. **Projected-grid port** — replace the clipmap mesh with the canonical
   Wicked Engine / Sea of Thieves / Johanson 2004 screen-space grid, which
   the previous session scoped but did not implement.

Both landed, both have open issues that need another pass. The ocean water
system is still iterating — neither approach is production-ready and the
user has explicitly said "don't remove the clipmap yet, not sure which one
wins". Both paths remain in-tree side-by-side, toggleable at runtime from
the buoyancy debug scene (`KEY_G`).

The canonical test scene is still **`tests/visual/test_buoyancy_debug.tscn`**.
All iteration should happen there, not in the main Godotwind scene.

---

## What shipped this session

### Step 1 — SSS rewrite (choppiness-driven ALBEDO blend)

**Previous state:** `light()` function computed a crest factor from
`smoothstep(0.8, 2.0, wave_height) × (1 - slope)` multiplied by backlight
(`dot(LIGHT, -VIEW)^4`) and rim (`0.5 - 0.5 × L·N)^3`), wrote the result
additively to `DIFFUSE_LIGHT` multiplied by a `sss_tint`. Two bugs:

1. **Wrong peak mask.** The SoT paper uses **FFT choppiness** (horizontal
   displacement magnitude) as the peak mask — "Where the choppiness offset
   is greater, this corresponds to wave peaks, which show more sub-surface
   due to shorter distance traveled by light through the water". Our
   height × slope formula only fired on tall crests in storms, and never in
   calm weather where `wave_height` doesn't cross 0.8m.
2. **LIGHT_COLOR tinting.** The final `DIFFUSE_LIGHT * ATTENUATION *
   LIGHT_COLOR` multiply crushed the blue-green `sss_tint` to yellow at
   sunset, because the sun color `(1.0, 0.7, 0.45)` dominates the output.

**New approach:** SSS is now an **ALBEDO blend** in `fragment()`, not an
additive term in `light()`. Matches the SoT paper verbatim — "we blend
between a deep water colour and a sub-surface water colour based on a
combination of view angle, sun direction and a wave peak mask".

Vertex shader accumulates horizontal displacement magnitude per cascade
into a new `v_choppiness` varying. Fragment shader uses it as the peak
mask, multiplies by view-angle and sun-backlight terms, and blends
`base_water = mix(base_water, color_sub_surface, scatter)` before the
fresnel / sky tint mix. The `light()` function is now pure Smith-GGX
specular + half-lambert diffuse + foam mix, no SSS.

**Uniforms (in `ocean_fft_common.gdshaderinc`):**
```glsl
uniform vec3 color_sub_surface : source_color = vec3(0.28, 0.62, 0.48);
uniform float sss_strength : hint_range(0.0, 3.0) = 0.9;
uniform float scatter_choppiness_min : hint_range(0.0, 2.0) = 0.28;
uniform float scatter_choppiness_max : hint_range(0.1, 3.0) = 0.75;
uniform vec3 sun_dir_world = vec3(0.0, -1.0, 0.0);
```

**Fragment SSS block (lines ~560-585 in the common include):**
```glsl
float peak_mask = smoothstep(scatter_choppiness_min, scatter_choppiness_max, v_choppiness);
vec3 world_view_dir = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
float world_cos_theta = clamp(dot(world_view_dir, world_normal), 0.0, 1.0);
float view_fade = pow(1.0 - world_cos_theta, 2.0);
float sun_back = clamp(0.5 + 0.5 * dot(-world_view_dir, sun_dir_world), 0.0, 1.0);
float scatter = sss_strength * peak_mask
    * mix(0.05, 1.0, view_fade)
    * mix(0.15, 1.0, sun_back);
scatter = clamp(scatter, 0.0, 1.0);
base_water = mix(base_water, color_sub_surface, scatter);
```

**Sun direction plumbing.** `OceanManager::_update_sun_uniform()` scans for
a `DirectionalLight3D` (lazy, every 60 frames if null) and pushes
`-light.global_basis.z` into the `sun_dir_world` shader uniform every
frame, so the sun-backlight term actually fires when the day/night cycle
rotates the sun.

**Weather hooks** — `_apply_weather_shader` SSS lerp is `0.6 → 1.0` (calm
→ storm). The old lerp was `0.9 → 0.3` (inverted for the height × slope
formula).

**Status: SHIPPED BUT STILL BROKEN.** User feedback after tuning pass
(2026-04-10 01:42): *"SSS is still buggy (big green patches, need some
more real projects as examples) for both modes"*. The choppiness-driven
approach fires more naturally than height × slope but still produces
visible flat green areas. See Open Issues §A.

### Step 2 — Projected-grid mesh port

Ships `ocean_fft_projected.gdshader` + a new `_create_projected_mesh()`
builder in `ocean_mesh.gd`, toggleable at runtime from the buoyancy debug
scene via `KEY_G`.

**Architecture choice — shared include.** Rather than copy-paste ~700
lines of shader code, the common state (uniforms, varyings, helpers,
fragment, light) moved into
`src/core/water/shaders/ocean_fft_common.gdshaderinc`. The two
`.gdshader` files are now thin wrappers:
- `ocean_fft.gdshader` — ~65 lines. `shader_type` + `render_mode
  world_vertex_coords, ...` + `#include ...` + clipmap vertex. Vertex
  reads world-space `VERTEX.xz` directly (mesh is snapped to a 64m grid
  around the camera by `OceanMesh::update_position`).
- `ocean_fft_projected.gdshader` — ~160 lines. `shader_type` +
  `render_mode cull_disabled, shadows_disabled, depth_draw_always` (no
  `world_vertex_coords`) + `#include ...` + projected vertex. Vertex reads
  `VERTEX.xz` as `[0,1]²` grid UV, remaps to NDC with an overscan factor
  (see below), unprojects via `INV_VIEW_MATRIX * INV_PROJECTION_MATRIX`
  with reversed-Z (z=1 near, z=0 far), ray-intersects the water plane at
  `y = sea_level`, applies FFT displacement at the resulting world XZ,
  writes `POSITION` directly to bypass the default MVP transform.

**Frustum overscan.** New uniform `projected_grid_overscan` in the
projected shader (default 1.15, range 1.0-1.5). Extends the grid beyond
the standard `[-1,1]²` NDC range so the outermost vertices project
slightly off-screen, leaving margin for camera rotation + numerical
precision. Wicked Engine uses ~1.1-1.2.

**Degenerate-ray fallback.** When `ray_d.y > -1e-4` (camera looking up or
parallel to the water plane) or `t < 0` (intersection behind camera), the
vertex is clamped to a distant horizon ring (`PROJECTED_GRID_FAR_HORIZON
= 20000m`) in the ray's XZ direction at `y = sea_level`. Prevents NaN /
infinity from escaping into the vertex stream.

**Mesh builder.** `_create_projected_mesh()` in `ocean_mesh.gd` builds a
single 192×192 flat grid in local `[0,1]²` coordinates (37249 vertices,
73728 triangles), with an enormous custom AABB `(-1e6, -1e4, -1e6) →
(+1e6, +1e4, +1e6)` and `extra_cull_margin = 1e6` to skip frustum culling
entirely (the mesh is at origin but the vertex shader writes world
positions anywhere in space).

**Runtime toggle.** `OceanManager::rebuild_mesh_with_mode(int)` tears down
the `OceanMesh` node, re-instantiates it with the new mesh mode, and
re-pushes shader parameters + shore mask + cascade scales + weather
reset. FFT cascade state is preserved across the rebuild because the
`WaveGenerator` lives on `OceanManager` not `OceanMesh`. Exposed as
`KEY_G` in `test_buoyancy_debug.gd`.

**Project setting.** `ocean/mesh_mode` (enum `Clipmap,Projected`, default
`Clipmap`). Applied during `OceanManager::_deferred_init`.

**Status: SHIPPED BUT HAS MULTIPLE VISIBLE ARTIFACTS.** See Open Issues
§B — the projected grid has at least three independent bugs that need
another session.

### Step 3 — Shader shared-include refactor

Side effect of step 2 but worth calling out separately: the shader code
now lives in `ocean_fft_common.gdshaderinc` (~530 lines), and both
`.gdshader` files are ~60-160 line wrappers that only own their vertex
path. This replaces what would have been ~700 lines of
copy-pasted-and-drift-prone fragment code with a single source of truth.
Future iteration on the fragment path (SSS tuning, SSR, refraction) only
touches one file.

Godot 4.x `#include "relative.gdshaderinc"` syntax works (verified by
`src/core/sky/shaders/sky.gdshader` which uses the same pattern).

---

## Open issues — hand to next session

### A. SSS still produces flat green patches (both mesh modes)

**User feedback (2026-04-10 01:42):** *"SSS is still buggy (big green
patches, need some more real projects as examples) for both modes"*.

**Two tuning passes already attempted, both insufficient:**

Pass 1 defaults:
- `scatter_choppiness_min = 0.08`
- `scatter_choppiness_max = 0.55`
- `sss_strength = 1.2` (weather 0.9 → 1.5)
- `view_fade` floor `mix(0.35, 1.0, ...)`
- `sun_back` floor `mix(0.45, 1.0, ...)`

User feedback after pass 1: *"the 'green' from SSS is very very intense
now. Big patches of flat green, doesn't look good at all."*

Pass 2 (current live values):
- `scatter_choppiness_min = 0.28`
- `scatter_choppiness_max = 0.75`
- `sss_strength = 0.9` (weather 0.6 → 1.0)
- `view_fade` floor `mix(0.05, 1.0, ...)`
- `sun_back` floor `mix(0.15, 1.0, ...)`

User feedback after pass 2: *"SSS is still buggy (big green patches, need
some more real projects as examples)"*.

**Diagnosis.** The choppiness-driven peak mask + half-lambert sun
backlight + view fade combination is closer to correct than the previous
height × slope + `pow(dot(LIGHT, -VIEW), 4)` formula, but still isn't
matching the user's mental model. Three possible root causes worth
investigating:

1. **Wrong metric entirely.** Looking again at the SoT quote: *"The wave
   peak mask is generated from the FFT choppiness vertex offsets"*. "Peak
   mask" in FFT literature usually refers to the **Jacobian determinant
   of the horizontal displacement field**, NOT the magnitude of the
   horizontal displacement. The Jacobian is what godot4-oceanfft and
   GodotOceanWaves use for whitecap generation, and it's the *change* in
   packing density — a sharp crest has a near-zero or negative Jacobian
   (mass compressing), flat water has J ≈ 1. Our current `length(disp.xz)`
   sums the raw displacement magnitude, which is non-zero even on gentle
   chop. Try sampling `gradient.z` (Jacobian, already computed for foam)
   instead. The peak mask would be `smoothstep(0.3, 0.9, gradient.z)` or
   similar — it'd only fire where the shader already draws foam, which
   IS physically where thin-water scatter lives.
2. **Need a thickness proxy, not a peak proxy.** SoT talks about "shorter
   distance traveled by light through the water". The actual physical
   quantity is water thickness along the sun ray. We have `wave_height`
   as a vertex varying, but what we really want is `thickness = wave_height
   + troughDepth_underneath`. That's hard to sample without a 3D volume
   lookup. Approximation: `thickness = wave_height > 0 ? wave_height :
   0.5` and scatter only where `wave_height > 0`. Then scatter = thin →
   `1 / thickness`, capped. This gives "bright crests, dark troughs"
   which is closer to SoT reference screenshots.
3. **Additive contribution rather than blend.** Maybe the mix-to-
   sub_surface_color is inherently too heavy-handed. A lighter touch:
   keep `base_water` as the deep color, then write scatter as an
   additive `EMISSION` term at the crests. That way flat water is
   unchanged (no green bleed) and only the actual crest tips add a cyan
   glow. Less accurate physically but maps to "the green only appears
   where thin water should be visible".

**Real-project references the user explicitly wants us to study:**
- tessarakkt/godot4-oceanfft — has a working SSS implementation, port
  their formula wholesale as a first attempt
- Wicked Engine `oceanSurfacePS.hlsl` — they use an extinction + refraction
  path, no crest-specific scatter. Might be we're overcomplicating this
  and should just tune the absorption coefficients + shallow color
  gradient to get the same visual effect
- Sea of Thieves "Technical Art" GDC talk — referenced by the paper quote
  but we don't have the actual shader source; need screenshots / gifs
- Ghost of Tsushima / Black Flag — often cited as AAA ocean references.
  Ghost of Tsushima is particularly interesting because it has the exact
  "lighter green at thin waves" look the user describes

**Next-session recommendation:** port the **godot4-oceanfft** SSS formula
verbatim before doing any more parameter tuning. If that doesn't look
right either, then the approach itself needs replacement (option 2 above
is the most promising). Don't burn another session on threshold tuning —
the problem is architectural, not numeric.

### B. Projected grid has multiple visible artifacts

**User feedback (2026-04-10 01:42):**
> projected grid mode:
> - the frustum of the projected grid cuts too much of the ocean when it's
>   in extreme waves (because waves "pull" the vertices closer together
>   probably)
> - it also cuts a lot of the ocean when looking down
> - it also wobbles when I move

#### B1. Wave displacement pulls the frustum edge inward

**Symptom:** In storm weather, the visible water boundary stops before
the actual frustum edge. Gaps of sky / skybox appear at the screen edges
where water should be.

**Root cause (likely):** the grid vertices are placed at fixed NDC
positions and then the FFT displacement adds `displacement * shore` to
the **world-space position** of each vertex. Vertices near the frustum
edge get pushed horizontally (choppiness!) which can move their final
clip-space position *inward* enough that the rendered geometry no longer
covers the screen edge. The 1.15 overscan is sized for camera rotation
margin, not for wave-scale XZ displacement.

**Fix options for next session:**
1. **Bigger overscan.** Bump `projected_grid_overscan` to 1.3 or 1.4. At
   max wind (20 m/s) the cascade-0 choppiness can push a vertex ~2-3m
   horizontally; at 500m away that's ~0.3% of NDC width, so 1.3 is
   probably overkill but safe. Cheapest fix.
2. **Post-displacement reprojection.** After applying FFT displacement,
   project the world position back to NDC and snap the vertex outward
   if it's inside the frustum edge. More correct but a chunk of extra
   math per vertex.
3. **Clamp horizontal displacement near frustum edges.** Scale
   `displacement.xz` down as `ndc` approaches the edge of overscan.
   Probably the cleanest canonical fix — Wicked Engine's shader has
   something similar.

Option 1 as a quick first step, option 3 as the real fix.

#### B2. Ocean cut off when looking down

**Symptom:** Camera looking down (positive pitch, towards the water
plane from above) has a visible horizon cut — water covers the top of
the screen but not the bottom.

**Root cause (likely):** the `ray_d.y > -1e-4` fallback fires too
aggressively. When the camera looks mostly down, the near-plane grid
vertices at the top of the screen have rays pointing more horizontally
(small `ray_d.y`) and can land on the wrong side of the threshold,
getting clamped to the horizon ring instead of the near-foreground
plane.

**Fix options:**
1. **Tighten the degenerate threshold.** `-1e-4` is very close to zero;
   something like `-0.01` or even `-0.1` might be needed. But this
   creates a new failure mode at the horizon line.
2. **Separate handling for near-horizon vertices.** If `ray_d.y` is
   very small negative, don't clamp — do the full ray-plane intersect
   and just trust that the resulting `t` is very large, then clamp by
   distance instead (which we already do for
   `dist_xz > PROJECTED_GRID_FAR_HORIZON`).
3. **Clip-space Y bias.** Instead of clamping the world-space ray, just
   push the vertex's CLIP-space Y to the bottom of the screen when it
   fails to intersect. This keeps the horizon silhouette flat and
   predictable, which is what Wicked Engine actually does.

Option 3 is canonical — study Wicked's handling of "ray doesn't hit
plane" in `oceanSurfaceVS.hlsl`.

#### B3. Wobble when moving

**Symptom:** Translating the camera causes visible wobble / swimming on
the water surface.

**Root cause (likely):** every frame, the camera's view and projection
matrices change, so the NDC-space grid unprojects to **different**
world-space positions. The FFT displacement at those world positions is
correct, but the visible vertex positions shift between frames because
the grid itself is anchored to the camera not to world space.

This is the opposite problem from the clipmap (where vertex snapping
prevents swim by keeping world-space vertices stable). In the projected
grid, vertex world-positions are intentionally not stable — they're
always exactly where the camera projects them. Any sub-pixel jitter in
the camera → unproject → displacement → project chain shows up as
wobble.

**Fix options:**
1. **Snap the NDC grid to pixel centers.** Offset the grid in NDC by
   `-fract(camera_xy / pixel_size)` so the grid aligns with screen
   pixels. This is what Wicked Engine does and it kills most visible
   wobble.
2. **Snap the displacement lookup UV.** Instead of using the unprojected
   world XZ directly as the FFT sample coord, quantize it to a grid
   (e.g. `floor(world_xz / 0.5) * 0.5`) so sub-pixel camera motion
   doesn't slide the sample point. Produces visible stepping at close
   range though.
3. **Anti-alias via temporal accumulation.** Rely on Godot's FXAA /
   TAA to hide the sub-pixel motion. Weakest fix, doesn't solve the
   root cause.

Option 1 is the canonical AAA fix. Requires passing the viewport size +
camera XY offset as shader uniforms (`CAMERA_POSITION_WORLD` is already
available, `VIEWPORT_SIZE` is a built-in).

### C. Clipmap still has vertex vibration when moving

**User feedback (2026-04-10 01:42):** *"clipmap: there's still some
issues of vibration when I move. Maybe the vertex snapping isn't working
ideally or that's not the best method"*

**Current state.** `OceanMesh::update_position(center)` snaps the mesh's
`global_position` to a 64m grid:
```gdscript
const SNAP_SIZE: float = 64.0
global_position = Vector3(
    snappedf(center.x, SNAP_SIZE),
    center.y,
    snappedf(center.z, SNAP_SIZE)
)
```

64m was picked as the inner-ring half-size (`BASE_QUAD_SIZE * 32 =
2*32`) so vertices only jump when the camera crosses a ring-sized
boundary. In theory this should eliminate swim. In practice the user is
seeing vibration.

**Possible causes:**
1. **Floating-point precision at large world coordinates.** Morrowind
   cells sit at ±8000m from origin. At 8000m, float32 has ~0.0005m
   precision, which may be visible as sub-pixel wobble after the
   vertex shader's matrix multiplies. `global_vertex_coords` render
   mode passes world positions into the vertex shader directly
   without the camera-relative transform that normally hides this.
2. **Y-axis not snapped.** The camera Y (not snapped) is passed
   through in the `center.y` value, and any Y motion causes the
   distance calculations (`length(VERTEX - CAMERA_POSITION_WORLD)`)
   to change continuously, which modulates `cascade_fade` in the
   vertex loop. The waves themselves don't move but the per-vertex
   amplitude does, creating vibration.
3. **The snapping happens on the Node3D transform but the vertex
   shader reads VERTEX directly as world coordinates** (because
   `render_mode world_vertex_coords` is set). The mesh's
   `global_position` does NOT move the vertices — it only moves the
   bounding box for culling. This might be a Godot render-mode quirk
   where `world_vertex_coords` pre-transforms the vertex through the
   model matrix, which means our snapping **does** work for the vertex
   positions. Needs verification with a shader-side `#debug` printf.

**Fix options for next session:**
1. **Verify snapping actually works.** Write a shader debug mode that
   outputs `VERTEX.x - floor(VERTEX.x / 64.0) * 64.0` as a color ramp
   and confirm the visible grid moves in 64m steps, not continuously.
2. **Snap Y too.** If the cascade_fade distance modulation is the
   culprit, snap `center.y` to `sea_level` always (the mesh only ever
   lives at `y = sea_level`, there's no reason to track camera Y).
3. **Switch to CDLOD** (quadtree with vertex morphing). This is the
   handoff doc's recommended canonical fix for the clipmap — the
   existing ring-overlap "interim fix" is a kludge that'd be
   eliminated by CDLOD anyway. Study tessarakkt/godot4-oceanfft's
   CDLOD implementation, port it into a third mesh mode, keep the
   projected grid as an alternative for comparison.

Option 2 is the cheapest test. Option 3 is the real answer if the
user keeps disliking both current modes.

**Important:** the user explicitly said *"I'm not sure to remove the
clipmap"*, so whichever mesh path next session lands on, **keep the
other two as fallbacks** until the user picks a winner. The toggle
infrastructure (`rebuild_mesh_with_mode`, project setting, `KEY_G`) is
designed to accommodate ≥2 modes.

---

## Files touched this session

### New files
- `src/core/water/shaders/ocean_fft_common.gdshaderinc` — shared shader
  include (530 lines). Uniforms, varyings, SSR helpers, bicubic filter,
  fragment(), light(), Smith-GGX specular helpers. Included by both
  `.gdshader` files. **Single source of truth for fragment behavior.**
- `src/core/water/shaders/ocean_fft_projected.gdshader` — projected-grid
  entry shader (~160 lines). `shader_type` + `render_mode` (no
  `world_vertex_coords`) + `#include common` + projected vertex function.
- `docs/audit/OCEAN_2026_04_10_SESSION.md` — this file.

### Modified files

#### `src/core/water/shaders/ocean_fft.gdshader`
- Trimmed from 745 lines to ~65. Now: `shader_type spatial;` +
  `render_mode world_vertex_coords, cull_disabled, shadows_disabled,
  depth_draw_always;` + `#include "ocean_fft_common.gdshaderinc"` +
  clipmap `vertex()` function.
- Behavior of the clipmap path is unchanged — all the fragment / SSS /
  SSR / refraction code moved to the common include, the vertex
  function is identical.

#### `src/core/water/ocean_mesh.gd`
- New `MeshMode { CLIPMAP, PROJECTED }` enum.
- New `_mesh_mode: MeshMode = MeshMode.CLIPMAP` member.
- New `PROJECTED_GRID_DIM = 192` constant.
- `initialize(radius, quality_override, mesh_mode)` — added `mesh_mode`
  parameter. Projected auto-downgrades to clipmap with a warning if
  quality isn't HIGH.
- `_create_shader()` — picks `ocean_fft.gdshader` or
  `ocean_fft_projected.gdshader` based on `_mesh_mode`.
- New `_create_projected_mesh(radius)` — single 192×192 flat grid in
  `[0,1]²` local space, custom AABB 1e6 on each axis to skip frustum
  culling.
- `update_position(center)` — no-op in `PROJECTED` mode.
- New `get_mesh_mode()` query.
- New `_mesh_mode_name()` debug helper.

#### `src/core/water/ocean_manager.gd`
- New `const SETTING_MESH_MODE := "ocean/mesh_mode"` project setting
  (enum `Clipmap,Projected`, default `Clipmap`).
- New `@export_range(0, 1) var water_mesh_mode: int = 0`.
- `_register_project_settings()` — registers the mesh mode setting.
- `_deferred_init()` — reads the setting + passes to
  `_ocean_mesh.initialize()`.
- `_cached_sun_light: DirectionalLight3D` + `_last_sun_scan_frame` state
  for the SSS sun direction uniform.
- New `_update_sun_uniform()` helper — scans the scene tree at most
  every 60 frames, pushes `-sun.global_basis.z` as `sun_dir_world` every
  frame it's known.
- `_process()` — calls `_update_sun_uniform()` unconditionally.
- `set_debug_mode()` — clamp range fixed from `(0, 8)` to `(0, 9)` to
  match the mode 9 (SSS scatter) added this session.
- New `rebuild_mesh_with_mode(int)` — runtime mesh mode toggle, tears
  down + rebuilds `OceanMesh`, re-pushes shader params + cascade scales
  + weather.
- New `get_mesh_mode()` query.
- `_apply_weather_shader()` — `sss_strength` lerp updated to
  `0.6 → 1.0` (calm → storm), was `0.9 → 0.3` in the old formula.
- `reset_weather()` — `sss_strength` reset updated from `0.9` to `0.6`.

#### `tests/visual/test_buoyancy_debug.gd`
- New `KEY_G` hotkey → `_toggle_mesh_mode()` calls
  `OceanManager.rebuild_mesh_with_mode()`.
- `DEBUG_MODE_NAMES[9]` label updated from "SSS crest factor" to "SSS
  scatter factor".
- Hint label text extended with the G key line.

---

## Next-session starting point

1. Read `OCEAN_2026_04_09_SESSION.md` + this file + `.claude/CLAUDE.md`
2. Launch `tests/visual/test_buoyancy_debug.tscn` and verify both mesh
   modes still render (press `G` to toggle)
3. **Priority 1 — fix SSS** (Open Issue §A). Port godot4-oceanfft's
   SSS formula as a direct replacement. Stop tuning thresholds on the
   current formula; it's architecturally close but not quite right.
4. **Priority 2 — fix projected grid wobble** (Open Issue §B3). NDC
   pixel snapping. Study Wicked Engine's handling. This is the single
   biggest visual artifact of the projected grid and blocks user
   acceptance.
5. **Priority 3 — fix projected grid frustum cuts** (Open Issues §B1 +
   §B2). Bigger overscan for quick mitigation, then Wicked's
   post-displacement reprojection for the real fix.
6. **Priority 4 — diagnose clipmap vibration** (Open Issue §C). Start
   with the Y-snap fix since it's cheapest, then verify whether
   `world_vertex_coords` actually honors mesh global_position snapping.
7. Scope CDLOD as a third mesh mode if neither current path wins after
   1-4 are resolved.

**Do NOT remove the clipmap path.** The user has explicitly said both
modes should stay until a clear winner emerges. The toggle
infrastructure is intentional, not temporary.

**Do NOT do more threshold-tuning passes on the current SSS formula
without porting a known-good reference first.** Two tuning passes on
the same wrong approach already happened this session and both failed
— classic pattern from the `CLAUDE.md` Simplicity Over Over-Engineering
principle.

## Reference findings (unchanged from 2026-04-09, re-verified)

- **Wicked Engine water** — projected grid, FFT + JONSWAP, no wave-tip
  SSS (extinction-based scattering only). Shader source in
  `WickedEngine/shaders/oceanSurfaceVS.hlsl`. **Study this for issues
  §B1, §B2, §B3.**
- **tessarakkt/godot4-oceanfft** — CDLOD quadtree, has a working SSS
  implementation. **Study this for issue §A.**
- **Sea of Thieves** (GDC talks) — projected grid + FFT + choppiness
  peak mask + deep/sub_surface color blend. The paper we're trying to
  replicate, but we don't have the shader source.
- **Claes Johanson 2004** — original projected-grid water rendering
  paper (Lund University MSc thesis).
- **Filip Strugar 2010** — CDLOD original paper (designed for terrain,
  adapted for water by some engines).
