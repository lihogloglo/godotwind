## MixamoCharacterFactory - Character assembly using Mixamo skeleton
##
## Creates characters using:
## - Mixamo-compatible skeleton for animation compatibility
## - Morrowind meshes rebinded to the Mixamo skeleton
## - Modern Godot animation features (AnimationTree, IK, etc.)
##
## Usage:
##   var factory := MixamoCharacterFactory.new()
##   var character := factory.create_npc(npc_record, race_record)
class_name MixamoCharacterFactory
extends RefCounted


const MixamoSkeletonTemplate := preload("res://src/core/character/mixamo/mixamo_skeleton_template.gd")
const BoneMapper := preload("res://src/core/character/mixamo/bone_mapper.gd")
const MeshExtractor := preload("res://src/core/character/mixamo/mesh_extractor.gd")
const SkinRebinder := preload("res://src/core/character/mixamo/skin_rebinder.gd")
const MixamoAnimationLoader := preload("res://src/core/character/mixamo/mixamo_animation_loader.gd")


## Configuration
var debug_mode: bool = false
var use_simplified_skeleton: bool = false  # No fingers for performance
var load_textures: bool = true


## Cached skeleton templates
var _skeleton_template_human: Skeleton3D = null
var _skeleton_template_beast: Skeleton3D = null


## Body part mesh cache: path -> MeshExtractor.MeshData[]
var _mesh_cache: Dictionary = {}


## Statistics
var _stats := {
	"characters_created": 0,
	"meshes_loaded": 0,
	"meshes_cached": 0,
	"bones_mapped": 0,
	"bones_unmapped": 0,
}


func _init() -> void:
	# Pre-create skeleton templates
	var skel_type := MixamoSkeletonTemplate.SkeletonType.SIMPLIFIED if use_simplified_skeleton else MixamoSkeletonTemplate.SkeletonType.FULL
	_skeleton_template_human = MixamoSkeletonTemplate.create(skel_type)
	_skeleton_template_beast = MixamoSkeletonTemplate.create(MixamoSkeletonTemplate.SkeletonType.BEAST)


## Create a complete NPC character
func create_npc(npc_record: NPCRecord, race_record: RaceRecord) -> CharacterBody3D:
	var start_time := Time.get_ticks_msec()

	# Determine character type
	var is_female: bool = npc_record.is_female() if npc_record.has_method("is_female") else false
	var is_beast: bool = race_record.is_beast() if race_record.has_method("is_beast") else false

	if debug_mode:
		print("MixamoCharacterFactory: Creating NPC '%s' (female=%s, beast=%s)" % [
			npc_record.record_id, is_female, is_beast
		])

	# Create skeleton instance
	var skeleton := _get_skeleton(is_beast)

	# Create character root
	var character_root := Node3D.new()
	character_root.name = npc_record.name if npc_record.name else npc_record.record_id
	character_root.add_child(skeleton)

	# Collect and attach body parts
	var body_parts := _get_body_parts_for_npc(npc_record, race_record, is_female)
	var attach_count := 0

	for part_info: BodyPartInfo in body_parts:
		var success := _attach_body_part(skeleton, part_info)
		if success:
			attach_count += 1

	if debug_mode:
		print("  Attached %d/%d body parts" % [attach_count, body_parts.size()])

	# Create CharacterBody3D wrapper
	var character := CharacterBody3D.new()
	character.name = npc_record.record_id
	character.add_child(character_root)

	# Setup collision
	_setup_collision(character, race_record, is_female)

	# Setup animation system
	_setup_animation(character, skeleton)

	# Add AnimationPlayer as sibling to skeleton
	# Animation tracks use path "Skeleton3D:bone_name" relative to AnimationPlayer's root
	var anim_player := AnimationPlayer.new()
	anim_player.name = "AnimationPlayer"
	character_root.add_child(anim_player)  # Add as sibling to skeleton
	# root_node defaults to ".." so "Skeleton3D" resolves to sibling skeleton

	# Load Mixamo animation library
	_load_mixamo_animations(anim_player)

	# Store metadata
	character.set_meta("record_type", "NPC_")
	character.set_meta("record_id", npc_record.record_id)
	character.set_meta("is_mixamo", true)
	character.set_meta("is_female", is_female)
	character.set_meta("is_beast", is_beast)

	_stats["characters_created"] += 1

	if debug_mode:
		print("  Created in %d ms" % (Time.get_ticks_msec() - start_time))

	return character


## Get skeleton template for character type
func _get_skeleton(is_beast: bool) -> Skeleton3D:
	var template := _skeleton_template_beast if is_beast else _skeleton_template_human
	return MixamoSkeletonTemplate._duplicate_skeleton(template)


## Body part info container
class BodyPartInfo:
	var model: String
	var part_type: int  # BodyPartRecord.PartType
	var record: RefCounted  # BodyPartRecord

	func _init(p_model: String, p_type: int, p_record: RefCounted = null) -> void:
		model = p_model
		part_type = p_type
		record = p_record


## Get body parts for an NPC (with type info for attachment)
## Uses a dictionary keyed by part_type to avoid duplicates (like multiple heads)
func _get_body_parts_for_npc(npc_record: NPCRecord, race_record: RaceRecord, is_female: bool) -> Array[BodyPartInfo]:
	# Use dictionary to avoid duplicates - keyed by part_type
	var parts_by_type: Dictionary = {}

	# Get ESMManager
	var esm_mgr: Node = null
	var main_loop := Engine.get_main_loop() as SceneTree
	if main_loop and main_loop.root:
		esm_mgr = main_loop.root.get_node_or_null("/root/ESMManager")

	if not esm_mgr:
		push_warning("MixamoCharacterFactory: ESMManager not available")
		return []

	# Get race body parts (skip HEAD=0 and HAIR=1, those come from NPC record)
	if esm_mgr.has_method("get_body_parts_for_race"):
		var race_parts: Array = esm_mgr.get_body_parts_for_race(race_record.record_id, is_female)
		for part in race_parts:
			if part and "model" in part and part.model:
				var part_type: int = part.part_type if "part_type" in part else 0
				# Skip HEAD and HAIR - those are NPC-specific
				if part_type == 0 or part_type == 1:
					continue
				# Store by part_type to avoid duplicates
				parts_by_type[part_type] = BodyPartInfo.new(part.model, part_type, part)

	# Get NPC-specific head (overrides any race head)
	if npc_record.head_id and esm_mgr.has_method("get_body_part"):
		var head_part = esm_mgr.get_body_part(npc_record.head_id)
		if head_part and head_part.model:
			parts_by_type[0] = BodyPartInfo.new(head_part.model, 0, head_part)  # 0 = HEAD

	# Get NPC-specific hair (overrides any race hair)
	if npc_record.hair_id and esm_mgr.has_method("get_body_part"):
		var hair_part = esm_mgr.get_body_part(npc_record.hair_id)
		if hair_part and hair_part.model:
			parts_by_type[1] = BodyPartInfo.new(hair_part.model, 1, hair_part)  # 1 = HAIR

	# Convert dictionary to array
	var parts: Array[BodyPartInfo] = []
	for part_type in parts_by_type:
		parts.append(parts_by_type[part_type])

	if debug_mode:
		print("  Found %d body parts for race %s" % [parts.size(), race_record.record_id])

	return parts


## Body part type to Mixamo bone name mapping for non-skinned parts
const PART_TYPE_TO_BONE := {
	0: "mixamorig1_Head",        # HEAD
	1: "mixamorig1_Head",        # HAIR
	2: "mixamorig1_Neck",        # NECK
	3: "mixamorig1_Spine2",      # CHEST
	4: "mixamorig1_Hips",        # GROIN
	5: "mixamorig1_LeftHand",    # HAND (will be duplicated for right)
	6: "mixamorig1_LeftForeArm", # WRIST
	7: "mixamorig1_LeftForeArm", # FOREARM
	8: "mixamorig1_LeftArm",     # UPPER_ARM
	9: "mixamorig1_LeftFoot",    # FOOT
	10: "mixamorig1_LeftFoot",   # ANKLE
	11: "mixamorig1_LeftLeg",    # KNEE
	12: "mixamorig1_LeftUpLeg",  # UPPER_LEG
	13: "mixamorig1_LeftShoulder", # CLAVICLE
	14: "mixamorig1_Tail",       # TAIL
}


## Attach a body part to the skeleton
func _attach_body_part(skeleton: Skeleton3D, part_info: BodyPartInfo) -> bool:
	# Normalize path
	var path := part_info.model.to_lower().replace("\\", "/")
	if not path.begins_with("meshes/"):
		path = "meshes/" + path

	# Get mesh data (from cache or extract)
	var mesh_datas: Array[MeshExtractor.MeshData]

	if path in _mesh_cache:
		mesh_datas = _mesh_cache[path]
		_stats["meshes_cached"] += 1
	else:
		mesh_datas = MeshExtractor.extract_from_bsa(path)
		if mesh_datas.is_empty():
			if debug_mode:
				print("  Failed to extract: %s" % path)
			return false
		_mesh_cache[path] = mesh_datas
		_stats["meshes_loaded"] += mesh_datas.size()

	# Rebind each mesh to the Mixamo skeleton
	for mesh_data in mesh_datas:
		var result := SkinRebinder.rebind(mesh_data, skeleton)

		if not result.success:
			if debug_mode:
				print("  Rebind failed for %s: %s" % [path, result.error])
			continue

		# Track mapping stats for skinned meshes
		if mesh_data.is_skinned:
			_stats["bones_mapped"] += mesh_data.bone_names.size() - result.unmapped_bones.size()
			_stats["bones_unmapped"] += result.unmapped_bones.size()

			if debug_mode and not result.unmapped_bones.is_empty():
				print("  Unmapped bones in %s: %s" % [path, result.unmapped_bones])

		# Create mesh instance
		var mesh_instance := SkinRebinder.create_mesh_instance(result, skeleton)
		if not mesh_instance:
			continue

		mesh_instance.name = path.get_file().get_basename()

		# For skinned meshes, add directly to skeleton (they will deform)
		if result.skin:
			skeleton.add_child(mesh_instance)
		else:
			# For non-skinned meshes, attach to the appropriate bone using BoneAttachment3D
			var bone_name: String = PART_TYPE_TO_BONE.get(part_info.part_type, "mixamorig1_Head")
			var bone_idx := skeleton.find_bone(bone_name)

			if bone_idx >= 0:
				var bone_attachment := BoneAttachment3D.new()
				bone_attachment.name = "Attach_" + mesh_instance.name
				bone_attachment.bone_name = bone_name
				skeleton.add_child(bone_attachment)
				bone_attachment.add_child(mesh_instance)

				# Reset mesh local transform (it should follow the bone)
				mesh_instance.transform = Transform3D.IDENTITY
			else:
				# Fallback: just add to skeleton
				skeleton.add_child(mesh_instance)

	return true


## Setup collision shape
func _setup_collision(character: CharacterBody3D, race_record: RaceRecord, is_female: bool) -> void:
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape"

	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8

	# Adjust for race
	if race_record:
		var height_mult: float = race_record.female_height if is_female else race_record.male_height
		capsule.height *= height_mult

	collision.shape = capsule
	collision.position.y = capsule.height / 2.0

	character.add_child(collision)


## Setup animation system
func _setup_animation(character: CharacterBody3D, skeleton: Skeleton3D) -> void:
	# Add AnimationTree for state machine
	var anim_tree := AnimationTree.new()
	anim_tree.name = "AnimationTree"

	# Create state machine root
	var state_machine := AnimationNodeStateMachine.new()
	anim_tree.tree_root = state_machine

	# The actual states will be configured when animations are loaded
	character.add_child(anim_tree)

	# Add IK controller
	var ik_script := load("res://src/core/animation/ik_controller.gd")
	if ik_script:
		var ik_controller: Node = ik_script.new()
		ik_controller.name = "IKController"
		character.add_child(ik_controller)


## Load Mixamo animations into the AnimationPlayer
func _load_mixamo_animations(anim_player: AnimationPlayer) -> void:
	var library := MixamoAnimationLoader.get_animation_library()
	if library == null or library.get_animation_list().is_empty():
		if debug_mode:
			print("  No Mixamo animations available")
		return

	# Add the library to the player
	anim_player.add_animation_library("mixamo", library)

	if debug_mode:
		print("  Loaded %d Mixamo animations" % library.get_animation_list().size())


## Clear mesh cache
func clear_cache() -> void:
	_mesh_cache.clear()


## Get statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Print statistics
func print_stats() -> void:
	print("=== MixamoCharacterFactory Stats ===")
	print("  Characters created: %d" % _stats["characters_created"])
	print("  Meshes loaded: %d" % _stats["meshes_loaded"])
	print("  Meshes from cache: %d" % _stats["meshes_cached"])
	print("  Bones mapped: %d" % _stats["bones_mapped"])
	print("  Bones unmapped: %d" % _stats["bones_unmapped"])
	if _stats["bones_mapped"] + _stats["bones_unmapped"] > 0:
		var rate := float(_stats["bones_mapped"]) / float(_stats["bones_mapped"] + _stats["bones_unmapped"]) * 100.0
		print("  Mapping rate: %.1f%%" % rate)
