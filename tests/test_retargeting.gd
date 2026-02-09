extends SceneTree
## Test: RetargetSetup — Cross-skeleton animation retargeting utilities
## Run with: godot --headless --script res://tests/test_retargeting.gd

const SPA := preload("res://src/core/animation/skeleton_profile_adapter.gd")
const RTS := preload("res://src/core/animation/retarget_setup.gd")

var _tests_passed: int = 0
var _tests_failed: int = 0


func _init() -> void:
	print("=" .repeat(60))
	print("RETARGET SETUP TESTS")
	print("=" .repeat(60))
	print("")

	_test_build_remap()
	_test_rename_morrowind()
	_test_rename_mixamo()
	_test_rename_preserves_unmapped()
	_test_create_source_skeleton()
	_test_create_source_custom_rests()
	_test_create_modifier()
	_test_remap_animation()
	_test_remap_animation_no_match()
	_test_remap_animation_preserves_node_path()
	_test_remap_library()
	_test_setup_same_type()
	_test_setup_different_type()
	_test_hierarchy_assembly()

	_print_summary()
	quit(1 if _tests_failed > 0 else 0)


# =========================================================================
# TEST: build_remap
# =========================================================================

func _test_build_remap() -> void:
	print("─" .repeat(60))
	print("SUITE: build_remap")
	print("─" .repeat(60))

	var mw := _create_morrowind_skeleton()
	var remap := RTS.build_remap(mw)

	_assert(remap.size() > 0, "Remap has entries")
	_assert_eq(remap.get("Bip01"), "Hips", "Bip01 -> Hips")
	_assert_eq(remap.get("Bip01 L Thigh"), "LeftUpperLeg", "Bip01 L Thigh -> LeftUpperLeg")
	_assert_eq(remap.get("Bip01 Head"), "Head", "Bip01 Head -> Head")

	# Verify skeleton was NOT modified
	_assert(mw.find_bone("Bip01") >= 0, "Skeleton still has Bip01 (not modified)")
	_assert(mw.find_bone("Bip01 L Thigh") >= 0, "Skeleton still has Bip01 L Thigh")

	mw.free()
	print("")


# =========================================================================
# TEST: rename_bones_to_profile — Morrowind
# =========================================================================

func _test_rename_morrowind() -> void:
	print("─" .repeat(60))
	print("SUITE: rename_bones_to_profile (Morrowind)")
	print("─" .repeat(60))

	var mw := _create_morrowind_skeleton()
	var remap := RTS.rename_bones_to_profile(mw)

	_assert(remap.size() > 0, "Remap dict returned entries")

	# Core bones should now have profile names
	_assert(mw.find_bone("Hips") >= 0, "Bip01 renamed to Hips")
	_assert(mw.find_bone("Spine") >= 0, "Bip01 Spine renamed to Spine")
	_assert(mw.find_bone("Chest") >= 0, "Bip01 Spine1 renamed to Chest")
	_assert(mw.find_bone("UpperChest") >= 0, "Bip01 Spine2 renamed to UpperChest")
	_assert(mw.find_bone("Neck") >= 0, "Bip01 Neck renamed to Neck")
	_assert(mw.find_bone("Head") >= 0, "Bip01 Head renamed to Head")

	# Limbs
	_assert(mw.find_bone("LeftUpperLeg") >= 0, "Bip01 L Thigh renamed to LeftUpperLeg")
	_assert(mw.find_bone("LeftLowerLeg") >= 0, "Bip01 L Calf renamed to LeftLowerLeg")
	_assert(mw.find_bone("LeftFoot") >= 0, "Bip01 L Foot renamed to LeftFoot")
	_assert(mw.find_bone("RightUpperArm") >= 0, "Bip01 R UpperArm renamed to RightUpperArm")
	_assert(mw.find_bone("RightHand") >= 0, "Bip01 R Hand renamed to RightHand")

	# Old names should be gone
	_assert(mw.find_bone("Bip01") < 0, "Old name Bip01 no longer exists")
	_assert(mw.find_bone("Bip01 L Thigh") < 0, "Old name Bip01 L Thigh no longer exists")

	# Remap dict correctness
	_assert_eq(remap.get("Bip01"), "Hips", "Remap: Bip01 -> Hips")
	_assert_eq(remap.get("Bip01 L Thigh"), "LeftUpperLeg", "Remap: Bip01 L Thigh -> LeftUpperLeg")

	# Bone count preserved
	_assert_eq(mw.get_bone_count(), 22, "Bone count unchanged (22)")

	# Stale metadata cleared
	_assert(not mw.has_meta("bone_map"), "Stale bone_map metadata cleared")

	mw.free()
	print("")


# =========================================================================
# TEST: rename_bones_to_profile — Mixamo
# =========================================================================

func _test_rename_mixamo() -> void:
	print("─" .repeat(60))
	print("SUITE: rename_bones_to_profile (Mixamo)")
	print("─" .repeat(60))

	var mx := _create_mixamo_skeleton()
	var remap := RTS.rename_bones_to_profile(mx)

	_assert(remap.size() > 0, "Remap dict returned entries")
	_assert(mx.find_bone("Hips") >= 0, "mixamorig1_Hips renamed to Hips")
	_assert(mx.find_bone("LeftUpperLeg") >= 0, "mixamorig1_LeftUpLeg renamed to LeftUpperLeg")
	_assert(mx.find_bone("RightFoot") >= 0, "mixamorig1_RightFoot renamed to RightFoot")

	# Old names gone
	_assert(mx.find_bone("mixamorig1_Hips") < 0, "Old mixamorig1_Hips gone")

	_assert_eq(mx.get_bone_count(), 22, "Bone count unchanged (22)")

	mx.free()
	print("")


# =========================================================================
# TEST: rename preserves unmapped bones
# =========================================================================

func _test_rename_preserves_unmapped() -> void:
	print("─" .repeat(60))
	print("SUITE: rename preserves unmapped bones")
	print("─" .repeat(60))

	# Create skeleton with some extra non-standard bones
	var skeleton := _create_morrowind_skeleton()
	var extra_idx := skeleton.add_bone("Bip01 Weapon")
	skeleton.set_bone_parent(extra_idx, skeleton.find_bone("Bip01 R Hand"))

	RTS.rename_bones_to_profile(skeleton)

	# Standard bones renamed
	_assert(skeleton.find_bone("Hips") >= 0, "Standard bone renamed")
	# Extra bone NOT renamed (not in profile)
	_assert(skeleton.find_bone("Bip01 Weapon") >= 0, "Unmapped bone 'Bip01 Weapon' preserved")

	skeleton.free()
	print("")


# =========================================================================
# TEST: create_source_skeleton
# =========================================================================

func _test_create_source_skeleton() -> void:
	print("─" .repeat(60))
	print("SUITE: create_source_skeleton")
	print("─" .repeat(60))

	var reference := _create_morrowind_skeleton()
	RTS.rename_bones_to_profile(reference)

	var source := RTS.create_source_skeleton(reference)

	_assert(source != null, "Source skeleton created")
	_assert_eq(source.name, "SourceSkeleton", "Source skeleton named correctly")
	_assert_eq(source.get_bone_count(), reference.get_bone_count(), "Same bone count")

	# Bones have same names
	for i in reference.get_bone_count():
		var ref_name := reference.get_bone_name(i)
		var src_name := source.get_bone_name(i)
		if ref_name != src_name:
			_assert(false, "Bone %d name mismatch: %s vs %s" % [i, ref_name, src_name])
			reference.free()
			source.free()
			print("")
			return

	_assert(true, "All bone names match reference")

	# Hierarchy preserved
	for i in source.get_bone_count():
		if source.get_bone_parent(i) != reference.get_bone_parent(i):
			_assert(false, "Bone %d parent mismatch" % i)
			reference.free()
			source.free()
			print("")
			return

	_assert(true, "All bone parents match reference")

	# Rest poses copied
	for i in source.get_bone_count():
		var ref_rest := reference.get_bone_rest(i)
		var src_rest := source.get_bone_rest(i)
		if not ref_rest.is_equal_approx(src_rest):
			_assert(false, "Bone %d rest pose mismatch" % i)
			reference.free()
			source.free()
			print("")
			return

	_assert(true, "All bone rest poses match reference")

	reference.free()
	source.free()
	print("")


# =========================================================================
# TEST: create_source_skeleton with custom rest poses
# =========================================================================

func _test_create_source_custom_rests() -> void:
	print("─" .repeat(60))
	print("SUITE: create_source_skeleton (custom rest poses)")
	print("─" .repeat(60))

	var reference := _create_morrowind_skeleton()
	RTS.rename_bones_to_profile(reference)

	var custom_rest := Transform3D(Basis.IDENTITY, Vector3(0, 1.0, 0))
	var source := RTS.create_source_skeleton(reference, {"Hips": custom_rest})

	_assert(source != null, "Source skeleton created with custom rests")

	# Hips should have custom rest
	var hips_idx := source.find_bone("Hips")
	_assert(hips_idx >= 0, "Source has Hips bone")
	if hips_idx >= 0:
		var hips_rest := source.get_bone_rest(hips_idx)
		_assert(hips_rest.origin.is_equal_approx(Vector3(0, 1.0, 0)),
			"Hips has custom rest pose (Y=1.0)")

	# Other bones should have reference rest
	var spine_idx := source.find_bone("Spine")
	if spine_idx >= 0:
		var spine_rest := source.get_bone_rest(spine_idx)
		var ref_spine_rest := reference.get_bone_rest(reference.find_bone("Spine"))
		_assert(spine_rest.is_equal_approx(ref_spine_rest),
			"Spine has reference rest pose (not custom)")

	reference.free()
	source.free()
	print("")


# =========================================================================
# TEST: create_modifier
# =========================================================================

func _test_create_modifier() -> void:
	print("─" .repeat(60))
	print("SUITE: create_modifier")
	print("─" .repeat(60))

	var modifier := RTS.create_modifier()

	_assert(modifier != null, "Modifier created")
	_assert_eq(modifier.name, "RetargetModifier", "Modifier named correctly")
	_assert(modifier.profile is SkeletonProfileHumanoid, "Modifier has SkeletonProfileHumanoid")
	_assert_eq(modifier.use_global_pose, false, "Default: use_global_pose = false")

	var modifier_global := RTS.create_modifier(true)
	_assert_eq(modifier_global.use_global_pose, true, "Global pose mode when requested")

	modifier.free()
	modifier_global.free()
	print("")


# =========================================================================
# TEST: remap_animation
# =========================================================================

func _test_remap_animation() -> void:
	print("─" .repeat(60))
	print("SUITE: remap_animation")
	print("─" .repeat(60))

	# Create a test animation with Morrowind bone names
	var anim := Animation.new()
	anim.length = 1.0

	# Add position track for "Bip01 L Thigh"
	var track0 := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(track0, NodePath("Skeleton3D:Bip01 L Thigh"))
	anim.position_track_insert_key(track0, 0.0, Vector3.ZERO)
	anim.position_track_insert_key(track0, 1.0, Vector3(0, 1, 0))

	# Add rotation track for "Bip01 Head"
	var track1 := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(track1, NodePath("Skeleton3D:Bip01 Head"))
	anim.rotation_track_insert_key(track1, 0.0, Quaternion.IDENTITY)

	# Add a non-bone track (should be untouched)
	var track2 := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(track2, NodePath("SomeNode:property"))
	anim.track_insert_key(track2, 0.0, 1.0)

	# Remap
	var name_map := {
		"Bip01 L Thigh": "LeftUpperLeg",
		"Bip01 Head": "Head",
	}
	var remapped := RTS.remap_animation(anim, name_map)

	_assert(remapped != null, "Remapped animation returned")
	_assert_eq(remapped.get_track_count(), 3, "Track count preserved")

	# Check remapped paths
	var path0 := String(remapped.track_get_path(0))
	_assert_eq(path0, "Skeleton3D:LeftUpperLeg", "Track 0 remapped to LeftUpperLeg")

	var path1 := String(remapped.track_get_path(1))
	_assert_eq(path1, "Skeleton3D:Head", "Track 1 remapped to Head")

	# Non-bone track untouched
	var path2 := String(remapped.track_get_path(2))
	_assert_eq(path2, "SomeNode:property", "Non-bone track path unchanged")

	# Keyframes preserved
	_assert_eq(remapped.track_get_key_count(0), 2, "Track 0 keyframe count preserved")
	_assert_eq(remapped.track_get_key_count(1), 1, "Track 1 keyframe count preserved")

	# Original not modified
	var orig_path0 := String(anim.track_get_path(0))
	_assert_eq(orig_path0, "Skeleton3D:Bip01 L Thigh", "Original animation not modified")

	print("")


# =========================================================================
# TEST: remap_animation — no matching bones
# =========================================================================

func _test_remap_animation_no_match() -> void:
	print("─" .repeat(60))
	print("SUITE: remap_animation (no match / empty map)")
	print("─" .repeat(60))

	var anim := Animation.new()
	var track0 := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(track0, NodePath("Skeleton3D:SomeBone"))
	anim.position_track_insert_key(track0, 0.0, Vector3.ZERO)

	# Empty map — should return original
	var result := RTS.remap_animation(anim, {})
	_assert(result == anim, "Empty name_map returns original animation")

	# Non-matching map — track unchanged
	var remapped := RTS.remap_animation(anim, {"OtherBone": "NewBone"})
	var path := String(remapped.track_get_path(0))
	_assert_eq(path, "Skeleton3D:SomeBone", "Non-matching map leaves track unchanged")

	print("")


# =========================================================================
# TEST: remap_animation — preserves node path
# =========================================================================

func _test_remap_animation_preserves_node_path() -> void:
	print("─" .repeat(60))
	print("SUITE: remap_animation (preserves node path)")
	print("─" .repeat(60))

	var anim := Animation.new()
	var track0 := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(track0, NodePath("Character/Model/Skeleton3D:Bip01 Spine"))
	anim.rotation_track_insert_key(track0, 0.0, Quaternion.IDENTITY)

	var remapped := RTS.remap_animation(anim, {"Bip01 Spine": "Spine"})

	var path := String(remapped.track_get_path(0))
	_assert_eq(path, "Character/Model/Skeleton3D:Spine",
		"Node path preserved, only bone name changed")

	print("")


# =========================================================================
# TEST: remap_library
# =========================================================================

func _test_remap_library() -> void:
	print("─" .repeat(60))
	print("SUITE: remap_library")
	print("─" .repeat(60))

	# Create library with 2 animations
	var lib := AnimationLibrary.new()

	var idle := Animation.new()
	idle.length = 2.0
	var t0 := idle.add_track(Animation.TYPE_ROTATION_3D)
	idle.track_set_path(t0, NodePath("Skeleton3D:Bip01"))
	idle.rotation_track_insert_key(t0, 0.0, Quaternion.IDENTITY)
	lib.add_animation("idle", idle)

	var walk := Animation.new()
	walk.length = 1.0
	var t1 := walk.add_track(Animation.TYPE_POSITION_3D)
	walk.track_set_path(t1, NodePath("Skeleton3D:Bip01 L Foot"))
	walk.position_track_insert_key(t1, 0.0, Vector3.ZERO)
	lib.add_animation("walk", walk)

	# Remap
	var name_map := {"Bip01": "Hips", "Bip01 L Foot": "LeftFoot"}
	var remapped := RTS.remap_library(lib, name_map)

	_assert(remapped != null, "Remapped library returned")
	_assert(remapped.has_animation("idle"), "Library has 'idle' animation")
	_assert(remapped.has_animation("walk"), "Library has 'walk' animation")

	var idle_path := String(remapped.get_animation("idle").track_get_path(0))
	_assert_eq(idle_path, "Skeleton3D:Hips", "idle: Bip01 remapped to Hips")

	var walk_path := String(remapped.get_animation("walk").track_get_path(0))
	_assert_eq(walk_path, "Skeleton3D:LeftFoot", "walk: Bip01 L Foot remapped to LeftFoot")

	# Original not modified
	var orig_path := String(lib.get_animation("idle").track_get_path(0))
	_assert_eq(orig_path, "Skeleton3D:Bip01", "Original library not modified")

	print("")


# =========================================================================
# TEST: setup_retargeting — same type returns null
# =========================================================================

func _test_setup_same_type() -> void:
	print("─" .repeat(60))
	print("SUITE: setup_retargeting (same type → null)")
	print("─" .repeat(60))

	var mw := _create_morrowind_skeleton()
	@warning_ignore("untyped_declaration")
	var result = RTS.setup_retargeting(mw, SPA.SkeletonType.MORROWIND)

	_assert(result == null, "Same skeleton type returns null (no retargeting needed)")

	# Skeleton should be unmodified (bones not renamed)
	_assert(mw.find_bone("Bip01") >= 0, "Skeleton not modified for same-type")

	mw.free()
	print("")


# =========================================================================
# TEST: setup_retargeting — different type
# =========================================================================

func _test_setup_different_type() -> void:
	print("─" .repeat(60))
	print("SUITE: setup_retargeting (different type)")
	print("─" .repeat(60))

	var mw := _create_morrowind_skeleton()
	@warning_ignore("untyped_declaration")
	var result = RTS.setup_retargeting(mw, SPA.SkeletonType.MIXAMO)

	_assert(result != null, "Different type returns result")
	_assert(result is Dictionary, "Result is Dictionary")

	if result:
		_assert(result.has("source_skeleton"), "Result has source_skeleton")
		_assert(result.has("modifier"), "Result has modifier")
		_assert(result.has("target_remap"), "Result has target_remap")

		var source: Skeleton3D = result["source_skeleton"]
		var modifier: RetargetModifier3D = result["modifier"]
		var target_remap: Dictionary = result["target_remap"]

		_assert(source != null, "Source skeleton created")
		_assert(modifier != null, "Modifier created")
		_assert(target_remap.size() > 0, "Target remap has entries")

		# Target skeleton should now have profile names
		_assert(mw.find_bone("Hips") >= 0, "Target renamed: Hips")
		_assert(mw.find_bone("LeftUpperLeg") >= 0, "Target renamed: LeftUpperLeg")
		_assert(mw.find_bone("Bip01") < 0, "Target: old Bip01 gone")

		# Source skeleton should have matching profile names
		_assert(source.find_bone("Hips") >= 0, "Source has Hips")
		_assert(source.find_bone("LeftUpperLeg") >= 0, "Source has LeftUpperLeg")

		# Same bone count
		_assert_eq(source.get_bone_count(), mw.get_bone_count(),
			"Source and target have same bone count")

		source.free()
		modifier.free()

	mw.free()
	print("")


# =========================================================================
# TEST: Hierarchy assembly
# =========================================================================

func _test_hierarchy_assembly() -> void:
	print("─" .repeat(60))
	print("SUITE: Hierarchy assembly (source > modifier > target)")
	print("─" .repeat(60))

	# Create target skeleton with profile names
	var target := _create_morrowind_skeleton()
	RTS.rename_bones_to_profile(target)

	# Create source skeleton
	var source := RTS.create_source_skeleton(target)

	# Create modifier
	var modifier := RTS.create_modifier()

	# Assemble: source > modifier > target
	source.add_child(modifier)
	modifier.add_child(target)

	# Verify hierarchy
	_assert_eq(modifier.get_parent(), source, "Modifier parent is source skeleton")
	_assert_eq(target.get_parent(), modifier, "Target parent is modifier")
	_assert_eq(source.get_child_count(), 1, "Source has 1 child (modifier)")
	_assert_eq(modifier.get_child_count(), 1, "Modifier has 1 child (target)")

	# Modifier configuration
	_assert(modifier.profile is SkeletonProfileHumanoid, "Modifier has correct profile")
	_assert_eq(modifier.use_global_pose, false, "Modifier uses local pose mode")

	# Source and target share bone names (required by RetargetModifier3D)
	var shared_count := 0
	for i in source.get_bone_count():
		var src_name := source.get_bone_name(i)
		if target.find_bone(src_name) >= 0:
			shared_count += 1
	_assert_eq(shared_count, source.get_bone_count(),
		"All source bones have matching target bones")

	source.free()  # Frees modifier and target too (children)
	print("")


# =========================================================================
# SKELETON BUILDERS (same as test_skeleton_profile.gd)
# =========================================================================

func _create_morrowind_skeleton() -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	var bones := [
		["Bip01", ""],
		["Bip01 Spine", "Bip01"],
		["Bip01 Spine1", "Bip01 Spine"],
		["Bip01 Spine2", "Bip01 Spine1"],
		["Bip01 Neck", "Bip01 Spine2"],
		["Bip01 Head", "Bip01 Neck"],
		["Bip01 L Clavicle", "Bip01 Spine2"],
		["Bip01 L UpperArm", "Bip01 L Clavicle"],
		["Bip01 L Forearm", "Bip01 L UpperArm"],
		["Bip01 L Hand", "Bip01 L Forearm"],
		["Bip01 R Clavicle", "Bip01 Spine2"],
		["Bip01 R UpperArm", "Bip01 R Clavicle"],
		["Bip01 R Forearm", "Bip01 R UpperArm"],
		["Bip01 R Hand", "Bip01 R Forearm"],
		["Bip01 L Thigh", "Bip01"],
		["Bip01 L Calf", "Bip01 L Thigh"],
		["Bip01 L Foot", "Bip01 L Calf"],
		["Bip01 L Toe0", "Bip01 L Foot"],
		["Bip01 R Thigh", "Bip01"],
		["Bip01 R Calf", "Bip01 R Thigh"],
		["Bip01 R Foot", "Bip01 R Calf"],
		["Bip01 R Toe0", "Bip01 R Foot"],
	]

	var indices := {}
	for def in bones:
		var idx := skeleton.add_bone(def[0])
		indices[def[0]] = idx

	for def in bones:
		if not def[1].is_empty() and def[1] in indices:
			skeleton.set_bone_parent(indices[def[0]], indices[def[1]])
		skeleton.set_bone_rest(indices[def[0]], Transform3D(Basis.IDENTITY, Vector3(0, 0.1, 0)))

	return skeleton


func _create_mixamo_skeleton() -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	var bones := [
		["mixamorig1_Hips", ""],
		["mixamorig1_Spine", "mixamorig1_Hips"],
		["mixamorig1_Spine1", "mixamorig1_Spine"],
		["mixamorig1_Spine2", "mixamorig1_Spine1"],
		["mixamorig1_Neck", "mixamorig1_Spine2"],
		["mixamorig1_Head", "mixamorig1_Neck"],
		["mixamorig1_LeftShoulder", "mixamorig1_Spine2"],
		["mixamorig1_LeftArm", "mixamorig1_LeftShoulder"],
		["mixamorig1_LeftForeArm", "mixamorig1_LeftArm"],
		["mixamorig1_LeftHand", "mixamorig1_LeftForeArm"],
		["mixamorig1_RightShoulder", "mixamorig1_Spine2"],
		["mixamorig1_RightArm", "mixamorig1_RightShoulder"],
		["mixamorig1_RightForeArm", "mixamorig1_RightArm"],
		["mixamorig1_RightHand", "mixamorig1_RightForeArm"],
		["mixamorig1_LeftUpLeg", "mixamorig1_Hips"],
		["mixamorig1_LeftLeg", "mixamorig1_LeftUpLeg"],
		["mixamorig1_LeftFoot", "mixamorig1_LeftLeg"],
		["mixamorig1_LeftToeBase", "mixamorig1_LeftFoot"],
		["mixamorig1_RightUpLeg", "mixamorig1_Hips"],
		["mixamorig1_RightLeg", "mixamorig1_RightUpLeg"],
		["mixamorig1_RightFoot", "mixamorig1_RightLeg"],
		["mixamorig1_RightToeBase", "mixamorig1_RightFoot"],
	]

	var indices := {}
	for def in bones:
		var idx := skeleton.add_bone(def[0])
		indices[def[0]] = idx

	for def in bones:
		if not def[1].is_empty() and def[1] in indices:
			skeleton.set_bone_parent(indices[def[0]], indices[def[1]])
		# Give Mixamo slightly different rest poses to distinguish from Morrowind
		skeleton.set_bone_rest(indices[def[0]], Transform3D(Basis.IDENTITY, Vector3(0, 0.15, 0)))

	return skeleton


# =========================================================================
# ASSERTION HELPERS
# =========================================================================

func _assert(condition: bool, test_name: String) -> void:
	if condition:
		_tests_passed += 1
		print("  PASS: %s" % test_name)
	else:
		_tests_failed += 1
		print("  FAIL: %s" % test_name)


func _assert_eq(actual: Variant, expected: Variant, test_name: String) -> void:
	if actual == expected:
		_tests_passed += 1
		print("  PASS: %s" % test_name)
	else:
		_tests_failed += 1
		print("  FAIL: %s (expected %s, got %s)" % [test_name, expected, actual])


func _print_summary() -> void:
	print("=" .repeat(60))
	print("  Total: %d | Passed: %d | Failed: %d" % [
		_tests_passed + _tests_failed, _tests_passed, _tests_failed])
	if _tests_failed == 0:
		print("  ALL TESTS PASSED")
	else:
		print("  SOME TESTS FAILED")
	print("=" .repeat(60))
