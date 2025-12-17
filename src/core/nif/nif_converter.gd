## NIF Converter - Converts NIF models to Godot scenes/meshes
## Creates Node3D hierarchy with MeshInstance3D nodes
## Supports skinned meshes with Skeleton3D, animations, and collision shapes
class_name NIFConverter
extends RefCounted

# Preload dependencies
const Defs := preload("res://src/core/nif/nif_defs.gd")
const Reader := preload("res://src/core/nif/nif_reader.gd")
const TexLoader := preload("res://src/core/texture/texture_loader.gd")
const MatLib := preload("res://src/core/texture/material_library.gd")
const SkeletonBuilder := preload("res://src/core/nif/nif_skeleton_builder.gd")
const AnimationConverter := preload("res://src/core/nif/nif_animation_converter.gd")
const CollisionBuilder := preload("res://src/core/nif/nif_collision_builder.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const MeshSimplifier := preload("res://src/core/nif/mesh_simplifier.gd")

# The NIFReader instance
var _reader: Reader = null

# Skeleton builder for skinned meshes
var _skeleton_builder: SkeletonBuilder = null

# Animation converter for keyframe data
var _animation_converter: AnimationConverter = null

# Collision builder for physics shapes
var _collision_builder: CollisionBuilder = null

# Whether to load textures during conversion
var load_textures: bool = true

# Whether to extract animations during conversion
# DISABLED by default: Most world objects are statics. Enable for NPCs/creatures.
var load_animations: bool = false

# Whether to generate collision shapes during conversion
var load_collision: bool = true

## Whether to use global material library for deduplication
## When true, materials with the same properties share a single instance
## This reduces VRAM usage and improves batching
var use_material_library: bool = true

## Collision mode for geometry-based collision
## See CollisionBuilder.CollisionMode for options:
## - TRIMESH: Full triangle mesh (accurate but slow) - best for architecture
## - CONVEX: Convex hull (fast, good for most objects)
## - AUTO_PRIMITIVE: Auto-detect best primitive shape (sphere, cylinder, box, capsule)
## - PRIMITIVE_ONLY: Only use primitives, skip if can't detect (fastest)
var collision_mode: int = CollisionBuilder.CollisionMode.AUTO_PRIMITIVE

## Whether to auto-select collision mode based on NIF path
## When true, architecture uses TRIMESH, items use AUTO_PRIMITIVE, etc.
var auto_collision_mode: bool = true

## Tolerance for primitive shape detection (0.0 = strict, 1.0 = loose)
var collision_detection_tolerance: float = 0.15

# Debug mode for skeleton/skinning output
var debug_skinning: bool = false

# Debug mode for animation output
var debug_animations: bool = false

# Debug mode for collision output
var debug_collision: bool = false

## LOD Generation Settings
## When enabled, generates simplified LOD meshes during conversion
## DISABLED: Using Godot's native VisibilityRange for LOD instead
var generate_lods: bool = false

## Triangle ratio for LOD1 (0.5 = 50% of original triangles)
var lod1_ratio: float = 0.5

## Triangle ratio for LOD2 (0.25 = 25% of original triangles)
var lod2_ratio: float = 0.25

## Minimum triangles to generate LODs (skip simple meshes)
var min_triangles_for_lod: int = 100

## Debug mode for LOD generation
var debug_lod: bool = false

# Source path for auto collision mode detection
var _source_path: String = ""

## Item ID for collision shape library lookups (e.g., "misc_com_bottle_01")
## Set this before converting to enable YAML-based collision shape overrides
var collision_item_id: String = ""

# Cache for converted resources
var _mesh_cache: Dictionary = {}  # record_index -> ArrayMesh
var _material_cache: Dictionary = {}  # hash -> StandardMaterial3D

# Skeleton cache for this conversion (skin_instance_index -> Skeleton3D)
var _skeleton_cache: Dictionary = {}

## Convert a NIF file to a Godot Node3D scene
## Returns the root Node3D or null on failure
func convert_file(path: String) -> Node3D:
	_source_path = path
	_reader = Reader.new()
	var result := _reader.load_file(path)
	if result != OK:
		return null
	return _convert()


## Convert a NIF file with item ID for collision shape library lookup
## item_id: The ESM record ID (e.g., "misc_com_bottle_01") for YAML shape matching
## Returns the root Node3D or null on failure
func convert_file_with_item_id(path: String, item_id: String) -> Node3D:
	collision_item_id = item_id
	return convert_file(path)


## Convert a NIF buffer to a Godot Node3D scene
## path_hint is optional but helps auto-detect collision mode and error messages
func convert_buffer(data: PackedByteArray, path_hint: String = "") -> Node3D:
	_source_path = path_hint
	_reader = Reader.new()
	var result := _reader.load_buffer(data, path_hint)
	if result != OK:
		return null
	return _convert()


## Convert a NIF buffer with item ID for collision shape library lookup
## item_id: The ESM record ID (e.g., "misc_com_bottle_01") for YAML shape matching
## Returns the root Node3D or null on failure
func convert_buffer_with_item_id(data: PackedByteArray, item_id: String, path_hint: String = "") -> Node3D:
	collision_item_id = item_id
	return convert_buffer(data, path_hint)


# =============================================================================
# ASYNC CONVERSION API
# =============================================================================
# These methods separate parsing from instantiation for background thread use.
# parse_buffer_only() is THREAD-SAFE and can run on WorkerThreadPool.
# convert_from_parsed() MUST run on main thread (creates scene tree nodes).
# =============================================================================

const NIFParseResult := preload("res://src/core/nif/nif_parse_result.gd")

## Parse a NIF buffer without creating scene nodes (THREAD-SAFE)
## This can be called from a worker thread via BackgroundProcessor.
## Returns NIFParseResult containing the parsed reader, or error info.
##
## Example usage with BackgroundProcessor:
##   var task_id = background_processor.submit_task(func():
##       var converter = NIFConverter.new()
##       return converter.parse_buffer_only(data, path, item_id)
##   )
static func parse_buffer_only(data: PackedByteArray, path_hint: String = "", item_id: String = "") -> NIFParseResult:
	if data.is_empty():
		return NIFParseResult.create_failure(path_hint, "Empty buffer")

	var reader := Reader.new()
	var parse_result := reader.load_buffer(data, path_hint)

	if parse_result != OK:
		return NIFParseResult.create_failure(path_hint, "Parse failed with error %d" % parse_result)

	if reader.roots.is_empty():
		return NIFParseResult.create_failure(path_hint, "No root nodes in NIF")

	var result := NIFParseResult.create_success(reader, path_hint)
	result.item_id = item_id
	result.buffer_hash = data.size()  # Simple hash for now
	return result


## Convert a pre-parsed NIF to a Godot Node3D scene (MAIN THREAD ONLY)
## parse_result: The result from parse_buffer_only()
## Returns the root Node3D or null on failure
func convert_from_parsed(parse_result: NIFParseResult) -> Node3D:
	if not parse_result.is_valid():
		push_error("NIFConverter: Invalid parse result for %s: %s" % [parse_result.path, parse_result.error])
		return null

	# Transfer parsed data to this converter instance
	_reader = parse_result.reader as Reader
	_source_path = parse_result.path
	collision_item_id = parse_result.item_id

	# Apply configuration from parse result if set
	if parse_result.load_textures != load_textures:
		load_textures = parse_result.load_textures
	if parse_result.load_animations != load_animations:
		load_animations = parse_result.load_animations
	if parse_result.load_collision != load_collision:
		load_collision = parse_result.load_collision

	return _convert()


## Internal conversion after parsing
func _convert() -> Node3D:
	_mesh_cache.clear()
	_material_cache.clear()
	_skeleton_cache.clear()

	# Initialize skeleton builder
	_skeleton_builder = SkeletonBuilder.new()
	_skeleton_builder.init(_reader)
	_skeleton_builder.debug_mode = debug_skinning

	# Initialize collision builder
	_collision_builder = CollisionBuilder.new()
	_collision_builder.init(_reader)
	_collision_builder.debug_mode = debug_collision
	_collision_builder.detection_tolerance = collision_detection_tolerance
	_collision_builder.item_id = collision_item_id  # For YAML-based shape lookups

	# Set collision mode - auto-detect from path or use configured mode
	if auto_collision_mode and not _source_path.is_empty():
		_collision_builder.collision_mode = CollisionBuilder.get_recommended_mode(_source_path)
		if debug_collision:
			print("NIFConverter: Auto-selected collision mode %d for %s" % [
				_collision_builder.collision_mode, _source_path.get_file()
			])
	else:
		_collision_builder.collision_mode = collision_mode

	if _reader.roots.is_empty():
		push_error("NIFConverter: No root nodes")
		return null

	# Check if this NIF has skinning - if so, we need to create skeleton first
	var has_skinning := _has_skinning_data()

	# Create root node
	# All transforms, vertices, and normals are converted from NIF coordinates
	# (Z-up, Y-forward) to Godot coordinates (Y-up, Z-back) during conversion.
	var root := Node3D.new()
	root.name = "NIFRoot"

	# If we have skinning, create the skeleton and add it to root first
	var skeleton: Skeleton3D = null
	if has_skinning:
		skeleton = _create_skeleton_for_nif()
		if skeleton:
			root.add_child(skeleton)
			if debug_skinning:
				print("NIFConverter: Created skeleton with %d bones" % skeleton.get_bone_count())

	# Convert each root
	for root_idx in _reader.roots:
		var record := _reader.get_record(root_idx)
		if record == null:
			continue

		var node := _convert_record(record, skeleton)
		if node:
			# If we have a skeleton, skinned meshes should be children of it
			if skeleton and _is_skinned_subtree(record):
				skeleton.add_child(node)
			else:
				root.add_child(node)

	# Post-process: Link skinned meshes to skeleton
	if skeleton:
		_link_skinned_meshes_to_skeleton(root, skeleton)

	# Extract and add animations if enabled
	if load_animations and _has_animation_data():
		var anim_player := _create_animation_player(skeleton)
		if anim_player:
			root.add_child(anim_player)
			if debug_animations:
				print("NIFConverter: Created AnimationPlayer with %d animations" % anim_player.get_animation_library("").get_animation_list().size())

	# Build and add collision shapes if enabled
	if load_collision:
		var collision_result := _collision_builder.build_collision()
		if collision_result.has_collision:
			var static_body := _collision_builder.create_static_body(collision_result)
			if static_body:
				root.add_child(static_body)
				if debug_collision:
					print("NIFConverter: Created StaticBody3D with %d collision shapes" % collision_result.collision_shapes.size())

			# Store actor collision info as metadata for later use
			if collision_result.has_actor_collision_box:
				root.set_meta("actor_collision_center", collision_result.bounding_box_center)
				root.set_meta("actor_collision_extents", collision_result.bounding_box_extents)

	return root


## Recursively find skinned meshes and link them to the skeleton
func _link_skinned_meshes_to_skeleton(node: Node, skeleton: Skeleton3D) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.has_meta("_has_skeleton"):
			# Set the skeleton path - need to compute relative path from mesh to skeleton
			mesh_instance.skeleton = mesh_instance.get_path_to(skeleton)
			mesh_instance.remove_meta("_has_skeleton")

			if debug_skinning:
				print("NIFConverter: Linked '%s' to skeleton (path=%s)" % [
					mesh_instance.name, mesh_instance.skeleton
				])

	# Recurse into children
	for child in node.get_children():
		_link_skinned_meshes_to_skeleton(child, skeleton)


## Check if this NIF has any skinning data
func _has_skinning_data() -> bool:
	for record in _reader.records:
		if record is Defs.NiSkinInstance:
			return true
	return false


## Check if a record or its children contain skinned geometry
func _is_skinned_subtree(record: Defs.NIFRecord) -> bool:
	if record is Defs.NiGeometry:
		var geom := record as Defs.NiGeometry
		return geom.skin_index >= 0

	if record is Defs.NiNode:
		var node := record as Defs.NiNode
		for child_idx in node.children_indices:
			if child_idx < 0:
				continue
			var child := _reader.get_record(child_idx)
			if child and _is_skinned_subtree(child):
				return true

	return false


## Create the skeleton for this NIF (finds first skin instance)
func _create_skeleton_for_nif() -> Skeleton3D:
	# Find the first NiSkinInstance
	for record in _reader.records:
		if record is Defs.NiSkinInstance:
			var skin_instance := record as Defs.NiSkinInstance
			var skeleton := _skeleton_builder.build_skeleton(skin_instance)
			if skeleton:
				_skeleton_cache[record.record_index] = skeleton
				return skeleton

	return null


## Convert a record to a Godot node
func _convert_record(record: Defs.NIFRecord, skeleton: Skeleton3D = null) -> Node3D:
	if record == null:
		return null

	# Node types (order matters - check derived types before base types)
	if record is Defs.NiLODNode:
		return _convert_ni_lod_node(record as Defs.NiLODNode, skeleton)
	elif record is Defs.NiSwitchNode:
		return _convert_ni_switch_node(record as Defs.NiSwitchNode, skeleton)
	elif record is Defs.NiNode:
		return _convert_ni_node(record as Defs.NiNode, skeleton)
	# Geometry types
	elif record is Defs.NiTriShape:
		return _convert_ni_tri_shape(record as Defs.NiTriShape, skeleton)
	elif record is Defs.NiTriStrips:
		return _convert_ni_tri_strips(record as Defs.NiTriStrips, skeleton)
	# Particle types
	elif record is Defs.NiParticles:
		return _convert_ni_particles(record as Defs.NiParticles)
	# Light types (order matters - check derived types before base types)
	elif record is Defs.NiSpotLight:
		return _convert_ni_spot_light(record as Defs.NiSpotLight)
	elif record is Defs.NiPointLight:
		return _convert_ni_point_light(record as Defs.NiPointLight)
	elif record is Defs.NiLight:
		return _convert_ni_light(record as Defs.NiLight)
	else:
		return null

## Convert a Transform3D from NIF coordinates to Godot coordinates
## Delegates to unified CoordinateSystem - outputs in meters
static func _convert_nif_transform(transform: Transform3D) -> Transform3D:
	return CS.transform_to_godot(transform)  # Converts to meters


## Convert NiNode to Node3D
func _convert_ni_node(ni_node: Defs.NiNode, skeleton: Skeleton3D = null) -> Node3D:
	var node := Node3D.new()
	node.name = ni_node.name if ni_node.name else "Node_%d" % ni_node.record_index

	# Apply transform - convert from NIF to Godot coordinates
	node.transform = _convert_nif_transform(ni_node.transform.to_transform3d())

	# Hide if flagged
	if ni_node.is_hidden():
		node.visible = false

	# Handle NiBillboardNode - mark with billboard metadata
	if ni_node.record_type == Defs.RT_NI_BILLBOARD_NODE:
		node.set_meta("nif_billboard", true)
		node.set_meta("nif_record_type", ni_node.record_type)

	# Convert children
	for child_idx in ni_node.children_indices:
		if child_idx < 0:
			continue
		var child_record := _reader.get_record(child_idx)
		var child_node := _convert_record(child_record, skeleton)
		if child_node:
			node.add_child(child_node)

	return node

## Convert NiTriShape to MeshInstance3D
func _convert_ni_tri_shape(shape: Defs.NiTriShape, skeleton: Skeleton3D = null) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = shape.name if shape.name else "Mesh_%d" % shape.record_index

	# Apply transform - convert from NIF to Godot coordinates
	# (for skinned meshes, this is typically identity)
	mesh_instance.transform = _convert_nif_transform(shape.transform.to_transform3d())

	# Hide if flagged
	if shape.is_hidden():
		mesh_instance.visible = false

	# Get geometry data
	if shape.data_index < 0:
		return mesh_instance

	var data_record := _reader.get_record(shape.data_index)
	if data_record == null or not (data_record is Defs.NiTriShapeData):
		return mesh_instance

	var data := data_record as Defs.NiTriShapeData

	# Check if this is a skinned mesh
	var is_skinned := shape.skin_index >= 0 and skeleton != null
	var skin_instance: Defs.NiSkinInstance = null
	var skin_data: Defs.NiSkinData = null

	if is_skinned:
		skin_instance = _reader.get_record(shape.skin_index) as Defs.NiSkinInstance
		if skin_instance and skin_instance.data_index >= 0:
			skin_data = _reader.get_record(skin_instance.data_index) as Defs.NiSkinData

		if debug_skinning:
			print("NIFConverter: Converting skinned mesh '%s'" % mesh_instance.name)

	# Create mesh (with or without skinning data)
	var mesh: ArrayMesh
	if is_skinned and skin_instance and skin_data:
		mesh = _create_skinned_tri_shape_mesh(data, skin_instance, skin_data)
	else:
		mesh = _create_tri_shape_mesh(data)

	if mesh:
		mesh_instance.mesh = mesh

		# Generate LOD meshes for non-skinned meshes
		if not is_skinned:
			var lod_meshes := _generate_lod_meshes(mesh)
			if not lod_meshes.is_empty():
				mesh_instance.set_meta("lod_meshes", lod_meshes)

		# Apply material from properties
		var material := _get_material_for_shape(shape)
		if material:
			mesh_instance.material_override = material

		# Link to skeleton for skinned meshes
		if is_skinned and skeleton:
			# The skeleton path is relative from the mesh to the skeleton
			# Since both are children of NIFRoot (or skeleton contains mesh),
			# we need to set this after the scene tree is built
			mesh_instance.set_meta("_has_skeleton", true)

	return mesh_instance

## Convert NiTriStrips to MeshInstance3D
func _convert_ni_tri_strips(strips: Defs.NiTriStrips, skeleton: Skeleton3D = null) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = strips.name if strips.name else "Mesh_%d" % strips.record_index

	# Apply transform - convert from NIF to Godot coordinates
	mesh_instance.transform = _convert_nif_transform(strips.transform.to_transform3d())

	# Hide if flagged
	if strips.is_hidden():
		mesh_instance.visible = false

	# Get geometry data
	if strips.data_index < 0:
		return mesh_instance

	var data_record := _reader.get_record(strips.data_index)
	if data_record == null or not (data_record is Defs.NiTriStripsData):
		return mesh_instance

	var data := data_record as Defs.NiTriStripsData

	# Check if this is a skinned mesh
	var is_skinned := strips.skin_index >= 0 and skeleton != null
	var skin_instance: Defs.NiSkinInstance = null
	var skin_data: Defs.NiSkinData = null

	if is_skinned:
		skin_instance = _reader.get_record(strips.skin_index) as Defs.NiSkinInstance
		if skin_instance and skin_instance.data_index >= 0:
			skin_data = _reader.get_record(skin_instance.data_index) as Defs.NiSkinData

		if debug_skinning:
			print("NIFConverter: Converting skinned strip mesh '%s'" % mesh_instance.name)

	# Create mesh (with or without skinning data)
	var mesh: ArrayMesh
	if is_skinned and skin_instance and skin_data:
		mesh = _create_skinned_tri_strips_mesh(data, skin_instance, skin_data)
	else:
		mesh = _create_tri_strips_mesh(data)

	if mesh:
		mesh_instance.mesh = mesh

		# Generate LOD meshes for non-skinned meshes
		if not is_skinned:
			var lod_meshes := _generate_lod_meshes(mesh)
			if not lod_meshes.is_empty():
				mesh_instance.set_meta("lod_meshes", lod_meshes)

		# Apply material from properties
		var material := _get_material_for_shape(strips)
		if material:
			mesh_instance.material_override = material

		# Link to skeleton for skinned meshes
		if is_skinned and skeleton:
			mesh_instance.set_meta("_has_skeleton", true)

	return mesh_instance

## Convert a Vector3 from NIF coordinates (Z-up) to Godot coordinates (Y-up)
## Delegates to unified CoordinateSystem - outputs in meters
static func _convert_nif_vector3(v: Vector3) -> Vector3:
	return CS.vector_to_godot(v)  # Converts to meters


## Convert a PackedVector3Array from NIF to Godot coordinates
## Delegates to unified CoordinateSystem - outputs in meters
static func _convert_nif_vertices(vertices: PackedVector3Array) -> PackedVector3Array:
	return CS.vectors_to_godot(vertices)  # Converts to meters


## Generate LOD meshes for a given mesh
## Returns dictionary with "lod1" and "lod2" keys, or empty if LOD generation skipped
func _generate_lod_meshes(mesh: ArrayMesh) -> Dictionary:
	if not generate_lods or mesh == null:
		return {}

	if mesh.get_surface_count() == 0:
		return {}

	var arrays := mesh.surface_get_arrays(0)
	if arrays.is_empty():
		return {}

	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if indices == null or indices.is_empty():
		return {}

	var num_triangles: int = indices.size() / 3
	if num_triangles < min_triangles_for_lod:
		if debug_lod:
			print("NIFConverter: Skipping LOD for mesh with %d triangles (min: %d)" % [num_triangles, min_triangles_for_lod])
		return {}

	var simplifier := MeshSimplifier.new()
	var result := {}

	# Generate LOD1
	var lod1_arrays := simplifier.simplify(arrays, lod1_ratio)
	if not lod1_arrays.is_empty() and lod1_arrays[Mesh.ARRAY_VERTEX] != null:
		var lod1_mesh := ArrayMesh.new()
		lod1_mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)
		lod1_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, lod1_arrays)
		result["lod1"] = lod1_mesh

		if debug_lod:
			var lod1_indices: PackedInt32Array = lod1_arrays[Mesh.ARRAY_INDEX]
			var lod1_tris: int = lod1_indices.size() / 3 if lod1_indices else 0
			print("NIFConverter: LOD1 %d -> %d triangles (%.1f%%)" % [num_triangles, lod1_tris, 100.0 * lod1_tris / num_triangles])

	# Generate LOD2
	var lod2_arrays := simplifier.simplify(arrays, lod2_ratio)
	if not lod2_arrays.is_empty() and lod2_arrays[Mesh.ARRAY_VERTEX] != null:
		var lod2_mesh := ArrayMesh.new()
		lod2_mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)
		lod2_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, lod2_arrays)
		result["lod2"] = lod2_mesh

		if debug_lod:
			var lod2_indices: PackedInt32Array = lod2_arrays[Mesh.ARRAY_INDEX]
			var lod2_tris: int = lod2_indices.size() / 3 if lod2_indices else 0
			print("NIFConverter: LOD2 %d -> %d triangles (%.1f%%)" % [num_triangles, lod2_tris, 100.0 * lod2_tris / num_triangles])

	return result


## Create ArrayMesh from NiTriShapeData
func _create_tri_shape_mesh(data: Defs.NiTriShapeData) -> ArrayMesh:
	if data.vertices.is_empty() or data.triangles.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	# Vertices - convert from NIF to Godot coordinates
	arrays[Mesh.ARRAY_VERTEX] = _convert_nif_vertices(data.vertices)

	# Normals - convert from NIF to Godot coordinates
	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = _convert_nif_vertices(data.normals)

	# UVs (use first UV set)
	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = data.uv_sets[0]

	# Vertex colors
	if not data.colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = data.colors

	# Indices - flip winding order (NIF uses opposite winding to Godot)
	var flipped_triangles := PackedInt32Array()
	flipped_triangles.resize(data.triangles.size())
	for i in range(0, data.triangles.size(), 3):
		flipped_triangles[i] = data.triangles[i]
		flipped_triangles[i + 1] = data.triangles[i + 2]
		flipped_triangles[i + 2] = data.triangles[i + 1]
	arrays[Mesh.ARRAY_INDEX] = flipped_triangles

	# Create mesh with explicit blend shape count of 0 to avoid AABB errors on duplicate
	var mesh := ArrayMesh.new()
	mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh

## Create ArrayMesh from NiTriStripsData
func _create_tri_strips_mesh(data: Defs.NiTriStripsData) -> ArrayMesh:
	if data.vertices.is_empty() or data.strips.is_empty():
		return null

	# Convert triangle strips to triangle list with flipped winding order
	var triangles := PackedInt32Array()
	for strip in data.strips:
		if strip.size() < 3:
			continue
		# Convert strip to triangles (with flipped winding for Godot)
		for i in range(strip.size() - 2):
			if i % 2 == 0:
				# Even triangles: flip winding (swap indices 1 and 2)
				triangles.append(strip[i])
				triangles.append(strip[i + 2])
				triangles.append(strip[i + 1])
			else:
				# Odd triangles: original strip alternation + flip = normal order
				triangles.append(strip[i])
				triangles.append(strip[i + 1])
				triangles.append(strip[i + 2])

	if triangles.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	# Convert vertices and normals from NIF to Godot coordinates
	arrays[Mesh.ARRAY_VERTEX] = _convert_nif_vertices(data.vertices)

	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = _convert_nif_vertices(data.normals)

	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = data.uv_sets[0]

	if not data.colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = data.colors

	arrays[Mesh.ARRAY_INDEX] = triangles

	# Create mesh with explicit blend shape count of 0 to avoid AABB errors on duplicate
	var mesh := ArrayMesh.new()
	mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh


## Create skinned ArrayMesh from NiTriShapeData with bone weights
func _create_skinned_tri_shape_mesh(data: Defs.NiTriShapeData, skin_instance: Defs.NiSkinInstance, skin_data: Defs.NiSkinData) -> ArrayMesh:
	if data.vertices.is_empty() or data.triangles.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	# Vertices - convert from NIF to Godot coordinates
	arrays[Mesh.ARRAY_VERTEX] = _convert_nif_vertices(data.vertices)

	# Normals - convert from NIF to Godot coordinates
	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = _convert_nif_vertices(data.normals)

	# UVs (use first UV set)
	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = data.uv_sets[0]

	# Vertex colors
	if not data.colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = data.colors

	# Indices - flip winding order (NIF uses opposite winding to Godot)
	var flipped_triangles := PackedInt32Array()
	flipped_triangles.resize(data.triangles.size())
	for i in range(0, data.triangles.size(), 3):
		flipped_triangles[i] = data.triangles[i]
		flipped_triangles[i + 1] = data.triangles[i + 2]
		flipped_triangles[i + 2] = data.triangles[i + 1]
	arrays[Mesh.ARRAY_INDEX] = flipped_triangles

	# Build bone indices and weights
	var skin_arrays := _skeleton_builder.build_skin_arrays(data, skin_instance, skin_data)
	if not skin_arrays.is_empty():
		arrays[Mesh.ARRAY_BONES] = skin_arrays["indices"]
		arrays[Mesh.ARRAY_WEIGHTS] = skin_arrays["weights"]

		if debug_skinning:
			print("  Added bone weights: %d vertices, %d indices, %d weights" % [
				data.num_vertices,
				skin_arrays["indices"].size(),
				skin_arrays["weights"].size()
			])

	# Create mesh with explicit blend shape count of 0 to avoid AABB errors on duplicate
	var mesh := ArrayMesh.new()
	mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh


## Create skinned ArrayMesh from NiTriStripsData with bone weights
func _create_skinned_tri_strips_mesh(data: Defs.NiTriStripsData, skin_instance: Defs.NiSkinInstance, skin_data: Defs.NiSkinData) -> ArrayMesh:
	if data.vertices.is_empty() or data.strips.is_empty():
		return null

	# Convert triangle strips to triangle list with flipped winding order
	var triangles := PackedInt32Array()
	for strip in data.strips:
		if strip.size() < 3:
			continue
		# Convert strip to triangles (with flipped winding for Godot)
		for i in range(strip.size() - 2):
			if i % 2 == 0:
				# Even triangles: flip winding (swap indices 1 and 2)
				triangles.append(strip[i])
				triangles.append(strip[i + 2])
				triangles.append(strip[i + 1])
			else:
				# Odd triangles: original strip alternation + flip = normal order
				triangles.append(strip[i])
				triangles.append(strip[i + 1])
				triangles.append(strip[i + 2])

	if triangles.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	# Convert vertices and normals from NIF to Godot coordinates
	arrays[Mesh.ARRAY_VERTEX] = _convert_nif_vertices(data.vertices)

	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = _convert_nif_vertices(data.normals)

	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = data.uv_sets[0]

	if not data.colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = data.colors

	arrays[Mesh.ARRAY_INDEX] = triangles

	# Build bone indices and weights
	var skin_arrays := _skeleton_builder.build_skin_arrays(data, skin_instance, skin_data)
	if not skin_arrays.is_empty():
		arrays[Mesh.ARRAY_BONES] = skin_arrays["indices"]
		arrays[Mesh.ARRAY_WEIGHTS] = skin_arrays["weights"]

		if debug_skinning:
			print("  Added bone weights: %d vertices, %d indices, %d weights" % [
				data.num_vertices,
				skin_arrays["indices"].size(),
				skin_arrays["weights"].size()
			])

	# Create mesh with explicit blend shape count of 0 to avoid AABB errors on duplicate
	var mesh := ArrayMesh.new()
	mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh


## Get material for a geometry shape
func _get_material_for_shape(geom: Defs.NiGeometry) -> StandardMaterial3D:
	var mat_prop: Defs.NiMaterialProperty = null
	var tex_prop: Defs.NiTexturingProperty = null
	var alpha_prop: Defs.NiAlphaProperty = null
	var vc_prop: Defs.NiVertexColorProperty = null

	# Collect properties
	for prop_idx in geom.property_indices:
		if prop_idx < 0:
			continue
		var prop := _reader.get_record(prop_idx)
		if prop is Defs.NiMaterialProperty:
			mat_prop = prop
		elif prop is Defs.NiTexturingProperty:
			tex_prop = prop
		elif prop is Defs.NiAlphaProperty:
			alpha_prop = prop
		elif prop is Defs.NiVertexColorProperty:
			vc_prop = prop

	# Check if we have any properties
	if mat_prop == null and tex_prop == null:
		return null

	# Get texture path if available
	var texture_path := ""
	if tex_prop and not tex_prop.textures.is_empty():
		var base_tex := tex_prop.textures[0] if tex_prop.textures.size() > 0 else null
		if base_tex and base_tex.has_texture and base_tex.source_index >= 0:
			var tex_source := _reader.get_record(base_tex.source_index)
			if tex_source is Defs.NiSourceTexture:
				var source := tex_source as Defs.NiSourceTexture
				texture_path = source.filename

	# Use MaterialLibrary for deduplication if enabled
	if use_material_library and load_textures:
		var props := MatLib.MaterialProperties.new()

		# Texture
		props.texture_path = texture_path

		# Material properties
		if mat_prop:
			props.albedo_color = mat_prop.diffuse
			props.specular = mat_prop.glossiness / 128.0
			props.roughness = 1.0 - props.specular
			if mat_prop.emissive.r > 0.01 or mat_prop.emissive.g > 0.01 or mat_prop.emissive.b > 0.01:
				props.has_emission = true
				props.emission_color = mat_prop.emissive
				props.emission_energy = 1.0

		# Alpha properties
		if alpha_prop:
			if alpha_prop.test_enabled():
				props.transparency_mode = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				props.alpha_scissor_threshold = alpha_prop.threshold / 255.0
			elif alpha_prop.blend_enabled():
				props.transparency_mode = BaseMaterial3D.TRANSPARENCY_ALPHA

		# Vertex colors
		if vc_prop:
			props.use_vertex_colors = true

		return MatLib.get_or_create_material(props)

	# Fallback: Create new material (legacy behavior)
	var material := StandardMaterial3D.new()

	# Texture filtering - critical for visual quality at distance
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	# Apply material properties
	if mat_prop:
		material.albedo_color = mat_prop.diffuse
		material.emission = mat_prop.emissive
		material.emission_enabled = mat_prop.emissive.r > 0 or mat_prop.emissive.g > 0 or mat_prop.emissive.b > 0
		material.metallic_specular = mat_prop.glossiness / 128.0  # Normalize

	# Apply alpha property
	if alpha_prop:
		if alpha_prop.blend_enabled():
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		if alpha_prop.test_enabled():
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			material.alpha_scissor_threshold = alpha_prop.threshold / 255.0

	# Apply vertex colors
	if vc_prop:
		material.vertex_color_use_as_albedo = true

	# Texture loading
	if not texture_path.is_empty():
		if load_textures:
			var texture := TexLoader.load_texture(texture_path)
			if texture:
				material.albedo_texture = texture
		else:
			# Store texture path in metadata for later loading
			material.set_meta("texture_path", texture_path)

	return material

## Get texture paths referenced by this NIF
func get_texture_paths() -> Array[String]:
	var paths: Array[String] = []

	for record in _reader.records:
		if record is Defs.NiSourceTexture:
			var tex := record as Defs.NiSourceTexture
			if tex.is_external and not tex.filename.is_empty():
				# Normalize path
				var path := tex.filename.replace("\\", "/").to_lower()
				if path not in paths:
					paths.append(path)

	return paths

## Get basic mesh info without full conversion
func get_mesh_info() -> Dictionary:
	var info := {
		"version": _reader.get_version_string(),
		"num_records": _reader.get_num_records(),
		"num_roots": _reader.roots.size(),
		"nodes": 0,
		"meshes": 0,
		"total_vertices": 0,
		"total_triangles": 0,
		"textures": [],
		"has_animations": _has_animation_data(),
		"has_skinning": _has_skinning_data()
	}

	for record in _reader.records:
		if record is Defs.NiNode:
			info["nodes"] += 1
		elif record is Defs.NiTriShape or record is Defs.NiTriStrips:
			info["meshes"] += 1
		elif record is Defs.NiTriShapeData:
			var data := record as Defs.NiTriShapeData
			info["total_vertices"] += data.num_vertices
			info["total_triangles"] += data.num_triangles
		elif record is Defs.NiTriStripsData:
			var data := record as Defs.NiTriStripsData
			info["total_vertices"] += data.num_vertices
			info["total_triangles"] += data.num_triangles
		elif record is Defs.NiSourceTexture:
			var tex := record as Defs.NiSourceTexture
			if tex.is_external and tex.filename:
				info["textures"].append(tex.filename)

	return info


## Check if this NIF has any animation data (keyframe controllers)
func _has_animation_data() -> bool:
	for record in _reader.records:
		if record is Defs.NiKeyframeController:
			return true
	return false


## Create AnimationPlayer with animations extracted from NIF
func _create_animation_player(skeleton: Skeleton3D) -> AnimationPlayer:
	# Initialize animation converter
	_animation_converter = AnimationConverter.new()
	_animation_converter.init(_reader, skeleton)
	_animation_converter.debug_mode = debug_animations

	# Try to extract animations by text keys first (named animations)
	var animations := _animation_converter.convert_to_animations_by_text_keys()

	if animations.is_empty():
		# No text keys or animations found
		return null

	# Create AnimationPlayer and AnimationLibrary
	var anim_player := AnimationPlayer.new()
	anim_player.name = "AnimationPlayer"

	var library := AnimationLibrary.new()

	for anim_name in animations:
		var anim: Animation = animations[anim_name]
		if anim:
			var err := library.add_animation(anim_name, anim)
			if err != OK:
				push_warning("NIFConverter: Failed to add animation '%s': %s" % [anim_name, error_string(err)])
			elif debug_animations:
				print("  Added animation '%s' (%.2fs, %d tracks)" % [
					anim_name, anim.length, anim.get_track_count()
				])

	# Add library to player (empty string for default library)
	var lib_err := anim_player.add_animation_library("", library)
	if lib_err != OK:
		push_warning("NIFConverter: Failed to add animation library: %s" % error_string(lib_err))
		return null

	return anim_player


## Get animation info without full conversion
func get_animation_info() -> Dictionary:
	var info := {
		"has_animations": false,
		"controller_count": 0,
		"text_keys": [],
		"animation_names": []
	}

	for record in _reader.records:
		if record is Defs.NiKeyframeController:
			info["has_animations"] = true
			info["controller_count"] += 1
		elif record is Defs.NiTextKeyExtraData:
			var text_key := record as Defs.NiTextKeyExtraData
			for key in text_key.keys:
				info["text_keys"].append({
					"time": key["time"],
					"name": key["value"]
				})

	# Parse animation names from text keys
	var seen_names := {}
	for key in info["text_keys"]:
		var parts: PackedStringArray = key["name"].split(":")
		if parts.size() >= 2:
			var anim_name := parts[0].strip_edges()
			if anim_name not in seen_names:
				seen_names[anim_name] = true
				info["animation_names"].append(anim_name)

	return info


## Get collision info without full conversion
func get_collision_info() -> Dictionary:
	var info := {
		"has_collision": false,
		"has_root_collision_node": false,
		"has_actor_collision_box": false,
		"collision_shape_count": 0,
		"collision_mode": "auto_primitive",
		"detected_shapes": [],
		"shape_types": [],
		"bounding_volumes": [],
		"visual_collision_type": "default"  # "default", "camera", "none"
	}

	if _reader == null:
		return info

	# Initialize collision builder if needed
	if _collision_builder == null:
		_collision_builder = CollisionBuilder.new()
		_collision_builder.init(_reader)
		_collision_builder.detection_tolerance = collision_detection_tolerance
		if auto_collision_mode and not _source_path.is_empty():
			_collision_builder.collision_mode = CollisionBuilder.get_recommended_mode(_source_path)
		else:
			_collision_builder.collision_mode = collision_mode

	var result := _collision_builder.build_collision()

	info["has_collision"] = result.has_collision
	info["has_root_collision_node"] = result.root_collision_node_index >= 0
	info["has_actor_collision_box"] = result.has_actor_collision_box
	info["collision_shape_count"] = result.collision_shapes.size()
	info["detected_shapes"] = result.detected_shapes

	# Report collision mode used
	match _collision_builder.collision_mode:
		CollisionBuilder.CollisionMode.TRIMESH:
			info["collision_mode"] = "trimesh"
		CollisionBuilder.CollisionMode.CONVEX:
			info["collision_mode"] = "convex"
		CollisionBuilder.CollisionMode.AUTO_PRIMITIVE:
			info["collision_mode"] = "auto_primitive"
		CollisionBuilder.CollisionMode.PRIMITIVE_ONLY:
			info["collision_mode"] = "primitive_only"

	# Collect shape types from result
	for shape_data in result.collision_shapes:
		if shape_data.has("type"):
			info["shape_types"].append(shape_data["type"])

	if result.has_actor_collision_box:
		info["actor_collision"] = {
			"center": result.bounding_box_center,
			"extents": result.bounding_box_extents
		}

	match result.visual_collision_type:
		0:
			info["visual_collision_type"] = "default"
		1:
			info["visual_collision_type"] = "camera"

	# Collect bounding volume types from the NIF
	for record in _reader.records:
		if record is Defs.NiAVObject:
			var av_obj := record as Defs.NiAVObject
			if av_obj.has_bounding_volume and av_obj.bounding_volume != null:
				var bv_info := {
					"node_name": av_obj.name,
					"type": _bv_type_to_string(av_obj.bounding_volume.type)
				}
				info["bounding_volumes"].append(bv_info)

	return info


## Convert bounding volume type to string
func _bv_type_to_string(bv_type: int) -> String:
	match bv_type:
		Defs.BV_BASE:
			return "base"
		Defs.BV_SPHERE:
			return "sphere"
		Defs.BV_BOX:
			return "box"
		Defs.BV_CAPSULE:
			return "capsule"
		Defs.BV_LOZENGE:
			return "lozenge"
		Defs.BV_UNION:
			return "union"
		Defs.BV_HALFSPACE:
			return "halfspace"
		_:
			return "unknown"


# =============================================================================
# PARTICLE CONVERSION
# =============================================================================

## Convert NiParticles to a GPUParticles3D node
## This handles NiParticles, NiAutoNormalParticles, and NiRotatingParticles
func _convert_ni_particles(particles: Defs.NiParticles) -> Node3D:
	var node := GPUParticles3D.new()
	node.name = particles.name if particles.name else "Particles_%d" % particles.record_index

	# Apply transform
	var nif_transform := particles.transform.to_transform3d()
	node.transform = _convert_nif_transform(nif_transform)

	# Get particle data
	var particles_data: Defs.NiParticlesData = null
	if particles.data_index >= 0 and particles.data_index < _reader.records.size():
		var data_record = _reader.records[particles.data_index]
		if data_record is Defs.NiParticlesData:
			particles_data = data_record as Defs.NiParticlesData

	# Create process material for particle behavior
	var material := ParticleProcessMaterial.new()

	# Look for particle system controller to get emission parameters
	var controller: Defs.NiParticleSystemController = null
	if particles.controller_index >= 0:
		controller = _find_particle_controller(particles.controller_index)

	if controller:
		# Set emission parameters from controller
		material.initial_velocity_min = controller.speed - controller.speed_variation
		material.initial_velocity_max = controller.speed + controller.speed_variation

		# Convert direction (declination is angle from up vector)
		var direction := controller.initial_normal.normalized()
		material.direction = CS.vector_to_godot(direction, false)  # Direction, no scale
		material.spread = rad_to_deg(controller.declination_variation) * 2.0

		# Lifetime
		node.lifetime = controller.lifetime if controller.lifetime > 0 else 1.0

		# Emission timing
		if controller.birth_rate > 0:
			node.amount = int(controller.birth_rate * node.lifetime)
		else:
			node.amount = 8  # Default

		# Emitter shape (box emitter if dimensions are set)
		if controller.emitter_dimensions.length() > 0.001:
			var extents: Vector3 = CS.vector_to_godot(controller.emitter_dimensions) * 0.5
			material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
			material.emission_box_extents = extents.abs()
		else:
			material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINT

		# Initial color
		material.color = controller.initial_color

		# Look for particle modifiers (gravity, grow/fade, color)
		_apply_particle_modifiers(controller, material, node)
	else:
		# Default particle settings
		node.amount = 8
		node.lifetime = 1.0
		material.direction = Vector3.UP
		material.initial_velocity_min = 1.0
		material.initial_velocity_max = 2.0

	# Set particle size from data
	if particles_data:
		var base_size: float = particles_data.particle_radius * CS.SCALE_FACTOR
		if base_size > 0:
			material.scale_min = base_size
			material.scale_max = base_size

		# If we have vertex colors in the particle data, use the first one
		if particles_data.colors.size() > 0:
			material.color = particles_data.colors[0]

	node.process_material = material

	# Create a simple quad mesh for particles (billboard)
	var quad_mesh := QuadMesh.new()
	quad_mesh.size = Vector2(0.1, 0.1)  # Will be scaled by material
	node.draw_pass_1 = quad_mesh

	# Look for texturing property for particle texture
	var tex_material := _get_particle_texture_material(particles)
	if tex_material:
		quad_mesh.material = tex_material

	# Set billboard mode
	var draw_material := quad_mesh.material
	if draw_material == null:
		draw_material = StandardMaterial3D.new()
		quad_mesh.material = draw_material
	if draw_material is StandardMaterial3D:
		draw_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		draw_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	# Store metadata
	node.set_meta("nif_record_type", particles.record_type)
	node.set_meta("nif_record_index", particles.record_index)

	return node


## Find particle system controller in controller chain
func _find_particle_controller(controller_index: int) -> Defs.NiParticleSystemController:
	var current_index := controller_index
	while current_index >= 0 and current_index < _reader.records.size():
		var record = _reader.records[current_index]
		if record is Defs.NiParticleSystemController:
			return record as Defs.NiParticleSystemController
		elif record is Defs.NiTimeController:
			current_index = (record as Defs.NiTimeController).next_controller_index
		else:
			break
	return null


## Apply particle modifiers (gravity, grow/fade, color) to the particle material
func _apply_particle_modifiers(controller: Defs.NiParticleSystemController, material: ParticleProcessMaterial, node: GPUParticles3D) -> void:
	# The controller has references to modifiers through extra data chain
	# For now, look through all records for modifiers that might apply
	for record in _reader.records:
		if record is Defs.NiGravity:
			var gravity := record as Defs.NiGravity
			# Convert gravity direction and force
			var gravity_dir: Vector3 = CS.vector_to_godot(gravity.direction, false)  # Direction, no scale
			material.gravity = gravity_dir * gravity.force * CS.SCALE_FACTOR
		elif record is Defs.NiParticleGrowFade:
			var grow_fade := record as Defs.NiParticleGrowFade
			# Set up scale curve for grow/fade
			if grow_fade.grow_time > 0 or grow_fade.fade_time > 0:
				var curve := Curve.new()
				var grow_t := grow_fade.grow_time / node.lifetime if node.lifetime > 0 else 0.0
				var fade_t := 1.0 - (grow_fade.fade_time / node.lifetime if node.lifetime > 0 else 0.0)

				curve.add_point(Vector2(0.0, 0.0))
				if grow_t > 0:
					curve.add_point(Vector2(grow_t, 1.0))
				else:
					curve.set_point_value(0, 1.0)
				if fade_t < 1.0:
					curve.add_point(Vector2(fade_t, 1.0))
				curve.add_point(Vector2(1.0, 0.0))

				var curve_tex := CurveTexture.new()
				curve_tex.curve = curve
				material.scale_curve = curve_tex


## Get texture material for particles from NiTexturingProperty
func _get_particle_texture_material(particles: Defs.NiParticles) -> Material:
	for prop_index in particles.property_indices:
		if prop_index < 0 or prop_index >= _reader.records.size():
			continue
		var prop = _reader.records[prop_index]
		if prop is Defs.NiTexturingProperty:
			var tex_prop := prop as Defs.NiTexturingProperty
			if tex_prop.textures.size() > 0 and tex_prop.textures[0].has_texture:
				var tex_desc := tex_prop.textures[0]
				if tex_desc.source_index >= 0 and tex_desc.source_index < _reader.records.size():
					var source = _reader.records[tex_desc.source_index]
					if source is Defs.NiSourceTexture:
						var source_tex := source as Defs.NiSourceTexture
						if source_tex.is_external and source_tex.filename:
							var mat := StandardMaterial3D.new()
							mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
							mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
							# Store texture path for later loading
							mat.set_meta("nif_texture_path", source_tex.filename)
							return mat
	return null


# =============================================================================
# LIGHT CONVERSION
# =============================================================================

## Convert NiLight (ambient/directional) to Godot light
func _convert_ni_light(light: Defs.NiLight) -> Node3D:
	# Check record type for specific light type
	if light.record_type == Defs.RT_NI_AMBIENT_LIGHT:
		# Godot doesn't have an ambient light node, store as metadata on a Node3D
		var node := Node3D.new()
		node.name = light.name if light.name else "AmbientLight_%d" % light.record_index

		var nif_transform := light.transform.to_transform3d()
		node.transform = _convert_nif_transform(nif_transform)

		node.set_meta("nif_record_type", light.record_type)
		node.set_meta("nif_light_type", "ambient")
		node.set_meta("nif_ambient_color", light.ambient_color)
		node.set_meta("nif_dimmer", light.dimmer)

		return node
	elif light.record_type == Defs.RT_NI_DIRECTIONAL_LIGHT:
		var dir_light := DirectionalLight3D.new()
		dir_light.name = light.name if light.name else "DirectionalLight_%d" % light.record_index

		var nif_transform := light.transform.to_transform3d()
		dir_light.transform = _convert_nif_transform(nif_transform)

		# Use diffuse color as light color
		dir_light.light_color = Color(light.diffuse_color.r, light.diffuse_color.g, light.diffuse_color.b)
		dir_light.light_energy = light.dimmer

		dir_light.set_meta("nif_record_type", light.record_type)
		dir_light.set_meta("nif_record_index", light.record_index)

		return dir_light

	# Fallback for base NiLight
	var node := Node3D.new()
	node.name = light.name if light.name else "Light_%d" % light.record_index
	node.set_meta("nif_record_type", light.record_type)
	return node


## Convert NiPointLight to OmniLight3D
func _convert_ni_point_light(light: Defs.NiPointLight) -> OmniLight3D:
	var omni_light := OmniLight3D.new()
	omni_light.name = light.name if light.name else "PointLight_%d" % light.record_index

	var nif_transform := light.transform.to_transform3d()
	omni_light.transform = _convert_nif_transform(nif_transform)

	# Use diffuse color as light color
	omni_light.light_color = Color(light.diffuse_color.r, light.diffuse_color.g, light.diffuse_color.b)
	omni_light.light_energy = light.dimmer

	# Calculate range from attenuation
	# NIF uses: attenuation = 1 / (constant + linear*d + quadratic*d^2)
	# We need to estimate a reasonable range
	var range := _calculate_light_range(light.constant_atten, light.linear_atten, light.quadratic_atten)
	omni_light.omni_range = range * CS.SCALE_FACTOR

	# Set attenuation curve (Godot uses inverse square by default which is close)
	if light.quadratic_atten > 0:
		omni_light.omni_attenuation = 1.0  # Quadratic falloff
	elif light.linear_atten > 0:
		omni_light.omni_attenuation = 0.5  # Linear-ish falloff
	else:
		omni_light.omni_attenuation = 0.0  # Constant (no falloff)

	omni_light.set_meta("nif_record_type", light.record_type)
	omni_light.set_meta("nif_record_index", light.record_index)
	omni_light.set_meta("nif_constant_atten", light.constant_atten)
	omni_light.set_meta("nif_linear_atten", light.linear_atten)
	omni_light.set_meta("nif_quadratic_atten", light.quadratic_atten)

	return omni_light


## Convert NiSpotLight to SpotLight3D
func _convert_ni_spot_light(light: Defs.NiSpotLight) -> SpotLight3D:
	var spot_light := SpotLight3D.new()
	spot_light.name = light.name if light.name else "SpotLight_%d" % light.record_index

	var nif_transform := light.transform.to_transform3d()
	spot_light.transform = _convert_nif_transform(nif_transform)

	# Use diffuse color as light color
	spot_light.light_color = Color(light.diffuse_color.r, light.diffuse_color.g, light.diffuse_color.b)
	spot_light.light_energy = light.dimmer

	# Calculate range from attenuation
	var range := _calculate_light_range(light.constant_atten, light.linear_atten, light.quadratic_atten)
	spot_light.spot_range = range * CS.SCALE_FACTOR

	# Spot angle (NIF uses outer angle, Godot uses half-angle)
	spot_light.spot_angle = rad_to_deg(light.outer_spot_angle)

	# Spot attenuation based on inner/outer angle difference
	if light.outer_spot_angle > 0 and light.inner_spot_angle > 0:
		var angle_ratio := light.inner_spot_angle / light.outer_spot_angle
		spot_light.spot_angle_attenuation = 1.0 - angle_ratio
	else:
		spot_light.spot_angle_attenuation = 1.0

	# Distance attenuation
	if light.quadratic_atten > 0:
		spot_light.spot_attenuation = 1.0
	elif light.linear_atten > 0:
		spot_light.spot_attenuation = 0.5
	else:
		spot_light.spot_attenuation = 0.0

	spot_light.set_meta("nif_record_type", light.record_type)
	spot_light.set_meta("nif_record_index", light.record_index)
	spot_light.set_meta("nif_outer_spot_angle", light.outer_spot_angle)
	spot_light.set_meta("nif_inner_spot_angle", light.inner_spot_angle)
	spot_light.set_meta("nif_exponent", light.exponent)

	return spot_light


## Calculate effective light range from NIF attenuation parameters
## Returns range in NIF units
func _calculate_light_range(constant: float, linear: float, quadratic: float) -> float:
	# Find distance where light intensity drops to ~1% (0.01)
	# attenuation = 1 / (c + l*d + q*d^2)
	# We want: 1 / (c + l*d + q*d^2) = 0.01
	# So: c + l*d + q*d^2 = 100

	if quadratic > 0.0001:
		# Solve quadratic: q*d^2 + l*d + (c - 100) = 0
		var a := quadratic
		var b := linear
		var c := constant - 100.0
		var discriminant := b * b - 4.0 * a * c
		if discriminant >= 0:
			return (-b + sqrt(discriminant)) / (2.0 * a)
	elif linear > 0.0001:
		# Linear case: l*d = 100 - c
		return (100.0 - constant) / linear

	# Default range if no attenuation (or constant only)
	return 500.0  # 500 NIF units


# =============================================================================
# LOD AND SWITCH NODE CONVERSION
# =============================================================================

## Recursively apply visibility range to all GeometryInstance3D nodes in a subtree
func _apply_visibility_range(node: Node, begin: float, end: float) -> void:
	if node is GeometryInstance3D:
		node.visibility_range_begin = begin
		node.visibility_range_end = end
		node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	for child in node.get_children():
		_apply_visibility_range(child, begin, end)


## Convert NiLODNode to Node3D with LOD metadata
func _convert_ni_lod_node(lod_node: Defs.NiLODNode, skeleton: Skeleton3D = null) -> Node3D:
	var node := Node3D.new()
	node.name = lod_node.name if lod_node.name else "LODNode_%d" % lod_node.record_index

	# Apply transform
	var nif_transform := lod_node.transform.to_transform3d()
	node.transform = _convert_nif_transform(nif_transform)

	# Store LOD data as metadata
	node.set_meta("nif_record_type", lod_node.record_type)
	node.set_meta("nif_record_index", lod_node.record_index)
	node.set_meta("nif_lod_center", CS.vector_to_godot(lod_node.lod_center))

	# Convert LOD levels (convert distances to meters)
	var converted_levels: Array = []
	for level in lod_node.lod_levels:
		converted_levels.append({
			"min_range": level.get("min_range", 0.0) * CS.SCALE_FACTOR,
			"max_range": level.get("max_range", 0.0) * CS.SCALE_FACTOR
		})
	node.set_meta("nif_lod_levels", converted_levels)

	# Convert children
	for child_index in lod_node.children_indices:
		if child_index < 0 or child_index >= _reader.records.size():
			continue
		var child_record = _reader.records[child_index]
		var child_node := _convert_record(child_record, skeleton)
		if child_node:
			node.add_child(child_node)
			# Store LOD level index on child
			var lod_index := lod_node.children_indices.find(child_index)
			child_node.set_meta("nif_lod_level", lod_index)

	# Apply Godot visibility ranges to each LOD level
	for i in node.get_child_count():
		var child = node.get_child(i)
		var lod_index = child.get_meta("nif_lod_level", -1)
		if lod_index < 0 or lod_index >= converted_levels.size():
			continue

		# Calculate visibility range for this LOD level
		var begin: float = 0.0
		var end: float = converted_levels[lod_index]["max_range"]

		# LOD levels after 0 start where the previous one ends
		if lod_index > 0:
			begin = converted_levels[lod_index - 1]["max_range"]

		# Last LOD level extends to infinity (0 = no limit in Godot)
		if lod_index == converted_levels.size() - 1:
			end = 0.0

		_apply_visibility_range(child, begin, end)

	return node


## Convert NiSwitchNode to Node3D with switch metadata
func _convert_ni_switch_node(switch_node: Defs.NiSwitchNode, skeleton: Skeleton3D = null) -> Node3D:
	var node := Node3D.new()
	node.name = switch_node.name if switch_node.name else "SwitchNode_%d" % switch_node.record_index

	# Apply transform
	var nif_transform := switch_node.transform.to_transform3d()
	node.transform = _convert_nif_transform(nif_transform)

	# Store switch data as metadata
	node.set_meta("nif_record_type", switch_node.record_type)
	node.set_meta("nif_record_index", switch_node.record_index)
	node.set_meta("nif_switch_flags", switch_node.switch_flags)
	node.set_meta("nif_initial_index", switch_node.initial_index)

	# Convert children
	var child_index_counter := 0
	for child_index in switch_node.children_indices:
		if child_index < 0 or child_index >= _reader.records.size():
			child_index_counter += 1
			continue
		var child_record = _reader.records[child_index]
		var child_node := _convert_record(child_record, skeleton)
		if child_node:
			node.add_child(child_node)
			# Store switch index on child
			child_node.set_meta("nif_switch_index", child_index_counter)
			# Hide all children except the initial one
			if child_index_counter != switch_node.initial_index:
				child_node.visible = false
		child_index_counter += 1

	return node
