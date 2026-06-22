extends GdUnitTestSuite

const SOR := preload("res://src/core/world/static_object_renderer.gd")
const DU := preload("res://src/core/world/distance_utils.gd")


func _build_simple_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	st.add_vertex(Vector3(0, 0, 0))
	st.set_normal(Vector3.UP)
	st.add_vertex(Vector3(1, 0, 0))
	st.set_normal(Vector3.UP)
	st.add_vertex(Vector3(0, 0, 1))
	st.add_index(0)
	st.add_index(1)
	st.add_index(2)
	return st.commit()


func _build_prototype(mesh: ArrayMesh, mat: Material) -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	root.add_child(mi)
	mi.owner = root
	return root


func test_model_material_contributors_include_bucket_direct_and_coverage_counts() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var mat := StandardMaterial3D.new()
	mat.resource_name = "contrib_mat"
	var proto := _build_prototype(_build_simple_mesh(), mat)
	auto_free(proto)
	add_child(proto)

	renderer.register_lod_from_prototype("test_contrib", proto)
	var bucket := renderer.create_cell_bucket(
		"test_contrib",
		"meshes\\contrib.nif",
		[
			Transform3D.IDENTITY,
			Transform3D(Basis.IDENTITY, Vector3(2, 0, 0)),
		],
		Vector2i(0, 0)
	)
	assert_that(bucket).is_not_null()
	var _direct_id := renderer.add_instance("test_contrib", Transform3D.IDENTITY, Vector2i(0, 0))
	renderer.set_hlod_covered_bucket_counts({"0,0:meshes\\contrib.nif": 2}, DU.HLOD_START)

	var census: Dictionary = renderer.get_bucket_census()
	assert_bool(bool(census["source_ref_coverage_available"])).is_true()
	assert_int((census["model_material_contributors"] as Array).size()).is_greater_equal(1)
	var rows: Array = census["top_model_material_contributors"]
	assert_int(rows.size()).is_greater_equal(1)
	var row: Dictionary = rows[0]
	assert_str(str(row["type"])).is_equal("test_contrib")
	assert_str(str(row["material"])).is_equal("contrib_mat")
	assert_int(int(row["instances"])).is_equal(2)
	assert_int(int(row["draw_groups"])).is_equal(1)
	assert_int(int(row["singleton_draw_groups"])).is_equal(0)
	assert_int(int(row["multimesh_draw_groups"])).is_equal(1)
	assert_int(int(row["multimesh_instances"])).is_equal(2)
	assert_float(float(row["max_aabb_dimension"])).is_greater_equal(1.0)
	assert_float(float(row["detail_visibility_cutoff"])).is_equal(DU.SCREEN_SIZE_CUTOFF_RATIO)
	assert_int(int(row["direct_duplicate_count"])).is_equal(1)
	assert_int(int(row["bucket_covered_duplicate_count"])).is_equal(2)


func test_mid_offender_census_reports_bucket_duplicates_and_cell_hotspots() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var mat := StandardMaterial3D.new()
	mat.resource_name = "offender_mat"
	var proto := _build_prototype(_build_simple_mesh(), mat)
	auto_free(proto)
	add_child(proto)

	renderer.register_lod_from_prototype("test_offender", proto)
	var bucket_a := renderer.create_cell_bucket(
		"test_offender",
		"meshes\\dupe.nif",
		[
			Transform3D.IDENTITY,
			Transform3D(Basis.IDENTITY, Vector3(70, 0, 0)),
		],
		Vector2i(0, 0)
	)
	var bucket_b := renderer.create_cell_bucket(
		"test_offender",
		"meshes\\single_group.nif",
		[
			Transform3D.IDENTITY,
			Transform3D(Basis.IDENTITY, Vector3(2, 0, 0)),
		],
		Vector2i(1, 0)
	)
	assert_that(bucket_a).is_not_null()
	assert_that(bucket_b).is_not_null()

	var _direct_duplicate := renderer.add_instance(
		"test_offender",
		Transform3D.IDENTITY,
		Vector2i(0, 0),
		"meshes\\dupe.nif"
	)
	var _direct_non_duplicate := renderer.add_instance(
		"test_offender",
		Transform3D.IDENTITY,
		Vector2i(2, 0),
		"meshes\\dupe.nif"
	)
	var proxy_id := renderer.add_visual_proxy(
		"source:proxy",
		"test_offender",
		Transform3D.IDENTITY,
		Vector2i(0, 0),
		"meshes\\dupe.nif"
	)
	assert_that(proxy_id).is_greater_equal(0)

	var census: Dictionary = renderer.get_bucket_census(10)

	var top_buckets: Array = census["top_bucket_contributors_by_draw_groups"]
	assert_int(top_buckets.size()).is_greater_equal(2)
	assert_str(str(top_buckets[0]["bucket_key"])).is_equal("0,0:meshes\\dupe.nif")
	assert_str(str(top_buckets[0]["cell"])).is_equal("0,0")
	assert_str(str(top_buckets[0]["type_name"])).is_equal("test_offender")
	assert_int(int(top_buckets[0]["instance_count"])).is_equal(2)
	assert_int(int(top_buckets[0]["draw_group_count"])).is_equal(2)
	assert_int(int(top_buckets[0]["singleton_draw_groups"])).is_equal(2)
	assert_int(int(top_buckets[0]["multimesh_draw_groups"])).is_equal(0)

	var singleton_heavy: Array = census["top_singleton_heavy_bucket_contributors"]
	assert_str(str(singleton_heavy[0]["bucket_key"])).is_equal("0,0:meshes\\dupe.nif")
	assert_int(int(singleton_heavy[0]["singleton_draw_groups"])).is_equal(2)

	assert_int(int(census["direct_static_duplicate_candidate_count"])).is_equal(1)
	assert_int(int(census["direct_static_duplicate_candidate_rs_instances"])).is_equal(1)
	var duplicate_rows: Array = census["top_direct_static_duplicate_candidates"]
	assert_int(duplicate_rows.size()).is_equal(1)
	assert_str(str(duplicate_rows[0]["cell"])).is_equal("0,0")
	assert_str(str(duplicate_rows[0]["type_name"])).is_equal("test_offender")
	assert_str(str(duplicate_rows[0]["bucket_key"])).is_equal("0,0:meshes\\dupe.nif")
	assert_int(int(duplicate_rows[0]["instance_count"])).is_equal(1)
	assert_int(int(duplicate_rows[0]["rs_instances"])).is_equal(1)

	var hotspots: Array = census["per_cell_mid_hotspots"]
	assert_int(hotspots.size()).is_greater_equal(2)
	assert_str(str(hotspots[0]["cell"])).is_equal("0,0")
	assert_int(int(hotspots[0]["bucket_count"])).is_equal(1)
	assert_int(int(hotspots[0]["bucket_draw_groups"])).is_equal(2)
	assert_int(int(hotspots[0]["direct_rs_instances"])).is_equal(2)
	assert_int(int(hotspots[0]["visual_proxy_instances"])).is_equal(1)
