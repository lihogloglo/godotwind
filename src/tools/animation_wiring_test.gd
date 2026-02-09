@warning_ignore("untyped_declaration", "unsafe_method_access", "inferred_declaration")
extends Node3D
## Visual Animation Wiring Test — Verifies Phase 2A/2B integration
##
## What you should see:
##   - A humanoid skeleton with colored bone visualization
##   - Skeleton pose changes visibly when switching animation states
##   - Info panel shows current state, velocity, grounded status
##   - Signal indicators flash when text key events fire
##
## Controls:
##   WASD       = move character (drives animation state)
##   Space      = jump
##   Shift      = hold for run speed
##   Right-click drag = orbit camera
##   Scroll     = zoom
##   F          = fire test text key signals manually
##   1          = toggle info panel
##
## Animation States:
##   Idle  = T-pose (rest)
##   Walk  = slight forward lean + alternating arms
##   Run   = more forward lean + exaggerated arms
##   Jump  = arms raised, compact body
##   Fall  = arms spread, extended body

const SPA := preload("res://src/core/animation/skeleton_profile_adapter.gd")

# Scene objects
var _camera: Camera3D
var _skeleton: Skeleton3D
var _char_body: CharacterBody3D
var _info_label: Label
var _signal_label: Label

# Animation system (CAS)
var _anim_system: Node = null

# Camera orbit
var _yaw := 20.0
var _pitch := -15.0
var _distance := 5.0
var _orbiting := false

# Movement
var _move_speed := 2.0
var _run_speed := 4.5
var _jump_velocity := 5.0
var _gravity := 9.8
var _velocity := Vector3.ZERO

# Signal tracking for visual indicators
var _last_sound := ""
var _last_footstep := ""
var _last_hit := false
var _signal_flash_time := 0.0
const FLASH_DURATION := 0.6

# Bone indices (profile names)
var _bone_indices := {}


func _ready() -> void:
	_create_environment()
	_create_ground()
	_create_skeleton_character()
	_create_animations()
	_setup_animation_system()
	_create_ui()
	_update_camera()


# =========================================================================
# ENVIRONMENT
# =========================================================================

func _create_environment() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, 30, 0)
	light.shadow_enabled = true
	add_child(light)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.1, 0.15)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.35, 0.45)
	env.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_camera = Camera3D.new()
	_camera.current = true
	add_child(_camera)


func _create_ground() -> void:
	var ground := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	var plane := BoxMesh.new()
	plane.size = Vector3(20, 0.1, 20)
	mi.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.18, 0.2, 0.16)
	mi.material_override = gmat
	ground.add_child(mi)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(20, 0.1, 20)
	cs.shape = shape
	ground.add_child(cs)
	ground.position = Vector3(0, -0.05, 0)
	add_child(ground)


# =========================================================================
# SKELETON — programmatic Morrowind Bip01 T-pose
# =========================================================================

func _create_skeleton_character() -> void:
	_char_body = CharacterBody3D.new()
	_char_body.position = Vector3(0, 0.0, 0)
	_char_body.floor_snap_length = 0.1
	add_child(_char_body)

	# Collision capsule
	var cs := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.25
	capsule.height = 1.6
	cs.position = Vector3(0, 0.8, 0)
	cs.shape = capsule
	_char_body.add_child(cs)

	# Build skeleton
	_skeleton = Skeleton3D.new()
	_char_body.add_child(_skeleton)

	var defs := [
		["Bip01", "", Vector3(0, 1.0, 0)],
		["Bip01 Spine", "Bip01", Vector3(0, 1.10, 0)],
		["Bip01 Spine1", "Bip01 Spine", Vector3(0, 1.25, 0)],
		["Bip01 Spine2", "Bip01 Spine1", Vector3(0, 1.40, 0)],
		["Bip01 Neck", "Bip01 Spine2", Vector3(0, 1.52, 0)],
		["Bip01 Head", "Bip01 Neck", Vector3(0, 1.62, 0)],
		["Bip01 L Clavicle", "Bip01 Spine2", Vector3(-0.08, 1.48, 0)],
		["Bip01 L UpperArm", "Bip01 L Clavicle", Vector3(-0.20, 1.48, 0)],
		["Bip01 L Forearm", "Bip01 L UpperArm", Vector3(-0.46, 1.46, -0.04)],
		["Bip01 L Hand", "Bip01 L Forearm", Vector3(-0.70, 1.48, 0)],
		["Bip01 R Clavicle", "Bip01 Spine2", Vector3(0.08, 1.48, 0)],
		["Bip01 R UpperArm", "Bip01 R Clavicle", Vector3(0.20, 1.48, 0)],
		["Bip01 R Forearm", "Bip01 R UpperArm", Vector3(0.46, 1.46, -0.04)],
		["Bip01 R Hand", "Bip01 R Forearm", Vector3(0.70, 1.48, 0)],
		["Bip01 L Thigh", "Bip01", Vector3(-0.10, 0.95, 0)],
		["Bip01 L Calf", "Bip01 L Thigh", Vector3(-0.10, 0.50, -0.04)],
		["Bip01 L Foot", "Bip01 L Calf", Vector3(-0.10, 0.05, 0)],
		["Bip01 L Toe0", "Bip01 L Foot", Vector3(-0.10, 0.02, -0.10)],
		["Bip01 R Thigh", "Bip01", Vector3(0.10, 0.95, 0)],
		["Bip01 R Calf", "Bip01 R Thigh", Vector3(0.10, 0.50, -0.04)],
		["Bip01 R Foot", "Bip01 R Calf", Vector3(0.10, 0.05, 0)],
		["Bip01 R Toe0", "Bip01 R Foot", Vector3(0.10, 0.02, -0.10)],
	]

	var indices := {}
	var wpos := {}
	for def in defs:
		var idx := _skeleton.add_bone(def[0])
		indices[def[0]] = idx
		wpos[def[0]] = def[2]

	for def in defs:
		var bname: String = def[0]
		var pname: String = def[1]
		if not pname.is_empty() and pname in indices:
			_skeleton.set_bone_parent(indices[bname], indices[pname])

	# Build first-child lookup for bone orientation
	var first_child_wp := {}
	for def in defs:
		var pname: String = def[1]
		if not pname.is_empty() and pname not in first_child_wp:
			first_child_wp[pname] = def[2]

	# Compute global basis for each bone
	var global_bases := {}
	for def in defs:
		var bname: String = def[0]
		var wp: Vector3 = def[2]
		if bname in first_child_wp:
			var child_wp: Vector3 = first_child_wp[bname]
			var direction := (child_wp - wp).normalized()
			global_bases[bname] = _compute_bone_basis(direction)
		else:
			var pname: String = def[1]
			if pname in global_bases:
				global_bases[bname] = global_bases[pname]
			else:
				global_bases[bname] = Basis.IDENTITY

	# Set rest transforms
	for def in defs:
		var bname: String = def[0]
		var pname: String = def[1]
		var wp: Vector3 = def[2]
		var bone_gb: Basis = global_bases[bname]
		if not pname.is_empty() and pname in indices:
			var pp: Vector3 = wpos[pname]
			var parent_gb: Basis = global_bases[pname]
			var local_origin := parent_gb.inverse() * (wp - pp)
			var local_basis := parent_gb.inverse() * bone_gb
			_skeleton.set_bone_rest(indices[bname], Transform3D(local_basis, local_origin))
		else:
			_skeleton.set_bone_rest(indices[bname], Transform3D(bone_gb, wp))

	_skeleton.reset_bone_poses()

	# Create BoneMap via SPA
	SPA.create_bone_map(_skeleton)

	# Cache bone indices
	for key in ["Hips", "Head", "Neck", "UpperChest", "Spine", "Chest",
				"LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
				"RightUpperLeg", "RightLowerLeg", "RightFoot",
				"LeftUpperArm", "LeftLowerArm", "LeftHand",
				"RightUpperArm", "RightLowerArm", "RightHand"]:
		_bone_indices[key] = SPA.get_bone_index(_skeleton, key)

	_visualize_skeleton()
	_create_direction_arrow()


func _compute_bone_basis(direction: Vector3) -> Basis:
	var up := direction.normalized()
	var right: Vector3
	if absf(up.dot(Vector3.FORWARD)) > 0.99:
		right = up.cross(Vector3.UP).normalized()
	else:
		right = up.cross(Vector3.FORWARD).normalized()
	var forward := right.cross(up).normalized()
	return Basis(right, up, forward)


func _visualize_skeleton() -> void:
	var joint_mat := StandardMaterial3D.new()
	joint_mat.albedo_color = Color(0.3, 0.7, 0.95)
	joint_mat.emission_enabled = true
	joint_mat.emission = Color(0.1, 0.25, 0.4)

	var limb_mat := StandardMaterial3D.new()
	limb_mat.albedo_color = Color(0.5, 0.55, 0.65)

	# Head nose cone
	var head_idx: int = _bone_indices.get("Head", -1)
	if head_idx >= 0:
		var nose_mat := StandardMaterial3D.new()
		nose_mat.albedo_color = Color(1.0, 0.4, 0.3)
		nose_mat.emission_enabled = true
		nose_mat.emission = Color(0.5, 0.15, 0.1)
		var nose_mi := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 0.02
		cone.height = 0.08
		nose_mi.mesh = cone
		nose_mi.material_override = nose_mat
		nose_mi.transform = Transform3D(Basis(Vector3.RIGHT, PI / 2.0), Vector3(0, 0, -0.06))
		var head_ba := BoneAttachment3D.new()
		head_ba.bone_idx = head_idx
		_skeleton.add_child(head_ba)
		head_ba.add_child(nose_mi)

	for i in _skeleton.get_bone_count():
		var mi := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.025
		sphere.height = 0.05
		mi.mesh = sphere
		mi.material_override = joint_mat
		var ba := BoneAttachment3D.new()
		ba.bone_idx = i
		_skeleton.add_child(ba)
		ba.add_child(mi)

		var parent_idx := _skeleton.get_bone_parent(i)
		if parent_idx >= 0:
			var rest := _skeleton.get_bone_rest(i)
			var length := rest.origin.length()
			if length > 0.01:
				var cyl_mi := MeshInstance3D.new()
				var cyl := CylinderMesh.new()
				cyl.top_radius = 0.012
				cyl.bottom_radius = 0.012
				cyl.height = length
				cyl_mi.mesh = cyl
				cyl_mi.material_override = limb_mat
				var dir := rest.origin.normalized()
				var up := Vector3.UP
				if absf(dir.dot(up)) > 0.99:
					up = Vector3.FORWARD
				var look_basis := Basis.looking_at(-dir, up)
				cyl_mi.transform = Transform3D(
					look_basis.rotated(look_basis.x, PI / 2.0),
					rest.origin * 0.5
				)
				var parent_ba := BoneAttachment3D.new()
				parent_ba.bone_idx = parent_idx
				_skeleton.add_child(parent_ba)
				parent_ba.add_child(cyl_mi)


func _create_direction_arrow() -> void:
	var arrow_root := Node3D.new()
	arrow_root.name = "DirectionArrow"
	_char_body.add_child(arrow_root)
	arrow_root.position = Vector3(0, 0.02, 0)

	var front_mat := StandardMaterial3D.new()
	front_mat.albedo_color = Color(0.2, 0.9, 0.3)
	front_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var front_cone := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.06
	cone.height = 0.15
	front_cone.mesh = cone
	front_cone.material_override = front_mat
	front_cone.transform = Transform3D(Basis(Vector3.RIGHT, PI / 2.0), Vector3(0, 0, -0.35))
	arrow_root.add_child(front_cone)

	var shaft_mat := StandardMaterial3D.new()
	shaft_mat.albedo_color = Color(0.6, 0.6, 0.6)
	shaft_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var shaft := MeshInstance3D.new()
	var shaft_cyl := CylinderMesh.new()
	shaft_cyl.top_radius = 0.012
	shaft_cyl.bottom_radius = 0.012
	shaft_cyl.height = 0.4
	shaft.mesh = shaft_cyl
	shaft.material_override = shaft_mat
	shaft.transform = Transform3D(Basis(Vector3.RIGHT, PI / 2.0), Vector3(0, 0, -0.08))
	arrow_root.add_child(shaft)


# =========================================================================
# ANIMATIONS — distinct poses per state so you can visually confirm
# =========================================================================

func _create_animations() -> void:
	var anim_player := AnimationPlayer.new()
	anim_player.name = "AnimationPlayer"
	_skeleton.add_child(anim_player)

	var lib := AnimationLibrary.new()

	# Idle: rest pose (T-pose) with subtle breathing on spine
	lib.add_animation("idle", _make_idle_animation())

	# Walk: alternating arms/legs, slight spine lean
	lib.add_animation("walk forward", _make_walk_animation())

	# Run: more exaggerated version of walk
	lib.add_animation("run forward", _make_run_animation())

	# Jump: arms up, body compact
	lib.add_animation("jump", _make_jump_animation())

	# Fall: arms spread, body extended
	lib.add_animation("fall", _make_fall_animation())

	# Land: brief recovery pose
	lib.add_animation("land", _make_land_animation())

	anim_player.add_animation_library("", lib)


func _make_idle_animation() -> Animation:
	var anim := Animation.new()
	anim.length = 2.0
	anim.loop_mode = Animation.LOOP_LINEAR

	# Subtle spine breathing
	var spine_idx: int = _bone_indices.get("Spine", -1)
	if spine_idx >= 0:
		var bone_name: String = _skeleton.get_bone_name(spine_idx)
		var t := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(t, ".:%s" % bone_name)
		anim.rotation_track_insert_key(t, 0.0, Quaternion.IDENTITY)
		anim.rotation_track_insert_key(t, 1.0, Quaternion(Vector3.RIGHT, deg_to_rad(2)))
		anim.rotation_track_insert_key(t, 2.0, Quaternion.IDENTITY)

	return anim


func _make_walk_animation() -> Animation:
	var anim := Animation.new()
	anim.length = 1.0
	anim.loop_mode = Animation.LOOP_LINEAR

	# Spine lean forward
	_add_bone_rotation_track(anim, "Spine", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(5))],
		[1.0, Quaternion(Vector3.RIGHT, deg_to_rad(5))],
	])

	# Left arm swings forward/back
	_add_bone_rotation_track(anim, "LeftUpperArm", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(20))],
		[0.5, Quaternion(Vector3.RIGHT, deg_to_rad(-20))],
		[1.0, Quaternion(Vector3.RIGHT, deg_to_rad(20))],
	])

	# Right arm opposite
	_add_bone_rotation_track(anim, "RightUpperArm", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(-20))],
		[0.5, Quaternion(Vector3.RIGHT, deg_to_rad(20))],
		[1.0, Quaternion(Vector3.RIGHT, deg_to_rad(-20))],
	])

	# Left thigh
	_add_bone_rotation_track(anim, "LeftUpperLeg", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(-15))],
		[0.5, Quaternion(Vector3.RIGHT, deg_to_rad(15))],
		[1.0, Quaternion(Vector3.RIGHT, deg_to_rad(-15))],
	])

	# Right thigh opposite
	_add_bone_rotation_track(anim, "RightUpperLeg", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(15))],
		[0.5, Quaternion(Vector3.RIGHT, deg_to_rad(-15))],
		[1.0, Quaternion(Vector3.RIGHT, deg_to_rad(15))],
	])

	return anim


func _make_run_animation() -> Animation:
	var anim := Animation.new()
	anim.length = 0.6
	anim.loop_mode = Animation.LOOP_LINEAR

	# More forward lean
	_add_bone_rotation_track(anim, "Spine", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(12))],
		[0.6, Quaternion(Vector3.RIGHT, deg_to_rad(12))],
	])

	# Exaggerated arm swing
	_add_bone_rotation_track(anim, "LeftUpperArm", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(40))],
		[0.3, Quaternion(Vector3.RIGHT, deg_to_rad(-40))],
		[0.6, Quaternion(Vector3.RIGHT, deg_to_rad(40))],
	])

	_add_bone_rotation_track(anim, "RightUpperArm", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(-40))],
		[0.3, Quaternion(Vector3.RIGHT, deg_to_rad(40))],
		[0.6, Quaternion(Vector3.RIGHT, deg_to_rad(-40))],
	])

	# Exaggerated leg swing
	_add_bone_rotation_track(anim, "LeftUpperLeg", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(-30))],
		[0.3, Quaternion(Vector3.RIGHT, deg_to_rad(30))],
		[0.6, Quaternion(Vector3.RIGHT, deg_to_rad(-30))],
	])

	_add_bone_rotation_track(anim, "RightUpperLeg", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(30))],
		[0.3, Quaternion(Vector3.RIGHT, deg_to_rad(-30))],
		[0.6, Quaternion(Vector3.RIGHT, deg_to_rad(30))],
	])

	# Elbow bend during run
	_add_bone_rotation_track(anim, "LeftLowerArm", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(30))],
		[0.6, Quaternion(Vector3.RIGHT, deg_to_rad(30))],
	])

	_add_bone_rotation_track(anim, "RightLowerArm", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(30))],
		[0.6, Quaternion(Vector3.RIGHT, deg_to_rad(30))],
	])

	return anim


func _make_jump_animation() -> Animation:
	var anim := Animation.new()
	anim.length = 0.5
	anim.loop_mode = Animation.LOOP_NONE

	# Arms raised
	_add_bone_rotation_track(anim, "LeftUpperArm", [
		[0.0, Quaternion.IDENTITY],
		[0.25, Quaternion(Vector3.RIGHT, deg_to_rad(60))],
		[0.5, Quaternion(Vector3.RIGHT, deg_to_rad(60))],
	])

	_add_bone_rotation_track(anim, "RightUpperArm", [
		[0.0, Quaternion.IDENTITY],
		[0.25, Quaternion(Vector3.RIGHT, deg_to_rad(60))],
		[0.5, Quaternion(Vector3.RIGHT, deg_to_rad(60))],
	])

	# Body tucks slightly
	_add_bone_rotation_track(anim, "Spine", [
		[0.0, Quaternion.IDENTITY],
		[0.25, Quaternion(Vector3.RIGHT, deg_to_rad(-8))],
		[0.5, Quaternion(Vector3.RIGHT, deg_to_rad(-5))],
	])

	return anim


func _make_fall_animation() -> Animation:
	var anim := Animation.new()
	anim.length = 1.0
	anim.loop_mode = Animation.LOOP_LINEAR

	# Arms spread out
	_add_bone_rotation_track(anim, "LeftUpperArm", [
		[0.0, Quaternion(Vector3.FORWARD, deg_to_rad(30))],
		[0.5, Quaternion(Vector3.FORWARD, deg_to_rad(40))],
		[1.0, Quaternion(Vector3.FORWARD, deg_to_rad(30))],
	])

	_add_bone_rotation_track(anim, "RightUpperArm", [
		[0.0, Quaternion(Vector3.FORWARD, deg_to_rad(-30))],
		[0.5, Quaternion(Vector3.FORWARD, deg_to_rad(-40))],
		[1.0, Quaternion(Vector3.FORWARD, deg_to_rad(-30))],
	])

	# Legs slightly bent
	_add_bone_rotation_track(anim, "LeftUpperLeg", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(-10))],
		[1.0, Quaternion(Vector3.RIGHT, deg_to_rad(-10))],
	])

	_add_bone_rotation_track(anim, "RightUpperLeg", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(-10))],
		[1.0, Quaternion(Vector3.RIGHT, deg_to_rad(-10))],
	])

	return anim


func _make_land_animation() -> Animation:
	var anim := Animation.new()
	anim.length = 0.4
	anim.loop_mode = Animation.LOOP_NONE

	# Crouch on landing
	_add_bone_rotation_track(anim, "LeftUpperLeg", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(-25))],
		[0.2, Quaternion(Vector3.RIGHT, deg_to_rad(-25))],
		[0.4, Quaternion.IDENTITY],
	])

	_add_bone_rotation_track(anim, "RightUpperLeg", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(-25))],
		[0.2, Quaternion(Vector3.RIGHT, deg_to_rad(-25))],
		[0.4, Quaternion.IDENTITY],
	])

	_add_bone_rotation_track(anim, "Spine", [
		[0.0, Quaternion(Vector3.RIGHT, deg_to_rad(10))],
		[0.2, Quaternion(Vector3.RIGHT, deg_to_rad(10))],
		[0.4, Quaternion.IDENTITY],
	])

	return anim


func _add_bone_rotation_track(anim: Animation, profile_name: String, keyframes: Array) -> void:
	var bone_idx: int = _bone_indices.get(profile_name, -1)
	if bone_idx < 0:
		return
	var bone_name: String = _skeleton.get_bone_name(bone_idx)
	var t := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(t, ".:%s" % bone_name)
	for kf in keyframes:
		anim.rotation_track_insert_key(t, kf[0], kf[1])


# =========================================================================
# ANIMATION SYSTEM WIRING — the actual Phase 2 code under test
# =========================================================================

func _setup_animation_system() -> void:
	var CAS: GDScript = load("res://src/core/animation/character_animation_system.gd")
	if not CAS:
		push_error("AnimationWiringTest: Could not load CharacterAnimationSystem")
		return

	_anim_system = CAS.new()
	_anim_system.name = "AnimationSystem"
	_anim_system.set("auto_setup", false)
	_anim_system.set("enable_ik", false)
	_anim_system.set("enable_procedural", false)
	_anim_system.set("enable_lod", false)
	_anim_system.set("debug_mode", true)
	_char_body.add_child(_anim_system)

	# Setup — this wires AnimationManager, creates AnimationTree + state machine
	_anim_system.setup(_skeleton, _char_body, _char_body)

	# Register test text keys on the walk animation (to test signal pipeline)
	var walk_keys: Array = [
		{"time": 0.0, "name": "SoundGen: Left"},
		{"time": 0.25, "name": "Sound: step_left"},
		{"time": 0.5, "name": "SoundGen: Right"},
		{"time": 0.75, "name": "Sound: step_right"},
	]
	_anim_system.register_text_keys("walk forward", walk_keys)

	# Connect signal indicators
	_anim_system.sound_triggered.connect(_on_sound_signal)
	_anim_system.hit_triggered.connect(_on_hit_signal)
	_anim_system.footstep_triggered.connect(_on_footstep_signal)
	_anim_system.animation_state_changed.connect(_on_state_changed)


# =========================================================================
# UI
# =========================================================================

func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	# Info panel (top-left)
	var panel := PanelContainer.new()
	panel.position = Vector2(10, 10)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.65)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	canvas.add_child(panel)

	_info_label = Label.new()
	_info_label.add_theme_font_size_override("font_size", 14)
	_info_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.95))
	panel.add_child(_info_label)

	# Signal panel (top-right)
	var signal_panel := PanelContainer.new()
	signal_panel.anchor_left = 1.0
	signal_panel.anchor_right = 1.0
	signal_panel.offset_left = -280
	signal_panel.offset_right = -10
	signal_panel.offset_top = 10
	var sstyle := StyleBoxFlat.new()
	sstyle.bg_color = Color(0, 0, 0, 0.65)
	sstyle.set_corner_radius_all(4)
	sstyle.set_content_margin_all(10)
	signal_panel.add_theme_stylebox_override("panel", sstyle)
	canvas.add_child(signal_panel)

	_signal_label = Label.new()
	_signal_label.add_theme_font_size_override("font_size", 14)
	_signal_label.add_theme_color_override("font_color", Color(0.95, 0.85, 0.7))
	signal_panel.add_child(_signal_label)

	# Controls help (bottom)
	var help_panel := PanelContainer.new()
	help_panel.anchor_top = 1.0
	help_panel.anchor_bottom = 1.0
	help_panel.offset_top = -50
	help_panel.offset_left = 10
	var hstyle := StyleBoxFlat.new()
	hstyle.bg_color = Color(0, 0, 0, 0.5)
	hstyle.set_corner_radius_all(4)
	hstyle.set_content_margin_all(6)
	help_panel.add_theme_stylebox_override("panel", hstyle)
	canvas.add_child(help_panel)

	var help := Label.new()
	help.text = "WASD = move | Shift = run | Space = jump | Right-click drag = orbit | Scroll = zoom | F = fire test signals"
	help.add_theme_font_size_override("font_size", 12)
	help.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	help_panel.add_child(help)


# =========================================================================
# MAIN LOOP
# =========================================================================

func _physics_process(delta: float) -> void:
	# --- WASD movement ---
	var move_dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		move_dir.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		move_dir.z += 1.0
	if Input.is_key_pressed(KEY_A):
		move_dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		move_dir.x += 1.0

	var is_running := Input.is_key_pressed(KEY_SHIFT)
	var speed := _run_speed if is_running else _move_speed

	if move_dir.length() > 0.01:
		var cam_yaw := deg_to_rad(_yaw)
		var cam_basis := Basis(Vector3.UP, cam_yaw)
		var world_dir := cam_basis * move_dir.normalized()
		_char_body.velocity.x = world_dir.x * speed
		_char_body.velocity.z = world_dir.z * speed
	else:
		_char_body.velocity.x = 0.0
		_char_body.velocity.z = 0.0

	# Jump
	if Input.is_action_just_pressed("ui_accept") and _char_body.is_on_floor():
		_char_body.velocity.y = _jump_velocity

	# Gravity
	if not _char_body.is_on_floor():
		_char_body.velocity.y -= _gravity * delta
	elif _char_body.velocity.y < 0:
		_char_body.velocity.y = 0.0

	_char_body.move_and_slide()

	# --- Drive animation system with current velocity (THIS IS THE PHASE 2A BRIDGE) ---
	if _anim_system:
		_anim_system.update_from_movement(_char_body.velocity, _char_body.is_on_floor())


func _process(delta: float) -> void:
	_update_camera()
	_update_info_label()
	_update_signal_flash(delta)


func _update_info_label() -> void:
	if not _info_label:
		return

	var state_name := "N/A"
	var am_state := ""
	if _anim_system:
		state_name = str(_anim_system.get_state())
		var am = _anim_system.get("animation_manager")
		if am:
			var sm = am.get("_state_machine")
			if sm:
				am_state = str(sm.get_current_node())

	var vel := _char_body.velocity if _char_body else Vector3.ZERO
	var h_speed := Vector3(vel.x, 0, vel.z).length()
	var grounded := _char_body.is_on_floor() if _char_body else false

	_info_label.text = (
		"ANIMATION WIRING TEST (Phase 2A/2B)\n" +
		"────────────────────────\n" +
		"State:     %s\n" % state_name +
		"SM Node:   %s\n" % am_state +
		"Velocity:  %.1f m/s (h: %.1f)\n" % [vel.length(), h_speed] +
		"Grounded:  %s\n" % ("YES" if grounded else "NO") +
		"Y vel:     %.1f\n" % vel.y +
		"Position:  %.1f, %.1f, %.1f" % [
			_char_body.position.x, _char_body.position.y, _char_body.position.z
		]
	)


func _update_signal_flash(delta: float) -> void:
	if _signal_flash_time > 0:
		_signal_flash_time -= delta

	var flash := " " if fmod(_signal_flash_time, 0.2) > 0.1 and _signal_flash_time > 0 else ""

	_signal_label.text = (
		"TEXT KEY SIGNALS\n" +
		"────────────────────────\n" +
		"Last Sound:    %s %s\n" % [_last_sound, flash if not _last_sound.is_empty() else ""] +
		"Last Footstep: %s %s\n" % [_last_footstep, flash if not _last_footstep.is_empty() else ""] +
		"Last Hit:      %s %s\n" % ["YES" if _last_hit else "---", flash if _last_hit else ""] +
		"\nPress F to fire test signals"
	)


# =========================================================================
# INPUT
# =========================================================================

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = maxf(1.5, _distance - 0.5)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = minf(15.0, _distance + 0.5)

	elif event is InputEventMouseMotion and _orbiting:
		var mm := event as InputEventMouseMotion
		_yaw += mm.relative.x * 0.3
		_pitch = clampf(_pitch - mm.relative.y * 0.3, -85.0, 85.0)

	elif event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode == KEY_F:
			_fire_test_signals()


func _fire_test_signals() -> void:
	if not _anim_system:
		return
	# Manually emit signals through AnimationManager to test the full pipeline
	var am = _anim_system.get("animation_manager")
	if am:
		am.sound_triggered.emit("test_manual_sound", _char_body.global_position)
		am.hit_triggered.emit(_char_body.global_position)
		am.footstep_triggered.emit("left", _char_body.global_position)


# =========================================================================
# CAMERA
# =========================================================================

func _update_camera() -> void:
	if not _camera or not _char_body:
		return
	var center := _char_body.global_position + Vector3(0, 1.0, 0)
	var yaw_rad := deg_to_rad(_yaw)
	var pitch_rad := deg_to_rad(_pitch)
	var offset := Vector3(
		sin(yaw_rad) * cos(pitch_rad),
		-sin(pitch_rad),
		cos(yaw_rad) * cos(pitch_rad)
	) * _distance
	_camera.global_position = center + offset
	_camera.look_at(center, Vector3.UP)


# =========================================================================
# SIGNAL HANDLERS
# =========================================================================

func _on_sound_signal(sound_id: String, _position: Vector3) -> void:
	_last_sound = sound_id
	_signal_flash_time = FLASH_DURATION


func _on_hit_signal(_position: Vector3) -> void:
	_last_hit = true
	_signal_flash_time = FLASH_DURATION


func _on_footstep_signal(foot: String, _position: Vector3) -> void:
	_last_footstep = foot
	_signal_flash_time = FLASH_DURATION


func _on_state_changed(old_state: StringName, new_state: StringName) -> void:
	# Brief flash on state change
	_signal_flash_time = maxf(_signal_flash_time, 0.3)
