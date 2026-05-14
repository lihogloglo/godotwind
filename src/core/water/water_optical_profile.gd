class_name WaterOpticalProfile
extends Resource

const TARGET_TRANSMITTANCE: float = 0.01
const MIN_VISIBILITY_M: float = 0.5
const MAX_VISIBILITY_M: float = 500.0
const DEFAULT_VISIBILITY_M: float = 57.5646
const DEFAULT_EXTINCTION_BIAS := Vector3(1.0, 0.25, 0.15)

@export_range(MIN_VISIBILITY_M, MAX_VISIBILITY_M, 0.1) var visibility_distance_m: float = DEFAULT_VISIBILITY_M
@export var extinction_color_bias: Vector3 = DEFAULT_EXTINCTION_BIAS
@export var absorption_color: Color = Color(0.02, 0.04, 0.06, 1.0)
@export var scattering_color: Color = Color(0.02, 0.04, 0.06, 1.0)
@export_range(0.0, 1.0, 0.01) var scattering_strength: float = 0.0


func duplicate_profile() -> WaterOpticalProfile:
	var copy := WaterOpticalProfile.new()
	copy.visibility_distance_m = visibility_distance_m
	copy.extinction_color_bias = extinction_color_bias
	copy.absorption_color = absorption_color
	copy.scattering_color = scattering_color
	copy.scattering_strength = scattering_strength
	return copy


func set_medium_color(color: Color) -> void:
	absorption_color = color
	scattering_color = color


func get_extinction_sigma() -> Vector3:
	var visibility := clampf(visibility_distance_m, MIN_VISIBILITY_M, MAX_VISIBILITY_M)
	var scalar := -log(TARGET_TRANSMITTANCE) / visibility
	return Vector3(
		maxf(extinction_color_bias.x, 0.0),
		maxf(extinction_color_bias.y, 0.0),
		maxf(extinction_color_bias.z, 0.0)
	) * scalar


func get_medium_color() -> Vector3:
	var t := clampf(scattering_strength, 0.0, 1.0)
	var medium := absorption_color.lerp(scattering_color, t)
	return Vector3(medium.r, medium.g, medium.b)


func get_medium_color_as_color() -> Color:
	var medium := get_medium_color()
	return Color(medium.x, medium.y, medium.z, 1.0)
