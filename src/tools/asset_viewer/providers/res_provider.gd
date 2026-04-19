## ResProvider — Inspector for prebaked `.res` PackedScene cache files.
##
## Scans `SettingsManager.get_models_path()` for `*.res` and `*.res.crashtest`
## (quarantined) files. On selection, loads the PackedScene WITHOUT
## instantiating and dumps the `SceneState` structure so corrupt cache files
## can be diagnosed without crashing the viewer.
##
## Instantiation is a separate user-driven action (custom "Instantiate" tab).
## Every instantiate attempt is wrapped in `CrashBreadcrumb.write()` so a
## native SIGSEGV inside `PackedScene.instantiate()` still names the file.
##
## Why this exists: `model_loader.gd:_instantiate_from_scene` crashes at
## `PackedScene.instantiate()` on certain cache files (bc_11, grass_01 as of
## 2026-04-19). The game-side crash has no backtrace in release builds; this
## viewer gives the user a hands-on tool to pick a file, see if it loads, and
## manually trigger the hazardous op in isolation.
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_cast", "unsafe_call_argument")
class_name ResProvider
extends AssetProvider

const CrashBreadcrumbScript := preload("res://src/core/logging/crash_breadcrumb.gd")

# State
var _models_dir: String = ""
var _files: Array[Dictionary] = []  # {path, name, size, is_quarantined, category}
var _last_loaded_scene: PackedScene = null
var _last_loaded_state: SceneState = null
var _last_item_id: String = ""
var _last_instantiated_node: Node3D = null

# Category prefixes mapped to human names
const CATEGORY_PREFIXES: Dictionary = {
	"f_terrain_": "terrain",
	"f_flora_": "flora",
	"f_misc_": "misc",
	"f_light_": "lights",
	"f_active_": "active",
	"f_armor_": "armor",
	"f_weapon_": "weapons",
	"f_book_": "books",
	"f_door_": "doors",
	"f_furn_": "furniture",
	"f_contain_": "containers",
	"f_npc_": "npcs",
	"f_creat_": "creatures",
	"f_static_": "static",
	"b_": "body",
	"x_": "architecture",
}


func _init() -> void:
	provider_name = "Baked .res Cache"


func initialize() -> Error:
	loading_started.emit()

	_models_dir = SettingsManager.get_models_path()
	if _models_dir.is_empty():
		loading_failed.emit("Models cache path empty — check SettingsManager.get_cache_dir()")
		return ERR_FILE_NOT_FOUND

	_log("Scanning cache dir: %s" % _models_dir)

	var dir := DirAccess.open(_models_dir)
	if dir == null:
		loading_failed.emit("Cannot open models cache dir: %s" % _models_dir)
		return ERR_CANT_OPEN

	dir.list_dir_begin()
	var scanned := 0
	var file_name := dir.get_next()
	while file_name != "":
		var is_res := file_name.ends_with(".res")
		var is_quarantine := file_name.ends_with(".res.crashtest")
		if is_res or is_quarantine:
			var full_path: String = _models_dir.path_join(file_name)
			var size := _stat_size(full_path)
			_files.append({
				"path": full_path,
				"name": file_name,
				"size": size,
				"is_quarantined": is_quarantine,
				"category": _categorize(file_name),
			})
			scanned += 1
			if scanned % 500 == 0:
				_progress(scanned, 0, "Scanned %d files..." % scanned)
		file_name = dir.get_next()
	dir.list_dir_end()

	_files.sort_custom(func(a, b) -> bool: return (a.get("name") as String) < (b.get("name") as String))

	var quarantine_count := 0
	for f: Dictionary in _files:
		if f.get("is_quarantined", false):
			quarantine_count += 1

	_log("[color=green]Scanned %d cache files (%d quarantined `.crashtest`)[/color]" % [_files.size(), quarantine_count])
	loading_completed.emit()
	return OK


func _stat_size(path: String) -> int:
	# Cheap file size without reading bytes.
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n


func _categorize(file_name: String) -> String:
	var lower := file_name.to_lower()
	for prefix: String in CATEGORY_PREFIXES:
		if lower.begins_with(prefix):
			return CATEGORY_PREFIXES[prefix]
	return "other"


func is_ready() -> bool:
	return not _files.is_empty()


func get_categories() -> Array[String]:
	var seen: Dictionary = {}
	var cats: Array[String] = ["quarantined"]  # synthetic category for .crashtest only
	for f: Dictionary in _files:
		var cat: String = f.get("category", "other")
		if not seen.has(cat):
			seen[cat] = true
			cats.append(cat)
	return cats


func get_items() -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	for f: Dictionary in _files:
		var name_str: String = f.get("name", "")
		var quarantined: bool = f.get("is_quarantined", false)
		var display_name := ("[QUARANTINED] " + name_str) if quarantined else name_str
		# Files flagged quarantined appear in BOTH their native category AND the synthetic "quarantined" bucket.
		# The viewer's browser filters by substring, so we list the file once under its native category.
		var category: String = "quarantined" if quarantined else f.get("category", "other")
		items.append({
			"id": f.get("path", ""),
			"name": display_name,
			"category": category,
			"tooltip": "%s (%d bytes)" % [f.get("path", ""), f.get("size", -1)],
			"path": f.get("path", ""),
			"size": f.get("size", -1),
			"is_quarantined": quarantined,
		})
	return items


## Loads the PackedScene AND instantiates it for preview. Breadcrumbs wrap
## both the load and the instantiate call so a native SIGSEGV names the
## offending file in `user://logs/crash_breadcrumb.txt`.
##
## If the viewer crashes on a specific file:
## 1. Read the breadcrumb file — last entry names the file + the stage
##    (`load_begin` before load, `instantiate_begin` before instantiate).
## 2. Quarantine the file (rename `.res` → `.res.crashtest`).
## 3. Relaunch the viewer — the quarantined file is still selectable for
##    re-investigation after rebake.
func load_item(item: Dictionary) -> Node3D:
	var path: String = item.get("path", "")
	if path.is_empty():
		_log("[color=red]Empty path[/color]")
		return null

	# Reset any previously instantiated node so we don't leak.
	if _last_instantiated_node and is_instance_valid(_last_instantiated_node):
		_last_instantiated_node.queue_free()
	_last_instantiated_node = null
	_last_loaded_scene = null
	_last_loaded_state = null
	_last_item_id = path

	_log("Loading: %s" % path.get_file())

	# Quarantined files have a non-standard extension so ResourceLoader won't
	# recognize them. Temporarily copy to a `.res` path for load inspection.
	var load_path := path
	var temp_copy := ""
	if path.ends_with(".crashtest"):
		temp_copy = _models_dir.path_join("_inspect_temp.res")
		var src := FileAccess.open(path, FileAccess.READ)
		if src == null:
			_log("[color=red]Cannot read quarantined file: %s[/color]" % path)
			return null
		var bytes := src.get_buffer(src.get_length())
		src.close()
		var dst := FileAccess.open(temp_copy, FileAccess.WRITE)
		if dst == null:
			_log("[color=red]Cannot write temp copy for inspect: %s[/color]" % temp_copy)
			return null
		dst.store_buffer(bytes)
		dst.close()
		load_path = temp_copy

	CrashBreadcrumbScript.write("res_provider::load_begin", path)
	var res := ResourceLoader.load(load_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	CrashBreadcrumbScript.write("res_provider::load_end", path)

	# Clean temp copy regardless of load success/failure.
	if not temp_copy.is_empty():
		DirAccess.remove_absolute(temp_copy)

	if res == null:
		_log("[color=red]ResourceLoader.load returned null[/color]")
		return null
	if not (res is PackedScene):
		_log("[color=red]Loaded resource is not PackedScene (got %s)[/color]" % res.get_class())
		return null

	_last_loaded_scene = res as PackedScene
	_last_loaded_state = _last_loaded_scene.get_state()

	var ns := _last_loaded_state.get_node_count()
	_log("  Loaded PackedScene — %d nodes, %d connections" % [ns, _last_loaded_state.get_connection_count()])
	if ns > 0:
		_log("  Root: %s (%s)" % [_last_loaded_state.get_node_name(0), _last_loaded_state.get_node_type(0)])

	# Instantiate. This is the operation that can crash the viewer if the
	# cache file is corrupt — breadcrumb is the diagnostic.
	CrashBreadcrumbScript.write("res_provider::instantiate_begin", path)
	var node := _last_loaded_scene.instantiate()
	CrashBreadcrumbScript.write("res_provider::instantiate_end", path)

	if node == null:
		_log("[color=red]instantiate() returned null[/color]")
		return null

	var n3d: Node3D = node as Node3D
	if n3d == null:
		_log("[color=orange]instantiate() returned non-Node3D: %s — wrapping[/color]" % node.get_class())
		var wrapper := Node3D.new()
		wrapper.add_child(node)
		n3d = wrapper

	_last_instantiated_node = n3d
	_log("[color=green]Instantiated — %s[/color]" % node.get_class())
	return n3d


func get_info_text(item: Dictionary) -> String:
	if _last_loaded_state == null or _last_item_id != item.get("id"):
		return "[b]Select or reload an item to inspect[/b]"

	var text := "[b].res Inspection:[/b]\n"
	text += "  Path: %s\n" % item.get("path", "")
	text += "  Size: %d bytes\n" % int(item.get("size", -1))
	text += "  Quarantined: %s\n" % ("yes (`.crashtest`)" if item.get("is_quarantined", false) else "no")

	text += "\n[b]SceneState:[/b]\n"
	text += "  Nodes: %d\n" % _last_loaded_state.get_node_count()
	text += "  Connections: %d\n" % _last_loaded_state.get_connection_count()

	var ns := _last_loaded_state.get_node_count()
	if ns > 0:
		text += "\n[b]Root:[/b]\n"
		text += "  Name: %s\n" % _last_loaded_state.get_node_name(0)
		text += "  Type: %s\n" % _last_loaded_state.get_node_type(0)
		text += "  Property count: %d\n" % _last_loaded_state.get_node_property_count(0)

	if ns > 1:
		text += "\n[b]First 10 child nodes:[/b]\n"
		for i in range(1, mini(11, ns)):
			text += "  %d. %s (%s)\n" % [i, _last_loaded_state.get_node_name(i), _last_loaded_state.get_node_type(i)]
		if ns > 11:
			text += "  ... and %d more\n" % (ns - 11)

	return text


func cleanup() -> void:
	if _last_instantiated_node and is_instance_valid(_last_instantiated_node):
		_last_instantiated_node.queue_free()
	_last_instantiated_node = null
	_last_loaded_scene = null
	_last_loaded_state = null
	_files.clear()
