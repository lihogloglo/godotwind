class_name WorldAssetProvider
extends RefCounted

## Source-neutral asset lookup contract.
##
## Implementations translate source-specific model/texture/archive references
## into framework resource handles or normalized asset IDs.

var source_name: String = "Generic"


func has_model(_model_id: String) -> bool:
	return false


func resolve_model_path(model_id: String) -> String:
	return model_id


func has_model_resource(_model_id: String, _item_id: String = "") -> bool:
	return false


func get_model_resource(_model_id: String, _item_id: String = "") -> Resource:
	return null


func create_model_scene(_model_id: String, _item_id: String = "") -> Node3D:
	return null


func submit_model_parse_task(_background_processor: Variant, _model_id: String, _item_id: String = "") -> int:
	return -1


func is_model_parse_result_valid(_parse_result: Variant) -> bool:
	return false


func get_model_parse_result_item_id(_parse_result: Variant) -> String:
	return ""


func create_model_scene_from_parse_result(_parse_result: Variant) -> Node3D:
	return null


func has_texture(_texture_id: String) -> bool:
	return false


func resolve_texture_path(texture_id: String) -> String:
	return texture_id


func get_texture_resource(_texture_id: String) -> Resource:
	return null
