## OceanSpray - GPU sea-spray layer driven by FFT crest energy.
##
## The node owns one camera-centered GPUParticles3D system. A particle shader
## samples the same FFT displacement cascade as the ocean surface and only
## activates particles where choppiness/height indicate a high-energy crest.
class_name OceanSpray
extends Node3D

const PARTICLE_SHADER_PATH := "res://src/core/water/shaders/ocean_spray_particles.gdshader"
const BILLBOARD_SHADER_PATH := "res://src/core/water/shaders/ocean_spray_billboard.gdshader"
const ARTIST_TEXTURE_PATH := "res://src/core/water/textures/sea_spray.png"
const DEFAULT_WINDOW_SIZE := 180.0

enum QualityTier { OFF, LOW, MEDIUM, HIGH }

var enabled: bool = true:
	set(value):
		enabled = value
		_apply_runtime_state()

var quality_tier: QualityTier = QualityTier.MEDIUM:
	set(value):
		quality_tier = value
		_apply_quality()

var _camera: Camera3D = null
var _particles: GPUParticles3D = null
var _process_material: ShaderMaterial = null
var _draw_material: ShaderMaterial = null
var _map_scales: PackedVector4Array = PackedVector4Array()
var _has_fft: bool = false
var _weather_energy: float = 0.0
var _wind_strength: float = 0.0


func _ready() -> void:
	_build_particles()
	_apply_quality()
	_apply_runtime_state()


func _process(_delta: float) -> void:
	if _camera and is_instance_valid(_camera):
		global_position = _camera.global_position
	if _process_material == null:
		return
	_process_material.set_shader_parameter(&"camera_position", global_position)


func set_camera(camera: Camera3D) -> void:
	_camera = camera
	if _camera and is_instance_valid(_camera):
		global_position = _camera.global_position


func set_fft_available(available: bool) -> void:
	_has_fft = available
	_apply_runtime_state()


func set_sea_level(value: float) -> void:
	if _process_material:
		_process_material.set_shader_parameter(&"sea_level", value)


func set_wave_scale(value: float) -> void:
	if _process_material:
		_process_material.set_shader_parameter(&"wave_scale", value)


func set_ocean_time(value: float) -> void:
	if _process_material:
		_process_material.set_shader_parameter(&"ocean_time", value)


func set_shore_mask(mask: Texture2D, world_bounds: Rect2) -> void:
	if _process_material == null:
		return
	_process_material.set_shader_parameter(&"shore_mask", mask)
	_process_material.set_shader_parameter(&"shore_mask_bounds", Vector4(
		world_bounds.position.x,
		world_bounds.position.y,
		world_bounds.size.x,
		world_bounds.size.y
	))


func set_map_scales(map_scales: PackedVector4Array) -> void:
	_map_scales = map_scales
	if _process_material:
		_process_material.set_shader_parameter(&"map_scales", _map_scales)


func set_weather(wind_t: float, wind_dir_xz: Vector2) -> void:
	_wind_strength = clampf(wind_t, 0.0, 1.0)
	# Breeze should barely mist, storms should visibly peel spray off crests.
	_weather_energy = smoothstep(0.22, 0.82, _wind_strength)
	if _process_material == null:
		return
	var dir := wind_dir_xz
	if dir.length_squared() < 0.0001:
		dir = Vector2(1.0, 1.0)
	dir = dir.normalized()
	_process_material.set_shader_parameter(&"wind_direction", dir)
	_process_material.set_shader_parameter(&"wind_strength", _wind_strength)
	_process_material.set_shader_parameter(&"weather_energy", _weather_energy)
	_apply_runtime_state()


func get_particle_count() -> int:
	return _particles.amount if _particles else 0


func is_emitting() -> bool:
	return _particles.emitting if _particles else false


func get_weather_energy() -> float:
	return _weather_energy


func get_runtime_status() -> Dictionary:
	return {
		"enabled": enabled,
		"visible": _particles.visible if _particles else false,
		"emitting": is_emitting(),
		"quality": int(quality_tier),
		"particle_candidates": get_particle_count(),
		"weather_energy": _weather_energy,
		"wind_strength": _wind_strength,
		"has_fft": _has_fft,
	}


func set_spray_texture(texture: Texture2D) -> void:
	if _draw_material and texture:
		_draw_material.set_shader_parameter(&"spray_texture", texture)


func set_render_layers(mask: int) -> void:
	if _particles:
		_particles.layers = mask


func _build_particles() -> void:
	_particles = GPUParticles3D.new()
	_particles.name = "SeaSprayParticles"
	_particles.local_coords = false
	_particles.lifetime = 2.6
	_particles.randomness = 0.28
	_particles.fixed_fps = 30
	_particles.fract_delta = true
	_particles.interpolate = true
	_particles.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	_particles.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD
	_particles.visibility_aabb = AABB(
		Vector3(-DEFAULT_WINDOW_SIZE, -24.0, -DEFAULT_WINDOW_SIZE),
		Vector3(DEFAULT_WINDOW_SIZE * 2.0, 80.0, DEFAULT_WINDOW_SIZE * 2.0)
	)
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_particles)

	var particle_shader := load(PARTICLE_SHADER_PATH) as Shader
	_process_material = ShaderMaterial.new()
	_process_material.shader = particle_shader
	_process_material.set_shader_parameter(&"spray_window_size", DEFAULT_WINDOW_SIZE)
	_process_material.set_shader_parameter(&"spawn_far_fade", DEFAULT_WINDOW_SIZE * 0.92)
	_particles.process_material = _process_material

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_draw_material = ShaderMaterial.new()
	_draw_material.shader = load(BILLBOARD_SHADER_PATH) as Shader
	_draw_material.set_shader_parameter(&"spray_texture", _load_spray_texture())
	quad.material = _draw_material
	_particles.draw_pass_1 = quad


func _apply_quality() -> void:
	if _particles == null:
		return
	match quality_tier:
		QualityTier.OFF:
			_particles.amount = 8
			_particles.amount_ratio = 0.0
			if _process_material:
				_process_material.set_shader_parameter(&"grid_rows", 3)
		QualityTier.LOW:
			_particles.amount = 1024
			_particles.amount_ratio = 1.0
			if _process_material:
				_process_material.set_shader_parameter(&"grid_rows", 32)
				_process_material.set_shader_parameter(&"max_particle_size", 1.9)
		QualityTier.MEDIUM:
			_particles.amount = 4096
			_particles.amount_ratio = 1.0
			if _process_material:
				_process_material.set_shader_parameter(&"grid_rows", 64)
				_process_material.set_shader_parameter(&"max_particle_size", 2.55)
		QualityTier.HIGH:
			_particles.amount = 9216
			_particles.amount_ratio = 1.0
			if _process_material:
				_process_material.set_shader_parameter(&"grid_rows", 96)
				_process_material.set_shader_parameter(&"max_particle_size", 2.9)
	_apply_runtime_state()


func _apply_runtime_state() -> void:
	if _particles == null:
		return
	var active := enabled and quality_tier != QualityTier.OFF and _has_fft and _weather_energy > 0.01
	_particles.emitting = active
	_particles.visible = enabled and quality_tier != QualityTier.OFF
	if _process_material:
		_process_material.set_shader_parameter(&"spray_enabled", active)
	if not active:
		_particles.amount_ratio = 0.0
	elif quality_tier != QualityTier.OFF:
		_particles.amount_ratio = 1.0


func _load_spray_texture() -> Texture2D:
	if ResourceLoader.exists(ARTIST_TEXTURE_PATH):
		var artist_tex := load(ARTIST_TEXTURE_PATH) as Texture2D
		if artist_tex:
			return artist_tex
	return _make_procedural_spray_texture()


func _make_procedural_spray_texture() -> ImageTexture:
	const SIZE := 128
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	var center := Vector2(SIZE * 0.5, SIZE * 0.5)
	var inv_radius := 1.0 / (SIZE * 0.5)
	for y in SIZE:
		for x in SIZE:
			var uv := Vector2(float(x), float(y))
			var dist := uv.distance_to(center) * inv_radius
			var soft := 1.0 - smoothstep(0.12, 1.0, dist)
			var streak := 0.55 + 0.45 * sin(float(x) * 0.22 + float(y) * 0.08)
			var alpha := clampf(soft * streak, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	return ImageTexture.create_from_image(img)
