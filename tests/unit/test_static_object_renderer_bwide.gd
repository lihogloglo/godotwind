## Unit tests for StaticObjectRenderer post-B-wide refactor
##
## Verifies:
##   - Single RS instance per object (no multi-RID cascade)
##   - Embedded LOD chain detection via has_lod_chain meta
##   - Promotion hides the single instance (no LOD-child visibility dance)
##   - Cell spatial index works for promotable instance lookup
##   - register_lod_from_prototype compatibility alias
extends GdUnitTestSuite

const SOR := preload("res://src/core/world/static_object_renderer.gd")
const RI := preload("res://src/core/world/reference_instantiator.gd")


class FakeModelLoader:
	extends RefCounted
	var packed_scenes: Dictionary[String, PackedScene] = {}

	func get_cached_packed_scene(model_path: String, item_id: String = "") -> PackedScene:
		var key := model_path.to_lower().replace("/", "\\")
		if not item_id.is_empty():
			key += ":" + item_id.to_lower()
		return packed_scenes.get(key) as PackedScene


## Build a test mesh with an embedded LOD chain via ImporterMesh
func _build_lod_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var grid := 30
	var step := 0.5
	for y in range(grid + 1):
		for x in range(grid + 1):
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(float(x) / grid, float(y) / grid))
			st.add_vertex(Vector3(x * step, 0.0, y * step))
	var stride := grid + 1
	for y in range(grid):
		for x in range(grid):
			var i00 := y * stride + x
			var i10 := y * stride + x + 1
			var i01 := (y + 1) * stride + x
			var i11 := (y + 1) * stride + x + 1
			st.add_index(i00); st.add_index(i10); st.add_index(i11)
			st.add_index(i00); st.add_index(i11); st.add_index(i01)
	var base := st.commit()

	var importer := ImporterMesh.new()
	importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, base.surface_get_arrays(0), [], {}, StandardMaterial3D.new())
	importer.generate_lods(60.0, 25.0, [])
	var lod_mesh: ArrayMesh = importer.get_mesh()
	lod_mesh.set_meta("has_lod_chain", true)
	return lod_mesh


## Build a simple small mesh (no LOD chain)
func _build_simple_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	st.add_vertex(Vector3(0, 0, 0))
	st.set_normal(Vector3.UP)
	st.add_vertex(Vector3(1, 0, 0))
	st.set_normal(Vector3.UP)
	st.add_vertex(Vector3(0, 0, 1))
	st.add_index(0); st.add_index(1); st.add_index(2)
	return st.commit()


func _build_prototype(mesh: ArrayMesh, mat: Material = null) -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	if mat:
		mi.material_override = mat
	root.add_child(mi)
	mi.owner = root
	return root


func _build_packed_scene(mesh: ArrayMesh) -> PackedScene:
	var root := _build_prototype(mesh)
	var packed := PackedScene.new()
	var err := packed.pack(root)
	root.free()
	assert_int(err).is_equal(OK)
	return packed


func test_register_mesh_type_detects_lod_chain() -> void:
	var renderer := SOR.new()
	# Must be in tree for scenario
	auto_free(renderer)
	add_child(renderer)

	var lod_mesh := _build_lod_mesh()
	renderer.register_mesh_type("test_lod", lod_mesh)
	assert_that(renderer.has_type("test_lod")).is_true()
	assert_that(renderer.has_lod("test_lod")).is_true()


func test_register_simple_mesh_no_lod() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var simple := _build_simple_mesh()
	renderer.register_mesh_type("test_simple", simple)
	assert_that(renderer.has_type("test_simple")).is_true()
	assert_that(renderer.has_lod("test_simple")).is_false()


func test_single_instance_per_object() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var lod_mesh := _build_lod_mesh()
	renderer.register_mesh_type("test_single", lod_mesh)

	var id := renderer.add_instance("test_single", Transform3D.IDENTITY, Vector2i(0, 0))
	assert_that(id).is_greater_equal(0)

	var stats := renderer.get_stats()
	assert_that(int(stats["total_instances"])).is_equal(1)
	assert_that(int(stats["visible_instances"])).is_equal(1)


func test_promotion_hides_single_instance() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var lod_mesh := _build_lod_mesh()
	renderer.register_mesh_type("test_promo", lod_mesh)
	var id := renderer.add_instance("test_promo", Transform3D.IDENTITY, Vector2i(0, 0))

	# Promote → should hide
	renderer.set_instance_promoted(id, true)
	var data := renderer.get_instance_data(id)
	assert_that(data.promoted).is_true()

	# Demote → should show
	renderer.set_instance_promoted(id, false)
	data = renderer.get_instance_data(id)
	assert_that(data.promoted).is_false()


func test_cell_spatial_index() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var mesh := _build_lod_mesh()
	renderer.register_mesh_type("test_cell", mesh)

	var _id1 := renderer.add_instance("test_cell", Transform3D(Basis.IDENTITY, Vector3(10, 0, 10)), Vector2i(0, 0), "model.nif")
	var _id2 := renderer.add_instance("test_cell", Transform3D(Basis.IDENTITY, Vector3(20, 0, 10)), Vector2i(0, 0), "model.nif")
	var _id3 := renderer.add_instance("test_cell", Transform3D(Basis.IDENTITY, Vector3(500, 0, 500)), Vector2i(4, 4), "model.nif")

	var promotable := renderer.get_promotable_instances(
		Vector3(15, 0, 10), 100.0 * 100.0, [Vector2i(0, 0)]
	)
	assert_that(promotable.size()).is_equal(2)

	var far_promotable := renderer.get_promotable_instances(
		Vector3(15, 0, 10), 100.0 * 100.0, [Vector2i(4, 4)]
	)
	assert_that(far_promotable.size()).is_equal(0)


func test_register_lod_from_prototype_compat() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var lod_mesh := _build_lod_mesh()
	var proto := _build_prototype(lod_mesh)
	auto_free(proto)
	add_child(proto)

	var has_chain := renderer.register_lod_from_prototype("test_compat", proto)
	assert_that(has_chain).is_true()
	assert_that(renderer.has_type("test_compat")).is_true()


func test_remove_cell_instances() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var mesh := _build_lod_mesh()
	renderer.register_mesh_type("test_remove", mesh)
	var _id1 := renderer.add_instance("test_remove", Transform3D.IDENTITY, Vector2i(1, 1))
	var _id2 := renderer.add_instance("test_remove", Transform3D.IDENTITY, Vector2i(1, 1))
	var _id3 := renderer.add_instance("test_remove", Transform3D.IDENTITY, Vector2i(2, 2))

	var removed := renderer.remove_cell_instances(Vector2i(1, 1))
	assert_that(removed).is_equal(2)
	assert_that(int(renderer.get_stats()["total_instances"])).is_equal(1)


func test_hlod_covered_bucket_caps_mid_range() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var mesh := _build_simple_mesh()
	var proto := _build_prototype(mesh)
	auto_free(proto)
	add_child(proto)
	renderer.register_lod_from_prototype("test_hlod_bucket", proto)
	var bucket := renderer.create_cell_bucket(
		"test_hlod_bucket",
		"meshes\\covered.nif",
		[Transform3D.IDENTITY],
		Vector2i(0, 0)
	)
	assert_that(bucket).is_not_null()

	renderer.set_hlod_covered_bucket_counts({"0,0:meshes\\covered.nif": 1}, 300.0)
	var stats := renderer.get_stats()
	assert_float(float(bucket.get("visibility_range_end"))).is_equal(300.0)
	assert_int(int(stats["hlod_bucket_overrides"])).is_equal(1)
	assert_int(int(stats["hlod_bucket_override_refs"])).is_equal(1)

	renderer.set_hlod_covered_bucket_counts({}, 300.0)
	stats = renderer.get_stats()
	assert_float(float(bucket.get("visibility_range_end"))).is_equal(300.0)
	assert_int(int(stats["hlod_bucket_overrides"])).is_equal(0)
	assert_int(int(stats["hlod_bucket_override_refs"])).is_equal(0)


func test_cell_bucket_uses_direct_rs_for_singleton_group() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var mesh := _build_simple_mesh()
	var proto := _build_prototype(mesh)
	auto_free(proto)
	add_child(proto)
	renderer.register_lod_from_prototype("test_singleton_bucket", proto)
	var bucket := renderer.create_cell_bucket(
		"test_singleton_bucket",
		"meshes\\singleton.nif",
		[Transform3D.IDENTITY],
		Vector2i(0, 0)
	)
	assert_that(bucket).is_not_null()
	assert_int(int(bucket.call("get_draw_group_count"))).is_equal(1)

	var groups: Array = bucket.get("draw_groups")
	var group: Variant = groups[0]
	assert_that(group.multimesh).is_null()
	assert_that(group.instance_rid.is_valid()).is_true()
	assert_int(int(group.instance_count)).is_equal(1)


func test_partial_hlod_bucket_coverage_keeps_mid_fallback() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var mesh := _build_simple_mesh()
	var proto := _build_prototype(mesh)
	auto_free(proto)
	add_child(proto)
	renderer.register_lod_from_prototype("test_hlod_partial", proto)
	var bucket := renderer.create_cell_bucket(
		"test_hlod_partial",
		"meshes\\partial.nif",
		[Transform3D.IDENTITY, Transform3D(Basis.IDENTITY, Vector3(2, 0, 0))],
		Vector2i(0, 0)
	)
	assert_that(bucket).is_not_null()

	renderer.set_hlod_covered_bucket_counts({"0,0:meshes\\partial.nif": 1}, 300.0)
	var stats := renderer.get_stats()
	assert_float(float(bucket.get("visibility_range_end"))).is_equal(300.0)
	assert_int(int(stats["hlod_bucket_overrides"])).is_equal(0)


func test_cell_bucket_uses_local_multimesh_for_close_repeated_group() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var mesh := _build_simple_mesh()
	var proto := _build_prototype(mesh)
	auto_free(proto)
	add_child(proto)
	renderer.register_lod_from_prototype("test_close_bucket", proto)
	var bucket := renderer.create_cell_bucket(
		"test_close_bucket",
		"meshes\\close.nif",
		[
			Transform3D(Basis.IDENTITY, Vector3(0, 0, 0)),
			Transform3D(Basis.IDENTITY, Vector3(2, 0, 0)),
		],
		Vector2i(0, 0)
	)
	assert_that(bucket).is_not_null()
	assert_int(int(bucket.call("get_draw_group_count"))).is_equal(1)

	var groups: Array = bucket.get("draw_groups")
	var group: Variant = groups[0]
	assert_that(group.multimesh).is_not_null()
	assert_int(int(group.instance_count)).is_equal(2)


func test_cell_bucket_splits_repeated_groups_into_spatial_clusters() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var mesh := _build_simple_mesh()
	var proto := _build_prototype(mesh)
	auto_free(proto)
	add_child(proto)
	renderer.register_lod_from_prototype("test_clustered_bucket", proto)
	var bucket := renderer.create_cell_bucket(
		"test_clustered_bucket",
		"meshes\\clustered.nif",
		[
			Transform3D(Basis.IDENTITY, Vector3(0, 0, 0)),
			Transform3D(Basis.IDENTITY, Vector3(70, 0, 0)),
		],
		Vector2i(0, 0)
	)
	assert_that(bucket).is_not_null()
	assert_int(int(bucket.call("get_draw_group_count"))).is_equal(2)

	var stats := renderer.get_stats()
	assert_int(int(stats["bucket_draw_groups"])).is_equal(2)
	assert_int(int(stats["bucket_rs_instances"])).is_equal(2)

	var groups: Array = bucket.get("draw_groups")
	for group: Variant in groups:
		assert_that(group.multimesh).is_null()
		assert_int(int(group.instance_count)).is_equal(1)


func test_visual_proxy_source_key_lifecycle() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var simple := _build_simple_mesh()
	renderer.register_mesh_type("test_proxy", simple)

	var source_key := "container|ext|0,0|42|crate_01"
	var id := renderer.add_visual_proxy(source_key, "test_proxy", Transform3D.IDENTITY, Vector2i(0, 0))
	assert_that(id).is_greater_equal(0)
	assert_int(int(renderer.get_stats()["visual_proxy_instances"])).is_equal(1)

	renderer.suppress_proxy(source_key)
	var data = renderer.get_instance_data(id)
	assert_bool(data.visible).is_false()

	renderer.restore_proxy_if_clean(source_key)
	data = renderer.get_instance_data(id)
	assert_bool(data.visible).is_true()

	renderer.mark_proxy_dirty(source_key, "test")
	data = renderer.get_instance_data(id)
	assert_bool(data.visible).is_false()
	renderer.restore_proxy_if_clean(source_key)
	data = renderer.get_instance_data(id)
	assert_bool(data.visible).is_false()


func test_visual_proxy_registers_from_cached_packed_scene_without_node_instantiation() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var model_path := "meshes\\d\\door_test.nif"
	var normalized := model_path.to_lower().replace("/", "\\")
	var loader := FakeModelLoader.new()
	loader.packed_scenes[normalized] = _build_packed_scene(_build_simple_mesh())

	var instantiator := RI.new()
	instantiator.static_renderer = renderer
	instantiator.model_loader = loader

	assert_bool(renderer.has_type(normalized)).is_false()
	assert_bool(instantiator._ensure_visual_proxy_type_registered(normalized, model_path, "")).is_true()
	assert_bool(renderer.has_type(normalized)).is_true()
