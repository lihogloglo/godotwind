# Mixamo Character Factory Test Scene
# Tests the full Mixamo NPC pipeline: FBX loading, animation system, state machine.
# Validates Phase 2+4 of Dual Character System implementation.
#
# Controls:
#   1-4: Switch animations (direct AnimationPlayer playback)
#   S: Toggle skeleton visibility
#   SPACE: Reset position
#   B: Print bone info
#   T: Print animation tracks

extends Node3D

const MixamoCharacterFactory := preload("res://src/core/character/mixamo/mixamo_character_factory.gd")

## Test configuration
const CHARACTER_FBX := "res://assets/characters/mixamo/Walking.fbx"
const ANIMATION_FBXS: Array[String] = [
	"res://assets/characters/mixamo/Neck Stretching.fbx",
	"res://assets/characters/mixamo/Walking.fbx",
	"res://assets/characters/mixamo/Sneaking Forward.fbx",
	"res://assets/characters/mixamo/Sprinting Forward Roll.fbx",
]

## Factory instance
var _factory: MixamoCharacterFactory

## NPC created by full pipeline
var _npc: CharacterBody3D

## References (extracted from NPC)
var _skeleton: Skeleton3D
var _anim_player: AnimationPlayer
var _anim_system: Node

## UI
var _ui_panel: Panel
var _status_label: Label


func _ready() -> void:
	Log.info("testing", "=== Mixamo Character Test (Full Pipeline) ===")

	# Create factory
	_factory = MixamoCharacterFactory.new()
	_factory.enable_ik = false
	_factory.enable_procedural = false
	_factory.enable_lod = false
	_factory.enable_wander = false
	_factory.debug_animations = true
	_factory.animation_name_overrides = {"neck_stretching": "idle"}

	# Create full NPC via create_npc() pipeline
	_npc = _factory.create_npc(CHARACTER_FBX, ANIMATION_FBXS)
	if not _npc:
		Log.error("testing", "Failed to create NPC from: %s" % CHARACTER_FBX)
		return

	add_child(_npc)
	_npc.global_position = Vector3.ZERO

	# Extract references from NPC hierarchy
	_skeleton = _find_skeleton(_npc)
	_anim_player = _find_animation_player(_npc)
	_anim_system = _npc.get_meta("animation_system", null)

	Log.info("testing", "NPC created: skeleton=%s, anim_player=%s, anim_system=%s" % [
		"OK" if _skeleton else "MISSING",
		"OK" if _anim_player else "MISSING",
		"OK" if _anim_system else "MISSING",
	])

	# Log available animations
	if _anim_player:
		Log.info("testing", "Available animations:")
		for anim_name in _anim_player.get_animation_list():
			Log.info("testing", "  - %s" % anim_name)

	# Create UI
	_create_ui()

	# Print diagnostics after first frame
	await get_tree().process_frame
	_print_bone_info()
	_print_instructions()


func _process(_delta: float) -> void:
	if not _npc:
		return
	_update_status()


func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed:
		return

	match event.keycode:
		KEY_1: _play_by_index(0)
		KEY_2: _play_by_index(1)
		KEY_3: _play_by_index(2)
		KEY_4: _play_by_index(3)
		KEY_SPACE: _reset_position()
		KEY_S: _toggle_skeleton()
		KEY_B: _print_bone_info()
		KEY_T: _print_track_info()


## Play animation by index in available animations list
func _play_by_index(index: int) -> void:
	if not _anim_player:
		return

	var animations := _anim_player.get_animation_list()
	if index < animations.size():
		var anim_name: String = animations[index]
		_anim_player.play(anim_name)
		Log.info("testing", "Playing: %s" % anim_name)


func _reset_position() -> void:
	if _npc:
		_npc.global_position = Vector3.ZERO
		Log.info("testing", "Position reset")


func _toggle_skeleton() -> void:
	if _skeleton:
		_skeleton.visible = not _skeleton.visible


func _print_bone_info() -> void:
	if not _skeleton:
		return
	Log.info("testing", "=== Skeleton: %d bones ===" % _skeleton.get_bone_count())
	for i in min(15, _skeleton.get_bone_count()):
		var name := _skeleton.get_bone_name(i)
		var parent_idx := _skeleton.get_bone_parent(i)
		var parent_name := _skeleton.get_bone_name(parent_idx) if parent_idx != -1 else "ROOT"
		var rest_rot := _skeleton.get_bone_rest(i).basis.get_rotation_quaternion()
		var pose_rot := _skeleton.get_bone_pose_rotation(i)
		var animating := not pose_rot.is_equal_approx(rest_rot)
		Log.info("testing", "  [%d] %s (parent: %s) %s" % [
			i, name, parent_name, "ANIM" if animating else "rest"])


func _print_track_info() -> void:
	if not _anim_player or not _anim_player.is_playing():
		Log.warn("testing", "No animation playing")
		return

	var current := _anim_player.current_animation
	# Find the Animation resource
	var anim: Animation = null
	for lib_name in _anim_player.get_animation_library_list():
		var lib := _anim_player.get_animation_library(lib_name)
		@warning_ignore("untyped_declaration")
		var anim_name_part = current.substr(current.find("/") + 1) if "/" in current else current
		if lib.has_animation(anim_name_part):
			anim = lib.get_animation(anim_name_part)
			break
		if lib.has_animation(current):
			anim = lib.get_animation(current)
			break

	if not anim:
		Log.warn("testing", "Cannot find Animation resource for: %s" % current)
		return

	Log.info("testing", "=== Tracks: %s (%d tracks, %.1fs) ===" % [current, anim.get_track_count(), anim.length])
	for i in min(10, anim.get_track_count()):
		var path := anim.track_get_path(i)
		var type_name := ""
		match anim.track_get_type(i):
			Animation.TYPE_POSITION_3D: type_name = "Pos"
			Animation.TYPE_ROTATION_3D: type_name = "Rot"
			Animation.TYPE_SCALE_3D: type_name = "Scl"
			_: type_name = "Other"
		Log.info("testing", "  [%d] %s — %s (%d keys)" % [
			i, path, type_name, anim.track_get_key_count(i)])


func _update_status() -> void:
	if not _status_label:
		return

	var text := "MIXAMO CHARACTER TEST\n\n"

	if _anim_player:
		text += "Playing: %s\n" % ("YES" if _anim_player.is_playing() else "NO")
		text += "Animation: %s\n" % _anim_player.current_animation
		if _anim_player.is_playing():
			text += "Time: %.2f / %.2f s\n" % [
				_anim_player.current_animation_position,
				_anim_player.current_animation_length]

	if _anim_system and _anim_system.has_method("get_state"):
		@warning_ignore("unsafe_method_access")
		text += "\nAnim System State: %s\n" % _anim_system.get_state()

	if _skeleton:
		# Check if bones are being driven
		var driving := 0
		for i in min(10, _skeleton.get_bone_count()):
			var rest_rot := _skeleton.get_bone_rest(i).basis.get_rotation_quaternion()
			var pose_rot := _skeleton.get_bone_pose_rotation(i)
			if not pose_rot.is_equal_approx(rest_rot):
				driving += 1

		if driving > 0:
			text += "\nBones animating: %d/10" % driving
		else:
			text += "\nBONES AT REST POSE"

	text += "\n\n1-4: anims, S: skeleton, B: bones, T: tracks"
	_status_label.text = text


func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	_ui_panel = Panel.new()
	_ui_panel.position = Vector2(10, 10)
	_ui_panel.custom_minimum_size = Vector2(300, 380)
	canvas.add_child(_ui_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	margin.add_child(vbox)

	_status_label = Label.new()
	_status_label.text = "Initializing..."
	_status_label.add_theme_font_size_override("font_size", 13)
	vbox.add_child(_status_label)


func _print_instructions() -> void:
	print("\n=== MIXAMO CHARACTER TEST (Full Pipeline) ===")
	print("  1-4: Switch animations")
	print("  S: Toggle skeleton")
	print("  B: Print bone info")
	print("  T: Print track info")
	print("  SPACE: Reset position")
	print("============================================\n")


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
