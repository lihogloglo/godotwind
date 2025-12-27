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

# Debug mode
var debug_mode: bool = false

# Part Reference Types - matches OpenMW ESM::PartReferenceType
# These define explicit left/right slots unlike BodyPartRecord.PartType
enum PartSlot {
	PRT_Head = 0,
	PRT_Hair = 1,
	PRT_Neck = 2,
	PRT_Cuirass = 3,
	PRT_Groin = 4,
	PRT_Skirt = 5,
	PRT_RHand = 6,
	PRT_LHand = 7,
	PRT_RWrist = 8,
	PRT_LWrist = 9,
	PRT_Shield = 10,
	PRT_RForearm = 11,
	PRT_LForearm = 12,
	PRT_RUpperarm = 13,
	PRT_LUpperarm = 14,
	PRT_RFoot = 15,
	PRT_LFoot = 16,
	PRT_RAnkle = 17,
	PRT_LAnkle = 18,
	PRT_RKnee = 19,
	PRT_LKnee = 20,
	PRT_RLeg = 21,
	PRT_LLeg = 22,
	PRT_RPauldron = 23,
	PRT_LPauldron = 24,
	PRT_Weapon = 25,
	PRT_Tail = 26,
	PRT_Count = 27
}

# Part slot to bone name mapping - matches OpenMW's sPartList
# Based on OpenMW's PartBoneMap in npcanimation.cpp
const PART_SLOT_BONE_MAP := {
	PartSlot.PRT_Head: "Head",
	PartSlot.PRT_Hair: "Head",  # Hair attaches to Head, filtered by "Hair"
	PartSlot.PRT_Neck: "Neck",
	PartSlot.PRT_Cuirass: "Chest",
	PartSlot.PRT_Groin: "Groin",
	PartSlot.PRT_Skirt: "Groin",
	PartSlot.PRT_RHand: "Right Hand",
	PartSlot.PRT_LHand: "Left Hand",
	PartSlot.PRT_RWrist: "Right Wrist",
	PartSlot.PRT_LWrist: "Left Wrist",
	PartSlot.PRT_Shield: "Shield Bone",
	PartSlot.PRT_RForearm: "Right Forearm",
	PartSlot.PRT_LForearm: "Left Forearm",
	PartSlot.PRT_RUpperarm: "Right Upper Arm",
	PartSlot.PRT_LUpperarm: "Left Upper Arm",
	PartSlot.PRT_RFoot: "Right Foot",
	PartSlot.PRT_LFoot: "Left Foot",
	PartSlot.PRT_RAnkle: "Right Ankle",
	PartSlot.PRT_LAnkle: "Left Ankle",
	PartSlot.PRT_RKnee: "Right Knee",
	PartSlot.PRT_LKnee: "Left Knee",
	PartSlot.PRT_RLeg: "Right Upper Leg",
	PartSlot.PRT_LLeg: "Left Upper Leg",
	PartSlot.PRT_RPauldron: "Right Clavicle",
	PartSlot.PRT_LPauldron: "Left Clavicle",
	PartSlot.PRT_Weapon: "Weapon Bone",
	PartSlot.PRT_Tail: "Tail"
}

# Mapping from BodyPartRecord.PartType to both left and right PartSlots
# BodyPart mesh part -> [left slot, right slot] or single slot
const BODY_PART_TO_SLOTS := {
	BodyPartRecord.PartType.HEAD: [PartSlot.PRT_Head],
	BodyPartRecord.PartType.HAIR: [PartSlot.PRT_Hair],
	BodyPartRecord.PartType.NECK: [PartSlot.PRT_Neck],
	BodyPartRecord.PartType.CHEST: [PartSlot.PRT_Cuirass],
	BodyPartRecord.PartType.GROIN: [PartSlot.PRT_Groin],
	BodyPartRecord.PartType.HAND: [PartSlot.PRT_LHand, PartSlot.PRT_RHand],
	BodyPartRecord.PartType.WRIST: [PartSlot.PRT_LWrist, PartSlot.PRT_RWrist],
	BodyPartRecord.PartType.FOREARM: [PartSlot.PRT_LForearm, PartSlot.PRT_RForearm],
	BodyPartRecord.PartType.UPPER_ARM: [PartSlot.PRT_LUpperarm, PartSlot.PRT_RUpperarm],
	BodyPartRecord.PartType.FOOT: [PartSlot.PRT_LFoot, PartSlot.PRT_RFoot],
	BodyPartRecord.PartType.ANKLE: [PartSlot.PRT_LAnkle, PartSlot.PRT_RAnkle],
	BodyPartRecord.PartType.KNEE: [PartSlot.PRT_LKnee, PartSlot.PRT_RKnee],
	BodyPartRecord.PartType.UPPER_LEG: [PartSlot.PRT_LLeg, PartSlot.PRT_RLeg],
	BodyPartRecord.PartType.CLAVICLE: [PartSlot.PRT_LPauldron, PartSlot.PRT_RPauldron],
	BodyPartRecord.PartType.TAIL: [PartSlot.PRT_Tail]
}

# Bone name aliases for Morrowind's Bip01 naming convention
const BONE_ALIASES := {
	"Head": ["Bip01 Head", "bip01 head"],
	"Neck": ["Bip01 Neck", "bip01 neck"],
	"Chest": ["Bip01 Spine2", "bip01 spine2"],
	"Groin": ["Bip01 Pelvis", "bip01 pelvis", "Bip01", "bip01"],
	"Right Hand": ["Bip01 R Hand", "bip01 r hand"],
	"Left Hand": ["Bip01 L Hand", "bip01 l hand"],
	"Right Wrist": ["Bip01 R Forearm", "bip01 r forearm"],
	"Left Wrist": ["Bip01 L Forearm", "bip01 l forearm"],
	"Right Forearm": ["Bip01 R Forearm", "bip01 r forearm"],
	"Left Forearm": ["Bip01 L Forearm", "bip01 l forearm"],
	"Right Upper Arm": ["Bip01 R UpperArm", "bip01 r upperarm"],
	"Left Upper Arm": ["Bip01 L UpperArm", "bip01 l upperarm"],
	"Right Foot": ["Bip01 R Foot", "bip01 r foot"],
	"Left Foot": ["Bip01 L Foot", "bip01 l foot"],
	"Right Ankle": ["Bip01 R Calf", "bip01 r calf"],
	"Left Ankle": ["Bip01 L Calf", "bip01 l calf"],
	"Right Knee": ["Bip01 R Calf", "bip01 r calf"],
	"Left Knee": ["Bip01 L Calf", "bip01 l calf"],
	"Right Upper Leg": ["Bip01 R Thigh", "bip01 r thigh"],
	"Left Upper Leg": ["Bip01 L Thigh", "bip01 l thigh"],
	"Right Clavicle": ["Bip01 R Clavicle", "bip01 r clavicle"],
	"Left Clavicle": ["Bip01 L Clavicle", "bip01 l clavicle"],
	"Tail": ["Bip01 Tail", "bip01 tail"],
	"Shield Bone": ["Bip01 L Hand", "bip01 l hand"],  # Shield attaches to left hand
	"Weapon Bone": ["Bip01 R Hand", "bip01 r hand"],  # Weapon attaches to right hand
}

# Equipment slot priorities (higher = takes precedence)
# Based on OpenMW's slotlist in npcanimation.cpp
const EQUIPMENT_PRIORITIES := {
	"Robe": 11,
	"Skirt": 3,
	"Helmet": 1,
	"Cuirass": 1,
	"Greaves": 1,
	"LeftPauldron": 1,
	"RightPauldron": 1,
	"Boots": 1,
	"LeftGauntlet": 1,
	"RightGauntlet": 1,
	"Shirt": 1,
	"Pants": 1,
}

# Equipped parts tracking: slot -> {model: Node3D, priority: int, equipment_slot: String}
var _equipped_parts: Dictionary = {}

# Part priorities for each slot (to handle equipment overriding body parts)
var _part_priorities: Array[int] = []
var _part_slots: Array[int] = []  # Which equipment slot owns each part

# Base skeleton paths for different character types
const BASE_SKELETON_MALE := "meshes/base_anim.nif"
const BASE_SKELETON_FEMALE := "meshes/base_anim_female.nif"
const BASE_SKELETON_BEAST := "meshes/base_animkna.nif"

# Animation file paths
const ANIM_KF_MALE := "meshes/xbase_anim.kf"
const ANIM_KF_FEMALE := "meshes/xbase_anim_female.kf"
const ANIM_KF_BEAST := "meshes/xbase_animkna.kf"


func _init() -> void:
	# Initialize part priority array
	_part_priorities.resize(PartSlot.PRT_Count)
	_part_priorities.fill(0)


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


## Attach a single body part to the skeleton using proper slot system
func _attach_body_part(skeleton: Skeleton3D, part: BodyPartRecord, part_type: int) -> void:
	if not part or part.model.is_empty():
		if debug_mode:
			push_warning("BodyPartAssembler: Invalid body part or empty model for type %d" % part_type)
		return

	# Get the slots this part type can attach to
	var slots: Array = BODY_PART_TO_SLOTS.get(part_type, [])
	if slots.is_empty():
		if debug_mode:
			push_warning("BodyPartAssembler: No slot mapping for part type %d" % part_type)
		return

	# Load body part model
	var part_model := _load_model_with_animations(part.model)
	if not part_model:
		if debug_mode:
			push_warning("BodyPartAssembler: Failed to load model '%s' for part '%s'" % [
				part.model, part.record_id
			])
		return

	# For paired parts (hands, feet, etc.), attach to BOTH left and right slots
	# Morrowind uses the same mesh for both sides - it's mirrored at runtime
	if slots.size() == 2:
		# Attach to both left and right
		var left_slot: int = slots[0]
		var right_slot: int = slots[1]

		# Create copies for each side
		var left_model := part_model.duplicate()
		var right_model := part_model

		_attach_to_slot(skeleton, left_model, left_slot, 0)
		_attach_to_slot(skeleton, right_model, right_slot, 0)

		if debug_mode:
			print("BodyPartAssembler: Attached '%s' to left and right slots" % part.record_id)
	else:
		# Single slot attachment
		var slot: int = slots[0]
		_attach_to_slot(skeleton, part_model, slot, 0)

		if debug_mode:
			print("BodyPartAssembler: Attached '%s' to slot %d" % [part.record_id, slot])


## Attach a model to a specific part slot
func _attach_to_slot(skeleton: Skeleton3D, model: Node3D, slot: int, priority: int) -> void:
	# Check if we can override existing part
	if _part_priorities[slot] > priority:
		# Existing part has higher priority, skip
		if debug_mode:
			print("BodyPartAssembler: Slot %d has higher priority part, skipping" % slot)
		model.queue_free()
		return

	# Remove existing part if any
	if _equipped_parts.has(slot):
		var old_data: Dictionary = _equipped_parts[slot]
		if old_data.has("model") and old_data["model"] is Node3D:
			(old_data["model"] as Node3D).queue_free()
		_equipped_parts.erase(slot)

	# Get bone name for this slot
	var bone_name: String = _get_bone_name_for_slot(skeleton, slot)
	if bone_name.is_empty():
		if debug_mode:
			push_warning("BodyPartAssembler: Could not find bone for slot %d" % slot)
		model.queue_free()
		return

	# Attach to bone
	_attach_to_bone(skeleton, model, bone_name)

	# Track equipped part
	_equipped_parts[slot] = {
		"model": model,
		"priority": priority,
	}
	_part_priorities[slot] = priority


## Get the actual bone name in the skeleton for a slot
func _get_bone_name_for_slot(skeleton: Skeleton3D, slot: int) -> String:
	var standard_name: String = PART_SLOT_BONE_MAP.get(slot, "")
	if standard_name.is_empty():
		return ""

	# Try to find the bone using aliases
	var aliases: Array = BONE_ALIASES.get(standard_name, [standard_name])

	for alias: String in aliases:
		var bone_idx := skeleton.find_bone(alias)
		if bone_idx >= 0:
			return alias

	# Try case-insensitive search
	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i)
		var bone_lower := bone_name.to_lower()
		for alias: String in aliases:
			if bone_lower == alias.to_lower():
				return bone_name

	return ""


## Remove a part from a specific slot
func remove_part_from_slot(skeleton: Skeleton3D, slot: int) -> void:
	if not _equipped_parts.has(slot):
		return

	var data: Dictionary = _equipped_parts[slot]
	if data.has("model") and data["model"] is Node3D:
		(data["model"] as Node3D).queue_free()

	_equipped_parts.erase(slot)
	_part_priorities[slot] = 0


## Equip an item to a slot with priority
func equip_to_slot(skeleton: Skeleton3D, model_path: String, slot: int, priority: int) -> bool:
	var model := _load_model_with_animations(model_path)
	if not model:
		return false

	_attach_to_slot(skeleton, model, slot, priority)
	return true


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
