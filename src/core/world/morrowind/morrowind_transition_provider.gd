class_name MorrowindTransitionProvider
extends "res://src/core/world/transition/transition_provider.gd"

const CS := preload("res://src/core/coordinate_system.gd")
const WorldSpaceHandleScript := preload("res://src/core/world/transition/world_space_handle.gd")
const TransitionPortalDescriptorScript := preload("res://src/core/world/transition/transition_portal_descriptor.gd")

const MIN_INTERIOR_LUMA: float = 0.08
const INTERIOR_FOG_DENSITY_SCALE: float = 0.003
const BUILDING_SEARCH_RADIUS: float = 5.0
const BUILDING_SEARCH_RADIUS_SQ: float = BUILDING_SEARCH_RADIUS * BUILDING_SEARCH_RADIUS

const BUILDING_PATTERNS: Array[String] = [
	"ex_common_house", "ex_common_warehouse", "ex_common_tower", "ex_common_",
	"ex_hlaalu_b", "ex_hlaalu_tower", "ex_hlaalu_manor",
	"ex_redoran_b", "ex_redoran_tower", "ex_redoran_manor",
	"ex_velothi_tower", "ex_velothi_",
	"ex_telvanni_tower", "ex_telvanni_manor", "ex_t_",
	"ex_imperial_tower", "ex_imperial_fort", "ex_imperial_castle",
	"ex_ashl_tower", "ex_ashl_",
	"ex_nord_", "ex_de_shack",
	"ex_stronghold",
	"ex_vivec",
	"ex_dwe_", "ex_dwrv_",
	"ex_dae_",
]

const NON_SEAMLESS_PATTERNS: Array[String] = [
	"ex_cave", "cave_door", "ex_bc_cave", "ex_cavern",
	"ex_tomb", "tomb_door", "ancestral",
	"terrain_",
	"ex_ship", "ship_cabin", "trapdoor",
]

var object_source: RefCounted = null


func configure(source: RefCounted) -> void:
	object_source = source


static func make_exterior_portal_key(cell_grid: Vector2i, base_ref_id: StringName, ref_num: int) -> StringName:
	return StringName("ext:%d,%d:%s:%d" % [cell_grid.x, cell_grid.y, str(base_ref_id).to_lower(), ref_num])


static func make_interior_portal_key(cell_name: String, base_ref_id: StringName, ref_num: int) -> StringName:
	return StringName("int:%s:%s:%d" % [cell_name.to_lower(), str(base_ref_id).to_lower(), ref_num])


func get_exterior_transition_portals(cell_payload: Variant, cell_grid: Vector2i) -> Array[TransitionPortalDescriptor]:
	var portals: Array[TransitionPortalDescriptor] = []
	if cell_payload == null or not ("references" in cell_payload):
		return portals

	var source_space := WorldSpaceHandleScript.exterior_grid(cell_grid)
	for ref: Variant in cell_payload.references:
		if not _is_teleport_ref(ref):
			continue
		var target_name := str(ref.teleport_cell)
		if target_name.is_empty() or not _is_interior_space(target_name):
			continue
		var descriptor := _build_portal_descriptor(ref, source_space, WorldSpaceHandleScript.interior(target_name), cell_grid)
		_identify_shell_for_portal(descriptor, cell_payload, ref)
		portals.append(descriptor)
	return portals


func get_interior_transition_portals(
	space_handle: WorldSpaceHandle,
	cell_payload: Variant,
	pocket_offset: Vector3,
) -> Array[TransitionPortalDescriptor]:
	var portals: Array[TransitionPortalDescriptor] = []
	if cell_payload == null or space_handle == null or not ("references" in cell_payload):
		return portals

	for ref: Variant in cell_payload.references:
		if not _is_teleport_ref(ref):
			continue
		var target_name := str(ref.teleport_cell)
		var target_space: WorldSpaceHandle = null
		if target_name.is_empty() or not _is_interior_space(target_name):
			target_space = WorldSpaceHandleScript.exterior_grid(CS.world_to_cell_grid(ref.teleport_pos))
		else:
			target_space = WorldSpaceHandleScript.interior(target_name)
		var descriptor := _build_portal_descriptor(ref, space_handle, target_space, Vector2i.ZERO)
		descriptor.portal_key = make_interior_portal_key(space_handle.key, descriptor.affordance_key, descriptor.affordance_ordinal)
		_set_ref_portal_key(ref, descriptor.portal_key)
		descriptor.source_position += pocket_offset
		portals.append(descriptor)
	return portals


func get_transition_space_payload(space_handle: WorldSpaceHandle) -> Variant:
	if object_source == null or space_handle == null:
		return null
	if space_handle.is_interior() and object_source.has_method("get_source_cell"):
		return object_source.call("get_source_cell", space_handle.key)
	if space_handle.is_exterior() and object_source.has_method("get_source_exterior_cell"):
		var parts := space_handle.key.split(",")
		if parts.size() == 2:
			return object_source.call("get_source_exterior_cell", Vector2i(int(parts[0]), int(parts[1])))
	return null


func build_transition_environment(
	space_handle: WorldSpaceHandle,
	cell_payload: Variant,
	exterior_environment: Environment,
) -> Environment:
	if space_handle == null or not space_handle.is_interior() or cell_payload == null:
		return null
	var env := Environment.new()

	if bool(cell_payload.get("has_ambient")):
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		var c: Color = cell_payload.get("ambient_color")
		var luma: float = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
		if luma < MIN_INTERIOR_LUMA:
			if luma < 0.001:
				env.ambient_light_color = Color(MIN_INTERIOR_LUMA, MIN_INTERIOR_LUMA, MIN_INTERIOR_LUMA)
			else:
				env.ambient_light_color = c * (MIN_INTERIOR_LUMA / luma)
		else:
			env.ambient_light_color = c
		env.ambient_light_energy = 0.8

		var fog_density := float(cell_payload.get("fog_density"))
		if fog_density > 0.001:
			env.fog_enabled = true
			env.fog_light_color = cell_payload.get("fog_color")
			env.fog_density = fog_density * INTERIOR_FOG_DENSITY_SCALE
	else:
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.15, 0.13, 0.11)
		env.ambient_light_energy = 0.5

	if bool(cell_payload.call("is_quasi_exterior")):
		env.background_mode = Environment.BG_SKY
		if exterior_environment:
			env.sky = exterior_environment.sky
	else:
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.02, 0.02, 0.03)

	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	return env


func _build_portal_descriptor(
	ref: Variant,
	source_space: WorldSpaceHandle,
	target_space: WorldSpaceHandle,
	cell_grid: Vector2i,
) -> TransitionPortalDescriptor:
	var descriptor := TransitionPortalDescriptorScript.new()
	descriptor.source_space = source_space
	descriptor.target_space = target_space
	descriptor.affordance_key = StringName(str(ref.ref_id))
	descriptor.affordance_ordinal = int(ref.ref_num)
	descriptor.portal_key = make_exterior_portal_key(cell_grid, descriptor.affordance_key, descriptor.affordance_ordinal)
	descriptor.source_position = CS.vector_to_godot(ref.position)
	descriptor.source_basis = CS.esm_rotation_to_godot_basis(ref.rotation)
	descriptor.target_position = CS.vector_to_godot(ref.teleport_pos)
	descriptor.target_basis = CS.esm_rotation_to_godot_basis(ref.teleport_rot)
	descriptor.target_yaw_basis = Basis(Vector3.UP, -ref.teleport_rot.z)
	descriptor.display_name = str(descriptor.affordance_key)
	descriptor.prompt_text = "Travel to %s" % target_space.display_name if target_space != null and not target_space.display_name.is_empty() else ""
	_set_ref_portal_key(ref, descriptor.portal_key)
	return descriptor


func _set_ref_portal_key(ref: Variant, portal_key: StringName) -> void:
	if ref is Object:
		(ref as Object).set_meta("transition_portal_key", str(portal_key))


func _is_teleport_ref(ref: Variant) -> bool:
	return ref != null and bool(ref.get("is_teleport"))


func _is_interior_space(cell_name: String) -> bool:
	if object_source == null or cell_name.is_empty() or not object_source.has_method("get_source_cell"):
		return false
	var cell: Variant = object_source.call("get_source_cell", cell_name)
	return cell != null and bool(cell.call("is_interior"))


func _identify_shell_for_portal(
	descriptor: TransitionPortalDescriptor,
	cell_payload: Variant,
	door_ref: Variant,
) -> void:
	var door_pos_mw: Vector3 = door_ref.position
	var best_ref_id: StringName = &""
	var best_model_path: String = ""
	var best_dist_sq: float = INF
	var is_non_seamless := false

	for ref: Variant in cell_payload.references:
		if ref.ref_id == door_ref.ref_id:
			continue
		var record_type: Array = [""]
		var base_record: Variant = _get_base_record(str(ref.ref_id), record_type)
		if base_record == null:
			continue
		var type_name := str(record_type[0])
		if type_name != "static" and type_name != "activator":
			continue
		var model_path := _model_path_for(base_record)
		if model_path.is_empty():
			continue
		var dist_sq: float = ref.position.distance_squared_to(door_pos_mw)
		if dist_sq > BUILDING_SEARCH_RADIUS_SQ * CS.UNITS_PER_METER * CS.UNITS_PER_METER:
			continue
		if _matches_any(model_path, NON_SEAMLESS_PATTERNS):
			is_non_seamless = true
		if _matches_any(model_path, BUILDING_PATTERNS) and dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_ref_id = ref.ref_id
			best_model_path = model_path

	if best_ref_id == &"" and not is_non_seamless:
		for ref: Variant in cell_payload.references:
			if ref.ref_id == door_ref.ref_id:
				continue
			var record_type: Array = [""]
			var base_record: Variant = _get_base_record(str(ref.ref_id), record_type)
			if base_record == null or str(record_type[0]) != "static":
				continue
			var model_path := _model_path_for(base_record)
			if model_path.is_empty():
				continue
			var dist_sq: float = ref.position.distance_squared_to(door_pos_mw)
			var fallback_radius_mw: float = 3.0 * CS.UNITS_PER_METER
			if dist_sq > fallback_radius_mw * fallback_radius_mw:
				continue
			if dist_sq < best_dist_sq:
				best_dist_sq = dist_sq
				best_ref_id = ref.ref_id
				best_model_path = model_path

	descriptor.shell_key = best_ref_id
	descriptor.shell_model_path = best_model_path
	descriptor.supports_seamless = not is_non_seamless and best_ref_id != &""

	if best_ref_id != &"":
		var dist_godot: float = sqrt(best_dist_sq) * CS.SCALE_FACTOR
		Log.info("streaming", "Portal '%s' -> shell '%s' (%s, dist=%.1fm, seamless=%s)" % [
			descriptor.affordance_key, best_ref_id, best_model_path.get_file(),
			dist_godot, descriptor.supports_seamless])
	else:
		Log.warn("streaming", "Portal '%s' -> NO shell found (seamless=%s, non_seamless_match=%s)" % [
			descriptor.affordance_key, descriptor.supports_seamless, is_non_seamless])


func _get_base_record(ref_id: String, record_type_out: Array) -> Variant:
	if object_source == null:
		return null
	if object_source.has_method("get_source_base_record_cached"):
		return object_source.call("get_source_base_record_cached", ref_id, record_type_out)
	if object_source.has_method("get_source_base_record"):
		return object_source.call("get_source_base_record", ref_id, record_type_out)
	return null


func _model_path_for(base_record: Variant) -> String:
	if base_record != null and "model" in base_record and base_record.model:
		return str(base_record.model).to_lower()
	return ""


func _matches_any(value: String, patterns: Array[String]) -> bool:
	for pattern: String in patterns:
		if value.contains(pattern):
			return true
	return false
