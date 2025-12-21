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

## Mesh subdivision level for water surface (higher = more detail)
@export_range(1, 64) var mesh_subdivisions: int = 16:
	set(value):
		mesh_subdivisions = value
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
	# Override parent's _setup_nodes to use polygon collision
	if not Engine.is_editor_hint():
		_area.body_entered.connect(_on_body_entered)
		_area.body_exited.connect(_on_body_exited)

	# Don't call parent _ready, we handle setup ourselves
	_setup_polygon_nodes()
	_create_shader()
	_create_material()
	_update_volume()


func _setup_polygon_nodes() -> void:
	# Create Area3D for detection if not exists
	if not _area:
		_area = Area3D.new()
		_area.name = "WaterArea"
		_area.monitoring = true
		_area.monitorable = false
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


func _create_polygon_collision() -> void:
	if not _collision_shape or polygon_points.size() < 3:
		return

	# Create extruded 3D shape from 2D polygon
	# We'll create a ConvexPolygonShape3D by extruding the polygon vertically
	var shape = ConvexPolygonShape3D.new()
	var points_3d: PackedVector3Array = []

	# Bottom vertices (at depth)
	for point in polygon_points:
		points_3d.append(Vector3(point.x, -size.y, point.y))

	# Top vertices (at water surface)
	for point in polygon_points:
		points_3d.append(Vector3(point.x, 0.0, point.y))

	shape.points = points_3d
	_collision_shape.shape = shape
	_collision_shape.position.y = water_surface_height


func _create_polygon_mesh() -> void:
	if not _water_mesh or polygon_points.size() < 3:
		return

	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	# Triangulate the polygon using ear clipping algorithm
	var triangles := _triangulate_polygon(polygon_points)

	# Calculate polygon bounds for UV mapping
	var bounds := _calculate_polygon_bounds(polygon_points)
	var bounds_size := Vector2(bounds.size.x, bounds.size.y)

	# Create vertices for each triangle
	for tri_indices in triangles:
		for idx in tri_indices:
			var point := polygon_points[idx]
			vertices.append(Vector3(point.x, 0.0, point.y))
			normals.append(Vector3.UP)

			# UV coordinates based on polygon bounds
			var uv := (point - bounds.position) / bounds_size
			uvs.append(uv)

			indices.append(vertices.size() - 1)

	# Optionally subdivide for wave detail
	if mesh_subdivisions > 1:
		var subdivided := _subdivide_mesh(vertices, uvs, indices, mesh_subdivisions)
		vertices = subdivided.vertices
		uvs = subdivided.uvs
		indices = subdivided.indices
		normals.resize(vertices.size())
		normals.fill(Vector3.UP)

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	_water_mesh.mesh = mesh
	_water_mesh.material_override = _material
	_water_mesh.position.y = water_surface_height

	print("[PolygonWaterVolume] Created polygon mesh with %d vertices, %d triangles" % [
		vertices.size(), indices.size() / 3])


## Triangulate polygon using ear clipping algorithm
## Returns array of triangle indices (each element is [i1, i2, i3])
func _triangulate_polygon(points: PackedVector2Array) -> Array:
	if points.size() < 3:
		return []

	var triangles: Array = []
	var remaining_indices: Array = []
	for i in range(points.size()):
		remaining_indices.append(i)

	# Ear clipping algorithm
	while remaining_indices.size() > 3:
		var ear_found := false

		for i in range(remaining_indices.size()):
			var prev_idx := remaining_indices[(i - 1 + remaining_indices.size()) % remaining_indices.size()]
			var curr_idx := remaining_indices[i]
			var next_idx := remaining_indices[(i + 1) % remaining_indices.size()]

			var p1 := points[prev_idx]
			var p2 := points[curr_idx]
			var p3 := points[next_idx]

			# Check if this forms a valid ear
			if _is_ear(p1, p2, p3, points, remaining_indices):
				triangles.append([prev_idx, curr_idx, next_idx])
				remaining_indices.remove_at(i)
				ear_found = true
				break

		if not ear_found:
			# Fallback: force create triangle if stuck
			if remaining_indices.size() >= 3:
				triangles.append([
					remaining_indices[0],
					remaining_indices[1],
					remaining_indices[2]
				])
				remaining_indices.remove_at(1)
			else:
				break

	# Add final triangle
	if remaining_indices.size() == 3:
		triangles.append([
			remaining_indices[0],
			remaining_indices[1],
			remaining_indices[2]
		])

	return triangles


## Check if three points form a valid ear (convex and contains no other points)
func _is_ear(p1: Vector2, p2: Vector2, p3: Vector2, all_points: PackedVector2Array, indices: Array) -> bool:
	# Check if triangle is counter-clockwise (convex)
	var cross := (p2.x - p1.x) * (p3.y - p1.y) - (p2.y - p1.y) * (p3.x - p1.x)
	if cross <= 0:
		return false

	# Check if any other point is inside this triangle
	for idx in indices:
		var point := all_points[idx]
		if point == p1 or point == p2 or point == p3:
			continue

		if _point_in_triangle(point, p1, p2, p3):
			return false

	return true


## Check if point is inside triangle
func _point_in_triangle(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var v0 := c - a
	var v1 := b - a
	var v2 := p - a

	var dot00 := v0.dot(v0)
	var dot01 := v0.dot(v1)
	var dot02 := v0.dot(v2)
	var dot11 := v1.dot(v1)
	var dot12 := v1.dot(v2)

	var inv_denom := 1.0 / (dot00 * dot11 - dot01 * dot01)
	var u := (dot11 * dot02 - dot01 * dot12) * inv_denom
	var v := (dot00 * dot12 - dot01 * dot02) * inv_denom

	return (u >= 0) and (v >= 0) and (u + v <= 1)


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


## Subdivide mesh for more detail (optional - for wave animation)
func _subdivide_mesh(verts: PackedVector3Array, uvs_in: PackedVector2Array, inds: PackedInt32Array, level: int) -> Dictionary:
	# Simple subdivision: just return original for now
	# Could implement Catmull-Clark or loop subdivision for smoother meshes
	return {
		"vertices": verts,
		"uvs": uvs_in,
		"indices": inds
	}


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
	if "flow_speed" in data and data["flow_speed"]:
		flow_speed = data["flow_speed"]


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
