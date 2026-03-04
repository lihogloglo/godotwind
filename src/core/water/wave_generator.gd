## WaveGenerator — FFT compute pipeline for ocean wave generation
## Handles JONSWAP spectrum computation, Stockham FFT, and displacement/normal map output.
## Load-balances cascade updates (1 per frame) to avoid GPU stutter.
## Ported from GodotOceanWaves with Godotwind conventions.
class_name WaveGenerator
extends Node

const G := 9.81
const DEPTH := 20.0

## Shader base path — relative to res://
const SHADER_PATH := "res://src/core/water/shaders/compute/"

var map_size: int
var context: RenderingContext
var pipelines: Dictionary
var descriptors: Dictionary
var _allocated_cascades: int = 0

# Generator state per invocation of update()
var pass_parameters: Array[WaveCascadeParameters]
var pass_num_cascades_remaining: int


func init_gpu(num_cascades: int) -> void:
	if not context:
		context = RenderingContext.create(RenderingServer.get_rendering_device())

	# Load compute shaders
	var spectrum_compute_shader := context.load_shader(SHADER_PATH + "spectrum_compute.glsl")
	var fft_butterfly_shader := context.load_shader(SHADER_PATH + "fft_butterfly.glsl")
	var spectrum_modulate_shader := context.load_shader(SHADER_PATH + "spectrum_modulate.glsl")
	var fft_compute_shader := context.load_shader(SHADER_PATH + "fft_compute.glsl")
	var transpose_shader := context.load_shader(SHADER_PATH + "transpose.glsl")
	var fft_unpack_shader := context.load_shader(SHADER_PATH + "fft_unpack.glsl")

	# Create GPU resources
	var dims := Vector2i(map_size, map_size)
	var num_fft_stages := int(log(map_size) / log(2))

	descriptors[&"spectrum"] = context.create_texture(
		dims, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		num_cascades
	)
	descriptors[&"butterfly_factors"] = context.create_storage_buffer(
		num_fft_stages * map_size * 4 * 4  # log2(map_size) * map_size * sizeof(vec4)
	)
	descriptors[&"fft_buffer"] = context.create_storage_buffer(
		num_cascades * map_size * map_size * 4 * 2 * 2 * 4  # cascades * size^2 * 4 FFTs * 2 buffers * sizeof(vec2)
	)
	descriptors[&"displacement_map"] = context.create_texture(
		dims, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		num_cascades
	)
	descriptors[&"normal_map"] = context.create_texture(
		dims, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		num_cascades
	)

	# Create descriptor sets
	# Spectrum needs two sets: writable for compute, readonly for modulate (Godot 4.6 validates access)
	var spectrum_write_set := context.create_descriptor_set([descriptors[&"spectrum"]], spectrum_compute_shader, 0)
	var spectrum_read_set := context.create_descriptor_set([descriptors[&"spectrum"]], spectrum_modulate_shader, 0)
	var fft_butterfly_set := context.create_descriptor_set([descriptors[&"butterfly_factors"]], fft_butterfly_shader, 0)
	var fft_compute_set := context.create_descriptor_set([descriptors[&"butterfly_factors"], descriptors[&"fft_buffer"]], fft_compute_shader, 0)
	var fft_buffer_modulate_set := context.create_descriptor_set([descriptors[&"fft_buffer"]], spectrum_modulate_shader, 1)
	var fft_buffer_unpack_set := context.create_descriptor_set([descriptors[&"fft_buffer"]], fft_unpack_shader, 1)
	var unpack_set := context.create_descriptor_set([descriptors[&"displacement_map"], descriptors[&"normal_map"]], fft_unpack_shader, 0)

	# Create compute pipelines
	pipelines[&"spectrum_compute"] = context.create_pipeline([map_size / 16, map_size / 16, 1], [spectrum_write_set], spectrum_compute_shader)
	pipelines[&"spectrum_modulate"] = context.create_pipeline([map_size / 16, map_size / 16, 1], [spectrum_read_set, fft_buffer_modulate_set], spectrum_modulate_shader)
	pipelines[&"fft_butterfly"] = context.create_pipeline([map_size / 2 / 64, int(log(map_size) / log(2)), 1], [fft_butterfly_set], fft_butterfly_shader)
	pipelines[&"fft_compute"] = context.create_pipeline([1, map_size, 4], [fft_compute_set], fft_compute_shader)
	pipelines[&"transpose"] = context.create_pipeline([map_size / 32, map_size / 32, 4], [fft_compute_set], transpose_shader)
	pipelines[&"fft_unpack"] = context.create_pipeline([map_size / 16, map_size / 16, 1], [unpack_set, fft_buffer_unpack_set], fft_unpack_shader)

	# Precompute butterfly factors (only once per map_size)
	var compute_list := context.compute_list_begin()
	pipelines[&"fft_butterfly"].call(context, compute_list)
	context.compute_list_end()

	_allocated_cascades = num_cascades
	Log.info("water", "WaveGenerator: GPU initialized - map_size: %d, cascades: %d" % [map_size, num_cascades])


func _process(_delta: float) -> void:
	# Update one cascade each frame for load balancing
	if pass_num_cascades_remaining == 0:
		return
	pass_num_cascades_remaining -= 1

	var compute_list := context.compute_list_begin()
	_update(compute_list, pass_num_cascades_remaining, pass_parameters)
	context.compute_list_end()


func _update(compute_list: int, cascade_index: int, parameters: Array[WaveCascadeParameters]) -> void:
	var params := parameters[cascade_index]

	# Spectrum generation (only when parameters change)
	if params.should_generate_spectrum:
		var alpha := JONSWAP_alpha(params.wind_speed, params.fetch_length * 1e3)
		var omega := JONSWAP_peak_angular_frequency(params.wind_speed, params.fetch_length * 1e3)
		pipelines[&"spectrum_compute"].call(context, compute_list,
			RenderingContext.create_push_constant([
				params.spectrum_seed.x, params.spectrum_seed.y,
				params.tile_length.x, params.tile_length.y,
				alpha, omega, params.wind_speed, deg_to_rad(params.wind_direction),
				DEPTH, params.swell, params.detail, params.spread, cascade_index
			]))
		params.should_generate_spectrum = false

	# Time-domain modulation
	pipelines[&"spectrum_modulate"].call(context, compute_list,
		RenderingContext.create_push_constant([
			params.tile_length.x, params.tile_length.y, DEPTH, params.time, cascade_index
		]))

	# Inverse FFT (row-wise, transpose, column-wise)
	var fft_push_constant := RenderingContext.create_push_constant([cascade_index])
	pipelines[&"fft_compute"].call(context, compute_list, fft_push_constant)
	pipelines[&"transpose"].call(context, compute_list, fft_push_constant)
	context.compute_list_add_barrier(compute_list)  # Required: transpose→fft dependency
	pipelines[&"fft_compute"].call(context, compute_list, fft_push_constant)
	context.compute_list_add_barrier(compute_list)  # Required: fft→unpack dependency

	# Unpack to displacement/normal maps
	pipelines[&"fft_unpack"].call(context, compute_list,
		RenderingContext.create_push_constant([
			cascade_index, params.whitecap, params.foam_grow_rate, params.foam_decay_rate
		]))


## Begin updating wave cascades. Load-balanced: schedules 1 cascade per frame.
## Any unprocessed cascades from the previous invocation are flushed first.
func update(delta: float, parameters: Array[WaveCascadeParameters]) -> void:
	assert(parameters.size() != 0, "Must provide at least one cascade parameter set")
	assert(not context or parameters.size() <= _allocated_cascades,
		"Cannot update more cascades (%d) than allocated (%d)" % [parameters.size(), _allocated_cascades])
	if not context:
		init_gpu(maxi(2, len(parameters)))
	elif pass_num_cascades_remaining != 0:
		# Flush unprocessed cascades from previous invocation
		var compute_list := context.compute_list_begin()
		for i in range(pass_num_cascades_remaining):
			_update(compute_list, i, pass_parameters)
		context.compute_list_end()

	# Update time-dependent parameters
	for i in len(parameters):
		var params := parameters[i]
		params.time += delta
		params.foam_grow_rate = delta * params.foam_amount * 7.5
		params.foam_decay_rate = delta * maxf(0.5, 10.0 - params.foam_amount) * 1.15

	pass_parameters = parameters
	pass_num_cascades_remaining = len(parameters)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if context:
			context.free()


# JONSWAP spectrum alpha parameter
# Source: https://wikiwaves.org/Ocean-Wave_Spectra#JONSWAP_Spectrum
static func JONSWAP_alpha(wind_speed := 20.0, fetch_length := 550e3) -> float:
	return 0.076 * pow(wind_speed ** 2 / (fetch_length * G), 0.22)


# JONSWAP peak angular frequency
# Source: https://wikiwaves.org/Ocean-Wave_Spectra#JONSWAP_Spectrum
static func JONSWAP_peak_angular_frequency(wind_speed := 20.0, fetch_length := 550e3) -> float:
	return 22.0 * pow(G * G / (wind_speed * fetch_length), 1.0 / 3.0)
