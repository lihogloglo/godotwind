## Unit tests for CoordinateSystem — MW↔Godot coordinate conversion.
## Morrowind is Z-up, Godot is Y-up with flipped Z.
## Conversion: Vector3(mw.x, mw.z, -mw.y)
extends GdUnitTestSuite

const CS := preload("res://src/core/coordinate_system.gd")


func test_vector_to_godot_zero() -> void:
	var result := CS.vector_to_godot(Vector3.ZERO)
	assert_float(result.x).is_equal(0.0)
	assert_float(result.y).is_equal(0.0)
	assert_float(result.z).is_equal(0.0)


func test_vector_to_godot_axes() -> void:
	# vector_to_godot applies SCALE_FACTOR and swizzle: (x, z, -y) * SF
	# Test without scale to isolate the swizzle
	var mw_x := CS.vector_to_godot(Vector3(1, 0, 0), false)
	assert_float(mw_x.x).is_equal_approx(1.0, 0.001)  # X stays

	var mw_y := CS.vector_to_godot(Vector3(0, 1, 0), false)
	assert_float(mw_y.z).is_less(0.0)  # MW Y → negative Godot Z

	var mw_z := CS.vector_to_godot(Vector3(0, 0, 1), false)
	assert_float(mw_z.y).is_greater(0.0)  # MW Z → positive Godot Y


func test_vector_roundtrip() -> void:
	# Convert MW → Godot → MW should return original (using vector_to_mw for proper reverse)
	var original := Vector3(100.0, -50.0, 200.0)
	var godot := CS.vector_to_godot(original)
	var back := CS.vector_to_mw(godot)
	assert_float(back.x).is_equal_approx(original.x, 0.1)
	assert_float(back.y).is_equal_approx(original.y, 0.1)
	assert_float(back.z).is_equal_approx(original.z, 0.1)


func test_cell_size_is_positive() -> void:
	assert_float(CS.CELL_SIZE_GODOT).is_greater(0.0)
	# Morrowind cell size should be roughly 117m (8192 units / 128 * 2... varies by convention)
	assert_float(CS.CELL_SIZE_GODOT).is_greater(100.0)
	assert_float(CS.CELL_SIZE_GODOT).is_less(200.0)
