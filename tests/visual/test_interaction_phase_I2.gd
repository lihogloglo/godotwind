## Phase I.2 — PickupInteractable + InventoryService stub
##
## Validates the I.2 contract from `docs/INTERACTION_SYSTEM.md` §7:
##   - `InventoryService` is a registered process-global accessor
##   - `PickupInteractable.interact()` routes through `current().store_item()`
##   - On `OK` result, the carryable RigidBody3D wrapper despawns
##   - On `INVENTORY_FULL` / `FORBIDDEN` / `INVALID_RECORD`, the body
##     stays in world and surfaces a `pickup_refused` signal
##
## Test flow (interactive):
##   1. Walk up to a carryable (sword, apple, book, torch).
##   2. Tap E → log line "Inventory: stored 1 × <id>" + "Pickup taken"
##      → the prop visually disappears.
##   3. Refused-path test: a fake "FORBIDDEN" service is swapped in
##      mid-test (press R to toggle) — taps then refuse and stay in world.
##
## Self-test on startup:
##   - Spawn a fake carryable, swap in a stub service, fire interact(),
##     assert the wrapper is queue_freed.
##
## Run: godot --path . res://tests/visual/test_interaction_phase_I2.tscn
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access")
extends Node

const InteractionRaycasterScript := preload("res://src/core/interaction/interaction_raycaster.gd")
const PlayerControllerScript := preload("res://src/core/player/player_controller.gd")
const CarryableRegistryScript := preload("res://src/core/interaction/carryable_registry.gd")
const CarryableBodyFactoryScript := preload("res://src/core/interaction/carryable_body_factory.gd")
const PickupInteractableScript := preload("res://src/core/interaction/morrowind/pickup_interactable.gd")
const MWCarryableRegistryScript := preload("res://src/core/interaction/morrowind/mw_carryable_registry.gd")
const InventoryServiceScript := preload("res://src/core/interaction/inventory_service.gd")
const MWInventoryServiceScript := preload("res://src/core/interaction/morrowind/mw_inventory_service.gd")


# A fake "always refuses" service for the toggle test.
class RefusingService extends "res://src/core/interaction/inventory_service.gd":
	func store_item(_record_id: StringName, _qty: int = 1) -> int:
		return StoreResult.FORBIDDEN


# Fake record type used by spawn_props (same shape as I.1).
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


const WALK_SPEED: float = 4.0
const GRAVITY: float = 18.0
const JUMP_VELOCITY: float = 6.0

var _player: PlayerController
var _raycaster: InteractionRaycaster
var _prompt_label: Label
var _event_log_label: Label
var _mode_label: Label
var _event_lines: Array[String] = []
var _real_service: Object  # MWInventoryService
var _refusing_service: Object  # RefusingService
var _refusing_active: bool = false


func _ready() -> void:
	# Pristine state — clear and re-register from scratch.
	CarryableRegistryScript.clear()
	MWCarryableRegistryScript.register_all()
	_real_service = MWInventoryServiceScript.new()
	_refusing_service = RefusingService.new()
	InventoryServiceScript.set_current(_real_service)

	_run_self_test()

	_build_world()
	_build_player()
	_spawn_props()
	_build_ui()

	_player.interact_tap.connect(_on_interact_tap)
	_player.interact_hold_begin.connect(_on_interact_hold_begin)
	_player.interact_release.connect(_on_interact_release)
	_raycaster.prompt_changed.connect(_on_prompt_changed)

	_log_event("[I.2 ready] WASD walk, E to take, R to toggle refusing service")


# ----------------------------------------------------------------------------
# Self-test
# ----------------------------------------------------------------------------

func _run_self_test() -> void:
	# Build a fake carryable + visual mesh sibling (mimics the real
	# spawn-path layout), register a stub OK service, fire interact,
	# verify the WHOLE prop root queue_frees — not just the wrapper.
	# This is the assertion that catches bug B (mesh phantom).
	var instance := Node3D.new()
	add_child(instance)
	# Visual mesh as a sibling of the body — same shape the factory
	# leaves behind. If despawn only frees the wrapper, this mesh stays
	# orphaned under `instance` and the assertion below catches it.
	var visual_mesh := MeshInstance3D.new()
	visual_mesh.name = "Mesh"
	visual_mesh.mesh = BoxMesh.new()
	instance.add_child(visual_mesh)
	var body := StaticBody3D.new()
	body.add_child(_make_box_shape(Vector3.ONE))
	instance.add_child(body)

	var rb := CarryableBodyFactoryScript.convert_static_to_rigid(
		instance, 1.0, &"selftest_item", "Self Test", PickupInteractableScript)
	assert(rb != null, "self-test factory returned null")

	# MF3 verification — factory must tag the prop root.
	assert(instance.has_meta("carryable_wrapper"),
		"factory did not set carryable_wrapper meta on prop root")

	# Find the wrapper (Pickup parent of rb).
	var wrapper: Node = rb.get_parent()
	assert(wrapper is Interactable, "wrapper is not an Interactable")
	assert(wrapper.get_parent() == instance, "wrapper parent should be the prop root")

	InventoryServiceScript.set_current(_real_service)
	wrapper.interact(_player_stub())
	# queue_free is deferred; await two frames to let it land + the
	# physics tick after.
	await get_tree().process_frame
	await get_tree().process_frame

	# MF6 — assert the WHOLE prop root is gone, not just the wrapper.
	# Bug B was wrapper-only despawn leaving the mesh as a phantom.
	assert(not is_instance_valid(instance),
		"prop root should have been freed (bug B regression — mesh phantom)")
	assert(not is_instance_valid(wrapper),
		"wrapper should be freed transitively with the prop root")
	assert(not is_instance_valid(visual_mesh),
		"visual mesh sibling should be freed transitively with the prop root")

	# Refused path: build another with the visual mesh sibling, swap to
	# refusing service, interact, verify the prop root is STILL alive.
	var instance2 := Node3D.new()
	add_child(instance2)
	var visual_mesh2 := MeshInstance3D.new()
	visual_mesh2.mesh = BoxMesh.new()
	instance2.add_child(visual_mesh2)
	var body2 := StaticBody3D.new()
	body2.add_child(_make_box_shape(Vector3.ONE))
	instance2.add_child(body2)
	var rb2 := CarryableBodyFactoryScript.convert_static_to_rigid(
		instance2, 1.0, &"selftest_item2", "Self Test 2", PickupInteractableScript)
	var wrapper2: Node = rb2.get_parent()
	InventoryServiceScript.set_current(_refusing_service)
	wrapper2.interact(_player_stub())
	await get_tree().process_frame
	assert(is_instance_valid(instance2), "prop root should NOT have been freed on FORBIDDEN")
	assert(is_instance_valid(wrapper2), "wrapper should NOT have been freed on FORBIDDEN")
	instance2.queue_free()

	# Restore real service for the interactive scene.
	InventoryServiceScript.set_current(_real_service)
	Log.info("interaction", "[self-test] InventoryService routing + despawn side-effect — PASS")


func _player_stub() -> Node3D:
	# A throwaway Node3D — PickupInteractable.interact() only forwards it
	# to super.interact(player) which emits a signal nobody listens to.
	return Node3D.new()


func _make_box_shape(size: Vector3) -> CollisionShape3D:
	var s := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size
	s.shape = b
	return s


# ----------------------------------------------------------------------------
# Scene + props (mirror of I.1)
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
		var mesh_size: Vector3 = prop_data[4]
		var color: Color = prop_data[5]

		var instance := _build_fake_nif_prototype(label, mesh_size, color)
		instance.position = pos
		add_child(instance)

		var mass: float = CarryableRegistryScript.get_mass(type_name, record)
		var rb := CarryableBodyFactoryScript.convert_static_to_rigid(
			instance, mass, StringName(record.record_id), record.name, PickupInteractableScript)
		if rb != null:
			# Wire the refused/taken signals so the test scene can react.
			var pickup: Node = rb.get_parent()
			pickup.connect("pickup_taken", _on_pickup_taken)
			pickup.connect("pickup_refused", _on_pickup_refused)
		_log_event("spawned %s" % label)


func _build_fake_nif_prototype(label: String, size: Vector3, color: Color) -> Node3D:
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
# Walking + UI
# ----------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _player == null:
		return
	var input_dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		input_dir.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		input_dir.y += 1.0
	if Input.is_key_pressed(KEY_A):
		input_dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1.0
	if input_dir != Vector2.ZERO:
		input_dir = input_dir.normalized()

	var cam := _player.get_camera()
	var cam_basis := cam.global_transform.basis
	var forward := -Vector3(cam_basis.z.x, 0, cam_basis.z.z).normalized()
	var right := Vector3(cam_basis.x.x, 0, cam_basis.x.z).normalized()
	var move := (right * input_dir.x + forward * -input_dir.y) * WALK_SPEED

	_player.velocity.x = move.x
	_player.velocity.z = move.z

	if _player.is_on_floor():
		if Input.is_key_pressed(KEY_SPACE):
			_player.velocity.y = JUMP_VELOCITY
	else:
		_player.velocity.y -= GRAVITY * delta

	_player.move_and_slide()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_R:
		_toggle_refusing_service()


func _toggle_refusing_service() -> void:
	_refusing_active = not _refusing_active
	if _refusing_active:
		InventoryServiceScript.set_current(_refusing_service)
		_log_event("InventoryService → REFUSING (FORBIDDEN)")
	else:
		InventoryServiceScript.set_current(_real_service)
		_log_event("InventoryService → REAL (OK)")
	_update_mode_label()


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)

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

	_mode_label = Label.new()
	_mode_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_mode_label.offset_left = 16
	_mode_label.offset_top = -40
	_mode_label.offset_right = 600
	_mode_label.offset_bottom = -16
	_mode_label.add_theme_font_size_override("font_size", 16)
	_mode_label.add_theme_color_override("font_color", Color(0.7, 1.0, 0.7))
	layer.add_child(_mode_label)
	_update_mode_label()

	var help := Label.new()
	help.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	help.offset_left = -380
	help.offset_top = 16
	help.offset_right = -16
	help.offset_bottom = 320
	help.add_theme_font_size_override("font_size", 14)
	help.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.text = "I.2 controls\n  WASD: walk\n  mouse: look\n  E: take (tap)\n  R: toggle refusing service\n  Esc: release mouse\n\nTap E on a prop:\n  REAL service → log + despawn\n  REFUSING service → log + stays\n\nWalk back over the empty\nspace to confirm props are\nactually gone."
	layer.add_child(help)


func _update_mode_label() -> void:
	if _mode_label == null:
		return
	if _refusing_active:
		_mode_label.text = "Service: REFUSING (FORBIDDEN) — press R to switch"
		_mode_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.7))
	else:
		_mode_label.text = "Service: REAL (OK) — press R to switch"
		_mode_label.add_theme_color_override("font_color", Color(0.7, 1.0, 0.7))


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
	_log_event("interact_hold_begin")


func _on_interact_release() -> void:
	_log_event("interact_release")


func _on_pickup_taken(record_id: String) -> void:
	_log_event("pickup_taken: %s" % record_id)


func _on_pickup_refused(record_id: String, reason: String) -> void:
	_log_event("pickup_refused: %s (%s)" % [record_id, reason])


func _log_event(line: String) -> void:
	_event_lines.append("%s  %s" % [Time.get_time_string_from_system(), line])
	while _event_lines.size() > 16:
		_event_lines.pop_front()
	if _event_log_label != null:
		_event_log_label.text = "\n".join(_event_lines)
	Log.info("interaction", line)
