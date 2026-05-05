extends GdUnitTestSuite

const GUARDED_FILES: Array[String] = [
	"res://src/core/world/cell_manager.gd",
	"res://src/core/world/reference_instantiator.gd",
	"res://src/core/world/object_paging.gd",
	"res://src/core/world/native_impostor_renderer.gd",
	"res://src/core/world/distant_light_manager.gd",
]


func test_core_streaming_modules_do_not_call_esm_manager_directly() -> void:
	for path: String in GUARDED_FILES:
		var code := _read_without_comments(path)
		assert_bool("ESMManager." in code).override_failure_message(
			"%s must use WorldObjectSource/adapter APIs instead of ESMManager directly" % path
		).is_false()


func test_near_streaming_uses_world_object_payload_boundary() -> void:
	var cell_manager_code := _read_without_comments("res://src/core/world/cell_manager.gd")
	var instantiator_code := _read_without_comments("res://src/core/world/reference_instantiator.gd")
	assert_bool("world_objects_to_classify" in cell_manager_code).is_true()
	assert_bool("resolve_gameplay_payload" in instantiator_code).is_true()
	assert_bool("instantiate_world_object" in cell_manager_code).is_true()


func _read_without_comments(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	assert_object(file).is_not_null()
	var lines: PackedStringArray = PackedStringArray()
	while not file.eof_reached():
		var line := file.get_line()
		if line.strip_edges().begins_with("#"):
			continue
		lines.append(line)
	return "\n".join(lines)
