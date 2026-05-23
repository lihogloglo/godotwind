class_name MorrowindAssetProvider
extends "res://src/core/world/world_asset_provider.gd"

const NIFConverter := preload("res://src/core/nif/nif_converter.gd")
const NIFParseResult := preload("res://src/core/nif/nif_parse_result.gd")


func _init() -> void:
	source_name = "Morrowind"


func has_model(model_id: String) -> bool:
	var normalized := resolve_model_path(model_id)
	var archive_path := _resolve_archive_model_path(normalized)
	return not archive_path.is_empty() or ResourceLoader.exists(normalized)


func resolve_model_path(model_id: String) -> String:
	return model_id.replace("/", "\\")


func has_model_resource(model_id: String, _item_id: String = "") -> bool:
	return ResourceLoader.exists(resolve_model_path(model_id))


func get_model_resource(model_id: String, _item_id: String = "") -> Resource:
	var normalized := resolve_model_path(model_id)
	if ResourceLoader.exists(normalized):
		return ResourceLoader.load(normalized)
	return null


func create_model_scene(model_id: String, item_id: String = "") -> Node3D:
	var normalized := resolve_model_path(model_id)
	var archive_path := _resolve_archive_model_path(normalized)
	if archive_path.is_empty():
		return null
	var nif_data := _bsa_extract_file(archive_path)
	if nif_data.is_empty():
		return null

	var converter := NIFConverter.new()
	converter.generate_lods = true
	converter.generate_occluders = false
	converter.load_animations = true
	if not item_id.is_empty():
		converter.collision_item_id = item_id
	return converter.convert_buffer(nif_data, archive_path)


func submit_model_parse_task(background_processor: Variant, model_id: String, item_id: String = "") -> int:
	if background_processor == null or not background_processor.has_method("submit_task"):
		return -1

	var normalized := resolve_model_path(model_id)
	var archive_path := _resolve_archive_model_path(normalized)
	if archive_path.is_empty():
		return -1

	return int(background_processor.call("submit_task", func() -> Variant:
		var nif_data := _bsa_extract_file(archive_path)
		if nif_data.is_empty():
			return null
		return NIFConverter.parse_buffer_only(nif_data, archive_path, item_id)
	))


func is_model_parse_result_valid(parse_result: Variant) -> bool:
	return parse_result is NIFParseResult and parse_result.is_valid()


func get_model_parse_result_item_id(parse_result: Variant) -> String:
	if parse_result is NIFParseResult:
		return str(parse_result.item_id)
	return ""


func create_model_scene_from_parse_result(parse_result: Variant) -> Node3D:
	if not is_model_parse_result_valid(parse_result):
		return null
	var converter := NIFConverter.new()
	return converter.convert_from_parsed(parse_result as NIFParseResult)


func has_texture(texture_id: String) -> bool:
	var normalized := texture_id.replace("/", "\\")
	return _bsa_has_file(normalized) or ResourceLoader.exists(normalized)


func resolve_texture_path(texture_id: String) -> String:
	return texture_id.replace("/", "\\")


func _bsa_has_file(path: String) -> bool:
	var bsa := _get_bsa_manager()
	return bsa != null and bsa.has_method("has_file") and bool(bsa.call("has_file", path))


func _bsa_extract_file(path: String) -> PackedByteArray:
	var bsa := _get_bsa_manager()
	if bsa == null or not bsa.has_method("extract_file"):
		return PackedByteArray()
	return bsa.call("extract_file", path) as PackedByteArray


func _resolve_archive_model_path(model_path: String) -> String:
	var full_path := model_path
	if not model_path.to_lower().begins_with("meshes"):
		full_path = "meshes\\" + model_path
	if _bsa_has_file(full_path):
		return full_path
	if _bsa_has_file(model_path):
		return model_path
	return ""


func _get_bsa_manager() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("/root/BSAManager")
