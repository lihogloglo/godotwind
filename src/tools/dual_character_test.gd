# Dual Character System Test Scene
# Spawns both MW and Mixamo characters to validate the dual pipeline.
#
# Controls:
#   WASD — move player character (Mixamo)
#   Mouse — orbit camera (3rd person)
#   V — toggle 1st/3rd person
#   TAB — switch control between Mixamo and MW character
#   ESC — release mouse
#
# Phase 5 of DUAL_CHARACTER_SYSTEM.md

extends Node3D

const MixamoCharacterFactory := preload("res://src/core/character/mixamo/mixamo_character_factory.gd")
const CharacterFactoryV2Script := preload("res://src/core/animation/character_factory_v2.gd")

## Mixamo character FBX (character model + walk animation)
const MIXAMO_CHARACTER_FBX := "res://assets/characters/mixamo/Walking.fbx"
## Additional Mixamo animation FBXs
const MIXAMO_ANIMATION_FBXS := [
	"res://assets/characters/mixamo/Walking.fbx",
	"res://assets/characters/mixamo/Neck Stretching.fbx",
	"res://assets/characters/mixamo/Sneaking Forward.fbx",
	"res://assets/characters/mixamo/Sprinting Forward Roll.fbx",
]

## Factories
var _mixamo_factory: MixamoCharacterFactory
var _mw_factory: CharacterFactoryV2Script

## Characters
var _mixamo_player: PlayerController
var _mw_npc: CharacterBody3D

## UI
var _status_label: Label
var _ui_panel: Panel

## State
var _controlling_mixamo: bool = true


func _ready() -> void:
	Log.info("testing", "=== Dual Character System Test ===")

	# Initialize factories
	_mixamo_factory = MixamoCharacterFactory.new()
	_mixamo_factory.enable_ik = false  # Skip IK for initial test
	_mixamo_factory.enable_procedural = false
	_mixamo_factory.debug_animations = true
	_mixamo_factory.animation_name_overrides = {"neck_stretching": "idle"}

	# Spawn characters
	_spawn_mixamo_player()
	_spawn_mw_npc()

	# Create UI
	_create_ui()

	_print_instructions()


func _spawn_mixamo_player() -> void:
	Log.info("testing", "--- Spawning Mixamo player character ---")

	# Use create_character (low-level) + PlayerController for player control
	var character_root := _mixamo_factory.create_character(MIXAMO_CHARACTER_FBX)
	if not character_root:
		Log.error("testing", "Failed to create Mixamo character")
		return

	# Load animations into the AnimationPlayer
	var skeleton := _find_skeleton(character_root)
	var anim_player := _find_animation_player(character_root)
	if anim_player and skeleton:
		# Set root_node so ".:BoneName" tracks resolve to skeleton
		anim_player.root_node = anim_player.get_path_to(skeleton)

		# Load and merge animations
		var merged_lib := AnimationLibrary.new()
		for anim_path: String in MIXAMO_ANIMATION_FBXS:
			var lib := _mixamo_factory.load_animation_library(anim_path, skeleton)
			if lib:
				for anim_name: String in lib.get_animation_list():
					if not merged_lib.has_animation(anim_name):
						merged_lib.add_animation(anim_name, lib.get_animation(anim_name))

		if merged_lib.get_animation_list().size() > 0:
			if anim_player.has_animation_library(""):
				anim_player.remove_animation_library("")
			anim_player.add_animation_library("", merged_lib)
			Log.info("testing", "Loaded %d animations for Mixamo player" % merged_lib.get_animation_list().size())

	# Remove placeholder AnimationTree (AnimationManager will create its own)
	if skeleton:
		for child in skeleton.get_children():
			if child is AnimationTree:
				child.active = false
				skeleton.remove_child(child)
				child.queue_free()

	# Create PlayerController and attach character
	_mixamo_player = PlayerController.new()
	_mixamo_player.name = "MixamoPlayer"
	_mixamo_player.walk_speed = 2.0  # Slower for visual testing
	_mixamo_player.run_speed = 5.0
	add_child(_mixamo_player)
	_mixamo_player.global_position = Vector3(2, 0, 0)

	# Set up HumanoidAnimationSystem
	var HumanoidSystem := preload("res://src/core/animation/humanoid_animation_system.gd")
	var anim_system := HumanoidSystem.new()
	anim_system.name = "AnimationSystem"
	anim_system.enable_ik = false
	anim_system.enable_procedural = false
	anim_system.enable_lod = false
	anim_system.auto_setup = false
	character_root.add_child(anim_system)

	# Attach character to player controller BEFORE setup
	# (so skeleton is in the scene tree when AnimationManager looks for it)
	_mixamo_player.attach_character(character_root, anim_system)

	# Now setup animation system (needs skeleton in tree)
	if skeleton:
		anim_system.setup(skeleton, _mixamo_player, character_root)

	_mixamo_player.enable()

	Log.info("testing", "Mixamo player spawned at (2, 0, 0)")


func _spawn_mw_npc() -> void:
	Log.info("testing", "--- Spawning MW NPC ---")

	# Check if ESMManager is available
	if not Engine.get_main_loop() or not Engine.get_main_loop() is SceneTree:
		Log.warn("testing", "No SceneTree available for MW NPC")
		_create_placeholder_mw_npc()
		return

	var scene_tree := Engine.get_main_loop() as SceneTree
	var esm := scene_tree.root.get_node_or_null("/root/ESMManager")
	if not esm:
		Log.warn("testing", "ESMManager not available — using placeholder MW NPC")
		_create_placeholder_mw_npc()
		return

	# Try to create a real MW NPC
	_mw_factory = CharacterFactoryV2Script.new()
	_mw_factory.enable_ik = false
	_mw_factory.enable_procedural = false
	_mw_factory.enable_wander = true
	_mw_factory.debug_characters = true

	# Find any NPC record for testing
	@warning_ignore("unsafe_method_access")
	var npc_record = esm.get_first_npc_record()
	if npc_record:
		@warning_ignore("unsafe_method_access")
		_mw_npc = _mw_factory.create_npc(npc_record)
		if _mw_npc:
			add_child(_mw_npc)
			_mw_npc.global_position = Vector3(-2, 0, 0)
			Log.info("testing", "MW NPC spawned at (-2, 0, 0)")
			return

	Log.warn("testing", "No NPC records found — using placeholder")
	_create_placeholder_mw_npc()


func _create_placeholder_mw_npc() -> void:
	# Create a visible placeholder for MW character
	var placeholder := CharacterBody3D.new()
	placeholder.name = "MW_NPC_Placeholder"

	var collision := CollisionShape3D.new()
	var capsule_shape := CapsuleShape3D.new()
	capsule_shape.radius = 0.35
	capsule_shape.height = 1.8
	collision.shape = capsule_shape
	collision.position.y = 0.9
	placeholder.add_child(collision)

	# Visual: orange capsule
	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	var capsule_mesh := CapsuleMesh.new()
	capsule_mesh.radius = 0.35
	capsule_mesh.height = 1.8
	visual.mesh = capsule_mesh
	visual.position.y = 0.9

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.5, 0.1, 0.9)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	visual.material_override = mat
	placeholder.add_child(visual)

	# Label
	var label_3d := Label3D.new()
	label_3d.text = "MW NPC\n(placeholder)"
	label_3d.position.y = 2.2
	label_3d.font_size = 32
	label_3d.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	placeholder.add_child(label_3d)

	add_child(placeholder)
	placeholder.global_position = Vector3(-2, 0, 0)
	_mw_npc = placeholder

	Log.info("testing", "MW placeholder spawned at (-2, 0, 0)")


func _process(_delta: float) -> void:
	if _status_label:
		_update_status()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			KEY_TAB:
				_toggle_control()


func _toggle_control() -> void:
	_controlling_mixamo = not _controlling_mixamo
	if _controlling_mixamo and _mixamo_player:
		_mixamo_player.enable()
		Log.info("testing", "Now controlling: Mixamo player")
	elif _mixamo_player:
		_mixamo_player.disable()
		Log.info("testing", "Released Mixamo player control")


func _update_status() -> void:
	var text := "=== Dual Character Test ===\n\n"

	# Mixamo status
	text += "MIXAMO (player-controlled):\n"
	if _mixamo_player:
		text += "  Position: %s\n" % _format_vec3(_mixamo_player.global_position)
		text += "  Speed: %.1f m/s\n" % _mixamo_player.velocity.length()
		text += "  Camera: %s\n" % ("3rd Person" if _mixamo_player.camera_mode == PlayerController.CameraMode.THIRD_PERSON else "1st Person")
		if _mixamo_player.animation_system and _mixamo_player.animation_system.has_method("get_state"):
			@warning_ignore("unsafe_method_access")
			text += "  Anim State: %s\n" % _mixamo_player.animation_system.get_state()
	else:
		text += "  NOT SPAWNED\n"

	text += "\n"

	# MW NPC status
	text += "MW NPC:\n"
	if _mw_npc:
		text += "  Position: %s\n" % _format_vec3(_mw_npc.global_position)
		if _mw_npc.has_meta("record_id"):
			text += "  Record: %s\n" % _mw_npc.get_meta("record_id")
		if _mw_npc.has_meta("is_placeholder"):
			text += "  (placeholder)\n"
	else:
		text += "  NOT SPAWNED\n"

	text += "\nControls: WASD, V=cam, TAB=switch, ESC=release"

	_status_label.text = text


func _format_vec3(v: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [v.x, v.y, v.z]


func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	_ui_panel = Panel.new()
	_ui_panel.position = Vector2(10, 10)
	_ui_panel.custom_minimum_size = Vector2(320, 350)
	canvas.add_child(_ui_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui_panel.add_child(margin)

	_status_label = Label.new()
	_status_label.text = "Initializing..."
	_status_label.add_theme_font_size_override("font_size", 13)
	margin.add_child(_status_label)


func _print_instructions() -> void:
	print("\n=== DUAL CHARACTER SYSTEM TEST ===")
	print("Mixamo character: player-controlled (WASD + mouse)")
	print("MW character: NPC with wander AI (or placeholder)")
	print("")
	print("Controls:")
	print("  WASD / ZQSD / Arrows — Move")
	print("  Mouse — Look / orbit camera")
	print("  V — Toggle 1st/3rd person")
	print("  TAB — Toggle character control")
	print("  SHIFT — Run")
	print("  SPACE — Jump")
	print("  ESC — Release mouse cursor")
	print("======================================\n")


func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root as Skeleton3D
	for child in root.get_children():
		var result := _find_skeleton(child)
		if result:
			return result
	return null


func _find_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root as AnimationPlayer
	for child in root.get_children():
		var result := _find_animation_player(child)
		if result:
			return result
	return null
