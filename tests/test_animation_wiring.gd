extends SceneTree
## Test: Animation wiring — movement drives animation, text key signals propagate
## Run with: godot --headless --script res://tests/test_animation_wiring.gd
##
## NOTE: Uses runtime load() instead of preload() because CAS/AM reference the
## Log autoload, which isn't registered at compile time in headless --script mode.
##
## AnimationTree's per-frame processing doesn't work reliably in headless mode,
## so we disable process callbacks and test the state management API directly.

var _tests_passed: int = 0
var _tests_failed: int = 0

# Signal tracking
var _state_changes: Array[Dictionary] = []
var _sounds: Array[Dictionary] = []
var _hits: Array[Vector3] = []
var _footsteps: Array[Dictionary] = []

# Shared scene
var _scene: Node3D = null
var _anim_system: Node = null


func _init() -> void:
	print("=" .repeat(60))
	print("ANIMATION WIRING TESTS")
	print("=" .repeat(60))
	print("")

	# Wait for autoloads to register before loading scripts that use Log
	await process_frame

	var CAS: GDScript = load("res://src/core/animation/character_animation_system.gd")
	if not CAS:
		print("  FAIL: Could not load CharacterAnimationSystem script")
		quit(1)
		return

	# Create scene once, share across all tests
	_scene = _create_animated_scene(CAS)
	if not _scene or not _anim_system:
		print("  FAIL: Could not create animated scene")
		quit(1)
		return

	# Disable AnimationManager's _process to prevent AnimationTree callbacks
	# from interfering — we're testing the state management API, not per-frame
	var am_node: Node = _anim_system.get("animation_manager")
	if am_node:
		am_node.set_process(false)

	# Also disable CAS process callbacks
	_anim_system.set_process(false)
	_anim_system.set_physics_process(false)

	@warning_ignore("unsafe_method_access")
	_test_movement_drives_state()
	@warning_ignore("unsafe_method_access")
	_test_text_key_signal_forwarding()
	@warning_ignore("unsafe_method_access")
	_test_text_key_registration()

	# Cleanup: deactivate AnimationTree before freeing to avoid headless segfault
	_cleanup_scene()

	_print_summary()
	quit(1 if _tests_failed > 0 else 0)


# =========================================================================
# TEST: Movement velocity drives animation state
# =========================================================================

@warning_ignore("unsafe_method_access")
func _test_movement_drives_state() -> void:
	print("─" .repeat(60))
	print("SUITE: Movement → Animation State")
	print("─" .repeat(60))

	_assert(_anim_system != null, "AnimationSystem created")

	# Connect state change tracking
	_state_changes.clear()
	_anim_system.animation_state_changed.connect(_on_state_changed)

	# Check if state machine is available (may fail in headless)
	var am_node: Node = _anim_system.get("animation_manager")
	var has_state_machine: bool = am_node != null and am_node.get("_state_machine") != null
	if not has_state_machine:
		print("  SKIP: State machine not available in headless mode")
		print("  (AnimationTree requires rendering to fully initialize)")
		_anim_system.animation_state_changed.disconnect(_on_state_changed)
		return

	# Initial state should be Idle
	var initial_state: StringName = _anim_system.get_state()
	_assert(initial_state == &"Idle", "Initial state is Idle (got: %s)" % initial_state)

	# Walking velocity → Walk state
	_anim_system.update_from_movement(Vector3(0, 0, 1.0), true)
	var walk_state: StringName = _anim_system.get_state()
	_assert(walk_state == &"Walk", "Velocity 1.0 → Walk (got: %s)" % walk_state)

	# Running velocity → Run state
	_anim_system.update_from_movement(Vector3(0, 0, 3.0), true)
	var run_state: StringName = _anim_system.get_state()
	_assert(run_state == &"Run", "Velocity 3.0 → Run (got: %s)" % run_state)

	# Stopped → back to Idle
	_anim_system.update_from_movement(Vector3.ZERO, true)
	var idle_state: StringName = _anim_system.get_state()
	_assert(idle_state == &"Idle", "Velocity 0 → Idle (got: %s)" % idle_state)

	# Airborne with upward velocity → Jump
	_anim_system.update_from_movement(Vector3(0, 5.0, 0), false)
	var jump_state: StringName = _anim_system.get_state()
	_assert(jump_state == &"Jump", "Upward + not grounded → Jump (got: %s)" % jump_state)

	# Airborne with downward velocity → Fall
	_anim_system.update_from_movement(Vector3(0, -5.0, 0), false)
	var fall_state: StringName = _anim_system.get_state()
	_assert(fall_state == &"Fall", "Downward + not grounded → Fall (got: %s)" % fall_state)

	# Verify state change signals fired
	_assert(_state_changes.size() >= 4, "State change signals fired (%d)" % _state_changes.size())

	_anim_system.animation_state_changed.disconnect(_on_state_changed)


# =========================================================================
# TEST: Text key signals propagate through CharacterAnimationSystem
# =========================================================================

@warning_ignore("unsafe_method_access")
func _test_text_key_signal_forwarding() -> void:
	print("─" .repeat(60))
	print("SUITE: Text Key Signal Forwarding")
	print("─" .repeat(60))

	# Connect signal trackers on CharacterAnimationSystem
	_sounds.clear()
	_hits.clear()
	_footsteps.clear()
	_anim_system.sound_triggered.connect(_on_sound)
	_anim_system.hit_triggered.connect(_on_hit)
	_anim_system.footstep_triggered.connect(_on_footstep)

	# Get the AnimationManager and emit signals through it
	var am_node: Node = _anim_system.get("animation_manager")
	_assert(am_node != null, "AnimationManager accessible from system")
	if not am_node:
		return

	# Emit through AnimationManager → should propagate to CharacterAnimationSystem
	am_node.sound_triggered.emit("test_sound", Vector3(1, 2, 3))
	_assert(_sounds.size() == 1, "Sound signal propagated to system")
	if _sounds.size() > 0:
		_assert(_sounds[0]["id"] == "test_sound", "Sound ID correct")

	am_node.hit_triggered.emit(Vector3(4, 5, 6))
	_assert(_hits.size() == 1, "Hit signal propagated to system")

	am_node.footstep_triggered.emit("left", Vector3(7, 8, 9))
	_assert(_footsteps.size() == 1, "Footstep signal propagated to system")
	if _footsteps.size() > 0:
		_assert(_footsteps[0]["foot"] == "left", "Footstep side correct")

	_anim_system.sound_triggered.disconnect(_on_sound)
	_anim_system.hit_triggered.disconnect(_on_hit)
	_anim_system.footstep_triggered.disconnect(_on_footstep)


# =========================================================================
# TEST: Text key registration flows through to handler
# =========================================================================

@warning_ignore("unsafe_method_access")
func _test_text_key_registration() -> void:
	print("─" .repeat(60))
	print("SUITE: Text Key Registration")
	print("─" .repeat(60))

	# Register text keys through CharacterAnimationSystem convenience method
	var test_keys: Array = [
		{"time": 0.0, "name": "start"},
		{"time": 0.3, "name": "Sound: footL"},
		{"time": 0.6, "name": "Sound: footR"},
		{"time": 1.0, "name": "stop"},
	]

	# Should not error — proves the call chain works
	_anim_system.register_text_keys("idle", test_keys)
	_pass("register_text_keys() called without error")

	# Verify we can query the handler through AnimationManager
	var am_node: Node = _anim_system.get("animation_manager")
	if am_node:
		var hit_time: float = am_node.get_hit_time("nonexistent")
		_assert(hit_time == -1.0, "get_hit_time for missing anim returns -1")


# =========================================================================
# SCENE CREATION & CLEANUP
# =========================================================================

@warning_ignore("unsafe_method_access")
func _create_animated_scene(CAS: GDScript) -> Node3D:
	## Create a minimal scene with skeleton, animations, and animation system
	var root_node := Node3D.new()
	root_node.name = "TestCharacter"

	# Create skeleton
	var skeleton := _create_skeleton()
	root_node.add_child(skeleton)

	# Create AnimationPlayer with mock animations
	var anim_player := AnimationPlayer.new()
	anim_player.name = "AnimationPlayer"
	skeleton.add_child(anim_player)

	# Add mock animations — names must match what AnimationManager._find_animation_for_state_name expects
	var lib := AnimationLibrary.new()
	for anim_name in ["idle", "walk forward", "run forward", "jump", "jump loop"]:
		var anim := Animation.new()
		anim.length = 1.0
		anim.loop_mode = Animation.LOOP_LINEAR
		# Add a dummy bone track so the animation isn't empty
		var track_idx := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(track_idx, ".:Bip01")
		anim.rotation_track_insert_key(track_idx, 0.0, Quaternion.IDENTITY)
		anim.rotation_track_insert_key(track_idx, 1.0, Quaternion.IDENTITY)
		lib.add_animation(anim_name, anim)
	anim_player.add_animation_library("", lib)

	# Create animation system (IK/procedural/LOD disabled — not needed for wiring test)
	_anim_system = CAS.new()
	_anim_system.name = "AnimationSystem"
	_anim_system.set("auto_setup", false)
	_anim_system.set("enable_ik", false)
	_anim_system.set("enable_procedural", false)
	_anim_system.set("enable_lod", false)
	root_node.add_child(_anim_system)

	# Add to scene tree (required for AnimationTree)
	root.add_child(root_node)

	# Setup animation system
	_anim_system.setup(skeleton, null, root_node)

	return root_node


@warning_ignore("unsafe_method_access")
func _cleanup_scene() -> void:
	if not _scene:
		return

	# Deactivate AnimationTree before freeing to avoid headless cleanup issues
	var am_node: Node = _anim_system.get("animation_manager") if _anim_system else null
	if am_node:
		var anim_tree: AnimationTree = am_node.get("animation_tree")
		if anim_tree:
			anim_tree.active = false

	_scene.queue_free()
	_scene = null
	_anim_system = null


func _create_skeleton() -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	var bones := [
		["Bip01", ""],
		["Bip01 Spine", "Bip01"],
		["Bip01 Spine1", "Bip01 Spine"],
		["Bip01 Spine2", "Bip01 Spine1"],
		["Bip01 Neck", "Bip01 Spine2"],
		["Bip01 Head", "Bip01 Neck"],
		["Bip01 L Clavicle", "Bip01 Spine2"],
		["Bip01 L UpperArm", "Bip01 L Clavicle"],
		["Bip01 L Forearm", "Bip01 L UpperArm"],
		["Bip01 L Hand", "Bip01 L Forearm"],
		["Bip01 R Clavicle", "Bip01 Spine2"],
		["Bip01 R UpperArm", "Bip01 R Clavicle"],
		["Bip01 R Forearm", "Bip01 R UpperArm"],
		["Bip01 R Hand", "Bip01 R Forearm"],
		["Bip01 L Thigh", "Bip01"],
		["Bip01 L Calf", "Bip01 L Thigh"],
		["Bip01 L Foot", "Bip01 L Calf"],
		["Bip01 L Toe0", "Bip01 L Foot"],
		["Bip01 R Thigh", "Bip01"],
		["Bip01 R Calf", "Bip01 R Thigh"],
		["Bip01 R Foot", "Bip01 R Calf"],
		["Bip01 R Toe0", "Bip01 R Foot"],
	]

	var indices := {}
	for def in bones:
		var idx := skeleton.add_bone(def[0])
		indices[def[0]] = idx

	for def in bones:
		if not def[1].is_empty() and def[1] in indices:
			skeleton.set_bone_parent(indices[def[0]], indices[def[1]])
		skeleton.set_bone_rest(indices[def[0]], Transform3D(Basis.IDENTITY, Vector3(0, 0.1, 0)))

	return skeleton


# =========================================================================
# SIGNAL HANDLERS
# =========================================================================

func _on_state_changed(old_state: StringName, new_state: StringName) -> void:
	_state_changes.append({"old": old_state, "new": new_state})


func _on_sound(sound_id: String, position: Vector3) -> void:
	_sounds.append({"id": sound_id, "pos": position})


func _on_hit(position: Vector3) -> void:
	_hits.append(position)


func _on_footstep(foot: String, position: Vector3) -> void:
	_footsteps.append({"foot": foot, "pos": position})


# =========================================================================
# TEST HELPERS
# =========================================================================

func _assert(condition: bool, desc: String) -> void:
	if condition:
		_pass(desc)
	else:
		_fail(desc)


func _pass(desc: String) -> void:
	_tests_passed += 1
	print("  PASS: %s" % desc)


func _fail(desc: String) -> void:
	_tests_failed += 1
	print("  FAIL: %s" % desc)


func _print_summary() -> void:
	print("")
	print("=" .repeat(60))
	var total := _tests_passed + _tests_failed
	if _tests_failed == 0:
		print("ALL %d TESTS PASSED" % total)
	else:
		print("%d/%d PASSED (%d FAILED)" % [_tests_passed, total, _tests_failed])
	print("=" .repeat(60))
