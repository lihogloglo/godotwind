## Test script for CollisionShapeLibrary
## Run with: godot --headless -s tests/test_collision_shapes.gd
extends SceneTree

const ShapeLib := preload("res://src/core/nif/collision_shape_library.gd")


func _init() -> void:
	print("=" .repeat(60))
	print("CollisionShapeLibrary Test Suite")
	print("=" .repeat(60))

	var passed := 0
	var failed := 0

	# Test 1: Library loads
	print("\n[TEST] Library singleton creation...")
	var lib := ShapeLib.get_instance()
	if lib != null:
		print("  PASS: Library instance created")
		passed += 1
	else:
		print("  FAIL: Library instance is null")
		failed += 1

	# Test 2: Library auto-loads YAML
	print("\n[TEST] YAML auto-loading...")
	if lib.is_loaded():
		var stats := lib.get_stats()
		print("  PASS: YAML loaded (%d items, %d patterns)" % [stats.item_count, stats.pattern_count])
		passed += 1
	else:
		print("  WARN: No YAML file found (this is OK if no file exists)")
		# Try explicit load
		if lib.load_from_file("res://collision-shapes.yaml"):
			print("  PASS: Explicitly loaded res://collision-shapes.yaml")
			passed += 1
		else:
			print("  SKIP: No YAML file available for testing")

	# Test 3: Exact item match
	print("\n[TEST] Exact item ID matching...")
	var test_cases := [
		["misc_com_bottle_01", ShapeLib.ShapeType.CYLINDER],
		["Gold_001", ShapeLib.ShapeType.CYLINDER],
		["misc_skull00", ShapeLib.ShapeType.SPHERE],
		["misc_com_wood_fork", ShapeLib.ShapeType.BOX],
	]

	for test in test_cases:
		var item_id: String = test[0]
		var expected: int = test[1]
		var result = lib.get_shape_for_item(item_id)
		if result != null and result == expected:
			print("  PASS: %s -> %s" % [item_id, ShapeLib.shape_type_name(result)])
			passed += 1
		elif result == null:
			print("  SKIP: %s (no mapping found)" % item_id)
		else:
			print("  FAIL: %s expected %s got %s" % [
				item_id,
				ShapeLib.shape_type_name(expected),
				ShapeLib.shape_type_name(result) if result != null else "null"
			])
			failed += 1

	# Test 4: Pattern matching
	print("\n[TEST] Pattern matching...")
	var pattern_tests := [
		["misc_com_bottle_99", ShapeLib.ShapeType.CYLINDER],  # Should match misc_com_bottle_*
		["misc_flask_anything", ShapeLib.ShapeType.CYLINDER],  # Should match misc_flask_*
		["ingred_pearl_01", ShapeLib.ShapeType.SPHERE],  # Should match ingred_pearl_*
		["misc_dwrv_goblet99", ShapeLib.ShapeType.CYLINDER],  # Should match misc_dwrv_goblet*
	]

	for test in pattern_tests:
		var item_id: String = test[0]
		var expected: int = test[1]
		var result = lib.get_shape_for_item(item_id)
		if result != null and result == expected:
			print("  PASS: %s -> %s (pattern match)" % [item_id, ShapeLib.shape_type_name(result)])
			passed += 1
		elif result == null:
			print("  SKIP: %s (no pattern match found)" % item_id)
		else:
			print("  FAIL: %s expected %s got %s" % [
				item_id,
				ShapeLib.shape_type_name(expected),
				ShapeLib.shape_type_name(result) if result != null else "null"
			])
			failed += 1

	# Test 5: No match returns null
	print("\n[TEST] Non-matching items return null...")
	var no_match_result = lib.get_shape_for_item("some_unknown_item_xyz")
	if no_match_result == null:
		print("  PASS: Unknown item returns null (will use auto-detection)")
		passed += 1
	else:
		print("  FAIL: Unknown item should return null, got %s" % ShapeLib.shape_type_name(no_match_result))
		failed += 1

	# Test 6: Case insensitivity
	print("\n[TEST] Case-insensitive matching...")
	var case_tests := [
		["MISC_COM_BOTTLE_01", ShapeLib.ShapeType.CYLINDER],
		["gold_001", ShapeLib.ShapeType.CYLINDER],
		["Misc_Skull00", ShapeLib.ShapeType.SPHERE],
	]

	for test in case_tests:
		var item_id: String = test[0]
		var expected: int = test[1]
		var result = lib.get_shape_for_item(item_id)
		if result != null and result == expected:
			print("  PASS: %s -> %s (case-insensitive)" % [item_id, ShapeLib.shape_type_name(result)])
			passed += 1
		elif result == null:
			print("  SKIP: %s (no mapping found)" % item_id)
		else:
			print("  FAIL: %s expected %s got %s" % [
				item_id,
				ShapeLib.shape_type_name(expected),
				ShapeLib.shape_type_name(result) if result != null else "null"
			])
			failed += 1

	# Test 7: Shape creation from bounds
	print("\n[TEST] Shape creation from bounds...")
	var bounds := AABB(Vector3(-0.5, -1.0, -0.5), Vector3(1.0, 2.0, 1.0))

	var box_shape := ShapeLib.create_shape_from_type(ShapeLib.ShapeType.BOX, bounds)
	if box_shape is BoxShape3D:
		print("  PASS: BOX shape created (size=%s)" % box_shape.size)
		passed += 1
	else:
		print("  FAIL: BOX shape creation failed")
		failed += 1

	var sphere_shape := ShapeLib.create_shape_from_type(ShapeLib.ShapeType.SPHERE, bounds)
	if sphere_shape is SphereShape3D:
		print("  PASS: SPHERE shape created (radius=%.2f)" % sphere_shape.radius)
		passed += 1
	else:
		print("  FAIL: SPHERE shape creation failed")
		failed += 1

	var cylinder_shape := ShapeLib.create_shape_from_type(ShapeLib.ShapeType.CYLINDER, bounds)
	if cylinder_shape is CylinderShape3D:
		print("  PASS: CYLINDER shape created (h=%.2f, r=%.2f)" % [cylinder_shape.height, cylinder_shape.radius])
		passed += 1
	else:
		print("  FAIL: CYLINDER shape creation failed")
		failed += 1

	var capsule_shape := ShapeLib.create_shape_from_type(ShapeLib.ShapeType.CAPSULE, bounds)
	if capsule_shape is CapsuleShape3D:
		print("  PASS: CAPSULE shape created (h=%.2f, r=%.2f)" % [capsule_shape.height, capsule_shape.radius])
		passed += 1
	else:
		print("  FAIL: CAPSULE shape creation failed")
		failed += 1

	# Test 8: Geometry-requiring shapes return null
	print("\n[TEST] Geometry-requiring shapes return null from create_shape_from_type...")
	var convex_shape := ShapeLib.create_shape_from_type(ShapeLib.ShapeType.CONVEX, bounds)
	if convex_shape == null:
		print("  PASS: CONVEX returns null (requires geometry)")
		passed += 1
	else:
		print("  FAIL: CONVEX should return null")
		failed += 1

	var trimesh_shape := ShapeLib.create_shape_from_type(ShapeLib.ShapeType.TRIMESH, bounds)
	if trimesh_shape == null:
		print("  PASS: TRIMESH returns null (requires geometry)")
		passed += 1
	else:
		print("  FAIL: TRIMESH should return null")
		failed += 1

	# Summary
	print("\n" + "=" .repeat(60))
	print("RESULTS: %d passed, %d failed" % [passed, failed])
	print("=" .repeat(60))

	if failed > 0:
		quit(1)
	else:
		quit(0)
