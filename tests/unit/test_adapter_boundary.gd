extends GdUnitTestSuite

const MorrowindImpostorCandidatesScript := preload("res://src/core/world/morrowind/morrowind_impostor_candidates.gd")
const MorrowindTerrainManagerScript := preload("res://src/core/world/morrowind/morrowind_terrain_manager.gd")
const MorrowindWorldSourceScript := preload("res://src/core/world/morrowind/morrowind_world_source.gd")

const FORBIDDEN_TERMS: PackedStringArray = [
	"ESMManager",
	"BSAManager",
	"NIFConverter",
	"CellRecord",
	"CellReference",
	"LandRecord",
	"RegionRecord",
	"NPCRecord",
	"CreatureRecord",
	"LeveledCreatureRecord",
	"LandTextureRecord",
	"Morrowind",
	"MW_",
	"get_legacy",
	"legacy_",
	".esm",
	".esp",
	".bsa",
	".nif",
	"ESM",
	"ESP",
	"BSA",
	"NIF",
	"LAND",
	"LTEX",
	"OpenMW",
	"Vvardenfell",
	"Bip01",
	"INFO",
	"QSTN",
	"QSTF",
	"QSTR",
	"SCVR",
	"RefId",
	"disposition",
]

const BASELINE_FORBIDDEN_COUNTS: Dictionary = {
	"src/core/animation/animation_blend_mask.gd": 6,
	"src/core/animation/animation_manager.gd": 1,
	"src/core/animation/character_factory_v2.gd": 49,
	"src/core/animation/humanoid_animation_system.gd": 1,
	"src/core/animation/morrowind_character_system.gd": 1,
	"src/core/animation/pelvis_offset_modifier.gd": 1,
	"src/core/animation/skeleton_utils.gd": 58,
	"src/core/animation/text_key_handler.gd": 2,
	"src/core/character/character_types.gd": 2,
	"src/core/character/mesh_extractor.gd": 52,
	"src/core/console/console.gd": 3,
	"src/core/console/object_picker.gd": 2,
	"src/core/deformation/terrain_deformation_texture_config.gd": 2,
	"src/core/diagnostics/pipeline_compile_monitor.gd": 5,
	"src/core/dialogue/dialogue_context.gd": 2,
	"src/core/dialogue/dialogue_provider.gd": 10,
	"src/core/logging/logger.gd": 5,
	"src/core/modding/mod_registry.gd": 10,
	"src/core/native_bridge.gd": 0,
	"src/core/settings_manager.gd": 22,
	"src/core/shaders/effects/cloud_shadow_effect.gd": 4,
	"src/core/shaders/effects/color_grading_effect.gd": 1,
	"src/core/shaders/effects/godrays_effect.gd": 6,
	"src/core/shaders/effects/light_glow_effect.gd": 3,
	"src/core/shaders/effects/prewater_capture_effect.gd": 4,
	"src/core/shaders/effects/sky_transmittance_effect.gd": 1,
	"src/core/shaders/effects/underwater_compositor_effect.gd": 8,
	"src/core/shaders/effects/volumetric_fog_effect.gd": 7,
	"src/core/shaders/effects/waterline_compositor_effect.gd": 13,
	"src/core/shaders/effects/wet_compositor_effect.gd": 6,
	"src/core/texture/material_library.gd": 4,
	"src/core/texture/texture_loader.gd": 6,
	"src/core/ui/dialogue_panel.gd": 10,
	"src/core/ui/loading_screen.gd": 21,
	"src/core/water/ocean_fft_provider.gd": 6,
	"src/core/water/water_system.gd": 0,
	"src/core/water/rendering_context.gd": 4,
	"src/core/water/water_surface_state.gd": 1,
	"src/core/weather/weather_data.gd": 1,
	"src/core/weather/weather_manager.gd": 6,
	"src/core/world/cell_manager.gd": 25,
	"src/core/world/cell_payload.gd": 0,
	"src/core/world/cell_preloader.gd": 0,
	"src/core/world/cell_static_collision.gd": 0,
	"src/core/world/distant_light_manager.gd": 0,
	"src/core/world/door_portal.gd": 5,
	"src/core/world/door_utils.gd": 1,
	"src/core/world/impostor_candidates.gd": 0,
	"src/core/world/interior_pocket_manager.gd": 2,
	"src/core/world/model_loader.gd": 0,
	"src/core/world/native_streaming_manager.gd": 9,
	"src/core/world/object_paging.gd": 0,
	"src/core/world/object_pool.gd": 140,
	"src/core/world/reference_instantiator.gd": 10,
	"src/core/world/static_object_renderer.gd": 0,
	"src/core/world/terrain_manager.gd": 0,
	"src/core/world/world_cell_manifest.gd": 0,
	"src/core/world/world_object_record.gd": 0,
	"src/core/world/world_object_source.gd": 0,
}

const BASELINE_MORROWIND_PRELOAD_COUNTS: Dictionary = {
	"src/core/animation/character_factory_v2.gd": 2,
	"src/core/world/native_streaming_manager.gd": 0,
	"src/core/world/reference_instantiator.gd": 0,
}

const BASELINE_TEXT_FORBIDDEN_COUNTS: Dictionary = {
	"docs/ARCHITECTURE.md": 31,
	"docs/plans/fixing_hlod.md": 6,
	"docs/plans/flowing_rivers_architecture.md": 8,
	"docs/plans/groundcover.md": 44,
	"docs/plans/impostor_rebuild.md": 9,
	"docs/plans/lighting_roadmap.md": 1,
	"docs/plans/nif_collision_part2.md": 5,
	"docs/STATUS.md": 31,
	"project.godot": 4,
	"src/native/ESMCache.cs": 45,
	"src/native/ESMRecords.cs": 20,
	"src/native/NativeBinaryReader.cs": 5,
	"src/native/NativeBSAReader.cs": 30,
	"src/native/NativeESMLoader.cs": 96,
	"src/native/NativeESMReader.cs": 28,
	"src/native/NativeFactory.cs": 101,
	"src/native/NativeNIFConverter.cs": 51,
	"src/native/NativeNIFReader.cs": 104,
	"src/native/NativeMorrowindHydrologyAtlasBuilder.cs": 3,
	"src/native/NativeObjectPagingKernel.cs": 2,
	"src/native/TerrainGenerator.cs": 152,
	"src/core/shaders/compute/godrays.glsl": 1,
	"src/core/shaders/compute/light_glow.glsl": 1,
	"src/core/shaders/compute/volumetric_fog.glsl": 5,
	"src/core/sky/shaders/sky.gdshader": 1,
	"src/core/water/shaders/ocean_fft_common.gdshaderinc": 1,
	"src/core/world/terrain_horizon.gdshader": 2,
}

const BROAD_RATCHET_FALSE_POSITIVE_CORE_FILES: Dictionary = {
	"src/core/shaders/effects/surface_refraction_compositor_effect.gd": "RenderingDevice.UNIFORM_TYPE contains source-marker substrings",
	"src/core/shaders/effects/underwater_compositor_effect.gd": "RenderingDevice.UNIFORM_TYPE contains source-marker substrings",
	"src/core/shaders/effects/waterline_compositor_effect.gd": "RenderingDevice.UNIFORM_TYPE contains source-marker substrings",
	"src/core/water/surface_refraction_layer.gd": "legacy_exclusion is a renderer source-mode label",
	"src/core/water/water_interaction_sim.gd": "RenderingDevice.UNIFORM_TYPE contains source-marker substrings",
}

const BROAD_TEXT_RATCHET_EXCLUDED_FILES: Dictionary = {
	"docs/STATUS.md": "status docs intentionally inventory source-specific shipped/debt areas",
	"docs/plans/interior_exterior_transition_refactor_2026_05_30.md": "boundary plan intentionally discusses Morrowind-to-framework ownership",
	"src/core/water/shaders/ocean_boujie_experimental_common.gdshaderinc": "legacy shader variable names are compatibility math, not source ownership",
}

const SOURCE_BRIDGE_TERMS: PackedStringArray = [
	"get_source_cell",
	"get_source_exterior_cell",
	"get_source_base_record",
	"get_source_creature",
	"get_source_leveled_creature",
	"source_base_record",
]

const BASELINE_SOURCE_BRIDGE_COUNTS: Dictionary = {
	"src/core/world/cell_manager.gd": 0,
}

const SOURCE_BRIDGE_MARKERS: PackedStringArray = [
	"get_source_cell",
	"get_source_exterior_cell",
	"get_source_base_record",
	"get_source_creature",
	"get_source_leveled_creature",
	"source_base_record",
]

const BASELINE_SOURCE_BRIDGE_MARKER_COUNTS: Dictionary = {
	"src/core/world/cell_manager.gd": {
		"get_source_cell": 0,
		"get_source_exterior_cell": 0,
	},
}

const WORLD_BOUNDARY_MARKERS: PackedStringArray = [
	"get_source_cell",
	"get_source_exterior_cell",
	"CellRecord",
	"CellReference",
	"ESMManager",
	"BSAManager",
	"NIF",
	"BSA",
	"LAND",
	"LTEX",
	"mw_",
	"Morrowind",
]

const WORLD_BOUNDARY_MARKER_LEDGER: Dictionary = {
	"src/core/world/cell_manager.gd": {
		"CellRecord": 0,
		"CellReference": 0,
		"get_source_cell": 0,
		"get_source_exterior_cell": 0,
	},
	"src/core/world/impostor_candidates.gd": {
		"BSA": 0,
		"BSAManager": 0,
		"LAND": 0,
	},
	"src/core/world/interior_pocket_manager.gd": {
		"CellRecord": 0,
		"CellReference": 0,
		"ESMManager": 0,
	},
	"src/core/world/reference_instantiator.gd": {
		"CellReference": 0,
		"mw_": 0,
	},
	"src/core/world/static_object_renderer.gd": {
		"CellReference": 0,
	},
}


func test_generic_core_does_not_add_new_source_specific_leaks() -> void:
	var files: Array[String] = []
	_collect_gd_files("res://src/core", files)
	for path: String in files:
		var normalized := _normalize_path(path)
		if _is_adapter_or_importer_path(normalized):
			continue
		if BROAD_RATCHET_FALSE_POSITIVE_CORE_FILES.has(normalized):
			continue
		var code := _read_without_comments(path)
		var forbidden_count := _count_forbidden_terms(code)
		var allowed_count := int(BASELINE_FORBIDDEN_COUNTS.get(normalized, 0))
		assert_int(forbidden_count).override_failure_message(
			"%s added source-specific framework leaks; move the logic behind an adapter/provider" % normalized
		).is_less_equal(allowed_count)


func test_generic_core_source_bridge_debt_does_not_expand() -> void:
	var files: Array[String] = []
	_collect_gd_files("res://src/core", files)
	for path: String in files:
		var normalized := _normalize_path(path)
		if _is_adapter_or_importer_path(normalized):
			continue
		var code := _read_without_comments(path)
		var bridge_count := _count_terms(code, SOURCE_BRIDGE_TERMS)
		var allowed_count := int(BASELINE_SOURCE_BRIDGE_COUNTS.get(normalized, 0))
		assert_int(bridge_count).override_failure_message(
			"%s added source-parser bridge calls; put them behind the source adapter instead" % normalized
		).is_less_equal(allowed_count)


func test_generic_core_source_bridge_markers_match_debt_ledger() -> void:
	var files: Array[String] = []
	_collect_gd_files("res://src/core", files)
	for path: String in files:
		var normalized := _normalize_path(path)
		if _is_adapter_or_importer_path(normalized):
			continue
		var code := _read_without_comments(path)
		var marker_baseline: Dictionary = BASELINE_SOURCE_BRIDGE_MARKER_COUNTS.get(normalized, {})
		for marker: String in SOURCE_BRIDGE_MARKERS:
			var marker_count := _count_occurrences(code, marker)
			var allowed_count := int(marker_baseline.get(marker, 0))
			assert_int(marker_count).override_failure_message(
				"%s has %d '%s' bridge markers; allowed debt is %d. New source bridges belong in adapters/providers." % [normalized, marker_count, marker, allowed_count]
			).is_less_equal(allowed_count)


func test_generic_world_boundary_markers_match_exact_debt_ledger() -> void:
	var files: Array[String] = []
	_collect_gd_files("res://src/core/world", files)
	for path: String in files:
		var normalized := _normalize_path(path)
		if _is_adapter_or_importer_path(normalized):
			continue
		var code := _read_without_comments(path)
		var marker_baseline: Dictionary = WORLD_BOUNDARY_MARKER_LEDGER.get(normalized, {})
		for marker: String in WORLD_BOUNDARY_MARKERS:
			var marker_count := _count_occurrences(code, marker)
			var allowed_count := int(marker_baseline.get(marker, 0))
			assert_int(marker_count).override_failure_message(
				"%s has %d '%s' boundary markers; exact debt ledger allows %d. Move new source-specific logic to an adapter/provider, or lower this ledger after cleanup." % [normalized, marker_count, marker, allowed_count]
			).is_equal(allowed_count)


func test_generic_world_has_no_direct_source_adapter_resource_refs() -> void:
	var files: Array[String] = []
	_collect_gd_files("res://src/core/world", files)
	for path: String in files:
		var normalized := _normalize_path(path)
		if _is_adapter_or_importer_path(normalized):
			continue
		var code := _read_without_comments(path).replace("\\", "/")
		var ref_count := _count_source_adapter_resource_refs(code)
		assert_int(ref_count).override_failure_message(
			"%s directly references a source adapter/importer resource; inject the provider or move this code under the source adapter" % normalized
		).is_equal(0)


func test_reference_instantiator_uses_public_spawn_adapter_hooks() -> void:
	var code := _read_without_comments("res://src/core/world/reference_instantiator.gd")
	for private_hook_pattern: String in ["call(\"_source_", "has_method(\"_source_"]:
		assert_bool(private_hook_pattern in code).override_failure_message(
			"ReferenceInstantiator must call public WorldObjectSpawnAdapter hooks, not private Morrowind _source_* methods"
		).is_false()


func test_visual_proxy_hooks_use_world_object_record_identity() -> void:
	var instantiator_code := _read_without_comments("res://src/core/world/reference_instantiator.gd")
	var adapter_code := _read_without_comments("res://src/core/world/morrowind/morrowind_object_spawn_adapter.gd")
	for retired_hook: String in [
		"ensure_source_visual_proxy_for_ref",
		"apply_source_visual_proxy_runtime(",
		"make_source_visual_proxy_key(",
		"make_source_key(",
	]:
		assert_bool(retired_hook in instantiator_code or retired_hook in adapter_code).override_failure_message(
			"Visual proxy hooks must use WorldObjectRecord.source_key, not parser-ref source-key generation"
		).is_false()
	assert_bool("ensure_source_visual_proxy_for_record" in instantiator_code and "ensure_source_visual_proxy_for_record" in adapter_code).is_true()
	assert_bool("apply_source_visual_proxy_runtime_for_record" in instantiator_code and "apply_source_visual_proxy_runtime_for_record" in adapter_code).is_true()


func test_cell_manager_legacy_object_streamer_hooks_stay_deleted() -> void:
	var cell_manager_code := _read_without_comments("res://src/core/world/cell_manager.gd")
	for retired_hook: String in [
		"get_cell_references(",
		"instantiate_deferred_object(",
		"func _apply_transform(",
		"set_parser_cell_bridge(",
		"get_parser_cell_bridge(",
		"parser_cell_bridge",
	]:
		assert_bool(retired_hook in cell_manager_code).override_failure_message(
			"CellManager must not restore the retired per-object ObjectStreamer parser-cell API"
		).is_false()


func test_parser_cell_bridge_stays_deleted() -> void:
	var world_source_code := _read_without_comments("res://src/core/world/world_source.gd")
	var morrowind_world_source_code := _read_without_comments("res://src/core/world/morrowind/morrowind_world_source.gd")
	var cell_manager_code := _read_without_comments("res://src/core/world/cell_manager.gd")
	for retired_symbol: String in [
		"parser_cell_bridge",
		"ParserCellBridge",
		"get_parser_cell_bridge(",
		"set_parser_cell_bridge(",
		"get_interior_cell_record(",
		"get_exterior_cell_record(",
	]:
		assert_bool(
			retired_symbol in world_source_code \
				or retired_symbol in morrowind_world_source_code \
				or retired_symbol in cell_manager_code
		).override_failure_message(
			"Parser-cell bridge is retired; use WorldObjectSource manifests instead"
		).is_false()


func test_phase_a_worker_tail_uses_world_object_record_identity() -> void:
	var instantiator_code := _read_without_comments("res://src/core/world/reference_instantiator.gd")
	var cell_manager_code := _read_without_comments("res://src/core/world/cell_manager.gd")
	assert_bool("entry.world_object_record = _make_payload_record_from_ref" in cell_manager_code).override_failure_message(
		"Phase A worker dispatch must wrap source refs into adapter-owned WorldObjectRecord payloads before scheduling"
	).is_true()
	assert_bool("make_source_key(" in instantiator_code).override_failure_message(
		"Phase A worker tail must use WorldObjectRecord.source_key, not parser-ref key reconstruction"
	).is_false()


func test_source_light_actor_helpers_use_world_object_record_callbacks() -> void:
	var instantiator_code := _read_without_comments("res://src/core/world/reference_instantiator.gd")
	var adapter_code := _read_without_comments("res://src/core/world/morrowind/morrowind_object_spawn_adapter.gd")
	for retired_callback: String in [
		"instantiate_source_light(",
		"instantiate_source_actor(",
	]:
		assert_bool(retired_callback in instantiator_code or retired_callback in adapter_code).override_failure_message(
			"Light/actor source-helper callbacks must consume WorldObjectRecord identity, not parser refs"
		).is_false()
	assert_bool("instantiate_source_light_record" in instantiator_code and "instantiate_source_light_record" in adapter_code).is_true()
	assert_bool("instantiate_source_actor_record" in instantiator_code and "instantiate_source_actor_record" in adapter_code).is_true()


func test_impostor_catalog_scan_is_morrowind_owned() -> void:
	var candidates := MorrowindImpostorCandidatesScript.new()
	assert_bool(candidates is ImpostorCandidates).is_true()
	var source := MorrowindWorldSourceScript.new()
	assert_bool(source.get_impostor_candidates() is ImpostorCandidates).override_failure_message(
		"WorldSource must inject source-owned impostor policy into generic streaming"
	).is_true()

	var generic_code := _read_without_comments("res://src/core/world/impostor_candidates.gd")
	var morrowind_code := _read_without_comments("res://src/core/world/morrowind/morrowind_impostor_candidates.gd")
	assert_bool(ImpostorCandidates.new().should_have_impostor("meshes/x/ex_vivec_01.nif")).override_failure_message(
		"Generic ImpostorCandidates must not own source-specific model-name policy"
	).is_false()
	assert_bool(candidates.should_have_impostor("meshes/x/ex_vivec_01.nif")).override_failure_message(
		"Morrowind impostor policy must classify Morrowind landmark models"
	).is_true()
	assert_bool("BSAManager" in generic_code).override_failure_message(
		"Generic ImpostorCandidates must classify provided model paths, not scan Morrowind BSA archives"
	).is_false()
	assert_bool("BSAManager" in morrowind_code).override_failure_message(
		"Morrowind archive-backed impostor catalog scanning belongs in the Morrowind adapter"
	).is_true()


func test_land_terrain_generation_is_morrowind_owned() -> void:
	var terrain_manager := MorrowindTerrainManagerScript.new()
	assert_bool(terrain_manager is TerrainManager).override_failure_message(
		"Morrowind terrain manager should reuse generic region helpers without making LAND generation generic"
	).is_true()

	var generic_code := _read_without_comments("res://src/core/world/terrain_manager.gd")
	var morrowind_code := _read_without_comments("res://src/core/world/morrowind/morrowind_terrain_manager.gd")
	for marker: String in ["LandRecord", "ESMManager", "LAND", "LTEX", "Morrowind", "mw_"]:
		assert_bool(marker in generic_code).override_failure_message(
			"Generic TerrainManager must not own source parser/control-map markers"
		).is_false()
	assert_bool("func generate_control_map(land: LandRecord)" in morrowind_code).override_failure_message(
		"Morrowind LAND control-map generation belongs in the Morrowind adapter"
	).is_true()


func test_generic_core_does_not_add_new_morrowind_adapter_preloads() -> void:
	var files: Array[String] = []
	_collect_gd_files("res://src/core", files)
	for path: String in files:
		var normalized := _normalize_path(path)
		if _is_adapter_or_importer_path(normalized):
			continue
		var code := _read_without_comments(path).replace("\\", "/")
		var preload_count := 0
		if "/morrowind/" in code:
			preload_count = _count_morrowind_adapter_path_refs(code)
		var allowed_count := int(BASELINE_MORROWIND_PRELOAD_COUNTS.get(normalized, 0))
		assert_int(preload_count).override_failure_message(
			"%s added a generic-core resource reference to a Morrowind adapter; inject the provider instead" % normalized
		).is_less_equal(allowed_count)


func test_boundary_ratchet_covers_project_native_and_active_docs() -> void:
	var files: Array[String] = ["res://project.godot", "res://docs/ARCHITECTURE.md", "res://docs/STATUS.md"]
	_collect_files_with_extension("res://docs/plans", "md", files)
	_collect_files_with_extension("res://src/native", "cs", files)
	_collect_files_with_extension("res://src/core", "gdshader", files)
	_collect_files_with_extension("res://src/core", "gdshaderinc", files)
	_collect_files_with_extension("res://src/core", "glsl", files)
	_collect_files_with_extension("res://src/core", "glslinc", files)
	for path: String in files:
		var normalized := _normalize_path(path)
		if BROAD_TEXT_RATCHET_EXCLUDED_FILES.has(normalized):
			continue
		var code := _read_text(path)
		var forbidden_count := _count_forbidden_terms(code)
		var allowed_count := int(BASELINE_TEXT_FORBIDDEN_COUNTS.get(normalized, 0))
		assert_int(forbidden_count).override_failure_message(
			"%s added source-specific leakage outside GDScript core (%d > %d); move source logic to adapters/importers or lower the ratchet after cleanup" % [normalized, forbidden_count, allowed_count]
		).is_less_equal(allowed_count)


func _collect_gd_files(dir_path: String, out: Array[String]) -> void:
	_collect_files_with_extension(dir_path, "gd", out)


func _collect_files_with_extension(dir_path: String, extension: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry.is_empty():
			break
		if entry.begins_with("."):
			continue
		var child := dir_path.path_join(entry)
		if dir.current_is_dir():
			_collect_files_with_extension(child, extension, out)
		elif entry.ends_with("." + extension):
			out.append(child)
	dir.list_dir_end()


func _is_adapter_or_importer_path(path: String) -> bool:
	return path.begins_with("src/core/esm/") \
		or path.begins_with("src/core/bsa/") \
		or path.begins_with("src/core/nif/") \
		or "/morrowind/" in path


func _read_without_comments(path: String) -> String:
	var text := _read_text(path)
	var lines: PackedStringArray = PackedStringArray()
	for line: String in text.split("\n"):
		if line.strip_edges().begins_with("#"):
			continue
		lines.append(line)
	return "\n".join(lines)


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	assert_object(file).is_not_null()
	return file.get_as_text()


func _count_forbidden_terms(code: String) -> int:
	return _count_terms(code, FORBIDDEN_TERMS)


func _count_terms(code: String, terms: PackedStringArray) -> int:
	var total := 0
	for term: String in terms:
		total += _count_occurrences(code, term)
	return total


func _count_morrowind_adapter_path_refs(code: String) -> int:
	var total := 0
	var prefixes: PackedStringArray = [
		"preload(\"res://src/core/",
		"load(\"res://src/core/",
		"extends \"res://src/core/",
	]
	for prefix: String in prefixes:
		var search_from := 0
		while true:
			var idx := code.find(prefix, search_from)
			if idx < 0:
				break
			var end_idx := code.find("\"", idx + prefix.length())
			if end_idx < 0:
				break
			var reference_text := code.substr(idx, end_idx - idx)
			if "/morrowind/" in reference_text:
				total += 1
			search_from = end_idx + 1
	return total


func _count_source_adapter_resource_refs(code: String) -> int:
	var total := 0
	var prefixes: PackedStringArray = [
		"preload(\"res://src/core/",
		"load(\"res://src/core/",
		"extends \"res://src/core/",
	]
	for prefix: String in prefixes:
		var search_from := 0
		while true:
			var idx := code.find(prefix, search_from)
			if idx < 0:
				break
			var end_idx := code.find("\"", idx + prefix.length())
			if end_idx < 0:
				break
			var reference_text := code.substr(idx, end_idx - idx)
			if "/morrowind/" in reference_text \
					or "/esm/" in reference_text \
					or "/bsa/" in reference_text \
					or "/nif/" in reference_text:
				total += 1
			search_from = end_idx + 1
	return total


func _count_occurrences(text: String, needle: String) -> int:
	if needle.is_empty():
		return 0
	var total := 0
	var search_from := 0
	while true:
		var idx := text.find(needle, search_from)
		if idx < 0:
			return total
		total += 1
		search_from = idx + needle.length()
	return total


func _normalize_path(path: String) -> String:
	var normalized := path.replace("\\", "/")
	if normalized.begins_with("res://"):
		return normalized.substr("res://".length())
	return normalized
