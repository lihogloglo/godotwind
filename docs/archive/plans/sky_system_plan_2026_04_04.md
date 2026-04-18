# GodotwindSky — Custom Sky System Plan

Replaces the Sky3D addon with a custom, framework-agnostic sky system.
This document contains everything a future agent needs to implement it.

**Status:** Plan approved (with revisions). Not yet implemented.
**Date:** 2026-04-04

---

## Table of Contents

1. [Why Replace Sky3D](#why-replace-sky3d)
2. [Architecture Decision](#architecture-decision)
3. [Current System Analysis](#current-system-analysis)
4. [New System Architecture](#new-system-architecture)
5. [Sky Shader Design](#sky-shader-design)
6. [Celestial Mechanics](#celestial-mechanics)
7. [Weather Integration](#weather-integration)
8. [Cloud Plugin Interface](#cloud-plugin-interface)
9. [Implementation Phases](#implementation-phases)
10. [Reference Implementations](#reference-implementations)
11. [Test Plan](#test-plan)
12. [Reviewer Feedback & Resolutions](#reviewer-feedback--resolutions)
13. [Open Questions Resolved](#open-questions-resolved)
14. [File Inventory](#file-inventory)

---

## 1. Why Replace Sky3D

Sky3D (TokisanGames, MIT, ~3,250 lines) is a general-purpose Godot sky addon. Godotwind
has outgrown it. We're using ~40% of its features and fighting the rest with workarounds.

### What we use from Sky3D
- Sun/moon orbital positioning (TimeOfDay.gd — excellent)
- Rayleigh/Mie sky shader (Preetham single-scatter)
- WorldEnvironment + DirectionalLight3D management
- Time-of-day clock

### What we've disabled or worked around
- **AtmFog** — permanently disabled (`environment_controls.gd:457`). Sky3D's screen-space
  fog quad (blend_mix) conflicts with Godot's depth fog. We use Godot depth fog instead.
- **Clouds** — disabled when SunshineClouds2 is active (`weather_renderer.gd:173-177`).
  Sky3D's bright cumulus bleeds through SunshineClouds2's dark overcast.
- **Fog density** — overridden by WeatherRenderer every frame via string-based `.set()`.
- **Ambient energy** — overridden by WeatherRenderer.
- **Clock** — awkward delegation: WeatherManager reads `Sky3D.current_time` when Sky3D is
  enabled, falls back to internal clock otherwise. Two code paths.
- **WorldEnvironment swap** — `on_show_sky_toggled()` is 50+ lines of add/remove/re-apply
  because only one WorldEnvironment can be active. Visual state must be reapplied on every swap.

### Sky3D's technical limitations
- **Single-scatter only** (Preetham 1999): sky goes too dark at sunrise/sunset, horizon
  band is too narrow, negative luminance at low turbidity.
- **Night sky** handled via hardcoded `atm_night_tint` constant, not physics.
- **No ozone absorption** — zenith isn't deep blue enough.
- **Cloud system** conflicts with external cloud plugins.
- **AtmFog** is a spatial shader quad that conflicts with Godot's native fog pipeline.

---

## 2. Architecture Decision

### Chosen: Analytical Sky Shader + Multi-Scatter Approximation

**NOT full LUT-based Hillaire 2020.** Rationale:
- Compute shader dependency locks out Godot's Compatibility renderer
- voithos' Godot implementation is experimental (4.4, not production-hardened)
- For ground-level open-world (not space-to-ground), analytical + multi-scatter is
  visually indistinguishable from LUT-based at typical viewing conditions
- Analytical is simpler to maintain, debug, and artist-tweak
- LUT upgrade path open for future if needed

### What we gain over Sky3D's Preetham
- Multi-scatter approximation (horizon brightness at low sun angles)
- Ozone absorption (Phase 2 — subtle deep blue at zenith)
- Single WorldEnvironment (no swap dance)
- Typed API (no string-based `.set()` calls)
- Clean clock ownership (WeatherManager always owns the clock)
- No workarounds for fog/cloud/ambient conflicts

### Atmospheric model
**Rayleigh + Mie scattering** with a multi-scatter energy boost term.

Multi-scatter technique: **Rescaled single-scatter approximation** based on Hillaire 2020
Section 5.3. The key insight is that higher-order scattering acts approximately as an
isotropic ambient term proportional to the single-scatter contribution. The approximation:

```
L_multiscatter = L_single_scatter * (1.0 / (1.0 - scatter_albedo * multi_scatter_factor))
```

Where:
- `scatter_albedo` = scattering / extinction (ratio of scattered vs absorbed light)
  For a clean atmosphere: Rayleigh albedo ~1.0, Mie albedo ~0.9
- `multi_scatter_factor` = artist-tunable 0-1 (default 0.5)

This is the "energy conservation rescaling" approach. It's not physically exact but it
correctly brightens the horizon at low sun angles and prevents the too-dark sky that plagues
single-scatter models. The formula is derived from the geometric series of successive
scattering orders: `sum(albedo^n) = 1/(1-albedo)`.

For implementation, this means after computing single-scatter Rayleigh and Mie contributions
along the view ray, multiply by the rescaling factor. The factor varies with sun zenith angle
(stronger effect at low sun = longer optical path = more scattering orders matter).

**NOT using:**
- Hosek-Wilkie (curve-fitted model, incompatible with custom Rayleigh+Mie integration)
- Full Bruneton LUT precomputation
- voithos compute shader pipeline

---

## 3. Current System Analysis

### Files that will be modified or deleted

#### Sky3D Addon (DELETE entirely — 3,250 lines)
```
addons/sky_3d/
  src/Sky3D.gd           (549 lines) — WorldEnvironment, top-level API
  src/SkyDome.gd         (1,279 lines) — Sky rendering, light management
  src/TimeOfDay.gd       (588 lines) — Clock + orbital mechanics
  src/OrbitalElements.gd (31 lines) — Data struct
  src/ScatterLib.gd      (50 lines) — Rayleigh/Mie constants (Preetham)
  src/TOD_Math.gd        (18 lines) — Math helpers
  shaders/SkyMaterial.gdshader  (520 lines) — Sky dome shader
  shaders/AtmFog.gdshader      (154 lines) — Screen-space fog (disabled)
  shaders/Common.gdshaderinc   (64 lines) — Shared shader functions
```

#### Weather System (MODIFY)
```
src/core/weather/weather_renderer.gd   (291 lines) — Replace Sky3D path with SkyManager
src/core/weather/weather_manager.gd    (~350 lines) — Remove Sky3D clock delegation
src/core/weather/weather_types.gd      (221 lines) — sky_color usage clarification
src/core/weather/weather_data.gd       (~500 lines) — No changes needed
src/core/weather/weather_interpolator.gd (~350 lines) — No changes needed
```

#### UI / Integration (MODIFY)
```
src/tools/ui/environment_controls.gd  (626 lines) — Massive simplification (remove swap)
src/tools/ui/weather_controls.gd      (~300 lines) — Update Sky3D references
src/tools/world_explorer.gd           (~1,249 lines) — Update sky initialization
tests/visual/test_weather.gd          (569 lines) — Update to use new sky
```

### Sky3D's ScatterLib.gd Constants (Reference)
These are the Preetham/Hoffman constants we'll reuse or replace:
```
Refractive index of air: n = 1.0003, n^2 = 1.00060009
Molecular density: N = 2.545e25
Depolarization factor: pn = 0.035
Wavelengths: R=680nm, G=550nm, B=440nm
Rayleigh scale height: 8.4km
Mie scale height: 1.25km
```

### Sky3D's Shader Architecture (SkyMaterial.gdshader)
The 520-line shader has these sections (useful for understanding what to replicate):
- Atmosphere scatter calculation (Rayleigh phase + HG Mie phase)
- Sun disc rendering (mask-based, configurable size)
- Moon rendering (sphere intersection + texture sampling with matrix transform)
- Star field (cubemap/panorama + scintillation)
- Cirrus clouds (2D noise — we won't replicate, SunshineClouds2 handles clouds)
- Cumulus clouds (10-step raymarch — we won't replicate)
- Celestial debug grids (we won't replicate)
- `AT_CUBEMAP_PASS` / `AT_HALF_RES_PASS` quality scaling

### Sky3D's TimeOfDay Orbital Mechanics (PRESERVE — adapt to new system)
TimeOfDay.gd (588 lines) has two modes:
- **SIMPLE**: Trigonometric east-to-west arc. Fast, configurable latitude.
- **REALISTIC**: Full Kepler orbital mechanics.
  - Sun: ecliptic longitude from orbital elements, equatorial coordinate transform
  - Moon: separate orbital elements (13+), proper ecliptic coords
  - Stars: sidereal time rotation
  - Location: latitude/longitude/UTC offset for proper azimuth/altitude

The REALISTIC mode is excellent and well-tested. We'll adapt it into `celestial_manager.gd`
rather than rewriting from scratch.

### Weather System Data Flow (Current)
```
world_explorer._process()
  → WeatherManager._process(delta)
    → if sky3d_enabled: read Sky3D.current_time (delegation!)
    → else: advance _fallback_hour
    → interpolate WeatherResult from WeatherData + game_hour
    → emit weather_updated signal
  → WeatherRenderer.apply(result)
    → if sky3d: _apply_sky3d() [string-based .set() on SkyDome]
    → else: _apply_fallback_light() [drive DirectionalLight]
    → _apply_depth_fog(env, result)
    → _apply_volumetric_fog(env, result)
    → _apply_sun_volumetric_energy(result)
    → _apply_sunshine_clouds(driver, result)
```

---

## 4. New System Architecture

### Component Overview

```
src/core/sky/
  sky_manager.gd           (~300 lines) — Top-level manager, WorldEnvironment owner
  celestial_manager.gd     (~250 lines) — Sun/moon/star positioning
  atmosphere_params.gd     (~60 lines)  — Atmospheric parameter data class
  shaders/
    sky.gdshader           (~350 lines) — Main sky shader
    sky_common.gdshaderinc (~80 lines)  — Shared scattering functions
```

### SkyManager (`sky_manager.gd`)

Top-level manager. Replaces Sky3D.gd + SkyDome.gd orchestration. Owns:
- **Single WorldEnvironment** (always in scene tree, never swapped)
- **Sun DirectionalLight3D** (positioned by CelestialManager)
- **Moon DirectionalLight3D** (positioned by CelestialManager)
- **Sky resource** with custom ShaderMaterial using `sky.gdshader`
- **CelestialManager** instance (composition, not inheritance)
- **AtmosphereParams** instance (current atmospheric state)

Public API (typed, not string-based):
```gdscript
class_name SkyManager extends Node

# Atmosphere
var atmosphere: AtmosphereParams

# State
var enabled: bool = true
var game_hour: float = 12.0  # Set by WeatherManager or external clock

# Sun/moon (read from CelestialManager, written to shader)
var sun_direction: Vector3  # read-only, set by CelestialManager
var moon_direction: Vector3 # read-only, set by CelestialManager

# Cloud integration (for sky darkening when clouds present)
var cloud_coverage: float = 0.0

# Wind (for future use — star twinkle modulation, etc.)
var wind_speed: float = 0.0

# Read-only state for cloud plugins
func get_sky_state() -> SkyState

# Direct access to owned nodes
func get_environment() -> Environment
func get_sun_light() -> DirectionalLight3D
func get_moon_light() -> DirectionalLight3D

# Update (called by world_explorer or WeatherManager)
func update(game_hour: float) -> void
```

### CelestialManager (`celestial_manager.gd`)

Adapted from Sky3D's TimeOfDay.gd. Stateless calculator — receives game_hour, outputs
directions. Does NOT own a clock.

```gdscript
class_name CelestialManager extends RefCounted

enum Mode { SIMPLE, REALISTIC }

var mode: Mode = Mode.SIMPLE
var latitude: float = 45.0   # degrees
var longitude: float = 0.0   # degrees

# Outputs (computed by update())
var sun_direction: Vector3
var sun_altitude: float       # radians, for light intensity curves
var moon_direction: Vector3
var moon_phase: float         # 0-1 (0=new, 0.5=full, 1=new)
var star_rotation: Basis      # For rotating star panorama

func update(game_hour: float, day_of_year: int = 172) -> void
```

SIMPLE mode: trigonometric arc (east→zenith→west, latitude-adjusted tilt).
REALISTIC mode: full Kepler from TimeOfDay.gd.

### AtmosphereParams (`atmosphere_params.gd`)

Data class. Framework defaults work for any open-world game. Game-specific
adapters (e.g., WeatherRenderer) modify these for weather effects.

```gdscript
class_name AtmosphereParams extends RefCounted

## Rayleigh scattering coefficient (wavelength-dependent, per-meter)
## Default: standard Earth atmosphere at sea level
var rayleigh_coefficient: Vector3 = Vector3(5.5e-6, 13.0e-6, 22.4e-6)

## Mie scattering coefficient (aerosol, wavelength-independent)
var mie_coefficient: float = 21e-6

## Henyey-Greenstein anisotropy parameter (0=isotropic, 0.76=forward scatter)
var mie_anisotropy: float = 0.76

## Ozone absorption coefficient (Chappuis band, subtle blue at zenith)
## Phase 2 addition — set to Vector3.ZERO to disable
var ozone_coefficient: Vector3 = Vector3.ZERO

## Atmospheric turbidity (1=clear mountain air, 2=clear, 5=hazy, 10=very hazy)
var turbidity: float = 2.0

## Ground albedo (affects multi-scatter ground reflection contribution)
var ground_albedo: Color = Color(0.3, 0.3, 0.3)

## Scale heights (how quickly density drops with altitude)
var rayleigh_scale_height: float = 8400.0  # meters (8.4km)
var mie_scale_height: float = 1200.0       # meters (1.2km)

## Multi-scatter strength (0=single-scatter only, 0.5=default, 1.0=maximum)
var multi_scatter_factor: float = 0.5

## Converts to shader uniforms dictionary
func to_shader_params() -> Dictionary
```

### Clock Ownership Call Chain (MUST BE CLEAR)

```
world_explorer._process(delta)
  → WeatherManager._process(delta)       # WeatherManager ALWAYS owns the clock
    → _advance_clock(delta)              # internal clock, no delegation
    → game_hour updated
    → interpolate WeatherResult
    → emit weather_updated(result)
  → SkyManager.update(WeatherManager.game_hour)  # sky reads from weather
    → CelestialManager.update(game_hour)          # computes sun/moon directions
    → _update_shader_uniforms()                   # sets sky shader params
    → _update_lights()                            # positions DirectionalLight3Ds
  → WeatherRenderer.apply(result)
    → sky_manager.atmosphere.turbidity = f(result)  # weather drives atmosphere
    → sky_manager.cloud_coverage = result.cloud_coverage
    → _apply_depth_fog(env, result)                 # fog on sky_manager's environment
    → _apply_volumetric_fog(env, result)
    → _apply_sun_volumetric_energy(result)
    → _apply_sunshine_clouds(driver, result)
```

Key: **WeatherManager owns time. SkyManager consumes time. CelestialManager computes positions.
WeatherRenderer drives atmospheric parameters.** No delegation, no two-way coupling.

### WeatherResult.sky_color Clarification

**WeatherResult.sky_color is NOT applied to the sky dome.** The sky dome color comes purely
from the scattering model, modulated by `atmosphere.turbidity` and `cloud_coverage` for
darkening. `WeatherResult.sky_color` is used ONLY for:
- `Environment.fog_light_color` (depth fog tinting)
- `Environment.ambient_light_color` (when sky IBL isn't available)
- Particle color tinting (rain/snow colored by ambient)

The physically-based sky shader IS the sky color. The MW 4-phase `sky_color` is a legacy
data source that drives fog and ambient only.

### IBL / HDR Correctness

The sky shader MUST output correct HDR radiance values in linear space. Godot's
`shader_type sky` uses the rendered sky for IBL (ambient + reflection probes).

Rules:
- Scattering output is in physical units (relative radiance). No tonemapping in the shader.
- Tonemapping is handled by the Environment resource (tonemap_mode = FILMIC/ACES/AGX).
- Sun disc must be HDR (energy >> 1.0) for proper specular reflections and glow.
- Night sky must be low but non-zero (star luminance + atmospheric glow).
- Test: place a mirror sphere in the scene, verify sky reflection matches visual sky.

---

## 5. Sky Shader Design

### `sky.gdshader` Structure

```glsl
shader_type sky;
render_mode use_debanding;

// --- Uniforms ---
// Atmosphere
uniform vec3 rayleigh_coefficient;
uniform float mie_coefficient;
uniform float mie_anisotropy;
uniform float rayleigh_scale_height;
uniform float mie_scale_height;
uniform float multi_scatter_factor;
uniform float turbidity;

// Celestials
uniform vec3 sun_direction;
uniform vec3 moon_direction;
uniform float moon_phase;        // 0-1
uniform float sun_disk_size;     // angular radius in radians
uniform float sun_energy;        // HDR multiplier
uniform sampler2D moon_texture;

// Stars
uniform sampler2D star_panorama; // equirectangular
uniform mat3 star_rotation;
uniform float star_energy;

// Ground
uniform vec3 ground_albedo;
uniform vec3 ground_color;       // below-horizon color

// Cloud darkening
uniform float cloud_coverage;    // 0-1, darkens sky behind clouds

// --- Includes ---
#include "sky_common.gdshaderinc"

// --- Main ---
void sky() {
    vec3 view_dir = EYEDIR;

    // Compute atmosphere scattering along view ray
    vec3 scatter = compute_atmosphere(view_dir, sun_direction, ...);

    // Apply multi-scatter rescaling
    float scatter_albedo = compute_scatter_albedo(rayleigh_coefficient, mie_coefficient);
    scatter *= 1.0 / (1.0 - scatter_albedo * multi_scatter_factor);

    // Render sun disc (HDR, with limb darkening)
    scatter += render_sun_disc(view_dir, sun_direction, sun_disk_size, sun_energy);

    // Render moon disc (texture + phase lighting)
    scatter += render_moon(view_dir, moon_direction, moon_phase, moon_texture);

    // Render stars (dimmed by atmospheric scatter)
    vec3 transmittance = compute_transmittance(view_dir, ...);
    scatter += render_stars(view_dir, star_panorama, star_rotation, star_energy) * transmittance;

    // Below horizon: ground color with ambient scatter
    if (view_dir.y < 0.0) {
        scatter = mix(scatter, ground_color * ground_albedo, smoothstep(0.0, -0.05, view_dir.y));
    }

    // Cloud darkening (when volumetric clouds cover the sky)
    scatter *= 1.0 - cloud_coverage * 0.3;

    COLOR = scatter;  // Linear HDR — NO tonemapping here
}
```

### `sky_common.gdshaderinc` Functions

```glsl
// Rayleigh phase function
float rayleigh_phase(float cos_theta) {
    return 0.75 * (1.0 + cos_theta * cos_theta);
}

// Henyey-Greenstein Mie phase function
float mie_phase(float cos_theta, float g) {
    float g2 = g * g;
    float denom = 1.0 + g2 - 2.0 * g * cos_theta;
    return (1.0 - g2) / (4.0 * PI * pow(denom, 1.5));
}

// Optical depth along a ray from position to top of atmosphere
// Uses Chapman function approximation for efficiency
vec2 optical_depth(vec3 pos, vec3 dir, float rayleigh_sh, float mie_sh, int steps)

// Single-scatter integration along view ray
vec3 compute_atmosphere(vec3 view_dir, vec3 sun_dir,
    vec3 rayleigh_coeff, float mie_coeff, float mie_g,
    float rayleigh_sh, float mie_sh, float turbidity)

// Transmittance from camera to top of atmosphere along direction
vec3 compute_transmittance(vec3 view_dir, ...)

// Scatter albedo (scattering / extinction)
float compute_scatter_albedo(vec3 rayleigh_coeff, float mie_coeff)

// Sun disc with limb darkening
vec3 render_sun_disc(vec3 view_dir, vec3 sun_dir, float size, float energy)

// Moon with texture and phase
vec3 render_moon(vec3 view_dir, vec3 moon_dir, float phase, sampler2D tex)

// Stars from panorama
vec3 render_stars(vec3 view_dir, sampler2D panorama, mat3 rotation, float energy)
```

### Performance Notes
- Start at **full resolution** (not `AT_HALF_RES_PASS`). The sky shader runs on cubemap
  faces, not every screen pixel. Profile before optimizing.
- Scattering integration uses ~16-32 ray steps (configurable). Sky3D uses a simplified
  analytical approximation; we use actual integration for accuracy.
- If profiling shows the sky is expensive, move scattering to `AT_HALF_RES_PASS` and keep
  sun disc + moon at full res. Note: test for edge artifacts with SunshineClouds2 compositing
  if doing this (cloud edges against upscaled sky background).

---

## 6. Celestial Mechanics

### Adapted from Sky3D's TimeOfDay.gd

The REALISTIC orbital mechanics in TimeOfDay.gd are well-implemented. Key algorithms to
preserve when adapting to `celestial_manager.gd`:

**Sun position (REALISTIC mode):**
1. Compute Julian date from game date
2. Compute orbital elements (mean anomaly, ecliptic longitude)
3. Convert ecliptic → equatorial coordinates (right ascension, declination)
4. Convert equatorial → horizontal coordinates (azimuth, altitude) using latitude/LST
5. Convert altitude/azimuth → direction vector

**Moon position (REALISTIC mode):**
1. Compute lunar orbital elements (13+ parameters)
2. Ecliptic longitude/latitude
3. Same equatorial → horizontal conversion as sun
4. Phase = dot product of moon direction with sun direction

**Star rotation:**
1. Compute Local Sidereal Time from game time + longitude
2. Build rotation matrix for star panorama

**SIMPLE mode:**
```gdscript
# Sun: east-to-west arc with latitude tilt
var sun_progress = (game_hour - 6.0) / 12.0  # 0 at sunrise, 1 at sunset
var elevation = sin(sun_progress * PI) * (90.0 - abs(latitude) * 0.4)
var azimuth = lerp(90.0, 270.0, sun_progress)
sun_direction = spherical_to_cartesian(elevation, azimuth)

# Moon: offset by ~12 hours
var moon_progress = fmod(sun_progress + 0.5, 1.0)
# ... similar calculation
```

### Light Intensity Curves

From Sky3D's SkyDome.gd — sun/moon light energy varies with altitude:
```gdscript
# Sun energy: peaks at zenith, fades at horizon, zero below
func _sun_light_energy(altitude_rad: float) -> float:
    if altitude_rad < 0.0:
        return 0.0
    return clampf(sin(altitude_rad) * 1.5, 0.0, 1.2)

# Sun color: warm at horizon, white at zenith
func _sun_light_color(altitude_rad: float) -> Color:
    var t = clampf(altitude_rad / (PI * 0.5), 0.0, 1.0)
    return Color(1.0, lerp(0.7, 0.98, t), lerp(0.4, 0.95, t))

# Moon energy: much dimmer, phase-dependent
func _moon_light_energy(altitude_rad: float, phase: float) -> float:
    if altitude_rad < 0.0:
        return 0.0
    var phase_factor = max(0.0, cos(phase * TAU))  # full moon = 1, new moon = 0
    return clampf(sin(altitude_rad) * 0.15 * phase_factor, 0.0, 0.15)
```

---

## 7. Weather Integration

### WeatherRenderer Changes

Replace the Sky3D path (`_apply_sky3d()`) with SkyManager path:

```gdscript
# BEFORE (weather_renderer.gd:155-191) — string-based, fragile:
func _apply_sky3d(sky3d: Node, result: WeatherTypes.WeatherResult) -> void:
    var sky_dome: Node = sky3d.get("sky")
    sky_dome.set("fog_density", clampf(base_fog, 0.0001, 0.01))
    sky_dome.set("fog_rayleigh_depth", ...)
    sky_dome.set("cumulus_visible", false)
    sky_dome.set("atm_darkness", ...)

# AFTER — typed, direct:
func _apply_sky(sky_manager: SkyManager, result: WeatherTypes.WeatherResult) -> void:
    # Turbidity: clear=2, hazy=5, storm=8-10
    sky_manager.atmosphere.turbidity = lerpf(2.0, 10.0, result.storm_fog_multiplier - 1.0)

    # Mie coefficient: higher in storms (more aerosols)
    sky_manager.atmosphere.mie_coefficient = lerpf(21e-6, 50e-6, result.storm_fog_multiplier - 1.0)

    # Cloud coverage for sky darkening
    sky_manager.cloud_coverage = result.cloud_coverage

    # Wind
    sky_manager.wind_speed = result.wind_speed
```

### WeatherManager Changes

Remove Sky3D clock delegation entirely. WeatherManager always owns the clock:

```gdscript
# DELETE: set_sky3d(), _sky3d reference, Sky3D clock reading
# DELETE: _fallback_hour, _fallback_time_scale, _fallback_paused (these become the ONLY clock)
# SIMPLIFY: _advance_clock() to just one path (was two: Sky3D vs fallback)

var game_hour: float = 8.0
var time_scale: float = 60.0  # game minutes per real minute

func _advance_clock(delta: float) -> void:
    if _paused:
        return
    game_hour += delta * time_scale / 3600.0
    if game_hour >= 24.0:
        game_hour -= 24.0
        _day += 1
```

### EnvironmentControls Changes

Massive simplification — no more Sky3D vs fallback swap:

```gdscript
# DELETE: _create_sky3d() (~50 lines)
# DELETE: on_show_sky_toggled() swap logic (~50 lines)
# DELETE: _disable_sky3d_fog() workaround
# DELETE: sky_3d reference, _sky3d_initialized flag

# SkyManager owns the WorldEnvironment. EnvironmentControls just reads it:
func _get_active_environment() -> Environment:
    return _sky_manager.get_environment()  # always valid, single source
```

---

## 8. Cloud Plugin Interface

SkyManager exposes a read-only state struct for any cloud system to consume:

```gdscript
class SkyState:
    var sun_direction: Vector3
    var moon_direction: Vector3
    var sun_color: Color
    var sun_energy: float
    var ambient_color: Color
    var game_hour: float
    ## Approximate transmittance at zenith — for cloud lighting.
    ## Cached, only recomputed when atmosphere params change.
    ## Analytical approximation: exp(-rayleigh_coeff * rayleigh_sh - mie_coeff * mie_sh)
    var atmosphere_transmittance_at_zenith: Color
```

`atmosphere_transmittance_at_zenith` is computed analytically (not a full integral):
```gdscript
func _compute_zenith_transmittance() -> Color:
    var r = atmosphere.rayleigh_coefficient
    var m = atmosphere.mie_coefficient
    var rsh = atmosphere.rayleigh_scale_height
    var msh = atmosphere.mie_scale_height
    var optical_r = Vector3(r.x * rsh, r.y * rsh, r.z * rsh)
    var optical_m = Vector3(m * msh, m * msh, m * msh)
    var total = optical_r + optical_m
    return Color(exp(-total.x), exp(-total.y), exp(-total.z))
```

This is cached and only recomputed when atmosphere params change (they change slowly
during weather transitions, not every frame).

SunshineClouds2 integration stays in `weather_controls.gd` — it reads `sky_manager.get_sky_state()`
for light tracking instead of directly referencing Sky3D's SunLight node.

---

## 9. Implementation Phases

### Phase 1: Core Sky System (~1,040 lines new code)
**Goal:** Working sky with atmosphere, sun disc, basic stars. Visual quality at least matching Sky3D.

New files:
- `src/core/sky/sky_manager.gd` (~300 lines)
- `src/core/sky/celestial_manager.gd` (~250 lines)
- `src/core/sky/atmosphere_params.gd` (~60 lines)
- `src/core/sky/shaders/sky.gdshader` (~350 lines)
- `src/core/sky/shaders/sky_common.gdshaderinc` (~80 lines)

Test: `tests/visual/test_sky.tscn` + `test_sky.gd` (~200 lines) — standalone sky test
with time slider, atmosphere parameter sliders.

Verification:
- Dawn (6h), noon (12h), sunset (18h), midnight (0h) all look correct
- Horizon is bright at sunset (multi-scatter working)
- IBL: place shiny sphere, confirm sky reflection matches visual sky
- Sun disc is HDR (visible glow when glow enabled)
- Compare side-by-side against Sky3D at same times

### Phase 2: Full Feature Parity (~300 lines additions)
**Goal:** Moon texture, star panorama with scintillation, REALISTIC orbital mode, ozone.

Additions:
- Moon texture mapping with phase lighting (from Sky3D's sphere intersection math)
- Star panorama (equirectangular) with scintillation effect
- CelestialManager REALISTIC mode (adapted from TimeOfDay.gd orbital mechanics)
- Ozone absorption (3 uniforms + ~5 shader lines)

Assets: Use Sky3D's moon texture and star panorama (MIT, add attribution in credits).
Make textures configurable — not hardcoded paths.

Verification: Side-by-side A/B with Sky3D at multiple times, seasons, latitudes.

### Phase 3: Weather + Cloud Integration (~200 lines modifications)
**Goal:** Wire new sky system into weather pipeline and cloud plugin.

Changes:
- `weather_renderer.gd`: Replace `_apply_sky3d()` with `_apply_sky(sky_manager, result)`
- `weather_manager.gd`: Remove Sky3D clock delegation, simplify to single clock
- `weather_controls.gd`: Update SunshineClouds2 light tracking to use SkyManager
- `environment_controls.gd`: Remove Sky3D swap logic, use SkyManager's Environment
- `test_weather.gd`: Update to use new sky system

Verification: All 10 weather presets work. SunshineClouds2 still works. Fog still driven.

### Phase 4: Cleanup + Delete Sky3D (net negative lines)
**Goal:** Remove all Sky3D code and workarounds.

Deletions:
- `addons/sky_3d/` entirely (~3,250 lines)
- Sky3D references in environment_controls.gd (~80 lines)
- Sky3D clock delegation in weather_manager.gd (~40 lines)
- Sky3D workarounds in weather_renderer.gd (~30 lines)

Verification: Full regression — main scene (Godotwind.tscn) + test_weather + test_sky.
No references to Sky3D remain in codebase.

### Lines Estimate

| Component | New | Modified | Deleted |
|-----------|-----|----------|---------|
| sky_manager.gd | ~300 | — | — |
| celestial_manager.gd | ~250 | — | — |
| atmosphere_params.gd | ~60 | — | — |
| sky.gdshader | ~350 | — | — |
| sky_common.gdshaderinc | ~80 | — | — |
| test_sky.gd + .tscn | ~200 | — | — |
| weather_renderer.gd | — | ~50 | ~30 |
| weather_manager.gd | — | ~20 | ~40 |
| environment_controls.gd | — | ~30 | ~80 |
| weather_controls.gd | — | ~20 | ~10 |
| test_weather.gd | — | ~40 | ~30 |
| addons/sky_3d/ | — | — | ~3,250 |
| **Total** | **~1,240** | **~160** | **~3,440** |

**Net: ~2,040 fewer lines.**

---

## 10. Reference Implementations

### Primary References

1. **Sky++ (sorta)** — godotshaders.com/shader/sky-sorta/
   - License: **CC0** (public domain)
   - Features: Rayleigh+Mie+ozone, multi-step ray sampling, 3 moons, stars, volumetric
     cumulus, cirrus, rainbow
   - Use for: Scattering integration structure, phase function implementations
   - Note: WIP, GPU-heavy. Cherry-pick math, not the whole shader.

2. **Sky3D** — github.com/TokisanGames/Sky3D
   - License: **MIT**
   - Features: Preetham single-scatter, orbital mechanics, moon texture, star field,
     light management, well-structured GDScript
   - Use for: TimeOfDay orbital mechanics (adapt into celestial_manager.gd), light
     intensity curves, moon sphere intersection math, star panorama sampling
   - Attribution required for code adapted from this project.

3. **voithos/godot-precomputed-atmosphere** — github.com/voithos/godot-precomputed-atmosphere
   - License: **MIT**
   - Features: Hillaire 2020 LUT-based atmosphere for Godot 4.4+
   - Use for: Multi-scatter approximation technique reference (Section 5.3 of Hillaire paper).
     We use an analytical version of their approach, not the compute shader pipeline.

4. **Hillaire 2020 paper** — "A Scalable and Production Ready Sky and Atmosphere Rendering
   Technique" (EGSR 2020, Sébastien Hillaire / Epic Games)
   - Section 5.3 describes the multi-scatter LUT and energy conservation approach.
   - Our analytical rescaling `1/(1-albedo*factor)` is derived from the same principle.

### Secondary References

5. **Hosek-Wilkie 2012/2013** — cgg.mff.cuni.cz/projects/SkylightModelling/
   - Analytical spectral sky model. Better sunsets than Preetham.
   - NOT used directly (incompatible with custom Rayleigh+Mie integration), but useful
     for visual comparison and parameter tuning.

6. **Bruneton 2017** — ebruneton.github.io/precomputed_atmospheric_scattering/
   - Reference implementation of precomputed atmospheric scattering.
   - Educational reference only — we don't use the LUT approach.

7. **Preetham 1999** — "A Practical Analytic Model for Daylight" (ATI/AMD)
   - What Sky3D implements. Known limitations: single-scatter, negative luminance at low
     turbidity, poor night sky handling. We exceed this.

---

## 11. Test Plan

### `tests/visual/test_sky.tscn` (NEW — Phase 1)

Standalone sky test scene. No weather system, no streaming, no ESM data.

Features:
- Time-of-day slider (0-24h)
- Atmosphere parameter sliders (turbidity, Mie anisotropy, multi-scatter factor)
- Ground plane with reflective sphere (IBL verification)
- Side-by-side comparison option (split screen with ProceduralSkyMaterial)
- FPS counter
- Debug overlay: sun altitude, moon phase, scattering params

Controls:
- T/Y: Time backward/forward
- +/-: Adjust turbidity
- M: Toggle multi-scatter
- Mouse: Right-click look, ZQSD move

Verification checklist:
- [ ] Dawn (6h): orange/pink horizon, blue zenith, horizon brightened by multi-scatter
- [ ] Noon (12h): deep blue zenith, white-ish sun, bright ambient
- [ ] Sunset (18h): red/orange horizon, purple zenith transition, long warm shadows
- [ ] Midnight (0h): dark sky, visible stars, moon illumination (if above horizon)
- [ ] IBL: shiny sphere reflects sky correctly at all times
- [ ] Sun disc: HDR (causes glow when glow enabled), limb darkening visible
- [ ] No banding artifacts (debanding working)
- [ ] No negative luminance (sky never goes black/negative at any angle)

### `tests/visual/test_weather.tscn` (UPDATED — Phase 3)

Replace Sky3D initialization with SkyManager. Same controls (1-0 for weather, T/Y for
time, etc.). Debug overlay updated to show SkyManager state instead of Sky3D SkyDome params.

Additional verification:
- [ ] All 10 weather presets produce correct atmosphere (clear=low turbidity, storm=high)
- [ ] SunshineClouds2 still composites correctly (no edge artifacts)
- [ ] Fog tinting matches sky horizon color
- [ ] Thunder flash works (volumetric emission spike)
- [ ] Weather transitions smooth (no atmosphere parameter popping)

### Main Scene Regression (Phase 4)

Run `scenes/Godotwind.tscn` with new sky system:
- [ ] Day/night cycle smooth during streaming
- [ ] No performance regression (sky shader not a bottleneck)
- [ ] Weather works in streaming world
- [ ] Ocean reflects new sky correctly

---

## 12. Reviewer Feedback & Resolutions

Reviewer feedback received 2026-04-04. Resolutions:

### MUST FIX (all addressed in plan above)

**1. Multi-scatter technique specified** — Section 2: "Rescaled single-scatter approximation"
using `L * 1/(1 - scatter_albedo * factor)`. Derived from geometric series of scattering
orders. Hillaire 2020 §5.3 reference. Not a "fudge factor" — it's the energy conservation
rescaling from the infinite series `sum(albedo^n)`.

**2. WeatherResult.sky_color redundancy** — Section 4 "WeatherResult.sky_color Clarification":
sky_color is NOT applied to sky dome. It only drives fog_light_color and ambient_color.
Sky dome color comes purely from scattering model.

**3. Clock ownership call chain** — Section 4 "Clock Ownership Call Chain": Full call chain
spelled out. WeatherManager._process() → SkyManager.update(hour) → CelestialManager.update().
No delegation, no two-way coupling.

**4. IBL / HDR correctness** — Section 4 "IBL / HDR Correctness": Shader outputs linear HDR
radiance. No tonemapping in shader. Environment handles tonemapping. Test plan includes
reflective sphere IBL verification.

### SHOULD FIX (addressed)

**5. AT_HALF_RES_PASS artifacts** — Section 5 "Performance Notes": Start full-res. Only
move to half-res if profiling shows need. Risk noted for SunshineClouds2 edge artifacts.

**6. SkyState.atmosphere_transmittance_at_zenith** — Section 8: Analytical approximation,
cached and only recomputed when atmosphere params change (not per-frame).

**7. Star / moon texture assets** — Phase 2: Use Sky3D's assets (MIT, attribution required).
Make configurable with no hardcoded paths.

### NICE-TO-HAVE (deferred per reviewer's suggestion)

**8. Ozone** — Deferred to Phase 2. Set to Vector3.ZERO in Phase 1.

**9. Hosek-Wilkie vs Preetham** — Not used. Single model: Rayleigh+Mie+multi-scatter.
Hosek-Wilkie listed as visual comparison reference only.

---

## 13. Open Questions Resolved

| Question | Resolution | Source |
|----------|-----------|--------|
| Moon texture | Use Sky3D's (MIT, add attribution). Make configurable. | Reviewer |
| Star field format | Equirectangular panorama (artist-friendly, matches Sky3D) | Reviewer |
| Aerial perspective | Godot depth fog is good enough. Phase 5 later if needed. | Reviewer |
| Performance budget | Start full-res. Only AT_HALF_RES if profiling shows need. | Reviewer |

---

## 14. File Inventory

### New Files (Phase 1-2)
```
src/core/sky/sky_manager.gd            — Top-level sky system manager
src/core/sky/celestial_manager.gd      — Sun/moon/star positioning
src/core/sky/atmosphere_params.gd      — Atmospheric parameter data class
src/core/sky/shaders/sky.gdshader      — Main sky shader
src/core/sky/shaders/sky_common.gdshaderinc — Shared scattering functions
tests/visual/test_sky.gd              — Standalone sky visual test
tests/visual/test_sky.tscn            — Test scene
```

### Modified Files (Phase 3)
```
src/core/weather/weather_renderer.gd   — Replace _apply_sky3d() with _apply_sky()
src/core/weather/weather_manager.gd    — Remove Sky3D clock delegation
src/tools/ui/environment_controls.gd   — Remove Sky3D swap logic
src/tools/ui/weather_controls.gd       — Update cloud plugin light tracking
src/tools/world_explorer.gd            — Update sky initialization
tests/visual/test_weather.gd           — Update to use SkyManager
```

### Deleted Files (Phase 4)
```
addons/sky_3d/                         — Entire addon (~3,250 lines)
```
