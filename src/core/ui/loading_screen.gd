## LoadingScreen — Reusable loading overlay for any scene
##
## Creates its own UI (no .tscn dependency). Shows progress bar + status text
## while loading BSA/ESM data. Also provides a shared `load_game_data()` coroutine
## so test scenes don't each reimplement the loading sequence.
##
## Usage:
##   var loading := LoadingScreen.new()
##   add_child(loading)
##   await loading.load_game_data()
##   loading.queue_free()
##
## Or manual control:
##   loading.show_loading("Loading NIF...")
##   loading.update_progress(50.0, "Parsing meshes...")
##   loading.hide_loading()
class_name LoadingScreen
extends CanvasLayer

var _overlay: ColorRect
var _title_label: Label
var _status_label: Label
var _progress_bar: ProgressBar


func _ready() -> void:
	layer = 100  # Always on top
	_build_ui()


## Show loading overlay with a title
func show_loading(title: String = "Loading...", status: String = "") -> void:
	_overlay.visible = true
	_title_label.text = title
	_status_label.text = status
	_progress_bar.value = 0


## Update progress (0-100) and status text
func update_progress(progress: float, status: String = "") -> void:
	_progress_bar.value = progress
	if not status.is_empty():
		_status_label.text = status


## Hide loading overlay
func hide_loading() -> void:
	_overlay.visible = false


## Shared game data loading coroutine — loads BSA + ESM with progress feedback.
## Skips steps that are already done (safe to call multiple times).
## Returns true on success, false on failure.
func load_game_data() -> bool:
	show_loading("Loading Game Data", "Initializing...")
	await get_tree().process_frame

	# Step 1: Get data path
	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		data_path = SettingsManager.auto_detect_installation()
	if data_path.is_empty():
		_status_label.text = "ERROR: No Morrowind data path configured"
		Log.error("loading", "No Morrowind data path configured")
		return false

	# Step 2: Load BSA archives (skip if already loaded)
	if not BSAManager.has_file("meshes\\xbase_anim.nif"):
		update_progress(10.0, "Loading BSA archives...")
		await get_tree().process_frame
		var bsa_count := BSAManager.load_archives_from_directory(data_path)
		Log.info("loading", "Loaded %d BSA archives" % bsa_count)
	else:
		update_progress(10.0, "BSA archives already loaded")
	await get_tree().process_frame

	# Step 3: Load ESM (skip if already loaded)
	if ESMManager.cells.is_empty():
		update_progress(30.0, "Loading ESM data...")
		await get_tree().process_frame
		var esm_file: String = SettingsManager.get_esm_file()
		var esm_path := data_path.path_join(esm_file)
		var error := ESMManager.load_file(esm_path)
		if error != OK:
			_status_label.text = "ERROR: Failed to load ESM"
			Log.error("loading", "Failed to load ESM: %s" % error_string(error))
			return false
		Log.info("loading", "ESM loaded: %d cells" % ESMManager.cells.size())
	else:
		update_progress(30.0, "ESM already loaded")
	await get_tree().process_frame

	update_progress(100.0, "Ready")
	await get_tree().process_frame

	hide_loading()
	return true


func _build_ui() -> void:
	# Full-screen dark overlay
	_overlay = ColorRect.new()
	_overlay.name = "LoadingOverlay"
	_overlay.color = Color(0.05, 0.05, 0.08, 0.95)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay)

	# Center container
	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_CENTER)
	vbox.offset_left = -200
	vbox.offset_right = 200
	vbox.offset_top = -60
	vbox.offset_bottom = 60
	vbox.add_theme_constant_override("separation", 12)
	_overlay.add_child(vbox)

	# Title
	_title_label = Label.new()
	_title_label.text = "Loading..."
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 24)
	_title_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
	vbox.add_child(_title_label)

	# Progress bar
	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0
	_progress_bar.max_value = 100
	_progress_bar.value = 0
	_progress_bar.custom_minimum_size = Vector2(400, 24)
	_progress_bar.show_percentage = false
	vbox.add_child(_progress_bar)

	# Status text
	_status_label = Label.new()
	_status_label.text = ""
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	vbox.add_child(_status_label)

	_overlay.visible = false
