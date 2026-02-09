## Morrowind Body Part Slots - Defines slot-to-bone mappings
## Game-specific layer matching OpenMW's ESM::PartReferenceType
class_name MorrowindBodyPartSlots
extends RefCounted


## Body part slots matching OpenMW's ESM::PartReferenceType
enum Slot {
	HEAD = 0,
	HAIR = 1,
	NECK = 2,
	CHEST = 3,
	GROIN = 4,
	SKIRT = 5,
	HAND_R = 6,
	HAND_L = 7,
	WRIST_R = 8,
	WRIST_L = 9,
	FOREARM_R = 10,
	FOREARM_L = 11,
	UPPER_ARM_R = 12,
	UPPER_ARM_L = 13,
	FOOT_R = 14,
	FOOT_L = 15,
	ANKLE_R = 16,
	ANKLE_L = 17,
	KNEE_R = 18,
	KNEE_L = 19,
	UPPER_LEG_R = 20,
	UPPER_LEG_L = 21,
	CLAVICLE_R = 22,
	CLAVICLE_L = 23,
	WEAPON = 24,
	SHIELD = 25,
	TAIL = 26,
}


## Map slots to skeleton bone names (normalized/lowercase)
const SLOT_TO_BONE := {
	Slot.HEAD: "bip01 head",
	Slot.HAIR: "bip01 head",
	Slot.NECK: "bip01 neck",
	Slot.CHEST: "bip01 spine2",  # Chest attachment is child of Bip01 Spine2 in xbase_anim.nif
	Slot.GROIN: "bip01 pelvis",
	Slot.SKIRT: "bip01 pelvis",
	Slot.HAND_R: "bip01 r hand",
	Slot.HAND_L: "bip01 l hand",
	Slot.WRIST_R: "bip01 r forearm",
	Slot.WRIST_L: "bip01 l forearm",
	Slot.FOREARM_R: "bip01 r forearm",
	Slot.FOREARM_L: "bip01 l forearm",
	Slot.UPPER_ARM_R: "bip01 r upperarm",
	Slot.UPPER_ARM_L: "bip01 l upperarm",
	Slot.FOOT_R: "bip01 r foot",
	Slot.FOOT_L: "bip01 l foot",
	Slot.ANKLE_R: "bip01 r calf",  # Ankle attachment is child of Bip01 R Calf in xbase_anim.nif
	Slot.ANKLE_L: "bip01 l calf",
	Slot.KNEE_R: "bip01 r calf",
	Slot.KNEE_L: "bip01 l calf",
	Slot.UPPER_LEG_R: "bip01 r thigh",
	Slot.UPPER_LEG_L: "bip01 l thigh",
	Slot.CLAVICLE_R: "bip01 r clavicle",
	Slot.CLAVICLE_L: "bip01 l clavicle",
	Slot.WEAPON: "bip01 r hand",  # Weapon bone or right hand
	Slot.SHIELD: "bip01 l hand",  # Shield bone or left hand
	Slot.TAIL: "bip01 tail",
}


## Left-side slots (need mirroring when using right-side mesh)
const LEFT_SIDE_SLOTS := [
	Slot.HAND_L,
	Slot.WRIST_L,
	Slot.FOREARM_L,
	Slot.UPPER_ARM_L,
	Slot.FOOT_L,
	Slot.ANKLE_L,
	Slot.KNEE_L,
	Slot.UPPER_LEG_L,
	Slot.CLAVICLE_L,
]


## Get the bone name for a slot
static func get_bone(slot: int) -> String:
	return SLOT_TO_BONE.get(slot, "")


## Check if slot is left-side (needs mirroring)
static func is_left_side(slot: int) -> bool:
	return slot in LEFT_SIDE_SLOTS


## Get the right-side equivalent of a left-side slot
static func get_right_equivalent(slot: int) -> int:
	match slot:
		Slot.HAND_L: return Slot.HAND_R
		Slot.WRIST_L: return Slot.WRIST_R
		Slot.FOREARM_L: return Slot.FOREARM_R
		Slot.UPPER_ARM_L: return Slot.UPPER_ARM_R
		Slot.FOOT_L: return Slot.FOOT_R
		Slot.ANKLE_L: return Slot.ANKLE_R
		Slot.KNEE_L: return Slot.KNEE_R
		Slot.UPPER_LEG_L: return Slot.UPPER_LEG_R
		Slot.CLAVICLE_L: return Slot.CLAVICLE_R
		_: return slot


## Get the left-side equivalent of a right-side slot
static func get_left_equivalent(slot: int) -> int:
	match slot:
		Slot.HAND_R: return Slot.HAND_L
		Slot.WRIST_R: return Slot.WRIST_L
		Slot.FOREARM_R: return Slot.FOREARM_L
		Slot.UPPER_ARM_R: return Slot.UPPER_ARM_L
		Slot.FOOT_R: return Slot.FOOT_L
		Slot.ANKLE_R: return Slot.ANKLE_L
		Slot.KNEE_R: return Slot.KNEE_L
		Slot.UPPER_LEG_R: return Slot.UPPER_LEG_L
		Slot.CLAVICLE_R: return Slot.CLAVICLE_L
		_: return slot


## Map ESM BodyPart.PartType to slot(s)
## PartType is what's stored in the ESM body part record
## Note: In Morrowind, each naked body part mesh contains geometry for BOTH sides
## (e.g., a hand mesh has both left and right hands). So we return only the
## RIGHT slot here - the mesh itself contains all needed geometry.
## Mirroring/duplicating is only used for CLOTHING/ARMOR overlays.
static func part_type_to_slots(part_type: int) -> Array[int]:
	match part_type:
		0:  # HEAD
			return [Slot.HEAD]
		1:  # HAIR
			return [Slot.HAIR]
		2:  # NECK
			return [Slot.NECK]
		3:  # CHEST
			return [Slot.CHEST]
		4:  # GROIN
			return [Slot.GROIN]
		5:  # HAND - mesh contains both hands
			return [Slot.HAND_R]
		6:  # WRIST - mesh contains both wrists
			return [Slot.WRIST_R]
		7:  # FOREARM - mesh contains both forearms
			return [Slot.FOREARM_R]
		8:  # UPPER_ARM - mesh contains both upper arms
			return [Slot.UPPER_ARM_R]
		9:  # FOOT - mesh contains both feet
			return [Slot.FOOT_R]
		10:  # ANKLE - mesh contains both ankles
			return [Slot.ANKLE_R]
		11:  # KNEE - mesh contains both knees
			return [Slot.KNEE_R]
		12:  # UPPER_LEG - mesh contains both upper legs
			return [Slot.UPPER_LEG_R]
		13:  # CLAVICLE - mesh contains both clavicles
			return [Slot.CLAVICLE_R]
		14:  # TAIL
			return [Slot.TAIL]
		_:
			return []


## Get slot name for debugging
static func slot_name(slot: int) -> String:
	match slot:
		Slot.HEAD: return "HEAD"
		Slot.HAIR: return "HAIR"
		Slot.NECK: return "NECK"
		Slot.CHEST: return "CHEST"
		Slot.GROIN: return "GROIN"
		Slot.SKIRT: return "SKIRT"
		Slot.HAND_R: return "HAND_R"
		Slot.HAND_L: return "HAND_L"
		Slot.WRIST_R: return "WRIST_R"
		Slot.WRIST_L: return "WRIST_L"
		Slot.FOREARM_R: return "FOREARM_R"
		Slot.FOREARM_L: return "FOREARM_L"
		Slot.UPPER_ARM_R: return "UPPER_ARM_R"
		Slot.UPPER_ARM_L: return "UPPER_ARM_L"
		Slot.FOOT_R: return "FOOT_R"
		Slot.FOOT_L: return "FOOT_L"
		Slot.ANKLE_R: return "ANKLE_R"
		Slot.ANKLE_L: return "ANKLE_L"
		Slot.KNEE_R: return "KNEE_R"
		Slot.KNEE_L: return "KNEE_L"
		Slot.UPPER_LEG_R: return "UPPER_LEG_R"
		Slot.UPPER_LEG_L: return "UPPER_LEG_L"
		Slot.CLAVICLE_R: return "CLAVICLE_R"
		Slot.CLAVICLE_L: return "CLAVICLE_L"
		Slot.WEAPON: return "WEAPON"
		Slot.SHIELD: return "SHIELD"
		Slot.TAIL: return "TAIL"
		_: return "UNKNOWN(%d)" % slot
