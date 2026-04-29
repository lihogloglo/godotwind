# OpenMW Shader Porting

How to take an OpenMW `.omwfx` post-processing shader and port it to a Godot 4.6 CompositorEffect.

For current status of what's already ported, see [`docs/systems/shaders_vaio_port.md`](../systems/shaders_vaio_port.md).

---

## The Problem

OpenMW community shaders (Rafael's VAIO, godrays, DIVE, etc.) use a custom `.omwfx` format mixing:
- **DSL** (not portable) — `render_target`, `technique`, `passes` declarations
- **Raw GLSL** (portable) — fragment/vertex shader code inside `fragment {}` and `vertex {}` blocks
- **OpenMW builtins** (need mapping) — `omw.eyePos`, `omw_GetDepth()`, etc.

You cannot load `.omwfx` files directly. Extract the GLSL algorithms, replace OpenMW builtins with Godot equivalents, wrap in a CompositorEffect.

---

## Architecture: Three Layers

### Layer 1 — Builtin compatibility (GLSL constants + helpers)

OpenMW builtins are sourced from Godot's render pipeline + WeatherManager. Godot compute shaders (`#version 450`) don't support `#include`, so the mapping is embedded in each compute shader. `src/core/shaders/omw_reference.glsl` documents the full list.

### Layer 2 — CompositorEffect pipeline (GDScript + Compute GLSL)

Each OpenMW pass becomes one `CompositorEffect` subclass of `PostProcessEffect`. Ordering uses `render_priority` (lower = earlier). Inter-effect texture passing goes through `ShaderManager.set_shared_texture(name, rid)` / `get_shared_texture(name)`.

### Layer 3 — Weather bridge (GDScript)

`WeatherManager._process()` emits `weather_updated` → `ShaderManager._process()` calls `update_weather_cache()` on each effect (main thread) → `_render_callback` reads cached values (render thread). Weather data is never read from autoloads on the render thread.

---

## Step-by-Step Port Guide

### 1. Identify the passes

Open the `.omwfx` file. Find the `technique` block:
```
technique {
    passes = stretch, blurRHalf, rays, combine;
}
```
Each pass name maps to a `fragment <name>` block containing GLSL.

### 2. Extract the GLSL

Copy contents of each `fragment <name> { ... }` block. Discard:
- `uniform_*` declarations → become push constants or registered effect parameters
- `render_target` → become `RenderingDevice.texture_create()` calls
- `sampler_2d` → become RDUniform sampler bindings
- `technique` / `passes` → become `render_priority` + multi-dispatch ordering

### 3. Replace OpenMW builtins

| OpenMW Builtin | Type | Godot Equivalent |
|---|---|---|
| `omw.eyePos` | vec3 | Push constant `camera_position.xyz` |
| `omw.eyeVec` | vec3 | Derived from inv_view |
| `omw.sunPos` | vec4 | Push constant `sun_direction.xyz` (toward sun) |
| `omw.sunColor` | vec3 | Push constant — `light_color * light_energy` |
| `omw.sunVis` | float | Push constant (0-1) |
| `omw.fogColor` | vec4 | Push constant from WeatherResult |
| `omw.fogNear` / `omw.fogFar` | float | Push constants |
| `omw.far` | float | From projection matrix |
| `omw.viewMatrix` | mat4 | `scene_data.get_cam_transform().affine_inverse()` |
| `omw.projectionMatrix` | mat4 | `scene_data.get_cam_projection()` |
| `omw.rcpResolution` / `omw.resolution` | vec2 | `1.0 / resolution` / `render_scene_buffers.get_internal_size()` |
| `omw.simulationTime` | float | `Time.get_ticks_msec() / 1000.0` |
| `omw.gameHour` | float | From WeatherManager (0-24) |
| `omw.weatherID` / `nextWeatherID` / `weatherTransition` | int / float | From WeatherManager |
| `omw.isInterior` / `isUnderwater` | bool | From cell system / OceanManager (future) |
| `omw.waterHeight` | float | From OceanManager |
| `omw.skyColor` | vec3 | From WeatherResult |

| OpenMW Function | Godot Equivalent |
|---|---|
| `omw_GetDepth(uv)` | `texture(depth_texture, uv).r` (reversed-Z: sky < 0.001) |
| `omw_GetLinearDepth(uv)` | Reconstruct: `inv_projection * vec4(uv*2-1, depth, 1)` then linearize |
| `omw_GetWorldPosFromUV(uv)` | `inv_view * inv_projection * vec4(uv*2-1, depth, 1)` |
| `omw_GetLastShader(uv)` | `imageLoad(color_image, ivec2(uv * resolution))` |
| `omw_Texture2D(sampler, uv)` | `texture(sampler, uv)` |
| `omw_FragColor` | `imageStore(color_image, pixel, color)` |
| `omw_Position` | N/A (compute uses `gl_GlobalInvocationID`) |

### 4. Convert coordinates (Z-up → Y-up)

Most common porting bug.

| Operation | OpenMW (Z-up) | Godot (Y-up) |
|---|---|---|
| Height of position | `pos.z` | `pos.y` |
| Horizontal plane | `pos.xy` | `pos.xz` |
| Height in noise UV | `ray_pos.zz` | `ray_pos.yy` |
| Noise 3D height axis | `animated_pos.z *= -1.17` | `animated_pos.y *= -1.17` |
| Valley check | `distance.z < 0` | `distance.y < 0` |
| Sun height | `omw.sunPos.z` | `sun_direction.y` |
| Camera height | `omw.eyePos.z` | `camera_position.y` |

### 5. Handle reversed-Z depth

OpenMW: standard depth (0 = near, 1 = far/sky).
Godot: reversed-Z (1 = near, 0 = far/sky).

```glsl
// OpenMW
float is_sky = step(threshold, omw_GetDepth(uv));   // depth >= 1.0
// Godot
float is_sky = step(texture(depth_texture, uv).r, 0.001);
```

### 6. Convert fragment → compute

```glsl
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (pixel.x >= int(resolution.x) || pixel.y >= int(resolution.y)) return;
    vec2 uv = (vec2(pixel) + 0.5) / resolution;
    vec4 color = imageLoad(color_image, pixel);
    // ...same algorithm...
    imageStore(color_image, pixel, result);
}
```

### 7. Create the GDScript effect

Extend `PostProcessEffect` (see `src/core/shaders/effects/godrays_effect.gd` for a complete example):

```gdscript
class_name MyEffect extends PostProcessEffect

const SHADER_PATH := "res://src/core/shaders/compute/my_shader.glsl"

func _init() -> void:
    super._init()
    effect_name = "my_effect"
    display_name = "My Effect"
    category = "Atmosphere"
    render_priority = 20
    effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
    access_resolved_color = true
    access_resolved_depth = true
    needs_depth = true

func on_effect_added() -> void:
    load_compute_shader(SHADER_PATH)

func _render_callback(effect_type: int, render_data: RenderData) -> void:
    pass  # build push constants, create uniform set, dispatch
```

Auto-discovered by `ShaderManager` from `src/core/shaders/effects/`.

### 8. Multi-pass effects

Use multiple `compute_list_begin/end` blocks with implicit barriers between them. Create internal textures with `TEXTURE_USAGE_STORAGE_BIT | TEXTURE_USAGE_SAMPLING_BIT` so they can be both written as images and read as samplers.

---

## Push constant budget

Vulkan guarantees 128 bytes; most desktop GPUs support 256. Godotwind targets D3D12 (Windows) where root constants are flexible — keep under 256 bytes. The godrays effect hit a 128-byte limit in practice and was restructured 192→128 by precomputing weather data on CPU. Volumetric fog uses 240 bytes. If you need more, move lookup tables to a UBO bound on a separate descriptor set.

---

## Weather type IDs

OpenMW and Godotwind share these indices:

| ID | Weather | Fog Density | Sun Occlusion |
|---|---|---|---|
| 0 | Clear | 1.0× | 0% |
| 1 | Cloudy | 1.12× | 25% |
| 2 | Foggy | 2.3× | 100% |
| 3 | Overcast | 1.15× | 75% |
| 4 | Rain | 1.7× | 100% |
| 5 | Thunderstorm | 1.45× | 100% |
| 6 | Ashstorm | 1.25× | 80% |
| 7 | Blight | 0.8× | 80% |
| 8 | Snow | 1.12× | 25% |
| 9 | Blizzard | 2.5× | 85% |

VAIO weather modifier tables (fog density, height, scatter, time-of-day) live as `const float ARR[10]` in each shader. Blend between current/next weather:
```glsl
float get_weather_modifier(in float[10] m) {
    int cur = clamp(int(weather_params.x), 0, 9);
    int nxt = clamp(int(weather_params.y), 0, 9);
    return mix(m[cur], m[nxt], weather_params.z);
}
```

---

## Noise textures

Available in `inspos/RafaelsShaderPack/Textures/`:

| Texture | Type | Size | Usage |
|---|---|---|---|
| `noise3d.dds` | Texture3D | 64³ | Primary fog volume noise |
| `perlin2d.png` | Texture2D | 256² | Low-frequency variation |
| `bluenoise.png` | Texture2D | 256² | Dithering (god rays) |
| `vaionoise.png` / `vaionoise3dw.dds` | 2D / 3D | — | VAIO-specific |

Effects fall back to procedural `FastNoiseLite` if textures are missing.

---

## VAIO Components Inventory (Rafael's Shader Pack)

Located at `inspos/RafaelsShaderPack/Shaders/`.

| File | Lines | What | Priority |
|---|---|---|---|
| `VAIO.omwfx` | ~1700 | Atmospheric scattering + volumetric fog + sky + lights | High |
| `godrays.omwfx` | ~400 | Screen-space radial god rays + blue noise | Shipped |
| `DIVE.omwfx` | ~600 | Underwater volumetrics + caustics | Medium |
| `wetworld.omwfx` | ~300 | Rain puddles, snow accumulation | Medium |
| `HBAO.omwfx` | ~200 | Horizon AO | Low (Godot has SSAO) |
| `tonemap.omwfx` | ~150 | Tone mapping | Low (Godot native) |
| `SMAA.omwfx` | ~200 | AA | Low (Godot has TAA/FXAA) |
| `SMB.omwfx` | ~150 | Motion blur | Low |

VAIO internal pass chain: `skyTransmittance → sky → fog → lights → combine`. Passes 1, 2, 3 ported (`sky_transmittance_effect.gd`, `volumetric_fog_effect.gd`); 4 and 5 not ported (point lights, final combine).

---

## Currently ported

| OpenMW Source | Godot Effect | Status |
|---|---|---|
| VAIO sky transmittance | `sky_transmittance_effect.gd` | Working — 256×64 Bruneton LUT, weather-aware |
| VAIO fog pass | `volumetric_fog_effect.gd` | Working — weather-aware, 24-step ray march |
| godrays.omwfx | `godrays_effect.gd` | Working — 4-pass sky mask + radial blur + rays + combine |
| VAIO lights pass | — | Not ported (point light glow) |
| DIVE.omwfx | — | Not ported (underwater) |

---

## Files Reference

| File | Purpose |
|---|---|
| `src/core/shaders/post_process_effect.gd` | Base class for all effects |
| `src/core/shaders/shader_manager.gd` | Effect registry, enable/disable, shared textures, weather cache pump |
| `src/core/shaders/effects/` | Auto-discovered effect scripts |
| `src/core/shaders/compute/` | Compute shader GLSL files |
| `src/core/weather/weather_manager.gd` | Weather state autoload |
| `src/core/weather/weather_types.gd` | WeatherParams, WeatherResult |
| `inspos/RafaelsShaderPack/` | Original OpenMW shaders + textures |

---

## Known limitations

- No generic `.omwfx` parser — each shader must be manually ported.
- Point lights not yet available in compute (would require building a light collection system).
- Single viewport only — VR/stereo rendering loops through views but shares push constants.
- `omw.isInterior` / `omw.isUnderwater` not yet wired (need cell transition / ocean integration).
- Reversed-Z depth: porters must update sky-detect comparisons (`depth >= 1.0` → `depth < 0.001`).
