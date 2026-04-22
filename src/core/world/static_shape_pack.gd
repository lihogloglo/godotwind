## Per-prototype collision shape cache, baked at conversion time and loaded at
## runtime via `ResourceLoader`. Parallel sidecar to the scene `.res` emitted by
## `model_loader.gd:_save_to_disk_cache` — same base path, `.shapes.res` suffix.
##
## Purpose: eliminate the 20–50ms `PackedScene.instantiate` + tree-walk spike
## that `StaticShapeCache.get_shapes` otherwise incurs on first sight of each
## unique prototype during cell transition. OpenMW avoids the spike entirely by
## reading `bhkPackedNiTriStripsShape` bytes directly into `btBvhTriangleMeshShape`;
## we approximate that with a tiny Resource sidecar so `ResourceLoader.load`
## returns the extracted shape list in sub-ms without touching the scene system.
##
## Contents: one entry per `CollisionShape3D` descendant of the prototype root,
## storing the `Shape3D` sub-resource (RefCounted, serializes natively) plus the
## transform of that `CollisionShape3D` local to the prototype root. Merge-time
## world composition happens in `cell_static_collision.build_for_cell`.
##
## See:
##   - `docs/plans/distant_rendering_2026_04/statics_no_node3d.md` §7 (T.6 spec)
##   - `static_shape_cache.gd` header (anticipates this sidecar)
class_name StaticShapePack
extends Resource


## Array of `{ shape: Shape3D, local_xf: Transform3D }` dictionaries.
## Typed `Array[Dictionary]` for ResourceSaver/Loader fidelity across sessions.
@export var shapes: Array[Dictionary] = []


## Walk `node` for every `CollisionShape3D` descendant, record `(shape,
## local_xf)` where `local_xf` is the transform relative to `node` (the
## prototype root). Returns the tuple list for consumption by `save_from_node`
## or `StaticShapeCache`'s walker fallback. Static — no cache state.
static func extract_from_node(node: Node3D) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if node != null:
		_walk(node, Transform3D.IDENTITY, out)
	return out


## Build a pack from `node` and save it to `base_path + ".shapes.res"`.
## No-op if the prototype has no collision — nothing written, and runtime
## `StaticShapeCache.get_shapes` falls back to the legacy walker path.
##
## Called from both prebake pipelines (`model_prebaker._save_model_to_cache`
## and `model_loader._save_to_disk_cache`) so every write of a scene `.res`
## produces its sidecar pack.
static func save_from_node(node: Node3D, base_path: String) -> Error:
	var entries := extract_from_node(node)
	if entries.is_empty():
		return OK  # no collision → no sidecar, by design

	var pack := StaticShapePack.new()
	pack.shapes = entries

	var pack_path := base_path + ".shapes.res"
	var result := ResourceSaver.save(pack, pack_path)
	if result != OK:
		push_warning("StaticShapePack: Failed to save %s (%s)" % [pack_path, error_string(result)])
	return result


static func _walk(node: Node, parent_xf: Transform3D, out: Array[Dictionary]) -> void:
	var local_xf := parent_xf
	if node is Node3D:
		local_xf = parent_xf * (node as Node3D).transform

	if node is CollisionShape3D:
		var cs := node as CollisionShape3D
		if cs.shape != null:
			out.append({
				"shape": cs.shape,
				"local_xf": local_xf,
			})

	for child in node.get_children():
		_walk(child, local_xf, out)
