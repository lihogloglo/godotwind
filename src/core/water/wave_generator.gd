## WaveGenerator - FFT-based ocean wave simulation
## Uses GPU compute shaders to generate displacement and normal maps
## Provides CPU-accessible sampling for buoyancy
class_name WaveGenerator
extends Node

# Wave cascade parameters
const MAX_CASCADES: int = 3
const DEFAULT_MAP_SIZE: int = 128  # Reduced from 256 for better CPU performance

# Cascade configuration (tile_length, scale for each cascade)
var _cascade_params: Array[Dictionary] = [
	{ "tile_length": 250.0, "scale": 1.0 },
	{ "tile_length": 67.0, "scale": 0.5 },
	{ "tile_length": 17.0, "scale": 0.25 }
]

# GPU resources
var _rd: RenderingDevice = null
var _use_compute: bool = false

# Compute shader pipelines
var _spectrum_shader: RID
var _modulate_shader: RID
var _fft_shader: RID
var _butterfly_shader: RID
var _transpose_shader: RID
var _unpack_shader: RID

# Textures and buffers
var _spectrum_texture: RID
var _displacement_texture: RID
var _normal_texture: RID
var _fft_buffer: RID
var _butterfly_buffer: RID

# CPU-accessible data
var _displacement_images: Array[Image] = []
var _normal_images: Array[Image] = []
var _map_size: int = DEFAULT_MAP_SIZE

# Wind parameters
var _wind_speed: float = 10.0
var _wind_direction: float = 0.0

# Timing
var _last_update_time: float = 0.0

# Fallback: Simple Gerstner waves when compute not available
var _use_gerstner_fallback: bool = true

# Pre-computed wave data for optimization
var _wave_data: Array[Dictionary] = []
var _cos_wind: float = 1.0
var _sin_wind: float = 0.0


func initialize(map_size: int = DEFAULT_MAP_SIZE) -> void:
	_map_size = map_size

	# Try to initialize compute shaders
	_rd = RenderingServer.get_rendering_device()
	if _rd:
		_use_compute = _init_compute_pipeline()

	if not _use_compute:
		print("[WaveGenerator] Using Gerstner fallback (map size: %d)" % _map_size)
		_init_fallback()
	else:
		print("[WaveGenerator] Using FFT compute shaders, map size: %d" % _map_size)

	# Initialize CPU-accessible images
	for i in range(MAX_CASCADES):
		var disp_img := Image.create(_map_size, _map_size, false, Image.FORMAT_RGBAF)
		disp_img.fill(Color(0, 0, 0, 0))
		_displacement_images.append(disp_img)

		var norm_img := Image.create(_map_size, _map_size, false, Image.FORMAT_RGBAF)
		norm_img.fill(Color(0, 1, 0, 0))  # Default normal pointing up
		_normal_images.append(norm_img)


func _init_compute_pipeline() -> bool:
	# Check if compute shaders exist
	var spectrum_path := "res://src/core/water/shaders/compute/spectrum_compute.glsl"
	if not FileAccess.file_exists(spectrum_path):
		return false

	# TODO: Full compute shader initialization
	# For now, return false to use Gerstner fallback
	# This will be implemented in Phase 2
	return false


func _init_fallback() -> void:
	_use_gerstner_fallback = true
	_precompute_wave_data()


func _precompute_wave_data() -> void:
	# Pre-compute wave parameters to avoid per-pixel dictionary lookups
	_wave_data.clear()

	var base_waves := [
		{ "wavelength": 60.0, "steepness": 0.25, "direction": Vector2(1.0, 0.0) },
		{ "wavelength": 31.0, "steepness": 0.25, "direction": Vector2(1.0, 0.6).normalized() },
		{ "wavelength": 18.0, "steepness": 0.25, "direction": Vector2(1.0, 1.3).normalized() },
		{ "wavelength": 8.0, "steepness": 0.15, "direction": Vector2(0.5, 1.0).normalized() },
	]

	_cos_wind = cos(_wind_direction)
	_sin_wind = sin(_wind_direction)

	for wave in base_waves:
		var wavelength: float = wave["wavelength"]
		var steepness: float = wave["steepness"]
		var d: Vector2 = wave["direction"]

		var k: float = TAU / wavelength
		var c: float = sqrt(9.81 / k)
		var a: float = steepness / k

		# Pre-rotate direction
		var rotated_d := Vector2(
			d.x * _cos_wind - d.y * _sin_wind,
			d.x * _sin_wind + d.y * _cos_wind
		)

		_wave_data.append({
			"k": k,
			"c": c,
			"a": a,
			"dx": rotated_d.x,
			"dy": rotated_d.y,
		})


func update(time: float) -> void:
	_last_update_time = time

	if _use_compute:
		_update_fft(time)
	else:
		_update_gerstner_optimized(time)


func _update_fft(_time: float) -> void:
	# TODO: Implement FFT pipeline in Phase 2
	pass


func _update_gerstner_optimized(time: float) -> void:
	# Optimized Gerstner wave update
	# - Uses pre-computed wave parameters
	# - Calculates normals from gradient in single pass
	# - Reduced map size and simplified calculations

	var wind_factor := _wind_speed / 10.0
	var eps := 1.0 / float(_map_size)  # Gradient epsilon

	for cascade_idx in range(MAX_CASCADES):
		var params := _cascade_params[cascade_idx]
		var tile_length: float = params["tile_length"]

		var img := _displacement_images[cascade_idx]
		var norm_img := _normal_images[cascade_idx]
		var inv_size := 1.0 / float(_map_size)
		var grad_scale := tile_length * eps

		for y in range(_map_size):
			var v := float(y) * inv_size * tile_length
			for x in range(_map_size):
				var u := float(x) * inv_size * tile_length

				# Calculate displacement and gradient in one pass
				var disp := Vector3.ZERO
				var grad_x := 0.0
				var grad_z := 0.0

				for wd in _wave_data:
					var k: float = wd["k"]
					var c: float = wd["c"]
					var a: float = wd["a"]
					var dx: float = wd["dx"]
					var dy: float = wd["dy"]

					var phase: float = k * (dx * u + dy * v - c * time)
					var cos_p := cos(phase)
					var sin_p := sin(phase)

					disp.x += dx * a * cos_p
					disp.y += a * sin_p
					disp.z += dy * a * cos_p

					# Analytical gradient (derivative of sin is cos)
					var grad_contrib := a * k * cos_p
					grad_x += dx * grad_contrib
					grad_z += dy * grad_contrib

				disp *= wind_factor
				grad_x *= wind_factor
				grad_z *= wind_factor

				# Calculate normal from gradient
				var normal := Vector3(-grad_x, 1.0, -grad_z).normalized()

				img.set_pixel(x, y, Color(disp.x, disp.y, disp.z, 0.0))
				norm_img.set_pixel(x, y, Color(normal.x, normal.y, normal.z, 0.0))


func sample_displacement(world_pos: Vector3) -> Vector3:
	if _displacement_images.is_empty():
		return Vector3.ZERO

	var total_displacement := Vector3.ZERO

	for cascade_idx in range(MAX_CASCADES):
		var params := _cascade_params[cascade_idx]
		var tile_length: float = params["tile_length"]
		var scale: float = params["scale"]

		# Convert world position to UV
		var u := fmod(world_pos.x, tile_length) / tile_length
		var v := fmod(world_pos.z, tile_length) / tile_length
		if u < 0: u += 1.0
		if v < 0: v += 1.0

		# Sample displacement image with bilinear interpolation
		var displacement := _sample_image_bilinear(_displacement_images[cascade_idx], u, v)
		total_displacement += Vector3(displacement.r, displacement.g, displacement.b) * scale

	return total_displacement


func sample_normal(world_pos: Vector3) -> Vector3:
	if _normal_images.is_empty():
		return Vector3.UP

	var total_normal := Vector3.ZERO

	for cascade_idx in range(MAX_CASCADES):
		var params := _cascade_params[cascade_idx]
		var tile_length: float = params["tile_length"]
		var scale: float = params["scale"]

		# Convert world position to UV
		var u := fmod(world_pos.x, tile_length) / tile_length
		var v := fmod(world_pos.z, tile_length) / tile_length
		if u < 0: u += 1.0
		if v < 0: v += 1.0

		# Sample normal image
		var normal_color := _sample_image_bilinear(_normal_images[cascade_idx], u, v)
		total_normal += Vector3(normal_color.r, normal_color.g, normal_color.b) * scale

	return total_normal.normalized() if total_normal.length() > 0.001 else Vector3.UP


func _sample_image_bilinear(img: Image, u: float, v: float) -> Color:
	var size := img.get_size()
	var x := u * (size.x - 1)
	var y := v * (size.y - 1)

	var x0: int = int(floor(x))
	var y0: int = int(floor(y))
	var x1: int = mini(x0 + 1, size.x - 1)
	var y1: int = mini(y0 + 1, size.y - 1)

	var fx := x - x0
	var fy := y - y0

	var c00 := img.get_pixel(x0, y0)
	var c10 := img.get_pixel(x1, y0)
	var c01 := img.get_pixel(x0, y1)
	var c11 := img.get_pixel(x1, y1)

	var c0 := c00.lerp(c10, fx)
	var c1 := c01.lerp(c11, fx)

	return c0.lerp(c1, fy)


func set_wind(speed: float, direction: float) -> void:
	_wind_speed = speed
	_wind_direction = direction
	# Recompute wave data when wind changes
	if _use_gerstner_fallback:
		_precompute_wave_data()


func get_wind_speed() -> float:
	return _wind_speed


func get_wind_direction() -> float:
	return _wind_direction


func get_map_size() -> int:
	return _map_size


func is_using_compute() -> bool:
	return _use_compute


func get_displacement_images() -> Array[Image]:
	return _displacement_images


func get_normal_images() -> Array[Image]:
	return _normal_images


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_cleanup_gpu_resources()


func _cleanup_gpu_resources() -> void:
	if not _rd:
		return

	# Free GPU resources
	if _spectrum_texture.is_valid():
		_rd.free_rid(_spectrum_texture)
	if _displacement_texture.is_valid():
		_rd.free_rid(_displacement_texture)
	if _normal_texture.is_valid():
		_rd.free_rid(_normal_texture)
	if _fft_buffer.is_valid():
		_rd.free_rid(_fft_buffer)
	if _butterfly_buffer.is_valid():
		_rd.free_rid(_butterfly_buffer)
