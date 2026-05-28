class_name WaterBodyDescriptor
extends RefCounted

const TYPE_OCEAN := &"ocean"
const TYPE_LAKE := &"lake"
const TYPE_RIVER := &"river"
const TYPE_POOL := &"pool"
const TYPE_UNKNOWN := &"unknown"

var body_id: StringName = &"water_body"
var body_type: StringName = TYPE_UNKNOWN
var priority: int = 100
var bounds: AABB = AABB()
var bounds_valid: bool = false
var surface_height: float = 0.0
var depth: float = 2.0
var flow_direction: Vector2 = Vector2.RIGHT
var flow_speed: float = 0.0
var coverage_texture: Texture2D = null
var flowmap_texture: Texture2D = null
var metadata: Dictionary = {}

var coverage_query: Callable = Callable()
var height_query: Callable = Callable()
var normal_query: Callable = Callable()
var gradient_query: Callable = Callable()
var velocity_query: Callable = Callable()
var water_body_id_query: Callable = Callable()


func sample_coverage(world_pos: Vector3) -> float:
	if coverage_query.is_valid():
		return clampf(float(coverage_query.call(world_pos)), 0.0, 1.0)
	if not bounds_valid:
		return 0.0
	if not _bounds_contains_xz(world_pos):
		return 0.0
	if world_pos.y < bounds.position.y:
		return 0.0
	return 1.0


func sample_height(world_pos: Vector3, fallback: float = NAN) -> float:
	if height_query.is_valid():
		return float(height_query.call(world_pos))
	if sample_coverage(world_pos) > 0.0:
		return surface_height
	return fallback


func sample_normal(world_pos: Vector3, fallback: Vector3 = Vector3.UP) -> Vector3:
	if normal_query.is_valid():
		var result: Variant = normal_query.call(world_pos)
		if result is Vector3:
			return (result as Vector3).normalized()
	return fallback


func sample_gradient(world_pos: Vector3, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if gradient_query.is_valid():
		var result: Variant = gradient_query.call(world_pos)
		if result is Vector2:
			return result
	return fallback


func sample_velocity(world_pos: Vector3, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if velocity_query.is_valid():
		var result: Variant = velocity_query.call(world_pos)
		if result is Vector3:
			return result
	if body_type == TYPE_RIVER and sample_coverage(world_pos) > 0.0:
		var dir := flow_direction.normalized()
		return Vector3(dir.x, 0.0, dir.y) * flow_speed
	return fallback


func sample_water_body_id(world_pos: Vector3, fallback: StringName = WaterSurfaceState.WATER_BODY_NONE) -> StringName:
	if water_body_id_query.is_valid():
		var result: Variant = water_body_id_query.call(world_pos)
		if result is StringName:
			return result
		if result is String:
			return StringName(result)
	if sample_coverage(world_pos) > 0.0:
		return body_id
	return fallback


func _bounds_contains_xz(world_pos: Vector3) -> bool:
	return world_pos.x >= bounds.position.x \
		and world_pos.x <= bounds.position.x + bounds.size.x \
		and world_pos.z >= bounds.position.z \
		and world_pos.z <= bounds.position.z + bounds.size.z
