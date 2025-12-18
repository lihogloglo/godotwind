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
	_run_test_suite("NIF Collision Tests", _test_nif_collision)
	_run_test_suite("NIF Particle Tests", _test_nif_particles)

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
		_test_skinned_nif(morrowind_bsa)


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


func _test_skinned_nif(bsa_path: String) -> void:
	# Test skinned NIF loading with skeleton builder
	var bsa_reader_script: GDScript = load("res://src/core/bsa/bsa_reader.gd")
	var nif_reader_script: GDScript = load("res://src/core/nif/nif_reader.gd")
	var nif_defs_script: GDScript = load("res://src/core/nif/nif_defs.gd")
	var skeleton_builder_script: GDScript = load("res://src/core/nif/nif_skeleton_builder.gd")

	_assert_not_null(skeleton_builder_script, "NIFSkeletonBuilder script loads")
	if skeleton_builder_script == null:
		return

	var bsa: RefCounted = bsa_reader_script.new()
	if bsa.open(bsa_path) != OK:
		print("  SKIP: Failed to open BSA for skinned NIF test")
		return

	# Try to find a skinned model - character heads have skinning
	var skinned_models: Array[String] = [
		"meshes\\b\\b_n_dark elf_m_head_01.nif",
		"meshes\\b\\b_n_breton_m_head_01.nif",
		"meshes\\b\\b_n_nord_m_head_01.nif",
	]

	var nif_data: PackedByteArray
	var model_path: String = ""
	for path in skinned_models:
		if bsa.has_file(path):
			nif_data = bsa.extract_file(path)
			if not nif_data.is_empty():
				model_path = path
				break

	if nif_data.is_empty():
		print("  SKIP: No skinned NIF models found in BSA")
		return

	print("  INFO: Testing skinned model: %s" % model_path)

	# Parse NIF
	var reader: RefCounted = nif_reader_script.new()
	var result: Error = reader.load_buffer(nif_data)
	_assert_eq(result, OK, "Skinned NIF parses successfully")
	if result != OK:
		return

	# Find skin instance - check by record_type string
	var skin_instance = null
	for record in reader.records:
		if record.record_type == "NiSkinInstance":
			skin_instance = record
			break

	_assert_not_null(skin_instance, "Skinned NIF has NiSkinInstance")
	if skin_instance == null:
		return

	print("  INFO: Found NiSkinInstance with %d bones" % skin_instance.bone_indices.size())

	# Test skeleton builder
	var builder: RefCounted = skeleton_builder_script.new()
	builder.init(reader)

	var skeleton: Skeleton3D = builder.build_skeleton(skin_instance)
	_assert_not_null(skeleton, "SkeletonBuilder creates Skeleton3D")
	if skeleton == null:
		return

	var bone_count: int = skeleton.get_bone_count()
	_assert(bone_count > 0, "Skeleton has bones")
	_assert_eq(bone_count, skin_instance.bone_indices.size(), "Skeleton bone count matches NiSkinInstance")

	print("  INFO: Created Skeleton3D with %d bones" % bone_count)

	# Print first few bones
	for i in range(mini(bone_count, 5)):
		var bone_name: String = skeleton.get_bone_name(i)
		var parent_idx: int = skeleton.get_bone_parent(i)
		var parent_name: String = skeleton.get_bone_name(parent_idx) if parent_idx >= 0 else "(root)"
		print("    Bone %d: %s -> %s" % [i, bone_name, parent_name])

	if bone_count > 5:
		print("    ... and %d more bones" % (bone_count - 5))

	# Cleanup
	skeleton.free()
	bsa.close()


func _test_nif_collision() -> void:
	# Test NIFCollisionBuilder
	var collision_builder_script: GDScript = load("res://src/core/nif/nif_collision_builder.gd")
	_assert_not_null(collision_builder_script, "NIFCollisionBuilder script loads")

	if collision_builder_script == null:
		return

	# Test NIFDefs bounding volume constants and classes
	var defs_script: GDScript = load("res://src/core/nif/nif_defs.gd")
	_assert_eq(defs_script.BV_SPHERE, 0, "BV_SPHERE constant = 0")
	_assert_eq(defs_script.BV_BOX, 1, "BV_BOX constant = 1")
	_assert_eq(defs_script.BV_CAPSULE, 2, "BV_CAPSULE constant = 2")

	# Test collision flags
	_assert_eq(defs_script.FLAG_MESH_COLLISION, 0x0002, "FLAG_MESH_COLLISION = 0x0002")
	_assert_eq(defs_script.FLAG_BBOX_COLLISION, 0x0004, "FLAG_BBOX_COLLISION = 0x0004")

	# Test BoundingVolume class instantiation
	var bv = defs_script.BoundingVolume.new()
	_assert_not_null(bv, "BoundingVolume class instantiates")
	_assert_eq(bv.type, defs_script.BV_BASE, "BoundingVolume default type is BASE")

	# Test BoundingSphere instantiation
	var sphere = defs_script.BoundingSphere.new()
	_assert_not_null(sphere, "BoundingSphere class instantiates")
	_assert_eq(sphere.radius, 0.0, "BoundingSphere default radius is 0")

	# Test BoundingBox instantiation
	var box = defs_script.BoundingBox.new()
	_assert_not_null(box, "BoundingBox class instantiates")
	_assert_eq(box.extents, Vector3.ONE, "BoundingBox default extents")

	# Test BoundingCapsule instantiation
	var capsule = defs_script.BoundingCapsule.new()
	_assert_not_null(capsule, "BoundingCapsule class instantiates")
	_assert_eq(capsule.radius, 0.0, "BoundingCapsule default radius is 0")

	# Test with actual BSA if available
	var morrowind_bsa: String = _find_morrowind_bsa()
	if morrowind_bsa.is_empty():
		print("  SKIP: Morrowind.bsa not found - skipping collision integration tests")
	else:
		_test_collision_integration(morrowind_bsa)


func _test_collision_integration(bsa_path: String) -> void:
	print("  INFO: Testing NIF collision with BSA: %s" % bsa_path)

	var bsa_reader_script: GDScript = load("res://src/core/bsa/bsa_reader.gd")
	var nif_reader_script: GDScript = load("res://src/core/nif/nif_reader.gd")
	var nif_converter_script: GDScript = load("res://src/core/nif/nif_converter.gd")
	var collision_builder_script: GDScript = load("res://src/core/nif/nif_collision_builder.gd")

	var bsa: RefCounted = bsa_reader_script.new()
	if bsa.open(bsa_path) != OK:
		print("  SKIP: Failed to open BSA for collision test")
		return

	# Create instance to access enum values
	var builder_instance: RefCounted = collision_builder_script.new()

	# Test CollisionMode enum exists (access via instance)
	_assert(builder_instance.CollisionMode.TRIMESH == 0, "CollisionMode.TRIMESH = 0")
	_assert(builder_instance.CollisionMode.CONVEX == 1, "CollisionMode.CONVEX = 1")
	_assert(builder_instance.CollisionMode.AUTO_PRIMITIVE == 2, "CollisionMode.AUTO_PRIMITIVE = 2")

	# Test get_recommended_mode static function
	var arch_mode: int = collision_builder_script.get_recommended_mode("meshes\\x\\test.nif")
	_assert_eq(arch_mode, builder_instance.CollisionMode.TRIMESH, "Architecture uses TRIMESH")

	var item_mode: int = collision_builder_script.get_recommended_mode("meshes\\m\\test.nif")
	_assert_eq(item_mode, builder_instance.CollisionMode.AUTO_PRIMITIVE, "Items use AUTO_PRIMITIVE")

	# Test with various NIF types to demonstrate collision modes
	var test_models: Array[Dictionary] = [
		{"path": "meshes\\m\\misc_potion_bargain_01.nif", "type": "potion", "expected_mode": "auto_primitive"},
		{"path": "meshes\\m\\misc_dwrv_coin00.nif", "type": "coin", "expected_mode": "auto_primitive"},
		{"path": "meshes\\x\\ex_hlaalu_b_01.nif", "type": "architecture", "expected_mode": "trimesh"},
		{"path": "meshes\\f\\furn_de_p_table_01.nif", "type": "furniture", "expected_mode": "convex"},
	]

	for test_model in test_models:
		var path: String = test_model["path"]
		if not bsa.has_file(path):
			print("  SKIP: %s not found in BSA" % path)
			continue

		var nif_data: PackedByteArray = bsa.extract_file(path)
		if nif_data.is_empty():
			print("  SKIP: Failed to extract %s" % path)
			continue

		print("  INFO: Testing %s (%s)" % [path.get_file(), test_model["type"]])

		# Test collision builder with different modes
		var reader: RefCounted = nif_reader_script.new()
		var result: Error = reader.load_buffer(nif_data)
		if result != OK:
			print("  SKIP: Failed to parse %s" % path)
			continue

		# Test with AUTO_PRIMITIVE mode
		var builder: RefCounted = collision_builder_script.new()
		builder.init(reader)
		builder.collision_mode = builder_instance.CollisionMode.AUTO_PRIMITIVE
		builder.debug_mode = true

		var collision_result = builder.build_collision()
		_assert_not_null(collision_result, "Collision builder returns result for %s" % path.get_file())

		if collision_result:
			print("    has_collision: %s" % collision_result.has_collision)
			print("    detected_shapes: %s" % ", ".join(collision_result.detected_shapes))
			print("    collision_shapes: %d" % collision_result.collision_shapes.size())

			# Report shape types created
			for shape_data in collision_result.collision_shapes:
				var shape = shape_data.get("shape")
				_assert(shape is Shape3D, "Collision shape is Shape3D type")
				var shape_type: String = shape_data.get("type", "unknown")
				print("      Shape: %s" % shape_type)

				# Verify primitive shapes are actual primitives
				if shape_type == "sphere":
					_assert(shape is SphereShape3D, "Sphere shape is SphereShape3D")
				elif shape_type == "cylinder":
					_assert(shape is CylinderShape3D, "Cylinder shape is CylinderShape3D")
				elif shape_type == "box":
					_assert(shape is BoxShape3D, "Box shape is BoxShape3D")
				elif shape_type == "capsule":
					_assert(shape is CapsuleShape3D, "Capsule shape is CapsuleShape3D")
				elif shape_type == "convex":
					_assert(shape is ConvexPolygonShape3D, "Convex shape is ConvexPolygonShape3D")
				elif shape_type == "trimesh":
					_assert(shape is ConcavePolygonShape3D, "Trimesh shape is ConcavePolygonShape3D")

		# Test converter with auto collision mode
		var converter: RefCounted = nif_converter_script.new()
		converter.auto_collision_mode = true
		converter._source_path = path
		converter._reader = nif_reader_script.new()
		converter._reader.load_buffer(nif_data)

		var collision_info: Dictionary = converter.get_collision_info()
		_assert(collision_info.has("collision_mode"), "Collision info has collision_mode key")
		_assert(collision_info.has("detected_shapes"), "Collision info has detected_shapes key")
		_assert(collision_info.has("shape_types"), "Collision info has shape_types key")

		print("    get_collision_info() returned:")
		print("      collision_mode: %s" % collision_info.get("collision_mode", "unknown"))
		print("      detected_shapes: " + str(collision_info.get("detected_shapes", [])))
		print("      shape_types: " + str(collision_info.get("shape_types", [])))

		# Verify auto mode selected correctly
		var expected_mode: String = test_model.get("expected_mode", "auto_primitive")
		_assert_eq(collision_info.get("collision_mode", ""), expected_mode,
			"Auto mode for %s is %s" % [test_model["type"], expected_mode])

		# Test full conversion with collision
		converter.load_collision = true
		converter.debug_collision = true
		var scene: Node3D = converter.convert_buffer(nif_data, path)

		if scene:
			var static_body: StaticBody3D = _find_static_body(scene)
			if collision_info.get("has_collision", false):
				_assert_not_null(static_body, "Scene has StaticBody3D for %s" % path.get_file())
				if static_body:
					var shape_count: int = 0
					for child in static_body.get_children():
						if child is CollisionShape3D:
							shape_count += 1
					print("    StaticBody3D has %d CollisionShape3D children" % shape_count)
			scene.queue_free()


func _find_static_body(node: Node) -> StaticBody3D:
	if node is StaticBody3D:
		return node as StaticBody3D
	for child in node.get_children():
		var result: StaticBody3D = _find_static_body(child)
		if result:
			return result
	return null


func _test_nif_particles() -> void:
	# Test NIF particle system support
	var defs_script: GDScript = load("res://src/core/nif/nif_defs.gd")
	_assert_not_null(defs_script, "NIFDefs script loads")

	if defs_script == null:
		return

	# Test particle-related class instantiation
	var particles := defs_script.NiParticles.new()
	_assert_not_null(particles, "NiParticles class instantiates")

	var particles_data := defs_script.NiParticlesData.new()
	_assert_not_null(particles_data, "NiParticlesData class instantiates")

	var controller := defs_script.NiParticleSystemController.new()
	_assert_not_null(controller, "NiParticleSystemController class instantiates")
	_assert_eq(controller.lifetime, 0.0, "Controller default lifetime is 0")
	_assert_eq(controller.birth_rate, 0.0, "Controller default birth_rate is 0")

	var gravity := defs_script.NiGravity.new()
	_assert_not_null(gravity, "NiGravity class instantiates")
	_assert_eq(gravity.direction, Vector3.DOWN, "Gravity default direction is DOWN")

	var grow_fade := defs_script.NiParticleGrowFade.new()
	_assert_not_null(grow_fade, "NiParticleGrowFade class instantiates")
	_assert_eq(grow_fade.grow_time, 0.0, "GrowFade default grow_time is 0")
	_assert_eq(grow_fade.fade_time, 0.0, "GrowFade default fade_time is 0")

	var color_mod := defs_script.NiParticleColorModifier.new()
	_assert_not_null(color_mod, "NiParticleColorModifier class instantiates")
	_assert_eq(color_mod.color_data_index, -1, "ColorModifier default index is -1")

	var rotation := defs_script.NiParticleRotation.new()
	_assert_not_null(rotation, "NiParticleRotation class instantiates")
	_assert_eq(rotation.random_initial_axis, false, "Rotation default random_axis is false")
	_assert_eq(rotation.rotation_speed, 0.0, "Rotation default speed is 0")

	var planar_col := defs_script.NiPlanarCollider.new()
	_assert_not_null(planar_col, "NiPlanarCollider class instantiates")
	_assert_eq(planar_col.plane_normal, Vector3.UP, "PlanarCollider default normal is UP")

	var spherical_col := defs_script.NiSphericalCollider.new()
	_assert_not_null(spherical_col, "NiSphericalCollider class instantiates")
	_assert_eq(spherical_col.radius, 0.0, "SphericalCollider default radius is 0")

	var bomb := defs_script.NiParticleBomb.new()
	_assert_not_null(bomb, "NiParticleBomb class instantiates")
	_assert_eq(bomb.decay_type, 0, "ParticleBomb default decay_type is 0")
	_assert_eq(bomb.symmetry_type, 0, "ParticleBomb default symmetry_type is 0")

	var screen_lod := defs_script.NiScreenLODData.new()
	_assert_not_null(screen_lod, "NiScreenLODData class instantiates")
	_assert_eq(screen_lod.bound_radius, 0.0, "ScreenLODData default bound_radius is 0")

	# Test NiColorData for particle color gradients
	var color_data := defs_script.NiColorData.new()
	_assert_not_null(color_data, "NiColorData class instantiates")
	_assert_eq(color_data.keys.size(), 0, "ColorData starts with no keys")

	# Test with actual BSA if available
	var morrowind_bsa: String = _find_morrowind_bsa()
	if morrowind_bsa.is_empty():
		print("  SKIP: Morrowind.bsa not found - skipping particle integration tests")
	else:
		_test_particle_integration(morrowind_bsa)


func _test_particle_integration(bsa_path: String) -> void:
	print("  INFO: Testing NIF particle system with BSA: %s" % bsa_path)

	var bsa_reader_script: GDScript = load("res://src/core/bsa/bsa_reader.gd")
	var nif_reader_script: GDScript = load("res://src/core/nif/nif_reader.gd")
	var nif_converter_script: GDScript = load("res://src/core/nif/nif_converter.gd")
	var defs_script: GDScript = load("res://src/core/nif/nif_defs.gd")

	var bsa: RefCounted = bsa_reader_script.new()
	if bsa.open(bsa_path) != OK:
		print("  SKIP: Failed to open BSA for particle test")
		return

	# Look for particle effect NIFs - common naming patterns in Morrowind
	var particle_models: Array[String] = [
		"meshes\\vfx\\vfx_ashstorm.nif",
		"meshes\\vfx\\vfx_blightstorm.nif",
		"meshes\\e\\vfx_firesmall01.nif",
		"meshes\\e\\vfx_firebig01.nif",
		"meshes\\e\\vfx_lightning01.nif",
		"meshes\\vfx\\vfx_ghost.nif",
		"meshes\\e\\vfx_mark.nif",
		"meshes\\e\\vfx_recall.nif",
	]

	var nif_data: PackedByteArray
	var model_path: String = ""
	for path in particle_models:
		if bsa.has_file(path):
			nif_data = bsa.extract_file(path)
			if not nif_data.is_empty():
				model_path = path
				break

	if nif_data.is_empty():
		# Try to find any file with "vfx" in the path
		var vfx_files: Array = bsa.find_files("meshes\\*vfx*.nif")
		if vfx_files.size() > 0:
			model_path = vfx_files[0].name
			nif_data = bsa.extract_file(model_path)

	if nif_data.is_empty():
		print("  SKIP: No particle effect NIFs found in BSA")
		return

	print("  INFO: Testing particle model: %s" % model_path)

	# Parse NIF
	var reader: RefCounted = nif_reader_script.new()
	var result: Error = reader.load_buffer(nif_data)
	_assert_eq(result, OK, "Particle NIF parses successfully")
	if result != OK:
		return

	# Look for particle-related records
	var has_particles := false
	var has_controller := false
	var has_gravity := false
	var has_grow_fade := false
	var has_color_mod := false
	var has_rotation := false
	var has_bomb := false

	for record in reader.records:
		match record.record_type:
			"NiParticles", "NiAutoNormalParticles", "NiRotatingParticles":
				has_particles = true
			"NiParticleSystemController":
				has_controller = true
			"NiGravity":
				has_gravity = true
			"NiParticleGrowFade":
				has_grow_fade = true
			"NiParticleColorModifier":
				has_color_mod = true
			"NiParticleRotation":
				has_rotation = true
			"NiParticleBomb":
				has_bomb = true

	print("  INFO: Particle records found:")
	print("    NiParticles: %s" % has_particles)
	print("    NiParticleSystemController: %s" % has_controller)
	print("    NiGravity: %s" % has_gravity)
	print("    NiParticleGrowFade: %s" % has_grow_fade)
	print("    NiParticleColorModifier: %s" % has_color_mod)
	print("    NiParticleRotation: %s" % has_rotation)
	print("    NiParticleBomb: %s" % has_bomb)

	_assert(has_particles or has_controller, "Particle NIF has particle records")

	# Test conversion to Godot scene
	var converter: RefCounted = nif_converter_script.new()
	var scene: Node3D = converter.convert_buffer(nif_data, model_path)
	_assert_not_null(scene, "NIFConverter creates Node3D from particle NIF")

	if scene:
		print("  INFO: Created scene with %d children" % scene.get_child_count())

		# Check for GPUParticles3D instances
		var particle_count := _count_particles(scene)
		if has_particles:
			_assert(particle_count > 0, "Scene contains GPUParticles3D nodes")
		print("  INFO: Scene has %d GPUParticles3D nodes" % particle_count)

		# Check particle properties if we have particles
		if particle_count > 0:
			var particles_node: GPUParticles3D = _find_particles(scene)
			if particles_node:
				_assert_not_null(particles_node.process_material, "Particles have process material")
				print("    Lifetime: %.2f" % particles_node.lifetime)
				print("    Amount: %d" % particles_node.amount)

				var mat: ParticleProcessMaterial = particles_node.process_material as ParticleProcessMaterial
				if mat:
					print("    Has color_ramp: %s" % (mat.color_ramp != null))
					print("    Has scale_curve: %s" % (mat.scale_curve != null))
					print("    Angular velocity: %.2f - %.2f" % [mat.angular_velocity_min, mat.angular_velocity_max])
					print("    Gravity: %s" % mat.gravity)

		# Clean up
		scene.queue_free()


func _count_particles(node: Node) -> int:
	var count := 0
	if node is GPUParticles3D:
		count += 1
	for child in node.get_children():
		count += _count_particles(child)
	return count


func _find_particles(node: Node) -> GPUParticles3D:
	if node is GPUParticles3D:
		return node as GPUParticles3D
	for child in node.get_children():
		var result: GPUParticles3D = _find_particles(child)
		if result:
			return result
	return null


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
