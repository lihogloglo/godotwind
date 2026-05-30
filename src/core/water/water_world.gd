class_name WaterWorld
extends Node

const UnderwaterParticulatesScript := preload("res://src/core/water/underwater_particulates.gd")
const WaterBodyRegistryScript := preload("res://src/core/water/water_body_registry.gd")
const WaterInteractionSimScript := preload("res://src/core/water/water_interaction_sim.gd")

const WATER_BODY_ATLAS_RESOLUTION := 128
const WATER_BODY_ATLAS_EXTENT_M := 512.0
const WATER_BODY_ATLAS_UPDATE_MOVE_M := 2.0
const SETTING_SEA_LEVEL := "ocean/sea_level"
const LAYER_ALL := &"all"
const LAYER_OCEAN_SURFACE := &"ocean_surface"
const LAYER_RIVERS := &"rivers"
const LAYER_LAKES_POOLS := &"lakes_pools"
const LAYER_QUERIES := &"queries"
const LAYER_INTERACTIONS := &"interactions"

@export var sea_level: float = 0.0
@export var water_body_atlas_enabled: bool = false

@export_group("Underwater Particles")
@export var underwater_particles_enabled: bool = false
@export_range(0, 3) var underwater_particles_quality: int = 2
@export_range(0.0, 2.0) var underwater_particles_opacity: float = 1.0
@export_range(0, 8192) var underwater_particles_count: int = 4096
@export_range(0.25, 4.0) var underwater_particles_size_scale: float = 4.0
@export_range(0.0, 4.0) var underwater_particles_speed_scale: float = 1.5

var _ocean_provider: Node = null
var _underwater_particulates: UnderwaterParticulates = null
var _water_interaction_sim: WaterInteractionSim = null
var _water_body_registry: RefCounted = WaterBodyRegistryScript.new()
var _water_interactors: Array[Node] = []
var _water_interaction_renderers: Array[Node] = []
var _world_water_provider: RefCounted = null
var _water_interaction_debug_enabled: bool = false
var _water_interaction_sync_initialized: bool = false
var _water_interaction_last_texture: Texture2D = null
var _water_dynamic_flow_last_texture: Texture2D = null
var _water_interaction_last_bounds: Vector4 = Vector4.ZERO
var _water_interaction_last_enabled: bool = false
var _water_dynamic_flow_last_enabled: bool = false
var _water_interaction_last_debug: bool = false
var _water_interaction_last_body_atlas_texture: Texture2D = null
var _water_interaction_last_body_atlas_bounds: Vector4 = Vector4.ZERO
var _water_interaction_last_body_atlas_available: bool = false
var _water_interaction_last_surface_height: float = NAN
var _water_interaction_renderer_sync_count: int = 0
var _local_flow_obstacles: Array[Dictionary] = []
var _terrain: Terrain3D = null
var _camera: Camera3D = null
var _time: float = 0.0
var _auto_find_camera: bool = true
var _water_body_atlas_image: Image = null
var _water_body_atlas_texture: ImageTexture = null
var _water_body_atlas_rd: RID = RID()
var _water_body_atlas_bounds: Rect2 = Rect2()
var _water_body_atlas_center_xz: Vector2 = Vector2.INF
var _water_body_atlas_frame: int = -1
var _water_body_atlas_last_rebuild_usec: int = 0
var _water_body_atlas_total_rebuild_usec: int = 0
var _water_body_atlas_rebuild_count: int = 0
var _water_layers: Dictionary = {
	LAYER_ALL: true,
	LAYER_OCEAN_SURFACE: true,
	LAYER_RIVERS: true,
	LAYER_LAKES_POOLS: true,
	LAYER_QUERIES: true,
	LAYER_INTERACTIONS: true,
}
var _generated_water_root: Node3D = null
var _generated_rivers_root: Node3D = null
var _generated_lakes_root: Node3D = null


func _ready() -> void:
	sea_level = float(ProjectSettings.get_setting(SETTING_SEA_LEVEL, 0.0))
	_ensure_generated_water_roots()
	_setup_underwater_particulates_layer()
	_setup_water_interaction_layer()
	set_process(true)
	set_physics_process(true)


func _process(delta: float) -> void:
	_time = Time.get_ticks_msec() / 1000.0
	if not is_water_layer_enabled(LAYER_ALL):
		return
	if _camera == null and _auto_find_camera:
		_camera = _find_active_camera()
	if _camera != null and is_instance_valid(_camera):
		_update_water_body_atlas(_camera.global_position)
		if _underwater_particulates != null:
			_underwater_particulates.set_camera(_camera)
			_underwater_particulates.sync_from_water_state(get_water_surface_state())
	else:
		_clear_water_body_atlas()
	update_local_water_interactions(delta)


func _physics_process(delta: float) -> void:
	if not is_water_layer_enabled(LAYER_ALL) or not is_water_layer_enabled(LAYER_INTERACTIONS):
		return
	if _water_interactors.is_empty():
		return
	var state := get_water_surface_state()
	for i in range(_water_interactors.size() - 1, -1, -1):
		var interactor := _water_interactors[i]
		if not is_instance_valid(interactor):
			_water_interactors.remove_at(i)
			continue
		if not interactor.has_method("gather_impulses"):
			continue
		var impulses: Array = interactor.call("gather_impulses", delta, state)
		for impulse: Dictionary in impulses:
			emit_water_impulse(
				impulse["position"],
				float(impulse["radius_m"]),
				float(impulse["strength"]),
				impulse["kind"],
				impulse["body_id"],
				impulse.get("wake_direction", Vector2.ZERO),
				float(impulse.get("wake_length_m", 0.0))
			)
		if interactor.has_method("gather_flow_obstacles"):
			var obstacles: Array = interactor.call("gather_flow_obstacles", delta, state)
			for obstacle: Dictionary in obstacles:
				emit_water_flow_obstacle(
					obstacle["position"],
					float(obstacle["radius_m"]),
					float(obstacle.get("block_strength", 0.0)),
					float(obstacle.get("wake_strength", 0.0)),
					obstacle.get("body_id", WaterSurfaceState.WATER_BODY_NONE)
				)


func set_ocean_provider(provider: Node) -> void:
	if _ocean_provider != null:
		unregister_water_interaction_renderer(_ocean_provider)
	_ocean_provider = provider
	if _ocean_provider != null:
		register_water_interaction_renderer(_ocean_provider)
		_ocean_provider.set_sea_level(sea_level)
		if _camera != null:
			_ocean_provider.set_camera(_camera)
		if _terrain != null:
			_ocean_provider.set_terrain(_terrain)
	_apply_render_layer_visibility()


func get_ocean_provider() -> Node:
	return _ocean_provider


func set_camera(camera: Camera3D) -> void:
	_camera = camera
	_auto_find_camera = camera == null
	if _underwater_particulates != null:
		_underwater_particulates.set_camera(camera)
	if _ocean_provider != null:
		_ocean_provider.set_camera(camera)


func set_terrain(terrain: Terrain3D) -> void:
	_terrain = terrain
	if _ocean_provider != null:
		_ocean_provider.set_terrain(terrain)


func set_sea_level(level: float) -> void:
	sea_level = level
	if _ocean_provider != null:
		_ocean_provider.set_sea_level(level)
	_sync_water_interaction_to_renderers(true)


func get_sea_level() -> float:
	if _ocean_provider != null:
		return _ocean_provider.get_sea_level()
	return sea_level


func get_water_body_registry() -> RefCounted:
	return _water_body_registry


func set_water_layer_enabled(layer: StringName, enabled: bool) -> void:
	var normalized := _normalize_water_layer(layer)
	if normalized == &"":
		Log.warn("water", "WaterWorld: unknown water layer '%s'" % str(layer))
		return
	if bool(_water_layers.get(normalized, true)) == enabled:
		return
	_water_layers[normalized] = enabled
	match normalized:
		LAYER_ALL:
			_apply_all_water_enabled(enabled)
		LAYER_OCEAN_SURFACE, LAYER_RIVERS, LAYER_LAKES_POOLS:
			_apply_render_layer_visibility()
		LAYER_QUERIES:
			if not enabled:
				_clear_water_body_atlas()
		LAYER_INTERACTIONS:
			_sync_water_interaction_to_renderers(true)


func is_water_layer_enabled(layer: StringName) -> bool:
	var normalized := _normalize_water_layer(layer)
	if normalized == &"":
		return false
	if normalized == LAYER_ALL:
		return bool(_water_layers.get(LAYER_ALL, true))
	return bool(_water_layers.get(LAYER_ALL, true)) and bool(_water_layers.get(normalized, true))


func get_water_toggle_state() -> Dictionary:
	return _water_layers.duplicate()


func get_generated_water_root() -> Node3D:
	return _ensure_generated_water_roots()


func get_generated_water_layer_root(body_type: StringName) -> Node3D:
	_ensure_generated_water_roots()
	if body_type == WaterBodyDescriptor.TYPE_RIVER or body_type == LAYER_RIVERS:
		return _generated_rivers_root
	return _generated_lakes_root


func add_generated_water_node(water_node: Node3D, body_type: StringName) -> void:
	if water_node == null:
		return
	get_generated_water_layer_root(body_type).add_child(water_node)
	_apply_render_layer_visibility()


func register_water_body(body: RefCounted) -> Error:
	var err: Error = _water_body_registry.register_body(body)
	if err == OK:
		_clear_water_body_atlas()
	return err


func unregister_water_body(body: RefCounted) -> void:
	_water_body_registry.unregister_body(body)
	_clear_water_body_atlas()


func unregister_water_body_id(body_id: StringName) -> void:
	_water_body_registry.unregister_body_id(body_id)
	_clear_water_body_atlas()


func register_water_body_provider(provider: RefCounted) -> Error:
	var err: Error = _water_body_registry.register_provider(provider)
	if err == OK:
		_clear_water_body_atlas()
	return err


func unregister_water_body_provider(provider: RefCounted) -> void:
	_water_body_registry.unregister_provider(provider)
	_clear_water_body_atlas()


func set_world_water_provider(provider: RefCounted) -> Error:
	if _world_water_provider != null:
		_water_body_registry.unregister_provider(_world_water_provider)
	_world_water_provider = provider
	if provider == null:
		_clear_water_body_atlas()
		return OK
	return register_water_body_provider(provider)


func get_water_body_runtime_status() -> Dictionary:
	var registry_stats: Dictionary = {}
	if _water_body_registry.has_method("get_stats"):
		registry_stats = _water_body_registry.call("get_stats")
	return {
		"atlas_enabled": water_body_atlas_enabled,
		"atlas_available": has_water_body_atlas(),
		"atlas_rebuild_last_usec": _water_body_atlas_last_rebuild_usec,
		"atlas_rebuild_total_usec": _water_body_atlas_total_rebuild_usec,
		"atlas_rebuild_count": _water_body_atlas_rebuild_count,
		"atlas_resolution": WATER_BODY_ATLAS_RESOLUTION if has_water_body_atlas() else 0,
		"atlas_bounds": _water_body_atlas_bounds,
		"registry": registry_stats,
		"world_provider": _get_world_water_provider_status(),
	}


func set_water_body_atlas_enabled(enabled: bool) -> void:
	if water_body_atlas_enabled == enabled:
		return
	water_body_atlas_enabled = enabled
	if not water_body_atlas_enabled:
		_clear_water_body_atlas()
		_sync_water_interaction_to_renderers(true)


func is_water_body_atlas_enabled() -> bool:
	return water_body_atlas_enabled


func force_update_water_body_atlas(center: Vector3) -> void:
	if not water_body_atlas_enabled:
		_clear_water_body_atlas()
		return
	_rebuild_water_body_atlas(center)


func get_water_body_atlas_texture() -> Texture2D:
	return _water_body_atlas_texture


func get_water_body_atlas_texture_rd() -> RID:
	return _water_body_atlas_rd


func get_water_body_atlas_image() -> Image:
	return _water_body_atlas_image


func get_water_body_atlas_bounds_rect() -> Rect2:
	return _water_body_atlas_bounds


func get_water_body_atlas_bounds() -> Vector4:
	return Vector4(
		_water_body_atlas_bounds.position.x,
		_water_body_atlas_bounds.position.y,
		_water_body_atlas_bounds.size.x,
		_water_body_atlas_bounds.size.y
	)


func has_water_body_atlas() -> bool:
	return water_body_atlas_enabled and is_water_layer_enabled(LAYER_QUERIES) and _water_body_atlas_texture != null and _water_body_atlas_image != null and _water_body_atlas_bounds.size != Vector2.ZERO


func sample_water_body_atlas(world_pos: Vector3) -> Dictionary:
	if not has_water_body_atlas():
		return {}
	var uv := Vector2(
		(world_pos.x - _water_body_atlas_bounds.position.x) / maxf(_water_body_atlas_bounds.size.x, 0.001),
		(world_pos.z - _water_body_atlas_bounds.position.y) / maxf(_water_body_atlas_bounds.size.y, 0.001)
	)
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return {}
	var size := _water_body_atlas_image.get_size()
	var px := clampi(floori(uv.x * float(size.x)), 0, size.x - 1)
	var py := clampi(floori(uv.y * float(size.y)), 0, size.y - 1)
	var sample := _water_body_atlas_image.get_pixel(px, py)
	var coverage := clampf(sample.r, 0.0, 1.0)
	return {
		"coverage": coverage,
		"height": sample.g,
		"body_gate": smoothstep(WaterSurfaceState.COVERAGE_GATE_START, WaterSurfaceState.COVERAGE_GATE_END, coverage),
	}


func sample_water_height(world_pos: Vector3) -> float:
	if not is_water_layer_enabled(LAYER_QUERIES):
		return -INF
	if _local_water_queries_enabled():
		var registered_height: float = _water_body_registry.sample_height(world_pos, NAN)
		if not is_nan(registered_height):
			return registered_height
	if _ocean_active() and _ocean_provider.get_water_coverage(world_pos) > WaterSurfaceState.COVERAGE_GATE_START:
		return _ocean_provider.get_wave_height(world_pos)
	return -INF


func sample_water_displacement(world_pos: Vector3) -> Vector3:
	if not is_water_layer_enabled(LAYER_QUERIES):
		return Vector3.ZERO
	if _local_water_queries_enabled() and _water_body_registry.sample_coverage(world_pos, 0.0) > WaterSurfaceState.COVERAGE_GATE_START:
		return Vector3.ZERO
	return _ocean_provider.get_wave_displacement(world_pos) if _ocean_active() else Vector3.ZERO


func sample_water_normal(world_pos: Vector3) -> Vector3:
	if not is_water_layer_enabled(LAYER_QUERIES):
		return Vector3.UP
	if _local_water_queries_enabled() and _water_body_registry.sample_coverage(world_pos, 0.0) > WaterSurfaceState.COVERAGE_GATE_START:
		return _water_body_registry.sample_normal(world_pos, Vector3.UP)
	return _ocean_provider.get_wave_normal(world_pos) if _ocean_active() else Vector3.UP


func sample_water_gradient(world_pos: Vector3) -> Vector2:
	if not is_water_layer_enabled(LAYER_QUERIES):
		return Vector2.ZERO
	if _local_water_queries_enabled() and _water_body_registry.sample_coverage(world_pos, 0.0) > WaterSurfaceState.COVERAGE_GATE_START:
		return _water_body_registry.sample_gradient(world_pos, Vector2.ZERO)
	return _ocean_provider.get_wave_gradient(world_pos) if _ocean_active() else Vector2.ZERO


func sample_water_velocity(world_pos: Vector3) -> Vector3:
	return sample_base_water_velocity(world_pos) + _sample_local_flow_delta(world_pos)


func sample_base_water_velocity(world_pos: Vector3) -> Vector3:
	if not is_water_layer_enabled(LAYER_QUERIES):
		return Vector3.ZERO
	if _local_water_queries_enabled():
		var registered_velocity: Vector3 = _water_body_registry.sample_velocity(world_pos, Vector3.INF)
		if registered_velocity != Vector3.INF:
			return registered_velocity
	return _ocean_provider.get_wave_velocity(world_pos) if _ocean_active() else Vector3.ZERO


func sample_water_coverage(world_pos: Vector3) -> float:
	if not is_water_layer_enabled(LAYER_QUERIES):
		return 0.0
	if _local_water_queries_enabled():
		var registered_coverage: float = _water_body_registry.sample_coverage(world_pos, 0.0)
		if registered_coverage > WaterSurfaceState.COVERAGE_GATE_START:
			return registered_coverage
	return _ocean_provider.get_water_coverage(world_pos) if _ocean_active() else 0.0


func sample_signed_water_shore_distance(world_pos: Vector3) -> float:
	if not is_water_layer_enabled(LAYER_QUERIES):
		return -INF
	if _local_water_queries_enabled() and _water_body_registry.sample_coverage(world_pos, 0.0) > WaterSurfaceState.COVERAGE_GATE_START:
		return 0.0
	return _ocean_provider.get_signed_shore_distance(world_pos) if _ocean_active() else -INF


func sample_water_shore_side(world_pos: Vector3) -> int:
	if not is_water_layer_enabled(LAYER_QUERIES):
		return WaterSurfaceState.SHORE_SIDE_UNKNOWN
	if _local_water_queries_enabled() and _water_body_registry.sample_coverage(world_pos, 0.0) > WaterSurfaceState.COVERAGE_GATE_START:
		return WaterSurfaceState.SHORE_SIDE_WATER
	return _ocean_provider.get_shore_side(world_pos) if _ocean_active() else WaterSurfaceState.SHORE_SIDE_UNKNOWN


func sample_water_body_id_at(world_pos: Vector3) -> StringName:
	if not is_water_layer_enabled(LAYER_QUERIES):
		return WaterSurfaceState.WATER_BODY_NONE
	if _local_water_queries_enabled():
		var registered_id: StringName = _water_body_registry.sample_water_body_id(world_pos, WaterSurfaceState.WATER_BODY_NONE)
		if registered_id != WaterSurfaceState.WATER_BODY_NONE:
			return registered_id
	return _ocean_provider.get_water_body_id_at(world_pos) if _ocean_active() else WaterSurfaceState.WATER_BODY_NONE


func sample_water_surface_query(world_pos: Vector3) -> Dictionary:
	if not is_water_layer_enabled(LAYER_QUERIES):
		return {}
	if _local_water_queries_enabled():
		var registered: Dictionary = _water_body_registry.sample_surface_query(world_pos)
		if not registered.is_empty():
			return registered
	if not _ocean_active():
		return {}
	var coverage: float = _ocean_provider.get_water_coverage(world_pos)
	var has_ocean: bool = coverage > WaterSurfaceState.COVERAGE_GATE_START
	var height: float = _ocean_provider.get_wave_height(world_pos) if has_ocean else -INF
	return {
		"height": height,
		"displacement": _ocean_provider.get_wave_displacement(world_pos) if has_ocean else Vector3.ZERO,
		"normal": _ocean_provider.get_wave_normal(world_pos) if has_ocean else Vector3.UP,
		"gradient": _ocean_provider.get_wave_gradient(world_pos) if has_ocean else Vector2.ZERO,
		"velocity": _ocean_provider.get_wave_velocity(world_pos) if has_ocean else Vector3.ZERO,
		"coverage": coverage if has_ocean else 0.0,
		"body_gate": WaterSurfaceState.coverage_to_body_gate_static(coverage if has_ocean else 0.0),
		"depth": height - world_pos.y if has_ocean else -INF,
		"water_body_id": _ocean_provider.get_water_body_id_at(world_pos) if has_ocean else WaterSurfaceState.WATER_BODY_NONE,
		"has_water_body": has_ocean,
		"coverage_source": get_water_query_source(),
	}


func get_water_surface_state() -> WaterSurfaceState:
	var state: WaterSurfaceState = _ocean_provider.get_water_surface_state() if _ocean_provider != null else WaterSurfaceState.new()
	var frame_id := Engine.get_process_frames()
	var has_registered_water: bool = _local_water_queries_enabled() and _water_body_registry.has_sources()
	state.sea_level = get_sea_level()
	state.ocean_time = _time
	if _water_interaction_sim != null:
		state.interaction_texture_rd = _water_interaction_sim.get_texture_rd()
		state.interaction_bounds = _water_interaction_sim.get_bounds()
		state.interaction_ready = state.interaction_texture_rd.is_valid()
	if _ocean_active():
		state.water_body_id = WaterSurfaceState.WATER_BODY_OCEAN
	elif has_registered_water:
		state.water_body_id = WaterSurfaceState.WATER_BODY_REGISTERED
	else:
		state.water_body_id = WaterSurfaceState.WATER_BODY_NONE
	state.water_body_index = 1 if _ocean_active() else 0
	state.coverage_available = _ocean_active() or has_registered_water
	if _camera != null and is_instance_valid(_camera):
		var camera_pos := _camera.global_position
		state.camera_water_coverage = sample_water_coverage(camera_pos)
		state.camera_water_body_id = sample_water_body_id_at(camera_pos)
		if state.camera_water_coverage > WaterSurfaceState.COVERAGE_GATE_START and state.camera_water_body_id != WaterSurfaceState.WATER_BODY_NONE:
			state.camera_water_level = sample_water_height(camera_pos)
		else:
			state.camera_water_level = NAN
	if has_registered_water:
		state.coverage_source = &"water_body_registry"
	elif _ocean_active():
		state.coverage_source = _ocean_provider.get_water_surface_state().coverage_source
	else:
		state.coverage_source = &"none"
	if has_water_body_atlas():
		state.water_body_atlas_texture = _water_body_atlas_texture
		state.water_body_atlas_image = _water_body_atlas_image
		state.water_body_atlas_rd = _water_body_atlas_rd
		state.water_body_atlas_bounds = get_water_body_atlas_bounds()
		state.water_body_atlas_resolution = Vector2i(WATER_BODY_ATLAS_RESOLUTION, WATER_BODY_ATLAS_RESOLUTION)
		state.water_body_atlas_available = true
	else:
		state.water_body_atlas_texture = null
		state.water_body_atlas_image = null
		state.water_body_atlas_rd = RID()
		state.water_body_atlas_bounds = Vector4.ZERO
		state.water_body_atlas_resolution = Vector2i.ZERO
		state.water_body_atlas_available = false
	state.snapshot_frame_id = frame_id
	state.surface_data_frame_id = frame_id
	state.cpu_query_available = _ocean_active() or has_registered_water
	state.cpu_query_source = get_water_query_source()
	state.cpu_readback_bytes_per_frame = get_water_query_readback_bytes_per_frame()
	state.height_query = Callable(self, "sample_water_height")
	state.displacement_query = Callable(self, "sample_water_displacement")
	state.normal_query = Callable(self, "sample_water_normal")
	state.gradient_query = Callable(self, "sample_water_gradient")
	state.velocity_query = Callable(self, "sample_water_velocity")
	state.base_velocity_query = Callable(self, "sample_base_water_velocity")
	state.coverage_query = Callable(self, "sample_water_coverage")
	state.signed_shore_distance_query = Callable(self, "sample_signed_water_shore_distance")
	state.shore_side_query = Callable(self, "sample_water_shore_side")
	state.water_body_id_query = Callable(self, "sample_water_body_id_at")
	state.surface_query = Callable(self, "sample_water_surface_query")
	return state


func get_water_query_source() -> StringName:
	if not is_water_layer_enabled(LAYER_QUERIES):
		return &"none"
	if _local_water_queries_enabled() and _water_body_registry.has_sources():
		return &"water_body_registry"
	if _ocean_active() and _ocean_provider != null:
		return _ocean_provider.get_water_query_source()
	return &"none"


func get_water_query_readback_bytes_per_frame() -> int:
	return _ocean_provider.get_water_query_readback_bytes_per_frame() if _ocean_provider != null else 0


func emit_water_impulse(
	world_pos: Vector3,
	radius_m: float,
	strength: float,
	kind: StringName = &"impact",
	body_id: StringName = &"",
	wake_direction: Vector2 = Vector2.ZERO,
	wake_length_m: float = 0.0,
) -> void:
	if not is_water_layer_enabled(LAYER_ALL) or not is_water_layer_enabled(LAYER_INTERACTIONS):
		return
	if _water_interaction_sim == null:
		_setup_water_interaction_layer()
	if _water_interaction_sim == null:
		return
	var sampled_body_id := body_id
	if sampled_body_id == &"":
		sampled_body_id = sample_water_body_id_at(world_pos)
	if sampled_body_id == WaterSurfaceState.WATER_BODY_NONE:
		return
	var coverage := sample_water_coverage(world_pos)
	if coverage <= WaterSurfaceState.COVERAGE_GATE_START:
		return
	var water_height := sample_water_height(world_pos)
	if is_nan(water_height) or absf(water_height) >= 1.0e20:
		return
	var shaped_strength := strength
	match kind:
		&"wake":
			shaped_strength *= 0.65
		&"projectile":
			shaped_strength *= 1.25
		_:
			shaped_strength = strength
	var body_gate := smoothstep(WaterSurfaceState.COVERAGE_GATE_START, WaterSurfaceState.COVERAGE_GATE_END, clampf(coverage, 0.0, 1.0))
	var requires_atlas := sampled_body_id != WaterSurfaceState.WATER_BODY_OCEAN and has_water_body_atlas()
	_water_interaction_sim.queue_impulse(
		world_pos,
		radius_m,
		shaped_strength,
		water_height,
		body_gate,
		requires_atlas,
		wake_direction,
		wake_length_m
	)


func emit_water_flow_obstacle(
	world_pos: Vector3,
	radius_m: float,
	block_strength: float,
	wake_strength: float,
	body_id: StringName = &""
) -> void:
	if not is_water_layer_enabled(LAYER_ALL) or not is_water_layer_enabled(LAYER_INTERACTIONS):
		return
	var sampled_body_id := body_id
	if sampled_body_id == &"":
		sampled_body_id = sample_water_body_id_at(world_pos)
	if sampled_body_id == WaterSurfaceState.WATER_BODY_NONE:
		return
	var coverage := sample_water_coverage(world_pos)
	if coverage <= WaterSurfaceState.COVERAGE_GATE_START:
		return
	var water_height := sample_water_height(world_pos)
	if is_nan(water_height) or absf(water_height) >= 1.0e20:
		return
	var base_velocity := sample_base_water_velocity(world_pos)
	if Vector2(base_velocity.x, base_velocity.z).length_squared() <= 0.0001:
		return
	var body_gate := smoothstep(WaterSurfaceState.COVERAGE_GATE_START, WaterSurfaceState.COVERAGE_GATE_END, clampf(coverage, 0.0, 1.0))
	var requires_atlas := sampled_body_id != WaterSurfaceState.WATER_BODY_OCEAN and has_water_body_atlas()
	if _water_interaction_sim == null:
		_setup_water_interaction_layer()
	if _water_interaction_sim != null:
		_water_interaction_sim.queue_flow_obstacle(
			world_pos,
			radius_m,
			base_velocity,
			block_strength,
			wake_strength,
			water_height,
			body_gate,
			requires_atlas
		)
	_track_local_flow_obstacle(world_pos, radius_m, base_velocity, block_strength, wake_strength)


func register_water_interactor(node: Node, options: Dictionary = {}) -> void:
	if node == null or _water_interactors.has(node):
		return
	_water_interactors.append(node)
	if not options.is_empty() and node.has_method("apply_water_interaction_options"):
		node.call("apply_water_interaction_options", options)


func unregister_water_interactor(node: Node) -> void:
	var idx := _water_interactors.find(node)
	if idx >= 0:
		_water_interactors.remove_at(idx)


func register_water_interaction_renderer(node: Node) -> void:
	if node == null or _water_interaction_renderers.has(node):
		return
	_water_interaction_renderers.append(node)
	_sync_one_water_interaction_renderer(node)


func unregister_water_interaction_renderer(node: Node) -> void:
	var idx := _water_interaction_renderers.find(node)
	if idx >= 0:
		_water_interaction_renderers.remove_at(idx)


func get_water_interaction_texture() -> Texture2D:
	if _water_interaction_sim == null:
		return null
	return _water_interaction_sim.get_texture()


func get_water_dynamic_flow_texture() -> Texture2D:
	if _water_interaction_sim == null:
		return null
	return _water_interaction_sim.get_flow_texture()


func get_water_interaction_bounds() -> Vector4:
	if _water_interaction_sim == null:
		return Vector4.ZERO
	return _water_interaction_sim.get_bounds()


func get_water_interaction_stats() -> Dictionary:
	if _water_interaction_sim == null:
		return {
			"enabled": false,
			"debug_enabled": _water_interaction_debug_enabled,
			"atlas_size": 0,
			"dispatch_count": 0,
			"last_impulse_count": 0,
			"pending_impulse_count": 0,
			"gpu_ms": -1.0,
			"cpu_upload_us": 0,
			"culled_impulses_total": 0,
			"active_dispatch": false,
			"atlas_scroll_px": Vector2i.ZERO,
			"renderer_sync_count": _water_interaction_renderer_sync_count,
		}
	var stats := _water_interaction_sim.get_stats()
	stats["debug_enabled"] = _water_interaction_debug_enabled
	stats["renderer_sync_count"] = _water_interaction_renderer_sync_count
	return stats


func set_water_interaction_debug_enabled(enabled: bool) -> void:
	_water_interaction_debug_enabled = enabled
	_sync_water_interaction_to_renderers(true)


func is_water_interaction_debug_enabled() -> bool:
	return _water_interaction_debug_enabled


func update_local_water_interactions(delta: float, center_world: Vector3 = Vector3.INF) -> void:
	if not is_water_layer_enabled(LAYER_ALL) or not is_water_layer_enabled(LAYER_INTERACTIONS):
		_clear_water_body_atlas()
		_sync_water_interaction_to_renderers(true)
		return
	if _water_interaction_sim == null:
		_setup_water_interaction_layer()
	if _water_interaction_sim == null:
		return
	var center := center_world
	if center == Vector3.INF and _camera != null and is_instance_valid(_camera):
		center = _camera.global_position
	elif center == Vector3.INF:
		center = Vector3(0.0, get_sea_level(), 0.0)
	if water_body_atlas_enabled and is_water_layer_enabled(LAYER_QUERIES) and _local_water_queries_enabled() and _water_body_registry.has_sources():
		_update_water_body_atlas(center)
	else:
		_clear_water_body_atlas()
	_water_interaction_sim.configure_water_body_mask(_water_body_atlas_rd, get_water_body_atlas_bounds(), has_water_body_atlas())
	_water_interaction_sim.update_sim(delta, center)
	_sync_water_interaction_to_renderers()


func set_underwater_particles_enabled(enabled: bool) -> void:
	underwater_particles_enabled = enabled
	if _underwater_particulates != null:
		_underwater_particulates.enabled = enabled


func is_underwater_particles_enabled() -> bool:
	return underwater_particles_enabled


func set_underwater_particles_quality(quality: int) -> void:
	underwater_particles_quality = clampi(quality, 0, 3)
	if _underwater_particulates != null:
		_underwater_particulates.quality_tier = underwater_particles_quality as UnderwaterParticulates.QualityTier


func get_underwater_particles_quality() -> int:
	return underwater_particles_quality


func get_underwater_particles_quality_name() -> String:
	match underwater_particles_quality:
		0:
			return "Off"
		1:
			return "Low"
		2:
			return "Medium"
		3:
			return "High"
		_:
			return "Unknown"


func set_underwater_particles_opacity(value: float) -> void:
	underwater_particles_opacity = clampf(value, 0.0, 2.0)
	if _underwater_particulates != null:
		_underwater_particulates.opacity = underwater_particles_opacity


func set_underwater_particles_count(value: int) -> void:
	underwater_particles_count = clampi(value, 0, 8192)
	if _underwater_particulates != null:
		_underwater_particulates.particle_count = underwater_particles_count


func set_underwater_particles_size_scale(value: float) -> void:
	underwater_particles_size_scale = clampf(value, 0.25, 4.0)
	if _underwater_particulates != null:
		_underwater_particulates.size_scale = underwater_particles_size_scale


func set_underwater_particles_speed_scale(value: float) -> void:
	underwater_particles_speed_scale = clampf(value, 0.0, 4.0)
	if _underwater_particulates != null:
		_underwater_particulates.speed_scale = underwater_particles_speed_scale


func get_underwater_particles_status() -> Dictionary:
	return {
		"enabled": underwater_particles_enabled,
		"quality": underwater_particles_quality,
		"quality_name": get_underwater_particles_quality_name(),
		"opacity": underwater_particles_opacity,
		"count": underwater_particles_count,
		"size_scale": underwater_particles_size_scale,
		"speed_scale": underwater_particles_speed_scale,
		"node_active": _underwater_particulates != null and _underwater_particulates.enabled,
	}


func set_underwater_particles_render_layers(mask: int) -> void:
	if _underwater_particulates != null:
		_underwater_particulates.set_render_layers(mask)


func _setup_underwater_particulates_layer() -> void:
	if _underwater_particulates != null:
		return
	_underwater_particulates = UnderwaterParticulatesScript.new()
	_underwater_particulates.name = "UnderwaterParticulates"
	_underwater_particulates.enabled = underwater_particles_enabled
	_underwater_particulates.quality_tier = underwater_particles_quality as UnderwaterParticulates.QualityTier
	_underwater_particulates.opacity = underwater_particles_opacity
	_underwater_particulates.particle_count = underwater_particles_count
	_underwater_particulates.size_scale = underwater_particles_size_scale
	_underwater_particulates.speed_scale = underwater_particles_speed_scale
	add_child(_underwater_particulates)
	if _camera != null:
		_underwater_particulates.set_camera(_camera)


func _setup_water_interaction_layer() -> void:
	if _water_interaction_sim != null:
		return
	_water_interaction_sim = WaterInteractionSimScript.new()
	_water_interaction_sim.name = "WaterInteractionSim"
	add_child(_water_interaction_sim)
	_sync_water_interaction_to_renderers(true)


func _sync_water_interaction_to_renderers(force: bool = false) -> void:
	var texture: Texture2D = null
	var dynamic_flow_texture: Texture2D = null
	var bounds := Vector4.ZERO
	var active := false
	var dynamic_flow_active := false
	if _water_interaction_sim != null:
		var stats := _water_interaction_sim.get_stats()
		texture = _water_interaction_sim.get_texture()
		dynamic_flow_texture = _water_interaction_sim.get_flow_texture()
		bounds = _water_interaction_sim.get_bounds()
		active = is_water_layer_enabled(LAYER_ALL) and is_water_layer_enabled(LAYER_INTERACTIONS) and bool(stats.get("enabled", false)) and texture != null
		dynamic_flow_active = active and dynamic_flow_texture != null
	var body_atlas_texture := get_water_body_atlas_texture()
	var body_atlas_bounds := get_water_body_atlas_bounds()
	var body_atlas_available := has_water_body_atlas()
	if not force \
			and _water_interaction_sync_initialized \
			and texture == _water_interaction_last_texture \
			and dynamic_flow_texture == _water_dynamic_flow_last_texture \
			and bounds == _water_interaction_last_bounds \
			and active == _water_interaction_last_enabled \
			and dynamic_flow_active == _water_dynamic_flow_last_enabled \
			and _water_interaction_debug_enabled == _water_interaction_last_debug \
			and body_atlas_texture == _water_interaction_last_body_atlas_texture \
			and body_atlas_bounds == _water_interaction_last_body_atlas_bounds \
			and body_atlas_available == _water_interaction_last_body_atlas_available \
			and get_sea_level() == _water_interaction_last_surface_height:
		return
	_water_interaction_sync_initialized = true
	_water_interaction_last_texture = texture
	_water_dynamic_flow_last_texture = dynamic_flow_texture
	_water_interaction_last_bounds = bounds
	_water_interaction_last_enabled = active
	_water_dynamic_flow_last_enabled = dynamic_flow_active
	_water_interaction_last_debug = _water_interaction_debug_enabled
	_water_interaction_last_body_atlas_texture = body_atlas_texture
	_water_interaction_last_body_atlas_bounds = body_atlas_bounds
	_water_interaction_last_body_atlas_available = body_atlas_available
	_water_interaction_last_surface_height = get_sea_level()
	for renderer: Node in _water_interaction_renderers.duplicate():
		_sync_one_water_interaction_renderer(renderer)


func _sync_one_water_interaction_renderer(node: Node) -> void:
	if not is_instance_valid(node) or not node.has_method("sync_water_interaction_texture"):
		return
	var texture: Texture2D = null
	var dynamic_flow_texture: Texture2D = null
	var bounds := Vector4.ZERO
	var active := false
	if _water_interaction_sim != null:
		var stats := _water_interaction_sim.get_stats()
		texture = _water_interaction_sim.get_texture()
		dynamic_flow_texture = _water_interaction_sim.get_flow_texture()
		bounds = _water_interaction_sim.get_bounds()
		active = bool(stats.get("enabled", false)) and texture != null
	node.call(
		"sync_water_interaction_texture",
		texture,
		bounds,
		active,
		_water_interaction_debug_enabled,
		get_water_body_atlas_texture(),
		get_water_body_atlas_bounds(),
		has_water_body_atlas(),
		dynamic_flow_texture,
		bounds,
		active and dynamic_flow_texture != null
	)
	_water_interaction_renderer_sync_count += 1


func _update_water_body_atlas(camera_pos: Vector3) -> void:
	if not water_body_atlas_enabled or not is_water_layer_enabled(LAYER_QUERIES) or not _local_water_queries_enabled() or not _water_body_registry.has_sources():
		_clear_water_body_atlas()
		return
	var center_xz := Vector2(camera_pos.x, camera_pos.z)
	var moved_enough := _water_body_atlas_center_xz == Vector2.INF \
		or center_xz.distance_to(_water_body_atlas_center_xz) >= WATER_BODY_ATLAS_UPDATE_MOVE_M
	if not moved_enough and has_water_body_atlas():
		return
	_rebuild_water_body_atlas(camera_pos)


func _rebuild_water_body_atlas(center: Vector3) -> void:
	var rebuild_start_usec := Time.get_ticks_usec()
	if not is_water_layer_enabled(LAYER_QUERIES) or not _local_water_queries_enabled() or not _water_body_registry.has_sources():
		_clear_water_body_atlas()
		return
	var resolution: int = WATER_BODY_ATLAS_RESOLUTION
	var extent: float = WATER_BODY_ATLAS_EXTENT_M
	var half_extent: float = extent * 0.5
	var bounds := Rect2(center.x - half_extent, center.z - half_extent, extent, extent)
	var image := _water_body_atlas_image
	if image == null or image.get_width() != resolution or image.get_height() != resolution or image.get_format() != Image.FORMAT_RGBAF:
		image = Image.create(resolution, resolution, false, Image.FORMAT_RGBAF)
	var inv_resolution: float = 1.0 / float(resolution)
	for y: int in resolution:
		var world_z := bounds.position.y + (float(y) + 0.5) * extent * inv_resolution
		for x: int in resolution:
			var world_x := bounds.position.x + (float(x) + 0.5) * extent * inv_resolution
			var query_pos := Vector3(world_x, center.y, world_z)
			var coverage: float = _water_body_registry.sample_coverage(query_pos, 0.0)
			var height: float = 0.0
			if coverage > WaterSurfaceState.COVERAGE_GATE_START:
				height = _water_body_registry.sample_height(query_pos, get_sea_level())
			image.set_pixel(x, y, Color(coverage, height, 0.0, 1.0 if coverage > 0.0 else 0.0))
	_water_body_atlas_image = image
	_water_body_atlas_bounds = bounds
	_water_body_atlas_center_xz = Vector2(center.x, center.z)
	_water_body_atlas_frame = Engine.get_process_frames()
	if _water_body_atlas_texture == null:
		_water_body_atlas_texture = ImageTexture.create_from_image(image)
	else:
		_water_body_atlas_texture.update(image)
	_water_body_atlas_rd = RID()
	if _water_body_atlas_texture != null:
		var texture_rid := _water_body_atlas_texture.get_rid()
		if texture_rid.is_valid():
			_water_body_atlas_rd = RenderingServer.texture_get_rd_texture(texture_rid)
	_water_body_atlas_last_rebuild_usec = Time.get_ticks_usec() - rebuild_start_usec
	_water_body_atlas_total_rebuild_usec += _water_body_atlas_last_rebuild_usec
	_water_body_atlas_rebuild_count += 1


func _clear_water_body_atlas() -> void:
	_water_body_atlas_image = null
	_water_body_atlas_texture = null
	_water_body_atlas_rd = RID()
	_water_body_atlas_bounds = Rect2()
	_water_body_atlas_center_xz = Vector2.INF
	_water_body_atlas_frame = -1


func _get_world_water_provider_status() -> Dictionary:
	if _world_water_provider == null:
		return {}
	if _world_water_provider.has_method("get_runtime_status"):
		var status_v: Variant = _world_water_provider.call("get_runtime_status")
		if status_v is Dictionary:
			return status_v
	return {
		"provider_id": StringName(_world_water_provider.get("provider_id")),
	}


func _track_local_flow_obstacle(
	world_pos: Vector3,
	radius_m: float,
	base_velocity: Vector3,
	block_strength: float,
	wake_strength: float
) -> void:
	var now := Time.get_ticks_msec()
	_local_flow_obstacles.append({
		"position": Vector2(world_pos.x, world_pos.z),
		"radius": clampf(radius_m, 0.08, 32.0),
		"base_velocity": Vector2(base_velocity.x, base_velocity.z),
		"block_strength": clampf(block_strength, 0.0, 2.0),
		"wake_strength": clampf(wake_strength, 0.0, 2.0),
		"expires_msec": now + 220,
	})
	if _local_flow_obstacles.size() > 96:
		_local_flow_obstacles = _local_flow_obstacles.slice(_local_flow_obstacles.size() - 96)


func _sample_local_flow_delta(world_pos: Vector3) -> Vector3:
	if _local_flow_obstacles.is_empty():
		return Vector3.ZERO
	var now := Time.get_ticks_msec()
	var world_xz := Vector2(world_pos.x, world_pos.z)
	var delta := Vector2.ZERO
	var kept: Array[Dictionary] = []
	for obstacle: Dictionary in _local_flow_obstacles:
		if int(obstacle.get("expires_msec", 0)) < now:
			continue
		kept.append(obstacle)
		var center: Vector2 = obstacle.get("position", Vector2.ZERO)
		var base_velocity: Vector2 = obstacle.get("base_velocity", Vector2.ZERO)
		var base_speed := base_velocity.length()
		if base_speed <= 0.001:
			continue
		var radius := maxf(float(obstacle.get("radius", 0.1)), 0.08)
		var to_sample := world_xz - center
		var dist := to_sample.length()
		var support := radius * 5.0
		if dist > support:
			continue
		var dir := base_velocity / base_speed
		var side := Vector2(-dir.y, dir.x)
		var along := to_sample.dot(dir)
		var lateral := to_sample.dot(side)
		var core := exp(-pow(dist / radius, 2.0))
		var downstream := smoothstep(-radius * 0.5, radius * 2.0, along) * (1.0 - smoothstep(radius * 2.0, support, along))
		var side_gate := smoothstep(0.0, radius * 0.95, absf(lateral)) * (1.0 - smoothstep(radius * 0.95, radius * 2.8, absf(lateral)))
		var block := float(obstacle.get("block_strength", 0.0))
		var wake := float(obstacle.get("wake_strength", 0.0))
		var slow := -base_velocity * block * core
		var deflect := side * (1.0 if lateral >= 0.0 else -1.0) * base_speed * wake * side_gate * downstream * 0.55
		delta += slow + deflect
	_local_flow_obstacles = kept
	if delta.length() > 8.0:
		delta = delta.normalized() * 8.0
	return Vector3(delta.x, 0.0, delta.y)


func _find_active_camera() -> Camera3D:
	var viewport := get_viewport()
	if viewport != null:
		var cam := viewport.get_camera_3d()
		if cam != null:
			return cam
	var cameras := get_tree().get_nodes_in_group("camera")
	for cam_node: Node in cameras:
		if cam_node is Camera3D and cam_node.is_current():
			return cam_node as Camera3D
	return null


func _ocean_active() -> bool:
	return is_water_layer_enabled(LAYER_QUERIES) \
		and is_water_layer_enabled(LAYER_OCEAN_SURFACE) \
		and _ocean_provider != null \
		and _ocean_provider.is_system_enabled()


func _local_water_queries_enabled() -> bool:
	return is_water_layer_enabled(LAYER_RIVERS) or is_water_layer_enabled(LAYER_LAKES_POOLS)


func _normalize_water_layer(layer: StringName) -> StringName:
	match layer:
		LAYER_ALL, &"water", &"all_water":
			return LAYER_ALL
		LAYER_OCEAN_SURFACE, &"ocean", &"ocean_surface":
			return LAYER_OCEAN_SURFACE
		LAYER_RIVERS, &"river":
			return LAYER_RIVERS
		LAYER_LAKES_POOLS, &"lakes", &"lake", &"pools", &"pool", &"still_water":
			return LAYER_LAKES_POOLS
		LAYER_QUERIES, &"gameplay", &"water_queries":
			return LAYER_QUERIES
		LAYER_INTERACTIONS, &"interaction", &"water_interactions":
			return LAYER_INTERACTIONS
	return &""


func _apply_all_water_enabled(enabled: bool) -> void:
	set_process(enabled)
	set_physics_process(enabled)
	if not enabled:
		_clear_water_body_atlas()
	_apply_render_layer_visibility()
	_sync_water_interaction_to_renderers(true)


func _ensure_generated_water_roots() -> Node3D:
	if _generated_water_root != null and is_instance_valid(_generated_water_root):
		return _generated_water_root
	_generated_water_root = Node3D.new()
	_generated_water_root.name = "GeneratedWaterBodies"
	add_child(_generated_water_root)
	_generated_rivers_root = Node3D.new()
	_generated_rivers_root.name = "Rivers"
	_generated_water_root.add_child(_generated_rivers_root)
	_generated_lakes_root = Node3D.new()
	_generated_lakes_root.name = "LakesPools"
	_generated_water_root.add_child(_generated_lakes_root)
	_apply_render_layer_visibility()
	return _generated_water_root


func _apply_render_layer_visibility() -> void:
	_ensure_generated_water_roots()
	var all_enabled := is_water_layer_enabled(LAYER_ALL)
	if _generated_water_root != null:
		_generated_water_root.visible = all_enabled
	if _generated_rivers_root != null:
		_generated_rivers_root.visible = all_enabled and is_water_layer_enabled(LAYER_RIVERS)
	if _generated_lakes_root != null:
		_generated_lakes_root.visible = all_enabled and is_water_layer_enabled(LAYER_LAKES_POOLS)
	if _ocean_provider != null and _ocean_provider.has_method("set_ocean_surface_visible"):
		_ocean_provider.call("set_ocean_surface_visible", all_enabled and is_water_layer_enabled(LAYER_OCEAN_SURFACE))
