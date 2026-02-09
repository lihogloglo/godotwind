extends SceneTree
## Minimal diagnostic: Does TwoBoneIK3D actually solve and modify bone poses?
## Run: godot --headless --path . --script res://tests/test_twoboneik3d_diagnostic.gd

func _init() -> void:
	print("=" .repeat(60))
	print("TWOBONEIK3D DIAGNOSTIC")
	print("=" .repeat(60))
	await process_frame

	await _test_solve_with_variations()

	print("=" .repeat(60))
	print("DONE")
	print("=" .repeat(60))
	quit(0)


func _test_solve_with_variations() -> void:
	# Test multiple approaches to make TwoBoneIK3D work
	await _try_approach("BASELINE: default setup", func(skel: Skeleton3D, ik: TwoBoneIK3D): pass)

	await _try_approach("set_process_internal(true) on skeleton", func(skel: Skeleton3D, ik: TwoBoneIK3D):
		skel.set_process_internal(true)
	)

	await _try_approach("skeleton.modifier_callback_mode_process = PHYSICS", func(skel: Skeleton3D, ik: TwoBoneIK3D):
		skel.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS
	)

	await _try_approach("ik.reset() after setup", func(skel: Skeleton3D, ik: TwoBoneIK3D):
		ik.reset()
	)

	await _try_approach("show_rest_only = false explicit", func(skel: Skeleton3D, ik: TwoBoneIK3D):
		skel.show_rest_only = false
	)

	await _try_approach("force_update + set_process_internal", func(skel: Skeleton3D, ik: TwoBoneIK3D):
		skel.set_process_internal(true)
		skel.force_update_all_bone_transforms()
	)


func _try_approach(label: String, setup: Callable) -> void:
	print("\n--- %s ---" % label)

	var container := Node3D.new()
	root.add_child(container)

	var skeleton := Skeleton3D.new()
	container.add_child(skeleton)

	# Simple 3-bone vertical chain with identity basis
	var upper := skeleton.add_bone("Upper")
	skeleton.set_bone_rest(upper, Transform3D(Basis.IDENTITY, Vector3(0, 1.0, 0)))

	var mid := skeleton.add_bone("Mid")
	skeleton.set_bone_parent(mid, upper)
	skeleton.set_bone_rest(mid, Transform3D(Basis.IDENTITY, Vector3(0, -0.5, 0)))

	var end_b := skeleton.add_bone("End")
	skeleton.set_bone_parent(end_b, mid)
	skeleton.set_bone_rest(end_b, Transform3D(Basis.IDENTITY, Vector3(0, -0.5, 0)))

	skeleton.reset_bone_poses()

	# Record rest
	var rest_end_global := skeleton.get_bone_global_pose(end_b).origin
	var rest_upper_rot := skeleton.get_bone_pose_rotation(upper)

	# Create IK
	var ik := TwoBoneIK3D.new()
	ik.set_setting_count(1)
	ik.set_root_bone_name(0, "Upper")
	ik.set_middle_bone_name(0, "Mid")
	ik.set_end_bone_name(0, "End")
	skeleton.add_child(ik)

	# Target to the right
	var target := Node3D.new()
	container.add_child(target)
	target.global_position = Vector3(0.5, 0.0, 0.0)
	ik.set_target_node(0, ik.get_path_to(target))

	# Apply the approach-specific setup
	setup.call(skeleton, ik)

	# Print state
	print("  is_processing_internal: %s" % skeleton.is_processing_internal())
	print("  modifier_mode: %d" % skeleton.modifier_callback_mode_process)
	print("  show_rest_only: %s" % skeleton.show_rest_only)
	print("  ik.active: %s ik.influence: %.2f" % [ik.active, ik.influence])

	# Wait
	for i in 30:
		await process_frame

	var new_end := skeleton.get_bone_global_pose(end_b).origin
	var new_upper_rot := skeleton.get_bone_pose_rotation(upper)
	var rot_changed := not rest_upper_rot.is_equal_approx(new_upper_rot)
	var pos_changed := not rest_end_global.is_equal_approx(new_end)
	print("  Upper rot changed: %s (dot=%.6f)" % [rot_changed, rest_upper_rot.dot(new_upper_rot)])
	print("  End pos changed: %s  end=%s" % [pos_changed, str(new_end)])

	if rot_changed or pos_changed:
		print("  >>> IK SOLVED! <<<")
	else:
		print("  (no change)")

	container.queue_free()
	await process_frame
