@warning_ignore("untyped_declaration", "unsafe_method_access", "inferred_declaration")
extends Node3D
## Windowed TwoBoneIK3D deep diagnostic v3
## Run: godot --path . res://tests/test_twoboneik3d_windowed.tscn

var _frame := 0
var _skel: Skeleton3D
var _ik: TwoBoneIK3D
var _rest_upper_rot: Quaternion
var _modification_count := 0
var _first_solved_frame := -1


func _ready() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, 30, 0)
	add_child(light)

	var camera := Camera3D.new()
	camera.current = true
	camera.position = Vector3(0, 1, 3)
	add_child(camera)
	camera.look_at(Vector3(0, 0.5, 0))

	print("=" .repeat(60))
	print("TWOBONEIK3D DEEP DIAGNOSTIC v3")
	print("=" .repeat(60))

	# Create skeleton
	_skel = Skeleton3D.new()
	add_child(_skel)

	var upper := _skel.add_bone("Upper")
	_skel.set_bone_rest(upper, Transform3D(Basis.IDENTITY, Vector3(0, 1.0, 0)))

	var mid := _skel.add_bone("Mid")
	_skel.set_bone_parent(mid, upper)
	_skel.set_bone_rest(mid, Transform3D(Basis.IDENTITY, Vector3(0, -0.5, 0)))

	var end_b := _skel.add_bone("End")
	_skel.set_bone_parent(end_b, mid)
	_skel.set_bone_rest(end_b, Transform3D(Basis.IDENTITY, Vector3(0, -0.5, 0)))

	_skel.reset_bone_poses()
	_rest_upper_rot = _skel.get_bone_pose_rotation(upper)
	print("REST upper_rot=%s" % str(_rest_upper_rot))
	print("Bone global poses: upper=%s mid=%s end=%s" % [
		str(_skel.get_bone_global_pose(0).origin),
		str(_skel.get_bone_global_pose(1).origin),
		str(_skel.get_bone_global_pose(2).origin)])

	# Create IK — add to skeleton FIRST, then configure
	_ik = TwoBoneIK3D.new()
	_skel.add_child(_ik)
	_ik.set_setting_count(1)
	_ik.set_root_bone_name(0, "Upper")
	_ik.set_middle_bone_name(0, "Mid")
	_ik.set_end_bone_name(0, "End")

	# Target to the RIGHT (not at rest position)
	var target := Node3D.new()
	target.name = "Target"
	add_child(target)
	target.global_position = Vector3(0.5, 0.5, 0.0)
	_ik.set_target_node(0, _ik.get_path_to(target))

	# Pole FORWARD
	var pole := Node3D.new()
	pole.name = "Pole"
	add_child(pole)
	pole.global_position = Vector3(0.0, 0.5, 1.0)
	_ik.set_pole_node(0, _ik.get_path_to(pole))
	_ik.set_pole_direction(0, SkeletonModifier3D.SECONDARY_DIRECTION_MINUS_Z)

	# Connect to modification signal to read poses RIGHT when modifier runs
	_ik.modification_processed.connect(_on_modification_processed)

	print("\n--- IK Config ---")
	print("active=%s  influence=%.2f" % [_ik.active, _ik.influence])
	print("root=%d mid=%d end=%d" % [_ik.get_root_bone(0), _ik.get_middle_bone(0), _ik.get_end_bone(0)])
	print("target='%s' pole='%s'" % [_ik.get_target_node(0), _ik.get_pole_node(0)])
	print("pole_direction=%d  mutable_bone_axes=%s" % [_ik.get_pole_direction(0), _ik.mutable_bone_axes])
	print("Skeleton global_transform=%s" % str(_skel.global_transform))


func _on_modification_processed() -> void:
	_modification_count += 1
	# Read poses INSIDE the signal — right after modifier ran
	var upper_rot = _skel.get_bone_pose_rotation(0)
	var solved = not _rest_upper_rot.is_equal_approx(upper_rot)
	if _modification_count <= 3 or solved:
		print("[SIGNAL #%d] upper=%s SOLVED=%s (in _process=%s)" % [
			_modification_count, str(upper_rot), solved, _frame > 0])
	if solved and _first_solved_frame < 0:
		_first_solved_frame = _modification_count
		print(">>> FIRST SOLVED at signal #%d <<<" % _modification_count)
		print("  mid=%s end=%s" % [
			str(_skel.get_bone_pose_rotation(1)),
			str(_skel.get_bone_global_pose(2).origin)])


func _process(_delta: float) -> void:
	_frame += 1

	if _frame == 5:
		# Check poses from _process (after skeleton updated)
		var upper_rot = _skel.get_bone_pose_rotation(0)
		var solved = not _rest_upper_rot.is_equal_approx(upper_rot)
		print("\n[_process frame 5] upper=%s SOLVED=%s (signals=%d)" % [
			str(upper_rot), solved, _modification_count])

	if _frame == 30:
		var upper_rot = _skel.get_bone_pose_rotation(0)
		var solved = not _rest_upper_rot.is_equal_approx(upper_rot)
		print("\n[_process frame 30] upper=%s SOLVED=%s (signals=%d)" % [
			str(upper_rot), solved, _modification_count])

		if not solved:
			print("\n--- Still not solved. Dumping all TwoBoneIK3D properties ---")
			for prop in _ik.get_property_list():
				var pname: String = prop["name"]
				if pname.begins_with("settings/") or pname in ["active", "influence", "mutable_bone_axes"]:
					print("  %s = %s" % [pname, str(_ik.get(pname))])

	if _frame == 60:
		var upper_rot = _skel.get_bone_pose_rotation(0)
		var solved = not _rest_upper_rot.is_equal_approx(upper_rot)
		print("\n[_process frame 60] SOLVED=%s signals=%d first_solved=%d" % [
			solved, _modification_count, _first_solved_frame])

		print("\n=== AUTO-QUIT ===")
		get_tree().quit(0)
