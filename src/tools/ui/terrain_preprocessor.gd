## Terrain preprocessing logic for WorldExplorer.
##
## Extracted from world_explorer.gd (Session 7). Handles the terrain prebaking
## operation that converts ESM LAND records into Terrain3D regions, including
## ocean floor padding. The heavy processing yields periodically to keep UI
## responsive.
##
## Usage:
## [codeblock]
## var preprocessor := TerrainPreprocessor.new(callbacks)
## await preprocessor.run(terrain_3d, terrain_manager)
## [/codeblock]
class_name TerrainPreprocessor
extends RefCounted

## Callback dictionary — keys are action names, values are Callables
var _cb: Dictionary = {}


## Create the terrain preprocessor.
## [param callbacks] Dictionary mapping action names to Callables:
##   log, get_tree, update_preprocess_status
func _init(callbacks: Dictionary) -> void:
	_cb = callbacks


## Run the terrain preprocessing operation.
## [param terrain] Terrain3D node to import regions into.
## [param terrain_mgr] TerrainManager with region import methods.
## [param ui_refs] Dictionary with UI node references:
##   preprocess_btn: Button, preprocess_status: Label
func run(terrain: Terrain3D, terrain_mgr: TerrainManager, ui_refs: Dictionary) -> void:
	var preprocess_btn: Button = ui_refs.get("preprocess_btn")
	var preprocess_status: Label = ui_refs.get("preprocess_status")

	_log("[color=cyan]Starting terrain preprocessing...[/color]")
	if preprocess_btn:
		preprocess_btn.disabled = true
	if preprocess_status:
		preprocess_status.text = "Preprocessing..."

	if not terrain:
		_log("[color=red]ERROR: Terrain3D not initialized[/color]")
		if preprocess_btn:
			preprocess_btn.disabled = false
		return

	# Use COMBINED REGION approach (4x4 cells per region = 256x256 pixels)
	# Collect all unique regions that have terrain data and find bounds
	var regions_with_data: Dictionary = {}
	var min_region := Vector2i(999, 999)
	var max_region := Vector2i(-999, -999)

	for key: String in ESMManager.lands:
		var land: LandRecord = ESMManager.lands[key]
		if not land or not land.has_heights():
			continue

		var region_coord: Vector2i = terrain_mgr.cell_to_region(Vector2i(land.cell_x, land.cell_y))
		regions_with_data[region_coord] = true

		min_region.x = mini(min_region.x, region_coord.x)
		min_region.y = mini(min_region.y, region_coord.y)
		max_region.x = maxi(max_region.x, region_coord.x)
		max_region.y = maxi(max_region.y, region_coord.y)

	_log("Found %d combined regions with data (from %d cells)" % [regions_with_data.size(), ESMManager.lands.size()])
	_log("Region bounds: (%d,%d) to (%d,%d)" % [min_region.x, min_region.y, max_region.x, max_region.y])

	# Expand bounds by 2 regions on each side for ocean floor
	const OCEAN_PADDING := 2
	min_region.x = maxi(min_region.x - OCEAN_PADDING, -16)
	min_region.y = maxi(min_region.y - OCEAN_PADDING, -16)
	max_region.x = mini(max_region.x + OCEAN_PADDING, 15)
	max_region.y = mini(max_region.y + OCEAN_PADDING, 15)

	var total_x := max_region.x - min_region.x + 1
	var total_y := max_region.y - min_region.y + 1
	var total_regions := total_x * total_y

	_log("Processing %d total regions (including %d ocean floor regions)" % [
		total_regions, total_regions - regions_with_data.size()])

	var processed := 0
	var ocean_floor := 0

	var get_land_func := func(cell_x: int, cell_y: int) -> LandRecord:
		return ESMManager.get_land(cell_x, cell_y)

	# Process ALL regions in the expanded bounds
	var tree: SceneTree = _get_tree()
	for ry in range(min_region.y, max_region.y + 1):
		for rx in range(min_region.x, max_region.x + 1):
			var region_coord := Vector2i(rx, ry)

			if regions_with_data.has(region_coord):
				if terrain_mgr.import_combined_region(terrain, region_coord, get_land_func):
					processed += 1
			else:
				if terrain_mgr.import_ocean_floor_region(terrain, region_coord):
					ocean_floor += 1

			# Update progress
			var done := processed + ocean_floor
			var percent := float(done) / float(total_regions) * 100.0
			if preprocess_status:
				preprocess_status.text = "Processing... %.0f%% (%d/%d regions)" % [percent, done, total_regions]

			# Yield periodically to keep UI responsive
			if done % 10 == 0 and tree:
				await tree.process_frame

	# Save to disk (cache folder)
	var terrain_data_dir := SettingsManager.get_terrain_path()
	DirAccess.make_dir_recursive_absolute(terrain_data_dir)
	terrain.data.save_directory(terrain_data_dir)

	_log("[color=green]Terrain preprocessing complete![/color]")
	_log("  Terrain regions: %d (4x4 cells each)" % processed)
	_log("  Ocean floor regions: %d" % ocean_floor)
	_log("  Saved to: %s" % terrain_data_dir)

	if preprocess_btn:
		preprocess_btn.disabled = false

	var update_cb: Callable = _cb.get("update_preprocess_status", Callable())
	if update_cb.is_valid():
		update_cb.call()


## Log a message via callback.
func _log(message: String) -> void:
	var cb: Callable = _cb.get("log", Callable())
	if cb.is_valid():
		cb.call(message)


## Get the SceneTree via callback.
func _get_tree() -> SceneTree:
	var cb: Callable = _cb.get("get_tree", Callable())
	if cb.is_valid():
		return cb.call()
	return null
