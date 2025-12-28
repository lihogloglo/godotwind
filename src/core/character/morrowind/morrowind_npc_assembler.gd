## Morrowind NPC Assembler - High-level NPC assembly with Mixamo skeleton
## Assembles Morrowind body parts onto a Mixamo skeleton for modern animation support
##
## KEY DESIGN:
## - Uses Mixamo skeleton (not Morrowind skeleton) for animation compatibility
## - Body parts are extracted from NIF files with their skinning data
## - Meshes are rebound from Morrowind bones to Mixamo bones
## - Original Morrowind inverse bind matrices are used (they define bone-local vertex positions)
class_name MorrowindNPCAssembler
extends RefCounted

# Mixamo components
const MixamoSkeletonTemplate := preload("res://src/core/character/mixamo/mixamo_skeleton_template.gd")
const BoneMapper := preload("res://src/core/character/mixamo/bone_mapper.gd")
const MeshExtractor := preload("res://src/core/character/mixamo/mesh_extractor.gd")

# Game layer components
const BodyPartSlots := preload("res://src/core/character/morrowind/morrowind_body_part_slots.gd")

# Coordinate system
const CS := preload("res://src/core/coordinate_system.gd")


## Cached skeleton templates: { "type" -> Skeleton3D }
static var _skeleton_cache: Dictionary = {}

## Cached body part mesh data: { "model_path" -> Array[MeshExtractor.MeshData] }
static var _body_part_cache: Dictionary = {}

## Debug mode
static var debug_mode: bool = false


## Body part data container (simplified, holds extracted mesh data)
class BodyPartData:
	var meshes: Array  # Array of MeshExtractor.MeshData
	var model_path: String

	static func from_meshes(p_meshes: Array, path: String) -> BodyPartData:
		var data := BodyPartData.new()
		data.meshes = p_meshes
		data.model_path = path
		return data


## Assemble a complete NPC from records using Mixamo skeleton
## Returns a Node3D with Skeleton3D and all body parts attached
static func assemble(npc_record, race_record) -> Node3D:
	var root := Node3D.new()
	root.name = npc_record.name if npc_record.name else npc_record.id if "id" in npc_record else "NPC"

	# Determine character type
	var is_female: bool = npc_record.is_female() if npc_record.has_method("is_female") else false
	var is_beast: bool = race_record.is_beast() if race_record.has_method("is_beast") else false

	# Create Mixamo skeleton (NOT Morrowind skeleton)
	var skeleton := _get_mixamo_skeleton(is_beast)
	if skeleton == null:
		push_error("MorrowindNPCAssembler: Failed to create Mixamo skeleton")
		return root

	skeleton.name = "Skeleton3D"
	root.add_child(skeleton)

	# Create AnimationPlayer for the skeleton
	var anim_player := AnimationPlayer.new()
	anim_player.name = "AnimationPlayer"
	skeleton.add_child(anim_player)

	# Collect body parts for this NPC
	var body_parts := _collect_body_parts(npc_record, race_record, is_female)

	if debug_mode:
		print("MorrowindNPCAssembler: Collected %d body parts for %s" % [body_parts.size(), root.name])

	# Attach each body part with rebinding to Mixamo skeleton
	for slot in body_parts:
		var part_data: BodyPartData = body_parts[slot]
		_attach_body_part_mixamo(skeleton, slot, part_data)

	if debug_mode:
		print("MorrowindNPCAssembler: Assembled NPC with %d meshes" % _count_mesh_instances(skeleton))

	return root


## Get or create a Mixamo skeleton
static func _get_mixamo_skeleton(is_beast: bool) -> Skeleton3D:
	var key := "beast" if is_beast else "humanoid"

	if key in _skeleton_cache:
		return _duplicate_skeleton(_skeleton_cache[key])

	# Create from Mixamo template
	var skeleton_type := MixamoSkeletonTemplate.SkeletonType.BEAST if is_beast else MixamoSkeletonTemplate.SkeletonType.FULL
	var template := MixamoSkeletonTemplate.create(skeleton_type)

	if template:
		_skeleton_cache[key] = template
		return _duplicate_skeleton(template)

	return null


## Duplicate a skeleton
static func _duplicate_skeleton(source: Skeleton3D) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.name = source.name

	for i in source.get_bone_count():
		skeleton.add_bone(source.get_bone_name(i))

	for i in source.get_bone_count():
		var parent_idx := source.get_bone_parent(i)
		if parent_idx >= 0:
			skeleton.set_bone_parent(i, parent_idx)
		skeleton.set_bone_rest(i, source.get_bone_rest(i))

	skeleton.reset_bone_poses()
	return skeleton


## Collect all body parts for an NPC
static func _collect_body_parts(npc_record, race_record, is_female: bool) -> Dictionary:
	var parts: Dictionary = {}

	# Get ESMManager autoload
	var esm_mgr: Node = _get_esm_manager()
	if esm_mgr == null:
		push_warning("MorrowindNPCAssembler: ESMManager not available")
		return parts

	# Get race body parts from ESM
	if esm_mgr.has_method("get_body_parts_for_race"):
		var race_parts: Array = esm_mgr.get_body_parts_for_race(race_record.record_id, is_female)
		for part in race_parts:
			var slots := BodyPartSlots.part_type_to_slots(part.part_type)
			for slot in slots:
				var part_data := _load_body_part(part.model)
				if part_data:
					parts[slot] = part_data

	# Override with NPC-specific head/hair if set
	if npc_record.head_id and esm_mgr.has_method("get_body_part"):
		var head_part = esm_mgr.get_body_part(npc_record.head_id)
		if head_part:
			var head_data := _load_body_part(head_part.model)
			if head_data:
				parts[BodyPartSlots.Slot.HEAD] = head_data

	if npc_record.hair_id and esm_mgr.has_method("get_body_part"):
		var hair_part = esm_mgr.get_body_part(npc_record.hair_id)
		if hair_part:
			var hair_data := _load_body_part(hair_part.model)
			if hair_data:
				parts[BodyPartSlots.Slot.HAIR] = hair_data

	return parts


## Get ESMManager autoload
static func _get_esm_manager() -> Node:
	var main_loop := Engine.get_main_loop() as SceneTree
	if main_loop and main_loop.root:
		return main_loop.root.get_node_or_null("/root/ESMManager")
	return null


## Get BSAManager autoload
static func _get_bsa_manager() -> Node:
	var main_loop := Engine.get_main_loop() as SceneTree
	if main_loop and main_loop.root:
		return main_loop.root.get_node_or_null("/root/BSAManager")
	return null


## Load a body part using MeshExtractor
static func _load_body_part(model_path: String) -> BodyPartData:
	if model_path.is_empty():
		return null

	# Normalize path
	var path := model_path.to_lower().replace("\\", "/")
	if not path.begins_with("meshes/"):
		path = "meshes/" + path

	# Check cache
	if path in _body_part_cache:
		return _body_part_cache[path]

	# Extract mesh data using MeshExtractor (handles BSA loading internally)
	var meshes := MeshExtractor.extract_from_bsa(path)

	if meshes.is_empty():
		push_warning("MorrowindNPCAssembler: No meshes extracted from: %s" % path)
		return null

	var part_data := BodyPartData.from_meshes(meshes, path)

	# Cache it
	_body_part_cache[path] = part_data

	return part_data


## Attach a body part to the Mixamo skeleton with proper rebinding
static func _attach_body_part_mixamo(skeleton: Skeleton3D, slot: int, part_data: BodyPartData) -> void:
	for mesh_data in part_data.meshes:
		var extracted: MeshExtractor.MeshData = mesh_data

		if extracted.is_skinned:
			# Create skinned mesh with rebinding to Mixamo
			_attach_skinned_mesh_mixamo(skeleton, extracted, slot)
		else:
			# Static mesh - attach to appropriate bone
			_attach_static_mesh(skeleton, extracted, slot)


## Attach a skinned mesh rebound to Mixamo skeleton
##
## GPU SKINNING MATH:
## Godot computes: vertex' = bone_global_pose × skin_bind × vertex
##
## The key insight is that the Skin resource stores the BIND POSE transform,
## which is the INVERSE of the inverse bind matrix.
##
## For correct rebinding from Morrowind to Mixamo:
## 1. Original MW formula: vertex' = MW_bone_global × MW_inv_bind × vertex
## 2. We want: vertex' = Mixamo_bone_global × new_bind × vertex
##
## The new_bind should position vertices correctly when Mixamo is at rest pose.
## Since MW vertices are already in meters (converted by MeshExtractor),
## we compute: new_inv_bind = Mixamo_bone_global_rest.inverse()
##
## This makes vertices appear at (Mixamo_pose × Mixamo_rest.inverse() × vertex)
## = vertex when Mixamo is at rest, but animated when bones move.
static func _attach_skinned_mesh_mixamo(skeleton: Skeleton3D, mesh_data: MeshExtractor.MeshData, slot: int) -> void:
	# Build bone index mapping: Morrowind bone index -> Mixamo bone index
	var bone_map: Dictionary = {}  # mw_idx -> mixamo_idx
	var unmapped_bones: PackedStringArray = PackedStringArray()

	for i in mesh_data.bone_names.size():
		var mw_name := mesh_data.bone_names[i]
		var mixamo_name := BoneMapper.to_mixamo(mw_name)

		if mixamo_name.is_empty():
			unmapped_bones.append(mw_name)
			# Map to hips as fallback
			bone_map[i] = skeleton.find_bone("mixamorig1_Hips")
			if bone_map[i] < 0:
				bone_map[i] = 0
			continue

		var mixamo_idx := skeleton.find_bone(mixamo_name)
		if mixamo_idx < 0:
			unmapped_bones.append(mw_name + " -> " + mixamo_name + " (not found)")
			bone_map[i] = 0
			continue

		bone_map[i] = mixamo_idx

	if debug_mode and not unmapped_bones.is_empty():
		print("MorrowindNPCAssembler: Unmapped bones: %s" % str(unmapped_bones))

	# Create mesh arrays with remapped bone indices
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

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

		for j in 4:
			var old_idx: int = old_indices[j]
			var new_idx: int = bone_map.get(old_idx, 0)
			bones.append(new_idx)
			weights.append(vert_weights[j])

	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights

	# Create ArrayMesh
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Create Skin resource with proper inverse bind matrices for Mixamo
	#
	# The vertices are already in Godot world space (converted from MW by MeshExtractor).
	# For skinning to work, we need inv_bind such that:
	#   bone_global_rest × inv_bind × vertex = vertex (at rest pose)
	#
	# Therefore: inv_bind = bone_global_rest.inverse()
	#
	# This way, when Mixamo animates, vertices follow the bones correctly.
	var skin := Skin.new()
	var added_bones: Dictionary = {}  # Track which mixamo bones we've added

	for i in mesh_data.bone_names.size():
		var mixamo_idx: int = bone_map.get(i, -1)
		if mixamo_idx < 0:
			continue

		# Skip duplicates (same Mixamo bone mapped from multiple MW bones)
		if mixamo_idx in added_bones:
			continue
		added_bones[mixamo_idx] = true

		# Compute global rest pose for this Mixamo bone
		var bone_global_rest := _get_bone_global_rest(skeleton, mixamo_idx)

		# The inverse bind matrix transforms vertices from world space to bone-local space
		var inv_bind := bone_global_rest.affine_inverse()

		# Add bind to skin
		skin.add_bind(mixamo_idx, inv_bind)

	# Create MeshInstance3D
	var instance := MeshInstance3D.new()
	instance.name = "BodyPart_%s" % BodyPartSlots.slot_name(slot)
	instance.mesh = array_mesh
	instance.skin = skin
	instance.skeleton = NodePath("..")  # Parent is skeleton

	# Apply material if texture available
	if not mesh_data.texture_path.is_empty():
		var material := _create_material(mesh_data.texture_path, mesh_data.material_properties)
		if material:
			array_mesh.surface_set_material(0, material)

	skeleton.add_child(instance)


## Get the global rest transform for a bone (accumulates parent transforms)
static func _get_bone_global_rest(skeleton: Skeleton3D, bone_idx: int) -> Transform3D:
	var global_rest := Transform3D.IDENTITY

	var current_idx := bone_idx
	while current_idx >= 0:
		var local_rest := skeleton.get_bone_rest(current_idx)
		global_rest = local_rest * global_rest
		current_idx = skeleton.get_bone_parent(current_idx)

	return global_rest


## Attach a static (non-skinned) mesh to appropriate bone
static func _attach_static_mesh(skeleton: Skeleton3D, mesh_data: MeshExtractor.MeshData, slot: int) -> void:
	# Get the Mixamo bone for this slot
	var mw_bone := BodyPartSlots.get_bone(slot)
	var mixamo_bone := BoneMapper.to_mixamo(mw_bone)

	if mixamo_bone.is_empty():
		push_warning("MorrowindNPCAssembler: No Mixamo bone for slot %s" % BodyPartSlots.slot_name(slot))
		return

	var bone_idx := skeleton.find_bone(mixamo_bone)
	if bone_idx < 0:
		push_warning("MorrowindNPCAssembler: Bone %s not found in skeleton" % mixamo_bone)
		return

	# Create BoneAttachment3D
	var attachment := BoneAttachment3D.new()
	attachment.name = "Attach_%s" % BodyPartSlots.slot_name(slot)
	attachment.bone_name = mixamo_bone
	attachment.bone_idx = bone_idx

	# Create mesh
	var array_mesh := MeshExtractor.create_array_mesh(mesh_data)

	var instance := MeshInstance3D.new()
	instance.name = "Static_%s" % BodyPartSlots.slot_name(slot)
	instance.mesh = array_mesh

	# Apply material
	if not mesh_data.texture_path.is_empty():
		var material := _create_material(mesh_data.texture_path, mesh_data.material_properties)
		if material:
			array_mesh.surface_set_material(0, material)

	attachment.add_child(instance)
	skeleton.add_child(attachment)


## Create a material from texture path
static func _create_material(texture_path: String, properties: Dictionary) -> StandardMaterial3D:
	# Normalize path
	var path := texture_path.to_lower().replace("\\", "/")
	if not path.begins_with("textures/"):
		path = "textures/" + path

	# Change extension to .dds (Morrowind textures)
	if path.ends_with(".tga"):
		path = path.replace(".tga", ".dds")

	# Try to load texture
	var texture: Texture2D = null

	# Use TextureLoader if available
	var tex_loader_script: GDScript = load("res://src/core/texture/texture_loader.gd") as GDScript
	if tex_loader_script:
		var loader: RefCounted = tex_loader_script.new()
		if loader.has_method("load_texture"):
			texture = loader.call("load_texture", path)

	if not texture:
		return null

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = texture
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	# Apply material properties if available
	if not properties.is_empty():
		if "alpha" in properties and properties["alpha"] < 1.0:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	return mat


## Count mesh instances under a node
static func _count_mesh_instances(node: Node) -> int:
	var count := 0
	if node is MeshInstance3D:
		count += 1
	for child in node.get_children():
		count += _count_mesh_instances(child)
	return count


## Clear all caches (for memory management)
static func clear_caches() -> void:
	_skeleton_cache.clear()
	_body_part_cache.clear()


## Preload skeleton for a race/gender (call during loading screen)
static func preload_skeleton(is_female: bool, is_beast: bool) -> void:
	var _skel := _get_mixamo_skeleton(is_beast)


## Get cache statistics
static func get_cache_stats() -> Dictionary:
	return {
		"skeletons": _skeleton_cache.size(),
		"body_parts": _body_part_cache.size()
	}
