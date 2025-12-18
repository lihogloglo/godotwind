@tool
## La Palma Terrain Importer (Memory-Optimized)
##
## Imports preprocessed La Palma heightmaps into Terrain3D native storage.
## Designed to work on low-memory systems by processing in small batches.
##
## Usage:
##   1. Run: python3 tools/preprocess_lapalma.py
##   2. Open scenes/lapalma_importer.tscn
##   3. In Inspector: click "Run Import"
##   4. Wait for completion, then click "Save Terrain"
##   5. Delete lapalma_processed/ and lapalma_map/ directories
extends Terrain3D

const DATA_DIR := "res://lapalma_processed"
const OUTPUT_DIR := "res://lapalma_terrain"

## How many regions to import before yielding and saving
## Lower = less memory usage, slower import
@export_range(1, 20) var batch_size: int = 3

## Click to start the import process
@export var run_import: bool = false:
	set(v):
		if v:
			_run_import()

## Click to save terrain to disk after import
@export var save_terrain: bool = false:
	set(v):
		if v:
			_save_terrain()

## Click to clear all terrain regions
@export var clear_terrain: bool = false:
	set(v):
		if v:
			_clear_terrain()

var _metadata: Dictionary = {}
var _is_importing: bool = false


func _run_import() -> void:
	if _is_importing:
		push_warning("Import already in progress")
		return
	_is_importing = true

	print("\n" + "=".repeat(60))
	print("La Palma Terrain Import (Memory-Optimized)")
	print("=".repeat(60))

	# Load metadata
	var meta_path := DATA_DIR + "/metadata.json"
	var file := FileAccess.open(meta_path, FileAccess.READ)
	if not file:
		push_error("Metadata not found: " + meta_path)
		push_error("Run: python3 tools/preprocess_lapalma.py")
		_is_importing = false
		return

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("Failed to parse metadata.json")
		_is_importing = false
		return
	file.close()
	_metadata = json.data

	var region_size: int = int(_metadata.region_size)
	var vs: float = float(_metadata.vertex_spacing)

	print("\nWorld: %s" % _metadata.get("world_name", "Unknown"))
	print("Region size: %d pixels" % region_size)
	print("Vertex spacing: %.1fm" % vs)
	print("Batch size: %d regions" % batch_size)

	# Configure terrain
	vertex_spacing = vs
	@warning_ignore("int_as_enum_without_cast", "int_as_enum_without_match")
	change_region_size(region_size)

	if not data:
		push_error("Terrain3D data not initialized")
		_is_importing = false
		return

	# Get regions to import
	var regions: Array = _metadata.get("regions", [])
	var region_world_size: float = float(region_size) * vs

	# Filter valid regions first
	var valid_regions: Array[Dictionary] = []
	for reg in regions:
		var coord := Vector2i(int(reg.x), int(reg.y))
		if abs(coord.x) <= 15 and abs(coord.y) <= 15:
			valid_regions.append(reg)

	var total := valid_regions.size()
	print("\nRegions to import: %d (of %d total)" % [total, regions.size()])

	# Import in small batches
	var start_time := Time.get_ticks_msec()
	var imported := 0

	for i in range(total):
		var reg: Dictionary = valid_regions[i]
		var coord := Vector2i(int(reg.x), int(reg.y))

		# Import single region
		var success := await _import_single_region(reg, coord, region_size, region_world_size)
		if success:
			imported += 1

		# Yield after each region for editor responsiveness
		if Engine.is_editor_hint() and is_inside_tree():
			await get_tree().process_frame

		# Progress update
		if imported % 10 == 0 or imported == total:
			var elapsed := (Time.get_ticks_msec() - start_time) / 1000.0
			var rate := imported / elapsed if elapsed > 0 else 0.0
			var remaining := (total - imported) / rate if rate > 0 else 0.0
			print("  [%d/%d] %.1f/sec, ~%.0fs remaining" % [imported, total, rate, remaining])

	var elapsed := (Time.get_ticks_msec() - start_time) / 1000.0

	print("\n" + "=".repeat(60))
	print("Import Complete!")
	print("=".repeat(60))
	print("  Regions imported: %d" % imported)
	print("  Time: %.1f seconds" % elapsed)
	print("\nNow click 'Save Terrain' to save to disk.")
	print("=".repeat(60) + "\n")

	_is_importing = false


func _import_single_region(reg: Dictionary, coord: Vector2i, region_size: int, region_world_size: float) -> bool:
	# Load heightmap from file
	var raw_path: String = DATA_DIR + "/regions/" + str(reg.file)
	var raw_file := FileAccess.open(raw_path, FileAccess.READ)
	if not raw_file:
		push_warning("Missing: " + str(reg.file))
		return false

	var raw_bytes := raw_file.get_buffer(region_size * region_size * 4)
	raw_file.close()

	var heightmap := Image.create_from_data(
		region_size, region_size, false, Image.FORMAT_RF, raw_bytes
	)

	# Create colormap (simple version - less memory)
	var colormap := _create_simple_colormap(heightmap, region_size)

	# Create control map
	var controlmap := _create_controlmap(region_size)

	# Calculate world position
	var world_x := float(coord.x) * region_world_size + region_world_size * 0.5
	var world_z := -float(coord.y) * region_world_size - region_world_size * 0.5
	var world_pos := Vector3(world_x, 0, world_z)

	# Import into Terrain3D
	var images: Array[Image] = []
	images.resize(Terrain3DRegion.TYPE_MAX)
	images[Terrain3DRegion.TYPE_HEIGHT] = heightmap
	images[Terrain3DRegion.TYPE_CONTROL] = controlmap
	images[Terrain3DRegion.TYPE_COLOR] = colormap

	data.import_images(images, world_pos, 0.0, 1.0)

	return true


func _save_terrain() -> void:
	if not data or data.get_region_count() == 0:
		push_error("No terrain to save. Run import first.")
		return

	# Create output directory
	var dir := DirAccess.open("res://")
	if dir and not dir.dir_exists(OUTPUT_DIR.replace("res://", "")):
		dir.make_dir_recursive(OUTPUT_DIR.replace("res://", ""))

	var global_path := ProjectSettings.globalize_path(OUTPUT_DIR)
	print("\nSaving terrain to: " + global_path)

	data.save_directory(global_path)

	# Calculate saved size
	var total_size := 0
	var out_dir := DirAccess.open(OUTPUT_DIR)
	if out_dir:
		out_dir.list_dir_begin()
		var fname := out_dir.get_next()
		while fname != "":
			if not out_dir.current_is_dir():
				var f := FileAccess.open(OUTPUT_DIR + "/" + fname, FileAccess.READ)
				if f:
					total_size += f.get_length()
			fname = out_dir.get_next()

	print("\n" + "=".repeat(60))
	print("Terrain Saved!")
	print("=".repeat(60))
	print("  Output: %s" % OUTPUT_DIR)
	print("  Size: %.1f MB" % (total_size / 1024.0 / 1024.0))
	print("  Regions: %d" % data.get_region_count())
	print("\nYou can now delete:")
	print("  - lapalma_processed/  (~900 MB)")
	print("  - lapalma_map/        (~2.2 GB)")
	print("=".repeat(60) + "\n")


func _clear_terrain() -> void:
	if not data:
		return
	print("Clearing terrain...")
	for region: Terrain3DRegion in data.get_regions_active():
		data.remove_region(region, false)
	data.update_maps(Terrain3DRegion.TYPE_MAX, true, false)
	print("Terrain cleared.")


func _create_simple_colormap(heightmap: Image, size: int) -> Image:
	## Create a simple height-based colormap using raw bytes (more memory efficient)
	var color_data := PackedByteArray()
	color_data.resize(size * size * 3)

	for y in range(size):
		for x in range(size):
			var height: float = heightmap.get_pixel(x, y).r
			var color := _height_to_color(height)
			var idx := (y * size + x) * 3
			color_data[idx] = int(color.r * 255)
			color_data[idx + 1] = int(color.g * 255)
			color_data[idx + 2] = int(color.b * 255)

	return Image.create_from_data(size, size, false, Image.FORMAT_RGB8, color_data)


func _height_to_color(height: float) -> Color:
	## Map height to terrain colors
	if height <= 0:
		return Color(0.76, 0.70, 0.50)  # Sandy beach
	elif height < 100:
		var t := height / 100.0
		return Color(0.35, 0.45, 0.25).lerp(Color(0.30, 0.50, 0.22), t)
	elif height < 500:
		var t := (height - 100) / 400.0
		return Color(0.30, 0.50, 0.22).lerp(Color(0.25, 0.42, 0.18), t)
	elif height < 1200:
		var t := (height - 500) / 700.0
		return Color(0.25, 0.42, 0.18).lerp(Color(0.35, 0.35, 0.28), t)
	elif height < 1800:
		var t := (height - 1200) / 600.0
		return Color(0.35, 0.35, 0.28).lerp(Color(0.45, 0.42, 0.38), t)
	elif height < 2200:
		var t := (height - 1800) / 400.0
		return Color(0.45, 0.42, 0.38).lerp(Color(0.55, 0.52, 0.50), t)
	else:
		return Color(0.60, 0.58, 0.55)  # Peak


func _create_controlmap(size: int) -> Image:
	## Create default control map (texture slot 0)
	var img := Image.create(size, size, false, Image.FORMAT_RF)
	var value: int = (0 & 0x1F) << 27
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, value)
	var default_val := bytes.decode_float(0)
	img.fill(Color(default_val, 0, 0, 1))
	return img
