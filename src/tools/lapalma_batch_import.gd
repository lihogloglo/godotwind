@tool
## La Palma Batch Import - Creates Terrain3D data from preprocessed heightmaps
##
## This script imports all La Palma regions into Terrain3D's native format,
## which loads much faster than streaming from raw heightmap files.
##
## Usage:
##   1. Open this script in the Godot editor
##   2. Run it via the Script menu -> Run (Ctrl+Shift+X)
##   3. Wait for import to complete (~5-10 minutes for 3000 regions)
##   4. The terrain will be saved to res://lapalma_terrain/
##
## After import, you can:
##   - Delete lapalma_processed/ directory (768MB)
##   - Delete lapalma_map/ directory (1.5GB+)
##   - Load terrain data from res://lapalma_terrain/ in your scene
extends EditorScript

const LaPalmaDataProviderScript := preload("res://src/core/world/lapalma_data_provider.gd")

const DATA_DIR := "res://lapalma_processed"
const OUTPUT_DIR := "res://lapalma_terrain"

# Progress tracking
var _total_regions: int = 0
var _imported_regions: int = 0
var _start_time: int = 0


func _run() -> void:
	print("=" .repeat(60))
	print("La Palma Batch Import")
	print("=" .repeat(60))

	_start_time = Time.get_ticks_msec()

	# Create data provider
	print("\n[1/4] Loading data provider...")
	var provider := LaPalmaDataProviderScript.new(DATA_DIR)
	var err := provider.initialize()

	if err != OK:
		push_error("Failed to initialize data provider. Run preprocess_lapalma.py first!")
		return

	print("  World: %s" % provider.world_name)
	print("  Vertex spacing: %.1fm" % provider.vertex_spacing)
	print("  Region size: %d pixels" % provider.region_size)

	# Get all terrain regions
	var regions := provider.get_all_terrain_regions()
	_total_regions = regions.size()
	print("  Terrain regions: %d" % _total_regions)

	# Create output directory first
	print("\n[2/4] Creating Terrain3D storage...")

	var global_output := ProjectSettings.globalize_path(OUTPUT_DIR)
	var dir := DirAccess.open("res://")
	if dir:
		if not dir.dir_exists(OUTPUT_DIR.replace("res://", "")):
			dir.make_dir_recursive(OUTPUT_DIR.replace("res://", ""))

	# Create Terrain3D and add to scene tree (required for data initialization)
	var terrain := Terrain3D.new()
	terrain.name = "BatchImportTerrain"

	# Get the editor's edited scene root to add terrain temporarily
	var editor := EditorInterface.get_edited_scene_root()
	if editor:
		editor.add_child(terrain)
		terrain.owner = editor  # Needed for proper scene integration
	else:
		push_error("No edited scene root! Open a scene first before running this script.")
		terrain.queue_free()
		return

	# Configure terrain BEFORE setting data_directory
	# This ensures proper initialization of internal structures
	terrain.vertex_spacing = provider.vertex_spacing

	# Create material first
	var material := Terrain3DMaterial.new()
	material.show_checkered = false
	material.show_colormap = true
	terrain.set_material(material)

	# Create assets
	terrain.set_assets(Terrain3DAssets.new())

	# Set region size
	@warning_ignore("int_as_enum_without_cast", "int_as_enum_without_match")
	terrain.change_region_size(provider.region_size)

	# Now set data_directory - this creates/loads the data
	terrain.data_directory = global_output

	# Check if data initialized
	if not terrain.data:
		push_error("Terrain3D data not created! Make sure Terrain3D addon is enabled.")
		if editor:
			editor.remove_child(terrain)
		terrain.queue_free()
		return

	print("  Data directory: %s" % global_output)
	print("  Storage created successfully")

	# Import all regions
	print("\n[3/4] Importing %d regions..." % _total_regions)
	print("  This may take several minutes...")

	var region_world_size := float(provider.region_size) * provider.vertex_spacing

	for i in range(regions.size()):
		var region_coord: Vector2i = regions[i]

		# Get heightmap
		var heightmap: Image = provider.get_heightmap_for_region(region_coord)
		if not heightmap:
			continue

		# Get colormap (procedural)
		var colormap: Image = provider.get_colormap_for_region(region_coord)

		# Create default control map
		var controlmap := _create_default_controlmap(provider.region_size)

		# Default colormap if not provided
		if not colormap:
			colormap = Image.create(provider.region_size, provider.region_size, false, Image.FORMAT_RGB8)
			colormap.fill(Color.WHITE)

		# Calculate world position (center of region)
		var world_x := float(region_coord.x) * region_world_size + region_world_size * 0.5
		var world_z := -float(region_coord.y) * region_world_size - region_world_size * 0.5
		var world_pos := Vector3(world_x, 0, world_z)

		# Create import array
		var images: Array[Image] = []
		images.resize(Terrain3DRegion.TYPE_MAX)
		images[Terrain3DRegion.TYPE_HEIGHT] = heightmap
		images[Terrain3DRegion.TYPE_CONTROL] = controlmap
		images[Terrain3DRegion.TYPE_COLOR] = colormap

		# Import into terrain
		terrain.data.import_images(images, world_pos, 0.0, 1.0)

		_imported_regions += 1

		# Progress update every 100 regions
		if _imported_regions % 100 == 0:
			var elapsed := (Time.get_ticks_msec() - _start_time) / 1000.0
			var rate := _imported_regions / elapsed
			var remaining := (_total_regions - _imported_regions) / rate
			print("  Imported %d/%d regions (%.1f/sec, ~%.0fs remaining)" % [
				_imported_regions, _total_regions, rate, remaining
			])

	print("  Import complete: %d regions" % _imported_regions)

	# Save the terrain data
	print("\n[4/4] Saving terrain to %s/..." % OUTPUT_DIR)

	# Save all regions to the data directory
	# save_directory() saves all active regions to the specified path
	terrain.data.save_directory(global_output)

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

	var elapsed := (Time.get_ticks_msec() - _start_time) / 1000.0

	print("\n" + "=" .repeat(60))
	print("Import Complete!")
	print("=" .repeat(60))
	print("  Regions imported: %d" % _imported_regions)
	print("  Output directory: %s" % OUTPUT_DIR)
	print("  Total size: %.1f MB" % (total_size / 1024.0 / 1024.0))
	print("  Time elapsed: %.1f seconds" % elapsed)
	print("")
	print("Next steps:")
	print("  1. In your scene, set Terrain3D data path to '%s'" % OUTPUT_DIR)
	print("  2. You can now delete:")
	print("     - lapalma_processed/ (768 MB)")
	print("     - lapalma_map/la_palma_heightmap.tif (1.5 GB)")
	print("=" .repeat(60))

	# Cleanup - remove from scene tree first
	if editor:
		editor.remove_child(terrain)
	terrain.queue_free()


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
