## CellStaticCollision — per-cell merged trimesh collision for statics_no_node3d T.2.
##
## statics_no_node3d T.1 moved static rendering to RenderingServer-direct
## (MultiMesh slots, no Node3D). That eliminated ~10k per-object StaticBody3D
## registrations in Jolt broadphase but also removed collision. This class
## restores collision by baking one `ConcavePolygonShape3D` per cell from the
## cell's static refs, parented to a single `StaticBody3D` child of the cell
## node. Runtime lifetime matches the cell — queue_free on cell unload
## cascades to the body and cleanly unregisters from Jolt.
##
## Spec: docs/plans/distant_rendering_2026_04/statics_no_node3d.md §3.2–3.4.
## Ownership: owned by CellManager. Call `build_for_cell(grid, cell_record)`
## from `_finalize_request`; attach the returned StaticBody3D to the cell_node.
##
## Shape data comes from a shared `StaticShapeCache` (per-prototype LRU keyed
## on model_path). First-time extraction instantiates the PackedScene, walks
## CollisionShape3D nodes, caches the (shape, local_xf) tuple list. MW has
## ~500 unique static prototypes vs ~10k refs/grid, so steady-state merge is
## dict lookup + transform math. ~2–5ms per cell on warm cache.
class_name CellStaticCollision
extends RefCounted


const CS := preload("res://src/core/coordinate_system.gd")
const CarryableRegistryScript := preload("res://src/core/interaction/carryable_registry.gd")


## Injected dependencies — set via configure().
var _shape_cache: RefCounted = null  # StaticShapeCache
var _instantiator: RefCounted = null  # ReferenceInstantiator — for classifier reuse

## Stats (read by cell_manager for heartbeat).
var stats: Dictionary = {
	"cells_built": 0,
	"total_triangles": 0,
	"total_build_time_us": 0,
}

## Toggle verbose per-cell Log.debug output. Off by default; flip in
## `configure` or via the owning cell_manager for collision-related triage.
var debug_enabled: bool = false

# Per-build diagnostic counters — report why an empty build returned null.
var _dbg_refs_seen: int = 0
var _dbg_classified_static: int = 0
var _dbg_shapes_fetched: int = 0
var _dbg_shapes_empty: int = 0


func configure(shape_cache: RefCounted, instantiator: RefCounted) -> void:
	_shape_cache = shape_cache
	_instantiator = instantiator


## Build a merged trimesh StaticBody3D for the cell. Returns null if the cell
## has no static refs with extractable shapes. The caller must `add_child` the
## result to the cell's cell_node so unload correctly cascades queue_free.
##
## cell_grid             — diagnostic only (body name suffix).
## cell_record           — CellRecord from ESMManager; caller guarantees non-null.
## use_static_renderer   — routing flag; `false` (interior pockets) SKIPS the
##                         build entirely because those refs use Node3D path
##                         with per-object StaticBody3D collision already.
##                         `true` (exterior) triggers the trimesh merge over
##                         the static-routed subset of refs.
func build_for_cell(cell_grid: Vector2i, cell_record: Variant, use_static_renderer: bool = true) -> StaticBody3D:
	if _shape_cache == null or _instantiator == null or cell_record == null:
		return null
	if not use_static_renderer:
		# Interior pockets — every ref is a Node3D with its own collision; a
		# cell-level trimesh would duplicate. Skip.
		return null

	var t0: int = Time.get_ticks_usec()
	var vertices: PackedVector3Array = PackedVector3Array()
	# Diagnostic counters — report WHY we failed to build a body if vertices end empty.
	_dbg_refs_seen = 0
	_dbg_classified_static = 0
	_dbg_shapes_fetched = 0
	_dbg_shapes_empty = 0

	for ref: CellReference in cell_record.references:
		_dbg_refs_seen += 1
		var rec_type: Array = [""]
		var base: Variant = ESMManager.get_any_record(str(ref.ref_id), rec_type)
		if base == null or not "model" in base:
			continue
		var type_name: String = rec_type[0] if rec_type.size() > 0 else ""
		var model_path: String = base.model
		if model_path.is_empty():
			continue

		var is_carryable: bool = CarryableRegistryScript.is_carryable(type_name, base)

		# Reuse the instantiator's classifier so T.2 tracks the RS-routed set
		# exactly. GDScript doesn't enforce private prefix; the call below is
		# stable because `_should_route_to_renderer` has been present since
		# statics_no_node3d T.1 shipped. If that ever changes, switch to a
		# public helper.
		if not _instantiator._should_route_to_renderer(type_name, model_path, is_carryable, use_static_renderer):
			continue
		_dbg_classified_static += 1

		_dbg_shapes_fetched += 1
		var shapes: Array = _shape_cache.get_shapes(model_path)
		if shapes.is_empty():
			_dbg_shapes_empty += 1
			continue

		# Compose ref world transform. Matches `_apply_transform` in the ref
		# instantiator: CS converts ESM (Z-up) to Godot (Y-up), rotation via
		# esm_rotation_to_godot_basis, scale via scale_to_godot.
		var ref_xf: Transform3D = Transform3D()
		ref_xf.origin = CS.vector_to_godot(ref.position)
		ref_xf.basis = CS.esm_rotation_to_godot_basis(ref.rotation)
		var scale_vec: Vector3 = CS.scale_to_godot(ref.scale)
		ref_xf.basis = ref_xf.basis.scaled(scale_vec)

		for entry: Dictionary in shapes:
			var shape: Shape3D = entry.get("shape")
			var local_xf: Transform3D = entry.get("local_xf", Transform3D.IDENTITY)
			if shape == null:
				continue
			var triangles: PackedVector3Array = _shape_to_triangles(shape)
			if triangles.is_empty():
				continue
			var world_xf: Transform3D = ref_xf * local_xf
			# PackedVector3Array: always len % 3 == 0 after shape extract.
			# Append each triangle transformed to world space.
			var n: int = triangles.size()
			var i: int = 0
			while i + 2 < n:
				vertices.push_back(world_xf * triangles[i])
				vertices.push_back(world_xf * triangles[i + 1])
				vertices.push_back(world_xf * triangles[i + 2])
				i += 3

	if vertices.is_empty():
		if debug_enabled:
			Log.debug("streaming", "[T.2] %s — no verts (refs=%d static=%d shapes=%d empty=%d)" % [
				str(cell_grid), _dbg_refs_seen, _dbg_classified_static, _dbg_shapes_fetched, _dbg_shapes_empty,
			])
		return null

	var trimesh: ConcavePolygonShape3D = ConcavePolygonShape3D.new()
	trimesh.set_faces(vertices)

	var body: StaticBody3D = StaticBody3D.new()
	body.name = "cell_static_collision_%d_%d" % [cell_grid.x, cell_grid.y]
	var col: CollisionShape3D = CollisionShape3D.new()
	col.shape = trimesh
	body.add_child(col)

	stats["cells_built"] += 1
	stats["total_triangles"] += vertices.size() / 3
	stats["total_build_time_us"] += Time.get_ticks_usec() - t0
	if debug_enabled:
		Log.debug("streaming", "[T.2] %s — tris=%d (refs=%d static=%d)" % [
			str(cell_grid), vertices.size() / 3, _dbg_refs_seen, _dbg_classified_static,
		])
	return body


# ----------------------------------------------------------------------------
# Shape → triangle helpers (statics_no_node3d §3.3)
# ----------------------------------------------------------------------------


## Convert a Shape3D into local-space triangle vertices (3 verts per tri).
## Returns empty for unknown shape types with a warning — callers skip.
static func _shape_to_triangles(shape: Shape3D) -> PackedVector3Array:
	if shape is ConcavePolygonShape3D:
		# 90%+ of MW NIFs end here (bhkPackedNiTriStripsShape → ConcavePolygonShape3D).
		# Direct read — already triangles.
		return (shape as ConcavePolygonShape3D).get_faces()
	if shape is ConvexPolygonShape3D:
		return _triangulate_convex((shape as ConvexPolygonShape3D).points)
	if shape is BoxShape3D:
		return _triangulate_box(shape as BoxShape3D)
	if shape is SphereShape3D:
		return _triangulate_sphere(shape as SphereShape3D)
	if shape is CapsuleShape3D:
		return _triangulate_capsule(shape as CapsuleShape3D)
	push_warning("CellStaticCollision: unsupported shape type %s — skipped" % shape.get_class())
	return PackedVector3Array()


## Fan-triangulation of a convex polyhedron point set. MW ConvexPolygonShape3D
## stores hull vertices; fan from vertex 0. Not a topologically correct
## triangulation for non-convex inputs, but ConvexPolygonShape3D guarantees
## convexity so this produces a watertight-enough trimesh for player collision.
static func _triangulate_convex(points: PackedVector3Array) -> PackedVector3Array:
	var out: PackedVector3Array = PackedVector3Array()
	if points.size() < 3:
		return out
	var v0: Vector3 = points[0]
	for i in range(1, points.size() - 1):
		out.push_back(v0)
		out.push_back(points[i])
		out.push_back(points[i + 1])
	return out


## 12 triangles for a box (6 faces × 2 tris). Winding is outward-facing.
static func _triangulate_box(box: BoxShape3D) -> PackedVector3Array:
	var s: Vector3 = box.size * 0.5
	# Vertex labeling:
	#   0: -x,-y,-z   1: +x,-y,-z   2: +x,+y,-z   3: -x,+y,-z
	#   4: -x,-y,+z   5: +x,-y,+z   6: +x,+y,+z   7: -x,+y,+z
	var v: Array = [
		Vector3(-s.x, -s.y, -s.z), Vector3(s.x, -s.y, -s.z),
		Vector3(s.x, s.y, -s.z), Vector3(-s.x, s.y, -s.z),
		Vector3(-s.x, -s.y, s.z), Vector3(s.x, -s.y, s.z),
		Vector3(s.x, s.y, s.z), Vector3(-s.x, s.y, s.z),
	]
	# Faces as (i0, i1, i2, i3) quads, emitted as two CCW triangles each.
	var faces: Array = [
		[3, 2, 1, 0],  # -Z  (outward -Z normal)
		[4, 5, 6, 7],  # +Z
		[0, 4, 7, 3],  # -X
		[2, 6, 5, 1],  # +X
		[0, 1, 5, 4],  # -Y
		[7, 6, 2, 3],  # +Y
	]
	var out: PackedVector3Array = PackedVector3Array()
	for f: Array in faces:
		out.push_back(v[f[0]]); out.push_back(v[f[1]]); out.push_back(v[f[2]])
		out.push_back(v[f[0]]); out.push_back(v[f[2]]); out.push_back(v[f[3]])
	return out


## Coarse UV-sphere triangulation — 16 slices × 8 stacks ≈ 256 tris.
## Good enough for trimesh collision; geometric fidelity isn't critical for
## player-body-against-static physics. Rarely used in MW static refs.
static func _triangulate_sphere(sph: SphereShape3D) -> PackedVector3Array:
	var out: PackedVector3Array = PackedVector3Array()
	var r: float = sph.radius
	var slices: int = 16
	var stacks: int = 8
	for st in range(stacks):
		var lat0: float = PI * (float(st) / stacks - 0.5)
		var lat1: float = PI * (float(st + 1) / stacks - 0.5)
		var y0: float = sin(lat0) * r
		var y1: float = sin(lat1) * r
		var r0: float = cos(lat0) * r
		var r1: float = cos(lat1) * r
		for sl in range(slices):
			var lng0: float = TAU * float(sl) / slices
			var lng1: float = TAU * float(sl + 1) / slices
			var c0: float = cos(lng0); var s0: float = sin(lng0)
			var c1: float = cos(lng1); var s1: float = sin(lng1)
			var p0: Vector3 = Vector3(c0 * r0, y0, s0 * r0)
			var p1: Vector3 = Vector3(c1 * r0, y0, s1 * r0)
			var p2: Vector3 = Vector3(c1 * r1, y1, s1 * r1)
			var p3: Vector3 = Vector3(c0 * r1, y1, s0 * r1)
			out.push_back(p0); out.push_back(p1); out.push_back(p2)
			out.push_back(p0); out.push_back(p2); out.push_back(p3)
	return out


## Capsule approximated as an axis-aligned bounding box of the same radius +
## height. MW statics almost never use CapsuleShape3D for collision (Jolt's
## trimesh converter emits ConcavePolygon for virtually everything); this is
## a correctness fallback, not a geometric one. Cheaper than stitching two
## hemispheres to a cylinder and the player-trimesh interaction is identical
## within the tolerance of a walking body.
static func _triangulate_capsule(cap: CapsuleShape3D) -> PackedVector3Array:
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(2.0 * cap.radius, cap.height, 2.0 * cap.radius)
	return _triangulate_box(box)
