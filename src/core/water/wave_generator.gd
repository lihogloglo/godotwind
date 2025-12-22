## WaveGenerator - GPU compute shader-based ocean wave simulation
## Uses FFT for realistic wave generation on capable hardware
## Falls back to flat plane for systems without compute shader support
## Based on: https://github.com/2Retr0/GodotOceanWaves (MIT License)
class_name WaveGenerator
extends Node

const G := 9.81
const DEPTH := 20.0
const MAX_CASCADES := 8

var map_size: int = 256
var context: RenderingContext = null
var pipelines: Dictionary = {}
var descriptors: Dictionary = {}

# Generator state per invocation of update()
var pass_parameters: Array[WaveCascadeParameters] = []
var pass_num_cascades_remaining: int = 0

# Whether GPU compute is available
var _use_compute: bool = false
var _initialized: bool = false

# Displacement/normal textures for shader use (GPU mode)
var displacement_maps := Texture2DArrayRD.new()
var normal_maps := Texture2DArrayRD.new()


func initialize(size: int = 256) -> void:
	map_size = size

	# Check if compute shaders are available
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		print("[WaveGenerator] No RenderingDevice available - using flat plane fallback")
		_use_compute = false
		return

	# Check if compute shader files exist
	var shader_path := "res://src/core/water/shaders/compute/spectrum_compute.glsl"
	if not FileAccess.file_exists(shader_path):
		print("[WaveGenerator] Compute shaders not found - using flat plane fallback")
		_use_compute = false
		return

	_use_compute = true
	print("[WaveGenerator] GPU compute shaders available, map size: %d" % map_size)


func init_gpu(num_cascades: int) -> void:
	if not _use_compute or _initialized:
		return

	# Create rendering context using the main rendering device
	if not context:
		context = RenderingContext.create(RenderingServer.get_rendering_device())

	# Load compute shaders
	var spectrum_compute_shader := context.load_shader("res://src/core/water/shaders/compute/spectrum_compute.glsl")
	var fft_butterfly_shader := context.load_shader("res://src/core/water/shaders/compute/fft_butterfly.glsl")
	var spectrum_modulate_shader := context.load_shader("res://src/core/water/shaders/compute/spectrum_modulate.glsl")
	var fft_compute_shader := context.load_shader("res://src/core/water/shaders/compute/fft_compute.glsl")
	var transpose_shader := context.load_shader("res://src/core/water/shaders/compute/transpose.glsl")
	var fft_unpack_shader := context.load_shader("res://src/core/water/shaders/compute/fft_unpack.glsl")

	# Verify shaders loaded
	if not spectrum_compute_shader.is_valid():
		push_error("[WaveGenerator] Failed to load compute shaders - falling back to flat plane")
		_use_compute = false
		return

	# Descriptor preparation
	var dims := Vector2i(map_size, map_size)
	var num_fft_stages := int(log(map_size) / log(2))

	# Create GPU resources
	descriptors[&"spectrum"] = context.create_texture(
		dims,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		num_cascades
	)

	descriptors[&"butterfly_factors"] = context.create_storage_buffer(
		num_fft_stages * map_size * 4 * 4  # #FFT stages * map size * sizeof(vec4)
	)

	descriptors[&"fft_buffer"] = context.create_storage_buffer(
		num_cascades * map_size * map_size * 4 * 2 * 2 * 4  # map_size^2 * 4 FFTs * 2 temp buffers * sizeof(vec2)
	)

	descriptors[&"displacement_map"] = context.create_texture(
		dims,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		num_cascades
	)

	descriptors[&"normal_map"] = context.create_texture(
		dims,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		num_cascades
	)

	# Create descriptor sets
	# Note: Each shader needs its own descriptor set validated against that shader's bindings
	var spectrum_compute_set := context.create_descriptor_set(
		[descriptors[&"spectrum"]], spectrum_compute_shader, 0
	)
	# spectrum_modulate expects readonly image at set 0 - create separate descriptor set
	var spectrum_modulate_set := context.create_descriptor_set(
		[descriptors[&"spectrum"]], spectrum_modulate_shader, 0
	)
	var fft_butterfly_set := context.create_descriptor_set(
		[descriptors[&"butterfly_factors"]], fft_butterfly_shader, 0
	)
	var fft_compute_set := context.create_descriptor_set(
		[descriptors[&"butterfly_factors"], descriptors[&"fft_buffer"]], fft_compute_shader, 0
	)
	var fft_buffer_set := context.create_descriptor_set(
		[descriptors[&"fft_buffer"]], spectrum_modulate_shader, 1
	)
	var unpack_set := context.create_descriptor_set(
		[descriptors[&"displacement_map"], descriptors[&"normal_map"]], fft_unpack_shader, 0
	)

	# Create compute pipelines
	pipelines[&"spectrum_compute"] = context.create_pipeline(
		[map_size / 16, map_size / 16, 1], [spectrum_compute_set], spectrum_compute_shader
	)
	pipelines[&"spectrum_modulate"] = context.create_pipeline(
		[map_size / 16, map_size / 16, 1], [spectrum_modulate_set, fft_buffer_set], spectrum_modulate_shader
	)
	pipelines[&"fft_butterfly"] = context.create_pipeline(
		[map_size / 2 / 64, num_fft_stages, 1], [fft_butterfly_set], fft_butterfly_shader
	)
	pipelines[&"fft_compute"] = context.create_pipeline(
		[1, map_size, 4], [fft_compute_set], fft_compute_shader
	)
	pipelines[&"transpose"] = context.create_pipeline(
		[map_size / 32, map_size / 32, 4], [fft_compute_set], transpose_shader
	)
	pipelines[&"fft_unpack"] = context.create_pipeline(
		[map_size / 16, map_size / 16, 1], [unpack_set, fft_buffer_set], fft_unpack_shader
	)

	# Generate butterfly factors once
	var compute_list := context.compute_list_begin()
	pipelines[&"fft_butterfly"].call(context, compute_list)
	context.compute_list_end()

	# Setup texture references for shader use
	displacement_maps.texture_rd_rid = descriptors[&"displacement_map"].rid
	normal_maps.texture_rd_rid = descriptors[&"normal_map"].rid

	_initialized = true
	print("[WaveGenerator] GPU compute initialized with %d cascades" % num_cascades)


func _process(_delta: float) -> void:
	if not _use_compute or not context:
		return

	# Update one cascade each frame for load balancing
	if pass_num_cascades_remaining == 0:
		return
	pass_num_cascades_remaining -= 1

	var compute_list := context.compute_list_begin()
	_update_cascade(compute_list, pass_num_cascades_remaining, pass_parameters)
	context.compute_list_end()


func _update_cascade(compute_list: int, cascade_index: int, parameters: Array[WaveCascadeParameters]) -> void:
	var params := parameters[cascade_index]

	# Wave spectra update
	if params.should_generate_spectrum:
		var alpha := _jonswap_alpha(params.wind_speed, params.fetch_length * 1e3)
		var omega := _jonswap_peak_angular_frequency(params.wind_speed, params.fetch_length * 1e3)
		pipelines[&"spectrum_compute"].call(context, compute_list, RenderingContext.create_push_constant([
			params.spectrum_seed.x, params.spectrum_seed.y,
			params.tile_length.x, params.tile_length.y,
			alpha, omega, params.wind_speed, deg_to_rad(params.wind_direction),
			DEPTH, params.swell, params.detail, params.spread, cascade_index
		]))
		params.should_generate_spectrum = false

	pipelines[&"spectrum_modulate"].call(context, compute_list, RenderingContext.create_push_constant([
		params.tile_length.x, params.tile_length.y, DEPTH, params.time, cascade_index
	]))

	# Wave spectra inverse Fourier transform
	var fft_push_constant := RenderingContext.create_push_constant([cascade_index])
	pipelines[&"fft_compute"].call(context, compute_list, fft_push_constant)
	pipelines[&"transpose"].call(context, compute_list, fft_push_constant)
	context.compute_list_add_barrier(compute_list)
	pipelines[&"fft_compute"].call(context, compute_list, fft_push_constant)

	# Displacement/normal map update
	pipelines[&"fft_unpack"].call(context, compute_list, RenderingContext.create_push_constant([
		cascade_index, params.whitecap, params.foam_grow_rate, params.foam_decay_rate
	]))


## Begins updating wave cascades. Updates one cascade per frame for load balancing.
func update(delta: float, parameters: Array[WaveCascadeParameters]) -> void:
	if not _use_compute:
		return

	assert(parameters.size() != 0)

	if not _initialized:
		init_gpu(maxi(2, len(parameters)))
		if not _initialized:
			return  # Failed to initialize

	if pass_num_cascades_remaining != 0:
		# Update remaining cascades from previous invocation
		var compute_list := context.compute_list_begin()
		for i in range(pass_num_cascades_remaining):
			_update_cascade(compute_list, i, pass_parameters)
		context.compute_list_end()

	# Update time-dependent parameters
	for i in len(parameters):
		var params := parameters[i]
		params.time += delta
		params.foam_grow_rate = delta * params.foam_amount * 7.5
		params.foam_decay_rate = delta * maxf(0.5, 10.0 - params.foam_amount) * 1.15

	pass_parameters = parameters
	pass_num_cascades_remaining = len(parameters)


## Legacy update method for compatibility
func update_time(time: float) -> void:
	# For flat plane fallback, nothing to do
	pass


## Sample wave displacement at world position (for buoyancy)
## Returns Vector3.ZERO for flat plane fallback
func sample_displacement(_world_pos: Vector3) -> Vector3:
	# For GPU compute, displacement is done entirely in shader
	# CPU sampling would require readback which is expensive
	# Return zero - buoyancy will use sea_level directly
	return Vector3.ZERO


## Sample wave normal at world position
func sample_normal(_world_pos: Vector3) -> Vector3:
	return Vector3.UP


func set_wind(_speed: float, _direction: float) -> void:
	# For GPU compute, wind is set per-cascade via WaveCascadeParameters
	pass


func is_using_compute() -> bool:
	return _use_compute


func is_initialized() -> bool:
	return _initialized


func get_map_size() -> int:
	return map_size


func get_displacement_texture() -> Texture2DArrayRD:
	return displacement_maps


func get_normal_texture() -> Texture2DArrayRD:
	return normal_maps


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		displacement_maps.texture_rd_rid = RID()
		normal_maps.texture_rd_rid = RID()
		context = null  # RefCounted will clean up


# JONSWAP spectrum calculations
# Source: https://wikiwaves.org/Ocean-Wave_Spectra#JONSWAP_Spectrum
static func _jonswap_alpha(wind_speed := 20.0, fetch_length := 550e3) -> float:
	return 0.076 * pow(wind_speed ** 2 / (fetch_length * G), 0.22)


static func _jonswap_peak_angular_frequency(wind_speed := 20.0, fetch_length := 550e3) -> float:
	return 22.0 * pow(G * G / (wind_speed * fetch_length), 1.0 / 3.0)
