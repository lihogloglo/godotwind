class_name WaterSystemClass
extends Node

const WaterWorldScript := preload("res://src/core/water/water_world.gd")
const OceanFFTProviderScript := preload("res://src/core/water/ocean_fft_provider.gd")
const WATER_LAYER_ALL := &"all"
const WATER_LAYER_OCEAN_SURFACE := &"ocean_surface"
const WATER_LAYER_RIVERS := &"rivers"
const WATER_LAYER_LAKES_POOLS := &"lakes_pools"
const WATER_LAYER_QUERIES := &"queries"
const WATER_LAYER_INTERACTIONS := &"interactions"

@export var ocean_radius: float = 50000.0:
	set(value):
		ocean_radius = value
		if _ocean_provider != null:
			_ocean_provider.ocean_radius = value

@export var sea_level: float = 0.0:
	set(value):
		if is_equal_approx(sea_level, value):
			sea_level = value
			return
		sea_level = value
		if _water_world != null:
			_water_world.set_sea_level(value)
		elif _ocean_provider != null:
			_ocean_provider.set_sea_level(value)

@export var water_quality: int = -1:
	set(value):
		water_quality = value
		if _ocean_provider != null:
			_ocean_provider.water_quality = value

@export var water_mesh_mode: int = 0:
	set(value):
		water_mesh_mode = value
		if _ocean_provider != null:
			_ocean_provider.water_mesh_mode = value

@export var wave_scale: float = 1.0:
	set(value):
		if is_equal_approx(wave_scale, value):
			wave_scale = value
			return
		wave_scale = value
		if _ocean_provider != null:
			_ocean_provider.set_wave_scale(value)

@export var use_prebaked_shore_mask: bool = true:
	set(value):
		use_prebaked_shore_mask = value
		if _ocean_provider != null:
			_ocean_provider.use_prebaked_shore_mask = value

@export var use_gpu_wave_readback: bool = false:
	set(value):
		use_gpu_wave_readback = value
		if _ocean_provider != null:
			_ocean_provider.use_gpu_wave_readback = value

@export var sea_spray_enabled: bool = true:
	set(value):
		sea_spray_enabled = value
		if _ocean_provider != null:
			_ocean_provider.set_sea_spray_enabled(value)

@export var underwater_particles_enabled: bool = false:
	set(value):
		underwater_particles_enabled = value
		if _water_world != null:
			_water_world.set_underwater_particles_enabled(value)

@export var water_body_atlas_enabled: bool = false:
	set(value):
		water_body_atlas_enabled = value
		if _water_world != null:
			_water_world.set_water_body_atlas_enabled(value)
		if _ocean_provider != null and _ocean_provider.has_method("set_water_body_atlas_enabled"):
			_ocean_provider.call("set_water_body_atlas_enabled", value)

var world: Node = null
var ocean_provider: Node = null

# Backward-facing debug aliases for existing labs/tests. They point at the new
# owners and are not part of the public water architecture.
var _ocean_mesh: OceanMesh = null
var _terrain: Terrain3D = null
var _cascade_parameters: Array[WaveCascadeParameters] = []
var _displacement_cpu_per_cascade: Array[PackedByteArray] = []
var _current_shore_wave_amplitude: float = 0.0
var _water_interaction_sim: WaterInteractionSim = null
var _water_interaction_renderers: Array[Node] = []

var _water_world: Node = null
var _ocean_provider: Node = null


func _init() -> void:
	_ensure_runtime()


func _ready() -> void:
	_ensure_runtime()
	_refresh_ocean_aliases()
	set_process(true)


func _ensure_runtime() -> void:
	if _water_world != null and _ocean_provider != null:
		return
	if _water_world == null:
		_water_world = WaterWorldScript.new()
		_water_world.name = "WaterWorld"
		add_child(_water_world)
		world = _water_world
	if _ocean_provider == null:
		_ocean_provider = OceanFFTProviderScript.new()
		_ocean_provider.name = "OceanFFTProvider"
		_ocean_provider.ocean_radius = ocean_radius
		_ocean_provider.sea_level = sea_level
		_ocean_provider.water_quality = water_quality
		_ocean_provider.water_mesh_mode = water_mesh_mode
		_ocean_provider.wave_scale = wave_scale
		_ocean_provider.use_prebaked_shore_mask = use_prebaked_shore_mask
		_ocean_provider.use_gpu_wave_readback = use_gpu_wave_readback
		_ocean_provider.sea_spray_enabled = sea_spray_enabled
		add_child(_ocean_provider)
		ocean_provider = _ocean_provider
	_water_world.set_ocean_provider(_ocean_provider)
	_water_world.set_sea_level(sea_level)
	_water_world.set_underwater_particles_enabled(underwater_particles_enabled)
	_water_world.set_water_body_atlas_enabled(water_body_atlas_enabled)
	if _ocean_provider.has_method("set_water_body_atlas_enabled"):
		_ocean_provider.call("set_water_body_atlas_enabled", water_body_atlas_enabled)


func _process(_delta: float) -> void:
	_refresh_ocean_aliases()


func get_ocean_provider() -> Node:
	return _ocean_provider


func get_water_world() -> Node:
	return _water_world


func get_water_surface_state() -> WaterSurfaceState:
	return _water_world.get_water_surface_state()


func register_water_body(body: RefCounted) -> Error:
	return _water_world.register_water_body(body)


func unregister_water_body(body: RefCounted) -> void:
	_water_world.unregister_water_body(body)


func unregister_water_body_id(body_id: StringName) -> void:
	_water_world.unregister_water_body_id(body_id)


func register_water_body_provider(provider: RefCounted) -> Error:
	return _water_world.register_water_body_provider(provider)


func unregister_water_body_provider(provider: RefCounted) -> void:
	_water_world.unregister_water_body_provider(provider)


func set_world_water_provider(provider: RefCounted) -> Error:
	return _water_world.set_world_water_provider(provider)


func get_water_body_runtime_status() -> Dictionary:
	return _water_world.get_water_body_runtime_status()


func set_water_body_atlas_enabled(enabled: bool) -> void:
	water_body_atlas_enabled = enabled


func is_water_body_atlas_enabled() -> bool:
	return _water_world != null and _water_world.is_water_body_atlas_enabled()


func force_update_water_body_atlas(center: Vector3) -> void:
	_water_world.force_update_water_body_atlas(center)


func get_water_body_registry() -> RefCounted:
	return _water_world.get_water_body_registry()


func get_water_body_atlas_texture() -> Texture2D:
	return _water_world.get_water_body_atlas_texture()


func get_water_body_atlas_texture_rd() -> RID:
	return _water_world.get_water_body_atlas_texture_rd()


func get_water_body_atlas_image() -> Image:
	return _water_world.get_water_body_atlas_image()


func get_water_body_atlas_bounds_rect() -> Rect2:
	return _water_world.get_water_body_atlas_bounds_rect()


func get_water_body_atlas_bounds() -> Vector4:
	return _water_world.get_water_body_atlas_bounds()


func has_water_body_atlas() -> bool:
	return _water_world.has_water_body_atlas()


func sample_water_body_atlas(world_pos: Vector3) -> Dictionary:
	return _water_world.sample_water_body_atlas(world_pos)


func sample_water_height(world_pos: Vector3) -> float:
	return _water_world.sample_water_height(world_pos)


func sample_water_displacement(world_pos: Vector3) -> Vector3:
	return _water_world.sample_water_displacement(world_pos)


func sample_water_normal(world_pos: Vector3) -> Vector3:
	return _water_world.sample_water_normal(world_pos)


func sample_water_gradient(world_pos: Vector3) -> Vector2:
	return _water_world.sample_water_gradient(world_pos)


func sample_water_velocity(world_pos: Vector3) -> Vector3:
	return _water_world.sample_water_velocity(world_pos)


func sample_base_water_velocity(world_pos: Vector3) -> Vector3:
	return _water_world.sample_base_water_velocity(world_pos)


func sample_water_coverage(world_pos: Vector3) -> float:
	return _water_world.sample_water_coverage(world_pos)


func sample_signed_water_shore_distance(world_pos: Vector3) -> float:
	return _water_world.sample_signed_water_shore_distance(world_pos)


func sample_water_shore_side(world_pos: Vector3) -> int:
	return _water_world.sample_water_shore_side(world_pos)


func sample_water_body_id_at(world_pos: Vector3) -> StringName:
	return _water_world.sample_water_body_id_at(world_pos)


func sample_water_surface_query(world_pos: Vector3) -> Dictionary:
	return _water_world.sample_water_surface_query(world_pos)


func emit_water_impulse(
	world_pos: Vector3,
	radius_m: float,
	strength: float,
	kind: StringName = &"impact",
	body_id: StringName = &"",
	wake_direction: Vector2 = Vector2.ZERO,
	wake_length_m: float = 0.0,
) -> void:
	_water_world.emit_water_impulse(world_pos, radius_m, strength, kind, body_id, wake_direction, wake_length_m)


func emit_water_flow_obstacle(
	world_pos: Vector3,
	radius_m: float,
	block_strength: float,
	wake_strength: float,
	body_id: StringName = &""
) -> void:
	_water_world.emit_water_flow_obstacle(world_pos, radius_m, block_strength, wake_strength, body_id)


func register_water_interactor(node: Node, options: Dictionary = {}) -> void:
	_water_world.register_water_interactor(node, options)


func unregister_water_interactor(node: Node) -> void:
	_water_world.unregister_water_interactor(node)


func register_water_interaction_renderer(node: Node) -> void:
	_water_world.register_water_interaction_renderer(node)


func unregister_water_interaction_renderer(node: Node) -> void:
	_water_world.unregister_water_interaction_renderer(node)


func get_water_interaction_texture() -> Texture2D:
	return _water_world.get_water_interaction_texture()


func get_water_dynamic_flow_texture() -> Texture2D:
	return _water_world.get_water_dynamic_flow_texture()


func get_water_interaction_bounds() -> Vector4:
	return _water_world.get_water_interaction_bounds()


func get_water_interaction_stats() -> Dictionary:
	return _water_world.get_water_interaction_stats()


func set_water_interaction_debug_enabled(enabled: bool) -> void:
	_water_world.set_water_interaction_debug_enabled(enabled)


func is_water_interaction_debug_enabled() -> bool:
	return _water_world.is_water_interaction_debug_enabled()


func update_local_water_interactions(delta: float, center_world: Vector3 = Vector3.INF) -> void:
	_water_world.update_local_water_interactions(delta, center_world)


func set_camera(camera: Camera3D) -> void:
	_water_world.set_camera(camera)


func set_terrain(terrain: Terrain3D) -> void:
	_terrain = terrain
	_water_world.set_terrain(terrain)


func set_sea_level(level: float) -> void:
	if is_equal_approx(sea_level, level):
		return
	sea_level = level
	if _water_world != null:
		_water_world.set_sea_level(level)


func get_sea_level() -> float:
	return _water_world.get_sea_level()


func set_underwater_particles_enabled(enabled: bool) -> void:
	underwater_particles_enabled = enabled
	_water_world.set_underwater_particles_enabled(enabled)


func is_underwater_particles_enabled() -> bool:
	return _water_world.is_underwater_particles_enabled()


func set_underwater_particles_quality(quality: int) -> void:
	_water_world.set_underwater_particles_quality(quality)


func get_underwater_particles_quality() -> int:
	return _water_world.get_underwater_particles_quality()


func get_underwater_particles_quality_name() -> String:
	return _water_world.get_underwater_particles_quality_name()


func set_underwater_particles_opacity(value: float) -> void:
	_water_world.set_underwater_particles_opacity(value)


func set_underwater_particles_count(value: int) -> void:
	_water_world.set_underwater_particles_count(value)


func set_underwater_particles_size_scale(value: float) -> void:
	_water_world.set_underwater_particles_size_scale(value)


func set_underwater_particles_speed_scale(value: float) -> void:
	_water_world.set_underwater_particles_speed_scale(value)


func get_underwater_particles_status() -> Dictionary:
	return _water_world.get_underwater_particles_status()


func set_underwater_particles_render_layers(mask: int) -> void:
	_water_world.set_underwater_particles_render_layers(mask)


func get_wave_height(world_pos: Vector3) -> float:
	return _ocean_provider.get_wave_height(world_pos) if _ocean_provider != null else get_sea_level()


func get_wave_displacement(world_pos: Vector3) -> Vector3:
	return _ocean_provider.get_wave_displacement(world_pos) if _ocean_provider != null else Vector3.ZERO


func get_wave_normal(world_pos: Vector3) -> Vector3:
	return _ocean_provider.get_wave_normal(world_pos) if _ocean_provider != null else Vector3.UP


func get_wave_gradient(world_pos: Vector3) -> Vector2:
	return _ocean_provider.get_wave_gradient(world_pos) if _ocean_provider != null else Vector2.ZERO


func get_wave_velocity(world_pos: Vector3) -> Vector3:
	return _ocean_provider.get_wave_velocity(world_pos) if _ocean_provider != null else Vector3.ZERO


func get_water_coverage(world_pos: Vector3) -> float:
	return _ocean_provider.get_water_coverage(world_pos) if _ocean_provider != null else 0.0


func get_signed_shore_distance(world_pos: Vector3) -> float:
	return _ocean_provider.get_signed_shore_distance(world_pos) if _ocean_provider != null else -INF


func get_shore_side(world_pos: Vector3) -> int:
	return _ocean_provider.get_shore_side(world_pos) if _ocean_provider != null else WaterSurfaceState.SHORE_SIDE_UNKNOWN


func get_water_body_id_at(world_pos: Vector3) -> StringName:
	return _ocean_provider.get_water_body_id_at(world_pos) if _ocean_provider != null else WaterSurfaceState.WATER_BODY_NONE


func is_in_ocean(world_pos: Vector3) -> bool:
	return _ocean_provider.is_in_ocean(world_pos) if _ocean_provider != null else false


func is_camera_submerged() -> bool:
	var state := get_water_surface_state()
	return state != null and state.has_camera_water()


func force_initialize() -> void:
	if _ocean_provider != null:
		_ocean_provider.force_initialize()
		_refresh_ocean_aliases()


func set_enabled(enabled: bool) -> void:
	if _ocean_provider != null:
		_ocean_provider.set_enabled(enabled)
		if _water_world != null:
			_water_world.set_water_layer_enabled(WATER_LAYER_OCEAN_SURFACE, enabled)
		_refresh_ocean_aliases()


func toggle_ocean() -> bool:
	if _ocean_provider == null:
		return false
	var enabled: bool = _ocean_provider.toggle_ocean()
	_refresh_ocean_aliases()
	return enabled


func is_system_enabled() -> bool:
	return _ocean_provider != null and _ocean_provider.is_system_enabled()


func set_all_water_enabled(enabled: bool) -> void:
	set_water_layer_enabled(WATER_LAYER_ALL, enabled)


func set_water_layer_enabled(layer: StringName, enabled: bool) -> void:
	if _water_world != null:
		_water_world.set_water_layer_enabled(layer, enabled)


func is_water_layer_enabled(layer: StringName) -> bool:
	return _water_world != null and _water_world.is_water_layer_enabled(layer)


func get_water_toggle_state() -> Dictionary:
	return _water_world.get_water_toggle_state() if _water_world != null else {}


func get_generated_water_root() -> Node3D:
	return _water_world.get_generated_water_root() if _water_world != null else null


func get_generated_water_layer_root(body_type: StringName) -> Node3D:
	return _water_world.get_generated_water_layer_root(body_type) if _water_world != null else null


func add_generated_water_node(water_node: Node3D, body_type: StringName) -> void:
	if _water_world != null:
		_water_world.add_generated_water_node(water_node, body_type)


func is_initialized() -> bool:
	return _ocean_provider != null and _ocean_provider.is_initialized()


func get_time() -> float:
	return _ocean_provider.get_time() if _ocean_provider != null else 0.0


func set_wave_scale(value: float) -> void:
	wave_scale = value
	if _ocean_provider != null:
		_ocean_provider.set_wave_scale(value)


func get_ocean_mesh() -> OceanMesh:
	return _ocean_provider.get_ocean_mesh() if _ocean_provider != null else null


func get_ocean_spray() -> OceanSpray:
	return _ocean_provider.get_ocean_spray() if _ocean_provider != null else null


func set_sea_spray_enabled(enabled: bool) -> void:
	sea_spray_enabled = enabled
	if _ocean_provider != null:
		_ocean_provider.set_sea_spray_enabled(enabled)


func toggle_sea_spray() -> bool:
	return _ocean_provider.toggle_sea_spray() if _ocean_provider != null else false


func is_sea_spray_enabled() -> bool:
	return _ocean_provider.is_sea_spray_enabled() if _ocean_provider != null else false


func set_sea_spray_quality(quality: int) -> void:
	if _ocean_provider != null:
		_ocean_provider.set_sea_spray_quality(quality)


func get_sea_spray_quality() -> int:
	return _ocean_provider.get_sea_spray_quality() if _ocean_provider != null else 0


func get_sea_spray_quality_name() -> String:
	return _ocean_provider.get_sea_spray_quality_name() if _ocean_provider != null else "Off"


func get_sea_spray_energy() -> float:
	return _ocean_provider.get_sea_spray_energy() if _ocean_provider != null else 0.0


func get_sea_spray_status() -> Dictionary:
	return _ocean_provider.get_sea_spray_status() if _ocean_provider != null else {}


func set_sea_spray_render_layers(mask: int) -> void:
	if _ocean_provider != null:
		_ocean_provider.set_sea_spray_render_layers(mask)


func get_shore_mask_generator() -> ShoreMaskGenerator:
	return _ocean_provider.get_shore_mask_generator() if _ocean_provider != null else null


func get_water_quality() -> OceanMesh.QualityMode:
	return _ocean_provider.get_water_quality() if _ocean_provider != null else OceanMesh.QualityMode.FLAT


func rebuild_mesh_with_mode(new_mode: int) -> void:
	if _ocean_provider != null:
		_ocean_provider.rebuild_mesh_with_mode(new_mode)
		_refresh_ocean_aliases()


func get_mesh_mode() -> int:
	return _ocean_provider.get_mesh_mode() if _ocean_provider != null else 0


func get_surface_shader_mode() -> int:
	return _ocean_provider.get_surface_shader_mode() if _ocean_provider != null else 0


func get_surface_shader_mode_name() -> String:
	return _ocean_provider.get_surface_shader_mode_name() if _ocean_provider != null else "Unknown"


func set_surface_shader_mode(mode: int) -> void:
	if _ocean_provider != null:
		_ocean_provider.set_surface_shader_mode(mode)


func set_water_quality(quality: int) -> void:
	water_quality = quality
	if _ocean_provider != null:
		_ocean_provider.set_water_quality(quality)
		_refresh_ocean_aliases()


func get_water_quality_name() -> String:
	return _ocean_provider.get_water_quality_name() if _ocean_provider != null else "Disabled"


func set_choppiness(value: float) -> void:
	if _ocean_provider != null:
		_ocean_provider.set_choppiness(value)


func set_wind_strength(value: float) -> void:
	if _ocean_provider != null:
		_ocean_provider.set_wind_strength(value)


func apply_weather(result: WeatherTypes.WeatherResult) -> void:
	if _ocean_provider != null:
		_ocean_provider.apply_weather(result)


func reset_weather() -> void:
	if _ocean_provider != null:
		_ocean_provider.reset_weather()


func set_debug_mode(mode: int) -> void:
	if _ocean_provider != null:
		_ocean_provider.set_debug_mode(mode)


func get_water_optical_profile() -> WaterOpticalProfile:
	return _ocean_provider.get_water_optical_profile() if _ocean_provider != null else WaterOpticalProfile.new()


func get_absorption_tint() -> Vector3:
	return _ocean_provider.get_absorption_tint() if _ocean_provider != null else Vector3.ZERO


func get_absorption_sigma() -> Vector3:
	return _ocean_provider.get_absorption_sigma() if _ocean_provider != null else Vector3.ZERO


func get_absorption_density() -> float:
	return _ocean_provider.get_absorption_density() if _ocean_provider != null else 0.0


func set_absorption_density(value: float) -> void:
	if _ocean_provider != null:
		_ocean_provider.set_absorption_density(value)


func get_water_visibility_distance() -> float:
	return _ocean_provider.get_water_visibility_distance() if _ocean_provider != null else 0.0


func set_water_visibility_distance(value: float) -> void:
	if _ocean_provider != null:
		_ocean_provider.set_water_visibility_distance(value)


func get_water_scattering_strength() -> float:
	return _ocean_provider.get_water_scattering_strength() if _ocean_provider != null else 0.0


func set_water_scattering_strength(value: float) -> void:
	if _ocean_provider != null:
		_ocean_provider.set_water_scattering_strength(value)


func get_water_scattering_color() -> Color:
	return _ocean_provider.get_water_scattering_color() if _ocean_provider != null else Color.BLACK


func set_water_scattering_color(value: Color) -> void:
	if _ocean_provider != null:
		_ocean_provider.set_water_scattering_color(value)


func get_absorption_tint_color() -> Color:
	return _ocean_provider.get_absorption_tint_color() if _ocean_provider != null else Color.BLACK


func set_absorption_tint_color(value: Color) -> void:
	if _ocean_provider != null:
		_ocean_provider.set_absorption_tint_color(value)


func clear_absorption_tint_override() -> void:
	if _ocean_provider != null:
		_ocean_provider.clear_absorption_tint_override()


func get_absorption_depth_falloff() -> float:
	return _ocean_provider.get_absorption_depth_falloff() if _ocean_provider != null else 0.0


func get_underwater_caustics_strength() -> float:
	return _ocean_provider.get_underwater_caustics_strength() if _ocean_provider != null else 0.0


func is_surface_ssr_enabled() -> bool:
	return _ocean_provider.is_surface_ssr_enabled() if _ocean_provider != null else false


func set_surface_ssr_enabled(enabled: bool) -> void:
	if _ocean_provider != null:
		_ocean_provider.set_surface_ssr_enabled(enabled)


func get_displacement_texture_rd() -> RID:
	return _ocean_provider.get_displacement_texture_rd() if _ocean_provider != null else RID()


func get_normal_texture_rd() -> RID:
	return _ocean_provider.get_normal_texture_rd() if _ocean_provider != null else RID()


func is_gpu_wave_readback_enabled() -> bool:
	return _ocean_provider.is_gpu_wave_readback_enabled() if _ocean_provider != null else false


func set_gpu_wave_readback_enabled(enabled: bool) -> void:
	if _ocean_provider != null:
		_ocean_provider.set_gpu_wave_readback_enabled(enabled)


func get_water_query_source() -> StringName:
	return _water_world.get_water_query_source()


func get_water_query_readback_bytes_per_frame() -> int:
	return _water_world.get_water_query_readback_bytes_per_frame()


func get_fft_cascade_count() -> int:
	return _ocean_provider.get_fft_cascade_count() if _ocean_provider != null else 0


func release_runtime_resources() -> void:
	if _ocean_provider != null:
		_ocean_provider.release_runtime_resources()
		_refresh_ocean_aliases()


func _get_shore_factor(world_pos: Vector3) -> float:
	return _ocean_provider._get_shore_factor(world_pos) if _ocean_provider != null else 1.0


func _sample_displacement_readback_cascade(world_pos: Vector3, buf: PackedByteArray, tile_length: Vector2) -> Vector3:
	return _ocean_provider._sample_displacement_readback_cascade(world_pos, buf, tile_length) if _ocean_provider != null else Vector3.ZERO


func _refresh_ocean_aliases() -> void:
	if _ocean_provider != null:
		_ocean_mesh = _ocean_provider.get_ocean_mesh()
		_cascade_parameters = _ocean_provider.get_cascade_parameters()
		_displacement_cpu_per_cascade = _ocean_provider.get_displacement_cpu_per_cascade()
		_current_shore_wave_amplitude = _ocean_provider.get_shore_wave_amplitude()
		wave_scale = _ocean_provider.get_wave_scale()
		sea_level = _ocean_provider.get_sea_level()
	if _water_world != null:
		_water_interaction_sim = _water_world.get("_water_interaction_sim") as WaterInteractionSim
		_water_interaction_renderers = _water_world.get("_water_interaction_renderers")
