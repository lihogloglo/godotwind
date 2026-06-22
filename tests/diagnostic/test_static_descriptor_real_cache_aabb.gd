extends GdUnitTestSuite

const SOR := preload("res://src/core/world/static_object_renderer.gd")
const DU := preload("res://src/core/world/distance_utils.gd")

const MODELS := [
	"f\\flora_bc_grass_01.nif",
	"f\\terrain_rock_bc_18.nif",
	"f\\terrain_rock_bc_17.nif",
	"f\\flora_bc_fern_02.nif",
]


func test_real_cached_static_descriptor_aabbs_are_meter_scale() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	for model_path: String in MODELS:
		var cache_path := _cache_path_for_model(model_path)
		var packed := ResourceLoader.load(cache_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		assert_object(packed).is_not_null()
		var type_name := model_path.to_lower().replace("/", "\\")
		assert_bool(renderer.register_from_packed_scene(type_name, packed)).is_true()
		var stats := renderer.get_mesh_type_stats(type_name)
		var aabb: AABB = stats.get("aabb", AABB())
		var max_dim := _aabb_max_dimension(aabb)
		var cutoff := clampf(
			max_dim * DU.SCREEN_SIZE_CUTOFF_RATIO,
			DU.SCREEN_SIZE_MIN_CUTOFF,
			DU.SCREEN_SIZE_MAX_CUTOFF
		) if max_dim > 0.0 else DU.MID_END
		var effective_cutoff := float(renderer.call("_get_type_detail_visibility_range_end", type_name))
		print("[static_descriptor_aabb] %s registered_aabb_pos=%s registered_aabb_size=%s max_dim=%.3f cutoff=%.3f effective_cutoff=%.3f cache=%s" % [
			model_path,
			aabb.position,
			aabb.size,
			max_dim,
			cutoff,
			effective_cutoff,
			cache_path,
		])
		assert_float(max_dim).is_less(50.0)
		assert_float(effective_cutoff).is_less(DU.MID_END)
		assert_float(effective_cutoff).is_less_equal(SOR.DETAIL_CULL_FAMILY_MAX_CUTOFF)


func _cache_path_for_model(model_path: String) -> String:
	var normalized := model_path.to_lower().replace("/", "\\")
	var safe_name := normalized.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	return SettingsManager.get_models_path().path_join("%s.res" % safe_name)


func _aabb_max_dimension(aabb: AABB) -> float:
	return maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
