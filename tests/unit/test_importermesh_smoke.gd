## Phase B.0 smoke test 1 — verify ImporterMesh.generate_lods() produces a LOD chain
## when called at runtime (not editor-only import pipeline).
##
## If lod_count == 0, we must pivot Phase B.1 to the manual
## ArrayMesh.add_surface_from_arrays(..., lods_dict, ...) path instead of ImporterMesh.
##
## Delete this test after Phase B.1 ships.
extends GdUnitTestSuite


## Build a simple grid-subdivided plane with enough triangles for meshoptimizer
## to produce a meaningful reduction cascade.
func _build_test_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# 40x40 grid = 1600 quads = 3200 triangles, 1681 verts.
	# Well above meshoptimizer's bail-out threshold.
	var grid_size := 40
	var step := 1.0
	for y in range(grid_size + 1):
		for x in range(grid_size + 1):
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(float(x) / grid_size, float(y) / grid_size))
			st.add_vertex(Vector3(x * step, 0.0, y * step))

	var stride := grid_size + 1
	for y in range(grid_size):
		for x in range(grid_size):
			var i00 := y * stride + x
			var i10 := y * stride + x + 1
			var i01 := (y + 1) * stride + x
			var i11 := (y + 1) * stride + x + 1
			st.add_index(i00)
			st.add_index(i10)
			st.add_index(i11)
			st.add_index(i00)
			st.add_index(i11)
			st.add_index(i01)

	var mesh := st.commit()
	return mesh


func test_importermesh_generates_lods_at_runtime() -> void:
	var base: ArrayMesh = _build_test_mesh()
	assert_that(base).is_not_null()
	assert_that(base.get_surface_count()).is_equal(1)

	var base_indices: PackedInt32Array = base.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	var base_tri_count: int = base_indices.size() / 3
	Log.info("tools", "ImporterMesh smoke: base tris = %d" % base_tri_count)
	assert_that(base_tri_count).is_greater(1000)

	# Feed surface into ImporterMesh and generate the LOD chain.
	var importer := ImporterMesh.new()
	importer.add_surface(
		Mesh.PRIMITIVE_TRIANGLES,
		base.surface_get_arrays(0),
		[],                      # blend_shapes
		{},                      # lods dict (we want auto-gen, not manual)
		StandardMaterial3D.new() # any material
	)

	# glTF importer defaults.
	importer.generate_lods(60.0, 25.0, [])

	# Query LOD chain from ImporterMesh DIRECTLY (public read API).
	# ArrayMesh does NOT expose surface_get_lod_count/indices/size in the scripting API
	# in 4.6 — LODs are write-only via add_surface_from_arrays(..., lods_dict, ...).
	# For cache detection in Phase C, we'll stamp a `has_lods` meta on the mesh instead.
	var lod_count := importer.get_surface_lod_count(0)
	Log.info("tools", "ImporterMesh smoke: surface_lod_count = %d" % lod_count)

	# Per-LOD tri counts for visibility.
	for i in range(lod_count):
		var lod_indices: PackedInt32Array = importer.get_surface_lod_indices(0, i)
		var lod_size: float = importer.get_surface_lod_size(0, i)
		Log.info("tools", "  LOD%d: %d tris, lod_size=%f" % [
			i + 1, lod_indices.size() / 3, lod_size
		])

	# The PASS criterion for Phase B.0 GO/NO-GO.
	assert_that(lod_count).is_greater(0)

	# Round-trip through get_mesh() must still produce a usable ArrayMesh.
	var out: ArrayMesh = importer.get_mesh()
	assert_that(out).is_not_null()
	assert_that(out.get_surface_count()).is_greater(0)


## Sanity check — material preserved through ImporterMesh round-trip (Open Question 2).
func test_importermesh_preserves_material() -> void:
	var base: ArrayMesh = _build_test_mesh()

	var tagged_material := StandardMaterial3D.new()
	tagged_material.albedo_color = Color(0.42, 0.17, 0.83)

	var importer := ImporterMesh.new()
	importer.add_surface(
		Mesh.PRIMITIVE_TRIANGLES,
		base.surface_get_arrays(0),
		[],
		{},
		tagged_material
	)
	importer.generate_lods(60.0, 25.0, [])
	var out: ArrayMesh = importer.get_mesh()

	var surface_mat: Material = out.surface_get_material(0)
	assert_that(surface_mat).is_not_null()
	# Identity check — should be same object (or at least same albedo)
	if surface_mat is StandardMaterial3D:
		var sm := surface_mat as StandardMaterial3D
		assert_that(sm.albedo_color.r).is_equal_approx(0.42, 0.001)
		assert_that(sm.albedo_color.g).is_equal_approx(0.17, 0.001)
		assert_that(sm.albedo_color.b).is_equal_approx(0.83, 0.001)
	Log.info("tools", "ImporterMesh smoke: material preserved = %s" % str(surface_mat))
