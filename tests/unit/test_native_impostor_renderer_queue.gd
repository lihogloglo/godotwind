extends GdUnitTestSuite

const NativeImpostorRendererScript := preload("res://src/core/world/native_impostor_renderer.gd")
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


func test_hlod_page_stats_ignore_hlod_begin_when_far_is_fixed() -> void:
	var renderer := NativeImpostorRendererScript.new()
	auto_free(renderer)

	var page := NativeImpostorRendererScript.ImpostorPage.new()
	page.key = "page"
	page.visibility_begin_distance = DU.HLOD_END
	page.impostor_ids = [1, 2] as Array[int]
	renderer._impostor_pages["page"] = page
	renderer._visibility_begin_distance = DU.FAR_START

	var stats: Dictionary = renderer._get_hlod_page_coverage_stats()
	assert_int(stats.get("covered_pages", -1)).is_equal(0)
	assert_int(stats.get("uncovered_pages", -1)).is_equal(1)
	assert_int(stats.get("covered_impostors", -1)).is_equal(0)
	assert_int(stats.get("page_overrides", -1)).is_equal(0)


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
