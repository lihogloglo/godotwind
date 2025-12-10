## Terrain Viewer - Test tool for visualizing Morrowind terrain with Terrain3D
## Loads LAND records and imports them into Terrain3D for visualization
extends Node3D

# Preload dependencies
const MWCoords := preload("res://src/core/morrowind_coords.gd")
const TerrainManagerScript := preload("res://src/core/world/terrain_manager.gd")

# UI references - Main panel
@onready var cell_x_spin: SpinBox = $UI/Panel/VBox/CoordsContainer/CellXSpin
@onready var cell_y_spin: SpinBox = $UI/Panel/VBox/CoordsContainer/CellYSpin
@onready var radius_spin: SpinBox = $UI/Panel/VBox/RadiusContainer/RadiusSpin
@onready var load_terrain_button: Button = $UI/Panel/VBox/LoadTerrainButton
@onready var stats_text: RichTextLabel = $UI/Panel/VBox/StatsText
@onready var log_text: RichTextLabel = $UI/Panel/VBox/LogText

# Quick load buttons
@onready var seyda_neen_btn: Button = $UI/Panel/VBox/QuickButtons/SeydaNeenBtn
@onready var balmora_btn: Button = $UI/Panel/VBox/QuickButtons/BalmoraBtn
@onready var vivec_btn: Button = $UI/Panel/VBox/QuickButtons/VivecBtn
@onready var origin_btn: Button = $UI/Panel/VBox/QuickButtons/OriginBtn

# Loading overlay UI
@onready var loading_overlay: ColorRect = $UI/LoadingOverlay
@onready var loading_label: Label = $UI/LoadingOverlay/VBox/LoadingLabel
@onready var progress_bar: ProgressBar = $UI/LoadingOverlay/VBox/ProgressBar
@onready var status_label: Label = $UI/LoadingOverlay/VBox/StatusLabel

# Terrain3D node reference
@onready var terrain_3d: Terrain3D = $Terrain3D
@onready var camera: Camera3D = $FlyCamera

# Camera movement
var camera_speed: float = 200.0  # Meters per second
var mouse_sensitivity: float = 0.003
var mouse_captured: bool = false

# Terrain manager instance
var terrain_manager: RefCounted  # TerrainManager

# Track loaded cells
var _loaded_cells: Array[Vector2i] = []


func _ready() -> void:
	# Initialize terrain manager
	terrain_manager = TerrainManagerScript.new()

	# Connect UI signals
	load_terrain_button.pressed.connect(_on_load_terrain_pressed)

	# Connect quick load buttons
	seyda_neen_btn.pressed.connect(func(): _load_preset_area(-2, -9, 2))  # Seyda Neen area
	balmora_btn.pressed.connect(func(): _load_preset_area(-3, -2, 2))     # Balmora area
	vivec_btn.pressed.connect(func(): _load_preset_area(5, -6, 2))        # Vivec area
	origin_btn.pressed.connect(func(): _load_preset_area(0, 0, 1))        # Origin

	# Get Morrowind data path from project settings
	var data_path: String = ProjectSettings.get_setting("morrowind/data_path", "")
	if data_path.is_empty():
		_hide_loading()
		_log("[color=red]ERROR: Morrowind data path not configured in project.godot[/color]")
		return

	_log("Morrowind data path: " + data_path)

	# Load ESM and BSA files with progress updates
	_show_loading("Loading Game Data", "Initializing...")
	call_deferred("_load_game_data_async", data_path)


## Show the loading overlay with a title and status
func _show_loading(title: String, status: String) -> void:
	loading_overlay.visible = true
	loading_label.text = title
	status_label.text = status
	progress_bar.value = 0


## Hide the loading overlay
func _hide_loading() -> void:
	loading_overlay.visible = false


## Update loading progress
func _update_loading(progress: float, status: String) -> void:
	progress_bar.value = progress
	status_label.text = status
	# Force UI update
	await get_tree().process_frame


## Async version of game data loading with progress updates
func _load_game_data_async(data_path: String) -> void:
	_log("Loading BSA archives...")
	_update_loading(10, "Loading BSA archives...")
	await get_tree().process_frame

	# Load BSA files
	var bsa_count := BSAManager.load_archives_from_directory(data_path)
	_log("Loaded %d BSA archives" % bsa_count)

	if bsa_count == 0:
		_log("[color=yellow]Warning: No BSA archives found.[/color]")

	_update_loading(40, "Loading ESM file...")
	await get_tree().process_frame

	# Load ESM file
	var esm_file: String = ProjectSettings.get_setting("morrowind/esm_file", "Morrowind.esm")
	var esm_path := data_path.path_join(esm_file)

	_log("Loading ESM: " + esm_path)
	var error := ESMManager.load_file(esm_path)

	if error != OK:
		_log("[color=red]ERROR: Failed to load ESM file: %s[/color]" % error_string(error))
		_hide_loading()
		return

	_log("[color=green]ESM loaded successfully![/color]")
	_log("LAND records: %d" % ESMManager.lands.size())
	_log("LTEX records: %d" % ESMManager.land_textures.size())

	_update_loading(90, "Initializing Terrain3D...")
	await get_tree().process_frame

	# Initialize Terrain3D if needed
	_init_terrain3d()

	_update_loading(100, "Done!")
	await get_tree().process_frame

	# Hide loading overlay after a brief delay
	await get_tree().create_timer(0.3).timeout
	_hide_loading()

	_log("[color=green]Ready to load terrain![/color]")
	_log("Use the controls to select cell coordinates and load terrain.")


## Initialize Terrain3D with required resources
func _init_terrain3d() -> void:
	if not terrain_3d:
		_log("[color=red]ERROR: Terrain3D node not found![/color]")
		return

	# Check if Terrain3D classes are available (GDExtension loaded)
	if not ClassDB.class_exists("Terrain3DData"):
		_log("[color=red]ERROR: Terrain3D GDExtension not loaded! Make sure the plugin is enabled.[/color]")
		return

	# Create Terrain3DData if not present
	if not terrain_3d.data:
		terrain_3d.data = Terrain3DData.new()
		_log("Created new Terrain3DData")

	# Create Terrain3DMaterial if not present
	if not terrain_3d.material:
		terrain_3d.material = Terrain3DMaterial.new()
		terrain_3d.material.show_colormap = true
		_log("Created new Terrain3DMaterial with colormap display")

	# Create Terrain3DAssets if not present
	if not terrain_3d.assets:
		terrain_3d.assets = Terrain3DAssets.new()
		_log("Created new Terrain3DAssets")

	_log("[color=green]Terrain3D initialized successfully[/color]")


## Load a preset area
func _load_preset_area(center_x: int, center_y: int, radius: int) -> void:
	cell_x_spin.value = center_x
	cell_y_spin.value = center_y
	radius_spin.value = radius
	_on_load_terrain_pressed()


## Handle load terrain button press
func _on_load_terrain_pressed() -> void:
	var center_x := int(cell_x_spin.value)
	var center_y := int(cell_y_spin.value)
	var radius := int(radius_spin.value)

	_log("\n[b]Loading terrain around (%d, %d) with radius %d[/b]" % [center_x, center_y, radius])

	# Get cells to load
	var cells_to_load := TerrainManagerScript.get_cells_in_radius(center_x, center_y, radius)
	_log("Cells to load: %d" % cells_to_load.size())

	# Show loading overlay
	_show_loading("Loading Terrain", "Preparing...")
	await get_tree().process_frame

	# Load terrain asynchronously
	await _load_terrain_async(cells_to_load)

	_hide_loading()


## Load terrain cells asynchronously
func _load_terrain_async(cells: Array[Vector2i]) -> void:
	var start_time := Time.get_ticks_msec()
	var total_cells := cells.size()
	var loaded_count := 0
	var skipped_count := 0

	# Clear existing terrain data
	_update_loading(5, "Clearing existing terrain...")
	await get_tree().process_frame

	# Reset Terrain3D data
	if terrain_3d.data:
		# Remove all existing regions
		for region in terrain_3d.data.get_regions_active():
			terrain_3d.data.remove_region(region, false)
		terrain_3d.data.update_maps(Terrain3DRegion.TYPE_MAX, true, false)

	_loaded_cells.clear()

	# Process each cell
	for i in range(total_cells):
		var cell_coord := cells[i]
		var progress := 10.0 + (80.0 * float(i) / float(total_cells))
		_update_loading(progress, "Loading cell (%d, %d)..." % [cell_coord.x, cell_coord.y])
		await get_tree().process_frame

		# Get LAND record for this cell
		var land: LandRecord = ESMManager.get_land(cell_coord.x, cell_coord.y)
		if not land:
			_log("[color=yellow]No LAND data for cell (%d, %d)[/color]" % [cell_coord.x, cell_coord.y])
			skipped_count += 1
			continue

		if not land.has_heights():
			_log("[color=yellow]Cell (%d, %d) has no height data[/color]" % [cell_coord.x, cell_coord.y])
			skipped_count += 1
			continue

		# Import this cell into Terrain3D
		_import_cell_to_terrain3d(land)
		_loaded_cells.append(cell_coord)
		loaded_count += 1

	# Update height range
	_update_loading(95, "Finalizing terrain...")
	await get_tree().process_frame

	if terrain_3d.data:
		terrain_3d.data.calc_height_range(true)

	var elapsed := Time.get_ticks_msec() - start_time

	# Update stats
	_update_stats(loaded_count, skipped_count, elapsed)

	_log("[color=green]Terrain loaded in %d ms[/color]" % elapsed)
	_log("Loaded: %d cells, Skipped: %d cells" % [loaded_count, skipped_count])

	# Position camera
	if not _loaded_cells.is_empty():
		_position_camera_for_terrain()


## Import a single LAND record into Terrain3D
func _import_cell_to_terrain3d(land: LandRecord) -> void:
	if not terrain_3d or not terrain_3d.data:
		return

	# Generate maps from LAND record
	var heightmap := terrain_manager.generate_heightmap(land)
	var colormap := terrain_manager.generate_color_map(land)
	var controlmap := terrain_manager.generate_control_map(land)

	# Calculate world position for this cell
	# Terrain3D uses XZ plane, Morrowind cell coords map to world position
	# MW cell (0,0) starts at world origin, each cell is ~117 meters (8192/70)
	var cell_size_godot := LandRecord.CELL_SIZE / MWCoords.UNITS_PER_METER

	# MW Y axis is North, Godot Z axis is South, so negate Y
	var world_x := float(land.cell_x) * cell_size_godot
	var world_z := float(-land.cell_y) * cell_size_godot  # Negate for coordinate conversion

	# Create import array [heightmap, controlmap, colormap]
	var imported_images: Array[Image] = []
	imported_images.resize(Terrain3DRegion.TYPE_MAX)
	imported_images[Terrain3DRegion.TYPE_HEIGHT] = heightmap
	imported_images[Terrain3DRegion.TYPE_CONTROL] = controlmap
	imported_images[Terrain3DRegion.TYPE_COLOR] = colormap

	# Import into Terrain3D at the calculated position
	var import_pos := Vector3(world_x, 0, world_z)
	terrain_3d.data.import_images(imported_images, import_pos, 0.0, 1.0)


## Update statistics display
func _update_stats(loaded: int, skipped: int, elapsed: int) -> void:
	var terrain_stats := terrain_manager.get_stats()
	stats_text.text = """[b]Terrain Stats:[/b]
Cells loaded: %d
Cells skipped: %d
Heightmaps generated: %d
Control maps generated: %d
Load time: %d ms

[b]Camera Position:[/b]
%s""" % [
		loaded,
		skipped,
		terrain_stats.get("heightmaps_generated", 0),
		terrain_stats.get("control_maps_generated", 0),
		elapsed,
		"%.1f, %.1f, %.1f" % [camera.position.x, camera.position.y, camera.position.z]
	]


## Position camera to view loaded terrain
func _position_camera_for_terrain() -> void:
	if _loaded_cells.is_empty():
		return

	# Calculate center of loaded cells
	var center := Vector2.ZERO
	for cell in _loaded_cells:
		center += Vector2(cell.x, cell.y)
	center /= _loaded_cells.size()

	# Convert to Godot world position
	var cell_size_godot := LandRecord.CELL_SIZE / MWCoords.UNITS_PER_METER
	var world_x := center.x * cell_size_godot + cell_size_godot * 0.5
	var world_z := -center.y * cell_size_godot - cell_size_godot * 0.5  # Negate Y

	# Get approximate terrain height at center
	var terrain_height := 0.0
	if terrain_3d and terrain_3d.data:
		terrain_height = terrain_3d.data.get_height(Vector3(world_x, 0, world_z))
		if is_nan(terrain_height) or terrain_height > 10000:
			terrain_height = 50.0  # Fallback height

	# Position camera above center, looking down at terrain
	var view_distance := cell_size_godot * (_loaded_cells.size() ** 0.5) * 0.8
	camera.position = Vector3(world_x, terrain_height + view_distance * 0.5, world_z + view_distance * 0.3)
	camera.look_at(Vector3(world_x, terrain_height, world_z))

	_log("Camera positioned at: (%.1f, %.1f, %.1f)" % [camera.position.x, camera.position.y, camera.position.z])


# ==================== Camera Controls ====================

func _input(event: InputEvent) -> void:
	# Toggle mouse capture with right click
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				mouse_captured = true
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				mouse_captured = false

	# Mouse look when captured
	if event is InputEventMouseMotion and mouse_captured:
		camera.rotate_y(-event.relative.x * mouse_sensitivity)
		camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * mouse_sensitivity)


func _process(delta: float) -> void:
	if not mouse_captured:
		return

	# WASD movement
	var input_dir := Vector3.ZERO

	if Input.is_key_pressed(KEY_W):
		input_dir.z -= 1
	if Input.is_key_pressed(KEY_S):
		input_dir.z += 1
	if Input.is_key_pressed(KEY_A):
		input_dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1
	if Input.is_key_pressed(KEY_SPACE):
		input_dir.y += 1
	if Input.is_key_pressed(KEY_SHIFT):
		input_dir.y -= 1

	# Speed boost with Ctrl
	var speed := camera_speed
	if Input.is_key_pressed(KEY_CTRL):
		speed *= 3.0

	# Move camera
	if input_dir != Vector3.ZERO:
		var move_dir := camera.global_transform.basis * input_dir.normalized()
		camera.position += move_dir * speed * delta

	# Update stats with camera position
	if stats_text and stats_text.text.find("Camera Position") >= 0:
		var lines := stats_text.text.split("\n")
		if lines.size() > 0:
			lines[-1] = "%.1f, %.1f, %.1f" % [camera.position.x, camera.position.y, camera.position.z]
			stats_text.text = "\n".join(lines)


func _log(message: String) -> void:
	if log_text:
		log_text.append_text(message + "\n")
	print(message.replace("[b]", "").replace("[/b]", "").replace("[color=green]", "").replace("[color=red]", "").replace("[color=yellow]", "").replace("[/color]", ""))
