class_name CellStaticBucket
extends RefCounted

const DU := preload("res://src/core/world/distance_utils.gd")
const SC := preload("res://src/core/world/streaming_config.gd")

const TRANSFORM_STRIDE := 12
const MULTIMESH_CLUSTER_SIZE_M: float = DU.CELL_SIZE_METERS * 0.5
const MAX_TRANSFORMS_PER_DRAW_GROUP := 128
const CONFIGURE_READY := "ready"
const CONFIGURE_PENDING := "pending"
const CONFIGURE_FAILED := "failed"
const EXTERIOR_RENDER_LAYER_MASK := 1

var type_name: String = ""
var payload_key: String = ""
var bucket_key: String = ""
var cell_grid: Vector2i = Vector2i.ZERO
var instance_count: int = 0
var draw_groups: Array[DrawGroup] = []
var visible: bool = true
var frozen: bool = false
var visibility_range_begin: float = 0.0
var visibility_range_end: float = DU.MID_END
var resource_handle: RefCounted = null
var _bucket_owner_key: String = ""
var _resource_refs: Array[Resource] = []
var _debug_force_visible: bool = false
var _debug_material: StandardMaterial3D = null
var _configure_active: bool = false
var _pending_sub_meshes: Array = []
var _pending_transforms: Array = []
var _pending_scenario: RID = RID()
var _pending_sub_mesh_index: int = 0
var _pending_clusters: Array = []
var _pending_cluster_index: int = 0
var _pending_bucket_origin: Vector3 = Vector3.ZERO
var _pending_current_sub_mesh: Variant = null


class DrawGroup:
	var mesh_resource: Mesh = null
	var material_resource: Material = null
	var surface_materials: Array[Material] = []
	var local_transform: Transform3D = Transform3D.IDENTITY
	var multimesh: MultiMesh = null
	var instance_rid: RID = RID()
	var instance_count: int = 0
	var local_aabb: AABB = AABB()


## Phase 2B bucket primitive: owns RS instance RIDs plus the strong resource
## refs/handle needed by those RIDs. `_mesh_types` is lookup, not lifetime.
func configure(
	p_type_name: String,
	p_payload_key: String,
	p_cell_grid: Vector2i,
	sub_meshes: Array,
	transforms: Array,
	scenario: RID,
	p_visibility_range_end: float,
	globally_visible: bool,
	p_resource_handle: RefCounted = null,
	p_visibility_range_begin: float = 0.0,
) -> bool:
	if not begin_configure(
		p_type_name,
		p_payload_key,
		p_cell_grid,
		sub_meshes,
		transforms,
		scenario,
		p_visibility_range_end,
		globally_visible,
		p_resource_handle,
		p_visibility_range_begin
	):
		return false
	while true:
		var status := configure_step(9_223_372_036_854_775_000)
		if status != CONFIGURE_PENDING:
			return status == CONFIGURE_READY
	return false


func begin_configure(
	p_type_name: String,
	p_payload_key: String,
	p_cell_grid: Vector2i,
	sub_meshes: Array,
	transforms: Array,
	scenario: RID,
	p_visibility_range_end: float,
	globally_visible: bool,
	p_resource_handle: RefCounted = null,
	p_visibility_range_begin: float = 0.0,
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
	visibility_range_begin = maxf(0.0, p_visibility_range_begin)
	visibility_range_end = p_visibility_range_end
	resource_handle = p_resource_handle
	if resource_handle != null and resource_handle.has_method("add_owner"):
		resource_handle.call("add_owner", _bucket_owner_key)
	_pin_sub_mesh_resources(sub_meshes)
	_pending_sub_meshes = sub_meshes.duplicate()
	_pending_transforms = transforms.duplicate()
	_pending_scenario = scenario
	_pending_sub_mesh_index = 0
	_pending_clusters.clear()
	_pending_cluster_index = 0
	_pending_bucket_origin = DU.cell_to_world_origin(cell_grid)
	_pending_current_sub_mesh = null
	_configure_active = true
	return true


func configure_step(deadline_usec: int) -> String:
	if not _configure_active:
		return CONFIGURE_READY if not draw_groups.is_empty() else CONFIGURE_FAILED
	var processed_clusters := 0
	while _pending_sub_mesh_index < _pending_sub_meshes.size():
		if Time.get_ticks_usec() >= deadline_usec:
			return CONFIGURE_PENDING
		if _pending_current_sub_mesh == null:
			_pending_current_sub_mesh = _pending_sub_meshes[_pending_sub_mesh_index]
			if _pending_current_sub_mesh == null or _pending_current_sub_mesh.mesh_resource == null:
				_advance_pending_sub_mesh()
				continue
			var mesh_resource: Mesh = _pending_current_sub_mesh.mesh_resource
			if mesh_resource == null or not is_instance_valid(mesh_resource):
				_advance_pending_sub_mesh()
				continue
			var clusters := _cluster_transforms(
				_pending_transforms,
				_pending_current_sub_mesh.local_transform,
				_pending_bucket_origin
			)
			_pending_clusters = _split_cluster_batches(clusters.values())
			_pending_cluster_index = 0

		while _pending_cluster_index < _pending_clusters.size():
			if Time.get_ticks_usec() >= deadline_usec:
				return CONFIGURE_PENDING
			var cluster_transforms: Array = _pending_clusters[_pending_cluster_index]
			var group := _create_draw_group_for_cluster(
				_pending_current_sub_mesh,
				cluster_transforms,
				_pending_bucket_origin,
				_pending_scenario
			)
			if group != null:
				draw_groups.append(group)
			_pending_cluster_index += 1
			processed_clusters += 1
			if processed_clusters > 0 and Time.get_ticks_usec() >= deadline_usec:
				return CONFIGURE_PENDING
		_advance_pending_sub_mesh()

	_clear_configure_state()
	return CONFIGURE_READY if not draw_groups.is_empty() else CONFIGURE_FAILED


func _advance_pending_sub_mesh() -> void:
	_pending_sub_mesh_index += 1
	_pending_clusters.clear()
	_pending_cluster_index = 0
	_pending_current_sub_mesh = null


func _clear_configure_state() -> void:
	_configure_active = false
	_pending_sub_meshes.clear()
	_pending_transforms.clear()
	_pending_scenario = RID()
	_pending_sub_mesh_index = 0
	_pending_clusters.clear()
	_pending_cluster_index = 0
	_pending_bucket_origin = Vector3.ZERO
	_pending_current_sub_mesh = null


func get_draw_group_count() -> int:
	return draw_groups.size()


func get_draw_group_census() -> Dictionary:
	var singleton_draw_groups := 0
	var singleton_instances := 0
	var multimesh_draw_groups := 0
	var multimesh_instances := 0
	var max_draw_group_instances := 0
	var contributors: Dictionary = {}
	for group: DrawGroup in draw_groups:
		var count := int(group.instance_count)
		max_draw_group_instances = maxi(max_draw_group_instances, count)
		var material_key := _draw_group_material_key(group)
		var contributor_key := "%s|%s" % [type_name, material_key]
		var contributor: Dictionary = contributors.get(contributor_key, {})
		if contributor.is_empty():
			contributor = {
				"type": type_name,
				"model": payload_key,
				"material": material_key,
				"instances": 0,
				"draw_groups": 0,
				"singleton_draw_groups": 0,
				"singleton_instances": 0,
				"multimesh_draw_groups": 0,
				"multimesh_instances": 0,
				"max_aabb_dimension": 0.0,
			}
		contributor["instances"] = int(contributor.get("instances", 0)) + count
		contributor["draw_groups"] = int(contributor.get("draw_groups", 0)) + 1
		contributor["max_aabb_dimension"] = maxf(
			float(contributor.get("max_aabb_dimension", 0.0)),
			_aabb_max_dimension(group.local_aabb)
		)
		if group.multimesh == null:
			singleton_draw_groups += 1
			singleton_instances += count
			contributor["singleton_draw_groups"] = int(contributor.get("singleton_draw_groups", 0)) + 1
			contributor["singleton_instances"] = int(contributor.get("singleton_instances", 0)) + count
		else:
			multimesh_draw_groups += 1
			multimesh_instances += count
			contributor["multimesh_draw_groups"] = int(contributor.get("multimesh_draw_groups", 0)) + 1
			contributor["multimesh_instances"] = int(contributor.get("multimesh_instances", 0)) + count
		contributors[contributor_key] = contributor
	var contributor_rows: Array[Dictionary] = []
	for contributor_value: Variant in contributors.values():
		contributor_rows.append(contributor_value as Dictionary)
	contributor_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("draw_groups", 0)) > int(b.get("draw_groups", 0))
	)
	return {
		"draw_groups": draw_groups.size(),
		"singleton_draw_groups": singleton_draw_groups,
		"singleton_instances": singleton_instances,
		"multimesh_draw_groups": multimesh_draw_groups,
		"multimesh_instances": multimesh_instances,
		"max_draw_group_instances": max_draw_group_instances,
		"contributors": contributor_rows,
	}


func set_visibility_range(p_visibility_range_begin: float, p_visibility_range_end: float) -> void:
	if frozen:
		return
	if is_equal_approx(visibility_range_begin, p_visibility_range_begin) and is_equal_approx(visibility_range_end, p_visibility_range_end):
		return
	visibility_range_begin = p_visibility_range_begin
	visibility_range_end = p_visibility_range_end
	for group: DrawGroup in draw_groups:
		if group.instance_rid.is_valid():
			_apply_visibility_range(group)


func set_visibility_range_end(p_visibility_range_end: float) -> void:
	set_visibility_range(visibility_range_begin, p_visibility_range_end)


func set_visible(p_visible: bool) -> void:
	if frozen:
		return
	if visible == p_visible:
		return
	visible = p_visible
	for group: DrawGroup in draw_groups:
		if group.instance_rid.is_valid():
			RenderingServer.instance_set_visible(group.instance_rid, true if _debug_force_visible else visible)


func set_debug_force_visible(enabled: bool) -> void:
	if frozen:
		return
	if _debug_force_visible == enabled:
		return
	_debug_force_visible = enabled
	for group: DrawGroup in draw_groups:
		_apply_debug_force_visible(group, enabled)


func get_debug_info() -> Dictionary:
	var groups: Array[Dictionary] = []
	for i in range(draw_groups.size()):
		var group: DrawGroup = draw_groups[i]
		groups.append(_get_draw_group_debug_info(group, i))
	return {
		"type_name": type_name,
		"payload_key": payload_key,
		"bucket_key": bucket_key,
		"cell_grid": cell_grid,
		"visible": visible,
		"frozen": frozen,
		"debug_force_visible": _debug_force_visible,
		"instance_count": instance_count,
		"draw_group_count": draw_groups.size(),
		"visibility_range_begin": visibility_range_begin,
		"visibility_range_end": visibility_range_end,
		"resource_handle_pinned": resource_handle != null,
		"resource_ref_count": _resource_refs.size(),
		"configure_active": _configure_active,
		"draw_groups": groups,
	}


func freeze() -> void:
	frozen = true


func cleanup() -> int:
	freeze()
	_clear_configure_state()
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


func _apply_debug_force_visible(group: DrawGroup, enabled: bool) -> void:
	if not group.instance_rid.is_valid():
		return
	RenderingServer.instance_set_ignore_culling(group.instance_rid, enabled)
	RenderingServer.instance_set_visible(group.instance_rid, true if enabled else visible)
	if enabled:
		RenderingServer.instance_geometry_set_material_override(group.instance_rid, _get_debug_material().get_rid())
		return
	_restore_group_materials(group)


func _get_debug_material() -> StandardMaterial3D:
	if _debug_material == null:
		_debug_material = StandardMaterial3D.new()
		_debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_debug_material.albedo_color = Color(1.0, 0.1, 0.85, 1.0)
		_debug_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _debug_material


func _restore_group_materials(group: DrawGroup) -> void:
	if not group.instance_rid.is_valid():
		return
	var material_rid := _get_valid_material_rid(group.material_resource)
	RenderingServer.instance_geometry_set_material_override(group.instance_rid, material_rid)
	if material_rid.is_valid() or group.multimesh != null:
		return
	for surface_index in range(group.surface_materials.size()):
		var surface_material_rid := _get_valid_material_rid(group.surface_materials[surface_index])
		if surface_material_rid.is_valid():
			RenderingServer.instance_set_surface_override_material(group.instance_rid, surface_index, surface_material_rid)


func _get_draw_group_debug_info(group: DrawGroup, index: int) -> Dictionary:
	var mesh_aabb := AABB()
	var mesh_rid_valid := false
	var surface_count := 0
	if group.mesh_resource != null and is_instance_valid(group.mesh_resource):
		mesh_aabb = group.mesh_resource.get_aabb()
		mesh_rid_valid = group.mesh_resource.get_rid().is_valid()
		surface_count = group.mesh_resource.get_surface_count()
	var custom_aabb := group.local_aabb
	var multimesh_rid_valid := false
	var multimesh_instance_count := 0
	var multimesh_visible_count := -1
	var multimesh_transform_format := -1
	if group.multimesh != null and is_instance_valid(group.multimesh):
		custom_aabb = group.multimesh.custom_aabb
		multimesh_rid_valid = group.multimesh.get_rid().is_valid()
		multimesh_instance_count = group.multimesh.instance_count
		multimesh_visible_count = group.multimesh.visible_instance_count
		multimesh_transform_format = group.multimesh.transform_format
	return {
		"index": index,
		"kind": "multimesh" if group.multimesh != null else "single_rs",
		"rid_valid": group.instance_rid.is_valid(),
		"mesh_rid_valid": mesh_rid_valid,
		"multimesh_rid_valid": multimesh_rid_valid,
		"instance_count": group.instance_count,
		"multimesh_instance_count": multimesh_instance_count,
		"multimesh_visible_instance_count": multimesh_visible_count,
		"multimesh_transform_format": multimesh_transform_format,
		"layer_mask": EXTERIOR_RENDER_LAYER_MASK,
		"visibility_range_begin": visibility_range_begin,
		"visibility_range_end": visibility_range_end,
		"visibility_margin_end": DU.FADE_MARGIN_LOD3_FAR + _aabb_horizontal_radius(group.local_aabb),
		"mesh_aabb": mesh_aabb,
		"custom_aabb": custom_aabb,
		"local_group_aabb": group.local_aabb,
		"local_transform": group.local_transform,
		"has_material_override": group.material_resource != null and is_instance_valid(group.material_resource),
		"surface_material_count": group.surface_materials.size(),
		"mesh_surface_count": surface_count,
		"debug_force_visible": _debug_force_visible,
	}


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
	if resource != null and is_instance_valid(resource) and resource not in _resource_refs:
		_resource_refs.append(resource)


static func _get_valid_material_rid(material: Material) -> RID:
	if material == null or not is_instance_valid(material):
		return RID()
	return material.get_rid()


static func _draw_group_material_key(group: DrawGroup) -> String:
	if group.material_resource != null and is_instance_valid(group.material_resource):
		return _material_resource_key(group.material_resource)
	var keys := PackedStringArray()
	for material: Material in group.surface_materials:
		if material != null and is_instance_valid(material):
			keys.append(_material_resource_key(material))
	if keys.is_empty() and group.mesh_resource != null and is_instance_valid(group.mesh_resource):
		for surface_index in range(group.mesh_resource.get_surface_count()):
			var material := group.mesh_resource.surface_get_material(surface_index)
			if material != null and is_instance_valid(material):
				keys.append(_material_resource_key(material))
	if keys.is_empty():
		return "<none>"
	keys.sort()
	return "|".join(keys)


static func _material_resource_key(material: Material) -> String:
	if not material.resource_path.is_empty():
		return material.resource_path.to_lower()
	if not material.resource_name.is_empty():
		return material.resource_name
	return "material#%d" % material.get_instance_id()


static func _aabb_max_dimension(aabb: AABB) -> float:
	return maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))


func _release_resource_owner() -> void:
	if resource_handle != null and resource_handle.has_method("remove_owner") and not _bucket_owner_key.is_empty():
		resource_handle.call("remove_owner", _bucket_owner_key)
	resource_handle = null
	_bucket_owner_key = ""


func _create_draw_groups(
	sub_mesh: Variant,
	transforms: Array,
	scenario: RID,
) -> Array[DrawGroup]:
	var bucket_origin := DU.cell_to_world_origin(cell_grid)
	var clusters := _cluster_transforms(transforms, sub_mesh.local_transform, bucket_origin)
	var groups: Array[DrawGroup] = []
	for cluster_value: Variant in _split_cluster_batches(clusters.values()):
		var cluster_transforms: Array = cluster_value
		var group := _create_draw_group_for_cluster(sub_mesh, cluster_transforms, bucket_origin, scenario)
		if group != null:
			groups.append(group)
	return groups


func _create_draw_group_for_cluster(
	sub_mesh: Variant,
	cluster_transforms: Array,
	bucket_origin: Vector3,
	scenario: RID,
) -> DrawGroup:
	var source_mesh: Mesh = sub_mesh.mesh_resource
	if source_mesh == null or not is_instance_valid(source_mesh):
		return null
	var material_resource: Material = sub_mesh.material_resource
	if material_resource != null and not is_instance_valid(material_resource):
		material_resource = null
	var surface_materials: Array[Material] = sub_mesh.surface_materials
	var mesh_resource := source_mesh
	if mesh_resource == null:
		return null

	var local_transform: Transform3D = sub_mesh.local_transform
	var mesh_aabb := mesh_resource.get_aabb()
	if cluster_transforms.size() == 1:
		var single_transform: Transform3D = cluster_transforms[0]
		return _create_single_rs_draw_group(
			mesh_resource,
			material_resource,
			surface_materials,
			local_transform,
			single_transform,
			mesh_aabb,
			scenario
		)
	return _create_multimesh_draw_group(
		mesh_resource,
		material_resource,
		surface_materials,
		local_transform,
		cluster_transforms,
		mesh_aabb,
		bucket_origin,
		scenario
	)


func _create_multimesh_draw_group(
	mesh_resource: Mesh,
	material_resource: Material,
	surface_materials: Array[Material],
	local_transform: Transform3D,
	transforms: Array,
	mesh_aabb: AABB,
	bucket_origin: Vector3,
	scenario: RID,
) -> DrawGroup:
	if transforms.is_empty() or not scenario.is_valid():
		return null
	var mesh_rid := mesh_resource.get_rid()
	if not mesh_rid.is_valid():
		return null

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh_resource
	multimesh.instance_count = transforms.size()

	var packed := _pack_multimesh_transforms(transforms, local_transform, mesh_aabb, bucket_origin)
	multimesh.set_buffer(packed.buffer)
	multimesh.custom_aabb = packed.custom_aabb

	var rid := RenderingServer.instance_create()
	RenderingServer.instance_set_base(rid, multimesh.get_rid())
	RenderingServer.instance_set_scenario(rid, scenario)
	RenderingServer.instance_set_layer_mask(rid, EXTERIOR_RENDER_LAYER_MASK)
	RenderingServer.instance_set_transform(rid, Transform3D(Basis.IDENTITY, bucket_origin))

	var material_rid := _get_valid_material_rid(material_resource)
	if material_rid.is_valid():
		RenderingServer.instance_geometry_set_material_override(rid, material_rid)
	else:
		# RenderingServer per-surface overrides are not valid on MultiMesh bases.
		# StaticObjectRenderer materializes surface overrides into the Mesh
		# resource before bucket creation; keep this as a final crash guard.
		pass

	var group := DrawGroup.new()
	group.mesh_resource = mesh_resource
	group.material_resource = material_resource
	group.surface_materials = surface_materials.duplicate()
	group.local_transform = local_transform
	group.multimesh = multimesh
	group.instance_rid = rid
	group.instance_count = transforms.size()
	group.local_aabb = packed.custom_aabb
	_apply_visibility_range(group)
	RenderingServer.instance_geometry_set_lod_bias(rid, SC.DEFAULT_LOD_BIAS)
	RenderingServer.instance_geometry_set_cast_shadows_setting(
		rid,
		_shadow_setting_for_mesh_aabb(mesh_aabb)
	)
	if not visible:
		RenderingServer.instance_set_visible(rid, false)
	return group


func _create_single_rs_draw_group(
	mesh_resource: Mesh,
	material_resource: Material,
	surface_materials: Array[Material],
	local_transform: Transform3D,
	world_transform: Transform3D,
	mesh_aabb: AABB,
	scenario: RID,
) -> DrawGroup:
	if not scenario.is_valid():
		return null
	var mesh_rid := mesh_resource.get_rid()
	if not mesh_rid.is_valid():
		return null

	var slot_transform := world_transform * local_transform
	var slot_aabb: AABB = slot_transform * mesh_aabb

	var rid := RenderingServer.instance_create()
	RenderingServer.instance_set_base(rid, mesh_rid)
	RenderingServer.instance_set_scenario(rid, scenario)
	RenderingServer.instance_set_layer_mask(rid, EXTERIOR_RENDER_LAYER_MASK)
	RenderingServer.instance_set_transform(rid, slot_transform)

	var material_rid := _get_valid_material_rid(material_resource)
	if material_rid.is_valid():
		RenderingServer.instance_geometry_set_material_override(rid, material_rid)
	else:
		for surface_index in range(surface_materials.size()):
			var surface_material_rid := _get_valid_material_rid(surface_materials[surface_index])
			if surface_material_rid.is_valid():
				RenderingServer.instance_set_surface_override_material(rid, surface_index, surface_material_rid)

	var group := DrawGroup.new()
	group.mesh_resource = mesh_resource
	group.material_resource = material_resource
	group.surface_materials = surface_materials.duplicate()
	group.local_transform = local_transform
	group.multimesh = null
	group.instance_rid = rid
	group.instance_count = 1
	group.local_aabb = slot_aabb
	_apply_visibility_range(group)
	RenderingServer.instance_geometry_set_lod_bias(rid, SC.DEFAULT_LOD_BIAS)
	RenderingServer.instance_geometry_set_cast_shadows_setting(
		rid,
		_shadow_setting_for_mesh_aabb(mesh_aabb)
	)
	if not visible:
		RenderingServer.instance_set_visible(rid, false)
	return group


func _apply_visibility_range(group: DrawGroup) -> void:
	var radius := _aabb_horizontal_radius(group.local_aabb)
	var begin := maxf(0.0, visibility_range_begin - radius)
	var end := visibility_range_end + radius
	RenderingServer.instance_geometry_set_visibility_range(
		group.instance_rid,
		begin,
		end,
		0.0,
		DU.FADE_MARGIN_LOD3_FAR + radius,
		SC.MID_VISIBILITY_FADE_MODE
	)


static func _aabb_horizontal_radius(aabb: AABB) -> float:
	if aabb.size == Vector3.ZERO:
		return 0.0
	return Vector2(aabb.size.x, aabb.size.z).length() * 0.5


static func _shadow_setting_for_mesh_aabb(aabb: AABB) -> int:
	var max_dim := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	if max_dim < SC.MID_SHADOW_MIN_MESH_SIZE_M:
		return RenderingServer.SHADOW_CASTING_SETTING_OFF
	return RenderingServer.SHADOW_CASTING_SETTING_ON


func _cluster_transforms(transforms: Array, local_transform: Transform3D, bucket_origin: Vector3) -> Dictionary:
	var clusters: Dictionary = {}
	for transform_value: Variant in transforms:
		var world_transform: Transform3D = transform_value
		var origin := (world_transform * local_transform).origin - bucket_origin
		var key := Vector2i(
			floori(origin.x / MULTIMESH_CLUSTER_SIZE_M),
			floori(origin.z / MULTIMESH_CLUSTER_SIZE_M)
		)
		if key not in clusters:
			clusters[key] = []
		clusters[key].append(world_transform)
	return clusters


func _split_cluster_batches(cluster_values: Array) -> Array:
	var batches: Array = []
	for cluster_value: Variant in cluster_values:
		var cluster_transforms: Array = cluster_value
		var count := cluster_transforms.size()
		if count <= MAX_TRANSFORMS_PER_DRAW_GROUP:
			batches.append(cluster_transforms)
			continue
		var start := 0
		while start < count:
			var end := mini(start + MAX_TRANSFORMS_PER_DRAW_GROUP, count)
			batches.append(cluster_transforms.slice(start, end))
			start = end
	return batches


func _pack_multimesh_transforms(
	transforms: Array,
	local_transform: Transform3D,
	mesh_aabb: AABB,
	bucket_origin: Vector3
) -> Dictionary:
	var buffer := PackedFloat32Array()
	buffer.resize(transforms.size() * TRANSFORM_STRIDE)
	var custom_aabb := AABB()
	for i in range(transforms.size()):
		var world_transform: Transform3D = transforms[i]
		var slot_transform := world_transform * local_transform
		slot_transform.origin -= bucket_origin
		var off := i * TRANSFORM_STRIDE
		var b := slot_transform.basis
		var o := slot_transform.origin
		buffer[off + 0] = b.x.x
		buffer[off + 1] = b.y.x
		buffer[off + 2] = b.z.x
		buffer[off + 3] = o.x
		buffer[off + 4] = b.x.y
		buffer[off + 5] = b.y.y
		buffer[off + 6] = b.z.y
		buffer[off + 7] = o.y
		buffer[off + 8] = b.x.z
		buffer[off + 9] = b.y.z
		buffer[off + 10] = b.z.z
		buffer[off + 11] = o.z

		var slot_aabb: AABB = slot_transform * mesh_aabb
		custom_aabb = slot_aabb if i == 0 else custom_aabb.merge(slot_aabb)
	return {
		"buffer": buffer,
		"custom_aabb": custom_aabb,
	}
