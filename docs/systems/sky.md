# Sky System

## Status (2026-04)

Shipped. Sky3D addon fully replaced by a custom sky system. Drives sun/moon lights, sky shader, and atmospheric scattering. Wired into `WeatherManager` + `WeatherRenderer`; consumed by SunshineClouds2 via `get_sky_state()`.

---

## Architecture

Three components, composition (not inheritance):

- **`SkyManager`** (`src/core/sky/sky_manager.gd`) — top-level owner. Holds the single `WorldEnvironment`, sun `DirectionalLight3D`, moon `DirectionalLight3D`, and the `Sky` resource with its `ShaderMaterial` bound to `sky.gdshader`. Instances one `CelestialManager` and one `AtmosphereParams`. Exposes `get_sky_state() -> SkyState` for cloud plugins.
- **`CelestialManager`** (`src/core/sky/celestial_manager.gd`) — stateless calculator. Receives `game_hour`, outputs `sun_direction`, `moon_direction`, `moon_phase`, `star_rotation`. Modes: SIMPLE (trigonometric east-to-west arc with latitude tilt) and REALISTIC (Kepler orbital mechanics adapted from Sky3D's TimeOfDay.gd).
- **`AtmosphereParams`** (`src/core/sky/atmosphere_params.gd`) — data class. Fields: `rayleigh_coefficient`, `mie_coefficient`, `mie_anisotropy`, `ozone_coefficient`, `turbidity`, `rayleigh_scale_height`, `mie_scale_height`, `multi_scatter_factor`, `ground_albedo`. `to_shader_params()` serialises to a uniforms dict.

---

## Scattering model

Analytical **Rayleigh + Mie** scattering with a multi-scatter energy rescaling. Derived from Hillaire 2020 §5.3 — higher-order scattering approximated as an isotropic boost:

```
L_multiscatter = L_single_scatter * 1 / (1 - scatter_albedo * multi_scatter_factor)
```

`scatter_albedo` = scattering / extinction (Rayleigh ~1.0, Mie ~0.9). `multi_scatter_factor` artist-tunable 0-1, default 0.5. This prevents the too-dark sunrise / sunset sky that single-scatter Preetham suffers from, without requiring a LUT or compute-shader pipeline (keeps Compatibility renderer support open).

Shader outputs linear HDR radiance — no tonemapping in the shader. `Environment` handles tonemapping (FILMIC / ACES / AGX).

---

## Clock ownership

Single owner, no delegation:

1. `WeatherManager._process(delta)` — **owns the clock**. Advances `game_hour` internally, emits `weather_updated` signal.
2. `SkyManager.update(game_hour)` — reads the hour, calls `CelestialManager.update()`, writes shader uniforms, positions the sun/moon `DirectionalLight3D`s.
3. `WeatherRenderer.apply(result)` — drives atmospheric params from weather state (turbidity ramps with storm_fog_multiplier, Mie coefficient rises with aerosol content, `sky_manager.cloud_coverage` tracks weather result, `WeatherResult.sky_color` feeds only `fog_light_color` + `ambient_light_color`, NOT the sky dome).

No two-way coupling. No Sky3D-style "who owns time" ambiguity.

---

## Performance contract (2026-07-06)

- **Radiance process mode is `PROCESS_MODE_INCREMENTAL`** (`sky_manager.gd`, `_initialize`). QUALITY re-renders the full radiance cubemap whenever the sky material is dirtied; our uniforms change every frame, so QUALITY meant a full-quality cubemap re-render per frame — this was the "Sky toggle costs a lot" hit. Godot docs: QUALITY "should not be used if you plan on changing the sky at runtime."
- **Uniform pushes are diffed** (`_set_param`) — unchanged values don't hit the RenderingServer and don't dirty the radiance. With time paused and cirrus hidden, the sky goes fully idle.
- **Shadow-light rotation is quantized** (`shadow_update_angle_deg`, default 0.5°). The sun/moon `DirectionalLight3D` basis only updates when the celestial body has moved past the step, so directional-shadow edges are pixel-stable between steps instead of crawling every frame (the industry "discrete sun steps" pattern; Godot cannot rotationally stabilize a continuously rotating shadow frustum). The sky's visual sun disc still moves smoothly — it reads the `sun_direction` uniform, not the light node. Set to 0 to restore continuous rotation.
- **Cloud renderer selector** (Clouds tab): Off / Cheap (Skydome) / Volumetric (SunshineClouds2), default Volumetric (`weather_controls.cloud_renderer`). Volumetric renders only when selected AND (sky or weather) on, never in interiors. **Cheap** is the clayjohn volumetric-cloud-demo-v2 port (`src/core/sky/clouds/`): a compute shader marches the cloud hemisphere into an octahedral texture amortized over 64 frames, cross-blending two snapshots; the sky shader just samples it. Requires Sky ON (it lives in the sky shader). Atmosphere colors for cloud lighting come from calibration ramps in `SkyManager._compute_cloud_atmo_colors` (the demo's LUT replacement). See `docs/plans/cheap_clouds_skydome_2026_07.md`.

## SDFGI

Enabled in `SkyManager._init_environment()` (`sky_manager.gd:250-259`): 4 cascades, `Y_SCALE_75_PERCENT`, occlusion on, `bounce_feedback=0.3`, `read_sky_light=true`, normal/probe bias 1.1. See `docs/systems/lighting.md` for how SDFGI interacts with the rest of the lighting pipeline.

---

## Key files

- `src/core/sky/sky_manager.gd`
- `src/core/sky/celestial_manager.gd`
- `src/core/sky/atmosphere_params.gd`
- `src/core/sky/shaders/sky.gdshader`
- `src/core/sky/shaders/sky_common.gdshaderinc`

---

## Cross-refs

- Weather integration: `src/core/weather/weather_renderer.gd`, `src/core/weather/weather_manager.gd`
- Original design doc archived to `docs/archive/plans/sky_system_plan_2026_04_04.md`
