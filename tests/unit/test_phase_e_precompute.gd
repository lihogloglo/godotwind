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
const CS := preload("res://src/core/coordinate_system.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const ReferenceInstantiatorScript := preload("res://src/core/world/reference_instantiator.gd")


class FakeStaticPrecomputeRenderer:
	extends Node

	var captured_type_name: String = ""
	var captured_cell_grid: Vector2i = Vector2i.ZERO
	var captured_transform: Transform3D = Transform3D.IDENTITY
	var captured_ref_id: StringName = &""
	var captured_ref_num: int = 0

	func precompute_instance(
		type_name: String,
		cell_grid: Vector2i,
		world_transform: Transform3D,
		ref_id: StringName = &"",
		ref_num: int = 0,
	) -> Variant:
		captured_type_name = type_name
		captured_cell_grid = cell_grid
		captured_transform = world_transform
		captured_ref_id = ref_id
		captured_ref_num = ref_num
		return null


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


func test_precompute_instance_returns_null_for_unregistered_type() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var precomp: Variant = renderer.precompute_instance("missing_type", Vector2i.ZERO, Transform3D.IDENTITY)
	assert_that(precomp).is_null()


func test_precompute_instance_populates_fields() -> void:
	var renderer := SOR.new()
	auto_free(renderer)
	add_child(renderer)

	var proto := _build_simple_prototype()
	auto_free(proto)
	add_child(proto)
	renderer.register_from_prototype("test_precomp", proto)

	var transform := Transform3D(Basis.IDENTITY.scaled(Vector3(2, 2, 2)), Vector3(100, 50, -200))
	var precomp: Variant = renderer.precompute_instance("test_precomp", Vector2i(3, -1), transform, &"ref_xyz", 7)
	assert_that(precomp).is_not_null()
	assert_that(precomp.type_name).is_equal("test_precomp")
	assert_that(precomp.cell_grid).is_equal(Vector2i(3, -1))
	assert_that(precomp.ref_num).is_equal(7)
	assert_that(precomp.sub_mesh_combined_xforms.size()).is_equal(1)
	assert_that(precomp.aabb.size).is_not_equal(Vector3.ZERO)
	assert_that(precomp.world_transform).is_equal(transform)


func test_worker_static_precompute_uses_source_neutral_renderer_contract() -> void:
	var instantiator := ReferenceInstantiatorScript.new()
	var renderer := FakeStaticPrecomputeRenderer.new()
	auto_free(renderer)
	add_child(renderer)
	instantiator.static_renderer = renderer

	var ref := CellReference.new()
	ref.ref_id = "test_ref"
	ref.ref_num = 99
	ref.position = Vector3(70.0, 140.0, 210.0)
	ref.rotation = Vector3.ZERO
	ref.scale = 2.0

	var entry := CellManagerScript.InstantiationEntry.new()
	entry.ref = ref
	entry.model_path = "Meshes/Test/Static.NIF"
	entry.item_id = "test_item"

	instantiator.call("_worker_static_precompute", entry, Vector2i(4, -2))

	var expected_basis := CS.esm_rotation_to_godot_basis(ref.rotation)
	expected_basis = expected_basis.scaled(CS.scale_to_godot(ref.scale))
	var expected := Transform3D(expected_basis, CS.vector_to_godot(ref.position))
	assert_str(renderer.captured_type_name).is_equal("meshes\\test\\static.nif")
	assert_that(renderer.captured_cell_grid).is_equal(Vector2i(4, -2))
	assert_vector(renderer.captured_transform.origin).is_equal_approx(expected.origin, Vector3.ONE * 0.001)
	assert_vector(renderer.captured_transform.basis.x).is_equal_approx(expected.basis.x, Vector3.ONE * 0.001)
	assert_str(str(renderer.captured_ref_id)).is_equal("test_ref")
	assert_int(renderer.captured_ref_num).is_equal(99)


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

	var transform := Transform3D(Basis.IDENTITY, Vector3(100, 200, 50))

	# Sync path uses the same normalized transform as the precompute path.
	var id_sync := renderer_sync.add_instance("test_match", transform, Vector2i(0, 0))

	# Precompute path. The worker would normally fill these from the
	# InstantiationEntry; tests populate directly to match the contract.
	var precomp: Variant = renderer_pc.precompute_instance("test_match", Vector2i(0, 0), transform, &"ref_match", 1)
	precomp.model_path = "meshes/test_match.nif"
	precomp.item_id = ""
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

	# Ref metadata parity — builder review BLOCKER 1 regression guard.
	# Precompute path MUST populate model_path / ref_id / ref_num in
	# InstanceData; empty strings break find_instances_near promotion query.
	assert_that(data_pc.model_path).is_equal("meshes/test_match.nif")
	assert_that(str(data_pc.ref_id)).is_equal("ref_match")
	assert_that(data_pc.ref_num).is_equal(1)
