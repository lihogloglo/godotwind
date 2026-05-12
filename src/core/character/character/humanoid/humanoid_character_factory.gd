# Humanoid Character Factory
# Loads humanoid characters from GLB/FBX files with native skeleton + animations
# NO retargeting - animations are used as-is from source files
#
# Two creation modes:
#   create_character() — low-level: returns Node3D with skeleton + mesh + AnimationPlayer
#   create_npc()       — full pipeline: returns CharacterMovementController with animation system
#
# Usage:
#   var factory := HumanoidCharacterFactory.new()
#   # Full NPC with animation system (single GLB with embedded animations):
#   var npc := factory.create_npc("res://character.glb")
#   # Or with separate animation files:
#   var npc := factory.create_npc("res://character.glb", ["res://walk.fbx", "res://idle.fbx"])
#   # Or low-level:
#   var character := factory.create_character("res://character.glb")

class_name HumanoidCharacterFactory
extends RefCounted

# Preload animation system classes
const HumanoidAnimationSystemScript := preload("res://src/core/animation/humanoid_animation_system.gd")

## Character hierarchy template
const CHARACTER_STRUCTURE := {
	"root": "CharacterRoot",        # Node3D container
	"skeleton": "Skeleton",         # Skeleton3D
	"mesh": "Body",                 # MeshInstance3D
	"equipment": "Equipment",       # Node3D for attachments
	"anim_player": "AnimationPlayer",
	"anim_tree": "AnimationTree",
}

## Skeleton profile for IK/retargeting (not used for animation, only for IK)
var _skeleton_profile: SkeletonProfile

## Animation cache: path -> AnimationLibrary
var _animation_cache: Dictionary = {}

## Configuration (set before calling create_npc)
var enable_ik: bool = true
var enable_procedural: bool = true
var enable_lod: bool = true
var enable_wander: bool = false
var debug_animations: bool = false

## Animation name overrides — applied to merged library before state machine builds.
## Maps normalized animation name → desired name. E.g. {"neck_stretching": "idle"}
var animation_name_overrides: Dictionary = {}

func _init() -> void:
	_skeleton_profile = SkeletonProfileHumanoid.new()
	Log.info("character", "HumanoidCharacterFactory initialized")

## Load humanoid character from GLB/FBX file
## Returns Node3D root with structure:
##   CharacterRoot (Node3D)
##   ├── Skeleton (Skeleton3D)
##   ├── Body (MeshInstance3D)
##   ├── Equipment (Node3D)
##   ├── AnimationPlayer
##   └── AnimationTree
func create_character(model_path: String) -> Node3D:
	if not FileAccess.file_exists(model_path):
		Log.error("character", "Model file not found: %s" % model_path)
		return null

	Log.info("character", "Loading humanoid character: %s" % model_path)

	# Load scene (works for both GLB and FBX)
	var scene: PackedScene = load(model_path)
	if scene == null:
		Log.error("character", "Failed to load as PackedScene: %s" % model_path)
		return null

	var imported_root := scene.instantiate()
	if imported_root == null:
		Log.error("character", "Failed to instantiate scene: %s" % model_path)
		return null

	# Extract skeleton and mesh from imported hierarchy
	var skeleton := _find_skeleton(imported_root)
	var mesh_instance := _find_mesh_instance(imported_root)

	if skeleton == null:
		Log.error("character", "No Skeleton3D found in: %s" % model_path)
		imported_root.queue_free()
		return null

	if mesh_instance == null:
		Log.warn("character", "No MeshInstance3D found in: %s" % model_path)

	# Create clean character hierarchy
	var character_root := Node3D.new()
	character_root.name = CHARACTER_STRUCTURE.root

	# Reparent skeleton to character root
	var original_parent := skeleton.get_parent()
	if original_parent:
		original_parent.remove_child(skeleton)
	character_root.add_child(skeleton)
	skeleton.owner = character_root
	skeleton.name = CHARACTER_STRUCTURE.skeleton

	# Reparent mesh if found
	if mesh_instance:
		var mesh_parent := mesh_instance.get_parent()
		if mesh_parent and mesh_parent != skeleton:
			mesh_parent.remove_child(mesh_instance)
			skeleton.add_child(mesh_instance)
			mesh_instance.owner = character_root
		mesh_instance.name = CHARACTER_STRUCTURE.mesh

	# Equipment container
	var equipment_root := Node3D.new()
	equipment_root.name = CHARACTER_STRUCTURE.equipment
	skeleton.add_child(equipment_root)
	equipment_root.owner = character_root

	# Set up animation system
	_setup_animation_system(character_root, skeleton)

	# Apply skeleton profile for IK compatibility
	_apply_skeleton_profile(skeleton)

	# Clean up imported root (keep only what we reparented)
	imported_root.queue_free()

	Log.info("character", "Humanoid character created: %d bones" % skeleton.get_bone_count())
	return character_root

## Create a full NPC from GLB/FBX with animation system, collision, and AI movement.
## Returns CharacterMovementController matching CharacterFactoryV2.create_npc() output format.
##
## animation_paths: additional files to load animations from (merged into single library).
##   If empty and model_path contains animations (e.g. Quaternius GLB), those are used.
## height/radius: collision capsule dimensions.
##
## Output hierarchy:
##   CharacterMovementController (CharacterBody3D)
##   ├── CollisionShape3D
##   └── CharacterRoot (Node3D)
##       ├── Skeleton3D
##       │   ├── Body (MeshInstance3D)
##       │   ├── Equipment (Node3D)
##       │   └── AnimationTree (created by AnimationManager)
##       ├── AnimationPlayer (with loaded animations)
##       └── HumanoidAnimationSystem (Node)
func create_npc(model_path: String, animation_paths: Array = [],
		height: float = 1.8, radius: float = 0.4) -> CharacterBody3D:
	var start := Time.get_ticks_msec()

	# 1. Create character root with skeleton + mesh
	var character_root := create_character(model_path)
	if not character_root:
		return null

	# 2. Get skeleton and animation player
	var skeleton := _find_skeleton(character_root)
	var anim_player := _find_animation_player(character_root)
	if not skeleton or not anim_player:
		Log.error("character", "Missing skeleton or AnimationPlayer after create_character()")
		character_root.queue_free()
		return null

	# 3. Set AnimationPlayer root_node to Skeleton so ".:BoneName" tracks resolve
	anim_player.root_node = anim_player.get_path_to(skeleton)

	# 4. Load animations — from model itself + any additional files
	var merged_lib := AnimationLibrary.new()

	# Load from the model file itself (GLBs like Quaternius contain all animations)
	var model_lib := load_animation_library(model_path, skeleton)
	if model_lib:
		for anim_name: String in model_lib.get_animation_list():
			if not merged_lib.has_animation(anim_name):
				merged_lib.add_animation(anim_name, model_lib.get_animation(anim_name))

	# Load from additional animation files (if any)
	for anim_path: String in animation_paths:
		var lib := load_animation_library(anim_path, skeleton)
		if lib:
			for anim_name: String in lib.get_animation_list():
				if not merged_lib.has_animation(anim_name):
					merged_lib.add_animation(anim_name, lib.get_animation(anim_name))

	# 4b. Apply animation name overrides (e.g. "neck_stretching" -> "idle")
	for old_name: String in animation_name_overrides:
		if merged_lib.has_animation(old_name):
			var new_name: String = animation_name_overrides[old_name]
			var anim := merged_lib.get_animation(old_name)
			merged_lib.remove_animation(old_name)
			merged_lib.add_animation(new_name, anim)
			Log.info("character", "Renamed animation: %s -> %s" % [old_name, new_name])

	if merged_lib.get_animation_list().size() > 0:
		if anim_player.has_animation_library(""):
			anim_player.remove_animation_library("")
		anim_player.add_animation_library("", merged_lib)
		Log.info("character", "Loaded %d merged animations for NPC" % merged_lib.get_animation_list().size())

	# 5. Remove the placeholder AnimationTree (AnimationManager creates its own)
	for child in skeleton.get_children():
		if child is AnimationTree:
			child.active = false
			skeleton.remove_child(child)
			child.queue_free()

	# 6. Create CharacterMovementController
	var movement_controller := CharacterMovementController.new()
	movement_controller.name = model_path.get_file().get_basename()
	movement_controller.wander_enabled = enable_wander
	movement_controller.add_child(character_root)
	movement_controller.set_collision_shape(radius, height)

	# 7. Create and wire HumanoidAnimationSystem
	var anim_system: HumanoidAnimationSystemScript = HumanoidAnimationSystemScript.new()
	anim_system.name = "AnimationSystem"
	anim_system.enable_ik = enable_ik
	anim_system.enable_procedural = enable_procedural
	anim_system.enable_lod = enable_lod
	anim_system.debug_mode = debug_animations
	anim_system.auto_setup = false
	character_root.add_child(anim_system)
	anim_system.setup(skeleton, movement_controller, character_root)

	# 8. Store references (same format as CharacterFactoryV2)
	movement_controller.character_root = character_root
	movement_controller.animation_system = anim_system
	movement_controller.set_meta("animation_system", anim_system)
	movement_controller.set_meta("character_type", "HUMANOID")
	movement_controller.set_meta("is_character", true)
	movement_controller.set_meta("uses_new_animation_system", true)

	Log.info("character", "Humanoid NPC created: %s (%d ms)" % [
		model_path.get_file(), Time.get_ticks_msec() - start])
	return movement_controller


## Load animation library from GLB/FBX file
## Animations must target the same skeleton bone structure
## preserve_bone_names: if true, keeps original bone names (default: true)
## Returns AnimationLibrary or null on failure
func load_animation_library(anim_path: String, skeleton: Skeleton3D, preserve_bone_names: bool = true) -> AnimationLibrary:
	if not FileAccess.file_exists(anim_path):
		Log.error("character", "Animation file not found: %s" % anim_path)
		return null

	# Check cache
	if _animation_cache.has(anim_path):
		Log.debug("character", "Animation cache hit: %s" % anim_path)
		return _animation_cache[anim_path]

	Log.info("character", "Loading animations: %s" % anim_path)

	# Use AnimationLoader with preserve_bone_names flag
	var library := AnimationLoader.load_from_glb(anim_path, {}, preserve_bone_names)
	if not library:
		Log.error("character", "Failed to load animations from: %s" % anim_path)
		return null

	# Cache and return
	_animation_cache[anim_path] = library
	var anim_count := library.get_animation_list().size()
	Log.info("character", "Loaded %d animations from: %s" % [anim_count, anim_path])
	return library

## Attach equipment to character using bone attachments
## equipment_data format:
##   {
##     "weapon_r": {"mesh": "res://...", "bone": "RightHand"},
##     "shield_l": {"mesh": "res://...", "bone": "LeftHand"},
##   }
func attach_equipment(character: Node3D, equipment_data: Dictionary) -> void:
	var skeleton := character.get_node_or_null(CHARACTER_STRUCTURE.skeleton) as Skeleton3D
	if skeleton == null:
		Log.error("character", "No skeleton found in character")
		return

	var equipment_root := skeleton.get_node_or_null(CHARACTER_STRUCTURE.equipment)
	if equipment_root == null:
		Log.error("character", "No equipment root found in character")
		return

	# Clear existing equipment
	for child in equipment_root.get_children():
		child.queue_free()

	# Attach new equipment
	for equipment_id in equipment_data:
		var equip_info: Dictionary = equipment_data[equipment_id]
		if not equip_info.has("mesh") or not equip_info.has("bone"):
			Log.warn("character", "Invalid equipment data for: %s" % equipment_id)
			continue

		var bone_name: String = equip_info.bone
		var bone_idx := skeleton.find_bone(bone_name)
		if bone_idx == -1:
			Log.warn("character", "Bone not found for equipment: %s -> %s" % [equipment_id, bone_name])
			continue

		# Create bone attachment
		var attachment := BoneAttachment3D.new()
		attachment.name = equipment_id
		attachment.bone_name = bone_name
		equipment_root.add_child(attachment)
		attachment.owner = character

		# Load and attach mesh
		var mesh_path: String = equip_info.mesh
		if FileAccess.file_exists(mesh_path):
			var mesh_scene: PackedScene = load(mesh_path)
			if mesh_scene:
				var mesh_node := mesh_scene.instantiate()
				attachment.add_child(mesh_node)
				mesh_node.owner = character
				Log.debug("character", "Attached equipment: %s to bone %s" % [equipment_id, bone_name])
		else:
			Log.warn("character", "Equipment mesh not found: %s" % mesh_path)

## Clear animation cache (for memory management)
func clear_cache() -> void:
	_animation_cache.clear()
	Log.info("character", "Animation cache cleared")

## INTERNAL: Find Skeleton3D in scene tree (depth-first search)
func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root as Skeleton3D

	for child in root.get_children():
		var result := _find_skeleton(child)
		if result:
			return result

	return null

## INTERNAL: Find first MeshInstance3D in scene tree
func _find_mesh_instance(root: Node) -> MeshInstance3D:
	if root is MeshInstance3D:
		return root as MeshInstance3D

	for child in root.get_children():
		var result := _find_mesh_instance(child)
		if result:
			return result

	return null

## INTERNAL: Find AnimationPlayer in scene tree
func _find_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root as AnimationPlayer

	for child in root.get_children():
		var result := _find_animation_player(child)
		if result:
			return result

	return null

## INTERNAL: Set up AnimationPlayer and AnimationTree
func _setup_animation_system(character_root: Node3D, skeleton: Skeleton3D) -> void:
	# AnimationPlayer (sibling of Skeleton under CharacterRoot)
	var anim_player := AnimationPlayer.new()
	anim_player.name = CHARACTER_STRUCTURE.anim_player
	character_root.add_child(anim_player)
	anim_player.owner = character_root

	Log.debug("character", "AnimationPlayer created (root_node: %s)" % anim_player.root_node)

	# AnimationTree (child of skeleton for bone track resolution)
	var anim_tree := AnimationTree.new()
	anim_tree.name = CHARACTER_STRUCTURE.anim_tree
	skeleton.add_child(anim_tree)
	anim_tree.owner = character_root
	anim_tree.anim_player = anim_tree.get_path_to(anim_player)

	# Simple blend tree (user will set up state machine separately)
	var blend_tree := AnimationNodeBlendTree.new()
	anim_tree.tree_root = blend_tree

## INTERNAL: Apply skeleton profile for IK compatibility
func _apply_skeleton_profile(skeleton: Skeleton3D) -> void:
	# Map skeleton bone names to SkeletonProfileHumanoid for IK
	var bone_map := _create_bone_map(skeleton)
	if bone_map:
		skeleton.set_meta("skeleton_profile", _skeleton_profile)
		skeleton.set_meta("bone_map", bone_map)
		Log.debug("character", "Skeleton profile applied for IK")

## INTERNAL: Create bone map for skeleton -> HumanoidProfile
## Tries profile-standard names first, then common alternative names
## Returns BoneMap or null if mapping fails
func _create_bone_map(skeleton: Skeleton3D) -> BoneMap:
	var bone_map := BoneMap.new()
	bone_map.profile = _skeleton_profile

	# Standard humanoid profile bone names — if the skeleton already uses these
	# (e.g. after Godot retarget import), they map 1:1
	var profile := SkeletonProfileHumanoid.new()
	var mapped_count := 0
	for i in profile.bone_size:
		var profile_name := profile.get_bone_name(i)
		if skeleton.find_bone(profile_name) != -1:
			bone_map.set_skeleton_bone_name(profile_name, profile_name)
			mapped_count += 1

	if mapped_count == 0:
		Log.warn("character", "No humanoid bones mapped to profile")
		return null

	Log.info("character", "Mapped %d bones to profile" % mapped_count)
	return bone_map
