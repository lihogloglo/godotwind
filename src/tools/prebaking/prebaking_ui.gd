## PrebakingUI - User interface for the prebaking tool
##
## Provides a panel UI to:
## - Enable/disable individual prebaking components
## - Start/stop/resume prebaking
## - View progress for each component
## - See detailed statistics
@tool
extends Control

const PrebakingManagerScript := preload("res://src/tools/prebaking/prebaking_manager.gd")
const CS := preload("res://src/core/coordinate_system.gd")

## References - use the preloaded script type for proper typing
@onready var manager: PrebakingManagerScript = $PrebakingManager

## UI Elements - will be created in _ready
var _main_container: VBoxContainer
var _header_label: Label
var _status_label: Label

# Component sections
var _terrain_section: Dictionary = {}
var _model_section: Dictionary = {}
var _impostor_section: Dictionary = {}
var _mesh_section: Dictionary = {}
var _navmesh_section: Dictionary = {}
var _shore_section: Dictionary = {}
var _cloud_section: Dictionary = {}

# Buttons
var _start_button: Button
var _stop_button: Button
var _reset_button: Button

# Overall progress
var _overall_progress: ProgressBar
var _overall_label: Label

# Log
var _log_text: RichTextLabel


func _ready() -> void:
	# Ensure manager reference is set
	if not manager:
		manager = get_node_or_null("PrebakingManager")
	if not manager:
		push_error("PrebakingUI: PrebakingManager child node not found!")
		return

	_build_ui()
	_connect_signals()
	_update_ui_state()

	# Find and assign Terrain3D to manager (required for shore mask baking)
	# Done after UI is built so we can show status, and deferred to allow terrain init
	call_deferred("_find_and_assign_terrain")



## Our own Terrain3D instance (created if not found in scene)
var _own_terrain: Terrain3D = null


## Find Terrain3D in the scene tree and assign it to the manager
## If not found, creates one and loads preprocessed terrain data
func _find_and_assign_terrain() -> void:
	print("PrebakingUI: _find_and_assign_terrain() called")

	# First check if already assigned
	if manager.terrain_3d:
		print("PrebakingUI: Terrain3D already assigned: %s" % manager.terrain_3d.get_path())
		return

	print("PrebakingUI: Searching for Terrain3D in scene tree...")

	# Try to find Terrain3D in the scene tree
	var tree := get_tree()
	if tree:
		var terrain := _find_terrain_recursive(tree.root)
		if terrain:
			manager.terrain_3d = terrain
			print("PrebakingUI: Found existing Terrain3D: %s" % terrain.get_path())
			return

	# No Terrain3D found - create our own and load preprocessed data
	print("PrebakingUI: No Terrain3D in scene, creating one with preprocessed data...")
	await _create_terrain_with_preprocessed_data()


## Create our own Terrain3D and load preprocessed terrain data
func _create_terrain_with_preprocessed_data() -> void:
	# Check if Terrain3D addon is available
	if not ClassDB.class_exists("Terrain3D"):
		push_error("PrebakingUI: Terrain3D addon not loaded!")
		_log("ERROR: Terrain3D addon not loaded!", Color.RED)
		return

	# Check if preprocessed terrain data exists in cache folder
	var terrain_data_dir := SettingsManager.get_terrain_path()
	print("PrebakingUI: Looking for terrain data at: %s" % terrain_data_dir)

	if not DirAccess.dir_exists_absolute(terrain_data_dir):
		push_warning("PrebakingUI: No preprocessed terrain data found at %s" % terrain_data_dir)
		_log("No preprocessed terrain at %s" % terrain_data_dir, Color.YELLOW)
		_log("Shore mask will use default world bounds", Color.YELLOW)
		# Still create terrain so baker has something to work with
		_create_empty_terrain()
		return

	# Create Terrain3D node
	_own_terrain = Terrain3D.new()
	_own_terrain.name = "PrebakingTerrain3D"
	add_child(_own_terrain)
	print("PrebakingUI: Created Terrain3D node")

	# Use shared configuration from CoordinateSystem (single source of truth)
	CS.configure_terrain3d(_own_terrain)

	print("PrebakingUI: Terrain3D configured, waiting for data initialization...")

	# Wait a frame for Terrain3D to initialize its data
	# Guard against null tree (can happen if node isn't fully in scene yet)
	var tree := get_tree()
	if tree:
		await tree.process_frame
	else:
		# Fallback: wait for tree to be available
		await ready
		tree = get_tree()
		if tree:
			await tree.process_frame

	# Load preprocessed terrain data from cache folder
	if _own_terrain.data:
		print("PrebakingUI: Loading terrain data from: %s" % terrain_data_dir)
		_own_terrain.data.load_directory(terrain_data_dir)
		var region_count := _own_terrain.data.get_region_count()
		print("PrebakingUI: Loaded %d terrain regions" % region_count)

		manager.terrain_3d = _own_terrain
		_log("Loaded %d terrain regions for shore mask" % region_count, Color.GREEN)
		print("PrebakingUI: Terrain3D ready for shore mask baking")
	else:
		push_error("PrebakingUI: Terrain3D.data not initialized after frame wait")
		_log("ERROR: Terrain3D.data not initialized", Color.RED)
		# Assign anyway so baker can use default bounds
		manager.terrain_3d = _own_terrain


## Create an empty terrain (no data) for when preprocessed data doesn't exist
func _create_empty_terrain() -> void:
	_own_terrain = Terrain3D.new()
	_own_terrain.name = "PrebakingTerrain3D"
	add_child(_own_terrain)

	# Use shared configuration from CoordinateSystem (single source of truth)
	CS.configure_terrain3d(_own_terrain)

	manager.terrain_3d = _own_terrain
	print("PrebakingUI: Created empty Terrain3D (no data)")


## Recursively search for a Terrain3D node
func _find_terrain_recursive(node: Node) -> Terrain3D:
	if not node:
		return null
	if node is Terrain3D:
		return node
	for child in node.get_children():
		var found := _find_terrain_recursive(child)
		if found:
			return found
	return null


func _build_ui() -> void:
	# Set minimum size for the window
	custom_minimum_size = Vector2(600, 700)

	# Main panel styling
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	# Add scroll container for when window is small
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	scroll.add_child(margin)

	_main_container = VBoxContainer.new()
	_main_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_container.add_theme_constant_override("separation", 12)
	margin.add_child(_main_container)

	# Header
	_header_label = Label.new()
	_header_label.text = "Asset Prebaking Tool"
	_header_label.add_theme_font_size_override("font_size", 24)
	_main_container.add_child(_header_label)

	# Status
	var status_hbox := HBoxContainer.new()
	_main_container.add_child(status_hbox)

	var status_title := Label.new()
	status_title.text = "Status: "
	status_hbox.add_child(status_title)

	_status_label = Label.new()
	_status_label.text = "Idle"
	_status_label.add_theme_color_override("font_color", Color.GRAY)
	status_hbox.add_child(_status_label)

	# Separator
	_main_container.add_child(HSeparator.new())

	# Component sections
	_terrain_section = _create_component_section("Terrain", "Preprocess Morrowind heightmaps to Terrain3D format - Required for world exploration!")
	_model_section = _create_component_section("Models", "Pre-convert NIF models to Godot resources (NEAR tier) - Most impactful for load times!")
	_impostor_section = _create_component_section("Impostors", "Octahedral impostor textures for distant landmarks (FAR tier)")
	_mesh_section = _create_component_section("Merged Meshes", "Simplified cell meshes for mid-distance rendering (MID tier)")
	_navmesh_section = _create_component_section("Navigation Meshes", "Pathfinding meshes for AI navigation")
	_shore_section = _create_component_section("Shore Mask", "Ocean visibility mask based on terrain height")
	_cloud_section = _create_component_section("Cloud Noise", "3D noise textures for volumetric raymarched clouds")

	# Separator
	_main_container.add_child(HSeparator.new())

	# Overall progress
	var progress_section := VBoxContainer.new()
	_main_container.add_child(progress_section)

	_overall_label = Label.new()
	_overall_label.text = "Overall Progress"
	progress_section.add_child(_overall_label)

	_overall_progress = ProgressBar.new()
	_overall_progress.custom_minimum_size.y = 24
	_overall_progress.value = 0
	progress_section.add_child(_overall_progress)

	# Buttons
	var button_hbox := HBoxContainer.new()
	button_hbox.add_theme_constant_override("separation", 8)
	_main_container.add_child(button_hbox)

	_start_button = Button.new()
	_start_button.text = "Bake Selected"
	_start_button.custom_minimum_size.x = 150
	_start_button.pressed.connect(_on_start_pressed)
	button_hbox.add_child(_start_button)

	_stop_button = Button.new()
	_stop_button.text = "Stop"
	_stop_button.custom_minimum_size.x = 80
	_stop_button.disabled = true
	_stop_button.pressed.connect(_on_stop_pressed)
	button_hbox.add_child(_stop_button)

	_reset_button = Button.new()
	_reset_button.text = "Reset All"
	_reset_button.custom_minimum_size.x = 80
	_reset_button.pressed.connect(_on_reset_pressed)
	button_hbox.add_child(_reset_button)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button_hbox.add_child(spacer)

	# Separator
	_main_container.add_child(HSeparator.new())

	# Log area
	var log_label := Label.new()
	log_label.text = "Log"
	_main_container.add_child(log_label)

	_log_text = RichTextLabel.new()
	_log_text.custom_minimum_size.y = 150
	_log_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_text.scroll_following = true
	_log_text.bbcode_enabled = true
	_main_container.add_child(_log_text)


func _create_component_section(title: String, description: String) -> Dictionary:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 4)
	_main_container.add_child(section)

	# Header row with checkbox
	var header_hbox := HBoxContainer.new()
	section.add_child(header_hbox)

	var checkbox := CheckBox.new()
	checkbox.text = title
	checkbox.button_pressed = true
	checkbox.add_theme_font_size_override("font_size", 16)
	header_hbox.add_child(checkbox)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_hbox.add_child(spacer)

	var bake_button := Button.new()
	bake_button.text = "Bake Only"
	bake_button.custom_minimum_size.x = 80
	header_hbox.add_child(bake_button)

	# Description
	var desc_label := Label.new()
	desc_label.text = description
	desc_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	desc_label.add_theme_font_size_override("font_size", 12)
	section.add_child(desc_label)

	# Progress bar
	var progress := ProgressBar.new()
	progress.custom_minimum_size.y = 16
	progress.value = 0
	section.add_child(progress)

	# Stats label
	var stats_label := Label.new()
	stats_label.text = "0 completed, 0 pending, 0 failed"
	stats_label.add_theme_font_size_override("font_size", 11)
	section.add_child(stats_label)

	return {
		"container": section,
		"checkbox": checkbox,
		"bake_button": bake_button,
		"progress": progress,
		"stats_label": stats_label,
	}


func _connect_signals() -> void:
	if not manager:
		return

	manager.status_changed.connect(_on_status_changed)
	manager.component_started.connect(_on_component_started)
	manager.component_progress.connect(_on_component_progress)
	manager.component_completed.connect(_on_component_completed)
	manager.item_baked.connect(_on_item_baked)
	manager.all_completed.connect(_on_all_completed)
	manager.error_occurred.connect(_on_error_occurred)

	# Component checkboxes
	(_terrain_section.checkbox as CheckBox).toggled.connect(func(pressed: bool) -> void:
		manager.enable_terrain = pressed
	)
	(_model_section.checkbox as CheckBox).toggled.connect(func(pressed: bool) -> void:
		manager.enable_models = pressed
	)
	(_impostor_section.checkbox as CheckBox).toggled.connect(func(pressed: bool) -> void:
		manager.enable_impostors = pressed
	)
	(_mesh_section.checkbox as CheckBox).toggled.connect(func(pressed: bool) -> void:
		manager.enable_merged_meshes = pressed
	)
	(_navmesh_section.checkbox as CheckBox).toggled.connect(func(pressed: bool) -> void:
		manager.enable_navmeshes = pressed
	)
	(_shore_section.checkbox as CheckBox).toggled.connect(func(pressed: bool) -> void:
		manager.enable_shore_mask = pressed
	)
	(_cloud_section.checkbox as CheckBox).toggled.connect(func(pressed: bool) -> void:
		manager.enable_cloud_noise = pressed
	)

	# Bake only buttons
	(_terrain_section.bake_button as Button).pressed.connect(func() -> void:
		manager.bake_component(PrebakingManagerScript.Component.TERRAIN)
	)
	(_model_section.bake_button as Button).pressed.connect(func() -> void:
		manager.bake_component(PrebakingManagerScript.Component.MODELS)
	)
	(_impostor_section.bake_button as Button).pressed.connect(func() -> void:
		manager.bake_component(PrebakingManagerScript.Component.IMPOSTORS)
	)
	(_mesh_section.bake_button as Button).pressed.connect(func() -> void:
		manager.bake_component(PrebakingManagerScript.Component.MERGED_MESHES)
	)
	(_navmesh_section.bake_button as Button).pressed.connect(func() -> void:
		manager.bake_component(PrebakingManagerScript.Component.NAVMESHES)
	)
	(_shore_section.bake_button as Button).pressed.connect(func() -> void:
		manager.bake_component(PrebakingManagerScript.Component.SHORE_MASK)
	)
	(_cloud_section.bake_button as Button).pressed.connect(func() -> void:
		manager.bake_component(PrebakingManagerScript.Component.CLOUD_NOISE)
	)


func _update_ui_state() -> void:
	if not manager:
		return

	var summary: Dictionary = manager.get_state_summary()
	var is_running: bool = manager.status == PrebakingManagerScript.Status.RUNNING

	# Update buttons
	_start_button.disabled = is_running
	_stop_button.disabled = not is_running
	_reset_button.disabled = is_running

	# Update start button text based on pending work
	if manager.has_pending_work():
		_start_button.text = "Resume Selected"
	else:
		_start_button.text = "Bake Selected"

	# Update component sections
	_update_component_section(_terrain_section, summary.get("terrain", {}) as Dictionary, is_running)
	_update_component_section(_model_section, summary.get("models", {}) as Dictionary, is_running)
	_update_component_section(_impostor_section, summary.get("impostors", {}) as Dictionary, is_running)
	_update_component_section(_mesh_section, summary.get("merged_meshes", {}) as Dictionary, is_running)
	_update_component_section(_navmesh_section, summary.get("navmeshes", {}) as Dictionary, is_running)
	_update_component_section(_shore_section, summary.get("shore_mask", {}) as Dictionary, is_running)
	_update_component_section(_cloud_section, summary.get("cloud_noise", {}) as Dictionary, is_running)

	# Update overall progress
	_overall_progress.value = summary.get("overall_progress", 0.0) * 100.0


func _update_component_section(section: Dictionary, data: Dictionary, is_running: bool) -> void:
	if data.is_empty():
		return

	var completed_arr: Array = data.get("completed", []) as Array
	var pending_arr: Array = data.get("pending", []) as Array
	var failed_arr: Array = data.get("failed", []) as Array
	var completed: int = completed_arr.size()
	var pending: int = pending_arr.size()
	var failed: int = failed_arr.size()
	var total := completed + pending + failed

	section.checkbox.disabled = is_running
	section.bake_button.disabled = is_running

	if total > 0:
		section.progress.value = float(completed) / float(total) * 100.0
	else:
		section.progress.value = 0

	section.stats_label.text = "%d completed, %d pending, %d failed" % [completed, pending, failed]


func _log(text: String, color: Color = Color.WHITE) -> void:
	var time_str := Time.get_time_string_from_system()
	var color_hex := color.to_html(false)
	_log_text.append_text("[color=#888888][%s][/color] [color=#%s]%s[/color]\n" % [time_str, color_hex, text])


# Signal handlers
func _on_start_pressed() -> void:
	_log("Starting prebaking...", Color.GREEN)
	manager.start_prebaking()


func _on_stop_pressed() -> void:
	_log("Stopping prebaking (will finish current item)...", Color.YELLOW)
	manager.stop_prebaking()


func _on_reset_pressed() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.dialog_text = "This will clear all progress and start fresh. Are you sure?"
	dialog.confirmed.connect(func() -> void:
		manager.reset_all()
		_log("Reset all progress", Color.ORANGE)
		_update_ui_state()
		dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void:
		dialog.queue_free()
	)
	add_child(dialog)
	dialog.popup_centered()


func _on_status_changed(new_status: int) -> void:
	match new_status:
		PrebakingManagerScript.Status.IDLE:
			_status_label.text = "Idle"
			_status_label.add_theme_color_override("font_color", Color.GRAY)
		PrebakingManagerScript.Status.RUNNING:
			_status_label.text = "Running"
			_status_label.add_theme_color_override("font_color", Color.GREEN)
		PrebakingManagerScript.Status.PAUSED:
			_status_label.text = "Paused"
			_status_label.add_theme_color_override("font_color", Color.YELLOW)
		PrebakingManagerScript.Status.COMPLETED:
			_status_label.text = "Completed"
			_status_label.add_theme_color_override("font_color", Color.CYAN)
		PrebakingManagerScript.Status.ERROR:
			_status_label.text = "Error"
			_status_label.add_theme_color_override("font_color", Color.RED)

	_update_ui_state()


func _on_component_started(component: String) -> void:
	_log("Started: %s" % component, Color.CYAN)


func _on_component_progress(component: String, current: int, total: int, item_name: String) -> void:
	# Update the specific component's progress bar
	var section: Dictionary
	match component:
		"Terrain": section = _terrain_section
		"Models": section = _model_section
		"Impostors": section = _impostor_section
		"Merged Meshes": section = _mesh_section
		"Navmeshes": section = _navmesh_section
		"Shore Mask": section = _shore_section
		"Cloud Noise": section = _cloud_section

	if not section.is_empty():
		section.progress.value = float(current) / float(total) * 100.0
		section.stats_label.text = "[%d/%d] %s" % [current, total, item_name]

	# Update overall progress
	_update_ui_state()


func _on_component_completed(component: String, success: int, failed: int, skipped: int) -> void:
	var msg := "%s: %d succeeded" % [component, success]
	if failed > 0:
		msg += ", %d failed" % failed
	if skipped > 0:
		msg += ", %d skipped" % skipped

	var color := Color.GREEN if failed == 0 else Color.YELLOW
	_log(msg, color)

	_update_ui_state()


func _on_item_baked(component: String, item_name: String, success: bool) -> void:
	if not success:
		_log("  FAILED: %s" % item_name, Color.RED)


func _on_all_completed(results: Dictionary) -> void:
	_log("All prebaking completed!", Color.GREEN)
	_update_ui_state()


func _on_error_occurred(component: String, error: String) -> void:
	_log("ERROR in %s: %s" % [component, error], Color.RED)
