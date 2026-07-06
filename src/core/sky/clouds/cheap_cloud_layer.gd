class_name CheapCloudLayer
extends RefCounted
## Cheap skydome clouds — ported from clayjohn's godot-volumetric-cloud-demo-v2
## (MIT, see assets/sky/ATTRIBUTION.txt).
##
## A compute shader raymarches the cloud hemisphere into an octahedral-mapped
## texture, amortized over [member frames_to_update] frames. Two finished
## textures are cross-blended in the sky shader to hide the rolling update.
## Per-frame GPU cost is 1/64th of a full hemisphere march — vs. a full-screen
## raymarch every frame for compositor clouds (SunshineClouds2).
##
## Owned by SkyManager. Not a Sky subclass (upstream extends Sky) because
## Godotwind's sky material already exists — this layer only feeds three
## shader uniforms: cheap_clouds_from, cheap_clouds_to, cheap_clouds_blend.
##
## Structural difference from upstream: the Hillaire sky-view LUT (set 2) is
## replaced by a 48-byte uniform buffer of three precomputed atmosphere colors
## supplied by SkyManager (our sky is analytical, there is no LUT).

const SHADER_PATH: String = "res://src/core/sky/clouds/cheap_clouds.glsl"
const LARGE_NOISE_PATH: String = "res://assets/sky/clouds/perlworlnoise.tga"
const SMALL_NOISE_PATH: String = "res://assets/sky/clouds/worlnoise.bmp"
const WEATHER_NOISE_PATH: String = "res://assets/sky/clouds/weather.bmp"

# ---- Driven per frame by SkyManager ----

## Wind heading in degrees (0 = from north/+X, matches upstream convention).
var wind_direction_deg: float = 0.0
## Wind speed in m/s.
var wind_speed: float = 1.0
## Raymarch extinction density (upstream default 0.05).
var density: float = 0.05
## Cloud coverage 0-1.
var cloud_coverage: float = 0.25
## Ground albedo tint for cloud undersides.
var ground_color: Color = Color(1.0, 1.0, 1.0, 1.0)

## Sun state (direction points TOWARD the sun).
var sun_direction: Vector3 = Vector3.UP
var sun_energy: float = 1.0
var sun_color: Color = Color.WHITE

## Precomputed atmosphere radiance (LUT replacement) — see
## SkyManager._compute_cloud_atmo_colors() for calibration.
var atmo_sun: Color = Color(90.0, 95.0, 100.0)
var atmo_ambient: Color = Color(14.0, 22.0, 36.0)
var atmo_ground: Color = Color(10.0, 9.5, 8.5)

# ---- Performance settings ----

## Frames over which one full hemisphere update is spread. Must be a perfect square.
var frames_to_update: int = 64
## Hemisphere texture resolution. Must be divisible by sqrt(frames_to_update).
var texture_size: int = 768

# ---- Amortization state (mirrors upstream) ----

## Everything the compute shader reads is cached here so it only changes when
## we swap to a new texture — mid-texture changes would tear the hemisphere.
class FrameData:
	var wind_direction: Vector2 = Vector2(1.0, 0.0)
	var wind_speed: float = 1.0
	var density: float = 0.05
	var cloud_coverage: float = 0.25
	var ground_color: Color = Color(1.0, 1.0, 1.0, 1.0)
	var light_direction: Vector3 = Vector3(0.0, 1.0, 0.0)
	var light_energy: float = 1.0
	var light_color: Color = Color(1.0, 1.0, 1.0, 1.0)
	var atmo_sun: Color = Color.WHITE
	var atmo_ambient: Color = Color.WHITE
	var atmo_ground: Color = Color.WHITE
	var _time: float = 0.0
	var _cloud_pos: Vector2 = Vector2.ZERO
	var _detailed_pos: Vector2 = Vector2.ZERO
	var _weather_pos: Vector2 = Vector2.ZERO

var _frame_data: FrameData = FrameData.new()
var _update_position: Vector2i = Vector2i.ZERO
var _update_region_size: int = 96  # texture_size / sqrt(frames_to_update)
var _num_workgroups: int = 12      # ceil(update_region_size / 8)

var _textures: Array[Texture2DRD] = []
var _texture_to_update: int = 0
var _texture_to_blend_from: int = 1
var _texture_to_blend_to: int = 2

var _frame: int = 0
var _can_run: bool = false
var _needs_full_init: bool = true
var _cleaned_up: bool = false

# Noise resources are loaded on the main thread; their RD RIDs are resolved on
# the render thread in _initialize_compute_code (texture_get_rd_texture is
# render-thread-only).
var _large_noise: Texture3D = null
var _small_noise: Texture3D = null
var _weather_noise: Texture2D = null


func initialize() -> void:
	_large_noise = load(LARGE_NOISE_PATH) as Texture3D
	_small_noise = load(SMALL_NOISE_PATH) as Texture3D
	_weather_noise = load(WEATHER_NOISE_PATH) as Texture2D
	if not _large_noise or not _small_noise or not _weather_noise:
		Log.error("sky", "CheapCloudLayer: noise textures missing under assets/sky/clouds/ — cheap clouds disabled")
		return

	var frames_sqrt: int = int(sqrt(float(frames_to_update)))
	_update_region_size = texture_size / frames_sqrt
	if texture_size % frames_sqrt != 0:
		texture_size = _update_region_size * frames_sqrt
		Log.warn("sky", "CheapCloudLayer: texture_size not divisible by sqrt(frames_to_update), clamped to %d" % texture_size)
	@warning_ignore("integer_division")
	_num_workgroups = (_update_region_size + 7) / 8

	RenderingServer.call_on_render_thread(_initialize_compute_code)


## Re-render the full hemisphere ASAP (on enable / after big time jumps).
func request_full_init() -> void:
	_needs_full_init = true


## Advance the amortized update by one frame. Call once per rendered frame.
## Pushes blend textures + blend amount into the sky material.
func update_sky(sky_material: ShaderMaterial) -> void:
	if not _can_run or sky_material == null:
		return

	if _needs_full_init:
		_needs_full_init = false
		_update_per_frame_data()
		# Render two complete textures in one go so clouds are visible
		# immediately (startup hitch is one-time and acceptable — upstream
		# does the same).
		for i in range(frames_to_update * 2):
			update_sky(sky_material)

	if _frame >= frames_to_update:
		_texture_to_update = (_texture_to_update + 1) % 3
		_texture_to_blend_from = (_texture_to_blend_from + 1) % 3
		_texture_to_blend_to = (_texture_to_blend_to + 1) % 3
		_update_per_frame_data()  # Only once per swap or quads get out of sync

		sky_material.set_shader_parameter("cheap_clouds_from", _textures[_texture_to_blend_from])
		sky_material.set_shader_parameter("cheap_clouds_to", _textures[_texture_to_blend_to])
		_frame = 0

	sky_material.set_shader_parameter("cheap_clouds_blend", float(_frame) / float(frames_to_update))

	RenderingServer.call_on_render_thread(_render_process.bind(_texture_to_update))

	_update_position.x += _update_region_size
	if _update_position.x >= texture_size:
		_update_position.x = 0
		_update_position.y += _update_region_size
	if _update_position.y >= texture_size:
		_update_position = Vector2i.ZERO

	_frame += 1


func _update_per_frame_data() -> void:
	_frame_data.light_direction = sun_direction.normalized()
	_frame_data.light_energy = sun_energy
	_frame_data.light_color = sun_color.srgb_to_linear()
	_frame_data.wind_direction = Vector2.from_angle(deg_to_rad(wind_direction_deg))
	_frame_data.wind_speed = wind_speed
	_frame_data.density = density
	_frame_data.cloud_coverage = cloud_coverage
	_frame_data.ground_color = ground_color
	_frame_data.atmo_sun = atmo_sun
	_frame_data.atmo_ambient = atmo_ambient
	_frame_data.atmo_ground = atmo_ground

	# Integrate wind positions over the elapsed time step
	var time: float = Time.get_ticks_msec() / 1000.0
	var delta: float = time - _frame_data._time
	var delta2: float = delta * 0.001
	var wind_dir_norm: Vector2 = _frame_data.wind_direction.normalized()

	_frame_data._time = time
	_frame_data._detailed_pos += delta * wind_dir_norm
	_frame_data._cloud_pos += delta * wind_dir_norm * _frame_data.wind_speed
	_frame_data._weather_pos += delta2 * wind_dir_norm * _frame_data.wind_speed


func cleanup() -> void:
	if _cleaned_up:
		return
	_cleaned_up = true
	_can_run = false
	# Free GPU resources on the render thread — they were created there and
	# may be in use by an in-flight compute list.
	RenderingServer.call_on_render_thread(_free_rd_resources)


###############################################################################
# Everything below runs on the render thread

var _rd: RenderingDevice = null
var _shader_rd: RID = RID()
var _pipeline: RID = RID()
var _texture_rd: Array[RID] = [RID(), RID(), RID()]
var _texture_set: Array[RID] = [RID(), RID(), RID()]
var _noise_uniform_set: RID = RID()
var _atmo_ubo: RID = RID()
var _atmo_uniform_set: RID = RID()
var _noise_sampler: RID = RID()


func _initialize_compute_code() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		Log.warn("sky", "CheapCloudLayer: no RenderingDevice (Compatibility renderer?) — cheap clouds unavailable")
		return

	var shader_file: RDShaderFile = load(SHADER_PATH) as RDShaderFile
	if shader_file == null:
		Log.error("sky", "CheapCloudLayer: failed to load compute shader %s" % SHADER_PATH)
		return
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	_shader_rd = _rd.shader_create_from_spirv(shader_spirv)
	if not _shader_rd.is_valid():
		Log.error("sky", "CheapCloudLayer: compute shader compilation failed")
		return
	_pipeline = _rd.compute_pipeline_create(_shader_rd)

	var tf := RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.width = texture_size
	tf.height = texture_size
	tf.depth = 1
	tf.array_layers = 1
	tf.mipmaps = 1
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		+ RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT \
		+ RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		+ RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		+ RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT

	_noise_uniform_set = _create_noise_uniform_set()
	if not _noise_uniform_set.is_valid():
		return

	# Atmosphere color UBO (LUT replacement): 3 x vec4 std140 = 48 bytes.
	_atmo_ubo = _rd.uniform_buffer_create(48)
	var ubo_uniform := RDUniform.new()
	ubo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	ubo_uniform.binding = 0
	ubo_uniform.add_id(_atmo_ubo)
	_atmo_uniform_set = _rd.uniform_set_create([ubo_uniform], _shader_rd, 2)

	_textures.clear()
	for i in range(3):
		_texture_rd[i] = _rd.texture_create(tf, RDTextureView.new(), [])
		_rd.texture_clear(_texture_rd[i], Color(0, 0, 0, 0), 0, 1, 0, 1)
		_texture_set[i] = _create_texture_uniform_set(_texture_rd[i])
		var tex := Texture2DRD.new()
		tex.texture_rd_rid = _texture_rd[i]
		_textures.push_back(tex)

	_can_run = true
	Log.info("sky", "CheapCloudLayer: initialized (%dx%d hemisphere, %d-frame amortization)" % [texture_size, texture_size, frames_to_update])


func _render_process(p_texture_to_update: int) -> void:
	if not _can_run:
		return

	# Atmosphere colors (cached per swap in FrameData, so mid-texture values
	# stay coherent). 48-byte update per dispatch is negligible.
	var atmo_bytes := PackedFloat32Array([
		_frame_data.atmo_sun.r, _frame_data.atmo_sun.g, _frame_data.atmo_sun.b, 1.0,
		_frame_data.atmo_ambient.r, _frame_data.atmo_ambient.g, _frame_data.atmo_ambient.b, 1.0,
		_frame_data.atmo_ground.r, _frame_data.atmo_ground.g, _frame_data.atmo_ground.b, 1.0,
	]).to_byte_array()
	_rd.buffer_update(_atmo_ubo, 0, atmo_bytes.size(), atmo_bytes)

	var push_constant: PackedFloat32Array = _fill_push_constant()

	var compute_list: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, _texture_set[p_texture_to_update], 0)
	_rd.compute_list_bind_uniform_set(compute_list, _noise_uniform_set, 1)
	_rd.compute_list_bind_uniform_set(compute_list, _atmo_uniform_set, 2)
	_rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
	_rd.compute_list_dispatch(compute_list, _num_workgroups, _num_workgroups, 1)
	_rd.compute_list_end()


func _fill_push_constant() -> PackedFloat32Array:
	# Order must match the Params push constant in cheap_clouds.glsl, padding included.
	var pc := PackedFloat32Array()
	pc.push_back(float(texture_size))
	pc.push_back(float(texture_size))
	pc.push_back(float(_update_position.x))
	pc.push_back(float(_update_position.y))

	pc.push_back(_frame_data._cloud_pos.x)
	pc.push_back(_frame_data._cloud_pos.y)
	pc.push_back(_frame_data._detailed_pos.x)
	pc.push_back(_frame_data._detailed_pos.y)

	pc.push_back(_frame_data._weather_pos.x)
	pc.push_back(_frame_data._weather_pos.y)
	pc.push_back(0.0)  # vec2 pad1
	pc.push_back(0.0)

	pc.push_back(_frame_data.ground_color.r)
	pc.push_back(_frame_data.ground_color.g)
	pc.push_back(_frame_data.ground_color.b)
	pc.push_back(_frame_data.ground_color.a)

	pc.push_back(_frame_data.light_direction.x)
	pc.push_back(_frame_data.light_direction.y)
	pc.push_back(_frame_data.light_direction.z)
	pc.push_back(_frame_data.light_energy)

	pc.push_back(_frame_data.light_color.r)
	pc.push_back(_frame_data.light_color.g)
	pc.push_back(_frame_data.light_color.b)
	pc.push_back(_frame_data._time)

	pc.push_back(0.0)  # float pad2
	pc.push_back(_frame_data.density)
	pc.push_back(_frame_data.cloud_coverage)
	pc.push_back(0.0)  # time_offset (unused)

	return pc


func _create_texture_uniform_set(p_texture_rd: RID) -> RID:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(p_texture_rd)
	return _rd.uniform_set_create([uniform], _shader_rd, 0)


func _create_noise_uniform_set() -> RID:
	var sampler_state := RDSamplerState.new()
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_noise_sampler = _rd.sampler_create(sampler_state)

	var uniforms: Array[RDUniform] = []
	var noise_rids: Array[RID] = [
		RenderingServer.texture_get_rd_texture(_large_noise.get_rid()),
		RenderingServer.texture_get_rd_texture(_small_noise.get_rid()),
		RenderingServer.texture_get_rd_texture(_weather_noise.get_rid()),
	]
	for i in range(3):
		if not noise_rids[i].is_valid():
			Log.error("sky", "CheapCloudLayer: noise texture %d has no RD texture — cheap clouds disabled" % i)
			return RID()
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = i
		uniform.add_id(_noise_sampler)
		uniform.add_id(noise_rids[i])
		uniforms.push_back(uniform)

	return _rd.uniform_set_create(uniforms, _shader_rd, 1)


func _free_rd_resources() -> void:
	if _rd == null:
		return
	for i in range(3):
		if _texture_rd[i].is_valid():
			_rd.free_rid(_texture_rd[i])
			_texture_rd[i] = RID()
	if _atmo_ubo.is_valid():
		_rd.free_rid(_atmo_ubo)
		_atmo_ubo = RID()
	if _shader_rd.is_valid():
		_rd.free_rid(_shader_rd)
		_shader_rd = RID()
	if _noise_sampler.is_valid():
		_rd.free_rid(_noise_sampler)
		_noise_sampler = RID()
