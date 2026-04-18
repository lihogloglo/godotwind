# Shaders — OpenMW / VAIO Port

Current state of Godotwind's OpenMW-to-Godot shader port infrastructure. For the architecture + builtin-mapping reference, see [`docs/reference/openmw_shader_porting.md`](../reference/openmw_shader_porting.md). For the step-by-step guide to port a new `.omwfx` shader, see [`docs/reference/openmw_shader_porting_howto.md`](../reference/openmw_shader_porting_howto.md).

---

## Status (2026-04-18)

**Ported and shipped:**
- **VAIO fog** — volumetric ray-marched fog with weather-aware density tables, height modifiers, and per-weather tinting (ashstorm/blight/blizzard).
- **Godrays** — Rafael's screen-space radial god rays (4-pass: sky mask, radial blur, ray accumulation, combine) with blue-noise dithering and weather-aware sun occlusion.
- **Sky transmittance LUT** — Bruneton/Neyret atmospheric extinction LUT (256×64) with per-weather aerosol density + sun tint; feeds the fog effect for physically-correct sun scattering color.
- **Shared-texture registry** — `ShaderManager` mediates cross-effect texture passing (e.g. fog reads the sky LUT).
- **Weather bridge** — `WeatherManager` state flows through cached push constants to every compute shader, thread-safe via main-thread cache pump.

**Not ported:**
- **VAIO point-light glow pass** (`RT_Lights`) — requires a light-collection system feeding a UBO. Partial scaffolding exists in `light_glow_effect.gd` / `light_glow.glsl`, not wired.
- **DIVE underwater effects** — caustics, underwater light shafts, backscattering, phytoplankton. Partial scaffolding exists in `underwater_compositor_effect.gd` / `underwater.glsl`, not at VAIO-DIVE parity.
- **wetworld, HBAO, tonemap, SMAA, SMB** — lower priority; Godot has native equivalents for most.

---

## Shipped Files

**CompositorEffect wrappers** (GDScript, extend `PostProcessEffect`):
- `src/core/shaders/effects/volumetric_fog_effect.gd`
- `src/core/shaders/effects/godrays_effect.gd`
- `src/core/shaders/effects/sky_transmittance_effect.gd`

**Compute shaders** (GLSL `#version 450`):
- `src/core/shaders/compute/volumetric_fog.glsl`
- `src/core/shaders/compute/godrays.glsl`
- `src/core/shaders/compute/sky_transmittance.glsl`

**Infrastructure:**
- `src/core/shaders/post_process_effect.gd` — base class for all compositor effects.
- `src/core/shaders/shader_manager.gd` — autoload registry, enable/disable, weather-cache pump, shared-texture registry.

---

## Shared-Texture Registry

OpenMW's `.omwfx` render pipelines chain passes together — a later pass reads the previous pass's render target. Godot `CompositorEffect`s don't natively share textures, so `ShaderManager` acts as the broker: each effect registers its output RID under a string key, and downstream effects look it up.

Public API in `src/core/shaders/shader_manager.gd`:

```gdscript
ShaderManager.set_shared_texture(name: String, rid: RID) -> void
ShaderManager.get_shared_texture(name: String) -> RID     # returns RID() if missing
ShaderManager.clear_shared_texture(name: String) -> void
ShaderManager.clear_all_shared_textures() -> void
```

Canonical use: `SkyTransmittanceEffect` (render_priority 5) writes the LUT under `"sky_transmittance"`; `VolumetricFogEffect` (priority 10) reads it at binding 4 for per-weather sun scattering tint. Effects fall back gracefully when a shared texture is missing (fog uses a default warm tint).

---

## Weather Data Flow

Weather state lives in the `WeatherManager` autoload. Each frame:

1. `WeatherManager._process()` advances weather state + emits `weather_updated` with an interpolated `WeatherResult` (fog colors, sky color, wind, game hour, weather IDs, transition factor).
2. `ShaderManager._process()` (main thread) calls `update_weather_cache()` on every registered effect, caching all needed fields into the effect instance.
3. `_render_callback()` (render thread) reads the cached values, packs them into a push-constant struct, and dispatches the compute shader.

Main-thread caching is load-bearing — the render thread must never touch autoloads directly. Push-constant budget is 240/256 bytes for fog, 128 bytes for godrays; additional fields require migration to a UBO.
