## GodraysEffect - Screen-space god rays post-processing
##
## Ported from Rafael's godrays.omwfx for OpenMW.
## Uses a 4-pass compute pipeline:
##   Pass 0: Sky mask (depth-based sun occlusion, half res)
##   Pass 1: Radial blur (smooth the mask along sun direction)
##   Pass 2: Ray computation (iterative sampling with blue noise)
##   Pass 3: Combine (composite rays + sun disc onto scene)
##
## Requires an active DirectionalLight3D set via set_sun().
## Weather-aware: ray intensity adjusts per weather type.
@tool
class_name GodraysEffect
extends PostProcessEffect

const SHADER_PATH := "res://src/core/shaders/compute/godrays.glsl"

## Pass IDs matching the compute shader
const PASS_SKY_MASK    := 0
const PASS_RADIAL_BLUR := 1
const PASS_RAYS        := 2
const PASS_COMBINE     := 3

## Internal render targets (mask/blur at full res, rays at half res)
var _rt_mask: RID
var _rt_blur: RID
var _rt_rays: RID

## Samplers
var _linear_sampler: RID   # bilinear + clamp (intermediate textures)
var _nearest_sampler: RID  # nearest + repeat (blue noise)
var _depth_sampler: RID    # linear + clamp (scene depth)

## Blue noise texture for temporal dithering
var _blue_noise_texture: Texture2D

## Current resolution tracking (recreate textures on resize)
var _current_full_size: Vector2i
var _current_half_size: Vector2i

## Active sun for ray direction — set by world_explorer or test scenes
var _active_sun: DirectionalLight3D = null

## Cloud density source — SunshineCloudsGD resource (read live, never cached)
var _cloud_source: Resource = null

## Cached weather data — written on main thread, read on render thread
var _cached_weather_id: float = 0.0
var _cached_next_weather_id: float = 0.0
var _cached_weather_transition: float = 0.0
var _cached_sun_vis: float = 1.0
var _cached_fog_near_ratio: float = 0.0
var _cached_fog_far: float = 5000.0
var _cached_weather_active: bool = false

## Dummy 1x1 textures for unused bindings
var _dummy_r16f: RID
var _dummy_rgba16f: RID


## Set the active sun for god ray direction
func set_sun(sun: DirectionalLight3D) -> void:
	_active_sun = sun


## Set the cloud density source (SunshineCloudsGD resource).
## GodraysEffect reads accumulation_textures live in _render_view — never cached,
## so resize-triggered texture recreation is handled transparently.
func set_cloud_source(resource: Resource) -> void:
	_cloud_source = resource


## Call from main thread to cache weather state (avoids render-thread data race)
func update_weather_cache() -> void:
	if WeatherManager and WeatherManager.enabled:
		var result: WeatherTypes.WeatherResult = WeatherManager.get_weather_result()
		_cached_weather_id = float(result.current_type)
		_cached_next_weather_id = float(result.next_type)
		_cached_weather_transition = result.transition_factor
		_cached_sun_vis = 1.0  # TODO: derive from weather result sun intensity
		# Map MW fog_depth (0.69=clear → 3.5=blizzard) to sharpness ratio (1=sharp → 0=soft)
		# OpenMW uses fogNear/480 where fogNear is a distance. Our fog_depth is a density multiplier.
		_cached_fog_near_ratio = clampf(1.0 - (result.fog_depth - 0.5), 0.0, 1.0)
		_cached_fog_far = 5000.0 / maxf(result.fog_depth, 0.1)  # denser fog = shorter visibility
		_cached_weather_active = true
	else:
		_cached_weather_active = false


func _init() -> void:
	super._init()

	effect_name = "godrays"
	display_name = "God Rays"
	description = "Screen-space god rays with sun disc, weather-aware occlusion, and blue noise dithering. Ported from Rafael's godrays.omwfx for OpenMW."
	category = "Atmosphere"
	render_priority = 11  # After fog (10), before color grading (100)

	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_depth = true

	_define_parameters()


func _define_parameters() -> void:
	# Ray parameters
	register_parameter("iterations", 16.0, 1.0, 50.0, 1.0,
		"Iterations", "Number of ray sampling iterations (more = smoother, slower)")

	register_parameter("ray_radius", 0.25, 0.1, 10.0, 0.1,
		"Ray Radius", "Radius around sun center that emits rays")

	register_parameter("ray_strength", 0.6, 0.1, 10.0, 0.05,
		"Ray Strength", "Brightness of sun rays")

	register_parameter("ray_falloff", 1.10, 0.1, 10.0, 0.1,
		"Ray Falloff", "How quickly rays fade with distance from sun")

	register_parameter("ray_falloff_const", 0.125, 0.1, 10.0, 0.1,
		"Minimum Ray Length", "Increase to extend minimum ray length")

	register_parameter("ray_sun_falloff", 1.5, 0.1, 10.0, 0.1,
		"Ray Falloff Exponent", "Ray strength falloff exponent near sun")

	register_parameter("center_vis", 0.2, 0.1, 10.0, 0.01,
		"Center Opacity", "Ray opacity at center of sun")

	register_parameter("ray_occlude", 0.3, 0.1, 10.0, 0.025,
		"Ray Occlude", "How much rays darken the underlying image")

	register_parameter("ray_brightness", 1.0, 0.1, 10.0, 0.05,
		"Ray Brightness", "Additional brightness for very bright rays")

	register_parameter("offscreen_range", 0.5, 0.1, 10.0, 0.1,
		"Offscreen Distance", "How far offscreen the sun can be before rays vanish")

	# Sun disc parameters
	register_parameter("sun_disc_radius", 0.025, 0.01, 10.0, 0.005,
		"Sun Radius", "Radius of the sun disc on screen")

	register_parameter("sun_disc_brightness", 0.5, 0.1, 10.0, 0.1,
		"Sun Brightness", "Brightness of the sun disc")

	register_parameter("sun_disc_desaturate", 0.4, -10.0, 10.0, 0.1,
		"Sun Desaturation", "Desaturation of sun disc color (negative = more saturation)")

	register_parameter("sun_disc_occlude", 0.1, 0.1, 10.0, 0.1,
		"Sun Disc Occlude", "How much the sun disc overwrites the original image")

	register_parameter("horizon_multiplier", 1.0, 0.0, 10.0, 0.1,
		"Horizon Multiplier", "Extra brightness for sun disc at the horizon (colorful sunsets)")


func on_effect_added() -> void:
	if not load_compute_shader(SHADER_PATH):
		push_error("[GodraysEffect] Failed to load shader")
		return

	_load_blue_noise()
	_create_samplers()
	_create_dummy_textures()

	Log.info("shaders", "GodraysEffect initialized")


func _load_blue_noise() -> void:
	var path := "res://inspos/RafaelsShaderPack/Textures/bluenoise.png"
	if ResourceLoader.exists(path):
		_blue_noise_texture = load(path)
	else:
		# Generate procedural blue noise fallback
		_blue_noise_texture = _generate_blue_noise(256)


func _generate_blue_noise(size: int) -> Texture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.frequency = 0.08
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE

	var img := Image.create(size, size, false, Image.FORMAT_RF)
	for y in size:
		for x in size:
			var value := (noise.get_noise_2d(x, y) + 1.0) * 0.5
			img.set_pixel(x, y, Color(value, 0, 0, 1))

	return ImageTexture.create_from_image(img)


func _create_samplers() -> void:
	if rd == null:
		return

	# Bilinear + clamp for intermediate textures and depth
	var linear_state := RDSamplerState.new()
	linear_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	linear_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_linear_sampler = rd.sampler_create(linear_state)
	_depth_sampler = rd.sampler_create(linear_state)

	# Nearest + repeat for blue noise (preserves high-frequency content)
	var nearest_state := RDSamplerState.new()
	nearest_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	nearest_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	nearest_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	nearest_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_nearest_sampler = rd.sampler_create(nearest_state)


func _create_dummy_textures() -> void:
	if rd == null:
		return

	# 1x1 R16F dummy for unused img_out bindings
	var fmt_r16f := RDTextureFormat.new()
	fmt_r16f.width = 1
	fmt_r16f.height = 1
	fmt_r16f.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	fmt_r16f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	fmt_r16f.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	_dummy_r16f = rd.texture_create(fmt_r16f, RDTextureView.new())

	# 1x1 RGBA16F dummy for unused color_image / cloud density bindings.
	# Zero-initialized so .a = 0.0 → no cloud attenuation when no cloud source.
	var fmt_rgba := RDTextureFormat.new()
	fmt_rgba.width = 1
	fmt_rgba.height = 1
	fmt_rgba.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt_rgba.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	fmt_rgba.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	var zero_rgba := PackedByteArray()
	zero_rgba.resize(8)  # 1×1 × 4 channels × 2 bytes (half-float)
	zero_rgba.fill(0)
	_dummy_rgba16f = rd.texture_create(fmt_rgba, RDTextureView.new(), [zero_rgba])


func _create_internal_textures(full_size: Vector2i, half_size: Vector2i) -> void:
	_free_internal_textures()

	# Mask and blur at FULL resolution for sharp silhouette edges
	# (matches Rafael's RT_Stretch/RT_Blur at width_ratio=1.0)
	var fmt_full := RDTextureFormat.new()
	fmt_full.width = full_size.x
	fmt_full.height = full_size.y
	fmt_full.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	fmt_full.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	fmt_full.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	_rt_mask = rd.texture_create(fmt_full, RDTextureView.new())
	_rt_blur = rd.texture_create(fmt_full, RDTextureView.new())

	# Ray sampling at half resolution (the expensive iterative part)
	var fmt_half := RDTextureFormat.new()
	fmt_half.width = half_size.x
	fmt_half.height = half_size.y
	fmt_half.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	fmt_half.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	fmt_half.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	_rt_rays = rd.texture_create(fmt_half, RDTextureView.new())

	_current_full_size = full_size
	_current_half_size = half_size


func _free_internal_textures() -> void:
	if rd == null:
		return
	if _rt_mask.is_valid():
		rd.free_rid(_rt_mask)
		_rt_mask = RID()
	if _rt_blur.is_valid():
		rd.free_rid(_rt_blur)
		_rt_blur = RID()
	if _rt_rays.is_valid():
		rd.free_rid(_rt_rays)
		_rt_rays = RID()


func _render_callback(effect_callback_type: int, render_data: RenderData) -> void:
	if not effect_enabled or blend_factor <= 0.0:
		return
	if not pipeline_rid.is_valid():
		return
	if _active_sun == null or not is_instance_valid(_active_sun):
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

	# Ensure textures exist and match viewport
	var half_size := Vector2i(size.x / 2, size.y / 2)
	if size != _current_full_size or not _rt_mask.is_valid():
		_create_internal_textures(size, half_size)

	var view_count: int = render_scene_buffers.get_view_count()
	for view in view_count:
		_render_view(view, size, half_size, render_scene_buffers, render_scene_data)


func _render_view(view: int, size: Vector2i, half_size: Vector2i,
		buffers: RenderSceneBuffersRD, scene_data: RenderSceneDataRD) -> void:
	var color_image := buffers.get_color_layer(view)
	var depth_texture := buffers.get_depth_layer(view)
	if not color_image.is_valid() or not depth_texture.is_valid():
		return

	# ── Compute sun screen position on CPU ──
	var cam_transform := scene_data.get_cam_transform()
	var projection := scene_data.get_cam_projection()
	var view_basis := cam_transform.affine_inverse().basis

	var toward_sun := _active_sun.global_basis.z  # direction toward sun

	# Project sun direction to screen — rotation only, no translation.
	# Sun is at infinity, so we project the direction through the view
	# matrix's rotation and then the projection matrix. This avoids the
	# camera-position dependency that caused the sun disc to shift with
	# camera movement (old code: cam_pos + dir * 100000 at MW world coords
	# made cam_pos a non-negligible fraction of the "sun distance").
	var sun_view_dir: Vector3 = view_basis * toward_sun

	var sun_uv := Vector2(0.5, 0.5)
	# sun_view_dir.z < 0 means sun is in front of camera (Godot view space: -Z = forward)
	if sun_view_dir.z < 0.0:
		var sun_clip := projection * Vector4(sun_view_dir.x, sun_view_dir.y, sun_view_dir.z, 1.0)
		if sun_clip.w > 0.001:
			var ndc_x: float = sun_clip.x / sun_clip.w
			var ndc_y: float = sun_clip.y / sun_clip.w
			sun_uv = Vector2(ndc_x * 0.5 + 0.5, ndc_y * 0.5 + 0.5)

	# Sun color from DirectionalLight3D
	var sun_color := _active_sun.light_color * _active_sun.light_energy
	var sun_dir := toward_sun.normalized()

	# Precompute weather values on CPU (128-byte push constant budget)
	var sun_height_vis: float = clampf(sun_dir.y * 20.0, 0.0, 1.0)

	# Weather-based sun occlusion (replaces GPU-side lookup table)
	var sun_weather_vis: float = 1.0
	if _cached_weather_active:
		var occlusion_table := [0.0, 0.25, 1.0, 0.75, 1.0, 1.0, 0.8, 0.8, 0.25, 0.85]
		var curr_idx: int = clampi(int(_cached_weather_id), 0, 9)
		var next_idx: int = clampi(int(_cached_next_weather_id), 0, 9)
		var inv_vis: float = lerpf(occlusion_table[curr_idx], occlusion_table[next_idx], _cached_weather_transition)
		sun_weather_vis = 1.0 - clampf(inv_vis, 0.0, 1.0)

	# Precompute disc light factor (nice_weather + sun_vis)
	var disc_light: float = 1.0
	if _cached_weather_active:
		var nice: float = 0.0
		var wid: int = clampi(int(_cached_weather_id), 0, 9)
		var nid: int = clampi(int(_cached_next_weather_id), 0, 9)
		if _cached_weather_transition > 0.0:
			nice = lerpf(1.0 if wid <= 1 else 0.0, 1.0 if nid <= 1 else 0.0, _cached_weather_transition)
			nice *= nice
		else:
			nice = 1.0 if wid <= 1 else 0.0
		var sv: float = _cached_sun_vis
		disc_light = 1.0 - pow(1.0 - lerpf(sv, 1.0, 0.333 * nice), 2.0)

	# ── Build push constants (128 bytes = 32 floats, Godot hard limit) ──
	var pc := PackedFloat32Array()

	# sun_screen_pos: xy=uv, z=forward_dot (negative = sun in front), w=time
	# forward_dot derived from view-space direction: z < 0 means in front
	var forward_dot: float = sun_view_dir.z
	pc.append(sun_uv.x)
	pc.append(sun_uv.y)
	pc.append(forward_dot)
	pc.append(Time.get_ticks_msec() / 1000.0)

	# sun_params: xyz=toward_sun, w=sun_height_vis
	pc.append(sun_dir.x)
	pc.append(sun_dir.y)
	pc.append(sun_dir.z)
	pc.append(sun_height_vis)

	# sun_color: rgb, a=blend_factor
	pc.append(sun_color.r)
	pc.append(sun_color.g)
	pc.append(sun_color.b)
	pc.append(blend_factor)

	# ray_params: iterations, radius, strength, falloff
	pc.append(get_param("iterations"))
	pc.append(get_param("ray_radius"))
	pc.append(get_param("ray_strength"))
	pc.append(get_param("ray_falloff"))

	# ray_params2: falloff_const, sun_falloff, center_vis, ray_occlude
	pc.append(get_param("ray_falloff_const"))
	pc.append(get_param("ray_sun_falloff"))
	pc.append(get_param("center_vis"))
	pc.append(get_param("ray_occlude"))

	# disc_params: radius, brightness, desaturate, disc_occlude
	pc.append(get_param("sun_disc_radius"))
	pc.append(get_param("sun_disc_brightness"))
	pc.append(get_param("sun_disc_desaturate"))
	pc.append(get_param("sun_disc_occlude"))

	# misc_params: offscreen, horizon_mult, ray_brightness, pass_id (set per pass)
	pc.append(get_param("offscreen_range"))
	pc.append(get_param("horizon_multiplier"))
	pc.append(get_param("ray_brightness"))
	pc.append(0.0)  # pass_id — overwritten per dispatch

	# extra_params: resolution_x, resolution_y, sun_weather_vis, disc_light
	pc.append(float(size.x))
	pc.append(float(size.y))
	pc.append(sun_weather_vis)
	pc.append(disc_light)

	var pc_bytes := pc.to_byte_array()
	var pc_size := pc.size() * 4  # should be 128

	# misc_params.w (pass_id) is float index 27, byte offset 108
	# sun_screen(0-3) + sun_dir(4-7) + sun_color(8-11) + ray(12-15) +
	# ray2(16-19) + disc(20-23) + misc(24-27) → misc.w = index 27
	var pass_id_byte_offset := 27 * 4

	# Blue noise RD texture
	var blue_noise_rid := RID()
	if _blue_noise_texture:
		blue_noise_rid = RenderingServer.texture_get_rd_texture(_blue_noise_texture.get_rid())

	var half_groups_x := (half_size.x + 7) / 8
	var half_groups_y := (half_size.y + 7) / 8
	var full_groups_x := (size.x + 7) / 8
	var full_groups_y := (size.y + 7) / 8

	# ═══ Pass 0: Sky Mask (full resolution) ═══
	# tex_a=depth, tex_b=dummy, img_out=rt_mask, color_image=dummy
	pc_bytes.encode_float(pass_id_byte_offset, float(PASS_SKY_MASK))
	var us0 := _create_uniform_set(depth_texture, _depth_sampler,
		_dummy_r16f, _linear_sampler,  # tex_b unused
		_rt_mask, _dummy_rgba16f)
	if not us0.is_valid():
		return

	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, us0, 0)
	rd.compute_list_set_push_constant(cl, pc_bytes, pc_size)
	rd.compute_list_dispatch(cl, full_groups_x, full_groups_y, 1)
	rd.compute_list_end()
	rd.free_rid(us0)

	# ═══ Pass 1: Radial Blur (full resolution) ═══
	# tex_a=rt_mask(sampler), tex_b=dummy, img_out=rt_blur, color_image=dummy
	pc_bytes.encode_float(pass_id_byte_offset, float(PASS_RADIAL_BLUR))
	var us1 := _create_uniform_set(_rt_mask, _linear_sampler,
		_dummy_r16f, _linear_sampler,
		_rt_blur, _dummy_rgba16f)
	if not us1.is_valid():
		return

	cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, us1, 0)
	rd.compute_list_set_push_constant(cl, pc_bytes, pc_size)
	rd.compute_list_dispatch(cl, full_groups_x, full_groups_y, 1)
	rd.compute_list_end()
	rd.free_rid(us1)

	# ═══ Pass 2: Rays ═══
	# tex_a=rt_blur(sampler), tex_b=blue_noise, img_out=rt_rays, color_image=dummy
	var noise_rid := blue_noise_rid if blue_noise_rid.is_valid() else _dummy_r16f
	pc_bytes.encode_float(pass_id_byte_offset, float(PASS_RAYS))
	var us2 := _create_uniform_set(_rt_blur, _linear_sampler,
		noise_rid, _nearest_sampler,
		_rt_rays, _dummy_rgba16f)
	if not us2.is_valid():
		return

	cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, us2, 0)
	rd.compute_list_set_push_constant(cl, pc_bytes, pc_size)
	rd.compute_list_dispatch(cl, half_groups_x, half_groups_y, 1)
	rd.compute_list_end()
	rd.free_rid(us2)

	# ═══ Pass 3: Combine ═══
	# tex_a=rt_rays, tex_b=sky_mask (Pass 0), img_out=dummy, color=scene, cloud=density
	# Sky mask: single source of truth for geometry occlusion (same signal as rays).
	# Cloud density: read LIVE from SunshineClouds2 accumulation_textures — never cached,
	# so resize-triggered texture recreation is handled transparently.
	pc_bytes.encode_float(pass_id_byte_offset, float(PASS_COMBINE))
	var cloud_tex_rid := _get_cloud_density_rid(view)
	var us3 := _create_uniform_set(_rt_rays, _linear_sampler,
		_rt_mask, _linear_sampler,
		_dummy_r16f, color_image,
		cloud_tex_rid, _linear_sampler)
	if not us3.is_valid():
		return

	cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, us3, 0)
	rd.compute_list_set_push_constant(cl, pc_bytes, pc_size)
	rd.compute_list_dispatch(cl, full_groups_x, full_groups_y, 1)
	rd.compute_list_end()
	rd.free_rid(us3)


## Read the cloud color accumulation texture RID live from the SunshineCloudsGD resource.
## Returns invalid RID if cloud source is absent, disabled, or textures not yet created.
## Called every frame inside _render_view — never cached, survives resize transparently.
func _get_cloud_density_rid(view: int) -> RID:
	if _cloud_source == null or not is_instance_valid(_cloud_source):
		return RID()
	if not _cloud_source.get("enabled"):
		return RID()
	var accum: Array = _cloud_source.get("accumulation_textures")
	if accum == null:
		return RID()
	var idx: int = view * 7 + 1  # cloud color+density texture for this view
	if idx >= accum.size():
		return RID()
	var rid: RID = accum[idx]
	return rid if rid.is_valid() else RID()


## Create a uniform set for one pass
## tex_a_rid + tex_a_sampler → binding 0 (sampler_with_texture)
## tex_b_rid + tex_b_sampler → binding 1 (sampler_with_texture)
## img_out_rid              → binding 2 (storage image, r16f)
## color_rid                → binding 3 (storage image, rgba16f)
## cloud_rid + cloud_sampler → binding 4 (sampler_with_texture, cloud density)
func _create_uniform_set(tex_a_rid: RID, tex_a_sampler: RID,
		tex_b_rid: RID, tex_b_sampler: RID,
		img_out_rid: RID, color_rid: RID,
		cloud_rid: RID = RID(), cloud_sampler: RID = RID()) -> RID:

	# Default cloud binding to dummy when not provided
	var actual_cloud_rid := cloud_rid if cloud_rid.is_valid() else _dummy_rgba16f
	var actual_cloud_sampler := cloud_sampler if cloud_sampler.is_valid() else _linear_sampler

	var uniforms: Array[RDUniform] = []

	# Binding 0: tex_a (sampler with texture)
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u0.binding = 0
	u0.add_id(tex_a_sampler)
	u0.add_id(tex_a_rid)
	uniforms.append(u0)

	# Binding 1: tex_b (sampler with texture)
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u1.binding = 1
	u1.add_id(tex_b_sampler)
	u1.add_id(tex_b_rid)
	uniforms.append(u1)

	# Binding 2: img_out (storage image)
	var u2 := RDUniform.new()
	u2.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u2.binding = 2
	u2.add_id(img_out_rid)
	uniforms.append(u2)

	# Binding 3: color_image (storage image)
	var u3 := RDUniform.new()
	u3.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u3.binding = 3
	u3.add_id(color_rid)
	uniforms.append(u3)

	# Binding 4: tex_cloud (sampler with texture — cloud density alpha)
	var u4 := RDUniform.new()
	u4.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u4.binding = 4
	u4.add_id(actual_cloud_sampler)
	u4.add_id(actual_cloud_rid)
	uniforms.append(u4)

	return rd.uniform_set_create(uniforms, shader_rid, 0)


func on_effect_removed() -> void:
	super.on_effect_removed()

	_free_internal_textures()

	if rd:
		if _linear_sampler.is_valid():
			rd.free_rid(_linear_sampler)
		if _nearest_sampler.is_valid():
			rd.free_rid(_nearest_sampler)
		if _depth_sampler.is_valid():
			rd.free_rid(_depth_sampler)
		if _dummy_r16f.is_valid():
			rd.free_rid(_dummy_r16f)
		if _dummy_rgba16f.is_valid():
			rd.free_rid(_dummy_rgba16f)
