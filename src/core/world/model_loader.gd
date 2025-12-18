## ModelLoader - Handles NIF model loading and caching
##
## Extracted from CellManager for single responsibility.
## Loads models from BSA archives, converts them to Godot scenes,
## and caches them for reuse.
##
## Usage:
##   var loader = ModelLoader.new()
##   var model = loader.get_model("meshes\\x\\ex_door.nif")
##   var model_with_collision = loader.get_model("meshes\\x\\ex_door.nif", "ex_door_01")
class_name ModelLoader
extends RefCounted

const NIFConverter := preload("res://src/core/nif/nif_converter.gd")

## Cache for loaded models: model_path (lowercase) -> Node3D prototype
var _model_cache: Dictionary = {}

## Statistics
var _stats: Dictionary = {
	"models_loaded": 0,
	"models_from_cache": 0,
}


## Get or load a model prototype
## Returns cached model if available, loads and converts from BSA if not.
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

	if cache_key in _model_cache:
		_stats["models_from_cache"] += 1
		return _model_cache[cache_key]

	# Build the full path - ESM stores paths relative to meshes/
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

	_model_cache[cache_key] = node
	_stats["models_loaded"] += 1
	return node


## Clear the model cache and reset statistics
func clear_cache() -> void:
	_model_cache.clear()
	_stats["models_loaded"] = 0
	_stats["models_from_cache"] = 0


## Get statistics about model loading
## Returns:
##   Dictionary with keys: models_loaded, models_from_cache, cached_models
func get_stats() -> Dictionary:
	return {
		"models_loaded": _stats["models_loaded"],
		"models_from_cache": _stats["models_from_cache"],
		"cached_models": _model_cache.size(),
	}


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


## Directly add a model to the cache (for async loading)
## Use this when you've already converted a model and want to cache it.
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
