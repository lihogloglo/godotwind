## Morrowind Bone Translator - Handles Morrowind's bone naming conventions
## Game-specific layer for Morrowind/OpenMW compatibility
class_name MorrowindBoneTranslator
extends RefCounted


## Normalize bone name (lowercase, trimmed)
static func normalize(name: String) -> String:
	return name.to_lower().strip_edges()


## Mirror bone name (left <-> right)
## Morrowind uses "Bip01 L/R" pattern
static func mirror(name: String) -> String:
	var n := normalize(name)

	# Handle "bip01 r " and "bip01 l " patterns (space after L/R)
	if n.contains(" r "):
		return n.replace(" r ", " l ")
	if n.contains(" l "):
		return n.replace(" l ", " r ")

	# Handle suffix patterns like "bip01 r hand" -> " r hand"
	# where there's a space before r/l at the end
	var parts := n.rsplit(" ", false, 1)
	if parts.size() == 2:
		var last := parts[1]
		if last.begins_with("r") and last.length() > 1:
			return parts[0] + " l" + last.substr(1)
		if last.begins_with("l") and last.length() > 1:
			return parts[0] + " r" + last.substr(1)

	return n  # No mirroring needed


## Create a translator callable for left-side body parts
static func left_side_translator() -> Callable:
	return func(name: String) -> String:
		return mirror(normalize(name))


## Create a translator callable that just normalizes
static func normalizing_translator() -> Callable:
	return func(name: String) -> String:
		return normalize(name)


## Check if a bone name is a left-side bone
static func is_left_bone(name: String) -> bool:
	var n := normalize(name)
	return n.contains(" l ") or (n.contains(" l") and not n.ends_with(" l"))


## Check if a bone name is a right-side bone
static func is_right_bone(name: String) -> bool:
	var n := normalize(name)
	return n.contains(" r ") or (n.contains(" r") and not n.ends_with(" r"))


## Standard Morrowind skeleton bone names (normalized)
const SKELETON_BONES := [
	"bip01",
	"bip01 pelvis",
	"bip01 spine",
	"bip01 spine1",
	"bip01 spine2",
	"bip01 neck",
	"bip01 head",
	# Right side
	"bip01 r clavicle",
	"bip01 r upperarm",
	"bip01 r forearm",
	"bip01 r hand",
	"bip01 r finger0",
	"bip01 r finger01",
	"bip01 r finger02",
	"bip01 r finger1",
	"bip01 r finger11",
	"bip01 r finger12",
	"bip01 r finger2",
	"bip01 r finger21",
	"bip01 r finger22",
	"bip01 r finger3",
	"bip01 r finger31",
	"bip01 r finger32",
	"bip01 r finger4",
	"bip01 r finger41",
	"bip01 r finger42",
	"bip01 r thigh",
	"bip01 r calf",
	"bip01 r foot",
	"bip01 r toe0",
	# Left side
	"bip01 l clavicle",
	"bip01 l upperarm",
	"bip01 l forearm",
	"bip01 l hand",
	"bip01 l finger0",
	"bip01 l finger01",
	"bip01 l finger02",
	"bip01 l finger1",
	"bip01 l finger11",
	"bip01 l finger12",
	"bip01 l finger2",
	"bip01 l finger21",
	"bip01 l finger22",
	"bip01 l finger3",
	"bip01 l finger31",
	"bip01 l finger32",
	"bip01 l finger4",
	"bip01 l finger41",
	"bip01 l finger42",
	"bip01 l thigh",
	"bip01 l calf",
	"bip01 l foot",
	"bip01 l toe0",
	# Beast race additions
	"bip01 tail",
]


## Validate that a bone name exists in the standard skeleton
static func is_valid_bone(name: String) -> bool:
	return normalize(name) in SKELETON_BONES


## Get all bones that should be affected by a body part slot
## Returns array of normalized bone names
static func get_bones_for_slot(slot: int) -> PackedStringArray:
	# Import slot enum from MorrowindBodyPartSlots
	# This is a helper for debugging/validation
	match slot:
		0:  # HEAD
			return PackedStringArray(["bip01 head"])
		1:  # HAIR
			return PackedStringArray(["bip01 head"])
		2:  # NECK
			return PackedStringArray(["bip01 neck"])
		3:  # CHEST
			return PackedStringArray(["bip01 spine1", "bip01 spine2"])
		4:  # GROIN
			return PackedStringArray(["bip01 pelvis"])
		_:
			return PackedStringArray()
