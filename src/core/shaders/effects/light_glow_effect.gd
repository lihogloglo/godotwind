## LightGlowEffect - Point light fog halos
##
## Ported from VAIO's RT_Lights pass (Rafael's Shader Pack).
## Accumulates per-pixel glow from nearby OmniLight3D nodes,
## creating atmospheric halos through fog. Light glow radius
## expands in foggier conditions.
##
## Requires active scene lights. Collects up to MAX_LIGHTS
## OmniLight3D nodes per frame, uploads positions/colors/radii
## as a storage buffer (SSBO).
##
## Weather-aware: glow intensity reduces during daytime,
## radius expands in fog/rain/blizzard.
@tool
class_name LightGlowEffect
extends PostProcessEffect

const SHADER_PATH := "res://src/core/shaders/compute/light_glow.glsl"
const SHARED_TEXTURE_NAME := "light_glow"

## Maximum lights processed per frame
const MAX_LIGHTS: int = 64

## Internal glow texture (half resolution)
var _glow_texture: RID

## Samplers
var _depth_sampler: RID

## Light data SSBO
var _light_buffer: RID
var _light_data: PackedFloat32Array

## Current half resolution
var _current_half_size: Vector2i

## Scene tree root for light collection (set externally)
var _scene_root: Node = null

## Cached weather/environment data (main thread → render thread)
var _cached_fog_intensity: float = 0.5
var _cached_fogginess: float = 0.0
var _cached_sun_height: float = 0.5
var _cached_light_count: int = 0
var _cached_camera_pos: Vector3 = Vector3.ZERO


func _init() -> void:
	super._init()

	effect_name = "light_glow"
	display_name = "Light Glow"
	description = "Point light fog halos. Lights create atmospheric glow through fog. Ported from VAIO's RT_Lights pass."
	category = "Atmosphere"
	render_priority = 12  # After godrays (11), before color grading (100)

	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_depth = true

	_define_parameters()


func _define_parameters() -> void:
	register_parameter("glow_intensity", 0.2, 0.0, 1.0, 0.025,
		"Glow Intensity", "Intensity of light glow halos through fog")

	register_parameter("max_distance", 13000.0, 500.0, 30000.0, 500.0,
		"Fade Distance", "Distance at which light glow disappears completely")

	register_parameter("collection_radius", 500.0, 100.0, 2000.0, 50.0,
		"Collection Radius", "Radius around camera to collect lights (meters)")


func on_effect_added() -> void:
	if not load_compute_shader(SHADER_PATH):
		push_error("[LightGlowEffect] Failed to load shader")
		return

	_create_sampler()
	_create_light_buffer()

	Log.info("shaders", "LightGlowEffect initialized (max %d lights)" % MAX_LIGHTS)


func _create_sampler() -> void:
	if rd == null:
		return

	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_depth_sampler = rd.sampler_create(sampler_state)


func _create_light_buffer() -> void:
	if rd == null:
		return

	# 2 vec4s per light × MAX_LIGHTS × 4 bytes per float
	var buffer_size := MAX_LIGHTS * 2 * 4 * 4
	_light_data = PackedFloat32Array()
	_light_data.resize(MAX_LIGHTS * 8)
	_light_buffer = rd.storage_buffer_create(buffer_size, _light_data.to_byte_array())


func _create_glow_texture(half_size: Vector2i) -> void:
	if _glow_texture.is_valid():
		rd.free_rid(_glow_texture)

	var fmt := RDTextureFormat.new()
	fmt.width = half_size.x
	fmt.height = half_size.y
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D

	_glow_texture = rd.texture_create(fmt, RDTextureView.new())
	_current_half_size = half_size

	# Register as shared texture for other effects to read
	if _glow_texture.is_valid():
		ShaderManager.set_shared_texture(SHARED_TEXTURE_NAME, _glow_texture)


## Set the scene root for light collection
func set_scene_root(root: Node) -> void:
	_scene_root = root


## Call from main thread to collect lights and cache state
func update_weather_cache() -> void:
	# Weather-based fogginess
	if WeatherManager and WeatherManager.enabled:
		var result: WeatherTypes.WeatherResult = WeatherManager.get_weather_result()
		_cached_fog_intensity = result.fog_depth
		# Fogginess: 0 = clear, higher = more fog glow expansion
		# Derive from weather fog density (VAIO: 5.0 * saturate(fogAmount - 1.0))
		var fog_amount: float = 2.0 * result.fog_depth
		_cached_fogginess = 5.0 * clampf(fog_amount - 1.0, 0.0, 1.0)
	else:
		_cached_fog_intensity = get_param("glow_intensity")
		_cached_fogginess = 0.0

	# Collect lights from scene
	_collect_lights()


## Collect nearby OmniLight3D nodes and upload to SSBO
func _collect_lights() -> void:
	_cached_light_count = 0

	if _scene_root == null or not is_instance_valid(_scene_root):
		return

	var collection_radius: float = get_param("collection_radius")
	var collection_radius_sq: float = collection_radius * collection_radius
	var lights: Array[OmniLight3D] = []

	# Find all OmniLight3D in the scene tree
	_find_lights_recursive(_scene_root, lights, collection_radius_sq)

	# Sort by distance (closest first) and cap at MAX_LIGHTS
	if lights.size() > MAX_LIGHTS:
		lights.sort_custom(func(a: OmniLight3D, b: OmniLight3D) -> bool:
			return a.global_position.distance_squared_to(_cached_camera_pos) < b.global_position.distance_squared_to(_cached_camera_pos)
		)
		lights.resize(MAX_LIGHTS)

	# Pack into SSBO data (2 vec4s per light)
	for i in lights.size():
		var light: OmniLight3D = lights[i]
		var pos: Vector3 = light.global_position
		var idx: int = i * 8

		# vec4 0: position.xyz, radius
		_light_data[idx + 0] = pos.x
		_light_data[idx + 1] = pos.y
		_light_data[idx + 2] = pos.z
		_light_data[idx + 3] = light.omni_range

		# vec4 1: color.rgb, intensity
		_light_data[idx + 4] = light.light_color.r
		_light_data[idx + 5] = light.light_color.g
		_light_data[idx + 6] = light.light_color.b
		_light_data[idx + 7] = light.light_energy

	_cached_light_count = lights.size()

	# Upload to GPU
	if _light_buffer.is_valid() and _cached_light_count > 0:
		rd.buffer_update(_light_buffer, 0, _cached_light_count * 8 * 4, _light_data.to_byte_array())


func _find_lights_recursive(node: Node, lights: Array[OmniLight3D], radius_sq: float) -> void:
	if node is OmniLight3D:
		var dist_sq: float = node.global_position.distance_squared_to(_cached_camera_pos)
		if dist_sq <= radius_sq and node.visible and node.light_energy > 0.01:
			lights.append(node)
	for child in node.get_children():
		_find_lights_recursive(child, lights, radius_sq)


func _render_callback(effect_callback_type: int, render_data: RenderData) -> void:
	if not effect_enabled or blend_factor <= 0.0:
		return
	if not pipeline_rid.is_valid():
		return
	if _cached_light_count <= 0:
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

	var half_size := Vector2i(size.x / 2, size.y / 2)
	if half_size != _current_half_size or not _glow_texture.is_valid():
		_create_glow_texture(half_size)

	# Cache camera position for light collection
	_cached_camera_pos = render_scene_data.get_cam_transform().origin

	var view_count: int = render_scene_buffers.get_view_count()
	for view in view_count:
		_render_view(view, size, half_size, render_scene_buffers, render_scene_data)


func _render_view(view: int, size: Vector2i, half_size: Vector2i,
		buffers: RenderSceneBuffersRD, scene_data: RenderSceneDataRD) -> void:
	var color_image := buffers.get_color_layer(view)
	var depth_texture := buffers.get_depth_layer(view)
	if not color_image.is_valid() or not depth_texture.is_valid():
		return

	var projection := scene_data.get_cam_projection()
	var cam_position := scene_data.get_cam_transform().origin

	# Build push constants (112 bytes)
	var pc := PackedFloat32Array()

	# inv_projection (mat4 = 16 floats)
	var inv_proj := projection.inverse()
	for row in 4:
		for col in 4:
			pc.append(inv_proj[col][row])

	# camera_position (vec4)
	pc.append(cam_position.x)
	pc.append(cam_position.y)
	pc.append(cam_position.z)
	pc.append(Time.get_ticks_msec() / 1000.0)

	# fog_params (vec4)
	pc.append(_cached_fog_intensity)
	pc.append(_cached_fogginess)
	pc.append(_cached_sun_height)
	pc.append(float(_cached_light_count))

	# resolution (vec2) + half_resolution (vec2)
	pc.append(float(size.x))
	pc.append(float(size.y))
	pc.append(float(half_size.x))
	pc.append(float(half_size.y))

	# Create uniforms
	var uniforms: Array[RDUniform] = []

	# Glow output (binding 0)
	var u_glow := RDUniform.new()
	u_glow.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_glow.binding = 0
	u_glow.add_id(_glow_texture)
	uniforms.append(u_glow)

	# Depth texture (binding 1)
	var u_depth := RDUniform.new()
	u_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_depth.binding = 1
	u_depth.add_id(_depth_sampler)
	u_depth.add_id(depth_texture)
	uniforms.append(u_depth)

	# Light buffer SSBO (binding 2)
	var u_lights := RDUniform.new()
	u_lights.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_lights.binding = 2
	u_lights.add_id(_light_buffer)
	uniforms.append(u_lights)

	var uniform_set := rd.uniform_set_create(uniforms, shader_rid, 0)
	if not uniform_set.is_valid():
		return

	# Dispatch at half resolution
	var groups_x := (half_size.x + 7) / 8
	var groups_y := (half_size.y + 7) / 8

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline_rid)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, pc.to_byte_array(), pc.size() * 4)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	rd.free_rid(uniform_set)

	# Composite glow onto scene color (additive blend)
	_composite_glow(color_image, size)


## Composite the half-res glow texture onto the scene color (additive)
func _composite_glow(color_image: RID, size: Vector2i) -> void:
	# For now, we'll composite using the volumetric fog shader's blend
	# by writing to the shared texture registry. The fog combine pass
	# reads "light_glow" and adds it.
	# TODO: Add a dedicated composite pass or integrate into fog combine.
	pass


## Set sun height for daytime glow reduction
func set_sun_height(height: float) -> void:
	_cached_sun_height = height


func on_effect_removed() -> void:
	super.on_effect_removed()

	ShaderManager.clear_shared_texture(SHARED_TEXTURE_NAME)

	if rd:
		if _glow_texture.is_valid():
			rd.free_rid(_glow_texture)
			_glow_texture = RID()
		if _depth_sampler.is_valid():
			rd.free_rid(_depth_sampler)
		if _light_buffer.is_valid():
			rd.free_rid(_light_buffer)
			_light_buffer = RID()
