## Phase I.1 — Carryable spawn path
##
## Validates the I.1 contract from `docs/INTERACTION_SYSTEM.md` §6.1:
##   - `CarryableRegistry` accepts type registrations + filter Callables
##   - `CarryableBodyFactory.convert_static_to_rigid` swaps an in-place
##     baked StaticBody3D for a RigidBody3D with the right layers, mass,
##     and freeze state, and reparents the original CollisionShape3D
##     children unmodified
##   - The MW adapter (`MWCarryableRegistry`) registers all 12 carryable
##     record types with `weight` extractors, plus the `light` filter that
##     gates on `FLAG_CAN_CARRY`
##   - The interaction raycaster targets the new RigidBody3D body via
##     layer 3 and the `PickupInteractable` child
##
## Test flow (no Morrowind data required — fakes records inline):
##   1. Auto self-test on startup: build a fake "NIF prototype" (Node3D
##      with baked StaticBody3D + box CollisionShape3D), call the factory,
##      assert layers/mass/freeze/PickupInteractable child.
##   2. Spawn 5 props in front of the camera:
##        - sword (WEAP, weight 12)        — carryable
##        - apple (INGR, weight 0.2)       — carryable
##        - book  (BOOK, weight 3)         — carryable
##        - torch (LIGH, FLAG_CAN_CARRY)   — carryable via filter
##        - sconce (LIGH, no flag)         — NOT carryable, stays static
##        - chair (STAT)                   — NOT carryable
##   3. Walk up to each, watch the prompt:
##        - carryables show "[E] Take <name>"
##        - non-carryables show no prompt (or chair shows nothing — no
##          adapter wired for STAT in I.1)
##   4. Tap E on a carryable → log line "Pickup tap: <name> — InventoryService stub"
##
## Run: godot --path . res://tests/visual/test_interaction_phase_I1.tscn
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access")
extends Node

const InteractionRaycasterScript := preload("res://src/core/interaction/interaction_raycaster.gd")
const PlayerControllerScript := preload("res://src/core/player/player_controller.gd")
const CarryableRegistryScript := preload("res://src/core/interaction/carryable_registry.gd")
const CarryableBodyFactoryScript := preload("res://src/core/interaction/carryable_body_factory.gd")
const PickupInteractableScript := preload("res://src/core/interaction/morrowind/pickup_interactable.gd")
const MWCarryableRegistryScript := preload("res://src/core/interaction/morrowind/mw_carryable_registry.gd")

# Fake "ESM record" — duck-typed. CarryableRegistry/MWCarryableRegistry
# only call `rec.weight` and `rec.can_carry()` (the latter for LIGH only),
# so an inner class with the right exported props is enough.
class FakeRecord:
	var record_id: String
	var name: String
	var weight: float
	var _can_carry: bool = true  # only checked for LIGH
	func _init(id: String, n: String, w: float, cc: bool = true) -> void:
		record_id = id
		name = n
		weight = w
		_can_carry = cc
	func can_carry() -> bool:
		return _can_carry


var _player: PlayerController
var _raycaster: InteractionRaycaster
var _prompt_label: Label
var _event_log_label: Label
var _event_lines: Array[String] = []

# Walking state — PlayerController only moves via the full animation
# system stack (MoveContainer). The test scene doesn't load any character
# meshes, so we drive the underlying CharacterBody3D directly with a
# minimal WASD/gravity loop in `_physics_process`.
const WALK_SPEED: float = 4.0
const GRAVITY: float = 18.0
const JUMP_VELOCITY: float = 6.0


func _ready() -> void:
	# Pristine registry — clear any leftover state and re-register MW types.
	CarryableRegistryScript.clear()
	MWCarryableRegistryScript.register_all()

	_run_self_tests()

	_build_world()
	_build_player()
	_spawn_props()
	_build_ui()

	_player.interact_tap.connect(_on_interact_tap)
	_player.interact_hold_begin.connect(_on_interact_hold_begin)
	_player.interact_release.connect(_on_interact_release)
	_raycaster.prompt_changed.connect(_on_prompt_changed)

	_log_event("[I.1 ready] WASD to walk, mouse-look, E to interact")


# ----------------------------------------------------------------------------
# Self-tests (run before scene visuals are built so failures land in the log)
# ----------------------------------------------------------------------------

func _run_self_tests() -> void:
	_test_registry_basic()
	_test_registry_filter()
	_test_factory_swap()


func _test_registry_basic() -> void:
	# MW adapter registered 12 types (11 unconditional + light w/ filter).
	var count: int = CarryableRegistryScript.type_count()
	assert(count == 12, "expected 12 registered MW types, got %d" % count)

	var sword := FakeRecord.new("longsword_steel", "Steel Longsword", 12.0)
	assert(CarryableRegistryScript.is_carryable(&"weapon", sword), "weapon should be carryable")
	assert(CarryableRegistryScript.get_mass(&"weapon", sword) == 12.0, "weapon mass mismatch")

	var apple := FakeRecord.new("ingred_apple_01", "Apple", 0.2)
	assert(CarryableRegistryScript.is_carryable(&"ingredient", apple))
	assert(not CarryableRegistryScript.is_carryable(&"static", apple), "static must not be carryable")

	Log.info("interaction", "[self-test] CarryableRegistry basic — PASS")


func _test_registry_filter() -> void:
	var torch := FakeRecord.new("light_torch_01", "Torch", 1.0, true)
	var sconce := FakeRecord.new("light_sconce_wall_01", "Wall Sconce", 5.0, false)
	assert(CarryableRegistryScript.is_carryable(&"light", torch), "torch should be carryable (FLAG_CAN_CARRY)")
	assert(not CarryableRegistryScript.is_carryable(&"light", sconce), "sconce should NOT be carryable")
	Log.info("interaction", "[self-test] CarryableRegistry LIGH filter — PASS")


func _test_factory_swap() -> void:
	# Build a fake "NIF prototype" with a baked StaticBody3D + CollisionShape3D,
	# convert it, and assert the result.
	var instance := Node3D.new()
	var static_body := StaticBody3D.new()
	static_body.name = "CollisionBody"
	static_body.collision_layer = 1  # original env-only
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.3, 0.5, 0.3)
	shape.shape = box
	static_body.add_child(shape)
	instance.add_child(static_body)

	var rb := CarryableBodyFactoryScript.convert_static_to_rigid(
		instance,
		2.5,
		&"test_record",
		"Test Record",
		PickupInteractableScript,
	)

	assert(rb != null, "factory returned null")
	assert(rb is RigidBody3D, "result is not a RigidBody3D")
	assert(rb.freeze == true, "body should be frozen")
	assert(rb.freeze_mode == RigidBody3D.FREEZE_MODE_KINEMATIC, "freeze_mode should be KINEMATIC")
	assert(rb.collision_layer == CarryableBodyFactoryScript.SPAWN_LAYER,
		"layer mismatch: got %d expected %d" % [rb.collision_layer, CarryableBodyFactoryScript.SPAWN_LAYER])
	assert(rb.collision_mask == CarryableBodyFactoryScript.SPAWN_MASK)
	assert(absf(rb.mass - 2.5) < 0.001, "mass mismatch: got %f" % rb.mass)
	assert(rb.get_meta("carryable") == true)
	assert(rb.get_meta("record_id") == "test_record")

	# Structure check: instance should now contain a PickupInteractable
	# (the wrapper) which contains the RigidBody3D, which contains the
	# reparented CollisionShape3D. The old StaticBody3D should be gone.
	var pickup_wrapper: Interactable = null
	for child in instance.get_children():
		assert(not (child is StaticBody3D), "old StaticBody3D was not removed")
		if child.get_script() == PickupInteractableScript:
			pickup_wrapper = child
	assert(pickup_wrapper != null, "PickupInteractable wrapper not found under instance")
	assert(rb.get_parent() == pickup_wrapper, "RigidBody3D should be a direct child of the Pickup wrapper")

	var shapes_under_rb: int = 0
	for child in rb.get_children():
		if child is CollisionShape3D:
			shapes_under_rb += 1
	assert(shapes_under_rb == 1, "expected 1 collision shape under RB, got %d" % shapes_under_rb)

	# Walk-up check: simulate what InteractionRaycaster does — confirm
	# walking up from the rigid body lands on the PickupInteractable.
	var walk: Node = rb
	var found_interactable: Interactable = null
	while walk != null:
		if walk is Interactable:
			found_interactable = walk
			break
		walk = walk.get_parent()
	assert(found_interactable == pickup_wrapper,
		"raycaster walk-up did not find Pickup wrapper from RigidBody3D")

	# Mass clamping check.
	var heavy_instance := Node3D.new()
	var heavy_body := StaticBody3D.new()
	heavy_body.add_child(_make_box_shape(Vector3.ONE))
	heavy_instance.add_child(heavy_body)
	var heavy_rb := CarryableBodyFactoryScript.convert_static_to_rigid(
		heavy_instance, 9999.0, &"heavy", "Heavy", PickupInteractableScript)
	assert(heavy_rb.mass == CarryableBodyFactoryScript.MASS_MAX_KG,
		"heavy mass should clamp to MASS_MAX_KG")
	heavy_instance.queue_free()

	instance.queue_free()
	Log.info("interaction", "[self-test] CarryableBodyFactory swap — PASS")


func _make_box_shape(size: Vector3) -> CollisionShape3D:
	var s := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size
	s.shape = b
	return s


# ----------------------------------------------------------------------------
# Scene construction
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


# Spawn props by going through the same code path as the cell instantiator:
# build a fake NIF-style prototype (mesh + StaticBody3D + CollisionShape3D),
# call the body factory if the type is carryable. Each prop is parented to
# a positioned Node3D so the world layout is stable.
func _spawn_props() -> void:
	# (label, position, type_name, fake_record, mesh_size, color)
	var props: Array = [
		["sword",  Vector3(-3.0, 0.6,  0), &"weapon",     FakeRecord.new("longsword_steel", "Steel Longsword", 12.0), Vector3(0.1, 0.1, 1.0), Color(0.7, 0.75, 0.8)],
		["apple",  Vector3(-1.5, 0.6,  0), &"ingredient", FakeRecord.new("ingred_apple_01", "Apple", 0.2),            Vector3(0.15, 0.15, 0.15), Color(0.85, 0.2, 0.2)],
		["book",   Vector3( 0.0, 0.6,  0), &"book",       FakeRecord.new("book_test_01",    "Test Tome", 3.0),        Vector3(0.2, 0.3, 0.05), Color(0.5, 0.25, 0.15)],
		["torch",  Vector3( 1.5, 0.6,  0), &"light",      FakeRecord.new("light_torch_01",  "Torch", 1.0, true),      Vector3(0.1, 0.5, 0.1), Color(0.9, 0.6, 0.2)],
		["sconce", Vector3( 3.0, 0.6,  0), &"light",      FakeRecord.new("light_sconce_01", "Wall Sconce", 5.0, false), Vector3(0.3, 0.3, 0.3), Color(0.5, 0.4, 0.2)],
		["chair",  Vector3( 4.5, 0.6,  0), &"static",     null,                                                       Vector3(0.6, 0.8, 0.6), Color(0.3, 0.25, 0.2)],
	]

	for prop_data in props:
		var label: String = prop_data[0]
		var position: Vector3 = prop_data[1]
		var type_name: StringName = prop_data[2]
		var record: Variant = prop_data[3]
		var mesh_size: Vector3 = prop_data[4]
		var color: Color = prop_data[5]

		var instance := _build_fake_nif_prototype(label, mesh_size, color)
		instance.position = position
		add_child(instance)

		# Replicate the relevant slice of reference_instantiator._instantiate_model_object:
		var is_carryable: bool = CarryableRegistryScript.is_carryable(type_name, record)
		if is_carryable:
			var mass: float = CarryableRegistryScript.get_mass(type_name, record)
			var display_name: String = record.name
			var rb := CarryableBodyFactoryScript.convert_static_to_rigid(
				instance, mass, StringName(record.record_id), display_name, PickupInteractableScript)
			if rb == null:
				_log_event("FAIL: %s factory returned null" % label)
			else:
				_log_event("spawned %s (carryable, %.1f kg)" % [label, rb.mass])
		else:
			_log_event("spawned %s (non-carryable)" % label)


# Mimic the shape of a NIF prototype after conversion: a Node3D root with
# a MeshInstance3D child and a StaticBody3D + CollisionShape3D sibling.
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
# UI + signal wiring
# ----------------------------------------------------------------------------

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
	_event_log_label.offset_bottom = 280
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
	help.offset_bottom = 280
	help.add_theme_font_size_override("font_size", 14)
	help.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.text = "I.1 controls\n  WASD: walk\n  mouse: look around\n  Space: jump\n  E (tap): primary verb on target\n  Esc: release mouse\n\nProps left → right:\n  sword (WEAP)  carryable\n  apple (INGR)  carryable\n  book  (BOOK)  carryable\n  torch (LIGH+) carryable via filter\n  sconce (LIGH-) NOT carryable\n  chair (STAT)  NOT carryable\n\nWalk up to a prop, look at it, tap E."
	layer.add_child(help)


func _physics_process(delta: float) -> void:
	if _player == null:
		return
	# WASD walker — replaces the MoveContainer path that PlayerController
	# would normally use. Camera-relative XZ motion + simple gravity.
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


func _on_prompt_changed(interactable: Interactable, distance: float) -> void:
	if interactable == null:
		_prompt_label.text = ""
		return
	_prompt_label.text = "[E] %s  (%.1fm)" % [interactable.get_prompt_text(), distance]


func _on_interact_tap() -> void:
	# Don't call target.interact() here — PlayerController._emit_interact_tap
	# already routes the tap to the raycaster's current target. This handler
	# is for logging/observation only.
	var target := _raycaster.get_current_target()
	var name_str: String = "(no target)" if target == null else String(target.name)
	_log_event("interact_tap → %s" % name_str)


func _on_interact_hold_begin() -> void:
	var target := _raycaster.get_current_target()
	var name_str: String = "(no target)" if target == null else String(target.name)
	_log_event("interact_hold_begin → %s" % name_str)


func _on_interact_release() -> void:
	_log_event("interact_release")


func _log_event(line: String) -> void:
	_event_lines.append("%s  %s" % [Time.get_time_string_from_system(), line])
	while _event_lines.size() > 14:
		_event_lines.pop_front()
	if _event_log_label != null:
		_event_log_label.text = "\n".join(_event_lines)
	Log.info("interaction", line)
