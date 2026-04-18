# Godotwind Lighting — Current State

> This is the current Godotwind lighting configuration. Shadow / GI / AA audit findings have been folded in where still current. For industry-practice comparison see `docs/reference/lighting_research.md`. For the open roadmap (distant-light billboards, SDFGI tuning, etc.) see `docs/plans/lighting_roadmap.md`.

---

## 1. Current State

### 1.1 Light Sources

**ESM Light Records → OmniLight3D** (`reference_instantiator.gd:404-471`)
- Morrowind LIGH records are converted to OmniLight3D nodes
- Range: `radius * MW_LIGHT_SCALE (1/70)`, minimum 0.125m (matches OpenMW)
- Color from ESM, energy 1.2 (fire) or 0.8 (non-fire)
- Negative light support (`light_negative = true`)
- Shadows disabled by default (managed by shadow budget system)
- **Distance fade: 120m start → 150m fully gone** — matches NEAR tier boundary

**NIF Lights** (`nif_converter.gd:2353-2410`)
- NiPointLight → OmniLight3D, NiSpotLight → SpotLight3D
- Attenuation computed from NIF coefficients (constant/linear/quadratic)
- NIF light data is parsed and converted, but secondary to ESM-driven lights

**Celestial Lights** (`sky_manager.gd`)
- DirectionalLight3D for sun (energy=22.0) and moon (energy=0.5)
- Driven by sky system's celestial position calculations
- Sun contributes to volumetric fog for god rays

**No SpotLight3D usage** from ESM data — all Morrowind lights are omnidirectional.

### 1.2 Light Animation

**File:** `light_animator.gd` (128 lines)
- Flicker, FlickerSlow, Pulse, PulseSlow — from MW light flags
- Random brightness targets [0.25, 1.0]
- Effective 15 FPS with temporal smoothing
- Matches OpenMW's LightController behavior

### 1.3 Shadow Management

**File:** `light_shadow_budget.gd` (161 lines)
- **Budget:** Max 8 shadow-casting lights simultaneously
- **Distance tiers (with hysteresis) per `light_shadow_budget.gd:23-26`:**
  - 0–8m: SHADOW_CUBE (6 passes, best quality) — CUBE enables when closer than 8m, disables beyond 10m
  - 8–28m: SHADOW_DUAL_PARABOLOID (2 passes) — DUAL enables when closer than 28m, disables beyond 30m
  - 30m+: No shadows
- Update interval: 0.5s, purge interval: 5s
- This is a solid system — well-architected for performance

**Directional (sun) shadow config** (`sky_manager.gd:274-279`, applied 2026-04-13):
- `directional_shadow_mode = SHADOW_PARALLEL_4_SPLITS`
- `directional_shadow_max_distance = 200.0`
- `shadow_bias = 0.02`
- `shadow_normal_bias = 1.5`
- Cascade splits: 4 splits. When `shadow_cascades` dev toggle is ON (`environment_controls.gd:373-375`), splits are `[0.1, 0.25, 0.5]` with `blend_splits = true`; otherwise Godot defaults apply.
- Project setting: `lights_and_shadows/directional_shadow/size = 2048`

### 1.4 Environment & Post-Processing

**File:** `environment_controls.gd`

| Feature | Status | Settings |
|---------|--------|----------|
| **SSAO** | Enabled | radius=1.5, intensity=3.0, detail=0.7 |
| **SSIL** | Enabled | radius=5.0, intensity=1.0 |
| **SSR** | Enabled | max_steps=64, depth_tolerance=0.2 |
| **Glow/Bloom** | Enabled | intensity=0.4, bloom=0.15, HDR threshold=0.8 |
| **Volumetric Fog** | Enabled | density=0.0015, length=800m, temporal reprojection |
| **Depth Fog** | Enabled | exponential, density=0.00008, height fog at y=0 |
| **Tonemap** | Filmic | exposure=1.0, white=8.0 |
| **SDFGI** | **Enabled** (`sky_manager.gd:251-259`) | cascades=4, y_scale=75%, use_occlusion=true, bounce_feedback=0.3, read_sky_light=true, energy=1.0, normal_bias=1.1, probe_bias=1.1 |
| **VoxelGI** | NOT used | — |
| **LightmapGI** | NOT used | — |
| **ReflectionProbe** | Only for ocean | — |
| **GI half-resolution** | Enabled (`project.godot`) | `rendering/global_illumination/gi/use_half_resolution = true` |
| **Anti-aliasing** | FSR 2.2 at native (runtime-applied via `environment_controls.gd` / `settings_tool.gd`) | `SCALING_3D_MODE_FSR2`, scale=1.0 — replaces TAA; MSAA disabled |

**Ambient light:** Source = SKY, contribution = 1.0, energy = 1.0
**Reflected light:** Source = SKY

### 1.5 Sky & Weather

- Custom atmospheric scattering shader (Rayleigh + Mie, Hillaire 2020 multi-scatter)
- Sun disc, moon, procedural stars
- Weather system modulates fog density/color, volumetric fog, sun energy, sky turbidity
- Thunder flash via volumetric emission spike
- God rays via sun volumetric fog energy

### 1.6 Custom Volumetric Effects

- `volumetric_fog_effect.gd` — ray-marched compute shader (ported from OpenMW VAIO)
- `godrays_effect.gd` — custom compute shader god rays
- These operate alongside Godot's built-in volumetric fog

### 1.7 Terrain Lighting

- `terrain_horizon.gdshader` — horizon map self-shadowing
- Baked horizon angles per 8 compass directions
- Sun elevation/azimuth mapped to shadow angles
- PBR terrain with albedo, normal maps, roughness, AO per texture

### 1.8 Impostor Lighting (FAR Tier, 500m–5km)

- Inline shader in `native_impostor_renderer.gd::_get_octahedral_shader_code()` (~240 lines)
- Two variants: v4 (legacy azimuthal 16-frame 4x4) and v5 (octahedral tri-sample 8x8 with yaw-rotated normals)
- Standalone `octahedral_impostor.gdshader` deleted (was dead code, diverged from inline shader)
- 2-pass baking: albedo (unlit) + normals (world-space RGB + depth A)
- PBR lighting applied: roughness=0.85, specular=0.3
- v5: Brucks tri-sample blending (barycentric weights across 3 nearest octahedral grid cells)
- v5: normals rotated by per-instance yaw before view-space transform (fixes inverted lighting on rotated instances)
- Shadow receive YES, shadow cast NO (avoids rectangular billboard shadows at 500m+)
- **No emissive data baked** — impostors are dark at night

### 1.9 Distance Rendering & Lights

| Tier | Range | Dynamic Lights | Shadows |
|------|-------|---------------|---------|
| **NEAR** | 0–150m | OmniLight3D + animation | Budget-managed (max 8) |
| **MID** | 150–500m | **None** | None |
| **FAR** | 500–5km | **None** (impostor-baked normals only) | None |

**Key gap:** Lights are completely invisible beyond 150m. A town 300m away is pitch black at night.

---

## 2. Key Files Reference

| File | Lines | Purpose |
|------|-------|---------|
| `src/core/esm/records/light_record.gd` | 119 | ESM LIGH record parsing |
| `src/core/world/reference_instantiator.gd` | 404–471 | OmniLight3D creation from ESM |
| `src/core/world/light_animator.gd` | 128 | Flicker/pulse animation |
| `src/core/world/light_shadow_budget.gd` | 161 | Dynamic shadow allocation |
| `src/core/sky/sky_manager.gd` | ~150 | Celestial lights + sky shader + SDFGI setup |
| `src/tools/ui/environment_controls.gd` | ~400 | Environment/post-processing setup |
| `src/core/weather/weather_renderer.gd` | ~150 | Weather → visual state |
| `src/tools/prebaking/impostor_baker_v3.gd` | ~300 | FAR tier impostor baking (v5 octahedral) |
| `native_impostor_renderer.gd::_get_octahedral_shader_code()` | ~240 | Impostor rendering shader (inline, v4+v5 variants) |
| `src/core/sky/shaders/sky.gdshader` | ~180 | Atmospheric scattering |
| `src/core/water/shaders/ocean_fft.gdshader` | ~180 | Ocean SSS lighting |
| `src/core/world/terrain_horizon.gdshader` | 366 | Terrain horizon self-shadow |
| `src/core/nif/nif_converter.gd` | 2353–2410 | NIF light → Godot conversion |
| `src/core/nif/nif_defs.gd` | 592–608 | NIF light class definitions |
| `src/core/shaders/effects/volumetric_fog_effect.gd` | — | Custom volumetric fog (OpenMW port) |
| `src/core/shaders/effects/godrays_effect.gd` | — | Custom god rays |
