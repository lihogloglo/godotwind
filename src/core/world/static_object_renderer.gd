## StaticObjectRenderer - RenderingServer-based renderer for static world objects
##
## Uses RenderingServer directly instead of Node3D for maximum performance.
## Best for objects that are purely visual with no interaction:
## - Flora (grass, flowers, kelp)
## - Small rocks and debris
## - Distant buildings (impostor LOD)
## - Ground clutter
##
## Benefits over Node3D:
## - No scene tree overhead (~40 bytes per Node vs ~16 bytes per RID)
## - Faster instantiation (no node creation, parenting, notifications)
## - Better batching potential
## - Direct control over visibility culling
##
## Limitations:
## - No automatic frustum culling (we do distance-based instead)
## - No physics - use for visual-only objects
## - No signals or scripting on instances
##
## Usage:
##   var renderer := StaticObjectRenderer.new()
##   add_child(renderer)  # Needs to be in tree for scenario
##   renderer.register_mesh("flora_kelp", kelp_mesh, kelp_material)
##   var id := renderer.add_instance("flora_kelp", transform)
##   renderer.set_instance_visible(id, false)  # Hide when far
##   renderer.remove_instance(id)  # When cell unloads
class_name StaticObjectRenderer
extends Node3D

## Registered mesh types: type_name -> MeshType
var _mesh_types: Dictionary = {}

## All instances: instance_id -> InstanceData
var _instances: Dictionary = {}

## Next instance ID
var _next_id: int = 0

## World scenario RID (set when entering tree)
var _scenario: RID = RID()

## Stats
var _stats: Dictionary = {
	"mesh_types": 0,
	"total_instances": 0,
	"visible_instances": 0,
}


## Mesh type registration data
class MeshType:
	var name: String
	var mesh_rid: RID          ## RenderingServer mesh
	var material_rid: RID      ## RenderingServer material (optional)
	var owns_mesh: bool        ## Whether we created the mesh RID
	var owns_material: bool    ## Whether we created the material RID
	var aabb: AABB             ## Bounding box for culling
	var instance_count: int = 0


## Instance data
class InstanceData:
	var id: int
	var type_name: String
	var instance_rid: RID      ## RenderingServer instance
	var transform: Transform3D
	var visible: bool = true
	var cell_grid: Vector2i    ## Which cell this belongs to


func _enter_tree() -> void:
	_scenario = get_viewport().get_world_3d().scenario


func _exit_tree() -> void:
	# Clean up all RenderingServer resources
	clear()


## Register a mesh type that can be instanced
## mesh: Can be ArrayMesh, or null to create from arrays
## material: Optional material to apply
func register_mesh_type(type_name: String, mesh: Mesh, material: Material = null) -> void:
	if type_name in _mesh_types:
		return  # Already registered

	var mesh_type := MeshType.new()
	mesh_type.name = type_name

	# Get or create mesh RID
	if mesh:
		mesh_type.mesh_rid = mesh.get_rid()
		mesh_type.owns_mesh = false
		mesh_type.aabb = mesh.get_aabb()
	else:
		mesh_type.mesh_rid = RenderingServer.mesh_create()
		mesh_type.owns_mesh = true
		mesh_type.aabb = AABB()

	# Get or create material RID
	if material:
		mesh_type.material_rid = material.get_rid()
		mesh_type.owns_material = false
	else:
		mesh_type.material_rid = RID()
		mesh_type.owns_material = false

	_mesh_types[type_name] = mesh_type
	_stats["mesh_types"] += 1


## Register a mesh type from a Node3D prototype (extracts mesh and material)
func register_from_prototype(type_name: String, prototype: Node3D) -> void:
	if type_name in _mesh_types:
		return

	# Find first MeshInstance3D in prototype
	var mesh_instance := _find_mesh_instance(prototype)
	if not mesh_instance or not mesh_instance.mesh:
		push_warning("StaticObjectRenderer: No mesh found in prototype for '%s'" % type_name)
		return

	var material: Material = null
	if mesh_instance.material_override:
		material = mesh_instance.material_override
	elif mesh_instance.mesh.get_surface_count() > 0:
		material = mesh_instance.mesh.surface_get_material(0)

	register_mesh_type(type_name, mesh_instance.mesh, material)


func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var result := _find_mesh_instance(child)
		if result:
			return result
	return null


## Add an instance of a registered mesh type
## Returns instance ID for later manipulation, or -1 on failure
func add_instance(type_name: String, transform: Transform3D, cell_grid: Vector2i = Vector2i.ZERO) -> int:
	if type_name not in _mesh_types:
		return -1

	if not _scenario.is_valid():
		push_warning("StaticObjectRenderer: Not in scene tree, cannot create instances")
		return -1

	var mesh_type: MeshType = _mesh_types[type_name]
	var rs := RenderingServer

	# Create instance
	var instance_rid := rs.instance_create()
	rs.instance_set_base(instance_rid, mesh_type.mesh_rid)
	rs.instance_set_scenario(instance_rid, _scenario)
	rs.instance_set_transform(instance_rid, transform)

	# Apply material if we have one
	if mesh_type.material_rid.is_valid():
		rs.instance_geometry_set_material_override(instance_rid, mesh_type.material_rid)

	# Store instance data
	var id := _next_id
	_next_id += 1

	var data := InstanceData.new()
	data.id = id
	data.type_name = type_name
	data.instance_rid = instance_rid
	data.transform = transform
	data.visible = true
	data.cell_grid = cell_grid

	_instances[id] = data
	mesh_type.instance_count += 1
	_stats["total_instances"] += 1
	_stats["visible_instances"] += 1

	return id


## Remove an instance
func remove_instance(id: int) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]

	# Free the RenderingServer instance
	if data.instance_rid.is_valid():
		RenderingServer.free_rid(data.instance_rid)

	# Update stats
	if data.type_name in _mesh_types:
		var mesh_type: MeshType = _mesh_types[data.type_name]
		mesh_type.instance_count -= 1

	if data.visible:
		_stats["visible_instances"] -= 1
	_stats["total_instances"] -= 1

	_instances.erase(id)


## Remove all instances belonging to a cell
func remove_cell_instances(cell_grid: Vector2i) -> int:
	var to_remove: Array[int] = []

	for id in _instances:
		var data: InstanceData = _instances[id]
		if data.cell_grid == cell_grid:
			to_remove.append(id)

	for id in to_remove:
		remove_instance(id)

	return to_remove.size()


## Set instance visibility
func set_instance_visible(id: int, visible: bool) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]
	if data.visible == visible:
		return

	data.visible = visible
	RenderingServer.instance_set_visible(data.instance_rid, visible)

	if visible:
		_stats["visible_instances"] += 1
	else:
		_stats["visible_instances"] -= 1


## Set instance transform
func set_instance_transform(id: int, transform: Transform3D) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]
	data.transform = transform
	RenderingServer.instance_set_transform(data.instance_rid, transform)


## Get instance transform
func get_instance_transform(id: int) -> Transform3D:
	if id not in _instances:
		return Transform3D.IDENTITY
	return _instances[id].transform


## Update visibility based on distance from camera
## Returns number of visibility changes made
func update_visibility_by_distance(camera_pos: Vector3, max_distance: float) -> int:
	var changes := 0
	var max_dist_sq := max_distance * max_distance

	for id in _instances:
		var data: InstanceData = _instances[id]
		var dist_sq := camera_pos.distance_squared_to(data.transform.origin)
		var should_be_visible := dist_sq <= max_dist_sq

		if data.visible != should_be_visible:
			set_instance_visible(id, should_be_visible)
			changes += 1

	return changes


## Batch add instances (more efficient than individual adds)
## transforms: Array of Transform3D
## Returns array of instance IDs
func add_instances_batch(type_name: String, transforms: Array, cell_grid: Vector2i = Vector2i.ZERO) -> Array[int]:
	var ids: Array[int] = []

	if type_name not in _mesh_types:
		return ids

	if not _scenario.is_valid():
		return ids

	var mesh_type: MeshType = _mesh_types[type_name]
	var rs := RenderingServer

	for transform in transforms:
		if not transform is Transform3D:
			continue

		var instance_rid := rs.instance_create()
		rs.instance_set_base(instance_rid, mesh_type.mesh_rid)
		rs.instance_set_scenario(instance_rid, _scenario)
		rs.instance_set_transform(instance_rid, transform)

		if mesh_type.material_rid.is_valid():
			rs.instance_geometry_set_material_override(instance_rid, mesh_type.material_rid)

		var id := _next_id
		_next_id += 1

		var data := InstanceData.new()
		data.id = id
		data.type_name = type_name
		data.instance_rid = instance_rid
		data.transform = transform
		data.visible = true
		data.cell_grid = cell_grid

		_instances[id] = data
		ids.append(id)

	mesh_type.instance_count += ids.size()
	_stats["total_instances"] += ids.size()
	_stats["visible_instances"] += ids.size()

	return ids


## Clear all instances and optionally mesh types
func clear(clear_mesh_types: bool = true) -> void:
	var rs := RenderingServer

	# Free all instances
	for id in _instances:
		var data: InstanceData = _instances[id]
		if data.instance_rid.is_valid():
			rs.free_rid(data.instance_rid)
	_instances.clear()

	# Free mesh types if requested
	if clear_mesh_types:
		for type_name in _mesh_types:
			var mesh_type: MeshType = _mesh_types[type_name]
			if mesh_type.owns_mesh and mesh_type.mesh_rid.is_valid():
				rs.free_rid(mesh_type.mesh_rid)
			if mesh_type.owns_material and mesh_type.material_rid.is_valid():
				rs.free_rid(mesh_type.material_rid)
		_mesh_types.clear()
		_stats["mesh_types"] = 0

	_stats["total_instances"] = 0
	_stats["visible_instances"] = 0


## Get statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Get mesh type info
func get_mesh_type_stats(type_name: String) -> Dictionary:
	if type_name not in _mesh_types:
		return {}

	var mesh_type: MeshType = _mesh_types[type_name]
	return {
		"name": mesh_type.name,
		"instance_count": mesh_type.instance_count,
		"aabb": mesh_type.aabb,
	}


## Get all registered mesh type names
func get_registered_types() -> Array[String]:
	var types: Array[String] = []
	for type_name in _mesh_types:
		types.append(type_name)
	return types


## Check if a type is registered
func has_type(type_name: String) -> bool:
	return type_name in _mesh_types
