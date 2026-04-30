class_name CellStaticBucket
extends RefCounted

const DU := preload("res://src/core/world/distance_utils.gd")

var type_name: String = ""
var cell_grid: Vector2i = Vector2i.ZERO
var instance_count: int = 0
var rs_instances: Array[RID] = []
var visible: bool = true


## Phase 2A bucket primitive: this owns RS instance RIDs only. Mesh/material
## resources are still held by StaticObjectRenderer._mesh_types.
func configure(
	p_type_name: String,
	p_cell_grid: Vector2i,
	sub_meshes: Array,
	transforms: Array,
	scenario: RID,
	visibility_range_end: float,
	globally_visible: bool,
) -> bool:
	if p_type_name.is_empty() or sub_meshes.is_empty() or transforms.is_empty() or not scenario.is_valid():
		return false

	type_name = p_type_name
	cell_grid = p_cell_grid
	instance_count = transforms.size()
	visible = globally_visible

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
	if visible == p_visible:
		return
	visible = p_visible
	for rid: RID in rs_instances:
		if rid.is_valid():
			RenderingServer.instance_set_visible(rid, visible)


func cleanup() -> int:
	var released := instance_count
	for rid: RID in rs_instances:
		if rid.is_valid():
			RenderingServer.free_rid(rid)
	rs_instances.clear()
	instance_count = 0
	visible = false
	return released


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
