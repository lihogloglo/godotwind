extends GdUnitTestSuite

const NativeStreamingManagerScript: Script = preload("res://src/core/world/native_streaming_manager.gd")


func test_default_benchmark_mode_is_valid_async_metadata() -> void:
	var manager: Node = NativeStreamingManagerScript.new()
	var meta: Dictionary = manager.call("get_benchmark_mode_metadata")
	var flags: Dictionary = meta.get("flags", {})

	assert_str(meta.get("schema", "")).is_equal("godotwind_benchmark_mode_v1")
	assert_bool(meta.get("valid_for_performance_baseline", false)).is_true()
	assert_bool(flags.get("async_loading_enabled", false)).is_true()
	assert_bool(flags.get("sync_loading_mode", true)).is_false()
	assert_bool(flags.has("phase_f_prereg_enabled")).is_false()
	assert_bool(flags.has("phase_f_prereg_status")).is_false()
	manager.free()


func test_sync_loading_mode_marks_benchmark_invalid() -> void:
	var manager: Node = NativeStreamingManagerScript.new()
	manager.set("async_loading_enabled", false)
	var meta: Dictionary = manager.call("get_benchmark_mode_metadata")
	var invalid: Array = meta.get("invalid_reasons", [])
	var stats: Dictionary = manager.call("get_stats")

	assert_bool(meta.get("valid_for_performance_baseline", true)).is_false()
	assert_bool(invalid.has("sync_loading_mode")).is_true()
	assert_bool(stats.has("benchmark_mode_metadata")).is_true()
	manager.free()


func test_near_only_mode_is_explicitly_classified() -> void:
	var manager: Node = NativeStreamingManagerScript.new()
	manager.call("set_mid_tier_visible", false)
	manager.call("set_impostors_visible", false)
	manager.call("set_hlod_visible", false)
	manager.call("set_distant_lights_visible", false)
	var meta: Dictionary = manager.call("get_benchmark_mode_metadata")
	var flags: Dictionary = meta.get("flags", {})

	assert_str(meta.get("mode_name", "")).is_equal("near_only")
	assert_bool(flags.get("near_only", false)).is_true()
	assert_bool(meta.get("valid_for_performance_baseline", false)).is_true()
	manager.free()
