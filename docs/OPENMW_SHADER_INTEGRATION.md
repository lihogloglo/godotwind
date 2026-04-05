# OpenMW Shader Integration Plan

How to port OpenMW community shaders (.omwfx) into Godotwind's Godot 4.6 framework.

**Status:** Planning. Compute fog shader upgraded with VAIO weather tables. Full compat layer not yet built.

**Goal:** Enable Godotwind to use atmospheric rendering techniques from the OpenMW modding community (Rafael's Shader Pack, zesterer's shaders, etc.) with minimal manual porting effort.

---

## The Problem

OpenMW community shaders like Rafael's VAIO and godrays are written in a custom `.omwfx` format that Godot cannot read. The format mixes:
- A **DSL** (Domain Specific Language) for render pipeline declaration (`render_target`, `technique`, `passes`)
- **Raw GLSL** fragments embedded inside pass declarations (vertex + fragment shaders)
- **OpenMW-specific builtins** (`omw.eyePos`, `omw_GetDepth()`, `omw.weatherID`, etc.)

We cannot load .omwfx files directly. But the GLSL algorithms inside them are portable if we provide equivalent builtins.

---

## Architecture: Three-Layer Approach

### Layer 1: OpenMW Compatibility Constants & Helpers (GLSL)

A set of GLSL constants, structs, and functions that provide the same data OpenMW shaders expect, sourced from Godot's rendering pipeline and our WeatherManager.

Since Godot compute shaders (`#version 450`) don't support `#include`, these are embedded directly in each compute shader that needs them. A reference file `src/core/shaders/omw_reference.glsl` documents the full mapping for porters.

**OpenMW Builtin → Godot Mapping:**

| OpenMW Builtin | Type | Godot Equivalent | Delivery Method |
|----------------|------|------------------|-----------------|
| `omw.eyePos` | vec3 | Camera position | Push constant |
| `omw.eyeVec` | vec3 | Camera forward | Derived from inv_view |
| `omw.sunPos` | vec3 | Sun direction (normalized) | Push constant from DirectionalLight3D |
| `omw.sunColor` | vec3 | Sun light color | Push constant from DirectionalLight3D |
| `omw.sunVis` | float | Sun visibility (0-1) | Push constant (1.0 exterior, 0.0 interior) |
| `omw.fogColor` | vec4 | Weather fog color | Push constant from WeatherResult |
| `omw.fogNear` | float | Fog start distance | Push constant (fog_params.z) |
| `omw.fogFar` | float | Fog end distance | Push constant (fog_params.w) |
| `omw.far` | float | Camera far plane | From projection matrix |
| `omw.viewMatrix` | mat4 | View matrix | Push constant (inv computed) |
| `omw.projectionMatrix` | mat4 | Projection matrix | Push constant (inv computed) |
| `omw.rcpResolution` | vec2 | 1.0 / viewport size | Derived from resolution push constant |
| `omw.resolution` | vec2 | Viewport size | Push constant |
| `omw.simulationTime` | float | Time in seconds | Push constant (Time.get_ticks_msec() / 1000.0) |
| `omw.gameHour` | float | Game hour (0-24) | Push constant from WeatherManager |
| `omw.weatherID` | int | Current weather type (0-9) | Push constant from WeatherManager |
| `omw.nextWeatherID` | int | Next weather type | Push constant from WeatherManager |
| `omw.weatherTransition` | float | Transition factor (0-1) | Push constant from WeatherManager |
| `omw.isInterior` | bool | Interior cell flag | Push constant (future) |
| `omw.isUnderwater` | bool | Camera underwater flag | Push constant (future) |
| `omw.waterHeight` | float | Water surface Y | Push constant from OceanManager |
| `omw.skyColor` | vec3 | Sky color | Push constant from WeatherResult |

**OpenMW Functions → Godot Equivalents:**

| OpenMW Function | Godot Equivalent |
|----------------|------------------|
| `omw_GetDepth(uv)` | `texture(depth_texture, uv).r` |
| `omw_GetLinearDepth(uv)` | Reconstruct from depth + inv matrices |
| `omw_GetWorldPosFromUV(uv)` | `get_world_position(uv, depth)` via inv_projection * inv_view |
| `omw_GetLastShader(uv)` | `imageLoad(color_image, pixel_coords)` or previous RT texture |
| `omw_Texture2D(sampler, uv)` | `texture(sampler, uv)` |
| `omw_Texture3D(sampler, uvw)` | `texture(sampler, uvw)` |
| `omw_GetPointLightCount()` | Not available in compute — pass as uniform array (future) |
| `omw_GetPointLightWorldPos(i)` | Not available — pass as uniform array (future) |

**Weather Modifier Tables (from VAIO):**

These are pure data arrays that live as GLSL constants in the shader:

```glsl
// Fog density multiplier per weather type
const float FOG_WEATHER_MODIFIERS[10] = float[10](
    1.00, 1.12, 2.30, 1.15, 1.70, 1.45, 1.25, 0.80, 1.12, 2.50
);

// Height fog multiplier per weather type
const float FOG_HEIGHT_MODIFIERS[10] = float[10](
    1.0, 1.2, 3.5, 1.4, 2.0, 2.5, 1.8, 2.0, 1.5, 3.0
);

// Sun scatter reduction per weather type
const float SCATTER_MODIFIERS[10] = float[10](
    1.0, 0.7, 0.2, 0.3, 0.3, 0.15, 0.1, 0.05, 0.4, 0.1
);

// Time-of-day fog adjustment
const float TIME_FOG_MODIFIERS[4] = float[4](
    1.3, 1.0, 1.2, 1.1  // pre-sunrise, day, sunset, night
);
```

Helper to blend between weather types during transitions:
```glsl
float get_weather_modifier(in float[10] modifiers) {
    int current = clamp(int(weather_params.x), 0, 9);
    int next = clamp(int(weather_params.y), 0, 9);
    float transition = weather_params.z;
    return mix(modifiers[current], modifiers[next], transition);
}
```

---

### Layer 2: CompositorEffect Pipeline (GDScript + Compute GLSL)

Each OpenMW render pass becomes a separate Godot `CompositorEffect` subclass.

**How OpenMW multi-pass works:**
```
technique {
    passes = skyTransmittance, sky, fog, lights, combine
}
render_target RT_SkyTransmittance { ... }
render_target RT_Sky { ... }
// Each pass reads previous RT, writes to its own RT
// Final "combine" pass composites everything onto the frame
```

**How Godot replicates this:**

Each pass = one `CompositorEffect` (subclass of our `PostProcessEffect`):
1. `SkyTransmittanceEffect` — computes atmospheric scattering LUT → writes to internal texture
2. `SkyEffect` — renders sky using LUT → writes to internal texture
3. `VolumetricFogEffect` — ray marches fog (reads sky texture) → writes to color buffer
4. `LightsEffect` — accumulates point light glow → writes to internal texture
5. `CombineEffect` — composites all layers onto final frame

**Ordering:** CompositorEffects have `render_priority` (integer). Lower = earlier. Set them in sequence:
```gdscript
sky_transmittance_effect.render_priority = 5
sky_effect.render_priority = 6
fog_effect.render_priority = 10
lights_effect.render_priority = 11
combine_effect.render_priority = 15
```

**Texture passing between effects:** Each effect creates an internal `RenderTexture` (via `RenderingDevice.texture_create()`). Subsequent effects receive RIDs of previous textures through shared state or a registry. The `ShaderManager` can mediate this:

```gdscript
# In shader_manager.gd
var _shared_textures: Dictionary = {}  # "sky_transmittance" → RID

func set_shared_texture(name: String, rid: RID) -> void:
    _shared_textures[name] = rid

func get_shared_texture(name: String) -> RID:
    return _shared_textures.get(name, RID())
```

Each effect writes: `ShaderManager.set_shared_texture("fog_output", my_texture_rid)`
Next effect reads: `var fog_tex: RID = ShaderManager.get_shared_texture("fog_output")`

---

### Layer 3: Weather Bridge (GDScript)

`WeatherManager` data flows into the compute shaders via cached push constants.

**Data flow:**
```
WeatherManager._process()          [main thread, every frame]
  → weather_updated signal
  → WeatherResult (interpolated colors, fog depth, wind, etc.)

ShaderManager._process()           [main thread, every frame]
  → calls VolumetricFogEffect.update_weather_cache()
  → caches weather_id, fog_color, game_hour, etc.

VolumetricFogEffect._render_callback()  [render thread]
  → reads cached values
  → packs into push constants
  → dispatches compute shader
```

**Thread safety:** Weather data is cached on the main thread via `update_weather_cache()` called from `ShaderManager._process()`. The render thread only reads the cached values. This avoids data races from accessing autoloads on the render thread.

**Push constant budget:** Currently 240 bytes / 256 byte limit. If more fields needed (point lights, interior flags), move weather tables to a Uniform Buffer Object (UBO) instead of push constants.

---

## What's Already Done

| Component | Status | File |
|-----------|--------|------|
| Compute fog shader with VAIO ray marching | Working | `src/core/shaders/compute/volumetric_fog.glsl` |
| Weather modifier tables in shader | Done | Same file — FOG_WEATHER_MODIFIERS, FOG_HEIGHT_MODIFIERS, SCATTER_MODIFIERS, TIME_FOG_MODIFIERS |
| Weather bridge (cached push constants) | Done | `src/core/shaders/effects/volumetric_fog_effect.gd` |
| Thread-safe weather caching | Done | `update_weather_cache()` called from `shader_manager.gd._process()` |
| Dynamic sun direction | Done | `set_sun()` on VolumetricFogEffect |
| Y-up coordinate conversion | Done | All `.z` height refs → `.y`, `ray_pos.xy` → `ray_pos.xz` |
| Native Godot fog (depth + height + volumetric) | Done | Weather-driven via `weather_renderer.gd` |
| Per-weather fog parameters (10 types) | Done | `weather_data.gd` + `weather_types.gd` |
| Fog interpolation (weather-to-weather + time-of-day) | Done | `weather_interpolator.gd` |
| Fog test scene with terrain | Done | `tests/visual/test_fog.tscn` |
| **Godrays compute shader (4-pass)** | **Done** | `src/core/shaders/compute/godrays.glsl` |
| **GodraysEffect CompositorEffect** | **Done** | `src/core/shaders/effects/godrays_effect.gd` |
| **Shared texture registry** | **Done** | `shader_manager.gd` — `set/get_shared_texture()` |
| **Shader porting guide** | **Done** | `docs/SHADER_PORTING.md` |
| **Sky transmittance LUT** | **Done** | `src/core/shaders/compute/sky_transmittance.glsl`, `src/core/shaders/effects/sky_transmittance_effect.gd` |
| **Fog transmittance integration** | **Done** | `volumetric_fog.glsl` binding 4, `volumetric_fog_effect.gd` shared texture lookup |

---

## What's Next — Implementation Roadmap

### Phase 1: Documentation & Reference — DONE

Created `docs/SHADER_PORTING.md` — community-facing guide:
- Step-by-step: how to take a .omwfx file and port it to Godotwind
- Which parts of .omwfx are DSL (not portable) vs GLSL (portable)
- Push constant struct layout
- How to register a new effect in ShaderManager

### Phase 2: Godrays CompositorEffect — DONE

Ported Rafael's `godrays.omwfx` as the second CompositorEffect.

**Implementation:**
- Single compute shader (`godrays.glsl`) with 4 kernels selected by `pass_id` push constant
- Pass 0 (Sky Mask): 2x2 supersampled depth → binary sky mask (half res)
- Pass 1 (Radial Blur): 5-tap Gaussian along radial from sun (half res)
- Pass 2 (Rays): N-iteration sampling toward sun with blue noise dithering (half res)
- Pass 3 (Combine): Tangent blur upscaling + sun disc + horizon clipping (full res)
- 4 dispatches with implicit barriers (compute_list_begin/end pairs)
- CPU-side sun screen position projection from DirectionalLight3D
- Per-pixel horizon clipping via `to_world()` reconstruction
- Weather-aware sun occlusion (10 weather types)
- 15 configurable parameters (ray strength, disc brightness, etc.)
- Push constants: 192 bytes (under 256 limit)

**Files:** `src/core/shaders/compute/godrays.glsl`, `src/core/shaders/effects/godrays_effect.gd`

### Phase 3: Shared Texture Registry — DONE

Added `_shared_textures` dictionary to `ShaderManager`:
- `set_shared_texture(name, rid)` / `get_shared_texture(name) -> RID`
- `clear_shared_texture(name)` / `clear_all_shared_textures()`
- Weather cache loop now covers both fog and godrays effects

This enables VAIO's multi-pass pattern where RT_Fog reads RT_Sky output.

### Phase 4: Sky Transmittance Effect — DONE

Ported VAIO's Bruneton/Neyret transmittance LUT as a compute shader.

**Implementation:**
- Compute shader (`sky_transmittance.glsl`) generates 256x64 LUT
- U = cos(zenith) * 0.5 + 0.5, V = normalized altitude (0=surface, 1=atmosphere top)
- 32-step integration through atmosphere with Rayleigh + Mie + ozone extinction
- Per-weather aerosol density tables (10 weather types with base density + height scale)
- Per-weather sun tint (ashstorm = brown, blight = red, snow = cool blue)
- LUT regenerated only when weather changes (dirty flag detection)
- Registered as shared texture "sky_transmittance" via ShaderManager
- render_priority = 5 (runs before fog=10 and godrays=11)
- Volumetric fog reads the LUT at binding 4 for physically-correct sun scattering tint
- Graceful fallback: fog uses default warm tint when LUT not available

**Files:** `src/core/shaders/compute/sky_transmittance.glsl`, `src/core/shaders/effects/sky_transmittance_effect.gd`

### Phase 5: Point Light Glow (2-3 hours)

Port VAIO's `RT_Lights` pass:
- Gather visible point lights from the scene
- Pass positions + radii + colors as a UBO (not push constants — too many)
- Compute per-pixel glow accumulation
- Light radius expansion in foggier conditions

Requires a GDScript system to collect DirectionalLight3D and OmniLight3D positions each frame and upload to GPU.

### Phase 6: Underwater Effects — DIVE (4-6 hours)

Port Rafael's `DIVE.omwfx`:
- Volumetric caustics (Perlin/Voronoi pattern, depth-dependent)
- Underwater light shafts (3 concentric shell layers)
- Underwater fog with 3D noise (similar to VAIO surface fog)
- Backscattering effect (blue tint from sub-surface light)
- Phytoplankton particles (low-intensity green organic tint)

---

## Coordinate System Conversion

**Critical:** OpenMW is Z-up, Godot is Y-up. Every .omwfx shader uses `.z` for height. When porting:

| Operation | OpenMW (Z-up) | Godot (Y-up) |
|-----------|---------------|--------------|
| Height of position | `pos.z` | `pos.y` |
| Horizontal plane | `pos.xy` | `pos.xz` |
| Height in noise UV | `ray_pos.zz` | `ray_pos.yy` |
| Noise 3D height axis | `animated_pos.z *= -1.17` | `animated_pos.y *= -1.17` |
| Valley check | `distance.z < 0` | `distance.y < 0` |

---

## .omwfx Format Reference

For porters who need to extract GLSL from .omwfx files:

```
// .omwfx structure (NOT GLSL — this is OpenMW's DSL)

// 1. Uniform declarations
uniform_float uFogDensity { default = 0.0007; min = 0.0; max = 0.01; }

// 2. Render target declarations
render_target RT_Fog { width_ratio = 1.0; height_ratio = 1.0; }

// 3. Technique declaration
technique {
    description = "Volumetric Fog";
    passes = fog, combine;
    version = "1.0";
}

// 4. Fragment shader (THIS is the portable GLSL)
fragment fog {
    omw_In vec2 omw_TexCoord;
    void main() {
        // ... actual fog algorithm ...
        omw_FragColor = vec4(result, 1.0);
    }
}

// 5. Vertex shader (usually trivial fullscreen quad)
vertex fog {
    omw_Out vec2 omw_TexCoord;
    void main() {
        omw_Position = vec4(omw_Vertex, 1.0);
        omw_TexCoord = omw_Vertex.xy * 0.5 + 0.5;
    }
}
```

**What to extract:** The `fragment` block contents. Replace `omw_` prefixed variables with Godot equivalents per the mapping table above. The `vertex` block is usually a fullscreen quad — in Godot compute shaders, this is replaced by `gl_GlobalInvocationID`.

**What to discard:** The `uniform_*` declarations (become push constants or registered parameters in GDScript), `render_target` declarations (become `RenderingDevice.texture_create()` calls), `technique`/`passes` (become CompositorEffect ordering).

---

## VAIO Shader Components (Rafael's Shader Pack)

Located at: `inspos/RafaelsShaderPack/Shaders/`

| File | Lines | What It Does | Priority |
|------|-------|-------------|----------|
| `VAIO.omwfx` | ~1700 | Atmospheric scattering + volumetric fog + sky + lights | High (fog already ported) |
| `godrays.omwfx` | ~400 | Screen-space radial god rays with blue noise dithering | High (next to port) |
| `DIVE.omwfx` | ~600 | Underwater volumetric effects (caustics, light shafts) | Medium (after ocean integration) |
| `wetworld.omwfx` | ~300 | Rain puddles, snow accumulation, surface wetness | Medium (after weather system) |
| `HBAO.omwfx` | ~200 | Horizon-based ambient occlusion | Low (Godot has native SSAO) |
| `tonemap.omwfx` | ~150 | Tone mapping / color correction | Low (Godot has native) |
| `SMAA.omwfx` | ~200 | Anti-aliasing | Low (Godot has TAA/FXAA) |
| `SMB.omwfx` | ~150 | Motion blur | Low |

### VAIO Internal Pass Chain

```
Pass 1: skyTransmittance
  → Computes atmospheric extinction LUT
  → 32 ray steps from origin to atmosphere top
  → Per-weather aerosol density tables

Pass 2: sky
  → Renders sky dome using transmittance LUT
  → Rayleigh (blue sky) + Mie (sun corona) + aerosol scattering
  → Stars, moons, celestial objects

Pass 3: fog
  → 32-step ray march through fog volume
  → Dual-layer noise (3D high-freq + 2D low-freq)
  → Height-based density with weather modifiers
  → Stamp texturing for organic variation
  → Distance-based attenuation
  → Already ported to volumetric_fog.glsl

Pass 4: lights
  → Accumulates point light glow
  → Per-light falloff and fog interaction
  → Interior light multiplier

Pass 5: combine
  → Composites all passes onto final frame
  → Fog color blending with Mie scattering
  → Weather-based exposure adjustment
```

---

## Noise Textures

VAIO requires these noise textures (available in `inspos/RafaelsShaderPack/Textures/`):

| Texture | Type | Size | Usage |
|---------|------|------|-------|
| `noise3d.dds` | Texture3D | 64^3 | Primary fog volume noise |
| `perlin2d.png` | Texture2D | 256^2 | Low-frequency variation + stamping |
| `blue_noise.png` | Texture2D | 256^2 | Dithering for god rays (temporal stability) |

If textures are missing, `VolumetricFogEffect` generates procedural replacements using `FastNoiseLite` (lower quality but functional).

---

## Testing Strategy

1. **Fog test scene** (`tests/visual/test_fog.tscn`) — terrain + weather + all fog types
2. **Weather test scene** (`tests/visual/test_weather.tscn`) — Sky3D + clouds + weather cycling
3. **Per-effect visual tests** — each new CompositorEffect should have a minimal test scene
4. **A/B comparison** — screenshot OpenMW with VAIO enabled, screenshot Godotwind with same weather type, compare

**Key visual checks:**
- Height fog pools in valleys (fly to sea level)
- Fog density increases during Foggy/Blizzard weather
- Ashstorm fog is brown-tinted, Blight is red-tinted
- God rays visible on clear days (low sun angle, looking toward sun)
- Thunder flash illuminates fog volume
- Fog animates (noise movement visible over time)
- No vertical banding (would indicate wrong coordinate plane in noise sampling)
- No flashing when turning camera (temporal reprojection artifact)

---

## Known Limitations

1. **No generic .omwfx parser** — each shader must be manually ported. The compatibility layer reduces effort but doesn't automate it.
2. **Point lights not yet available** in compute shaders — requires building a light collection system.
3. **Push constant budget** — 240/256 bytes used. Additional data requires UBO migration.
4. **Single viewport only** — VR/stereo rendering loops through views but shares push constants.
5. **No interior/exterior flag** — `omw.isInterior` not yet wired (needs cell transition system).
6. **Godot's reversed-Z depth** — OpenMW uses standard depth. The depth comparison `depth < 0.0001` for sky detection accounts for this, but porters must be aware.

---

## Files Reference

| File | Purpose |
|------|---------|
| `src/core/shaders/compute/volumetric_fog.glsl` | Main fog compute shader (VAIO-derived, weather-aware) |
| `src/core/shaders/effects/volumetric_fog_effect.gd` | CompositorEffect wrapper (push constants, textures, weather cache) |
| `src/core/shaders/shader_manager.gd` | Effect registry, enable/disable, transitions, weather cache pump |
| `src/core/weather/weather_manager.gd` | Autoload — weather state machine, signals |
| `src/core/weather/weather_types.gd` | WeatherParams, WeatherResult, fog field definitions |
| `src/core/weather/weather_data.gd` | All 10 weather type definitions with fog parameters |
| `src/core/weather/weather_interpolator.gd` | Stateless time-of-day + weather blending |
| `src/core/weather/weather_renderer.gd` | Drives native Godot fog from WeatherResult |
| `tests/visual/test_fog.tscn` | Fog test scene with terrain |
| `tests/visual/test_weather.tscn` | Weather test scene (no terrain) |
| `inspos/RafaelsShaderPack/Shaders/` | Original OpenMW shaders for reference |
| `inspos/RafaelsShaderPack/Textures/` | Noise textures used by VAIO/godrays |
