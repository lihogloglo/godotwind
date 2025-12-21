## CharacterFactory - Creates fully assembled and animated characters
##
## Combines BodyPartAssembler, CharacterAnimationController, and CharacterMovementController
## to create complete NPC and creature instances with animation and movement
class_name CharacterFactory
extends RefCounted

# Dependencies
var model_loader: RefCounted  # ModelLoader
var body_part_assembler: BodyPartAssembler
var kf_loader: RefCounted  # NIFKFLoader

# Configuration
var enable_movement: bool = true
var enable_wander: bool = false
var debug_characters: bool = false


func _init() -> void:
	body_part_assembler = BodyPartAssembler.new()


## Set model loader dependency
func set_model_loader(loader: RefCounted) -> void:
	model_loader = loader
	if body_part_assembler:
		body_part_assembler.model_loader = loader


## Create an NPC character instance
func create_npc(npc_record: NPCRecord, ref_num: int = 0) -> CharacterBody3D:
	if not npc_record:
		return null

	# Assemble body parts
	var character_root := body_part_assembler.assemble_npc(npc_record)
	if not character_root:
		push_warning("CharacterFactory: Failed to assemble NPC '%s'" % npc_record.record_id)
		return _create_placeholder_character(npc_record, "npc", ref_num)

	# Load animations
	_load_character_animations(character_root, npc_record.is_female(),
		_is_beast_race(npc_record.race_id))

	# Create movement controller
	var movement_controller := CharacterMovementController.new()
	movement_controller.name = npc_record.record_id + "_" + str(ref_num)
	movement_controller.wander_enabled = enable_wander

	# Create animation controller
	var anim_controller := CharacterAnimationController.new()
	anim_controller.name = "AnimationController"
	anim_controller.debug_animations = debug_characters

	# Set up hierarchy
	movement_controller.setup(character_root, anim_controller)
	character_root.add_child(anim_controller)
	anim_controller.setup(character_root)

	# Set collision shape based on race/size
	_setup_collision_for_npc(movement_controller, npc_record)

	# Add metadata
	movement_controller.set_meta("record_type", "NPC_")
	movement_controller.set_meta("record_id", npc_record.record_id)
	movement_controller.set_meta("ref_num", ref_num)
	movement_controller.set_meta("is_character", true)

	if debug_characters:
		print("CharacterFactory: Created NPC '%s' (%s)" % [
			npc_record.name if not npc_record.name.is_empty() else npc_record.record_id,
			"female" if npc_record.is_female() else "male"
		])

	return movement_controller


## Create a creature instance
func create_creature(creature_record: CreatureRecord, ref_num: int = 0) -> CharacterBody3D:
	if not creature_record:
		return null

	# Assemble creature
	var character_root := body_part_assembler.assemble_creature(creature_record)
	if not character_root:
		push_warning("CharacterFactory: Failed to assemble creature '%s'" % creature_record.record_id)
		return _create_placeholder_character(creature_record, "creature", ref_num)

	# Load creature-specific animations
	_load_creature_animations(character_root, creature_record)

	# Create movement controller
	var movement_controller := CharacterMovementController.new()
	movement_controller.name = creature_record.record_id + "_" + str(ref_num)
	movement_controller.wander_enabled = enable_wander

	# Create animation controller
	var anim_controller := CharacterAnimationController.new()
	anim_controller.name = "AnimationController"
	anim_controller.debug_animations = debug_characters

	# Set up hierarchy
	movement_controller.setup(character_root, anim_controller)
	character_root.add_child(anim_controller)
	anim_controller.setup(character_root)

	# Set collision based on creature type
	_setup_collision_for_creature(movement_controller, creature_record)

	# Add metadata
	movement_controller.set_meta("record_type", "CREA")
	movement_controller.set_meta("record_id", creature_record.record_id)
	movement_controller.set_meta("ref_num", ref_num)
	movement_controller.set_meta("is_character", true)

	if debug_characters:
		print("CharacterFactory: Created creature '%s'" % creature_record.record_id)

	return movement_controller


## Load character animations from .kf file
func _load_character_animations(character_root: Node3D, is_female: bool, is_beast: bool) -> void:
	var anim_path := BodyPartAssembler.get_animation_path(is_female, is_beast)

	# Find AnimationPlayer
	var anim_player := _find_animation_player(character_root)
	if not anim_player:
		if debug_characters:
			print("CharacterFactory: No AnimationPlayer found in character root")
		return

	# TODO: Load .kf file and add animations to AnimationPlayer
	# For now, animations should be loaded from the base skeleton NIF
	if debug_characters:
		print("CharacterFactory: Would load animations from '%s'" % anim_path)


## Load creature-specific animations
func _load_creature_animations(character_root: Node3D, creature_record: CreatureRecord) -> void:
	# Creature animations are typically in <creature_id>.kf
	var anim_path := creature_record.model.get_basename() + ".kf"

	# Find AnimationPlayer
	var anim_player := _find_animation_player(character_root)
	if not anim_player:
		return

	# TODO: Load .kf file if it exists
	if debug_characters:
		print("CharacterFactory: Would load creature animations from '%s'" % anim_path)


## Set up collision for NPC
func _setup_collision_for_npc(movement_controller: CharacterMovementController,
		npc_record: NPCRecord) -> void:
	# Get race for height scaling
	var race: RaceRecord = ESMManager.get_race(npc_record.race_id)

	var height := 1.8  # Default human height
	var radius := 0.4

	if race:
		if npc_record.is_female():
			height *= race.female_height
		else:
			height *= race.male_height

	movement_controller.set_collision_shape(radius, height)


## Set up collision for creature
func _setup_collision_for_creature(movement_controller: CharacterMovementController,
		creature_record: CreatureRecord) -> void:
	# TODO: Get collision data from creature model metadata
	# For now, use defaults based on creature type

	var height := 1.5
	var radius := 0.5

	# Adjust based on creature type
	match creature_record.creature_type:
		0:  # Creature
			height = 1.2
			radius = 0.6
		1:  # Daedra
			height = 2.0
			radius = 0.7
		2:  # Undead
			height = 1.8
			radius = 0.5
		3:  # Humanoid
			height = 1.8
			radius = 0.4

	movement_controller.set_collision_shape(radius, height)


## Check if race is beast race (Argonian/Khajiit)
func _is_beast_race(race_id: String) -> bool:
	var race: RaceRecord = ESMManager.get_race(race_id)
	if race:
		return race.is_beast()
	return false


## Find AnimationPlayer in scene tree
func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer

	for child in node.get_children():
		var result := _find_animation_player(child)
		if result:
			return result

	return null


## Create a placeholder character for testing
func _create_placeholder_character(record, type: String, ref_num: int) -> CharacterBody3D:
	var movement_controller := CharacterMovementController.new()
	movement_controller.name = record.record_id + "_" + str(ref_num) + "_placeholder"

	# Create visual placeholder
	var visual := MeshInstance3D.new()
	visual.name = "Visual"

	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	visual.mesh = capsule

	# Color based on type
	var mat := StandardMaterial3D.new()
	if type == "npc":
		mat.albedo_color = Color(0.2, 0.6, 1.0, 0.8)  # Blue
	else:
		mat.albedo_color = Color(1.0, 0.4, 0.2, 0.8)  # Orange
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	visual.material_override = mat

	# Create container
	var container := Node3D.new()
	container.name = "Character"
	container.add_child(visual)

	movement_controller.add_child(container)
	movement_controller.set_collision_shape(0.35, 1.8)

	# Metadata
	movement_controller.set_meta("is_placeholder", true)
	movement_controller.set_meta("record_type", "NPC_" if type == "npc" else "CREA")
	movement_controller.set_meta("record_id", record.record_id if "record_id" in record else "unknown")
	movement_controller.set_meta("ref_num", ref_num)

	return movement_controller
