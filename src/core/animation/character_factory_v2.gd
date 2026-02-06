## CharacterFactoryV2 - Creates characters with the new animation system
##
## Updated factory that uses the new modular animation system:
## - MorrowindCharacterSystem for NPCs
## - CreatureAnimationSystem for creatures
## - Full IK, procedural animation, and LOD support
##
## PERFORMANCE OPTIMIZATIONS:
## - Static skeleton template caching (via MorrowindNPCAssembler)
## - Static animation library caching (shared across all NPCs of same type)
## - Static body part mesh caching (via MorrowindNPCAssembler)
## - Prebaked animation support for fastest loading
class_name CharacterFactoryV2
extends RefCounted

# Preload dependencies
const NIFKFLoader := preload("res://src/core/nif/nif_kf_loader.gd")
const ModelPrebaker := preload("res://src/tools/prebaking/model_prebaker.gd")
const MorrowindCharacterSystemScript := preload("res://src/core/animation/morrowind_character_system.gd")
const CreatureAnimationSystemScript := preload("res://src/core/animation/creature_animation_system.gd")
const CharacterAnimationSystemScript := preload("res://src/core/animation/character_animation_system.gd")
const MorrowindNPCAssembler := preload("res://src/core/character/morrowind/morrowind_npc_assembler.gd")
const NIFConverter := preload("res://src/core/nif/nif_converter.gd")

# Dependencies
var model_loader: RefCounted = null  # ModelLoader
var kf_loader: NIFKFLoader = null

# =============================================================================
# STATIC CACHES (shared across all CharacterFactoryV2 instances)
# =============================================================================

## Animation library cache: cache_key -> AnimationLibrary
## Key format: "meshes\xbase_anim.kf" (normalized, lowercase)
static var _animation_library_cache: Dictionary = {}

## Parsed animation cache (fallback when no prebaked): cache_key -> Dictionary of anim_name -> Animation
static var _parsed_animation_cache: Dictionary = {}

## Cache statistics
static var _anim_cache_hits: int = 0
static var _anim_cache_misses: int = 0

# Configuration
@export_group("Features")
var enable_ik: bool = true
var enable_procedural: bool = true
var enable_lod: bool = true
var enable_movement: bool = true
var enable_wander: bool = false

@export_group("Debug")
var debug_characters: bool = false
var debug_animations: bool = false


func _init() -> void:
	kf_loader = NIFKFLoader.new()
	kf_loader.debug_mode = false


## Set model loader dependency
func set_model_loader(loader: RefCounted) -> void:
	model_loader = loader


## Get cache statistics
static func get_cache_stats() -> Dictionary:
	var assembler_stats := MorrowindNPCAssembler.get_cache_stats()
	var total := _anim_cache_hits + _anim_cache_misses
	return {
		"skeleton_templates": assembler_stats.get("skeletons", 0),
		"cached_body_parts": assembler_stats.get("body_parts", 0),
		"cached_animation_libraries": _animation_library_cache.size(),
		"cached_parsed_animations": _parsed_animation_cache.size(),
		"animation_cache_hits": _anim_cache_hits,
		"animation_cache_misses": _anim_cache_misses,
		"animation_hit_rate": float(_anim_cache_hits) / maxf(1.0, float(total)) * 100.0
	}


## Clear all static caches
static func clear_all_caches() -> void:
	MorrowindNPCAssembler.clear_caches()
	_animation_library_cache.clear()
	_parsed_animation_cache.clear()
	_anim_cache_hits = 0
	_anim_cache_misses = 0


## Preload all character assets for fastest NPC creation
## Call this once at startup after BSA archives are loaded
static func preload_character_assets() -> void:
	Log.info("animation", "CharacterFactoryV2: Preloading character assets...")
	var start := Time.get_ticks_msec()

	# Preload skeleton templates
	MorrowindNPCAssembler.preload_skeleton(false, false)  # male humanoid
	MorrowindNPCAssembler.preload_skeleton(true, false)   # female humanoid
	MorrowindNPCAssembler.preload_skeleton(false, true)   # beast

	# Preload animation libraries for all character types
	_preload_animation_library("meshes/xbase_anim.kf", "male")
	_preload_animation_library("meshes/xbase_anim_female.kf", "female")
	_preload_animation_library("meshes/xbase_animkna.kf", "beast")

	Log.info("animation", "CharacterFactoryV2: Assets preloaded in %d ms" % (Time.get_ticks_msec() - start))
	var stats := get_cache_stats()
	Log.info("animation", "  Skeletons: %d, Body parts: %d, Animations: %d" % [
		stats["skeleton_templates"],
		stats["cached_body_parts"],
		stats["cached_animation_libraries"]
	])


## Preload a specific animation library
static func _preload_animation_library(kf_path: String, type_name: String) -> void:
	var cache_key := kf_path.to_lower().replace("/", "\\")

	# Check if already cached
	if cache_key in _animation_library_cache:
		return

	# Try prebaked first
	var prebaked_lib := ModelPrebaker.load_cached_animations(kf_path)
	if prebaked_lib:
		_animation_library_cache[cache_key] = prebaked_lib
		Log.info("animation", "  Loaded prebaked %s animations: %d" % [type_name, prebaked_lib.get_animation_list().size()])
		return

	# Fall back to parsing from BSA
	if not BSAManager.has_file(kf_path):
		push_warning("CharacterFactoryV2: Animation file not found: %s" % kf_path)
		return

	var kf_data := BSAManager.extract_file(kf_path)
	if kf_data.is_empty():
		return

	var loader := NIFKFLoader.new()
	var animations := loader.load_kf_buffer(kf_data, null)

	if not animations.is_empty():
		# Create an AnimationLibrary from the parsed animations
		var lib := AnimationLibrary.new()
		for anim_name: String in animations:
			lib.add_animation(anim_name, animations[anim_name])
		_animation_library_cache[cache_key] = lib
		Log.info("animation", "  Parsed %s animations: %d" % [type_name, animations.size()])


## Create an NPC character instance
func create_npc(npc_record: NPCRecord, ref_num: int = 0) -> CharacterBody3D:
	if not npc_record:
		return null

	var total_start := Time.get_ticks_msec()

	# Get race info first (needed for assembly)
	var race: RaceRecord = ESMManager.get_race(npc_record.race_id)
	if not race:
		push_warning("CharacterFactoryV2: Race not found for NPC '%s'" % npc_record.record_id)
		return _create_placeholder_character(npc_record, "npc", ref_num)

	# Assemble body parts using new system
	var assemble_start := Time.get_ticks_msec()
	var character_root := MorrowindNPCAssembler.assemble(npc_record, race)
	if not character_root:
		push_warning("CharacterFactoryV2: Failed to assemble NPC '%s'" % npc_record.record_id)
		return _create_placeholder_character(npc_record, "npc", ref_num)
	if debug_characters:
		Log.info("animation", "CharacterFactoryV2: Assemble NPC: %d ms" % (Time.get_ticks_msec() - assemble_start))

	# Get additional race info for animation
	var is_female := npc_record.is_female()
	var is_beast := race.is_beast() if race else false

	# Find skeleton (should already exist from body part assembly)
	var skeleton := _find_skeleton(character_root)
	if not skeleton:
		push_warning("CharacterFactoryV2: No skeleton found for NPC '%s'" % npc_record.record_id)
		return _create_placeholder_character(npc_record, "npc", ref_num)

	# Load animations (uses cached animation library)
	var anim_start := Time.get_ticks_msec()
	_load_character_animations(character_root, skeleton, is_female, is_beast)
	if debug_characters:
		Log.info("animation", "CharacterFactoryV2: Load animations: %d ms" % (Time.get_ticks_msec() - anim_start))

	# Create movement controller (CharacterBody3D)
	var movement_controller := CharacterMovementController.new()
	movement_controller.name = npc_record.record_id + "_" + str(ref_num)
	movement_controller.wander_enabled = enable_wander

	# Add character root to movement controller
	movement_controller.add_child(character_root)

	# Create new animation system
	var anim_system: MorrowindCharacterSystemScript = MorrowindCharacterSystemScript.new()
	anim_system.name = "AnimationSystem"
	anim_system.enable_ik = enable_ik
	anim_system.enable_procedural = enable_procedural
	anim_system.enable_lod = enable_lod
	anim_system.debug_mode = debug_animations
	anim_system.auto_setup = false  # We'll call setup manually

	character_root.add_child(anim_system)

	# Setup animation system
	anim_system.setup_morrowind(
		skeleton,
		movement_controller,
		is_female,
		is_beast,
		npc_record.race_id,
		npc_record.record_id
	)

	# Set collision shape based on race/size
	_setup_collision_for_npc(movement_controller, npc_record)

	# Store references for movement controller
	movement_controller.character_root = character_root
	movement_controller.set_meta("animation_system", anim_system)

	# Add metadata
	movement_controller.set_meta("record_type", "NPC_")
	movement_controller.set_meta("record_id", npc_record.record_id)
	movement_controller.set_meta("ref_num", ref_num)
	movement_controller.set_meta("is_character", true)
	movement_controller.set_meta("uses_new_animation_system", true)

	if debug_characters:
		Log.info("animation", "CharacterFactoryV2: Created NPC '%s' (%s, %s) - Total: %d ms" % [
			npc_record.name if not npc_record.name.is_empty() else npc_record.record_id,
			"female" if is_female else "male",
			"beast" if is_beast else "humanoid",
			Time.get_ticks_msec() - total_start
		])

	return movement_controller


## Create a creature instance
func create_creature(creature_record: CreatureRecord, ref_num: int = 0) -> CharacterBody3D:
	if not creature_record:
		return null

	# Creatures are simple - just load the model directly
	var character_root := _load_creature_model(creature_record)
	if not character_root:
		push_warning("CharacterFactoryV2: Failed to load creature '%s'" % creature_record.record_id)
		return _create_placeholder_character(creature_record, "creature", ref_num)

	# Find skeleton (creatures may or may not have one)
	var skeleton := _find_skeleton(character_root)

	# Load creature-specific animations
	if skeleton:
		_load_creature_animations(character_root, skeleton, creature_record)

	# Create movement controller
	var movement_controller := CharacterMovementController.new()
	movement_controller.name = creature_record.record_id + "_" + str(ref_num)
	movement_controller.wander_enabled = enable_wander

	# Add character root to movement controller
	movement_controller.add_child(character_root)

	# Create animation system (only if skeleton exists)
	if skeleton:
		var anim_system: CreatureAnimationSystemScript = CreatureAnimationSystemScript.new()
		anim_system.name = "AnimationSystem"
		anim_system.enable_ik = enable_ik
		anim_system.enable_procedural = enable_procedural
		anim_system.enable_lod = enable_lod
		anim_system.debug_mode = debug_animations
		anim_system.auto_setup = false

		character_root.add_child(anim_system)

		# Setup animation system
		anim_system.setup_creature(
			skeleton,
			movement_controller,
			creature_record.record_id
		)

		movement_controller.set_meta("animation_system", anim_system)

	# Set collision based on creature type
	_setup_collision_for_creature(movement_controller, creature_record)

	# Store references
	movement_controller.character_root = character_root

	# Add metadata
	movement_controller.set_meta("record_type", "CREA")
	movement_controller.set_meta("record_id", creature_record.record_id)
	movement_controller.set_meta("ref_num", ref_num)
	movement_controller.set_meta("is_character", true)
	movement_controller.set_meta("uses_new_animation_system", true)

	if debug_characters:
		Log.info("animation", "CharacterFactoryV2: Created creature '%s'" % creature_record.record_id)

	return movement_controller


## Get animation path for character type
static func _get_animation_path(is_female: bool, is_beast: bool) -> String:
	if is_beast:
		return "meshes/xbase_animkna.kf"
	elif is_female:
		return "meshes/xbase_anim_female.kf"
	else:
		return "meshes/xbase_anim.kf"


## Load character animations from .kf file
## Uses static cache for maximum performance - shares AnimationLibrary across all NPCs
## of the same type (male/female/beast) to minimize memory usage
func _load_character_animations(character_root: Node3D, skeleton: Skeleton3D, is_female: bool, is_beast: bool) -> void:
	var anim_path := _get_animation_path(is_female, is_beast)

	# Find AnimationPlayer
	var anim_player := _find_animation_player(character_root)
	if not anim_player:
		if debug_characters:
			Log.debug("animation", "CharacterFactoryV2: No AnimationPlayer found in character root")
		return

	# Normalize path for cache key
	var cache_key := anim_path.to_lower().replace("/", "\\")

	# 1) Check static animation library cache (fastest - SHARE the library directly)
	if cache_key in _animation_library_cache:
		_anim_cache_hits += 1
		var cached_lib: AnimationLibrary = _animation_library_cache[cache_key]
		# Share the same AnimationLibrary - Godot 4 allows this!
		# Multiple AnimationPlayers can reference the same library
		if anim_player.has_animation_library(""):
			anim_player.remove_animation_library("")
		anim_player.add_animation_library("", cached_lib)
		if debug_characters:
			Log.debug("animation", "CharacterFactoryV2: Shared cached AnimationLibrary '%s' (%d anims)" % [
				anim_path, cached_lib.get_animation_list().size()
			])
		return

	_anim_cache_misses += 1

	# 2) Try prebaked AnimationLibrary
	var prebaked_lib := ModelPrebaker.load_cached_animations(anim_path)
	if prebaked_lib:
		# Cache for future use and share directly
		_animation_library_cache[cache_key] = prebaked_lib
		if anim_player.has_animation_library(""):
			anim_player.remove_animation_library("")
		anim_player.add_animation_library("", prebaked_lib)
		if debug_characters:
			Log.debug("animation", "CharacterFactoryV2: Loaded and shared prebaked AnimationLibrary '%s'" % anim_path)
		return

	# 3) Check parsed animation cache - convert to library
	if cache_key in _parsed_animation_cache:
		var animations: Dictionary = _parsed_animation_cache[cache_key]
		# Create a shared library from parsed cache
		var new_lib := AnimationLibrary.new()
		for anim_name: String in animations:
			new_lib.add_animation(anim_name, animations[anim_name])
		_animation_library_cache[cache_key] = new_lib
		if anim_player.has_animation_library(""):
			anim_player.remove_animation_library("")
		anim_player.add_animation_library("", new_lib)
		if debug_characters:
			Log.debug("animation", "CharacterFactoryV2: Created shared library from parsed cache '%s'" % anim_path)
		return

	# 4) Load from BSA and parse (slowest - only on first run without prebake)
	var full_path := anim_path
	if not anim_path.to_lower().begins_with("meshes"):
		full_path = "meshes\\" + anim_path

	if not BSAManager.has_file(full_path):
		if debug_characters:
			Log.debug("animation", "CharacterFactoryV2: Animation file not found in BSA: '%s'" % full_path)
		return

	var kf_data := BSAManager.extract_file(full_path)
	if kf_data.is_empty():
		push_warning("CharacterFactoryV2: Failed to extract animation file: '%s'" % full_path)
		return

	# Load animations using NIFKFLoader
	var parse_start := Time.get_ticks_msec()
	var animations := kf_loader.load_kf_buffer(kf_data, skeleton)
	if debug_characters:
		Log.info("animation", "CharacterFactoryV2: Parsed KF file '%s' in %d ms (%d anims)" % [
			anim_path, Time.get_ticks_msec() - parse_start, animations.size()
		])

	# Cache parsed animations
	_parsed_animation_cache[cache_key] = animations

	# Create a shared AnimationLibrary and cache it
	if not animations.is_empty():
		var new_lib := AnimationLibrary.new()
		for anim_name: String in animations:
			new_lib.add_animation(anim_name, animations[anim_name])
		_animation_library_cache[cache_key] = new_lib

		# Share the library
		if anim_player.has_animation_library(""):
			anim_player.remove_animation_library("")
		anim_player.add_animation_library("", new_lib)

	if debug_characters:
		Log.debug("animation", "CharacterFactoryV2: Created and shared new AnimationLibrary '%s' (%d anims)" % [
			anim_path, animations.size()
		])


## Load creature-specific animations
func _load_creature_animations(character_root: Node3D, skeleton: Skeleton3D, creature_record: CreatureRecord) -> void:
	var model_path := creature_record.model
	if model_path.is_empty():
		return

	# Get base name and add .kf extension
	var base_path := model_path.get_base_dir() + "/" + model_path.get_file().get_basename()
	var anim_path := base_path + ".kf"
	var cache_key := anim_path.to_lower().replace("/", "\\")

	# Find AnimationPlayer
	var anim_player := _find_animation_player(character_root)
	if not anim_player:
		# Create one if it doesn't exist
		anim_player = AnimationPlayer.new()
		anim_player.name = "AnimationPlayer"
		if skeleton:
			skeleton.add_child(anim_player)
		else:
			character_root.add_child(anim_player)

	# Get or create AnimationLibrary
	var lib: AnimationLibrary
	if anim_player.has_animation_library(""):
		lib = anim_player.get_animation_library("")
	else:
		lib = AnimationLibrary.new()
		anim_player.add_animation_library("", lib)

	# Check cache first
	if cache_key in _animation_library_cache:
		_anim_cache_hits += 1
		var cached_lib: AnimationLibrary = _animation_library_cache[cache_key]
		for anim_name: String in cached_lib.get_animation_list():
			if not lib.has_animation(anim_name):
				lib.add_animation(anim_name, cached_lib.get_animation(anim_name).duplicate())
		return

	_anim_cache_misses += 1

	# Try to load .kf file from BSA
	var full_path := anim_path
	if not BSAManager.has_file(anim_path):
		full_path = "meshes\\" + anim_path
		if not BSAManager.has_file(full_path):
			return

	var kf_data := BSAManager.extract_file(full_path)
	if kf_data.is_empty():
		return

	# Load animations using NIFKFLoader
	var animations := kf_loader.load_kf_buffer(kf_data, skeleton)
	if animations.is_empty():
		return

	# Cache the animations
	var new_lib := AnimationLibrary.new()
	for anim_name: String in animations:
		new_lib.add_animation(anim_name, animations[anim_name])
	_animation_library_cache[cache_key] = new_lib

	# Add to player
	for anim_name: String in animations:
		var anim: Animation = animations[anim_name]
		if not lib.has_animation(anim_name):
			lib.add_animation(anim_name, anim)


## Set up collision for NPC
func _setup_collision_for_npc(movement_controller: CharacterMovementController,
		npc_record: NPCRecord) -> void:
	var race: RaceRecord = ESMManager.get_race(npc_record.race_id)

	var height := 1.8
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
	var height := 1.5
	var radius := 0.5

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


## Find AnimationPlayer in scene tree
func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer

	for child in node.get_children():
		var result := _find_animation_player(child)
		if result:
			return result

	return null


## Find Skeleton3D in scene tree
func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D

	for child in node.get_children():
		var result := _find_skeleton(child)
		if result:
			return result

	return null


## Load a creature model from NIF
func _load_creature_model(creature_record: CreatureRecord) -> Node3D:
	if creature_record.model.is_empty():
		return null

	# Normalize path
	var path := creature_record.model.to_lower().replace("\\", "/")
	if not path.begins_with("meshes/"):
		path = "meshes/" + path

	# Load from BSA
	var bsa_mgr := _get_bsa_manager()
	if bsa_mgr == null:
		push_warning("CharacterFactoryV2: BSAManager not available")
		return null

	var data: PackedByteArray = bsa_mgr.get_file(path) if bsa_mgr.has_method("get_file") else PackedByteArray()
	if data.is_empty():
		push_warning("CharacterFactoryV2: Cannot load creature model: %s" % path)
		return null

	# Convert NIF to scene
	var converter := NIFConverter.new()
	converter.load_textures = true
	converter.load_animations = true
	converter.load_collision = false

	var scene := converter.convert_buffer(data, path)
	if scene:
		scene.name = "Creature"
		scene.set_meta("creature_record_id", creature_record.record_id)

	return scene


## Get BSAManager autoload
func _get_bsa_manager() -> Node:
	var main_loop := Engine.get_main_loop() as SceneTree
	if main_loop and main_loop.root:
		return main_loop.root.get_node_or_null("/root/BSAManager")
	return null


## Create a placeholder character for testing
func _create_placeholder_character(record: ESMRecord, type: String, ref_num: int) -> CharacterBody3D:
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
		mat.albedo_color = Color(0.2, 0.6, 1.0, 0.8)
	else:
		mat.albedo_color = Color(1.0, 0.4, 0.2, 0.8)
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
	movement_controller.set_meta("record_id", record.record_id)
	movement_controller.set_meta("ref_num", ref_num)

	return movement_controller


# =============================================================================
# UTILITY METHODS
# =============================================================================

## Get animation system from a character
static func get_animation_system(character: Node) -> Node:
	return character.get_meta("animation_system", null)


## Check if character uses new animation system
static func uses_new_system(character: Node) -> bool:
	return character.get_meta("uses_new_animation_system", false)
