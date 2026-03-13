@warning_ignore("untyped_declaration", "unsafe_method_access", "inferred_declaration")
extends Node3D
## Visual IK Test — Interactive TwoBoneIK3D foot, look-at, and hand IK demo
##
## What you should see:
##   - A humanoid skeleton standing on uneven terrain
##   - Feet adapt to terrain slope (foot IK)
##   - Head/neck tracks a floating orb (look-at IK)
##   - Right hand reaches toward a floating cube (hand IK)
##   - Left panel shows IK state info
##
## Controls:
##   Left-click drag  = pick up and move look orb or hand cube
##   Shift+click      = spawn step platform at mouse position
##   WASD             = move character across terrain
##   Right-click drag = orbit camera
##   Scroll           = zoom
##   1 = toggle foot IK
##   2 = toggle look-at IK
##   3 = toggle hand IK
##   Space = resume auto-motion for all targets
##   R = reset character position


# Scene objects
var _camera: Camera3D
var _skeleton: Skeleton3D
var _char_body: CharacterBody3D
var _look_orb: MeshInstance3D
var _hand_cube: MeshInstance3D
var _info_label: Label

# IK nodes (TwoBoneIK3D — Godot 4.6)
# TwoBoneIK3D requires BOTH a target AND a pole Node3D to solve.
var _left_foot_ik: TwoBoneIK3D
var _right_foot_ik: TwoBoneIK3D
var _right_arm_ik: TwoBoneIK3D
var _left_foot_target: Node3D
var _right_foot_target: Node3D
var _right_hand_target: Node3D
var _left_foot_pole: Node3D
var _right_foot_pole: Node3D
var _right_arm_pole: Node3D

# Foot target markers (visual debug)
var _left_foot_marker: MeshInstance3D
var _right_foot_marker: MeshInstance3D

# Bone indices
var _bone_indices := {}

# IK state
var _foot_ik_enabled := true
var _look_ik_enabled := true
var _hand_ik_enabled := true
var _time := 0.0

# Per-target auto-motion state (Space resumes all)
var _look_auto := true
var _hand_auto := true

# Mouse drag state
var _dragged_target: MeshInstance3D = null
var _drag_plane_y := 0.0
var _dragging := false

# Camera orbit
var _yaw := 30.0
var _pitch := -15.0
var _distance := 5.0
var _orbiting := false

# WASD movement
var _move_speed := 2.5
var _gravity := 9.8

# Smoothed foot targets
var _left_foot_smooth := Vector3.ZERO
var _right_foot_smooth := Vector3.ZERO
var _pelvis_offset := 0.0

# Spawned terrain material (shared)
var _spawn_mat: StandardMaterial3D


func _ready() -> void:
	_create_environment()
	_create_terrain()
	_create_skeleton_character()
	_setup_ik()
	_create_look_target()
	_create_hand_target()
	_create_ui()
	_update_camera()

	# Shared material for spawned terrain
	_spawn_mat = StandardMaterial3D.new()
	_spawn_mat.albedo_color = Color(0.4, 0.35, 0.25)


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
	env.background_color = Color(0.1, 0.12, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.35, 0.45)
	env.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_camera = Camera3D.new()
	_camera.current = true
	add_child(_camera)


func _create_terrain() -> void:
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.25, 0.28, 0.22)

	# Main flat ground
	_add_box(Vector3(0, -0.25, 0), Vector3(12, 0.5, 12), ground_mat)

	# Step directly under left foot at start pos — immediate foot IK demo
	var step_mat := StandardMaterial3D.new()
	step_mat.albedo_color = Color(0.35, 0.32, 0.22)
	_add_box(Vector3(-0.25, 0.05, 0), Vector3(0.6, 0.10, 0.8), step_mat)

	# Walkable terrain features (low enough to step over)
	_add_box(Vector3(-1.5, 0.035, 0), Vector3(1.2, 0.07, 2.0), ground_mat)
	_add_box(Vector3(1.5, 0.05, 0.5), Vector3(1.2, 0.10, 1.8), ground_mat)
	_add_box(Vector3(0, 0.04, -1.5), Vector3(2.0, 0.08, 1.0), ground_mat)
	_add_box(Vector3(-2.0, 0.06, -2.0), Vector3(1.5, 0.12, 1.5), ground_mat)
	_add_box(Vector3(2.0, 0.08, -2.0), Vector3(1.0, 0.16, 1.2), ground_mat)
	# Higher steps further out (need to jump/slide onto)
	_add_box(Vector3(-3.0, 0.1, 0), Vector3(1.0, 0.20, 1.5), ground_mat)
	_add_box(Vector3(3.0, 0.12, 0), Vector3(1.0, 0.24, 1.5), ground_mat)


func _add_box(pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> void:
	var sb := StaticBody3D.new()
	sb.position = pos
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	sb.add_child(mi)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	sb.add_child(cs)
	add_child(sb)


# =========================================================================
# SKELETON CHARACTER — programmatic T-pose with proper rest transforms
# =========================================================================

func _create_skeleton_character() -> void:
	_char_body = CharacterBody3D.new()
	_char_body.position = Vector3(0, 0.0, 0)
	_char_body.floor_snap_length = 0.15  # Step up small height differences
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
		# [name, parent, world_pos]
		["Bip01", "", Vector3(0, 1.0, 0)],
		["Bip01 Spine", "Bip01", Vector3(0, 1.10, 0)],
		["Bip01 Spine1", "Bip01 Spine", Vector3(0, 1.25, 0)],
		["Bip01 Spine2", "Bip01 Spine1", Vector3(0, 1.40, 0)],
		["Bip01 Neck", "Bip01 Spine2", Vector3(0, 1.52, 0)],
		["Bip01 Head", "Bip01 Neck", Vector3(0, 1.62, 0)],
		# Left arm (forearm slightly forward for elbow bend hint)
		["Bip01 L Clavicle", "Bip01 Spine2", Vector3(-0.08, 1.48, 0)],
		["Bip01 L UpperArm", "Bip01 L Clavicle", Vector3(-0.20, 1.48, 0)],
		["Bip01 L Forearm", "Bip01 L UpperArm", Vector3(-0.46, 1.46, -0.04)],
		["Bip01 L Hand", "Bip01 L Forearm", Vector3(-0.70, 1.48, 0)],
		# Right arm (forearm slightly forward for elbow bend hint)
		["Bip01 R Clavicle", "Bip01 Spine2", Vector3(0.08, 1.48, 0)],
		["Bip01 R UpperArm", "Bip01 R Clavicle", Vector3(0.20, 1.48, 0)],
		["Bip01 R Forearm", "Bip01 R UpperArm", Vector3(0.46, 1.46, -0.04)],
		["Bip01 R Hand", "Bip01 R Forearm", Vector3(0.70, 1.48, 0)],
		# Left leg (calf slightly forward for knee bend hint)
		["Bip01 L Thigh", "Bip01", Vector3(-0.10, 0.95, 0)],
		["Bip01 L Calf", "Bip01 L Thigh", Vector3(-0.10, 0.50, -0.04)],
		["Bip01 L Foot", "Bip01 L Calf", Vector3(-0.10, 0.05, 0)],
		["Bip01 L Toe0", "Bip01 L Foot", Vector3(-0.10, 0.02, -0.10)],
		# Right leg (calf slightly forward for knee bend hint)
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

	# Set parent relationships
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

	# Compute global basis for each bone (orient +Y toward first child)
	var global_bases := {}
	for def in defs:
		var bname: String = def[0]
		var wp: Vector3 = def[2]
		if bname in first_child_wp:
			var child_wp: Vector3 = first_child_wp[bname]
			var direction := (child_wp - wp).normalized()
			global_bases[bname] = _compute_bone_basis(direction)
		else:
			# Leaf bone: inherit parent's orientation
			var pname: String = def[1]
			if pname in global_bases:
				global_bases[bname] = global_bases[pname]
			else:
				global_bases[bname] = Basis.IDENTITY

	# Set rest transforms with proper orientations
	for def in defs:
		var bname: String = def[0]
		var pname: String = def[1]
		var wp: Vector3 = def[2]
		var bone_gb: Basis = global_bases[bname]

		if not pname.is_empty() and pname in indices:
			var pp: Vector3 = wpos[pname]
			var parent_gb: Basis = global_bases[pname]
			# Convert world offset and orientation to parent-local space
			var local_origin := parent_gb.inverse() * (wp - pp)
			var local_basis := parent_gb.inverse() * bone_gb
			_skeleton.set_bone_rest(indices[bname], Transform3D(local_basis, local_origin))
		else:
			_skeleton.set_bone_rest(indices[bname], Transform3D(bone_gb, wp))

	# Reset all bones to rest pose
	_skeleton.reset_bone_poses()

	# Cache bone indices (direct skeleton lookup)
	for key in ["Hips", "Head", "Neck", "UpperChest",
				"LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
				"RightUpperLeg", "RightLowerLeg", "RightFoot",
				"LeftUpperArm", "LeftLowerArm", "LeftHand",
				"RightUpperArm", "RightLowerArm", "RightHand"]:
		_bone_indices[key] = _skeleton.find_bone(key)

	# Visualize bones with capsule meshes (limb segments)
	_visualize_skeleton()

	# Front/back direction arrow on the ground
	_create_direction_arrow()


func _create_direction_arrow() -> void:
	## Arrow on the ground showing character forward (-Z) direction.
	## Green cone = FRONT, red tail = BACK.
	var arrow_root := Node3D.new()
	arrow_root.name = "DirectionArrow"
	_char_body.add_child(arrow_root)
	arrow_root.position = Vector3(0, 0.02, 0)  # Just above ground

	# Front cone (green) — points forward (-Z)
	var front_mat := StandardMaterial3D.new()
	front_mat.albedo_color = Color(0.2, 0.9, 0.3)
	front_mat.emission_enabled = true
	front_mat.emission = Color(0.1, 0.4, 0.1)
	front_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var front_cone := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.08
	cone.height = 0.2
	front_cone.mesh = cone
	front_cone.material_override = front_mat
	# Rotate so cone tip points along -Z (forward)
	front_cone.transform = Transform3D(
		Basis(Vector3.RIGHT, PI / 2.0),
		Vector3(0, 0, -0.45)
	)
	arrow_root.add_child(front_cone)

	# Shaft (white/gray line from back to front)
	var shaft_mat := StandardMaterial3D.new()
	shaft_mat.albedo_color = Color(0.7, 0.7, 0.7)
	shaft_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var shaft := MeshInstance3D.new()
	var shaft_cyl := CylinderMesh.new()
	shaft_cyl.top_radius = 0.015
	shaft_cyl.bottom_radius = 0.015
	shaft_cyl.height = 0.5
	shaft.mesh = shaft_cyl
	shaft.material_override = shaft_mat
	# Lay the cylinder along -Z
	shaft.transform = Transform3D(
		Basis(Vector3.RIGHT, PI / 2.0),
		Vector3(0, 0, -0.1)
	)
	arrow_root.add_child(shaft)

	# Back ball (red) — at +Z (behind character)
	var back_mat := StandardMaterial3D.new()
	back_mat.albedo_color = Color(0.9, 0.2, 0.2)
	back_mat.emission_enabled = true
	back_mat.emission = Color(0.4, 0.1, 0.05)
	back_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var back_ball := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.04
	ball.height = 0.08
	back_ball.mesh = ball
	back_ball.material_override = back_mat
	back_ball.position = Vector3(0, 0, 0.15)
	arrow_root.add_child(back_ball)


func _visualize_skeleton() -> void:
	var joint_mat := StandardMaterial3D.new()
	joint_mat.albedo_color = Color(0.3, 0.7, 0.95)
	joint_mat.emission_enabled = true
	joint_mat.emission = Color(0.1, 0.25, 0.4)

	var limb_mat := StandardMaterial3D.new()
	limb_mat.albedo_color = Color(0.5, 0.55, 0.65)

	# Head direction indicator (nose cone — shows where the head is looking)
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
		# Point forward (-Z) from the head bone
		nose_mi.transform = Transform3D(
			Basis(Vector3.RIGHT, PI / 2.0),
			Vector3(0, 0, -0.06)
		)

		var head_ba := BoneAttachment3D.new()
		head_ba.bone_idx = head_idx
		_skeleton.add_child(head_ba)
		head_ba.add_child(nose_mi)

	for i in _skeleton.get_bone_count():
		# Joint sphere
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

		# Limb cylinder to parent
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


# =========================================================================
# IK SETUP — TwoBoneIK3D (Godot 4.6)
# =========================================================================

func _setup_ik() -> void:
	# --- Foot IK ---
	var l_upper: int = _bone_indices.get("LeftUpperLeg", -1)
	var l_lower: int = _bone_indices.get("LeftLowerLeg", -1)
	var l_foot: int = _bone_indices.get("LeftFoot", -1)
	var r_upper: int = _bone_indices.get("RightUpperLeg", -1)
	var r_lower: int = _bone_indices.get("RightLowerLeg", -1)
	var r_foot: int = _bone_indices.get("RightFoot", -1)

	if l_foot >= 0:
		_left_foot_ik = TwoBoneIK3D.new()
		_left_foot_ik.name = "LeftFootIK"
		_left_foot_ik.set_setting_count(1)
		if l_upper >= 0:
			_left_foot_ik.set_root_bone_name(0, _skeleton.get_bone_name(l_upper))
		if l_lower >= 0:
			_left_foot_ik.set_middle_bone_name(0, _skeleton.get_bone_name(l_lower))
		_left_foot_ik.set_end_bone_name(0, _skeleton.get_bone_name(l_foot))
		_left_foot_ik.set_end_bone_direction(0, SkeletonModifier3D.BONE_DIRECTION_FROM_PARENT)
		_left_foot_ik.set_pole_direction(0, SkeletonModifier3D.SECONDARY_DIRECTION_MINUS_Z)
		_skeleton.add_child(_left_foot_ik)

		# Target outside skeleton (child of char body) to avoid transform feedback
		_left_foot_target = Node3D.new()
		_left_foot_target.name = "LeftFootTarget"
		_char_body.add_child(_left_foot_target)
		_left_foot_ik.set_target_node(0, _left_foot_ik.get_path_to(_left_foot_target))
		_left_foot_smooth = _skeleton.global_transform * _skeleton.get_bone_global_pose(l_foot).origin
		_left_foot_target.global_position = _left_foot_smooth

		# Pole node (knees bend forward)
		_left_foot_pole = Node3D.new()
		_left_foot_pole.name = "LeftFootPole"
		_char_body.add_child(_left_foot_pole)
		_left_foot_pole.global_position = _left_foot_smooth + Vector3(0, 0.4, -0.5)
		_left_foot_ik.set_pole_node(0, _left_foot_ik.get_path_to(_left_foot_pole))

	if r_foot >= 0:
		_right_foot_ik = TwoBoneIK3D.new()
		_right_foot_ik.name = "RightFootIK"
		_right_foot_ik.set_setting_count(1)
		if r_upper >= 0:
			_right_foot_ik.set_root_bone_name(0, _skeleton.get_bone_name(r_upper))
		if r_lower >= 0:
			_right_foot_ik.set_middle_bone_name(0, _skeleton.get_bone_name(r_lower))
		_right_foot_ik.set_end_bone_name(0, _skeleton.get_bone_name(r_foot))
		_right_foot_ik.set_end_bone_direction(0, SkeletonModifier3D.BONE_DIRECTION_FROM_PARENT)
		_right_foot_ik.set_pole_direction(0, SkeletonModifier3D.SECONDARY_DIRECTION_MINUS_Z)
		_skeleton.add_child(_right_foot_ik)

		_right_foot_target = Node3D.new()
		_right_foot_target.name = "RightFootTarget"
		_char_body.add_child(_right_foot_target)
		_right_foot_ik.set_target_node(0, _right_foot_ik.get_path_to(_right_foot_target))
		_right_foot_smooth = _skeleton.global_transform * _skeleton.get_bone_global_pose(r_foot).origin
		_right_foot_target.global_position = _right_foot_smooth

		# Pole node (knees bend forward)
		_right_foot_pole = Node3D.new()
		_right_foot_pole.name = "RightFootPole"
		_char_body.add_child(_right_foot_pole)
		_right_foot_pole.global_position = _right_foot_smooth + Vector3(0, 0.4, -0.5)
		_right_foot_ik.set_pole_node(0, _right_foot_ik.get_path_to(_right_foot_pole))

	# --- Right arm IK (hand tracking) ---
	var ra_upper: int = _bone_indices.get("RightUpperArm", -1)
	var ra_lower: int = _bone_indices.get("RightLowerArm", -1)
	var ra_hand: int = _bone_indices.get("RightHand", -1)

	if ra_hand >= 0:
		_right_arm_ik = TwoBoneIK3D.new()
		_right_arm_ik.name = "RightArmIK"
		_right_arm_ik.set_setting_count(1)
		if ra_upper >= 0:
			_right_arm_ik.set_root_bone_name(0, _skeleton.get_bone_name(ra_upper))
		if ra_lower >= 0:
			_right_arm_ik.set_middle_bone_name(0, _skeleton.get_bone_name(ra_lower))
		_right_arm_ik.set_end_bone_name(0, _skeleton.get_bone_name(ra_hand))
		_right_arm_ik.set_end_bone_direction(0, SkeletonModifier3D.BONE_DIRECTION_FROM_PARENT)
		_right_arm_ik.set_pole_direction(0, SkeletonModifier3D.SECONDARY_DIRECTION_MINUS_Z)
		_skeleton.add_child(_right_arm_ik)

		_right_hand_target = Node3D.new()
		_right_hand_target.name = "RightHandTarget"
		_char_body.add_child(_right_hand_target)
		_right_arm_ik.set_target_node(0, _right_arm_ik.get_path_to(_right_hand_target))
		var hand_global := _skeleton.global_transform * _skeleton.get_bone_global_pose(ra_hand).origin
		_right_hand_target.global_position = hand_global

		# Pole node (elbows bend backward/down)
		_right_arm_pole = Node3D.new()
		_right_arm_pole.name = "RightArmPole"
		_char_body.add_child(_right_arm_pole)
		_right_arm_pole.global_position = hand_global + Vector3(0, -0.3, 0.5)
		_right_arm_ik.set_pole_node(0, _right_arm_ik.get_path_to(_right_arm_pole))

	# --- Debug: Print TwoBoneIK3D configuration ---
	_print_ik_diagnostics()

	# --- Foot target debug markers ---
	var marker_mat := StandardMaterial3D.new()
	marker_mat.albedo_color = Color(1.0, 0.2, 0.2)
	marker_mat.emission_enabled = true
	marker_mat.emission = Color(0.5, 0.1, 0.05)

	_left_foot_marker = MeshInstance3D.new()
	var lsphere := SphereMesh.new()
	lsphere.radius = 0.03
	lsphere.height = 0.06
	_left_foot_marker.mesh = lsphere
	_left_foot_marker.material_override = marker_mat
	add_child(_left_foot_marker)

	_right_foot_marker = MeshInstance3D.new()
	var rsphere := SphereMesh.new()
	rsphere.radius = 0.03
	rsphere.height = 0.06
	_right_foot_marker.mesh = rsphere
	_right_foot_marker.material_override = marker_mat
	add_child(_right_foot_marker)


# =========================================================================
# IK DIAGNOSTICS
# =========================================================================

var _diag_frame := 0

func _print_ik_diagnostics() -> void:
	print("=== TwoBoneIK3D DIAGNOSTICS ===")
	if _left_foot_ik:
		print("  LeftFootIK:")
		print("    active: %s" % _left_foot_ik.active)
		print("    root: '%s' (idx %d)" % [_left_foot_ik.get_root_bone_name(0), _left_foot_ik.get_root_bone(0)])
		print("    middle: '%s' (idx %d)" % [_left_foot_ik.get_middle_bone_name(0), _left_foot_ik.get_middle_bone(0)])
		print("    end: '%s' (idx %d)" % [_left_foot_ik.get_end_bone_name(0), _left_foot_ik.get_end_bone(0)])
		print("    target: '%s' pole: '%s'" % [_left_foot_ik.get_target_node(0), _left_foot_ik.get_pole_node(0)])
		var target_resolved = _left_foot_ik.get_node_or_null(_left_foot_ik.get_target_node(0))
		var pole_resolved = _left_foot_ik.get_node_or_null(_left_foot_ik.get_pole_node(0))
		print("    target resolved: %s  pole resolved: %s" % [target_resolved != null, pole_resolved != null])
	else:
		print("  LeftFootIK: NULL")

	if _right_arm_ik:
		print("  RightArmIK:")
		print("    active: %s" % _right_arm_ik.active)
		print("    root: '%s' middle: '%s' end: '%s'" % [
			_right_arm_ik.get_root_bone_name(0),
			_right_arm_ik.get_middle_bone_name(0),
			_right_arm_ik.get_end_bone_name(0)])
		print("    target: '%s' pole: '%s'" % [_right_arm_ik.get_target_node(0), _right_arm_ik.get_pole_node(0)])
		var target_resolved = _right_arm_ik.get_node_or_null(_right_arm_ik.get_target_node(0))
		var pole_resolved = _right_arm_ik.get_node_or_null(_right_arm_ik.get_pole_node(0))
		print("    target resolved: %s  pole resolved: %s" % [target_resolved != null, pole_resolved != null])
	print("=== END DIAGNOSTICS ===")


func _print_frame_diagnostics() -> void:
	## Print bone pose info once per second to check if TwoBoneIK3D modifies poses
	_diag_frame += 1
	if _diag_frame % 60 != 0:
		return

	var l_foot_idx: int = _bone_indices.get("LeftFoot", -1)
	if l_foot_idx >= 0:
		var pose_rot = _skeleton.get_bone_pose_rotation(l_foot_idx)
		var pose_pos = _skeleton.get_bone_pose_position(l_foot_idx)
		var rest_pos = _skeleton.get_bone_rest(l_foot_idx).origin
		print("[frame %d] L_foot pose_rot: %s  pose_pos: %s  rest_pos: %s" % [
			_diag_frame, str(pose_rot), str(pose_pos), str(rest_pos)])
		if _left_foot_target:
			print("  L_foot target global: %s" % str(_left_foot_target.global_position))

	var l_thigh_idx: int = _bone_indices.get("LeftUpperLeg", -1)
	if l_thigh_idx >= 0:
		var pose_rot = _skeleton.get_bone_pose_rotation(l_thigh_idx)
		print("  L_thigh pose_rot: %s" % str(pose_rot))


# =========================================================================
# LOOK-AT & HAND TARGETS
# =========================================================================

func _create_look_target() -> void:
	_look_orb = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.08
	sphere.height = 0.16
	_look_orb.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.85, 0.2)
	mat.emission_enabled = true
	mat.emission = Color(0.8, 0.6, 0.1)
	mat.emission_energy_multiplier = 2.0
	_look_orb.material_override = mat
	add_child(_look_orb)


func _create_hand_target() -> void:
	_hand_cube = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.1, 0.1, 0.1)
	_hand_cube.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.9, 0.5)
	mat.emission_enabled = true
	mat.emission = Color(0.1, 0.4, 0.2)
	mat.emission_energy_multiplier = 1.5
	_hand_cube.material_override = mat
	add_child(_hand_cube)


# =========================================================================
# UI
# =========================================================================

func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	var panel := PanelContainer.new()
	panel.position = Vector2(10, 10)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)
	canvas.add_child(panel)

	_info_label = Label.new()
	_info_label.add_theme_font_size_override("font_size", 14)
	_info_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.95))
	panel.add_child(_info_label)


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

	if move_dir.length() > 0.01:
		# Move relative to camera yaw
		var cam_yaw := deg_to_rad(_yaw)
		var cam_basis := Basis(Vector3.UP, cam_yaw)
		var world_dir := cam_basis * move_dir.normalized()
		_char_body.velocity.x = world_dir.x * _move_speed
		_char_body.velocity.z = world_dir.z * _move_speed
	else:
		_char_body.velocity.x = 0.0
		_char_body.velocity.z = 0.0

	# Apply gravity
	if not _char_body.is_on_floor():
		_char_body.velocity.y -= _gravity * delta
	else:
		_char_body.velocity.y = 0.0

	_char_body.move_and_slide()

	# --- Auto-motion timer (only when targets are in auto mode) ---
	_time += delta

	# --- Move targets ---
	if _look_auto and not _dragging_target(_look_orb):
		_update_look_target_auto()
	if _hand_auto and not _dragging_target(_hand_cube):
		_update_hand_target_auto()

	# --- Drag update ---
	if _dragging and _dragged_target:
		_update_drag()

	# --- Foot IK ---
	if _foot_ik_enabled and _left_foot_ik and _right_foot_ik:
		_update_foot_ik(delta)

	# --- Look-at IK ---
	if _look_ik_enabled:
		_update_look_at_ik(delta)

	# --- Hand IK (right arm tracks cube) ---
	if _hand_ik_enabled and _right_arm_ik and _right_hand_target:
		_right_hand_target.global_position = _hand_cube.global_position
		# Update arm pole (elbows bend backward/down relative to character)
		if _right_arm_pole:
			var char_back := _char_body.global_transform.basis.z
			var elbow_pos := _char_body.global_position + Vector3(0.3, 1.2, 0)
			_right_arm_pole.global_position = elbow_pos + char_back * 0.5 + Vector3.DOWN * 0.3

	# --- IK active state ---
	if _left_foot_ik:
		_left_foot_ik.active = _foot_ik_enabled
	if _right_foot_ik:
		_right_foot_ik.active = _foot_ik_enabled
	if _right_arm_ik:
		_right_arm_ik.active = _hand_ik_enabled

	# --- Update foot target markers ---
	if _left_foot_marker:
		_left_foot_marker.global_position = _left_foot_smooth
	if _right_foot_marker:
		_right_foot_marker.global_position = _right_foot_smooth

	# --- Per-frame diagnostics ---
	_print_frame_diagnostics()


func _process(_delta: float) -> void:
	_update_camera()
	_update_info()


func _dragging_target(target: MeshInstance3D) -> bool:
	return _dragging and _dragged_target == target


func _update_look_target_auto() -> void:
	var radius := 1.5
	var base := _char_body.global_position if _char_body else Vector3.ZERO
	var y := base.y + 1.6 + sin(_time * 0.7) * 0.3
	_look_orb.global_position = Vector3(
		base.x + sin(_time * 0.5) * radius,
		y,
		base.z + cos(_time * 0.5) * radius
	)


func _update_hand_target_auto() -> void:
	var base := _char_body.global_position if _char_body else Vector3.ZERO
	_hand_cube.global_position = Vector3(
		base.x + 0.6 + sin(_time * 0.8) * 0.15,
		base.y + 1.3 + sin(_time * 1.2) * 0.15,
		base.z + 0.3 + cos(_time * 0.6) * 0.2
	)


# =========================================================================
# MOUSE DRAG — pick up and move look orb or hand cube
# =========================================================================

func _try_pick_target(screen_pos: Vector2) -> void:
	## Left-click: pick the nearest target within screen distance threshold.
	if not _camera:
		return

	var orb_screen := _camera.unproject_position(_look_orb.global_position)
	var cube_screen := _camera.unproject_position(_hand_cube.global_position)

	var orb_dist := orb_screen.distance_to(screen_pos)
	var cube_dist := cube_screen.distance_to(screen_pos)
	var threshold := 80.0  # pixels

	if orb_dist < threshold and orb_dist < cube_dist:
		_dragged_target = _look_orb
		_drag_plane_y = _look_orb.global_position.y
		_dragging = true
		_look_auto = false
	elif cube_dist < threshold:
		_dragged_target = _hand_cube
		_drag_plane_y = _hand_cube.global_position.y
		_dragging = true
		_hand_auto = false


func _update_drag() -> void:
	## Move dragged target on a horizontal plane at _drag_plane_y, projected from mouse.
	if not _camera or not _dragged_target:
		return

	var mouse_pos := get_viewport().get_mouse_position()
	var ray_origin := _camera.project_ray_origin(mouse_pos)
	var ray_dir := _camera.project_ray_normal(mouse_pos)

	# Intersect with horizontal plane at _drag_plane_y
	if absf(ray_dir.y) < 0.001:
		return  # Ray parallel to plane

	var t := (_drag_plane_y - ray_origin.y) / ray_dir.y
	if t < 0:
		return  # Plane behind camera

	var hit := ray_origin + ray_dir * t
	_dragged_target.global_position = hit

	# Allow vertical adjustment with Shift held
	if Input.is_key_pressed(KEY_SHIFT):
		# Vertical drag mode: mouse Y controls height
		var mouse_delta := get_viewport().get_mouse_position()
		# Use the drag plane Y and adjust based on camera-relative up
		_drag_plane_y = hit.y


func _stop_drag() -> void:
	_dragging = false
	_dragged_target = null


# =========================================================================
# TERRAIN SPAWNING — Shift+click to add step platforms
# =========================================================================

func _spawn_terrain_at_mouse(screen_pos: Vector2) -> void:
	## Raycast from camera through mouse into the physics world, spawn a box there.
	if not _camera:
		return

	var ray_origin := _camera.project_ray_origin(screen_pos)
	var ray_dir := _camera.project_ray_normal(screen_pos)
	var ray_end := ray_origin + ray_dir * 50.0

	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.collision_mask = 1
	var hit := space_state.intersect_ray(query)

	if hit:
		var pos: Vector3 = hit.position
		# Spawn a small raised platform
		var height := randf_range(0.1, 0.35)
		_add_box(Vector3(pos.x, pos.y + height * 0.5, pos.z),
			Vector3(0.6, height, 0.6), _spawn_mat)


# =========================================================================
# FOOT IK
# =========================================================================

func _update_foot_ik(delta: float) -> void:
	var space_state := _char_body.get_world_3d().direct_space_state
	var l_foot_idx: int = _bone_indices.get("LeftFoot", -1)
	var r_foot_idx: int = _bone_indices.get("RightFoot", -1)

	if l_foot_idx < 0 or r_foot_idx < 0:
		return

	var l_foot_global := _skeleton.global_transform * _skeleton.get_bone_global_pose(l_foot_idx).origin
	var r_foot_global := _skeleton.global_transform * _skeleton.get_bone_global_pose(r_foot_idx).origin

	var l_hit := _raycast_ground(space_state, l_foot_global)
	var r_hit := _raycast_ground(space_state, r_foot_global)

	var foot_offset := 0.05
	var max_adjust := 0.4
	var smooth_speed := 10.0

	# Left foot
	var l_target := l_foot_global
	var l_off := 0.0
	if l_hit:
		l_target = l_hit.position + Vector3.UP * foot_offset
		var diff := l_target - l_foot_global
		if diff.length() > max_adjust:
			l_target = l_foot_global + diff.normalized() * max_adjust
		l_off = l_target.y - l_foot_global.y

	# Right foot
	var r_target := r_foot_global
	var r_off := 0.0
	if r_hit:
		r_target = r_hit.position + Vector3.UP * foot_offset
		var diff := r_target - r_foot_global
		if diff.length() > max_adjust:
			r_target = r_foot_global + diff.normalized() * max_adjust
		r_off = r_target.y - r_foot_global.y

	# Smooth
	_left_foot_smooth = _left_foot_smooth.lerp(l_target, smooth_speed * delta)
	_right_foot_smooth = _right_foot_smooth.lerp(r_target, smooth_speed * delta)
	_left_foot_target.global_position = _left_foot_smooth
	_right_foot_target.global_position = _right_foot_smooth

	# Update pole positions (knees bend forward relative to character)
	var char_forward := -_char_body.global_transform.basis.z
	if _left_foot_pole:
		_left_foot_pole.global_position = l_foot_global + char_forward * 0.5 + Vector3.UP * 0.4
	if _right_foot_pole:
		_right_foot_pole.global_position = r_foot_global + char_forward * 0.5 + Vector3.UP * 0.4

	# Pelvis offset
	var target_pelvis := minf(l_off, r_off)
	_pelvis_offset = lerpf(_pelvis_offset, target_pelvis, smooth_speed * delta)
	var hips_idx: int = _bone_indices.get("Hips", -1)
	if hips_idx >= 0:
		var pose := _skeleton.get_bone_pose(hips_idx)
		var adjusted := pose.origin
		adjusted.y = _skeleton.get_bone_rest(hips_idx).origin.y + _pelvis_offset
		_skeleton.set_bone_pose_position(hips_idx, adjusted)


func _raycast_ground(space_state: PhysicsDirectSpaceState3D, from: Vector3) -> Dictionary:
	var ray_start := from + Vector3.UP * 0.5
	var ray_end := from + Vector3.DOWN * 1.5
	var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end)
	query.collision_mask = 1
	if _char_body:
		query.exclude = [_char_body.get_rid()]
	return space_state.intersect_ray(query)


# =========================================================================
# LOOK-AT IK (manual bone rotation — not TwoBoneIK3D, uses direct pose)
# =========================================================================

func _update_look_at_ik(delta: float) -> void:
	var head_idx: int = _bone_indices.get("Head", -1)
	var neck_idx: int = _bone_indices.get("Neck", -1)
	if head_idx < 0:
		return

	var target_pos := _look_orb.global_position
	var head_global := _skeleton.global_transform * _skeleton.get_bone_global_pose(head_idx).origin

	var to_target := (target_pos - head_global).normalized()
	var forward := -_skeleton.global_transform.basis.z
	var angle := rad_to_deg(forward.angle_to(to_target))

	if angle > 90.0:
		return

	var weight := 1.0 - (angle / 90.0)
	weight = smoothstep(0.0, 1.0, weight)

	_apply_look_bone(head_idx, to_target, 0.6 * weight, delta)
	if neck_idx >= 0:
		_apply_look_bone(neck_idx, to_target, 0.25 * weight, delta)


func _apply_look_bone(bone_idx: int, target_dir: Vector3, weight: float, delta: float) -> void:
	if weight <= 0.001:
		return

	var look_xform := Transform3D.IDENTITY.looking_at(target_dir, Vector3.UP)
	var target_quat := look_xform.basis.get_rotation_quaternion()
	# Orthonormalize to avoid "Basis must be normalized" quaternion errors
	var current_quat := _skeleton.get_bone_global_pose(bone_idx).basis.orthonormalized().get_rotation_quaternion()
	var blended_quat := current_quat.slerp(target_quat, clampf(weight * 5.0 * delta, 0.0, 1.0))

	var parent_idx := _skeleton.get_bone_parent(bone_idx)
	var parent_quat := _skeleton.get_bone_global_pose(parent_idx).basis.orthonormalized().get_rotation_quaternion() if parent_idx >= 0 else Quaternion.IDENTITY
	var rest_quat := _skeleton.get_bone_rest(bone_idx).basis.get_rotation_quaternion()
	var local_quat := rest_quat.inverse() * parent_quat.inverse() * blended_quat
	_skeleton.set_bone_pose_rotation(bone_idx, local_quat)


# =========================================================================
# INFO PANEL
# =========================================================================

func _update_info() -> void:
	var text := "IK Visual Test (Interactive)\n"
	text += "══════════════════════════\n"
	text += "[1] Foot IK:    %s\n" % ("ON" if _foot_ik_enabled else "OFF")
	text += "[2] Look-at IK: %s\n" % ("ON" if _look_ik_enabled else "OFF")
	text += "[3] Hand IK:    %s\n" % ("ON" if _hand_ik_enabled else "OFF")
	text += "[WASD] Move  [Space] Resume auto\n"
	text += "[Shift+Click] Spawn terrain\n"
	text += "[L-Click drag] Move target\n"
	text += "[R] Reset position\n"
	text += "──────────────────────────\n"

	# Drag state
	if _dragging and _dragged_target:
		var name := "Look Orb" if _dragged_target == _look_orb else "Hand Cube"
		text += "DRAGGING: %s\n" % name
	else:
		text += "Look auto: %s | Hand auto: %s\n" % [
			"ON" if _look_auto else "OFF", "ON" if _hand_auto else "OFF"]

	# Character position
	if _char_body:
		var pos := _char_body.global_position
		text += "Char pos: %.2f, %.2f, %.2f\n" % [pos.x, pos.y, pos.z]

	text += "──────────────────────────\n"

	# Foot IK details
	if _left_foot_ik:
		text += "L Foot: %.2f, %.2f, %.2f\n" % [
			_left_foot_smooth.x, _left_foot_smooth.y, _left_foot_smooth.z]
	if _right_foot_ik:
		text += "R Foot: %.2f, %.2f, %.2f\n" % [
			_right_foot_smooth.x, _right_foot_smooth.y, _right_foot_smooth.z]
	text += "Pelvis offset: %.3f\n" % _pelvis_offset

	# Look-at angle
	var head_idx: int = _bone_indices.get("Head", -1)
	if head_idx >= 0:
		var head_global := _skeleton.global_transform * _skeleton.get_bone_global_pose(head_idx)
		var head_forward := -head_global.basis.z
		var to_orb := (_look_orb.global_position - head_global.origin).normalized()
		var aim_angle := rad_to_deg(head_forward.angle_to(to_orb))
		var aim_dot := head_forward.dot(to_orb)
		text += "Head→target: %.1f° (dot %.2f)\n" % [aim_angle, aim_dot]

	text += "Look pos: %.1f, %.1f, %.1f\n" % [
		_look_orb.global_position.x, _look_orb.global_position.y, _look_orb.global_position.z]

	text += "Bones: %d" % _skeleton.get_bone_count()

	_info_label.text = text


# =========================================================================
# INPUT
# =========================================================================

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				_foot_ik_enabled = not _foot_ik_enabled
			KEY_2:
				_look_ik_enabled = not _look_ik_enabled
			KEY_3:
				_hand_ik_enabled = not _hand_ik_enabled
			KEY_SPACE:
				# Resume auto-motion for all targets
				_look_auto = true
				_hand_auto = true
			KEY_R:
				# Reset character position
				_char_body.global_position = Vector3(0, 0.0, 0)
				_char_body.velocity = Vector3.ZERO

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if event.shift_pressed:
					_spawn_terrain_at_mouse(event.position)
				else:
					_try_pick_target(event.position)
			else:
				_stop_drag()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_distance = maxf(1.5, _distance - 0.4)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_distance = minf(12.0, _distance + 0.4)
	elif event is InputEventMouseMotion and _orbiting:
		_yaw -= event.relative.x * 0.3
		_pitch = clampf(_pitch - event.relative.y * 0.3, -80.0, 80.0)


# =========================================================================
# BONE ORIENTATION HELPER
# =========================================================================

func _compute_bone_basis(direction: Vector3) -> Basis:
	## Compute a Basis where +Y points along the given direction.
	## TwoBoneIK3D needs proper bone orientations to solve correctly.
	var y_axis := direction.normalized()
	var ref := Vector3.FORWARD
	if abs(y_axis.dot(ref)) > 0.99:
		ref = Vector3.UP
	var x_axis := ref.cross(y_axis).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	return Basis(x_axis, y_axis, z_axis)


# =========================================================================
# CAMERA — follows character position
# =========================================================================

func _update_camera() -> void:
	# Camera center follows character
	var target_center := Vector3(0, 1.0, 0)
	if _char_body:
		target_center = _char_body.global_position + Vector3(0, 1.0, 0)

	var ry := deg_to_rad(_yaw)
	var rp := deg_to_rad(_pitch)
	var offset := Vector3(
		_distance * cos(rp) * sin(ry),
		_distance * sin(rp),
		_distance * cos(rp) * cos(ry)
	)
	_camera.global_position = target_center + offset
	_camera.look_at(target_center)
