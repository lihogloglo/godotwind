class_name CellStaticBucket
extends RefCounted

const DU := preload("res://src/core/world/distance_utils.gd")

var type_name: String = ""
var payload_key: String = ""
var bucket_key: String = ""
var cell_grid: Vector2i = Vector2i.ZERO
var instance_count: int = 0
var rs_instances: Array[RID] = []
var visible: bool = true
var frozen: bool = false
var resource_handle: RefCounted = null
var _bucket_owner_key: String = ""
var _resource_refs: Array[Resource] = []


## Phase 2B bucket primitive: owns RS instance RIDs plus the strong resource
## refs/handle needed by those RIDs. `_mesh_types` is lookup, not lifetime.
func configure(
	p_type_name: String,
	p_payload_key: String,
	p_cell_grid: Vector2i,
	sub_meshes: Array,
	transforms: Array,
	scenario: RID,
	visibility_range_end: float,
	globally_visible: bool,
	p_resource_handle: RefCounted = null,
) -> bool:
	if p_type_name.is_empty() or p_payload_key.is_empty() or sub_meshes.is_empty() or transforms.is_empty() or not scenario.is_valid():
		return false

	type_name = p_type_name
	payload_key = p_payload_key
	cell_grid = p_cell_grid
	bucket_key = "%d,%d:%s" % [cell_grid.x, cell_grid.y, payload_key]
	_bucket_owner_key = "bucket:%s" % bucket_key
	instance_count = transforms.size()
	visible = globally_visible
	frozen = false
	resource_handle = p_resource_handle
	if resource_handle != null and resource_handle.has_method("add_owner"):
		resource_handle.call("add_owner", _bucket_owner_key)
	_pin_sub_mesh_resources(sub_meshes)

	for world_transform_value: Variant in transforms:
		var world_transform: Transform3D = world_transform_value
		for sub_mesh_value: Variant in sub_meshes:
			var sub_mesh: Variant = sub_mesh_value
			if sub_mesh == null or sub_mesh.mesh_resource == null:
				continue
			var material_rid: RID = sub_mesh.material_resource.get_rid() if sub_mesh.material_resource else RID()
			var rid := _create_rs_instance(
				sub_mesh.mesh_resource.get_rid(),
				material_rid,
				sub_mesh.surface_materials,
				world_transform * sub_mesh.local_transform,
				scenario,
				visibility_range_end
			)
			if rid.is_valid():
				rs_instances.append(rid)

	return not rs_instances.is_empty()


func set_visible(p_visible: bool) -> void:
	if frozen:
		return
	if visible == p_visible:
		return
	visible = p_visible
	for rid: RID in rs_instances:
		if rid.is_valid():
			RenderingServer.instance_set_visible(rid, visible)


func freeze() -> void:
	frozen = true


func cleanup() -> int:
	freeze()
	var released := instance_count
	for rid: RID in rs_instances:
		if rid.is_valid():
			RenderingServer.free_rid(rid)
	rs_instances.clear()
	instance_count = 0
	visible = false
	_release_resource_owner()
	_resource_refs.clear()
	return released


func _pin_sub_mesh_resources(sub_meshes: Array) -> void:
	for sub_mesh_value: Variant in sub_meshes:
		var sub_mesh: Variant = sub_mesh_value
		if sub_mesh == null:
			continue
		_append_resource_ref(sub_mesh.mesh_resource)
		_append_resource_ref(sub_mesh.material_resource)
		for material_value: Variant in sub_mesh.surface_materials:
			_append_resource_ref(material_value as Resource)


func _append_resource_ref(resource: Resource) -> void:
	if resource != null and resource not in _resource_refs:
		_resource_refs.append(resource)


func _release_resource_owner() -> void:
	if resource_handle != null and resource_handle.has_method("remove_owner") and not _bucket_owner_key.is_empty():
		resource_handle.call("remove_owner", _bucket_owner_key)
	resource_handle = null
	_bucket_owner_key = ""


func _create_rs_instance(
	mesh_rid: RID,
	material_rid: RID,
	surface_materials: Array[Material],
	xform: Transform3D,
	scenario: RID,
	visibility_range_end: float,
) -> RID:
	if not mesh_rid.is_valid():
		return RID()

	var rid := RenderingServer.instance_create()
	RenderingServer.instance_set_base(rid, mesh_rid)
	RenderingServer.instance_set_scenario(rid, scenario)
	RenderingServer.instance_set_transform(rid, xform)

	if material_rid.is_valid():
		RenderingServer.instance_geometry_set_material_override(rid, material_rid)
	elif not surface_materials.is_empty():
		for surface_index in range(surface_materials.size()):
			var material: Material = surface_materials[surface_index]
			if material != null:
				RenderingServer.instance_set_surface_override_material(rid, surface_index, material.get_rid())

	RenderingServer.instance_geometry_set_visibility_range(
		rid,
		0.0,
		visibility_range_end,
		0.0,
		DU.FADE_MARGIN_LOD3_FAR,
		RenderingServer.VISIBILITY_RANGE_FADE_SELF
	)
	RenderingServer.instance_geometry_set_lod_bias(rid, 1.0)
	if not visible:
		RenderingServer.instance_set_visible(rid, false)

	return rid
