## Controller Test — Quaternius humanoid character with PlayerController
##
## Creates a Quaternius GLB character, wires up HumanoidAnimationSystem,
## and attaches to PlayerController for 3rd-person movement.
##
## Controls:
##   WASD — Move
##   Shift — Sprint
##   Ctrl — Walk (slow)
##   Space — Jump
##   V — Toggle 1st/3rd person
##   R — Toggle root motion
##   Mouse — Look
##   ESC — Release mouse
@warning_ignore("untyped_declaration", "unsafe_method_access")
extends Node3D

const MODEL_PATH := "res://assets/characters/quaternius/UAL2_Standard.glb"

var player_controller: PlayerController
var factory: HumanoidCharacterFactory


func _ready() -> void:
	_create_player()


func _create_player() -> void:
	# Create factory
	factory = HumanoidCharacterFactory.new()
	factory.enable_ik = false
	factory.enable_procedural = false
	factory.debug_animations = true

	# Load character model (skeleton + mesh)
	var character_root := factory.create_character(MODEL_PATH)
	if not character_root:
		push_error("ControllerTest: Failed to load character from %s" % MODEL_PATH)
		return

	# Get skeleton and animation player
	var skeleton := _find_node_of_type(character_root, "Skeleton3D") as Skeleton3D
	var anim_player := _find_node_of_type(character_root, "AnimationPlayer") as AnimationPlayer
	if not skeleton or not anim_player:
		push_error("ControllerTest: Missing Skeleton3D or AnimationPlayer")
		character_root.queue_free()
		return

	# Set AnimationPlayer root_node to Skeleton so ".:BoneName" tracks resolve
	anim_player.root_node = anim_player.get_path_to(skeleton)

	# Load animations preserving ORIGINAL names from the GLB.
	# (AnimationLoader._normalize_name() mangles multi-animation GLBs —
	#  "Walk_Carry" steals the "walk" slot before the real "Walk" animation.)
	var lib := _load_animations_raw(MODEL_PATH)
	if lib:
		if anim_player.has_animation_library(""):
			anim_player.remove_animation_library("")
		anim_player.add_animation_library("", lib)
		print("=== Loaded %d animations ===" % lib.get_animation_list().size())
		var names := lib.get_animation_list()
		names.sort()
		for anim_name in names:
			var anim: Animation = lib.get_animation(anim_name)
			print("  %-30s  %.1fs  %d tracks  loop=%d" % [
				anim_name, anim.length, anim.get_track_count(), anim.loop_mode])

	# Remove placeholder AnimationTree (AnimationManager creates its own)
	for child in skeleton.get_children():
		if child is AnimationTree:
			child.active = false
			skeleton.remove_child(child)
			child.queue_free()

	# Create PlayerController — velocity-driven by default
	player_controller = PlayerController.new()
	player_controller.name = "PlayerController"
	player_controller.use_root_motion = false
	player_controller.run_speed = 5.0
	player_controller.sprint_speed = 8.0
	player_controller.walk_speed = 2.5
	player_controller.camera_distance = 4.0
	add_child(player_controller)
	player_controller.global_position = Vector3(0, 0.1, 0)

	# Create HumanoidAnimationSystem
	var anim_system := HumanoidAnimationSystem.new()
	anim_system.name = "AnimationSystem"
	anim_system.enable_ik = false
	anim_system.enable_procedural = false
	anim_system.debug_mode = true
	anim_system.auto_setup = false
	character_root.add_child(anim_system)

	# Attach character to player controller (this reparents character_root)
	player_controller.attach_character(character_root, anim_system)

	# Setup animation system AFTER character is in the scene tree
	anim_system.setup(skeleton, player_controller, character_root)

	# Enable controller
	player_controller.enable()

	# Print state → animation mapping
	var anim_mgr = anim_system.animation_manager
	if anim_mgr:
		print("=== State → Animation mapping ===")
		for state in [&"Idle", &"Walk", &"Run", &"Sprint", &"Jump", &"Fall", &"Land"]:
			var mapped = anim_mgr.get_animation_for_state(state)
			print("  %-10s → %s" % [state, mapped if not mapped.is_empty() else "(NONE)"])

	# Print bone hierarchy
	print("=== Skeleton: %d bones ===" % skeleton.get_bone_count())
	for i in skeleton.get_bone_count():
		var parent_idx := skeleton.get_bone_parent(i)
		var parent_name := skeleton.get_bone_name(parent_idx) if parent_idx >= 0 else "ROOT"
		print("  [%d] %s ← %s" % [i, skeleton.get_bone_name(i), parent_name])

	# Print move container state
	if player_controller.has_method("get_movement_motor"):
		var motor = player_controller.get_movement_motor()
		var mc = motor.get_move_container() if motor else null
		if mc and mc.has_method("get_current_move_name"):
			print("=== MoveContainer: %d moves, current='%s' ===" % [
				mc.moves.size(), mc.get_current_move_name()])

	print("ControllerTest: Ready — root_motion=%s" % player_controller.use_root_motion)


## Load animations from GLB preserving original names.
## Only fixes track paths to ".:BoneName" format.
func _load_animations_raw(scene_path: String) -> AnimationLibrary:
	var scene: PackedScene = load(scene_path)
	if not scene:
		push_error("ControllerTest: Cannot load scene: %s" % scene_path)
		return null

	var root := scene.instantiate()
	if not root:
		return null

	var source_player := _find_node_of_type(root, "AnimationPlayer") as AnimationPlayer
	if not source_player:
		push_error("ControllerTest: No AnimationPlayer in: %s" % scene_path)
		root.queue_free()
		return null

	var lib := AnimationLibrary.new()
	for anim_name in source_player.get_animation_list():
		if anim_name == "RESET":
			continue

		var source_anim := source_player.get_animation(anim_name)
		if not source_anim:
			continue

		# Fix track paths to ".:BoneName" and set loop mode for locomotion
		var fixed := _fix_track_paths(source_anim)

		# Auto-detect loop mode from name
		var lower := anim_name.to_lower()
		if _is_looping_animation(lower):
			fixed.loop_mode = Animation.LOOP_LINEAR

		lib.add_animation(anim_name, fixed)

	root.queue_free()
	return lib


## Fix track paths from "Armature/Skeleton3D:BoneName" to ".:BoneName"
func _fix_track_paths(source: Animation) -> Animation:
	var result := Animation.new()
	result.length = source.length
	result.loop_mode = source.loop_mode

	for track_idx in source.get_track_count():
		var path := source.track_get_path(track_idx)
		var track_type := source.track_get_type(track_idx)

		# Extract bone name from track path subname
		if path.get_subname_count() == 0:
			continue
		var bone_name := String(path.get_subname(0))
		if bone_name.is_empty():
			continue

		var new_path := NodePath(".:" + bone_name)
		var new_idx := result.add_track(track_type)
		result.track_set_path(new_idx, new_path)
		result.track_set_interpolation_type(new_idx, source.track_get_interpolation_type(track_idx))

		for key_idx in source.track_get_key_count(track_idx):
			var time := source.track_get_key_time(track_idx, key_idx)
			var value = source.track_get_key_value(track_idx, key_idx)
			var transition := source.track_get_key_transition(track_idx, key_idx)
			result.track_insert_key(new_idx, time, value, transition)

	return result


## Check if animation name implies looping
func _is_looping_animation(lower_name: String) -> bool:
	var looping_keywords: PackedStringArray = ["idle", "walk", "run", "sprint", "crouch", "swim", "fall"]
	for keyword in looping_keywords:
		# Word-boundary check: keyword at start/end or bounded by _
		var pos := lower_name.find(keyword)
		if pos >= 0:
			var before_ok := (pos == 0 or lower_name[pos - 1] == "_")
			var after_pos := pos + keyword.length()
			var after_ok := (after_pos >= lower_name.length() or lower_name[after_pos] == "_")
			if before_ok and after_ok:
				return true
	return false


func _find_node_of_type(node: Node, type_name: String) -> Node:
	if node.get_class() == type_name:
		return node
	for child in node.get_children():
		var result := _find_node_of_type(child, type_name)
		if result:
			return result
	return null


func _unhandled_input(event: InputEvent) -> void:
	# R — toggle root motion
	if event is InputEventKey and event.physical_keycode == KEY_R and event.pressed and not event.echo:
		if player_controller:
			player_controller.use_root_motion = not player_controller.use_root_motion
			print("Root motion: %s" % ("ON" if player_controller.use_root_motion else "OFF"))
