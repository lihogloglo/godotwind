class_name WorldObjectSpawnAdapter
extends RefCounted

var object_source: RefCounted = null


func configure(source: RefCounted) -> void:
	object_source = source


func instantiate_world_object(
	_record: RefCounted,
	_instantiator: RefCounted,
	_cell_grid: Vector2i = Vector2i.ZERO,
	_cache_item_id: String = "",
) -> Node3D:
	return null


func resolve_source_reference_base_record(
	_source_ref: Variant,
	_record_type_out: Array = [],
	_cached: bool = false,
) -> Variant:
	return null


func make_world_object_record_from_source_reference(
	_source_ref: Variant,
	_base_record: Variant,
	_type_name: String,
	_model_path: String,
	_item_id: String,
	_cache_item_id: String,
	_static_route: bool,
	_cell_grid: Vector2i,
) -> RefCounted:
	return null


func is_source_record_carryable(_type_name: String, _base_record: Variant) -> bool:
	return false


func postprocess_source_model_object(
	_instance: Node3D,
	_ref: Variant,
	_base_record: Variant,
	_type_name: String,
	_cell_grid: Vector2i,
	_record_id: String,
	_instantiator: RefCounted,
	_source_key: String = "",
) -> void:
	pass


func postprocess_source_actor(
	character: Node3D,
	_ref: Variant,
	_actor_record: Variant,
	_actor_type: String,
	_instantiator: RefCounted,
) -> Node3D:
	return character


func source_light_animation_for_record(_light_record: Variant) -> int:
	return 0
