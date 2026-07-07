# TCA Weather System Audit - 2026-05-11

Scope: docs-only audit of
`https://github.com/kS222138/TCA_Weather_System` for ideas worth adapting into
Godotwind. No runtime code was changed for this audit.

## Sources Read

TCA Weather System:

- Repository HEAD: `42e9d4f5d56c1103a75071cf5e83dadf414fd4a8`
  (`2026-04-24`, "Update README to v1.4.0").
- `README.md`
- `LICENSE`
- `addons/TCA_Weather_System/plugin.cfg`
- `addons/TCA_Weather_System/weather_controller.tscn`
- `addons/TCA_Weather_System/scripts/EnvironmentManager.gd`
- `addons/TCA_Weather_System/scripts/WeatherController.gd`
- `addons/TCA_Weather_System/scripts/WeatherResource.gd`
- `addons/TCA_Weather_System/scripts/SeasonResource.gd`
- `addons/TCA_Weather_System/scripts/WeatherOccurrenceResource.gd`
- `addons/TCA_Weather_System/scripts/PrecipitationResource.gd`
- `addons/TCA_Weather_System/scripts/weather_forecast.gd`
- `addons/TCA_Weather_System/scripts/weather_transition.gd`
- `addons/TCA_Weather_System/scripts/wind_controller.gd`
- `addons/TCA_Weather_System/scripts/cloud_driver.gd`
- `addons/TCA_Weather_System/scripts/VegetationWindDriver.gd`
- `addons/TCA_Weather_System/scripts/performance_controller.gd`
- `addons/TCA_Weather_System/scripts/WetnessController.gd`
- `addons/TCA_Weather_System/shaders/weather_system_sky.gdshader`
- `addons/TCA_Weather_System/shaders/clouds_volume.gdshader`
- `addons/TCA_Weather_System/shaders/tca_water_shader.gdshader`
- `addons/TCA_Weather_System/shaders/fog.gdshader`
- `addons/TCA_Weather_System/shaders/wetness_effect.gdshader`
- `addons/TCA_Weather_System/weather/*.tres`
- `addons/TCA_Weather_System/seasons/*.tres`
- `addons/TCA_Weather_System/precipitation/*.tres`
- `addons/TCA_Weather_System/particles/*.tscn`
- `addons/TCA_Weather_System/presets/*.tres`

Godotwind:

- `docs/STATUS.md`
- `docs/systems/sky.md`
- `docs/systems/ocean/architecture.md`
- `docs/systems/shaders_vaio_port.md`
- `docs/systems/lighting.md`
- `docs/plans/wetness_system.md`
- `docs/audit/wetness_screen_space_2026_05_09.md`
- `docs/audit/ocean_shader_performance_audit_2026_05_10.md`
- `src/core/weather/*.gd`
- `src/core/sky/*.gd`
- `src/tools/ui/weather_controls.gd`

Godot 4.6 official docs:

- Global shader uniforms:
  https://docs.godotengine.org/en/4.6/tutorials/shaders/shader_reference/shading_language.html#global-uniforms
- `RenderingServer.global_shader_parameter_set()`:
  https://docs.godotengine.org/en/4.6/classes/class_renderingserver.html#class-renderingserver-method-global-shader-parameter-set
- `CompositorEffect` callback stages:
  https://docs.godotengine.org/en/4.6/classes/class_compositoreffect.html
- Volumetric fog:
  https://docs.godotengine.org/en/4.6/tutorials/3d/volumetric_fog.html
- GPUParticles3D particle properties:
  https://docs.godotengine.org/en/4.6/tutorials/3d/particles/properties.html
- Screen-reading shaders:
  https://docs.godotengine.org/en/4.6/tutorials/shaders/screen-reading_shaders.html

## Executive Verdict

TCA is interesting as a feature checklist and small idea mine, not as a
drop-in dependency.

The repository is MIT licensed, targets Godot 4.6+, and covers many weather
adjacent ideas Godotwind eventually wants: weather event signals, rain/snow
particles, seasonal weather resources, wind gusts, vegetation wind, quality
tiers, cloud/fog tuning, and rain-driven wetness.

The architecture does not fit Godotwind directly. TCA's main scene/plugin owns
its own `WorldEnvironment`, `DirectionalLight3D`, sky material, water material,
reflection probe, time loop, weather state, wetness, and particles. Godotwind
already has separate owners:

- `WeatherManager` owns weather state and the single game clock.
- `WeatherRenderer` applies `WeatherResult` to fog, sky, clouds, and fallback
  environment state.
- `SkyManager` owns sky, sun, moon, atmosphere, and the active
  `WorldEnvironment`.
- `OceanManager` owns the FFT water surface and `WaterSurfaceState`.
- `ShaderManager` owns compositor-effect weather cache updates and shared
  render textures.
- `WetnessManager` and waterline compositor work use the water-surface
  contract, not terrain-only or material-only guesses.

So the right move is to adapt a few patterns into the existing Godotwind
pipeline, while leaving TCA's all-in-one manager, water shader, sky replacement,
and wetness shader out.

## Maturity Notes

TCA's README describes v1.4.0 features, but the code appears uneven:

- The README lists `weather_type_changed`, `rain_intensity_changed`,
  `snow_intensity_changed`, `fog_density_changed`, and
  `wind_gust_triggered`; the inspected scripts expose broader
  `weather_changed`, `wind_changed`, `season_changed`, and `time_changed`
  signals instead.
- Some resources serialize older class/property names such as
  `DERWeatherResource`, `minDuration`, `cloudSpeed`, and `fogDensity`, while
  the scripts define `WeatherResource`, `min_duration`, `cloud_speed`, and
  `fog_density`.
- `rain_particles.gd` is a debug-style script that prints generated positions
  instead of driving the actual particle scene.
- `wetness_effect.gdshader` is a simple `ALBEDO` mix and does not implement a
  physically based wet material response.
- `tca_water_shader.gdshader` uses transparency and screen/depth assumptions
  that conflict with Godotwind's recovered opaque FFT ocean contract.

That does not make the repo useless. It does mean we should treat it like a
reference board, not trusted production code.

## Pick List

### Pick 1 - Weather event/audio bridge

Value: high.

TCA's README names the correct product-level feature: weather systems should
emit small, stable events that audio, UI, gameplay, and diagnostics can consume
without reaching into renderer internals.

Godotwind already emits `WeatherManager.weather_updated`,
`weather_changed`, `region_changed`, and `game_hour_changed`. What is missing
is a higher-level event bridge for audio/gameplay:

- weather type change with old/new IDs and names;
- rain/snow/storm intensity threshold crossings;
- thunder flash event;
- wind gust event;
- ambient/rain loop target changes from `WeatherResult`;
- optional "weather became severe" / "weather cleared" convenience events.

Implementation should not copy TCA's signal names blindly. Add a small
Godotwind-owned event bridge that reads `WeatherResult` and emits typed,
framework-level events. The Morrowind adapter can map `ambient_sound` and
`rain_sound` IDs to actual BSA audio later.

Practical effect: rain loops, storm ambience, UI labels, NPC reactions, and
quest/gameplay scripts can subscribe to weather without depending on the visual
renderer or Morrowind data structures.

### Pick 2 - Stable precipitation scaling via `amount_ratio`

Value: high.

TCA's particle scenes use `amount_ratio`. Godot's 4.6 particle docs explicitly
call out that changing `amount_ratio` while emitting does not restart already
created particles, while changing `amount` is the heavier capacity knob.

Godotwind's `WeatherParticles.update()` currently changes `amount` when
intensity changes. The next precipitation pass should allocate a quality-tier
maximum once, then drive live intensity through `amount_ratio`, material
velocity, turbulence, and emission state.

Practical effect: smoother rain/snow intensity transitions with less particle
buffer churn and less visual popping.

### Pick 3 - Wind state as a shared environment contract

Value: high.

TCA separates wind into direction, speed, gust, turbulence, and consumers. The
current Godotwind `WeatherResult` has `wind_speed` and `storm_direction`, and
`WeatherControls` maps a manual wind slider to SunshineClouds2 and OceanManager.

The Godot-standard way to broadcast wind to many shaders is global shader
uniforms. The Godot 4.6 docs explicitly position global uniforms for
environmental effects like foliage moving with wind, and
`RenderingServer.global_shader_parameter_set()` can update them at runtime
without per-material tracking.

Prefer a Godotwind `WeatherWindState` over a TCA-style material registry:

- direction as a Godot XZ vector;
- scalar speed;
- gust scalar;
- turbulence scalar/phase;
- precipitation drag factor;
- optional storm origin/direction.

`WeatherManager` or a thin `WeatherEnvironmentBridge` should set cached
values, and then push global shader uniforms once per frame when weather is
active. Materials that need wind opt in by declaring the global uniforms.

Practical effect: vegetation, cloud motion, sea spray, rain slant, ash storms,
cloth, banners, and water waves can read one wind contract instead of each
system inventing its own mapping.

### Pick 4 - Quality tiers for weather visuals

Value: medium-high.

TCA's `PerformanceController` is not a good direct import because it mutates
unrelated material parameters and auto-adjusts from `Engine.get_frames_per_second()`
alone. The useful idea is not "auto quality by FPS"; it is that weather has a
small number of artist-facing quality tiers.

Godotwind already has a benchmark/subsystem-toggle culture. Weather should
expose explicit quality profiles that map to:

- precipitation capacity and `amount_ratio` cap;
- storm particle capacity;
- SunshineClouds2 resolution/steps/blur or enabled state;
- volumetric fog length/density/detail choices;
- wetness compositor enabled/off/debug;
- waterline/rays/caustics/particulate quality when ocean integration reaches
  production;
- optional shader-global wind update rate for very low settings.

Auto quality can be considered later, but only after benchmark telemetry proves
which knobs matter. The default should be deterministic.

Practical effect: weather can be included in progressive benchmarks and main
scene tuning without surprise full-screen passes or runaway particle cost.

### Pick 5 - Resource-shaped generic weather profiles

Value: medium.

TCA models `WeatherResource`, `SeasonResource`,
`WeatherOccurrenceResource`, and `PrecipitationResource` as exported resources.
Godotwind currently hardcodes Morrowind/OpenMW weather defaults in
`WeatherData`, which is fine for the Morrowind adapter but less ideal for the
project's stated generic framework goal.

The useful adaptation is a generic weather-profile asset format, not TCA's
specific resource files. Long term, Godotwind could have:

- generic framework `WeatherProfile` resources in `src/core/weather/`;
- Morrowind adapter data that builds those profiles from MW/OpenMW defaults;
- non-Morrowind games providing their own profile resources;
- optional `SeasonProfile` resources for games that actually have seasons.

This should be deferred until weather data needs a second non-Morrowind source.
Do not refactor `WeatherData` merely because TCA has resources.

Practical effect: future data sources can plug into the weather framework
without modifying the renderer.

### Pick 6 - Cloud art-direction ideas, not the shader

Value: medium.

TCA's sky/cloud shader includes several art-direction knobs worth remembering:

- rain darkens sky and cloud tint;
- moonlight contributes to clouds at night;
- cloud shadow factor dims sky/sun contribution;
- sunrise haze is separate from generic fog;
- cloud coverage has multiple scales.

Godotwind should not replace its sky shader with TCA's shader. Godotwind already
has `SkyManager`, atmospheric scattering, and SunshineClouds2 integration.
Also, Godot sky shaders can update radiance cubemaps when time or light inputs
change, so piling animated cloud raymarching directly into the sky shader is
not the cheapest canonical path for this project.

Adapt the art knobs into `WeatherRenderer` and SunshineClouds2 resource
mapping:

- cloud ambient color from `SkyManager.SkyState`;
- rain/snow/ash cloud tint;
- weather coverage to SunshineClouds2 coverage/density/sharpness;
- night/moon ambient boost;
- cloud shadow strength as a weather/quality knob.

Practical effect: storm skies and night clouds look more intentional without
replacing the current sky architecture.

### Pick 7 - Rain wetness as a weather input to existing wetness architecture

Value: medium.

TCA has the right product instinct: rain should make exposed surfaces wet and
dry over time. Its actual wetness implementation is not usable for Godotwind.
Godotwind already has a more correct wetness plan based on the water-surface
contract, screen-space contact, retained material memory, and Lagarde-style
wet material response.

Adapt only the weather-to-wetness trigger:

- rain intensity raises a global rain wetness target;
- exposed outdoor surfaces can accumulate retained wetness;
- drying decays over time after rain stops;
- interiors and sheltered areas need an exposure mask before this becomes
  broad production behavior.

Do not add a simple terrain color overlay. Do not route rain wetness through
the ocean shore/runup code. Do not enable a full-screen wet pass by default
until the cost is benchmarked.

Practical effect: rain can eventually make the world visibly damp, but through
the existing physically grounded wetness ownership.

### Pick 8 - Forecast/next-weather API

Value: low-medium.

TCA's `WeatherForecast` is simple weighted random selection. Godotwind already
has region probabilities and weather-change timing. The useful addition is an
API that exposes "current target / next likely weather" for UI, ambience, and
save/load, not a second weather roller.

Implement later as read-only state from `WeatherManager`:

- current type;
- target type if transitioning;
- hours until next roll;
- last roll region;
- deterministic RNG seed/state once save/load is implemented.

Practical effect: UI/debug panels and gameplay can talk about weather without
forking the state machine.

## Do Not Pick

### Do not import TCA's all-in-one `EnvironmentManager`

It combines wind, weather, seasons, time, post-processing, reflection probes,
wetness, sky uniforms, water uniforms, and direct environment mutation. That is
exactly the ownership shape Godotwind has been avoiding.

Godotwind should keep state, render application, sky, water, and compositor
effects separated.

### Do not replace Godotwind's sky

Godotwind's sky system is already shipped and owns the sun/moon/atmosphere
contract. TCA's sky shader can provide art-tuning ideas, but replacing the sky
would regress clock ownership and likely compete with SunshineClouds2.

### Do not import TCA's water shader

Godotwind's ocean contract is load-bearing:

- visible FFT ocean owns the water surface look;
- current source still uses `hint_screen_texture` / `hint_depth_texture` for
  bounded surface refraction, depth-derived tint, debug views, and custom SSR;
- underwater camera medium is compositor-owned through
  `UnderwaterCompositorEffect`;
- receiver waterline is an off-by-default diagnostic/compositor path, not
  accepted production optics;
- `WaterSurfaceState` is the shared water contract.

TCA's water shader is transparent, Gerstner-based, and owns effects that belong
to Godotwind's FFT surface or compositor pipeline. It is the wrong architecture
for Godotwind. Current authority:
`docs/systems/ocean/architecture.md` and
`docs/systems/ocean/godot_4_6_water_rendering_rules.md`.

### Do not import TCA's wetness shader

It is a simple albedo color mix. Godotwind's wetness needs material roughness,
darkened porous response, exposed-contact masks, retained object memory, and
submerged-surface separation.

### Do not import the per-material vegetation registry as the final design

TCA's `VegetationWindDriver` is better than scene-tree scanning, but Godot 4.6
global shader uniforms are the more canonical solution for wind values shared
across many shaders. A registry may still be useful for one-off material
conversion or legacy materials, but the live wind state should be global.

### Do not use FPS-only auto quality as default behavior

Automatic quality changes based only on instantaneous FPS can hide regressions
and make benchmark runs noisy. Keep explicit quality tiers first. Auto quality,
if ever added, must use measured subsystem costs and hysteresis.

## Proposed Architecture

The clean target is a weather environment contract layered on top of the
existing `WeatherResult`.

```text
WeatherManager
  - owns time, region weather rolls, transitions
  - outputs WeatherResult and WeatherWindState

WeatherEventBridge
  - observes WeatherResult deltas
  - emits audio/gameplay/UI events
  - does not mutate visual systems

WeatherRenderer
  - applies fog, sky, volumetric, SunshineClouds2, fallback light
  - owns visual mapping from WeatherResult to Environment/SkyManager/clouds

WeatherShaderGlobals
  - pushes global shader uniforms for wind and precipitation exposure
  - stores cached values locally; never reads global shader params per frame

WeatherParticles
  - camera-centered GPUParticles3D emitters
  - stable max amount per quality tier
  - live intensity via amount_ratio and process material state

OceanManager / WetnessManager
  - consume WeatherResult through explicit apply methods
  - keep water/wetness contracts unchanged
```

This keeps Morrowind as one data source. Weather state remains generic, and
Morrowind-specific region probabilities, Red Mountain storm direction, and
sound IDs stay in adapter/data layers.

## Implementation Plan

### Phase 0 - Write Down The Contract

Goal: prevent another weather/sky/water ownership tangle.

Tasks:

- Add a short `docs/systems/weather.md` or update an existing weather doc with
  current owners: `WeatherManager`, `WeatherRenderer`, `WeatherParticles`,
  `SkyManager`, `OceanManager`, `WetnessManager`, and `ShaderManager`.
- Define which fields belong in `WeatherResult` versus which belong in a new
  `WeatherWindState`.
- Define which systems may mutate `Environment` properties.
- Define which systems may set global shader uniforms.
- Define which systems may add CompositorEffects.

Verification:

- Static review only for the doc.
- No scene launch required until implementation changes begin.

### Phase 1 - Weather Event Bridge

Goal: expose weather gameplay/audio events without coupling consumers to
rendering.

Suggested files:

- `src/core/weather/weather_event_bridge.gd`
- Unit tests under `tests/unit/`
- Optional integration wiring in `src/tools/ui/weather_controls.gd` or the main
  scene once accepted.

Behavior:

- Connect to `WeatherManager.weather_updated` and `weather_changed`.
- Track previous values.
- Emit thresholded events for precipitation start/stop and intensity bands.
- Emit thunder flash events when `thunder_flash` rises above a threshold.
- Emit wind gust events once Phase 2 adds gust state.
- Emit ambient/rain loop target events when `ambient_sound_id` or
  `rain_sound_id` changes.

Acceptance:

- Unit tests prove no per-frame spam while intensity stays in the same band.
- Unit tests prove start/stop/threshold crossings fire once.
- No direct reference to `WeatherRenderer`, `SkyManager`, `OceanManager`, or
  Morrowind record classes.

### Phase 2 - Wind State And Shader Globals

Goal: make wind a shared environmental contract.

Suggested files:

- Extend `WeatherTypes.WeatherResult` or add `WeatherTypes.WeatherWindState`.
- Add `src/core/weather/weather_shader_globals.gd` or a small method on
  `WeatherManager` if no separate object is needed.
- Add project shader globals in `project.godot`.

Suggested globals:

```glsl
global uniform vec4 gw_wind_xz_speed_gust;
global uniform vec4 gw_weather_params;
```

Example packing:

- `gw_wind_xz_speed_gust.xy`: normalized XZ wind direction.
- `gw_wind_xz_speed_gust.z`: speed in m/s or normalized weather speed.
- `gw_wind_xz_speed_gust.w`: gust scalar.
- `gw_weather_params.x`: rain intensity.
- `gw_weather_params.y`: snow intensity.
- `gw_weather_params.z`: storm intensity.
- `gw_weather_params.w`: wetness exposure target.

Acceptance:

- No per-material wind updates for generic global wind.
- Do not read global shader uniforms per frame; cache values in script if
  script-side reads are needed.
- Visual smoke with one simple wind-responsive material before broader
  vegetation integration.

### Phase 3 - Precipitation Rewrite Around Stable Particle Capacity

Goal: make rain/snow/storm transitions smoother and cheaper.

Suggested changes:

- Set max `amount` from a quality tier during setup or quality changes.
- Drive live intensity with `amount_ratio`.
- Keep existing camera-following emitter box.
- Add wind/gust slant from Phase 2.
- Consider TCA's `RibbonTrailMesh` rain look, but rebuild in Godotwind style.
- Add a weather-particle visual test scene if current coverage is insufficient.

Acceptance:

- Rain and snow ramp smoothly during weather transitions.
- Changing intensity does not restart the emitter every frame.
- Particle capacity changes happen only on quality-tier changes.
- Benchmark weather particles separately at low/medium/high/ultra capacities.

### Phase 4 - Weather Quality Profiles

Goal: make weather visual cost explicit and benchmarkable.

Suggested files:

- `src/core/weather/weather_quality_profile.gd`
- Optional UI mapping in `src/tools/ui/weather_controls.gd`
- Benchmark labels in existing benchmark subsystem docs/commands.

Quality knobs:

- precipitation max particles;
- storm/ash max particles;
- cloud compositor enabled and quality values;
- volumetric fog length/detail defaults;
- godray/fog pass quality when relevant;
- wetness compositor off/debug/on;
- ocean weather coupling quality for waves/spray/rays.

Acceptance:

- Profiles are deterministic.
- Progressive benchmark can report the weather tier.
- Auto quality remains off unless explicitly enabled in a later plan.

### Phase 5 - Cloud Weather Art Mapping

Goal: adapt TCA's useful sky/cloud art controls into SunshineClouds2 and
Godotwind sky state.

Suggested changes:

- Extend `WeatherRenderer._apply_sunshine_clouds()` mapping.
- Map rain/snow/ash to cloud tint and density/sharpness.
- Add moon/night ambient boost using `SkyManager.get_sky_state()`.
- Keep cloud shadow tuning as a weather/quality setting.
- Avoid adding animated cloud raymarching to `sky.gdshader`.

Acceptance:

- Clear, rain, thunderstorm, ashstorm, snow, and blizzard have distinct cloud
  mood without breaking time-of-day color.
- Night clouds remain visible but not glowing white.
- Visual verification in `tests/visual/test_weather.tscn` and main scene once
  wired.

### Phase 6 - Rain Wetness Input

Goal: let rain feed the existing wetness system without changing wetness
ownership.

Suggested changes:

- Add weather rain/snow/storm exposure inputs to `WetnessManager`.
- Start with retained wetness on opted-in objects and debug surfaces.
- Defer broad terrain/world wetness until an outdoor exposure/shelter mask
  exists.
- Keep full-screen wet compositor quality-gated.

Acceptance:

- Rain increases wetness only when weather is active and exposure allows it.
- Drying decays after rain stops.
- Submerged surfaces remain owned by underwater/waterline optics.
- Wetness remains off or quality-gated by default until benchmarked.

### Phase 7 - Optional Generic Weather Profile Resources

Goal: support non-Morrowind weather data without rewriting core weather logic.

Suggested changes:

- Define `WeatherProfile` and optional `SeasonProfile` resources in core.
- Add a loader/adapter that converts existing `WeatherData` defaults into
  profiles.
- Keep region probability lookup in the Morrowind adapter.

Acceptance:

- Morrowind behavior is unchanged.
- A fake non-Morrowind profile can drive WeatherManager in a unit/integration
  test without touching `src/core/esm/`.

## Verification Plan For Future Implementation

For docs-only work, no Godot launch is required. For future implementation:

- GDScript-only logic: run focused gdUnit tests and an interactive visual
  scene if the changed path affects rendering or gameplay.
- C# changes: run `dotnet build Godotwind.sln` before Godot launch.
- Shader changes: clear matching shader/import artifacts, run Godot `--import`,
  then launch an interactive scene. Do not use automated screenshots for visual
  acceptance.
- Weather visuals: run `tests/visual/test_weather.tscn` interactively, then
  `scenes/Godotwind.tscn` once main-scene wiring is touched.
- Ocean/wetness coupling: verify in Ocean Lab first, then main scene.
- Performance-sensitive changes: use the existing benchmark/progressive
  subsystem so weather cost is measured separately from streaming.

Useful commands:

```powershell
dotnet build Godotwind.sln
<godot-executable> --path <project-path> res://tests/visual/test_weather.tscn
<godot-executable> --path <project-path> scenes/Godotwind.tscn
```

## Recommended Priority

1. Weather event/audio bridge.
2. Wind state plus global shader uniforms.
3. Precipitation `amount_ratio` rewrite.
4. Weather quality profiles.
5. Cloud art mapping into SunshineClouds2.
6. Rain wetness input through `WetnessManager`.
7. Generic weather/season resources only when a second data source needs them.

This ordering picks the ideas with the best value-to-risk ratio first. It also
keeps every change inside Godotwind's existing ownership model instead of
letting a plugin-shaped architecture sprawl across weather, sky, water, and
post-processing.
