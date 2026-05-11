## WetnessManager - shared water-contact wetness coordinator.
##
## Screen-space contact wetness is handled by WetCompositorEffect. This manager
## only pushes render-thread-safe water state to compositor effects and tracks
## retained wetness memory for objects that should stay wet after leaving water.
class_name WetnessManagerClass
extends Node

const SETTING_ENABLED := "wetness/enabled"
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
var _debug_mask: bool = false
var _compositors: Array[PostProcessEffect] = []
var _memory_holders: Dictionary = {}
var _shader_manager_effect_registered: bool = false
var _missing_shader_effect_logged: bool = false


class MemoryHolder:
	var root: Node3D
	var material_rids: Array[RID]
	var bottom_local_y: float
	var sample_radius: float
	var wet_line_local: float

	func _init(
		p_root: Node3D,
		p_material_rids: Array[RID],
		p_bottom_local_y: float,
		p_sample_radius: float
	) -> void:
		root = p_root
		material_rids = p_material_rids.duplicate()
		bottom_local_y = p_bottom_local_y
		sample_radius = maxf(p_sample_radius, 0.0)
		wet_line_local = bottom_local_y - 1.0


func _ready() -> void:
	_register_project_settings()
	_enabled = bool(ProjectSettings.get_setting(SETTING_ENABLED, false))
	_debug_mask = bool(ProjectSettings.get_setting(SETTING_DEBUG_MASK, false))
	wet_margin = float(ProjectSettings.get_setting(SETTING_WET_MARGIN, wet_margin))
	wet_albedo_darken = float(ProjectSettings.get_setting(SETTING_ALBEDO_DARKEN, wet_albedo_darken))
	wet_roughness_target = float(ProjectSettings.get_setting(SETTING_ROUGHNESS_TARGET, wet_roughness_target))
	retained_wetness_strength = float(ProjectSettings.get_setting(SETTING_RETAINED_STRENGTH, retained_wetness_strength))
	wet_dry_rate = float(ProjectSettings.get_setting(SETTING_DRY_RATE, wet_dry_rate))
	call_deferred("_sync_shader_manager_effect")


func _register_project_settings() -> void:
	_register_setting(SETTING_ENABLED, false, TYPE_BOOL, 0, "Enable shared screen-space wetness")
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
	_sync_shader_manager_effect()


func is_enabled() -> bool:
	return _enabled


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
	if root == null:
		return
	_memory_holders[root.get_instance_id()] = MemoryHolder.new(
		root,
		material_rids,
		bottom_local_y,
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
	return holder.root.global_position.y + holder.wet_line_local


func _process(delta: float) -> void:
	_sync_shader_manager_effect()
	var state := _get_water_state()
	var active_water := _is_active_water_state(state)
	for effect: PostProcessEffect in _compositors.duplicate():
		if effect == null or not is_instance_valid(effect):
			_compositors.erase(effect)
			continue
		effect.effect_enabled = _enabled and active_water
		effect.blend_factor = 1.0 if effect.effect_enabled else 0.0
		_push_params_to_effect(effect)
		if effect.effect_enabled and effect.has_method("sync_from_water_state"):
			effect.call("sync_from_water_state", state)
	if _enabled and active_water:
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
		if _enabled and shader_manager.has_method("is_effect_enabled") and not bool(shader_manager.call("is_effect_enabled", "wet_compositor")):
			shader_manager.call("enable_effect", "wet_compositor", 0.0)
		elif not _enabled and shader_manager.has_method("is_effect_enabled") and bool(shader_manager.call("is_effect_enabled", "wet_compositor")):
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

		var root_y: float = holder.root.global_position.y
		var bottom_world: float = root_y + holder.bottom_local_y
		var water_y: float = _sample_contact_water_y(state, holder.root, bottom_world, holder.sample_radius)
		if water_y > -INF:
			holder.wet_line_local = maxf(holder.wet_line_local, water_y - root_y)
		else:
			holder.wet_line_local -= wet_dry_rate * delta
			holder.wet_line_local = maxf(holder.wet_line_local, holder.bottom_local_y - 1.0)

		var wet_line_world := root_y + holder.wet_line_local
		for mat_rid: RID in holder.material_rids:
			if not mat_rid.is_valid():
				continue
			RenderingServer.material_set_param(mat_rid, &"wet_line_y", wet_line_world)
			RenderingServer.material_set_param(mat_rid, &"wet_margin", wet_margin)
			RenderingServer.material_set_param(mat_rid, &"wet_albedo_darken", wet_albedo_darken)
			RenderingServer.material_set_param(mat_rid, &"wet_roughness_target", wet_roughness_target)
			RenderingServer.material_set_param(mat_rid, &"retained_wetness_strength", retained_wetness_strength)
			RenderingServer.material_set_param(mat_rid, &"wet_debug", _debug_mask)

	for instance_id: int in erase_ids:
		_memory_holders.erase(instance_id)


func _sample_contact_water_y(state: WaterSurfaceState, root: Node3D, bottom_world_y: float, radius: float) -> float:
	if state == null or root == null or not state.can_sample_height():
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
		var depth: float = state.sample_water_depth(sample_pos, -INF)
		if depth > 0.0:
			max_y = maxf(max_y, state.sample_height(sample_pos, state.sea_level))
	return max_y


func _horizontal_axis(axis: Vector3) -> Vector3:
	var horizontal: Vector3 = Vector3(axis.x, 0.0, axis.z)
	if horizontal.length_squared() <= 0.0001:
		return Vector3.RIGHT
	return horizontal.normalized()
