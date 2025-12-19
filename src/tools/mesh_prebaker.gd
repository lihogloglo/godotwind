@tool
## MeshPrebaker - Offline tool to generate merged meshes for MID tier distant rendering
##
## This tool pre-generates merged static meshes for all exterior cells.
## Pre-baked meshes load instantly at runtime instead of 50-100ms per cell.
##
## Usage (in Godot editor):
##   1. Open this script in the editor
##   2. Run via menu: Script > Run in Editor
##   OR use the command line:
##   godot --headless --script src/tools/mesh_prebaker.gd
##
## Output:
##   res://assets/merged_cells/cell_X_Y.res (ArrayMesh resources)
##
## Requirements:
##   - ESMManager autoload must be configured
##   - BSAManager must have Morrowind data loaded
extends EditorScript


const StaticMeshMerger := preload("res://src/core/world/static_mesh_merger.gd")
const MeshSimplifier := preload("res://src/core/nif/mesh_simplifier.gd")
const ModelLoader := preload("res://src/core/world/model_loader.gd")

## Output directory for pre-baked meshes
const OUTPUT_DIR := "res://assets/merged_cells/"

## Cell range to process (Morrowind exterior world bounds)
## Default covers the main Vvardenfell island
const CELL_RANGE := {
	"min_x": -50,
	"max_x": 50,
	"min_y": -50,
	"max_y": 50,
}

## Whether to skip cells that already have pre-baked meshes
var skip_existing: bool = true

## Stats
var _stats := {
	"total_cells": 0,
	"processed_cells": 0,
	"merged_cells": 0,
	"empty_cells": 0,
	"skipped_cells": 0,
	"failed_cells": 0,
	"total_vertices": 0,
	"total_objects": 0,
}


func _run() -> void:
	print("=" .repeat(60))
	print("MeshPrebaker - Generating merged meshes for MID tier")
	print("=" .repeat(60))

	# Ensure output directory exists
	if not DirAccess.dir_exists_absolute(OUTPUT_DIR):
		var err := DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
		if err != OK:
			push_error("Failed to create output directory: %s (error %d)" % [OUTPUT_DIR, err])
			return
		print("Created output directory: %s" % OUTPUT_DIR)

	# Check ESMManager
	if not Engine.has_singleton("ESMManager"):
		push_error("ESMManager autoload not found. Ensure it's configured in project settings.")
		return

	# Create merger and dependencies
	var merger := StaticMeshMerger.new()
	merger.mesh_simplifier = MeshSimplifier.new()
	merger.model_loader = ModelLoader.new()

	# Calculate total cells
	var total := (CELL_RANGE.max_x - CELL_RANGE.min_x + 1) * (CELL_RANGE.max_y - CELL_RANGE.min_y + 1)
	_stats.total_cells = total
	print("Processing %d cells (%d x %d)" % [total, CELL_RANGE.max_x - CELL_RANGE.min_x + 1, CELL_RANGE.max_y - CELL_RANGE.min_y + 1])
	print("")

	var start_time := Time.get_ticks_msec()
	var last_progress_time := start_time

	# Process each cell
	for y in range(CELL_RANGE.min_y, CELL_RANGE.max_y + 1):
		for x in range(CELL_RANGE.min_x, CELL_RANGE.max_x + 1):
			var grid := Vector2i(x, y)
			_process_cell(grid, merger)
			_stats.processed_cells += 1

			# Progress output every 5 seconds
			var current_time := Time.get_ticks_msec()
			if current_time - last_progress_time >= 5000:
				var progress := float(_stats.processed_cells) / float(total) * 100.0
				var elapsed := (current_time - start_time) / 1000.0
				var eta := elapsed / (_stats.processed_cells / float(total)) - elapsed if _stats.processed_cells > 0 else 0
				print("Progress: %.1f%% (%d/%d) - Merged: %d, Empty: %d, ETA: %.0fs" % [
					progress, _stats.processed_cells, total, _stats.merged_cells, _stats.empty_cells, eta
				])
				last_progress_time = current_time

	# Final stats
	var elapsed := (Time.get_ticks_msec() - start_time) / 1000.0
	print("")
	print("=" .repeat(60))
	print("MeshPrebaker Complete")
	print("=" .repeat(60))
	print("Time: %.1f seconds" % elapsed)
	print("Total cells: %d" % _stats.total_cells)
	print("Merged cells: %d (with geometry)" % _stats.merged_cells)
	print("Empty cells: %d (ocean/no objects)" % _stats.empty_cells)
	print("Skipped cells: %d (already pre-baked)" % _stats.skipped_cells)
	print("Failed cells: %d" % _stats.failed_cells)
	print("Total vertices: %d" % _stats.total_vertices)
	print("Total objects merged: %d" % _stats.total_objects)
	print("")
	print("Output: %s" % OUTPUT_DIR)


func _process_cell(grid: Vector2i, merger: StaticMeshMerger) -> void:
	var output_path := OUTPUT_DIR + "cell_%d_%d.res" % [grid.x, grid.y]

	# Skip if already exists
	if skip_existing and ResourceLoader.exists(output_path):
		_stats.skipped_cells += 1
		return

	# Get cell record
	var cell_record = ESMManager.get_exterior_cell(grid.x, grid.y)
	if not cell_record or cell_record.references.is_empty():
		_stats.empty_cells += 1
		return

	# Merge cell
	var merged_data = merger.merge_cell(grid, cell_record.references)
	if not merged_data or not merged_data.mesh:
		_stats.empty_cells += 1
		return

	# Save mesh
	var err := ResourceSaver.save(merged_data.mesh, output_path)
	if err != OK:
		push_warning("Failed to save merged mesh for cell %s: error %d" % [grid, err])
		_stats.failed_cells += 1
		return

	_stats.merged_cells += 1
	_stats.total_vertices += merged_data.vertex_count
	_stats.total_objects += merged_data.object_count
