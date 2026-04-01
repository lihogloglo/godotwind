## Weather Particles — Rain, snow, and storm precipitation via GPUParticles3D
##
## Node3D that follows the camera and emits precipitation particles
## based on the current WeatherResult. Contains three GPUParticles3D children:
## rain, snow, and storm (ash/blight/blizzard).
class_name WeatherParticles
extends Node3D


## Emission box size (meters) — particles spawn in this area around camera
const EMISSION_SIZE: float = 80.0

## Emission height above camera
const EMISSION_HEIGHT: float = 30.0

## Particle lifetime (seconds)
const RAIN_LIFETIME: float = 2.0
const SNOW_LIFETIME: float = 8.0
const STORM_LIFETIME: float = 4.0

var _rain: GPUParticles3D = null
var _snow: GPUParticles3D = null
var _storm: GPUParticles3D = null

var _rain_material: ParticleProcessMaterial = null
var _snow_material: ParticleProcessMaterial = null
var _storm_material: ParticleProcessMaterial = null

## Camera to follow
var _camera: Camera3D = null

## Cached particle amounts to avoid GPU buffer realloc every frame
var _last_rain_amount: int = 0
var _last_snow_amount: int = 0
var _last_storm_amount: int = 0


func _ready() -> void:
	_setup_rain()
	_setup_snow()
	_setup_storm()


## Set camera to follow
func set_camera(camera: Camera3D) -> void:
	_camera = camera


## Update particle emission based on weather result
func update(result: WeatherTypes.WeatherResult) -> void:
	# Follow camera
	if _camera and is_instance_valid(_camera):
		global_position = _camera.global_position

	# Rain
	if result.rain_intensity > 0.01:
		_rain.emitting = true
		var rain_amount: int = clampi(int(result.rain_intensity * 600), 10, 1000)
		if rain_amount != _last_rain_amount:
			_rain.amount = rain_amount
			_last_rain_amount = rain_amount
		_rain_material.initial_velocity_min = result.rain_intensity * 400.0
		_rain_material.initial_velocity_max = result.rain_intensity * 575.0
	else:
		_rain.emitting = false

	# Snow
	if result.snow_intensity > 0.01:
		_snow.emitting = true
		var snow_amount: int = clampi(int(result.snow_intensity * 750), 10, 1500)
		if snow_amount != _last_snow_amount:
			_snow.amount = snow_amount
			_last_snow_amount = snow_amount
		_snow_material.initial_velocity_min = 20.0
		_snow_material.initial_velocity_max = 100.0 * result.snow_intensity
	else:
		_snow.emitting = false

	# Storm (ash/blight/blizzard)
	if result.storm_intensity > 0.01:
		_storm.emitting = true
		var storm_amount: int = clampi(int(result.storm_intensity * 500), 10, 800)
		if storm_amount != _last_storm_amount:
			_storm.amount = storm_amount
			_last_storm_amount = storm_amount
		# Storm particles come from a direction
		if result.storm_direction.length_squared() > 0.01:
			_storm_material.direction = result.storm_direction.normalized()
		_storm_material.initial_velocity_min = 200.0 * result.storm_intensity
		_storm_material.initial_velocity_max = 400.0 * result.storm_intensity
	else:
		_storm.emitting = false


#region Setup

func _setup_rain() -> void:
	_rain = GPUParticles3D.new()
	_rain.name = "RainParticles"
	_rain.emitting = false
	_rain.amount = 450
	_rain.lifetime = RAIN_LIFETIME
	_rain.visibility_aabb = AABB(Vector3(-EMISSION_SIZE, -EMISSION_HEIGHT, -EMISSION_SIZE),
		Vector3(EMISSION_SIZE * 2, EMISSION_HEIGHT * 2, EMISSION_SIZE * 2))

	_rain_material = ParticleProcessMaterial.new()
	_rain_material.direction = Vector3(0, -1, 0)
	_rain_material.spread = 5.0
	_rain_material.initial_velocity_min = 400.0
	_rain_material.initial_velocity_max = 575.0
	_rain_material.gravity = Vector3(0, -9.8, 0)
	_rain_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_rain_material.emission_box_extents = Vector3(EMISSION_SIZE, 2.0, EMISSION_SIZE)

	# Rain drop mesh — thin stretched quad
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.02, 0.3)
	_rain_material.particle_flag_align_y = true

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.75, 0.85, 0.4)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	mesh.material = mat

	_rain.process_material = _rain_material
	_rain.draw_pass_1 = mesh
	_rain.position = Vector3(0, EMISSION_HEIGHT, 0)
	add_child(_rain)


func _setup_snow() -> void:
	_snow = GPUParticles3D.new()
	_snow.name = "SnowParticles"
	_snow.emitting = false
	_snow.amount = 750
	_snow.lifetime = SNOW_LIFETIME
	_snow.visibility_aabb = AABB(Vector3(-EMISSION_SIZE, -EMISSION_HEIGHT * 2, -EMISSION_SIZE),
		Vector3(EMISSION_SIZE * 2, EMISSION_HEIGHT * 3, EMISSION_SIZE * 2))

	_snow_material = ParticleProcessMaterial.new()
	_snow_material.direction = Vector3(0, -1, 0)
	_snow_material.spread = 30.0  # Snow drifts more
	_snow_material.initial_velocity_min = 20.0
	_snow_material.initial_velocity_max = 80.0
	_snow_material.gravity = Vector3(0, -2.0, 0)  # Light gravity
	_snow_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_snow_material.emission_box_extents = Vector3(EMISSION_SIZE, 2.0, EMISSION_SIZE)
	# Slight turbulence for drifting
	_snow_material.turbulence_enabled = true
	_snow_material.turbulence_noise_strength = 2.0
	_snow_material.turbulence_noise_speed_random = 0.5
	_snow_material.turbulence_noise_scale = 4.0

	# Snowflake mesh — small billboard quad
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.06, 0.06)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.95, 1.0, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mesh.material = mat

	_snow.process_material = _snow_material
	_snow.draw_pass_1 = mesh
	_snow.position = Vector3(0, EMISSION_HEIGHT, 0)
	add_child(_snow)


func _setup_storm() -> void:
	_storm = GPUParticles3D.new()
	_storm.name = "StormParticles"
	_storm.emitting = false
	_storm.amount = 400
	_storm.lifetime = STORM_LIFETIME
	_storm.visibility_aabb = AABB(Vector3(-EMISSION_SIZE * 2, -EMISSION_HEIGHT, -EMISSION_SIZE * 2),
		Vector3(EMISSION_SIZE * 4, EMISSION_HEIGHT * 2, EMISSION_SIZE * 4))

	_storm_material = ParticleProcessMaterial.new()
	_storm_material.direction = Vector3(1, -0.2, 0)  # Default, overridden by storm_direction
	_storm_material.spread = 20.0
	_storm_material.initial_velocity_min = 200.0
	_storm_material.initial_velocity_max = 350.0
	_storm_material.gravity = Vector3(0, -1.0, 0)
	_storm_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_storm_material.emission_box_extents = Vector3(EMISSION_SIZE * 1.5, EMISSION_HEIGHT, EMISSION_SIZE * 1.5)
	# Storm turbulence
	_storm_material.turbulence_enabled = true
	_storm_material.turbulence_noise_strength = 5.0
	_storm_material.turbulence_noise_speed_random = 1.0

	# Ash/dust particle — small billboard
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.15, 0.15)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.35, 0.25, 0.6)  # Brownish ash default
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mesh.material = mat

	_storm.process_material = _storm_material
	_storm.draw_pass_1 = mesh
	_storm.position = Vector3(0, EMISSION_HEIGHT * 0.5, 0)
	add_child(_storm)

#endregion
