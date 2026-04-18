# Porting OpenMW Shaders to Godotwind

> Reference — step-by-step guide for porting a new .omwfx shader. Pairs with [`docs/reference/openmw_shader_porting.md`](openmw_shader_porting.md) (architecture + builtin mapping) and [`docs/systems/shaders_vaio_port.md`](../systems/shaders_vaio_port.md) (current status).

How to take an OpenMW `.omwfx` post-processing shader and port it to a Godot 4.6 CompositorEffect.

---

## Quick Overview

OpenMW community shaders (Rafael's VAIO, godrays, DIVE, etc.) use a custom `.omwfx` format mixing:
- **DSL** (not portable) — `render_target`, `technique`, `passes` declarations
- **Raw GLSL** (portable) — fragment/vertex shader code inside `fragment {}` and `vertex {}` blocks
- **OpenMW builtins** (need mapping) — `omw.eyePos`, `omw_GetDepth()`, etc.

**You cannot load .omwfx files directly.** Extract the GLSL algorithms, replace OpenMW builtins with Godot equivalents, and wrap in a CompositorEffect.

---

## Step-by-Step Porting Guide

### 1. Identify the Passes

Open the `.omwfx` file. Find the `technique` block at the bottom:
```
technique {
    passes = stretch, blurRHalf, rays, combine;
}
```

Each pass name corresponds to a `fragment <name>` block containing the GLSL algorithm.

### 2. Extract the GLSL

Copy the contents of each `fragment <name> { ... }` block. These are standard GLSL fragment shaders. Ignore:
- `uniform_float`, `uniform_bool`, `uniform_int` — become push constants or effect parameters
- `render_target` — become `RenderingDevice.texture_create()` calls
- `sampler_2d` — become RDUniform sampler bindings
- `technique` — becomes CompositorEffect render_priority ordering

### 3. Replace OpenMW Builtins

| OpenMW Builtin | Type | Godot Equivalent | Notes |
|---|---|---|---|
| `omw.eyePos` | vec3 | Push constant `camera_position.xyz` | Camera world position |
| `omw.eyeVec` | vec3 | Push constant or derived from inv_view | Camera forward direction |
| `omw.sunPos` | vec4 | Push constant `sun_direction.xyz` | Direction TOWARD sun (not FROM) |
| `omw.sunColor` | vec3 | Push constant from DirectionalLight3D | `light_color * light_energy` |
| `omw.sunVis` | float | Push constant (0-1) | Sun visibility factor |
| `omw.fogColor` | vec4 | Push constant from WeatherResult | |
| `omw.fogNear` | float | Push constant | Fog start distance |
| `omw.fogFar` | float | Push constant | Fog end distance |
| `omw.far` | float | From projection matrix | Camera far plane |
| `omw.viewMatrix` | mat4 | `scene_data.get_cam_transform().affine_inverse()` | |
| `omw.projectionMatrix` | mat4 | `scene_data.get_cam_projection()` | |
| `omw.rcpResolution` | vec2 | `1.0 / resolution` | |
| `omw.resolution` | vec2 | `render_scene_buffers.get_internal_size()` | |
| `omw.simulationTime` | float | `Time.get_ticks_msec() / 1000.0` | |
| `omw.gameHour` | float | From WeatherManager | 0-24 game time |
| `omw.weatherID` | int | From WeatherManager | 0-9 weather type |
| `omw.nextWeatherID` | int | From WeatherManager | Transition target |
| `omw.weatherTransition` | float | From WeatherManager | 0-1 blend factor |
| `omw.isInterior` | bool | From cell system (future) | |
| `omw.isUnderwater` | bool | From OceanManager (future) | |
| `omw.waterHeight` | float | From OceanManager | Water surface Y |
| `omw.skyColor` | vec3 | From WeatherResult | |

| OpenMW Function | Godot Equivalent |
|---|---|
| `omw_GetDepth(uv)` | `texture(depth_texture, uv).r` — **reversed-Z**: sky < 0.001 |
| `omw_GetLinearDepth(uv)` | Reconstruct: `inv_projection * vec4(uv*2-1, depth, 1)` then linearize |
| `omw_GetWorldPosFromUV(uv)` | `inv_view * inv_projection * vec4(uv*2-1, depth, 1)` |
| `omw_GetLastShader(uv)` | `imageLoad(color_image, ivec2(uv * resolution))` |
| `omw_Texture2D(sampler, uv)` | `texture(sampler, uv)` |
| `omw_FragColor` | `imageStore(color_image, pixel, color)` |
| `omw_Position` | N/A (compute shaders use `gl_GlobalInvocationID`) |

### 4. Convert Coordinates (Z-up → Y-up)

**This is the most common porting bug.** OpenMW uses Z-up, Godot uses Y-up.

| Operation | OpenMW (Z-up) | Godot (Y-up) |
|---|---|---|
| Height of position | `pos.z` | `pos.y` |
| Horizontal plane | `pos.xy` | `pos.xz` |
| Height in noise UV | `ray_pos.zz` | `ray_pos.yy` |
| Noise 3D height axis | `animated_pos.z` | `animated_pos.y` |
| Valley check | `distance.z < 0` | `distance.y < 0` |
| Sun height | `omw.sunPos.z` | `sun_direction.y` |
| Camera height | `omw.eyePos.z` | `camera_position.y` |
| Horizon azimuth | `toWorld().z` | `to_world().y` |

### 5. Handle Reversed-Z Depth

OpenMW uses standard depth (0 = near, 1 = far/sky).
Godot uses reversed-Z (1 = near, 0 = far/sky).

```glsl
// OpenMW: sky test
float is_sky = step(threshold, omw_GetDepth(uv));  // depth >= 1.0

// Godot: sky test (reversed-Z)
float is_sky = step(texture(depth_texture, uv).r, 0.001);  // depth < 0.001
```

### 6. Convert Fragment Shader → Compute Shader

OpenMW shaders are fragment shaders (one invocation per pixel). Godot CompositorEffects use compute shaders.

**Fragment shader pattern:**
```glsl
omw_In vec2 omw_TexCoord;
void main() {
    vec2 uv = omw_TexCoord;
    vec4 color = omw_GetLastShader(uv);
    // ... process ...
    omw_FragColor = result;
}
```

**Compute shader equivalent:**
```glsl
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (pixel.x >= int(resolution.x) || pixel.y >= int(resolution.y))
        return;
    
    vec2 uv = (vec2(pixel) + 0.5) / resolution;
    vec4 color = imageLoad(color_image, pixel);
    // ... process (same algorithm) ...
    imageStore(color_image, pixel, result);
}
```

### 7. Create the GDScript Effect

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
    _define_parameters()

func on_effect_added() -> void:
    load_compute_shader(SHADER_PATH)

func _render_callback(effect_type: int, render_data: RenderData) -> void:
    # Build push constants, create uniform set, dispatch compute
    pass
```

The effect is auto-discovered by `ShaderManager` from `src/core/shaders/effects/`.

### 8. Multi-Pass Effects

For effects with multiple passes (like godrays), use multiple `compute_list_begin/end` blocks with barrier between them:

```gdscript
# Pass 1
var cl := rd.compute_list_begin()
rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
rd.compute_list_bind_uniform_set(cl, uniform_set_pass1, 0)
rd.compute_list_set_push_constant(cl, pc_bytes, pc_size)
rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
rd.compute_list_end()  # implicit barrier
rd.free_rid(uniform_set_pass1)

# Pass 2 (reads pass 1 output)
cl = rd.compute_list_begin()
# ... same pattern with pass 2 uniform set
rd.compute_list_end()
```

Create internal textures with `TEXTURE_USAGE_STORAGE_BIT | TEXTURE_USAGE_SAMPLING_BIT` so they can be both written as images and read as samplers.

---

## Weather Type IDs

Both OpenMW and Godotwind use the same weather type indices:

| ID | Weather | Fog Density | Sun Occlusion |
|---|---|---|---|
| 0 | Clear | 1.0x | 0% |
| 1 | Cloudy | 1.12x | 25% |
| 2 | Foggy | 2.3x | 100% |
| 3 | Overcast | 1.15x | 75% |
| 4 | Rain | 1.7x | 100% |
| 5 | Thunderstorm | 1.45x | 100% |
| 6 | Ashstorm | 1.25x | 80% |
| 7 | Blight | 0.8x | 80% |
| 8 | Snow | 1.12x | 25% |
| 9 | Blizzard | 2.5x | 85% |

---

## Push Constant Budget

Vulkan guarantees 128 bytes of push constants. Most desktop GPUs support 256 bytes. Godotwind targets D3D12 (Windows) where root constants are flexible, but keep under 256 bytes for portability. **Note:** The godrays effect hit a 128-byte limit in practice (possibly driver/platform-specific) and was restructured from 192→128 bytes by precomputing weather data on CPU. The volumetric fog effect uses 240 bytes without issues on the same hardware.

If you need more data, move lookup tables to a Uniform Buffer Object (UBO) bound as a separate descriptor set.

---

## Noise Textures

Available in `inspos/RafaelsShaderPack/Textures/`:

| Texture | Type | Size | Usage |
|---|---|---|---|
| `noise3d.dds` | Texture3D | 64³ | Primary fog volume noise |
| `perlin2d.png` | Texture2D | 256² | Low-frequency variation |
| `bluenoise.png` | Texture2D | 256² | Dithering (god rays) |
| `vaionoise.png` | Texture2D | — | VAIO-specific noise |
| `vaionoise3dw.dds` | Texture3D | — | VAIO weather noise |

If textures are missing, effects generate procedural fallbacks via `FastNoiseLite`.

---

## Existing Ported Effects

| OpenMW Source | Godot Effect | Status |
|---|---|---|
| VAIO fog pass | `volumetric_fog_effect.gd` | Working — weather-aware, 24-step ray march |
| godrays.omwfx | `godrays_effect.gd` | Working — 4-pass sky mask + radial blur + rays + combine |
| VAIO sky transmittance | `sky_transmittance_effect.gd` | Working — 256x64 Bruneton LUT, weather-aware, feeds fog |
| VAIO lights pass | Not ported | Phase 5 — point light glow |
| DIVE.omwfx | Not ported | Phase 6 — underwater effects |

---

## Files Reference

| File | Purpose |
|---|---|
| `src/core/shaders/post_process_effect.gd` | Base class for all effects |
| `src/core/shaders/shader_manager.gd` | Effect registry, enable/disable, shared textures |
| `src/core/shaders/effects/` | Auto-discovered effect scripts |
| `src/core/shaders/compute/` | Compute shader GLSL files |
| `src/core/weather/weather_manager.gd` | Weather state autoload |
| `src/core/weather/weather_types.gd` | WeatherParams, WeatherResult |
| `docs/reference/openmw_shader_porting.md` | Full architecture reference + builtin mapping |
| `docs/systems/shaders_vaio_port.md` | Current status — what's ported |
