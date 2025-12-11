## ObjectLODManager - Manages Level of Detail for world objects
##
## Provides distance-based LOD for cell objects:
## - Full detail: Original NIF model with all geometry
## - Low detail: Simplified representation (shadows disabled)
## - Billboard: RenderingServer-based impostor for maximum performance
## - Culled: Object hidden entirely at very far distances
##
## Uses RenderingServer directly for billboards to avoid scene tree overhead.
##
## Usage:
##   var lod_manager := ObjectLODManager.new()
##   lod_manager.camera = get_viewport().get_camera_3d()
##   cell_node.add_child(lod_manager)
##   lod_manager.register_object(mesh_instance, bounds_size)
class_name ObjectLODManager
extends Node3D

## LOD levels
enum LODLevel {
	FULL,        ## Original model (closest)
	LOW,         ## Simplified representation
	BILLBOARD,   ## 2D impostor billboard
	CULLED       ## Hidden (farthest)
}

## Distance thresholds for LOD transitions (in meters)
## Objects smaller than MIN_SIZE_FOR_LOD use simpler thresholds
@export var lod_full_distance: float = 50.0      ## Switch to low detail
@export var lod_low_distance: float = 150.0      ## Switch to billboard
@export var lod_cull_distance: float = 500.0     ## Cull entirely

## Minimum object size to apply LOD (smaller objects cull earlier)
@export var min_size_for_full_lod: float = 5.0   ## Meters
@export var min_size_for_billboard: float = 2.0  ## Meters

## Camera to calculate distances from
var camera: Camera3D = null

## Tracked objects: { node_id -> LODObjectData }
var _tracked_objects: Dictionary = {}

## Impostor material cache for billboards
var _impostor_materials: Dictionary = {}  ## texture_path -> StandardMaterial3D

## Stats
var _stats: Dictionary = {
	"objects_tracked": 0,
	"objects_full": 0,
	"objects_low": 0,
	"objects_billboard": 0,
	"objects_culled": 0,
	"lod_switches_this_frame": 0,
}

## Update frequency (don't update every frame for performance)
var _update_interval: float = 0.1  ## seconds
var _time_since_update: float = 0.0


## Object data stored for each tracked object
class LODObjectData:
	var node: Node3D                      ## The object node
	var bounds_size: float                ## Approximate size in meters
	var current_lod: int = LODLevel.FULL  ## Current LOD level
	var original_children: Array = []     ## Stored when switching to billboard
	var texture_path: String = ""         ## For impostor generation
	# RenderingServer resources for billboard (more performant than nodes)
	var rs_instance: RID = RID()          ## RenderingServer instance RID
	var rs_mesh: RID = RID()              ## RenderingServer mesh RID
	var rs_material: RID = RID()          ## RenderingServer material RID


func _process(delta: float) -> void:
	_time_since_update += delta
	if _time_since_update < _update_interval:
		return
	_time_since_update = 0.0

	_update_all_lods()


## Register an object for LOD management
## bounds_size: approximate diameter of the object in meters
## texture_path: optional texture for billboard impostor
func register_object(node: Node3D, bounds_size: float, texture_path: String = "") -> void:
	if not node or not is_instance_valid(node):
		return

	var data := LODObjectData.new()
	data.node = node
	data.bounds_size = bounds_size
	data.texture_path = texture_path

	_tracked_objects[node.get_instance_id()] = data
	_stats["objects_tracked"] += 1


## Unregister an object from LOD management
func unregister_object(node: Node3D) -> void:
	if not node:
		return
	var id := node.get_instance_id()
	if id in _tracked_objects:
		var data: LODObjectData = _tracked_objects[id]
		# Restore original state if needed
		_restore_full_lod(data)
		# Free RenderingServer resources
		_free_rs_billboard(data)
		_tracked_objects.erase(id)
		_stats["objects_tracked"] -= 1


## Register all mesh instances in a cell node
func register_cell_objects(cell_node: Node3D) -> void:
	_register_recursive(cell_node)


func _register_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		var size := _estimate_mesh_size(mesh_instance)
		var tex_path := _get_primary_texture_path(mesh_instance)
		register_object(mesh_instance, size, tex_path)

	for child in node.get_children():
		_register_recursive(child)


## Update LOD for all tracked objects
func _update_all_lods() -> void:
	if not camera:
		return

	var camera_pos := camera.global_position
	_stats["lod_switches_this_frame"] = 0
	_stats["objects_full"] = 0
	_stats["objects_low"] = 0
	_stats["objects_billboard"] = 0
	_stats["objects_culled"] = 0

	var to_remove: Array = []

	for id in _tracked_objects:
		var data: LODObjectData = _tracked_objects[id]

		# Check if object still exists
		if not data.node or not is_instance_valid(data.node):
			to_remove.append(id)
			continue

		var distance := camera_pos.distance_to(data.node.global_position)
		var new_lod := _calculate_lod_level(distance, data.bounds_size)

		if new_lod != data.current_lod:
			_switch_lod(data, new_lod)
			_stats["lod_switches_this_frame"] += 1

		# Update stats
		match data.current_lod:
			LODLevel.FULL:
				_stats["objects_full"] += 1
			LODLevel.LOW:
				_stats["objects_low"] += 1
			LODLevel.BILLBOARD:
				_stats["objects_billboard"] += 1
			LODLevel.CULLED:
				_stats["objects_culled"] += 1

	# Clean up removed objects and free their RS resources
	for id in to_remove:
		var data: LODObjectData = _tracked_objects[id]
		_free_rs_billboard(data)
		_tracked_objects.erase(id)
		_stats["objects_tracked"] -= 1


## Calculate appropriate LOD level based on distance and object size
func _calculate_lod_level(distance: float, size: float) -> int:
	# Scale distances by object size (smaller objects switch sooner)
	var size_factor := clampf(size / min_size_for_full_lod, 0.5, 2.0)
	var full_dist := lod_full_distance * size_factor
	var low_dist := lod_low_distance * size_factor
	var cull_dist := lod_cull_distance * size_factor

	# Very small objects skip billboard stage
	if size < min_size_for_billboard:
		if distance < full_dist:
			return LODLevel.FULL
		else:
			return LODLevel.CULLED

	if distance < full_dist:
		return LODLevel.FULL
	elif distance < low_dist:
		return LODLevel.LOW
	elif distance < cull_dist:
		return LODLevel.BILLBOARD
	else:
		return LODLevel.CULLED


## Switch an object to a new LOD level
func _switch_lod(data: LODObjectData, new_lod: int) -> void:
	var old_lod := data.current_lod

	match new_lod:
		LODLevel.FULL:
			_restore_full_lod(data)
		LODLevel.LOW:
			# For now, LOW is same as FULL but with reduced shadow quality
			# Future: swap to simplified mesh
			_apply_low_lod(data)
		LODLevel.BILLBOARD:
			_apply_billboard_lod(data)
		LODLevel.CULLED:
			_apply_culled(data)

	data.current_lod = new_lod


## Restore full detail LOD
func _restore_full_lod(data: LODObjectData) -> void:
	if not data.node or not is_instance_valid(data.node):
		return

	# Show the node
	data.node.visible = true

	# Re-enable shadows
	if data.node is MeshInstance3D:
		(data.node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	# Restore original children if they were hidden
	for child in data.original_children:
		if is_instance_valid(child):
			child.visible = true
	data.original_children.clear()

	# Hide RenderingServer billboard (don't free - may reuse)
	if data.rs_instance.is_valid():
		RenderingServer.instance_set_visible(data.rs_instance, false)


## Apply low detail LOD (reduced quality but same mesh)
func _apply_low_lod(data: LODObjectData) -> void:
	if not data.node or not is_instance_valid(data.node):
		return

	data.node.visible = true

	# Disable shadows for performance
	if data.node is MeshInstance3D:
		(data.node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Apply billboard LOD (2D impostor using RenderingServer)
func _apply_billboard_lod(data: LODObjectData) -> void:
	if not data.node or not is_instance_valid(data.node):
		return

	# Hide original mesh children
	data.original_children.clear()
	for child in data.node.get_children():
		if child is MeshInstance3D or child is GeometryInstance3D:
			if child.visible:
				data.original_children.append(child)
				child.visible = false

	# Also hide if this node itself is a mesh
	if data.node is MeshInstance3D:
		data.node.visible = false

	# Create RenderingServer billboard if not exists
	if not data.rs_instance.is_valid():
		_create_rs_billboard(data)

	# Show and update billboard position
	if data.rs_instance.is_valid():
		RenderingServer.instance_set_visible(data.rs_instance, true)
		_update_rs_billboard_transform(data)


## Apply culled state (completely hidden)
func _apply_culled(data: LODObjectData) -> void:
	if not data.node or not is_instance_valid(data.node):
		return

	data.node.visible = false

	# Hide RenderingServer billboard
	if data.rs_instance.is_valid():
		RenderingServer.instance_set_visible(data.rs_instance, false)


## Create a billboard using RenderingServer directly (more performant)
func _create_rs_billboard(data: LODObjectData) -> void:
	var rs := RenderingServer

	# Create mesh (quad)
	data.rs_mesh = rs.mesh_create()

	var size := data.bounds_size
	var half := size * 0.5

	# Quad vertices (billboard will rotate toward camera)
	var vertices := PackedVector3Array([
		Vector3(-half, 0, 0),
		Vector3(half, 0, 0),
		Vector3(half, size, 0),
		Vector3(-half, size, 0),
	])

	var uvs := PackedVector2Array([
		Vector2(0, 1),
		Vector2(1, 1),
		Vector2(1, 0),
		Vector2(0, 0),
	])

	var normals := PackedVector3Array([
		Vector3(0, 0, 1),
		Vector3(0, 0, 1),
		Vector3(0, 0, 1),
		Vector3(0, 0, 1),
	])

	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3])

	# Build surface arrays
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	rs.mesh_add_surface_from_arrays(data.rs_mesh, RenderingServer.PRIMITIVE_TRIANGLES, arrays)

	# Create material
	data.rs_material = rs.material_create()
	rs.material_set_param(data.rs_material, "billboard_mode", 1)  # BILLBOARD_ENABLED

	# Try to load texture
	var texture_rid := RID()
	if not data.texture_path.is_empty():
		var texture := TextureLoader.load_texture(data.texture_path)
		if texture:
			texture_rid = texture.get_rid()

	if texture_rid.is_valid():
		rs.material_set_param(data.rs_material, "albedo_texture", texture_rid)
	else:
		rs.material_set_param(data.rs_material, "albedo_color", Color(0.6, 0.6, 0.6, 0.9))

	# Set material on mesh surface
	rs.mesh_surface_set_material(data.rs_mesh, 0, data.rs_material)

	# Create instance
	data.rs_instance = rs.instance_create()
	rs.instance_set_base(data.rs_instance, data.rs_mesh)

	# Get the scenario from viewport
	var scenario := get_viewport().get_world_3d().scenario
	rs.instance_set_scenario(data.rs_instance, scenario)

	# Set initial transform
	_update_rs_billboard_transform(data)

	# Initially hidden
	rs.instance_set_visible(data.rs_instance, false)


## Update RenderingServer billboard transform to match object position
func _update_rs_billboard_transform(data: LODObjectData) -> void:
	if not data.rs_instance.is_valid() or not data.node or not is_instance_valid(data.node):
		return

	var transform := data.node.global_transform
	RenderingServer.instance_set_transform(data.rs_instance, transform)


## Free RenderingServer resources for a billboard
func _free_rs_billboard(data: LODObjectData) -> void:
	var rs := RenderingServer

	if data.rs_instance.is_valid():
		rs.free_rid(data.rs_instance)
		data.rs_instance = RID()

	if data.rs_mesh.is_valid():
		rs.free_rid(data.rs_mesh)
		data.rs_mesh = RID()

	if data.rs_material.is_valid():
		rs.free_rid(data.rs_material)
		data.rs_material = RID()


## Estimate the size of a mesh instance in meters
func _estimate_mesh_size(mesh_instance: MeshInstance3D) -> float:
	if not mesh_instance.mesh:
		return 1.0

	var aabb := mesh_instance.mesh.get_aabb()
	var size := aabb.size
	return maxf(maxf(size.x, size.y), size.z)


## Get the primary texture path from a mesh instance
func _get_primary_texture_path(mesh_instance: MeshInstance3D) -> String:
	# Check material override
	var mat := mesh_instance.material_override
	if not mat:
		# Check surface materials
		if mesh_instance.mesh and mesh_instance.mesh.get_surface_count() > 0:
			mat = mesh_instance.mesh.surface_get_material(0)

	if mat and mat is StandardMaterial3D:
		var std_mat := mat as StandardMaterial3D
		if std_mat.albedo_texture:
			return std_mat.albedo_texture.resource_path
		# Check metadata for deferred texture path
		if std_mat.has_meta("texture_path"):
			return std_mat.get_meta("texture_path")

	return ""


## Get LOD statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Set camera reference
func set_camera(cam: Camera3D) -> void:
	camera = cam


## Clear all tracked objects and free RenderingServer resources
func clear() -> void:
	for id in _tracked_objects:
		var data: LODObjectData = _tracked_objects[id]
		_restore_full_lod(data)
		# Free RenderingServer resources
		_free_rs_billboard(data)
	_tracked_objects.clear()
	_stats["objects_tracked"] = 0


## Called when node is removed from tree - cleanup RS resources
func _exit_tree() -> void:
	for id in _tracked_objects:
		var data: LODObjectData = _tracked_objects[id]
		_free_rs_billboard(data)
