## BodyPartAssembler - Assembles NPCs from body parts
##
## Morrowind NPCs are constructed from multiple body part meshes:
## - Race-specific body parts (chest, hands, feet, etc.)
## - NPC-specific head and hair
## - Equipment (clothing/armor) that replaces body parts
##
## Based on OpenMW's npcanimation.cpp implementation
class_name BodyPartAssembler
extends RefCounted

# Preload dependencies
const CS := preload("res://src/core/coordinate_system.gd")
const NIFConverter := preload("res://src/core/nif/nif_converter.gd")

# Injected dependencies
var model_loader: RefCounted  # ModelLoader

# Body part type to bone name mapping
# Based on OpenMW's PartBoneMap in npcanimation.cpp
# Morrowind uses "Bip01" prefix for Biped bones
# Format: "Bip01 L/R <Part>" for left/right variants
const PART_BONE_MAP := {
	BodyPartRecord.PartType.HEAD: "Bip01 Head",
	BodyPartRecord.PartType.HAIR: "Bip01 Head",
	BodyPartRecord.PartType.NECK: "Bip01 Neck",
	BodyPartRecord.PartType.CHEST: "Bip01 Spine2",  # Chest attaches to upper spine
	BodyPartRecord.PartType.GROIN: "Bip01 Pelvis",  # Groin attaches to pelvis
	BodyPartRecord.PartType.HAND: ["Bip01 L Hand", "Bip01 R Hand"],
	BodyPartRecord.PartType.WRIST: ["Bip01 L Forearm", "Bip01 R Forearm"],  # Wrist uses forearm bone
	BodyPartRecord.PartType.FOREARM: ["Bip01 L Forearm", "Bip01 R Forearm"],
	BodyPartRecord.PartType.UPPER_ARM: ["Bip01 L UpperArm", "Bip01 R UpperArm"],
	BodyPartRecord.PartType.FOOT: ["Bip01 L Foot", "Bip01 R Foot"],
	BodyPartRecord.PartType.ANKLE: ["Bip01 L Calf", "Bip01 R Calf"],  # Ankle uses calf bone
	BodyPartRecord.PartType.KNEE: ["Bip01 L Calf", "Bip01 R Calf"],
	BodyPartRecord.PartType.UPPER_LEG: ["Bip01 L Thigh", "Bip01 R Thigh"],
	BodyPartRecord.PartType.CLAVICLE: ["Bip01 L Clavicle", "Bip01 R Clavicle"],
	BodyPartRecord.PartType.TAIL: "Bip01 Tail"  # Beast races only
}

# Base skeleton paths for different character types
const BASE_SKELETON_MALE := "meshes/base_anim.nif"
const BASE_SKELETON_FEMALE := "meshes/base_anim_female.nif"
const BASE_SKELETON_BEAST := "meshes/base_animkna.nif"

# Animation file paths
const ANIM_KF_MALE := "meshes/xbase_anim.kf"
const ANIM_KF_FEMALE := "meshes/xbase_anim_female.kf"
const ANIM_KF_BEAST := "meshes/xbase_animkna.kf"


## Assemble an NPC from body parts
## Returns a Node3D with Skeleton3D and attached body part meshes
func assemble_npc(npc_record: NPCRecord) -> Node3D:
	if not npc_record:
		push_error("BodyPartAssembler: Invalid NPC record")
		return null

	# Get race record to determine body parts
	var race: RaceRecord = ESMManager.get_race(npc_record.race_id)
	if not race:
		push_warning("BodyPartAssembler: Race '%s' not found for NPC '%s'" % [
			npc_record.race_id, npc_record.record_id
		])
		return null

	var is_female := npc_record.is_female()
	var is_beast := race.is_beast()

	# Create base skeleton container
	var character_root := Node3D.new()
	character_root.name = "Character"

	# Load base skeleton
	var skeleton := _load_base_skeleton(is_female, is_beast)
	if not skeleton:
		push_error("BodyPartAssembler: Failed to load base skeleton")
		return null

	skeleton.name = "Skeleton3D"
	character_root.add_child(skeleton)

	# Assemble body parts
	_attach_body_parts(skeleton, npc_record, race, is_female, is_beast)

	# Store metadata for later use
	character_root.set_meta("npc_record_id", npc_record.record_id)
	character_root.set_meta("race_id", npc_record.race_id)
	character_root.set_meta("is_female", is_female)
	character_root.set_meta("is_beast", is_beast)

	return character_root


## Assemble a creature from its model
## Creatures use a single model file unlike NPCs
func assemble_creature(creature_record: CreatureRecord) -> Node3D:
	if not creature_record or creature_record.model.is_empty():
		return null

	# Creatures are simpler - just load the model with animations enabled
	var model := _load_model_with_animations(creature_record.model)
	if model:
		model.name = "Creature"
		model.set_meta("creature_record_id", creature_record.record_id)

	return model


## Load base skeleton model
func _load_base_skeleton(is_female: bool, is_beast: bool) -> Skeleton3D:
	var skeleton_path: String

	if is_beast:
		skeleton_path = BASE_SKELETON_BEAST
	elif is_female:
		skeleton_path = BASE_SKELETON_FEMALE
	else:
		skeleton_path = BASE_SKELETON_MALE

	# Load skeleton with animations enabled
	var skeleton_model := _load_model_with_animations(skeleton_path)
	if not skeleton_model:
		return null

	# Find Skeleton3D node in the loaded model
	var skeleton: Skeleton3D = _find_skeleton(skeleton_model)
	if not skeleton:
		push_error("BodyPartAssembler: No Skeleton3D found in '%s'" % skeleton_path)
		return null

	# Reparent skeleton to isolate it from the loaded model hierarchy
	var parent := skeleton.get_parent()
	if parent:
		parent.remove_child(skeleton)

	return skeleton


## Attach body parts to skeleton
func _attach_body_parts(skeleton: Skeleton3D, npc: NPCRecord, race: RaceRecord,
		is_female: bool, is_beast: bool) -> void:

	# Get all race body parts
	var race_parts := _get_race_body_parts(race, is_female, is_beast)

	# Attach each body part
	for part_type: int in race_parts:
		var part_record: BodyPartRecord = race_parts[part_type]
		_attach_body_part(skeleton, part_record, part_type)

	# Override with NPC-specific head and hair
	if not npc.head_id.is_empty():
		var head: BodyPartRecord = ESMManager.get_body_part(npc.head_id)
		if head:
			_attach_body_part(skeleton, head, BodyPartRecord.PartType.HEAD)

	if not npc.hair_id.is_empty():
		var hair: BodyPartRecord = ESMManager.get_body_part(npc.hair_id)
		if hair:
			_attach_body_part(skeleton, hair, BodyPartRecord.PartType.HAIR)


## Get all body parts for a race
func _get_race_body_parts(race: RaceRecord, is_female: bool, _is_beast: bool) -> Dictionary:
	var parts := {}

	# Access body_parts dictionary directly from ESMManager
	var all_body_parts: Dictionary = ESMManager.body_parts

	if all_body_parts.is_empty():
		push_warning("BodyPartAssembler: No body parts loaded in ESMManager")
		return parts

	# Search for body parts matching this race
	# Body parts are named like: "b_n_<race>_<gender>_<part>"
	# Example: "b_n_dark elf_m_chest", "b_n_argonian_m_chest"
	# Beast races use: "b_n_khajiit_m_chest", etc.
	var race_id_lower := race.record_id.to_lower()

	for part_id: String in all_body_parts:
		var part: BodyPartRecord = all_body_parts[part_id]
		if not part:
			continue

		# Skip if not a skin type (we want base body, not clothing/armor)
		if part.mesh_type != BodyPartRecord.MeshType.SKIN:
			continue

		# Check gender match
		if is_female != part.is_female():
			continue

		# Skip vampire parts for non-vampires (vampire parts have "vampire" in name)
		if part.is_vampire:
			continue

		# Check if part belongs to this race by looking for race name in part ID
		var part_id_lower: String = part_id.to_lower()

		# Match race ID in body part name
		# Body parts typically named: b_n_<race>_<gender>_<part>
		if race_id_lower in part_id_lower:
			# Only add if we don't already have this part type, or replace with better match
			if not parts.has(part.part_type):
				parts[part.part_type] = part

	return parts


## Attach a single body part to the skeleton
func _attach_body_part(skeleton: Skeleton3D, part: BodyPartRecord, part_type: int) -> void:
	if not part or part.model.is_empty():
		return

	# Get bone name(s) for this part type
	var bone_info: Variant = PART_BONE_MAP.get(part_type)
	if not bone_info:
		return

	# Load body part model
	var part_model := _load_model_with_animations(part.model)
	if not part_model:
		return

	# Handle single bone or multiple bones (left/right)
	if bone_info is String:
		_attach_to_bone(skeleton, part_model, bone_info as String)
	elif bone_info is Array:
		# For paired parts (hands, feet, etc.), attach to right bone
		# TODO: Proper left/right detection based on part ID
		var bone_array: Array = bone_info as Array
		if bone_array.size() < 2:
			push_warning("BodyPartAssembler: Invalid bone array for part type %d" % part_type)
			return
		var bone_name: String = str(bone_array[1])  # Default to right
		if "left" in part.record_id.to_lower():
			bone_name = str(bone_array[0])
		_attach_to_bone(skeleton, part_model, bone_name)


## Attach a model to a specific bone
func _attach_to_bone(skeleton: Skeleton3D, model: Node3D, bone_name: String) -> void:
	var bone_idx := skeleton.find_bone(bone_name)

	# Try case-insensitive search if exact match fails
	if bone_idx == -1:
		bone_idx = _find_bone_case_insensitive(skeleton, bone_name)

	if bone_idx == -1:
		# Don't spam warnings for common missing bones - skeleton may not have all parts
		if not bone_name.contains("Tail"):  # Tails only on beast races
			push_warning("BodyPartAssembler: Bone '%s' not found in skeleton" % bone_name)
		return

	# Get the actual bone name from the skeleton (for correct casing)
	var actual_bone_name := skeleton.get_bone_name(bone_idx)

	# Create BoneAttachment3D
	var bone_attachment := BoneAttachment3D.new()
	bone_attachment.name = actual_bone_name + "_Attachment"
	bone_attachment.bone_name = actual_bone_name

	skeleton.add_child(bone_attachment)

	# Find all mesh instances in the part model and attach them
	_attach_meshes_recursive(bone_attachment, model)


## Find bone by name (case-insensitive)
func _find_bone_case_insensitive(skeleton: Skeleton3D, bone_name: String) -> int:
	var target := bone_name.to_lower()
	for i in skeleton.get_bone_count():
		if skeleton.get_bone_name(i).to_lower() == target:
			return i
	return -1


## Recursively find and attach mesh instances
func _attach_meshes_recursive(parent: Node, node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		# Duplicate the mesh instance and attach to bone
		var dup := mesh_instance.duplicate()
		dup.name = mesh_instance.name
		parent.add_child(dup)

	for child in node.get_children():
		_attach_meshes_recursive(parent, child)


## Load a model with animations enabled
func _load_model_with_animations(model_path: String) -> Node3D:
	if not model_loader:
		push_error("BodyPartAssembler: model_loader not set")
		return null

	# Load model data from BSA
	var full_path := model_path
	if not model_path.to_lower().begins_with("meshes"):
		full_path = "meshes\\" + model_path

	var nif_data := PackedByteArray()
	if BSAManager.has_file(full_path):
		nif_data = BSAManager.extract_file(full_path)
	elif BSAManager.has_file(model_path):
		nif_data = BSAManager.extract_file(model_path)

	if nif_data.is_empty():
		push_warning("BodyPartAssembler: Model not found in BSA: '%s'" % model_path)
		return null

	# Convert with animations enabled
	var converter := NIFConverter.new()
	converter.load_animations = true  # Enable animations for character models
	converter.load_textures = true
	converter.load_collision = false  # Body parts don't need collision

	var node := converter.convert_buffer(nif_data, full_path)
	if not node:
		push_warning("BodyPartAssembler: Failed to convert NIF: '%s'" % full_path)
		return null

	return node


## Find Skeleton3D node in a scene tree
func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D

	for child in node.get_children():
		var result := _find_skeleton(child)
		if result:
			return result

	return null


## Get base animation path for character type
static func get_animation_path(is_female: bool, is_beast: bool) -> String:
	if is_beast:
		return ANIM_KF_BEAST
	elif is_female:
		return ANIM_KF_FEMALE
	else:
		return ANIM_KF_MALE
