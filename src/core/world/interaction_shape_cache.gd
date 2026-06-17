## InteractionShapeCache - Shared interaction-area geometry per prototype.
##
## The 10.7 ms door instantiation cost is dominated by `_compute_mesh_aabb`
## (full subtree walk) + `BoxShape3D.new` allocation, repeated per-instance
## even though every instance of the same door prototype produces an
## **identical** AABB. This cache memoizes both: the AABB walk runs once per
## prototype, the resulting `BoxShape3D` Resource is reused across all
## instances (Godot canonical pattern — `CollisionShape3D.shape` is a
## shareable Resource, see `class_collisionshape3d` docs).
##
## Per @roaster plan-review clarification 1: caching only the shape leaves the
## subtree walk per-instance (most of the wasted work). Cache the AABB walk
## RESULT (`aabb_size`, `aabb_center`), not just the shape.
##
## Per @roaster plan-review clarification "shape cache key correctness": the
## key is the canonical prototype identity used everywhere else in the
## codebase (`model_path.to_lower().replace("/", "\\")`), NOT the raw model
## path string. Two refs with the same model under different ESM record IDs
## share geometry; matching the registry's normalization avoids a divergent
## cache key.
##
## Mutation contract: callers MUST NOT mutate the returned `BoxShape3D.size`
## per instance. The shape is shared. Mutation invalidates every other
## interaction area built from the same cache entry. Mitigation is naming +
## documentation (canonical Godot Resources are shareable by design — same
## contract every other shared shape in this codebase relies on).
##
## Plan: docs/plans/near_streaming_2026_04_28_interactive_spawn.md step 2.
##
## Deliberately NO class_name — consumers preload this script as a Script
## const. Class-name-free avoids the gdUnit4 test-scan + load-order resolution issues
## that bit `reference_instantiator.gd` when class_name was set here.
extends RefCounted


## Cached AABB walk result + the BoxShape3D Resource derived from it.
##
## `aabb_size` and `aabb_center` are AABB-local (relative to the prototype
## root). Callers compose them onto an instance's CollisionShape3D.position;
## the BoxShape3D itself is rotation-invariant so no per-instance basis math
## is needed.
class CachedInteractionGeometry:
	extends RefCounted
	## Shared `BoxShape3D` Resource — multiple `CollisionShape3D` nodes can
	## reference the same shape RID. Sized once at compute time, never mutated.
	var shape: BoxShape3D
	## AABB extents in prototype-local space. Callers reuse without walking.
	var aabb_size: Vector3
	## AABB center offset (CollisionShape3D.position) in prototype-local space.
	var aabb_center: Vector3


## Default fallback geometry for prototypes that have no MeshInstance3D
## children or whose mesh AABBs are degenerate. A 0.6 m cube at origin —
## small enough to feel local to the door, large enough to be raycast-clickable
## from short range. Mirrors the legacy fallback in
## `reference_instantiator._generate_interaction_area`.
const _DEFAULT_BOX_SIZE := Vector3(0.6, 0.6, 0.6)
const _DEFAULT_BOX_CENTER := Vector3(0.0, 0.0, 0.0)


## prototype_key (normalized model path) -> CachedInteractionGeometry
var _cache: Dictionary[String, CachedInteractionGeometry] = {}

## Diagnostics — read by `get_stats` for logging / verification.
var _hit_count: int = 0
var _miss_count: int = 0


## Look up cached geometry by prototype key, or compute it from the
## prototype root if this is the first encounter.
##
## `prototype_key` MUST be normalized via `make_key(model_path)` so cache
## hits work across all callers. Callers that pass a raw model path will
## see misses every time and the cache becomes write-only.
##
## `prototype_root` is the `Node3D` whose mesh-AABB tree we walk on miss.
## On hit the parameter is unused (no walk happens). Callers can pass null
## ONLY if they're sure the key is already cached — otherwise the function
## returns the default fallback geometry.
##
## Returns a `CachedInteractionGeometry` (never null). Multiple calls with
## the same key return the SAME object — `shape` field is the shared
## `BoxShape3D` Resource. Mutation is a contract violation.
func get_or_compute(prototype_key: String, prototype_root: Node3D) -> CachedInteractionGeometry:
	var cached: CachedInteractionGeometry = _cache.get(prototype_key)
	if cached != null:
		_hit_count += 1
		return cached

	_miss_count += 1
	var entry := CachedInteractionGeometry.new()

	if prototype_root != null:
		var aabb := _compute_mesh_aabb(prototype_root)
		if aabb.has_volume():
			entry.aabb_size = aabb.size
			entry.aabb_center = aabb.get_center()
		else:
			entry.aabb_size = _DEFAULT_BOX_SIZE
			entry.aabb_center = _DEFAULT_BOX_CENTER
	else:
		# Caller passed null — emit a fallback so nothing crashes downstream,
		# but log a warning since this is almost certainly a caller bug.
		push_warning(
			"InteractionShapeCache.get_or_compute: prototype_root null for new key '%s' — using fallback geometry"
			% prototype_key
		)
		entry.aabb_size = _DEFAULT_BOX_SIZE
		entry.aabb_center = _DEFAULT_BOX_CENTER

	var box := BoxShape3D.new()
	box.size = entry.aabb_size
	entry.shape = box

	_cache[prototype_key] = entry
	return entry


## Canonical prototype-identity normalization used across the codebase
## (`model_loader.gd`, `cell_manager.gd`, `reference_instantiator.gd`).
## Matches the registry / static-prepare key so the cache lines up with
## prototype identity, not raw input strings.
##
## Empty input returns empty (caller is expected to guard against that and
## not call get_or_compute with an empty key).
static func make_key(model_path: String) -> String:
	if model_path.is_empty():
		return ""
	return model_path.to_lower().replace("/", "\\")


## Diagnostics — current hit/miss counts + entry count. Cheap O(1) read,
## intended for benchmark verification + log lines.
func get_stats() -> Dictionary:
	return {
		"entries": _cache.size(),
		"hits": _hit_count,
		"misses": _miss_count,
	}


## Drop everything. Used by tests + `clear_caches` console command.
## Safe to call when no callers hold cached entries — the shared
## `BoxShape3D` Resources stay alive only as long as some `CollisionShape3D`
## still references them, which is the standard Godot Resource lifetime
## contract.
func clear() -> void:
	_cache.clear()
	_hit_count = 0
	_miss_count = 0


# ----------------------------------------------------------------------------
# Internal — AABB walk (mirrors `reference_instantiator._compute_mesh_aabb`,
# kept private so the canonical AABB walk site stays the cache).
# ----------------------------------------------------------------------------


## Compute the combined AABB of all `MeshInstance3D` nodes under root,
## expressed in root's LOCAL space. Uses local transforms only — safe to
## call before the node enters the scene tree.
##
## Mirrors `reference_instantiator._compute_mesh_aabb` exactly. The legacy
## function stays in place for non-cached call sites (e.g. test scenes) but
## the door / activator hot path goes through this cache.
static func _compute_mesh_aabb(root: Node3D) -> AABB:
	var aabbs: Array[AABB] = []
	if root is MeshInstance3D and (root as MeshInstance3D).mesh != null:
		aabbs.append((root as MeshInstance3D).mesh.get_aabb())
	for child in root.get_children():
		_collect_mesh_aabbs(child, Transform3D.IDENTITY, aabbs)
	if aabbs.is_empty():
		return AABB()
	var combined: AABB = aabbs[0]
	for i in range(1, aabbs.size()):
		combined = combined.merge(aabbs[i])
	return combined


## Recursive AABB collector. Accumulates mesh AABBs into `out`, transformed
## by the cumulative local transform chain from root.
static func _collect_mesh_aabbs(node: Node, parent_xf: Transform3D, out: Array[AABB]) -> void:
	var xf: Transform3D = parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			out.append(xf * mi.mesh.get_aabb())
	for child in node.get_children():
		_collect_mesh_aabbs(child, xf, out)
