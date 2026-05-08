class_name WaterSurfaceState
extends RefCounted

var sea_level: float = 0.0
var wave_scale: float = 1.0
var ocean_time: float = 0.0
var map_scales: PackedVector4Array = PackedVector4Array()
var cascade_count: int = 0
var displacement_texture_rd: RID = RID()

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

var cpu_query_available: bool = false
var cpu_query_source: StringName = &"none"
var cpu_readback_bytes_per_frame: int = 0
var displacement_texture_size: int = 0
var height_query: Callable = Callable()
var displacement_query: Callable = Callable()
var normal_query: Callable = Callable()


func has_fft() -> bool:
	return displacement_texture_rd.is_valid() and cascade_count > 0


func has_shore_mask() -> bool:
	return shore_mask_rd.is_valid()


func can_sample_height() -> bool:
	return cpu_query_available and height_query.is_valid()


func can_sample_displacement() -> bool:
	return cpu_query_available and displacement_query.is_valid()


func can_sample_normal() -> bool:
	return cpu_query_available and normal_query.is_valid()


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
