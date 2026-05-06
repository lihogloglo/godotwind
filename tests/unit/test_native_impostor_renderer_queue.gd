extends GdUnitTestSuite

const NativeImpostorRendererScript := preload("res://src/core/world/native_impostor_renderer.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
const DU := preload("res://src/core/world/distance_utils.gd")


func test_unloaded_cells_are_removed_from_pending_queue_and_resume() -> void:
	var renderer := NativeImpostorRendererScript.new()
	auto_free(renderer)
	add_child(renderer)

	renderer._pending_impostor_cells = [
		Vector2i(0, 0),
		Vector2i(1, 0),
		Vector2i(2, 0),
		Vector2i(3, 0),
	] as Array[Vector2i]
	renderer._pending_impostor_cell_set = {
		Vector2i(0, 0): true,
		Vector2i(1, 0): true,
		Vector2i(2, 0): true,
		Vector2i(3, 0): true,
	}
	renderer._pending_cell_index = 2
	renderer._has_resume = true
	renderer._resume_cell_grid = Vector2i(2, 0)
	renderer._resume_ref_index = 7

	renderer._unload_impostors_in_cells([Vector2i(1, 0), Vector2i(2, 0)] as Array[Vector2i])

	assert_int(renderer._pending_impostor_cells.size()).is_equal(2)
	assert_that(renderer._pending_impostor_cells.has(Vector2i(1, 0))).is_false()
	assert_that(renderer._pending_impostor_cells.has(Vector2i(2, 0))).is_false()
	assert_int(renderer._pending_cell_index).is_equal(1)
	assert_bool(renderer._has_resume).is_false()
	assert_int(renderer._resume_ref_index).is_equal(0)


func test_hlod_page_stats_do_not_count_default_far_begin_as_override() -> void:
	var renderer := NativeImpostorRendererScript.new()
	auto_free(renderer)

	var page := NativeImpostorRendererScript.ImpostorPage.new()
	page.key = "page"
	page.visibility_begin_distance = DU.FAR_START
	page.impostor_ids = [1] as Array[int]
	renderer._impostor_pages["page"] = page
	renderer._visibility_begin_distance = DU.FAR_START

	var stats: Dictionary = renderer._get_hlod_page_coverage_stats()
	assert_int(stats.get("covered_pages", -1)).is_equal(0)
	assert_int(stats.get("uncovered_pages", -1)).is_equal(1)
	assert_int(stats.get("page_overrides", -1)).is_equal(0)


func test_hlod_page_stats_count_hlod_deferred_page_when_far_starts_early() -> void:
	var renderer := NativeImpostorRendererScript.new()
	auto_free(renderer)

	var page := NativeImpostorRendererScript.ImpostorPage.new()
	page.key = "page"
	page.visibility_begin_distance = DU.HLOD_END
	page.impostor_ids = [1, 2] as Array[int]
	renderer._impostor_pages["page"] = page
	renderer._visibility_begin_distance = DU.FAR_START

	var stats: Dictionary = renderer._get_hlod_page_coverage_stats()
	assert_int(stats.get("covered_pages", -1)).is_equal(1)
	assert_int(stats.get("uncovered_pages", -1)).is_equal(0)
	assert_int(stats.get("covered_impostors", -1)).is_equal(2)
	assert_int(stats.get("page_overrides", -1)).is_equal(1)


func test_impostor_page_readiness_allows_albedo_only() -> void:
	var impostor := NativeImpostorRendererScript.ImpostorData.new()
	impostor.texture_index = 0
	impostor.normal_texture_index = -1

	var bucket := NativeImpostorRendererScript.TextureBucket.new()
	bucket.committed_texture_array_layers = 1
	bucket.committed_normal_array_layers = 0

	assert_bool(NativeImpostorRendererScript._is_impostor_ready_for_page(impostor, bucket)).is_true()


func test_impostor_page_readiness_allows_pending_normal_layer() -> void:
	var impostor := NativeImpostorRendererScript.ImpostorData.new()
	impostor.texture_index = 0
	impostor.normal_texture_index = 0

	var bucket := NativeImpostorRendererScript.TextureBucket.new()
	bucket.committed_texture_array_layers = 1
	bucket.committed_normal_array_layers = 0

	assert_bool(NativeImpostorRendererScript._is_impostor_ready_for_page(impostor, bucket)).is_true()


func test_add_impostor_loads_v6_metadata_on_first_use() -> void:
	var model_path := "meshes/x/unit_impostor_metadata_regression.nif"
	var hash_key := ImpostorCandidatesScript.get_hash_key(model_path)
	var albedo_path := ImpostorCandidatesScript.get_impostor_texture_path_v6(model_path)
	var normal_path := ImpostorCandidatesScript.get_impostor_normal_res_path_v6(model_path)
	var metadata_path := ImpostorCandidatesScript.get_impostor_metadata_path_v6(model_path)
	_write_test_impostor_files(albedo_path, normal_path, metadata_path)

	var renderer := NativeImpostorRendererScript.new()
	auto_free(renderer)
	var candidates := ImpostorCandidatesScript.new()
	candidates.add_custom_candidate(model_path)
	renderer.set_impostor_candidates(candidates)

	renderer.add_impostor(model_path, Vector2i.ZERO, Vector3.ZERO)

	assert_bool(renderer._impostor_metadata.has(hash_key)).is_true()
	assert_bool(renderer._pending_impostors.has(hash_key)).is_true()
	assert_int(int(renderer._stats.get("skipped_metadata_uncached", 0))).is_equal(0)

	DirAccess.remove_absolute(albedo_path)
	DirAccess.remove_absolute(normal_path)
	DirAccess.remove_absolute(metadata_path)


func _write_test_impostor_files(albedo_path: String, normal_path: String, metadata_path: String) -> void:
	DirAccess.make_dir_recursive_absolute(albedo_path.get_base_dir())
	var albedo := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	albedo.fill(Color.WHITE)
	assert_int(albedo.save_png(albedo_path)).is_equal(OK)

	var normal_image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	normal_image.fill(Color(0.5, 1.0, 0.5, 0.0))
	var normal_texture := ImageTexture.create_from_image(normal_image)
	assert_int(ResourceSaver.save(normal_texture, normal_path)).is_equal(OK)

	var metadata := {
		"version": 6,
		"projection": "hemi",
		"bounds": {
			"capture_size": 10.0,
			"width": 10.0,
			"height": 10.0,
			"depth": 10.0,
			"center": [0.0, 0.0, 0.0],
		},
	}
	var file := FileAccess.open(metadata_path, FileAccess.WRITE)
	assert_object(file).is_not_null()
	file.store_string(JSON.stringify(metadata))
	file.close()
