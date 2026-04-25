## CellStaticCollision — per-cell merged trimesh collision for statics_no_node3d T.2.
##
## statics_no_node3d T.1 moved static rendering to RenderingServer-direct
## (MultiMesh slots, no Node3D). That eliminated ~10k per-object StaticBody3D
## registrations in Jolt broadphase but also removed collision. This class
## restores collision by baking one `ConcavePolygonShape3D` per cell from the
## cell's static refs.
##
## Spec: docs/plans/distant_rendering_2026_04/statics_no_node3d.md §3.2–3.4.
##
## Win 1 (NEAR refactor 2026-04-25) — added an off-thread split following
## Zylann's godot_voxel pattern. Triangle assembly + transform math runs on
## a WorkerThreadPool task; main thread does only the BVH build (ConcavePolygon
## set_faces) + body register. Cuts the cell-burst stall in half because the
## 20-50ms cold-cache walk is no longer on the main frame.
##
## Win 2 (NEAR refactor 2026-04-25) — body register goes server-direct via
## `PhysicsServer3D.body_create`, replacing the per-cell StaticBody3D Node3D.
## Same Jolt body underneath; saves ~1.3 KB per cell of Node3D wrapper +
## lifecycle/notification machinery, and aligns the collision side with the
## render side (which already uses RS instances). Reference: reduz's server-
## direct pattern, see docs/research/server_direct_pattern.md.
##
## Three-step pipeline:
##   1. `collect_classified_refs(grid, cell_record, use_static)` — MAIN. Filters
##      refs via the existing classifier, resolves shape-pack sidecars, and
##      packs into a `BuildPayload`. Returns null for empty cells.
##   2. `worker_collect_triangles(payload)` — WORKER. Pure data: warms shape
##      cache from sidecars, walks per-prototype shapes, transforms to world
##      space, packs into `payload.vertices`. Reads `StaticShapeCache` via the
##      worker-safe `get_shapes_for_worker` (cache + sidecar only).
##   3. `finalize_body(payload, world_3d)` — MAIN. `set_faces` (BVH build) +
##      `PhysicsServer3D.body_create` + space registration. Returns a
##      `FinalizedBody` carrying the body RID + a strong-ref to the trimesh
##      Shape3D (so its internal RID stays alive while the body references it).
##      Caller stores both, frees via `free_body` on cell unload.
##
## Synchronous compatibility: `build_for_cell` chains all three inline. Used
## by tests / fallbacks; production cell loads use the async path.
##
## Ownership: owned by CellManager. The async path is driven by
## `_tick_static_collision_build` (cell_manager.gd) which dispatches the
## worker at cell-ready and finalizes one cell per frame. Body lifetime
## tracked on `AsyncCellRequest.collision_body`; freed in
## `_drain_collision_worker_for_request` on cancel / unload / shutdown.
##
## Shape data comes from a shared `StaticShapeCache` (per-prototype LRU keyed
## on model_path). First-time extraction loads the prebaked `.shapes.res`
## sidecar (~sub-ms via ResourceLoader.load) or falls back to PackedScene
## walker (~20-50ms). MW has ~500 unique static prototypes vs ~10k refs/grid.
##
## Debug visibility caveat: server-direct bodies do NOT show up in Godot's
## "Visible Collision Shapes" overlay. Per-cell collision counts surface in
## the dev console via `print_streaming_stats` (extended Win 2). For visual
## wireframe debugging, build a small ImmediateMesh debug-draw layer that
## walks the manager's RID list — see server_direct_pattern.md §"Inspector".
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
	"total_worker_time_us": 0,
}

## Toggle verbose per-cell Log.debug output. Off by default; flip in
## `configure` or via the owning cell_manager for collision-related triage.
var debug_enabled: bool = false


## Per-cell async build state.
##
## Created by `collect_classified_refs` on main, mutated by
## `worker_collect_triangles` on a WorkerThreadPool thread, consumed by
## `finalize_body` on main. RefCounted so the caller can hold a strong ref
## across the worker dispatch — once the main-thread `is_task_completed`
## boundary clears, the worker's writes are visible.
##
## Field thread-safety:
## - `entries`, `pack_paths` — written on main during collect, read-only in
##   worker. Safe.
## - `vertices`, `build_time_us`, `dbg_*` — written ONLY by the worker,
##   read by main AFTER `WorkerThreadPool.is_task_completed` returns true.
##   `is_task_completed` is the implicit acquire/release barrier.
class BuildPayload:
	extends RefCounted
	var cell_grid: Vector2i
	## Per-ref work items: { model_path: String, ref_xf: Transform3D }
	var entries: Array = []
	## Unique model_path → resolved sidecar path (may be empty if no sidecar).
	## Worker uses these to call `StaticShapeCache.warm_from_path` before
	## reading. Resolved on main because `ModelLoader.resolve_shape_pack_path`
	## mutates a non-locked file-exists cache.
	var pack_paths: Dictionary = {}
	## Worker output — world-space triangle vertices, len % 3 == 0.
	var vertices: PackedVector3Array = PackedVector3Array()
	var build_time_us: int = 0
	## Diagnostic counters — same shape as the legacy `_dbg_*` fields.
	var dbg_refs_seen: int = 0
	var dbg_classified_static: int = 0
	var dbg_shapes_fetched: int = 0
	var dbg_shapes_empty: int = 0


## Win 2 — handle to a server-direct cell collision body.
##
## Holds the PhysicsServer3D body RID + a strong reference to the underlying
## `ConcavePolygonShape3D` resource. The strong-ref is load-bearing: the
## body internally references the shape's RID, and if the Godot Shape3D
## wrapper is GC'd while the body still holds the RID, Jolt crashes.
##
## Free via `CellStaticCollision.free_body(finalized)` — that removes the
## body from the physics space, then drops the shape ref so the underlying
## RID can be released by Godot's destructor.
class FinalizedBody:
	extends RefCounted
	var body_rid: RID = RID()
	var shape: Shape3D = null  # ConcavePolygonShape3D, kept alive while body references it
	var cell_grid: Vector2i = Vector2i.ZERO  # diagnostic only


func configure(shape_cache: RefCounted, instantiator: RefCounted) -> void:
	_shape_cache = shape_cache
	_instantiator = instantiator


## Synchronous compatibility wrapper — runs collect → worker (inline) → finalize
## on the calling thread. Kept for tests / fallbacks; the hot path goes through
## the three-step async pipeline driven by cell_manager.
##
## Returns null when nothing to build (interior pocket profile, or no shapes).
##
## Win 2 (NEAR refactor 2026-04-25): now returns a `FinalizedBody` (server-
## direct RID + shape ref) instead of a StaticBody3D. Caller is responsible
## for calling `free_body` on the returned handle when the cell unloads.
func build_for_cell(cell_grid: Vector2i, cell_record: Variant, world_3d: World3D, use_static_renderer: bool = true) -> FinalizedBody:
	var payload := collect_classified_refs(cell_grid, cell_record, use_static_renderer)
	if payload == null:
		return null
	worker_collect_triangles(payload)
	return finalize_body(payload, world_3d)


## MAIN-THREAD: classify refs, resolve sidecars, pack into a BuildPayload.
##
## Returns null when:
## - dependencies missing
## - cell_record null
## - use_static_renderer false (interior-pocket carve-out)
## - no static-routed refs found
##
## Performance: O(N_refs) main-thread cost. The expensive work
## (sidecar load + triangulation + transform) is deferred to the worker.
## Typical Seyda-Neen-cell cost: ~0.2-0.5 ms (mostly ESM lookups).
func collect_classified_refs(cell_grid: Vector2i, cell_record: Variant, use_static_renderer: bool = true) -> BuildPayload:
	if _shape_cache == null or _instantiator == null or cell_record == null:
		return null
	if not use_static_renderer:
		# Interior pockets — every ref is a Node3D with its own collision; a
		# cell-level trimesh would duplicate. Skip.
		return null

	var payload := BuildPayload.new()
	payload.cell_grid = cell_grid

	for ref: CellReference in cell_record.references:
		payload.dbg_refs_seen += 1
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
		# exactly. Stays main-thread because `_should_route_to_renderer`
		# transitively calls `model_loader.has_animation` (cache write).
		if not _instantiator._should_route_to_renderer(type_name, model_path, is_carryable, use_static_renderer):
			continue
		payload.dbg_classified_static += 1

		# Compose ref world transform. Matches `_apply_transform` in the ref
		# instantiator: CS converts ESM (Z-up) to Godot (Y-up), rotation via
		# esm_rotation_to_godot_basis, scale via scale_to_godot.
		var ref_xf: Transform3D = Transform3D()
		ref_xf.origin = CS.vector_to_godot(ref.position)
		ref_xf.basis = CS.esm_rotation_to_godot_basis(ref.rotation)
		var scale_vec: Vector3 = CS.scale_to_godot(ref.scale)
		ref_xf.basis = ref_xf.basis.scaled(scale_vec)

		payload.entries.append({
			"model_path": model_path,
			"ref_xf": ref_xf,
		})

		# Resolve sidecar path for this prototype if we haven't yet. Phase F
		# typically pre-warms the cache, but resolving the pack path here lets
		# the worker call `warm_from_path` defensively for late-arriving cells.
		# `resolve_pack_path` mutates ModelLoader's _file_exists_cache, so it
		# stays main-thread.
		if not payload.pack_paths.has(model_path):
			payload.pack_paths[model_path] = _shape_cache.call("resolve_pack_path", model_path)

	if payload.entries.is_empty():
		return null
	return payload


## WORKER-THREAD: warm sidecars, walk shapes, triangulate, transform.
##
## Pure data — no autoloads, no scene-tree, no main-thread-only APIs. Reads
## `StaticShapeCache` via `warm_from_path` (worker-safe per existing Phase F
## usage) and `get_shapes_for_worker` (worker-safe; cache + sidecar only,
## skips legacy walker which is main-thread-only).
##
## Writes only to `payload.vertices`, `payload.build_time_us`, `payload.dbg_*`.
## Main thread reads those AFTER `WorkerThreadPool.is_task_completed` returns
## true — that boundary is the implicit acquire/release barrier.
##
## Plan: docs/research/static_collision_streaming.md §"Phase 1 — Off-thread
## world-space triangle assembly". Mirrors Zylann's godot_voxel meshing.
# WIN1:WORKER_SAFE — no autoload, no scene-tree, no main-thread APIs.
func worker_collect_triangles(payload: BuildPayload) -> void:
	if payload == null or _shape_cache == null:
		return
	var t0: int = Time.get_ticks_usec()
	var vertices: PackedVector3Array = PackedVector3Array()

	# Warm any uncached sidecars first. Idempotent + dedup'd inside warm_from_path.
	# Empty pack_path is a no-op (skipped inside warm_from_path).
	for model_path: String in payload.pack_paths:
		var pack_path: String = payload.pack_paths[model_path]
		if not pack_path.is_empty():
			_shape_cache.call("warm_from_path", model_path, pack_path)

	for entry: Dictionary in payload.entries:
		var model_path: String = entry["model_path"]
		var ref_xf: Transform3D = entry["ref_xf"]

		payload.dbg_shapes_fetched += 1
		# WORKER-SAFE — cache + sidecar only. Returns empty when prototype has
		# no warmed entry (Phase F missed AND no sidecar). `finalize_body`
		# surfaces a push_warning in that case so the regression is visible;
		# triangles for that ref are dropped (no main-thread fallback to keep
		# the design simple — production sidecar coverage is complete per
		# statics_no_node3d.md).
		var shapes: Array = _shape_cache.call("get_shapes_for_worker", model_path)
		if shapes.is_empty():
			payload.dbg_shapes_empty += 1
			continue

		for shape_entry: Dictionary in shapes:
			var shape: Shape3D = shape_entry.get("shape")
			var local_xf: Transform3D = shape_entry.get("local_xf", Transform3D.IDENTITY)
			if shape == null:
				continue
			var triangles: PackedVector3Array = _shape_to_triangles(shape)
			if triangles.is_empty():
				continue
			var world_xf: Transform3D = ref_xf * local_xf
			var n: int = triangles.size()
			var i: int = 0
			while i + 2 < n:
				vertices.push_back(world_xf * triangles[i])
				vertices.push_back(world_xf * triangles[i + 1])
				vertices.push_back(world_xf * triangles[i + 2])
				i += 3

	# Last writes — become visible to main once is_task_completed returns true.
	payload.vertices = vertices
	payload.build_time_us = Time.get_ticks_usec() - t0


## MAIN-THREAD: build the body from the worker's vertex output.
##
## Empty worker output → null body. If `dbg_shapes_empty > 0`, log a warning
## with the count so a missing-sidecar regression surfaces (production sidecar
## coverage is complete per statics_no_node3d.md; any non-zero empty count
## indicates a Phase F gap or a fresh prototype without a baked sidecar).
##
## Win 2 (NEAR refactor 2026-04-25): goes server-direct via PhysicsServer3D.
## Body sits at world origin (Transform3D.IDENTITY) because the trimesh
## vertices are pre-transformed to world space by the worker. The same Jolt
## body underneath as the previous StaticBody3D path; saves the Node3D
## wrapper cost and aligns with reduz's server-direct pattern.
##
## Returns null for empty payloads — caller skips the body register.
func finalize_body(payload: BuildPayload, world_3d: World3D) -> FinalizedBody:
	if payload == null:
		return null
	if world_3d == null:
		push_error("CellStaticCollision.finalize_body: world_3d is null — cannot register body with physics space")
		return null

	if payload.dbg_shapes_empty > 0:
		# Log every cell that hit the empty path so missing-sidecar regressions
		# don't slip silently. One warning per affected cell, not per ref.
		push_warning("CellStaticCollision: cell %s — %d/%d prototypes had no shapes (Phase F miss or missing .shapes.res sidecar). Triangles dropped." % [
			str(payload.cell_grid), payload.dbg_shapes_empty, payload.dbg_shapes_fetched,
		])

	if payload.vertices.is_empty():
		if debug_enabled:
			Log.debug("streaming", "[T.2-W1] %s — no verts (refs=%d static=%d shapes=%d empty=%d)" % [
				str(payload.cell_grid), payload.dbg_refs_seen, payload.dbg_classified_static,
				payload.dbg_shapes_fetched, payload.dbg_shapes_empty,
			])
		return null

	var trimesh: ConcavePolygonShape3D = ConcavePolygonShape3D.new()
	trimesh.set_faces(payload.vertices)  # the BVH build — main-thread only

	# Server-direct body register. Default mode is BODY_MODE_STATIC (verified
	# against PhysicsServer3D.body_create docs); we set it explicitly anyway
	# so the contract is obvious to readers. Layer/mask 1 matches the legacy
	# StaticBody3D defaults that production was running with pre-Win 2.
	var body_rid: RID = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body_rid, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(body_rid, 1)
	PhysicsServer3D.body_set_collision_mask(body_rid, 1)
	PhysicsServer3D.body_add_shape(body_rid, trimesh.get_rid())
	PhysicsServer3D.body_set_space(body_rid, world_3d.get_space())
	# Vertices are world-space; body sits at origin. Setting transform
	# explicitly avoids any uninitialized-transform surprises in Jolt.
	PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D.IDENTITY)

	var finalized := FinalizedBody.new()
	finalized.body_rid = body_rid
	finalized.shape = trimesh  # strong-ref keeps shape RID alive while body references it
	finalized.cell_grid = payload.cell_grid

	stats["cells_built"] += 1
	stats["total_triangles"] += payload.vertices.size() / 3
	stats["total_build_time_us"] += payload.build_time_us  # worker-side time
	stats["total_worker_time_us"] += payload.build_time_us
	if debug_enabled:
		Log.debug("streaming", "[T.2-W1+W2] %s — tris=%d (worker %d µs, refs=%d static=%d) body=%s" % [
			str(payload.cell_grid), payload.vertices.size() / 3, payload.build_time_us,
			payload.dbg_refs_seen, payload.dbg_classified_static, body_rid,
		])
	return finalized


## Win 2 — release a server-direct cell body. Frees the body RID first
## (removing it from the broadphase), then drops the Shape3D strong ref so
## Godot's destructor releases the shape's RID.
##
## Idempotent: null and already-freed handles are no-ops.
##
## Main-thread only — PhysicsServer3D.free_rid is not thread-safe.
static func free_body(finalized: FinalizedBody) -> void:
	if finalized == null:
		return
	if finalized.body_rid.is_valid():
		PhysicsServer3D.free_rid(finalized.body_rid)
		finalized.body_rid = RID()
	finalized.shape = null  # release strong ref → Godot frees shape RID


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
