## VolumetricCloudsEffect - Ray-marched volumetric clouds
##
## Inspired by Rafael's VAIO shader for OpenMW.
## Creates realistic 3D clouds using ray marching through a noise volume.
##
## Features:
## - True volumetric clouds with light scattering
## - Weather-based density variation
## - Animated movement
## - Sunset/sunrise coloring
## - Self-shadowing
@tool
class_name VolumetricCloudsEffect
extends PostProcessEffect

const SHADER_PATH := "res://src/core/shaders/compute/volumetric_clouds.glsl"

var _noise_3d_texture: Texture3D
var _noise_sampler: RID
var _depth_sampler: RID


func _init() -> void:
	super._init()

	effect_name = "volumetric_clouds"
	display_name = "Volumetric Clouds"
	description = "Ray-marched volumetric clouds with light scattering, self-shadowing, and weather effects. Inspired by OpenMW's VAIO shader."
	category = "Atmosphere"
	render_priority = 5  # Before fog

	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_SKY
	access_resolved_color = true
	access_resolved_depth = true
	needs_depth = true

	_define_parameters()


func _define_parameters() -> void:
	# Cloud density and coverage
	register_parameter("cloud_density", 0.425, 0.0, 1.0, 0.01,
		"Cloud Density", "Base density of clouds")

	register_parameter("cloud_coverage", 0.5, 0.0, 1.0, 0.01,
		"Cloud Coverage", "How much of the sky is covered (0 = clear, 1 = overcast)")

	# Movement
	register_parameter("cloud_speed", 7.0, 0.0, 50.0, 0.5,
		"Cloud Speed", "How fast the clouds move across the sky")

	# Lighting
	register_parameter("cloud_scattering", 1.0, 0.0, 2.0, 0.1,
		"Scattering", "Amount of Mie scattering (sun glow through clouds)")

	register_parameter("shadow_roughness", 2, 0, 2, 1,
		"Shadow Detail", "Level of shadow detail (0 = smooth, 2 = rough)")

	# Layer heights
	register_parameter("cloud_bottom", 10000.0, 5000.0, 20000.0, 500.0,
		"Bottom Layer", "Height of cloud layer bottom (in units)")

	register_parameter("cloud_top", 25000.0, 15000.0, 40000.0, 500.0,
		"Top Layer", "Height of cloud layer top (in units)")

	# Colors
	register_parameter("cloud_color_day", Color(0.95, 0.95, 0.98, 1.2), null, null, 0.01,
		"Day Color", "Cloud color during daytime (alpha = brightness)")

	register_parameter("cloud_color_sunset", Color(1.0, 0.6, 0.3, 1.0), null, null, 0.01,
		"Sunset Color", "Cloud tint color during sunset/sunrise")

	# Sun (can be linked to Sky3D)
	register_parameter("sun_direction", Vector3(-0.5, -0.5, 0.707).normalized(), null, null, 0.01,
		"Sun Direction", "Direction of the sun for lighting")

	register_parameter("sun_intensity", 1.0, 0.0, 3.0, 0.1,
		"Sun Intensity", "Brightness of sun lighting on clouds")


func on_effect_added() -> void:
	if not load_compute_shader(SHADER_PATH):
		push_error("[VolumetricCloudsEffect] Failed to load shader")
		return

	_load_noise_texture()
	_create_samplers()

	print("[VolumetricCloudsEffect] Effect initialized")


func _load_noise_texture() -> void:
	# Try to load Rafael's noise texture
	var noise_path := "res://inspos/RafaelsShaderPack/Textures/vaionoise3dw.dds"

	if ResourceLoader.exists(noise_path):
		_noise_3d_texture = load(noise_path)
	else:
		# Fall back to noise3d.dds
		var alt_path := "res://inspos/RafaelsShaderPack/Textures/noise3d.dds"
		if ResourceLoader.exists(alt_path):
			_noise_3d_texture = load(alt_path)
		else:
			# Generate procedural noise
			_noise_3d_texture = _generate_cloud_noise(64)


func _generate_cloud_noise(size: int) -> Texture3D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.03
	noise.fractal_octaves = 5
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5

	var images: Array[Image] = []
	for z in size:
		var img := Image.create(size, size, false, Image.FORMAT_RF)
		for y in size:
			for x in size:
				var value := (noise.get_noise_3d(x, y, z) + 1.0) * 0.5
				img.set_pixel(x, y, Color(value, 0, 0, 1))
		images.append(img)

	var tex := Texture3D.new()
	tex.create_from_images(images)
	return tex


func _create_samplers() -> void:
	if rd == null:
		return

	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE

	_noise_sampler = rd.sampler_create(sampler_state)
	_depth_sampler = rd.sampler_create(sampler_state)


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

	var render_scene_data := render_data.get_render_scene_data()
	if render_scene_data == null:
		return

	var size: Vector2i = render_scene_buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	var view_count: int = render_scene_buffers.get_view_count()
	for view in view_count:
		_render_view(view, size, render_scene_buffers, render_scene_data)


func _render_view(view: int, size: Vector2i, buffers: RenderSceneBuffersRD, scene_data: RenderSceneDataRD) -> void:
	var color_image := buffers.get_color_layer(view)
	var depth_texture := buffers.get_depth_layer(view)

	if not color_image.is_valid() or not depth_texture.is_valid():
		return

	var projection := scene_data.get_cam_projection()
	var view_matrix := scene_data.get_cam_transform().affine_inverse()
	var cam_position := scene_data.get_cam_transform().origin

	# Build push constants
	var push_constants := PackedFloat32Array()

	# inv_projection (mat4)
	var inv_proj := projection.inverse()
	for row in 4:
		for col in 4:
			push_constants.append(inv_proj[col][row])

	# inv_view (mat4)
	var inv_view := view_matrix.inverse()
	for row in 4:
		for col in 4:
			push_constants.append(inv_view[col][row])

	# camera_position (vec4)
	push_constants.append(cam_position.x)
	push_constants.append(cam_position.y)
	push_constants.append(cam_position.z)
	push_constants.append(Time.get_ticks_msec() / 1000.0)

	# sun_direction (vec4)
	var sun_dir: Vector3 = get_param("sun_direction")
	push_constants.append(sun_dir.x)
	push_constants.append(sun_dir.y)
	push_constants.append(sun_dir.z)
	push_constants.append(get_param("sun_intensity"))

	# cloud_params (vec4)
	push_constants.append(get_param("cloud_density"))
	push_constants.append(get_param("cloud_coverage"))
	push_constants.append(get_param("cloud_speed"))
	push_constants.append(get_param("cloud_scattering"))

	# cloud_params2 (vec4)
	push_constants.append(get_param("cloud_bottom"))
	push_constants.append(get_param("cloud_top"))
	push_constants.append(float(get_param("shadow_roughness")))
	push_constants.append(blend_factor)

	# cloud_color_day (vec4)
	var color_day: Color = get_param("cloud_color_day")
	push_constants.append(color_day.r)
	push_constants.append(color_day.g)
	push_constants.append(color_day.b)
	push_constants.append(color_day.a)

	# cloud_color_sunset (vec4)
	var color_sunset: Color = get_param("cloud_color_sunset")
	push_constants.append(color_sunset.r)
	push_constants.append(color_sunset.g)
	push_constants.append(color_sunset.b)
	push_constants.append(color_sunset.a)

	# resolution (vec2) + padding
	push_constants.append(float(size.x))
	push_constants.append(float(size.y))
	push_constants.append(0.0)
	push_constants.append(0.0)

	# Create uniforms
	var uniforms: Array[RDUniform] = []

	var u_color := RDUniform.new()
	u_color.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_color.binding = 0
	u_color.add_id(color_image)
	uniforms.append(u_color)

	var u_depth := RDUniform.new()
	u_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_depth.binding = 1
	u_depth.add_id(_depth_sampler)
	u_depth.add_id(depth_texture)
	uniforms.append(u_depth)

	if _noise_3d_texture:
		var u_noise := RDUniform.new()
		u_noise.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u_noise.binding = 2
		u_noise.add_id(_noise_sampler)
		u_noise.add_id(RenderingServer.texture_get_rd_texture(_noise_3d_texture.get_rid()))
		uniforms.append(u_noise)

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


func on_effect_removed() -> void:
	super.on_effect_removed()

	if rd:
		if _noise_sampler.is_valid():
			rd.free_rid(_noise_sampler)
		if _depth_sampler.is_valid():
			rd.free_rid(_depth_sampler)


## Update sun direction from Sky3D (call this from world_explorer)
func sync_with_sky3d(sky3d: Node) -> void:
	if sky3d == null:
		return

	# Get sun direction from Sky3D's sun light
	var sun_light := sky3d.get_node_or_null("SkyDome/SunLight") as DirectionalLight3D
	if sun_light:
		set_param("sun_direction", -sun_light.global_transform.basis.z)

	# Get sun intensity from Sky3D
	if sky3d.has_method("get") and sky3d.get("sun_energy"):
		set_param("sun_intensity", sky3d.sun_energy)
