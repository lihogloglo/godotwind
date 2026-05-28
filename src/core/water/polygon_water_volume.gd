## PolygonWaterVolume - Polygon-based water volume for lakes, rivers with complex shapes
## Extends WaterVolume to support arbitrary polygon boundaries instead of boxes
## Essential for Morrowind's irregular lakes and rivers
@tool
class_name PolygonWaterVolume
extends WaterVolume

## Polygon boundary points in local XZ coordinates
## Define the water body outline as viewed from above
@export var polygon_points: PackedVector2Array = PackedVector2Array([
	Vector2(-10, -10),
	Vector2(10, -10),
	Vector2(10, 10),
	Vector2(-10, 10)
]):
	set(value):
		polygon_points = value
		if is_inside_tree():
			_update_volume()

## Reserved for future tessellation. Polygon surfaces currently use authored vertices only.
@export_range(1, 1) var mesh_subdivisions: int = 1:
	set(_value):
		mesh_subdivisions = 1
		if is_inside_tree():
			_update_volume()

## Debug: Show polygon boundary in editor
@export var show_debug_boundary: bool = false:
	set(value):
		show_debug_boundary = value
		if is_inside_tree():
			_update_debug_visualization()

# Debug visualization
var _debug_boundary: Node3D = null


func _ready() -> void:
	# Don't call parent _ready, we handle setup ourselves
	_setup_polygon_nodes()
	_create_shader()
	_create_material()
	_update_volume()

	if not Engine.is_editor_hint():
		_area.body_entered.connect(_on_body_entered)
		_area.body_exited.connect(_on_body_exited)
		if register_with_water_registry:
			_register_with_water_registry()
		_register_water_interaction_renderer()


func _setup_polygon_nodes() -> void:
	# Create Area3D for detection if not exists
	if not _area:
		_area = Area3D.new()
		_area.name = "WaterArea"
		_area.monitoring = true
		_area.monitorable = false
		_area.collision_layer = 0
		_area.collision_mask = detection_collision_mask
		add_child(_area)
		if Engine.is_editor_hint():
			_area.owner = get_tree().edited_scene_root

	# Create collision shape if not exists
	if not _collision_shape:
		_collision_shape = CollisionShape3D.new()
		_collision_shape.name = "PolygonCollision"
		_area.add_child(_collision_shape)
		if Engine.is_editor_hint():
			_collision_shape.owner = get_tree().edited_scene_root

	# Create water mesh if not exists
	if not _water_mesh:
		_water_mesh = MeshInstance3D.new()
		_water_mesh.name = "WaterSurface"
		add_child(_water_mesh)
		if Engine.is_editor_hint():
			_water_mesh.owner = get_tree().edited_scene_root


func _update_volume() -> void:
	if not is_inside_tree() or polygon_points.size() < 3:
		return

	_create_polygon_collision()
	_create_polygon_mesh()
	_update_debug_visualization()
	_update_body_descriptor()


func _create_polygon_collision() -> void:
	if not _collision_shape or polygon_points.size() < 3:
		return

	# Broadphase only. Exact water coverage is the point-in-polygon query below,
	# which handles concave river shapes without pretending they are convex.
	var polygon_bounds := _calculate_polygon_bounds(polygon_points)
	var shape := BoxShape3D.new()
	shape.size = Vector3(maxf(polygon_bounds.size.x, 0.1), size.y, maxf(polygon_bounds.size.y, 0.1))
	_collision_shape.shape = shape
	_collision_shape.position = Vector3(
		polygon_bounds.position.x + polygon_bounds.size.x * 0.5,
		water_surface_height - size.y * 0.5,
		polygon_bounds.position.y + polygon_bounds.size.y * 0.5
	)


func _create_polygon_mesh() -> void:
	if not _water_mesh or polygon_points.size() < 3:
		return

	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var triangles := _triangulate_polygon(polygon_points)
	if triangles.is_empty():
		_water_mesh.mesh = null
		Log.warn("water", "PolygonWaterVolume: Invalid polygon could not be triangulated")
		return

	# Calculate polygon bounds for UV mapping
	var bounds := _calculate_polygon_bounds(polygon_points)
	var bounds_size := Vector2(maxf(bounds.size.x, 0.001), maxf(bounds.size.y, 0.001))

	# Create one vertex per polygon point; Geometry2D supplies triangle indices
	# and normalizes clockwise contours to counter-clockwise output.
	for point in polygon_points:
		vertices.append(Vector3(point.x, 0.0, point.y))
		normals.append(Vector3.UP)

		# UV coordinates based on polygon bounds
		var uv := (point - bounds.position) / bounds_size
		uvs.append(uv)

	indices = triangles

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	_water_mesh.mesh = mesh
	_water_mesh.material_override = _material
	_water_mesh.position.y = water_surface_height

	Log.debug("water", "PolygonWaterVolume: Created polygon mesh with %d vertices, %d triangles" % [
		vertices.size(), indices.size() / 3])


## Triangulate polygon using Godot's Geometry2D helper.
## Returns flat triangle indices into the source points.
func _triangulate_polygon(points: PackedVector2Array) -> PackedInt32Array:
	if points.size() < 3:
		return PackedInt32Array()
	return Geometry2D.triangulate_polygon(points)


## Calculate bounding rectangle of polygon
func _calculate_polygon_bounds(points: PackedVector2Array) -> Rect2:
	if points.size() == 0:
		return Rect2()

	var min_x := points[0].x
	var max_x := points[0].x
	var min_y := points[0].y
	var max_y := points[0].y

	for point in points:
		min_x = min(min_x, point.x)
		max_x = max(max_x, point.x)
		min_y = min(min_y, point.y)
		max_y = max(max_y, point.y)

	return Rect2(min_x, min_y, max_x - min_x, max_y - min_y)


func _update_body_descriptor() -> void:
	if _body_descriptor == null:
		return
	super._update_body_descriptor()
	if polygon_points.size() < 3:
		_body_descriptor.bounds_valid = false
		return
	var polygon_bounds := _calculate_polygon_bounds(polygon_points)
	var min_local := Vector3(
		polygon_bounds.position.x,
		water_surface_height - size.y,
		polygon_bounds.position.y
	)
	var max_local := Vector3(
		polygon_bounds.position.x + polygon_bounds.size.x,
		water_surface_height,
		polygon_bounds.position.y + polygon_bounds.size.y
	)
	var global_bounds := _aabb_from_transformed_box(min_local, max_local)
	_body_descriptor.bounds = global_bounds
	_body_descriptor.bounds_valid = true


func _aabb_from_transformed_box(min_local: Vector3, max_local: Vector3) -> AABB:
	var corners: Array[Vector3] = [
		Vector3(min_local.x, min_local.y, min_local.z),
		Vector3(max_local.x, min_local.y, min_local.z),
		Vector3(min_local.x, max_local.y, min_local.z),
		Vector3(max_local.x, max_local.y, min_local.z),
		Vector3(min_local.x, min_local.y, max_local.z),
		Vector3(max_local.x, min_local.y, max_local.z),
		Vector3(min_local.x, max_local.y, max_local.z),
		Vector3(max_local.x, max_local.y, max_local.z),
	]
	var first: Vector3 = global_transform * corners[0]
	var bounds := AABB(first, Vector3.ZERO)
	for i in range(1, corners.size()):
		bounds = bounds.expand(global_transform * corners[i])
	return bounds


## Override: Check if position is in polygon (2D check)
func is_position_in_water(pos: Vector3) -> bool:
	if polygon_points.size() < 3:
		return false

	var local_pos := to_local(pos)

	# Check vertical bounds
	if local_pos.y < -size.y or local_pos.y > water_surface_height:
		return false

	# Check if point is inside 2D polygon using ray casting
	var point_2d := Vector2(local_pos.x, local_pos.z)
	return _point_in_polygon(point_2d, polygon_points)


func sample_water_coverage(pos: Vector3) -> float:
	if polygon_points.size() < 3:
		return 0.0
	var local_pos := to_local(pos)
	if local_pos.y < water_surface_height - size.y:
		return 0.0
	var point_2d := Vector2(local_pos.x, local_pos.z)
	return 1.0 if _point_in_polygon(point_2d, polygon_points) else 0.0


## Ray casting algorithm for point-in-polygon test
func _point_in_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
	var inside := false
	var j := polygon.size() - 1

	for i in range(polygon.size()):
		var vi := polygon[i]
		var vj := polygon[j]

		if ((vi.y > point.y) != (vj.y > point.y)) and \
		   (point.x < (vj.x - vi.x) * (point.y - vi.y) / (vj.y - vi.y) + vi.x):
			inside = not inside

		j = i

	return inside


## Debug visualization for editor
func _update_debug_visualization() -> void:
	if not Engine.is_editor_hint():
		return

	# Remove old debug visualization
	if _debug_boundary:
		_debug_boundary.queue_free()
		_debug_boundary = null

	if not show_debug_boundary or polygon_points.size() < 3:
		return

	# Create debug boundary lines
	_debug_boundary = MeshInstance3D.new()
	_debug_boundary.name = "DebugBoundary"
	add_child(_debug_boundary)
	_debug_boundary.owner = get_tree().edited_scene_root

	var immediate := ImmediateMesh.new()
	_debug_boundary.mesh = immediate

	# Draw polygon outline
	immediate.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for point in polygon_points:
		immediate.surface_add_vertex(Vector3(point.x, water_surface_height, point.y))
	# Close the loop
	immediate.surface_add_vertex(Vector3(polygon_points[0].x, water_surface_height, polygon_points[0].y))
	immediate.surface_end()

	# Create simple material for debug lines
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color.CYAN
	mat.disable_receive_shadows = true
	_debug_boundary.material_override = mat


## Export polygon to JSON format
func export_to_json() -> Dictionary:
	return {
		"name": name,
		"water_type": WaterVolume.WaterType.keys()[water_type],
		"position": [global_position.x, global_position.y, global_position.z],
		"water_surface_height": water_surface_height,
		"depth": size.y,
		"polygon": _polygon_to_array(polygon_points),
		"water_color": [water_color.r, water_color.g, water_color.b, water_color.a],
		"clarity": clarity,
		"enable_waves": enable_waves,
		"wave_scale": wave_scale,
		"flow_direction": [flow_direction.x, flow_direction.y] if water_type == WaterVolume.WaterType.RIVER else null,
		"flow_speed": flow_speed if water_type == WaterVolume.WaterType.RIVER else null
	}


## Import polygon from JSON format
func import_from_json(data: Dictionary) -> void:
	if "name" in data:
		name = data["name"]
	if "water_type" in data:
		water_type = WaterVolume.WaterType[data["water_type"]]
	if "position" in data:
		var pos = data["position"]
		global_position = Vector3(pos[0], pos[1], pos[2])
	if "water_surface_height" in data:
		water_surface_height = data["water_surface_height"]
	if "depth" in data:
		size.y = data["depth"]
	if "polygon" in data:
		polygon_points = _array_to_polygon(data["polygon"])
	if "water_color" in data:
		var c = data["water_color"]
		water_color = Color(c[0], c[1], c[2], c[3])
	if "clarity" in data:
		clarity = data["clarity"]
	if "enable_waves" in data:
		enable_waves = data["enable_waves"]
	if "wave_scale" in data:
		wave_scale = data["wave_scale"]
	if "flow_direction" in data and data["flow_direction"]:
		var f = data["flow_direction"]
		flow_direction = Vector2(f[0], f[1])
	if "flow_speed" in data and data["flow_speed"] != null:
		flow_speed = float(data["flow_speed"])


func _polygon_to_array(polygon: PackedVector2Array) -> Array:
	var result: Array = []
	for point in polygon:
		result.append([point.x, point.y])
	return result


func _array_to_polygon(arr: Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in arr:
		result.append(Vector2(point[0], point[1]))
	return result


## Get polygon area (for statistics/debugging)
func get_polygon_area() -> float:
	if polygon_points.size() < 3:
		return 0.0

	var area := 0.0
	var j := polygon_points.size() - 1

	for i in range(polygon_points.size()):
		area += (polygon_points[j].x + polygon_points[i].x) * (polygon_points[j].y - polygon_points[i].y)
		j = i

	return abs(area * 0.5)


## Create a simplified box approximation of the polygon (for quick checks)
func get_bounding_box() -> Rect2:
	return _calculate_polygon_bounds(polygon_points)
