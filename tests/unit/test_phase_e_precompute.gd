## Unit tests for Phase E precompute/consume round-trip.
##
## Verifies that StaticObjectRenderer.precompute_instance (worker-safe) +
## add_instance_precomputed (main) produce the same observable state as the
## synchronous add_instance path — with the same _mesh_types, the same
## cell_index bookkeeping, and the same stats.
##
## Plan: docs/plans/distant_rendering_2026_04/phase_e_static_bulk_upload.md §3.2
extends GdUnitTestSuite

const SOR := preload("res://src/core/world/static_object_renderer.gd")
const CellReferenceScript := preload("res://src/core/esm/records/cell_reference.gd")


func _build_simple_prototype() -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	# Minimal valid mesh — a single triangle.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP); st.add_vertex(Vector3(0, 0, 0))
	st.set_normal(Vector3.UP); st.add_vertex(Vector3(1, 0, 0))
	st.set_normal(Vector3.UP); st.add_vertex(Vector3(0, 0, 1))
	st.add_index(0); st.add_index(1); st.add_index(2)
	mi.mesh = st.commit()
	root.add_child(mi)
	return root


func _build_ref(ref_id: String, ref_num: int, mw_position: Vector3, mw_rotation: Vector3, mw_scale: float) -> CellReference:
	var ref := CellReferenceScript.new()
	ref.ref_id = StringName(ref_id)
	ref.ref_num = ref_num
	ref.position = mw_position
	ref.rotation = mw_rotation
	ref.scale = mw_scale
	return ref


func test_precompute_instance_returns_null_for_unregistered_type() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var ref := _build_ref("test_ref", 1, Vector3(100, 0, 200), Vector3.ZERO, 1.0)
	var precomp: Variant = renderer.precompute_instance("missing_type", ref, Vector2i.ZERO)
	assert_that(precomp).is_null()


func test_precompute_instance_populates_fields() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var proto := _build_simple_prototype()
	auto_free(proto)
	add_child(proto)
	renderer.register_from_prototype("test_precomp", proto)

	var ref := _build_ref("ref_xyz", 7, Vector3(100, 200, 50), Vector3.ZERO, 2.0)
	var precomp: Variant = renderer.precompute_instance("test_precomp", ref, Vector2i(3, -1))
	assert_that(precomp).is_not_null()
	assert_that(precomp.type_name).is_equal("test_precomp")
	assert_that(precomp.cell_grid).is_equal(Vector2i(3, -1))
	assert_that(precomp.ref_num).is_equal(7)
	assert_that(precomp.sub_mesh_combined_xforms.size()).is_equal(1)
	# custom_data carries (spawn_time, fade_duration, 0, 0) — spawn_time may
	# vary per run; assert fade_duration is approximately the renderer constant.
	# Color stores f32 which causes tiny precision drift vs f64 constant.
	assert_that(absf(precomp.custom_data.g - SOR.REGISTRY_FADE_DURATION_S)).is_less(0.001)
	# Scale is applied via esm_rotation_to_godot_basis(...).scaled(scale).
	# Position passes through CS.vector_to_godot which swaps Y/Z.
	assert_that(precomp.world_transform.origin).is_not_equal(Vector3.ZERO)


func test_add_instance_precomputed_matches_add_instance() -> void:
	# Two parallel renderers; one uses sync add_instance, the other uses
	# precompute_instance + add_instance_precomputed. Observable stats must match.
	var renderer_sync := SOR.new()
	var renderer_pc := SOR.new()
	auto_free(renderer_sync)
	auto_free(renderer_pc)
	add_child(renderer_sync)
	add_child(renderer_pc)

	var proto_a := _build_simple_prototype()
	var proto_b := _build_simple_prototype()
	auto_free(proto_a); auto_free(proto_b)
	add_child(proto_a); add_child(proto_b)
	renderer_sync.register_from_prototype("test_match", proto_a)
	renderer_pc.register_from_prototype("test_match", proto_b)

	var ref := _build_ref("ref_match", 1, Vector3(100, 0, 200), Vector3.ZERO, 1.0)

	# Sync path — derive transform the same way _instantiate_static_object does.
	var CS := preload("res://src/core/coordinate_system.gd")
	var pos := CS.vector_to_godot(ref.position)
	var scale := CS.scale_to_godot(ref.scale)
	var basis := CS.esm_rotation_to_godot_basis(ref.rotation)
	basis = basis.scaled(scale)
	var transform := Transform3D(basis, pos)
	var id_sync := renderer_sync.add_instance("test_match", transform, Vector2i(0, 0))

	# Precompute path.
	var precomp: Variant = renderer_pc.precompute_instance("test_match", ref, Vector2i(0, 0))
	var id_pc := renderer_pc.add_instance_precomputed(precomp)

	# Both should succeed.
	assert_that(id_sync).is_greater_equal(0)
	assert_that(id_pc).is_greater_equal(0)

	# Observable stats match.
	var stats_sync := renderer_sync.get_stats()
	var stats_pc := renderer_pc.get_stats()
	assert_that(int(stats_sync["total_instances"])).is_equal(int(stats_pc["total_instances"]))
	assert_that(int(stats_sync["visible_instances"])).is_equal(int(stats_pc["visible_instances"]))

	# Stored transforms match.
	var data_sync := renderer_sync.get_instance_data(id_sync)
	var data_pc := renderer_pc.get_instance_data(id_pc)
	assert_that(data_sync.transform.origin.distance_to(data_pc.transform.origin)).is_less(0.0001)
