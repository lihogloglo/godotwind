class_name WorldCoordinateMapper
extends RefCounted

## Source-neutral grid and coordinate policy.
##
## Core streaming works in Godot meters. Source-specific unit conversion belongs
## in source adapters; this base mapper only defines the framework grid math.

var cell_size_meters: float = 256.0


func get_cell_size_meters() -> float:
	return cell_size_meters


func world_to_cell(world_pos: Vector3) -> Vector2i:
	var cell_size := get_cell_size_meters()
	return Vector2i(
		floori(world_pos.x / cell_size),
		floori(-world_pos.z / cell_size)
	)


func cell_to_world_origin(cell: Vector2i, y: float = 0.0) -> Vector3:
	var cell_size := get_cell_size_meters()
	return Vector3(
		float(cell.x) * cell_size,
		y,
		-float(cell.y) * cell_size
	)


func cell_to_world_center(cell: Vector2i, y: float = 0.0) -> Vector3:
	var cell_size := get_cell_size_meters()
	var half_cell := cell_size * 0.5
	return Vector3(
		float(cell.x) * cell_size + half_cell,
		y,
		-float(cell.y) * cell_size - half_cell
	)


func cell_distance_squared(cell_a: Vector2i, cell_b: Vector2i) -> float:
	var cell_size := get_cell_size_meters()
	var dx := float(cell_b.x - cell_a.x) * cell_size
	var dy := float(cell_b.y - cell_a.y) * cell_size
	return dx * dx + dy * dy


func cell_distance(cell_a: Vector2i, cell_b: Vector2i) -> float:
	return sqrt(cell_distance_squared(cell_a, cell_b))


func distance_to_cell_radius(distance_meters: float) -> int:
	return ceili(distance_meters / get_cell_size_meters())


func cell_radius_to_distance(cell_radius: int) -> float:
	return float(cell_radius) * get_cell_size_meters()


func chunk_center_world(center_cell: Vector2i, size_level: int) -> Vector2:
	var size: int = 1 << size_level
	var cell_size := get_cell_size_meters()
	var half_extent := float(size) * cell_size * 0.5
	return Vector2(
		float(center_cell.x) * cell_size + half_extent,
		-float(center_cell.y) * cell_size - half_extent
	)
