## ModelLoader - Handles NIF model loading and caching
##
## Extracted from CellManager for single responsibility.
## Loads models from BSA archives, converts them to Godot scenes,
## and caches them for reuse.
##
## Supports TWO levels of caching:
## 1. Memory cache: Fast, per-session (lost on restart)
## 2. Disk cache: Persistent, saves converted models as .res files
##
## Disk caching dramatically improves loading times after first run:
## - First run: 300ms-6s per complex model (NIF conversion)
## - Subsequent runs: 1-5ms per model (direct resource load)
##
## Usage:
##   var loader = ModelLoader.new()
##   loader.enable_disk_cache = true  # Enable persistent caching
##   var model = loader.get_model("meshes\\x\\ex_door.nif")
##   var model_with_collision = loader.get_model("meshes\\x\\ex_door.nif", "ex_door_01")
class_name ModelLoader
extends RefCounted

## Cache for loaded models: model_path (lowercase) -> Node3D prototype
var _model_cache: Dictionary = {}

## Enable disk caching of converted models (saves as .res files)
## Set to true to persist converted models between game sessions
var enable_disk_cache: bool = true

## RUNTIME MODE: Only load from disk cache, never convert NIFs
## When true (default for world explorer), models not in disk cache return null
## When false (prebaking mode), missing models trigger NIF conversion
var runtime_mode: bool = true

## Directory for disk cache (set from SettingsManager on first use)
## Defaults to Documents/Godotwind/cache/models/
var _disk_cache_dir: String = ""

## Cache for file existence checks to avoid repeated disk I/O
## Maps disk_path -> bool (exists or not)
## This eliminates repeated FileAccess.file_exists() calls which are slow
var _file_exists_cache: Dictionary = {}

## Pending async load requests: disk_path -> {cache_key: String, callbacks: Array[Callable]}
## Multiple requests for the same model share one load operation
var _pending_async_loads: Dictionary = {}

## Statistics
var _stats: Dictionary = {
	"models_loaded": 0,
	"models_from_cache": 0,
	"models_from_disk": 0,
	"models_from_disk_async": 0,
	"file_exists_cache_hits": 0,
	"models_saved": 0,
}

## Track first saved model for condensed logging
var _first_saved_model: String = ""
var _last_save_report_count: int = 0


## Get or load a model prototype
## Returns cached model if available, loads and converts from BSA if not.
## With disk caching enabled, converted models are saved for instant loading next time.
##
## Parameters:
##   model_path: Path to NIF model (e.g., "meshes\\x\\ex_door.nif")
##   item_id: Optional ESM record ID for collision shape library lookup
##
## Returns:
##   Node3D prototype (never modify, use duplicate()), or null if not found
func get_model(model_path: String, item_id: String = "") -> Node3D:
	var normalized := model_path.to_lower().replace("/", "\\")

	# Cache key includes item_id since same model may need different collision for different items
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()

	# 1. Check memory cache first (fastest)
	if cache_key in _model_cache:
		_stats["models_from_cache"] += 1
		return _model_cache[cache_key]

	# 2. Check disk cache if enabled (fast - direct resource load)
	if enable_disk_cache:
		var disk_path := _get_disk_cache_path(cache_key)
		if _cached_file_exists(disk_path):
			var loaded := _load_from_disk_cache(disk_path)
			if loaded:
				_model_cache[cache_key] = loaded
				_stats["models_from_disk"] += 1
				return loaded

	# 3. RUNTIME MODE: Return null for uncached models (no NIF conversion at runtime)
	# NIF conversion should ONLY happen during prebaking, never during gameplay
	if runtime_mode:
		# Cache null to avoid repeated disk checks
		_model_cache[cache_key] = null
		return null

	# 4. PREBAKING MODE ONLY: Fall back to BSA extraction + NIF conversion
	# This path is only used by prebaking tools, never during world exploration
	var full_path := model_path
	if not model_path.to_lower().begins_with("meshes"):
		full_path = "meshes\\" + model_path

	# Try to load from BSA - check first to avoid error spam
	var nif_data := PackedByteArray()
	if BSAManager.has_file(full_path):
		nif_data = BSAManager.extract_file(full_path)
	elif BSAManager.has_file(model_path):
		nif_data = BSAManager.extract_file(model_path)

	if nif_data.is_empty():
		# Only warn once per model, don't spam
		if not cache_key in _model_cache:
			push_warning("ModelLoader: Model not found in BSA: '%s' (tried meshes\\ prefix too)" % model_path)
		_model_cache[cache_key] = null
		return null

	# Convert NIF to Godot scene with item_id for collision shape lookup
	# NOTE: This only runs during prebaking, not at runtime
	const NIFConverter := preload("res://src/core/nif/nif_converter.gd")
	var converter := NIFConverter.new()
	if not item_id.is_empty():
		converter.collision_item_id = item_id
	var node := converter.convert_buffer(nif_data, full_path)

	if not node:
		# Only warn once per failed model
		if not cache_key in _model_cache:
			push_warning("ModelLoader: Failed to convert NIF: '%s'" % full_path)
		_model_cache[cache_key] = null
		return null

	# 5. Save to disk cache for next time (async-friendly)
	if enable_disk_cache:
		_save_to_disk_cache(node, cache_key)

	_model_cache[cache_key] = node
	_stats["models_loaded"] += 1
	return node


## Clear the model cache and reset statistics
func clear_cache() -> void:
	_model_cache.clear()
	_file_exists_cache.clear()
	_stats["models_loaded"] = 0
	_stats["models_from_cache"] = 0
	_stats["models_from_disk"] = 0
	_stats["file_exists_cache_hits"] = 0


## Cached file existence check - avoids repeated disk I/O
## Results are cached for the session lifetime since prebaked files don't change
func _cached_file_exists(path: String) -> bool:
	if path in _file_exists_cache:
		_stats["file_exists_cache_hits"] += 1
		return _file_exists_cache[path]

	var exists := FileAccess.file_exists(path)
	_file_exists_cache[path] = exists
	return exists


## Get statistics about model loading
## Returns:
##   Dictionary with keys: models_loaded, models_from_cache, models_from_disk, models_from_disk_async, etc.
func get_stats() -> Dictionary:
	return {
		"models_loaded": _stats["models_loaded"],
		"models_from_cache": _stats["models_from_cache"],
		"models_from_disk": _stats["models_from_disk"],
		"models_from_disk_async": _stats["models_from_disk_async"],
		"models_saved": _stats["models_saved"],
		"pending_async_loads": _pending_async_loads.size(),
		"cached_models": _model_cache.size(),
		"file_exists_cache_hits": _stats["file_exists_cache_hits"],
		"file_exists_cache_size": _file_exists_cache.size(),
	}


## Print final summary of saved models (call when batch save is complete)
func print_save_summary() -> void:
	var saved: int = _stats["models_saved"]
	if saved == 0:
		return

	# Only print if there are unreported saves
	if saved > _last_save_report_count:
		if saved == 1:
			print("ModelLoader: Saved %s" % _first_saved_model)
		else:
			print("ModelLoader: Saved %d models total (first: %s)" % [saved, _first_saved_model])
		_last_save_report_count = saved


## Get the number of models currently cached
func get_cache_size() -> int:
	return _model_cache.size()


## Check if a model is already cached
## Parameters:
##   model_path: Path to check
##   item_id: Optional item ID (if different collision)
## Returns:
##   true if model is in cache (even if null)
func has_model(model_path: String, item_id: String = "") -> bool:
	var normalized := model_path.to_lower().replace("/", "\\")
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()
	return cache_key in _model_cache


# =============================================================================
# ASYNC DISK LOADING API
# =============================================================================
# Uses ResourceLoader.load_threaded_request() to load models without blocking
# the main thread. Call request_model_async() to start loading, then call
# process_async_loads() each frame to check for completions.
# =============================================================================

## Request async loading of a model from disk cache
## Returns immediately. Call process_async_loads() to get results.
## Parameters:
##   model_path: Path to NIF model
##   item_id: Optional item ID for collision variations
##   callback: Called when load completes with (model_path: String, item_id: String, model: Node3D)
## Returns:
##   true if load was started or model already cached, false if not in disk cache
func request_model_async(model_path: String, item_id: String = "", callback: Callable = Callable()) -> bool:
	var normalized := model_path.to_lower().replace("/", "\\")
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()

	# 1. Check memory cache first
	if cache_key in _model_cache:
		_stats["models_from_cache"] += 1
		var model: Node3D = _model_cache[cache_key]
		if callback.is_valid():
			callback.call(model_path, item_id, model)
		return true

	# 2. Check if already loading this model
	var disk_path := _get_disk_cache_path(cache_key)
	if disk_path in _pending_async_loads:
		# Already loading - add callback to existing request
		if callback.is_valid():
			_pending_async_loads[disk_path].callbacks.append({
				"callback": callback,
				"model_path": model_path,
				"item_id": item_id
			})
		return true

	# 3. Check disk cache exists
	if not enable_disk_cache or not _cached_file_exists(disk_path):
		# Not in disk cache - in runtime mode this means model isn't prebaked
		if runtime_mode:
			_model_cache[cache_key] = null  # Cache miss
			if callback.is_valid():
				callback.call(model_path, item_id, null)
		return false

	# 4. Start async load
	var err := ResourceLoader.load_threaded_request(disk_path, "PackedScene")
	if err != OK:
		push_warning("ModelLoader: Failed to start async load for %s: %s" % [disk_path, error_string(err)])
		if callback.is_valid():
			callback.call(model_path, item_id, null)
		return false

	# Track pending load
	_pending_async_loads[disk_path] = {
		"cache_key": cache_key,
		"callbacks": [] as Array[Dictionary]
	}
	if callback.is_valid():
		_pending_async_loads[disk_path].callbacks.append({
			"callback": callback,
			"model_path": model_path,
			"item_id": item_id
		})

	return true


## Check if a model is currently being loaded asynchronously
func is_loading_async(model_path: String, item_id: String = "") -> bool:
	var normalized := model_path.to_lower().replace("/", "\\")
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()
	var disk_path := _get_disk_cache_path(cache_key)
	return disk_path in _pending_async_loads


## Process pending async loads - call this every frame
## Returns number of loads completed this frame
func process_async_loads() -> int:
	if _pending_async_loads.is_empty():
		return 0

	var completed := 0
	var to_remove: Array[String] = []

	for disk_path: String in _pending_async_loads:
		var status := ResourceLoader.load_threaded_get_status(disk_path)

		match status:
			ResourceLoader.THREAD_LOAD_LOADED:
				# Load completed successfully
				var packed_scene := ResourceLoader.load_threaded_get(disk_path) as PackedScene
				var model: Node3D = null

				if packed_scene:
					var instance := packed_scene.instantiate()
					if instance is Node3D:
						model = instance as Node3D
					else:
						# Wrong type - corrupted cache
						if instance:
							instance.free()
						DirAccess.remove_absolute(disk_path)
				else:
					# Failed to load - corrupted cache
					DirAccess.remove_absolute(disk_path)

				# Cache the result
				var cache_key: String = _pending_async_loads[disk_path].cache_key
				_model_cache[cache_key] = model
				if model:
					_stats["models_from_disk_async"] += 1

				# Call all callbacks
				for cb_info: Dictionary in _pending_async_loads[disk_path].callbacks:
					var cb: Callable = cb_info.callback
					if cb.is_valid():
						cb.call(cb_info.model_path, cb_info.item_id, model)

				to_remove.append(disk_path)
				completed += 1

			ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				# Load failed
				push_warning("ModelLoader: Async load failed for %s" % disk_path)
				var cache_key: String = _pending_async_loads[disk_path].cache_key
				_model_cache[cache_key] = null

				# Call callbacks with null
				for cb_info: Dictionary in _pending_async_loads[disk_path].callbacks:
					var cb: Callable = cb_info.callback
					if cb.is_valid():
						cb.call(cb_info.model_path, cb_info.item_id, null)

				to_remove.append(disk_path)
				completed += 1

			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				# Still loading - do nothing
				pass

	# Remove completed loads
	for disk_path: String in to_remove:
		_pending_async_loads.erase(disk_path)

	return completed


## Get count of pending async loads
func get_pending_async_count() -> int:
	return _pending_async_loads.size()


## Directly add a model to the cache (for async loading)
## Use this when you've already converted a model and want to cache it.
## Also saves to disk cache if enabled.
## Parameters:
##   model_path: Path to cache under
##   model: The Node3D prototype to cache
##   item_id: Optional item ID for collision variations
func add_to_cache(model_path: String, model: Node3D, item_id: String = "") -> void:
	var normalized := model_path.to_lower().replace("/", "\\")
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()
	_model_cache[cache_key] = model
	if model:
		_stats["models_loaded"] += 1
		# Count meshes for debugging
		var mesh_count := _count_meshes(model)
		# Also save to disk cache for next session
		if enable_disk_cache:
			if mesh_count > 0:
				_save_to_disk_cache(model, cache_key)
			else:
				# Don't cache empty models - they're placeholders like doors/sounds
				pass


## Count MeshInstance3D nodes with valid meshes
func _count_meshes(node: Node) -> int:
	var count := 0
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		if mesh_inst.mesh:
			count += 1
	for child in node.get_children():
		count += _count_meshes(child)
	return count


## Get a model from cache only (doesn't load if not cached)
## Returns null if not in cache or if cache entry is null.
## Parameters:
##   model_path: Path to retrieve
##   item_id: Optional item ID for collision variations
## Returns:
##   Cached Node3D or null if not cached
func get_cached(model_path: String, item_id: String = "") -> Node3D:
	var normalized := model_path.to_lower().replace("/", "\\")
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()

	if cache_key in _model_cache:
		_stats["models_from_cache"] += 1
		return _model_cache[cache_key]
	return null


# =============================================================================
# DISK CACHE IMPLEMENTATION
# =============================================================================
# Saves converted Node3D scenes as PackedScene resources (.res files)
# This allows loading models in 1-5ms instead of 300ms-6s for NIF conversion.
# =============================================================================

## Get the disk cache directory (lazy initialization from SettingsManager)
func _get_disk_cache_dir() -> String:
	if _disk_cache_dir.is_empty():
		_disk_cache_dir = SettingsManager.get_models_path()
	return _disk_cache_dir


## Get the disk cache path for a cache key
## Converts cache_key to a valid filename and returns full path
## NOTE: Strips item_id suffix since prebaked models don't include it
func _get_disk_cache_path(cache_key: String) -> String:
	# Strip item_id suffix if present (e.g., "meshes\x\ex_door.nif:door_01" -> "meshes\x\ex_door.nif")
	# Prebaked models are saved without item_id since collision is already baked in
	var base_key := cache_key
	var colon_pos := cache_key.rfind(":")
	if colon_pos > 0:
		base_key = cache_key.substr(0, colon_pos)

	# Convert to safe filename
	# Example: "meshes\x\ex_door.nif" -> "meshes_x_ex_door_nif.res"
	var safe_name := base_key.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	return _get_disk_cache_dir().path_join(safe_name + ".res")


## Load a model from disk cache
## Returns Node3D instance or null if loading failed
func _load_from_disk_cache(disk_path: String) -> Node3D:
	if not FileAccess.file_exists(disk_path):
		return null

	var packed_scene := ResourceLoader.load(disk_path, "PackedScene") as PackedScene
	if not packed_scene:
		# Cache file is corrupted or incompatible - delete it
		DirAccess.remove_absolute(disk_path)
		return null

	var instance := packed_scene.instantiate()
	if not instance is Node3D:
		# Wrong type - delete corrupted cache
		DirAccess.remove_absolute(disk_path)
		return null

	return instance as Node3D


## Save a model to disk cache
## Saves each mesh as a separate .mesh file, then the scene structure as .res
func _save_to_disk_cache(node: Node3D, cache_key: String) -> void:
	if not node:
		return

	# Ensure cache directory exists
	var cache_dir := _get_disk_cache_dir()
	if not DirAccess.dir_exists_absolute(cache_dir):
		var err := DirAccess.make_dir_recursive_absolute(cache_dir)
		if err != OK:
			push_warning("ModelLoader: Failed to create cache directory: %s" % error_string(err))
			return

	var base_path := _get_disk_cache_path(cache_key).get_basename()

	# First, save all meshes as separate .mesh files and update references
	var mesh_count := _save_meshes_to_disk(node, base_path, 0)

	if mesh_count == 0:
		return  # Nothing to cache

	# CRITICAL: Set owner on all children so PackedScene.pack() includes them
	# Without this, pack() only saves the root node when not in scene tree
	_set_owner_recursive(node, node)

	# Now save the scene (meshes will be referenced by path)
	var scene_path := base_path + ".res"
	var packed_scene := PackedScene.new()
	var pack_result := packed_scene.pack(node)
	if pack_result != OK:
		push_warning("ModelLoader: Failed to pack scene: %s (%s)" % [cache_key, error_string(pack_result)])
		return

	var save_result := ResourceSaver.save(packed_scene, scene_path)
	if save_result != OK:
		push_warning("ModelLoader: Failed to save scene: %s (%s)" % [scene_path, error_string(save_result)])
	else:
		# Update file existence cache so subsequent checks don't hit disk
		_file_exists_cache[scene_path] = true
		_stats["models_saved"] += 1

		# Track first model for condensed logging
		if _first_saved_model.is_empty():
			_first_saved_model = cache_key.get_file()

		# Print condensed progress every 10 models
		if _stats["models_saved"] % 10 == 0:
			var count: int = _stats["models_saved"]
			if count == 10:
				print("ModelLoader: Saved %s and 9 more models..." % _first_saved_model)
			else:
				print("ModelLoader: Saved %d models (last: %s)" % [count, cache_key.get_file()])
			_last_save_report_count = count


## Save all meshes in a node tree to disk and update their resource paths
## Returns count of meshes saved
func _save_meshes_to_disk(node: Node, base_path: String, start_idx: int) -> int:
	var count := start_idx

	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		if mesh_inst.mesh:
			var mesh_path := "%s_mesh_%d.mesh" % [base_path, count]
			var save_result := ResourceSaver.save(mesh_inst.mesh, mesh_path)
			if save_result == OK:
				# Update the mesh to point to the saved file
				mesh_inst.mesh.take_over_path(mesh_path)
				count += 1

	for child in node.get_children():
		count = _save_meshes_to_disk(child, base_path, count)

	return count


## Recursively set owner on all descendants for PackedScene.pack()
func _set_owner_recursive(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		_set_owner_recursive(child, owner_node)


## Prepare resources for saving by giving them unique paths within the scene file
## This allows PackedScene to properly embed all mesh and material data
## Returns count of resources prepared
func _prepare_resources_for_saving(node: Node, scene_path: String, depth: int = 0) -> int:
	var count := 0
	var base_name := scene_path.get_file().get_basename()

	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		if mesh_inst.mesh:
			# Give the mesh a unique internal path
			mesh_inst.mesh.resource_local_to_scene = true
			mesh_inst.mesh.take_over_path("local://mesh_%s_%d" % [base_name, count])
			count += 1
			# Also handle materials
			for i in range(mesh_inst.mesh.get_surface_count()):
				var mat := mesh_inst.mesh.surface_get_material(i)
				if mat:
					mat.resource_local_to_scene = true
					mat.take_over_path("local://mat_%s_%d" % [base_name, count])
					count += 1
					# Handle textures within material
					if mat is StandardMaterial3D:
						var std_mat := mat as StandardMaterial3D
						_prepare_texture(std_mat.albedo_texture, base_name, count)
						_prepare_texture(std_mat.normal_texture, base_name, count + 1)
						count += 2
		# Mark override materials too
		for i in range(mesh_inst.get_surface_override_material_count()):
			var mat := mesh_inst.get_surface_override_material(i)
			if mat:
				mat.resource_local_to_scene = true
				mat.take_over_path("local://override_mat_%s_%d" % [base_name, count])
				count += 1

	if node is CollisionShape3D:
		var shape := (node as CollisionShape3D).shape
		if shape:
			shape.resource_local_to_scene = true
			shape.take_over_path("local://shape_%s_%d" % [base_name, count])
			count += 1

	for child in node.get_children():
		count += _prepare_resources_for_saving(child, scene_path, count)

	return count


## Helper to prepare a texture for saving
func _prepare_texture(tex: Texture2D, base_name: String, idx: int) -> void:
	if tex and tex.resource_path.is_empty():
		tex.resource_local_to_scene = true
		tex.take_over_path("local://tex_%s_%d" % [base_name, idx])


## Clear the disk cache (deletes all cached .res files)
## Use this when game assets have been updated
func clear_disk_cache() -> void:
	var cache_dir := _get_disk_cache_dir()
	if not DirAccess.dir_exists_absolute(cache_dir):
		return

	var dir := DirAccess.open(cache_dir)
	if not dir:
		return

	var deleted := 0
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".res"):
			dir.remove(file_name)
			deleted += 1
		file_name = dir.get_next()
	dir.list_dir_end()

	print("ModelLoader: Cleared disk cache (%d files deleted)" % deleted)


## Get disk cache statistics
## Returns Dictionary with:
##   cache_dir: Path to cache directory
##   file_count: Number of cached files
##   total_size_mb: Total size in MB
func get_disk_cache_stats() -> Dictionary:
	var cache_dir := _get_disk_cache_dir()
	var stats := {
		"cache_dir": cache_dir,
		"file_count": 0,
		"total_size_bytes": 0,
		"total_size_mb": 0.0
	}

	if not DirAccess.dir_exists_absolute(cache_dir):
		return stats

	var dir := DirAccess.open(cache_dir)
	if not dir:
		return stats

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".res"):
			stats["file_count"] += 1
			var file := FileAccess.open(cache_dir + "/" + file_name, FileAccess.READ)
			if file:
				stats["total_size_bytes"] += file.get_length()
				file.close()
		file_name = dir.get_next()
	dir.list_dir_end()

	stats["total_size_mb"] = stats["total_size_bytes"] / (1024.0 * 1024.0)
	return stats


## Check if a model is cached on disk
## Parameters:
##   model_path: Path to check
##   item_id: Optional item ID for collision variations
## Returns:
##   true if model is in disk cache
func has_disk_cached(model_path: String, item_id: String = "") -> bool:
	var normalized := model_path.to_lower().replace("/", "\\")
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()
	var disk_path := _get_disk_cache_path(cache_key)
	return _cached_file_exists(disk_path)
