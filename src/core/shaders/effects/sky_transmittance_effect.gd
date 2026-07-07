## SkyTransmittanceEffect - Precomputed atmospheric transmittance LUT
##
## Precomputed sky-transmittance pass (Bruneton & Neyret 2008).
## Generates a 2D lookup table of atmospheric transmittance (RGB extinction)
## indexed by (cos_zenith_angle, normalized_altitude).
##
## The LUT is stored as a shared texture via ShaderManager so that downstream
## effects (volumetric fog, godrays, sky inscattering) can look up atmospheric
## extinction without re-integrating. This matches the multi-pass architecture
## where RT_SkyTransmittance feeds into RT_Sky and RT_Fog.
##
## The LUT is regenerated when weather changes (aerosol density varies per weather
## type) and on the first frame. During stable weather it can skip recomputation.
##
## Shared texture name: "sky_transmittance"
## LUT lookup: UV = (cosTheta * 0.5 + 0.5, normalizedAltitude)
@tool
class_name SkyTransmittanceEffect
extends PostProcessEffect

const SHADER_PATH := "res://src/core/shaders/compute/sky_transmittance.glsl"
const SHARED_TEXTURE_NAME := "sky_transmittance"

## LUT dimensions. 256x64 transmittance-table resolution.
## U = cos(zenith) needs higher resolution (256) for horizon precision.
## V = altitude needs less (64) — exponential density change is smooth.
const LUT_WIDTH: int = 256
const LUT_HEIGHT: int = 64

## Internal LUT texture
var _lut_texture: RID

## Sampler for the LUT (linear filtering for smooth interpolation)
var _lut_sampler: RID

## Cached weather state for dirty detection
var _cached_weather_id: float = -1.0
var _cached_next_weather_id: float = -1.0
var _cached_weather_transition: float = -1.0

## Current weather params for push constants (written on main thread)
var _current_weather_id: float = 0.0
var _current_next_weather_id: float = 0.0
var _current_weather_transition: float = 0.0
var _current_game_hour: float = 12.0

## Whether the LUT needs regeneration
var _lut_dirty: bool = true

## Frame counter for initial generation
var _frame_count: int = 0


func _init() -> void:
	super._init()

	effect_name = "sky_transmittance"
	display_name = "Sky Transmittance LUT"
	description = "Precomputed atmospheric transmittance lookup table (Bruneton 2008). Feeds into fog and godrays for physically-correct atmospheric scattering."
	category = "Atmosphere"
	# Runs BEFORE fog (10) and godrays (11) so the LUT is ready
	render_priority = 5

	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	# We don't read color or depth — we just write to our own LUT texture
	access_resolved_color = true
	access_resolved_depth = false
	needs_depth = false

	_define_parameters()


func _define_parameters() -> void:
	register_parameter("aerosol_turbidity", 1.0, 0.1, 5.0, 0.1,
		"Aerosol Turbidity", "Base multiplier for aerosol (Mie) scattering density")

	register_parameter("update_interval", 0.5, 0.0, 5.0, 0.1,
		"Update Interval", "Seconds between LUT recomputation during weather transitions (0 = every frame)")


func on_effect_added() -> void:
	if not load_compute_shader(SHADER_PATH):
		push_error("[SkyTransmittanceEffect] Failed to load shader")
		return

	_create_lut_texture()
	_create_sampler()

	Log.info("shaders", "SkyTransmittanceEffect initialized (%dx%d LUT)" % [LUT_WIDTH, LUT_HEIGHT])


func _create_lut_texture() -> void:
	if rd == null:
		return

	var fmt := RDTextureFormat.new()
	fmt.width = LUT_WIDTH
	fmt.height = LUT_HEIGHT
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D

	_lut_texture = rd.texture_create(fmt, RDTextureView.new())

	if _lut_texture.is_valid():
		# Register in ShaderManager's shared texture registry
		ShaderManager.set_shared_texture(SHARED_TEXTURE_NAME, _lut_texture)


func _create_sampler() -> void:
	if rd == null:
		return

	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE

	_lut_sampler = rd.sampler_create(sampler_state)


## Call from main thread to cache weather state (avoids render-thread data race)
func update_weather_cache() -> void:
	if WeatherManager and WeatherManager.enabled:
		var result: WeatherTypes.WeatherResult = WeatherManager.get_weather_result()
		_current_weather_id = float(result.current_type)
		_current_next_weather_id = float(result.next_type)
		_current_weather_transition = result.transition_factor
		_current_game_hour = result.game_hour

		# Check if weather changed — mark LUT dirty
		if _current_weather_id != _cached_weather_id \
				or _current_next_weather_id != _cached_next_weather_id \
				or absf(_current_weather_transition - _cached_weather_transition) > 0.01:
			_lut_dirty = true


func _render_callback(effect_callback_type: int, render_data: RenderData) -> void:
	if not effect_enabled:
		return
	if not pipeline_rid.is_valid() or not _lut_texture.is_valid():
		return

	if rd == null:
		rd = RenderingServer.get_rendering_device()
		if rd == null:
			return

	# Only regenerate when dirty (weather changed or first frame)
	_frame_count += 1
	if not _lut_dirty and _frame_count > 2:
		return

	_generate_lut()

	# Update cache
	_cached_weather_id = _current_weather_id
	_cached_next_weather_id = _current_next_weather_id
	_cached_weather_transition = _current_weather_transition
	_lut_dirty = false


func _generate_lut() -> void:
	# Build push constants (32 bytes = 8 floats)
	var pc := PackedFloat32Array()

	# weather_params (vec4)
	pc.append(_current_weather_id)
	pc.append(_current_next_weather_id)
	pc.append(_current_weather_transition)
	pc.append(_current_game_hour)

	# lut_size (vec2) + aerosol_turbidity + padding
	pc.append(float(LUT_WIDTH))
	pc.append(float(LUT_HEIGHT))
	pc.append(get_param("aerosol_turbidity"))
	pc.append(0.0)  # padding

	# Create uniform set
	var uniforms: Array[RDUniform] = []

	var u_lut := RDUniform.new()
	u_lut.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_lut.binding = 0
	u_lut.add_id(_lut_texture)
	uniforms.append(u_lut)

	var uniform_set := rd.uniform_set_create(uniforms, shader_rid, 0)
	if not uniform_set.is_valid():
		return

	# Dispatch compute shader
	var groups_x := (LUT_WIDTH + 7) / 8
	var groups_y := (LUT_HEIGHT + 7) / 8

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline_rid)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, pc.to_byte_array(), pc.size() * 4)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	rd.free_rid(uniform_set)


## Get the LUT texture RID (for direct access by other effects)
func get_lut_texture() -> RID:
	return _lut_texture


## Get the LUT sampler RID
func get_lut_sampler() -> RID:
	return _lut_sampler


func on_effect_removed() -> void:
	super.on_effect_removed()

	# Remove from shared texture registry
	ShaderManager.clear_shared_texture(SHARED_TEXTURE_NAME)

	if rd:
		if _lut_texture.is_valid():
			rd.free_rid(_lut_texture)
			_lut_texture = RID()
		if _lut_sampler.is_valid():
			rd.free_rid(_lut_sampler)
			_lut_sampler = RID()
