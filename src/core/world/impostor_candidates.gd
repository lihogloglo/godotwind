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


## Impostor generation settings
const DEFAULT_SETTINGS := {
	"texture_size": 512,       # Resolution per impostor (512-2048)
	"frames": 16,              # Viewing angles (8-32 for octahedral)
	"use_alpha": true,         # Enable alpha cutout
	"optimize_size": true,     # Compress texture
	"min_distance": 2000.0,    # Start showing impostor at 2km
	"max_distance": 5000.0,    # Stop showing at 5km
}

## High-priority landmark patterns (matched against actual BSA files)
## These patterns identify large, distinctive structures visible from distance
const LANDMARK_PATTERNS := [
	# Morrowind cantons and major structures
	"ex_vivec",
	"ex_mournhold",

	# Strongholds and fortresses
	"ex_stronghold",
	"ex_hlaalu_b",  # Hlaalu buildings
	"ex_redoran_b", # Redoran buildings

	# Dwemer ruins (large exterior structures)
	"ex_dwe_",      # Dwemer exterior
	"ex_dwrv_",     # Dwemer ruins

	# Ghostfence
	"ex_ghostfence",

	# Daedric shrines
	"ex_dae_",      # Daedric exterior

	# Imperial forts
	"ex_imp_",

	# Velothi towers
	"ex_velothi",

	# Telvanni towers
	"ex_t_",
]

## Cached landmark models (populated on first call)
var _cached_landmark_models: Array[String] = []
var _landmark_cache_built: bool = false

## Large buildings that should have impostors
const LARGE_BUILDING_PATTERNS := [
	"ex_hlaalu_tower",
	"ex_hlaalu_manor",
	"ex_redoran_tower",
	"ex_redoran_manor",
	"ex_telvanni_tower",
	"ex_telvanni_manor",
	"ex_velothi_tower",
	"ex_imperial_tower",
	"ex_imperial_fort",
	"ex_imperial_castle",
	"ex_dock_",
	"lighthouse",
	"windmill",
	"watchtower",
	"ex_ashl_tower",
]

## Large rock formations visible from distance
const TERRAIN_FEATURE_PATTERNS := [
	"terrain_rock_rm_",  # Large rocks only
	"terrain_rock_big_",
	"terrain_arch_",
	"terrain_pillar_",
]

## Large trees that should have impostors
const TREE_PATTERNS := [
	"flora_tree_gl",     # Grazelands trees
	"flora_tree_ai",     # Ascadian Isles trees
	"flora_tree_bc",     # Bitter Coast trees
	"flora_tree_wg",     # West Gash trees
	"flora_emp_tree",    # Emperor Parasol (large mushroom)
	"flora_ashtree",     # Ashlands trees
]

## Minimum size (meters) for an object to be considered for impostors
const MIN_SIZE_FOR_IMPOSTOR := 5.0

## Cache for checked model paths
var _impostor_cache: Dictionary = {}  # model_path -> bool

## Custom overrides for specific models
var _custom_candidates: Dictionary = {}  # model_path -> settings


## Check if a model should have an impostor generated
func should_have_impostor(model_path: String) -> bool:
	var lower := model_path.to_lower().replace("/", "\\")

	# Check cache
	if lower in _impostor_cache:
		return _impostor_cache[lower]

	var result := _check_impostor_candidate(lower)
	_impostor_cache[lower] = result
	return result


## Internal check for impostor candidacy
func _check_impostor_candidate(lower_path: String) -> bool:
	# Check custom overrides first
	if lower_path in _custom_candidates:
		return true

	# Check landmark patterns
	for pattern in LANDMARK_PATTERNS:
		if pattern in lower_path:
			return true

	# Check building patterns
	for pattern in LARGE_BUILDING_PATTERNS:
		if pattern in lower_path:
			return true

	# Check terrain features
	for pattern in TERRAIN_FEATURE_PATTERNS:
		if pattern in lower_path:
			return true

	# Check large trees
	for pattern in TREE_PATTERNS:
		if pattern in lower_path:
			return true

	return false


## Get impostor generation settings for a model
## Returns settings dict or null if not an impostor candidate
func get_impostor_settings(model_path: String) -> Dictionary:
	if not should_have_impostor(model_path):
		return {}

	var lower := model_path.to_lower().replace("/", "\\")

	# Check custom settings
	if lower in _custom_candidates:
		return _custom_candidates[lower].duplicate()

	# Default settings based on model type
	var settings := DEFAULT_SETTINGS.duplicate()

	# Landmarks get higher resolution
	for pattern in LANDMARK_PATTERNS:
		if pattern in lower:
			settings["texture_size"] = 1024
			settings["frames"] = 24
			return settings

	# Large buildings
	for pattern in LARGE_BUILDING_PATTERNS:
		if pattern in lower:
			settings["texture_size"] = 512
			settings["frames"] = 16
			return settings

	# Trees get smaller textures (many of them)
	for pattern in TREE_PATTERNS:
		if pattern in lower:
			settings["texture_size"] = 256
			settings["frames"] = 8
			return settings

	# Terrain features
	for pattern in TERRAIN_FEATURE_PATTERNS:
		if pattern in lower:
			settings["texture_size"] = 512
			settings["frames"] = 12
			return settings

	return settings


## Add a custom impostor candidate with specific settings
func add_custom_candidate(model_path: String, settings: Dictionary = {}) -> void:
	var lower := model_path.to_lower().replace("/", "\\")
	var custom_settings := DEFAULT_SETTINGS.duplicate()

	for key in settings:
		custom_settings[key] = settings[key]

	_custom_candidates[lower] = custom_settings
	_impostor_cache[lower] = true


## Remove a custom candidate
func remove_custom_candidate(model_path: String) -> void:
	var lower := model_path.to_lower().replace("/", "\\")
	_custom_candidates.erase(lower)
	_impostor_cache.erase(lower)


## Get all landmark model paths by scanning BSA for matching files
func get_landmark_models() -> Array[String]:
	# Return cached results if already built
	if _landmark_cache_built:
		return _cached_landmark_models.duplicate()

	_cached_landmark_models.clear()

	# Scan BSA for files matching landmark patterns
	if BSAManager.get_archive_count() == 0:
		push_warning("ImpostorCandidates: BSA archives not loaded, cannot scan for landmarks")
		return _cached_landmark_models

	# Get all NIF files from BSA
	var nif_files := BSAManager.get_files_by_extension(".nif")

	for file_info in nif_files:
		var file_path: String = file_info["path"].to_lower()

		# Only check meshes in the x/ folder (exterior meshes)
		if not "\\x\\" in file_path and not "/x/" in file_path:
			continue

		# Check against landmark patterns
		for pattern in LANDMARK_PATTERNS:
			if pattern in file_path:
				_cached_landmark_models.append(file_info["path"])
				break

	_landmark_cache_built = true
	print("ImpostorCandidates: Found %d landmark models in BSA" % _cached_landmark_models.size())
	return _cached_landmark_models.duplicate()


## Get all impostor candidate patterns
func get_all_patterns() -> Dictionary:
	return {
		"landmarks": LANDMARK_PATTERNS.duplicate(),
		"buildings": LARGE_BUILDING_PATTERNS.duplicate(),
		"terrain": TERRAIN_FEATURE_PATTERNS.duplicate(),
		"trees": TREE_PATTERNS.duplicate(),
		"custom": _custom_candidates.keys(),
	}


## Clear the cache (call after modifying candidates)
func clear_cache() -> void:
	_impostor_cache.clear()
	_cached_landmark_models.clear()
	_landmark_cache_built = false


## Check if a model path matches any pattern in a list
static func matches_any_pattern(model_path: String, patterns: Array) -> bool:
	var lower := model_path.to_lower()
	for pattern in patterns:
		if pattern in lower:
			return true
	return false


## Get the impostors cache directory from SettingsManager
## Static helper that accesses the autoloaded singleton
static func _get_impostors_dir() -> String:
	var settings: Node = Engine.get_main_loop().root.get_node_or_null("/root/SettingsManager")
	if settings and settings.has_method("get_impostors_path"):
		return settings.get_impostors_path()
	# Fallback if SettingsManager not available (e.g., in editor without autoloads)
	push_warning("ImpostorCandidates: SettingsManager not found, using default path")
	var documents := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	return documents.path_join("Godotwind").path_join("cache").path_join("impostors")


## Get the impostor texture path for a model
## Returns expected path where impostor texture would be stored
static func get_impostor_texture_path(model_path: String) -> String:
	# Hash the model path for unique filename
	var hash_str := str(model_path.to_lower().hash())
	return _get_impostors_dir().path_join("%s_impostor.png" % hash_str)


## Get the impostor metadata path for a model
static func get_impostor_metadata_path(model_path: String) -> String:
	var hash_str := str(model_path.to_lower().hash())
	return _get_impostors_dir().path_join("%s_impostor.json" % hash_str)
