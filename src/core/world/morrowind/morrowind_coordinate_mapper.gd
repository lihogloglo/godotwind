class_name MorrowindCoordinateMapper
extends "res://src/core/world/world_coordinate_mapper.gd"

const CS := preload("res://src/core/coordinate_system.gd")


func _init() -> void:
	cell_size_meters = CS.CELL_SIZE_GODOT


func source_vector_to_world(source_pos: Vector3, apply_scale: bool = true) -> Vector3:
	return CS.vector_to_godot(source_pos, apply_scale)


func world_vector_to_source(world_pos: Vector3, apply_scale: bool = true) -> Vector3:
	return CS.vector_to_mw(world_pos, apply_scale)


func source_rotation_to_world_basis(source_rotation: Vector3) -> Basis:
	return CS.esm_rotation_to_godot_basis(source_rotation)


func source_scale_to_world(source_scale: float) -> Vector3:
	return CS.scale_to_godot(source_scale)


func source_height_to_world(source_height: float) -> float:
	return CS.height_to_godot(source_height)


func terrain_y_to_image_y(source_y: int, size: int = 65) -> int:
	return CS.terrain_y_to_image_y(source_y, size)
