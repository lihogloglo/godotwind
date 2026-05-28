## WaterInteractor - reusable probe component for visual water contact events.
## It is engine/data-source agnostic: it only reads WaterSurfaceState queries and
## emits impulses through OceanManager when registered.
class_name WaterInteractor
extends Node3D

@export var radius_m: float = 0.35
@export var impact_strength: float = 1.0
@export var wake_strength: float = 0.18
@export var wake_interval_m: float = 0.0
@export var wake_interval_s: float = 0.0
@export var surface_band_m: float = 0.45
@export var mass_scale: float = 1.0
@export var auto_register: bool = true
@export var affects_flow: bool = false
@export_range(0.0, 2.0, 0.01) var flow_block_strength: float = 0.65
@export_range(0.0, 2.0, 0.01) var flow_wake_strength: float = 0.45
@export var probe_offsets: PackedVector3Array = PackedVector3Array()

var _last_positions: Array[Vector3] = []
var _last_depths: PackedFloat32Array = PackedFloat32Array()
var _last_emit_positions: Array[Vector3] = []
var _wake_timers: PackedFloat32Array = PackedFloat32Array()
var _registered_with_ocean_manager: bool = false


func _ready() -> void:
	_ensure_probe_state()
	if auto_register and not Engine.is_editor_hint() and is_instance_valid(OceanManager):
		OceanManager.register_water_interactor(self)
		_registered_with_ocean_manager = true
		set_physics_process(false)


func _exit_tree() -> void:
	if _registered_with_ocean_manager and is_instance_valid(OceanManager):
		OceanManager.unregister_water_interactor(self)
	_registered_with_ocean_manager = false


func _physics_process(delta: float) -> void:
	if _registered_with_ocean_manager or not is_instance_valid(OceanManager):
		return
	var state := OceanManager.get_water_surface_state()
	for impulse: Dictionary in gather_impulses(delta, state):
		OceanManager.emit_water_impulse(
			impulse["position"],
			float(impulse["radius_m"]),
			float(impulse["strength"]),
			impulse["kind"],
			impulse["body_id"],
			impulse.get("wake_direction", Vector2.ZERO),
			float(impulse.get("wake_length_m", 0.0))
		)
	for obstacle: Dictionary in gather_flow_obstacles(delta, state):
		OceanManager.emit_water_flow_obstacle(
			obstacle["position"],
			float(obstacle["radius_m"]),
			float(obstacle.get("block_strength", 0.0)),
			float(obstacle.get("wake_strength", 0.0)),
			obstacle.get("body_id", WaterSurfaceState.WATER_BODY_NONE)
		)


func apply_water_interaction_options(options: Dictionary) -> void:
	if options.has("radius_m"):
		radius_m = float(options["radius_m"])
	if options.has("impact_strength"):
		impact_strength = float(options["impact_strength"])
	if options.has("wake_strength"):
		wake_strength = float(options["wake_strength"])
	if options.has("wake_interval_m"):
		wake_interval_m = float(options["wake_interval_m"])
	if options.has("wake_interval_s"):
		wake_interval_s = float(options["wake_interval_s"])
	if options.has("surface_band_m"):
		surface_band_m = float(options["surface_band_m"])
	if options.has("mass_scale"):
		mass_scale = float(options["mass_scale"])
	if options.has("affects_flow"):
		affects_flow = bool(options["affects_flow"])
	if options.has("flow_block_strength"):
		flow_block_strength = float(options["flow_block_strength"])
	if options.has("flow_wake_strength"):
		flow_wake_strength = float(options["flow_wake_strength"])
	if options.has("probe_offsets"):
		probe_offsets = options["probe_offsets"]
		_ensure_probe_state()


func gather_impulses(delta: float, state: WaterSurfaceState) -> Array[Dictionary]:
	var impulses: Array[Dictionary] = []
	if state == null or delta <= 0.0:
		return impulses
	_ensure_probe_state()

	var positions := _probe_world_positions()
	for i in range(positions.size()):
		var probe_pos := positions[i]
		var surface := state.sample_surface_query(probe_pos)
		var coverage := float(surface.get("coverage", 0.0))
		var body_id: StringName = surface.get("water_body_id", WaterSurfaceState.WATER_BODY_NONE)
		if coverage <= WaterSurfaceState.COVERAGE_GATE_START or body_id == WaterSurfaceState.WATER_BODY_NONE:
			_last_positions[i] = probe_pos
			_last_depths[i] = -INF
			_wake_timers[i] = 0.0
			continue

		var water_height := float(surface.get("height", -INF))
		if water_height <= -1.0e20:
			_last_positions[i] = probe_pos
			_last_depths[i] = -INF
			continue

		var depth := water_height - probe_pos.y
		var last_depth := _last_depths[i]
		var velocity := (probe_pos - _last_positions[i]) / delta
		var water_velocity: Vector3 = surface.get("velocity", Vector3.ZERO)
		var relative_velocity := velocity - water_velocity
		var relative_lateral_speed := Vector2(relative_velocity.x, relative_velocity.z).length()
		var surface_pos := Vector3(probe_pos.x, water_height, probe_pos.z)

		if last_depth > -1.0e20:
			var crossed_surface := (last_depth < -0.02 and depth >= -0.02) or (last_depth > 0.02 and depth <= 0.02)
			if crossed_surface:
				var vertical_speed := absf((depth - last_depth) / delta)
				var strength := impact_strength * mass_scale * clampf(vertical_speed / 6.0 + relative_lateral_speed / 10.0, 0.15, 3.0)
				impulses.append(_make_impulse(surface_pos, radius_m, strength, &"impact", body_id))

		_wake_timers[i] += delta
		var near_surface := absf(depth) <= surface_band_m
		var moved_since_emit := surface_pos.distance_to(_last_emit_positions[i])
		if near_surface and relative_lateral_speed > 0.15 and (_wake_timers[i] >= wake_interval_s or moved_since_emit >= wake_interval_m):
			var wake_radius := radius_m * clampf(0.8 + relative_lateral_speed * 0.12, 0.8, 2.0)
			var wake_force := wake_strength * mass_scale * clampf(relative_lateral_speed / 4.0, 0.08, 2.0)
			var wake_direction := Vector2(-relative_velocity.x, -relative_velocity.z)
			var wake_length := clampf(relative_lateral_speed * 0.9, wake_radius * 1.5, wake_radius * 5.0)
			impulses.append(_make_impulse(surface_pos, wake_radius, wake_force, &"wake", body_id, wake_direction, wake_length))
			_last_emit_positions[i] = surface_pos
			_wake_timers[i] = 0.0

		_last_positions[i] = probe_pos
		_last_depths[i] = depth

	return impulses


func gather_flow_obstacles(delta: float, state: WaterSurfaceState) -> Array[Dictionary]:
	var obstacles: Array[Dictionary] = []
	if not affects_flow or state == null or delta <= 0.0:
		return obstacles
	var positions := _probe_world_positions()
	for probe_pos: Vector3 in positions:
		var surface := state.sample_surface_query(probe_pos)
		var coverage := float(surface.get("coverage", 0.0))
		var body_id: StringName = surface.get("water_body_id", WaterSurfaceState.WATER_BODY_NONE)
		if coverage <= WaterSurfaceState.COVERAGE_GATE_START or body_id == WaterSurfaceState.WATER_BODY_NONE:
			continue
		var water_height := float(surface.get("height", -INF))
		if water_height <= -1.0e20:
			continue
		var depth := water_height - probe_pos.y
		if absf(depth) > surface_band_m and depth < 0.0:
			continue
		var water_velocity: Vector3 = surface.get("velocity", Vector3.ZERO)
		if Vector2(water_velocity.x, water_velocity.z).length_squared() <= 0.0001:
			continue
		obstacles.append({
			"position": Vector3(probe_pos.x, water_height, probe_pos.z),
			"radius_m": radius_m,
			"block_strength": flow_block_strength * mass_scale,
			"wake_strength": flow_wake_strength,
			"body_id": body_id,
		})
	return obstacles


func _make_impulse(
	position: Vector3,
	radius: float,
	strength: float,
	kind: StringName,
	body_id: StringName,
	wake_direction: Vector2 = Vector2.ZERO,
	wake_length_m: float = 0.0
) -> Dictionary:
	return {
		"position": position,
		"radius_m": radius,
		"strength": strength,
		"kind": kind,
		"body_id": body_id,
		"wake_direction": wake_direction,
		"wake_length_m": wake_length_m,
	}


func _probe_world_positions() -> Array[Vector3]:
	var positions: Array[Vector3] = []
	if probe_offsets.is_empty():
		positions.append(global_position)
		return positions
	for offset: Vector3 in probe_offsets:
		positions.append(global_transform * offset)
	return positions


func _ensure_probe_state() -> void:
	var count := maxi(probe_offsets.size(), 1)
	while _last_positions.size() < count:
		_last_positions.append(global_position)
		_last_emit_positions.append(global_position)
		_last_depths.append(-INF)
		_wake_timers.append(0.0)
	while _last_positions.size() > count:
		_last_positions.pop_back()
		_last_emit_positions.pop_back()
		_last_depths.resize(_last_depths.size() - 1)
		_wake_timers.resize(_wake_timers.size() - 1)
