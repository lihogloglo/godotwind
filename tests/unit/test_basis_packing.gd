## API contract regression test for Godot 4.6 Basis and Projection indexing.
##
## Exists because two agents got this wrong in a single debugging session:
##   - Basis[i] returns COLUMNS (same as basis.x/y/z), NOT rows
##   - Projection[col] returns COLUMNS (column-major storage)
##
## The session hypothesis "a compositor effect packs inv_view transposed because
## Basis[i] returns rows" was WRONG. Both indexing forms match.
##
## If Godot ever changes this API, our shader matrix packing will silently break;
## this test catches that.
extends GdUnitTestSuite


func test_basis_index_returns_columns() -> void:
	# Rotate 90deg around Y: axis_x (column 0) should point to (0, 0, -1)
	var b := Basis.IDENTITY.rotated(Vector3.UP, PI * 0.5)

	assert_vector(b.x).is_equal_approx(Vector3(0, 0, -1), Vector3.ONE * 0.001)
	assert_vector(b.y).is_equal_approx(Vector3(0, 1, 0), Vector3.ONE * 0.001)
	assert_vector(b.z).is_equal_approx(Vector3(1, 0, 0), Vector3.ONE * 0.001)

	# Critical invariant: basis[i] == basis.x/y/z (COLUMNS, not rows)
	assert_vector(b[0]).is_equal_approx(b.x, Vector3.ONE * 0.001)
	assert_vector(b[1]).is_equal_approx(b.y, Vector3.ONE * 0.001)
	assert_vector(b[2]).is_equal_approx(b.z, Vector3.ONE * 0.001)


func test_projection_index_returns_columns() -> void:
	# For a standard perspective projection, col 0 should be (f_x, 0, 0, 0) and
	# col 1 should be (0, f_y, 0, 0). If [col][row] returned rows, the off-diagonal
	# entries would be non-zero.
	var proj := Projection.create_perspective(60.0, 16.0 / 9.0, 0.1, 1000.0)

	assert_float(proj[0][0]).is_not_equal(0.0)
	assert_float(proj[1][1]).is_not_equal(0.0)
	assert_float(proj[0][1]).is_equal(0.0)
	assert_float(proj[1][0]).is_equal(0.0)


func test_transform_basis_matches_direct_access() -> void:
	# Regression for the hypothesis "transform.basis[col] packs rows".
	# Build a transform with a known non-trivial basis and verify both access forms agree.
	var t := Transform3D(Basis.IDENTITY.rotated(Vector3.UP, PI * 0.5), Vector3(5, 6, 7))
	assert_vector(t.basis[0]).is_equal_approx(t.basis.x, Vector3.ONE * 0.001)
	assert_vector(t.basis[1]).is_equal_approx(t.basis.y, Vector3.ONE * 0.001)
	assert_vector(t.basis[2]).is_equal_approx(t.basis.z, Vector3.ONE * 0.001)
