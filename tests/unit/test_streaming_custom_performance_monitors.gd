extends GdUnitTestSuite

const NativeStreamingManagerScript: Script = preload("res://src/core/world/native_streaming_manager.gd")
const MONITOR_IDS: Array[StringName] = [
	&"godotwind/streaming/queue_size",
	&"godotwind/streaming/loaded_cells",
	&"godotwind/streaming/visual_ready_cells",
	&"godotwind/streaming/async_requests",
	&"godotwind/streaming/startup_phase",
	&"godotwind/streaming/first_playable_reached",
	&"godotwind/streaming/stream_total_ms",
]


func after_test() -> void:
	_clear_monitors()


func test_registering_streaming_custom_monitors_twice_is_safe() -> void:
	_clear_monitors()
	var manager: Node = NativeStreamingManagerScript.new()

	manager.call("_register_streaming_custom_monitors")
	manager.call("_register_streaming_custom_monitors")

	for monitor_id: StringName in MONITOR_IDS:
		assert_bool(Performance.has_custom_monitor(monitor_id)).is_true()

	assert_float(float(Performance.get_custom_monitor(&"godotwind/streaming/startup_phase"))).is_equal(1.0)
	assert_float(float(Performance.get_custom_monitor(&"godotwind/streaming/first_playable_reached"))).is_equal(0.0)
	assert_float(float(Performance.get_custom_monitor(&"godotwind/streaming/queue_size"))).is_equal(0.0)

	manager.call("_unregister_streaming_custom_monitors")
	for monitor_id: StringName in MONITOR_IDS:
		assert_bool(Performance.has_custom_monitor(monitor_id)).is_false()
	manager.free()


func _clear_monitors() -> void:
	for monitor_id: StringName in MONITOR_IDS:
		if Performance.has_custom_monitor(monitor_id):
			Performance.remove_custom_monitor(monitor_id)
