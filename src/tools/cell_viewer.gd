## Cell Viewer - Test tool for visualizing Morrowind cells
## Loads a cell and displays all objects with a free fly camera
extends Node3D

# Preload coordinate utilities
const MWCoords := preload("res://src/core/morrowind_coords.gd")

# UI references - Right panel
@onready var cell_name_edit: LineEdit = $UI/Panel/VBox/CellNameEdit
@onready var load_cell_button: Button = $UI/Panel/VBox/LoadCellButton
@onready var stats_text: RichTextLabel = $UI/Panel/VBox/StatsText
@onready var log_text: RichTextLabel = $UI/Panel/VBox/LogText
@onready var cell_container: Node3D = $CellContainer
@onready var camera: Camera3D = $FlyCamera

# Quick load buttons
@onready var census_btn: Button = $UI/Panel/VBox/QuickButtons/CensusBtn
@onready var lighthouse_btn: Button = $UI/Panel/VBox/QuickButtons/LightHouseBtn
@onready var tradehouse_btn: Button = $UI/Panel/VBox/QuickButtons/TradeHouseBtn
@onready var balmora_btn: Button = $UI/Panel/VBox/QuickButtons/BalmoreraBtn

# UI references - Left panel (cell browser)
@onready var search_edit: LineEdit = $UI/LeftPanel/VBox/SearchEdit
@onready var result_count_label: Label = $UI/LeftPanel/VBox/ResultCount
@onready var cell_list: ItemList = $UI/LeftPanel/VBox/CellList
@onready var interior_btn: Button = $UI/LeftPanel/VBox/FilterContainer/InteriorBtn
@onready var exterior_btn: Button = $UI/LeftPanel/VBox/FilterContainer/ExteriorBtn
@onready var all_btn: Button = $UI/LeftPanel/VBox/FilterContainer/AllBtn

# Loading overlay UI
@onready var loading_overlay: ColorRect = $UI/LoadingOverlay
@onready var loading_label: Label = $UI/LoadingOverlay/VBox/LoadingLabel
@onready var progress_bar: ProgressBar = $UI/LoadingOverlay/VBox/ProgressBar
@onready var status_label: Label = $UI/LoadingOverlay/VBox/StatusLabel

# Camera movement
var camera_speed: float = 500.0  # Units per second
var mouse_sensitivity: float = 0.003
var camera_velocity: Vector3 = Vector3.ZERO
var mouse_captured: bool = false

# Cell manager
var cell_manager: CellManager

# Cell browser
var _all_cells: Array[Dictionary] = []  # {name: String, is_interior: bool, record: CellRecord}
var _filtered_cells: Array[Dictionary] = []
var _current_filter: String = "interior"  # "interior", "exterior", "all"
var _search_timer: Timer = null
var _max_display_items: int = 500


func _ready() -> void:
	# Initialize cell manager
	cell_manager = CellManager.new()

	# Connect UI signals - Right panel
	load_cell_button.pressed.connect(_on_load_cell_pressed)

	# Connect quick load buttons
	census_btn.pressed.connect(func(): _load_cell("Seyda Neen, Census and Excise Office"))
	lighthouse_btn.pressed.connect(func(): _load_cell("Seyda Neen, Lighthouse"))
	tradehouse_btn.pressed.connect(func(): _load_cell("Seyda Neen, Arrille's Tradehouse"))
	balmora_btn.pressed.connect(func(): _load_cell("Balmora, South Wall Cornerclub"))

	# Connect UI signals - Left panel (cell browser)
	search_edit.text_changed.connect(_on_search_text_changed)
	cell_list.item_selected.connect(_on_cell_selected)
	cell_list.item_activated.connect(_on_cell_activated)

	# Filter buttons
	interior_btn.pressed.connect(func(): _set_filter("interior"))
	exterior_btn.pressed.connect(func(): _set_filter("exterior"))
	all_btn.pressed.connect(func(): _set_filter("all"))

	# Create search debounce timer
	_search_timer = Timer.new()
	_search_timer.one_shot = true
	_search_timer.wait_time = 0.2
	_search_timer.timeout.connect(_apply_filter)
	add_child(_search_timer)

	# Get Morrowind data path from project settings
	var data_path: String = ProjectSettings.get_setting("morrowind/data_path", "")
	if data_path.is_empty():
		_hide_loading()
		_log("[color=red]ERROR: Morrowind data path not configured in project.godot[/color]")
		return

	_log("Morrowind data path: " + data_path)

	# Load ESM and BSA files with progress updates
	# Use call_deferred to allow the UI to render first
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
		_log("[color=yellow]Warning: No BSA archives found. Models may not load.[/color]")

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
	_log("Cells: %d, Statics: %d" % [ESMManager.cells.size(), ESMManager.statics.size()])

	_update_loading(80, "Building cell list...")
	await get_tree().process_frame

	# Build cell list for browser
	_build_cell_list()

	_update_loading(95, "Finalizing...")
	await get_tree().process_frame

	# Apply initial filter
	_apply_filter()

	_update_loading(100, "Done!")
	await get_tree().process_frame

	# Hide loading overlay after a brief delay
	await get_tree().create_timer(0.3).timeout
	_hide_loading()


func _build_cell_list() -> void:
	_all_cells.clear()

	for cell_id in ESMManager.cells:
		var cell: CellRecord = ESMManager.cells[cell_id]
		var cell_info := {
			"name": cell.name if cell.is_interior() else "Exterior (%d, %d)" % [cell.grid_x, cell.grid_y],
			"is_interior": cell.is_interior(),
			"record": cell,
			"ref_count": cell.references.size(),
			"grid_x": cell.grid_x,
			"grid_y": cell.grid_y,
		}
		_all_cells.append(cell_info)

	# Sort: interiors by name, exteriors by grid
	_all_cells.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["is_interior"] != b["is_interior"]:
			return a["is_interior"]  # Interiors first
		if a["is_interior"]:
			return a["name"].naturalnocasecmp_to(b["name"]) < 0
		else:
			if a["grid_x"] != b["grid_x"]:
				return a["grid_x"] < b["grid_x"]
			return a["grid_y"] < b["grid_y"]
	)

	_log("Built cell list: %d interior, %d exterior" % [
		_all_cells.filter(func(c: Dictionary): return c["is_interior"]).size(),
		_all_cells.filter(func(c: Dictionary): return not c["is_interior"]).size()
	])


# ==================== Cell Browser ====================

func _on_search_text_changed(_new_text: String) -> void:
	_search_timer.start()


func _set_filter(filter: String) -> void:
	_current_filter = filter

	# Update button states
	interior_btn.button_pressed = filter == "interior"
	exterior_btn.button_pressed = filter == "exterior"
	all_btn.button_pressed = filter == "all"

	_apply_filter()


func _apply_filter() -> void:
	_filtered_cells.clear()

	var search_text := search_edit.text.strip_edges().to_lower()

	for cell_info: Dictionary in _all_cells:
		# Apply type filter
		if _current_filter == "interior" and not cell_info["is_interior"]:
			continue
		if _current_filter == "exterior" and cell_info["is_interior"]:
			continue

		# Apply search filter
		if not search_text.is_empty():
			var name_lower: String = cell_info["name"].to_lower()
			if name_lower.find(search_text) < 0:
				continue

		_filtered_cells.append(cell_info)

	_populate_cell_list()


func _populate_cell_list() -> void:
	cell_list.clear()

	var display_count := mini(_filtered_cells.size(), _max_display_items)
	for i in display_count:
		var cell_info: Dictionary = _filtered_cells[i]
		var display_name: String = cell_info["name"]
		if cell_info["ref_count"] > 0:
			display_name += " (%d)" % cell_info["ref_count"]

		cell_list.add_item(display_name)
		cell_list.set_item_metadata(i, cell_info)

		# Color code: interiors white, exteriors light blue
		if not cell_info["is_interior"]:
			cell_list.set_item_custom_fg_color(i, Color(0.7, 0.85, 1.0))

	# Update result count
	if _filtered_cells.size() > _max_display_items:
		result_count_label.text = "%d cells (showing first %d)" % [_filtered_cells.size(), _max_display_items]
	else:
		result_count_label.text = "%d cells" % _filtered_cells.size()


func _on_cell_selected(index: int) -> void:
	var cell_info: Dictionary = cell_list.get_item_metadata(index)
	cell_name_edit.text = cell_info["name"]


func _on_cell_activated(index: int) -> void:
	var cell_info: Dictionary = cell_list.get_item_metadata(index)
	cell_name_edit.text = cell_info["name"]
	_load_cell_from_info(cell_info)


# ==================== Cell Loading ====================

func _on_load_cell_pressed() -> void:
	var cell_name := cell_name_edit.text.strip_edges()
	if cell_name.is_empty():
		_log("[color=yellow]Please enter a cell name[/color]")
		return

	_load_cell(cell_name)


func _load_cell(cell_name: String) -> void:
	_log("\n[b]Loading cell: '%s'[/b]" % cell_name)

	# Clear existing cell
	for child in cell_container.get_children():
		child.queue_free()

	# Check if this is an exterior cell (format: "Exterior (X, Y)")
	var cell_node: Node3D = null
	var cell_record: CellRecord = null
	var start_time := Time.get_ticks_msec()

	var exterior_regex := RegEx.new()
	exterior_regex.compile("^Exterior\\s*\\(\\s*(-?\\d+)\\s*,\\s*(-?\\d+)\\s*\\)$")
	var match_result := exterior_regex.search(cell_name)

	if match_result:
		# Exterior cell - parse coordinates
		var grid_x := int(match_result.get_string(1))
		var grid_y := int(match_result.get_string(2))
		_log("Loading exterior cell at grid (%d, %d)" % [grid_x, grid_y])
		cell_node = cell_manager.load_exterior_cell(grid_x, grid_y)
		cell_record = ESMManager.get_exterior_cell(grid_x, grid_y)
	else:
		# Interior cell - load by name
		cell_node = cell_manager.load_cell(cell_name)
		cell_record = ESMManager.get_cell(cell_name)

	if not cell_node:
		_log("[color=red]Failed to load cell[/color]")
		return

	var elapsed := Time.get_ticks_msec() - start_time
	cell_container.add_child(cell_node)

	# Update stats
	_update_stats(cell_record, elapsed)

	_log("[color=green]Cell loaded in %d ms[/color]" % elapsed)
	_log("Objects: %d" % cell_node.get_child_count())

	# Position camera at center of cell
	_position_camera_for_cell(cell_record)


func _load_cell_from_info(cell_info: Dictionary) -> void:
	var cell_record: CellRecord = cell_info["record"]

	_log("\n[b]Loading cell: '%s'[/b]" % cell_info["name"])

	# Clear existing cell
	for child in cell_container.get_children():
		child.queue_free()

	# Load the cell
	var start_time := Time.get_ticks_msec()
	var cell_node: Node3D

	if cell_info["is_interior"]:
		cell_node = cell_manager.load_cell(cell_record.name)
	else:
		cell_node = cell_manager.load_exterior_cell(cell_info["grid_x"], cell_info["grid_y"])

	if not cell_node:
		_log("[color=red]Failed to load cell[/color]")
		return

	var elapsed := Time.get_ticks_msec() - start_time
	cell_container.add_child(cell_node)

	# Update stats
	_update_stats(cell_record, elapsed)

	_log("[color=green]Cell loaded in %d ms[/color]" % elapsed)
	_log("Objects: %d" % cell_node.get_child_count())

	# Position camera
	_position_camera_for_cell(cell_record)


func _update_stats(cell_record: CellRecord, elapsed: int) -> void:
	var stats := cell_manager.get_stats()
	stats_text.text = """[b]Cell Stats:[/b]
Name: %s
References in ESM: %d
Objects loaded: %d
Objects failed: %d
Models loaded: %d
Models from cache: %d
Load time: %d ms""" % [
		cell_record.get_description() if cell_record else "Unknown",
		cell_record.references.size() if cell_record else 0,
		stats["objects_instantiated"],
		stats["objects_failed"],
		stats["models_loaded"],
		stats["models_from_cache"],
		elapsed
	]


func _position_camera_for_cell(cell: CellRecord) -> void:
	if not cell:
		return

	# Calculate center of all objects
	var center := Vector3.ZERO
	var count := 0

	for ref in cell.references:
		# Convert to Godot coordinates using the unified system
		var pos := MWCoords.position_to_godot(ref.position)
		center += pos
		count += 1

	if count > 0:
		center /= count

	# Position camera above center, looking down slightly
	camera.position = center + Vector3(0, 300, 500)
	camera.look_at(center)

	_log("Camera positioned at: %s" % camera.position)


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


func _log(message: String) -> void:
	if log_text:
		log_text.append_text(message + "\n")
	print(message.replace("[b]", "").replace("[/b]", "").replace("[color=green]", "").replace("[color=red]", "").replace("[color=yellow]", "").replace("[/color]", ""))
