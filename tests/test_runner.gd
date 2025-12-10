extends SceneTree
## Headless Test Runner for Godotwind
## Run with: godot --headless --script res://tests/test_runner.gd
##
## Exit codes:
##   0 = All tests passed
##   1 = Some tests failed
##   2 = Error during test execution

var _tests_passed: int = 0
var _tests_failed: int = 0
var _test_results: Array[Dictionary] = []

func _init() -> void:
	print("=" .repeat(60))
	print("GODOTWIND TEST RUNNER")
	print("=" .repeat(60))
	print("")

	# Run all test suites
	_run_test_suite("ESM Loader Tests", _test_esm_loader)
	_run_test_suite("Record Parsing Tests", _test_record_parsing)
	_run_test_suite("ESM Manager Tests", _test_esm_manager)
	_run_test_suite("BSA Archive Tests", _test_bsa_archive)
	_run_test_suite("NIF Model Tests", _test_nif_model)

	# Print summary
	_print_summary()

	# Exit with appropriate code
	if _tests_failed > 0:
		quit(1)
	else:
		quit(0)


func _run_test_suite(suite_name: String, test_func: Callable) -> void:
	print("─" .repeat(60))
	print("SUITE: %s" % suite_name)
	print("─" .repeat(60))

	var start_time: int = Time.get_ticks_msec()
	test_func.call()
	var duration: int = Time.get_ticks_msec() - start_time

	print("  Duration: %d ms" % duration)
	print("")


func _assert(condition: bool, test_name: String, details: String = "") -> void:
	if condition:
		_tests_passed += 1
		print("  PASS: %s" % test_name)
		_test_results.append({"name": test_name, "passed": true})
	else:
		_tests_failed += 1
		print("  FAIL: %s" % test_name)
		if details:
			print("          %s" % details)
		_test_results.append({"name": test_name, "passed": false, "details": details})


func _assert_eq(actual: Variant, expected: Variant, test_name: String) -> void:
	var passed: bool = actual == expected
	var details: String = "" if passed else "Expected: %s, Got: %s" % [expected, actual]
	_assert(passed, test_name, details)


func _assert_not_null(value: Variant, test_name: String) -> void:
	_assert(value != null, test_name, "Value was null")


# =============================================================================
# TEST SUITES
# =============================================================================

func _test_esm_loader() -> void:
	# Test ESMDefs
	var defs_script: GDScript = load("res://src/core/esm/esm_defs.gd")
	_assert_not_null(defs_script, "ESMDefs script loads")

	# Test FourCC conversion - use static method
	var fourcc: int = ESMDefs.four_cc("TES3")
	_assert_eq(fourcc, 0x33534554, "FourCC conversion for TES3")  # "TES3" in little-endian

	# Test record type enum exists (access as static)
	_assert(ESMDefs.RecordType.REC_TES3 != 0, "RecordType enum has TES3")
	_assert(ESMDefs.RecordType.REC_CELL != 0, "RecordType enum has CELL")
	_assert(ESMDefs.RecordType.REC_NPC_ != 0, "RecordType enum has NPC_")


func _test_record_parsing() -> void:
	# Test that record classes can be instantiated
	var record_types: Array[String] = [
		"res://src/core/esm/records/esm_record.gd",
		"res://src/core/esm/records/static_record.gd",
		"res://src/core/esm/records/cell_record.gd",
		"res://src/core/esm/records/npc_record.gd",
		"res://src/core/esm/records/weapon_record.gd",
		"res://src/core/esm/records/book_record.gd",
		"res://src/core/esm/records/spell_record.gd",
		"res://src/core/esm/records/class_record.gd",
		"res://src/core/esm/records/race_record.gd",
	]

	for path: String in record_types:
		var script: GDScript = load(path)
		_assert_not_null(script, "Record script loads: %s" % path.get_file())

		if script:
			var instance: Variant = script.new()
			_assert_not_null(instance, "Record instantiates: %s" % path.get_file())


func _test_esm_manager() -> void:
	# Note: In headless mode, we can't easily test ESMManager because Godot
	# needs to rebuild its class cache first. Run in editor mode to verify.
	# For now, just verify the script file exists.
	_assert(FileAccess.file_exists("res://src/core/esm/esm_manager.gd"), "ESMManager script exists")

	# Test all record scripts can be found
	var record_scripts: Array[String] = [
		"res://src/core/esm/records/book_record.gd",
		"res://src/core/esm/records/spell_record.gd",
		"res://src/core/esm/records/enchantment_record.gd",
		"res://src/core/esm/records/potion_record.gd",
		"res://src/core/esm/records/ingredient_record.gd",
		"res://src/core/esm/records/clothing_record.gd",
		"res://src/core/esm/records/misc_record.gd",
		"res://src/core/esm/records/class_record.gd",
		"res://src/core/esm/records/faction_record.gd",
		"res://src/core/esm/records/race_record.gd",
		"res://src/core/esm/records/skill_record.gd",
		"res://src/core/esm/records/birthsign_record.gd",
		"res://src/core/esm/records/sound_record.gd",
		"res://src/core/esm/records/region_record.gd",
		"res://src/core/esm/records/body_part_record.gd",
		"res://src/core/esm/records/apparatus_record.gd",
		"res://src/core/esm/records/lockpick_record.gd",
		"res://src/core/esm/records/probe_record.gd",
		"res://src/core/esm/records/repair_record.gd",
		"res://src/core/esm/records/leveled_item_record.gd",
		"res://src/core/esm/records/leveled_creature_record.gd",
		"res://src/core/esm/records/magic_effect_record.gd",
		"res://src/core/esm/records/script_record.gd",
		"res://src/core/esm/records/land_texture_record.gd",
		"res://src/core/esm/records/dialogue_record.gd",
		"res://src/core/esm/records/dialogue_info_record.gd",
		"res://src/core/esm/records/land_record.gd",
		"res://src/core/esm/records/pathgrid_record.gd",
		"res://src/core/esm/records/sound_gen_record.gd",
		"res://src/core/esm/records/start_script_record.gd",
	]

	for path: String in record_scripts:
		_assert(FileAccess.file_exists(path), "Record script exists: %s" % path.get_file())


func _test_bsa_archive() -> void:
	# Test BSADefs
	var defs_script: GDScript = load("res://src/core/bsa/bsa_defs.gd")
	_assert_not_null(defs_script, "BSADefs script loads")

	if defs_script == null:
		return

	# Test BSA version detection (access via script constants)
	_assert_eq(defs_script.BSAVersion.UNCOMPRESSED, 0x100, "BSA version constant for Morrowind")
	_assert_eq(defs_script.BSAVersion.COMPRESSED, 0x00415342, "BSA version constant for Oblivion/Skyrim")

	# Test hash calculation (static method via script)
	var hash_result: Dictionary = defs_script.calculate_hash("meshes\\a\\active_bolt.nif")
	_assert(hash_result.has("low"), "Hash calculation returns low bits")
	_assert(hash_result.has("high"), "Hash calculation returns high bits")
	_assert(hash_result.has("combined"), "Hash calculation returns combined hash")

	# Test path normalization (static method via script)
	var normalized: String = defs_script.normalize_path("Meshes/A/Test.NIF")
	_assert_eq(normalized, "meshes\\a\\test.nif", "Path normalization (lowercase + backslash)")

	# Test BSAReader script loads
	var reader_script: GDScript = load("res://src/core/bsa/bsa_reader.gd")
	_assert_not_null(reader_script, "BSAReader script loads")

	if reader_script == null:
		return

	# Test BSAReader instantiation
	var reader: RefCounted = reader_script.new()
	_assert_not_null(reader, "BSAReader instantiates")
	_assert_eq(reader.is_open(), false, "BSAReader starts closed")
	_assert_eq(reader.get_file_count(), 0, "BSAReader starts with 0 files")

	# Test BSAManager script exists
	_assert(FileAccess.file_exists("res://src/core/bsa/bsa_manager.gd"), "BSAManager script exists")

	# Test with actual Morrowind.bsa if available
	var morrowind_bsa: String = _find_morrowind_bsa()
	if morrowind_bsa.is_empty():
		print("  SKIP: Morrowind.bsa not found - skipping integration tests")
	else:
		_test_bsa_integration(morrowind_bsa, reader_script, defs_script)


func _find_morrowind_bsa() -> String:
	# Check common locations for Morrowind.bsa
	var paths: Array[String] = [
		"C:/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
		"C:/Program Files/Steam/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
		"D:/Steam/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
		"D:/Games/Morrowind/Data Files/Morrowind.bsa",
	]

	# Also check project config
	var config_path: String = ProjectSettings.get_setting("morrowind/data_path", "")
	if config_path:
		paths.insert(0, config_path.path_join("Morrowind.bsa"))

	for path: String in paths:
		if FileAccess.file_exists(path):
			return path

	return ""


func _test_bsa_integration(bsa_path: String, reader_script: GDScript, defs_script: GDScript) -> void:
	print("  INFO: Testing with %s" % bsa_path)

	var reader: RefCounted = reader_script.new()
	var result: Error = reader.open(bsa_path)
	_assert_eq(result, OK, "BSAReader opens Morrowind.bsa")

	if result != OK:
		return

	_assert(reader.is_open(), "BSAReader reports as open")
	_assert(reader.get_file_count() > 0, "BSAReader found files in archive")

	var file_count: int = reader.get_file_count()
	print("  INFO: Found %d files in archive" % file_count)

	# Test file listing
	var file_list: Array = reader.get_file_list()
	_assert_eq(file_list.size(), file_count, "File list matches file count")

	# Test has_file for known Morrowind files
	_assert(reader.has_file("meshes\\m\\probe_journeyman_01.nif"), "Archive contains known mesh file")
	_assert(reader.has_file("textures\\menu_thin_border_bottom.dds"), "Archive contains known texture file")

	# Print first 5 files to see actual paths
	var sample_files: Array = reader.get_file_list().slice(0, 5)
	print("  INFO: First 5 files in archive:")
	for f in sample_files:
		print("    - %s" % f.name)

	# Test with an actual file from the textures folder
	var tex_files: Array = reader.find_files("textures\\*.dds")
	if tex_files.size() > 0:
		_assert(reader.has_file(tex_files[0].name), "Archive contains texture from find_files")

	# Test case-insensitive lookup
	_assert(reader.has_file("MESHES\\M\\PROBE_JOURNEYMAN_01.NIF"), "Case-insensitive file lookup works")

	# Test get_file_entry
	var entry: RefCounted = reader.get_file_entry("meshes\\m\\probe_journeyman_01.nif")
	_assert_not_null(entry, "get_file_entry returns entry for known file")
	if entry:
		_assert(entry.size > 0, "File entry has non-zero size")
		print("  INFO: probe_journeyman_01.nif size = %d bytes" % entry.size)

	# Test file extraction
	var data: PackedByteArray = reader.extract_file("meshes\\m\\probe_journeyman_01.nif")
	_assert(data.size() > 0, "File extraction returns data")
	if data.size() > 0 and entry:
		_assert_eq(data.size(), entry.size, "Extracted data size matches entry size")

		# Check NIF magic bytes ("NetImmerse File Format" or "Gamebryo File Format")
		if data.size() >= 20:
			var header: String = data.slice(0, 20).get_string_from_ascii()
			var is_nif: bool = header.begins_with("NetImmerse") or header.begins_with("Gamebryo")
			_assert(is_nif, "Extracted NIF file has valid header")
			print("  INFO: NIF header = %s" % header.substr(0, 20))

	# Test find_files
	var nif_files: Array = reader.find_files("meshes\\m\\*.nif")
	_assert(nif_files.size() > 0, "find_files returns results for meshes\\m\\*.nif")
	print("  INFO: Found %d NIF files in meshes\\m\\" % nif_files.size())

	# Test get_stats
	var stats: Dictionary = reader.get_stats()
	_assert(stats.has("file_count"), "Stats has file_count")
	_assert(stats.has("total_size"), "Stats has total_size")
	_assert(stats.has("extensions"), "Stats has extensions")
	print("  INFO: Total archive size = %.2f MB" % (stats.get("total_size", 0) / 1024.0 / 1024.0))

	# Print extension breakdown
	if stats.has("extensions"):
		print("  INFO: Extension breakdown:")
		var exts: Dictionary = stats["extensions"]
		for ext: String in exts:
			var ext_data: Dictionary = exts[ext]
			print("    .%s: %d files (%.2f MB)" % [ext, ext_data["count"], ext_data["size"] / 1024.0 / 1024.0])


func _test_nif_model() -> void:
	# Test NIFDefs
	var defs_script: GDScript = load("res://src/core/nif/nif_defs.gd")
	_assert_not_null(defs_script, "NIFDefs script loads")

	if defs_script == null:
		return

	# Test NIF version constants
	_assert_eq(defs_script.VER_MW, 0x04000002, "NIF version constant for Morrowind")

	# Test version parsing
	var version_str: String = defs_script.version_to_string(0x04000002)
	_assert_eq(version_str, "4.0.0.2", "Version int to string conversion")

	# Test Morrowind version check
	_assert(defs_script.is_morrowind_version(0x04000002), "is_morrowind_version returns true for MW")
	_assert(not defs_script.is_morrowind_version(0x14000005), "is_morrowind_version returns false for OB")

	# Test NIFReader script loads
	var reader_script: GDScript = load("res://src/core/nif/nif_reader.gd")
	_assert_not_null(reader_script, "NIFReader script loads")

	# Test NIFConverter script loads
	var converter_script: GDScript = load("res://src/core/nif/nif_converter.gd")
	_assert_not_null(converter_script, "NIFConverter script loads")

	if reader_script == null:
		return

	# Test NIFReader instantiation
	var reader: RefCounted = reader_script.new()
	_assert_not_null(reader, "NIFReader instantiates")

	# Test with actual NIF from BSA if available
	var morrowind_bsa: String = _find_morrowind_bsa()
	if morrowind_bsa.is_empty():
		print("  SKIP: Morrowind.bsa not found - skipping NIF integration tests")
	else:
		_test_nif_integration(morrowind_bsa, reader_script, converter_script, defs_script)


func _test_nif_integration(bsa_path: String, reader_script: GDScript, converter_script: GDScript, defs_script: GDScript) -> void:
	print("  INFO: Testing NIF parsing with BSA: %s" % bsa_path)

	# First, extract a NIF from BSA
	var bsa_reader_script: GDScript = load("res://src/core/bsa/bsa_reader.gd")
	var bsa: RefCounted = bsa_reader_script.new()
	var bsa_result: Error = bsa.open(bsa_path)
	if bsa_result != OK:
		print("  SKIP: Failed to open BSA for NIF extraction")
		return

	# Extract a simple mesh (probe is a good simple test case)
	var nif_data: PackedByteArray = bsa.extract_file("meshes\\m\\probe_journeyman_01.nif")
	_assert(nif_data.size() > 0, "NIF file extracted from BSA")

	if nif_data.is_empty():
		return

	print("  INFO: Extracted NIF size = %d bytes" % nif_data.size())

	# Test NIFReader parsing
	var reader: RefCounted = reader_script.new()
	reader.debug_mode = true  # Enable debug output
	var result: Error = reader.load_buffer(nif_data)
	_assert_eq(result, OK, "NIFReader parses NIF buffer")

	if result != OK:
		return

	# Check version
	var version: int = reader.get_version()
	_assert_eq(version, defs_script.VER_MW, "NIF version is Morrowind (4.0.0.2)")
	print("  INFO: NIF version = %s" % reader.get_version_string())

	# Check records
	var num_records: int = reader.get_num_records()
	_assert(num_records > 0, "NIF has records")
	print("  INFO: NIF has %d records" % num_records)

	# Check roots
	var roots: Array = reader.get_roots()
	_assert(roots.size() > 0, "NIF has root nodes")
	print("  INFO: NIF has %d root nodes" % roots.size())

	# Test converter
	var converter: RefCounted = converter_script.new()
	var info: Dictionary = converter.get_mesh_info()

	# Load buffer for converter
	var conv_result: Error = converter._reader.load_buffer(nif_data) if converter._reader else ERR_UNCONFIGURED
	# Actually, converter needs buffer first
	converter._reader = reader_script.new()
	converter._reader.load_buffer(nif_data)

	info = converter.get_mesh_info()
	_assert(info.has("version"), "Mesh info has version")
	_assert(info.has("num_records"), "Mesh info has num_records")
	_assert(info.has("meshes"), "Mesh info has meshes count")

	print("  INFO: Mesh info:")
	print("    Version: %s" % info.get("version", "unknown"))
	print("    Records: %d" % info.get("num_records", 0))
	print("    Nodes: %d" % info.get("nodes", 0))
	print("    Meshes: %d" % info.get("meshes", 0))
	print("    Vertices: %d" % info.get("total_vertices", 0))
	print("    Triangles: %d" % info.get("total_triangles", 0))

	var textures: Array = info.get("textures", [])
	if textures.size() > 0:
		print("    Textures: %d" % textures.size())
		for tex in textures.slice(0, 3):
			print("      - %s" % tex)

	# Test conversion to Godot scene
	var scene: Node3D = converter.convert_buffer(nif_data)
	_assert_not_null(scene, "NIFConverter creates Node3D from NIF")

	if scene:
		print("  INFO: Created scene with %d children" % scene.get_child_count())

		# Check for mesh instances
		var mesh_count := _count_mesh_instances(scene)

		_assert(mesh_count > 0, "Scene contains MeshInstance3D nodes")
		print("  INFO: Scene has %d MeshInstance3D nodes" % mesh_count)

		# Clean up
		scene.queue_free()


func _count_mesh_instances(node: Node) -> int:
	var count := 0
	if node is MeshInstance3D:
		count += 1
	for child in node.get_children():
		count += _count_mesh_instances(child)
	return count


func _print_summary() -> void:
	print("=" .repeat(60))
	print("TEST SUMMARY")
	print("=" .repeat(60))
	print("")
	print("  Total:  %d" % (_tests_passed + _tests_failed))
	print("  Passed: %d" % _tests_passed)
	print("  Failed: %d" % _tests_failed)
	print("")

	if _tests_failed > 0:
		print("FAILED TESTS:")
		for result: Dictionary in _test_results:
			if not result.get("passed", false):
				print("  - %s" % result.get("name", "unknown"))
				if result.has("details") and result.get("details", ""):
					print("    %s" % result.details)
		print("")

	if _tests_failed == 0:
		print("ALL TESTS PASSED!")
	else:
		print("SOME TESTS FAILED")
	print("")
