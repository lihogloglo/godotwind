class_name SkyManager
extends Node3D
## Top-level sky system manager. Owns WorldEnvironment, sun/moon lights, sky shader.
## Replaces Sky3D addon with a framework-agnostic, physically-based sky.
##
## Call update(game_hour) each frame — typically from world_explorer or WeatherManager.
## Weather drives atmosphere params via the atmosphere property.
## Cloud plugins read get_sky_state() for light/atmosphere info.

const SKY_SHADER_PATH: String = "res://src/core/sky/shaders/sky.gdshader"

# Default texture paths (MIT licensed — Sky3D by TokisanGames, see assets/sky/ATTRIBUTION.txt)
const STAR_PANORAMA_PATH: String = "res://assets/sky/Milkyway.jpg"
const STAR_FIELD_PATH: String = "res://assets/sky/StarField.jpg"
const MOON_TEXTURE_PATH: String = "res://assets/sky/MoonMap.png"

# ---- Public State ----

## Atmospheric parameters. WeatherRenderer modifies these for weather effects.
var atmosphere: AtmosphereParams = AtmosphereParams.new()

## Cloud coverage (0-1). Darkens sky behind volumetric clouds.
## Set by WeatherRenderer — the cloud plugin does actual cloud rendering.
var cloud_coverage: float = 0.0

## Wind speed (m/s). Available for star twinkle modulation, etc.
var wind_speed: float = 0.0

## Wind direction in degrees (0=north, 90=east, 180=south, 270=west).
var wind_direction: float = 0.0

## Current game hour (read-only — set via update()).
var game_hour: float = 12.0

## Whether the sky system is enabled.
var enabled: bool = true:
	set(value):
		enabled = value
		_update_visibility()

# ---- Configuration ----

## Sun disc angular radius in radians (~0.5 degrees real sun).
var sun_disk_size: float = 0.0087
## Sun HDR energy multiplier.
var sun_energy: float = 22.0
## Sun disc color.
var sun_color: Color = Color(1.0, 0.95, 0.9)

## Moon disc angular radius.
var moon_disk_size: float = 0.009
## Moon light energy.
var moon_energy: float = 0.5

## Star brightness.
var star_energy: float = 0.3

## Night sky ambient glow intensity.
var night_intensity: float = 0.005

## Ground color below horizon.
var ground_color: Color = Color(0.15, 0.12, 0.1)

# ---- Mie Halos ----

## Sun halo intensity (corona around sun disc). 0=disabled.
var sun_halo_intensity: float = 0.4
## Sun halo Henyey-Greenstein g parameter (higher = tighter halo).
var sun_halo_g: float = 0.96
## Moon halo intensity. 0=disabled.
var moon_halo_intensity: float = 0.05
## Moon halo g parameter.
var moon_halo_g: float = 0.95

# ---- Star Scintillation ----

## Amount of star twinkling (0=static, 1=max flicker).
var scintillation_amount: float = 0.15
## Speed of star twinkling.
var scintillation_speed: float = 1.5

# ---- Color Tinting ----

## Artist tint for daytime sky (multiplicative). White=no tint.
var day_tint: Color = Color(1.0, 1.0, 1.0)
## Artist tint for nighttime sky.
var night_tint: Color = Color(0.6, 0.7, 1.0)
## Artist tint for horizon (strongest at sunrise/sunset).
var horizon_tint: Color = Color(1.0, 0.85, 0.7)
## How strongly tints affect the sky (0=pure physics, 1=full tint).
var tint_strength: float = 0.3

# ---- Light Curves ----

## Sun light energy vs altitude curve. X=altitude (0=horizon, 1=zenith), Y=energy.
## If null, uses the default hardcoded curve.
var sun_light_curve: Curve = null
## Moon light energy vs altitude curve. If null, uses default.
var moon_light_curve: Curve = null

# ---- Ambient Transitions ----

## Sky contribution during day (1.0 = sky fully drives ambient).
var day_sky_contribution: float = 1.0
## Sky contribution at night (lower allows ambient_energy to fill in).
var night_sky_contribution: float = 0.4
## Ambient light energy at night (boost to prevent pitch black).
var night_ambient_energy: float = 0.15
## Transition speed for ambient changes (per second).
var ambient_transition_speed: float = 0.5

var _current_sky_contribution: float = 1.0
var _current_ambient_energy: float = 1.0

# ---- Cirrus Clouds ----

## Whether cirrus clouds are visible.
var cirrus_visible: bool = true
## Cirrus coverage (0=clear, 1=full coverage).
## Default bumped 2026-04-09 from 0.4 → 0.55 for clearer baseline visibility.
var cirrus_coverage: float = 0.55
## Cirrus absorption (Beer's law extinction strength).
var cirrus_absorption: float = 2.0
## Cirrus brightness.
var cirrus_intensity: float = 8.0
## Cirrus alpha thickness.
## Default bumped 2026-04-09 from 0.4 → 0.6 so the layer reads as proper wisps.
var cirrus_thickness: float = 0.6
## Cirrus noise scale (higher = smaller wisps).
## Default dropped 2026-04-09 from 1.0 → 0.7 so individual streaks are larger.
var cirrus_size: float = 0.7
## Cirrus wind scroll speed (UV units per second). Two layers at different speeds.
var cirrus_wind_speed1: Vector2 = Vector2(0.06, 0.02)
var cirrus_wind_speed2: Vector2 = Vector2(-0.04, 0.03)
## Cirrus day color (warm white).
var cirrus_day_color: Color = Color(1.0, 0.98, 0.95)
## Cirrus night color (dark blue-grey).
var cirrus_night_color: Color = Color(0.15, 0.18, 0.25)

var _cirrus_scroll1: Vector2 = Vector2.ZERO
var _cirrus_scroll2: Vector2 = Vector2.ZERO

# ---- Textures (Phase 2) ----

## Star panorama texture (equirectangular). Set to null for procedural stars.
var star_panorama: Texture2D = null:
	set(value):
		star_panorama = value
		if _sky_material:
			if value:
				_sky_material.set_shader_parameter("star_panorama", value)
				_sky_material.set_shader_parameter("star_panorama_enabled", true)
			else:
				_sky_material.set_shader_parameter("star_panorama_enabled", false)

## Moon texture. Set to null for simple white disc.
var moon_texture: Texture2D = null:
	set(value):
		moon_texture = value
		if _sky_material:
			if value:
				_sky_material.set_shader_parameter("moon_texture", value)
				_sky_material.set_shader_parameter("moon_texture_enabled", true)
			else:
				_sky_material.set_shader_parameter("moon_texture_enabled", false)

# ---- Celestial ----

## Celestial position calculator.
var celestial: CelestialManager = CelestialManager.new()

# ---- Read-Only Outputs ----

## Current sun direction (normalized, points toward sun).
var sun_direction: Vector3:
	get: return celestial.sun_direction

## Current moon direction (normalized, points toward moon).
var moon_direction: Vector3:
	get: return celestial.moon_direction

# ---- Owned Nodes ----

var _world_env: WorldEnvironment
var _sun_light: DirectionalLight3D
var _moon_light: DirectionalLight3D
var _sky_material: ShaderMaterial
var _environment: Environment
var _initialized: bool = false

# ---- Cached Zenith Transmittance ----

var _zenith_transmittance: Color = Color.WHITE
var _last_atm_hash: float = 0.0
var _debug_logged: bool = false


# ---- SkyState for Cloud Plugins ----

class SkyState:
	var sun_direction: Vector3
	var moon_direction: Vector3
	var sun_color: Color
	var sun_energy: float
	var ambient_color: Color
	var game_hour: float
	var atmosphere_transmittance_at_zenith: Color
	var wind_speed: float
	var wind_direction: float
	var date_string: String


func _ready() -> void:
	_initialize()


func _initialize() -> void:
	if _initialized:
		return

	# --- Sky shader material ---
	var shader: Shader = load(SKY_SHADER_PATH) as Shader
	if not shader:
		Log.error("sky", "Failed to load sky shader: %s" % SKY_SHADER_PATH)
		return

	_sky_material = ShaderMaterial.new()
	_sky_material.shader = shader

	# --- Sky resource ---
	var sky := Sky.new()
	sky.sky_material = _sky_material
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = Sky.RADIANCE_SIZE_256

	# --- Environment ---
	_environment = Environment.new()
	_environment.background_mode = Environment.BG_SKY
	_environment.sky = sky
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_environment.ambient_light_sky_contribution = 1.0
	_environment.ambient_light_energy = 1.0
	_environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	_environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_environment.tonemap_exposure = 1.0
	_environment.tonemap_white = 8.0

	# SSR, fog, glow etc. configured by environment_controls.gd, not here.

	# --- WorldEnvironment ---
	_world_env = WorldEnvironment.new()
	_world_env.name = "SkyWorldEnvironment"
	_world_env.environment = _environment
	add_child(_world_env)

	# --- Sun DirectionalLight3D ---
	_sun_light = DirectionalLight3D.new()
	_sun_light.name = "SunLight"
	_sun_light.light_color = Color(1.0, 0.95, 0.9)
	_sun_light.light_energy = 1.0
	_sun_light.shadow_enabled = true
	_sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_sun_light.directional_shadow_max_distance = 200.0
	_sun_light.light_bake_mode = Light3D.BAKE_DISABLED
	add_child(_sun_light)

	# --- Moon DirectionalLight3D ---
	_moon_light = DirectionalLight3D.new()
	_moon_light.name = "MoonLight"
	_moon_light.light_color = Color(0.6, 0.65, 0.8)
	_moon_light.light_energy = 0.0
	_moon_light.shadow_enabled = false
	_moon_light.light_bake_mode = Light3D.BAKE_DISABLED
	add_child(_moon_light)

	# --- Load default textures (Phase 2) ---
	_load_default_textures()

	_initialized = true
	Log.info("sky", "SkyManager initialized")


## Main update — call each frame with current game hour.
func update(hour: float) -> void:
	if not _initialized or not enabled:
		return

	game_hour = hour

	# Update celestial positions (calendar auto-advances on day boundary)
	celestial.update(hour)

	# Animate cirrus wind scroll — driven by weather wind
	var delta: float = get_process_delta_time() if is_inside_tree() else 0.016
	# Wind multiplier: base speed even in calm, scales up with weather wind
	var wind_mult: float = maxf(0.5, wind_speed * 2.0)
	# Rotate scroll direction by wind_direction (degrees → radians)
	var wind_rad: float = deg_to_rad(wind_direction)
	var wind_cos: float = cos(wind_rad)
	var wind_sin: float = sin(wind_rad)
	var base1: Vector2 = cirrus_wind_speed1 * wind_mult
	var base2: Vector2 = cirrus_wind_speed2 * wind_mult
	_cirrus_scroll1 += Vector2(base1.x * wind_cos - base1.y * wind_sin, base1.x * wind_sin + base1.y * wind_cos) * delta
	_cirrus_scroll2 += Vector2(base2.x * wind_cos - base2.y * wind_sin, base2.x * wind_sin + base2.y * wind_cos) * delta
	# Wrap to avoid float32 precision loss after long sessions (noise tiles, period arbitrary)
	_cirrus_scroll1 = Vector2(fmod(_cirrus_scroll1.x, 1000.0), fmod(_cirrus_scroll1.y, 1000.0))
	_cirrus_scroll2 = Vector2(fmod(_cirrus_scroll2.x, 1000.0), fmod(_cirrus_scroll2.y, 1000.0))

	# Update shader uniforms
	_update_shader_uniforms()

	# Update lights
	_update_lights()

	# One-time diagnostic
	if not _debug_logged and _sun_light:
		_debug_logged = true
		var light_z: Vector3 = -_sun_light.basis.z
		Log.info("sky", "Sun dir: %s | Light -Z: %s | Energy: %.2f | In tree: %s" % [
			celestial.sun_direction, light_z, _sun_light.light_energy, _sun_light.is_inside_tree()])

	# Update zenith transmittance cache (for cloud plugins)
	_update_zenith_transmittance()


## Get read-only sky state for cloud plugins.
func get_sky_state() -> SkyState:
	var state := SkyState.new()
	state.sun_direction = celestial.sun_direction
	state.moon_direction = celestial.moon_direction
	state.sun_color = _sun_light.light_color if _sun_light else Color.WHITE
	state.sun_energy = _sun_light.light_energy if _sun_light else 0.0
	state.ambient_color = _environment.ambient_light_color if _environment else Color.WHITE
	state.game_hour = game_hour
	state.atmosphere_transmittance_at_zenith = _zenith_transmittance
	state.wind_speed = wind_speed
	state.wind_direction = wind_direction
	state.date_string = celestial.get_date_string()
	return state


## Get the owned Environment resource.
func get_environment() -> Environment:
	return _environment


## Get the sun DirectionalLight3D.
func get_sun_light() -> DirectionalLight3D:
	return _sun_light


## Get the moon DirectionalLight3D.
func get_moon_light() -> DirectionalLight3D:
	return _moon_light


## Get the WorldEnvironment node.
func get_world_environment() -> WorldEnvironment:
	return _world_env


#region Shader Uniforms

func _update_shader_uniforms() -> void:
	if not _sky_material:
		return

	# Atmosphere params
	var params: Dictionary = atmosphere.to_shader_params()
	for key: String in params:
		_sky_material.set_shader_parameter(key, params[key])

	# Turbidity (separate because it's used raw, not just in to_shader_params)
	_sky_material.set_shader_parameter("turbidity", atmosphere.turbidity)

	# Celestial directions
	_sky_material.set_shader_parameter("sun_direction", celestial.sun_direction)
	_sky_material.set_shader_parameter("moon_direction", celestial.moon_direction)

	# Sun/moon disc
	_sky_material.set_shader_parameter("sun_disk_size", sun_disk_size)
	_sky_material.set_shader_parameter("sun_energy", sun_energy)
	_sky_material.set_shader_parameter("sun_color", Vector3(sun_color.r, sun_color.g, sun_color.b))
	_sky_material.set_shader_parameter("moon_disk_size", moon_disk_size)
	_sky_material.set_shader_parameter("moon_energy", moon_energy)

	# Stars
	_sky_material.set_shader_parameter("star_rotation", celestial.star_rotation)
	_sky_material.set_shader_parameter("star_energy", star_energy)
	_sky_material.set_shader_parameter("scintillation_amount", scintillation_amount)
	_sky_material.set_shader_parameter("scintillation_speed", scintillation_speed)

	# Mie halos
	_sky_material.set_shader_parameter("sun_halo_intensity", sun_halo_intensity)
	_sky_material.set_shader_parameter("sun_halo_g", sun_halo_g)
	_sky_material.set_shader_parameter("moon_halo_intensity", moon_halo_intensity)
	_sky_material.set_shader_parameter("moon_halo_g", moon_halo_g)

	# Color tinting
	_sky_material.set_shader_parameter("day_tint", Vector3(day_tint.r, day_tint.g, day_tint.b))
	_sky_material.set_shader_parameter("night_tint", Vector3(night_tint.r, night_tint.g, night_tint.b))
	_sky_material.set_shader_parameter("horizon_tint", Vector3(horizon_tint.r, horizon_tint.g, horizon_tint.b))
	_sky_material.set_shader_parameter("tint_strength", tint_strength)

	# Night
	_sky_material.set_shader_parameter("night_intensity", night_intensity)

	# Ground
	_sky_material.set_shader_parameter("ground_color", Vector3(ground_color.r, ground_color.g, ground_color.b))

	# Cloud darkening
	_sky_material.set_shader_parameter("cloud_coverage", cloud_coverage)

	# Cirrus clouds
	_sky_material.set_shader_parameter("cirrus_visible", cirrus_visible)
	_sky_material.set_shader_parameter("cirrus_coverage", cirrus_coverage)
	_sky_material.set_shader_parameter("cirrus_absorption", cirrus_absorption)
	_sky_material.set_shader_parameter("cirrus_intensity", cirrus_intensity)
	_sky_material.set_shader_parameter("cirrus_thickness", cirrus_thickness)
	_sky_material.set_shader_parameter("cirrus_size", cirrus_size)
	_sky_material.set_shader_parameter("cirrus_scroll1", _cirrus_scroll1)
	_sky_material.set_shader_parameter("cirrus_scroll2", _cirrus_scroll2)
	_sky_material.set_shader_parameter("cirrus_day_color", Vector3(cirrus_day_color.r, cirrus_day_color.g, cirrus_day_color.b))
	_sky_material.set_shader_parameter("cirrus_night_color", Vector3(cirrus_night_color.r, cirrus_night_color.g, cirrus_night_color.b))

#endregion


#region Light Management

func _update_lights() -> void:
	var sun_dir: Vector3 = celestial.sun_direction
	var moon_dir: Vector3 = celestial.moon_direction
	var alt: float = celestial.sun_altitude
	var delta: float = get_process_delta_time() if is_inside_tree() else 0.016

	# --- Sun light ---
	if _sun_light:
		_sun_light.basis = _direction_to_light_basis(sun_dir)

		# Energy: from curve if available, otherwise hardcoded
		if sun_light_curve:
			# Curve X: 0=horizon, 1=zenith. Map altitude to 0-1 range.
			var curve_t: float = clampf(alt / (PI * 0.5), 0.0, 1.0)
			_sun_light.light_energy = sun_light_curve.sample(curve_t)
		else:
			var sun_factor: float = clampf((sin(alt) + sun_disk_size) / (2.0 * sun_disk_size + 0.5), 0.0, 1.0)
			_sun_light.light_energy = lerpf(0.0, 1.2, sun_factor)

		# Color: warm at horizon, white at zenith
		var t: float = clampf(alt / (PI * 0.5), 0.0, 1.0)
		_sun_light.light_color = Color(1.0, lerpf(0.7, 0.98, t), lerpf(0.4, 0.95, t))

		# Shadows off when below horizon
		_sun_light.shadow_enabled = alt > -0.05

	# --- Moon light ---
	if _moon_light:
		_moon_light.basis = _direction_to_light_basis(moon_dir)

		var moon_alt: float = asin(clampf(moon_dir.y, -1.0, 1.0))
		var phase_factor: float = maxf(0.0, cos(celestial.moon_phase * TAU))

		if moon_light_curve:
			var curve_t: float = clampf(moon_alt / (PI * 0.5), 0.0, 1.0)
			_moon_light.light_energy = moon_light_curve.sample(curve_t) * phase_factor
		else:
			var moon_factor: float = clampf(sin(moon_alt), 0.0, 1.0) * phase_factor
			_moon_light.light_energy = clampf(moon_factor * 0.15, 0.0, 0.15)

		_moon_light.shadow_enabled = _moon_light.light_energy > 0.05

	# --- Smooth Ambient Transitions ---
	if _environment:
		# Target values based on sun altitude
		var is_night: float = clampf(-sin(alt) * 2.0, 0.0, 1.0)  # 0=day, 1=night
		var target_contribution: float = lerpf(day_sky_contribution, night_sky_contribution, is_night)
		var target_ambient: float = lerpf(1.0, night_ambient_energy, is_night)

		# Smooth transition
		var lerp_speed: float = 1.0 - exp(-ambient_transition_speed * delta)
		_current_sky_contribution = lerpf(_current_sky_contribution, target_contribution, lerp_speed)
		_current_ambient_energy = lerpf(_current_ambient_energy, target_ambient, lerp_speed)

		_environment.ambient_light_sky_contribution = _current_sky_contribution
		_environment.ambient_light_energy = _current_ambient_energy


## Build a Basis where -Z points in the light direction (away from the celestial body).
## direction: normalized vector pointing TOWARD the celestial body from the observer.
static func _direction_to_light_basis(direction: Vector3) -> Basis:
	# We want +Z = direction (toward body), so -Z = -direction (light shines away from body).
	var forward: Vector3 = direction.normalized()
	# Choose an up vector that isn't parallel to forward
	var up_ref: Vector3 = Vector3.UP if absf(forward.y) < 0.99 else Vector3.RIGHT
	var right: Vector3 = forward.cross(up_ref).normalized()
	var up: Vector3 = right.cross(forward).normalized()
	# Basis columns are (X=right, Y=up, Z=forward)
	return Basis(right, up, forward)

#endregion


#region Zenith Transmittance Cache

func _update_zenith_transmittance() -> void:
	# Only recompute when atmosphere params change (check via simple hash)
	var hash: float = atmosphere.rayleigh_coefficient.length() + atmosphere.mie_coefficient + atmosphere.turbidity
	if absf(hash - _last_atm_hash) < 1e-8:
		return
	_last_atm_hash = hash

	# Analytical approximation: exp(-rayleigh_coeff * rayleigh_sh - mie_coeff * mie_sh)
	var r: Vector3 = atmosphere.rayleigh_coefficient
	var m: float = atmosphere.mie_coefficient * atmosphere.turbidity
	var rsh: float = atmosphere.rayleigh_scale_height
	var msh: float = atmosphere.mie_scale_height
	var optical_r := Vector3(r.x * rsh, r.y * rsh, r.z * rsh)
	var optical_m := Vector3(m * msh, m * msh, m * msh)
	var total: Vector3 = optical_r + optical_m
	_zenith_transmittance = Color(exp(-total.x), exp(-total.y), exp(-total.z))

#endregion


#region Visibility

func _update_visibility() -> void:
	# WorldEnvironment extends Node (not Node3D) — no .visible property.
	# Toggle by nulling/restoring the environment resource instead.
	if _world_env:
		_world_env.environment = _environment if enabled else null
	if _sun_light:
		_sun_light.visible = enabled
	if _moon_light:
		_moon_light.visible = enabled

#endregion


#region Texture Loading

func _load_default_textures() -> void:
	# Star panorama
	if ResourceLoader.exists(STAR_PANORAMA_PATH):
		star_panorama = load(STAR_PANORAMA_PATH) as Texture2D
		if star_panorama and _sky_material:
			_sky_material.set_shader_parameter("star_panorama", star_panorama)
			_sky_material.set_shader_parameter("star_panorama_enabled", true)
			Log.info("sky", "Loaded star panorama: %s" % STAR_PANORAMA_PATH)
	else:
		Log.info("sky", "No star panorama found — using procedural stars")

	# Moon texture
	if ResourceLoader.exists(MOON_TEXTURE_PATH):
		moon_texture = load(MOON_TEXTURE_PATH) as Texture2D
		if moon_texture and _sky_material:
			_sky_material.set_shader_parameter("moon_texture", moon_texture)
			_sky_material.set_shader_parameter("moon_texture_enabled", true)
			Log.info("sky", "Loaded moon texture: %s" % MOON_TEXTURE_PATH)
	else:
		Log.info("sky", "No moon texture found — using simple disc")

	# Cirrus clouds use procedural noise (no texture needed)
	Log.info("sky", "Cirrus clouds: procedural FBM noise (no texture)")

#endregion
