class_name WaterBodyProvider
extends RefCounted

var provider_id: StringName = &"water_provider"
var priority: int = 100


func initialize() -> Error:
	return OK


func prepare_region(_region_coord: Vector2i) -> Error:
	return OK


func get_water_body_descriptors_for_region(_region_coord: Vector2i) -> Array[RefCounted]:
	return []


func sample_coverage(_world_pos: Vector3) -> float:
	return 0.0


func sample_height(_world_pos: Vector3, fallback: float = NAN) -> float:
	return fallback


func sample_normal(_world_pos: Vector3, fallback: Vector3 = Vector3.UP) -> Vector3:
	return fallback


func sample_gradient(_world_pos: Vector3, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	return fallback


func sample_velocity(_world_pos: Vector3, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	return fallback


func sample_water_body_id(_world_pos: Vector3, fallback: StringName = WaterSurfaceState.WATER_BODY_NONE) -> StringName:
	return fallback
