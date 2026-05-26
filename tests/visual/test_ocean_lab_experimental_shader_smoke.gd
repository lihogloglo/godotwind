extends "res://tests/visual/test_ocean_lab.gd"

## Crash smoke for the Ocean Lab Boujie High surface shader.
## Inherits the interactive lab, enables the shader, exercises rebuild paths,
## and verifies the separate SurfaceRefractionLayer stays parked. No captures.


func _ready() -> void:
	super._ready()
	await _wait_frames(8)

	_surface_refraction_enabled = true
	_surface_refraction_debug_mode = 1
	_surface_edge_guard_enabled = true
	_push_surface_refraction_control()
	if _surface_refraction_layer == null:
		_fail("surface refraction layer missing before shader toggle")
		return
	if not bool(_surface_refraction_layer.call("is_enabled")):
		_fail("surface refraction layer did not enable in default mode")
		return

	_toggle_experimental_surface_shader()
	await _wait_frames(12)
	if not _assert_experimental_active("initial toggle"):
		return

	_apply_weather_preset((_current_weather + 1) % WEATHER_PRESETS.size())
	_apply_optical_preset((_current_optical_preset + 1) % OPTICAL_PRESETS.size())
	await _wait_frames(8)
	if not _assert_experimental_active("weather/optics round trip"):
		return

	_toggle_mesh_mode()
	await _wait_frames(12)
	if not _assert_experimental_active("projected mesh rebuild"):
		return

	_toggle_mesh_mode()
	await _wait_frames(12)
	if not _assert_experimental_active("clipmap mesh rebuild"):
		return

	_cycle_quality()
	await _wait_frames(8)
	if not _assert_experimental_mode_state("flat quality rebuild"):
		return

	_cycle_quality()
	await _wait_frames(12)
	if not _assert_experimental_active("high quality rebuild"):
		return

	_toggle_experimental_surface_shader()
	await _wait_frames(8)
	if _experimental_surface_shader_enabled:
		_fail("Boujie shader did not toggle off")
		return
	if OceanManager.get_surface_shader_mode() != OceanMesh.SurfaceShaderMode.DEFAULT:
		_fail("OceanManager did not return to default shader mode")
		return
	if _surface_refraction_layer == null or not bool(_surface_refraction_layer.call("is_enabled")):
		_fail("surface refraction layer did not restore after returning to default")
		return
	if _surface_refraction_debug_mode != 1 or not _surface_edge_guard_enabled:
		_fail("surface refraction debug/guard state was not restored")
		return

	print("[Ocean Lab Boujie High Shader Smoke] passed")
	get_tree().quit(0)


func _wait_frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _assert_experimental_active(label: String) -> bool:
	if not _assert_experimental_mode_state(label):
		return false
	if OceanManager.get_water_quality() != OceanMesh.QualityMode.HIGH:
		return true
	var mat := _get_ocean_material()
	if mat == null or mat.shader == null:
		return _fail("ocean material missing during %s" % label)
	var shader_path := mat.shader.resource_path
	if not shader_path.contains("ocean_boujie_experimental"):
		return _fail("unexpected shader during %s: %s" % [label, shader_path])
	return true


func _assert_experimental_mode_state(label: String) -> bool:
	if not _experimental_surface_shader_enabled:
		return _fail("Boujie flag dropped during %s" % label)
	if OceanManager.get_surface_shader_mode() != OceanMesh.SurfaceShaderMode.BOUJIE_EXPERIMENTAL:
		return _fail("OceanManager shader mode dropped during %s" % label)
	if OceanManager.has_method("get_surface_shader_mode_name") and OceanManager.get_surface_shader_mode_name() != "Boujie High":
		return _fail("OceanManager shader mode name was %s during %s" % [
			OceanManager.get_surface_shader_mode_name(),
			label,
		])
	if _surface_shader_button != null and _surface_shader_button.text != "Shader: Boujie High":
		return _fail("surface shader button text was %s during %s" % [
			_surface_shader_button.text,
			label,
		])
	if _surface_refraction_layer != null and bool(_surface_refraction_layer.call("is_enabled")):
		return _fail("surface refraction layer stayed enabled during %s" % label)
	if _surface_refraction_button != null and not _surface_refraction_button.disabled:
		return _fail("surface refraction button was not disabled during %s" % label)
	return true


func _fail(message: String) -> bool:
	push_error("[Ocean Lab Boujie High Shader Smoke] %s" % message)
	get_tree().quit(1)
	return false
