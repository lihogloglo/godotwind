@tool
extends Node
## Manages application settings with priority: env var > user config > ProjectSettings
##
## Priority order:
## 1. Environment variables (MORROWIND_DATA_PATH, MORROWIND_ESM_FILE)
## 2. User config file (user://settings.cfg)
## 3. ProjectSettings (project.godot)

const CONFIG_FILE_PATH := "user://settings.cfg"

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


## Gets the merged cells cache path
func get_merged_cells_path() -> String:
	return get_cache_base_path().path_join("merged_cells")


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


## Creates all cache subdirectories if they don't exist
## Returns OK on success, or the first error encountered
func ensure_cache_directories() -> Error:
	var paths := [
		get_cache_base_path(),
		get_impostors_path(),
		get_merged_cells_path(),
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
