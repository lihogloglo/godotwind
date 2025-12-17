@tool
## La Palma Batch Import (Scene-based) - Creates Terrain3D data from preprocessed heightmaps
##
## This script imports all La Palma regions into Terrain3D's native format.
## Unlike the EditorScript version, this runs as a scene and has proper Terrain3D initialization.
##
## Usage:
##   1. Open scenes/lapalma_batch_importer.tscn
##   2. In the Inspector, check "Run Import" to start the import
##   3. Wait for import to complete (~5-10 minutes for 3000 regions)
##   4. Check "Save To Disk" to save to res://lapalma_terrain/
##
## After import, you can:
##   - Delete lapalma_processed/ directory (768MB)
##   - Delete lapalma_map/ directory (1.5GB+)
##   - Load terrain data from res://lapalma_terrain/ in your scene
extends Terrain3D

const LaPalmaDataProviderScript := preload("res://src/core/world/lapalma_data_provider.gd")

const DATA_DIR := "res://lapalma_processed"
const OUTPUT_DIR := "res://lapalma_terrain"

# Export controls (like the official importer)
@export var run_import: bool = false : set = _set_run_import
@export var save_to_disk: bool = false : set = _save_data
@export var clear_terrain: bool = false : set = _clear_terrain

# Progress tracking
var _total_regions: int = 0
var _imported_regions: int = 0
var _start_time: int = 0
var _provider: RefCounted = null
var _is_importing: bool = false


func _set_run_import(p_value: bool) -> void:
	if not p_value:
		return
	if _is_importing:
		push_warning("Import already in progress!")
		return
	# Call async import function
	_start_import_async()


func _start_import_async() -> void:
	_is_importing = true

	print("=" .repeat(60))
	print("La Palma Batch Import")
	print("=" .repeat(60))

	_start_time = Time.get_ticks_msec()

	# Create data provider
	print("\n[1/3] Loading data provider...")
	_provider = LaPalmaDataProviderScript.new(DATA_DIR)
	var err: Error = _provider.initialize()

	if err != OK:
		push_error("Failed to initialize data provider. Run preprocess_lapalma.py first!")
		_is_importing = false
		run_import = false
		return

	print("  World: %s" % _provider.world_name)
	print("  Vertex spacing: %.1fm" % _provider.vertex_spacing)
	print("  Region size: %d pixels" % _provider.region_size)

	# Get all terrain regions
	var regions: Array = _provider.get_all_terrain_regions()
	_total_regions = regions.size()
	print("  Terrain regions: %d" % _total_regions)

	# Ensure terrain is configured
	print("\n[2/3] Configuring terrain...")
	vertex_spacing = _provider.vertex_spacing

	@warning_ignore("int_as_enum_without_cast", "int_as_enum_without_match")
	change_region_size(_provider.region_size)

	if not data:
		push_error("Terrain3D data not initialized!")
		_is_importing = false
		run_import = false
		return

	print("  Terrain3D data ready")

	# Import all regions
	print("\n[3/3] Importing regions...")
	print("  This may take several minutes...")
	print("  (Editor may be slow during import - this is normal)")

	var region_world_size: float = float(_provider.region_size) * float(_provider.vertex_spacing)
	_imported_regions = 0

	# Terrain3D has a hard limit of ±8192 world units
	# Calculate which regions fit within this limit
	const TERRAIN3D_WORLD_LIMIT := 8192.0
	var max_region_coord: int = int(TERRAIN3D_WORLD_LIMIT / region_world_size) - 1
	var skipped_regions := 0

	print("  Terrain3D limit: +/-%.0f units" % TERRAIN3D_WORLD_LIMIT)
	print("  Region size: %.0fm -> max region coord: +/-%d" % [region_world_size, max_region_coord])

	# Filter regions that fit within bounds
	var valid_regions: Array[Vector2i] = []
	for coord in regions:
		var region_coord: Vector2i = coord
		if abs(region_coord.x) <= max_region_coord and abs(region_coord.y) <= max_region_coord:
			valid_regions.append(region_coord)
		else:
			skipped_regions += 1

	_total_regions = valid_regions.size()
	print("  Valid regions: %d (skipped %d outside bounds)" % [_total_regions, skipped_regions])

	if _total_regions == 0:
		push_error("No regions fit within Terrain3D bounds! Try increasing vertex_spacing.")
		_is_importing = false
		run_import = false
		return

	# Process in batches to prevent editor crash
	const BATCH_SIZE := 10  # Import 10 regions per frame to prevent crash
	var batch_count := 0

	for i in range(valid_regions.size()):
		var region_coord: Vector2i = valid_regions[i]

		# Get heightmap
		var heightmap: Image = _provider.get_heightmap_for_region(region_coord)
		if not heightmap:
			continue

		# Get colormap (procedural)
		var colormap: Image = _provider.get_colormap_for_region(region_coord)

		# Create default control map
		var controlmap: Image = _create_default_controlmap(int(_provider.region_size))

		# Default colormap if not provided
		if not colormap:
			colormap = Image.create(int(_provider.region_size), int(_provider.region_size), false, Image.FORMAT_RGB8)
			colormap.fill(Color.WHITE)

		# Calculate world position (center of region)
		var world_x: float = float(region_coord.x) * region_world_size + region_world_size * 0.5
		var world_z: float = -float(region_coord.y) * region_world_size - region_world_size * 0.5
		var world_pos := Vector3(world_x, 0, world_z)

		# Create import array
		var images: Array[Image] = []
		images.resize(Terrain3DRegion.TYPE_MAX)
		images[Terrain3DRegion.TYPE_HEIGHT] = heightmap
		images[Terrain3DRegion.TYPE_CONTROL] = controlmap
		images[Terrain3DRegion.TYPE_COLOR] = colormap

		# Import into terrain
		data.import_images(images, world_pos, 0.0, 1.0)

		_imported_regions += 1
		batch_count += 1

		# Yield every BATCH_SIZE regions to let editor breathe
		if batch_count >= BATCH_SIZE:
			batch_count = 0
			# Allow editor to process events
			if Engine.is_editor_hint() and is_inside_tree():
				await get_tree().process_frame

		# Progress update every 100 regions
		if _imported_regions % 100 == 0:
			var elapsed := (Time.get_ticks_msec() - _start_time) / 1000.0
			var rate := _imported_regions / elapsed if elapsed > 0 else 0.0
			var remaining := (_total_regions - _imported_regions) / rate if rate > 0 else 0.0
			print("  Imported %d/%d regions (%.1f/sec, ~%.0fs remaining)" % [
				_imported_regions, _total_regions, rate, remaining
			])

	var elapsed := (Time.get_ticks_msec() - _start_time) / 1000.0

	print("\n" + "=" .repeat(60))
	print("Import Complete!")
	print("=" .repeat(60))
	print("  Regions imported: %d" % _imported_regions)
	print("  Time elapsed: %.1f seconds" % elapsed)
	print("")
	if skipped_regions > 0:
		var coverage_km := (max_region_coord * 2 + 1) * region_world_size / 1000.0
		print("[WARNING] %d regions skipped (outside Terrain3D bounds)" % skipped_regions)
		print("  Current coverage: ~%.1f x %.1f km (centered at origin)" % [coverage_km, coverage_km])
		print("  To import more: rerun preprocessing with larger vertex_spacing")
		print("")
	print("Now check 'Save To Disk' in the Inspector to save the terrain.")
	print("=" .repeat(60))

	_is_importing = false
	run_import = false  # Reset the checkbox


func _save_data(p_value: bool) -> void:
	if not p_value:
		return

	if not data or data.get_region_count() == 0:
		push_error("No terrain data to save! Run import first.")
		return

	# Create output directory
	var global_output := ProjectSettings.globalize_path(OUTPUT_DIR)
	var dir := DirAccess.open("res://")
	if dir:
		if not dir.dir_exists(OUTPUT_DIR.replace("res://", "")):
			dir.make_dir_recursive(OUTPUT_DIR.replace("res://", ""))

	print("Saving terrain to %s..." % global_output)

	# Save all regions to the data directory
	data.save_directory(global_output)

	# Calculate directory size
	var total_size: int = 0
	var dir_check := DirAccess.open(OUTPUT_DIR)
	if dir_check:
		dir_check.list_dir_begin()
		var file_name := dir_check.get_next()
		while file_name != "":
			if not dir_check.current_is_dir():
				var f := FileAccess.open(OUTPUT_DIR.path_join(file_name), FileAccess.READ)
				if f:
					total_size += f.get_length()
					f.close()
			file_name = dir_check.get_next()

	print("=" .repeat(60))
	print("Save Complete!")
	print("=" .repeat(60))
	print("  Output directory: %s" % OUTPUT_DIR)
	print("  Total size: %.1f MB" % (total_size / 1024.0 / 1024.0))
	print("  Region count: %d" % data.get_region_count())
	print("")
	print("Next steps:")
	print("  1. In your scene, set Terrain3D data_directory to '%s'" % global_output)
	print("  2. You can now delete:")
	print("     - lapalma_processed/ (768 MB)")
	print("     - lapalma_map/la_palma_heightmap.tif (1.5 GB)")
	print("=" .repeat(60))


func _clear_terrain(p_value: bool) -> void:
	if not p_value:
		return

	if not data:
		return

	print("Clearing all terrain regions...")
	for region: Terrain3DRegion in data.get_regions_active():
		data.remove_region(region, false)
	data.update_maps(Terrain3DRegion.TYPE_MAX, true, false)
	print("Terrain cleared.")


func _create_default_controlmap(size: int) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_RF)
	# Default to texture slot 0
	var value: int = 0
	value |= (0 & 0x1F) << 27
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, value)
	var default_value := bytes.decode_float(0)
	img.fill(Color(default_value, 0, 0, 1))
	return img
