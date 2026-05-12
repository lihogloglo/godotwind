## Focused Phase 2 visual validation for carry prompt suppression.
##
## The scene wires the real PlayerController -> InteractionRaycaster ->
## CarryController path against simple generated props. It makes the Phase 2
## contract easy to inspect:
## - prompts show when aiming at a carryable or activator;
## - holding interact grabs a carryable and suppresses prompts;
## - tapping interact while carrying does not activate the current target;
## - releasing interact drops/throws and prompts return.
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access", "unsafe_cast")
extends Node3D

const InputActionsScript := preload("res://src/core/input/input_actions.gd")
const InteractionRaycasterScript := preload("res://src/core/interaction/interaction_raycaster.gd")
const PlayerControllerScript := preload("res://src/core/player/player_controller.gd")
const CarryableRegistryScript := preload("res://src/core/interaction/carryable_registry.gd")
const CarryableBodyFactoryScript := preload("res://src/core/interaction/carryable_body_factory.gd")
const CarryControllerScript := preload("res://src/core/interaction/carry_controller.gd")
const PickupInteractableScript := preload("res://src/core/interaction/morrowind/pickup_interactable.gd")
const ActivatorInteractableScript := preload("res://src/core/interaction/morrowind/activator_interactable.gd")
const InventoryServiceScript := preload("res://src/core/interaction/inventory_service.gd")
const MWCarryableRegistryScript := preload("res://src/core/interaction/morrowind/mw_carryable_registry.gd")
const MWInventoryServiceScript := preload("res://src/core/interaction/morrowind/mw_inventory_service.gd")

const VALIDATION_CASES: Array[StringName] = [
	&"prompt_visible_before_carry",
	&"prompt_hidden_while_carrying",
	&"tap_ignored_while_carrying",
	&"prompt_returns_after_release",
]

const WALK_SPEED: float = 4.0
const GRAVITY: float = 18.0
const JUMP_VELOCITY: float = 6.0


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
var _carry: CarryController
var _prompt_label: Label
var _carry_status_label: Label
var _event_log_label: Label
var _event_lines: Array[String] = []


func _ready() -> void:
	InputActionsScript.verify()
	CarryableRegistryScript.clear()
	MWCarryableRegistryScript.register_all()
	InventoryServiceScript.set_current(MWInventoryServiceScript.new())

	_create_world()
	_create_player()
	_spawn_validation_props()
	_create_hud()
	_wire_signals()

	_log_event("Carry prompt suppression scene ready")


func get_validation_case_names() -> PackedStringArray:
	var names := PackedStringArray()
	for case_name: StringName in VALIDATION_CASES:
		names.append(String(case_name))
	return names


func get_scene_purpose() -> String:
	return "Phase 2 carry prompt suppression and tap gating visual validation"


func _physics_process(delta: float) -> void:
	if _player == null:
		return
	var input_dir: Vector2 = Input.get_vector(
		&"move_left", &"move_right", &"move_forward", &"move_backward")
	var cam := _player.get_camera()
	var cam_basis := cam.global_transform.basis
	var forward := -Vector3(cam_basis.z.x, 0.0, cam_basis.z.z).normalized()
	var right := Vector3(cam_basis.x.x, 0.0, cam_basis.x.z).normalized()
	var move := (right * input_dir.x + forward * -input_dir.y) * WALK_SPEED

	_player.velocity.x = move.x
	_player.velocity.z = move.z
	if _player.is_on_floor():
		if Input.is_action_just_pressed(&"jump"):
			_player.velocity.y = JUMP_VELOCITY
	else:
		_player.velocity.y -= GRAVITY * delta
	_player.move_and_slide()


func _create_world() -> void:
	_add_box("Floor", Vector3(0.0, -0.1, 0.0), Vector3(18.0, 0.2, 18.0),
		Color(0.30, 0.31, 0.34))
	_add_box("PromptReturnMarker", Vector3(2.6, 0.05, 0.0), Vector3(1.2, 0.1, 1.2),
		Color(0.16, 0.36, 0.58))
	_add_box("CarryPad", Vector3(-1.4, 0.05, 0.0), Vector3(1.2, 0.1, 1.2),
		Color(0.48, 0.34, 0.18))

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(35.0), 0.0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.13, 0.16, 0.19)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.55
	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)


func _create_player() -> void:
	_player = PlayerControllerScript.new() as PlayerController
	_player.name = "CarryPromptPlayer"
	_player.position = Vector3(0.0, 0.5, 5.2)
	add_child(_player)
	_player.set_camera_mode(PlayerController.CameraMode.FIRST_PERSON)
	_player.spring_arm.spring_length = 0.0
	_player.enable()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	_raycaster = InteractionRaycasterScript.new() as InteractionRaycaster
	_raycaster.name = "InteractionRaycaster"
	_raycaster.camera = _player.get_camera()
	_raycaster.max_distance = 8.0
	_player.get_camera().add_child(_raycaster)
	_player.set_interaction_raycaster(_raycaster)

	_carry = CarryControllerScript.new() as CarryController
	_carry.name = "CarryController"
	_player.add_child(_carry)
	_carry.setup(_player.get_camera(), _player)
	_player.set_carry_controller(_carry)


func _spawn_validation_props() -> void:
	_spawn_carryable("barrel", Vector3(-1.4, 0.55, 0.0), &"misc",
		FakeRecord.new("prompt_test_barrel_01", "Prompt Barrel", 5.0),
		Vector3(0.55, 0.70, 0.55), Color(0.52, 0.34, 0.18))

	_spawn_carryable("cup", Vector3(0.0, 0.32, -0.2), &"misc",
		FakeRecord.new("prompt_test_cup_01", "Small Cup", 0.4),
		Vector3(0.28, 0.28, 0.28), Color(0.76, 0.68, 0.47))

	_spawn_activator("activation_pillar", Vector3(2.6, 0.8, 0.0),
		Vector3(0.65, 1.6, 0.65), Color(0.24, 0.46, 0.72))

	_add_label(Vector3(-1.4, 1.35, 0.0), "carryable\nhold interact")
	_add_label(Vector3(0.0, 0.95, -0.2), "second item\nshould not tap while carrying")
	_add_label(Vector3(2.6, 1.95, 0.0), "activator\nprompt returns here")


func _spawn_carryable(label: String, pos: Vector3, type_name: StringName,
		record: Variant, mesh_size: Vector3, color: Color) -> void:
	var instance := _build_fake_prop(label, mesh_size, color)
	instance.position = pos
	add_child(instance)
	var mass: float = CarryableRegistryScript.get_mass(type_name, record)
	var rb := CarryableBodyFactoryScript.convert_static_to_rigid(
		instance, mass, StringName(record.record_id), record.name, PickupInteractableScript)
	if rb == null:
		_log_event("FAILED to spawn carryable %s" % label)
		return
	var pickup := rb.get_parent() as PickupInteractable
	if pickup != null:
		pickup.pickup_taken.connect(_on_pickup_taken)
		pickup.pickup_refused.connect(_on_pickup_refused)


func _build_fake_prop(label: String, size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "Prop_%s" % label

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "Mesh"
	var box := BoxMesh.new()
	box.size = size
	mesh_inst.mesh = box
	mesh_inst.material_override = _make_material(color)
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


func _spawn_activator(label: String, pos: Vector3, size: Vector3, color: Color) -> void:
	var root := Node3D.new()
	root.name = "Prop_%s" % label
	root.position = pos
	root.set_script(ActivatorInteractableScript)
	var activator := root as ActivatorInteractable
	activator.record_id = "prompt_test_activator_01"
	activator.display_name = "Prompt Test Pillar"
	activator.script_id = "prompt_suppression_visual"
	activator.activator_triggered.connect(_on_activator_triggered)

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = _make_material(color)
	root.add_child(mesh)

	var body := StaticBody3D.new()
	body.name = "ActivatorCollision"
	body.collision_layer = 1 | 4
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)
	root.add_child(body)

	add_child(root)


func _create_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "CarryPromptHUD"
	canvas.layer = 5
	add_child(canvas)

	var crosshair := ColorRect.new()
	crosshair.color = Color(1.0, 1.0, 1.0, 0.9)
	crosshair.size = Vector2(4.0, 4.0)
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.offset_left = -2.0
	crosshair.offset_top = -2.0
	crosshair.offset_right = 2.0
	crosshair.offset_bottom = 2.0
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(crosshair)

	_prompt_label = Label.new()
	_prompt_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt_label.offset_left = -320.0
	_prompt_label.offset_top = -112.0
	_prompt_label.offset_right = 320.0
	_prompt_label.offset_bottom = -70.0
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_font_size_override("font_size", 24)
	_prompt_label.add_theme_color_override("font_color", Color(1.0, 0.94, 0.72))
	canvas.add_child(_prompt_label)

	_carry_status_label = Label.new()
	_carry_status_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_carry_status_label.offset_left = -360.0
	_carry_status_label.offset_top = -160.0
	_carry_status_label.offset_right = 360.0
	_carry_status_label.offset_bottom = -120.0
	_carry_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_carry_status_label.add_theme_font_size_override("font_size", 18)
	_carry_status_label.add_theme_color_override("font_color", Color(0.70, 0.95, 1.0))
	_carry_status_label.text = "Not carrying"
	canvas.add_child(_carry_status_label)

	_event_log_label = Label.new()
	_event_log_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_event_log_label.offset_left = 16.0
	_event_log_label.offset_top = 16.0
	_event_log_label.offset_right = 760.0
	_event_log_label.offset_bottom = 360.0
	_event_log_label.add_theme_font_size_override("font_size", 14)
	_event_log_label.add_theme_color_override("font_color", Color(0.86, 0.94, 1.0))
	_event_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	canvas.add_child(_event_log_label)

	var help := Label.new()
	help.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	help.offset_left = -430.0
	help.offset_top = 16.0
	help.offset_right = -16.0
	help.offset_bottom = 330.0
	help.add_theme_font_size_override("font_size", 14)
	help.add_theme_color_override("font_color", Color(1.0, 0.94, 0.74))
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.text = (
		"Carry Prompt Suppression\n"
		+ "Move/look with the normal player controls.\n"
		+ "Aim at a prop: prompt should show.\n"
		+ "Hold interact on a carryable: prompt should disappear while held.\n"
		+ "Tap interact while still carrying: no pickup or activator signal should fire.\n"
		+ "Release interact: prompt should return when aiming at a target."
	)
	canvas.add_child(help)


func _wire_signals() -> void:
	_player.interact_tap.connect(_on_interact_tap)
	_player.interact_hold_begin.connect(_on_interact_hold_begin)
	_player.interact_release.connect(_on_interact_release)
	_raycaster.prompt_changed.connect(_on_prompt_changed)
	_carry.grabbed.connect(_on_carry_grabbed)
	_carry.released.connect(_on_carry_released)
	_carry.grab_refused.connect(_on_grab_refused)


func _on_prompt_changed(interactable: Interactable, distance: float) -> void:
	if interactable == null:
		_prompt_label.text = ""
		return
	_prompt_label.text = "[interact] %s  (%.1fm)" % [interactable.get_prompt_text(), distance]


func _on_carry_grabbed(body: RigidBody3D) -> void:
	_carry_status_label.text = "Carrying %s - prompts suppressed" % body.name
	_log_event("grabbed: %s" % body.name)


func _on_carry_released(body: RigidBody3D) -> void:
	_carry_status_label.text = "Released %s - prompts may return" % body.name
	_log_event("released: %s" % body.name)


func _on_interact_tap() -> void:
	var target := _raycaster.get_current_target()
	var target_name := "(no target)" if target == null else String(target.name)
	if _carry != null and _carry.is_carrying():
		_log_event("tap while carrying was gated before target interact: %s" % target_name)
	else:
		_log_event("tap routed to target: %s" % target_name)


func _on_interact_hold_begin() -> void:
	var target := _raycaster.get_current_target()
	var target_name := "(no target)" if target == null else String(target.name)
	_log_event("hold begin: %s" % target_name)


func _on_interact_release() -> void:
	_log_event("interact release")


func _on_pickup_taken(record_id: String) -> void:
	_log_event("pickup_taken fired: %s" % record_id)


func _on_pickup_refused(record_id: String, reason: String) -> void:
	_log_event("pickup_refused fired: %s (%s)" % [record_id, reason])


func _on_activator_triggered(record_id: String, _record: Variant,
		script_id: String, _player_node: Node3D) -> void:
	_log_event("activator_triggered fired: %s [%s]" % [record_id, script_id])


func _on_grab_refused(reason: String) -> void:
	_log_event("grab_refused: %s" % reason)


func _add_box(box_name: String, pos: Vector3, size: Vector3, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "%sBody" % box_name
	body.position = pos
	body.collision_layer = 1
	body.collision_mask = 0

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)

	var mesh := MeshInstance3D.new()
	mesh.name = box_name
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh.mesh = box_mesh
	mesh.material_override = _make_material(color)
	body.add_child(mesh)

	add_child(body)
	return body


func _add_label(pos: Vector3, text: String) -> void:
	var label := Label3D.new()
	label.name = "Label_%s" % text.replace("\n", "_")
	label.text = text
	label.position = pos
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 28
	label.modulate = Color.WHITE
	add_child(label)


func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


func _log_event(line: String) -> void:
	_event_lines.append("%s  %s" % [Time.get_time_string_from_system(), line])
	if _event_lines.size() > 18:
		_event_lines.remove_at(0)
	if _event_log_label != null:
		_event_log_label.text = "\n".join(_event_lines)
	Log.info("interaction", line)
