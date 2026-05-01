class_name CellStaticBucket
extends RefCounted

const DU := preload("res://src/core/world/distance_utils.gd")

var type_name: String = ""
var payload_key: String = ""
var bucket_key: String = ""
var cell_grid: Vector2i = Vector2i.ZERO
var instance_count: int = 0
var draw_groups: Array[DrawGroup] = []
var visible: bool = true
var frozen: bool = false
var resource_handle: RefCounted = null
var _bucket_owner_key: String = ""
var _resource_refs: Array[Resource] = []


class DrawGroup:
	var mesh_resource: Mesh = null
	var material_resource: Material = null
	var surface_materials: Array[Material] = []
	var local_transform: Transform3D = Transform3D.IDENTITY
	var multimesh: MultiMesh = null
	var instance_rid: RID = RID()
	var instance_count: int = 0


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

	for sub_mesh_value: Variant in sub_meshes:
		var sub_mesh: Variant = sub_mesh_value
		if sub_mesh == null or sub_mesh.mesh_resource == null:
			continue
		var group := _create_draw_group(
			sub_mesh,
			transforms,
			scenario,
			visibility_range_end
		)
		if group != null:
			draw_groups.append(group)

	return not draw_groups.is_empty()


func get_draw_group_count() -> int:
	return draw_groups.size()


func set_visible(p_visible: bool) -> void:
	if frozen:
		return
	if visible == p_visible:
		return
	visible = p_visible
	for group: DrawGroup in draw_groups:
		if group.instance_rid.is_valid():
			RenderingServer.instance_set_visible(group.instance_rid, visible)


func freeze() -> void:
	frozen = true


func cleanup() -> int:
	freeze()
	var released := instance_count
	for group: DrawGroup in draw_groups:
		if group.instance_rid.is_valid():
			RenderingServer.free_rid(group.instance_rid)
			group.instance_rid = RID()
		group.multimesh = null
		group.mesh_resource = null
		group.material_resource = null
		group.surface_materials.clear()
	draw_groups.clear()
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


func _create_draw_group(
	sub_mesh: Variant,
	transforms: Array,
	scenario: RID,
	visibility_range_end: float,
) -> DrawGroup:
	var source_mesh: Mesh = sub_mesh.mesh_resource
	if source_mesh == null:
		return null
	var material_resource: Material = sub_mesh.material_resource
	var surface_materials: Array[Material] = sub_mesh.surface_materials
	var mesh_resource := _make_multimesh_mesh(source_mesh, material_resource, surface_materials)
	if mesh_resource == null:
		return null

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh_resource
	multimesh.instance_count = transforms.size()

	var local_transform: Transform3D = sub_mesh.local_transform
	var mesh_aabb := mesh_resource.get_aabb()
	var custom_aabb := AABB()
	for i in range(transforms.size()):
		var world_transform: Transform3D = transforms[i]
		var slot_transform := world_transform * local_transform
		multimesh.set_instance_transform(i, slot_transform)
		var slot_aabb: AABB = slot_transform * mesh_aabb
		custom_aabb = slot_aabb if i == 0 else custom_aabb.merge(slot_aabb)
	multimesh.custom_aabb = custom_aabb

	var rid := RenderingServer.instance_create()
	RenderingServer.instance_set_base(rid, multimesh.get_rid())
	RenderingServer.instance_set_scenario(rid, scenario)
	RenderingServer.instance_set_transform(rid, Transform3D.IDENTITY)

	var material_rid: RID = material_resource.get_rid() if material_resource != null else RID()
	if material_rid.is_valid():
		RenderingServer.instance_geometry_set_material_override(rid, material_rid)

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

	var group := DrawGroup.new()
	group.mesh_resource = mesh_resource
	group.material_resource = material_resource
	group.surface_materials = surface_materials.duplicate()
	group.local_transform = local_transform
	group.multimesh = multimesh
	group.instance_rid = rid
	group.instance_count = transforms.size()
	return group


func _make_multimesh_mesh(source_mesh: Mesh, material_resource: Material, surface_materials: Array[Material]) -> Mesh:
	if material_resource != null or surface_materials.is_empty():
		return source_mesh

	var surface_count := source_mesh.get_surface_count()
	var material_count := mini(surface_materials.size(), surface_count)
	var has_surface_material := false
	for surface_index in range(material_count):
		if surface_materials[surface_index] != null:
			has_surface_material = true
			break
	if not has_surface_material:
		return source_mesh

	var mesh_copy: Mesh = source_mesh.duplicate(false) as Mesh
	if mesh_copy == null:
		return source_mesh
	for surface_index in range(material_count):
		var material: Material = surface_materials[surface_index]
		if material != null:
			mesh_copy.surface_set_material(surface_index, material)
	return mesh_copy
