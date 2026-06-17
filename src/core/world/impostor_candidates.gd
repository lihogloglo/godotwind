## ImpostorCandidates - Curated list of objects that should have impostors
##
## Defines which objects are visible from far distances (2km-5km) and
## should be rendered as octahedral impostors instead of full geometry.
##
## Criteria for impostor candidates:
## - Visible from >1km distance
## - Distinctive silhouette (recognizable from far)
## - Static (no animation)
## - Important landmark or common large object
## - Not too small (<5m in any dimension)
##
## Usage:
##   var candidates := ImpostorCandidates.new()
##   if candidates.should_have_impostor(model_path):
##       var settings := candidates.get_impostor_settings(model_path)
class_name ImpostorCandidates
extends RefCounted

const DU := preload("res://src/core/world/distance_utils.gd")

## Impostor generation settings
const DEFAULT_SETTINGS: Dictionary = {
	"texture_size": 512,       # Resolution per impostor (512-2048)
	"frames": 16,              # Viewing angles (8-32 for octahedral)
	"use_alpha": true,         # Enable alpha cutout
	"optimize_size": true,     # Compress texture
	"min_distance": DU.FAR_START,
	"max_distance": DU.FAR_END,    # Stop showing at FAR end (5km)
}

## Cached landmark models (populated on first call)
var _cached_landmark_models: Array[String] = []
var _landmark_cache_built: bool = false

## Cached all impostor models (all categories)
var _cached_all_models: Array[String] = []
var _all_cache_built: bool = false

## Minimum size (meters) for an object to be considered for impostors
const MIN_SIZE_FOR_IMPOSTOR: float = 5.0

## Cache for checked model paths
var _impostor_cache: Dictionary = {}  # model_path -> bool

## Custom overrides for specific models
var _custom_candidates: Dictionary = {}  # model_path -> settings


## Check if a model should have an impostor generated
func should_have_impostor(model_path: String) -> bool:
	var lower: String = model_path.to_lower().replace("/", "\\")

	# Check cache
	if lower in _impostor_cache:
		return _impostor_cache[lower]

	var result: bool = _check_impostor_candidate(lower)
	_impostor_cache[lower] = result
	return result


func get_landmark_patterns() -> Array[String]:
	return []


func get_large_building_patterns() -> Array[String]:
	return []


func get_terrain_feature_patterns() -> Array[String]:
	return []


func get_tree_patterns() -> Array[String]:
	return []


func get_vegetation_patterns() -> Array[String]:
	return []


func get_prop_patterns() -> Array[String]:
	return []


func get_architecture_detail_patterns() -> Array[String]:
	return []


func get_ruin_patterns() -> Array[String]:
	return []


func get_cave_patterns() -> Array[String]:
	return []


func get_skip_patterns() -> Array[String]:
	return []


func get_candidate_pattern_groups() -> Array:
	return [
		get_landmark_patterns(),
		get_large_building_patterns(),
		get_terrain_feature_patterns(),
		get_tree_patterns(),
		get_vegetation_patterns(),
		get_prop_patterns(),
		get_architecture_detail_patterns(),
		get_ruin_patterns(),
		get_cave_patterns(),
	]


## Internal check for impostor candidacy
func _check_impostor_candidate(lower_path: String) -> bool:
	# Check skip patterns first (editor markers, collision, etc.)
	if _matches_any(lower_path, get_skip_patterns()):
		return false

	# Check custom overrides
	if lower_path in _custom_candidates:
		return true

	# Check all candidate pattern arrays
	for pattern_array: Array in get_candidate_pattern_groups():
		if _matches_any(lower_path, pattern_array):
			return true

	return false


## Get impostor generation settings for a model
## Returns settings dict or null if not an impostor candidate
func get_impostor_settings(model_path: String) -> Dictionary:
	if not should_have_impostor(model_path):
		return {}

	var lower: String = model_path.to_lower().replace("/", "\\")

	# Check custom settings
	if lower in _custom_candidates:
		var custom_dict: Dictionary = _custom_candidates[lower]
		return custom_dict.duplicate()

	# Default settings based on model type
	var settings: Dictionary = DEFAULT_SETTINGS.duplicate()

	# Landmarks get higher resolution (Vivec cantons, strongholds, etc.)
	for pattern: String in get_landmark_patterns():
		if pattern in lower:
			settings["texture_size"] = 1024
			settings["frames"] = 24
			return settings

	# Large buildings get medium-high resolution
	for pattern: String in get_large_building_patterns():
		if pattern in lower:
			settings["texture_size"] = 512
			settings["frames"] = 16
			return settings

	# Ruins get medium resolution
	for pattern: String in get_ruin_patterns():
		if pattern in lower:
			settings["texture_size"] = 512
			settings["frames"] = 12
			return settings

	# Terrain features (rocks, arches) - medium resolution
	for pattern: String in get_terrain_feature_patterns():
		if pattern in lower:
			settings["texture_size"] = 512
			settings["frames"] = 12
			return settings

	# Trees get smaller textures (many of them, but iconic)
	for pattern: String in get_tree_patterns():
		if pattern in lower:
			settings["texture_size"] = 256
			settings["frames"] = 8
			return settings

	# Architectural details (walls, stairs, platforms) - LOD only, small impostor
	for pattern: String in get_architecture_detail_patterns():
		if pattern in lower:
			settings["texture_size"] = 256
			settings["frames"] = 8
			return settings

	# Props (barrels, signs, ships) - LOD + small impostor for ships
	for pattern: String in get_prop_patterns():
		if pattern in lower:
			# Ships get bigger impostors since they're larger
			if "ship" in lower:
				settings["texture_size"] = 512
				settings["frames"] = 12
			else:
				settings["texture_size"] = 128
				settings["frames"] = 6
			return settings

	# Vegetation - LOD only, very small impostor (or none)
	for pattern: String in get_vegetation_patterns():
		if pattern in lower:
			settings["texture_size"] = 128
			settings["frames"] = 4
			# Smaller max distance for small vegetation
			settings["max_distance"] = 2000.0
			return settings

	# Cave/dungeon entrances - medium resolution (important landmarks)
	for pattern: String in get_cave_patterns():
		if pattern in lower:
			settings["texture_size"] = 512
			settings["frames"] = 12
			return settings

	return settings


## Add a custom impostor candidate with specific settings
func add_custom_candidate(model_path: String, settings: Dictionary = {}) -> void:
	var lower: String = model_path.to_lower().replace("/", "\\")
	var custom_settings: Dictionary = DEFAULT_SETTINGS.duplicate()

	for key: String in settings:
		custom_settings[key] = settings[key]

	_custom_candidates[lower] = custom_settings
	_impostor_cache[lower] = true


## Remove a custom candidate
func remove_custom_candidate(model_path: String) -> void:
	var lower: String = model_path.to_lower().replace("/", "\\")
	_custom_candidates.erase(lower)
	_impostor_cache.erase(lower)


## Source-neutral hook for catalog-backed landmark paths.
## Source adapters should override this when they can scan source archives.
func get_landmark_models() -> Array[String]:
	return []


## Source-neutral hook for catalog-backed impostor model paths.
## Source adapters should override this when they can scan source archives.
func get_all_impostor_models() -> Array[String]:
	return []


## Helper to check if a path matches any pattern in a list
func _matches_any(lower_path: String, patterns: Array[String]) -> bool:
	for pattern: String in patterns:
		if pattern in lower_path:
			return true
	return false


## Get all impostor candidate patterns
func get_all_patterns() -> Dictionary:
	return {
		"landmarks": get_landmark_patterns().duplicate(),
		"buildings": get_large_building_patterns().duplicate(),
		"ruins": get_ruin_patterns().duplicate(),
		"terrain": get_terrain_feature_patterns().duplicate(),
		"vegetation": get_vegetation_patterns().duplicate(),
		"props": get_prop_patterns().duplicate(),
		"architecture": get_architecture_detail_patterns().duplicate(),
		"trees": get_tree_patterns().duplicate(),
		"caves": get_cave_patterns().duplicate(),
		"skip": get_skip_patterns().duplicate(),
		"custom": _custom_candidates.keys(),
	}


## Clear the cache (call after modifying candidates)
func clear_cache() -> void:
	_impostor_cache.clear()
	_cached_landmark_models.clear()
	_landmark_cache_built = false
	_cached_all_models.clear()
	_all_cache_built = false


## Check if a model path matches any pattern in a list
static func matches_any_pattern(model_path: String, patterns: Array) -> bool:
	var lower: String = model_path.to_lower()
	for pattern: String in patterns:
		if pattern in lower:
			return true
	return false


## Get the impostors cache directory from SettingsManager
## Static helper that accesses the autoloaded singleton
static func _get_impostors_dir() -> String:
	var main_loop: SceneTree = Engine.get_main_loop() as SceneTree
	if main_loop == null:
		push_warning("ImpostorCandidates: Main loop not available, using default path")
		var documents_fallback: String = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
		return documents_fallback.path_join("Godotwind").path_join("cache").path_join("impostors")
	var settings_node: Node = main_loop.root.get_node_or_null("/root/SettingsManager")
	if settings_node and settings_node.has_method("get_impostors_path"):
		return str(settings_node.call("get_impostors_path"))
	# Fallback if SettingsManager not available (e.g., in editor without autoloads)
	push_warning("ImpostorCandidates: SettingsManager not found, using default path")
	var documents: String = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	return documents.path_join("Godotwind").path_join("cache").path_join("impostors")


## Normalize a model path for consistent hashing
## CRITICAL: This must match the baker's normalization exactly!
## - Removes "meshes\" or "meshes/" prefix
## - Converts forward slashes to backslashes
## - Lowercases the result
## Returns the normalized path (not the hash)
static func normalize_model_path(model_path: String) -> String:
	var normalized: String = model_path
	var lower: String = normalized.to_lower()
	if lower.begins_with("meshes\\") or lower.begins_with("meshes/"):
		normalized = normalized.substr(7)  # Remove "meshes\" or "meshes/"
	# CRITICAL: Normalize slashes BEFORE hashing - forward slashes become backslashes
	# This ensures source-record paths and source-archive paths produce the same hash.
	normalized = normalized.replace("/", "\\")
	return normalized.to_lower()


## Get the hash key for a model path (used for texture lookups)
## This is the single source of truth for hash key generation.
## MUST be used everywhere that needs to match impostor textures to model paths.
## Uses MD5 (first 8 chars) for deterministic hashing across sessions and platforms.
## WARNING: String.hash() is NOT deterministic - do not use it for persistent lookups!
static func get_hash_key(model_path: String) -> String:
	var normalized: String = normalize_model_path(model_path)
	# Use MD5 for deterministic hashing (first 8 hex chars = 32 bits of entropy)
	return normalized.md5_text().substr(0, 8)


## v6 octahedral impostors are the only maintained impostor artifact format.
## Runtime fails closed on missing v6 bakes instead of silently rendering older
## cache entries with stale scale, projection, or normal conventions.
static func get_impostor_texture_path_v6(model_path: String) -> String:
	var hash_key: String = get_hash_key(model_path)
	var base_name: String = _impostor_base_name(model_path)
	return _get_impostors_dir().path_join("%s_%s_v6.png" % [base_name, hash_key])


static func get_impostor_normal_res_path_v6(model_path: String) -> String:
	var hash_key: String = get_hash_key(model_path)
	var base_name: String = _impostor_base_name(model_path)
	return _get_impostors_dir().path_join("%s_%s_normal_v6.res" % [base_name, hash_key])


static func get_impostor_metadata_path_v6(model_path: String) -> String:
	var hash_key: String = get_hash_key(model_path)
	var base_name: String = _impostor_base_name(model_path)
	return _get_impostors_dir().path_join("%s_%s_v6.json" % [base_name, hash_key])


static func _impostor_base_name(model_path: String) -> String:
	var normalized: String = normalize_model_path(model_path)
	var base_name: String = normalized.get_file().get_basename()
	return base_name.replace("\\", "_").replace("/", "_").replace(" ", "_").to_lower()
