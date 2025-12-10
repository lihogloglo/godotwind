## Cell Viewer - Test tool for visualizing Morrowind cells
## Loads a cell and displays all objects with a free fly camera
extends Node3D

# UI references
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

# Camera movement
var camera_speed: float = 500.0  # Units per second
var mouse_sensitivity: float = 0.003
var camera_velocity: Vector3 = Vector3.ZERO
var mouse_captured: bool = false

# Cell manager
var cell_manager: CellManager


func _ready() -> void:
	# Initialize cell manager
	cell_manager = CellManager.new()

	# Connect UI signals
	load_cell_button.pressed.connect(_on_load_cell_pressed)

	# Connect quick load buttons
	census_btn.pressed.connect(func(): _load_cell("Seyda Neen, Census and Excise Office"))
	lighthouse_btn.pressed.connect(func(): _load_cell("Seyda Neen, Lighthouse"))
	tradehouse_btn.pressed.connect(func(): _load_cell("Seyda Neen, Arrille's Tradehouse"))
	balmora_btn.pressed.connect(func(): _load_cell("Balmora, South Wall Cornerclub"))

	# Get Morrowind data path from project settings
	var data_path: String = ProjectSettings.get_setting("morrowind/data_path", "")
	if data_path.is_empty():
		_log("[color=red]ERROR: Morrowind data path not configured in project.godot[/color]")
		return

	_log("Morrowind data path: " + data_path)

	# Load ESM and BSA files
	_load_game_data(data_path)


func _load_game_data(data_path: String) -> void:
	_log("Loading BSA archives...")

	# Load BSA files
	var bsa_count := BSAManager.load_archives_from_directory(data_path)
	_log("Loaded %d BSA archives" % bsa_count)

	if bsa_count == 0:
		_log("[color=yellow]Warning: No BSA archives found. Models may not load.[/color]")

	# Load ESM file
	var esm_file: String = ProjectSettings.get_setting("morrowind/esm_file", "Morrowind.esm")
	var esm_path := data_path.path_join(esm_file)

	_log("Loading ESM: " + esm_path)
	var error := ESMManager.load_file(esm_path)

	if error != OK:
		_log("[color=red]ERROR: Failed to load ESM file: %s[/color]" % error_string(error))
		return

	_log("[color=green]ESM loaded successfully![/color]")
	_log("Cells: %d, Statics: %d" % [ESMManager.cells.size(), ESMManager.statics.size()])

	# Show some available cells
	_show_sample_cells()


func _show_sample_cells() -> void:
	_log("\n[b]Sample interior cells:[/b]")
	var count := 0
	for cell_id in ESMManager.cells:
		var cell: CellRecord = ESMManager.cells[cell_id]
		if cell.is_interior() and cell.references.size() > 0:
			_log("  - %s (%d refs)" % [cell.name, cell.references.size()])
			count += 1
			if count >= 10:
				_log("  ... and %d more" % (ESMManager.cells.size() - count))
				break


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

	# Load the new cell
	var start_time := Time.get_ticks_msec()
	var cell_node := cell_manager.load_cell(cell_name)

	if not cell_node:
		_log("[color=red]Failed to load cell[/color]")
		return

	var elapsed := Time.get_ticks_msec() - start_time
	cell_container.add_child(cell_node)

	# Get the cell record for stats
	var cell_record: CellRecord = ESMManager.get_cell(cell_name)

	# Update stats
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

	_log("[color=green]Cell loaded in %d ms[/color]" % elapsed)
	_log("Objects: %d" % cell_node.get_child_count())

	# Position camera at center of cell
	_position_camera_for_cell(cell_record)


func _position_camera_for_cell(cell: CellRecord) -> void:
	if not cell:
		return

	# Calculate center of all objects
	var center := Vector3.ZERO
	var count := 0

	for ref in cell.references:
		# Convert to Godot coordinates
		var pos := Vector3(ref.position.x, ref.position.z, -ref.position.y)
		center += pos
		count += 1

	if count > 0:
		center /= count

	# Position camera above center, looking down slightly
	camera.position = center + Vector3(0, 300, 500)
	camera.look_at(center)

	_log("Camera positioned at: %s" % camera.position)


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
