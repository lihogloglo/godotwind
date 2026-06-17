## Phase I.7 — door / container / activator adapters + sig 11 shutdown fix
##
## Validates the I.7 contract from `docs/INTERACTION_SYSTEM.md` §17.4:
##   - DoorInteractable adapter — wraps DOOR records, emits door_activated signal
##   - ContainerInteractable adapter — wraps CONT records, emits container_opened
##   - ActivatorInteractable adapter — wraps ACTI records, emits activator_triggered
##   - Carry-mode exclusivity — already gated upstream in PlayerController._emit_interact_tap
##   - Sig 11 shutdown crash fix — CarryController._exit_tree releases held body
##
## Self-tests:
##   1. DoorInteractable — get_prompt_text returns "Open <name>" / "Travel to <dest>"
##      depending on has_destination, interact() emits door_activated with payload
##   2. ContainerInteractable — get_prompt_text shows "(Locked)" suffix when locked,
##      interact() refuses with locked + emits container_refused, otherwise
##      emits container_opened
##   3. ActivatorInteractable — get_prompt_text returns "Activate <name>",
##      interact() emits activator_triggered with script_id payload
##   4. Sig 11 fix — CarryController._exit_tree restores held body to canonical
##      Jolt state without crashing (smoke test, won't reproduce the actual
##      shutdown crash because we can't tear down a SceneTree from inside it)
##
## Interactive test:
##   - 4 props: door, container (unlocked), container (locked), activator.
##   - Tap E on each, watch the chat log for the right signal + prompt format.
##
## Run: godot --path . res://tests/visual/test_interaction_phase_I7.tscn
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access", "unsafe_cast")
extends Node

const InteractionRaycasterScript := preload("res://src/core/interaction/interaction_raycaster.gd")
const PlayerControllerScript := preload("res://src/core/player/player_controller.gd")
const CarryControllerScript := preload("res://src/core/interaction/carry_controller.gd")
const DoorInteractableScript := preload("res://src/core/interaction/morrowind/door_interactable.gd")
const ContainerInteractableScript := preload("res://src/core/interaction/morrowind/container_interactable.gd")
const ActivatorInteractableScript := preload("res://src/core/interaction/morrowind/activator_interactable.gd")


var _player: PlayerController
var _raycaster: InteractionRaycaster
var _carry: Node
var _prompt_label: Label
var _event_log_label: Label
var _event_lines: Array[String] = []


func _ready() -> void:
	_run_self_tests()

	_build_world()
	_build_player()
	_spawn_props()
	_build_ui()

	_player.interact_tap.connect(_on_interact_tap)
	_raycaster.prompt_changed.connect(_on_prompt_changed)

	_log_event("[I.7 ready] WASD walk · tap E on door/container/activator · check log for signal")


# ----------------------------------------------------------------------------
# Self-tests
# ----------------------------------------------------------------------------

func _run_self_tests() -> void:
	_test_door_interactable()
	_test_container_interactable()
	_test_activator_interactable()
	_test_carry_exit_tree_smoke()
	Log.info("interaction", "[self-test] I.7 door/container/activator + sig11 fix — PASS")


func _test_door_interactable() -> void:
	var door := DoorInteractableScript.new()
	door.record_id = "iron_door_01"
	door.display_name = "Iron Door"

	# Without destination → "Open <name>"
	door.has_destination = false
	assert(door.get_prompt_text() == "Open Iron Door",
		"door prompt wrong: '%s'" % door.get_prompt_text())

	# With destination → "Travel to <dest>"
	door.has_destination = true
	door.destination_name = "Balmora, Mages Guild"
	assert(door.get_prompt_text() == "Travel to Balmora, Mages Guild",
		"door travel prompt wrong: '%s'" % door.get_prompt_text())

	# interact() emits door_activated
	var fired := [false]
	var captured_id := [""]
	var handler := func(record_id: String, _record: Variant, _player: Node3D) -> void:
		fired[0] = true
		captured_id[0] = record_id
	door.door_activated.connect(handler)
	door.interact(null)
	assert(fired[0], "door_activated signal didn't fire")
	assert(captured_id[0] == "iron_door_01", "wrong record_id captured")

	door.queue_free()


func _test_container_interactable() -> void:
	var box := ContainerInteractableScript.new()
	box.record_id = "iron_crate_01"
	box.display_name = "Iron Crate"

	# Unlocked → "Open <name>"
	assert(box.get_prompt_text() == "Open Iron Crate",
		"container prompt wrong: '%s'" % box.get_prompt_text())

	# Locked → "Open <name> (Locked)"
	box.locked = true
	box.lock_level = 25
	assert(box.get_prompt_text() == "Open Iron Crate (Locked)",
		"locked prompt wrong: '%s'" % box.get_prompt_text())

	# interact() refuses when locked
	var refused := [false]
	box.container_refused.connect(func(_record_id: String, _reason: String) -> void:
		refused[0] = true)
	box.interact(null)
	assert(refused[0], "locked container should fire container_refused")

	# Unlock and re-test → emits container_opened
	box.locked = false
	var opened := [false]
	box.container_opened.connect(func(_record_id: String, _record: Variant, _player: Node3D) -> void:
		opened[0] = true)
	box.interact(null)
	assert(opened[0], "unlocked container should fire container_opened")

	box.queue_free()


func _test_activator_interactable() -> void:
	var act := ActivatorInteractableScript.new()
	act.record_id = "lever_01"
	act.display_name = "Stone Lever"
	act.script_id = "lever_open_door_script"

	assert(act.get_prompt_text() == "Activate Stone Lever",
		"activator prompt wrong: '%s'" % act.get_prompt_text())

	var fired := [false]
	var captured_script := [""]
	act.activator_triggered.connect(func(_record_id: String, _record: Variant, script_id: String, _player: Node3D) -> void:
		fired[0] = true
		captured_script[0] = script_id)
	act.interact(null)
	assert(fired[0], "activator_triggered signal didn't fire")
	assert(captured_script[0] == "lever_open_door_script",
		"wrong script_id captured: '%s'" % captured_script[0])

	act.queue_free()


# Sig 11 fix smoke test — can't reproduce the actual shutdown crash
# inside the test, but we verify _exit_tree doesn't crash on a held body
func _test_carry_exit_tree_smoke() -> void:
	var harness := Node3D.new()
	add_child(harness)
	var cam := Camera3D.new()
	harness.add_child(cam)
	var carry := CarryControllerScript.new()
	harness.add_child(carry)
	carry.setup(cam, null)

	# Manually inject a fake "held" state — bypasses the normal grab path
	# so the test doesn't depend on a full PickupInteractable spawn.
	var fake_rb := RigidBody3D.new()
	fake_rb.collision_mask = 1 | 2  # Environment + Player
	add_child(fake_rb)
	# Direct field write — exposed as `var _held_body` (underscore prefix
	# but assignable). This is a self-test, not production code.
	carry._held_body = fake_rb
	carry._saved_collision_mask = fake_rb.collision_mask

	# Trigger _exit_tree by removing the carry node from the tree.
	# Sig 11 reproduces (in the buggy version) when this happens with
	# a held body still in the kinematic-frozen direct-write state.
	harness.remove_child(carry)
	carry.free()  # Trigger _exit_tree via free, not queue_free

	# If we got here, _exit_tree didn't crash. Verify the fake_rb was
	# restored to a sane state (mask restored, INHERIT mode, freeze=false).
	assert(fake_rb.collision_mask == 1 | 2, "mask not restored on exit_tree")
	assert(fake_rb.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_INHERIT,
		"interpolation mode not restored")
	assert(not fake_rb.freeze, "freeze not cleared on exit_tree")

	fake_rb.queue_free()
	harness.queue_free()


# ----------------------------------------------------------------------------
# Scene + props
# ----------------------------------------------------------------------------

func _build_world() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	add_child(floor_body)
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(20, 0.2, 20)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	var floor_mesh := MeshInstance3D.new()
	var fmesh := BoxMesh.new()
	fmesh.size = Vector3(20, 0.2, 20)
	floor_mesh.mesh = fmesh
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.3, 0.3, 0.35)
	floor_mesh.material_override = fmat
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
	_player.position = Vector3(0, 0.5, 5)
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

	_carry = CarryControllerScript.new()
	_carry.name = "CarryController"
	_player.add_child(_carry)
	_carry.setup(_player.get_camera(), _player)
	_player.set_carry_controller(_carry)


func _spawn_props() -> void:
	# Door — emits door_activated on tap
	var door := _make_prop("door", Vector3(-3, 0.9, 0), Color(0.4, 0.25, 0.15),
		Vector3(0.2, 1.8, 1.0))
	var door_adapter := DoorInteractableScript.new()
	door_adapter.record_id = "door_test_01"
	door_adapter.display_name = "Iron Door"
	door_adapter.has_destination = true
	door_adapter.destination_name = "Test Destination"
	_wrap_prop_with_interactable(door, door_adapter)
	door_adapter.door_activated.connect(_on_door_activated)

	# Container (unlocked) — emits container_opened on tap
	var box := _make_prop("box", Vector3(-1, 0.4, 0), Color(0.5, 0.4, 0.25),
		Vector3(0.8, 0.8, 0.8))
	var box_adapter := ContainerInteractableScript.new()
	box_adapter.record_id = "crate_test_01"
	box_adapter.display_name = "Wooden Crate"
	_wrap_prop_with_interactable(box, box_adapter)
	box_adapter.container_opened.connect(_on_container_opened)

	# Container (locked) — refuses on tap
	var locked := _make_prop("locked_box", Vector3(1, 0.4, 0), Color(0.4, 0.3, 0.15),
		Vector3(0.8, 0.8, 0.8))
	var locked_adapter := ContainerInteractableScript.new()
	locked_adapter.record_id = "crate_locked_01"
	locked_adapter.display_name = "Locked Strongbox"
	locked_adapter.locked = true
	locked_adapter.lock_level = 50
	_wrap_prop_with_interactable(locked, locked_adapter)
	locked_adapter.container_refused.connect(_on_container_refused)
	locked_adapter.container_opened.connect(_on_container_opened)

	# Activator — emits activator_triggered
	var lever := _make_prop("lever", Vector3(3, 0.6, 0), Color(0.5, 0.5, 0.55),
		Vector3(0.2, 1.2, 0.2))
	var lever_adapter := ActivatorInteractableScript.new()
	lever_adapter.record_id = "lever_test_01"
	lever_adapter.display_name = "Stone Lever"
	lever_adapter.script_id = "test_lever_script"
	_wrap_prop_with_interactable(lever, lever_adapter)
	lever_adapter.activator_triggered.connect(_on_activator_triggered)


func _wrap_prop_with_interactable(prop: Node3D, interactable: Interactable) -> void:
	var parent := prop.get_parent()
	if parent == null:
		return
	interactable.name = "%s_Interactable" % prop.name
	interactable.transform = prop.transform
	prop.transform = Transform3D.IDENTITY
	parent.remove_child(prop)
	parent.add_child(interactable)
	interactable.add_child(prop)


func _make_prop(label: String, pos: Vector3, color: Color, size: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "Prop_%s" % label
	root.position = pos

	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh_inst.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh_inst.material_override = mat
	root.add_child(mesh_inst)

	var body := StaticBody3D.new()
	body.collision_layer = 1 | 4  # Environment + Interactable
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)
	root.add_child(body)

	add_child(root)
	return root


# ----------------------------------------------------------------------------
# Walking
# ----------------------------------------------------------------------------

const WALK_SPEED: float = 4.0
const GRAVITY: float = 18.0
const JUMP_VELOCITY: float = 6.0


func _physics_process(delta: float) -> void:
	if _player == null:
		return
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
# UI + signal handlers
# ----------------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

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
	layer.add_child(_prompt_label)

	_event_log_label = Label.new()
	_event_log_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_event_log_label.offset_left = 16
	_event_log_label.offset_top = 16
	_event_log_label.offset_right = 700
	_event_log_label.offset_bottom = 380
	_event_log_label.add_theme_font_size_override("font_size", 14)
	_event_log_label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	_event_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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
	help.text = "I.7 controls\n  WASD walk, mouse look\n  Tap E on:\n    door — Travel to <dest>\n    crate — Open\n    locked strongbox — refused\n    lever — Activate\n\nWatch the log for the right signal\non each tap.\n\nClose window — should NOT crash\n(sig 11 fix in CarryController._exit_tree)"
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


func _on_door_activated(record_id: String, _record: Variant, _player: Node3D) -> void:
	_log_event("door_activated: %s" % record_id)


func _on_container_opened(record_id: String, _record: Variant, _player: Node3D) -> void:
	_log_event("container_opened: %s" % record_id)


func _on_container_refused(record_id: String, reason: String) -> void:
	_log_event("container_refused: %s (%s)" % [record_id, reason])


func _on_activator_triggered(record_id: String, _record: Variant, script_id: String, _player: Node3D) -> void:
	_log_event("activator_triggered: %s [script: %s]" % [record_id, script_id])


func _log_event(line: String) -> void:
	_event_lines.append("%s  %s" % [Time.get_time_string_from_system(), line])
	if _event_lines.size() > 16:
		_event_lines.remove_at(0)
	if _event_log_label != null:
		_event_log_label.text = "\n".join(_event_lines)
	Log.info("interaction", line)
