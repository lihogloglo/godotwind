## Test script for TerrainStreamer coordinate mapping
## Run this to verify coordinate mapping is correct
extends Node

const TerrainStreamerScript := preload("res://src/core/world/terrain_streamer.gd")

func _ready() -> void:
	print("\n========== TerrainStreamer Coordinate Mapping Tests ==========\n")

	var all_passed := true

	# Test 1: cell_to_chunk basic cases
	print("[TEST 1] cell_to_chunk basic cases")
	all_passed = all_passed and _test_equal(TerrainStreamerScript.cell_to_chunk(0, 0), Vector2i(0, 0), "cell (0,0) → chunk (0,0)")
	all_passed = all_passed and _test_equal(TerrainStreamerScript.cell_to_chunk(-1, -1), Vector2i(-1, -1), "cell (-1,-1) → chunk (-1,-1)")
	all_passed = all_passed and _test_equal(TerrainStreamerScript.cell_to_chunk(31, 31), Vector2i(0, 0), "cell (31,31) → chunk (0,0)")
	all_passed = all_passed and _test_equal(TerrainStreamerScript.cell_to_chunk(32, 32), Vector2i(1, 1), "cell (32,32) → chunk (1,1)")
	all_passed = all_passed and _test_equal(TerrainStreamerScript.cell_to_chunk(-32, -32), Vector2i(-1, -1), "cell (-32,-32) → chunk (-1,-1)")
	all_passed = all_passed and _test_equal(TerrainStreamerScript.cell_to_chunk(-33, -33), Vector2i(-2, -2), "cell (-33,-33) → chunk (-2,-2)")

	# Test 2: cell_to_local coordinate mapping
	print("\n[TEST 2] cell_to_local coordinate mapping")
	all_passed = all_passed and _test_equal(TerrainStreamerScript.cell_to_local(0, 0, Vector2i(0, 0)), Vector2i(-16, -16), "cell (0,0) in chunk (0,0) → local (-16,-16)")
	all_passed = all_passed and _test_equal(TerrainStreamerScript.cell_to_local(31, 31, Vector2i(0, 0)), Vector2i(15, 15), "cell (31,31) in chunk (0,0) → local (15,15)")
	all_passed = all_passed and _test_equal(TerrainStreamerScript.cell_to_local(32, 32, Vector2i(1, 1)), Vector2i(-16, -16), "cell (32,32) in chunk (1,1) → local (-16,-16)")
	all_passed = all_passed and _test_equal(TerrainStreamerScript.cell_to_local(63, 63, Vector2i(1, 1)), Vector2i(15, 15), "cell (63,63) in chunk (1,1) → local (15,15)")

	# Test 3: Local coordinate bounds validation
	print("\n[TEST 3] Local coordinate bounds (must be -16 to +15)")
	all_passed = all_passed and _test_bounds_valid(Vector2i(-16, -16), "local (-16,-16) is valid")
	all_passed = all_passed and _test_bounds_valid(Vector2i(15, 15), "local (15,15) is valid")
	all_passed = all_passed and _test_bounds_valid(Vector2i(0, 0), "local (0,0) is valid")
	all_passed = all_passed and _test_bounds_invalid(Vector2i(-17, 0), "local (-17,0) is invalid")
	all_passed = all_passed and _test_bounds_invalid(Vector2i(16, 0), "local (16,0) is invalid")

	# Test 4: Morrowind map coverage
	print("\n[TEST 4] Morrowind map coverage")
	print("  Morrowind map: X: -18 to +23, Y: -19 to +27")

	var chunks_needed: Dictionary = {}
	for x in range(-18, 24):
		for y in range(-19, 28):
			var chunk = TerrainStreamerScript.cell_to_chunk(x, y)
			chunks_needed[chunk] = true

	var chunk_count = chunks_needed.size()
	var expected_chunks = 4  # Should fit in 2×2 chunks

	if chunk_count == expected_chunks:
		print("  ✓ PASS: Full Morrowind map fits in %d chunks (expected %d)" % [chunk_count, expected_chunks])
	else:
		print("  ✗ FAIL: Morrowind map requires %d chunks (expected %d)" % [chunk_count, expected_chunks])
		all_passed = false

	# List the chunks
	print("  Chunks needed:")
	var chunk_list: Array[Vector2i] = []
	for chunk: Vector2i in chunks_needed:
		chunk_list.append(chunk)
	chunk_list.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x
	)
	for chunk in chunk_list:
		var cell_min := Vector2i(chunk.x * 32, chunk.y * 32)
		var cell_max := Vector2i(chunk.x * 32 + 31, chunk.y * 32 + 31)
		print("    Chunk (%d, %d): cells [%d,%d] to [%d,%d]" % [
			chunk.x, chunk.y, cell_min.x, cell_min.y, cell_max.x, cell_max.y
		])

	# Test 5: Chunk boundaries
	print("\n[TEST 5] Chunk boundaries (edge cases)")
	all_passed = all_passed and _test_equal(TerrainStreamerScript.cell_to_chunk(0, 0), Vector2i(0, 0), "cell (0,0) → chunk (0,0)")
	all_passed = all_passed and _test_equal(TerrainStreamerScript.cell_to_chunk(1, 0), Vector2i(0, 0), "cell (1,0) → chunk (0,0)")
	all_passed = all_passed and _test_equal(TerrainStreamerScript.cell_to_chunk(31, 0), Vector2i(0, 0), "cell (31,0) → chunk (0,0)")
	all_passed = all_passed and _test_equal(TerrainStreamerScript.cell_to_chunk(32, 0), Vector2i(1, 0), "cell (32,0) → chunk (1,0)")
	all_passed = all_passed and _test_equal(TerrainStreamerScript.cell_to_chunk(-1, 0), Vector2i(-1, 0), "cell (-1,0) → chunk (-1,0)")

	# Final result
	print("\n" + "=".repeat(60))
	if all_passed:
		print("[SUCCESS] All coordinate mapping tests PASSED ✓")
		print("The unified coordinate system is working correctly!")
	else:
		print("[FAILURE] Some tests FAILED ✗")
		print("Review the failed tests above.")
	print("=".repeat(60) + "\n")

	# Auto-quit after tests
	await get_tree().create_timer(1.0).timeout
	get_tree().quit()


func _test_equal(actual: Vector2i, expected: Vector2i, description: String) -> bool:
	if actual == expected:
		print("  ✓ PASS: %s" % description)
		return true
	else:
		print("  ✗ FAIL: %s (got %s, expected %s)" % [description, actual, expected])
		return false


func _test_bounds_valid(local: Vector2i, description: String) -> bool:
	var valid := local.x >= -16 and local.x <= 15 and local.y >= -16 and local.y <= 15
	if valid:
		print("  ✓ PASS: %s" % description)
		return true
	else:
		print("  ✗ FAIL: %s" % description)
		return false


func _test_bounds_invalid(local: Vector2i, description: String) -> bool:
	var invalid := local.x < -16 or local.x > 15 or local.y < -16 or local.y > 15
	if invalid:
		print("  ✓ PASS: %s" % description)
		return true
	else:
		print("  ✗ FAIL: %s (should be invalid but passed bounds check)" % description)
		return false
