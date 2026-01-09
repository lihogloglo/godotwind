## PostProcessEffect - Base class for hot-swappable post-processing effects
##
## Extends CompositorEffect to provide a unified interface for all post-processing
## effects in Godotwind. Supports runtime enable/disable, parameter tweaking,
## and smooth transitions between effects.
##
## Usage:
## [codeblock]
## class_name MyEffect extends PostProcessEffect
##
## func _init() -> void:
##     effect_name = "my_effect"
##     effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
##
## func _render_callback(effect_type: int, render_data: RenderData) -> void:
##     # Your rendering code here
## [/codeblock]
@tool
class_name PostProcessEffect
extends CompositorEffect

## Unique identifier for this effect
@export var effect_name: String = "unnamed_effect"

## Display name shown in UI
@export var display_name: String = "Unnamed Effect"

## Description of what this effect does
@export_multiline var description: String = ""

## Category for UI organization (e.g., "Atmosphere", "Color", "Artistic")
@export var category: String = "General"

## Whether this effect is currently enabled
@export var effect_enabled: bool = true:
	set(value):
		effect_enabled = value
		enabled = value  # CompositorEffect's built-in enabled property

## Blend factor for smooth transitions (0.0 = off, 1.0 = full)
@export_range(0.0, 1.0) var blend_factor: float = 1.0

## Render priority (lower = earlier in pipeline)
@export var render_priority: int = 0

## Whether this effect needs depth buffer access
var needs_depth: bool = false

## Whether this effect needs normal buffer access
var needs_normals: bool = false

## Parameters that can be tweaked at runtime
## Key: parameter name, Value: Dictionary with "value", "min", "max", "step", "type"
var parameters: Dictionary = {}

## Signal emitted when a parameter changes
signal parameter_changed(param_name: String, new_value: Variant)

## Signal emitted when effect is enabled/disabled
signal effect_toggled(enabled: bool)

## Rendering device reference (cached)
var rd: RenderingDevice

## Shader RID (loaded by subclasses)
var shader_rid: RID

## Pipeline RID
var pipeline_rid: RID

## Mutex for thread-safe parameter access
var _param_mutex: Mutex


func _init() -> void:
	_param_mutex = Mutex.new()
	# Default to post-transparent for most effects
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	# Access flags for what we need
	access_resolved_color = true
	access_resolved_depth = false  # Set true if needs_depth


func _notification(what: int) -> void:
	# Note: NOTIFICATION_PREDELETE can fire during engine shutdown when
	# RenderingDevice may already be freed. Use defensive cleanup.
	if what == NOTIFICATION_PREDELETE:
		if rd != null:
			if pipeline_rid.is_valid():
				rd.free_rid(pipeline_rid)
			if shader_rid.is_valid():
				rd.free_rid(shader_rid)


## Override in subclass to define parameters
func _define_parameters() -> void:
	pass


## Register a parameter that can be tweaked at runtime
func register_parameter(
	name: String,
	default_value: Variant,
	min_value: Variant = null,
	max_value: Variant = null,
	step: float = 0.01,
	display_name: String = "",
	param_description: String = ""
) -> void:
	parameters[name] = {
		"value": default_value,
		"default": default_value,
		"min": min_value,
		"max": max_value,
		"step": step,
		"display_name": display_name if display_name else name.capitalize(),
		"description": param_description,
		"type": typeof(default_value)
	}


## Get a parameter value (thread-safe)
func get_param(name: String) -> Variant:
	_param_mutex.lock()
	var value = parameters.get(name, {}).get("value")
	_param_mutex.unlock()
	return value


## Set a parameter value (thread-safe)
func set_param(name: String, value: Variant) -> void:
	_param_mutex.lock()
	if name in parameters:
		var param = parameters[name]
		# Clamp if bounds are set
		if param["min"] != null and param["max"] != null:
			if typeof(value) in [TYPE_FLOAT, TYPE_INT]:
				value = clamp(value, param["min"], param["max"])
		param["value"] = value
	_param_mutex.unlock()
	parameter_changed.emit(name, value)


## Reset a parameter to its default value
func reset_param(name: String) -> void:
	_param_mutex.lock()
	if name in parameters:
		parameters[name]["value"] = parameters[name]["default"]
	_param_mutex.unlock()


## Reset all parameters to defaults
func reset_all_params() -> void:
	_param_mutex.lock()
	for name in parameters:
		parameters[name]["value"] = parameters[name]["default"]
	_param_mutex.unlock()


## Get all parameters as a dictionary (for serialization)
func get_all_params() -> Dictionary:
	_param_mutex.lock()
	var result: Dictionary = {}
	for name in parameters:
		result[name] = parameters[name]["value"]
	_param_mutex.unlock()
	return result


## Set multiple parameters at once (for deserialization)
func set_all_params(values: Dictionary) -> void:
	for name in values:
		set_param(name, values[name])


## Load a compute shader from file
func load_compute_shader(path: String) -> bool:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		push_error("[%s] Failed to get rendering device" % effect_name)
		return false

	var shader_file := load(path) as RDShaderFile
	if shader_file == null:
		push_error("[%s] Failed to load shader: %s" % [effect_name, path])
		return false

	var shader_spirv := shader_file.get_spirv()
	if shader_spirv == null:
		push_error("[%s] Failed to get SPIRV from shader: %s" % [effect_name, path])
		return false

	shader_rid = rd.shader_create_from_spirv(shader_spirv)
	if not shader_rid.is_valid():
		push_error("[%s] Failed to create shader from SPIRV" % effect_name)
		return false

	pipeline_rid = rd.compute_pipeline_create(shader_rid)
	if not pipeline_rid.is_valid():
		push_error("[%s] Failed to create compute pipeline" % effect_name)
		return false

	return true


## Cleanup GPU resources
func _cleanup_gpu_resources() -> void:
	if rd == null:
		return

	if pipeline_rid.is_valid():
		rd.free_rid(pipeline_rid)
		pipeline_rid = RID()

	if shader_rid.is_valid():
		rd.free_rid(shader_rid)
		shader_rid = RID()


## Helper to create a uniform set for a compute shader
func create_uniform_set(uniforms: Array[RDUniform], set_index: int = 0) -> RID:
	if rd == null or not shader_rid.is_valid():
		return RID()
	return rd.uniform_set_create(uniforms, shader_rid, set_index)


## Helper to dispatch a compute shader
func dispatch_compute(
	uniform_set: RID,
	push_constants: PackedByteArray,
	groups_x: int,
	groups_y: int,
	groups_z: int = 1
) -> void:
	if rd == null or not pipeline_rid.is_valid():
		return

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline_rid)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	if push_constants.size() > 0:
		rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, groups_z)
	rd.compute_list_end()


## Convert parameters to push constant byte array
func params_to_push_constants(param_names: Array[String]) -> PackedByteArray:
	var floats := PackedFloat32Array()
	_param_mutex.lock()
	for name in param_names:
		if name in parameters:
			var value = parameters[name]["value"]
			if typeof(value) == TYPE_FLOAT:
				floats.append(value)
			elif typeof(value) == TYPE_INT:
				floats.append(float(value))
			elif typeof(value) == TYPE_BOOL:
				floats.append(1.0 if value else 0.0)
			elif typeof(value) == TYPE_VECTOR2:
				floats.append(value.x)
				floats.append(value.y)
			elif typeof(value) == TYPE_VECTOR3:
				floats.append(value.x)
				floats.append(value.y)
				floats.append(value.z)
			elif typeof(value) == TYPE_COLOR:
				floats.append(value.r)
				floats.append(value.g)
				floats.append(value.b)
				floats.append(value.a)
	_param_mutex.unlock()
	return floats.to_byte_array()


## Get effect info for UI display
func get_effect_info() -> Dictionary:
	return {
		"name": effect_name,
		"display_name": display_name,
		"description": description,
		"category": category,
		"enabled": effect_enabled,
		"blend_factor": blend_factor,
		"parameters": parameters.duplicate(true)
	}


## Called when effect is added to the pipeline
func on_effect_added() -> void:
	pass


## Called when effect is removed from the pipeline
func on_effect_removed() -> void:
	_cleanup_gpu_resources()
