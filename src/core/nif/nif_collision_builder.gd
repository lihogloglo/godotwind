## NIF Collision Builder - Generates Godot collision shapes from NIF data
## Based on OpenMW's BulletNifLoader (components/nifbullet/bulletnifloader.cpp)
##
## Enhanced with smart collision shape detection for better Jolt physics performance:
## - Uses CollisionShapeLibrary for explicit item shape mappings (YAML-based)
## - Auto-detects optimal primitive shapes (sphere, cylinder, box, capsule)
## - Supports convex hull for complex objects (faster than trimesh)
## - Falls back to trimesh only for architecture/terrain
##
## Priority for shape selection:
## 1. Explicit item ID match from CollisionShapeLibrary (YAML)
## 2. Pattern match from CollisionShapeLibrary (YAML wildcards)
## 3. Auto-detection from geometry (vertex analysis)
## 4. Fallback to convex hull or trimesh
##
## Morrowind collision detection works as follows:
## 1. If a NIF has a "RootCollisionNode", geometry under it is used for collision
## 2. If not, collision is auto-generated from rendered geometry based on flags
## 3. BoundingVolume data on NiAVObjects can provide primitive collision shapes
## 4. The "Bounding Box" named node provides actor collision boxes
## 5. String extra data with "NC" prefix disables collision
class_name NIFCollisionBuilder
extends RefCounted

# Preload dependencies
const Defs := preload("res://src/core/nif/nif_defs.gd")
const Reader := preload("res://src/core/nif/nif_reader.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const ShapeLib := preload("res://src/core/nif/collision_shape_library.gd")

## Collision generation mode
## Controls how geometry is converted to physics shapes
enum CollisionMode {
	TRIMESH,        ## Full triangle mesh (most accurate, slowest) - use for architecture
	CONVEX,         ## Convex hull (fast, good for most objects)
	AUTO_PRIMITIVE, ## Auto-detect best primitive (sphere, cylinder, box, capsule)
	PRIMITIVE_ONLY, ## Only use primitives, skip if can't detect (fastest)
}

## Shape analysis result for auto-detection
enum DetectedShape {
	UNKNOWN,
	SPHERE,
	CYLINDER,
	BOX,
	CAPSULE,
	CONVEX,
}

# The NIFReader instance
var _reader: Reader = null

# Debug mode
var debug_mode: bool = false

## Collision mode for geometry (default: AUTO_PRIMITIVE for items, TRIMESH for architecture)
var collision_mode: CollisionMode = CollisionMode.AUTO_PRIMITIVE

## Threshold for shape detection (0.0 = strict, 1.0 = loose)
var detection_tolerance: float = 0.15

## Minimum vertex count for auto-primitive detection (skip tiny meshes)
var min_vertices_for_detection: int = 8

## Force trimesh for RootCollisionNode geometry (architecture usually needs exact collision)
var force_trimesh_for_collision_nodes: bool = true

## Path-based collision overrides (pattern -> CollisionMode or shape type)
## Example: {"meshes/m/misc_potion*.nif": CollisionMode.AUTO_PRIMITIVE}
var collision_overrides: Dictionary = {}

## Item ID for shape library lookups (e.g., "misc_com_bottle_01")
## Set this before calling build_collision() for YAML-based shape overrides
var item_id: String = ""

## Reference to the shape library singleton
var _shape_library: ShapeLib = null

## Collision result structure
class CollisionResult:
	var has_collision: bool = false
	var collision_shapes: Array[Dictionary] = []  # {shape: Shape3D, transform: Transform3D, type: String}
	var root_collision_node_index: int = -1  # Index of RootCollisionNode if found
	var bounding_box_center: Vector3 = Vector3.ZERO
	var bounding_box_extents: Vector3 = Vector3.ZERO
	var has_actor_collision_box: bool = false
	var visual_collision_type: int = 0  # 0=default, 1=camera-only
	var detected_shapes: Array[String] = []  # For debugging - what shapes were detected

## Initialize with a NIFReader
func init(reader: Reader) -> void:
	_reader = reader
	# Get shape library singleton (may or may not be loaded)
	_shape_library = ShapeLib.get_instance()

## Build collision from NIF data
## Returns a CollisionResult with shapes and metadata
func build_collision() -> CollisionResult:
	var result := CollisionResult.new()

	if _reader == null or _reader.roots.is_empty():
		return result

	# First pass: Find RootCollisionNode and actor bounding box
	for root_idx in _reader.roots:
		var root := _reader.get_record(root_idx)
		if root == null:
			continue

		if root is Defs.NiAVObject:
			_find_special_nodes(root as Defs.NiAVObject, result)

	# Second pass: Build collision shapes
	for root_idx in _reader.roots:
		var root := _reader.get_record(root_idx)
		if root == null:
			continue

		if root is Defs.NiAVObject:
			_process_collision_node(root as Defs.NiAVObject, Transform3D.IDENTITY, result)

	result.has_collision = result.collision_shapes.size() > 0 or result.has_actor_collision_box

	if debug_mode:
		print("NIFCollisionBuilder: Built %d collision shapes" % result.collision_shapes.size())
		if result.detected_shapes.size() > 0:
			print("  Detected shapes: %s" % ", ".join(result.detected_shapes))
		if result.has_actor_collision_box:
			print("  Actor collision box: center=%s, extents=%s" % [
				result.bounding_box_center, result.bounding_box_extents
			])

	return result


## Find special collision nodes (RootCollisionNode, Bounding Box)
func _find_special_nodes(node: Defs.NiAVObject, result: CollisionResult) -> void:
	# Check for "Bounding Box" named node (actor collision)
	if node.name == "Bounding Box":
		if node.has_bounding_volume and node.bounding_volume != null:
			var bv := node.bounding_volume
			if bv.type == Defs.BV_BOX and bv.box != null:
				# Valid bounding box for actor collision
				result.has_actor_collision_box = true
				result.bounding_box_center = bv.box.center
				result.bounding_box_extents = bv.box.extents
				if debug_mode:
					print("NIFCollisionBuilder: Found actor bounding box at node '%s'" % node.name)
		return  # Don't recurse into Bounding Box node

	# Check for RootCollisionNode
	if node.record_type == Defs.RT_ROOT_COLLISION_NODE:
		result.root_collision_node_index = node.record_index
		if debug_mode:
			print("NIFCollisionBuilder: Found RootCollisionNode at index %d" % node.record_index)

	# Check for string extra data markers
	if node.extra_data_index >= 0:
		var extra := _reader.get_record(node.extra_data_index)
		if extra is Defs.NiStringExtraData:
			var str_data := extra as Defs.NiStringExtraData
			if str_data.string_data.begins_with("NC"):
				if str_data.string_data.length() > 2 and str_data.string_data[2] == "C":
					result.visual_collision_type = 1  # Camera only
				else:
					result.visual_collision_type = 0  # No collision

	# Recurse into children
	if node is Defs.NiNode:
		var ni_node := node as Defs.NiNode
		for child_idx in ni_node.children_indices:
			if child_idx >= 0:
				var child := _reader.get_record(child_idx)
				if child is Defs.NiAVObject:
					_find_special_nodes(child as Defs.NiAVObject, result)


## Process a node for collision generation
func _process_collision_node(node: Defs.NiAVObject, parent_transform: Transform3D, result: CollisionResult) -> void:
	# Skip hidden nodes
	if node.is_hidden():
		return

	# Skip nodes named "Bounding Box" (handled separately for actors)
	if node.name == "Bounding Box":
		return

	# Calculate world transform
	var local_transform := node.transform.to_transform3d()
	var world_transform := parent_transform * local_transform

	# Determine if we should generate collision for this node
	var is_collision_node := node.record_type == Defs.RT_ROOT_COLLISION_NODE
	var is_under_collision_node := result.root_collision_node_index >= 0
	var should_generate := false

	if is_collision_node:
		# Process children of RootCollisionNode
		should_generate = false  # RootCollisionNode itself has no collision, its children do
	elif is_under_collision_node:
		# Under RootCollisionNode - geometry becomes collision
		should_generate = true
	elif result.root_collision_node_index < 0:
		# No RootCollisionNode - use rendered geometry with flags
		should_generate = node.has_mesh_collision() or node.has_bbox_collision()

	# Generate collision from bounding volume primitives
	if node.has_bounding_volume and node.bounding_volume != null:
		var shape_data := _create_shape_from_bounding_volume(node.bounding_volume, world_transform)
		if not shape_data.is_empty():
			result.collision_shapes.append(shape_data)

	# Generate collision from geometry
	if should_generate and node is Defs.NiGeometry:
		var geom := node as Defs.NiGeometry
		# Use trimesh for RootCollisionNode geometry if configured
		var use_mode := collision_mode
		if is_under_collision_node and force_trimesh_for_collision_nodes:
			use_mode = CollisionMode.TRIMESH
		var shape_data := _create_shape_from_geometry(geom, world_transform, use_mode, result)
		if not shape_data.is_empty():
			result.collision_shapes.append(shape_data)

	# Recurse into children
	if node is Defs.NiNode:
		var ni_node := node as Defs.NiNode
		for child_idx in ni_node.children_indices:
			if child_idx >= 0:
				var child := _reader.get_record(child_idx)
				if child is Defs.NiAVObject:
					# If this is RootCollisionNode, children generate collision
					if is_collision_node:
						_process_collision_geometry(child as Defs.NiAVObject, world_transform, result)
					else:
						_process_collision_node(child as Defs.NiAVObject, world_transform, result)


## Process geometry under RootCollisionNode
func _process_collision_geometry(node: Defs.NiAVObject, parent_transform: Transform3D, result: CollisionResult) -> void:
	if node.is_hidden():
		return

	var local_transform := node.transform.to_transform3d()
	var world_transform := parent_transform * local_transform

	# Generate collision from geometry
	if node is Defs.NiGeometry:
		var geom := node as Defs.NiGeometry
		# RootCollisionNode geometry uses trimesh by default (architecture)
		var use_mode := CollisionMode.TRIMESH if force_trimesh_for_collision_nodes else collision_mode
		var shape_data := _create_shape_from_geometry(geom, world_transform, use_mode, result)
		if not shape_data.is_empty():
			result.collision_shapes.append(shape_data)
			if debug_mode:
				print("NIFCollisionBuilder: Created collision from '%s' (type: %s)" % [node.name, shape_data.get("type", "unknown")])

	# Recurse into children
	if node is Defs.NiNode:
		var ni_node := node as Defs.NiNode
		for child_idx in ni_node.children_indices:
			if child_idx >= 0:
				var child := _reader.get_record(child_idx)
				if child is Defs.NiAVObject:
					_process_collision_geometry(child as Defs.NiAVObject, world_transform, result)


## Create a Godot collision shape from a BoundingVolume
func _create_shape_from_bounding_volume(bv: Defs.BoundingVolume, transform: Transform3D) -> Dictionary:
	match bv.type:
		Defs.BV_SPHERE:
			if bv.sphere != null:
				var shape := SphereShape3D.new()
				shape.radius = bv.sphere.radius
				var shape_transform := Transform3D.IDENTITY
				shape_transform.origin = _convert_nif_vector(bv.sphere.center)
				return {
					"shape": shape,
					"transform": transform * shape_transform,
					"type": "sphere"
				}

		Defs.BV_BOX:
			if bv.box != null:
				var shape := BoxShape3D.new()
				# Note: Godot BoxShape3D uses full size, NIF uses half-extents
				shape.size = _convert_nif_vector(bv.box.extents).abs() * 2.0
				var shape_transform := Transform3D.IDENTITY
				shape_transform.origin = _convert_nif_vector(bv.box.center)
				# Apply orientation axes
				shape_transform.basis = _convert_nif_basis(bv.box.axes)
				return {
					"shape": shape,
					"transform": transform * shape_transform,
					"type": "box"
				}

		Defs.BV_CAPSULE:
			if bv.capsule != null:
				var shape := CapsuleShape3D.new()
				shape.radius = bv.capsule.radius
				shape.height = bv.capsule.extent * 2.0 + bv.capsule.radius * 2.0
				var shape_transform := Transform3D.IDENTITY
				shape_transform.origin = _convert_nif_vector(bv.capsule.center)
				# Orient capsule along its axis
				var axis := _convert_nif_vector(bv.capsule.axis).normalized()
				if axis != Vector3.UP and axis.length() > 0.001:
					shape_transform.basis = _create_basis_from_axis(axis)
				return {
					"shape": shape,
					"transform": transform * shape_transform,
					"type": "capsule"
				}

		Defs.BV_UNION:
			# For union types, we should generate multiple shapes
			# For now, skip (handled by recursion in caller)
			pass

	return {}


## Create a Godot collision shape from NiGeometry with specified mode
func _create_shape_from_geometry(geom: Defs.NiGeometry, transform: Transform3D, mode: CollisionMode, result: CollisionResult) -> Dictionary:
	if geom.data_index < 0:
		return {}

	var data := _reader.get_record(geom.data_index)
	if data == null:
		return {}

	var vertices: PackedVector3Array
	var triangles: PackedInt32Array

	if data is Defs.NiTriShapeData:
		var tri_data := data as Defs.NiTriShapeData
		vertices = tri_data.vertices
		triangles = tri_data.triangles
	elif data is Defs.NiTriStripsData:
		var strip_data := data as Defs.NiTriStripsData
		vertices = strip_data.vertices
		triangles = _convert_strips_to_triangles(strip_data.strips)
	else:
		return {}

	if vertices.is_empty():
		return {}

	# Convert vertices to Godot coordinates
	var converted_vertices := PackedVector3Array()
	converted_vertices.resize(vertices.size())
	for i in range(vertices.size()):
		converted_vertices[i] = _convert_nif_vector(vertices[i])

	# Calculate bounds for shape creation
	var bounds := _calculate_bounds(converted_vertices)

	# Priority 1: Check CollisionShapeLibrary for explicit shape mapping
	if not item_id.is_empty() and _shape_library != null and _shape_library.is_loaded():
		var library_shape = _shape_library.get_shape_for_item(item_id)
		if library_shape != null:
			var shape_type: int = library_shape
			result.detected_shapes.append("LIBRARY:" + ShapeLib.shape_type_name(shape_type))

			# If the library specifies a primitive shape, create it from bounds
			if not ShapeLib.requires_geometry(shape_type):
				var shape := ShapeLib.create_shape_from_type(shape_type, bounds)
				if shape != null:
					var shape_transform := Transform3D.IDENTITY
					shape_transform.origin = bounds.get_center()
					if debug_mode:
						print("NIFCollisionBuilder: Using library shape '%s' for '%s'" % [
							ShapeLib.shape_type_name(shape_type), item_id
						])
					return {
						"shape": shape,
						"transform": transform * shape_transform,
						"type": ShapeLib.shape_type_name(shape_type).to_lower(),
						"source": "library"
					}

			# Library says to use geometry-based shape (CONVEX, TRIMESH, AUTO)
			match shape_type:
				ShapeLib.ShapeType.CONVEX:
					return _create_convex_shape(converted_vertices, transform)
				ShapeLib.ShapeType.TRIMESH:
					return _create_trimesh_shape(converted_vertices, triangles, transform)
				# ShapeLib.ShapeType.AUTO falls through to normal auto-detection

	# Priority 2: Choose shape based on collision mode
	match mode:
		CollisionMode.TRIMESH:
			return _create_trimesh_shape(converted_vertices, triangles, transform)

		CollisionMode.CONVEX:
			return _create_convex_shape(converted_vertices, transform)

		CollisionMode.AUTO_PRIMITIVE:
			# Try to detect best primitive, fall back to convex
			var detected := _detect_best_shape(converted_vertices)
			result.detected_shapes.append(DetectedShape.keys()[detected])

			if detected != DetectedShape.UNKNOWN and detected != DetectedShape.CONVEX:
				var primitive := _create_primitive_shape(converted_vertices, detected, transform)
				if not primitive.is_empty():
					return primitive

			# Fall back to convex hull
			return _create_convex_shape(converted_vertices, transform)

		CollisionMode.PRIMITIVE_ONLY:
			# Only use primitives, skip if can't detect
			var detected := _detect_best_shape(converted_vertices)
			result.detected_shapes.append(DetectedShape.keys()[detected])

			if detected != DetectedShape.UNKNOWN and detected != DetectedShape.CONVEX:
				return _create_primitive_shape(converted_vertices, detected, transform)
			return {}

	return {}


## Analyze mesh vertices to detect best primitive shape
func _detect_best_shape(vertices: PackedVector3Array) -> DetectedShape:
	if vertices.size() < min_vertices_for_detection:
		return DetectedShape.CONVEX  # Too few vertices to analyze

	# Calculate bounds and center
	var bounds := _calculate_bounds(vertices)
	var center := bounds.get_center()
	var size := bounds.size

	# Normalize for comparison
	var max_dim := maxf(maxf(size.x, size.y), size.z)
	if max_dim < 0.001:
		return DetectedShape.UNKNOWN

	var norm_size := size / max_dim

	# Calculate average distance from center and variance
	var total_dist := 0.0
	var distances := PackedFloat32Array()
	distances.resize(vertices.size())

	for i in range(vertices.size()):
		var dist := (vertices[i] - center).length()
		distances[i] = dist
		total_dist += dist

	var avg_dist := total_dist / vertices.size()
	var variance := 0.0
	for d in distances:
		variance += (d - avg_dist) ** 2
	variance /= vertices.size()
	var std_dev := sqrt(variance)
	var dist_uniformity := 1.0 - (std_dev / avg_dist) if avg_dist > 0.001 else 0.0

	# Check for sphere (all points roughly equidistant from center)
	if dist_uniformity > (1.0 - detection_tolerance):
		if debug_mode:
			print("NIFCollisionBuilder: Detected SPHERE (uniformity=%.2f)" % dist_uniformity)
		return DetectedShape.SPHERE

	# Check aspect ratios for cylinder/capsule vs box
	var aspect_xy := minf(norm_size.x, norm_size.z) / maxf(norm_size.x, norm_size.z) if maxf(norm_size.x, norm_size.z) > 0.001 else 1.0
	var height_ratio := norm_size.y / ((norm_size.x + norm_size.z) / 2.0) if (norm_size.x + norm_size.z) > 0.001 else 1.0

	# Check for cylinder (circular in XZ plane, elongated in Y)
	if aspect_xy > (1.0 - detection_tolerance) and height_ratio > 1.2:
		# Verify circular cross-section
		var xz_uniformity := _check_circular_cross_section(vertices, center)
		if xz_uniformity > (1.0 - detection_tolerance):
			if debug_mode:
				print("NIFCollisionBuilder: Detected CYLINDER (aspect_xy=%.2f, height_ratio=%.2f, xz_uniform=%.2f)" % [aspect_xy, height_ratio, xz_uniformity])
			return DetectedShape.CYLINDER

	# Check for capsule (cylinder with rounded ends)
	if aspect_xy > (1.0 - detection_tolerance) and height_ratio > 1.5:
		# Could be capsule - similar to cylinder but check for rounded ends
		if debug_mode:
			print("NIFCollisionBuilder: Detected CAPSULE (aspect_xy=%.2f, height_ratio=%.2f)" % [aspect_xy, height_ratio])
		return DetectedShape.CAPSULE

	# Check for box (roughly equal extents or rectangular)
	var box_score := _calculate_box_score(vertices, bounds)
	if box_score > (1.0 - detection_tolerance):
		if debug_mode:
			print("NIFCollisionBuilder: Detected BOX (score=%.2f)" % box_score)
		return DetectedShape.BOX

	# Default to convex hull
	return DetectedShape.CONVEX


## Check how circular the XZ cross-section is
func _check_circular_cross_section(vertices: PackedVector3Array, center: Vector3) -> float:
	var total_xz_dist := 0.0
	var xz_distances := PackedFloat32Array()

	for v in vertices:
		var xz_dist := Vector2(v.x - center.x, v.z - center.z).length()
		xz_distances.append(xz_dist)
		total_xz_dist += xz_dist

	if xz_distances.size() == 0:
		return 0.0

	var avg_xz := total_xz_dist / xz_distances.size()
	if avg_xz < 0.001:
		return 0.0

	var variance := 0.0
	for d in xz_distances:
		variance += (d - avg_xz) ** 2
	variance /= xz_distances.size()

	var std_dev := sqrt(variance)
	return 1.0 - (std_dev / avg_xz)


## Calculate how well vertices fit a box shape
func _calculate_box_score(vertices: PackedVector3Array, bounds: AABB) -> float:
	# Check how many vertices are near the faces/edges/corners of the bounding box
	var near_surface_count := 0
	var tolerance := bounds.size.length() * detection_tolerance

	for v in vertices:
		var local := v - bounds.position
		var near_min_x := local.x < tolerance
		var near_max_x := local.x > bounds.size.x - tolerance
		var near_min_y := local.y < tolerance
		var near_max_y := local.y > bounds.size.y - tolerance
		var near_min_z := local.z < tolerance
		var near_max_z := local.z > bounds.size.z - tolerance

		# Count if near any face
		if near_min_x or near_max_x or near_min_y or near_max_y or near_min_z or near_max_z:
			near_surface_count += 1

	return float(near_surface_count) / float(vertices.size())


## Calculate AABB bounds of vertices
func _calculate_bounds(vertices: PackedVector3Array) -> AABB:
	if vertices.is_empty():
		return AABB()

	var min_v := vertices[0]
	var max_v := vertices[0]

	for v in vertices:
		min_v.x = minf(min_v.x, v.x)
		min_v.y = minf(min_v.y, v.y)
		min_v.z = minf(min_v.z, v.z)
		max_v.x = maxf(max_v.x, v.x)
		max_v.y = maxf(max_v.y, v.y)
		max_v.z = maxf(max_v.z, v.z)

	return AABB(min_v, max_v - min_v)


## Create a primitive shape based on detected type
func _create_primitive_shape(vertices: PackedVector3Array, detected: DetectedShape, transform: Transform3D) -> Dictionary:
	var bounds := _calculate_bounds(vertices)
	var center := bounds.get_center()
	var size := bounds.size

	match detected:
		DetectedShape.SPHERE:
			var shape := SphereShape3D.new()
			# Use average distance from center as radius
			var total_dist := 0.0
			for v in vertices:
				total_dist += (v - center).length()
			shape.radius = total_dist / vertices.size()
			var shape_transform := Transform3D.IDENTITY
			shape_transform.origin = center
			return {
				"shape": shape,
				"transform": transform * shape_transform,
				"type": "sphere"
			}

		DetectedShape.CYLINDER:
			var shape := CylinderShape3D.new()
			# Height is Y extent, radius is average of X/Z extents
			shape.height = size.y
			shape.radius = (size.x + size.z) / 4.0  # Half of average diameter
			var shape_transform := Transform3D.IDENTITY
			shape_transform.origin = center
			return {
				"shape": shape,
				"transform": transform * shape_transform,
				"type": "cylinder"
			}

		DetectedShape.BOX:
			var shape := BoxShape3D.new()
			shape.size = size
			var shape_transform := Transform3D.IDENTITY
			shape_transform.origin = center
			return {
				"shape": shape,
				"transform": transform * shape_transform,
				"type": "box"
			}

		DetectedShape.CAPSULE:
			var shape := CapsuleShape3D.new()
			# Height is Y extent, radius is average of X/Z extents
			shape.radius = (size.x + size.z) / 4.0
			shape.height = size.y
			var shape_transform := Transform3D.IDENTITY
			shape_transform.origin = center
			return {
				"shape": shape,
				"transform": transform * shape_transform,
				"type": "capsule"
			}

	return {}


## Create convex hull shape from vertices
func _create_convex_shape(vertices: PackedVector3Array, transform: Transform3D) -> Dictionary:
	if vertices.is_empty():
		return {}

	var shape := ConvexPolygonShape3D.new()
	shape.points = vertices
	# Godot auto-computes the convex hull from the points

	return {
		"shape": shape,
		"transform": transform,
		"type": "convex",
		"num_points": vertices.size()
	}


## Create trimesh (concave polygon) shape from vertices and triangles
func _create_trimesh_shape(vertices: PackedVector3Array, triangles: PackedInt32Array, transform: Transform3D) -> Dictionary:
	if triangles.is_empty():
		return {}

	# Build faces array: 3 vertices per triangle
	var faces := PackedVector3Array()
	faces.resize(triangles.size())
	for i in range(0, triangles.size(), 3):
		var i0 := triangles[i]
		var i1 := triangles[i + 1]
		var i2 := triangles[i + 2]
		if i0 < vertices.size() and i1 < vertices.size() and i2 < vertices.size():
			faces[i] = vertices[i0]
			faces[i + 1] = vertices[i1]
			faces[i + 2] = vertices[i2]

	if faces.is_empty():
		return {}

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)

	return {
		"shape": shape,
		"transform": transform,
		"type": "trimesh",
		"num_triangles": triangles.size() / 3
	}


## Convert triangle strips to triangle list
func _convert_strips_to_triangles(strips: Array) -> PackedInt32Array:
	var triangles := PackedInt32Array()

	for strip in strips:
		if strip.size() < 3:
			continue

		for i in range(2, strip.size()):
			var a: int = strip[i - 2]
			var b: int = strip[i - 1]
			var c: int = strip[i]

			# Skip degenerate triangles
			if a == b or b == c or a == c:
				continue

			# Flip winding for odd triangles
			if i % 2 == 0:
				triangles.append(a)
				triangles.append(b)
				triangles.append(c)
			else:
				triangles.append(a)
				triangles.append(c)
				triangles.append(b)

	return triangles


## Convert a NIF vector (Z-up) to Godot vector (Y-up)
## Delegates to unified CoordinateSystem - outputs in meters
func _convert_nif_vector(v: Vector3) -> Vector3:
	return CS.vector_to_godot(v)  # Converts to meters


## Convert a NIF basis/rotation to Godot
## Delegates to unified CoordinateSystem
func _convert_nif_basis(b: Basis) -> Basis:
	return CS.basis_to_godot(b)


## Create a basis that orients Y axis along the given direction
func _create_basis_from_axis(axis: Vector3) -> Basis:
	if axis.is_equal_approx(Vector3.UP):
		return Basis.IDENTITY
	if axis.is_equal_approx(Vector3.DOWN):
		return Basis(Vector3.RIGHT, Vector3.DOWN, Vector3.FORWARD)

	# Find a perpendicular vector
	var perp := Vector3.UP.cross(axis).normalized()
	if perp.length() < 0.001:
		perp = Vector3.RIGHT.cross(axis).normalized()

	var perp2 := axis.cross(perp).normalized()
	return Basis(perp, axis, perp2)


## Create a StaticBody3D with collision shapes
## Convenience method for direct use
func create_static_body(collision_result: CollisionResult) -> StaticBody3D:
	if not collision_result.has_collision:
		return null

	var body := StaticBody3D.new()
	body.name = "CollisionBody"

	for shape_data in collision_result.collision_shapes:
		var coll_shape := CollisionShape3D.new()
		coll_shape.shape = shape_data["shape"]
		coll_shape.transform = shape_data["transform"]
		if shape_data.has("type"):
			coll_shape.name = "Shape_%s" % shape_data["type"]
		body.add_child(coll_shape)

	return body


## Create collision for actor (CharacterBody3D-compatible)
## Returns a CollisionShape3D configured as a box or capsule
func create_actor_collision(collision_result: CollisionResult) -> CollisionShape3D:
	if not collision_result.has_actor_collision_box:
		return null

	var extents := _convert_nif_vector(collision_result.bounding_box_extents).abs()

	# Use capsule if the box is taller than it is wide (typical humanoid)
	var width := maxf(extents.x, extents.z) * 2.0
	var height := extents.y * 2.0

	var shape: Shape3D
	if height > width * 1.5:
		# Use capsule for humanoids
		var capsule := CapsuleShape3D.new()
		capsule.radius = width / 2.0
		capsule.height = height
		shape = capsule
	else:
		# Use box for squat creatures
		var box := BoxShape3D.new()
		box.size = extents * 2.0
		shape = box

	var coll_shape := CollisionShape3D.new()
	coll_shape.shape = shape
	coll_shape.name = "ActorCollision"
	coll_shape.position = _convert_nif_vector(collision_result.bounding_box_center)

	return coll_shape


## Get recommended collision mode based on NIF path/type
## Can be used to set collision_mode before calling build_collision()
static func get_recommended_mode(nif_path: String) -> CollisionMode:
	var lower_path := nif_path.to_lower()

	# Architecture - use trimesh for exact collision
	if "\\x\\" in lower_path or "/x/" in lower_path:  # exterior architecture
		return CollisionMode.TRIMESH
	if "\\i\\" in lower_path or "/i/" in lower_path:  # interior architecture
		return CollisionMode.TRIMESH

	# Furniture - often needs exact collision
	if "\\f\\" in lower_path or "/f/" in lower_path:
		return CollisionMode.CONVEX

	# Weapons, armor, misc items - use auto-primitive
	if "\\m\\" in lower_path or "/m/" in lower_path:
		return CollisionMode.AUTO_PRIMITIVE
	if "\\w\\" in lower_path or "/w/" in lower_path:
		return CollisionMode.AUTO_PRIMITIVE
	if "\\a\\" in lower_path or "/a/" in lower_path:
		return CollisionMode.AUTO_PRIMITIVE

	# Creatures - use convex or primitive
	if "\\c\\" in lower_path or "/c/" in lower_path:
		return CollisionMode.CONVEX

	# Default to auto-primitive
	return CollisionMode.AUTO_PRIMITIVE
