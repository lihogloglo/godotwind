## Unit tests for DistanceUtils — cell distance math, tier classification, coordinate conversion.
## These are foundational math tests with zero external dependencies.
extends GdUnitTestSuite

const DU := preload("res://src/core/world/distance_utils.gd")


func test_cell_distance_squared_same_cell() -> void:
	var result := DU.cell_distance_squared(Vector2i(0, 0), Vector2i(0, 0))
	assert_float(result).is_equal(0.0)


func test_cell_distance_squared_adjacent() -> void:
	var result := DU.cell_distance_squared(Vector2i(0, 0), Vector2i(1, 0))
	# 1 cell = CELL_SIZE_METERS apart, so distance_sq = CELL_SIZE_METERS^2
	var expected := DU.CELL_SIZE_METERS * DU.CELL_SIZE_METERS
	assert_float(result).is_equal_approx(expected, 0.01)


func test_cell_distance_squared_diagonal() -> void:
	var result := DU.cell_distance_squared(Vector2i(0, 0), Vector2i(1, 1))
	# Diagonal: sqrt(2) * CELL_SIZE_METERS, so squared = 2 * CELL_SIZE_METERS^2
	var expected := 2.0 * DU.CELL_SIZE_METERS * DU.CELL_SIZE_METERS
	assert_float(result).is_equal_approx(expected, 0.01)


func test_cell_distance_is_sqrt_of_squared() -> void:
	var a := Vector2i(3, -5)
	var b := Vector2i(-2, 7)
	var dist := DU.cell_distance(a, b)
	var dist_sq := DU.cell_distance_squared(a, b)
	assert_float(dist * dist).is_equal_approx(dist_sq, 0.01)


func test_cell_to_world_center_origin() -> void:
	# Cell (0,0) center should be at (HALF_CELL, 0, -HALF_CELL) due to Z flip
	var center := DU.cell_to_world_center(Vector2i(0, 0))
	assert_float(center.x).is_equal_approx(DU.HALF_CELL_SIZE, 0.01)
	assert_float(center.y).is_equal(0.0)
	assert_float(center.z).is_equal_approx(-DU.HALF_CELL_SIZE, 0.01)


func test_world_to_cell_roundtrip() -> void:
	# Convert cell to world center, then back — should return same cell
	var original := Vector2i(5, -3)
	var world_pos := DU.cell_to_world_center(original)
	var result := DU.world_to_cell(world_pos)
	assert_int(result.x).is_equal(original.x)
	assert_int(result.y).is_equal(original.y)


func test_tier_constants_are_ordered() -> void:
	assert_float(DU.NEAR_START).is_less(DU.NEAR_END)
	assert_float(DU.NEAR_END).is_equal(DU.MID_START)
	assert_float(DU.MID_START).is_less(DU.MID_END)
	# Phase 5 (2026-04-17): FAR_START broken from MID_END and pinned at
	# HLOD_END (1km). The MID+HLOD pipeline carries 150-1000m; impostors
	# only pick up at FAR_START.
	assert_float(DU.HLOD_START).is_equal(300.0)
	assert_float(DU.HLOD_END).is_equal(DU.FAR_START)
	assert_float(DU.FAR_START).is_less(DU.FAR_END)


func test_distance_to_cell_radius() -> void:
	# 150m / CELL_SIZE_METERS should give ~1-2 cells
	var radius := DU.distance_to_cell_radius(DU.NEAR_END)
	assert_int(radius).is_greater(0)
	# And converting back should cover at least the original distance
	var covered := DU.cell_radius_to_distance(radius)
	assert_float(covered).is_greater_equal(DU.NEAR_END)


func test_is_cell_in_range() -> void:
	var center := Vector2i(0, 0)
	# Cell at origin is in range 0-500m
	assert_bool(DU.is_cell_in_range(center, center, 0.0, 500.0)).is_true()
	# Cell 10 cells away is NOT in range 0-100m (10*117 = 1170m > 100m)
	assert_bool(DU.is_cell_in_range(Vector2i(10, 0), center, 0.0, 100.0)).is_false()
