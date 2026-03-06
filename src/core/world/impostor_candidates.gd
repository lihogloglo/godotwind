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
	"min_distance": DU.FAR_START,  # Start showing at FAR tier (500m)
	"max_distance": DU.FAR_END,    # Stop showing at FAR end (5km)
}

## High-priority landmark patterns (matched against actual BSA files)
## These patterns identify large, distinctive structures visible from distance
const LANDMARK_PATTERNS: Array[String] = [
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

## Cached all impostor models (all categories)
var _cached_all_models: Array[String] = []
var _all_cache_built: bool = false

## Large buildings that should have impostors
const LARGE_BUILDING_PATTERNS: Array[String] = [
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
	# Common buildings (Seyda Neen, etc.)
	"ex_common_house",
	"ex_common_warehouse",
	"ex_common_tower",
	"ex_common_",  # Catch-all for common exterior buildings
	# Nordic buildings
	"ex_nord_",
	# Wooden docks and platforms
	"ex_de_dock",
	"ex_de_shack",
]

## Rock formations visible from distance (expanded for dense world)
const TERRAIN_FEATURE_PATTERNS: Array[String] = [
	# Large distinctive rocks
	"terrain_rock_rm_",   # Red Mountain rocks
	"terrain_rock_big_",  # Big rocks
	"terrain_rock_bc_",   # Bitter Coast rocks
	"terrain_rock_wg_",   # West Gash rocks
	"terrain_rock_ai_",   # Ascadian Isles rocks
	"terrain_rock_gl_",   # Grazelands rocks
	"terrain_rock_ash_",  # Ashlands rocks
	"terrain_rock_ma_",   # Molag Amur rocks
	"terrain_rock_sh_",   # Sheogorad rocks
	# Medium-sized rocks (visible from MID tier)
	"terrain_rock_sm_",   # Small-medium rocks
	# Arches and pillars
	"terrain_arch_",
	"terrain_pillar_",
	# Cliffs and ledges
	"terrain_cliff_",
	"terrain_ledge_",
	# Swamp/water surface details
	"terrain_bc_scum",    # Bitter Coast swamp scum
]

## Trees that should have LODs/impostors (expanded)
const TREE_PATTERNS: Array[String] = [
	# Large trees by region
	"flora_tree_gl",     # Grazelands trees
	"flora_tree_ai",     # Ascadian Isles trees
	"flora_tree_bc",     # Bitter Coast trees
	"flora_tree_wg",     # West Gash trees
	"flora_ashtree",     # Ashlands trees
	# Giant mushrooms (iconic Morrowind flora)
	"flora_emp_tree",    # Emperor Parasol
	"flora_bc_empmush",  # Emperor mushrooms
	# Telvanni mushroom towers (organic buildings)
	"flora_t_mushroom",
	# Other significant vegetation
	"flora_bc_tree",     # Bitter Coast general
	"flora_bc_fern",     # Large ferns
]

## Smaller vegetation that adds density (LOD only, no impostor - too small)
## These are MID tier objects that don't need FAR tier impostors
const VEGETATION_PATTERNS: Array[String] = [
	# Mushrooms (distinctive Morrowind flora)
	"flora_bc_mushroom",   # Bitter Coast mushrooms
	"flora_bc_shelffungus", # Bitter Coast shelf fungus
	"flora_ash_grass",     # Ashlands grass clumps
	"flora_grass_",        # Grass patches
	"flora_bc_grass",      # Bitter Coast grass
	"flora_kelp",          # Underwater kelp
	# Smaller plants with silhouettes
	"flora_bc_fern",
	"flora_bc_podplant",
	"flora_bc_knee",       # Bitter Coast knee-high plants
	"flora_bc_lilypad",    # Bitter Coast lilypads
	"flora_comberry",
	"flora_marshmerrow",
	"flora_saltrice",
	"flora_stoneflower",
	"flora_wickwheat",
	"flora_corkbulb",
	"flora_hackle-lo",
	# Stumps and logs
	"flora_bc_log",
	"flora_bc_stump",
]

## Props and clutter that add life to the world
const PROP_PATTERNS: Array[String] = [
	# Wooden structures
	"ex_de_ship",         # Ships and boats (important for coastal areas)
	"furn_de_rope",       # Ropes and rigging
	# Stone markers and monuments
	"ex_t_menhir",        # Standing stones (Telvanni)
	"ex_ashl_marker",     # Ashlander markers
	"furn_headstone",     # Gravestones
	# Signs and posts
	"furn_sign",          # Town signs
	"ex_de_post",         # Posts
	# Barrels and crates (common outdoor clutter)
	"furn_de_barrel",
	"furn_com_barrel",
	"furn_de_crate",
	# Market stalls
	"furn_de_stall",
	# Wells and fountains
	"furn_well",
	"furn_fountain",
	# Campfires and outdoor fixtures
	"furn_campfire",
	"light_de_lantern_",  # Lanterns on posts
]

## Dunmer architectural details (walls, fences, stairs)
const ARCHITECTURE_DETAIL_PATTERNS: Array[String] = [
	# Walls and fences
	"ex_hlaalu_fence",
	"ex_hlaalu_wall",
	"ex_redoran_fence",
	"ex_redoran_wall",
	"ex_common_wall",
	"ex_common_fence",
	# Stairs and platforms
	"ex_common_stair",
	"ex_hlaalu_stair",
	"ex_redoran_stair",
	"ex_de_docks_stair",
	# Pillars and posts
	"ex_common_pillar",
	"ex_hlaalu_pillar",
	"ex_hlaalu_post",
	# Bridges
	"ex_de_bridge",
	"ex_common_bridge",
	# Platforms and docks (for coastal/river areas)
	"ex_common_plat",
	"ex_de_docks_plat",
	"ex_de_docks_plank",
	"ex_de_docks_post",
	"ex_de_docks_ladder",
	"ex_de_shack_plat",
	"ex_de_shack_post",
]

## Ruined structures (add atmosphere)
const RUIN_PATTERNS: Array[String] = [
	"ex_dwe_ruin",        # Dwemer ruins (catch-all for smaller pieces)
	"ex_dae_ruin",        # Daedric ruins
	"ex_velothi_ruin",    # Velothi ruins
	"ex_hlaalu_ruin",     # Ruined Hlaalu buildings
	"ex_common_ruin",     # Ruined common buildings
	"ex_6th_ruin",        # Sixth House ruins
	"ruin_",              # Generic ruins
]

## Cave and dungeon entrances (visible from outside)
const CAVE_PATTERNS: Array[String] = [
	"ex_cave_door",       # Cave doors
	"ex_bc_cave",         # Bitter Coast cave entrances
	"ex_cave_entrance",   # Generic cave entrances
	"ex_cavern",          # Cavern entrances
	"ex_mine_entrance",   # Mine entrances
	"ex_grotto",          # Grotto entrances
]

## Objects to explicitly skip (never generate LODs)
const SKIP_PATTERNS: Array[String] = [
	"editormarker",       # Editor markers (invisible in-game)
	"xmarker",            # X markers
	"activator_",         # Activators
	"collision_",         # Collision meshes
	"trigger_",           # Trigger volumes
]

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


## All pattern arrays for impostor candidates (order = priority)
const ALL_CANDIDATE_PATTERNS: Array = [
	LANDMARK_PATTERNS,
	LARGE_BUILDING_PATTERNS,
	TERRAIN_FEATURE_PATTERNS,
	TREE_PATTERNS,
	VEGETATION_PATTERNS,
	PROP_PATTERNS,
	ARCHITECTURE_DETAIL_PATTERNS,
	RUIN_PATTERNS,
	CAVE_PATTERNS,
]


## Internal check for impostor candidacy
func _check_impostor_candidate(lower_path: String) -> bool:
	# Check skip patterns first (editor markers, collision, etc.)
	if _matches_any(lower_path, SKIP_PATTERNS):
		return false

	# Check custom overrides
	if lower_path in _custom_candidates:
		return true

	# Check all candidate pattern arrays
	for pattern_array: Array in ALL_CANDIDATE_PATTERNS:
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
	for pattern: String in LANDMARK_PATTERNS:
		if pattern in lower:
			settings["texture_size"] = 1024
			settings["frames"] = 24
			return settings

	# Large buildings get medium-high resolution
	for pattern: String in LARGE_BUILDING_PATTERNS:
		if pattern in lower:
			settings["texture_size"] = 512
			settings["frames"] = 16
			return settings

	# Ruins get medium resolution
	for pattern: String in RUIN_PATTERNS:
		if pattern in lower:
			settings["texture_size"] = 512
			settings["frames"] = 12
			return settings

	# Terrain features (rocks, arches) - medium resolution
	for pattern: String in TERRAIN_FEATURE_PATTERNS:
		if pattern in lower:
			settings["texture_size"] = 512
			settings["frames"] = 12
			return settings

	# Trees get smaller textures (many of them, but iconic)
	for pattern: String in TREE_PATTERNS:
		if pattern in lower:
			settings["texture_size"] = 256
			settings["frames"] = 8
			return settings

	# Architectural details (walls, stairs, platforms) - LOD only, small impostor
	for pattern: String in ARCHITECTURE_DETAIL_PATTERNS:
		if pattern in lower:
			settings["texture_size"] = 256
			settings["frames"] = 8
			return settings

	# Props (barrels, signs, ships) - LOD + small impostor for ships
	for pattern: String in PROP_PATTERNS:
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
	for pattern: String in VEGETATION_PATTERNS:
		if pattern in lower:
			settings["texture_size"] = 128
			settings["frames"] = 4
			# Smaller max distance for small vegetation
			settings["max_distance"] = 2000.0
			return settings

	# Cave/dungeon entrances - medium resolution (important landmarks)
	for pattern: String in CAVE_PATTERNS:
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
	var nif_files: Array = BSAManager.get_files_by_extension(".nif")

	for file_info: Dictionary in nif_files:
		var file_path: String = str(file_info["path"]).to_lower()

		# Only check meshes in the x/ folder (exterior meshes)
		if not "\\x\\" in file_path and not "/x/" in file_path:
			continue

		# Check against landmark patterns
		for pattern: String in LANDMARK_PATTERNS:
			if pattern in file_path:
				_cached_landmark_models.append(str(file_info["path"]))
				break

	_landmark_cache_built = true
	return _cached_landmark_models.duplicate()


## Get all impostor candidate models by scanning BSA for all matching patterns
## This includes landmarks, buildings, terrain, trees, vegetation, props, architecture, ruins
func get_all_impostor_models() -> Array[String]:
	# Return cached results if already built
	if _all_cache_built:
		return _cached_all_models.duplicate()

	_cached_all_models.clear()

	# Scan BSA for files matching all impostor patterns
	if BSAManager.get_archive_count() == 0:
		push_warning("ImpostorCandidates: BSA archives not loaded, cannot scan for impostors")
		return _cached_all_models

	# Get all NIF files from BSA
	var nif_files: Array = BSAManager.get_files_by_extension(".nif")
	var seen: Dictionary = {}  # Avoid duplicates

	# Helper to check and add model if it matches any pattern in a list
	var check_patterns := func(file_path: String, original_path: String, patterns: Array[String]) -> bool:
		for pattern: String in patterns:
			if pattern in file_path:
				_cached_all_models.append(original_path)
				seen[file_path] = true
				return true
		return false

	for file_info: Dictionary in nif_files:
		var file_path: String = str(file_info["path"]).to_lower()
		var original_path: String = str(file_info["path"])

		# Skip if already added
		if file_path in seen:
			continue

		# Check exterior meshes (in x/ folder)
		var is_exterior: bool = "\\x\\" in file_path or "/x/" in file_path

		# Skip editor markers and other non-visual objects
		var should_skip: bool = false
		for skip_pattern: String in SKIP_PATTERNS:
			if skip_pattern in file_path:
				should_skip = true
				break
		if should_skip:
			continue

		if is_exterior:
			# Priority order for exterior meshes
			if check_patterns.call(file_path, original_path, LANDMARK_PATTERNS):
				continue
			if check_patterns.call(file_path, original_path, LARGE_BUILDING_PATTERNS):
				continue
			if check_patterns.call(file_path, original_path, RUIN_PATTERNS):
				continue
			if check_patterns.call(file_path, original_path, TERRAIN_FEATURE_PATTERNS):
				continue
			if check_patterns.call(file_path, original_path, ARCHITECTURE_DETAIL_PATTERNS):
				continue
			if check_patterns.call(file_path, original_path, CAVE_PATTERNS):
				continue

		# Trees, vegetation, and props can be in various folders
		if file_path not in seen:
			if check_patterns.call(file_path, original_path, TREE_PATTERNS):
				continue
		if file_path not in seen:
			if check_patterns.call(file_path, original_path, VEGETATION_PATTERNS):
				continue
		if file_path not in seen:
			if check_patterns.call(file_path, original_path, PROP_PATTERNS):
				continue

	_all_cache_built = true

	# Count by category for logging
	var counts: Dictionary = {
		"landmarks": 0,
		"buildings": 0,
		"ruins": 0,
		"terrain": 0,
		"trees": 0,
		"vegetation": 0,
		"props": 0,
		"architecture": 0,
		"caves": 0,
	}

	for model_path: String in _cached_all_models:
		var lower: String = model_path.to_lower()

		if _matches_any(lower, LANDMARK_PATTERNS):
			counts["landmarks"] += 1
		elif _matches_any(lower, LARGE_BUILDING_PATTERNS):
			counts["buildings"] += 1
		elif _matches_any(lower, RUIN_PATTERNS):
			counts["ruins"] += 1
		elif _matches_any(lower, TERRAIN_FEATURE_PATTERNS):
			counts["terrain"] += 1
		elif _matches_any(lower, TREE_PATTERNS):
			counts["trees"] += 1
		elif _matches_any(lower, VEGETATION_PATTERNS):
			counts["vegetation"] += 1
		elif _matches_any(lower, PROP_PATTERNS):
			counts["props"] += 1
		elif _matches_any(lower, ARCHITECTURE_DETAIL_PATTERNS):
			counts["architecture"] += 1
		elif _matches_any(lower, CAVE_PATTERNS):
			counts["caves"] += 1

	Log.info("streaming", "ImpostorCandidates: Found %d models total" % _cached_all_models.size())
	Log.info("streaming", "  Landmarks: %d, Buildings: %d, Ruins: %d" % [counts["landmarks"], counts["buildings"], counts["ruins"]])
	Log.info("streaming", "  Terrain: %d, Trees: %d, Vegetation: %d" % [counts["terrain"], counts["trees"], counts["vegetation"]])
	Log.info("streaming", "  Props: %d, Architecture: %d, Caves: %d" % [counts["props"], counts["architecture"], counts["caves"]])

	return _cached_all_models.duplicate()


## Helper to check if a path matches any pattern in a list
func _matches_any(lower_path: String, patterns: Array[String]) -> bool:
	for pattern: String in patterns:
		if pattern in lower_path:
			return true
	return false


## Get all impostor candidate patterns
func get_all_patterns() -> Dictionary:
	return {
		"landmarks": LANDMARK_PATTERNS.duplicate(),
		"buildings": LARGE_BUILDING_PATTERNS.duplicate(),
		"ruins": RUIN_PATTERNS.duplicate(),
		"terrain": TERRAIN_FEATURE_PATTERNS.duplicate(),
		"vegetation": VEGETATION_PATTERNS.duplicate(),
		"props": PROP_PATTERNS.duplicate(),
		"architecture": ARCHITECTURE_DETAIL_PATTERNS.duplicate(),
		"trees": TREE_PATTERNS.duplicate(),
		"caves": CAVE_PATTERNS.duplicate(),
		"skip": SKIP_PATTERNS.duplicate(),
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
	# This ensures ESM paths (forward slash) and BSA paths (backslash) produce same hash
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


## Get the impostor texture path for a model
## Returns expected path where impostor texture would be stored
## Format: {base_name}_{md5_hash}.png
## NOTE: The baker receives paths WITHOUT the "meshes\" prefix (e.g., "x\Ex_T_menhir_L_01.nif")
## We must normalize the path the same way for hash consistency
static func get_impostor_texture_path(model_path: String) -> String:
	var hash_key: String = get_hash_key(model_path)
	var normalized: String = normalize_model_path(model_path)
	var base_name: String = normalized.get_file().get_basename()
	# Clean filename and lowercase (match baker output format which is lowercase on disk)
	base_name = base_name.replace("\\", "_").replace("/", "_").replace(" ", "_").to_lower()
	return _get_impostors_dir().path_join("%s_%s.png" % [base_name, hash_key])


## Get the impostor normal texture path for a model
## Format: {base_name}_{md5_hash}_normal.png
static func get_impostor_normal_path(model_path: String) -> String:
	var hash_key: String = get_hash_key(model_path)
	var normalized: String = normalize_model_path(model_path)
	var base_name: String = normalized.get_file().get_basename()
	base_name = base_name.replace("\\", "_").replace("/", "_").replace(" ", "_").to_lower()
	return _get_impostors_dir().path_join("%s_%s_normal.png" % [base_name, hash_key])


## Get the impostor metadata path for a model
## Format: {base_name}_{md5_hash}.json
static func get_impostor_metadata_path(model_path: String) -> String:
	var hash_key: String = get_hash_key(model_path)
	var normalized: String = normalize_model_path(model_path)
	var base_name: String = normalized.get_file().get_basename()
	base_name = base_name.replace("\\", "_").replace("/", "_").replace(" ", "_").to_lower()
	return _get_impostors_dir().path_join("%s_%s.json" % [base_name, hash_key])
