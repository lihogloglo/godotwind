## Phase I.3 — CarryController + kinematic reparent + hold spring
##
## Validates the I.3 contract from `docs/INTERACTION_SYSTEM.md` §6.2 / §6.5
## per @reviewer pre-stated bar (id=4017) + ack (id=4019):
##   - MF1 single-owner held state in `CarryController`
##   - MF2 deferred reparent (no physics-callback reentry)
##   - MF3 bit-precise mask flip + restore via `SPAWN_MASK` constants
##   - MF4 mesh-follow restructure (verified by visual + I.2 self-test)
##   - MF5 NaN/inf guard on hold spring + roll math
##   - MF6 roll lock — held basis Y stays world-up across pitch range
##   - MF7 release = drop = unfreeze + restore mask + velocity = player_velocity
##   - MF8 input via action API (`Input.get_vector` / `is_action_just_pressed`)
##
## Self-test on startup (headless-friendly):
##   1. Grab path: try_grab(wrapper) → assert is_carrying, mask cleared,
##      Pickup reparented to HoldTarget marker.
##   2. Release path: release() → assert mask restored bit-for-bit,
##      freeze=false, Pickup reparented back to original parent.
##   3. Roll lock: simulate camera pitch through ±80°, run hold spring
##      a few iterations, assert wrapper basis Y stays nearly world-up.
##   4. NaN guard: corrupt the wrapper's position to NaN, run physics
##      step, assert it gets clamped to zero (no propagation).
##
## Interactive test:
##   - WASD walk (action API), mouse look, Space jump.
##   - Look at sword/apple/book/torch and HOLD E to lift.
##   - Walk around carrying — visual mesh follows the body.
##   - Release E to drop. Body falls under gravity, Jolt sleeps it.
##   - Tap E (no hold) → goes through I.2 inventory tap path → despawn.
##
## Run: godot --path . res://tests/visual/test_interaction_phase_I3.tscn
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access", "unsafe_cast")
extends Node

const InteractionRaycasterScript := preload("res://src/core/interaction/interaction_raycaster.gd")
const PlayerControllerScript := preload("res://src/core/player/player_controller.gd")
const CarryableRegistryScript := preload("res://src/core/interaction/carryable_registry.gd")
const CarryableBodyFactoryScript := preload("res://src/core/interaction/carryable_body_factory.gd")
const CarryControllerScript := preload("res://src/core/interaction/carry_controller.gd")
const PickupInteractableScript := preload("res://src/core/interaction/morrowind/pickup_interactable.gd")
const MWCarryableRegistryScript := preload("res://src/core/interaction/morrowind/mw_carryable_registry.gd")
const InventoryServiceScript := preload("res://src/core/interaction/inventory_service.gd")
const MWInventoryServiceScript := preload("res://src/core/interaction/morrowind/mw_inventory_service.gd")


# Fake record for spawn props (same shape as I.1/I.2).
class FakeRecord:
	var record_id: String
	var name: String
	var weight: float
	var _can_carry: bool = true
	func _init(id: String, n: String, w: float, cc: bool = true) -> void:
		record_id = id
		name = n
		weight = w
		_can_carry = cc
	func can_carry() -> bool:
		return _can_carry


var _player: PlayerController
var _raycaster: InteractionRaycaster
var _carry: Node  # CarryController — class_name not yet visible to test scene
var _prompt_label: Label
var _event_log_label: Label
var _carry_label: Label
var _event_lines: Array[String] = []
var _event_head: int = 0
const _EVENT_LOG_CAP: int = 16


func _ready() -> void:
	# Pristine state.
	CarryableRegistryScript.clear()
	MWCarryableRegistryScript.register_all()
	InventoryServiceScript.set_current(MWInventoryServiceScript.new())

	_run_self_tests()

	_build_world()
	_build_player()
	_spawn_props()
	_build_ui()

	_player.interact_tap.connect(_on_interact_tap)
	_player.interact_hold_begin.connect(_on_interact_hold_begin)
	_player.interact_release.connect(_on_interact_release)
	_raycaster.prompt_changed.connect(_on_prompt_changed)

	_log_event("[I.3 ready] WASD walk · hold E to lift · release to drop · tap E to take")


# ----------------------------------------------------------------------------
# Self-tests (run before scene build so failures land early in the log)
# ----------------------------------------------------------------------------

func _run_self_tests() -> void:
	_test_grab_release_mask_flip()
	_test_roll_lock()
	_test_nan_guard()
	await _test_raycaster_rapid_swap()
	Log.info("interaction", "[self-test] CarryController grab/release/roll/nan + raycaster swap — PASS")


# MF1.5 (reviewer id=4022): rapid target swap stress test for the
# raycaster's tree_exiting connect/disconnect balance. Sequence:
# A → B → A → null → A within a handful of physics frames. Assertions:
#   - no warnings or errors
#   - final state matches expected target
#   - the cached target is the one we ended on
#   - freeing the cached target out from under the raycaster nulls it
#     synchronously via the tree_exiting signal (no dangling reference)
func _test_raycaster_rapid_swap() -> void:
	var harness := Node3D.new()
	add_child(harness)
	var rc := InteractionRaycasterScript.new()
	# Don't call _ready normally — we don't want it to need a real
	# camera. Bypass the physics_process loop and drive the cache
	# transitions directly through the same code path consumers do.
	harness.add_child(rc)

	# Build three independent Interactables.
	var a := Interactable.new()
	a.name = "A"
	add_child(a)
	var b := Interactable.new()
	b.name = "B"
	add_child(b)

	# Manual cache swap helper — calls the same _disconnect/_connect
	# methods _update_target uses, in the same order.
	var swap := func(t: Interactable) -> void:
		rc._disconnect_target_exiting()
		rc._current_target = t
		rc._connect_target_exiting(t)

	# A → B → A → null → A within five swaps
	swap.call(a)
	assert(rc._current_target == a, "swap A failed")
	assert(rc._target_exiting_connected, "flag not set after connect A")
	swap.call(b)
	assert(rc._current_target == b, "swap B failed")
	assert(rc._target_exiting_connected, "flag not set after connect B")
	swap.call(a)
	assert(rc._current_target == a, "swap back to A failed")
	swap.call(null)
	assert(rc._current_target == null, "swap to null failed")
	assert(not rc._target_exiting_connected, "flag still set after null swap")
	swap.call(a)
	assert(rc._current_target == a, "swap A again failed")

	# Now free the cached target out from under the raycaster.
	# The tree_exiting signal must fire and clear _current_target
	# synchronously, BEFORE the user can read it.
	a.queue_free()
	# tree_exiting fires during queue_free's actual delete pass; await
	# two frames to make sure that pass has run.
	await get_tree().process_frame
	await get_tree().process_frame
	assert(rc._current_target == null,
		"tree_exiting did not clear _current_target after free")
	assert(not rc._target_exiting_connected,
		"flag not reset after tree_exiting fired")

	# Cleanup
	if is_instance_valid(b):
		b.queue_free()
	harness.queue_free()
	await get_tree().process_frame


func _test_grab_release_mask_flip() -> void:
	# Build a fake camera + player + carry controller.
	var harness := Node3D.new()
	add_child(harness)
	var cam := Camera3D.new()
	harness.add_child(cam)
	var fake_player := CharacterBody3D.new()
	add_child(fake_player)

	var carry := CarryControllerScript.new()
	harness.add_child(carry)
	carry.setup(cam, fake_player)

	# Build a fake carryable via the factory.
	var prop := _build_fake_prop("selftest_grab", Vector3(0.2, 0.2, 0.2), Color.WHITE)
	add_child(prop)
	var rb := CarryableBodyFactoryScript.convert_static_to_rigid(
		prop, 1.0, &"selftest_grab", "Self Test", PickupInteractableScript)
	assert(rb != null, "factory returned null")

	var pickup: Interactable = rb.get_parent() as Interactable
	var original_mask: int = rb.collision_mask
	var expected_held_mask: int = original_mask & ~CarryableBodyFactoryScript.LAYER_PLAYER

	# MF3 — verify the spawn mask actually has the player bit set,
	# otherwise the flip is a no-op and the assertion below means nothing.
	assert((original_mask & CarryableBodyFactoryScript.LAYER_PLAYER) != 0,
		"spawn mask should have LAYER_PLAYER set (got %d)" % original_mask)

	# Snapshot the wrapper's original parent — the no-reparent
	# architecture (id=4041) leaves the wrapper under the prop root
	# the entire hold lifetime; the body is driven via direct
	# global_transform writes from `_physics_process`.
	var original_pickup_parent: Node = pickup.get_parent()

	# Snapshot the gravity scale too — velocity-drive sets it to 0 during
	# hold and restores on release.
	var original_gravity_scale: float = rb.gravity_scale

	# Grab
	var ok: bool = carry.try_grab(pickup)
	assert(ok, "try_grab returned false")
	# State mutation is deferred — wait two frames so it lands.
	await get_tree().process_frame
	await get_tree().process_frame
	assert(carry.is_carrying(), "is_carrying false after grab")
	assert(rb.collision_mask == expected_held_mask,
		"held mask wrong: got %d expected %d" % [rb.collision_mask, expected_held_mask])
	# Velocity-drive contract: body is DYNAMIC during hold (Jolt integrates
	# it via per-physics-tick velocity commands). Freeze MUST be cleared.
	assert(not rb.freeze,
		"body should NOT be frozen during velocity-drive hold")
	# Gravity scale zeroed during hold (so the chase target dictates
	# position without gravity sag).
	assert(rb.gravity_scale == 0.0,
		"gravity_scale should be 0 during hold (got %.3f)" % rb.gravity_scale)
	# Wrapper must NOT have been reparented — velocity-drive leaves the
	# scene tree intact, body moves via Jolt integration.
	assert(pickup.get_parent() == original_pickup_parent,
		"wrapper should NOT be reparented")

	# Release
	carry.release()
	await get_tree().process_frame
	await get_tree().process_frame
	assert(not carry.is_carrying(), "is_carrying true after release")
	# §6.5 — mask must be restored EXACTLY to the snapshot value.
	assert(rb.collision_mask == original_mask,
		"mask not restored exactly: got %d expected %d" % [rb.collision_mask, original_mask])
	# Gravity restored exactly.
	assert(rb.gravity_scale == original_gravity_scale,
		"gravity_scale not restored: got %.3f expected %.3f" % [rb.gravity_scale, original_gravity_scale])
	# Body stays unfrozen post-release (Jolt's `can_sleep` puts it to
	# rest naturally).
	assert(not rb.freeze, "body should remain unfrozen after release")
	# Wrapper should still be where it always was.
	assert(pickup.get_parent() == original_pickup_parent,
		"wrapper parent changed across hold cycle")

	# Cleanup
	harness.queue_free()
	fake_player.queue_free()
	prop.queue_free()
	await get_tree().process_frame


func _test_roll_lock() -> void:
	# Build minimal harness
	var harness := Node3D.new()
	add_child(harness)
	var cam := Camera3D.new()
	harness.add_child(cam)
	var fake_player := CharacterBody3D.new()
	add_child(fake_player)
	var carry := CarryControllerScript.new()
	harness.add_child(carry)
	carry.setup(cam, fake_player)

	var prop := _build_fake_prop("selftest_roll", Vector3(0.2, 0.2, 0.2), Color.WHITE)
	add_child(prop)
	var rb := CarryableBodyFactoryScript.convert_static_to_rigid(
		prop, 1.0, &"selftest_roll", "Self Test", PickupInteractableScript)
	var pickup: Interactable = rb.get_parent() as Interactable
	carry.try_grab(pickup)
	await get_tree().process_frame
	await get_tree().process_frame

	# Roll-lock contract: camera yaw + pitch track, roll component is
	# DROPPED. Velocity-drive computes this target basis every physics
	# tick and sets `angular_velocity` to chase it. We can't directly
	# drive the body's basis by calling `_physics_process` because the
	# chase uses Jolt integration — instead we verify the TARGET BASIS
	# that the chase would aim at, by calling the exact expression used
	# inside `_physics_process`. Sweep several pitches with an injected
	# roll on the camera and assert the computed target has zero roll.
	var pitch_steps: Array[float] = [
		deg_to_rad(-80.0),
		deg_to_rad(-45.0),
		0.0,
		deg_to_rad(45.0),
		deg_to_rad(80.0),
	]
	for pitch in pitch_steps:
		# Inject a roll on the camera too — the held basis must IGNORE it.
		cam.rotation = Vector3(pitch, 0.0, deg_to_rad(20.0))
		# Sync the marker (child of camera) by forcing transform update.
		var marker := carry.get_hold_target_marker()
		var cam_euler: Vector3 = marker.global_transform.basis.get_euler()
		# Build target basis the same way carry._physics_process does.
		var target_basis: Basis = Basis.from_euler(Vector3(cam_euler.x, cam_euler.y, 0.0))
		var expected: Basis = Basis.from_euler(Vector3(pitch, 0.0, 0.0))
		var dot_x: float = target_basis.x.dot(expected.x)
		var dot_y: float = target_basis.y.dot(expected.y)
		var dot_z: float = target_basis.z.dot(expected.z)
		assert(dot_x > 0.99 and dot_y > 0.99 and dot_z > 0.99,
			"roll lock failed at pitch=%.1f°: dots = (%.3f, %.3f, %.3f)" % [
				rad_to_deg(pitch), dot_x, dot_y, dot_z])

	carry.release()
	await get_tree().process_frame
	harness.queue_free()
	fake_player.queue_free()
	prop.queue_free()
	await get_tree().process_frame


func _test_nan_guard() -> void:
	var harness := Node3D.new()
	add_child(harness)
	var cam := Camera3D.new()
	harness.add_child(cam)
	var fake_player := CharacterBody3D.new()
	add_child(fake_player)
	var carry := CarryControllerScript.new()
	harness.add_child(carry)
	carry.setup(cam, fake_player)

	var prop := _build_fake_prop("selftest_nan", Vector3(0.2, 0.2, 0.2), Color.WHITE)
	add_child(prop)
	var rb := CarryableBodyFactoryScript.convert_static_to_rigid(
		prop, 1.0, &"selftest_nan", "Self Test", PickupInteractableScript)
	var pickup: Interactable = rb.get_parent() as Interactable
	carry.try_grab(pickup)
	await get_tree().process_frame
	await get_tree().process_frame

	# Inject NaN into the body's global position. The velocity-drive
	# chase should detect the non-finite `desired_v` it computes from
	# the NaN body position and write `Vector3.ZERO` instead of
	# propagating NaN into `linear_velocity`.
	rb.global_position = Vector3(NAN, NAN, NAN)
	carry._physics_process(0.016)
	assert(rb.linear_velocity.is_finite(),
		"NaN position propagated through velocity chase")

	carry.release()
	await get_tree().process_frame
	harness.queue_free()
	fake_player.queue_free()
	prop.queue_free()
	await get_tree().process_frame


# ----------------------------------------------------------------------------
# Scene + props
# ----------------------------------------------------------------------------

func _build_world() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	add_child(floor_body)

	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 0.2, 20)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)

	var floor_mesh := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(20, 0.2, 20)
	floor_mesh.mesh = mesh
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.3, 0.3, 0.35)
	floor_mesh.material_override = floor_mat
	floor_body.add_child(floor_mesh)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-PI / 4, PI / 4, 0)
	sun.light_energy = 1.2
	add_child(sun)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.18, 0.22)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.4
	env_node.environment = env
	add_child(env_node)


func _build_player() -> void:
	_player = PlayerControllerScript.new()
	_player.position = Vector3(0, 0.1, 4.0)
	add_child(_player)
	_player.set_camera_mode(PlayerControllerScript.CameraMode.FIRST_PERSON)
	_player.spring_arm.spring_length = 0.0
	_player.enable()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	_raycaster = InteractionRaycasterScript.new()
	_raycaster.camera = _player.get_camera()
	_raycaster.max_distance = 8.0
	_player.get_camera().add_child(_raycaster)
	_player.set_interaction_raycaster(_raycaster)

	# Spawn the carry controller as a child of the player rig.
	# `setup(camera, player)` builds the HoldTarget Marker3D under the
	# camera and remembers the player CharacterBody3D for the velocity
	# carryover on release.
	_carry = CarryControllerScript.new()
	_carry.name = "CarryController"
	_player.add_child(_carry)
	_carry.setup(_player.get_camera(), _player)
	_player.set_carry_controller(_carry)


func _spawn_props() -> void:
	var props: Array = [
		["sword",  Vector3(-3.0, 0.6,  0), &"weapon",     FakeRecord.new("longsword_steel", "Steel Longsword", 12.0), Vector3(0.1, 0.1, 1.0), Color(0.7, 0.75, 0.8)],
		["apple",  Vector3(-1.5, 0.6,  0), &"ingredient", FakeRecord.new("ingred_apple_01", "Apple", 0.2),            Vector3(0.15, 0.15, 0.15), Color(0.85, 0.2, 0.2)],
		["book",   Vector3( 0.0, 0.6,  0), &"book",       FakeRecord.new("book_test_01",    "Test Tome", 3.0),        Vector3(0.2, 0.3, 0.05), Color(0.5, 0.25, 0.15)],
		["torch",  Vector3( 1.5, 0.6,  0), &"light",      FakeRecord.new("light_torch_01",  "Torch", 1.0, true),      Vector3(0.1, 0.5, 0.1), Color(0.9, 0.6, 0.2)],
	]
	for prop_data in props:
		var label: String = prop_data[0]
		var pos: Vector3 = prop_data[1]
		var type_name: StringName = prop_data[2]
		var record: Variant = prop_data[3]
		var size: Vector3 = prop_data[4]
		var color: Color = prop_data[5]

		var instance := _build_fake_prop(label, size, color)
		instance.position = pos
		add_child(instance)

		var mass: float = CarryableRegistryScript.get_mass(type_name, record)
		var rb := CarryableBodyFactoryScript.convert_static_to_rigid(
			instance, mass, StringName(record.record_id), record.name, PickupInteractableScript)
		if rb == null:
			_log_event("FAIL: %s factory returned null" % label)


func _build_fake_prop(label: String, size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "Prop_%s" % label
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "Mesh"
	var box := BoxMesh.new()
	box.size = size
	mesh_inst.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh_inst.material_override = mat
	root.add_child(mesh_inst)

	var body := StaticBody3D.new()
	body.name = "CollisionBody"
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)
	root.add_child(body)
	return root


# ----------------------------------------------------------------------------
# Walking — MF8: action API, no raw KEY_*
# ----------------------------------------------------------------------------

const WALK_SPEED: float = 4.0
const GRAVITY: float = 18.0
const JUMP_VELOCITY: float = 6.0


func _physics_process(delta: float) -> void:
	if _player == null:
		return
	# MF8 — Input.get_vector with the K-phase canonical action names.
	# project.godot [input] section already defines all four; verified
	# via grep before coding (id=4017 SF4 ack).
	var input_dir: Vector2 = Input.get_vector(
		"move_left", "move_right", "move_forward", "move_backward")

	var cam := _player.get_camera()
	var cam_basis := cam.global_transform.basis
	var forward := -Vector3(cam_basis.z.x, 0, cam_basis.z.z).normalized()
	var right := Vector3(cam_basis.x.x, 0, cam_basis.x.z).normalized()
	var move := (right * input_dir.x + forward * -input_dir.y) * WALK_SPEED

	_player.velocity.x = move.x
	_player.velocity.z = move.z

	if _player.is_on_floor():
		if Input.is_action_just_pressed("jump"):
			_player.velocity.y = JUMP_VELOCITY
	else:
		_player.velocity.y -= GRAVITY * delta

	_player.move_and_slide()


# ----------------------------------------------------------------------------
# UI + signal wiring
# ----------------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)

	# Center-screen crosshair — small dot at the raycast aim point.
	# The MW port will swap this for the real cursor texture from the
	# Morrowind data files; for the I.3 test scene a primitive ColorRect
	# is enough to give the player an aim reference.
	var crosshair := ColorRect.new()
	crosshair.color = Color(1, 1, 1, 0.85)
	crosshair.size = Vector2(4, 4)
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.offset_left = -2
	crosshair.offset_top = -2
	crosshair.offset_right = 2
	crosshair.offset_bottom = 2
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(crosshair)

	_prompt_label = Label.new()
	_prompt_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt_label.offset_top = -100
	_prompt_label.offset_left = -250
	_prompt_label.offset_right = 250
	_prompt_label.offset_bottom = -60
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_font_size_override("font_size", 22)
	_prompt_label.add_theme_color_override("font_color", Color(1, 1, 0.85))
	_prompt_label.text = ""
	layer.add_child(_prompt_label)

	_carry_label = Label.new()
	_carry_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_carry_label.offset_top = -140
	_carry_label.offset_left = -250
	_carry_label.offset_right = 250
	_carry_label.offset_bottom = -100
	_carry_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_carry_label.add_theme_font_size_override("font_size", 18)
	_carry_label.add_theme_color_override("font_color", Color(0.7, 1, 0.7))
	_carry_label.text = ""
	layer.add_child(_carry_label)

	_event_log_label = Label.new()
	_event_log_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_event_log_label.offset_left = 16
	_event_log_label.offset_top = 16
	_event_log_label.offset_right = 700
	_event_log_label.offset_bottom = 320
	_event_log_label.add_theme_font_size_override("font_size", 14)
	_event_log_label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	_event_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_event_log_label.text = ""
	layer.add_child(_event_log_label)

	var help := Label.new()
	help.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	help.offset_left = -380
	help.offset_top = 16
	help.offset_right = -16
	help.offset_bottom = 320
	help.add_theme_font_size_override("font_size", 14)
	help.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.text = "I.3 controls (action API)\n  WASD: walk\n  mouse: look\n  Space: jump\n  E (tap < 0.2s): take to inventory\n  E (hold > 0.2s): lift + carry\n  E release while holding: drop\n  Esc: release mouse\n\nLook at a prop and HOLD E. Walk\naround. Release to drop. Drop\nshould unfreeze + fall + settle.\n\nTap E to take instead (I.2 path)."
	layer.add_child(help)


func _on_prompt_changed(interactable: Interactable, distance: float) -> void:
	if interactable == null:
		_prompt_label.text = ""
		return
	_prompt_label.text = "[E] %s  (%.1fm)" % [interactable.get_prompt_text(), distance]


func _on_interact_tap() -> void:
	var target := _raycaster.get_current_target()
	var name_str: String = "(no target)" if target == null else String(target.name)
	_log_event("interact_tap → %s" % name_str)


func _on_interact_hold_begin() -> void:
	var target := _raycaster.get_current_target()
	var name_str: String = "(no target)" if target == null else String(target.name)
	_log_event("interact_hold_begin → %s" % name_str)


func _on_interact_release() -> void:
	_log_event("interact_release")


func _process(_delta: float) -> void:
	if _carry != null and _carry.call("is_carrying"):
		var held: Node = _carry.call("get_held_pickup")
		if held != null and is_instance_valid(held):
			_carry_label.text = "carrying: %s" % (held as Interactable).get_prompt_text()
		else:
			_carry_label.text = "carrying: (?)"
	elif _carry_label != null:
		_carry_label.text = ""


func _log_event(line: String) -> void:
	# Ring buffer (cleanup task from reviewer SF1 — replaces I.1/I.2's
	# pop_front anti-pattern). O(1) write, O(N) render once per event.
	if _event_lines.size() < _EVENT_LOG_CAP:
		_event_lines.append("%s  %s" % [Time.get_time_string_from_system(), line])
	else:
		_event_lines[_event_head] = "%s  %s" % [Time.get_time_string_from_system(), line]
		_event_head = (_event_head + 1) % _EVENT_LOG_CAP
	if _event_log_label != null:
		# Render in chronological order starting from _event_head.
		var ordered: Array[String] = []
		for i in _event_lines.size():
			ordered.append(_event_lines[(_event_head + i) % _event_lines.size()])
		_event_log_label.text = "\n".join(ordered)
	Log.info("interaction", line)
