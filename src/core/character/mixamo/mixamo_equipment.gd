# Mixamo Equipment System
# Simpler than MW body parts - uses standard attachment points
# Equipment attaches to bones via BoneAttachment3D
#
# Usage:
#   var equipment := MixamoEquipment.new()
#   equipment.attach(character, "weapon_r", "res://sword.glb", "RightHand")

class_name MixamoEquipment
extends RefCounted

## Standard attachment bone names for Mixamo skeleton
const ATTACHMENT_BONES := {
	"weapon_main": "RightHand",
	"weapon_off": "LeftHand",
	"shield": "LeftForeArm",
	"helmet": "Head",
	"backpack": "Spine2",
	"belt": "Hips",
}

## Equipment slot data
class EquipmentSlot extends RefCounted:
	var id: String              # Slot identifier (e.g., "weapon_r")
	var bone_name: String        # Target bone (e.g., "RightHand")
	var mesh_path: String        # Path to equipment mesh
	var offset: Transform3D      # Local transform offset
	var visible: bool = true     # Visibility toggle

	func _init(p_id: String, p_bone: String, p_mesh: String, p_offset: Transform3D = Transform3D.IDENTITY) -> void:
		id = p_id
		bone_name = p_bone
		mesh_path = p_mesh
		offset = p_offset

## Attach equipment to character
## Returns true on success, false on failure
static func attach(character: Node3D, slot_id: String, mesh_path: String, bone_name: String, offset: Transform3D = Transform3D.IDENTITY) -> bool:
	var skeleton := _get_skeleton(character)
	if skeleton == null:
		Log.error("character", "Cannot attach equipment: no skeleton found")
		return false

	var bone_idx := skeleton.find_bone(bone_name)
	if bone_idx == -1:
		Log.warn("character", "Bone not found for equipment: %s -> %s" % [slot_id, bone_name])
		return false

	var equipment_root := _get_equipment_root(character, skeleton)
	if equipment_root == null:
		Log.error("character", "Cannot attach equipment: no equipment root")
		return false

	# Remove existing equipment in this slot
	var existing := equipment_root.get_node_or_null(slot_id)
	if existing:
		existing.queue_free()

	# Create bone attachment
	var attachment := BoneAttachment3D.new()
	attachment.name = slot_id
	attachment.bone_name = bone_name
	equipment_root.add_child(attachment)
	attachment.owner = character

	# Load mesh
	if not FileAccess.file_exists(mesh_path):
		Log.warn("character", "Equipment mesh not found: %s" % mesh_path)
		return false

	var scene: PackedScene = load(mesh_path)
	if scene == null:
		Log.error("character", "Failed to load equipment mesh: %s" % mesh_path)
		return false

	var mesh_node := scene.instantiate()
	if mesh_node == null:
		Log.error("character", "Failed to instantiate equipment mesh: %s" % mesh_path)
		return false

	# Apply offset and attach
	mesh_node.transform = offset
	attachment.add_child(mesh_node)
	mesh_node.owner = character

	Log.info("character", "Attached equipment: %s to %s" % [slot_id, bone_name])
	return true

## Detach equipment from slot
static func detach(character: Node3D, slot_id: String) -> void:
	var skeleton := _get_skeleton(character)
	if skeleton == null:
		return

	var equipment_root := _get_equipment_root(character, skeleton)
	if equipment_root == null:
		return

	var attachment := equipment_root.get_node_or_null(slot_id)
	if attachment:
		attachment.queue_free()
		Log.info("character", "Detached equipment: %s" % slot_id)

## Toggle equipment visibility
static func set_visible(character: Node3D, slot_id: String, visible: bool) -> void:
	var skeleton := _get_skeleton(character)
	if skeleton == null:
		return

	var equipment_root := _get_equipment_root(character, skeleton)
	if equipment_root == null:
		return

	var attachment := equipment_root.get_node_or_null(slot_id)
	if attachment:
		attachment.visible = visible

## Get list of currently attached equipment slots
static func get_attached_slots(character: Node3D) -> Array[String]:
	var skeleton := _get_skeleton(character)
	if skeleton == null:
		return []

	var equipment_root := _get_equipment_root(character, skeleton)
	if equipment_root == null:
		return []

	var slots: Array[String] = []
	for child in equipment_root.get_children():
		if child is BoneAttachment3D:
			slots.append(child.name)

	return slots

## Clear all equipment from character
static func clear_all(character: Node3D) -> void:
	var skeleton := _get_skeleton(character)
	if skeleton == null:
		return

	var equipment_root := _get_equipment_root(character, skeleton)
	if equipment_root == null:
		return

	for child in equipment_root.get_children():
		child.queue_free()

	Log.info("character", "Cleared all equipment")

## INTERNAL: Get skeleton from character hierarchy
static func _get_skeleton(character: Node3D) -> Skeleton3D:
	return character.get_node_or_null("Skeleton") as Skeleton3D

## INTERNAL: Get or create equipment root node
static func _get_equipment_root(character: Node3D, skeleton: Skeleton3D) -> Node3D:
	var equipment_root := skeleton.get_node_or_null("Equipment") as Node3D
	if equipment_root == null:
		# Create if missing (for backwards compatibility)
		equipment_root = Node3D.new()
		equipment_root.name = "Equipment"
		skeleton.add_child(equipment_root)
		equipment_root.owner = character
		Log.warn("character", "Created missing Equipment node")
	return equipment_root
