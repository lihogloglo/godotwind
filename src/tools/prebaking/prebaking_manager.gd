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

## Baking components
enum Component {
	MODELS,        # Individual NIF->Godot conversions (NEAR tier)
	IMPOSTORS,     # Octahedral impostor textures (FAR tier)
	MERGED_MESHES, # Simplified merged cell meshes (MID tier)
	NAVMESHES,     # Navigation meshes
	SHORE_MASK,    # Ocean visibility mask
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
var _state_manager: RefCounted = null

## Bakers
var _model_baker: RefCounted = null
var _impostor_baker: Node = null
var _mesh_baker: RefCounted = null
var _navmesh_baker: RefCounted = null
var _shore_baker: RefCounted = null

## Component enable flags
var enable_models: bool = true
var enable_impostors: bool = true
var enable_merged_meshes: bool = true
var enable_navmeshes: bool = true
var enable_shore_mask: bool = true

## Current component being processed
var _current_component: Component = Component.MODELS
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

	# Models first - this is the most impactful for load times
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
func reset_all() -> void:
	if _is_processing:
		push_warning("PrebakingManager: Cannot reset while processing")
		return

	_state_manager.clear_state()
	status = Status.IDLE
	status_changed.emit(status)
	print("PrebakingManager: Reset all progress")


## Get current state summary
func get_state_summary() -> Dictionary:
	return _state_manager.get_summary()


## Check if there's pending work to resume
func has_pending_work() -> bool:
	return _state_manager.has_pending_work()


## Bake individual models (NIF -> Godot conversion)
func _bake_models() -> Dictionary:
	print("\n" + "=".repeat(80))
	print("MODELS: Pre-converting NIF models to Godot resources")
	print("=".repeat(80))

	component_started.emit("Models")

	_model_baker = ModelPrebaker.new()
	var baker: RefCounted = _model_baker

	if baker.initialize() != OK:
		error_occurred.emit("Models", "Failed to initialize model baker")
		return {"success": 0, "failed": 0, "skipped": 0, "error": "Initialization failed"}

	# Connect progress signals
	baker.progress.connect(func(current, total, name):
		component_progress.emit("Models", current, total, name)
	)
	baker.model_baked.connect(func(path, success, mesh_count):
		item_baked.emit("Models", path, success)
	)

	# Bake all models
	var result: Dictionary = await baker.bake_all_models()

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

	var baker: Node = _impostor_baker

	# Get pending items
	var state: PrebakeState.ComponentState = _state_manager.impostors
	if state.pending.is_empty():
		# Build initial pending list from impostor candidates
		var candidates := ImpostorCandidates.new()
		state.pending = candidates.get_landmark_models().duplicate()
		state.start_time = Time.get_unix_time_from_system()

	print("  %d pending, %d completed, %d failed" % [
		state.pending.size(), state.completed.size(), state.failed.size()])

	if baker.initialize() != OK:
		error_occurred.emit("Impostors", "Failed to initialize impostor baker")
		return {"success": 0, "failed": 0, "error": "Initialization failed"}

	# Connect progress
	baker.progress.connect(func(current, total, name):
		component_progress.emit("Impostors", current, total, name)
	)
	baker.model_baked.connect(func(path, success, output):
		item_baked.emit("Impostors", path, success)
		if success:
			state.completed.append(path)
			state.pending.erase(path)
			state.last_baked = path
		else:
			state.failed.append(path)
			state.pending.erase(path)
		_state_manager.save_state()
	)

	# Bake pending items
	var pending: Array = state.pending.duplicate()
	var result: Dictionary = baker.bake_models(pending)

	state.end_time = Time.get_unix_time_from_system()
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
	var baker: RefCounted = _mesh_baker

	# Get pending items
	var state: PrebakeState.ComponentState = _state_manager.merged_meshes
	if state.pending.is_empty():
		# Build initial pending list from ESM cells
		var cells := _get_all_exterior_cells()
		for cell in cells:
			state.pending.append("%d,%d" % [cell.x, cell.y])
		state.start_time = Time.get_unix_time_from_system()

	print("  %d pending, %d completed, %d failed" % [
		state.pending.size(), state.completed.size(), state.failed.size()])

	if baker.initialize() != OK:
		error_occurred.emit("Merged Meshes", "Failed to initialize mesh baker")
		return {"success": 0, "failed": 0, "error": "Initialization failed"}

	# Connect progress
	baker.progress.connect(func(current, total, name):
		component_progress.emit("Merged Meshes", current, total, name)
	)
	baker.cell_baked.connect(func(cell_grid, success, output, stats):
		var cell_key := "%d,%d" % [cell_grid.x, cell_grid.y]
		item_baked.emit("Merged Meshes", cell_key, success)
		if success:
			state.completed.append(cell_key)
			state.pending.erase(cell_key)
			state.last_baked = cell_key
		else:
			state.failed.append(cell_key)
			state.pending.erase(cell_key)
		_state_manager.save_state()
	)

	# Bake
	var result: Dictionary = baker.bake_all_cells()

	state.end_time = Time.get_unix_time_from_system()
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
	var baker: RefCounted = _navmesh_baker

	# Configure
	baker.bake_exterior_cells = true
	baker.bake_interior_cells = false
	baker.skip_existing = true

	if terrain_3d:
		baker.terrain_3d = terrain_3d

	# Get pending items
	var state: PrebakeState.ComponentState = _state_manager.navmeshes
	if state.pending.is_empty():
		var cells := _get_all_exterior_cells()
		for cell in cells:
			state.pending.append("%d,%d" % [cell.x, cell.y])
		state.start_time = Time.get_unix_time_from_system()

	print("  %d pending, %d completed, %d failed" % [
		state.pending.size(), state.completed.size(), state.failed.size()])

	if baker.initialize() != OK:
		error_occurred.emit("Navmeshes", "Failed to initialize navmesh baker")
		return {"success": 0, "failed": 0, "error": "Initialization failed"}

	# Connect progress
	baker.progress.connect(func(current, total, cell_id):
		component_progress.emit("Navmeshes", current, total, cell_id)
	)
	baker.cell_baked.connect(func(cell_id, success, output, polygons):
		item_baked.emit("Navmeshes", cell_id, success)
		if success:
			state.completed.append(cell_id)
			state.pending.erase(cell_id)
			state.last_baked = cell_id
		else:
			state.failed.append(cell_id)
			state.pending.erase(cell_id)
		_state_manager.save_state()
	)

	# Bake
	var result: Dictionary = baker.bake_all_cells()

	state.end_time = Time.get_unix_time_from_system()
	_state_manager.save_state()

	component_completed.emit("Navmeshes", result.success, result.failed, result.skipped)

	return result


## Bake shore mask
func _bake_shore_mask() -> Dictionary:
	print("\n" + "=".repeat(80))
	print("SHORE MASK: Baking ocean visibility mask")
	print("=".repeat(80))

	component_started.emit("Shore Mask")

	if not terrain_3d:
		push_warning("PrebakingManager: No Terrain3D set, skipping shore mask")
		component_completed.emit("Shore Mask", 0, 1, 0)
		return {"success": 0, "failed": 1, "error": "No terrain"}

	_shore_baker = ShoreMaskBaker.new()
	var baker: RefCounted = _shore_baker
	baker.terrain = terrain_3d

	# Connect progress
	baker.progress.connect(func(percent, message):
		component_progress.emit("Shore Mask", int(percent), 100, message)
	)

	# Bake
	var result: Dictionary = baker.bake_shore_mask()

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

	for key in ESMManager.cells:
		var cell: CellRecord = ESMManager.cells[key]
		if cell and not cell.is_interior():
			var grid := Vector2i(cell.grid_x, cell.grid_y)
			if grid not in seen:
				seen[grid] = true
				cells.append(grid)

	cells.sort_custom(func(a, b): return a.x < b.x or (a.x == b.x and a.y < b.y))
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

	_is_processing = false
	status = Status.COMPLETED if not _should_stop else Status.PAUSED
	status_changed.emit(status)
	all_completed.emit({_component_name(component): result})


func _component_name(component: Component) -> String:
	match component:
		Component.MODELS: return "models"
		Component.IMPOSTORS: return "impostors"
		Component.MERGED_MESHES: return "merged_meshes"
		Component.NAVMESHES: return "navmeshes"
		Component.SHORE_MASK: return "shore_mask"
	return "unknown"
