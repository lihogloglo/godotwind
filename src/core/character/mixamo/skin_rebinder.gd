## SkinRebinder - Rebinds Morrowind meshes to Mixamo skeleton
##
## Takes mesh data extracted from Morrowind NIFs and creates proper Godot
## Skin resources that work with a Mixamo skeleton. Handles the transform
## corrections needed when mapping between different skeleton standards.
##
## KEY INSIGHT: When rebinding a skinned mesh from skeleton A to skeleton B,
## we need to compute corrective inverse bind matrices:
##
##   new_inv_bind = Mixamo_bone_global.inverse() × MW_bone_global × MW_inv_bind
##
## This ensures that vertices appear at the correct positions when the Mixamo
## skeleton is in its rest pose, even though the bone positions differ.
class_name SkinRebinder
extends RefCounted


const BoneMapper := preload("res://src/core/character/mixamo/bone_mapper.gd")
const MeshExtractor := preload("res://src/core/character/mixamo/mesh_extractor.gd")
const CS := preload("res://src/core/coordinate_system.gd")

## Cached Morrowind skeleton bone transforms (computed from xbase_anim.nif)
## Key: lowercase bone name, Value: global rest Transform3D (in Godot space)
static var _mw_bone_transforms: Dictionary = {}
static var _mw_skeleton_loaded: bool = false


## Result of rebinding operation
class RebindResult:
	var success: bool = false
	var mesh: ArrayMesh = null
	var skin: Skin = null
	var unmapped_bones: PackedStringArray = PackedStringArray()
	var error: String = ""

	static func ok(p_mesh: ArrayMesh, p_skin: Skin) -> RebindResult:
		var r := RebindResult.new()
		r.success = true
		r.mesh = p_mesh
		r.skin = p_skin
		return r

	static func fail(p_error: String) -> RebindResult:
		var r := RebindResult.new()
		r.success = false
		r.error = p_error
		return r


## Rebind a mesh to a Mixamo skeleton
## mesh_data: Extracted mesh from MeshExtractor
## mixamo_skeleton: Target Mixamo skeleton
## Returns: RebindResult with mesh and skin
static func rebind(
	mesh_data: MeshExtractor.MeshData,
	mixamo_skeleton: Skeleton3D
) -> RebindResult:
	if not mesh_data:
		return RebindResult.fail("Mesh data is null")

	if not mixamo_skeleton:
		return RebindResult.fail("Skeleton is null")

	if not mesh_data.is_skinned:
		# Non-skinned mesh - just create the mesh without skin
		var mesh := MeshExtractor.create_array_mesh(mesh_data)
		return RebindResult.ok(mesh, null)

	# Build bone index mapping: morrowind index -> mixamo index
	var bone_map := _build_bone_map(mesh_data.bone_names, mixamo_skeleton)

	if bone_map.mapped.is_empty():
		return RebindResult.fail("No bones could be mapped")

	# Create remapped mesh with new bone indices
	var remapped_mesh := _create_remapped_mesh(mesh_data, bone_map.index_map)

	# Create Skin resource with corrected inverse bind matrices
	var skin := _create_skin(
		mesh_data.bone_names,
		mesh_data.inv_bind_poses,
		bone_map.index_map,
		mixamo_skeleton
	)

	var result := RebindResult.ok(remapped_mesh, skin)
	result.unmapped_bones = bone_map.unmapped
	return result


## Build bone index mapping
static func _build_bone_map(
	morrowind_bones: PackedStringArray,
	mixamo_skeleton: Skeleton3D
) -> Dictionary:
	var index_map := {}  # morrowind_idx -> mixamo_idx
	var mapped := PackedStringArray()
	var unmapped := PackedStringArray()

	for i in morrowind_bones.size():
		var mw_name := morrowind_bones[i]
		var mixamo_name := BoneMapper.to_mixamo(mw_name)

		if mixamo_name.is_empty():
			unmapped.append(mw_name)
			# Map to root as fallback
			index_map[i] = 0
			continue

		var mixamo_idx := mixamo_skeleton.find_bone(mixamo_name)
		if mixamo_idx < 0:
			unmapped.append(mw_name)
			index_map[i] = 0
			continue

		index_map[i] = mixamo_idx
		mapped.append(mw_name)

	return {
		"index_map": index_map,
		"mapped": mapped,
		"unmapped": unmapped
	}


## Create mesh with remapped bone indices
static func _create_remapped_mesh(
	mesh_data: MeshExtractor.MeshData,
	index_map: Dictionary
) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	# Copy geometry data
	arrays[Mesh.ARRAY_VERTEX] = mesh_data.vertices
	if not mesh_data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = mesh_data.normals
	if not mesh_data.uvs.is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = mesh_data.uvs
	arrays[Mesh.ARRAY_INDEX] = mesh_data.indices

	# Remap bone indices
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()

	for i in mesh_data.vertices.size():
		var old_indices: PackedInt32Array = mesh_data.bone_indices[i]
		var vert_weights: PackedFloat32Array = mesh_data.bone_weights[i]

		# Remap each bone index
		for j in 4:
			var old_idx: int = old_indices[j]
			var new_idx: int = index_map.get(old_idx, 0)
			bones.append(new_idx)
			weights.append(vert_weights[j])

	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Copy metadata
	mesh.set_meta("source_path", mesh_data.source_path)
	mesh.set_meta("texture_path", mesh_data.texture_path)

	return mesh


## Ensure Morrowind skeleton transforms are loaded
static func _ensure_mw_skeleton_loaded() -> void:
	if _mw_skeleton_loaded:
		return

	# Load xbase_anim.nif to get bone global transforms
	var bsa_mgr: Node = null
	var main_loop := Engine.get_main_loop() as SceneTree
	if main_loop and main_loop.root:
		bsa_mgr = main_loop.root.get_node_or_null("/root/BSAManager")

	if not bsa_mgr:
		push_error("SkinRebinder: BSAManager not available for loading Morrowind skeleton")
		return

	var skel_path := "meshes\\xbase_anim.nif"  # Use backslash for BSA lookup
	var data: PackedByteArray = bsa_mgr.extract_file(skel_path)
	if data.is_empty():
		push_error("SkinRebinder: Cannot load Morrowind skeleton: %s" % skel_path)
		return

	# Parse NIF
	var NIFReader := preload("res://src/core/nif/nif_reader.gd")
	var reader := NIFReader.new()
	var err := reader.load_buffer(data, skel_path)
	if err != OK:
		push_error("SkinRebinder: Failed to parse skeleton NIF: %s" % skel_path)
		return

	if reader.roots.is_empty():
		push_error("SkinRebinder: No roots in skeleton NIF")
		return

	var root := reader.get_record(reader.roots[0])
	if root:
		_extract_bone_transforms_recursive(reader, root, Transform3D.IDENTITY)

	_mw_skeleton_loaded = true


## Recursively extract bone transforms from NIF hierarchy
static func _extract_bone_transforms_recursive(reader, node, parent_global: Transform3D) -> void:
	if node == null or not "name" in node:
		return

	# Get local transform
	var local_transform := Transform3D.IDENTITY
	if "translation" in node and "rotation" in node:
		var translation: Vector3 = node.translation
		var rotation: Basis = node.rotation
		var scale_val: float = node.scale if "scale" in node else 1.0

		var basis := rotation
		if scale_val != 1.0:
			basis = basis.scaled(Vector3(scale_val, scale_val, scale_val))

		local_transform = Transform3D(basis, translation)

	# Compute global transform in NIF space
	var global_nif := parent_global * local_transform

	# Convert to Godot space and store
	var bone_name: String = node.name.to_lower()
	if not bone_name.is_empty():
		_mw_bone_transforms[bone_name] = CS.transform_to_godot(global_nif)

	# Process children
	if "children_indices" in node:
		for child_idx in node.children_indices:
			if child_idx >= 0:
				var child = reader.get_record(child_idx)
				if child != null:
					_extract_bone_transforms_recursive(reader, child, global_nif)


## Get Morrowind bone global transform (in Godot space)
static func get_mw_bone_global(bone_name: String) -> Transform3D:
	_ensure_mw_skeleton_loaded()
	var lower := bone_name.to_lower()
	if lower in _mw_bone_transforms:
		return _mw_bone_transforms[lower]
	return Transform3D.IDENTITY


## Create Skin resource with corrected inverse bind matrices
##
## GPU SKINNING MATH:
## Godot computes: vertex' = bone_global_pose × skin_inv_bind × vertex
##
## THE PROBLEM:
## Morrowind meshes have vertices positioned for a character where bones are at
## origin (very small skeleton). The inv_bind matrices transform these to bone-local
## space such that: MW_bone_world × MW_inv_bind = identity.
##
## This means vertex positions ARE the "world" positions, but for a tiny skeleton
## centered at origin.
##
## When we map to Mixamo (which has bones at proper humanoid positions like
## hips at Y=1.0), we need to MOVE the vertices to match the new bone positions.
##
## THE SOLUTION:
## Use the ORIGINAL Morrowind inv_bind matrix. The key insight is:
## - MW inv_bind transforms vertices to bone-local space
## - When Mixamo bone is at its rest position, the bone-local vertex gets
##   positioned at: Mixamo_rest.origin + bone_local_pos
##
## This automatically moves vertices to the Mixamo skeleton's positions while
## keeping the bone-relative geometry intact.
static func _create_skin(
	morrowind_bones: PackedStringArray,
	morrowind_inv_binds: Array,
	index_map: Dictionary,
	mixamo_skeleton: Skeleton3D
) -> Skin:
	var skin := Skin.new()

	# Track which Mixamo bones we've already added to avoid duplicates
	var added_bones := {}

	for i in morrowind_bones.size():
		var mixamo_idx: int = index_map.get(i, -1)
		if mixamo_idx < 0:
			continue

		# Skip if we've already added this bone (handles duplicate mappings)
		if mixamo_idx in added_bones:
			continue
		added_bones[mixamo_idx] = true

		var mw_bone_name: String = morrowind_bones[i]

		# Get original Morrowind inverse bind matrix
		var mw_inv_bind: Transform3D
		if i < morrowind_inv_binds.size():
			mw_inv_bind = morrowind_inv_binds[i]
		else:
			push_warning("SkinRebinder: Missing inverse bind for bone %d (%s)" % [i, mw_bone_name])
			mw_inv_bind = Transform3D.IDENTITY

		# USE THE ORIGINAL MORROWIND INV_BIND!
		# The Morrowind inv_bind transforms vertices to bone-local space.
		# When Mixamo skeleton is at rest, the GPU computes:
		#   vertex' = Mixamo_rest × MW_inv_bind × vertex
		#           = Mixamo_rest × (bone-local position)
		#
		# This places the vertex at Mixamo bone's position + local offset.
		# Since Mixamo has proper humanoid proportions, vertices end up
		# at correct world positions.
		skin.add_bind(mixamo_idx, mw_inv_bind)

	return skin


## Create a MeshInstance3D with proper skeleton binding
static func create_mesh_instance(
	result: RebindResult,
	skeleton: Skeleton3D,
	material: Material = null
) -> MeshInstance3D:
	if not result.success:
		push_error("SkinRebinder: Cannot create MeshInstance from failed result: %s" % result.error)
		return null

	var instance := MeshInstance3D.new()
	instance.mesh = result.mesh

	if result.skin:
		instance.skin = result.skin
		instance.skeleton = NodePath("..")  # Parent is skeleton

	if material:
		instance.material_override = material
	elif result.mesh.get_surface_count() > 0:
		# Try to create material from texture path
		var tex_path: String = result.mesh.get_meta("texture_path", "")
		if not tex_path.is_empty():
			var mat := _create_material_from_texture(tex_path)
			if mat:
				result.mesh.surface_set_material(0, mat)

	return instance


## Create material from texture path
static func _create_material_from_texture(texture_path: String) -> StandardMaterial3D:
	# Normalize path
	var path := texture_path.to_lower().replace("\\", "/")
	if not path.begins_with("textures/"):
		path = "textures/" + path

	# Try to load texture from BSA
	var texture: Texture2D = null

	# Use TextureLoader if available
	var tex_loader: GDScript = load("res://src/core/texture/texture_loader.gd") as GDScript
	if tex_loader:
		var loader: RefCounted = tex_loader.new()
		texture = loader.call("load_texture", path)

	if not texture:
		return null

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = texture
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	return mat


## Batch rebind multiple meshes
static func rebind_multiple(
	mesh_datas: Array[MeshExtractor.MeshData],
	mixamo_skeleton: Skeleton3D
) -> Array[RebindResult]:
	var results: Array[RebindResult] = []

	for mesh_data in mesh_datas:
		results.append(rebind(mesh_data, mixamo_skeleton))

	return results


## Debug: Print bone mapping for a mesh
static func print_bone_mapping(
	morrowind_bones: PackedStringArray,
	mixamo_skeleton: Skeleton3D
) -> void:
	var lines := PackedStringArray()
	lines.append("=== Bone Mapping Debug ===")
	lines.append("Morrowind bones: %d" % morrowind_bones.size())

	var mapped := 0
	var unmapped := 0

	for i in morrowind_bones.size():
		var mw_name := morrowind_bones[i]
		var mixamo_name := BoneMapper.to_mixamo(mw_name)

		if mixamo_name.is_empty():
			lines.append("  [UNMAPPED] %s -> ?" % mw_name)
			unmapped += 1
			continue

		var mixamo_idx := mixamo_skeleton.find_bone(mixamo_name)
		if mixamo_idx < 0:
			lines.append("  [NOT FOUND] %s -> %s (not in skeleton)" % [mw_name, mixamo_name])
			unmapped += 1
			continue

		lines.append("  [OK] %s -> %s (idx %d)" % [mw_name, mixamo_name, mixamo_idx])
		mapped += 1

	lines.append("Mapped: %d, Unmapped: %d" % [mapped, unmapped])
	Log.debug("character", "\n".join(lines))


## Clear cached Morrowind skeleton data (for memory management)
static func clear_mw_skeleton_cache() -> void:
	_mw_bone_transforms.clear()
	_mw_skeleton_loaded = false


## Debug: Print Morrowind skeleton bone transforms
static func print_mw_skeleton_debug() -> void:
	_ensure_mw_skeleton_loaded()
	var lines := PackedStringArray()
	lines.append("=== Morrowind Skeleton Bones ===")
	lines.append("Total bones: %d" % _mw_bone_transforms.size())

	var bones := _mw_bone_transforms.keys()
	bones.sort()

	for bone_name in bones:
		var transform: Transform3D = _mw_bone_transforms[bone_name]
		lines.append("  %s: pos=%s" % [bone_name, transform.origin])
	Log.debug("character", "\n".join(lines))
