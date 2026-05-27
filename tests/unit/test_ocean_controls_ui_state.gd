extends GdUnitTestSuite

const OceanControlsScript := preload("res://src/tools/ui/ocean_controls.gd")


func test_underwater_feature_choices_survive_process_sync() -> void:
	var controls: OceanControls = OceanControlsScript.new({})
	controls.set_underwater_feature_enabled(&"snell", false)
	controls.set_underwater_feature_enabled(&"wobble", false)

	controls.process(0.016)

	assert_bool(controls.is_underwater_feature_enabled(&"snell")).is_false()
	assert_bool(controls.is_underwater_feature_enabled(&"wobble")).is_false()
	assert_bool(controls.is_underwater_feature_enabled(&"absorption_fog")).is_true()


func test_particle_toggle_uses_ocean_manager_state_not_compositor_feature_flag() -> void:
	var controls: OceanControls = OceanControlsScript.new({})
	controls.set_underwater_feature_enabled(&"particles", false)

	var status := controls.get_runtime_status()

	assert_bool(status["underwater_particles_enabled"]).is_false()
	assert_bool(controls.is_underwater_feature_enabled(&"particles")).is_false()
	assert_bool(controls.underwater_features.has(&"particles")).is_false()
