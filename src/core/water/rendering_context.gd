## RenderingContext - Wrapper around RenderingDevice for compute shader management
## Handles memory management and provides helper functions for compute pipelines
## Based on: https://github.com/2Retr0/GodotOceanWaves (MIT License)
class_name RenderingContext
extends RefCounted


class DeletionQueue:
	var queue: Array[RID] = []

	func push(rid: RID) -> RID:
		queue.push_back(rid)
		return rid

	func flush(device: RenderingDevice) -> void:
		# Work backwards in order of allocation when freeing resources
		for i in range(queue.size() - 1, -1, -1):
			if not queue[i].is_valid():
				continue
			device.free_rid(queue[i])
		queue.clear()


class Descriptor:
	var rid: RID
	var type: RenderingDevice.UniformType

	func _init(rid_: RID, type_: RenderingDevice.UniformType) -> void:
		rid = rid_
		type = type_


var device: RenderingDevice
var deletion_queue := DeletionQueue.new()
var shader_cache: Dictionary
var needs_sync := false


static func create(rd: RenderingDevice = null) -> RenderingContext:
	var context := RenderingContext.new()
	context.device = RenderingServer.create_local_rendering_device() if not rd else rd
	return context


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# All resources must be freed after use to avoid memory leaks
		deletion_queue.flush(device)
		shader_cache.clear()
		if device != RenderingServer.get_rendering_device():
			device.free()


# --- WRAPPER FUNCTIONS ---
func submit() -> void:
	device.submit()
	needs_sync = true


func sync() -> void:
	device.sync()
	needs_sync = false


func compute_list_begin() -> int:
	return device.compute_list_begin()


func compute_list_end() -> void:
	device.compute_list_end()


func compute_list_add_barrier(compute_list: int) -> void:
	device.compute_list_add_barrier(compute_list)


# --- HELPER FUNCTIONS ---
func load_shader(path: String) -> RID:
	if not shader_cache.has(path):
		var shader_file: RDShaderFile = load(path) as RDShaderFile
		if not shader_file:
			push_error("[RenderingContext] Failed to load shader: %s" % path)
			return RID()
		var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
		shader_cache[path] = deletion_queue.push(device.shader_create_from_spirv(shader_spirv))
	return shader_cache[path]


func create_storage_buffer(size: int, data: PackedByteArray = [], usage := 0) -> Descriptor:
	if size > len(data):
		var padding := PackedByteArray()
		padding.resize(size - len(data))
		data += padding
	var buffer_size: int = max(size, len(data))
	return Descriptor.new(
		deletion_queue.push(device.storage_buffer_create(buffer_size, data, usage)),
		RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	)


func create_texture(dimensions: Vector2i, format: RenderingDevice.DataFormat, usage := 0x18B, num_layers := 0, view := RDTextureView.new(), data: PackedByteArray = []) -> Descriptor:
	assert(num_layers >= 1)
	var texture_format := RDTextureFormat.new()
	texture_format.array_layers = 1 if num_layers == 0 else num_layers
	texture_format.format = format
	texture_format.width = dimensions.x
	texture_format.height = dimensions.y
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D if num_layers == 0 else RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	texture_format.usage_bits = usage
	return Descriptor.new(
		deletion_queue.push(device.texture_create(texture_format, view, data)),
		RenderingDevice.UNIFORM_TYPE_IMAGE
	)


## Creates a descriptor set. Ordering matches binding ordering in shader.
func create_descriptor_set(descriptors: Array[Descriptor], shader: RID, descriptor_set_index := 0) -> RID:
	var uniforms: Array[RDUniform]
	for i in range(len(descriptors)):
		var uniform := RDUniform.new()
		uniform.uniform_type = descriptors[i].type
		uniform.binding = i
		uniform.add_id(descriptors[i].rid)
		uniforms.push_back(uniform)
	return deletion_queue.push(device.uniform_set_create(uniforms, shader, descriptor_set_index))


## Returns a Callable which dispatches a compute pipeline within a compute list
func create_pipeline(block_dimensions: Array, descriptor_sets: Array, shader: RID) -> Callable:
	var pipeline := deletion_queue.push(device.compute_pipeline_create(shader))
	return func(context: RenderingContext, compute_list: int, push_constant: PackedByteArray = []) -> void:
		var dev := context.device
		dev.compute_list_bind_compute_pipeline(compute_list, pipeline)
		if push_constant.size() > 0:
			dev.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
		for i in range(len(descriptor_sets)):
			var desc_set: RID = descriptor_sets[i]
			dev.compute_list_bind_uniform_set(compute_list, desc_set, i)
		var dim_x: int = block_dimensions[0]
		var dim_y: int = block_dimensions[1]
		var dim_z: int = block_dimensions[2]
		dev.compute_list_dispatch(compute_list, dim_x, dim_y, dim_z)


## Returns a PackedByteArray from the provided data, size rounded to nearest multiple of 16
static func create_push_constant(data: Array) -> PackedByteArray:
	var packed_size := len(data) * 4
	assert(packed_size <= 128, "Push constant size must be at most 128 bytes!")

	var padding := ceili(packed_size / 16.0) * 16 - packed_size
	var packed_data := PackedByteArray()
	packed_data.resize(packed_size + (padding if padding > 0 else 0))
	packed_data.fill(0)

	for i in range(len(data)):
		match typeof(data[i]):
			TYPE_INT, TYPE_BOOL:
				var int_val: int = data[i]
				packed_data.encode_s32(i * 4, int_val)
			TYPE_FLOAT:
				var float_val: float = data[i]
				packed_data.encode_float(i * 4, float_val)
	return packed_data
