## ModRegistry - Centralized registry for mod load order and asset overrides
##
## This is a RefCounted object (not an autoload) managed by WorldExplorer.
## It handles:
## - Loading mods.json manifest
## - Compiling the flattened asset map (Asset Path -> Mod Provider)
## - Providing priority-aware path resolution for loaders
class_name ModRegistry
extends RefCounted

## Represents a single mod's data and assets
class Mod:
	var name: String
	var path: String            ## Folder path relative to Data Files or absolute
	var enabled: bool = true
	var esps: Array[String] = [] ## ESM/ESP files in this mod
	var bsas: Array[String] = [] ## BSA archives in this mod
	var has_prebaked: bool = false
	var has_loose: bool = false

## Path to the mods manifest
const MODS_JSON_PATH := "user://mods.json"

## The list of mods in load order (highest index = highest priority)
var _mods: Array[Mod] = []

## Flattened asset map for O(1) resolution: normalized_path -> Mod
var _asset_map: Dictionary = {}  # String -> Mod

## Statistics
var total_mods_loaded: int = 0
var total_overrides_indexed: int = 0


## Initialize and load the manifest
func load_manifest() -> Error:
	_mods.clear()
	_asset_map.clear()
	
	if not FileAccess.file_exists(MODS_JSON_PATH):
		# Create empty manifest if missing
		_save_default_manifest()
		return OK
		
	var file := FileAccess.open(MODS_JSON_PATH, FileAccess.READ)
	if file == null:
		return FileAccess.get_open_error()
		
	var json_str := file.get_as_text()
	file.close()
	
	var json := JSON.new()
	var err := json.parse(json_str)
	if err != OK:
		push_error("ModRegistry: Failed to parse mods.json: %s" % json.get_error_message())
		return err
		
	var data: Dictionary = json.data
	var mods_data: Array = data.get("mods", [])
	
	for mod_entry: Dictionary in mods_data:
		var mod := Mod.new()
		mod.name = mod_entry.get("name", "Unknown Mod")
		mod.path = mod_entry.get("path", "")
		mod.enabled = mod_entry.get("enabled", true)
		
		if mod.enabled:
			_mods.append(mod)
			_scan_mod_assets(mod)
			
	total_mods_loaded = _mods.size()
	Log.info("mod", "Loaded %d mods from manifest" % total_mods_loaded)
	return OK


## Scan a mod folder for BSAs, ESPs, and prebaked assets
func _scan_mod_assets(mod: Mod) -> void:
	if mod.path.is_empty():
		return
		
	var dir := DirAccess.open(mod.path)
	if dir == null:
		push_warning("ModRegistry: Could not open mod path: %s" % mod.path)
		return
		
	# 1. Look for ESPs/ESMs
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var lower := file_name.to_lower()
			if lower.ends_with(".esp") or lower.ends_with(".esm"):
				mod.esps.append(file_name)
			elif lower.ends_with(".bsa"):
				mod.bsas.append(file_name)
		file_name = dir.get_next()
	
	# 2. Check for prebaked folder
	if dir.dir_exists("prebaked"):
		mod.has_prebaked = true
		_index_prebaked_assets(mod)
		
	# 3. Check for loose files (simplified check for common folders)
	if dir.dir_exists("textures") or dir.dir_exists("meshes"):
		mod.has_loose = true
		_index_loose_assets(mod)


## Index prebaked .res files in mod/prebaked/
func _index_prebaked_assets(mod: Mod) -> void:
	var prebaked_path := mod.path.path_join("prebaked")
	var files := _list_files_recursive(prebaked_path)
	for f in files:
		var normalized := f.to_lower().replace("/", "\\")
		# Mod priority: later mods overwrite earlier ones in the map
		_asset_map[normalized] = mod
		total_overrides_indexed += 1


## Index loose source files in mod/ (textures, meshes, etc)
func _index_loose_assets(mod: Mod) -> void:
	# For loose files, we only index specific subfolders
	for sub: String in ["textures", "meshes", "icons", "sound", "music", "video"]:
		var sub_path := mod.path.path_join(sub)
		if DirAccess.dir_exists_absolute(sub_path):
			var files := _list_files_recursive(sub_path)
			for f in files:
				# Store path relative to mod root (e.g. "textures/foo.dds")
				var rel_path := sub.path_join(f)
				var normalized := rel_path.to_lower().replace("/", "\\")
				_asset_map[normalized] = mod
				total_overrides_indexed += 1


## Helper to list all files in a directory recursively
func _list_files_recursive(path: String) -> Array[String]:
	var results: Array[String] = []
	var dir := DirAccess.open(path)
	if dir == null:
		return results
		
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if dir.current_is_dir():
			if file_name != "." and file_name != "..":
				var sub_files := _list_files_recursive(path.path_join(file_name))
				for sf in sub_files:
					results.append(file_name.path_join(sf))
		else:
			results.append(file_name)
		file_name = dir.get_next()
		
	return results


## Save a default empty manifest
func _save_default_manifest() -> void:
	var default_data := {
		"version": "1.0",
		"mods": []
	}
	var file := FileAccess.open(MODS_JSON_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(default_data, "	"))
		file.close()


## Resolve an asset path to its winning mod provider
## Returns null if the asset is not overridden by any mod
func resolve_mod_for_path(path: String) -> Mod:
	var normalized := path.to_lower().replace("/", "\\")
	return _asset_map.get(normalized)


## Get the list of all enabled ESPs across all mods in load order
func get_esp_load_order() -> Array[String]:
	var order: Array[String] = []
	for mod in _mods:
		for esp in mod.esps:
			# Ensure it's the full path to the ESP
			order.append(mod.path.path_join(esp))
	return order


## Get the list of all BSAs across all mods in load order
func get_bsa_load_order() -> Array[String]:
	var order: Array[String] = []
	for mod in _mods:
		for bsa in mod.bsas:
			order.append(mod.path.path_join(bsa))
	return order
