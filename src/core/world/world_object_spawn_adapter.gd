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
