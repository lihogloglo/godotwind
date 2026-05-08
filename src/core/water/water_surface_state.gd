class_name WaterSurfaceState
extends RefCounted

const WATER_BODY_NONE := &"none"
const WATER_BODY_OCEAN := &"ocean"
const SHORE_SIDE_LAND := -1
const SHORE_SIDE_UNKNOWN := 0
const SHORE_SIDE_WATER := 1

var sea_level: float = 0.0
var wave_scale: float = 1.0
var ocean_time: float = 0.0
var map_scales: PackedVector4Array = PackedVector4Array()
var cascade_count: int = 0
var displacement_texture_rd: RID = RID()
var normal_texture_rd: RID = RID()

var water_body_id: StringName = WATER_BODY_NONE
var water_body_index: int = 0
var coverage_source: StringName = &"none"
var coverage_available: bool = false

var shore_mask_texture: Texture2D = null
var shore_mask_rd: RID = RID()
var shore_mask_bounds: Vector4 = Vector4(-8000.0, -8000.0, 16000.0, 16000.0)
var shore_fade_distance: float = 50.0
var shore_wave_amplitude: float = 0.18
var shore_wave_frequency: float = 0.1
var shore_wave_speed: float = 0.4
var shore_wave_steepness: float = 0.58

var absorption_tint: Vector3 = Vector3(0.02, 0.04, 0.06)
var absorption_sigma: Vector3 = Vector3(0.08, 0.02, 0.012)
var absorption_depth_falloff: float = 20.0
var underwater_caustics_strength: float = 1.0

var snapshot_frame_id: int = -1
var surface_data_frame_id: int = -1
var readback_frame_id: int = -1
var gpu_cascade_ready_mask: int = 0
var cpu_cascade_ready_mask: int = 0
var fft_ready: bool = false
var normal_data_ready: bool = false
var readback_ready: bool = false

var cpu_query_available: bool = false
var cpu_query_source: StringName = &"none"
var cpu_readback_bytes_per_frame: int = 0
var displacement_texture_size: int = 0
var height_query: Callable = Callable()
var displacement_query: Callable = Callable()
var normal_query: Callable = Callable()
var gradient_query: Callable = Callable()
var velocity_query: Callable = Callable()
var coverage_query: Callable = Callable()
var signed_shore_distance_query: Callable = Callable()
var shore_side_query: Callable = Callable()
var water_body_id_query: Callable = Callable()


func has_fft() -> bool:
	return fft_ready and displacement_texture_rd.is_valid() and cascade_count > 0


func has_shore_mask() -> bool:
	return shore_mask_rd.is_valid()


func has_normal_data() -> bool:
	return normal_data_ready and normal_texture_rd.is_valid()


func gpu_cascade_ready(index: int) -> bool:
	if index < 0 or index >= cascade_count:
		return false
	return (gpu_cascade_ready_mask & (1 << index)) != 0


func cpu_cascade_ready(index: int) -> bool:
	if index < 0 or index >= cascade_count:
		return false
	return (cpu_cascade_ready_mask & (1 << index)) != 0


func is_fresh_for_frame(frame_id: int) -> bool:
	return surface_data_frame_id == frame_id


func can_sample_height() -> bool:
	return cpu_query_available and height_query.is_valid()


func can_sample_displacement() -> bool:
	return cpu_query_available and displacement_query.is_valid()


func can_sample_normal() -> bool:
	return cpu_query_available and normal_query.is_valid()


func can_sample_gradient() -> bool:
	return cpu_query_available and gradient_query.is_valid()


func can_sample_velocity() -> bool:
	return cpu_query_available and velocity_query.is_valid()


func can_sample_coverage() -> bool:
	return coverage_available and coverage_query.is_valid()


func can_sample_signed_shore_distance() -> bool:
	return coverage_available and signed_shore_distance_query.is_valid()


func can_sample_shore_side() -> bool:
	return coverage_available and shore_side_query.is_valid()


func can_sample_water_body_id() -> bool:
	return coverage_available and water_body_id_query.is_valid()


func sample_height(world_pos: Vector3, fallback: float = 0.0) -> float:
	if can_sample_height():
		return float(height_query.call(world_pos))
	return fallback


func sample_displacement(world_pos: Vector3, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if can_sample_displacement():
		var result: Variant = displacement_query.call(world_pos)
		if result is Vector3:
			return result
	return fallback


func sample_normal(world_pos: Vector3, fallback: Vector3 = Vector3.UP) -> Vector3:
	if can_sample_normal():
		var result: Variant = normal_query.call(world_pos)
		if result is Vector3:
			return result
	return fallback


func sample_gradient(world_pos: Vector3, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if can_sample_gradient():
		var result: Variant = gradient_query.call(world_pos)
		if result is Vector2:
			return result
	return fallback


func sample_velocity(world_pos: Vector3, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if can_sample_velocity():
		var result: Variant = velocity_query.call(world_pos)
		if result is Vector3:
			return result
	return fallback


func sample_coverage(world_pos: Vector3, fallback: float = 0.0) -> float:
	if can_sample_coverage():
		return float(coverage_query.call(world_pos))
	return fallback


func sample_signed_shore_distance(world_pos: Vector3, fallback: float = 0.0) -> float:
	if can_sample_signed_shore_distance():
		return float(signed_shore_distance_query.call(world_pos))
	return fallback


func sample_shore_side(world_pos: Vector3, fallback: int = SHORE_SIDE_UNKNOWN) -> int:
	if can_sample_shore_side():
		return int(shore_side_query.call(world_pos))
	return fallback


func sample_water_body_id(world_pos: Vector3, fallback: StringName = WATER_BODY_NONE) -> StringName:
	if can_sample_water_body_id():
		var result: Variant = water_body_id_query.call(world_pos)
		if result is StringName:
			return result
		if result is String:
			return StringName(result)
	return fallback
