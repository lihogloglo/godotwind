extends SceneTree
## Test: SPA — BoneMap creation for Morrowind and Mixamo skeletons
## Run with: godot --headless --script res://tests/test_skeleton_profile.gd

const SPA := preload("res://src/core/animation/skeleton_profile_adapter.gd")

var _tests_passed: int = 0
var _tests_failed: int = 0


func _init() -> void:
	print("=" .repeat(60))
	print("SKELETON PROFILE ADAPTER TESTS")
	print("=" .repeat(60))
	print("")

	_test_morrowind_skeleton()
	_test_mixamo_skeleton()
	_test_generic_skeleton()
	_test_detection()
	_test_utility_methods()
	_test_ik_bone_resolution()
	_test_blend_mask()

	_print_summary()
	quit(1 if _tests_failed > 0 else 0)


# =========================================================================
# TEST: MORROWIND SKELETON
# =========================================================================

func _test_morrowind_skeleton() -> void:
	print("─" .repeat(60))
	print("SUITE: Morrowind Bip01 Skeleton")
	print("─" .repeat(60))

	var skeleton := _create_morrowind_skeleton()
	_assert(skeleton.get_bone_count() > 0, "Morrowind skeleton created with bones")

	var bone_map := SPA.create_bone_map(skeleton)
	_assert(bone_map != null, "BoneMap created for Morrowind skeleton")
	if bone_map == null:
		skeleton.free()
		return

	# Verify profile is set
	_assert(bone_map.profile != null, "BoneMap has SkeletonProfileHumanoid")

	# Verify core bone mappings
	_assert_bone(bone_map, "Hips", "Bip01")
	_assert_bone(bone_map, "Spine", "Bip01 Spine")
	_assert_bone(bone_map, "Chest", "Bip01 Spine1")
	_assert_bone(bone_map, "UpperChest", "Bip01 Spine2")
	_assert_bone(bone_map, "Neck", "Bip01 Neck")
	_assert_bone(bone_map, "Head", "Bip01 Head")

	# Left arm
	_assert_bone(bone_map, "LeftShoulder", "Bip01 L Clavicle")
	_assert_bone(bone_map, "LeftUpperArm", "Bip01 L UpperArm")
	_assert_bone(bone_map, "LeftLowerArm", "Bip01 L Forearm")
	_assert_bone(bone_map, "LeftHand", "Bip01 L Hand")

	# Right arm
	_assert_bone(bone_map, "RightShoulder", "Bip01 R Clavicle")
	_assert_bone(bone_map, "RightUpperArm", "Bip01 R UpperArm")
	_assert_bone(bone_map, "RightLowerArm", "Bip01 R Forearm")
	_assert_bone(bone_map, "RightHand", "Bip01 R Hand")

	# Left leg
	_assert_bone(bone_map, "LeftUpperLeg", "Bip01 L Thigh")
	_assert_bone(bone_map, "LeftLowerLeg", "Bip01 L Calf")
	_assert_bone(bone_map, "LeftFoot", "Bip01 L Foot")
	_assert_bone(bone_map, "LeftToes", "Bip01 L Toe0")

	# Right leg
	_assert_bone(bone_map, "RightUpperLeg", "Bip01 R Thigh")
	_assert_bone(bone_map, "RightLowerLeg", "Bip01 R Calf")
	_assert_bone(bone_map, "RightFoot", "Bip01 R Foot")
	_assert_bone(bone_map, "RightToes", "Bip01 R Toe0")

	# Verify metadata was stored
	var retrieved := SPA.get_bone_map(skeleton)
	_assert(retrieved == bone_map, "BoneMap stored as skeleton metadata")

	# Verify bone index lookup
	var hips_idx := SPA.get_bone_index(skeleton, "Hips")
	_assert(hips_idx >= 0, "Hips bone index found via adapter")
	_assert_eq(skeleton.get_bone_name(hips_idx), "Bip01", "Hips index resolves to Bip01")

	var mapped_count := SPA.count_mapped_bones(bone_map)
	_assert(mapped_count >= 22, "At least 22 core bones mapped (got %d)" % mapped_count)
	print("  INFO: Mapped %d profile bones" % mapped_count)

	skeleton.free()
	print("")


# =========================================================================
# TEST: MIXAMO SKELETON
# =========================================================================

func _test_mixamo_skeleton() -> void:
	print("─" .repeat(60))
	print("SUITE: Mixamo Skeleton")
	print("─" .repeat(60))

	var skeleton := _create_mixamo_skeleton()
	_assert(skeleton.get_bone_count() > 0, "Mixamo skeleton created with bones")

	var bone_map := SPA.create_bone_map(skeleton)
	_assert(bone_map != null, "BoneMap created for Mixamo skeleton")
	if bone_map == null:
		skeleton.free()
		return

	# Verify core bone mappings
	_assert_bone(bone_map, "Hips", "mixamorig1_Hips")
	_assert_bone(bone_map, "Spine", "mixamorig1_Spine")
	_assert_bone(bone_map, "Chest", "mixamorig1_Spine1")
	_assert_bone(bone_map, "UpperChest", "mixamorig1_Spine2")
	_assert_bone(bone_map, "Neck", "mixamorig1_Neck")
	_assert_bone(bone_map, "Head", "mixamorig1_Head")

	# Left arm
	_assert_bone(bone_map, "LeftShoulder", "mixamorig1_LeftShoulder")
	_assert_bone(bone_map, "LeftUpperArm", "mixamorig1_LeftArm")
	_assert_bone(bone_map, "LeftLowerArm", "mixamorig1_LeftForeArm")
	_assert_bone(bone_map, "LeftHand", "mixamorig1_LeftHand")

	# Right arm
	_assert_bone(bone_map, "RightShoulder", "mixamorig1_RightShoulder")
	_assert_bone(bone_map, "RightUpperArm", "mixamorig1_RightArm")
	_assert_bone(bone_map, "RightLowerArm", "mixamorig1_RightForeArm")
	_assert_bone(bone_map, "RightHand", "mixamorig1_RightHand")

	# Left leg
	_assert_bone(bone_map, "LeftUpperLeg", "mixamorig1_LeftUpLeg")
	_assert_bone(bone_map, "LeftLowerLeg", "mixamorig1_LeftLeg")
	_assert_bone(bone_map, "LeftFoot", "mixamorig1_LeftFoot")
	_assert_bone(bone_map, "LeftToes", "mixamorig1_LeftToeBase")

	# Right leg
	_assert_bone(bone_map, "RightUpperLeg", "mixamorig1_RightUpLeg")
	_assert_bone(bone_map, "RightLowerLeg", "mixamorig1_RightLeg")
	_assert_bone(bone_map, "RightFoot", "mixamorig1_RightFoot")
	_assert_bone(bone_map, "RightToes", "mixamorig1_RightToeBase")

	# Verify detection type
	var skel_type := SPA.detect_skeleton_type(skeleton)
	_assert_eq(skel_type, SPA.SkeletonType.MIXAMO, "Detected as MIXAMO type")

	var mapped_count := SPA.count_mapped_bones(bone_map)
	_assert(mapped_count >= 20, "At least 20 core bones mapped (got %d)" % mapped_count)
	print("  INFO: Mapped %d profile bones" % mapped_count)

	skeleton.free()
	print("")


# =========================================================================
# TEST: GENERIC SKELETON
# =========================================================================

func _test_generic_skeleton() -> void:
	print("─" .repeat(60))
	print("SUITE: Generic Skeleton (heuristic matching)")
	print("─" .repeat(60))

	var skeleton := _create_generic_skeleton()
	_assert(skeleton.get_bone_count() > 0, "Generic skeleton created with bones")

	var bone_map := SPA.create_bone_map(skeleton)
	_assert(bone_map != null, "BoneMap created for generic skeleton")
	if bone_map == null:
		skeleton.free()
		return

	# Verify some core mappings work via heuristic
	_assert_bone(bone_map, "Hips", "Hips")
	_assert_bone(bone_map, "Spine", "Spine")
	_assert_bone(bone_map, "Head", "Head")
	_assert_bone(bone_map, "Neck", "Neck")

	var mapped_count := SPA.count_mapped_bones(bone_map)
	_assert(mapped_count >= 4, "At least 4 bones mapped via heuristic (got %d)" % mapped_count)
	print("  INFO: Mapped %d profile bones (heuristic)" % mapped_count)

	skeleton.free()
	print("")


# =========================================================================
# TEST: DETECTION
# =========================================================================

func _test_detection() -> void:
	print("─" .repeat(60))
	print("SUITE: Skeleton Type Detection")
	print("─" .repeat(60))

	# Morrowind detection
	var mw_skel := _create_morrowind_skeleton()
	_assert_eq(SPA.detect_skeleton_type(mw_skel),
		SPA.SkeletonType.MORROWIND, "Detects Morrowind skeleton")
	mw_skel.free()

	# Mixamo detection
	var mx_skel := _create_mixamo_skeleton()
	_assert_eq(SPA.detect_skeleton_type(mx_skel),
		SPA.SkeletonType.MIXAMO, "Detects Mixamo skeleton")
	mx_skel.free()

	# Generic detection
	var gen_skel := _create_generic_skeleton()
	_assert_eq(SPA.detect_skeleton_type(gen_skel),
		SPA.SkeletonType.GENERIC, "Detects generic skeleton")
	gen_skel.free()

	print("")


# =========================================================================
# TEST: UTILITY METHODS
# =========================================================================

func _test_utility_methods() -> void:
	print("─" .repeat(60))
	print("SUITE: Utility Methods")
	print("─" .repeat(60))

	# Null/empty skeleton
	var null_map := SPA.create_bone_map(null)
	_assert(null_map == null, "Returns null for null skeleton")

	var empty_skel := Skeleton3D.new()
	var empty_map := SPA.create_bone_map(empty_skel)
	_assert(empty_map == null, "Returns null for empty skeleton")
	empty_skel.free()

	# Unmapped bones list
	var skel := _create_morrowind_skeleton()
	var bone_map := SPA.create_bone_map(skel)
	if bone_map:
		var unmapped := SPA.get_unmapped_bones(bone_map)
		print("  INFO: Unmapped bones: %s" % ", ".join(unmapped) if unmapped.size() > 0 else "  INFO: All profile bones mapped!")
		# There will be some unmapped (eyes, jaw, fingers not in simple MW skeleton)
		_assert(unmapped.size() >= 0, "get_unmapped_bones returns array")

	# get_bone_index for non-existent bone
	var bad_idx := SPA.get_bone_index(skel, "NonExistentBone")
	_assert_eq(bad_idx, -1, "Returns -1 for non-existent profile bone")

	skel.free()
	print("")


# =========================================================================
# TEST: IK BONE RESOLUTION
# =========================================================================

func _test_ik_bone_resolution() -> void:
	print("─" .repeat(60))
	print("SUITE: IK Bone Resolution via BoneMap")
	print("─" .repeat(60))

	# IK key -> profile bone mapping (must match ik_controller.gd _IK_TO_PROFILE)
	var ik_to_profile := {
		"hips": "Hips", "head": "Head", "neck": "Neck",
		"left_foot": "LeftFoot", "right_foot": "RightFoot",
		"left_upper_leg": "LeftUpperLeg", "left_lower_leg": "LeftLowerLeg",
		"right_upper_leg": "RightUpperLeg", "right_lower_leg": "RightLowerLeg",
		"left_upper_arm": "LeftUpperArm", "left_forearm": "LeftLowerArm",
		"left_hand": "LeftHand",
		"right_upper_arm": "RightUpperArm", "right_forearm": "RightLowerArm",
		"right_hand": "RightHand",
	}

	# Test on Morrowind skeleton
	var mw := _create_morrowind_skeleton()
	SPA.create_bone_map(mw)

	_assert(SPA.get_bone_index(mw, "LeftFoot") >= 0, "MW: IK finds LeftFoot")
	_assert(SPA.get_bone_index(mw, "RightFoot") >= 0, "MW: IK finds RightFoot")
	_assert(SPA.get_bone_index(mw, "LeftUpperLeg") >= 0, "MW: IK finds LeftUpperLeg")
	_assert(SPA.get_bone_index(mw, "LeftLowerLeg") >= 0, "MW: IK finds LeftLowerLeg")
	_assert(SPA.get_bone_index(mw, "Hips") >= 0, "MW: IK finds Hips")
	_assert(SPA.get_bone_index(mw, "Head") >= 0, "MW: IK finds Head")
	_assert(SPA.get_bone_index(mw, "Neck") >= 0, "MW: IK finds Neck")
	_assert(SPA.get_bone_index(mw, "UpperChest") >= 0, "MW: IK finds UpperChest (spine2)")

	# Verify correct bone names resolved
	var lfoot := SPA.get_skeleton_bone(mw, "LeftFoot")
	_assert_eq(lfoot, &"Bip01 L Foot", "MW: LeftFoot resolves to Bip01 L Foot")
	var rhand := SPA.get_skeleton_bone(mw, "RightHand")
	_assert_eq(rhand, &"Bip01 R Hand", "MW: RightHand resolves to Bip01 R Hand")
	mw.free()

	# Test on Mixamo skeleton
	var mx := _create_mixamo_skeleton()
	SPA.create_bone_map(mx)

	_assert(SPA.get_bone_index(mx, "LeftFoot") >= 0, "MX: IK finds LeftFoot")
	_assert(SPA.get_bone_index(mx, "RightFoot") >= 0, "MX: IK finds RightFoot")
	_assert(SPA.get_bone_index(mx, "LeftUpperLeg") >= 0, "MX: IK finds LeftUpperLeg")
	_assert(SPA.get_bone_index(mx, "Hips") >= 0, "MX: IK finds Hips")
	_assert(SPA.get_bone_index(mx, "Head") >= 0, "MX: IK finds Head")

	var mx_lfoot := SPA.get_skeleton_bone(mx, "LeftFoot")
	_assert_eq(mx_lfoot, &"mixamorig1_LeftFoot", "MX: LeftFoot resolves to mixamorig1_LeftFoot")
	mx.free()

	print("")


# =========================================================================
# TEST: BLEND MASK BONE RESOLUTION
# =========================================================================
# Tests that profile bones used by AnimationBlendMask resolve correctly.
# Can't import ABM directly in headless (depends on Log autoload).

func _test_blend_mask() -> void:
	print("─" .repeat(60))
	print("SUITE: Blend Mask Bone Resolution via BoneMap")
	print("─" .repeat(60))

	# Blend mask roots use these profile bones:
	#   TORSO: "Chest", LEFT_ARM: "LeftShoulder", RIGHT_ARM: "RightShoulder"

	# --- Morrowind skeleton ---
	var mw := _create_morrowind_skeleton()
	SPA.create_bone_map(mw)

	# TORSO root: Chest -> Bip01 Spine1
	_assert_eq(SPA.get_skeleton_bone(mw, "Chest"), &"Bip01 Spine1",
		"MW: Chest resolves to Bip01 Spine1 (TORSO root)")
	_assert(SPA.get_bone_index(mw, "Chest") >= 0, "MW: Chest bone index found")

	# LEFT_ARM root: LeftShoulder -> Bip01 L Clavicle
	_assert_eq(SPA.get_skeleton_bone(mw, "LeftShoulder"), &"Bip01 L Clavicle",
		"MW: LeftShoulder resolves to Bip01 L Clavicle (LEFT_ARM root)")

	# RIGHT_ARM root: RightShoulder -> Bip01 R Clavicle
	_assert_eq(SPA.get_skeleton_bone(mw, "RightShoulder"), &"Bip01 R Clavicle",
		"MW: RightShoulder resolves to Bip01 R Clavicle (RIGHT_ARM root)")

	# Verify descendants exist (blend mask walks down from root)
	var chest_idx := SPA.get_bone_index(mw, "Chest")
	var head_idx := mw.find_bone("Bip01 Head")
	_assert(_is_descendant_of(mw, head_idx, chest_idx),
		"MW: Head is descendant of Chest (TORSO mask covers head)")

	var lclavicle_idx := SPA.get_bone_index(mw, "LeftShoulder")
	var lhand_idx := mw.find_bone("Bip01 L Hand")
	_assert(_is_descendant_of(mw, lhand_idx, lclavicle_idx),
		"MW: L Hand is descendant of L Clavicle (LEFT_ARM mask covers hand)")
	mw.free()

	# --- Mixamo skeleton ---
	var mx := _create_mixamo_skeleton()
	SPA.create_bone_map(mx)

	_assert_eq(SPA.get_skeleton_bone(mx, "Chest"), &"mixamorig1_Spine1",
		"MX: Chest resolves to mixamorig1_Spine1 (TORSO root)")
	_assert_eq(SPA.get_skeleton_bone(mx, "LeftShoulder"), &"mixamorig1_LeftShoulder",
		"MX: LeftShoulder resolves (LEFT_ARM root)")
	_assert_eq(SPA.get_skeleton_bone(mx, "RightShoulder"), &"mixamorig1_RightShoulder",
		"MX: RightShoulder resolves (RIGHT_ARM root)")
	mx.free()

	print("")


## Check if bone_idx is a descendant of ancestor_idx
func _is_descendant_of(skeleton: Skeleton3D, bone_idx: int, ancestor_idx: int) -> bool:
	var current := bone_idx
	while current >= 0:
		var parent := skeleton.get_bone_parent(current)
		if parent == ancestor_idx:
			return true
		current = parent
	return false


# =========================================================================
# SKELETON BUILDERS
# =========================================================================

func _create_morrowind_skeleton() -> Skeleton3D:
	## Build a minimal Morrowind Bip01 skeleton for testing.
	var skeleton := Skeleton3D.new()
	var bones := [
		# [name, parent_name]
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
	## Build a simplified Mixamo skeleton for testing (core bones only).
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
		skeleton.set_bone_rest(indices[def[0]], Transform3D(Basis.IDENTITY, Vector3(0, 0.1, 0)))

	return skeleton


func _create_generic_skeleton() -> Skeleton3D:
	## Build a skeleton with generic/standard naming for heuristic testing.
	var skeleton := Skeleton3D.new()
	var bones := ["Hips", "Spine", "Chest", "Neck", "Head",
		"LeftShoulder", "Left_UpperArm", "Left_LowerArm", "Left_Hand",
		"RightShoulder", "Right_UpperArm", "Right_LowerArm", "Right_Hand",
		"Left_UpperLeg", "Left_LowerLeg", "Left_Foot",
		"Right_UpperLeg", "Right_LowerLeg", "Right_Foot"]
	for bone_name in bones:
		skeleton.add_bone(bone_name)
	return skeleton


# =========================================================================
# ASSERTION HELPERS
# =========================================================================

func _assert_bone(bone_map: BoneMap, profile_name: String, expected_skeleton_name: String) -> void:
	var actual := bone_map.get_skeleton_bone_name(profile_name)
	var passed := (actual == expected_skeleton_name)
	if passed:
		_tests_passed += 1
		print("  PASS: %s → %s" % [profile_name, expected_skeleton_name])
	else:
		_tests_failed += 1
		print("  FAIL: %s → expected '%s', got '%s'" % [profile_name, expected_skeleton_name, actual])


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
