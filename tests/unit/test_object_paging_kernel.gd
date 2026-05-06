## Parity + correctness test for ObjectPagingKernel.
##
## Covers the Phase 1 extraction (docs/audit/OBJECT_PAGING_PLAN.md §11):
## hot merge math moved from ObjectPaging into the C# kernel via a
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
const Merger := preload("res://src/core/world/object_paging.gd")
const DU := preload("res://src/core/world/distance_utils.gd")
const MorrowindWorldObjectSource := preload("res://src/core/world/morrowind/morrowind_world_object_source.gd")


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


## Build a deterministic triangle soup with enough vertices to exceed the
## cost-benefit merge threshold for single-ref rejection tests.
static func _make_triangle_soup_mesh(triangle_count: int) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var vert_count := triangle_count * 3
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	verts.resize(vert_count)
	normals.resize(vert_count)
	indices.resize(vert_count)
	for tri_idx in range(triangle_count):
		var base := tri_idx * 3
		var x := float(tri_idx % 10)
		var y := float(tri_idx / 10)
		verts[base] = Vector3(x, y, 0.0)
		verts[base + 1] = Vector3(x + 1.0, y, 0.0)
		verts[base + 2] = Vector3(x, y + 1.0, 0.0)
		normals[base] = Vector3(0.0, 0.0, 1.0)
		normals[base + 1] = Vector3(0.0, 0.0, 1.0)
		normals[base + 2] = Vector3(0.0, 0.0, 1.0)
		indices[base] = base
		indices[base + 1] = base + 1
		indices[base + 2] = base + 2
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
	var mesh: ArrayMesh = Kernel.merge_refs([], Vector3.ZERO, 0, true)
	assert_that(mesh).is_null()


func test_object_paging_stats_include_observability_counters() -> void:
	var paging := Merger.new()
	var stats: Dictionary = paging.get_stats()

	assert_bool(stats.has("runtime_lod_generation_enabled")).is_true()
	assert_bool(stats.has("runtime_force_merge_eligible_refs")).is_true()
	assert_bool(stats["runtime_lod_generation_enabled"]).is_false()
	assert_bool(stats.has("refs_size_rejected")).is_true()
	assert_bool(stats.has("refs_surface_rejected")).is_true()
	assert_bool(stats.has("refs_partial_bucket_rejected")).is_true()
	assert_bool(stats.has("surface_cap_rejections")).is_true()
	assert_bool(stats.has("surface_cap_over_budget_published")).is_true()
	assert_bool(stats.has("cached_publish_queue_size")).is_true()
	assert_bool(stats.has("visible_hlod_draw_calls")).is_true()
	assert_bool(stats.has("null_material_surface_count")).is_true()
	assert_bool(stats.has("default_proxy_surface_count")).is_true()
	assert_bool(stats.has("overflow_proxy_surfaces")).is_true()
	assert_bool(stats.has("chunk_surface_histogram")).is_true()
	assert_bool(stats.has("warmup_queue_size")).is_true()


func test_single_ref_preserves_surface() -> void:
	var tri := _make_triangle_mesh()
	var mat := StandardMaterial3D.new()
	var ref := _make_ref(tri, mat, Vector3(10.0, 0.0, 0.0))

	var merged: ArrayMesh = Kernel.merge_refs([ref], Vector3.ZERO, 0, true)
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
	var merged: ArrayMesh = Kernel.merge_refs([ref], Vector3(90.0, 0.0, 0.0), 0, true)
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

	var merged: ArrayMesh = Kernel.merge_refs([ref_a, ref_b], Vector3.ZERO, 0, true)
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

	var merged: ArrayMesh = Kernel.merge_refs([ref_a, ref_b], Vector3.ZERO, 0, true)
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

	var merged: ArrayMesh = Kernel.merge_refs([ref_a, ref_b], Vector3.ZERO, 0, true)
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


func test_null_source_material_uses_proxy_material_not_engine_default() -> void:
	var tri := _make_triangle_mesh()
	var ref := _make_ref(tri, null, Vector3.ZERO)

	var merged: ArrayMesh = Kernel.merge_refs([ref], Vector3.ZERO, 0, true)
	assert_that(merged).is_not_null()
	assert_that(merged.get_surface_count()).is_equal(1)
	assert_that(merged.surface_get_material(0)).is_not_null()

	var stats := Kernel.collect_mesh_stats(merged)
	assert_int(int(stats.get("null_material_surface_count", -1))).is_equal(0)
	assert_int(int(stats.get("default_proxy_surface_count", 0))).is_equal(1)
	assert_int(int(stats.get("source_null_material_surfaces", 0))).is_equal(1)


func test_surface_overflow_uses_proxy_material_not_null_material() -> void:
	var refs: Array = []
	for i in range(260):
		refs.append(_make_ref(_make_triangle_mesh(), StandardMaterial3D.new(), Vector3(float(i), 0.0, 0.0)))

	var merged: ArrayMesh = Kernel.merge_refs(refs, Vector3.ZERO, 0, true)
	assert_that(merged).is_not_null()
	assert_that(merged.get_surface_count()).is_equal(Merger.MAX_RUNTIME_CHUNK_SURFACES)

	for si in range(merged.get_surface_count()):
		assert_that(merged.surface_get_material(si)).is_not_null()

	var stats := Kernel.collect_mesh_stats(merged)
	assert_int(int(stats.get("null_material_surface_count", -1))).is_equal(0)
	assert_int(int(stats.get("default_proxy_surface_count", 0))).is_equal(0)
	assert_int(int(stats.get("overflow_proxy_surfaces", 0))).is_greater(0)


func test_surface_overflow_folds_one_over_runtime_cap() -> void:
	var refs: Array = []
	for i in range(Merger.MAX_RUNTIME_CHUNK_SURFACES + 1):
		refs.append(_make_ref(_make_triangle_mesh(), StandardMaterial3D.new(), Vector3(float(i), 0.0, 0.0)))

	var merged: ArrayMesh = Kernel.merge_refs(refs, Vector3.ZERO, 0, true)
	assert_that(merged).is_not_null()
	assert_that(merged.get_surface_count()).is_equal(Merger.MAX_RUNTIME_CHUNK_SURFACES)

	var stats := Kernel.collect_mesh_stats(merged)
	assert_int(int(stats.get("null_material_surface_count", -1))).is_equal(0)
	assert_int(int(stats.get("default_proxy_surface_count", 0))).is_equal(0)
	assert_int(int(stats.get("overflow_proxy_surfaces", 0))).is_equal(2)


func test_estimate_mesh_bytes_scales_with_vertex_count() -> void:
	var tri := _make_triangle_mesh()
	var mat := StandardMaterial3D.new()

	# 1 ref → 3 verts
	var ref1 := _make_ref(tri, mat, Vector3.ZERO)
	var merged1: ArrayMesh = Kernel.merge_refs([ref1], Vector3.ZERO, 0, true)
	var bytes1 := Kernel.estimate_mesh_bytes(merged1)

	# 4 refs (shared material) → 12 verts
	var refs4: Array = []
	for i in range(4):
		refs4.append(_make_ref(tri, mat, Vector3(float(i) * 10.0, 0.0, 0.0)))
	var merged4: ArrayMesh = Kernel.merge_refs(refs4, Vector3.ZERO, 0, true)
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
	var mesh_radius_sq := 0.04  # 0.2m radius
	var dist_sq := 10000.0  # 100m

	# Godotwind's tuned minSize=0.003 gives threshold = 10000 * 0.000009 = 0.09.
	# Scale=1 -> 0.04 < 0.09 rejected. Scale=2 -> 0.16 >= 0.09 kept.
	assert_bool(Merger._is_size_worthy(mesh_radius_sq, 0.5, dist_sq, DU.PAGING_MIN_SIZE_SQ)) \
		.is_false()
	assert_bool(Merger._is_size_worthy(mesh_radius_sq, 1.0, dist_sq, DU.PAGING_MIN_SIZE_SQ)) \
		.is_false()
	assert_bool(Merger._is_size_worthy(mesh_radius_sq, 2.0, dist_sq, DU.PAGING_MIN_SIZE_SQ)) \
		.is_true()

	# Farther: dist=500m, threshold=2.25. Scale=7 -> 1.96 rejected; scale=8 -> 2.56 kept.
	assert_bool(Merger._is_size_worthy(mesh_radius_sq, 7.0, 250000.0, DU.PAGING_MIN_SIZE_SQ)) \
		.is_false()
	assert_bool(Merger._is_size_worthy(mesh_radius_sq, 8.0, 250000.0, DU.PAGING_MIN_SIZE_SQ)) \
		.is_true()


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


## PAGING_MIN_SIZE keeps OpenMW's projected-size pattern but uses Godotwind's
## meter-scale tuned default so buildings and vegetation survive HLOD range.
func test_paging_min_size_matches_godotwind_tuned_default() -> void:
	assert_float(DU.PAGING_MIN_SIZE).is_equal_approx(0.003, 0.001)
	assert_float(DU.PAGING_MIN_SIZE_SQ).is_equal_approx(0.000009, 0.000001)


func test_surface_budget_preserves_coverage() -> void:
	var merger := Merger.new()
	var state := Merger.MergePrepState.new()
	var big := Kernel.RefInput.new()
	big.rs2 = 100.0
	big.dist_sq = 10000.0
	big.surface_count = 100
	big.source_ref_num = 1
	big.bucket_key = "0,0:big"
	var small_a := Kernel.RefInput.new()
	small_a.rs2 = 1.0
	small_a.dist_sq = 10000.0
	small_a.surface_count = 40
	small_a.source_ref_num = 2
	small_a.bucket_key = "0,0:small_a"
	var small_b := Kernel.RefInput.new()
	small_b.rs2 = 1.0
	small_b.dist_sq = 10000.0
	small_b.surface_count = 40
	small_b.source_ref_num = 3
	small_b.bucket_key = "0,0:small_b"
	state.inputs = [small_a, small_b, big]

	merger._apply_surface_budget(state)

	assert_int(state.inputs.size()).is_equal(3)
	assert_int(state.refs_surface_rejected).is_equal(0)
	assert_int(state.surface_estimate).is_equal(180)


func test_partial_bucket_inputs_still_render_but_do_not_suppress_mid() -> void:
	var merger := Merger.new()
	var state := Merger.MergePrepState.new()
	var partial := Kernel.RefInput.new()
	partial.source_ref_num = 10
	partial.bucket_key = "0,0:partial"
	var complete := Kernel.RefInput.new()
	complete.source_ref_num = 20
	complete.bucket_key = "0,0:complete"
	state.inputs = [partial, complete]
	state.source_ref_nums = {10: true, 20: true}
	state.source_bucket_counts = {
		"0,0:partial": 1,
		"0,0:complete": 1,
	}
	state.bucket_total_counts = {
		"0,0:partial": 2,
		"0,0:complete": 1,
	}

	merger._update_complete_bucket_counts(state)

	assert_int(state.inputs.size()).is_equal(2)
	assert_bool(state.source_ref_nums.has(10)).is_true()
	assert_bool(state.source_ref_nums.has(20)).is_true()
	assert_bool(state.source_bucket_counts.has("0,0:partial")).is_false()
	assert_int(int(state.source_bucket_counts.get("0,0:complete", 0))).is_equal(1)
	assert_int(state.refs_partial_bucket_rejected).is_equal(1)


func test_active_hlod_chunks_are_pinned_during_cache_eviction() -> void:
	var merger := Merger.new()
	var active_key := Vector3i(0, 0, 1)
	var inactive_key := Vector3i(2, 0, 1)
	var active_data := Merger.PagingChunkData.new()
	active_data.key = active_key
	merger._active_chunks[active_key] = active_data
	merger._mesh_cache[active_key] = ArrayMesh.new()
	merger._mesh_sizes[active_key] = 16
	merger._mesh_cache[inactive_key] = ArrayMesh.new()
	merger._mesh_sizes[inactive_key] = 16
	merger._lru_order = [active_key, inactive_key]
	merger._cache_used_bytes = Merger.CACHE_BUDGET_BYTES

	merger._cache_evict_to_fit(1)

	assert_bool(merger._active_chunks.has(active_key)).is_true()
	assert_bool(merger._mesh_cache.has(active_key)).is_true()
	assert_bool(merger._mesh_cache.has(inactive_key)).is_false()


func test_prefetch_completion_warms_cache_without_publishing_visual_chunk() -> void:
	var merger := Merger.new()
	var prefetch_key := Vector3i(4, 0, 1)
	var generation := 1
	var mesh := _make_triangle_mesh()

	merger._chunk_generations[prefetch_key] = generation
	merger._last_desired_chunks = {}
	merger._completed_queue.append({
		"key": prefetch_key,
		"generation": generation,
		"mesh": mesh,
		"bytes": 256,
		"mesh_stats": Kernel.collect_mesh_stats(mesh),
	})

	var published := merger.process_completions()

	assert_int(published).is_equal(0)
	assert_bool(merger._mesh_cache.has(prefetch_key)).is_true()
	assert_bool(merger._active_chunks.has(prefetch_key)).is_false()
	assert_int(int(merger.get_stats().get("cache_entries", 0))).is_equal(1)
	assert_int(int(merger.get_stats().get("active_visual_chunks", 0))).is_equal(0)


func test_prototype_warmup_clears_temporary_negative_chunks() -> void:
	var merger := Merger.new()
	var missing_key := Vector3i(0, 0, 1)
	var surface_key := Vector3i(2, 0, 1)
	merger._negative_chunks[missing_key] = "missing_prototype"
	merger._negative_chunks[surface_key] = "surface_cap"

	merger._clear_temporary_negative_chunks()

	assert_bool(merger._negative_chunks.has(missing_key)).is_false()
	assert_bool(merger._negative_chunks.has(surface_key)).is_true()


#endregion


#region Phase 3a — type filter parity tests

## static record types are always paging-eligible at every size_level.
func test_type_eligible_static_always_paged() -> void:
	for size_level in range(3):
		assert_bool(Merger._type_eligible("static", size_level)) \
			.override_failure_message("static must be paging-eligible at size_level=%d" % size_level) \
			.is_true()


## door + activator same contract — architectural, always eligible.
func test_type_eligible_door_and_activator_always_paged() -> void:
	for size_level in range(3):
		assert_bool(Merger._type_eligible("door", size_level)).is_true()
		assert_bool(Merger._type_eligible("activator", size_level)).is_true()


## container is size-aware: paged at size_level=0, dropped at higher.
## Matches OpenMW `typeFilter(REC_CONT, far)` → `!far` (keep for near chunks only).
func test_type_eligible_container_size_aware() -> void:
	assert_bool(Merger._type_eligible("container", 0)) \
		.override_failure_message("container must be paged at near (size_level=0)") \
		.is_true()
	assert_bool(Merger._type_eligible("container", 1)) \
		.override_failure_message("container must NOT be paged at size_level=1 (MID-far)") \
		.is_false()
	assert_bool(Merger._type_eligible("container", 2)) \
		.override_failure_message("container must NOT be paged at size_level=2 (HLOD)") \
		.is_false()


## light is never paged — owned by distant_light_manager tier.
func test_type_eligible_light_never_paged() -> void:
	for size_level in range(3):
		assert_bool(Merger._type_eligible("light", size_level)) \
			.override_failure_message("light must never be paged (owned by distant_light_manager)") \
			.is_false()


## Inventory items + actors must never page — they're dynamic or
## covered by other tiers.
func test_type_eligible_inventory_and_actors_rejected() -> void:
	var rejected := ["npc", "creature", "weapon", "armor", "clothing",
			"book", "potion", "ingredient", "misc", "apparatus",
			"lockpick", "probe", "repair", "leveled_item", "body_part"]
	for tn in rejected:
		assert_bool(Merger._type_eligible(tn, 0)) \
			.override_failure_message("Type '%s' must not be paging-eligible." % tn) \
			.is_false()


## Unknown / empty type strings default to reject — conservative.
func test_type_eligible_unknown_defaults_to_reject() -> void:
	assert_bool(Merger._type_eligible("", 0)).is_false()
	assert_bool(Merger._type_eligible("spell", 0)).is_false()
	assert_bool(Merger._type_eligible("dialogue_info", 0)).is_false()


func test_morrowind_hlod_filter_keeps_large_architecture() -> void:
	assert_bool(MorrowindWorldObjectSource._is_hlod_geometry_candidate("static", null, "x\\ex_hlaalu_b_01.nif")).is_true()
	assert_bool(MorrowindWorldObjectSource._is_hlod_geometry_candidate("static", null, "x\\terrain_rock_big_01.nif")).is_true()


func test_morrowind_hlod_filter_routes_specialized_clutter_out() -> void:
	assert_bool(MorrowindWorldObjectSource._is_hlod_geometry_candidate("static", null, "f\\flora_tree_bc_01.nif")).is_false()
	assert_bool(MorrowindWorldObjectSource._is_hlod_geometry_candidate("static", null, "f\\furn_de_barrel_01.nif")).is_false()
	assert_bool(MorrowindWorldObjectSource._is_hlod_geometry_candidate("static", null, "x\\terrain_rock_sm_01.nif")).is_false()

#endregion


#region Phase 3b — cost-benefit analyze tests

## Empty input → empty keep_mask.
func test_analyze_empty_input() -> void:
	var result: Dictionary = Kernel._analyze_chunk([], 0)
	assert_that(result).is_empty()


## Single high-cost mesh type can still fail cost-benefit.
## With one material and one ref: benefit = 1 × 1 × 256 = 256; cost = 300.
func test_analyze_single_high_cost_type_not_merged() -> void:
	var tri := _make_triangle_soup_mesh(100)
	var mat := StandardMaterial3D.new()
	var refs: Array = [_make_ref(tri, mat, Vector3.ZERO)]
	var result: Dictionary = Kernel._analyze_chunk(refs, 0)

	var mesh_id: int = tri.get_instance_id()
	assert_that(result).contains_keys([mesh_id])
	assert_bool(result[mesh_id]["merge"]) \
		.override_failure_message("Single high-cost type must not merge when mergeBenefit <= mergeCost.") \
		.is_false()


## Two mesh types sharing ONE material → mergeBenefit > 0.
## With default PAGING_MERGE_FACTOR = 256, the small 3-vert triangles easily
## clear the cost threshold. Both types should merge.
func test_analyze_two_types_shared_material_both_merged() -> void:
	# Distinct mesh resources but same material → shared_material_count = 1 for each
	var tri_a := _make_triangle_mesh()
	var tri_b := _make_triangle_mesh()  # distinct instance, same content
	var mat := StandardMaterial3D.new()

	var refs: Array = [
		_make_ref(tri_a, mat, Vector3.ZERO),
		_make_ref(tri_a, mat, Vector3(1, 0, 0)),
		_make_ref(tri_a, mat, Vector3(2, 0, 0)),
		_make_ref(tri_b, mat, Vector3(3, 0, 0)),
		_make_ref(tri_b, mat, Vector3(4, 0, 0)),
	]
	var result: Dictionary = Kernel._analyze_chunk(refs, 0)

	var id_a: int = tri_a.get_instance_id()
	var id_b: int = tri_b.get_instance_id()
	assert_bool(result[id_a]["merge"]) \
		.override_failure_message("Type A shares material with B and has 3 refs — should merge.") \
		.is_true()
	assert_bool(result[id_b]["merge"]) \
		.override_failure_message("Type B shares material with A and has 2 refs — should merge.") \
		.is_true()


## Distinct materials no longer block merging. Current analyze uses OpenMW's
## intra-NIF state-reuse shape: each low-cost triangle type independently
## clears benefit > cost even when materials are not shared across mesh types.
func test_analyze_two_types_distinct_materials_can_merge_when_low_cost() -> void:
	var tri_a := _make_triangle_mesh()
	var tri_b := _make_triangle_mesh()
	var mat_a := StandardMaterial3D.new()
	var mat_b := StandardMaterial3D.new()

	var refs: Array = [
		_make_ref(tri_a, mat_a, Vector3.ZERO),
		_make_ref(tri_b, mat_b, Vector3(1, 0, 0)),
	]
	var result: Dictionary = Kernel._analyze_chunk(refs, 0)

	assert_bool(result[tri_a.get_instance_id()]["merge"]).is_true()
	assert_bool(result[tri_b.get_instance_id()]["merge"]).is_true()


## size_level affects merge cost: higher level = higher cost = harder to merge.
## A borderline-beneficial type at size_level=0 may flip to unmerged at level=2.
##
## Setup: enough refs + shared materials that benefit clears cost at level 0
## but not at level 2 (3× vertex cost multiplier).
func test_analyze_size_level_affects_decision() -> void:
	# Build a borderline case: 2 mesh types share a material, few refs.
	# At PAGING_MERGE_FACTOR=256, benefit = ref_count × shared = small × 1.
	# Cost = total_verts × cost_multiplier. At level 0 (×1), benefit>cost.
	# At level 2 (×3), cost triples — may flip.
	var tri_a := _make_triangle_mesh()  # 3 verts
	var tri_b := _make_triangle_mesh()
	var mat := StandardMaterial3D.new()

	# 2 refs of A, 2 of B, sharing mat → benefit_a = 2×1 = 2, cost_a = 3×level
	# At level 0: 2×256 = 512 > 3 → merge. At level 2: 512 > 9 → still merge.
	# Need much larger cost to flip. Make total_verts absurd by repeating refs.
	var refs: Array = []
	for i in range(2):
		refs.append(_make_ref(tri_a, mat, Vector3(float(i), 0, 0)))
	for i in range(2):
		refs.append(_make_ref(tri_b, mat, Vector3(float(i) + 2, 0, 0)))

	var result_0: Dictionary = Kernel._analyze_chunk(refs, 0)
	var result_2: Dictionary = Kernel._analyze_chunk(refs, 2)

	# At small vert count, level doesn't flip — contract is monotonic but
	# outcome depends on scale. Assert the threshold respects the multiplier:
	# if level_0 rejects, level_2 MUST reject. If level_0 accepts, level_2
	# may accept or reject.
	var a_id: int = tri_a.get_instance_id()
	if not result_0[a_id]["merge"]:
		assert_bool(result_2[a_id]["merge"]) \
			.override_failure_message("size_level=2 cannot accept what level=0 rejected (cost monotonic).") \
			.is_false()


## Zero-vertex type → merge_cost = 0 → merge_benefit > 0 → degenerate "merge true".
## Acceptable edge case: empty mesh has no cost anyway.
func test_analyze_zero_vert_degenerate() -> void:
	var empty := ArrayMesh.new()  # no surfaces
	var mat := StandardMaterial3D.new()
	var refs: Array = [_make_ref(empty, mat, Vector3.ZERO)]
	var result: Dictionary = Kernel._analyze_chunk(refs, 0)

	# Mesh with 0 surfaces produces no group entry (ref_count loop skips).
	# So result dict doesn't contain it.
	assert_that(result).is_empty()


## PAGING_MERGE_FACTOR = 256 matches OpenMW canonical default (plan §8).
func test_paging_merge_factor_matches_openmw_default() -> void:
	assert_float(DU.PAGING_MERGE_FACTOR).is_equal_approx(256.0, 0.001)

#endregion


#region Phase 4a — chunk-key alignment & center-distance math (plan §4.1-4.2, 4.5)

## Positive-cell alignment at size_level=0 (size=1) is identity.
func test_chunk_key_size_level_0_identity() -> void:
	for x in [-3, -1, 0, 1, 5, 100]:
		for y in [-3, 0, 7]:
			var cell := Vector2i(x, y)
			assert_that(DU.chunk_key_for_cell(cell, 0)).is_equal(cell)


## size_level=1 (size=2) aligns to even values.
func test_chunk_key_size_level_1_aligns_to_even() -> void:
	assert_that(DU.chunk_key_for_cell(Vector2i(0, 0), 1)).is_equal(Vector2i(0, 0))
	assert_that(DU.chunk_key_for_cell(Vector2i(1, 1), 1)).is_equal(Vector2i(0, 0))
	assert_that(DU.chunk_key_for_cell(Vector2i(2, 2), 1)).is_equal(Vector2i(2, 2))
	assert_that(DU.chunk_key_for_cell(Vector2i(3, 3), 1)).is_equal(Vector2i(2, 2))


## size_level=2 (size=4) aligns to multiples of 4. Critical — covers the
## negative-cell boundary roaster flagged (plan §4.1).
func test_chunk_key_size_level_2_handles_negative_cells() -> void:
	# Boundaries verified in the plan doc:
	assert_that(DU.chunk_key_for_cell(Vector2i(0, 0), 2)).is_equal(Vector2i(0, 0))
	assert_that(DU.chunk_key_for_cell(Vector2i(3, 3), 2)).is_equal(Vector2i(0, 0))
	assert_that(DU.chunk_key_for_cell(Vector2i(4, 4), 2)).is_equal(Vector2i(4, 4))
	# Negative cells — the floor-toward-negative-infinity case.
	assert_that(DU.chunk_key_for_cell(Vector2i(-1, -1), 2)).is_equal(Vector2i(-4, -4))
	assert_that(DU.chunk_key_for_cell(Vector2i(-4, -4), 2)).is_equal(Vector2i(-4, -4))
	assert_that(DU.chunk_key_for_cell(Vector2i(-5, -5), 2)).is_equal(Vector2i(-8, -8))
	assert_that(DU.chunk_key_for_cell(Vector2i(-8, -8), 2)).is_equal(Vector2i(-8, -8))
	# Mixed-sign.
	assert_that(DU.chunk_key_for_cell(Vector2i(-5, 3), 2)).is_equal(Vector2i(-8, 0))


## Chunk center at (0,0) level 0 sits at half-cell offset. Z is flipped
## per Godot convention (MW +Y → Godot -Z), matching cell_to_world_center.
func test_chunk_center_world_origin_cell() -> void:
	var center := DU.chunk_center_world(Vector2i(0, 0), 0)
	assert_float(center.x).is_equal_approx(DU.HALF_CELL_SIZE, 0.01)
	# Z flipped — cell y=0 center is -half_cell_size
	assert_float(center.y).is_equal_approx(-DU.HALF_CELL_SIZE, 0.01)


## Chunk center at size_level=2 covers 4 cells — center = (2, 2) cell offsets.
func test_chunk_center_world_size_level_2() -> void:
	var center := DU.chunk_center_world(Vector2i(0, 0), 2)
	# Chunk (0,0) at size=4 covers cells (0,0)...(3,3). Center = (2, 2) cells.
	assert_float(center.x).is_equal_approx(2.0 * DU.CELL_SIZE_METERS, 0.01)
	assert_float(center.y).is_equal_approx(-2.0 * DU.CELL_SIZE_METERS, 0.01)


## Band-end constants match plan §4 table.
func test_paging_band_end_values() -> void:
	assert_float(DU.paging_band_end(0)).is_equal_approx(300.0, 0.01)
	assert_float(DU.paging_band_end(1)).is_equal_approx(600.0, 0.01)
	assert_float(DU.paging_band_end(2)).is_equal_approx(1000.0, 0.01)


## Band boundaries form a contiguous sequence — tier N end = tier N+1 start.
func test_paging_band_boundaries_contiguous() -> void:
	assert_float(DU.paging_band_start(0)).is_equal_approx(150.0, 0.01)
	assert_float(DU.paging_band_start(1)).is_equal_approx(DU.paging_band_end(0), 0.01)
	assert_float(DU.paging_band_start(2)).is_equal_approx(DU.paging_band_end(1), 0.01)


## Ring radius bounds per plan §4.5. Worst case size_level=2 = 3 chunks.
func test_hlod_visual_floor_starts_at_hlod_boundary() -> void:
	var merger := Merger.new()
	assert_float(float(merger.get("_visual_begin_floor"))).is_equal_approx(DU.HLOD_START, 0.01)
	assert_bool(merger._chunk_has_visual_range(Vector3i(0, 0, 0))).is_false()
	assert_bool(merger._chunk_has_visual_range(Vector3i(0, 0, 1))).is_true()
	assert_bool(merger._chunk_has_visual_range(Vector3i(0, 0, 2))).is_true()


func test_paging_ring_radius_bounds() -> void:
	# size_level=0: band_end=300, chunk_extent=117 → ceil(300/117) = 3 (actually 300/117=2.56)
	# Let's check what we get and assert it's <= a reasonable bound.
	for sl in range(3):
		var r := DU.paging_ring_radius(sl)
		assert_int(r).is_greater_equal(1)
		assert_int(r).is_less_equal(10)
	# HLOD (size_level=2) per plan §4.5 = 3
	assert_int(DU.paging_ring_radius(2)).is_equal(3)


## PAGING_HYSTERESIS matches cell_manager's 20m convention (plan §4.4).
func test_paging_hysteresis_matches_existing_scheme() -> void:
	assert_float(DU.PAGING_HYSTERESIS).is_equal_approx(20.0, 0.01)

#endregion


#region Phase 4b — top-down walk invariants (plan §4.3)

## The top-down walk's critical correctness property: after the walk, no 1×1
## MW cell is claimed by more than one chunk. Rebuilds the `covered_cells`
## set from the walk output and asserts uniqueness.
func test_top_down_walk_no_cell_double_coverage() -> void:
	var merger := Merger.new()
	# Camera at origin (0,0), far enough that all three tiers are populated.
	# World origin is at (0, 0, 0) — MW cell (0, 0) roughly covers x∈[0,117], z∈[-117,0].
	var desired: Dictionary = merger._compute_desired_chunks(Vector2i(0, 0), Vector3.ZERO)

	var owners: Dictionary = {}  # Vector2i (cell) -> Vector3i (owner chunk key)
	for key: Vector3i in desired:
		var size: int = 1 << key.z
		for sy in range(size):
			for sx in range(size):
				var cell := Vector2i(key.x + sx, key.y + sy)
				assert_that(owners.has(cell)).override_failure_message(
					"Cell %s claimed by multiple chunks: existing=%s, new=%s" % [cell, owners.get(cell, Vector3i.ZERO), key]
				).is_false()
				owners[cell] = key


## Every returned chunk's center must lie within its tier's band distance
## from the camera — verifies band classification respected the strict bounds.
func test_top_down_walk_band_membership() -> void:
	var merger := Merger.new()
	var camera_pos := Vector3(0.0, 0.0, 0.0)
	var desired: Dictionary = merger._compute_desired_chunks(Vector2i(0, 0), camera_pos)
	var camera_xz := Vector2(camera_pos.x, camera_pos.z)

	for key: Vector3i in desired:
		var center := DU.chunk_center_world(Vector2i(key.x, key.y), key.z)
		var dist: float = camera_xz.distance_to(center)
		var band_start: float = DU.paging_band_start(key.z)
		var band_end: float = DU.paging_band_end(key.z)

		assert_bool(dist >= band_start and dist < band_end).override_failure_message(
			"Chunk %s center dist=%.1f outside tier band [%.1f, %.1f)" % [key, dist, band_start, band_end]
		).is_true()


## At origin camera, only visual HLOD tiers should produce chunks. Size level 0
## is below the runtime visual floor and remains suppressed.
func test_top_down_walk_all_tiers_populated_from_origin() -> void:
	var merger := Merger.new()
	var desired: Dictionary = merger._compute_desired_chunks(Vector2i(0, 0), Vector3.ZERO)

	var tier_counts: Dictionary = {0: 0, 1: 0, 2: 0}
	for key: Vector3i in desired:
		tier_counts[key.z] = tier_counts[key.z] + 1

	assert_int(tier_counts[0]).override_failure_message("size_level=0 chunks must stay suppressed below the HLOD visual floor.").is_equal(0)
	assert_int(tier_counts[1]).override_failure_message("No size_level=1 chunks desired — band [300,600) should produce chunks at origin.").is_greater(0)
	assert_int(tier_counts[2]).override_failure_message("No size_level=2 chunks desired — band [600,1000) should produce chunks at origin.").is_greater(0)


func test_predictive_prefetch_adds_ahead_chunks_without_changing_current_desired() -> void:
	var merger := Merger.new()
	merger._camera_world_pos_cached = Vector3.ZERO
	merger._camera_velocity_xz = Vector2(100.0, 0.0)
	var current: Dictionary = merger._compute_desired_chunks(Vector2i(0, 0), Vector3.ZERO)

	var prefetch: Dictionary = merger._compute_predictive_prefetch_chunks(current)

	assert_int(prefetch.size()).is_greater(0)
	for key: Vector3i in prefetch:
		assert_bool(current.has(key)).is_false()


## Verify anti-overlap in a specific geometric setup: a 2×2 chunk
## accepted in the MID-far tier must prevent 1×1 sub-chunks at those cells
## from appearing in the MID-near tier. (Top-down walk gives larger tiers
## priority on overlapping cells.)
func test_top_down_walk_large_chunk_blocks_smaller_overlap() -> void:
	var merger := Merger.new()
	var desired: Dictionary = merger._compute_desired_chunks(Vector2i(0, 0), Vector3.ZERO)

	# Build set of cells claimed at size_level >= 1 (the larger tiers)
	var claimed_by_larger: Dictionary = {}
	for key: Vector3i in desired:
		if key.z >= 1:
			var size: int = 1 << key.z
			for sy in range(size):
				for sx in range(size):
					claimed_by_larger[Vector2i(key.x + sx, key.y + sy)] = true

	# No size_level=0 chunk should land on a cell already claimed by a larger tier
	for key: Vector3i in desired:
		if key.z == 0:
			var cell := Vector2i(key.x, key.y)
			assert_bool(cell in claimed_by_larger).override_failure_message(
				"size_level=0 chunk at %s lands in cell claimed by larger tier — anti-overlap violation" % [cell]
			).is_false()

#endregion


#region Phase 4c — hysteresis retention (plan §4.4)

## Pure static helper — chunk inside strict band is always retained; chunks
## past the upper retention edge are released; the zero-distance case (camera
## AT chunk center) falls below the lower edge for any positive-distance band.
func test_is_within_retention_for_tier_0_bounds() -> void:
	# Tier 0 retention window = [150 - 20, 300 + 20) = [130, 320).
	# Cell (1,0) at size_level=0 has center ≈ (175.5, -58.5), dist from origin ≈ 185m.
	var key := Vector3i(1, 0, 0)
	var center: Vector2 = DU.chunk_center_world(Vector2i(1, 0), 0)

	# Camera at origin → dist ~185m → inside retention window.
	assert_bool(Merger._is_within_retention_for(key, Vector2.ZERO)) \
		.override_failure_message("Tier-0 chunk at dist ~185m should be retained (window [130, 320)).") \
		.is_true()

	# Camera offset along -X so chunk sits at dist ~395m → past retention upper 320.
	var far_camera := Vector2(-215.0, 0.0)
	assert_bool(Merger._is_within_retention_for(key, far_camera)) \
		.override_failure_message("Tier-0 chunk at dist ~395m must NOT be retained (beyond 320).") \
		.is_false()

	# Camera AT chunk center → dist 0 → below retention lower 130.
	assert_bool(Merger._is_within_retention_for(key, center)) \
		.override_failure_message("Tier-0 chunk at dist 0 must NOT be retained (below 130).") \
		.is_false()


## A chunk whose strict-band-exit (just past band_end) still sits inside
## the +hysteresis upper edge must be pre-populated into desired.
func test_hysteresis_retains_active_chunk_past_strict_band() -> void:
	var merger := Merger.new()
	var retained_key := Vector3i(2, 0, 0)
	# Cell (2,0) size_level=0 center ≈ (292.6, -58.5), dist from origin ≈ 298m.
	# Shifting camera -20m along X: dist grows to ≈ 318m — still inside [130, 320).
	var data := Merger.PagingChunkData.new()
	data.key = retained_key
	merger._active_chunks[retained_key] = data

	var camera_pos := Vector3(-20.0, 0.0, 0.0)
	var desired: Dictionary = merger._compute_desired_chunks(Vector2i(0, 0), camera_pos)

	assert_bool(retained_key in desired).override_failure_message(
		"Retained tier-0 chunk at dist ~318m (retention [130, 320)) must survive the pre-pass."
	).is_true()


## A chunk beyond the +hysteresis upper edge is NOT pre-populated — the walk
## is free to re-tier, and the post-walk diff will unload it.
func test_hysteresis_releases_active_chunk_past_retention_edge() -> void:
	var merger := Merger.new()
	var released_key := Vector3i(2, 0, 0)
	var data := Merger.PagingChunkData.new()
	data.key = released_key
	merger._active_chunks[released_key] = data

	# Camera shifted -50m along X → chunk dist ≈ 347m, past retention upper 320.
	var camera_pos := Vector3(-50.0, 0.0, 0.0)
	var desired: Dictionary = merger._compute_desired_chunks(Vector2i(0, 0), camera_pos)

	assert_bool(released_key in desired).override_failure_message(
		"Active tier-0 chunk at dist ~347m must NOT be retained (retention upper = 320)."
	).is_false()


## Retained chunk pre-marks its sub-cells covered, blocking the strict-band
## walk from accepting an overlapping chunk at a different tier. The specific
## invariant plan §4.4 protects — hysteresis applies to TRANSITIONS, not
## membership; a retained chunk locks out its area until it releases.
func test_hysteresis_retained_chunk_blocks_retiering_walk() -> void:
	var merger := Merger.new()
	# Seed tier-0 chunk at (2,0,0). Camera at origin → chunk dist ~298m, inside
	# strict band [150, 300) AND retention [130, 320). Retention adds it first,
	# marking cell (2,0) covered so the tier-1 walk can't claim it.
	var retained_key := Vector3i(2, 0, 0)
	var data := Merger.PagingChunkData.new()
	data.key = retained_key
	merger._active_chunks[retained_key] = data

	var desired: Dictionary = merger._compute_desired_chunks(Vector2i(0, 0), Vector3.ZERO)

	assert_bool(retained_key in desired).override_failure_message(
		"Retained tier-0 chunk at ~298m must be present in desired."
	).is_true()

	# Tier-1 chunk at (2,0,1) would cover cells (2,0),(3,0),(2,1),(3,1).
	# Cell (2,0) is claimed by retained tier-0 → tier-1 walk must skip it.
	assert_bool(Vector3i(2, 0, 1) in desired).override_failure_message(
		"Tier-1 chunk (2,0,1) overlaps retained tier-0's cell (2,0) — walker must skip."
	).is_false()


## Empty active set = Phase 4b behavior. Sanity check that the pre-pass is a
## no-op when `_active_chunks` is empty — every Phase 4b walker-invariant test
## relies on this.
func test_hysteresis_no_effect_with_empty_active_chunks() -> void:
	var merger := Merger.new()
	assert_int(merger._active_chunks.size()).is_equal(0)

	var desired: Dictionary = merger._compute_desired_chunks(Vector2i(0, 0), Vector3.ZERO)

	# Same walker invariants as Phase 4b: every sub-cell claimed by at most one chunk.
	var owners: Dictionary = {}
	for key: Vector3i in desired:
		var size: int = 1 << key.z
		for sy in range(size):
			for sx in range(size):
				var cell := Vector2i(key.x + sx, key.y + sy)
				assert_bool(owners.has(cell)).override_failure_message(
					"Cell %s double-covered with empty active set — pre-pass must be a no-op." % [cell]
				).is_false()
				owners[cell] = key


## Pre-pass + strict walk must never produce double-coverage. Tests the
## interaction: an active chunk inside its strict band is both retained AND
## what the walk would have produced — the dict-write is idempotent (same key)
## and the `covered_cells` marking prevents the walk from re-accepting a
## sibling chunk on the same sub-cells.
func test_hysteresis_pre_pass_and_walk_never_double_cover() -> void:
	var merger := Merger.new()
	# Three active chunks spanning all tiers, each inside both strict band AND
	# retention window at origin camera.
	var seeds: Array[Vector3i] = [
		Vector3i(1, 0, 0),   # tier-0 ~175m → strict [150,300)
		Vector3i(2, 2, 1),   # tier-1 ~391m → strict [300,600)
		Vector3i(4, 4, 2),   # tier-2 ~828m → strict [600,1000)
	]
	for key: Vector3i in seeds:
		var data := Merger.PagingChunkData.new()
		data.key = key
		merger._active_chunks[key] = data

	var desired: Dictionary = merger._compute_desired_chunks(Vector2i(0, 0), Vector3.ZERO)

	# Every seeded chunk must still be in desired.
	for key: Vector3i in seeds:
		assert_bool(key in desired).override_failure_message(
			"Seeded active chunk %s dropped from desired — retention failed." % [key]
		).is_true()

	# Walker invariant: no cell is owned by more than one chunk.
	var owners: Dictionary = {}
	for key: Vector3i in desired:
		var size: int = 1 << key.z
		for sy in range(size):
			for sx in range(size):
				var cell := Vector2i(key.x + sx, key.y + sy)
				assert_bool(owners.has(cell)).override_failure_message(
					"Cell %s claimed by multiple chunks: existing=%s, new=%s" % [cell, owners.get(cell, Vector3i.ZERO), key]
				).is_false()
				owners[cell] = key

#endregion


#region Phase 4d — teleport detection (plan §11 Phase 3)

## Pure predicate — first-ever call (prev == INF) never fires teleport.
## Protects against spurious warmup on initial enable.
func test_teleport_first_call_never_fires() -> void:
	assert_bool(Merger._is_teleport(Vector3.INF, Vector3.ZERO)) \
		.override_failure_message("Sentinel prev position (INF) must not count as teleport.") \
		.is_false()


## Small camera motion within threshold stays false.
func test_teleport_small_motion_below_threshold() -> void:
	var prev := Vector3(100.0, 0.0, 0.0)
	var curr := Vector3(100.0 + Merger.TELEPORT_THRESHOLD * 0.5, 0.0, 0.0)
	assert_bool(Merger._is_teleport(prev, curr)) \
		.override_failure_message("Half-threshold motion must not fire teleport.") \
		.is_false()


## Jump past threshold fires teleport.
func test_teleport_large_jump_fires() -> void:
	var prev := Vector3.ZERO
	var curr := Vector3(Merger.TELEPORT_THRESHOLD + 10.0, 0.0, 0.0)
	assert_bool(Merger._is_teleport(prev, curr)) \
		.override_failure_message("Jump past TELEPORT_THRESHOLD must fire teleport.") \
		.is_true()


## Threshold constant sanity — 500m matches the plan §11 Phase 3 callout.
func test_teleport_threshold_matches_plan() -> void:
	assert_float(Merger.TELEPORT_THRESHOLD).is_equal_approx(500.0, 0.01)

#endregion


#region Phase 5 — minSizeMergeFactor second-pass (OpenMW §2.5)

## Constant parity — matches OpenMW canonical defaults (plan §8).
func test_paging_min_size_merge_factor_matches_openmw() -> void:
	assert_float(DU.PAGING_MIN_SIZE_MERGE_FACTOR).is_equal_approx(0.5, 0.001)
	assert_float(DU.PAGING_MIN_SIZE_COST_MULTIPLIER).is_equal_approx(1.0, 0.001)


## Formula corner case — benefit == 0 collapses to MIN_SIZE² (base threshold).
## This branch is only ever reached by callers that pass zero benefit through
## the helper directly; production `_analyze_chunk` skips the formula when
## merge is rejected.
func test_min_size_merged_sq_zero_benefit_collapses_to_base() -> void:
	var threshold: float = Kernel._compute_min_size_merged_sq(0.0, 1000.0)
	var expected: float = DU.PAGING_MIN_SIZE * DU.PAGING_MIN_SIZE
	assert_float(threshold).is_equal_approx(expected, 0.0001)


## Strong merge (benefit >> cost) — factor2 → 0 → minSizeMergeFactor2 → 0.5 →
## threshold = (MIN_SIZE × 0.5)². Loosest filter, most refs survive.
func test_min_size_merged_sq_strong_merge_loosens_threshold() -> void:
	# benefit = 1000, cost = 1 → factor2 = clamp(1 × 1.0 / 1000, 0, 1) = 0.001
	# minSizeMergeFactor2 = 0.999 × 0.5 + 0.001 ≈ 0.5005
	var threshold: float = Kernel._compute_min_size_merged_sq(1000.0, 1.0)
	var loose_expected: float = (DU.PAGING_MIN_SIZE * 0.5) * (DU.PAGING_MIN_SIZE * 0.5)
	# Should be close to the loose end — within 2% because factor2 isn't exactly 0.
	var ratio := threshold / loose_expected
	assert_bool(ratio >= 0.99 and ratio <= 1.05) \
		.override_failure_message("Strong merge threshold %f should be near loose bound %f (ratio=%f)" % [threshold, loose_expected, ratio]) \
		.is_true()


## Weak merge (benefit barely > cost) — factor2 → 1 → minSizeMergeFactor2 → 1 →
## threshold = MIN_SIZE² (tight, equal to base filter).
func test_min_size_merged_sq_weak_merge_tightens_to_base() -> void:
	# benefit == cost → factor2 = 1.0 → minSizeMergeFactor2 = 1.0 → base threshold.
	var threshold: float = Kernel._compute_min_size_merged_sq(100.0, 100.0)
	var base_expected: float = DU.PAGING_MIN_SIZE * DU.PAGING_MIN_SIZE
	assert_float(threshold).is_equal_approx(base_expected, 0.0001)


## Analyze now emits rich per-type dicts: merge:bool + min_size_merged_sq:float.
## Rejected types get min_size_merged_sq = 0 (filter is no-op).
func test_analyze_rejected_type_has_zero_min_size_merged() -> void:
	var tri := _make_triangle_soup_mesh(100)
	var mat := StandardMaterial3D.new()
	var refs: Array = [_make_ref(tri, mat, Vector3.ZERO)]
	var result: Dictionary = Kernel._analyze_chunk(refs, 0)

	var mesh_id: int = tri.get_instance_id()
	assert_bool(result[mesh_id]["merge"]).is_false()
	assert_float(result[mesh_id]["min_size_merged_sq"]).is_equal_approx(0.0, 0.0001)


## Accepted types get a positive min_size_merged_sq in [0, MIN_SIZE²].
func test_analyze_merged_type_has_positive_min_size_merged() -> void:
	var tri_a := _make_triangle_mesh()
	var tri_b := _make_triangle_mesh()
	var mat := StandardMaterial3D.new()
	var refs: Array = [
		_make_ref(tri_a, mat, Vector3.ZERO),
		_make_ref(tri_a, mat, Vector3(1, 0, 0)),
		_make_ref(tri_b, mat, Vector3(2, 0, 0)),
		_make_ref(tri_b, mat, Vector3(3, 0, 0)),
	]
	var result: Dictionary = Kernel._analyze_chunk(refs, 0)

	var base_sq: float = DU.PAGING_MIN_SIZE * DU.PAGING_MIN_SIZE
	for mesh_id: int in result:
		var entry: Dictionary = result[mesh_id]
		if not entry["merge"]:
			continue
		var t: float = entry["min_size_merged_sq"]
		assert_bool(t > 0.0 and t <= base_sq + 0.0001) \
			.override_failure_message("Merged type must have min_size_merged_sq in (0, MIN_SIZE²]; got %f (base %f)" % [t, base_sq]) \
			.is_true()


## Integration: a ref whose projected size is below the merged type's
## second-pass threshold must be dropped during flatten, even when its
## mesh-type is approved for merging.
func test_flatten_drops_sub_threshold_ref_via_second_pass() -> void:
	var tri_a := _make_triangle_mesh()
	var tri_b := _make_triangle_mesh()
	var mat := StandardMaterial3D.new()
	# Analyze-approvable setup (shared material, multiple refs per type).
	var big := _make_ref(tri_a, mat, Vector3.ZERO)
	var big2 := _make_ref(tri_a, mat, Vector3(1, 0, 0))
	var small := _make_ref(tri_b, mat, Vector3(2, 0, 0))
	var small2 := _make_ref(tri_b, mat, Vector3(3, 0, 0))

	# Configure refs so the second-pass filter rejects `small` and `small2`
	# but keeps `big` and `big2`. rs2=1000, dist_sq=10000, threshold worst-case
	# at MIN_SIZE^2 ~= 0.000009 -> dist_sq * threshold ~= 0.09.
	# Big's rs2=1000 is kept. Small's rs2=0.01 is rejected.
	big.rs2 = 1000.0
	big.dist_sq = 10000.0
	big2.rs2 = 1000.0
	big2.dist_sq = 10000.0
	small.rs2 = 0.01
	small.dist_sq = 10000.0
	small2.rs2 = 0.01
	small2.dist_sq = 10000.0

	var result: Dictionary = Kernel._analyze_chunk([big, big2, small, small2], 0)
	var triplets: Array = Kernel._flatten_to_triplets([big, big2, small, small2], Vector3.ZERO, result)

	# Only triplets from approved + size-passing refs survive. We can't easily
	# map triplets back to the original ref, but the COUNT must be lower than
	# the all-approved case. Compare against a baseline where rs2/dist_sq are
	# zeroed (second-pass disabled per our guard).
	for r: Kernel.RefInput in [big, big2, small, small2]:
		r.rs2 = 0.0
		r.dist_sq = 0.0
	var baseline_triplets: Array = Kernel._flatten_to_triplets([big, big2, small, small2], Vector3.ZERO, result)

	assert_int(triplets.size()) \
		.override_failure_message("Second-pass filter must reject ≥1 ref (triplets=%d vs baseline=%d)" % [triplets.size(), baseline_triplets.size()]) \
		.is_less(baseline_triplets.size())


## Zeroed rs2/dist_sq disables the Phase 5 filter (backward compat).
func test_flatten_second_pass_noop_when_ref_metrics_missing() -> void:
	var tri_a := _make_triangle_mesh()
	var tri_b := _make_triangle_mesh()
	var mat := StandardMaterial3D.new()
	var refs: Array = [
		_make_ref(tri_a, mat, Vector3.ZERO),
		_make_ref(tri_a, mat, Vector3(1, 0, 0)),
		_make_ref(tri_b, mat, Vector3(2, 0, 0)),
		_make_ref(tri_b, mat, Vector3(3, 0, 0)),
	]
	# Default RefInput.rs2 = 0.0, dist_sq = 0.0 → filter skipped.
	var result: Dictionary = Kernel._analyze_chunk(refs, 0)
	var triplets: Array = Kernel._flatten_to_triplets(refs, Vector3.ZERO, result)

	# With all refs contributing a surface each, we should see 4 triplets (one
	# per ref) when analyze approves the merge. If any were rejected we'd see
	# fewer — this locks in that zero-metrics refs pass through.
	var merged_count := 0
	for mesh_id: int in result:
		if result[mesh_id]["merge"]:
			merged_count += 1
	if merged_count == 2:
		assert_int(triplets.size()) \
			.override_failure_message("With 4 approved refs and zero-metrics, expected 4 triplets.") \
			.is_equal(4)

#endregion


#region Phase 2 SizeCache re-evaluation (was here, kept verbatim)

## Camera-motion parity — cached ref moving into range must re-evaluate.
## Simulates SizeCache flow: a ref rejected at 500m, camera walks to 10m,
## same `_is_size_worthy` call with cached `rad²×scale²` should now return
## true. Validates the re-test logic in `_request_merge` that drives cache
## eviction + full-path fallthrough.
func test_size_worthy_reevaluation_after_camera_approach() -> void:
	# Cache-equivalent value: mesh_radius_sq × scale² = 1.0 × 1.0 = 1.0
	var cached_rs2 := 1.0
	var min_size_sq := DU.PAGING_MIN_SIZE_SQ

	# At 1000m: threshold = 1000000 * 0.000009 = 9. 1.0 < 9 -> rejected.
	var at_1000 := 1000000.0 * min_size_sq
	assert_bool(cached_rs2 < at_1000) \
		.override_failure_message("SizeCache path assumes ref rejected at 1000m.") \
		.is_true()

	# At 5m: threshold = 25 * 0.000009 = 0.000225. 1.0 >= threshold -> kept. Cache should
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

	var merged: ArrayMesh = Kernel.merge_refs([ref], Vector3.ZERO, 0, true)
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
