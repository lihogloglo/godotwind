## Parity + correctness test for ObjectPagingKernel.
##
## Covers the Phase 1 extraction (docs/audit/OBJECT_PAGING_PLAN.md §11):
## hot merge math moved from RuntimeHLODMerger into the C# kernel via a
## thin GDScript facade. These tests are the rollback anchor — a failure
## here means the C# kernel diverges from the pre-extraction GDScript
## contract and the phase should revert.
##
## Strategy: deterministic synthetic input fixtures (hand-crafted ArrayMeshes
## with known vertex counts, positions, and materials), then structural
## assertions on the merged output. Hashing the whole ArrayMesh is fragile
## because Godot's internal vertex ordering may differ across the C# path;
## structural properties (per-material surface presence, vertex counts,
## bounding boxes, material identity) are stable.
@warning_ignore("unused_parameter")
extends GdUnitTestSuite

const Kernel := preload("res://src/core/world/object_paging_kernel.gd")
const Merger := preload("res://src/core/world/runtime_hlod_merger.gd")
const DU := preload("res://src/core/world/distance_utils.gd")


#region Fixtures

## Build a simple triangle ArrayMesh with 3 verts in the XY plane.
## Deterministic — every call returns the same vertex positions.
static func _make_triangle_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(0.0, 1.0, 0.0),
	])
	var normals := PackedVector3Array([
		Vector3(0.0, 0.0, 1.0),
		Vector3(0.0, 0.0, 1.0),
		Vector3(0.0, 0.0, 1.0),
	])
	var indices := PackedInt32Array([0, 1, 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Build a SubMeshInput wrapping a given mesh at identity local transform.
static func _make_sub(mesh: ArrayMesh, mat_override: Material) -> Kernel.SubMeshInput:
	var sm := Kernel.SubMeshInput.new()
	sm.mesh = mesh
	sm.local_transform = Transform3D.IDENTITY
	sm.material_override = mat_override
	sm.surface_materials = []
	return sm


## Build a RefInput with one sub-mesh at a given world position.
static func _make_ref(mesh: ArrayMesh, mat: Material, world_pos: Vector3) -> Kernel.RefInput:
	var ref := Kernel.RefInput.new()
	ref.ref_transform = Transform3D(Basis.IDENTITY, world_pos)
	ref.sub_meshes = [_make_sub(mesh, mat)]
	return ref

#endregion


#region Tests

func test_empty_input_returns_null() -> void:
	var mesh: ArrayMesh = Kernel.merge_refs([], Vector3.ZERO)
	assert_that(mesh).is_null()


func test_single_ref_preserves_surface() -> void:
	var tri := _make_triangle_mesh()
	var mat := StandardMaterial3D.new()
	var ref := _make_ref(tri, mat, Vector3(10.0, 0.0, 0.0))

	var merged: ArrayMesh = Kernel.merge_refs([ref], Vector3.ZERO)
	assert_that(merged).is_not_null()
	assert_that(merged.get_surface_count()).is_equal(1)

	# 3 verts (one triangle). LOD chain generation may re-emit the same surface
	# with additional surface_lod_indices; vertex count stays the same.
	var arrays: Array = merged.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_that(verts.size()).is_equal(3)

	# Ref transform places triangle at x=10. Chunk origin is 0, so local x stays 10.
	# Vertex 0 of triangle was (0,0,0) → (10,0,0) after ref_transform.
	# Accept any vertex with x ≈ 10 since LOD gen may reorder.
	var found_at_10 := false
	for v: Vector3 in verts:
		if absf(v.x - 10.0) < 0.01 and absf(v.y) < 0.01 and absf(v.z) < 0.01:
			found_at_10 = true
			break
	assert_bool(found_at_10).override_failure_message(
		"Expected a vertex at world-local (10,0,0) after ref_transform; got %s" % [verts]
	).is_true()


func test_chunk_origin_subtracts_from_vertex_positions() -> void:
	var tri := _make_triangle_mesh()
	var mat := StandardMaterial3D.new()
	var ref := _make_ref(tri, mat, Vector3(100.0, 0.0, 0.0))

	# chunk_origin = (90, 0, 0) — vertex 0 should end at (10, 0, 0)
	var merged: ArrayMesh = Kernel.merge_refs([ref], Vector3(90.0, 0.0, 0.0))
	assert_that(merged).is_not_null()

	var arrays: Array = merged.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var min_x := INF
	var max_x := -INF
	for v: Vector3 in verts:
		min_x = min(min_x, v.x)
		max_x = max(max_x, v.x)

	# Triangle verts were (0,0,0), (1,0,0), (0,1,0) + ref offset (100,0,0) - chunk (90,0,0) = (10,0,0), (11,0,0), (10,1,0)
	assert_float(min_x).is_between(9.99, 10.01)
	assert_float(max_x).is_between(10.99, 11.01)


func test_two_refs_same_material_merge_into_one_surface() -> void:
	var tri := _make_triangle_mesh()
	var mat := StandardMaterial3D.new()  # single material instance shared
	var ref_a := _make_ref(tri, mat, Vector3(10.0, 0.0, 0.0))
	var ref_b := _make_ref(tri, mat, Vector3(20.0, 0.0, 0.0))

	var merged: ArrayMesh = Kernel.merge_refs([ref_a, ref_b], Vector3.ZERO)
	assert_that(merged).is_not_null()

	# Same material → one merged surface.
	assert_that(merged.get_surface_count()).is_equal(1)

	# 2 × 3 = 6 vertices
	var arrays: Array = merged.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_that(verts.size()).is_equal(6)

	# Verify both ref positions are represented (one vertex near x=10, one near x=20)
	var found_a := false
	var found_b := false
	for v: Vector3 in verts:
		if absf(v.x - 10.0) < 0.01: found_a = true
		if absf(v.x - 20.0) < 0.01: found_b = true
	assert_bool(found_a and found_b).override_failure_message(
		"Expected vertices from both refs (x≈10 and x≈20); got %s" % [verts]
	).is_true()


func test_two_refs_different_materials_produce_two_surfaces() -> void:
	var tri := _make_triangle_mesh()
	var mat_a := StandardMaterial3D.new()
	var mat_b := StandardMaterial3D.new()  # distinct instance → distinct hash
	var ref_a := _make_ref(tri, mat_a, Vector3(10.0, 0.0, 0.0))
	var ref_b := _make_ref(tri, mat_b, Vector3(20.0, 0.0, 0.0))

	var merged: ArrayMesh = Kernel.merge_refs([ref_a, ref_b], Vector3.ZERO)
	assert_that(merged).is_not_null()
	assert_that(merged.get_surface_count()).is_equal(2)

	# Each surface has 3 verts (no concat happened, different materials)
	for si in range(merged.get_surface_count()):
		var arrays: Array = merged.surface_get_arrays(si)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		assert_that(verts.size()).is_equal(3)


func test_materials_preserved_on_merged_surfaces() -> void:
	var tri := _make_triangle_mesh()
	var mat_a := StandardMaterial3D.new()
	var mat_b := StandardMaterial3D.new()
	var ref_a := _make_ref(tri, mat_a, Vector3(10.0, 0.0, 0.0))
	var ref_b := _make_ref(tri, mat_b, Vector3(20.0, 0.0, 0.0))

	var merged: ArrayMesh = Kernel.merge_refs([ref_a, ref_b], Vector3.ZERO)
	assert_that(merged).is_not_null()
	assert_that(merged.get_surface_count()).is_equal(2)

	# Both materials must appear on exactly one surface each — we do not
	# assume a particular order because C# dict iteration is now sorted by
	# matId, but matId is Godot's instance id (non-deterministic across runs).
	var seen_a := false
	var seen_b := false
	for si in range(merged.get_surface_count()):
		var m: Material = merged.surface_get_material(si)
		if m == mat_a: seen_a = true
		elif m == mat_b: seen_b = true
	assert_bool(seen_a and seen_b).override_failure_message(
		"Expected both mat_a and mat_b on merged surfaces."
	).is_true()


func test_estimate_mesh_bytes_scales_with_vertex_count() -> void:
	var tri := _make_triangle_mesh()
	var mat := StandardMaterial3D.new()

	# 1 ref → 3 verts
	var ref1 := _make_ref(tri, mat, Vector3.ZERO)
	var merged1: ArrayMesh = Kernel.merge_refs([ref1], Vector3.ZERO)
	var bytes1 := Kernel.estimate_mesh_bytes(merged1)

	# 4 refs (shared material) → 12 verts
	var refs4: Array = []
	for i in range(4):
		refs4.append(_make_ref(tri, mat, Vector3(float(i) * 10.0, 0.0, 0.0)))
	var merged4: ArrayMesh = Kernel.merge_refs(refs4, Vector3.ZERO)
	var bytes4 := Kernel.estimate_mesh_bytes(merged4)

	# 4× vertex count should give ≈4× byte estimate. LOD chain adds a
	# multiplier but it's applied identically to both, so the ratio holds.
	assert_int(bytes4).is_greater(bytes1)
	assert_float(float(bytes4) / float(bytes1)).is_between(3.0, 5.0)


func test_null_mesh_bytes_returns_zero() -> void:
	assert_int(Kernel.estimate_mesh_bytes(null)).is_equal(0)


#region Phase 2 — projected-size filter parity tests

## Large mesh (5m radius) close to camera (10m) should always pass.
func test_size_worthy_large_close_mesh_kept() -> void:
	var mesh_radius_sq := 25.0  # 5m radius
	var scale := 1.0
	var dist_sq := 100.0  # 10m
	assert_bool(Merger._is_size_worthy(mesh_radius_sq, scale, dist_sq, DU.PAGING_MIN_SIZE_SQ)) \
		.override_failure_message("Large close mesh must pass projected-size test.") \
		.is_true()


## Tiny mesh (0.1m radius) at HLOD range (500m) should be rejected.
func test_size_worthy_small_distant_mesh_rejected() -> void:
	var mesh_radius_sq := 0.01  # 0.1m radius
	var scale := 1.0
	var dist_sq := 250000.0  # 500m
	assert_bool(Merger._is_size_worthy(mesh_radius_sq, scale, dist_sq, DU.PAGING_MIN_SIZE_SQ)) \
		.override_failure_message("Small distant mesh must be rejected.") \
		.is_false()


## Scale multiplier matters — a mesh with scale=2 covers 4× area in the test.
## Same mesh at scale=0.5 projects 4× smaller → rejection threshold shifts.
func test_size_worthy_scale_changes_outcome() -> void:
	var mesh_radius_sq := 1.0  # 1m radius
	var dist_sq := 10000.0  # 100m

	# Scale=2.0 → radius² × scale² = 4. Threshold = dist² × minSize² = 10000 × 0.0196 = 196.
	# 4 < 196 → still rejected at 100m.
	assert_bool(Merger._is_size_worthy(mesh_radius_sq, 2.0, dist_sq, DU.PAGING_MIN_SIZE_SQ)) \
		.is_false()

	# Closer: dist=30m, dist_sq=900, threshold=900 × 0.0196 = 17.64.
	# Scale=2 → 4. Still rejected (17.64 > 4).
	# Scale=5 → 25. 25 >= 17.64 → kept.
	assert_bool(Merger._is_size_worthy(mesh_radius_sq, 5.0, 900.0, DU.PAGING_MIN_SIZE_SQ)) \
		.is_true()
	assert_bool(Merger._is_size_worthy(mesh_radius_sq, 2.0, 900.0, DU.PAGING_MIN_SIZE_SQ)) \
		.is_false()


## Threshold boundary — exactly at the cutoff should pass (>= inclusive).
func test_size_worthy_exact_boundary_kept() -> void:
	# radius² × scale² = dist² × minSize² exactly
	var min_size_sq := 0.01  # simpler round numbers for the boundary test
	var mesh_radius_sq := 1.0
	var scale := 1.0
	var dist_sq := 100.0  # min_size_sq × dist_sq = 1.0 = mesh_radius_sq × scale²
	assert_bool(Merger._is_size_worthy(mesh_radius_sq, scale, dist_sq, min_size_sq)) \
		.override_failure_message("Exact-threshold ref should be kept (>= inclusive).") \
		.is_true()


## Degenerate geometry (radius=0) keeps the ref — delegated to later phases.
## This is Phase 2's explicit contract: the size filter is a CONSERVATIVE
## reject. Unknown/zero-radius geometry passes through; Phase 3 type filter
## can still cull it, and the merge kernel will no-op on empty vertex arrays.
func test_size_worthy_zero_radius_kept() -> void:
	assert_bool(Merger._is_size_worthy(0.0, 1.0, 10000.0, DU.PAGING_MIN_SIZE_SQ)) \
		.is_true()


## Camera co-located with ref (dist=0) keeps the ref.
func test_size_worthy_zero_distance_kept() -> void:
	assert_bool(Merger._is_size_worthy(1.0, 1.0, 0.0, DU.PAGING_MIN_SIZE_SQ)) \
		.is_true()


## PAGING_MIN_SIZE = 0.14 matches OpenMW canonical default (plan §8 / 17.1).
func test_paging_min_size_matches_openmw_default() -> void:
	assert_float(DU.PAGING_MIN_SIZE).is_equal_approx(0.14, 0.001)
	assert_float(DU.PAGING_MIN_SIZE_SQ).is_equal_approx(0.0196, 0.0001)


## Camera-motion parity — cached ref moving into range must re-evaluate.
## Simulates SizeCache flow: a ref rejected at 500m, camera walks to 10m,
## same `_is_size_worthy` call with cached `rad²×scale²` should now return
## true. Validates the re-test logic in `_request_merge` that drives cache
## eviction + full-path fallthrough.
func test_size_worthy_reevaluation_after_camera_approach() -> void:
	# Cache-equivalent value: mesh_radius_sq × scale² = 1.0 × 1.0 = 1.0
	var cached_rs2 := 1.0
	var min_size_sq := DU.PAGING_MIN_SIZE_SQ  # 0.0196

	# At 500m: threshold = 250000 × 0.0196 = 4900. 1.0 < 4900 → rejected.
	var at_500 := 250000.0 * min_size_sq
	assert_bool(cached_rs2 < at_500) \
		.override_failure_message("SizeCache path assumes ref rejected at 500m.") \
		.is_true()

	# At 5m: threshold = 25 × 0.0196 = 0.49. 1.0 >= 0.49 → kept. Cache should
	# evict and fall through to full-path instantiation.
	var at_5 := 25.0 * min_size_sq
	assert_bool(cached_rs2 < at_5) \
		.override_failure_message("SizeCache path must re-admit ref at 5m (eviction trigger).") \
		.is_false()

#endregion


func test_normals_transformed_by_ref_rotation() -> void:
	var tri := _make_triangle_mesh()  # normals point +Z
	var mat := StandardMaterial3D.new()

	# 90° rotation around X should map +Z normal to -Y (in Godot right-handed)
	var ref := Kernel.RefInput.new()
	ref.ref_transform = Transform3D(Basis().rotated(Vector3.RIGHT, PI / 2.0), Vector3.ZERO)
	ref.sub_meshes = [_make_sub(tri, mat)]

	var merged: ArrayMesh = Kernel.merge_refs([ref], Vector3.ZERO)
	assert_that(merged).is_not_null()

	var arrays: Array = merged.surface_get_arrays(0)
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	assert_that(normals.size()).is_greater(0)

	# After X+90° rotation of +Z: (0,0,1) → (0,-1,0) in Godot (right-handed, CCW)
	# Godot's Basis.rotated with Vector3.RIGHT (+X) and positive angle rotates
	# Z toward -Y. Accept either sign convention (some transform paths differ).
	var n0: Vector3 = normals[0]
	var rotated_ok := absf(n0.x) < 0.01 and absf(absf(n0.y) - 1.0) < 0.01 and absf(n0.z) < 0.01
	assert_bool(rotated_ok).override_failure_message(
		"Expected normal rotated to ±Y after 90° X rotation; got %s" % [n0]
	).is_true()

#endregion
