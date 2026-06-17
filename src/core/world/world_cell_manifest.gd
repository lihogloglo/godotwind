class_name WorldCellManifest
extends RefCounted

var cell_grid: Vector2i = Vector2i.ZERO
var cell_name: String = ""
var objects: Array = []


func _init(p_cell_grid: Vector2i = Vector2i.ZERO) -> void:
	cell_grid = p_cell_grid


func add_object(record: RefCounted) -> void:
	if record != null:
		objects.append(record)


func get_capable_objects(capability: int) -> Array:
	var out: Array = []
	for record: RefCounted in objects:
		if record.has_capability(capability):
			out.append(record)
	return out
