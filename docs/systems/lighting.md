# Lighting

Current lighting configuration. For industry comparison see `docs/reference/lighting_research.md`. For the open roadmap (distant-light billboards, SDFGI tuning, etc.) see `docs/plans/lighting_roadmap.md`.

---

## 1. Light sources

**ESM Light Records → OmniLight3D** (`reference_instantiator.gd::_instantiate_light` + `_attach_animated_omni_light` + `_attach_server_direct_light`)

- MW LIGH records → OmniLight3D nodes.
- Range: `radius * MW_LIGHT_SCALE (1/70)`, minimum 0.125 m (matches OpenMW).
- Color from ESM, energy 1.2 (fire) or 0.8 (non-fire).
- Negative light support (`light_negative = true`).
- Shadows disabled by default (managed by shadow budget system).
- Distance fade: `distance_fade_begin = 120 m`, `distance_fade_length = 30 m` (fully gone at 150 m, matches NEAR tier boundary).

**Lazy-spawn gate (Win 4a, 2026-04-25):** lights farther than `LIGHT_PROXIMITY_THRESHOLD_M = 60 m` from the camera at cell-load time are NOT spawned — distance fade kills their contribution by 120 m anyway, and most clutter lights are <100 MW radius. Big lights (radius ≥ `LIGHT_ALWAYS_SPAWN_RADIUS_MW = 700`) bypass the gate so braziers / large fires / cell-defining lights always render.

**Server-direct lights (Win 4b, 2026-04-25):** non-animated lights go through `RenderingServer.omni_light_create()` + `RenderingServer.instance_create()` instead of an OmniLight3D Node3D wrapper. Saves ~1.3 KB + lifecycle/notification machinery per light. Animated lights (flicker / pulse flag-gated) stay on the Node3D path so `light_animator.gd` can drive `light_energy` per frame. See `docs/research/server_direct_pattern.md`.

**Distant real lights (60/150-350 m)** (`distant_light_manager.gd`, 2026-07-06)
- Server-direct RS omni lights for significant lights beyond NEAR: radius ≥ 2 m,
  nearest-first budget of 64, no shadows, excluded from SDFGI (`LIGHT_BAKE_DISABLED`).
- **The 350 m / 64-light caps are GPU constraints, not taste.** Forward+
  clusters are depth-sliced logarithmically; past ~400 m all vista lights land
  in the same few huge clusters and every distant pixel shades all of them —
  the original 600 m / 160-light config measured +30 ms GPU on an RTX 4060
  laptop (2026-07-06 regression). Do not raise these without re-measuring.
- Per-light near handoff: big lights (≥ 10 m radius, which NEAR always spawns)
  crossfade at NEAR_END (150-180 m ramp); small lights are carried all the way
  down to NEAR's 60 m lazy-spawn boundary — otherwise they blink out across
  the 60-150 m band. Far side fades out over 320-350 m. Selection + energy
  ramps re-evaluate every 0.5 s.
- The billboard MultiMesh glow sprites remain on top (150 m - FAR_END) as the
  corona layer — one draw call per page.

**Emissive light models** (`reference_instantiator._boost_light_model_emission`, 2026-07-06)
- Surfaces of light-source models that already emit in the NIF data (flame
  quads, glow textures) get their emission energy raised (fire 2.5×, other
  1.5×) via per-instance surface overrides — shared prebaked materials are
  duplicated once per tier, never mutated. Requires glow (default ON).

**NIF Lights** (`nif_converter.gd`)
- NiPointLight → OmniLight3D, NiSpotLight → SpotLight3D.
- Attenuation computed from NIF coefficients.
- Secondary to ESM-driven lights.

**Celestial lights** (`sky_manager.gd`)
- DirectionalLight3D for sun (energy=22.0) and moon (energy=0.5).
- Driven by sky system's celestial position calculations.
- Sun feeds volumetric fog for god rays.

No SpotLight3D usage from ESM data — all MW lights are omnidirectional.

---

## 2. Light animation

**File:** `light_animator.gd` (128 lines)

Flicker, FlickerSlow, Pulse, PulseSlow from MW light flags. Random brightness targets `[0.25, 1.0]`, effective 15 FPS with temporal smoothing. Matches OpenMW's `LightController` behavior.

---

## 3. Shadow management

**File:** `light_shadow_budget.gd` (161 lines)

- **Budget:** max 8 shadow-casting lights simultaneously.
- **Distance tiers (with hysteresis):**
  - 0–8 m: SHADOW_CUBE (6 passes) — enables < 8 m, disables > 10 m
  - 8–28 m: SHADOW_DUAL_PARABOLOID (2 passes) — enables < 28 m, disables > 30 m
  - 30 m+: no shadows
- Update interval 0.5 s, purge interval 5 s.

**Directional (sun) shadow** (`sky_manager.gd:275-276`):

- `directional_shadow_mode = SHADOW_PARALLEL_4_SPLITS`
- `directional_shadow_max_distance = 200.0`
- Cascade splits: when `shadow_cascades` dev toggle is ON (`environment_controls.gd`), splits are `[0.1, 0.25, 0.5]` with `blend_splits = true`; otherwise Godot defaults apply.
- Project setting: `lights_and_shadows/directional_shadow/size = 2048`

---

## 4. Environment & post-processing

`environment_controls.gd`

Exterior defaults (`environment_controls.gd` `_visual_state`, 2026-07-06):

| Feature | Default | Settings |
|---|---|---|
| **SSAO** | OFF outdoors, forced ON in interiors | radius=1.5, intensity=2.0-3.0 |
| **SSIL** | OFF | radius=5.0, intensity=1.0 |
| **SSR** | ON | max_steps=64, depth_tolerance=0.2 |
| **Glow/Bloom** | ON (2026-07-06 — emissive light models rely on it) | intensity=0.4, bloom=0.15, HDR threshold=0.8 |
| **Volumetric Fog** | OFF outdoors, OFF in enclosed interiors | density=0.0015 when enabled |
| **Depth Fog** | ON | exponential, density=0.00008, height fog at y=0 |
| **Tonemap** | Filmic | exposure=1.0, white=8.0 |
| **SDFGI** | ON (`sky_manager.gd:298`) — exterior GI + interior fallback | cascades=4, y_scale=75%, occlusion on, bounce_feedback=0.3, read_sky_light=true |
| **VoxelGI** | Prebaked per interior (2026-07-06) | see §Interior lighting |
| **LightmapGI** | Not used — `bake()` not scriptable (godot-proposals#8656), batch bake impossible | — |
| **ReflectionProbe** | One per interior pocket (2026-07-06) | UPDATE_ONCE, box-projected, interior=true |
| **GI half-resolution** | Enabled (`project.godot`) | `rendering/global_illumination/gi/use_half_resolution = true` |
| **Anti-aliasing** | FSR 2.2 at native scale (temporal AA; NOT Godot TAA — `use_taa` stays false) | `environment_controls.on_taa_toggled` / `settings_tool.gd` (menu default FSR2_NATIVE) |

Ambient light: source = SKY, contribution = 1.0, energy = 1.0. Reflected light: source = SKY.

## 4b. Interior lighting (2026-07-06 lighting pass)

- **Environment**: built per transition as a `duplicate()` of the live exterior
  Environment (`morrowind_transition_provider._build_space_environment`), so
  interiors inherit the user's post stack. Overrides: ambient from the cell's
  AMBI record (luma floor 0.08), MW fog color/density, near-black background,
  `sky = null`, volumetric fog off, SSAO + glow forced on. Forced OFF indoors:
  SDFGI (it replaces the constant ambient on static geometry — with no sky it
  turned interiors pitch black, and it costs real GPU), SSR (the probe covers
  reflections), and the inherited exterior HEIGHT fog (anchored near y=0, it
  saturates at the pocket's y=-500 offset into a white wall — the 2026-07-06
  "Arille's fog" regression).
- **AMBI sunlight_color is parsed but deliberately unused** — user decision
  2026-07-06: an interior directional "sun" doesn't make sense here.
- **ReflectionProbe**: one per pocket in finish-up phase 1, sized to the pocket
  AABB, `UPDATE_ONCE`, box projection, interior=true, interior layers only.
- **VoxelGI**: prebaked per interior cell by
  `src/tools/prebaking/interior_gi_bake_runner.tscn` into
  `<cache>/interior_gi/<cell>.res` (contract: `interior_gi_cache.gd`). Loaded
  in pocket phase 1; when present it disables the interior env's SDFGI
  fallback. Voxel field is re-lit per frame from live lights → torch flicker
  bounces (the reason VoxelGI was chosen over lightmaps, besides LightmapGI's
  bake being unscriptable).
- Without a bake, interiors fall back to SDFGI from the duplicated exterior
  environment.

## 4c. Material specular gate (2026-07-06)

MW convention (OpenMW nifloader): a shape has specular ONLY with an enabled
`NiSpecularProperty`. MW meshes routinely store WHITE specular color + nonzero
glossiness with specular disabled; applying them unconditionally maxed
`metallic_specular` and washed containers/crates with a whitish sheen.
`MaterialProperties.specular_enabled` (material_library.gd) now gates
specular/roughness/specular_color in every converter path, and specular state
is part of the dedup cache key. **Model prebake cache must be re-baked for the
fix to appear on prebaked assets.**

**Note:** the current ocean surface shader declares `hint_depth_texture` /
`hint_screen_texture` and owns a custom SSR raymarch for water-surface
reflections. See `docs/systems/ocean/architecture.md` and
`docs/systems/ocean/godot_4_6_water_rendering_rules.md`.

---

## 5. Sky & weather

- Custom atmospheric scattering shader (Rayleigh + Mie, Hillaire 2020 multi-scatter).
- Sun disc, moon, procedural stars.
- Weather modulates fog density/color, volumetric fog, sun energy, sky turbidity.
- Thunder flash via volumetric emission spike.
- God rays via custom compute shader (`godrays_effect.gd`).

See `docs/systems/sky.md`.

---

## 6. Custom volumetric effects

- `volumetric_fog_effect.gd` — ray-marched compute shader (ported from OpenMW VAIO).
- `godrays_effect.gd` — custom compute shader god rays.

These operate alongside Godot's built-in volumetric fog.

---

## 7. Terrain lighting

- `terrain_horizon.gdshader` — horizon-map self-shadowing.
- Baked horizon angles per 8 compass directions.
- Sun elevation/azimuth → shadow angles.
- PBR terrain with albedo, normal, roughness, AO per texture.

---

## 8. Impostor lighting (FAR tier 400-5000 m)

- Inline shader in `native_impostor_renderer.gd::_get_octahedral_shader_code()` (~240 lines).
- Two variants: v4 (legacy azimuthal 16-frame 4×4) and v5 (octahedral tri-sample 8×8 with yaw-rotated normals).
- 2-pass baking: albedo (unlit) + normals (world-space RGB + depth A).
- PBR lighting applied: roughness=0.85, specular=0.3.
- v5: Brucks tri-sample blending (barycentric weights across 3 nearest octahedral grid cells).
- v5: normals rotated by per-instance yaw before view-space transform (fixes inverted lighting on rotated instances).
- Shadow receive YES, shadow cast NO (avoids rectangular billboard shadows in the FAR tier).
- **No emissive data baked** — impostors are dark at night.

---

## 9. Distance rendering & lights

Tier ranges from `distance_utils.gd` (post-Phase-5, 2026-04-17):

| Tier | Range | Dynamic Lights | Shadows |
|---|---|---|---|
| **NEAR** | 0–150 m | OmniLight3D (animated) or RS server-direct (static), lazy-spawn beyond 60 m | Budget-managed (max 8) |
| **MID** | 150-400 m static visual bridge | None | None |
| **HLOD** | Optional 400-1000 m comparison tier | None | None |
| **FAR** | 400-5000 m, capped by view distance | None (impostor-baked normals only) | None |

**Key gap:** dynamic lights are completely invisible beyond 150 m. A town 300 m away is pitch black at night. This is the open item driving `docs/plans/lighting_roadmap.md` (distant light billboards / Priority 2).

---

## 10. Files

| File | Purpose |
|---|---|
| `src/core/esm/records/light_record.gd` | ESM LIGH record parsing |
| `src/core/world/reference_instantiator.gd` | OmniLight3D + server-direct light creation, lazy-spawn gate |
| `src/core/world/light_animator.gd` | Flicker/pulse animation |
| `src/core/world/light_shadow_budget.gd` | Dynamic shadow allocation |
| `src/core/sky/sky_manager.gd` | Celestial lights + sky shader + SDFGI setup |
| `src/tools/ui/environment_controls.gd` | Environment/post-processing setup |
| `src/core/weather/weather_renderer.gd` | Weather → visual state |
| `src/tools/prebaking/impostor_baker_v3.gd` | FAR tier impostor baking (v5 octahedral) |
| `native_impostor_renderer.gd` | Impostor rendering shader (inline, v4+v5 variants) |
| `src/core/sky/shaders/sky.gdshader` | Atmospheric scattering |
| `src/core/water/shaders/ocean_fft.gdshader` | Ocean SSS lighting |
| `src/core/world/terrain_horizon.gdshader` | Terrain horizon self-shadow |
| `src/core/nif/nif_converter.gd` | NIF light → Godot conversion |
| `src/core/shaders/effects/volumetric_fog_effect.gd` | Custom volumetric fog (OpenMW port) |
| `src/core/shaders/effects/godrays_effect.gd` | Custom god rays |
