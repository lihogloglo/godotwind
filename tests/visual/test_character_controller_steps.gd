## Focused visual measuring rig for the character step solver.
##
## Phase 6 of character-controller productionization keeps the current
## up/forward/down probe architecture and validates it against named scenarios.
@warning_ignore("untyped_declaration", "unsafe_method_access")
extends Node3D

const PlayerControllerScript := preload("res://src/core/player/player_controller.gd")
const DefaultMovementConfig := preload("res://src/core/character/controller/movement_presets/default_movement_config.tres")
const GameplayPhysicsLayersScript := preload("res://src/core/physics/gameplay_physics_layers.gd")
const InputActionsScript := preload("res://src/core/input/input_actions.gd")

const STEP_CASES: Array[StringName] = [
	&"small_step",
	&"tall_wall",
	&"angled_wall",
	&"ceiling_blocked_step",
	&"down_step_no_floor",
	&"rigidbody_obstacle",
]
const RESPAWN_ACTION: StringName = &"step_solver_respawn"
const RESPAWN_POSITION: Vector3 = Vector3(-15.0, 1.1, 8.0)
const FALL_RESPAWN_Y: float = -12.0

var _player_controller: PlayerController


func _ready() -> void:
	InputActionsScript.verify()
	_create_environment()
	_create_step_lanes()
	_create_player()
	_create_hud()


func get_step_case_names() -> PackedStringArray:
	var names := PackedStringArray()
	for step_case: StringName in STEP_CASES:
		names.append(String(step_case))
	return names


func get_respawn_action_name() -> StringName:
	return RESPAWN_ACTION


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(RESPAWN_ACTION):
		_respawn_player()
		get_viewport().set_input_as_handled()


func _physics_process(_delta: float) -> void:
	if _player_controller and _player_controller.global_position.y < FALL_RESPAWN_Y:
		_respawn_player()


func _create_environment() -> void:
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.rotation = Vector3(deg_to_rad(-55.0), deg_to_rad(35.0), 0.0)
	light.light_energy = 1.15
	light.shadow_enabled = true
	add_child(light)

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.55
	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)


func _create_step_lanes() -> void:
	_add_lane_floor("SmallStep", -15.0, 0.0, true, 0.30)
	_add_box("SmallStep_Block", Vector3(-15.0, 0.15, 0.0), Vector3(2.4, 0.30, 1.0),
		Color(0.35, 0.62, 0.40))
	_add_label(Vector3(-15.0, 1.15, 0.0), "small step\nclimb")

	_add_lane_floor("TallWall", -9.0, 0.0, true, 0.0)
	_add_box("TallWall_Block", Vector3(-9.0, 0.70, 0.0), Vector3(2.4, 1.40, 0.6),
		Color(0.65, 0.32, 0.30))
	_add_label(Vector3(-9.0, 1.75, 0.0), "tall wall\nblock")

	_add_lane_floor("AngledWall", -3.0, 0.0, true, 0.0)
	_add_box("AngledWall_Block", Vector3(-3.0, 0.60, 0.0), Vector3(3.3, 1.20, 0.35),
		Color(0.62, 0.50, 0.28), deg_to_rad(35.0))
	_add_label(Vector3(-3.0, 1.55, 0.0), "angled wall\nslide/block")

	_add_lane_floor("CeilingStep", 3.0, 0.0, true, 0.30)
	_add_box("CeilingStep_Block", Vector3(3.0, 0.15, 0.0), Vector3(2.4, 0.30, 1.0),
		Color(0.35, 0.48, 0.72))
	_add_box("CeilingStep_Overhead", Vector3(3.0, 1.78, -0.2), Vector3(2.8, 0.24, 2.5),
		Color(0.30, 0.34, 0.45))
	_add_label(Vector3(3.0, 2.20, 0.0), "ceiling step\nno pop-through")

	_add_lane_floor("NoFloorStep", 9.0, 0.0, false, 0.0)
	_add_box("NoFloorStep_Block", Vector3(9.0, 0.15, 0.0), Vector3(2.4, 0.30, 1.0),
		Color(0.55, 0.42, 0.70))
	_add_void_marker(Vector3(9.0, -1.0, -4.5), Vector2(3.2, 7.0))
	_add_label(Vector3(9.0, 1.15, 0.0), "edge lip\nfalling is ok")
	_add_label(Vector3(9.0, 0.45, -4.5), "void marker\nno collision")

	_add_lane_floor("RigidBody", 15.0, 0.0, true, 0.0)
	_add_box("RigidBody_CrateSupport", Vector3(15.0, -0.05, 0.0), Vector3(3.2, 0.10, 1.4),
		Color(0.34, 0.38, 0.34))
	_add_rigidbody_sphere("RigidBody_PushTarget", Vector3(15.0, 0.45, 0.0), 0.45,
		Color(0.95, 0.54, 0.12))
	_add_label(Vector3(15.0, 1.45, 0.0), "pushable rigidbody\nno climb")


func _add_lane_floor(prefix: String, x: float, approach_y: float,
		has_landing: bool, landing_y: float) -> void:
	_add_box("%s_ApproachFloor" % prefix, Vector3(x, approach_y - 0.05, 5.0),
		Vector3(3.2, 0.10, 9.0), Color(0.34, 0.38, 0.34))
	if has_landing:
		_add_box("%s_LandingFloor" % prefix, Vector3(x, landing_y - 0.05, -5.0),
			Vector3(3.2, 0.10, 9.0), Color(0.34, 0.38, 0.34))


func _add_box(box_name: String, pos: Vector3, size: Vector3, color: Color,
		rotation_y: float = 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "%sBody" % box_name
	body.position = pos
	body.rotation.y = rotation_y
	body.collision_layer = GameplayPhysicsLayersScript.ENVIRONMENT
	body.collision_mask = GameplayPhysicsLayersScript.PLAYER | GameplayPhysicsLayersScript.ENVIRONMENT

	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)

	var mesh := MeshInstance3D.new()
	mesh.name = box_name
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh.mesh = box_mesh
	mesh.material_override = _make_material(color)
	body.add_child(mesh)

	add_child(body)
	return body


func _add_rigidbody_box(box_name: String, pos: Vector3, size: Vector3,
		color: Color) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = box_name
	body.mass = 1.0
	body.position = pos
	body.collision_layer = GameplayPhysicsLayersScript.ENVIRONMENT
	body.collision_mask = GameplayPhysicsLayersScript.ENVIRONMENT | GameplayPhysicsLayersScript.PLAYER

	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)

	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh.mesh = box_mesh
	mesh.material_override = _make_material(color)
	body.add_child(mesh)

	add_child(body)
	return body


func _add_rigidbody_sphere(sphere_name: String, pos: Vector3, radius: float,
		color: Color) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = sphere_name
	body.mass = 0.5
	body.position = pos
	body.collision_layer = GameplayPhysicsLayersScript.ENVIRONMENT
	body.collision_mask = GameplayPhysicsLayersScript.ENVIRONMENT | GameplayPhysicsLayersScript.PLAYER
	body.physics_material_override = PhysicsMaterial.new()
	body.physics_material_override.friction = 0.15
	body.physics_material_override.bounce = 0.0

	var shape := SphereShape3D.new()
	shape.radius = radius
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)

	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	mesh.mesh = sphere
	mesh.material_override = _make_material(color)
	body.add_child(mesh)

	add_child(body)
	return body


func _add_void_marker(pos: Vector3, size: Vector2) -> void:
	var marker := MeshInstance3D.new()
	marker.name = "NoFloorStep_VoidMarker"
	var plane := PlaneMesh.new()
	plane.size = size
	marker.mesh = plane
	marker.position = pos
	var mat := _make_material(Color(0.85, 0.08, 0.05, 0.45))
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker.material_override = mat
	add_child(marker)


func _create_player() -> void:
	_player_controller = PlayerControllerScript.new() as PlayerController
	_player_controller.name = "StepSolverPlayer"
	_player_controller.movement_config = DefaultMovementConfig.duplicate(true) as CharacterMovementConfig
	add_child(_player_controller)
	_player_controller.global_position = RESPAWN_POSITION

	var visual_root := Node3D.new()
	visual_root.name = "CapsuleVisualRoot"
	_add_player_capsule_visual(visual_root)
	_player_controller.attach_character(visual_root, null)
	_player_controller.set_camera_mode(PlayerController.CameraMode.THIRD_PERSON)
	_player_controller.enable()


func _add_player_capsule_visual(parent: Node3D) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = "CapsulePreview"
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	mesh.mesh = capsule
	mesh.position.y = 0.9
	mesh.material_override = _make_material(Color(0.88, 0.88, 0.92))
	parent.add_child(mesh)

	var forward := MeshInstance3D.new()
	forward.name = "ForwardMarker"
	var marker := BoxMesh.new()
	marker.size = Vector3(0.10, 0.10, 0.60)
	forward.mesh = marker
	forward.position = Vector3(0.0, 1.0, -0.45)
	forward.material_override = _make_material(Color(0.95, 0.22, 0.18))
	parent.add_child(forward)


func _create_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "StepSolverHUD"
	add_child(canvas)

	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.position = Vector2(12, 12)
	label.size = Vector2(520, 150)
	label.add_theme_font_size_override("normal_font_size", 15)
	label.add_theme_color_override("default_color", Color.WHITE)
	label.text = (
		"[b]Step Solver Contract[/b]\n"
		+ "WASD move  Shift sprint  Space jump  C/Ctrl crouch  Tab camera  R respawn\n"
		+ "Start on the left lane, then strafe to each labeled obstacle.\n"
		+ "Expected: small climbs, tall blocks, angled slides/blocks, ceiling blocks, no stair-snap over edge, crate pushes."
	)
	canvas.add_child(label)


func _add_label(pos: Vector3, text: String) -> void:
	var label := Label3D.new()
	label.name = "Label_%s" % text.replace("\n", "_")
	label.text = text
	label.position = pos
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 28
	label.modulate = Color(1.0, 1.0, 1.0)
	add_child(label)


func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


func _respawn_player() -> void:
	if not _player_controller:
		return
	_player_controller.teleport_to(RESPAWN_POSITION)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
