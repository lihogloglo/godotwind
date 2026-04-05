## VolumetricFogEffect - Ray-marched volumetric fog post-processing
##
## Inspired by Rafael's VAIO shader for OpenMW, adapted for Godot 4.5.
## Uses compute shaders to ray-march through a 3D noise volume,
## creating realistic, animated fog with height-based density variation.
##
## Features:
## - Ray-marched volumetric fog with 3D noise
## - Height-based density (valleys get foggier)
## - Animated noise for movement
## - Sun scattering (Mie phase function)
## - Stamp texturing for organic look
@tool
class_name VolumetricFogEffect
extends PostProcessEffect

## Path to compute shader
const SHADER_PATH := "res://src/core/shaders/compute/volumetric_fog.glsl"

## Noise textures
var _noise_3d_texture: Texture3D
var _noise_2d_texture: Texture2D

## GPU resources
var _depth_sampler: RID
var _noise_3d_sampler: RID
var _noise_2d_sampler: RID

## Cached uniform set (invalidate on parameter change)
var _uniform_set_dirty: bool = true

## Dummy 1x1 texture for when transmittance LUT is not available
var _dummy_transmittance: RID

## Active sun for dynamic direction — set by world_explorer or test scenes
var _active_sun: DirectionalLight3D = null

## Cached weather data — written on main thread, read on render thread.
## Avoids data race from accessing WeatherManager autoload in _render_callback.
var _cached_weather_id: float = 0.0
var _cached_next_weather_id: float = 0.0
var _cached_weather_transition: float = 0.0
var _cached_game_hour: float = 12.0
var _cached_fog_color: Color = Color(0.7, 0.75, 0.8)
var _cached_weather_active: bool = false

## Set the active sun for dynamic fog scattering direction
func set_sun(sun: DirectionalLight3D) -> void:
	_active_sun = sun


## Call from main thread (_process or before rendering) to cache weather state.
## This avoids accessing the WeatherManager autoload from the render thread.
func update_weather_cache() -> void:
	if WeatherManager and WeatherManager.enabled:
		var result: WeatherTypes.WeatherResult = WeatherManager.get_weather_result()
		_cached_weather_id = float(result.current_type)
		_cached_next_weather_id = float(result.next_type)
		_cached_weather_transition = result.transition_factor
		_cached_game_hour = result.game_hour
		_cached_fog_color = result.fog_color
		_cached_weather_active = true
	else:
		_cached_weather_active = false


func _init() -> void:
	super._init()

	effect_name = "volumetric_fog"
	display_name = "Volumetric Fog"
	description = "Ray-marched volumetric fog with 3D noise, height falloff, and sun scattering. Inspired by OpenMW's VAIO shader."
	category = "Atmosphere"
	render_priority = 10

	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_depth = true

	_define_parameters()


func _define_parameters() -> void:
	# Fog appearance
	register_parameter("fog_color", Color(0.7, 0.75, 0.8, 1.0), null, null, 0.01,
		"Fog Color", "Base color of the fog")

	register_parameter("fog_intensity", 0.5, 0.0, 2.0, 0.01,
		"Intensity", "Overall fog intensity (0 = no fog, 1 = normal, 2 = dense)")

	register_parameter("fog_density", 0.0007, 0.0001, 0.01, 0.0001,
		"Density", "Fog density coefficient (exponential falloff)")

	# Distance parameters
	register_parameter("fog_start", 50.0, 0.0, 500.0, 10.0,
		"Start Distance", "Distance where fog begins to appear")

	register_parameter("fog_end", 5000.0, 500.0, 20000.0, 100.0,
		"End Distance", "Maximum fog distance (also affects sky)")

	# Height-based fog
	register_parameter("height_falloff", 0.003, 0.0, 0.01, 0.0005,
		"Height Falloff", "How quickly fog density decreases with height")

	register_parameter("height_multiplier", 5.0, 1.0, 20.0, 0.5,
		"Valley Multiplier", "Extra fog density in valleys (below camera)")

	# Animation
	register_parameter("fog_speed", 5.0, 0.0, 25.0, 0.5,
		"Animation Speed", "How fast the fog moves/animates")

	# Stamping (detail texturing)
	register_parameter("stamp_intensity", 0.35, 0.0, 1.0, 0.05,
		"Stamp Intensity", "Adds texture detail to fog (0 = smooth, 1 = textured)")

	register_parameter("stamp_contrast", 1.4, 1.0, 2.0, 0.1,
		"Stamp Contrast", "Contrast of the stamp texture effect")

	# Sun scattering
	register_parameter("sun_intensity", 1.0, 0.0, 3.0, 0.1,
		"Sun Glow", "Intensity of sun scattering through fog (Mie effect)")

	register_parameter("sun_direction", Vector3(-0.5, -0.5, -0.707).normalized(), null, null, 0.01,
		"Sun Direction", "Direction of the sun for scattering calculation")


func on_effect_added() -> void:
	# Load compute shader
	if not load_compute_shader(SHADER_PATH):
		push_error("[VolumetricFogEffect] Failed to load shader")
		return

	# Load or create noise textures
	_load_noise_textures()

	# Create samplers
	_create_samplers()

	# Create dummy transmittance texture (1x1 white = full transmittance)
	_create_dummy_transmittance()

	Log.info("shaders", "VolumetricFogEffect initialized")


func _load_noise_textures() -> void:
	# Try to load Rafael's noise textures if available
	var noise_3d_path := "res://inspos/RafaelsShaderPack/Textures/noise3d.dds"
	var noise_2d_path := "res://inspos/RafaelsShaderPack/Textures/perlin2d.png"

	if ResourceLoader.exists(noise_3d_path):
		_noise_3d_texture = load(noise_3d_path)
	else:
		# Generate procedural 3D noise
		_noise_3d_texture = _generate_3d_noise(64)

	if ResourceLoader.exists(noise_2d_path):
		_noise_2d_texture = load(noise_2d_path)
	else:
		# Generate procedural 2D noise
		_noise_2d_texture = _generate_2d_noise(256)


func _generate_3d_noise(size: int) -> Texture3D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 0.05
	noise.fractal_octaves = 4

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


func _generate_2d_noise(size: int) -> Texture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 0.02
	noise.fractal_octaves = 4

	var img := Image.create(size, size, false, Image.FORMAT_RF)
	for y in size:
		for x in size:
			var value := (noise.get_noise_2d(x, y) + 1.0) * 0.5
			img.set_pixel(x, y, Color(value, 0, 0, 1))

	return ImageTexture.create_from_image(img)


func _create_samplers() -> void:
	if rd == null:
		return

	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT

	_depth_sampler = rd.sampler_create(sampler_state)
	_noise_3d_sampler = rd.sampler_create(sampler_state)
	_noise_2d_sampler = rd.sampler_create(sampler_state)


func _create_dummy_transmittance() -> void:
	if rd == null:
		return
	var fmt := RDTextureFormat.new()
	fmt.width = 1
	fmt.height = 1
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	_dummy_transmittance = rd.texture_create(fmt, RDTextureView.new())


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

	# Process each view (for VR/stereo support)
	var view_count: int = render_scene_buffers.get_view_count()
	for view in view_count:
		_render_view(view, size, render_scene_buffers, render_scene_data)


func _render_view(view: int, size: Vector2i, buffers: RenderSceneBuffersRD, scene_data: RenderSceneDataRD) -> void:
	# Get color and depth textures
	var color_image := buffers.get_color_layer(view)
	var depth_texture := buffers.get_depth_layer(view)

	if not color_image.is_valid() or not depth_texture.is_valid():
		return

	# Get camera matrices
	var projection := scene_data.get_cam_projection()
	var view_matrix := scene_data.get_cam_transform().affine_inverse()
	var cam_position := scene_data.get_cam_transform().origin

	# Build push constants
	var push_constants := PackedFloat32Array()

	# inv_projection (mat4 = 16 floats)
	var inv_proj := projection.inverse()
	for row in 4:
		for col in 4:
			push_constants.append(inv_proj[col][row])

	# inv_view (mat4 = 16 floats)
	var inv_view := view_matrix.inverse()
	for row in 4:
		for col in 4:
			push_constants.append(inv_view[col][row])

	# camera_position (vec4)
	push_constants.append(cam_position.x)
	push_constants.append(cam_position.y)
	push_constants.append(cam_position.z)
	push_constants.append(Time.get_ticks_msec() / 1000.0)  # time

	# fog_color (vec4) — use cached weather fog color when weather is active
	var fog_color: Color = get_param("fog_color")
	var intensity: float = get_param("fog_intensity")
	if _cached_weather_active:
		fog_color = _cached_fog_color
	push_constants.append(fog_color.r)
	push_constants.append(fog_color.g)
	push_constants.append(fog_color.b)
	push_constants.append(intensity)

	# fog_params (vec4)
	push_constants.append(get_param("fog_density"))
	push_constants.append(get_param("height_falloff"))
	push_constants.append(get_param("fog_start"))
	push_constants.append(get_param("fog_end"))

	# fog_params2 (vec4)
	push_constants.append(get_param("fog_speed"))
	push_constants.append(get_param("height_multiplier"))
	push_constants.append(get_param("stamp_intensity"))
	push_constants.append(get_param("stamp_contrast"))

	# sun_direction (vec4) — try to find active sun, fall back to parameter
	var sun_dir: Vector3 = get_param("sun_direction")
	if _active_sun and is_instance_valid(_active_sun):
		sun_dir = -_active_sun.global_basis.z
	push_constants.append(sun_dir.x)
	push_constants.append(sun_dir.y)
	push_constants.append(sun_dir.z)
	push_constants.append(get_param("sun_intensity"))

	# weather_params (vec4) — OpenMW compat: weather_id, next_weather_id, transition, game_hour
	# Uses cached values written on main thread (see update_weather_cache)
	push_constants.append(_cached_weather_id)
	push_constants.append(_cached_next_weather_id)
	push_constants.append(_cached_weather_transition)
	push_constants.append(_cached_game_hour)

	# resolution (vec2)
	push_constants.append(float(size.x))
	push_constants.append(float(size.y))

	# blend_factor + has_transmittance flag
	push_constants.append(blend_factor)
	var transmittance_rid: RID = ShaderManager.get_shared_texture("sky_transmittance")
	var has_transmittance: float = 1.0 if transmittance_rid.is_valid() else 0.0
	push_constants.append(has_transmittance)

	# Create uniforms
	var uniforms: Array[RDUniform] = []

	# Color image (binding 0)
	var u_color := RDUniform.new()
	u_color.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_color.binding = 0
	u_color.add_id(color_image)
	uniforms.append(u_color)

	# Depth texture (binding 1)
	var u_depth := RDUniform.new()
	u_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_depth.binding = 1
	u_depth.add_id(_depth_sampler)
	u_depth.add_id(depth_texture)
	uniforms.append(u_depth)

	# 3D noise texture (binding 2)
	if _noise_3d_texture:
		var u_noise3d := RDUniform.new()
		u_noise3d.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u_noise3d.binding = 2
		u_noise3d.add_id(_noise_3d_sampler)
		u_noise3d.add_id(RenderingServer.texture_get_rd_texture(_noise_3d_texture.get_rid()))
		uniforms.append(u_noise3d)

	# 2D noise texture (binding 3)
	if _noise_2d_texture:
		var u_noise2d := RDUniform.new()
		u_noise2d.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u_noise2d.binding = 3
		u_noise2d.add_id(_noise_2d_sampler)
		u_noise2d.add_id(RenderingServer.texture_get_rd_texture(_noise_2d_texture.get_rid()))
		uniforms.append(u_noise2d)

	# Transmittance LUT (binding 4) — from SkyTransmittanceEffect shared texture
	var lut_rid: RID = transmittance_rid if transmittance_rid.is_valid() else _dummy_transmittance
	var u_transmittance := RDUniform.new()
	u_transmittance.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_transmittance.binding = 4
	u_transmittance.add_id(_depth_sampler)  # reuse linear/clamp sampler
	u_transmittance.add_id(lut_rid)
	uniforms.append(u_transmittance)

	# Create uniform set
	var uniform_set := rd.uniform_set_create(uniforms, shader_rid, 0)
	if not uniform_set.is_valid():
		return

	# Dispatch compute shader
	var groups_x := (size.x + 7) / 8
	var groups_y := (size.y + 7) / 8

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline_rid)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	# Free uniform set (created per frame)
	rd.free_rid(uniform_set)


func on_effect_removed() -> void:
	super.on_effect_removed()

	if rd:
		if _depth_sampler.is_valid():
			rd.free_rid(_depth_sampler)
		if _noise_3d_sampler.is_valid():
			rd.free_rid(_noise_3d_sampler)
		if _noise_2d_sampler.is_valid():
			rd.free_rid(_noise_2d_sampler)
		if _dummy_transmittance.is_valid():
			rd.free_rid(_dummy_transmittance)
