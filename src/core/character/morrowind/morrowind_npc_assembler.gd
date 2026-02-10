## Morrowind NPC Assembler - High-level NPC assembly with native skeleton
## Assembles Morrowind body parts onto the native Morrowind skeleton.
##
## KEY DESIGN:
## - Uses native Morrowind skeleton (from xbase_anim.nif), NOT Mixamo
## - Body parts attach directly — bone names and skinning data match
## - No skin rebinding needed (bones are native Bip01)
## - Bone renaming to profile names happens later in CharacterFactoryV2
class_name MorrowindNPCAssembler
extends RefCounted

# NIF conversion for loading skeleton from xbase_anim.nif
const NIFConverter := preload("res://src/core/nif/nif_converter.gd")
const MeshExtractor := preload("res://src/core/character/mixamo/mesh_extractor.gd")
const NIFReader := preload("res://src/core/nif/nif_reader.gd")
const NIFDefs := preload("res://src/core/nif/nif_defs.gd")
const CS := preload("res://src/core/coordinate_system.gd")

# Game layer components
const BodyPartSlots := preload("res://src/core/character/morrowind/morrowind_body_part_slots.gd")


## Cached skeleton templates: { "type" -> Skeleton3D }
static var _skeleton_cache: Dictionary = {}

## Cached body part mesh data: { "model_path" -> Array[MeshExtractor.MeshData] }
static var _body_part_cache: Dictionary = {}

## Cached attachment node transforms: { "type" -> { "name_lower" -> Transform3D } }
static var _attachment_cache: Dictionary = {}

## Debug mode
static var debug_mode: bool = false

## Slot -> OpenMW attachment node name (lowercase) in xbase_anim.nif
const SLOT_TO_ATTACHMENT_NAME := {
	BodyPartSlots.Slot.HEAD: "head",
	BodyPartSlots.Slot.HAIR: "head",
	BodyPartSlots.Slot.NECK: "neck",
	BodyPartSlots.Slot.CHEST: "chest",
	BodyPartSlots.Slot.GROIN: "groin",
	BodyPartSlots.Slot.SKIRT: "groin",
	BodyPartSlots.Slot.HAND_R: "right hand",
	BodyPartSlots.Slot.HAND_L: "left hand",
	BodyPartSlots.Slot.WRIST_R: "right wrist",
	BodyPartSlots.Slot.WRIST_L: "left wrist",
	BodyPartSlots.Slot.FOREARM_R: "right forearm",
	BodyPartSlots.Slot.FOREARM_L: "left forearm",
	BodyPartSlots.Slot.UPPER_ARM_R: "right upper arm",
	BodyPartSlots.Slot.UPPER_ARM_L: "left upper arm",
	BodyPartSlots.Slot.FOOT_R: "right foot",
	BodyPartSlots.Slot.FOOT_L: "left foot",
	BodyPartSlots.Slot.ANKLE_R: "right ankle",
	BodyPartSlots.Slot.ANKLE_L: "left ankle",
	BodyPartSlots.Slot.KNEE_R: "right knee",
	BodyPartSlots.Slot.KNEE_L: "left knee",
	BodyPartSlots.Slot.UPPER_LEG_R: "right upper leg",
	BodyPartSlots.Slot.UPPER_LEG_L: "left upper leg",
	BodyPartSlots.Slot.CLAVICLE_R: "right clavicle",
	BodyPartSlots.Slot.CLAVICLE_L: "left clavicle",
	BodyPartSlots.Slot.WEAPON: "weapon bone",
	BodyPartSlots.Slot.SHIELD: "shield bone",
	BodyPartSlots.Slot.TAIL: "tail",
}

## Known attachment node names from xbase_anim.nif
const ATTACHMENT_NODE_NAMES := [
	"head", "neck", "chest", "groin",
	"right hand", "left hand", "right wrist", "left wrist",
	"right forearm", "left forearm", "right upper arm", "left upper arm",
	"right foot", "left foot", "right ankle", "left ankle",
	"right knee", "left knee", "right upper leg", "left upper leg",
	"right clavicle", "left clavicle", "weapon bone", "shield bone", "tail",
]


## Body part data container (simplified, holds extracted mesh data)
class BodyPartData:
	var meshes: Array  # Array of MeshExtractor.MeshData
	var model_path: String

	static func from_meshes(p_meshes: Array, path: String) -> BodyPartData:
		var data := BodyPartData.new()
		data.meshes = p_meshes
		data.model_path = path
		return data


## Assemble a complete NPC from records using native Morrowind skeleton
## Returns a Node3D with Skeleton3D and all body parts attached
static func assemble(npc_record, race_record) -> Node3D:
	var root := Node3D.new()
	root.name = npc_record.name if npc_record.name else npc_record.id if "id" in npc_record else "NPC"

	# Determine character type
	var is_female: bool = npc_record.is_female() if npc_record.has_method("is_female") else false
	var is_beast: bool = race_record.is_beast() if race_record.has_method("is_beast") else false

	# Create native Morrowind skeleton (from xbase_anim.nif)
	var skeleton := _get_morrowind_skeleton(is_beast)
	if skeleton == null:
		push_error("MorrowindNPCAssembler: Failed to create Morrowind skeleton")
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
		Log.info("character", "Collected %d body parts for %s" % [body_parts.size(), root.name])

	# Attach each body part directly (no rebinding — bones match)
	for slot in body_parts:
		var part_data: BodyPartData = body_parts[slot]
		_attach_body_part_native(skeleton, slot, part_data, is_beast)

	if debug_mode:
		Log.info("character", "Assembled NPC with %d meshes on native skeleton (%d bones)" % [
			_count_mesh_instances(skeleton), skeleton.get_bone_count()])

	return root


# =============================================================================
# SKELETON CREATION
# =============================================================================

## Get or create a native Morrowind skeleton
## Humanoid (male & female share same skeleton) or beast (Khajiit/Argonian)
static func _get_morrowind_skeleton(is_beast: bool) -> Skeleton3D:
	var key := "beast" if is_beast else "humanoid"

	if key in _skeleton_cache:
		return _duplicate_skeleton(_skeleton_cache[key])

	# Load from xbase_anim.nif (humanoid) or xbase_animkna.nif (beast)
	var nif_path := "meshes\\xbase_animkna.nif" if is_beast else "meshes\\xbase_anim.nif"
	var skeleton := _load_skeleton_from_nif(nif_path)

	if skeleton:
		_skeleton_cache[key] = skeleton
		if debug_mode:
			Log.info("character", "Cached %s skeleton: %d bones from %s" % [
				key, skeleton.get_bone_count(), nif_path])
		return _duplicate_skeleton(skeleton)

	return null


## Load a Skeleton3D from a NIF file (xbase_anim.nif hierarchy)
static func _load_skeleton_from_nif(nif_path: String) -> Skeleton3D:
	var bsa_mgr := _get_bsa_manager()
	if not bsa_mgr:
		push_error("MorrowindNPCAssembler: BSAManager not available")
		return null

	var data: PackedByteArray = bsa_mgr.extract_file(nif_path)
	if data.is_empty():
		push_error("MorrowindNPCAssembler: Cannot load skeleton NIF: %s" % nif_path)
		return null

	# Use NIFConverter to parse the NIF and build skeleton from bone hierarchy
	var converter := NIFConverter.new()
	converter.load_textures = false
	converter.load_animations = false
	converter.load_collision = false

	# convert_buffer initializes the reader and skeleton builder
	var scene := converter.convert_buffer(data, nif_path)

	# Build skeleton from the NiNode hierarchy (xbase_anim.nif is skeleton-only)
	var skeleton := converter.create_skeleton_from_hierarchy()

	# Clean up the temporary scene
	if scene:
		scene.queue_free()

	if not skeleton:
		push_error("MorrowindNPCAssembler: No skeleton built from: %s" % nif_path)

	return skeleton


## Duplicate a skeleton (for instancing from cache)
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


# =============================================================================
# BODY PART ATTACHMENT (NATIVE — NO REBINDING)
# =============================================================================

## Attach a body part directly to the native skeleton
static func _attach_body_part_native(skeleton: Skeleton3D, slot: int, part_data: BodyPartData, is_beast: bool) -> void:
	var is_mirrored: bool = BodyPartSlots.is_left_side(slot)
	var is_limb_slot: bool = BodyPartSlots.is_limb_slot(slot)

	# For non-limb slots (CHEST, GROIN, etc.), check if ANY sub-mesh from this NIF
	# qualifies as full-body skin (many bones). If so, ALL skinned sub-meshes should
	# use the skinned path — their node_transform is in skeleton-root space and would
	# produce incorrect positioning via the static path.
	var has_full_body_mesh: bool = false
	if not is_limb_slot:
		for md in part_data.meshes:
			if md.is_skinned and md.bone_names.size() > 4:
				has_full_body_mesh = true
				break

	for mesh_data in part_data.meshes:
		var extracted: MeshExtractor.MeshData = mesh_data

		# Route decision (matching OpenMW's two-path system):
		# 1. Limb slots → ALWAYS static (per OpenMW: individual limb NIFs have
		#    non-Skeleton root, so they go through Path B regardless of skin data)
		# 2. Non-limb slots with full-body NIF → ALL skinned sub-meshes go through
		#    the skinned path (even those with <=4 bones). Their transforms are in
		#    skeleton-root space and must be resolved by the skinning pipeline.
		# 3. Non-limb slots without full-body NIF → standard bone count heuristic
		var is_full_body_skin: bool = false
		if not is_limb_slot:
			if has_full_body_mesh and extracted.is_skinned:
				is_full_body_skin = true
			elif extracted.is_skinned and extracted.bone_names.size() > 4:
				is_full_body_skin = true

		if debug_mode:
			Log.info("character", "  [%s] mesh: %d verts, %d bones, skinned=%s, route=%s" % [
				BodyPartSlots.slot_name(slot),
				extracted.vertices.size(),
				extracted.bone_names.size(),
				str(extracted.is_skinned),
				"SKINNED" if is_full_body_skin else "STATIC"])

		if is_full_body_skin:
			if is_mirrored:
				_attach_skinned_mesh_mirrored(skeleton, extracted, slot)
			else:
				_attach_skinned_mesh_native(skeleton, extracted, slot)
		else:
			_attach_static_mesh(skeleton, extracted, slot, is_beast)


## Attach a skinned mesh directly to the native Morrowind skeleton
##
## No rebinding needed — mesh bone names already match the skeleton.
## We create a Skin resource that maps mesh-local bone indices to skeleton
## bone indices, using the original Morrowind inverse bind matrices.
static func _attach_skinned_mesh_native(skeleton: Skeleton3D, mesh_data: MeshExtractor.MeshData, slot: int) -> void:
	# Create the ArrayMesh with skinning data
	var array_mesh := MeshExtractor.create_array_mesh(mesh_data)

	# Create Skin mapping mesh bone indices → skeleton bone indices
	var skin := _create_native_skin(mesh_data, skeleton)
	if not skin:
		push_warning("MorrowindNPCAssembler: Failed to create skin for slot %s" % BodyPartSlots.slot_name(slot))
		return

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


## Attach a MIRRORED skinned mesh for left-side body parts.
##
## Morrowind individual limb parts (hand, foot, etc.) only have right-side
## geometry. For left-side slots we mirror the mesh data:
##   - Vertex X positions negated
##   - Normal X components negated
##   - Triangle winding reversed
##   - Bone names remapped from right → left equivalents
##   - Inverse bind matrices computed from skeleton rest poses (for left bones)
static func _attach_skinned_mesh_mirrored(skeleton: Skeleton3D, mesh_data: MeshExtractor.MeshData, slot: int) -> void:
	# Build mirrored arrays
	var mirrored_verts := PackedVector3Array()
	mirrored_verts.resize(mesh_data.vertices.size())
	for i in mesh_data.vertices.size():
		var v := mesh_data.vertices[i]
		mirrored_verts[i] = Vector3(-v.x, v.y, v.z)

	var mirrored_normals := PackedVector3Array()
	if not mesh_data.normals.is_empty():
		mirrored_normals.resize(mesh_data.normals.size())
		for i in mesh_data.normals.size():
			var n := mesh_data.normals[i]
			mirrored_normals[i] = Vector3(-n.x, n.y, n.z)

	var mirrored_indices := PackedInt32Array()
	mirrored_indices.resize(mesh_data.indices.size())
	for i in range(0, mesh_data.indices.size(), 3):
		mirrored_indices[i] = mesh_data.indices[i]
		mirrored_indices[i + 1] = mesh_data.indices[i + 2]
		mirrored_indices[i + 2] = mesh_data.indices[i + 1]

	# Build mesh arrays
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = mirrored_verts
	if not mirrored_normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = mirrored_normals
	if not mesh_data.uvs.is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = mesh_data.uvs
	arrays[Mesh.ARRAY_INDEX] = mirrored_indices

	# Remap bone names (right → left) and build skinning data
	var remapped_bone_names := PackedStringArray()
	for bone_name in mesh_data.bone_names:
		remapped_bone_names.append(_mirror_bone_name(bone_name))

	# Build bone indices/weights for the mesh
	if mesh_data.is_skinned:
		var bones := PackedInt32Array()
		var weights := PackedFloat32Array()
		for i in mesh_data.vertices.size():
			var bi: PackedInt32Array = mesh_data.bone_indices[i]
			var bw: PackedFloat32Array = mesh_data.bone_weights[i]
			bones.append_array(bi)
			weights.append_array(bw)
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = weights

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Create Skin with left-side bone indices using mirrored NIF bind data.
	# Right side uses: bind = nif_inv_bind * skin_transform
	# Left side (vertices X-flipped): bind = mirror * nif_inv_bind * skin_transform * mirror
	var skin := Skin.new()
	var has_nif_binds: bool = mesh_data.inv_bind_poses.size() == mesh_data.bone_names.size()
	var mirror_basis := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
	var mirror_xf := Transform3D(mirror_basis, Vector3.ZERO)

	# Find a valid fallback bone (first bone that exists in skeleton)
	var mirrored_fallback := 0
	for i in remapped_bone_names.size():
		var idx := _find_bone_ci(skeleton, remapped_bone_names[i])
		if idx >= 0:
			mirrored_fallback = idx
			break

	for i in remapped_bone_names.size():
		var bone_name: String = remapped_bone_names[i]
		var bone_idx := _find_bone_ci(skeleton, bone_name)
		if bone_idx < 0:
			bone_idx = mirrored_fallback  # use first valid bone, not root

		var inv_bind: Transform3D
		if has_nif_binds:
			# Mirror the right-side NIF inverse bind and compose with skin_transform
			inv_bind = mirror_xf * mesh_data.inv_bind_poses[i] * mesh_data.skin_transform * mirror_xf
		else:
			# Fallback: compute from skeleton rest poses (no skin_transform available)
			inv_bind = skeleton.get_bone_global_rest(bone_idx).affine_inverse()

		skin.add_bind(bone_idx, inv_bind)

	# Create MeshInstance3D
	var instance := MeshInstance3D.new()
	instance.name = "BodyPart_%s" % BodyPartSlots.slot_name(slot)
	instance.mesh = array_mesh
	instance.skin = skin
	instance.skeleton = NodePath("..")

	# Apply material
	if not mesh_data.texture_path.is_empty():
		var material := _create_material(mesh_data.texture_path, mesh_data.material_properties)
		if material:
			array_mesh.surface_set_material(0, material)

	skeleton.add_child(instance)


## Create a Skin resource for native skeleton attachment
##
## Maps each mesh bone (by name) to the matching skeleton bone index.
## Uses NIF's own inverse bind matrices composed with skin_transform for accuracy.
## Falls back to skeleton rest poses when NIF data is unavailable.
static func _create_native_skin(mesh_data: MeshExtractor.MeshData, skeleton: Skeleton3D) -> Skin:
	if mesh_data.bone_names.is_empty():
		return null

	var skin := Skin.new()
	var unmapped := PackedStringArray()
	var has_nif_binds: bool = mesh_data.inv_bind_poses.size() == mesh_data.bone_names.size()

	# First pass: find a valid fallback bone (first bone that exists in skeleton)
	var fallback_bone_idx := 0
	for i in mesh_data.bone_names.size():
		var idx := _find_bone_ci(skeleton, mesh_data.bone_names[i])
		if idx >= 0:
			fallback_bone_idx = idx
			break

	for i in mesh_data.bone_names.size():
		var bone_name: String = mesh_data.bone_names[i]

		var bone_idx := _find_bone_ci(skeleton, bone_name)

		if bone_idx < 0:
			unmapped.append(bone_name)
			bone_idx = fallback_bone_idx  # use first valid bone, not root

		var inv_bind: Transform3D
		if has_nif_binds:
			# Use NIF's per-bone inverse bind composed with skin_transform
			# full_inv_bind = per_bone_inv_bind * skin_transform
			# skin_transform converts mesh space → skeleton root space
			inv_bind = mesh_data.inv_bind_poses[i] * mesh_data.skin_transform
		else:
			# Fallback: compute from skeleton rest poses
			inv_bind = skeleton.get_bone_global_rest(bone_idx).affine_inverse()

		skin.add_bind(bone_idx, inv_bind)

	if not unmapped.is_empty():
		Log.warn("character", "Native skin unmapped bones (fell back to '%s'): %s" % [
			skeleton.get_bone_name(fallback_bone_idx), str(unmapped)])

	return skin


## Attach a static (non-skinned) mesh to a bone via BoneAttachment3D.
##
## Right side: mesh as-is, positioned by attachment_transform * node_transform.
## Left side: FULL MESH-SPACE MIRROR — vertex X, normal X, winding all flipped
## in mesh data. Transform has NO negative scale (avoids MODEL_NORMAL_MATRIX ambiguity).
## This is the same strategy as _attach_skinned_mesh_mirrored().
static func _attach_static_mesh(skeleton: Skeleton3D, mesh_data: MeshExtractor.MeshData, slot: int, is_beast: bool = false) -> void:
	var is_mirrored: bool = BodyPartSlots.is_left_side(slot)

	var array_mesh: ArrayMesh
	if is_mirrored:
		array_mesh = _create_mirrored_mesh(mesh_data)
	else:
		array_mesh = MeshExtractor.create_array_mesh(mesh_data)

	var instance := MeshInstance3D.new()
	instance.name = "Static_%s" % BodyPartSlots.slot_name(slot)
	instance.mesh = array_mesh

	if not mesh_data.texture_path.is_empty():
		var material := _create_material(mesh_data.texture_path, mesh_data.material_properties)
		if material:
			array_mesh.surface_set_material(0, material)

	# Find bone
	var bone_name := BodyPartSlots.get_bone(slot)
	var bone_idx := _find_bone_ci(skeleton, bone_name) if not bone_name.is_empty() else -1
	if bone_idx < 0 and not mesh_data.parent_bone_name.is_empty():
		bone_idx = _find_bone_ci(skeleton, mesh_data.parent_bone_name)

	if bone_idx >= 0:
		# Compute instance transform
		var attach_name: String = SLOT_TO_ATTACHMENT_NAME.get(slot, "")
		var attachment_transforms := _get_attachment_transforms(is_beast)

		if is_mirrored:
			# Mesh vertices/normals are already X-flipped. We need the transform to
			# position the mirrored mesh correctly WITHOUT negative scale.
			# Derivation: right_att * mirror * node_xf * vertex
			#           = right_att * (mirror * node_xf * mirror) * mirrored_vertex
			# So T = right_att * bone_offset * conjugate(node_xf, mirror)
			# where conjugate flips the origin X and mirrors the basis.
			var right_slot: int = BodyPartSlots.get_right_equivalent(slot)
			var right_name: String = SLOT_TO_ATTACHMENT_NAME.get(right_slot, attach_name)
			var att: Transform3D = attachment_transforms.get(right_name, Transform3D.IDENTITY)

			var M := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
			var mirrored_node := Transform3D(
				M * mesh_data.node_transform.basis * M,
				M * mesh_data.node_transform.origin
			)

			if mesh_data.has_bone_offset:
				instance.transform = att * Transform3D(Basis.IDENTITY, mesh_data.bone_offset_position) * mirrored_node
			else:
				instance.transform = att * mirrored_node
		else:
			# Right side: attachment * [bone_offset] * node_transform
			var att: Transform3D = attachment_transforms.get(attach_name, Transform3D.IDENTITY)
			if mesh_data.has_bone_offset:
				var bone_offset_xf := Transform3D(Basis.IDENTITY, mesh_data.bone_offset_position)
				instance.transform = att * bone_offset_xf * mesh_data.node_transform
			else:
				instance.transform = att * mesh_data.node_transform

		var attachment := BoneAttachment3D.new()
		attachment.name = "Attach_%s" % BodyPartSlots.slot_name(slot)
		attachment.bone_name = skeleton.get_bone_name(bone_idx)
		skeleton.add_child(attachment)
		attachment.add_child(instance)
	else:
		instance.transform = mesh_data.node_transform
		skeleton.add_child(instance)


# =============================================================================
# ATTACHMENT NODE TRANSFORMS
# =============================================================================

## Get attachment transforms for a skeleton type, loading from NIF if needed.
## Returns { "name_lower" -> Transform3D } mapping attachment node names to
## their local transforms (in Godot space) relative to parent bone.
static func _get_attachment_transforms(is_beast: bool) -> Dictionary:
	var key := "beast" if is_beast else "humanoid"

	if key in _attachment_cache:
		return _attachment_cache[key]

	var nif_path := "meshes\\xbase_animkna.nif" if is_beast else "meshes\\xbase_anim.nif"
	var transforms := _extract_attachment_transforms(nif_path)
	_attachment_cache[key] = transforms

	if debug_mode:
		Log.info("character", "Cached %d attachment transforms for %s skeleton" % [transforms.size(), key])

	return transforms


## Extract attachment node transforms from a skeleton NIF file.
static func _extract_attachment_transforms(nif_path: String) -> Dictionary:
	var result: Dictionary = {}

	var bsa_mgr := _get_bsa_manager()
	if not bsa_mgr:
		return result

	var data: PackedByteArray = bsa_mgr.extract_file(nif_path)
	if data.is_empty():
		return result

	var reader := NIFReader.new()
	var err := reader.load_buffer(data, nif_path)
	if err != OK:
		return result

	for root_idx in reader.roots:
		var root := reader.get_record(root_idx)
		if root is NIFDefs.NiNode:
			_collect_attachment_nodes(reader, root as NIFDefs.NiNode, result)

	return result


## Recursively collect named attachment nodes from NIF hierarchy.
static func _collect_attachment_nodes(reader: NIFReader, node: NIFDefs.NiNode, out: Dictionary) -> void:
	var node_name: String = node.name if node.name else ""
	var name_lower := node_name.to_lower()

	if name_lower in ATTACHMENT_NODE_NAMES:
		var local_nif := Transform3D.IDENTITY
		if node.transform:
			local_nif = node.transform.to_transform3d()
		out[name_lower] = CS.transform_to_godot(local_nif)

	for child_idx in node.children_indices:
		if child_idx < 0:
			continue
		var child := reader.get_record(child_idx)
		if child is NIFDefs.NiNode:
			_collect_attachment_nodes(reader, child as NIFDefs.NiNode, out)


# =============================================================================
# BODY PART COLLECTION
# =============================================================================

## Collect all body parts for an NPC
static func _collect_body_parts(npc_record, race_record, is_female: bool) -> Dictionary:
	var parts: Dictionary = {}

	var esm_mgr: Node = _get_esm_manager()
	if esm_mgr == null:
		push_warning("MorrowindNPCAssembler: ESMManager not available")
		return parts

	# Get race body parts from ESM
	if esm_mgr.has_method("get_body_parts_for_race"):
		var race_parts: Array = esm_mgr.get_body_parts_for_race(race_record.record_id, is_female)
		if debug_mode:
			Log.info("character", "ESM returned %d body parts for race '%s' (%s):" % [
				race_parts.size(), race_record.record_id, "female" if is_female else "male"])
		for part in race_parts:
			# Skip first-person body parts (*.1st) — they are close-up meshes
			# for the player's first-person view, NOT for third-person NPCs.
			# In Morrowind ESM, these have record IDs ending in ".1st".
			if part.record_id.to_lower().ends_with(".1st"):
				if debug_mode:
					Log.info("character", "  [SKIP] ESM part '%s' — first-person only" % part.record_id)
				continue

			var slots := BodyPartSlots.part_type_to_slots(part.part_type)
			if debug_mode:
				Log.info("character", "  ESM part '%s' type=%d model='%s' -> slots=%s" % [
					part.record_id, part.part_type, part.model, str(slots)])
			for slot in slots:
				var part_data := _load_body_part(part.model)
				if part_data:
					if debug_mode:
						var max_bones := 0
						for md in part_data.meshes:
							if md.is_skinned and md.bone_names.size() > max_bones:
								max_bones = md.bone_names.size()
						if max_bones > 0:
							Log.info("character", "    -> %d sub-meshes, max %d bones, skinned" % [
								part_data.meshes.size(), max_bones])
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

	# If a limb slot references the SAME NIF as a non-limb slot (e.g., HAND_R references
	# Skins.nif which is already loaded for CHEST), skip it. The non-limb slot renders
	# that NIF via the skinned path; having the limb slot re-render the same 7 sub-meshes
	# as static attachments on a single bone produces floating geometry.
	# We do NOT remove limb slots that reference their own dedicated NIF files.
	var non_limb_models: Dictionary = {}  # model_path -> slot
	for slot: int in parts:
		if not BodyPartSlots.is_limb_slot(slot):
			var pd: BodyPartData = parts[slot]
			non_limb_models[pd.model_path] = slot

	var duplicate_limb_slots := PackedInt32Array()
	for slot: int in parts:
		if BodyPartSlots.is_limb_slot(slot):
			var pd: BodyPartData = parts[slot]
			if pd.model_path in non_limb_models:
				duplicate_limb_slots.append(slot)
				if debug_mode:
					Log.info("character", "  Skipping limb slot %s — same NIF as %s ('%s')" % [
						BodyPartSlots.slot_name(slot),
						BodyPartSlots.slot_name(non_limb_models[pd.model_path]),
						pd.model_path])
	for slot in duplicate_limb_slots:
		parts.erase(slot)

	# Populate left-side slots from right-side parts.
	# Morrowind body parts are modeled for the RIGHT side only.
	# Left-side geometry is created by full mesh-space mirror:
	# vertex X flip + normal X flip + winding reverse (+ bone remap for skinned).
	# No transform-level scale(-1,1,1) — avoids MODEL_NORMAL_MATRIX ambiguity.
	var right_slots: Array = parts.keys().duplicate()
	for right_slot: int in right_slots:
		var left_slot: int = BodyPartSlots.get_left_equivalent(right_slot)
		if left_slot != right_slot and left_slot not in parts:
			parts[left_slot] = parts[right_slot]

	if debug_mode:
		Log.info("character", "Final slot assignment (%d slots):" % parts.size())
		for slot: int in parts:
			var pd: BodyPartData = parts[slot]
			Log.info("character", "  %s: %d meshes from '%s'" % [
				BodyPartSlots.slot_name(slot), pd.meshes.size(), pd.model_path])

	return parts


# =============================================================================
# AUTOLOAD ACCESSORS
# =============================================================================

static func _get_esm_manager() -> Node:
	var main_loop := Engine.get_main_loop() as SceneTree
	if main_loop and main_loop.root:
		return main_loop.root.get_node_or_null("/root/ESMManager")
	return null


static func _get_bsa_manager() -> Node:
	var main_loop := Engine.get_main_loop() as SceneTree
	if main_loop and main_loop.root:
		return main_loop.root.get_node_or_null("/root/BSAManager")
	return null


# =============================================================================
# BODY PART LOADING
# =============================================================================

## Load a body part using MeshExtractor
static func _load_body_part(model_path: String) -> BodyPartData:
	if model_path.is_empty():
		return null

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
	_body_part_cache[path] = part_data

	return part_data


# =============================================================================
# MATERIAL CREATION
# =============================================================================

static func _create_material(texture_path: String, properties: Dictionary) -> StandardMaterial3D:
	var path := texture_path.to_lower().replace("\\", "/")
	if not path.begins_with("textures/"):
		path = "textures/" + path

	if path.ends_with(".tga"):
		path = path.replace(".tga", ".dds")

	var texture: Texture2D = null

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

	if not properties.is_empty():
		if "alpha" in properties and properties["alpha"] < 1.0:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	return mat


# =============================================================================
# MESH MIRRORING
# =============================================================================

## Full mesh-space mirror: flip vertex X, normal X, reverse winding.
## Produces a self-consistent left-side mesh. No transform-level scale(-1,1,1) needed.
## This avoids all MODEL_NORMAL_MATRIX ambiguity — default CULL_BACK just works.
## Same strategy as _attach_skinned_mesh_mirrored() uses for skinned parts.
static func _create_mirrored_mesh(mesh_data: MeshExtractor.MeshData) -> ArrayMesh:
	var mirrored_verts := PackedVector3Array()
	mirrored_verts.resize(mesh_data.vertices.size())
	for i in mesh_data.vertices.size():
		mirrored_verts[i] = Vector3(-mesh_data.vertices[i].x, mesh_data.vertices[i].y, mesh_data.vertices[i].z)

	var mirrored_normals := PackedVector3Array()
	if not mesh_data.normals.is_empty():
		mirrored_normals.resize(mesh_data.normals.size())
		for i in mesh_data.normals.size():
			mirrored_normals[i] = Vector3(-mesh_data.normals[i].x, mesh_data.normals[i].y, mesh_data.normals[i].z)

	var mirrored_indices := PackedInt32Array()
	mirrored_indices.resize(mesh_data.indices.size())
	for i in range(0, mesh_data.indices.size(), 3):
		mirrored_indices[i] = mesh_data.indices[i]
		mirrored_indices[i + 1] = mesh_data.indices[i + 2]
		mirrored_indices[i + 2] = mesh_data.indices[i + 1]

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = mirrored_verts
	if not mirrored_normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = mirrored_normals
	if not mesh_data.uvs.is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = mesh_data.uvs
	arrays[Mesh.ARRAY_INDEX] = mirrored_indices

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return array_mesh


## Mirror a Morrowind bone name from right to left (or vice versa).
## Handles "Bip01 R " ↔ "Bip01 L " pattern (case-insensitive).
static func _mirror_bone_name(bone_name: String) -> String:
	var lower := bone_name.to_lower()
	# "bip01 r " → "bip01 l " and vice versa
	if lower.contains(" r "):
		return bone_name.replace(" R ", " L ").replace(" r ", " l ")
	elif lower.contains(" l "):
		return bone_name.replace(" L ", " R ").replace(" l ", " r ")
	# Handle end-of-string: "Bip01 R" (no trailing space)
	if lower.ends_with(" r"):
		return bone_name.substr(0, bone_name.length() - 1) + ("L" if bone_name[-1] == "R" else "l")
	elif lower.ends_with(" l"):
		return bone_name.substr(0, bone_name.length() - 1) + ("R" if bone_name[-1] == "L" else "r")
	return bone_name


# =============================================================================
# UTILITIES
# =============================================================================

## Case-insensitive bone lookup
static func _find_bone_ci(skeleton: Skeleton3D, bone_name: String) -> int:
	var idx := skeleton.find_bone(bone_name)
	if idx >= 0:
		return idx
	var lower := bone_name.to_lower()
	for j in skeleton.get_bone_count():
		if skeleton.get_bone_name(j).to_lower() == lower:
			return j
	return -1


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
	_attachment_cache.clear()


## Preload skeleton for a race/gender (call during loading screen)
static func preload_skeleton(_is_female: bool, is_beast: bool) -> void:
	_get_morrowind_skeleton(is_beast)


## Get cache statistics
static func get_cache_stats() -> Dictionary:
	return {
		"skeletons": _skeleton_cache.size(),
		"body_parts": _body_part_cache.size()
	}
