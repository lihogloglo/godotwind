## Per-prototype collision-shape cache for statics_no_node3d T.2.
##
## Caches extracted `(shape, local_xf)` tuples per `model_path` (lowercased).
## First query for a path instantiates the PackedScene once, walks the tree
## for CollisionShape3D nodes, records each shape + its transform local to
## the prototype root, and queue_frees the inspection instance. All future
## queries for the same path return the cached array in O(1).
##
## Canonical per-prototype cache per plan §3.2.5 (B1 fix from @roaster).
## MW has ~500 unique static prototypes vs ~10k refs in a 3×3 active grid,
## so this cache delivers ~20× instantiate reduction on the collision ingest.
##
## Thread safety: main-thread-only access in v1. If T.6 promotes shape
## extraction to prebake-time sidecars, cache becomes a boot-loaded read-only
## dict (no sync concerns).
class_name StaticShapeCache
extends RefCounted


## One cached entry per unique model_path. Shapes are stored as references to
## Godot's Shape3D resources — ref-counted, shared across all refs that use
## this prototype. Transform is the shape's position/rotation RELATIVE to the
## prototype root (not world-space; world-space is applied at merge time).
class Entry:
	extends RefCounted
	var shapes: Array = []  # [{shape: Shape3D, local_xf: Transform3D}, ...]


var _cache: Dictionary[String, Entry] = {}
var _model_loader: RefCounted = null


func set_model_loader(loader: RefCounted) -> void:
	_model_loader = loader


## Query the cache for a model_path. On miss, instantiates the prototype
## once, extracts all CollisionShape3D entries, caches, and queue_frees
## the inspection instance. Caller MUST NOT mutate the returned array.
func get_shapes(model_path: String) -> Array:
	var key := model_path.to_lower()
	if key in _cache:
		return _cache[key].shapes

	var entry := Entry.new()

	if _model_loader == null:
		_cache[key] = entry
		return entry.shapes

	# Miss — instantiate to inspect. One-time cost per unique prototype.
	var prototype: Node3D = _model_loader.call("get_model", model_path, "")
	if prototype == null:
		_cache[key] = entry
		return entry.shapes

	_walk_for_shapes(prototype, Transform3D.IDENTITY, entry)
	prototype.queue_free()
	_cache[key] = entry
	return entry.shapes


func _walk_for_shapes(node: Node, parent_xf: Transform3D, entry: Entry) -> void:
	var local_xf := parent_xf
	if node is Node3D:
		local_xf = parent_xf * (node as Node3D).transform

	if node is CollisionShape3D:
		var cs := node as CollisionShape3D
		if cs.shape != null:
			entry.shapes.append({
				"shape": cs.shape,
				"local_xf": local_xf,
			})

	for child in node.get_children():
		_walk_for_shapes(child, local_xf, entry)


## For debug / measurement: how many prototypes are cached.
func get_cache_size() -> int:
	return _cache.size()


## For debug / measurement: total shapes across all cached prototypes.
func get_total_shapes() -> int:
	var total := 0
	for entry: Entry in _cache.values():
		total += entry.shapes.size()
	return total
