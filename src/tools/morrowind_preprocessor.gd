## MorrowindPreprocessor - Unified tool for preprocessing Morrowind assets
##
## Orchestrates all preprocessing steps required for distant rendering:
## 1. Impostor baking (octahedral textures for FAR tier)
## 2. Mesh merging (pre-merged cells for MID tier)
## 3. Texture atlasing (optional, future enhancement)
## 4. Navmesh baking (optional, future AI pathfinding)
##
## Usage:
##   var preprocessor := MorrowindPreprocessor.new()
##   preprocessor.preprocessing_progress.connect(_on_progress)
##   var results := preprocessor.preprocess_all()
##   print("Complete: %s" % results)
class_name MorrowindPreprocessor
extends RefCounted

const ImpostorBaker := preload("res://src/tools/impostor_baker.gd")
const MeshPrebaker := preload("res://src/tools/mesh_prebaker.gd")
const NavMeshBaker := preload("res://src/tools/navmesh_baker.gd")
const MorrowindDataProvider := preload("res://src/core/world/morrowind_data_provider.gd")

## Preprocessing steps
enum Step {
	IMPOSTORS,
	MERGED_MESHES,
	TEXTURE_ATLASES,  # Future
	NAVMESHES,        # Future
}

## Progress tracking
signal preprocessing_progress(step: String, current: int, total: int)
signal step_complete(step: String, success_count: int, failed_count: int)
signal preprocessing_complete(results: Dictionary)

## Configuration
var enable_impostors: bool = true
var enable_merged_meshes: bool = true
var enable_texture_atlases: bool = false  # Future enhancement
var enable_navmeshes: bool = true         # Now implemented!

## Output directory
var output_base_dir: String = "res://assets"

## Statistics
var _results: Dictionary = {}


## Preprocess all assets
func preprocess_all() -> Dictionary:
	print("=" * 80)
	print("MorrowindPreprocessor: Starting full preprocessing")
	print("=" * 80)

	_results.clear()
	var start_time := Time.get_ticks_msec()

	# Step 1: Bake impostors
	if enable_impostors:
		_results["impostors"] = _preprocess_impostors()

	# Step 2: Bake merged meshes
	if enable_merged_meshes:
		_results["merged_meshes"] = _preprocess_merged_meshes()

	# Step 3: Generate texture atlases (future)
	if enable_texture_atlases:
		_results["texture_atlases"] = _preprocess_texture_atlases()

	# Step 4: Bake navmeshes (future)
	if enable_navmeshes:
		_results["navmeshes"] = _preprocess_navmeshes()

	var elapsed := (Time.get_ticks_msec() - start_time) / 1000.0
	_results["total_time_seconds"] = elapsed

	print("=" * 80)
	print("MorrowindPreprocessor: Preprocessing complete in %.1f seconds" % elapsed)
	print("=" * 80)
	_print_summary()

	preprocessing_complete.emit(_results)
	return _results


## Preprocess impostors only
func preprocess_impostors() -> Dictionary:
	if not enable_impostors:
		return {"skipped": true}

	return _preprocess_impostors()


## Preprocess merged meshes only
func preprocess_merged_meshes() -> Dictionary:
	if not enable_merged_meshes:
		return {"skipped": true}

	return _preprocess_merged_meshes()


## Internal: Bake all impostors
func _preprocess_impostors() -> Dictionary:
	print("\n" + "=" * 80)
	print("STEP 1: Baking Impostors")
	print("=" * 80)

	var baker := ImpostorBaker.new()
	baker.output_dir = output_base_dir.path_join("impostors")

	# Connect progress signals
	baker.progress.connect(func(current, total, name):
		preprocessing_progress.emit("Impostors", current, total)
		print("  [%d/%d] %s" % [current, total, name])
	)

	# Get world provider for candidates
	var world_provider := MorrowindDataProvider.new()
	world_provider.initialize()

	# Bake all
	var result := baker.bake_all_candidates(world_provider)

	step_complete.emit("Impostors", result.success, result.failed)

	print("\nImpostor Baking Complete:")
	print("  Total: %d" % result.total)
	print("  Success: %d" % result.success)
	print("  Failed: %d" % result.failed)

	return result


## Internal: Bake all merged meshes
func _preprocess_merged_meshes() -> Dictionary:
	print("\n" + "=" * 80)
	print("STEP 2: Baking Merged Cell Meshes")
	print("=" * 80)

	var baker := MeshPrebaker.new()
	baker.output_dir = output_base_dir.path_join("merged_cells")

	# Connect progress signals
	baker.progress.connect(func(current, total, name):
		preprocessing_progress.emit("Merged Meshes", current, total)
		print("  [%d/%d] %s" % [current, total, name])
	)

	# Bake all
	var result := baker.bake_all_cells()

	step_complete.emit("Merged Meshes", result.success, result.failed)

	print("\nMerged Mesh Baking Complete:")
	print("  Total: %d" % result.total)
	print("  Success: %d" % result.success)
	print("  Failed: %d" % result.failed)

	return result


## Internal: Generate texture atlases (future)
func _preprocess_texture_atlases() -> Dictionary:
	print("\n" + "=" * 80)
	print("STEP 3: Generating Texture Atlases (Not Implemented)")
	print("=" * 80)

	# TODO: Implement texture atlas generation
	# 1. Collect all textures used by merged meshes
	# 2. Pack into 4096×4096 atlases using rect packing
	# 3. Remap UV coordinates in merged meshes
	# 4. Save atlas textures

	return {
		"total": 0,
		"success": 0,
		"failed": 0,
		"error": "Not implemented yet"
	}


## Internal: Bake navmeshes
func _preprocess_navmeshes() -> Dictionary:
	print("\n" + "=" * 80)
	print("STEP 4: Baking Navmeshes")
	print("=" * 80)

	var baker := NavMeshBaker.new()
	baker.output_dir = output_base_dir.path_join("navmeshes")

	# Configure what to bake
	baker.bake_exterior_cells = true
	baker.bake_interior_cells = false  # Disable interior for now (can enable later)
	baker.skip_existing = true

	# Connect progress signals
	baker.progress.connect(func(current, total, cell_id):
		preprocessing_progress.emit("Navmeshes", current, total)
		print("  [%d/%d] %s" % [current, total, cell_id])
	)

	# Bake all cells
	var result := baker.bake_all_cells()

	step_complete.emit("Navmeshes", result.success, result.failed)

	print("\nNavmesh Baking Complete:")
	print("  Total: %d" % result.total)
	print("  Baked: %d" % result.success)
	print("  Skipped: %d (already exist)" % result.skipped)
	print("  Failed: %d" % result.failed)
	if result.success > 0:
		print("  Avg bake time: %.2fs per cell" % result.avg_bake_time)

	return result


## Print summary of results
func _print_summary() -> void:
	print("\nPreprocessing Summary:")
	print("-" * 80)

	var total_success := 0
	var total_failed := 0

	for step in _results:
		if step == "total_time_seconds":
			continue

		var result: Dictionary = _results[step]
		if result.get("skipped", false):
			print("  %s: SKIPPED" % step.capitalize())
			continue

		var success: int = result.get("success", 0)
		var failed: int = result.get("failed", 0)
		total_success += success
		total_failed += failed

		print("  %s: %d succeeded, %d failed" % [step.capitalize(), success, failed])

	print("-" * 80)
	print("  TOTAL: %d succeeded, %d failed" % [total_success, total_failed])
	print("  Time: %.1f seconds" % _results.get("total_time_seconds", 0.0))


## Estimate preprocessing time
static func estimate_time() -> Dictionary:
	return {
		"impostors_minutes": 30,      # ~30 minutes for 100 landmarks
		"merged_meshes_hours": 2,     # ~2 hours for 600 cells
		"texture_atlases_minutes": 60,  # ~1 hour (not implemented)
		"navmeshes_minutes": 120,     # ~2 hours (not implemented)
		"total_hours": 4.5,           # Approximate total
	}


## Get cache paths from SettingsManager (helper for static functions)
static func _get_cache_paths() -> Dictionary:
	var settings := Engine.get_main_loop().root.get_node_or_null("/root/SettingsManager")
	if settings:
		return {
			"impostors": settings.get_impostors_path(),
			"merged_cells": settings.get_merged_cells_path(),
		}
	# Fallback if SettingsManager not available
	var documents := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	var base := documents.path_join("Godotwind").path_join("cache")
	return {
		"impostors": base.path_join("impostors"),
		"merged_cells": base.path_join("merged_cells"),
	}


## Check if preprocessing is complete
static func is_preprocessing_complete() -> bool:
	var paths := _get_cache_paths()
	var has_impostors := DirAccess.dir_exists_absolute(paths.impostors)
	var has_merged := DirAccess.dir_exists_absolute(paths.merged_cells)

	# Check for at least some files in each directory
	if not has_impostors or not has_merged:
		return false

	var impostor_count := _count_files(paths.impostors, "png")
	var merged_count := _count_files(paths.merged_cells, "res")

	# Need at least some assets
	return impostor_count > 0 and merged_count > 0


## Count files with extension in directory
static func _count_files(dir_path: String, extension: String) -> int:
	var dir := DirAccess.open(dir_path)
	if not dir:
		return 0

	var count := 0
	dir.list_dir_begin()
	var file_name := dir.get_next()

	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with("." + extension):
			count += 1
		file_name = dir.get_next()

	dir.list_dir_end()
	return count


## Get preprocessing status
static func get_preprocessing_status() -> Dictionary:
	var paths := _get_cache_paths()
	return {
		"complete": is_preprocessing_complete(),
		"impostors": {
			"exists": DirAccess.dir_exists_absolute(paths.impostors),
			"count": _count_files(paths.impostors, "png"),
		},
		"merged_meshes": {
			"exists": DirAccess.dir_exists_absolute(paths.merged_cells),
			"count": _count_files(paths.merged_cells, "res"),
		},
	}
