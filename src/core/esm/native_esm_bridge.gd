class_name NativeESMBridge
extends RefCounted

const NativeBridgeScript := preload("res://src/core/native_bridge.gd")

var _bridge: NativeBridge = null


func _init() -> void:
	_bridge = NativeBridgeScript.new()


static func is_available() -> bool:
	return NativeBridgeScript.is_csharp_available()


func has_native_esm() -> bool:
	return _bridge != null and _bridge.has_native_factory_method(&"CreateESMLoader")


func create_esm_loader() -> RefCounted:
	if not has_native_esm():
		return null
	return _bridge.create_native_service(&"CreateESMLoader")


@warning_ignore("unsafe_method_access")
func load_esm_file(path: String, lazy_load_references: bool = true) -> RefCounted:
	if not has_native_esm():
		return null
	return _bridge.call_native_factory(&"LoadESMFile", [path, lazy_load_references]) as RefCounted


@warning_ignore("unsafe_method_access")
func load_esm_file_cached(esm_path: String, cache_path: String = "") -> RefCounted:
	if not has_native_esm():
		return null
	if cache_path.is_empty():
		return _bridge.call_native_factory(&"LoadESMFileWithCache", [esm_path]) as RefCounted
	return _bridge.call_native_factory(&"LoadESMFileWithCachePath", [esm_path, cache_path]) as RefCounted


@warning_ignore("unsafe_method_access")
func esm_cache_exists(esm_path: String) -> bool:
	if not has_native_esm():
		return false
	var result: Variant = _bridge.call_native_factory(&"ESMCacheExists", [esm_path])
	return result if result is bool else false


@warning_ignore("unsafe_method_access")
func get_esm_cache_path(esm_path: String) -> String:
	if not has_native_esm():
		return ""
	var result: Variant = _bridge.call_native_factory(&"GetESMCachePath", [esm_path])
	return result if result is String else ""


@warning_ignore("unsafe_method_access")
func get_model_path(loader: RefCounted, record_id: String) -> String:
	if loader == null:
		return ""
	var result: Variant = loader.call("GetModelPath", record_id)
	return result if result is String else ""


@warning_ignore("unsafe_method_access")
func get_exterior_cell(loader: RefCounted, grid_x: int, grid_y: int) -> RefCounted:
	if loader == null:
		return null
	return loader.call("GetExteriorCell", grid_x, grid_y) as RefCounted


@warning_ignore("unsafe_method_access")
func get_cell_references(cell: RefCounted) -> Array:
	if cell == null:
		return []
	var refs: Variant = cell.get("References")
	return refs if refs is Array else []


@warning_ignore("unsafe_method_access")
func export_all_cells_packed(loader: RefCounted) -> Dictionary:
	if loader == null:
		return {}
	var result: Variant = loader.call("ExportAllCellsPacked")
	return result if result is Dictionary else {}


@warning_ignore("unsafe_method_access")
func get_record_info(loader: RefCounted, record_id: String) -> Variant:
	if loader == null:
		return null
	return loader.call("GetRecordInfo", record_id)


@warning_ignore("unsafe_method_access")
func get_typed_record_data(loader: RefCounted, type_name: String, record_id: String) -> Dictionary:
	if loader == null:
		return {}
	var method_name: String = ""
	match type_name:
		"activator": method_name = "GetActivatorData"
		"light": method_name = "GetLightData"
		"npc": method_name = "GetNPCData"
		"creature": method_name = "GetCreatureData"
		"door": method_name = "GetDoorData"
		"container": method_name = "GetContainerData"
		"weapon": method_name = "GetWeaponData"
		"armor": method_name = "GetArmorData"
		"clothing": method_name = "GetClothingData"
		_: return {}
	var result: Variant = loader.call(method_name, record_id)
	return result if result is Dictionary else {}


@warning_ignore("unsafe_property_access")
func get_esm_stats(loader: RefCounted) -> Dictionary:
	if loader == null:
		return {}

	var statics_count := 0
	var cells_count := 0
	var exterior_count := 0

	var statics_v: Variant = loader.get("Statics")
	if statics_v is Dictionary:
		var statics_d: Dictionary = statics_v as Dictionary
		statics_count = statics_d.size()

	var cells_v: Variant = loader.get("Cells")
	if cells_v is Dictionary:
		var cells_d: Dictionary = cells_v as Dictionary
		cells_count = cells_d.size()

	var exterior_v: Variant = loader.get("ExteriorCells")
	if exterior_v is Dictionary:
		var exterior_d: Dictionary = exterior_v as Dictionary
		exterior_count = exterior_d.size()

	return {
		"total_records": loader.get("TotalRecordsLoaded"),
		"load_time_ms": loader.get("LoadTimeMs"),
		"statics_count": statics_count,
		"cells_count": cells_count,
		"exterior_cells_count": exterior_count,
	}
