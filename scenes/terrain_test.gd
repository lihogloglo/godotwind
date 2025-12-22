## Simplified Morrowind Terrain Test
##
## This is a minimal test scene that loads Morrowind terrain directly into Terrain3D
## without the complexity of world streaming. This helps identify performance bottlenecks
## by comparing direct loading vs streaming.
##
## Key differences from world_explorer:
## - No WorldStreamingManager (no streaming logic)
## - No OWDB (no object loading)
## - No dynamic region loading/unloading
## - Direct synchronous terrain loading
## - Loads a fixed area around a specific location
##
## This allows us to measure:
## - Pure terrain generation time
## - Terrain3D rendering performance
## - Memory usage without streaming overhead
extends Node3D

# Preload dependencies
const TerrainManagerScript := preload("res://src/core/world/terrain_manager.gd")
const TerrainTextureLoaderScript := preload("res://src/core/world/terrain_texture_loader.gd")
const CS := preload("res://src/core/coordinate_system.gd")

# Test configuration
const TEST_CENTER_CELL := Vector2i(-2, -9)  # Seyda Neen
const TEST_RADIUS_REGIONS := 2  # Load 2 regions in each direction = 5x5 grid

# Node references
@onready var camera: Camera3D = $Camera3D
@onready var terrain_3d: Terrain3D = $Terrain3D
@onready var status_label: RichTextLabel = $UI/InfoPanel/VBox/StatusLabel

# Managers
var terrain_manager: RefCounted = null
var texture_loader: RefCounted = null

# Camera controls
var camera_speed: float = 200.0
var mouse_sensitivity: float = 0.003
var mouse_captured: bool = false

# Stats
var _total_load_time_ms: float = 0.0
var _regions_loaded: int = 0
var _data_path: String = ""


func _ready() -> void:
	# Initialize managers
	terrain_manager = TerrainManagerScript.new()
	texture_loader = TerrainTextureLoaderScript.new()

	# Get Morrowind data path (try auto-detection if not configured)
	_data_path = SettingsManager.get_data_path()
	if _data_path.is_empty():
		_log("No data path configured, attempting auto-detection...")
		_data_path = SettingsManager.auto_detect_installation()
		if not _data_path.is_empty():
			_log("[color=green]Auto-detected Morrowind at: %s[/color]" % _data_path)
			SettingsManager.set_data_path(_data_path)
		else:
			_log("[color=red]ERROR: Morrowind data path not configured and auto-detection failed.[/color]")
			_log("[color=yellow]Set MORROWIND_DATA_PATH environment variable or use settings UI.[/color]")
			return

	# Start initialization
	call_deferred("_init_async")


func _init_async() -> void:
	var init_start := Time.get_ticks_msec()

	# Load BSA archives
	_log("Loading BSA archives...")
	var bsa_count := BSAManager.load_archives_from_directory(_data_path)
	_log("Loaded %d BSA archives" % bsa_count)

	# Load ESM file
	_log("Loading ESM file...")
	var esm_file: String = SettingsManager.get_esm_file()
	var esm_path := _data_path.path_join(esm_file)
	var error := ESMManager.load_file(esm_path)

	if error != OK:
		_log("[color=red]ERROR: Failed to load ESM: %s[/color]" % error_string(error))
		return

	_log("[color=green]ESM loaded: %d LAND records, %d CELL records[/color]" % [ESMManager.lands.size(), ESMManager.cells.size()])

	# Initialize Terrain3D
	_log("Initializing Terrain3D...")
	_init_terrain3d()

	var init_time := Time.get_ticks_msec() - init_start
	_log("[color=cyan]Initialization complete in %d ms[/color]" % init_time)

	# Load test terrain
	_log("")
	_log("[color=yellow]Loading terrain around Seyda Neen...[/color]")
	_load_test_terrain()

	_log("")
	_log("[color=green]Test complete![/color]")
	_log("[color=cyan]Total regions loaded: %d[/color]" % _regions_loaded)
	_log("[color=cyan]Total terrain load time: %.2f ms[/color]" % _total_load_time_ms)
	if _regions_loaded > 0:
		_log("[color=cyan]Average per region: %.2f ms[/color]" % (_total_load_time_ms / _regions_loaded))


func _init_terrain3d() -> void:
	if not ClassDB.class_exists("Terrain3DData"):
		_log("[color=red]ERROR: Terrain3D addon not loaded[/color]")
		return

	if not terrain_3d:
		_log("[color=red]ERROR: Terrain3D node not found[/color]")
		return

	# Configure Terrain3D with same settings as world_explorer
	var vertex_spacing := CS.CELL_SIZE_GODOT / 64.0
	terrain_3d.vertex_spacing = vertex_spacing

	@warning_ignore("int_as_enum_without_cast", "int_as_enum_without_match")
	terrain_3d.change_region_size(256)

	terrain_3d.mesh_lods = 7
	terrain_3d.mesh_size = 48

	# Setup material
	if not terrain_3d.material:
		terrain_3d.set_material(Terrain3DMaterial.new())
	terrain_3d.material.show_checkered = false

	# Setup assets
	if not terrain_3d.assets:
		terrain_3d.set_assets(Terrain3DAssets.new())

	# Load terrain textures
	var textures_loaded: int = texture_loader.load_terrain_textures(terrain_3d.assets)
	_log("Loaded %d terrain textures" % textures_loaded)

	# Configure terrain manager
	terrain_manager.set_texture_slot_mapper(texture_loader)

	_log("Terrain3D configured: region_size=256, vertex_spacing=%.3f" % vertex_spacing)


func _load_test_terrain() -> void:
	# Calculate center region from center cell
	var center_region := TerrainManagerScript.cell_to_region(TEST_CENTER_CELL)
	_log("Center cell: %s → region: %s" % [TEST_CENTER_CELL, center_region])

	# Load regions in a grid around center
	var regions_to_load: Array[Vector2i] = []
	for rx in range(-TEST_RADIUS_REGIONS, TEST_RADIUS_REGIONS + 1):
		for ry in range(-TEST_RADIUS_REGIONS, TEST_RADIUS_REGIONS + 1):
			regions_to_load.append(center_region + Vector2i(rx, ry))

	_log("Loading %d regions..." % regions_to_load.size())

	# Load each region and measure time
	for region_coord in regions_to_load:
		var load_start := Time.get_ticks_usec()

		# Get the 4x4 cells that make up this region
		var cell_coords: Array[Vector2i] = []
		var base_x := region_coord.x * TerrainManagerScript.CELLS_PER_REGION
		var base_y := region_coord.y * TerrainManagerScript.CELLS_PER_REGION

		for cx in range(TerrainManagerScript.CELLS_PER_REGION):
			for cy in range(TerrainManagerScript.CELLS_PER_REGION):
				cell_coords.append(Vector2i(base_x + cx, base_y + cy))

		# Check if we have LAND records for any of these cells
		var has_land := false
		for cell_coord in cell_coords:
			if ESMManager.get_land(cell_coord.x, cell_coord.y) != null:
				has_land = true
				break

		if not has_land:
			continue  # Skip regions with no terrain data

		# Generate and import the combined region
		var get_land_func := func(x: int, y: int) -> LandRecord:
			return ESMManager.get_land(x, y)

		terrain_manager.import_combined_region(terrain_3d, region_coord, get_land_func)

		var load_time_us := Time.get_ticks_usec() - load_start
		var load_time_ms := load_time_us / 1000.0

		_total_load_time_ms += load_time_ms
		_regions_loaded += 1

		_log("  Region %s loaded in %.2f ms" % [region_coord, load_time_ms])

		# Yield occasionally to keep UI responsive
		if _regions_loaded % 5 == 0:
			await get_tree().process_frame

	# Position camera at test center
	var center_pos := CS.cell_grid_to_center_godot(TEST_CENTER_CELL)
	camera.position = Vector3(center_pos.x, 200, center_pos.z)
	_log("Camera positioned at %s" % camera.position)


func _process(delta: float) -> void:
	if not mouse_captured:
		return

	# Camera movement
	var velocity := Vector3.ZERO
	var speed := camera_speed

	if Input.is_key_pressed(KEY_CTRL):
		speed *= 3.0

	if Input.is_key_pressed(KEY_W):
		velocity -= camera.global_transform.basis.z
	if Input.is_key_pressed(KEY_S):
		velocity += camera.global_transform.basis.z
	if Input.is_key_pressed(KEY_A):
		velocity -= camera.global_transform.basis.x
	if Input.is_key_pressed(KEY_D):
		velocity += camera.global_transform.basis.x
	if Input.is_key_pressed(KEY_SPACE):
		velocity += Vector3.UP
	if Input.is_key_pressed(KEY_SHIFT):
		velocity -= Vector3.UP

	if velocity.length() > 0:
		velocity = velocity.normalized() * speed * delta
		camera.position += velocity


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				mouse_captured = true
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			else:
				mouse_captured = false
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	if event is InputEventMouseMotion and mouse_captured:
		camera.rotate_y(-event.relative.x * mouse_sensitivity)
		camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * mouse_sensitivity)

		# Clamp vertical rotation
		var rot := camera.rotation
		rot.x = clamp(rot.x, -PI/2, PI/2)
		camera.rotation = rot


func _log(message: String) -> void:
	print(message)
	if status_label:
		status_label.append_text(message + "\n")


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_O:
			# Toggle ocean
			if OceanManager:
				var enabled := OceanManager.toggle_ocean()
				_log("Ocean: %s" % ("ON" if enabled else "OFF"))
			else:
				_log("OceanManager not available")
