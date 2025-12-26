extends SceneTree

func _init() -> void:
	print("=== Testing Native C# Integration ===")

	# Test 1: Check if NativeBridge can be loaded
	var bridge_script := load("res://src/core/native_bridge.gd")
	if bridge_script == null:
		print("FAIL: Cannot load native_bridge.gd")
		quit()
		return
	print("PASS: native_bridge.gd loaded")

	# Test 2: Instantiate NativeBridge
	var bridge: RefCounted = bridge_script.new()
	if bridge == null:
		print("FAIL: Cannot instantiate NativeBridge")
		quit()
		return
	print("PASS: NativeBridge instantiated")

	# Test 3: Check native availability
	var has_terrain: bool = bridge.call("has_native_terrain")
	var has_nif: bool = bridge.call("has_native_nif")
	var has_binary: bool = bridge.call("has_native_binary_reader")

	print("Native Terrain Available: %s" % has_terrain)
	print("Native NIF Available: %s" % has_nif)
	print("Native Binary Reader Available: %s" % has_binary)

	# Test 4: Get performance info
	var perf_info: Dictionary = bridge.call("get_performance_info")
	print("Performance Info: %s" % str(perf_info))

	# Test 5: Try to create a native reader
	if has_nif:
		var reader: RefCounted = bridge.call("create_nif_reader")
		if reader != null:
			print("PASS: Native NIFReader created successfully")
		else:
			print("FAIL: Could not create Native NIFReader")

	# Test 6: Try to create terrain generator
	if has_terrain:
		var test_heights := PackedFloat32Array()
		test_heights.resize(65 * 65)
		for i in range(test_heights.size()):
			test_heights[i] = float(i) / 1000.0

		var heightmap: Image = bridge.call("generate_heightmap", test_heights)
		if heightmap != null:
			print("PASS: Native heightmap generated: %dx%d format=%d" % [heightmap.get_width(), heightmap.get_height(), heightmap.get_format()])
		else:
			print("FAIL: Could not generate heightmap")

	print("=== Test Complete ===")
	quit()
