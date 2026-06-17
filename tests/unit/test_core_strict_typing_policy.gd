extends GdUnitTestSuite

const UNTYPED_WARNING_SETTING: String = "gdscript/warnings/untyped_declaration"

const CORE_UNTYPED_SUPPRESSION_LEDGER: Dictionary = {
	"src/core/logging/crash_breadcrumb.gd": 1,
	"src/core/native_bridge.gd": 1,
	"src/core/world/object_paging_kernel.gd": 1,
	"src/core/world/morrowind/morrowind_terrain_texture_loader.gd": 2,
}


func test_project_enables_untyped_declaration_warning() -> void:
	var project_text: String = _read_text("res://project.godot")
	var setting_line: String = "%s=1" % UNTYPED_WARNING_SETTING
	assert_bool(_has_uncommented_line(project_text, setting_line)) \
		.override_failure_message("project.godot must enable %s so src/core typing drift is visible" % UNTYPED_WARNING_SETTING) \
		.is_true()


func test_core_untyped_warning_suppressions_match_debt_ledger() -> void:
	var files: Array[String] = []
	_collect_files_with_extension("res://src/core", "gd", files)
	var observed: Dictionary = {}
	for path: String in files:
		var normalized: String = _normalize_path(path)
		var count: int = _count_occurrences(_read_text(path), '@warning_ignore("untyped_declaration"')
		if count > 0:
			observed[normalized] = count

	assert_int(observed.size()) \
		.override_failure_message("Unexpected core files suppress untyped_declaration: %s" % str(observed)) \
		.is_equal(CORE_UNTYPED_SUPPRESSION_LEDGER.size())

	for path: String in CORE_UNTYPED_SUPPRESSION_LEDGER.keys():
		assert_int(int(observed.get(path, 0))) \
			.override_failure_message("%s untyped_declaration suppressions changed; remove the debt or update the Spring cleanup ledger intentionally" % path) \
			.is_equal(int(CORE_UNTYPED_SUPPRESSION_LEDGER[path]))


func test_transition_provider_loop_variables_are_typed() -> void:
	var source: String = _read_text("res://src/core/world/morrowind/morrowind_transition_provider.gd")
	assert_bool(source.find("for ref in cell_payload.references:") == -1) \
		.override_failure_message("MorrowindTransitionProvider loop variables must remain typed under the core strict-typing policy") \
		.is_true()


func _collect_files_with_extension(dir_path: String, extension: String, out: Array[String]) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry: String = dir.get_next()
		if entry.is_empty():
			break
		if entry.begins_with("."):
			continue
		var child: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			_collect_files_with_extension(child, extension, out)
		elif entry.ends_with("." + extension):
			out.append(child)
	dir.list_dir_end()


func _read_text(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	assert_object(file).is_not_null()
	return file.get_as_text()


func _has_uncommented_line(text: String, expected_line: String) -> bool:
	for line: String in text.split("\n"):
		var stripped: String = line.strip_edges()
		if stripped.begins_with("#") or stripped.begins_with(";"):
			continue
		if stripped == expected_line:
			return true
	return false


func _count_occurrences(text: String, needle: String) -> int:
	if needle.is_empty():
		return 0
	var total: int = 0
	var search_from: int = 0
	while true:
		var idx: int = text.find(needle, search_from)
		if idx < 0:
			return total
		total += 1
		search_from = idx + needle.length()
	return total


func _normalize_path(path: String) -> String:
	var normalized: String = path.replace("\\", "/")
	if normalized.begins_with("res://"):
		return normalized.substr("res://".length())
	return normalized
