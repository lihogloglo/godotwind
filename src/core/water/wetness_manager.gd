## WetnessManager - shared water-contact wetness coordinator.
##
## Screen-space contact wetness is handled by WetCompositorEffect. This manager
## only pushes render-thread-safe water state to compositor effects and tracks
## retained wetness memory for objects that should stay wet after leaving water.
class_name WetnessManagerClass
extends Node

const SETTING_ENABLED := "wetness/enabled"
const SETTING_LIVE_COMPOSITOR_ENABLED := "wetness/live_compositor_enabled"
const SETTING_DEBUG_MASK := "wetness/debug_mask"
const SETTING_WET_MARGIN := "wetness/wet_margin"
const SETTING_ALBEDO_DARKEN := "wetness/albedo_darken"
const SETTING_ROUGHNESS_TARGET := "wetness/roughness_target"
const SETTING_RETAINED_STRENGTH := "wetness/retained_strength"
const SETTING_DRY_RATE := "wetness/dry_rate"

@export var wet_margin: float = 0.3
@export var wet_albedo_darken: float = 0.6
@export var wet_roughness_target: float = 0.05
@export var retained_wetness_strength: float = 0.35
@export var wet_dry_rate: float = 0.1
@export var submerged_optics_depth: float = 0.10

var _enabled: bool = false
var _live_compositor_enabled: bool = false
var _debug_mask: bool = false
var _compositors: Array[PostProcessEffect] = []
var _memory_holders: Dictionary = {}
var _shader_manager_effect_registered: bool = false
var _missing_shader_effect_logged: bool = false


class MemoryHolder:
	var root: Node3D
	var material_rids: Array[RID]
	var local_bounds: AABB
	var sample_radius: float
	var wet_height_above_bottom: float

	func _init(
		p_root: Node3D,
		p_material_rids: Array[RID],
		p_local_bounds: AABB,
		p_sample_radius: float
	) -> void:
		root = p_root
		material_rids = p_material_rids.duplicate()
		local_bounds = p_local_bounds
		sample_radius = maxf(p_sample_radius, 0.0)
		wet_height_above_bottom = -1.0

	func get_bottom_world_y() -> float:
		var min_y := INF
		var pos := local_bounds.position
		var end := local_bounds.end
		var xf := _current_root_transform()
		var corners: Array[Vector3] = [
			Vector3(pos.x, pos.y, pos.z),
			Vector3(end.x, pos.y, pos.z),
			Vector3(pos.x, end.y, pos.z),
			Vector3(end.x, end.y, pos.z),
			Vector3(pos.x, pos.y, end.z),
			Vector3(end.x, pos.y, end.z),
			Vector3(pos.x, end.y, end.z),
			Vector3(end.x, end.y, end.z),
		]
		for corner: Vector3 in corners:
			min_y = minf(min_y, (xf * corner).y)
		return min_y

	func get_wet_line_world_y() -> float:
		return get_bottom_world_y() + wet_height_above_bottom

	func _current_root_transform() -> Transform3D:
		if root.is_inside_tree():
			return root.global_transform
		return Transform3D(root.transform.basis, root.position)


func _ready() -> void:
	_register_project_settings()
	_enabled = bool(ProjectSettings.get_setting(SETTING_ENABLED, false))
	_live_compositor_enabled = bool(ProjectSettings.get_setting(SETTING_LIVE_COMPOSITOR_ENABLED, false))
	_debug_mask = bool(ProjectSettings.get_setting(SETTING_DEBUG_MASK, false))
	wet_margin = float(ProjectSettings.get_setting(SETTING_WET_MARGIN, wet_margin))
	wet_albedo_darken = float(ProjectSettings.get_setting(SETTING_ALBEDO_DARKEN, wet_albedo_darken))
	wet_roughness_target = float(ProjectSettings.get_setting(SETTING_ROUGHNESS_TARGET, wet_roughness_target))
	retained_wetness_strength = float(ProjectSettings.get_setting(SETTING_RETAINED_STRENGTH, retained_wetness_strength))
	wet_dry_rate = float(ProjectSettings.get_setting(SETTING_DRY_RATE, wet_dry_rate))
	call_deferred("_sync_shader_manager_effect")


func _register_project_settings() -> void:
	_register_setting(SETTING_ENABLED, false, TYPE_BOOL, 0, "Enable retained object wetness")
	_register_setting(SETTING_LIVE_COMPOSITOR_ENABLED, false, TYPE_BOOL, 0, "Enable shared screen-space wetness compositor")
	_register_setting(SETTING_DEBUG_MASK, false, TYPE_BOOL, 0, "Show the wetness compositor mask")
	_register_setting(SETTING_WET_MARGIN, 0.3, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0.0,2.0,0.01")
	_register_setting(SETTING_ALBEDO_DARKEN, 0.6, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0.0,1.0,0.01")
	_register_setting(SETTING_ROUGHNESS_TARGET, 0.05, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0.0,0.3,0.01")
	_register_setting(SETTING_RETAINED_STRENGTH, 0.35, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0.0,1.0,0.01")
	_register_setting(SETTING_DRY_RATE, 0.1, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0.0,2.0,0.01")


func _register_setting(
	name: String,
	default_value: Variant,
	type: int,
	hint: int,
	hint_string: String
) -> void:
	if ProjectSettings.has_setting(name):
		return
	ProjectSettings.set_setting(name, default_value)
	ProjectSettings.set_initial_value(name, default_value)
	var info: Dictionary = {
		"name": name,
		"type": type,
	}
	if hint != 0:
		info["hint"] = hint
	if not hint_string.is_empty():
		info["hint_string"] = hint_string
	ProjectSettings.add_property_info(info)


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	ProjectSettings.set_setting(SETTING_ENABLED, enabled)


func is_enabled() -> bool:
	return _enabled


func set_live_compositor_enabled(enabled: bool) -> void:
	_live_compositor_enabled = enabled
	ProjectSettings.set_setting(SETTING_LIVE_COMPOSITOR_ENABLED, enabled)
	_sync_shader_manager_effect()


func is_live_compositor_enabled() -> bool:
	return _live_compositor_enabled


func set_debug_mask(enabled: bool) -> void:
	_debug_mask = enabled
	ProjectSettings.set_setting(SETTING_DEBUG_MASK, enabled)
	for effect: PostProcessEffect in _compositors:
		_push_params_to_effect(effect)


func register_compositor(effect: PostProcessEffect) -> void:
	if effect == null or _compositors.has(effect):
		return
	_compositors.append(effect)
	_push_params_to_effect(effect)


func unregister_compositor(effect: PostProcessEffect) -> void:
	_compositors.erase(effect)


func register_memory_holder(
	root: Node3D,
	material_rids: Array[RID],
	bottom_local_y: float,
	sample_radius: float
) -> void:
	var radius: float = maxf(sample_radius, 0.01)
	var local_bounds := AABB(
		Vector3(-radius, bottom_local_y, -radius),
		Vector3(radius * 2.0, radius, radius * 2.0)
	)
	register_wettable_object(root, material_rids, local_bounds, sample_radius)


func register_wettable_object(
	root: Node3D,
	material_rids: Array[RID],
	local_bounds: AABB,
	sample_radius: float
) -> void:
	if root == null:
		return
	if not local_bounds.has_volume():
		local_bounds = AABB(Vector3(-0.1, -0.1, -0.1), Vector3(0.2, 0.2, 0.2))
	_memory_holders[root.get_instance_id()] = MemoryHolder.new(
		root,
		material_rids,
		local_bounds,
		sample_radius
	)


func unregister_memory_holder(root: Node3D) -> void:
	if root == null:
		return
	_memory_holders.erase(root.get_instance_id())


func get_memory_holder_wet_line(root: Node3D) -> float:
	if root == null:
		return -INF
	var holder: MemoryHolder = _memory_holders.get(root.get_instance_id())
	if holder == null:
		return -INF
	return holder.get_wet_line_world_y()


func _process(delta: float) -> void:
	_sync_shader_manager_effect()
	var state := _get_water_state()
	var active_water := _is_active_water_state(state)
	for effect: PostProcessEffect in _compositors.duplicate():
		if effect == null or not is_instance_valid(effect):
			_compositors.erase(effect)
			continue
		effect.effect_enabled = _live_compositor_enabled and active_water
		effect.blend_factor = 1.0 if effect.effect_enabled else 0.0
		_push_params_to_effect(effect)
		if effect.effect_enabled and effect.has_method("sync_from_water_state"):
			effect.call("sync_from_water_state", state)
	if _enabled:
		_update_memory_holders(delta, state)


func _sync_shader_manager_effect() -> void:
	if not is_inside_tree() or not get_tree().root.has_node("ShaderManager"):
		return
	var shader_manager := get_tree().root.get_node("ShaderManager")
	if not shader_manager.has_method("get_effect"):
		return
	var effect: Variant = shader_manager.call("get_effect", "wet_compositor")
	if effect is PostProcessEffect:
		register_compositor(effect)
		_shader_manager_effect_registered = true
		if _live_compositor_enabled and shader_manager.has_method("is_effect_enabled") and not bool(shader_manager.call("is_effect_enabled", "wet_compositor")):
			shader_manager.call("enable_effect", "wet_compositor", 0.0)
		elif not _live_compositor_enabled and shader_manager.has_method("is_effect_enabled") and bool(shader_manager.call("is_effect_enabled", "wet_compositor")):
			shader_manager.call("disable_effect", "wet_compositor", 0.0)
	elif not _missing_shader_effect_logged:
		_missing_shader_effect_logged = true
		Log.debug("water", "WetnessManager: wet_compositor effect not loaded yet")


func _push_params_to_effect(effect: PostProcessEffect) -> void:
	if effect == null or not effect.has_method("set_wet_params"):
		return
	effect.call(
		"set_wet_params",
		wet_margin,
		wet_albedo_darken,
		wet_roughness_target,
		retained_wetness_strength,
		submerged_optics_depth,
		_debug_mask
	)


func _get_water_state() -> WaterSurfaceState:
	if not is_inside_tree() or not get_tree().root.has_node("OceanManager"):
		return null
	var ocean_manager := get_tree().root.get_node("OceanManager")
	if ocean_manager.has_method("get_water_surface_state"):
		var state: Variant = ocean_manager.call("get_water_surface_state")
		if state is WaterSurfaceState:
			return state
	return null


func _is_active_water_state(state: WaterSurfaceState) -> bool:
	return (
		state != null
		and state.water_body_id != WaterSurfaceState.WATER_BODY_NONE
		and state.coverage_available
	)


func _update_memory_holders(delta: float, state: WaterSurfaceState) -> void:
	var erase_ids: Array[int] = []
	for instance_id: int in _memory_holders:
		var holder: MemoryHolder = _memory_holders[instance_id]
		if holder.root == null or not is_instance_valid(holder.root):
			erase_ids.append(instance_id)
			continue

		var bottom_world: float = holder.get_bottom_world_y()
		var water_y: float = _sample_contact_water_y(state, holder.root, bottom_world, holder.sample_radius)
		if water_y > -INF:
			holder.wet_height_above_bottom = maxf(holder.wet_height_above_bottom, water_y - bottom_world)
		else:
			holder.wet_height_above_bottom -= wet_dry_rate * delta
			holder.wet_height_above_bottom = maxf(holder.wet_height_above_bottom, -1.0)

		var wet_line_world := holder.get_wet_line_world_y()
		for mat_rid: RID in holder.material_rids:
			if not mat_rid.is_valid():
				continue
			_push_material_params(mat_rid, wet_line_world, state)

	for instance_id: int in erase_ids:
		_memory_holders.erase(instance_id)


func _push_material_params(mat_rid: RID, wet_line_world: float, state: WaterSurfaceState) -> void:
	RenderingServer.material_set_param(mat_rid, &"wet_line_y", wet_line_world)
	RenderingServer.material_set_param(mat_rid, &"wet_margin", wet_margin)
	RenderingServer.material_set_param(mat_rid, &"wet_albedo_darken", wet_albedo_darken)
	RenderingServer.material_set_param(mat_rid, &"wet_roughness_target", wet_roughness_target)
	RenderingServer.material_set_param(mat_rid, &"retained_wetness_strength", retained_wetness_strength)
	RenderingServer.material_set_param(mat_rid, &"wet_debug", _debug_mask)
	RenderingServer.material_set_param(mat_rid, &"live_contact_from_compositor", false)

	var active_water := _is_active_water_state(state)
	RenderingServer.material_set_param(mat_rid, &"dynamic_water_enabled", active_water)
	if not active_water:
		return

	RenderingServer.material_set_param(mat_rid, &"dynamic_water_use_fft", state.has_fft())
	RenderingServer.material_set_param(mat_rid, &"dynamic_water_has_shore_mask", state.shore_mask_texture != null)
	RenderingServer.material_set_param(mat_rid, &"camera_world_position", _get_camera_world_position())
	RenderingServer.material_set_param(mat_rid, &"sea_level", state.sea_level)
	RenderingServer.material_set_param(mat_rid, &"wave_scale", state.wave_scale)
	RenderingServer.material_set_param(mat_rid, &"ocean_time", state.ocean_time)
	RenderingServer.material_set_param(mat_rid, &"map_scales", state.map_scales)
	RenderingServer.material_set_param(mat_rid, &"shore_mask_bounds", state.shore_mask_bounds)
	RenderingServer.material_set_param(mat_rid, &"shore_fade_distance", state.shore_fade_distance)
	RenderingServer.material_set_param(mat_rid, &"shore_wave_amplitude", state.shore_wave_amplitude)
	RenderingServer.material_set_param(mat_rid, &"shore_wave_frequency", state.shore_wave_frequency)
	RenderingServer.material_set_param(mat_rid, &"shore_wave_speed", state.shore_wave_speed)
	RenderingServer.material_set_param(mat_rid, &"shore_wave_steepness", state.shore_wave_steepness)
	if state.shore_mask_texture != null:
		RenderingServer.material_set_param(mat_rid, &"shore_mask", state.shore_mask_texture.get_rid())


func _get_camera_world_position() -> Vector3:
	if is_inside_tree():
		var camera := get_viewport().get_camera_3d()
		if camera != null:
			return camera.global_position
	return Vector3.ZERO


func _sample_contact_water_y(state: WaterSurfaceState, root: Node3D, bottom_world_y: float, radius: float) -> float:
	if not _is_active_water_state(state) or root == null or not state.can_sample_height():
		return -INF

	var max_y: float = -INF
	var center: Vector3 = root.global_position
	center.y = bottom_world_y
	var x_axis: Vector3 = _horizontal_axis(root.global_transform.basis.x)
	var z_axis: Vector3 = _horizontal_axis(root.global_transform.basis.z)
	var sample_radius: float = maxf(radius, 0.0)
	var offsets: Array[Vector3] = [
		Vector3.ZERO,
		x_axis * sample_radius,
		-x_axis * sample_radius,
		z_axis * sample_radius,
		-z_axis * sample_radius,
		(x_axis + z_axis).normalized() * sample_radius,
		(x_axis - z_axis).normalized() * sample_radius,
		(-x_axis + z_axis).normalized() * sample_radius,
		(-x_axis - z_axis).normalized() * sample_radius,
	]
	for offset: Vector3 in offsets:
		var sample_pos: Vector3 = center + offset
		if state.can_sample_coverage() and state.sample_body_gate(sample_pos, 0.0) <= 0.01:
			continue
		var depth: float = state.sample_water_depth(sample_pos, -INF)
		if depth > 0.0:
			max_y = maxf(max_y, state.sample_height(sample_pos, state.sea_level))
	return max_y


func _horizontal_axis(axis: Vector3) -> Vector3:
	var horizontal: Vector3 = Vector3(axis.x, 0.0, axis.z)
	if horizontal.length_squared() <= 0.0001:
		return Vector3.RIGHT
	return horizontal.normalized()
