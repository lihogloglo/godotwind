extends Control
## Settings Tool for configuring Morrowind data path, cache location, and texture packs

const StreamingConfig := preload("res://src/core/world/streaming_config.gd")

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

# Cache path UI elements
@onready var cache_path_edit: LineEdit = %CachePathEdit
@onready var cache_browse_button: Button = %CacheBrowseButton
@onready var cache_reset_button: Button = %CacheResetButton
@onready var current_cache_label: Label = %CurrentCacheLabel
@onready var cache_file_dialog: FileDialog = %CacheFileDialog

# Texture packs UI elements
@onready var texture_packs_list: ItemList = %TexturePacksList
@onready var add_texture_pack_button: Button = %AddTexturePackButton
@onready var remove_texture_pack_button: Button = %RemoveTexturePackButton
@onready var move_up_button: Button = %MoveUpButton
@onready var move_down_button: Button = %MoveDownButton
@onready var clear_texture_cache_button: Button = %ClearTextureCacheButton
@onready var texture_pack_file_dialog: FileDialog = %TexturePackFileDialog

# Graphics settings UI elements
@onready var quality_preset_option: OptionButton = %QualityPresetOption
@onready var distant_rendering_check: CheckBox = %DistantRenderingCheck
@onready var anti_aliasing_option: OptionButton = %AntiAliasingOption
@onready var shadow_quality_option: OptionButton = %ShadowQualityOption
@onready var view_distance_slider: HSlider = %ViewDistanceSlider
@onready var view_distance_value: Label = %ViewDistanceValue
@onready var vsync_check: CheckBox = %VSyncCheck
@onready var ssao_check: CheckBox = %SSAOCheck
@onready var ssr_check: CheckBox = %SSRCheck
@onready var glow_check: CheckBox = %GlowCheck
@onready var volumetric_fog_check: CheckBox = %VolumetricFogCheck
@onready var max_fps_option: OptionButton = %MaxFPSOption

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

	# Connect cache path signals
	cache_browse_button.pressed.connect(_on_cache_browse_pressed)
	cache_reset_button.pressed.connect(_on_cache_reset_pressed)
	cache_file_dialog.dir_selected.connect(_on_cache_dir_selected)

	# Configure cache file dialog
	cache_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	cache_file_dialog.access = FileDialog.ACCESS_FILESYSTEM

	# Connect texture pack signals
	add_texture_pack_button.pressed.connect(_on_add_texture_pack_pressed)
	remove_texture_pack_button.pressed.connect(_on_remove_texture_pack_pressed)
	move_up_button.pressed.connect(_on_move_up_pressed)
	move_down_button.pressed.connect(_on_move_down_pressed)
	clear_texture_cache_button.pressed.connect(_on_clear_texture_cache_pressed)
	texture_pack_file_dialog.dir_selected.connect(_on_texture_pack_dir_selected)
	texture_packs_list.item_selected.connect(_on_texture_pack_selected)

	# Configure texture pack file dialog
	texture_pack_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	texture_pack_file_dialog.access = FileDialog.ACCESS_FILESYSTEM

	# Connect graphics settings signals
	view_distance_slider.min_value = StreamingConfig.MIN_LOAD_RADIUS_CELLS
	view_distance_slider.max_value = StreamingConfig.MAX_LOAD_RADIUS_CELLS
	view_distance_slider.step = 1.0
	quality_preset_option.item_selected.connect(_on_quality_preset_changed)
	distant_rendering_check.toggled.connect(_on_distant_rendering_toggled)
	anti_aliasing_option.item_selected.connect(_on_anti_aliasing_changed)
	shadow_quality_option.item_selected.connect(_on_shadow_quality_changed)
	view_distance_slider.value_changed.connect(_on_view_distance_changed)
	vsync_check.toggled.connect(_on_vsync_toggled)
	ssao_check.toggled.connect(_on_ssao_toggled)
	ssr_check.toggled.connect(_on_ssr_toggled)
	glow_check.toggled.connect(_on_glow_toggled)
	volumetric_fog_check.toggled.connect(_on_volumetric_fog_toggled)
	max_fps_option.item_selected.connect(_on_max_fps_changed)

	# Load current settings
	_load_current_settings()

	_log("[b]Godotwind Settings Tool[/b]")
	_log("Configure your Morrowind installation and cache paths here.")
	_log("")
	_log("[b]Priority order:[/b]")
	_log("1. Environment variables (MORROWIND_DATA_PATH, GODOTWIND_CACHE_PATH)")
	_log("2. User config file (user://settings.cfg)")
	_log("3. Project settings / defaults")
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

	# Load cache path settings
	var cache_path := SettingsManager.get_cache_base_path()
	var default_cache := SettingsManager.get_default_cache_path()
	cache_path_edit.text = cache_path

	# Show cache path with indicator if it's custom or default
	if cache_path == default_cache:
		current_cache_label.text = cache_path + " (default)"
		current_cache_label.add_theme_color_override("font_color", Color.GRAY)
	else:
		current_cache_label.text = cache_path + " (custom)"
		current_cache_label.add_theme_color_override("font_color", Color.GREEN)

	# Load texture pack directories
	_load_texture_packs_list()

	# Load graphics settings
	_load_graphics_settings()

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
	var cache_path := cache_path_edit.text.strip_edges()

	_log("Saving settings...")
	SettingsManager.set_data_path(data_path)
	SettingsManager.set_esm_file(esm_file)

	# Save cache path (empty means use default)
	if cache_path.is_empty() or cache_path == SettingsManager.get_default_cache_path():
		# Clear custom cache path to use default
		SettingsManager.set_cache_base_path("")
		_log("  Cache path: %s (default)" % SettingsManager.get_default_cache_path())
	else:
		SettingsManager.set_cache_base_path(cache_path)
		_log("  Cache path: %s (custom)" % cache_path)

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
	Log.info("tools", text.replace("[b]", "").replace("[/b]", "").replace("[color=red]", "").replace("[color=green]", "").replace("[color=yellow]", "").replace("[color=orange]", "").replace("[/color]", ""))


# =============================================================================
# Cache Path Configuration
# =============================================================================

func _on_cache_browse_pressed() -> void:
	# Set initial directory if current path is valid
	var current_cache := cache_path_edit.text.strip_edges()
	if not current_cache.is_empty() and DirAccess.dir_exists_absolute(current_cache):
		cache_file_dialog.current_dir = current_cache
	else:
		# Default to Documents folder
		cache_file_dialog.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)

	cache_file_dialog.popup_centered_ratio(0.7)


func _on_cache_dir_selected(dir: String) -> void:
	cache_path_edit.text = dir
	_log("Cache path set to: %s" % dir)
	_log("[color=yellow]Click 'Save Settings' to apply changes.[/color]")


func _on_cache_reset_pressed() -> void:
	var default_path := SettingsManager.get_default_cache_path()
	cache_path_edit.text = default_path
	_log("Cache path reset to default: %s" % default_path)
	_log("[color=yellow]Click 'Save Settings' to apply changes.[/color]")


# =============================================================================
# External Texture Packs Configuration
# =============================================================================

func _load_texture_packs_list() -> void:
	texture_packs_list.clear()
	var dirs := SettingsManager.get_external_texture_directories()
	for i in dirs.size():
		var dir: String = dirs[i]
		# Show priority number (higher = later = higher priority)
		var priority := i + 1
		texture_packs_list.add_item("[%d] %s" % [priority, dir])
	_update_texture_pack_buttons()


func _update_texture_pack_buttons() -> void:
	var selected := texture_packs_list.get_selected_items()
	var has_selection := selected.size() > 0
	var item_count := texture_packs_list.item_count

	remove_texture_pack_button.disabled = not has_selection
	move_up_button.disabled = not has_selection or (has_selection and selected[0] == 0)
	move_down_button.disabled = not has_selection or (has_selection and selected[0] == item_count - 1)


func _on_texture_pack_selected(_index: int) -> void:
	_update_texture_pack_buttons()


func _on_add_texture_pack_pressed() -> void:
	# Set initial directory to a reasonable location
	var last_dir := ""
	var dirs := SettingsManager.get_external_texture_directories()
	if dirs.size() > 0:
		last_dir = dirs[dirs.size() - 1]
		if DirAccess.dir_exists_absolute(last_dir):
			# Go to parent directory to make it easier to add sibling folders
			last_dir = last_dir.get_base_dir()

	if last_dir.is_empty() or not DirAccess.dir_exists_absolute(last_dir):
		# Default to user's Documents or home directory
		last_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)

	texture_pack_file_dialog.current_dir = last_dir
	texture_pack_file_dialog.popup_centered_ratio(0.7)


func _on_texture_pack_dir_selected(dir: String) -> void:
	# Check if directory is already in the list
	var dirs := SettingsManager.get_external_texture_directories()
	if dir in dirs:
		_log("[color=yellow]Directory already in list: %s[/color]" % dir)
		return

	# Add to list and save immediately
	SettingsManager.add_external_texture_directory(dir)
	_load_texture_packs_list()

	# Clear texture cache since we have new textures available
	_clear_texture_cache_internal()

	_log("[color=green]Added texture pack directory:[/color] %s" % dir)
	_log("Priority: %d (higher = overrides lower)" % SettingsManager.get_external_texture_directories().size())


func _on_remove_texture_pack_pressed() -> void:
	var selected := texture_packs_list.get_selected_items()
	if selected.size() == 0:
		return

	var idx: int = selected[0]
	var dirs := SettingsManager.get_external_texture_directories()
	if idx < 0 or idx >= dirs.size():
		return

	var removed_dir: String = dirs[idx]
	SettingsManager.remove_external_texture_directory(removed_dir)
	_load_texture_packs_list()

	# Clear texture cache since available textures changed
	_clear_texture_cache_internal()

	_log("[color=orange]Removed texture pack directory:[/color] %s" % removed_dir)


func _on_move_up_pressed() -> void:
	var selected := texture_packs_list.get_selected_items()
	if selected.size() == 0:
		return

	var idx: int = selected[0]
	if idx <= 0:
		return

	var dirs := SettingsManager.get_external_texture_directories()
	if idx >= dirs.size():
		return

	# Swap with previous item
	var temp: String = dirs[idx]
	dirs[idx] = dirs[idx - 1]
	dirs[idx - 1] = temp
	SettingsManager.set_external_texture_directories(dirs)
	_load_texture_packs_list()

	# Re-select the moved item
	texture_packs_list.select(idx - 1)
	_update_texture_pack_buttons()

	# Clear texture cache since priority changed
	_clear_texture_cache_internal()

	_log("Moved texture pack up (lower priority now)")


func _on_move_down_pressed() -> void:
	var selected := texture_packs_list.get_selected_items()
	if selected.size() == 0:
		return

	var idx: int = selected[0]
	var dirs := SettingsManager.get_external_texture_directories()
	if idx < 0 or idx >= dirs.size() - 1:
		return

	# Swap with next item
	var temp: String = dirs[idx]
	dirs[idx] = dirs[idx + 1]
	dirs[idx + 1] = temp
	SettingsManager.set_external_texture_directories(dirs)
	_load_texture_packs_list()

	# Re-select the moved item
	texture_packs_list.select(idx + 1)
	_update_texture_pack_buttons()

	# Clear texture cache since priority changed
	_clear_texture_cache_internal()

	_log("Moved texture pack down (higher priority now)")


func _on_clear_texture_cache_pressed() -> void:
	_clear_texture_cache_internal()
	_log("[color=green]Texture cache cleared.[/color]")
	_log("Textures will be reloaded from external directories on next use.")


func _clear_texture_cache_internal() -> void:
	# Clear the TextureLoader's internal caches
	var TextureLoaderScript := preload("res://src/core/texture/texture_loader.gd")
	TextureLoaderScript.clear_cache()


# =============================================================================
# Graphics Settings Configuration
# =============================================================================

func _load_graphics_settings() -> void:
	# Load all graphics settings from SettingsManager
	quality_preset_option.select(SettingsManager.get_quality_preset())
	distant_rendering_check.button_pressed = SettingsManager.get_distant_rendering_enabled()
	anti_aliasing_option.select(SettingsManager.get_anti_aliasing())
	shadow_quality_option.select(SettingsManager.get_shadow_quality())

	var view_distance := SettingsManager.get_streaming_radius_cells()
	view_distance_slider.value = view_distance
	view_distance_value.text = "%d cells" % view_distance

	vsync_check.button_pressed = SettingsManager.get_vsync_enabled()
	ssao_check.button_pressed = SettingsManager.get_ssao_enabled()
	ssr_check.button_pressed = SettingsManager.get_ssr_enabled()
	glow_check.button_pressed = SettingsManager.get_glow_enabled()
	volumetric_fog_check.button_pressed = SettingsManager.get_volumetric_fog_enabled()

	# Map FPS value to option index
	var max_fps := SettingsManager.get_max_fps()
	var fps_index := 0  # Unlimited
	match max_fps:
		30: fps_index = 1
		60: fps_index = 2
		90: fps_index = 3
		120: fps_index = 4
		144: fps_index = 5
	max_fps_option.select(fps_index)


func _on_quality_preset_changed(index: int) -> void:
	SettingsManager.set_quality_preset(index as SettingsManager.QualityPreset)
	_log("Quality preset changed to: %s" % quality_preset_option.get_item_text(index))
	_log("[color=yellow]Restart required for full effect.[/color]")


func _on_distant_rendering_toggled(enabled: bool) -> void:
	SettingsManager.set_distant_rendering_enabled(enabled)
	if enabled:
		_log("[color=green]Distant rendering enabled[/color] - LOD + Impostors active")
	else:
		_log("[color=orange]Distant rendering disabled[/color] - NEAR tier only (~150m)")


func _on_anti_aliasing_changed(index: int) -> void:
	SettingsManager.set_anti_aliasing(index as SettingsManager.AntiAliasing)
	var aa_name := anti_aliasing_option.get_item_text(index)
	_log("Anti-aliasing changed to: %s" % aa_name)

	# Apply immediately if possible
	_apply_anti_aliasing(index)


func _apply_anti_aliasing(mode: int) -> void:
	var viewport := get_viewport()
	if not viewport:
		return

	# Reset all AA state
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.use_taa = false
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = 1.0

	match mode:
		0:  # Disabled
			pass
		1:  # FXAA
			viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
		2:  # SMAA
			viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
		3:  # MSAA 2x
			viewport.msaa_3d = Viewport.MSAA_2X
		4:  # FSR2 Quality (75% scale — performance + AA)
			viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
			viewport.scaling_3d_scale = 0.75
			viewport.fsr_sharpness = 0.2
		5:  # FSR2 Native (best temporal AA)
			viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
			viewport.scaling_3d_scale = 1.0
			viewport.fsr_sharpness = 0.2


func _on_shadow_quality_changed(index: int) -> void:
	SettingsManager.set_shadow_quality(index)
	var quality_name := shadow_quality_option.get_item_text(index)
	_log("Shadow quality changed to: %s" % quality_name)
	_log("[color=yellow]May require scene reload to apply.[/color]")


func _on_view_distance_changed(value: float) -> void:
	var radius := StreamingConfig.clamp_load_radius_cells(int(round(value)))
	SettingsManager.set_streaming_radius_cells(radius)
	view_distance_slider.set_value_no_signal(radius)
	view_distance_value.text = "%d cells" % radius


func _on_vsync_toggled(enabled: bool) -> void:
	SettingsManager.set_vsync_enabled(enabled)
	# Apply immediately
	if enabled:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
		_log("VSync enabled")
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		_log("VSync disabled")


func _on_ssao_toggled(enabled: bool) -> void:
	SettingsManager.set_ssao_enabled(enabled)
	_log("SSAO %s" % ("enabled" if enabled else "disabled"))


func _on_ssr_toggled(enabled: bool) -> void:
	SettingsManager.set_ssr_enabled(enabled)
	_log("SSR %s" % ("enabled" if enabled else "disabled"))


func _on_glow_toggled(enabled: bool) -> void:
	SettingsManager.set_glow_enabled(enabled)
	_log("Glow/Bloom %s" % ("enabled" if enabled else "disabled"))


func _on_volumetric_fog_toggled(enabled: bool) -> void:
	SettingsManager.set_volumetric_fog_enabled(enabled)
	_log("Volumetric fog %s" % ("enabled" if enabled else "disabled"))


func _on_max_fps_changed(index: int) -> void:
	var fps_values := [0, 30, 60, 90, 120, 144]
	var fps: int = fps_values[index] if index < fps_values.size() else 0
	SettingsManager.set_max_fps(fps)

	# Apply immediately
	Engine.max_fps = fps
	if fps == 0:
		_log("Max FPS: Unlimited")
	else:
		_log("Max FPS: %d" % fps)
