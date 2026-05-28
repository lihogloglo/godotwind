## UnderwaterParticulates - camera-followed world-space underwater mote layer.
##
## Uses one GPUParticles3D system with tiny world-space billboards. The emitter
## follows the camera for culling, while spawns snap to a coarse world anchor so
## swimming reads as passing through water-suspended motes instead of dragging a
## camera-locked shell.
class_name UnderwaterParticulates
extends Node3D

const PARTICLE_SHADER_PATH := "res://src/core/water/shaders/underwater_particulates_particles.gdshader"
const BILLBOARD_SHADER_PATH := "res://src/core/water/shaders/underwater_particulates_billboard.gdshader"
const DEFAULT_WINDOW_RADIUS_M := 18.0
const DEFAULT_VERTICAL_HALF_EXTENT_M := 5.0
const SPAWN_ANCHOR_CELL_M := 4.0
const VISIBILITY_MARGIN_M := SPAWN_ANCHOR_CELL_M * 0.75

enum QualityTier { OFF, LOW, MEDIUM, HIGH }

var enabled: bool = false:
	set(value):
		enabled = value
		_apply_runtime_state()

var quality_tier: QualityTier = QualityTier.MEDIUM:
	set(value):
		quality_tier = value
		_apply_quality()

var opacity: float = 1.0:
	set(value):
		opacity = clampf(value, 0.0, 2.0)
		if _draw_material:
			_draw_material.set_shader_parameter(&"alpha_multiplier", opacity)
		if _process_material:
			_process_material.set_shader_parameter(&"mote_opacity", opacity)

var particle_count: int = 4096:
	set(value):
		particle_count = clampi(value, 0, 8192)
		_apply_particle_count()

var size_scale: float = 4.0:
	set(value):
		size_scale = clampf(value, 0.25, 4.0)
		if _process_material:
			_process_material.set_shader_parameter(&"mote_size_scale", size_scale)

var speed_scale: float = 1.5:
	set(value):
		speed_scale = clampf(value, 0.0, 4.0)
		if _process_material:
			_process_material.set_shader_parameter(&"drift_speed_scale", speed_scale)

var _camera: Camera3D = null
var _particles: GPUParticles3D = null
var _process_material: ShaderMaterial = null
var _draw_material: ShaderMaterial = null
var _sea_level: float = 0.0
var _water_state: WaterSurfaceState = null
var _surface_level: float = 0.0
var _camera_water_depth: float = 0.0
var _spawn_center: Vector3 = Vector3.ZERO
var _current_direction_xz: Vector2 = Vector2(0.35, 0.14).normalized()
var _current_strength: float = 0.35


func _ready() -> void:
	_build_particles()
	_apply_quality()
	_apply_runtime_state()


func _process(_delta: float) -> void:
	if _camera and is_instance_valid(_camera):
		var camera_pos := _camera.global_position
		global_position = camera_pos
		_spawn_center = _compute_spawn_center(camera_pos)
		var water_query := _sample_camera_water_query(camera_pos)
		_surface_level = float(water_query.get("height", _sea_level))
		_camera_water_depth = maxf(float(water_query.get("depth", 0.0)), 0.0)
	if _process_material == null:
		return
	_process_material.set_shader_parameter(&"camera_position", global_position)
	_process_material.set_shader_parameter(&"spawn_center", _spawn_center)
	_process_material.set_shader_parameter(&"sea_level", _surface_level)
	_process_material.set_shader_parameter(&"camera_water_depth", _camera_water_depth)
	_apply_runtime_state()


func set_camera(camera: Camera3D) -> void:
	_camera = camera
	if _camera and is_instance_valid(_camera):
		global_position = _camera.global_position
		_spawn_center = _compute_spawn_center(_camera.global_position)


func set_sea_level(value: float) -> void:
	_sea_level = value
	_surface_level = value
	if _process_material:
		_process_material.set_shader_parameter(&"sea_level", _sea_level)


func sync_from_water_state(state: WaterSurfaceState) -> void:
	_water_state = state
	if state != null:
		_sea_level = state.sea_level


func set_current(wind_t: float, current_dir_xz: Vector2) -> void:
	_current_strength = clampf(wind_t, 0.0, 1.0)
	var dir := current_dir_xz
	if dir.length_squared() < 0.0001:
		dir = Vector2(0.35, 0.14)
	_current_direction_xz = dir.normalized()
	if _process_material:
		_process_material.set_shader_parameter(&"current_direction", _current_direction_xz)
		_process_material.set_shader_parameter(&"current_strength", _current_strength)


func set_render_layers(mask: int) -> void:
	if _particles:
		_particles.layers = mask


func get_particle_count() -> int:
	if quality_tier == QualityTier.OFF:
		return 0
	return particle_count


func is_emitting() -> bool:
	return _particles.emitting if _particles else false


func get_runtime_status() -> Dictionary:
	return {
		"enabled": enabled,
		"visible": _particles.visible if _particles else false,
		"emitting": is_emitting(),
		"quality": int(quality_tier),
		"particle_count": get_particle_count(),
		"opacity": opacity,
		"size_scale": size_scale,
		"speed_scale": speed_scale,
		"camera_water_depth": _camera_water_depth,
	}


func _build_particles() -> void:
	_particles = GPUParticles3D.new()
	_particles.name = "UnderwaterParticulateMotes"
	_particles.local_coords = false
	_particles.lifetime = 6.0
	_particles.preprocess = 4.0
	_particles.randomness = 0.18
	_particles.fixed_fps = 30
	_particles.fract_delta = true
	_particles.interpolate = true
	_particles.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	_particles.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD
	_particles.visibility_aabb = AABB(
		Vector3(-DEFAULT_WINDOW_RADIUS_M - VISIBILITY_MARGIN_M, -DEFAULT_VERTICAL_HALF_EXTENT_M - VISIBILITY_MARGIN_M, -DEFAULT_WINDOW_RADIUS_M - VISIBILITY_MARGIN_M),
		Vector3((DEFAULT_WINDOW_RADIUS_M + VISIBILITY_MARGIN_M) * 2.0, (DEFAULT_VERTICAL_HALF_EXTENT_M + VISIBILITY_MARGIN_M) * 2.0, (DEFAULT_WINDOW_RADIUS_M + VISIBILITY_MARGIN_M) * 2.0)
	)
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_particles)

	_process_material = ShaderMaterial.new()
	_process_material.shader = load(PARTICLE_SHADER_PATH) as Shader
	_process_material.set_shader_parameter(&"window_radius_m", DEFAULT_WINDOW_RADIUS_M)
	_process_material.set_shader_parameter(&"vertical_half_extent_m", DEFAULT_VERTICAL_HALF_EXTENT_M)
	_process_material.set_shader_parameter(&"spawn_center", _spawn_center)
	_process_material.set_shader_parameter(&"sea_level", _sea_level)
	_process_material.set_shader_parameter(&"current_direction", _current_direction_xz)
	_process_material.set_shader_parameter(&"current_strength", _current_strength)
	_process_material.set_shader_parameter(&"mote_opacity", opacity)
	_process_material.set_shader_parameter(&"mote_size_scale", size_scale)
	_process_material.set_shader_parameter(&"drift_speed_scale", speed_scale)
	_particles.process_material = _process_material

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_draw_material = ShaderMaterial.new()
	_draw_material.shader = load(BILLBOARD_SHADER_PATH) as Shader
	_draw_material.set_shader_parameter(&"alpha_multiplier", opacity)
	quad.material = _draw_material
	_particles.draw_pass_1 = quad


func _apply_quality() -> void:
	if _particles == null:
		return
	match quality_tier:
		QualityTier.OFF:
			particle_count = 0
		QualityTier.LOW:
			particle_count = 768
		QualityTier.MEDIUM:
			particle_count = 4096
		QualityTier.HIGH:
			particle_count = 4096
	_apply_runtime_state()


func _apply_particle_count() -> void:
	if _particles == null:
		return
	_particles.amount = maxi(particle_count, 8)
	_particles.amount_ratio = 0.0 if particle_count <= 0 else 1.0
	_apply_runtime_state()


func _apply_runtime_state() -> void:
	if _particles == null:
		return
	var active := enabled and particle_count > 0 and _camera_water_depth > 0.05
	_particles.emitting = active
	_particles.visible = active
	if not active:
		_particles.amount_ratio = 0.0
	else:
		_particles.amount_ratio = 1.0
	if _process_material:
		_process_material.set_shader_parameter(&"particles_enabled", active)


func _compute_spawn_center(camera_pos: Vector3) -> Vector3:
	var cell := maxf(SPAWN_ANCHOR_CELL_M, 0.5)
	return Vector3(
		roundf(camera_pos.x / cell) * cell,
		roundf(camera_pos.y / cell) * cell,
		roundf(camera_pos.z / cell) * cell
	)


func _sample_camera_water_query(world_pos: Vector3) -> Dictionary:
	if _water_state == null:
		return {
			"height": _sea_level,
			"depth": 0.0,
		}
	var query := _water_state.sample_surface_query(world_pos)
	var water_y := float(query.get("height", _sea_level))
	var has_body := bool(query.get("has_water_body", false)) and not is_nan(water_y) and water_y > -1.0e20
	return {
		"height": water_y if has_body else _sea_level,
		"depth": water_y - world_pos.y if has_body else 0.0,
	}
