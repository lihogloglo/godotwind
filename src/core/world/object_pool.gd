## ObjectPool - Pooling system for frequently instantiated objects
##
## Instead of creating and destroying Node3D instances, this pool
## reuses existing instances by hiding/showing and repositioning them.
##
## Benefits:
## - Reduced allocation/deallocation overhead
## - Lower memory fragmentation
## - Faster cell loading (reuse vs duplicate)
## - Reduced scene tree churn
##
## Usage:
##   var pool := ObjectPool.new()
##   pool.preload_model("meshes/f/flora_kelp_01.nif", 50)  # Pre-create 50 instances
##
##   # When loading cells:
##   var instance := pool.acquire("meshes/f/flora_kelp_01.nif")
##   if instance:
##       instance.transform = desired_transform
##       cell_node.add_child(instance)
##
##   # When unloading cells:
##   pool.release(instance)  # Returns to pool for reuse
class_name ObjectPool
extends RefCounted

## Pool entry for a specific model
class PoolEntry:
	var model_path: String
	var prototype: Node3D                ## Original model to duplicate
	var available: Array[Node3D] = []    ## Instances ready for reuse
	var in_use: Array[Node3D] = []       ## Instances currently in use
	var max_pool_size: int = 100         ## Cap per model type
	var total_created: int = 0           ## Total instances ever created

	func get_available_count() -> int:
		return available.size()

	func get_in_use_count() -> int:
		return in_use.size()


## Model pools: normalized_path -> PoolEntry
var _pools: Dictionary = {}

## Node to parent pooled objects when not in use
var _pool_parent: Node3D = null

## Statistics
var _stats: Dictionary = {
	"total_pools": 0,
	"total_instances": 0,
	"acquires": 0,
	"releases": 0,
	"cache_hits": 0,
	"cache_misses": 0,
	"new_instances_created": 0,
}

## Default pool size limits
var default_pool_size: int = 80
var max_total_instances: int = 10000  ## Global cap across all pools (increased for 100+ model types)


## Initialize the pool with a parent node for storing inactive instances
func init(parent: Node3D) -> void:
	_pool_parent = parent


## Register a model prototype for pooling
## prototype: The Node3D to clone for new instances
## initial_count: Number of instances to pre-create
## max_size: Maximum pool size for this model
func register_model(model_path: String, prototype: Node3D, initial_count: int = 0, max_size: int = -1) -> void:
	var normalized := _normalize_path(model_path)

	if normalized in _pools:
		return  # Already registered

	var entry := PoolEntry.new()
	entry.model_path = normalized
	entry.prototype = prototype
	entry.max_pool_size = max_size if max_size > 0 else default_pool_size

	_pools[normalized] = entry
	_stats["total_pools"] += 1

	# Pre-create initial instances
	if initial_count > 0:
		_preload_instances(entry, initial_count)


## Preload instances for a model (by path)
## Useful for common objects like flora, rocks, etc.
func preload_model(model_path: String, count: int) -> void:
	var normalized := _normalize_path(model_path)

	if normalized not in _pools:
		push_warning("ObjectPool: Model not registered: %s" % model_path)
		return

	var entry: PoolEntry = _pools[normalized]
	_preload_instances(entry, count)


## Acquire an instance from the pool
## Returns null if model not registered or pool exhausted
func acquire(model_path: String) -> Node3D:
	var normalized := _normalize_path(model_path)
	_stats["acquires"] += 1

	if normalized not in _pools:
		_stats["cache_misses"] += 1
		return null

	var entry: PoolEntry = _pools[normalized]

	# Try to get from available pool
	if not entry.available.is_empty():
		var instance: Node3D = entry.available.pop_back()
		entry.in_use.append(instance)
		instance.visible = true
		_stats["cache_hits"] += 1
		return instance

	# Pool exhausted - create new if under limit
	if entry.total_created < entry.max_pool_size and _stats["total_instances"] < max_total_instances:
		var instance := _create_instance(entry)
		if instance:
			entry.in_use.append(instance)
			_stats["cache_misses"] += 1
			return instance

	# Pool fully exhausted
	_stats["cache_misses"] += 1
	return null


## Release an instance back to the pool
## The instance should be removed from its parent before calling this
func release(instance: Node3D) -> void:
	if not instance or not is_instance_valid(instance):
		return

	_stats["releases"] += 1

	# Find which pool this belongs to
	var model_path := instance.get_meta("pool_model_path", "") as String
	if model_path.is_empty():
		# Not a pooled object - just free it
		instance.queue_free()
		return

	if model_path not in _pools:
		instance.queue_free()
		return

	var entry: PoolEntry = _pools[model_path]

	# Remove from in_use list
	var idx := entry.in_use.find(instance)
	if idx >= 0:
		entry.in_use.remove_at(idx)

	# Reset and return to available pool
	_reset_instance(instance)
	entry.available.append(instance)

	# Re-parent to pool parent
	if instance.get_parent():
		instance.get_parent().remove_child(instance)
	if _pool_parent:
		_pool_parent.add_child(instance)


## Release all instances from a cell node back to pools
func release_cell_objects(cell_node: Node3D) -> int:
	var released := 0
	var to_release: Array[Node3D] = []

	# Collect pooled objects
	_collect_pooled_objects(cell_node, to_release)

	# Release them
	for obj in to_release:
		release(obj)
		released += 1

	return released


func _collect_pooled_objects(node: Node, result: Array[Node3D]) -> void:
	if node is Node3D and node.has_meta("pool_model_path"):
		result.append(node as Node3D)
	else:
		# Only traverse non-pooled nodes
		for child in node.get_children():
			_collect_pooled_objects(child, result)


## Check if a model is registered for pooling
func has_model(model_path: String) -> bool:
	return _normalize_path(model_path) in _pools


## Get stats for a specific model
func get_model_stats(model_path: String) -> Dictionary:
	var normalized := _normalize_path(model_path)
	if normalized not in _pools:
		return {}

	var entry: PoolEntry = _pools[normalized]
	return {
		"available": entry.get_available_count(),
		"in_use": entry.get_in_use_count(),
		"total_created": entry.total_created,
		"max_size": entry.max_pool_size,
	}


## Get overall pool statistics
func get_stats() -> Dictionary:
	var total_available := 0
	var total_in_use := 0

	for path: String in _pools:
		var entry: PoolEntry = _pools[path]
		total_available += entry.get_available_count()
		total_in_use += entry.get_in_use_count()

	var stats := _stats.duplicate()
	stats["total_available"] = total_available
	stats["total_in_use"] = total_in_use
	stats["total_instances"] = total_available + total_in_use

	var acquires_count: int = _stats["acquires"]
	if acquires_count > 0:
		var hits_count: int = _stats["cache_hits"]
		stats["hit_rate"] = float(hits_count) / float(acquires_count)
	else:
		stats["hit_rate"] = 0.0

	return stats


## Get list of registered model paths
func get_registered_models() -> Array[String]:
	var models: Array[String] = []
	for path: String in _pools:
		models.append(path)
	return models


## Clear all pools and free all instances
func clear() -> void:
	for path: String in _pools:
		var entry: PoolEntry = _pools[path]

		# Free all available instances
		for instance: Node3D in entry.available:
			if is_instance_valid(instance):
				instance.queue_free()
		entry.available.clear()

		# Free all in-use instances
		for instance: Node3D in entry.in_use:
			if is_instance_valid(instance):
				instance.queue_free()
		entry.in_use.clear()

		entry.total_created = 0

	_pools.clear()
	_stats = {
		"total_pools": 0,
		"total_instances": 0,
		"acquires": 0,
		"releases": 0,
		"cache_hits": 0,
		"cache_misses": 0,
		"new_instances_created": 0,
	}


## Internal: Create a new instance from prototype
func _create_instance(entry: PoolEntry) -> Node3D:
	if not entry.prototype or not is_instance_valid(entry.prototype):
		return null

	var instance: Node3D = entry.prototype.duplicate()
	instance.set_meta("pool_model_path", entry.model_path)
	entry.total_created += 1
	_stats["new_instances_created"] += 1
	_stats["total_instances"] += 1

	return instance


## Internal: Preload multiple instances
func _preload_instances(entry: PoolEntry, count: int) -> void:
	var to_create := mini(count, entry.max_pool_size - entry.total_created)
	var total_inst: int = _stats["total_instances"]
	to_create = mini(to_create, max_total_instances - total_inst)

	for i in range(to_create):
		var instance := _create_instance(entry)
		if instance:
			_reset_instance(instance)
			entry.available.append(instance)
			if _pool_parent:
				_pool_parent.add_child(instance)


## Internal: Reset an instance to default state
func _reset_instance(instance: Node3D) -> void:
	instance.visible = false
	instance.transform = Transform3D.IDENTITY


## Internal: Normalize model path for consistent lookups
func _normalize_path(path: String) -> String:
	return path.to_lower().replace("/", "\\")


## Identify common objects that should be pooled
## Returns a dictionary of model_path -> recommended_pool_size
## Expanded to 100+ models for better cache hit rate (targeting 70%+ hit rate)
static func identify_common_models(cell_manager: Variant) -> Dictionary:
	# Expanded from ~25 to 100+ models for much better cache hit rate
	return {
		# ====== FLORA - High frequency (100+ instances each) ======
		"meshes/f/flora_kelp_01.nif": 150,
		"meshes/f/flora_kelp_02.nif": 150,
		"meshes/f/flora_kelp_03.nif": 150,
		"meshes/f/flora_kelp_04.nif": 150,
		"meshes/f/flora_grass_01.nif": 200,
		"meshes/f/flora_grass_02.nif": 200,
		"meshes/f/flora_grass_03.nif": 200,
		"meshes/f/flora_grass_04.nif": 150,
		"meshes/f/flora_heather_01.nif": 100,
		"meshes/f/flora_ash_grass_r_01.nif": 100,
		"meshes/f/flora_ash_grass_b_01.nif": 100,
		"meshes/f/flora_ash_grass_w_01.nif": 100,

		# Flora - Medium frequency (50-100 instances)
		"meshes/f/flora_comberry_01.nif": 80,
		"meshes/f/flora_marshmerrow_01.nif": 80,
		"meshes/f/flora_marshmerrow_02.nif": 80,
		"meshes/f/flora_marshmerrow_03.nif": 80,
		"meshes/f/flora_wickwheat_01.nif": 80,
		"meshes/f/flora_wickwheat_02.nif": 80,
		"meshes/f/flora_gold_kanet_01.nif": 80,
		"meshes/f/flora_gold_kanet_02.nif": 80,
		"meshes/f/flora_black_anther_01.nif": 80,
		"meshes/f/flora_stoneflower_01.nif": 80,
		"meshes/f/flora_stoneflower_02.nif": 80,
		"meshes/f/flora_bc_fern_01.nif": 80,
		"meshes/f/flora_bc_fern_02.nif": 80,
		"meshes/f/flora_bc_fern_03.nif": 80,
		"meshes/f/flora_saltrice_01.nif": 80,
		"meshes/f/flora_saltrice_02.nif": 80,
		"meshes/f/flora_coda_flower_01.nif": 60,
		"meshes/f/flora_corkbulb_01.nif": 60,
		"meshes/f/flora_hackle-lo_01.nif": 60,
		"meshes/f/flora_hackle-lo_02.nif": 60,
		"meshes/f/flora_scathecraw_01.nif": 60,
		"meshes/f/flora_scathecraw_02.nif": 60,
		"meshes/f/flora_willow_flower_01.nif": 60,

		# ====== TREES - Medium frequency (30-50 instances) ======
		"meshes/f/flora_tree_ai_01.nif": 50,
		"meshes/f/flora_tree_ai_02.nif": 50,
		"meshes/f/flora_tree_ai_03.nif": 50,
		"meshes/f/flora_tree_bc_01.nif": 50,
		"meshes/f/flora_tree_bc_02.nif": 50,
		"meshes/f/flora_tree_gl_01.nif": 40,
		"meshes/f/flora_tree_gl_02.nif": 40,
		"meshes/f/flora_tree_wg_01.nif": 40,
		"meshes/f/flora_tree_wg_02.nif": 40,
		"meshes/f/flora_ash_log_01.nif": 40,
		"meshes/f/flora_ash_log_02.nif": 40,

		# ====== ROCKS - High frequency (80+ instances) ======
		"meshes/r/rock_ai_small_01.nif": 100,
		"meshes/r/rock_ai_small_02.nif": 100,
		"meshes/r/rock_ai_small_03.nif": 100,
		"meshes/r/rock_bc_small_01.nif": 100,
		"meshes/r/rock_bc_small_02.nif": 100,
		"meshes/r/rock_bc_small_03.nif": 100,
		"meshes/r/rock_gl_small_01.nif": 100,
		"meshes/r/rock_gl_small_02.nif": 100,
		"meshes/r/rock_ai_medium_01.nif": 60,
		"meshes/r/rock_ai_medium_02.nif": 60,
		"meshes/r/rock_bc_medium_01.nif": 60,
		"meshes/r/rock_bc_medium_02.nif": 60,
		"meshes/r/rock_gl_medium_01.nif": 60,
		"meshes/r/terrain_rock_ai_01.nif": 80,
		"meshes/r/terrain_rock_ai_02.nif": 80,
		"meshes/r/terrain_rock_bc_01.nif": 80,
		"meshes/r/terrain_rock_bc_02.nif": 80,
		"meshes/r/terrain_rock_gl_01.nif": 80,
		"meshes/r/terrain_rock_rm_01.nif": 80,
		"meshes/r/terrain_rock_rm_02.nif": 80,
		"meshes/r/terrain_rock_wg_01.nif": 80,

		# ====== CONTAINERS - Medium frequency (40-60 instances) ======
		"meshes/c/contain_barrel_01.nif": 60,
		"meshes/c/contain_barrel_02.nif": 60,
		"meshes/c/contain_barrel_03.nif": 50,
		"meshes/c/contain_sack_01.nif": 60,
		"meshes/c/contain_sack_02.nif": 60,
		"meshes/c/contain_crate_01.nif": 50,
		"meshes/c/contain_crate_02.nif": 50,
		"meshes/c/contain_crate_03.nif": 50,
		"meshes/c/contain_chest_02.nif": 40,
		"meshes/c/contain_chest_03.nif": 40,
		"meshes/c/contain_urn_01.nif": 50,
		"meshes/c/contain_urn_02.nif": 50,
		"meshes/c/contain_pot_redware_01.nif": 50,
		"meshes/c/contain_pot_redware_02.nif": 50,

		# ====== LIGHTS - High frequency in interiors (60+ instances) ======
		"meshes/l/light_com_candle_01.nif": 80,
		"meshes/l/light_com_candle_02.nif": 80,
		"meshes/l/light_com_candle_03.nif": 80,
		"meshes/l/light_com_candle_04.nif": 60,
		"meshes/l/light_com_candle_05.nif": 60,
		"meshes/l/light_com_lantern_01.nif": 80,
		"meshes/l/light_com_lantern_02.nif": 80,
		"meshes/l/light_com_sconce_01.nif": 60,
		"meshes/l/light_com_sconce_02.nif": 60,
		"meshes/l/light_de_lantern_01.nif": 60,
		"meshes/l/light_de_lantern_02.nif": 60,

		# ====== FURNITURE - Medium frequency (30-50 instances) ======
		"meshes/f/furn_com_chair_01.nif": 50,
		"meshes/f/furn_com_chair_02.nif": 50,
		"meshes/f/furn_com_chair_03.nif": 40,
		"meshes/f/furn_com_bench_01.nif": 50,
		"meshes/f/furn_com_bench_02.nif": 50,
		"meshes/f/furn_com_table_01.nif": 40,
		"meshes/f/furn_com_table_02.nif": 40,
		"meshes/f/furn_com_table_03.nif": 40,
		"meshes/f/furn_de_bed_01.nif": 40,
		"meshes/f/furn_de_bed_02.nif": 40,
		"meshes/f/furn_de_chair_01.nif": 40,
		"meshes/f/furn_de_table_01.nif": 40,
		"meshes/f/furn_de_shelf_01.nif": 50,
		"meshes/f/furn_de_shelf_02.nif": 50,
		"meshes/f/furn_de_p_shelf_01.nif": 40,
		"meshes/f/furn_com_rm_bookshelf.nif": 40,

		# ====== MISC CLUTTER - Medium frequency (30-50 instances) ======
		"meshes/m/misc_com_bottle_01.nif": 60,
		"meshes/m/misc_com_bottle_02.nif": 60,
		"meshes/m/misc_com_bottle_03.nif": 50,
		"meshes/m/misc_com_bottle_04.nif": 50,
		"meshes/m/misc_com_bottle_05.nif": 50,
		"meshes/m/misc_com_bucket_01.nif": 50,
		"meshes/m/misc_com_bucket_02.nif": 50,
		"meshes/m/misc_com_plate_01.nif": 40,
		"meshes/m/misc_com_plate_02.nif": 40,
		"meshes/m/misc_com_bowl_01.nif": 40,
		"meshes/m/misc_com_bowl_02.nif": 40,
		"meshes/m/misc_com_cup_01.nif": 40,
		"meshes/m/misc_com_cup_02.nif": 40,
		"meshes/m/misc_com_goblet_01.nif": 40,
		"meshes/m/misc_de_bowl_01.nif": 40,
		"meshes/m/misc_de_cup_01.nif": 40,
		"meshes/m/misc_6th_bell_01.nif": 30,
		"meshes/m/misc_de_tankard_01.nif": 40,

		# ====== ARCHITECTURE STATICS - Medium frequency (30-50 instances) ======
		"meshes/x/ex_common_pillar_01.nif": 50,
		"meshes/x/ex_common_pillar_02.nif": 50,
		"meshes/x/ex_common_plat_01.nif": 50,
		"meshes/x/ex_common_plat_02.nif": 40,
		"meshes/x/ex_common_plat_small.nif": 40,
		"meshes/x/ex_hlaalu_fence_01.nif": 50,
		"meshes/x/ex_hlaalu_post_01.nif": 50,
		"meshes/x/ex_de_docks_plank_01.nif": 50,
		"meshes/x/ex_de_docks_plank_02.nif": 50,
		"meshes/x/ex_de_docks_post_01.nif": 40,
		"meshes/x/ex_de_docks_ladder_01.nif": 40,
		"meshes/x/ex_de_shack_plat_01.nif": 40,
		"meshes/x/ex_de_shack_post_01.nif": 40,
		"meshes/x/ex_de_ship_plank_01.nif": 40,
	}
