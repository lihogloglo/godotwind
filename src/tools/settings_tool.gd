extends Control
## Settings Tool for configuring Morrowind data path

@onready var current_path_label: Label = %CurrentPathLabel
@onready var path_source_label: Label = %PathSourceLabel
@onready var data_path_edit: LineEdit = %DataPathEdit
@onready var esm_file_edit: LineEdit = %ESMFileEdit
@onready var browse_button: Button = %BrowseButton
@onready var auto_detect_button: Button = %AutoDetectButton
@onready var save_button: Button = %SaveButton
@onready var validate_label: Label = %ValidateLabel
@onready var file_dialog: FileDialog = %FileDialog
@onready var output_text: RichTextLabel = %OutputText

func _ready() -> void:
	# Connect signals
	browse_button.pressed.connect(_on_browse_pressed)
	auto_detect_button.pressed.connect(_on_auto_detect_pressed)
	save_button.pressed.connect(_on_save_pressed)
	data_path_edit.text_changed.connect(_on_path_changed)
	esm_file_edit.text_changed.connect(_on_path_changed)
	file_dialog.dir_selected.connect(_on_dir_selected)

	# Configure file dialog
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM

	# Load current settings
	_load_current_settings()

	_log("[b]Morrowind Settings Tool[/b]")
	_log("Configure your Morrowind installation path here.")
	_log("")
	_log("[b]Priority order:[/b]")
	_log("1. MORROWIND_DATA_PATH environment variable")
	_log("2. User config file (user://settings.cfg)")
	_log("3. Project settings (project.godot)")
	_log("")
	_log("Settings saved here will be stored in your user config.")
	_log("")

func _load_current_settings() -> void:
	# Get current path and source
	var current_path := SettingsManager.get_data_path()
	var source := SettingsManager.get_data_path_source()
	var esm_file := SettingsManager.get_esm_file()

	# Update labels
	if current_path.is_empty():
		current_path_label.text = "Not configured"
		current_path_label.add_theme_color_override("font_color", Color.RED)
		path_source_label.text = ""
	else:
		current_path_label.text = current_path
		current_path_label.add_theme_color_override("font_color", Color.GREEN)
		path_source_label.text = "Source: %s" % source

	# Set edit fields
	data_path_edit.text = current_path
	esm_file_edit.text = esm_file

	# Validate
	_validate_settings()

func _on_browse_pressed() -> void:
	# Set initial directory if current path is valid
	var current_path := data_path_edit.text.strip_edges()
	if not current_path.is_empty() and DirAccess.dir_exists_absolute(current_path):
		file_dialog.current_dir = current_path

	file_dialog.popup_centered_ratio(0.7)

func _on_dir_selected(dir: String) -> void:
	data_path_edit.text = dir
	_validate_settings()

func _on_auto_detect_pressed() -> void:
	_log("Auto-detecting Morrowind installation...")

	var detected_path := SettingsManager.auto_detect_installation()

	if detected_path.is_empty():
		_log("[color=red]Could not auto-detect Morrowind installation.[/color]")
		_log("[color=yellow]Please browse to your Morrowind Data Files folder manually.[/color]")

		# Show some hints
		_log("")
		_log("[b]Common paths to check:[/b]")
		var common_paths := SettingsManager.get_common_paths()
		for path in common_paths.slice(0, 10):  # Show first 10
			_log("  • %s" % path)
	else:
		_log("[color=green]Found Morrowind installation at:[/color]")
		_log("  %s" % detected_path)
		data_path_edit.text = detected_path
		_validate_settings()

func _on_path_changed(_new_text: String) -> void:
	_validate_settings()

func _validate_settings() -> bool:
	var data_path := data_path_edit.text.strip_edges()
	var esm_file := esm_file_edit.text.strip_edges()

	if data_path.is_empty():
		validate_label.text = "⚠ Data path is empty"
		validate_label.add_theme_color_override("font_color", Color.ORANGE)
		return false

	if not DirAccess.dir_exists_absolute(data_path):
		validate_label.text = "✗ Directory does not exist"
		validate_label.add_theme_color_override("font_color", Color.RED)
		return false

	if esm_file.is_empty():
		validate_label.text = "⚠ ESM file name is empty"
		validate_label.add_theme_color_override("font_color", Color.ORANGE)
		return false

	var esm_path := data_path.path_join(esm_file)
	if not FileAccess.file_exists(esm_path):
		validate_label.text = "✗ ESM file not found: %s" % esm_file
		validate_label.add_theme_color_override("font_color", Color.RED)
		return false

	# All good!
	validate_label.text = "✓ Configuration is valid"
	validate_label.add_theme_color_override("font_color", Color.GREEN)
	return true

func _on_save_pressed() -> void:
	if not _validate_settings():
		_log("[color=red]Cannot save: Configuration is invalid[/color]")
		return

	var data_path := data_path_edit.text.strip_edges()
	var esm_file := esm_file_edit.text.strip_edges()

	_log("Saving settings...")
	SettingsManager.set_data_path(data_path)
	SettingsManager.set_esm_file(esm_file)

	_log("[color=green]Settings saved successfully![/color]")
	_log("  Data path: %s" % data_path)
	_log("  ESM file: %s" % esm_file)
	_log("")
	_log("These settings are now stored in: user://settings.cfg")
	_log("(Location: %s)" % OS.get_user_data_dir())

	# Reload current settings to show updated source
	_load_current_settings()

func _log(text: String) -> void:
	output_text.append_text(text + "\n")
	print(text.replace("[b]", "").replace("[/b]", "").replace("[color=red]", "").replace("[color=green]", "").replace("[color=yellow]", "").replace("[color=orange]", "").replace("[/color]", ""))
