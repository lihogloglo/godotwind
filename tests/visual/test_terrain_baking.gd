## Automated terrain baking test — runs the full terrain + horizon map pipeline
## without manual clicking. Reports exactly where/when crashes occur.
##
## Launch:
##   godot --path . res://tests/visual/test_terrain_baking.tscn
##
## Output: console logs with timing, region counts, and error trapping.
extends Node

const PrebakingManagerScript := preload("res://src/tools/prebaking/prebaking_manager.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const TerrainManagerScript := preload("res://src/core/world/morrowind/morrowind_terrain_manager.gd")

var _prebaking_manager: Node = null
var _start_time: float = 0.0
var _regions_processed: int = 0
var _regions_failed: int = 0
var _last_region: String = ""
var _phase: String = "init"


func _ready() -> void:
	Log.info("testing", "=" .repeat(80))
	Log.info("testing", "TERRAIN BAKING AUTOMATED TEST")
	Log.info("testing", "=" .repeat(80))
	_start_time = Time.get_ticks_msec()

	# Run with a frame delay so the scene tree is fully ready
	await get_tree().process_frame
	_run_test()


func _run_test() -> void:
	# === Phase 1: Test terrain region import (isolated) ===
	_phase = "terrain_import"
	Log.info("testing", "--- Phase 1: Terrain Region Import ---")

	if not _ensure_data():
		_fail("Cannot load ESM/BSA data")
		return

	# Create a Camera3D first — Terrain3D v1.1+ crashes without one
	var cam := Camera3D.new()
	cam.name = "BakingCamera"
	cam.current = true
	add_child(cam)

	var terrain := Terrain3D.new()
	terrain.name = "TestTerrain3D"

	# Set scale BEFORE add_child — DLL clipmap uses it during _initialize()
	CS.configure_terrain3d_pre_tree(terrain)
	add_child(terrain)

	# Re-disable physics AFTER add_child — C++ ENTER_TREE re-enables it
	terrain.set_physics_process(false)
	terrain.set_process(false)

	await get_tree().process_frame

	# Set camera explicitly for Terrain3D
	if terrain.has_method("set_camera"):
		terrain.set_camera(cam)
		Log.info("testing", "Camera set on Terrain3D")

	# Configure post-tree: sets vertex_spacing, region_size, material, assets, tessellation
	if not CS.configure_terrain3d(terrain):
		_fail("configure_terrain3d failed — terrain.data is null?")
		return

	Log.info("testing", "Terrain3D created and configured, vertex_spacing=%.3f" % terrain.get_vertex_spacing())

	# Test a small batch of regions first (canary)
	var terrain_manager := TerrainManagerScript.new()
	var texture_loader := preload("res://src/core/world/morrowind/morrowind_terrain_texture_loader.gd").new()
	var textures_loaded := texture_loader.load_terrain_textures(terrain.assets)
	Log.info("testing", "Loaded %d terrain textures" % textures_loaded)
	terrain_manager.set_texture_slot_mapper(texture_loader)

	var get_land_func := func(cell_x: int, cell_y: int) -> LandRecord:
		return ESMManager.get_land(cell_x, cell_y)

	# Collect all regions with data
	var regions_with_data: Array[Vector2i] = []
	for key: String in ESMManager.lands:
		var land: LandRecord = ESMManager.lands[key]
		if not land or not land.has_heights():
			continue
		var region_coord: Vector2i = terrain_manager.cell_to_region(Vector2i(land.cell_x, land.cell_y))
		if region_coord not in regions_with_data:
			regions_with_data.append(region_coord)

	Log.info("testing", "Found %d unique terrain regions to import" % regions_with_data.size())

	# Import all regions with crash tracking
	var import_success := 0
	var import_failed := 0
	var batch_size := 10
	var i := 0

	for region_coord: Vector2i in regions_with_data:
		_last_region = "%d,%d" % [region_coord.x, region_coord.y]
		i += 1

		var ok := terrain_manager.import_combined_region(terrain, region_coord, get_land_func)
		if ok:
			import_success += 1
		else:
			import_failed += 1
			Log.warn("testing", "  FAILED region %s" % _last_region)

		# Save incrementally and yield (Terrain3D can crash after ~50 imports)
		if i % batch_size == 0:
			var elapsed := (Time.get_ticks_msec() - _start_time) / 1000.0
			Log.info("testing", "  Imported %d/%d regions (%.1fs elapsed, last: %s)" % [
				i, regions_with_data.size(), elapsed, _last_region])
			# Save terrain data incrementally so progress survives crashes
			var save_dir := SettingsManager.get_terrain_path()
			DirAccess.make_dir_recursive_absolute(save_dir)
			terrain.data.save_directory(save_dir)
			await get_tree().process_frame

	Log.info("testing", "Phase 1 COMPLETE: %d success, %d failed out of %d" % [
		import_success, import_failed, regions_with_data.size()])

	# Final save
	var terrain_data_dir := SettingsManager.get_terrain_path()
	DirAccess.make_dir_recursive_absolute(terrain_data_dir)
	terrain.data.save_directory(terrain_data_dir)
	Log.info("testing", "Terrain saved to: %s" % terrain_data_dir)

	# === Phase 2: Test horizon map baking ===
	_phase = "horizon_maps"
	Log.info("testing", "--- Phase 2: Horizon Map Baking ---")

	var vertex_spacing: float = terrain.get_vertex_spacing()

	# Try native C# baker
	var native_baker: RefCounted = null
	var use_native := false
	var factory_script = load("res://src/native/NativeFactory.cs")
	if factory_script:
		var factory: RefCounted = factory_script.new()
		if factory.call("IsAvailable"):
			native_baker = factory.call("CreateHorizonMapBaker")
			if native_baker:
				native_baker.set("MaxMarchDistance", 64)
				native_baker.set("TexelSpacing", vertex_spacing)
				use_native = true
				Log.info("testing", "Using native C# horizon baker")

	var baker: HorizonMapBaker = null
	if not use_native:
		baker = HorizonMapBaker.new()
		baker.texel_spacing = vertex_spacing
		Log.info("testing", "Using GDScript horizon baker (slow)")

	const CELL_SIZE := 64
	var cells_per_region: int = TerrainManagerScript.CELLS_PER_REGION
	var region_size_pixels: int = cells_per_region * CELL_SIZE

	# Collect heightmaps for all regions
	var min_region := Vector2i(999999, 999999)
	var max_region := Vector2i(-999999, -999999)
	for rc: Vector2i in regions_with_data:
		min_region.x = mini(min_region.x, rc.x)
		min_region.y = mini(min_region.y, rc.y)
		max_region.x = maxi(max_region.x, rc.x)
		max_region.y = maxi(max_region.y, rc.y)

	var heightmaps: Dictionary = {}
	var complete_regions: Dictionary = {}
	var expected_cells: int = cells_per_region * cells_per_region

	Log.info("testing", "Building heightmap grid from (%d,%d) to (%d,%d)" % [
		min_region.x, min_region.y, max_region.x, max_region.y])

	for ry in range(min_region.y, max_region.y + 1):
		for rx in range(min_region.x, max_region.x + 1):
			var region_coord := Vector2i(rx, ry)
			var heightmap := Image.create(region_size_pixels, region_size_pixels, false, Image.FORMAT_RF)
			heightmap.fill(Color(CS.OCEAN_FLOOR_GODOT, 0, 0, 1))

			var cells_found: int = 0
			var sw_cell: Vector2i = TerrainManagerScript.region_to_sw_cell(region_coord)
			for local_y in range(cells_per_region):
				for local_x in range(cells_per_region):
					var cell_x: int = sw_cell.x + local_x
					var cell_y: int = sw_cell.y + local_y
					var land: LandRecord = get_land_func.call(cell_x, cell_y)
					if land and land.has_heights():
						cells_found += 1
						var cell_hm: Image = terrain_manager.generate_heightmap(land)
						var img_offset_x: int = local_x * CELL_SIZE
						var img_offset_y: int = (cells_per_region - 1 - local_y) * CELL_SIZE
						heightmap.blit_rect(cell_hm, Rect2i(0, 0, CELL_SIZE, CELL_SIZE), Vector2i(img_offset_x, img_offset_y))

			heightmaps[region_coord] = heightmap
			complete_regions[region_coord] = (cells_found == expected_cells)

	var complete_count: int = complete_regions.values().count(true)
	Log.info("testing", "Collected %d heightmaps, %d complete" % [heightmaps.size(), complete_count])

	# Bake horizon maps for complete regions
	var horizon_baked := 0
	var horizon_total := complete_count
	var horizon_start := Time.get_ticks_msec()

	for ry in range(min_region.y, max_region.y + 1):
		for rx in range(min_region.x, max_region.x + 1):
			var region_coord := Vector2i(rx, ry)
			if not complete_regions.get(region_coord, false):
				continue

			_last_region = "horizon_%d,%d" % [rx, ry]
			var heightmap: Image = heightmaps[region_coord]

			var neighbors: Dictionary = {}
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var neighbor_coord := Vector2i(rx + dx, ry + dy)
					if heightmaps.has(neighbor_coord):
						neighbors[Vector2i(dx, dy)] = heightmaps[neighbor_coord]

			var tex1: Image
			var tex2: Image
			if use_native:
				var native_result = native_baker.call("BakeWithNeighbors", heightmap, neighbors)
				tex1 = native_result[0]
				tex2 = native_result[1]
			else:
				var result: Array[Image] = baker.bake_with_neighbors(heightmap, neighbors)
				tex1 = result[0]
				tex2 = result[1]
			HorizonMapManager.save_region(region_coord, tex1, tex2)

			horizon_baked += 1
			if horizon_baked % 5 == 0:
				var elapsed := (Time.get_ticks_msec() - horizon_start) / 1000.0
				Log.info("testing", "  Horizon maps: %d/%d (%.1fs)" % [horizon_baked, horizon_total, elapsed])
				await get_tree().process_frame

	Log.info("testing", "Phase 2 COMPLETE: %d horizon maps baked" % horizon_baked)

	# === Summary ===
	var total_elapsed := (Time.get_ticks_msec() - _start_time) / 1000.0
	Log.info("testing", "=" .repeat(80))
	Log.info("testing", "ALL PHASES COMPLETE in %.1fs" % total_elapsed)
	Log.info("testing", "  Terrain regions: %d success, %d failed" % [import_success, import_failed])
	Log.info("testing", "  Horizon maps: %d baked" % horizon_baked)
	Log.info("testing", "=" .repeat(80))

	# Clean up
	terrain.queue_free()

	# Auto-quit after a short delay
	await get_tree().create_timer(2.0).timeout
	get_tree().quit(0)


func _ensure_data() -> bool:
	if ESMManager.cells.size() > 0:
		Log.info("testing", "ESM already loaded (%d cells)" % ESMManager.cells.size())
		return true

	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		Log.error("testing", "No Morrowind data path configured")
		return false

	if BSAManager.get_archive_count() == 0:
		var loaded := BSAManager.load_archives_from_directory(data_path)
		if loaded == 0:
			Log.error("testing", "No BSA archives found in: %s" % data_path)
			return false
		Log.info("testing", "Loaded %d BSA archives" % loaded)

	var esm_file: String = SettingsManager.get_esm_file()
	var esm_path := data_path.path_join(esm_file)
	var err := ESMManager.load_file(esm_path)
	if err != OK:
		Log.error("testing", "Failed to load ESM: %s" % error_string(err))
		return false

	ESMManager.ensure_typed_dicts_populated()
	Log.info("testing", "ESM loaded: %d cells, %d lands" % [ESMManager.cells.size(), ESMManager.lands.size()])
	return true


func _fail(msg: String) -> void:
	Log.error("testing", "FAIL at phase '%s', last region '%s': %s" % [_phase, _last_region, msg])
	push_error("TERRAIN BAKING TEST FAILED: %s (phase=%s, region=%s)" % [msg, _phase, _last_region])
	await get_tree().create_timer(1.0).timeout
	get_tree().quit(1)


## If Godot crashes, the last log line tells you exactly which region caused it.
## Check the Godot log file (usually in AppData or ~/.local/share/godot/app_userdata/).
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_WM_CLOSE_REQUEST:
		Log.info("testing", "SHUTDOWN at phase '%s', last region '%s'" % [_phase, _last_region])
