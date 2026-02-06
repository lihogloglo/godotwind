## ColorGradingEffect - Basic color correction and grading
##
## Provides standard color grading controls including:
## - Exposure
## - Contrast/Brightness
## - Saturation
## - Lift/Gamma/Gain (shadow/midtone/highlight control)
## - Color filter/tint
@tool
class_name ColorGradingEffect
extends PostProcessEffect

const SHADER_PATH := "res://src/core/shaders/compute/color_grading.glsl"


func _init() -> void:
	super._init()

	effect_name = "color_grading"
	display_name = "Color Grading"
	description = "Basic color correction with exposure, contrast, saturation, and lift/gamma/gain controls."
	category = "Color"
	render_priority = 100  # Run late in the pipeline

	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true

	_define_parameters()


func _define_parameters() -> void:
	# Exposure
	register_parameter("exposure", 0.0, -5.0, 5.0, 0.1,
		"Exposure", "Exposure adjustment in stops (-5 to +5)")

	# Contrast and brightness
	register_parameter("contrast", 1.0, 0.5, 2.0, 0.05,
		"Contrast", "Contrast multiplier (1.0 = neutral)")

	register_parameter("brightness", 0.0, -1.0, 1.0, 0.02,
		"Brightness", "Brightness offset (-1 to +1)")

	# Saturation
	register_parameter("saturation", 1.0, 0.0, 2.0, 0.05,
		"Saturation", "Color saturation (0 = grayscale, 1 = normal, 2 = vivid)")

	# Lift/Gamma/Gain
	register_parameter("lift", 0.0, -0.5, 0.5, 0.02,
		"Lift (Shadows)", "Adjusts shadow levels")

	register_parameter("gamma", 1.0, 0.5, 2.0, 0.05,
		"Gamma (Midtones)", "Adjusts midtone levels")

	register_parameter("gain", 1.0, 0.5, 2.0, 0.05,
		"Gain (Highlights)", "Adjusts highlight levels")

	# Color filter
	register_parameter("color_filter", Color(1.0, 1.0, 1.0, 0.0), null, null, 0.01,
		"Color Filter", "Tint color (alpha = intensity)")


func on_effect_added() -> void:
	if not load_compute_shader(SHADER_PATH):
		push_error("[ColorGradingEffect] Failed to load shader")
		return

	Logger.info("shaders", "ColorGradingEffect initialized")


func _render_callback(effect_callback_type: int, render_data: RenderData) -> void:
	if not effect_enabled or blend_factor <= 0.0:
		return

	if rd == null:
		rd = RenderingServer.get_rendering_device()
		if rd == null:
			return

	var render_scene_buffers := render_data.get_render_scene_buffers()
	if render_scene_buffers == null:
		return

	var size: Vector2i = render_scene_buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	var view_count: int = render_scene_buffers.get_view_count()
	for view in view_count:
		_render_view(view, size, render_scene_buffers)


func _render_view(view: int, size: Vector2i, buffers: RenderSceneBuffersRD) -> void:
	var color_image := buffers.get_color_layer(view)
	if not color_image.is_valid():
		return

	# Build push constants
	var push_constants := PackedFloat32Array()

	# color_filter (vec4)
	var filter: Color = get_param("color_filter")
	push_constants.append(filter.r)
	push_constants.append(filter.g)
	push_constants.append(filter.b)
	push_constants.append(filter.a)

	# lift_gamma_gain (vec4)
	push_constants.append(get_param("lift"))
	push_constants.append(get_param("gamma"))
	push_constants.append(get_param("gain"))
	push_constants.append(get_param("saturation"))

	# contrast_params (vec4)
	push_constants.append(get_param("contrast"))
	push_constants.append(get_param("brightness"))
	push_constants.append(get_param("exposure"))
	push_constants.append(blend_factor)

	# resolution + padding
	push_constants.append(float(size.x))
	push_constants.append(float(size.y))
	push_constants.append(0.0)
	push_constants.append(0.0)

	# Create uniform
	var uniforms: Array[RDUniform] = []

	var u_color := RDUniform.new()
	u_color.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_color.binding = 0
	u_color.add_id(color_image)
	uniforms.append(u_color)

	var uniform_set := rd.uniform_set_create(uniforms, shader_rid, 0)
	if not uniform_set.is_valid():
		return

	var groups_x := (size.x + 7) / 8
	var groups_y := (size.y + 7) / 8

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline_rid)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	rd.free_rid(uniform_set)


## Preset: Morrowind-style warm tones
func apply_morrowind_preset() -> void:
	set_param("exposure", 0.2)
	set_param("contrast", 1.1)
	set_param("brightness", 0.0)
	set_param("saturation", 0.9)
	set_param("lift", 0.02)
	set_param("gamma", 1.05)
	set_param("gain", 1.0)
	set_param("color_filter", Color(1.0, 0.95, 0.85, 0.15))


## Preset: High contrast dramatic
func apply_dramatic_preset() -> void:
	set_param("exposure", 0.0)
	set_param("contrast", 1.3)
	set_param("brightness", -0.05)
	set_param("saturation", 1.1)
	set_param("lift", -0.02)
	set_param("gamma", 0.95)
	set_param("gain", 1.05)
	set_param("color_filter", Color(1.0, 1.0, 1.0, 0.0))


## Preset: Desaturated/bleached look
func apply_bleached_preset() -> void:
	set_param("exposure", 0.3)
	set_param("contrast", 0.9)
	set_param("brightness", 0.05)
	set_param("saturation", 0.6)
	set_param("lift", 0.05)
	set_param("gamma", 1.1)
	set_param("gain", 0.95)
	set_param("color_filter", Color(0.95, 0.98, 1.0, 0.1))
