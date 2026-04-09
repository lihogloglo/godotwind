## Unit tests for ImpostorBakerV3 octahedral encoding.
##
## Locks the encoding contract between baker (GDScript) and the phase 2
## runtime shader (GLSL). Both sides must produce identical mappings or the
## frame lookup desyncs. Five essential tests cover the contract — round
## trip, unit length, hemi y>=0 invariant, and generate_directions count.
extends GdUnitTestSuite

const Baker := preload("res://src/tools/prebaking/impostor_baker_v3.gd")
const EPSILON := 1e-4


func test_sphere_round_trip() -> void:
	# encode(decode(uv)) ≈ uv for every cell of the production 8×8 grid.
	# Picks up sign-flip + fold-direction bugs in either function.
	for cell_uv in _grid_cell_uvs(8):
		var dir := Baker.octahedral_decode_sphere(cell_uv)
		var round_trip := Baker.octahedral_encode_sphere(dir)
		assert_float(round_trip.x).is_equal_approx(cell_uv.x, EPSILON)
		assert_float(round_trip.y).is_equal_approx(cell_uv.y, EPSILON)
		assert_float(dir.length()).is_equal_approx(1.0, EPSILON)


func test_hemi_round_trip() -> void:
	# Same for hemi.
	for cell_uv in _grid_cell_uvs(8):
		var dir := Baker.octahedral_decode_hemi(cell_uv)
		var round_trip := Baker.octahedral_encode_hemi(dir)
		assert_float(round_trip.x).is_equal_approx(cell_uv.x, EPSILON)
		assert_float(round_trip.y).is_equal_approx(cell_uv.y, EPSILON)
		assert_float(dir.length()).is_equal_approx(1.0, EPSILON)


func test_hemi_all_above_horizon() -> void:
	# Hemi unwrap must never produce a direction below the horizon.
	for cell_uv in _grid_cell_uvs(8):
		var dir := Baker.octahedral_decode_hemi(cell_uv)
		assert_float(dir.y).is_greater_equal(-EPSILON)


func test_sphere_covers_both_hemispheres() -> void:
	# Sphere variant must produce both upper and lower directions.
	var has_upper := false
	var has_lower := false
	for cell_uv in _grid_cell_uvs(8):
		var dir := Baker.octahedral_decode_sphere(cell_uv)
		if dir.y > 0.1:
			has_upper = true
		if dir.y < -0.1:
			has_lower = true
	assert_bool(has_upper).is_true()
	assert_bool(has_lower).is_true()


func test_generate_directions_count_and_unit_length() -> void:
	# generate_directions returns N² unit vectors for both projections.
	for projection in ["hemi", "sphere"]:
		var dirs := Baker.generate_directions(8, projection)
		assert_int(dirs.size()).is_equal(64)
		for d in dirs:
			assert_float(d.length()).is_equal_approx(1.0, EPSILON)


## Enumerate cell-center UVs for an N×N grid, matching baker traversal order.
static func _grid_cell_uvs(grid_size: int) -> Array[Vector2]:
	var uvs: Array[Vector2] = []
	uvs.resize(grid_size * grid_size)
	var idx := 0
	for row in range(grid_size):
		for col in range(grid_size):
			var u := (float(col) + 0.5) / float(grid_size)
			var v := (float(row) + 0.5) / float(grid_size)
			uvs[idx] = Vector2(u * 2.0 - 1.0, v * 2.0 - 1.0)
			idx += 1
	return uvs
