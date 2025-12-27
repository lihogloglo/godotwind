## PrebakingManager - Orchestrates all prebaking operations
##
## Coordinates the prebaking of:
## - Impostors (octahedral textures for FAR tier)
## - Merged meshes (simplified cells for MID tier)
## - Navigation meshes (pathfinding)
## - Shore masks (ocean visibility)
##
## Features:
## - Resume capability (persists progress)
## - Parallel processing where possible
## - Per-component enable/disable
## - Progress tracking with UI signals
@tool
class_name PrebakingManager
extends Node

const PrebakeState := preload("res://src/tools/prebaking/prebake_state.gd")
const ImpostorBakerV2 := preload("res://src/tools/prebaking/impostor_baker_v2.gd")
const MeshPrebakerV2 := preload("res://src/tools/prebaking/mesh_prebaker_v2.gd")
const ModelPrebaker := preload("res://src/tools/prebaking/model_prebaker.gd")
const NavMeshBaker := preload("res://src/tools/navmesh_baker.gd")
const ShoreMaskBaker := preload("res://src/tools/shore_mask_baker.gd")
const ImpostorCandidates := preload("res://src/core/world/impostor_candidates.gd")
const TerrainManagerScript := preload("res://src/core/world/terrain_manager.gd")
const TerrainTextureLoaderScript := preload("res://src/core/world/terrain_texture_loader.gd")
const CS := preload("res://src/core/coordinate_system.gd")

## Baking components
enum Component {
	TERRAIN,       # Preprocessed Terrain3D regions (heightmaps, textures)
	MODELS,        # Individual NIF->Godot conversions (NEAR tier)
	IMPOSTORS,     # Octahedral impostor textures (FAR tier)
	MERGED_MESHES, # Simplified merged cell meshes (MID tier)
	NAVMESHES,     # Navigation meshes
	SHORE_MASK,    # Ocean visibility mask
	CLOUD_NOISE,   # 3D noise textures for volumetric clouds
}

## Baking status
enum Status {
	IDLE,
	RUNNING,
	PAUSED,
	COMPLETED,
	ERROR,
}

## Current status
var status: Status = Status.IDLE

## State persistence
var state: PrebakeState.ComponentState = null
var _state_manager: PrebakeState = null

## Bakers
var _model_baker: ModelPrebaker = null
var _impostor_baker: ImpostorBakerV2 = null
var _mesh_baker: MeshPrebakerV2 = null
var _navmesh_baker: NavMeshBaker = null
var _shore_baker: ShoreMaskBaker = null

## Component enable flags
var enable_terrain: bool = true
var enable_models: bool = true
var enable_impostors: bool = true
var enable_merged_meshes: bool = true
var enable_navmeshes: bool = true
var enable_shore_mask: bool = true
var enable_cloud_noise: bool = true

## Current component being processed
var _current_component: Component = Component.TERRAIN
var _is_processing: bool = false
var _should_stop: bool = false

## Terrain3D reference (for shore mask and navmesh)
var terrain_3d: Node = null

## Progress signals
signal component_started(component: String)
signal component_progress(component: String, current: int, total: int, item_name: String)
signal component_completed(component: String, success: int, failed: int, skipped: int)
signal item_baked(component: String, item_name: String, success: bool)
signal all_completed(results: Dictionary)
signal status_changed(new_status: int)
signal error_occurred(component: String, error: String)


## Whether ESM data has been loaded
var _esm_loaded: bool = false

func _ready() -> void:
	_state_manager = PrebakeState.new()
	_state_manager.load_state()


## Ensure ESM and BSA data is loaded (required for baking)
func _ensure_data_loaded() -> bool:
	if _esm_loaded:
		return true

	# Check if already loaded by another system
	if ESMManager.cells.size() > 0:
		_esm_loaded = true
		print("PrebakingManager: ESM already loaded (%d cells)" % ESMManager.cells.size())
		return true

	print("PrebakingManager: Loading ESM data...")

	# Initialize BSA
	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		push_error("PrebakingManager: No Morrowind data path configured in settings")
		error_occurred.emit("Init", "No Morrowind data path configured")
		return false

	# Load BSA archives if not already loaded
	if BSAManager.get_archive_count() == 0:
		var loaded := BSAManager.load_archives_from_directory(data_path)
		if loaded == 0:
			push_error("PrebakingManager: No BSA archives found in: %s" % data_path)
			error_occurred.emit("Init", "No BSA archives found")
			return false
		print("PrebakingManager: Loaded %d BSA archives" % loaded)

	# Load ESM file
	var esm_file: String = SettingsManager.get_esm_file()
	var esm_path := data_path.path_join(esm_file)

	var esm_error := ESMManager.load_file(esm_path)
	if esm_error != OK:
		push_error("PrebakingManager: Failed to load ESM: %s" % error_string(esm_error))
		error_occurred.emit("Init", "Failed to load ESM file: " + esm_file)
		return false

	print("PrebakingManager: ESM loaded - %d cells, %d statics" % [ESMManager.cells.size(), ESMManager.statics.size()])
	_esm_loaded = true
	return true


func _exit_tree() -> void:
	if _impostor_baker:
		_impostor_baker.queue_free()


## Start prebaking all enabled components
func start_prebaking() -> void:
	if _is_processing:
		push_warning("PrebakingManager: Already processing")
		return

	print("=".repeat(80))
	print("PrebakingManager: Starting prebaking")
	print("=".repeat(80))

	# Ensure ESM/BSA data is loaded
	if not _ensure_data_loaded():
		push_error("PrebakingManager: Cannot start - data not loaded")
		status = Status.ERROR
		status_changed.emit(status)
		return

	_is_processing = true
	_should_stop = false
	status = Status.RUNNING
	status_changed.emit(status)

	_state_manager.is_running = true
	_state_manager.save_state()

	# Process components in order
	var results := {}

	# Terrain first - required for shore mask and provides base terrain data
	if enable_terrain and not _should_stop:
		_current_component = Component.TERRAIN
		results["terrain"] = await _bake_terrain()

	# Models - most impactful for load times
	if enable_models and not _should_stop:
		_current_component = Component.MODELS
		results["models"] = await _bake_models()

	if enable_impostors and not _should_stop:
		_current_component = Component.IMPOSTORS
		results["impostors"] = await _bake_impostors()

	if enable_merged_meshes and not _should_stop:
		_current_component = Component.MERGED_MESHES
		results["merged_meshes"] = await _bake_merged_meshes()

	if enable_navmeshes and not _should_stop:
		_current_component = Component.NAVMESHES
		results["navmeshes"] = await _bake_navmeshes()

	if enable_shore_mask and not _should_stop:
		_current_component = Component.SHORE_MASK
		results["shore_mask"] = await _bake_shore_mask()

	if enable_cloud_noise and not _should_stop:
		_current_component = Component.CLOUD_NOISE
		results["cloud_noise"] = await _bake_cloud_noise()

	# Complete
	_is_processing = false
	_state_manager.is_running = false
	_state_manager.save_state()

	if _should_stop:
		status = Status.PAUSED
		print("PrebakingManager: Paused by user")
	else:
		status = Status.COMPLETED
		print("PrebakingManager: All components completed")

	status_changed.emit(status)
	all_completed.emit(results)


## Stop prebaking (can be resumed later)
func stop_prebaking() -> void:
	print("PrebakingManager: Stop requested")
	_should_stop = true


## Reset all progress and start fresh
## If clear_cache is true, also deletes all cached files from disk
func reset_all(clear_cache: bool = true) -> void:
	if _is_processing:
		push_warning("PrebakingManager: Cannot reset while processing")
		return

	_state_manager.clear_state()

	if clear_cache:
		_clear_cache_directories()

	status = Status.IDLE
	status_changed.emit(status)
	print("PrebakingManager: Reset all progress%s" % (" and cleared cache" if clear_cache else ""))


## Clear all cached files from disk
func _clear_cache_directories() -> void:
	var directories := [
		SettingsManager.get_terrain_path(),
		SettingsManager.get_models_path(),
		SettingsManager.get_impostors_path(),
		SettingsManager.get_merged_cells_path(),
		SettingsManager.get_navmeshes_path(),
		SettingsManager.get_ocean_path(),
	]

	for dir_path: String in directories:
		if DirAccess.dir_exists_absolute(dir_path):
			var deleted := _delete_directory_contents(dir_path)
			print("PrebakingManager: Cleared %d files from %s" % [deleted, dir_path])


## Delete all files in a directory (not subdirectories)
func _delete_directory_contents(dir_path: String) -> int:
	var dir := DirAccess.open(dir_path)
	if not dir:
		push_warning("PrebakingManager: Cannot open directory: %s" % dir_path)
		return 0

	var deleted := 0
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var full_path := dir_path.path_join(file_name)
			var err := DirAccess.remove_absolute(full_path)
			if err == OK:
				deleted += 1
			else:
				push_warning("PrebakingManager: Failed to delete: %s" % full_path)
		file_name = dir.get_next()
	dir.list_dir_end()

	return deleted


## Get current state summary
func get_state_summary() -> Dictionary:
	return _state_manager.get_summary()


## Check if there's pending work to resume
func has_pending_work() -> bool:
	return _state_manager.has_pending_work()


## Bake terrain (heightmaps, textures -> Terrain3D regions)
func _bake_terrain() -> Dictionary:
	print("\n" + "=".repeat(80))
	print("TERRAIN: Preprocessing Terrain3D regions")
	print("=".repeat(80))

	component_started.emit("Terrain")

	# Get terrain state
	var state: PrebakeState.ComponentState = _state_manager.terrain

	# Check if already completed
	if state.is_complete() and not state.pending.is_empty():
		print("  Terrain already preprocessed, skipping")
		component_completed.emit("Terrain", state.completed.size(), 0, 0)
		return {"success": state.completed.size(), "failed": 0, "skipped": 0}

	# Create or get Terrain3D
	if not terrain_3d:
		# Create a temporary Terrain3D for preprocessing
		if not ClassDB.class_exists("Terrain3D"):
			error_occurred.emit("Terrain", "Terrain3D addon not loaded")
			return {"success": 0, "failed": 1, "error": "Terrain3D addon not loaded"}

		terrain_3d = Terrain3D.new()
		terrain_3d.name = "PrebakingTerrain3D"
		add_child(terrain_3d)

		# Use shared configuration from CoordinateSystem (single source of truth)
		CS.configure_terrain3d(terrain_3d as Terrain3D)

		# Wait a frame for initialization
		await get_tree().process_frame

	# Create terrain manager and texture loader
	var terrain_manager := TerrainManagerScript.new()
	var texture_loader := TerrainTextureLoaderScript.new()

	# Load terrain textures
	var terrain_assets: Terrain3DAssets = (terrain_3d as Terrain3D).assets
	var textures_loaded := texture_loader.load_terrain_textures(terrain_assets)
	print("  Loaded %d terrain textures" % textures_loaded)
	terrain_manager.set_texture_slot_mapper(texture_loader)

	# Collect all unique regions that have terrain data
	var regions_with_data: Dictionary = {}  # region_coord -> true

	for key: String in ESMManager.lands:
		var land: LandRecord = ESMManager.lands[key]
		if not land or not land.has_heights():
			continue
		var region_coord: Vector2i = terrain_manager.cell_to_region(Vector2i(land.cell_x, land.cell_y))
		regions_with_data[region_coord] = true

	# Initialize pending list if needed
	if state.pending.is_empty() and state.completed.is_empty():
		for region_coord: Vector2i in regions_with_data.keys():
			state.pending.append("%d,%d" % [region_coord.x, region_coord.y])
		state.start_time = Time.get_unix_time_from_system()
		_state_manager.save_state()

	print("  Found %d regions (%d pending, %d completed)" % [
		regions_with_data.size(), state.pending.size(), state.completed.size()])

	# Process each combined region
	var total := state.pending.size() + state.completed.size()
	var processed := 0
	var failed := 0

	# Create callable for getting LAND records
	var get_land_func := func(cell_x: int, cell_y: int) -> LandRecord:
		return ESMManager.get_land(cell_x, cell_y)

	var pending_copy := state.pending.duplicate()
	for region_key: String in pending_copy:
		if _should_stop:
			break

		# Parse region coordinate
		var parts := region_key.split(",")
		var region_coord := Vector2i(int(parts[0]), int(parts[1]))

		# Import combined region (4x4 cells at once)
		if terrain_manager.import_combined_region(terrain_3d as Terrain3D, region_coord, get_land_func):
			processed += 1
			state.completed.append(region_key)
			state.last_baked = region_key
			item_baked.emit("Terrain", region_key, true)
		else:
			failed += 1
			state.failed.append(region_key)
			item_baked.emit("Terrain", region_key, false)

		state.pending.erase(region_key)

		# Update progress
		var current := state.completed.size() + state.failed.size()
		component_progress.emit("Terrain", current, total, region_key)

		# Yield periodically to keep UI responsive
		if current % 10 == 0:
			_state_manager.save_state()
			await get_tree().process_frame

	# Save terrain data to disk
	if processed > 0:
		var terrain_data_dir := SettingsManager.get_terrain_path()
		DirAccess.make_dir_recursive_absolute(terrain_data_dir)
		var terrain_node := terrain_3d as Terrain3D
		terrain_node.data.save_directory(terrain_data_dir)
		print("  Saved terrain to: %s" % terrain_data_dir)

	state.end_time = Time.get_unix_time_from_system()
	_state_manager.save_state()

	component_completed.emit("Terrain", processed, failed, 0)

	return {"success": processed, "failed": failed, "skipped": 0}


## Bake individual models (NIF -> Godot conversion)
func _bake_models() -> Dictionary:
	print("\n" + "=".repeat(80))
	print("MODELS: Pre-converting NIF models to Godot resources")
	print("=".repeat(80))

	component_started.emit("Models")

	_model_baker = ModelPrebaker.new()

	if _model_baker.initialize() != OK:
		error_occurred.emit("Models", "Failed to initialize model baker")
		return {"success": 0, "failed": 0, "skipped": 0, "error": "Initialization failed"}

	# Connect progress signals
	_model_baker.progress.connect(func(current: int, total: int, name: String) -> void:
		component_progress.emit("Models", current, total, name)
	)
	_model_baker.model_baked.connect(func(path: String, success: bool, mesh_count: int) -> void:
		item_baked.emit("Models", path, success)
	)

	# Bake all models
	var result: Dictionary = await _model_baker.bake_all_models()

	component_completed.emit("Models", result.success, result.failed, result.skipped)

	return result


## Bake impostors
func _bake_impostors() -> Dictionary:
	print("\n" + "=".repeat(80))
	print("IMPOSTORS: Baking octahedral impostor textures")
	print("=".repeat(80))

	component_started.emit("Impostors")

	# Create baker if needed
	if not _impostor_baker:
		_impostor_baker = ImpostorBakerV2.new()
		add_child(_impostor_baker)

	# Get pending items
	var impostor_state: PrebakeState.ComponentState = _state_manager.impostors
	if impostor_state.pending.is_empty():
		# Build initial pending list from impostor candidates
		var candidates := ImpostorCandidates.new()
		impostor_state.pending = candidates.get_landmark_models().duplicate()
		impostor_state.start_time = Time.get_unix_time_from_system()

	print("  %d pending, %d completed, %d failed" % [
		impostor_state.pending.size(), impostor_state.completed.size(), impostor_state.failed.size()])

	if _impostor_baker.initialize() != OK:
		error_occurred.emit("Impostors", "Failed to initialize impostor baker")
		return {"success": 0, "failed": 0, "error": "Initialization failed"}

	# Connect progress
	_impostor_baker.progress.connect(func(current: int, total: int, name: String) -> void:
		component_progress.emit("Impostors", current, total, name)
	)
	_impostor_baker.model_baked.connect(func(path: String, success: bool, output: String) -> void:
		item_baked.emit("Impostors", path, success)
		if success:
			impostor_state.completed.append(path)
			impostor_state.pending.erase(path)
			impostor_state.last_baked = path
		else:
			impostor_state.failed.append(path)
			impostor_state.pending.erase(path)
		_state_manager.save_state()
	)

	# Bake pending items (must await since bake_models is now async)
	var pending: Array = impostor_state.pending.duplicate()
	var result: Dictionary = await _impostor_baker.bake_models(pending)

	impostor_state.end_time = Time.get_unix_time_from_system()
	_state_manager.save_state()

	component_completed.emit("Impostors", result.success, result.failed, 0)

	return result


## Bake merged meshes
func _bake_merged_meshes() -> Dictionary:
	print("\n" + "=".repeat(80))
	print("MERGED MESHES: Baking simplified cell meshes")
	print("=".repeat(80))

	component_started.emit("Merged Meshes")

	_mesh_baker = MeshPrebakerV2.new()

	# Get pending items
	var mesh_state: PrebakeState.ComponentState = _state_manager.merged_meshes
	if mesh_state.pending.is_empty():
		# Build initial pending list from ESM cells
		var cells := _get_all_exterior_cells()
		for cell: Vector2i in cells:
			mesh_state.pending.append("%d,%d" % [cell.x, cell.y])
		mesh_state.start_time = Time.get_unix_time_from_system()

	print("  %d pending, %d completed, %d failed" % [
		mesh_state.pending.size(), mesh_state.completed.size(), mesh_state.failed.size()])

	if _mesh_baker.initialize() != OK:
		error_occurred.emit("Merged Meshes", "Failed to initialize mesh baker")
		return {"success": 0, "failed": 0, "error": "Initialization failed"}

	# Connect progress
	_mesh_baker.progress.connect(func(current: int, total: int, name: String) -> void:
		component_progress.emit("Merged Meshes", current, total, name)
	)
	_mesh_baker.cell_baked.connect(func(cell_grid: Vector2i, success: bool, output: String, stats: Dictionary) -> void:
		var cell_key := "%d,%d" % [cell_grid.x, cell_grid.y]
		item_baked.emit("Merged Meshes", cell_key, success)
		if success:
			mesh_state.completed.append(cell_key)
			mesh_state.pending.erase(cell_key)
			mesh_state.last_baked = cell_key
		else:
			mesh_state.failed.append(cell_key)
			mesh_state.pending.erase(cell_key)
		_state_manager.save_state()
	)

	# Bake (must await since bake_all_cells is now async)
	var result: Dictionary = await _mesh_baker.bake_all_cells()

	mesh_state.end_time = Time.get_unix_time_from_system()
	_state_manager.save_state()

	component_completed.emit("Merged Meshes", result.success, result.failed, result.skipped)

	return result


## Bake navigation meshes
func _bake_navmeshes() -> Dictionary:
	print("\n" + "=".repeat(80))
	print("NAVMESHES: Baking navigation meshes")
	print("=".repeat(80))

	component_started.emit("Navmeshes")

	_navmesh_baker = NavMeshBaker.new()

	# Configure
	_navmesh_baker.bake_exterior_cells = true
	_navmesh_baker.bake_interior_cells = false
	_navmesh_baker.skip_existing = true

	if terrain_3d and terrain_3d is Terrain3D:
		_navmesh_baker.terrain_3d = terrain_3d as Terrain3D

	# Get pending items
	var nav_state: PrebakeState.ComponentState = _state_manager.navmeshes
	if nav_state.pending.is_empty():
		var cells := _get_all_exterior_cells()
		for cell: Vector2i in cells:
			nav_state.pending.append("%d,%d" % [cell.x, cell.y])
		nav_state.start_time = Time.get_unix_time_from_system()

	print("  %d pending, %d completed, %d failed" % [
		nav_state.pending.size(), nav_state.completed.size(), nav_state.failed.size()])

	if _navmesh_baker.initialize() != OK:
		error_occurred.emit("Navmeshes", "Failed to initialize navmesh baker")
		return {"success": 0, "failed": 0, "error": "Initialization failed"}

	# Connect progress
	_navmesh_baker.progress.connect(func(current: int, total: int, cell_id: String) -> void:
		component_progress.emit("Navmeshes", current, total, cell_id)
	)
	_navmesh_baker.cell_baked.connect(func(cell_id: String, success: bool, output: String, polygons: int) -> void:
		item_baked.emit("Navmeshes", cell_id, success)
		if success:
			nav_state.completed.append(cell_id)
			nav_state.pending.erase(cell_id)
			nav_state.last_baked = cell_id
		else:
			nav_state.failed.append(cell_id)
			nav_state.pending.erase(cell_id)
		_state_manager.save_state()
	)

	# Bake (must await since bake_all_cells is now async)
	var result: Dictionary = await _navmesh_baker.bake_all_cells()

	nav_state.end_time = Time.get_unix_time_from_system()
	_state_manager.save_state()

	component_completed.emit("Navmeshes", result.success, result.failed, result.skipped)

	return result


## Bake shore mask
func _bake_shore_mask() -> Dictionary:
	print("\n" + "=".repeat(80))
	print("SHORE MASK: Baking ocean visibility mask")
	print("=".repeat(80))
	print("PrebakingManager: terrain_3d = %s" % [terrain_3d])
	if terrain_3d and terrain_3d is Terrain3D:
		var terrain_node := terrain_3d as Terrain3D
		print("PrebakingManager: terrain_3d path = %s" % terrain_node.get_path())
		print("PrebakingManager: terrain_3d.data = %s" % [terrain_node.data])

	component_started.emit("Shore Mask")

	if not terrain_3d:
		push_warning("PrebakingManager: No Terrain3D set, skipping shore mask")
		error_occurred.emit("Shore Mask", "No Terrain3D found in scene")
		component_completed.emit("Shore Mask", 0, 1, 0)
		return {"success": 0, "failed": 1, "error": "No terrain"}

	_shore_baker = ShoreMaskBaker.new()
	_shore_baker.terrain = terrain_3d as Terrain3D

	# Connect progress
	_shore_baker.progress.connect(func(percent: float, message: String) -> void:
		component_progress.emit("Shore Mask", int(percent), 100, message)
	)

	# Bake
	var result: Dictionary = _shore_baker.bake_shore_mask()

	var state: PrebakeState.ComponentState = _state_manager.shore_mask
	if result.success:
		state.completed.append("shore_mask")
		state.last_baked = "shore_mask"
	else:
		state.failed.append("shore_mask")

	state.end_time = Time.get_unix_time_from_system()
	_state_manager.save_state()

	var success := 1 if result.success else 0
	var failed := 0 if result.success else 1
	component_completed.emit("Shore Mask", success, failed, 0)

	return {"success": success, "failed": failed}


## Get all exterior cells from ESM
func _get_all_exterior_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var seen: Dictionary = {}

	if not ESMManager:
		return cells

	for key: String in ESMManager.cells:
		var cell: CellRecord = ESMManager.cells[key]
		if cell and not cell.is_interior():
			var grid := Vector2i(cell.grid_x, cell.grid_y)
			if grid not in seen:
				seen[grid] = true
				cells.append(grid)

	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y))
	return cells


## Bake only a single component
func bake_component(component: Component) -> void:
	if _is_processing:
		push_warning("PrebakingManager: Already processing")
		return

	# Ensure ESM/BSA data is loaded
	if not _ensure_data_loaded():
		push_error("PrebakingManager: Cannot start - data not loaded")
		status = Status.ERROR
		status_changed.emit(status)
		return

	_is_processing = true
	_should_stop = false
	status = Status.RUNNING
	status_changed.emit(status)

	var result: Dictionary

	match component:
		Component.TERRAIN:
			result = await _bake_terrain()
		Component.MODELS:
			result = await _bake_models()
		Component.IMPOSTORS:
			result = await _bake_impostors()
		Component.MERGED_MESHES:
			result = await _bake_merged_meshes()
		Component.NAVMESHES:
			result = await _bake_navmeshes()
		Component.SHORE_MASK:
			result = await _bake_shore_mask()
		Component.CLOUD_NOISE:
			result = await _bake_cloud_noise()

	_is_processing = false
	status = Status.COMPLETED if not _should_stop else Status.PAUSED
	status_changed.emit(status)
	all_completed.emit({_component_name(component): result})


func _component_name(component: Component) -> String:
	match component:
		Component.TERRAIN: return "terrain"
		Component.MODELS: return "models"
		Component.IMPOSTORS: return "impostors"
		Component.MERGED_MESHES: return "merged_meshes"
		Component.NAVMESHES: return "navmeshes"
		Component.SHORE_MASK: return "shore_mask"
		Component.CLOUD_NOISE: return "cloud_noise"
	return "unknown"


## Bake cloud noise textures for volumetric clouds
func _bake_cloud_noise() -> Dictionary:
	print("\n" + "=".repeat(80))
	print("CLOUD NOISE: Generating 3D noise textures for volumetric clouds")
	print("=".repeat(80))

	component_started.emit("Cloud Noise")

	# Use cache directory from SettingsManager
	var output_path: String = SettingsManager.get_cache_base_path().path_join("cloud_noise") + "/"
	const SHAPE_RESOLUTION := 64
	const DETAIL_RESOLUTION := 32

	print("CLOUD NOISE: Output path: %s" % output_path)

	# Ensure output directory exists
	DirAccess.make_dir_recursive_absolute(output_path)

	var start_time := Time.get_ticks_msec()
	var total_slices := SHAPE_RESOLUTION + DETAIL_RESOLUTION
	var current_slice := 0

	# Generate shape noise
	component_progress.emit("Cloud Noise", 0, total_slices, "Generating shape noise...")

	var num_cells := 4
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345

	var points := []
	var total_cells := num_cells * num_cells * num_cells
	for i in range(total_cells):
		var cell_x := i % num_cells
		var cell_y := (i / num_cells) % num_cells
		var cell_z := i / (num_cells * num_cells)
		var base := Vector3(cell_x, cell_y, cell_z) / float(num_cells)
		var offset := Vector3(rng.randf(), rng.randf(), rng.randf()) / float(num_cells)
		points.append(base + offset)

	# Generate shape noise slices
	for z in range(SHAPE_RESOLUTION):
		if _should_stop:
			component_completed.emit("Cloud Noise", 0, 0, current_slice)
			return {"success": 0, "failed": 0, "skipped": current_slice}

		var img := Image.create(SHAPE_RESOLUTION, SHAPE_RESOLUTION, false, Image.FORMAT_RF)

		for y in range(SHAPE_RESOLUTION):
			for x in range(SHAPE_RESOLUTION):
				var pos := Vector3(x, y, z) / float(SHAPE_RESOLUTION)

				var worley1 := _worley_noise_3d(pos * 4.0, points, num_cells)
				var worley2 := _worley_noise_3d(pos * 8.0, points, num_cells)
				var worley3 := _worley_noise_3d(pos * 16.0, points, num_cells)

				var perlin := _perlin_noise_3d(pos * 8.0)
				var worley := worley1 * 0.625 + worley2 * 0.25 + worley3 * 0.125

				var value := _remap(perlin, worley - 1.0, 1.0, 0.0, 1.0)
				value = clamp(value, 0.0, 1.0)

				img.set_pixel(x, y, Color(value, value, value, 1.0))

		var slice_path := output_path + "shape_%03d.exr" % z
		img.save_exr(slice_path)

		current_slice += 1
		if z % 8 == 0:
			component_progress.emit("Cloud Noise", current_slice, total_slices, "Shape noise: %d%%" % [int(float(z) / float(SHAPE_RESOLUTION) * 100.0)])
			await get_tree().process_frame

	# Save shape metadata
	var shape_meta := {"size": SHAPE_RESOLUTION, "slices": SHAPE_RESOLUTION, "format": "exr"}
	var shape_meta_file := FileAccess.open(output_path + "shape_meta.json", FileAccess.WRITE)
	shape_meta_file.store_string(JSON.stringify(shape_meta))
	shape_meta_file.close()

	# Generate detail noise slices
	component_progress.emit("Cloud Noise", current_slice, total_slices, "Generating detail noise...")

	for z in range(DETAIL_RESOLUTION):
		if _should_stop:
			component_completed.emit("Cloud Noise", 0, 0, current_slice)
			return {"success": 0, "failed": 0, "skipped": current_slice}

		var img := Image.create(DETAIL_RESOLUTION, DETAIL_RESOLUTION, false, Image.FORMAT_RF)

		for y in range(DETAIL_RESOLUTION):
			for x in range(DETAIL_RESOLUTION):
				var pos := Vector3(x, y, z) / float(DETAIL_RESOLUTION)

				var worley1 := _worley_noise_3d(pos * 8.0, points, num_cells)
				var worley2 := _worley_noise_3d(pos * 16.0, points, num_cells)
				var worley3 := _worley_noise_3d(pos * 32.0, points, num_cells)

				var value := worley1 * 0.625 + worley2 * 0.25 + worley3 * 0.125
				value = clamp(value, 0.0, 1.0)

				img.set_pixel(x, y, Color(value, value, value, 1.0))

		var slice_path := output_path + "detail_%03d.exr" % z
		img.save_exr(slice_path)

		current_slice += 1
		if z % 4 == 0:
			component_progress.emit("Cloud Noise", current_slice, total_slices, "Detail noise: %d%%" % [int(float(z) / float(DETAIL_RESOLUTION) * 100.0)])
			await get_tree().process_frame

	# Save detail metadata
	var detail_meta := {"size": DETAIL_RESOLUTION, "slices": DETAIL_RESOLUTION, "format": "exr"}
	var detail_meta_file := FileAccess.open(output_path + "detail_meta.json", FileAccess.WRITE)
	detail_meta_file.store_string(JSON.stringify(detail_meta))
	detail_meta_file.close()

	var elapsed := (Time.get_ticks_msec() - start_time) / 1000.0
	print("Cloud noise generation complete in %.1f seconds" % elapsed)

	component_completed.emit("Cloud Noise", 2, 0, 0)  # 2 textures: shape and detail
	return {"success": 2, "failed": 0}


# Cloud noise generation helper functions

func _worley_noise_3d(pos: Vector3, points: Array, num_cells: int) -> float:
	pos = Vector3(fposmod(pos.x, 1.0), fposmod(pos.y, 1.0), fposmod(pos.z, 1.0))
	var min_dist := 1.0
	var cell := Vector3i(int(pos.x * num_cells), int(pos.y * num_cells), int(pos.z * num_cells))

	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var neighbor := Vector3i(
					(cell.x + dx + num_cells) % num_cells,
					(cell.y + dy + num_cells) % num_cells,
					(cell.z + dz + num_cells) % num_cells
				)
				var idx := neighbor.x + neighbor.y * num_cells + neighbor.z * num_cells * num_cells
				if idx >= 0 and idx < points.size():
					var point: Vector3 = points[idx]
					var wrapped_point := point + Vector3(dx, dy, dz) / float(num_cells)
					if dx == -1 and cell.x == 0: wrapped_point.x -= 1.0
					elif dx == 1 and cell.x == num_cells - 1: wrapped_point.x += 1.0
					if dy == -1 and cell.y == 0: wrapped_point.y -= 1.0
					elif dy == 1 and cell.y == num_cells - 1: wrapped_point.y += 1.0
					if dz == -1 and cell.z == 0: wrapped_point.z -= 1.0
					elif dz == 1 and cell.z == num_cells - 1: wrapped_point.z += 1.0
					min_dist = min(min_dist, pos.distance_to(wrapped_point))

	return 1.0 - min_dist * num_cells


func _perlin_noise_3d(pos: Vector3) -> float:
	var p := Vector3(floorf(pos.x), floorf(pos.y), floorf(pos.z))
	var f := Vector3(pos.x - p.x, pos.y - p.y, pos.z - p.z)
	f = f * f * (Vector3.ONE * 3.0 - f * 2.0)
	var n: float = p.x + p.y * 157.0 + p.z * 113.0

	var h000: float = _hash_noise(n)
	var h100: float = _hash_noise(n + 1.0)
	var h010: float = _hash_noise(n + 157.0)
	var h110: float = _hash_noise(n + 158.0)
	var h001: float = _hash_noise(n + 113.0)
	var h101: float = _hash_noise(n + 114.0)
	var h011: float = _hash_noise(n + 270.0)
	var h111: float = _hash_noise(n + 271.0)

	var x00: float = lerpf(h000, h100, f.x)
	var x10: float = lerpf(h010, h110, f.x)
	var x01: float = lerpf(h001, h101, f.x)
	var x11: float = lerpf(h011, h111, f.x)

	var y0: float = lerpf(x00, x10, f.y)
	var y1: float = lerpf(x01, x11, f.y)

	return lerpf(y0, y1, f.z)


func _hash_noise(n: float) -> float:
	var v := sin(n) * 43758.5453123
	return v - floor(v)


func _remap(value: float, old_min: float, old_max: float, new_min: float, new_max: float) -> float:
	return new_min + (value - old_min) * (new_max - new_min) / (old_max - old_min)
