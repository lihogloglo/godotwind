## VectorMapGenerator - GPU compute shader for animated water flow/height map
##
## Generates a dynamic vector map texture used by the Gerstner water shader.
## The vector map contains:
## - R,G channels: Flow direction (used for foam/bubble animation)
## - B channel: Height data (used for wave displacement and foam masking)
##
## Based on Godot-Water-Shader-Prototype-4.4 by OKiN
## Ported to work with world_vertex_coords clipmap mesh

class_name VectorMapGenerator
extends RefCounted

# Texture size (must be power of 2)
const TEXTURE_SIZE: int = 1024

# Double-buffered textures for ping-pong rendering
var _texture_rds: Array[RID] = [RID(), RID()]
var _texture_sets_samplers: Array[RID] = [RID(), RID()]
var _texture_sets_images: Array[RID] = [RID(), RID()]
var _flow_texture_set: RID

# Compute resources
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _sampler: RID

# Output texture (Texture2DRD that can be used in spatial shaders)
var _output_texture: Texture2DRD

# Current buffer index (for ping-pong)
var _current_buffer: int = 0

# Elapsed time
var _time: float = 0.0

# Shader parameters (matching original defaults)
var forward_offset: float = 1.5
var forward_fadeoff: float = 0.001
var flow_strength: float = 1.0
var flow_randomize: float = 0.2
var flow_random_speed: float = 0.5
var blur_strength: float = 0.02
var blur_offset: float = 1.0
var curl_strength: float = 0.6
var curl_offset: float = 7.0
var shift_vector: Vector2 = Vector2(0.01, 0.05)
var shift_speed: float = 1.0

# Initialization state
var _initialized: bool = false


func _init() -> void:
	_output_texture = Texture2DRD.new()


## Initialize the compute shader pipeline
## flow_texture: Source flow texture (RGB where B=flow strength)
func initialize(flow_texture: Texture2D) -> bool:
	if _initialized:
		return true

	# Get rendering device
	_rd = RenderingServer.get_rendering_device()
	if not _rd:
		push_error("[VectorMapGenerator] Failed to get rendering device")
		return false

	# Load and compile shader
	var shader_file := load("res://src/core/water/shaders/vector_map.glsl") as RDShaderFile
	if not shader_file:
		push_error("[VectorMapGenerator] Failed to load vector_map.glsl")
		return false

	var shader_spirv := shader_file.get_spirv()
	if not shader_spirv:
		push_error("[VectorMapGenerator] Failed to get SPIR-V from shader file")
		return false

	_shader = _rd.shader_create_from_spirv(shader_spirv)
	if not _shader.is_valid():
		push_error("[VectorMapGenerator] Failed to create shader")
		return false

	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		push_error("[VectorMapGenerator] Failed to create compute pipeline")
		_rd.free_rid(_shader)
		return false

	# Create sampler
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_sampler = _rd.sampler_create(sampler_state)

	# Create flow texture uniform set
	if flow_texture:
		var flow_rd_rid := RenderingServer.texture_get_rd_texture(flow_texture.get_rid())
		if flow_rd_rid.is_valid():
			_flow_texture_set = _create_sampler_uniform_set(flow_rd_rid, 2)
		else:
			push_warning("[VectorMapGenerator] Flow texture RID invalid, using fallback")
			_flow_texture_set = _create_fallback_flow_texture_set()
	else:
		push_warning("[VectorMapGenerator] No flow texture provided, using fallback")
		_flow_texture_set = _create_fallback_flow_texture_set()

	# Create double-buffered textures
	var tf := RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.width = TEXTURE_SIZE
	tf.height = TEXTURE_SIZE
	tf.depth = 1
	tf.array_layers = 1
	tf.mipmaps = 1
	tf.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT |
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)

	for i in 2:
		_texture_rds[i] = _rd.texture_create(tf, RDTextureView.new(), [])
		# Initialize with neutral flow (0.5, 0.5) and zero height
		# sRGB equivalent to (0.5, 0.5, 0.0, 1.0) in linear space
		_rd.texture_clear(_texture_rds[i], Color(0.735, 0.735, 0.0, 1.0), 0, 1, 0, 1)

		_texture_sets_samplers[i] = _create_sampler_uniform_set(_texture_rds[i], 0)
		_texture_sets_images[i] = _create_image_uniform_set(_texture_rds[i], 1)

	# Set initial output texture
	_output_texture.texture_rd_rid = _texture_rds[0]

	_initialized = true
	print("[VectorMapGenerator] Initialized with %dx%d texture" % [TEXTURE_SIZE, TEXTURE_SIZE])
	return true


func _create_fallback_flow_texture_set() -> RID:
	## Create a fallback flow texture when none is provided
	## Creates a simple neutral flow texture
	var tf := RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.width = 256
	tf.height = 256
	tf.depth = 1
	tf.array_layers = 1
	tf.mipmaps = 1
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT

	var fallback_tex := _rd.texture_create(tf, RDTextureView.new(), [])
	# Fill with neutral gray (0.5, 0.5, 0.5, 1.0)
	_rd.texture_clear(fallback_tex, Color(0.5, 0.5, 0.5, 1.0), 0, 1, 0, 1)

	return _create_sampler_uniform_set(fallback_tex, 2)


func _create_sampler_uniform_set(texture_rd: RID, uniform_set: int) -> RID:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = 0
	uniform.add_id(_sampler)
	uniform.add_id(texture_rd)
	return _rd.uniform_set_create([uniform], _shader, uniform_set)


func _create_image_uniform_set(texture_rd: RID, uniform_set: int) -> RID:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(texture_rd)
	return _rd.uniform_set_create([uniform], _shader, uniform_set)


## Update the vector map (call once per frame)
func update(delta: float) -> void:
	if not _initialized:
		return

	_time += delta

	# Swap buffers (ping-pong)
	var read_buffer := _current_buffer
	var write_buffer := (_current_buffer + 1) % 2
	_current_buffer = write_buffer

	# Update output texture RID
	_output_texture.texture_rd_rid = _texture_rds[write_buffer]

	# Run compute shader on render thread
	RenderingServer.call_on_render_thread(_dispatch_compute.bind(read_buffer, write_buffer))


func _dispatch_compute(read_buffer: int, write_buffer: int) -> void:
	# Build push constants
	var push_constant := PackedFloat32Array([
		forward_offset,
		forward_fadeoff,
		flow_strength,
		flow_randomize,
		flow_random_speed,
		blur_strength,
		blur_offset,
		curl_strength,
		curl_offset,
		shift_vector.x,
		shift_vector.y,
		shift_speed,
		_time,
		0.0,  # padding
		0.0,  # padding
		0.0   # padding
	])

	# Calculate dispatch groups
	@warning_ignore("integer_division")
	var x_groups: int = (TEXTURE_SIZE - 1) / 8 + 1
	@warning_ignore("integer_division")
	var y_groups: int = (TEXTURE_SIZE - 1) / 8 + 1

	var read_set := _texture_sets_samplers[read_buffer]
	var write_set := _texture_sets_images[write_buffer]

	# Dispatch compute shader
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, read_set, 0)
	_rd.compute_list_bind_uniform_set(compute_list, write_set, 1)
	_rd.compute_list_bind_uniform_set(compute_list, _flow_texture_set, 2)
	_rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
	_rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
	_rd.compute_list_end()


## Get the output texture (Texture2DRD) for use in shaders
func get_texture() -> Texture2DRD:
	return _output_texture


## Check if generator is initialized
func is_initialized() -> bool:
	return _initialized


## Clean up GPU resources
func cleanup() -> void:
	if not _initialized:
		return

	# Clear texture RID from output to prevent dangling reference
	if _output_texture:
		_output_texture.texture_rd_rid = RID()

	# Free GPU resources on render thread
	RenderingServer.call_on_render_thread(_free_resources)
	_initialized = false


func _free_resources() -> void:
	for i in 2:
		if _texture_rds[i].is_valid():
			_rd.free_rid(_texture_rds[i])
		_texture_rds[i] = RID()

	if _shader.is_valid():
		_rd.free_rid(_shader)
		_shader = RID()

	if _sampler.is_valid():
		_rd.free_rid(_sampler)
		_sampler = RID()

	# Pipeline and uniform sets are cleaned up automatically as dependencies
