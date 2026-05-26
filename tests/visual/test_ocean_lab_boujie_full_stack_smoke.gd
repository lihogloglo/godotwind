extends "res://tests/visual/test_ocean_lab.gd"

## Crash smoke for the Ocean Lab Boujie Full preset.
## Enables the Boujie High surface shader plus the requested underwater feature
## stack, places the camera below water, waits for dispatch/particle state, and
## exits without screenshots or automated capture.

var _smoke_frames: int = 0
var _finishing: bool = false
var _smoke_stage: int = 0

const FEATURE_ABSORPTION_FOG := 1
const FEATURE_SNELL := 2
const FEATURE_WOBBLE := 8
const FEATURE_CAUSTICS := 64


func _ready() -> void:
	super._ready()
	_toggle_boujie_full_preset()
	_place_camera_underwater()
	_refresh_control_labels()
	print("[Ocean Lab Boujie Full Stack Smoke] Ready")


func _process(delta: float) -> void:
	if _finishing:
		return
	super._process(delta)
	_smoke_frames += 1
	if _smoke_frames < 30:
		return
	if _smoke_stage == 0:
		if not _assert_boujie_full_stack():
			return
		_toggle_boujie_full_preset()
		_smoke_stage = 1
		_smoke_frames = 0
		return
	if not _assert_boujie_full_restored():
		return
	print("[Ocean Lab Boujie Full Stack Smoke] passed")
	_finish_smoke(0)


func _assert_boujie_full_stack() -> bool:
	if not _is_boujie_full_preset_active():
		return _fail("Boujie Full preset state did not stay active")
	if OceanManager == null or OceanManager.get_surface_shader_mode() != OceanMesh.SurfaceShaderMode.BOUJIE_EXPERIMENTAL:
		return _fail("OceanManager was not in Boujie shader mode")
	if OceanManager.has_method("get_surface_shader_mode_name") and OceanManager.get_surface_shader_mode_name() != "Boujie High":
		return _fail("OceanManager shader mode name was %s" % OceanManager.get_surface_shader_mode_name())
	var mat := _get_ocean_material()
	if mat == null or mat.shader == null or not mat.shader.resource_path.contains("ocean_boujie_experimental"):
		return _fail("ocean material was not using a Boujie shader")
	if mat.get_shader_parameter("boujie_texture_albedo") == null:
		return _fail("Boujie albedo texture was not bound")
	if mat.get_shader_parameter("boujie_texture_refraction") == null:
		return _fail("Boujie refraction texture was not bound")
	if mat.get_shader_parameter("micro_normal_texture") == null:
		return _fail("Boujie micro-normal texture was not bound")
	var wind_dir: Vector2 = mat.get_shader_parameter("wind_dir_xz")
	if wind_dir.length_squared() < 0.5:
		return _fail("Boujie surface wind direction was not pushed")
	if float(mat.get_shader_parameter("wind_speed_mps")) <= 0.0:
		return _fail("Boujie surface wind speed was not pushed")
	if _world_env == null or _world_env.environment == null or not _world_env.environment.ssr_enabled:
		return _fail("environment SSR was not applied to the Environment")
	if _surface_refraction_layer != null and bool(_surface_refraction_layer.call("is_enabled")):
		return _fail("surface refraction layer stayed enabled under Boujie Full")
	if _waterline_enabled:
		return _fail("receiver waterline enabled under Boujie Full; underwater medium must be single-owner")
	if _waterline_stack != null and _waterline_stack.enabled:
		return _fail("receiver waterline stack activated under Boujie Full")
	if not _wet_compositor_enabled:
		return _fail("wet compositor flag did not enable under Boujie Full")
	if _wet_effect == null or not _wet_effect.effect_enabled:
		return _fail("wet compositor effect did not enable under Boujie Full")
	if _underwater_effect == null or not _underwater_effect.effect_enabled:
		return _fail("underwater compositor did not enable")
	if _underwater_quality_tier != UW_QUALITY_NAMES.size() - 1:
		return _fail("underwater quality was not high")
	if not (_uw_absorption_enabled and _uw_snell_enabled and _uw_wobble_effect_enabled and _uw_particles_enabled and _uw_caustics_enabled):
		return _fail("underwater feature flags were not all requested")
	var perf := _get_underwater_perf_snapshot()
	if not bool(perf.get("scene_copy_active", false)):
		return _fail("underwater wobble source copy did not activate")
	var feature_flags := int(perf.get("feature_flags", 0))
	var expected_flags := FEATURE_ABSORPTION_FOG | FEATURE_SNELL | FEATURE_WOBBLE | FEATURE_CAUSTICS
	if (feature_flags & expected_flags) != expected_flags:
		return _fail("underwater compositor feature flags missing: got %d expected mask %d" % [feature_flags, expected_flags])
	if not bool(perf.get("caustics_valid", false)):
		return _fail("underwater caustics texture/RID was not valid")
	if not bool(perf.get("snell_enabled", false)) or not bool(perf.get("caustics_enabled", false)):
		return _fail("underwater Snell/caustics perf status did not enable")
	if int(perf.get("frame", -1)) < 0:
		return _fail("underwater compositor did not report a dispatch frame")
	if not perf.has("total_ms"):
		return _fail("underwater compositor did not report timing")
	var wet_perf := _get_wet_perf_snapshot()
	if wet_perf.is_empty() or int(wet_perf.get("frame", -1)) < 0:
		return _fail("wet compositor did not report a dispatch frame")
	var water_state := _get_water_state()
	if water_state == null or not water_state.has_fft() or not water_state.can_sample_height():
		return _fail("shared WaterSurfaceState was not FFT/query ready")
	var particle_status := _get_underwater_particles_status()
	if not bool(particle_status.get("enabled", false)):
		return _fail("underwater particles were not enabled")
	if int(particle_status.get("quality", -1)) != 3:
		return _fail("underwater particle quality was not high")
	if int(particle_status.get("particle_count", 0)) <= 0:
		return _fail("underwater particle count was zero")
	if not bool(particle_status.get("emitting", false)):
		return _fail("underwater particles were not emitting below water")
	return true


func _assert_boujie_full_restored() -> bool:
	if _is_boujie_full_preset_active():
		return _fail("Boujie Full stayed active after pressing the button again")
	if _experimental_surface_shader_enabled:
		return _fail("Boujie surface shader stayed enabled after Boujie Full disable")
	if OceanManager == null or OceanManager.get_surface_shader_mode() != OceanMesh.SurfaceShaderMode.DEFAULT:
		return _fail("OceanManager did not return to the default surface shader")
	if _underwater_effect_enabled:
		return _fail("underwater compositor request stayed enabled after Boujie Full disable")
	if _uw_particles_enabled:
		return _fail("underwater particles stayed enabled after Boujie Full disable")
	if _waterline_enabled:
		return _fail("receiver waterline stayed enabled after Boujie Full disable")
	if _wet_compositor_enabled:
		return _fail("wet compositor stayed enabled after Boujie Full disable")
	if _boujie_full_button != null and _boujie_full_button.text != "Boujie Full: Enable":
		return _fail("Boujie Full button label did not return to Enable")
	return true


func _place_camera_underwater() -> void:
	if _camera == null:
		return
	var target := _playground_origin
	var sample_pos := target + Vector3(0.0, 0.0, 18.0)
	var water_y := _sea_level
	var state := _get_water_state()
	if state != null and state.can_sample_height():
		water_y = state.sample_height(sample_pos, _sea_level)
	_camera.global_position = Vector3(sample_pos.x, water_y - 2.0, sample_pos.z)
	_camera.look_at(Vector3(target.x, water_y - 2.0, target.z), Vector3.UP)


func _fail(message: String) -> bool:
	push_error("[Ocean Lab Boujie Full Stack Smoke] %s" % message)
	_finish_smoke(1)
	return false


func _finish_smoke(exit_code: int) -> void:
	_finishing = true
	_underwater_effect_enabled = false
	_uw_particles_enabled = false
	_push_underwater_effect_controls()
	if _underwater_effect != null:
		_underwater_effect.effect_enabled = false
		_underwater_effect.blend_factor = 0.0
	if _waterline_stack != null:
		_waterline_stack.set_enabled(false)
	if _water_compositor != null:
		_water_compositor.compositor_effects = []
	if _world_env != null:
		_world_env.compositor = null
	await get_tree().process_frame
	await get_tree().process_frame
	if _underwater_effect != null:
		_underwater_effect.on_effect_removed()
		_underwater_effect = null
	if _waterline_stack != null:
		_waterline_stack.shutdown()
		_waterline_stack.queue_free()
		_waterline_stack = null
	if _wet_effect != null:
		_wet_effect.effect_enabled = false
		_wet_effect.blend_factor = 0.0
		_wet_effect.on_effect_removed()
		_wet_effect = null
	if OceanManager != null and OceanManager.has_method("release_runtime_resources"):
		OceanManager.release_runtime_resources()
	_shutdown_shader_manager_effects()
	for _i in range(6):
		await get_tree().process_frame
	get_tree().quit(exit_code)


func _shutdown_shader_manager_effects() -> void:
	var shader_manager := get_node_or_null("/root/ShaderManager")
	if shader_manager != null and shader_manager.has_method("shutdown"):
		shader_manager.call("shutdown")
