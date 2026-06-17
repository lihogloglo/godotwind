class_name MorrowindImpostorCandidates
extends ImpostorCandidates

const LANDMARK_PATTERNS: Array[String] = [
	"ex_vivec",
	"ex_mournhold",
	"ex_stronghold",
	"ex_hlaalu_b",
	"ex_redoran_b",
	"ex_dwe_",
	"ex_dwrv_",
	"ex_ghostfence",
	"ex_dae_",
	"ex_imp_",
	"ex_velothi",
	"ex_t_",
]

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
	"ex_common_house",
	"ex_common_warehouse",
	"ex_common_tower",
	"ex_common_",
	"ex_nord_",
	"ex_de_dock",
	"ex_de_shack",
]

const TERRAIN_FEATURE_PATTERNS: Array[String] = [
	"terrain_rock_rm_",
	"terrain_rock_big_",
	"terrain_rock_bc_",
	"terrain_rock_wg_",
	"terrain_rock_ai_",
	"terrain_rock_gl_",
	"terrain_rock_ash_",
	"terrain_rock_ma_",
	"terrain_rock_sh_",
	"terrain_rock_sm_",
	"terrain_arch_",
	"terrain_pillar_",
	"terrain_cliff_",
	"terrain_ledge_",
	"terrain_bc_scum",
]

const TREE_PATTERNS: Array[String] = [
	"flora_tree_gl",
	"flora_tree_ai",
	"flora_tree_bc",
	"flora_tree_wg",
	"flora_ashtree",
	"flora_emp_tree",
	"flora_bc_empmush",
	"flora_t_mushroom",
	"flora_bc_tree",
	"flora_bc_fern",
]

const VEGETATION_PATTERNS: Array[String] = [
	"flora_bc_mushroom",
	"flora_bc_shelffungus",
	"flora_ash_grass",
	"flora_grass_",
	"flora_bc_grass",
	"flora_kelp",
	"flora_bc_fern",
	"flora_bc_podplant",
	"flora_bc_knee",
	"flora_bc_lilypad",
	"flora_comberry",
	"flora_marshmerrow",
	"flora_saltrice",
	"flora_stoneflower",
	"flora_wickwheat",
	"flora_corkbulb",
	"flora_hackle-lo",
	"flora_bc_log",
	"flora_bc_stump",
]

const PROP_PATTERNS: Array[String] = [
	"ex_de_ship",
	"furn_de_rope",
	"ex_t_menhir",
	"ex_ashl_marker",
	"furn_headstone",
	"furn_sign",
	"ex_de_post",
	"furn_de_barrel",
	"furn_com_barrel",
	"furn_de_crate",
	"furn_de_stall",
	"furn_well",
	"furn_fountain",
	"furn_campfire",
	"light_de_lantern_",
]

const ARCHITECTURE_DETAIL_PATTERNS: Array[String] = [
	"ex_hlaalu_fence",
	"ex_hlaalu_wall",
	"ex_redoran_fence",
	"ex_redoran_wall",
	"ex_common_wall",
	"ex_common_fence",
	"ex_common_stair",
	"ex_hlaalu_stair",
	"ex_redoran_stair",
	"ex_de_docks_stair",
	"ex_common_pillar",
	"ex_hlaalu_pillar",
	"ex_hlaalu_post",
	"ex_de_bridge",
	"ex_common_bridge",
	"ex_common_plat",
	"ex_de_docks_plat",
	"ex_de_docks_plank",
	"ex_de_docks_post",
	"ex_de_docks_ladder",
	"ex_de_shack_plat",
	"ex_de_shack_post",
]

const RUIN_PATTERNS: Array[String] = [
	"ex_dwe_ruin",
	"ex_dae_ruin",
	"ex_velothi_ruin",
	"ex_hlaalu_ruin",
	"ex_common_ruin",
	"ex_6th_ruin",
	"ruin_",
]

const CAVE_PATTERNS: Array[String] = [
	"ex_cave_door",
	"ex_bc_cave",
	"ex_cave_entrance",
	"ex_cavern",
	"ex_mine_entrance",
	"ex_grotto",
]

const SKIP_PATTERNS: Array[String] = [
	"editormarker",
	"xmarker",
	"activator_",
	"collision_",
	"trigger_",
]


func get_landmark_patterns() -> Array[String]:
	return LANDMARK_PATTERNS


func get_large_building_patterns() -> Array[String]:
	return LARGE_BUILDING_PATTERNS


func get_terrain_feature_patterns() -> Array[String]:
	return TERRAIN_FEATURE_PATTERNS


func get_tree_patterns() -> Array[String]:
	return TREE_PATTERNS


func get_vegetation_patterns() -> Array[String]:
	return VEGETATION_PATTERNS


func get_prop_patterns() -> Array[String]:
	return PROP_PATTERNS


func get_architecture_detail_patterns() -> Array[String]:
	return ARCHITECTURE_DETAIL_PATTERNS


func get_ruin_patterns() -> Array[String]:
	return RUIN_PATTERNS


func get_cave_patterns() -> Array[String]:
	return CAVE_PATTERNS


func get_skip_patterns() -> Array[String]:
	return SKIP_PATTERNS


## Get all landmark model paths by scanning loaded Morrowind BSA archives.
func get_landmark_models() -> Array[String]:
	if _landmark_cache_built:
		return _cached_landmark_models.duplicate()

	_cached_landmark_models.clear()

	if BSAManager.get_archive_count() == 0:
		push_warning("MorrowindImpostorCandidates: BSA archives not loaded, cannot scan for landmarks")
		return _cached_landmark_models

	var nif_files: Array = BSAManager.get_files_by_extension(".nif")

	for file_info: Dictionary in nif_files:
		var file_path: String = str(file_info["path"]).to_lower()

		if not "\\x\\" in file_path and not "/x/" in file_path:
			continue

		for pattern: String in LANDMARK_PATTERNS:
			if pattern in file_path:
				_cached_landmark_models.append(str(file_info["path"]))
				break

	_landmark_cache_built = true
	return _cached_landmark_models.duplicate()


## Get all impostor candidate models by scanning loaded Morrowind BSA archives.
func get_all_impostor_models() -> Array[String]:
	if _all_cache_built:
		return _cached_all_models.duplicate()

	_cached_all_models.clear()

	if BSAManager.get_archive_count() == 0:
		push_warning("MorrowindImpostorCandidates: BSA archives not loaded, cannot scan for impostors")
		return _cached_all_models

	var nif_files: Array = BSAManager.get_files_by_extension(".nif")
	var seen: Dictionary = {}

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

		if file_path in seen:
			continue

		var is_exterior: bool = "\\x\\" in file_path or "/x/" in file_path
		if _matches_any(file_path, SKIP_PATTERNS):
			continue

		if is_exterior:
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

		if file_path not in seen and check_patterns.call(file_path, original_path, TREE_PATTERNS):
			continue
		if file_path not in seen and check_patterns.call(file_path, original_path, VEGETATION_PATTERNS):
			continue
		if file_path not in seen and check_patterns.call(file_path, original_path, PROP_PATTERNS):
			continue

	_all_cache_built = true
	_log_candidate_counts()
	return _cached_all_models.duplicate()


func _log_candidate_counts() -> void:
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

	Log.info("streaming", "MorrowindImpostorCandidates: Found %d models total" % _cached_all_models.size())
	Log.info("streaming", "  Landmarks: %d, Buildings: %d, Ruins: %d" % [counts["landmarks"], counts["buildings"], counts["ruins"]])
	Log.info("streaming", "  Terrain: %d, Trees: %d, Vegetation: %d" % [counts["terrain"], counts["trees"], counts["vegetation"]])
	Log.info("streaming", "  Props: %d, Architecture: %d, Caves: %d" % [counts["props"], counts["architecture"], counts["caves"]])
