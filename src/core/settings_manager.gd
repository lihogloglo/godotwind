@tool
extends Node
## Manages application settings with priority: env var > user config > ProjectSettings
##
## Priority order:
## 1. Environment variables (MORROWIND_DATA_PATH, MORROWIND_ESM_FILE)
## 2. User config file (user://settings.cfg)
## 3. ProjectSettings (project.godot)

const CONFIG_FILE_PATH := "user://settings.cfg"
const StreamingConfig := preload("res://src/core/world/streaming_config.gd")

var _config := ConfigFile.new()
var _config_loaded := false

## Returns Linux common installation paths for Morrowind
static func _get_linux_common_paths() -> Array[String]:
	var home := OS.get_environment("HOME")
	var paths: Array[String] = [
		# Steam on Linux
		home + "/.steam/steam/steamapps/common/Morrowind/Data Files",
		home + "/.local/share/Steam/steamapps/common/Morrowind/Data Files",
		# Flatpak Steam
		home + "/.var/app/com.valvesoftware.Steam/.steam/steam/steamapps/common/Morrowind/Data Files",
		# System-wide installations
		"/usr/share/games/morrowind/Data Files",
		"/usr/local/share/games/morrowind/Data Files",
		# GOG on Linux
		home + "/GOG Games/Morrowind/Data Files",
		# Lutris
		home + "/Games/morrowind/Data Files",
		# Wine prefix
		home + "/.wine/drive_c/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files",
	]
	return paths

## Returns Windows common installation paths for Morrowind
static func _get_windows_common_paths() -> Array[String]:
	var paths: Array[String] = [
		# Classic Steam installation (most common)
		"C:/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files",
		"C:/Program Files/Steam/steamapps/common/Morrowind/Data Files",
		# Bethesda retail
		"C:/Program Files (x86)/Bethesda Softworks/Morrowind/Data Files",
		"C:/Program Files/Bethesda Softworks/Morrowind/Data Files",
		# GOG
		"C:/GOG Games/Morrowind/Data Files",
		"C:/Program Files (x86)/GOG Galaxy/Games/Morrowind/Data Files",
		"C:/Program Files/GOG Galaxy/Games/Morrowind/Data Files",
		# Common game drive locations
		"D:/Games/Morrowind/Data Files",
		"D:/SteamLibrary/steamapps/common/Morrowind/Data Files",
		"E:/SteamLibrary/steamapps/common/Morrowind/Data Files",
		"F:/SteamLibrary/steamapps/common/Morrowind/Data Files",
		# Steam in root of drives
		"D:/Steam/steamapps/common/Morrowind/Data Files",
		"E:/Steam/steamapps/common/Morrowind/Data Files",
	]

	# Add user-specific Steam library path if available
	var local_app_data := OS.get_environment("LOCALAPPDATA")
	if not local_app_data.is_empty():
		# Some users have Steam in AppData
		paths.append(local_app_data + "/Steam/steamapps/common/Morrowind/Data Files")

	return paths

func _ready() -> void:
	_load_config()

func _load_config() -> void:
	if _config_loaded:
		return

	var err := _config.load(CONFIG_FILE_PATH)
	if err != OK and err != ERR_FILE_NOT_FOUND:
		push_warning("SettingsManager: Failed to load config file: %s (error: %d)" % [CONFIG_FILE_PATH, err])
	_config_loaded = true

func _save_config() -> void:
	var err := _config.save(CONFIG_FILE_PATH)
	if err != OK:
		push_error("SettingsManager: Failed to save config file: %s (error: %d)" % [CONFIG_FILE_PATH, err])

## Gets the Morrowind data path using the priority system
func get_data_path() -> String:
	# 1. Check environment variable
	var env_path := OS.get_environment("MORROWIND_DATA_PATH")
	if not env_path.is_empty():
		return env_path

	# 2. Check user config file
	_load_config()
	if _config.has_section_key("morrowind", "data_path"):
		var config_path: String = _config.get_value("morrowind", "data_path")
		if not config_path.is_empty():
			return config_path

	# 3. Fallback to ProjectSettings
	return ProjectSettings.get_setting("morrowind/data_path", "")

## Sets the Morrowind data path in user config
func set_data_path(path: String) -> void:
	_load_config()
	_config.set_value("morrowind", "data_path", path)
	_save_config()

## Gets the ESM file name using the priority system
func get_esm_file() -> String:
	# 1. Check environment variable
	var env_esm := OS.get_environment("MORROWIND_ESM_FILE")
	if not env_esm.is_empty():
		return env_esm

	# 2. Check user config file
	_load_config()
	if _config.has_section_key("morrowind", "esm_file"):
		var config_esm: String = _config.get_value("morrowind", "esm_file")
		if not config_esm.is_empty():
			return config_esm

	# 3. Fallback to ProjectSettings
	return ProjectSettings.get_setting("morrowind/esm_file", "Morrowind.esm")

## Sets the ESM file name in user config
func set_esm_file(filename: String) -> void:
	_load_config()
	_config.set_value("morrowind", "esm_file", filename)
	_save_config()

## Gets all common paths for the current platform
func get_common_paths() -> Array[String]:
	var paths: Array[String] = []

	if OS.get_name() == "Linux":
		paths.append_array(_get_linux_common_paths())
		# Also include Windows paths for Wine/Proton compatibility
		paths.append_array(_get_windows_common_paths())
	else:
		# Windows, macOS, etc.
		paths.append_array(_get_windows_common_paths())

	return paths

## Attempts to auto-detect Morrowind installation
## Returns the detected path or empty string if not found
func auto_detect_installation() -> String:
	# First check if current path is valid
	var current_path := get_data_path()
	if not current_path.is_empty() and DirAccess.dir_exists_absolute(current_path):
		var esm_path := current_path.path_join(get_esm_file())
		if FileAccess.file_exists(esm_path):
			return current_path

	# Try all common paths
	for path in get_common_paths():
		if DirAccess.dir_exists_absolute(path):
			var esm_path := path.path_join(get_esm_file())
			if FileAccess.file_exists(esm_path):
				return path

	return ""

## Returns the full path to the ESM file
func get_esm_path() -> String:
	var data_path := get_data_path()
	if data_path.is_empty():
		return ""
	return data_path.path_join(get_esm_file())

## Validates if the current configuration is valid
func validate_configuration() -> bool:
	var data_path := get_data_path()
	if data_path.is_empty():
		return false

	if not DirAccess.dir_exists_absolute(data_path):
		return false

	var esm_path := get_esm_path()
	return FileAccess.file_exists(esm_path)

## Gets the source of the current data path setting (for debugging)
func get_data_path_source() -> String:
	if not OS.get_environment("MORROWIND_DATA_PATH").is_empty():
		return "environment variable"

	_load_config()
	if _config.has_section_key("morrowind", "data_path"):
		var config_path: String = _config.get_value("morrowind", "data_path")
		if not config_path.is_empty():
			return "user config"

	return "project settings"


# =============================================================================
# Cache Path Management
# =============================================================================
# Prebaked/cached data (impostors, merged meshes, navmeshes, etc.) is stored
# outside the project folder to keep the repo clean and allow configurable paths.

## Returns the default cache base path (Documents/Godotwind/cache)
func get_default_cache_path() -> String:
	var documents := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	return documents.path_join("Godotwind").path_join("cache")


## Gets the cache base path (configurable, defaults to Documents/Godotwind/cache)
func get_cache_base_path() -> String:
	# Check environment variable first
	var env_path := OS.get_environment("GODOTWIND_CACHE_PATH")
	if not env_path.is_empty():
		return env_path

	# Check user config
	_load_config()
	if _config.has_section_key("cache", "base_path"):
		var config_path: String = _config.get_value("cache", "base_path")
		if not config_path.is_empty():
			return config_path

	# Default to Documents folder
	return get_default_cache_path()


## Sets a custom cache base path
func set_cache_base_path(path: String) -> void:
	_load_config()
	_config.set_value("cache", "base_path", path)
	_save_config()


## Gets the impostors cache path
func get_impostors_path() -> String:
	return get_cache_base_path().path_join("impostors")


## Gets the navmeshes cache path
func get_navmeshes_path() -> String:
	return get_cache_base_path().path_join("navmeshes")


## Gets the ocean data cache path (shore mask, etc.)
func get_ocean_path() -> String:
	return get_cache_base_path().path_join("ocean")


## Gets the prebaked models cache path (individual NIF->Godot conversions)
func get_models_path() -> String:
	return get_cache_base_path().path_join("models")


## Gets the preprocessed terrain data cache path (Terrain3D regions)
func get_terrain_path() -> String:
	return get_cache_base_path().path_join("terrain")


# =============================================================================
# External Texture Directory Management (OpenMW-style mod support)
# =============================================================================
# External texture directories allow loading textures from mod folders outside BSA.
# Priority: Later directories override earlier ones (like OpenMW mod order).
# External textures override BSA textures when found.

## Gets external texture directories (for mod texture packs)
## Returns array where later entries have higher priority
func get_external_texture_directories() -> Array[String]:
	_load_config()
	var dirs: Array[String] = []
	if _config.has_section_key("textures", "external_directories"):
		var config_dirs: Variant = _config.get_value("textures", "external_directories", [])
		if config_dirs is Array:
			for dir: Variant in config_dirs:
				if dir is String:
					dirs.append(dir)
	return dirs


## Sets external texture directories
func set_external_texture_directories(dirs: Array[String]) -> void:
	_load_config()
	_config.set_value("textures", "external_directories", dirs)
	_save_config()


## Adds an external texture directory (appended = highest priority)
func add_external_texture_directory(dir: String) -> void:
	var dirs := get_external_texture_directories()
	if dir not in dirs:
		dirs.append(dir)
		set_external_texture_directories(dirs)


## Removes an external texture directory
func remove_external_texture_directory(dir: String) -> void:
	var dirs := get_external_texture_directories()
	var idx := dirs.find(dir)
	if idx >= 0:
		dirs.remove_at(idx)
		set_external_texture_directories(dirs)


# =============================================================================
# Graphics Settings
# =============================================================================
# Rendering and visual quality settings that affect performance and visuals.

## Anti-aliasing modes
enum AntiAliasing {
	DISABLED,
	FXAA,
	SMAA,
	MSAA_2X,
	FSR2_QUALITY,  ## FSR 2.2 at 75% scale (performance + AA)
	FSR2_NATIVE,   ## FSR 2.2 at native res (best temporal AA)
}

## Quality presets matching StreamingConfig
enum QualityPreset {
	LOW,
	MEDIUM,
	HIGH,
	ULTRA,
	CUSTOM
}

## Gets the anti-aliasing mode
func get_anti_aliasing() -> AntiAliasing:
	_load_config()
	return _config.get_value("graphics", "anti_aliasing", AntiAliasing.FSR2_NATIVE) as AntiAliasing

## Sets the anti-aliasing mode
func set_anti_aliasing(mode: AntiAliasing) -> void:
	_load_config()
	_config.set_value("graphics", "anti_aliasing", mode)
	_save_config()

## Gets whether distant rendering (LOD + impostors) is enabled
func get_distant_rendering_enabled() -> bool:
	_load_config()
	return _config.get_value("graphics", "distant_rendering", true)

## Sets whether distant rendering is enabled
func set_distant_rendering_enabled(enabled: bool) -> void:
	_load_config()
	_config.set_value("graphics", "distant_rendering", enabled)
	_save_config()

## Gets the quality preset
func get_quality_preset() -> QualityPreset:
	_load_config()
	return _config.get_value("graphics", "quality_preset", QualityPreset.MEDIUM) as QualityPreset

## Sets the quality preset
func set_quality_preset(preset: QualityPreset) -> void:
	_load_config()
	_config.set_value("graphics", "quality_preset", preset)
	_save_config()

## Gets the view distance multiplier (0.5 to 2.0)
func get_view_distance_multiplier() -> float:
	_load_config()
	return _config.get_value("graphics", "view_distance_multiplier", 1.0)

## Sets the view distance multiplier
func set_view_distance_multiplier(multiplier: float) -> void:
	_load_config()
	_config.set_value("graphics", "view_distance_multiplier", clampf(multiplier, 0.25, 2.0))
	_save_config()

## Gets the user-facing object view distance in meters.
func get_view_distance_meters() -> int:
	var env_distance := OS.get_environment("GODOTWIND_VIEW_DISTANCE_METERS")
	if not env_distance.is_empty():
		return StreamingConfig.clamp_view_distance_meters(int(env_distance))

	_load_config()
	var default_distance: int = int(ProjectSettings.get_setting(
		"graphics/view_distance_meters",
		StreamingConfig.DEFAULT_VIEW_DISTANCE_METERS
	))
	var distance: int = int(_config.get_value("graphics", "view_distance_meters", default_distance))
	return StreamingConfig.clamp_view_distance_meters(distance)

## Sets the user-facing object view distance in meters.
func set_view_distance_meters(distance_m: int) -> void:
	_load_config()
	_config.set_value("graphics", "view_distance_meters", StreamingConfig.clamp_view_distance_meters(distance_m))
	_save_config()


## Legacy compatibility for older tools/settings. Values in the old 1-10 cell
## range are converted to the approximate historical render distance.
func get_streaming_radius_cells() -> int:
	var distance := get_view_distance_meters()
	return StreamingConfig.scene_load_radius_cells_for_view_distance_meters(distance)


func set_streaming_radius_cells(radius: int) -> void:
	set_view_distance_meters(int(round(StreamingConfig.distant_render_end_for_load_radius_cells(radius))))

## Gets whether VSync is enabled
func get_vsync_enabled() -> bool:
	_load_config()
	return _config.get_value("graphics", "vsync", true)

## Sets VSync
func set_vsync_enabled(enabled: bool) -> void:
	_load_config()
	_config.set_value("graphics", "vsync", enabled)
	_save_config()

## Gets the shadow quality (0=disabled, 1=low, 2=medium, 3=high, 4=ultra)
func get_shadow_quality() -> int:
	_load_config()
	return _config.get_value("graphics", "shadow_quality", 2)

## Sets shadow quality
func set_shadow_quality(quality: int) -> void:
	_load_config()
	_config.set_value("graphics", "shadow_quality", clampi(quality, 0, 4))
	_save_config()

## Gets SSAO (Screen Space Ambient Occlusion) enabled state
func get_ssao_enabled() -> bool:
	_load_config()
	return _config.get_value("graphics", "ssao", true)

## Sets SSAO enabled state
func set_ssao_enabled(enabled: bool) -> void:
	_load_config()
	_config.set_value("graphics", "ssao", enabled)
	_save_config()

## Gets SSR (Screen Space Reflections) enabled state
func get_ssr_enabled() -> bool:
	_load_config()
	return _config.get_value("graphics", "ssr", true)

## Sets SSR enabled state
func set_ssr_enabled(enabled: bool) -> void:
	_load_config()
	_config.set_value("graphics", "ssr", enabled)
	_save_config()

## Gets Glow/Bloom enabled state
func get_glow_enabled() -> bool:
	_load_config()
	return _config.get_value("graphics", "glow", true)

## Sets Glow enabled state
func set_glow_enabled(enabled: bool) -> void:
	_load_config()
	_config.set_value("graphics", "glow", enabled)
	_save_config()

## Gets volumetric fog enabled state
func get_volumetric_fog_enabled() -> bool:
	_load_config()
	return _config.get_value("graphics", "volumetric_fog", false)

## Sets volumetric fog enabled state
func set_volumetric_fog_enabled(enabled: bool) -> void:
	_load_config()
	_config.set_value("graphics", "volumetric_fog", enabled)
	_save_config()

## Gets the max FPS limit (0 = unlimited)
func get_max_fps() -> int:
	_load_config()
	return _config.get_value("graphics", "max_fps", 0)

## Sets max FPS limit
func set_max_fps(fps: int) -> void:
	_load_config()
	_config.set_value("graphics", "max_fps", maxi(fps, 0))
	_save_config()


## Creates all cache subdirectories if they don't exist
## Returns OK on success, or the first error encountered
func ensure_cache_directories() -> Error:
	var paths := [
		get_cache_base_path(),
		get_impostors_path(),
		get_navmeshes_path(),
		get_ocean_path(),
		get_models_path(),
		get_terrain_path(),
	]

	for path: String in paths:
		if not DirAccess.dir_exists_absolute(path):
			var err := DirAccess.make_dir_recursive_absolute(path)
			if err != OK:
				push_error("SettingsManager: Failed to create cache directory: %s (error: %d)" % [path, err])
				return err

	return OK
