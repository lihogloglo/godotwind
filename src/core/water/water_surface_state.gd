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


func has_fft() -> bool:
	return displacement_texture_rd.is_valid() and cascade_count > 0


func has_shore_mask() -> bool:
	return shore_mask_rd.is_valid()
