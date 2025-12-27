## NIF Skeleton Builder - Builds Godot Skeleton3D from NIF skinning data
## Creates bone hierarchy and handles skinned mesh binding
class_name NIFSkeletonBuilder
extends RefCounted

const Defs := preload("res://src/core/nif/nif_defs.gd")
const CS := preload("res://src/core/coordinate_system.gd")

# Reference to the NIF reader for accessing records
var _reader: RefCounted = null

# Bone name to index mapping (case-insensitive)
var _bone_name_to_index: Dictionary = {}

# Validation results
var _validation_errors: Array[String] = []
var _validation_warnings: Array[String] = []

# Debug output
var debug_mode: bool = false


## Initialize with a NIF reader instance
func init(reader: RefCounted) -> void:
	_reader = reader
	_bone_name_to_index.clear()
	_validation_errors.clear()
	_validation_warnings.clear()


## Check if a geometry node has skinning data
func has_skin(geom: Defs.NiGeometry) -> bool:
	return geom.skin_index >= 0


## Build a Skeleton3D from NiSkinInstance
## Returns the skeleton and populates bone mapping for later use
func build_skeleton(skin_instance: Defs.NiSkinInstance) -> Skeleton3D:
	_validation_errors.clear()
	_validation_warnings.clear()

	if skin_instance == null:
		_add_error("Null skin instance provided")
		return null

	var skin_data := _reader.call("get_record", skin_instance.data_index) as Defs.NiSkinData
	if skin_data == null:
		_add_error("Could not find NiSkinData at index %d" % skin_instance.data_index)
		return null

	if skin_instance.bone_indices.is_empty():
		_add_error("Skin instance has no bones")
		return null

	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	_bone_name_to_index.clear()

	# Get the skeleton root node
	var root_node: Defs.NiNode = null
	if skin_instance.root_index >= 0:
		root_node = _reader.call("get_record", skin_instance.root_index) as Defs.NiNode

	if root_node == null:
		_add_warning("No root node found for skeleton, hierarchy may be incorrect")

	if debug_mode:
		print("NIFSkeletonBuilder: Building skeleton with %d bones" % skin_instance.bone_indices.size())
		if root_node:
			print("  Root node: '%s'" % root_node.name)

	# Track missing bones for error reporting
	var missing_bones: Array[int] = []
	var duplicate_names: Dictionary = {}

	# Build bones from the bone list in NiSkinInstance
	# Each bone index points to an NiNode in the scene graph
	for i in range(skin_instance.bone_indices.size()):
		var bone_node_idx := skin_instance.bone_indices[i]
		var bone_node := _reader.call("get_record", bone_node_idx) as Defs.NiNode

		if bone_node == null:
			missing_bones.append(bone_node_idx)
			# Create placeholder bone to maintain index alignment
			var bone_name := "Missing_Bone_%d" % i
			skeleton.add_bone(bone_name)
			_bone_name_to_index[bone_name.to_lower()] = skeleton.get_bone_count() - 1
			continue

		var bone_name := bone_node.name if bone_node.name else "Bone_%d" % i

		# Check for duplicate bone names
		var lower_name := bone_name.to_lower()
		if lower_name in _bone_name_to_index:
			if lower_name not in duplicate_names:
				duplicate_names[lower_name] = 1
			duplicate_names[lower_name] += 1
			bone_name = "%s_%d" % [bone_name, duplicate_names[lower_name]]

		var bone_idx := skeleton.get_bone_count()

		# Add bone to skeleton
		skeleton.add_bone(bone_name)

		# Store mapping (case-insensitive)
		_bone_name_to_index[bone_name.to_lower()] = bone_idx

		if debug_mode:
			print("  Bone %d: '%s' (node %d)" % [bone_idx, bone_name, bone_node_idx])

	# Report missing bones
	if not missing_bones.is_empty():
		_add_warning("Missing %d bone nodes: %s" % [missing_bones.size(), str(missing_bones)])

	# Report duplicate names
	if not duplicate_names.is_empty():
		_add_warning("Renamed %d duplicate bone names" % duplicate_names.size())

	# Set up bone hierarchy by finding parent relationships
	_setup_bone_hierarchy(skeleton, skin_instance, root_node)

	# Set bone rest poses from NiSkinData inverse bind matrices
	_setup_bone_rest_poses(skeleton, skin_instance, skin_data)

	# Validate final skeleton
	_validate_skeleton(skeleton)

	# Print validation results if any
	if debug_mode or not _validation_errors.is_empty():
		_print_validation_results()

	return skeleton


## Validate the built skeleton
func _validate_skeleton(skeleton: Skeleton3D) -> void:
	if skeleton.get_bone_count() == 0:
		_add_error("Skeleton has no bones")
		return

	# Check for expected Morrowind bones
	var expected_bones := ["bip01", "bip01 spine", "bip01 head"]
	var found_expected := 0
	for bone_name: String in expected_bones:
		if bone_name in _bone_name_to_index:
			found_expected += 1

	if found_expected == 0:
		_add_warning("No expected Morrowind bones found (Bip01, Bip01 Spine, etc.)")

	# Check for orphan bones (bones with no parent that aren't root)
	var orphan_count := 0
	var root_count := 0
	for i in skeleton.get_bone_count():
		var parent := skeleton.get_bone_parent(i)
		if parent < 0:
			root_count += 1
			if root_count > 1 and "bip01" not in skeleton.get_bone_name(i).to_lower():
				orphan_count += 1

	if orphan_count > 0:
		_add_warning("Found %d potentially orphaned bones (multiple roots)" % orphan_count)


## Add a validation error
func _add_error(message: String) -> void:
	_validation_errors.append(message)
	push_error("NIFSkeletonBuilder: %s" % message)


## Add a validation warning
func _add_warning(message: String) -> void:
	_validation_warnings.append(message)
	if debug_mode:
		push_warning("NIFSkeletonBuilder: %s" % message)


## Print validation results
func _print_validation_results() -> void:
	if not _validation_errors.is_empty():
		print("NIFSkeletonBuilder: %d errors:" % _validation_errors.size())
		for error: String in _validation_errors:
			print("  ERROR: %s" % error)

	if not _validation_warnings.is_empty():
		print("NIFSkeletonBuilder: %d warnings:" % _validation_warnings.size())
		for warning: String in _validation_warnings:
			print("  WARNING: %s" % warning)


## Get validation errors
func get_errors() -> Array[String]:
	return _validation_errors


## Get validation warnings
func get_warnings() -> Array[String]:
	return _validation_warnings


## Check if skeleton build had errors
func has_errors() -> bool:
	return not _validation_errors.is_empty()


## Set up parent-child relationships between bones
func _setup_bone_hierarchy(skeleton: Skeleton3D, skin_instance: Defs.NiSkinInstance, root_node: Defs.NiNode) -> void:
	# Build a map of node index -> bone index for quick lookup
	var node_to_bone: Dictionary = {}
	for i in range(skin_instance.bone_indices.size()):
		node_to_bone[skin_instance.bone_indices[i]] = i

	# For each bone, find its parent by traversing up the NiNode tree
	for i in range(skin_instance.bone_indices.size()):
		var bone_node_idx := skin_instance.bone_indices[i]
		var parent_bone_idx := _find_parent_bone(bone_node_idx, node_to_bone, root_node)

		if parent_bone_idx >= 0:
			skeleton.set_bone_parent(i, parent_bone_idx)
			if debug_mode:
				print("  Bone %d parent -> %d" % [i, parent_bone_idx])


## Find the parent bone index for a given node by traversing up the tree
func _find_parent_bone(node_idx: int, node_to_bone: Dictionary, root_node: Defs.NiNode) -> int:
	# We need to find the parent NiNode and check if it's a bone
	# This requires traversing the node tree to find parents

	# Build parent map if we haven't already
	var parent_map := _build_parent_map(root_node)

	var current_idx := node_idx
	while parent_map.has(current_idx):
		var parent_idx: int = parent_map[current_idx]
		if node_to_bone.has(parent_idx):
			return node_to_bone[parent_idx]
		current_idx = parent_idx

	return -1  # No parent bone found (root bone)


## Build a map of child node index -> parent node index
func _build_parent_map(root_node: Defs.NiNode) -> Dictionary:
	var parent_map: Dictionary = {}
	if root_node == null:
		return parent_map

	_build_parent_map_recursive(root_node, parent_map)
	return parent_map


func _build_parent_map_recursive(node: Defs.NiNode, parent_map: Dictionary) -> void:
	for child_idx in node.children_indices:
		if child_idx < 0:
			continue
		parent_map[child_idx] = node.record_index

		var child: Defs.NIFRecord = _reader.call("get_record", child_idx)
		if child is Defs.NiNode:
			_build_parent_map_recursive(child as Defs.NiNode, parent_map)


## Set bone rest poses from inverse bind matrices
func _setup_bone_rest_poses(skeleton: Skeleton3D, skin_instance: Defs.NiSkinInstance, skin_data: Defs.NiSkinData) -> void:
	# The NiSkinData contains inverse bind matrices for each bone
	# These transforms go from mesh space to bone space
	#
	# In Godot's skeletal animation system:
	# - bone_rest is the bone's transform in its parent's space (or skeleton space for root bones)
	# - For skinning, Godot internally computes the inverse bind matrix
	#
	# NIF stores the inverse bind matrix directly in NiSkinData.bones[i].transform
	# We need to invert it to get the rest pose, then convert coordinates

	for i in range(mini(skin_instance.bone_indices.size(), skin_data.bones.size())):
		var bone_data: Dictionary = skin_data.bones[i]
		var bone_transform: Defs.NIFTransform = bone_data["transform"]

		# Get the inverse bind matrix from NiSkinData
		var inverse_bind := bone_transform.to_transform3d()

		# Invert to get the bind pose (bone position in mesh space)
		var bind_pose := inverse_bind.affine_inverse()

		# Convert from Morrowind coordinates (Z-up, Y-forward) to Godot (Y-up, Z-back)
		var rest_pose := _convert_nif_transform(bind_pose)

		skeleton.set_bone_rest(i, rest_pose)

		if debug_mode:
			print("  Bone %d rest: pos=%s rot=%s" % [i, rest_pose.origin, rest_pose.basis.get_euler()])


## Convert a NIF transform from Morrowind to Godot coordinate system
## Delegates to unified CoordinateSystem - outputs in meters
func _convert_nif_transform(transform: Transform3D) -> Transform3D:
	return CS.transform_to_godot(transform)  # Converts to meters


## Convert a bone transform from Morrowind to Godot coordinate system (legacy alias)
func _convert_bone_transform(transform: Transform3D) -> Transform3D:
	return CS.transform_to_godot(transform)  # Converts to meters


## Get bone index by name (case-insensitive)
func get_bone_index(bone_name: String) -> int:
	return _bone_name_to_index.get(bone_name.to_lower(), -1)


## Build bone indices and weights arrays for a skinned mesh
## Returns a dictionary with "indices" and "weights" PackedFloat32Arrays
## Godot expects 4 bone influences per vertex
func build_skin_arrays(geom_data: Defs.NiGeometryData, skin_instance: Defs.NiSkinInstance, skin_data: Defs.NiSkinData) -> Dictionary:
	var num_vertices := geom_data.num_vertices

	# Godot uses 4 bones per vertex (can be extended to 8 with USE_SKELETON_WEIGHTS_8)
	const BONES_PER_VERTEX := 4

	# Initialize arrays - Godot wants int for indices, float for weights
	var bone_indices := PackedInt32Array()
	var bone_weights := PackedFloat32Array()
	bone_indices.resize(num_vertices * BONES_PER_VERTEX)
	bone_weights.resize(num_vertices * BONES_PER_VERTEX)

	# Initialize to zero
	bone_indices.fill(0)
	bone_weights.fill(0.0)

	# Build per-vertex weight data from NiSkinData
	# NiSkinData stores weights per-bone, we need to convert to per-vertex
	var vertex_weights: Array = []  # Array of arrays: [bone_idx, weight] pairs per vertex
	vertex_weights.resize(num_vertices)
	for i in range(num_vertices):
		vertex_weights[i] = []

	# Collect weights from each bone
	for bone_idx in range(skin_data.bones.size()):
		var bone_data: Dictionary = skin_data.bones[bone_idx]
		var weights: Array = bone_data["weights"]

		for weight_info: Dictionary in weights:
			var vertex_idx: int = weight_info["vertex"]
			var weight: float = weight_info["weight"]

			if vertex_idx < num_vertices and weight > 0.0:
				var vert_weights: Array = vertex_weights[vertex_idx]
				vert_weights.append([bone_idx, weight])

	# Convert to Godot format (4 bones per vertex, sorted by weight)
	for vert_idx in range(num_vertices):
		var weights: Array = vertex_weights[vert_idx]

		# Sort by weight descending
		weights.sort_custom(func(a: Variant, b: Variant) -> bool: return a[1] > b[1])

		# Take top 4 influences
		var total_weight := 0.0
		for i in range(mini(weights.size(), BONES_PER_VERTEX)):
			var bone_idx: int = weights[i][0]
			var weight: float = weights[i][1]

			bone_indices[vert_idx * BONES_PER_VERTEX + i] = bone_idx
			bone_weights[vert_idx * BONES_PER_VERTEX + i] = weight
			total_weight += weight

		# Normalize weights to sum to 1.0
		if total_weight > 0.0:
			for i in range(BONES_PER_VERTEX):
				bone_weights[vert_idx * BONES_PER_VERTEX + i] /= total_weight

	if debug_mode:
		# Debug: print first few vertices
		for i in range(mini(5, num_vertices)):
			var idx := i * BONES_PER_VERTEX
			print("  Vertex %d: bones=[%d,%d,%d,%d] weights=[%.3f,%.3f,%.3f,%.3f]" % [
				i,
				bone_indices[idx], bone_indices[idx+1], bone_indices[idx+2], bone_indices[idx+3],
				bone_weights[idx], bone_weights[idx+1], bone_weights[idx+2], bone_weights[idx+3]
			])

	return {
		"indices": bone_indices,
		"weights": bone_weights
	}


## Check if NiSkinPartition data should be used instead of NiSkinData weights
func has_skin_partition(skin_instance: Defs.NiSkinInstance) -> bool:
	var skin_data := _reader.call("get_record", skin_instance.data_index) as Defs.NiSkinData
	if skin_data == null:
		return false

	# Check if there's a partition index in the skin instance
	# In Morrowind NIFs, partition is typically stored separately
	# For now, we use NiSkinData weights which are always present
	return false


## Build skin arrays from NiSkinPartition (GPU-optimized format)
## This is more efficient but may split the mesh into multiple draw calls
func build_skin_arrays_from_partition(partition: Defs.NiSkinPartition, partition_idx: int) -> Dictionary:
	if partition_idx >= partition.partitions.size():
		return {}

	var part: Dictionary = partition.partitions[partition_idx]
	var num_vertices: int = part["num_vertices"]
	var bones_per_vertex: int = part["bones_per_vertex"]
	var partition_bones: PackedInt32Array = part["bones"]
	var vertex_weights: PackedFloat32Array = part["weights"]

	const BONES_PER_VERTEX := 4

	var bone_indices := PackedInt32Array()
	var bone_weights := PackedFloat32Array()
	bone_indices.resize(num_vertices * BONES_PER_VERTEX)
	bone_weights.resize(num_vertices * BONES_PER_VERTEX)
	bone_indices.fill(0)
	bone_weights.fill(0.0)

	# Copy weights, remapping partition bone indices to skeleton bone indices
	for vert_idx in range(num_vertices):
		for bone_slot in range(mini(bones_per_vertex, BONES_PER_VERTEX)):
			var weight_idx := vert_idx * bones_per_vertex + bone_slot
			var weight: float = vertex_weights[weight_idx]

			if part.has("bone_indices"):
				var local_bone_idx: int = part["bone_indices"][weight_idx]
				var global_bone_idx: int = partition_bones[local_bone_idx] if local_bone_idx < partition_bones.size() else 0
				bone_indices[vert_idx * BONES_PER_VERTEX + bone_slot] = global_bone_idx
			else:
				bone_indices[vert_idx * BONES_PER_VERTEX + bone_slot] = bone_slot

			bone_weights[vert_idx * BONES_PER_VERTEX + bone_slot] = weight

	return {
		"indices": bone_indices,
		"weights": bone_weights
	}
