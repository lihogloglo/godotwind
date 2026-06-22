extends GdUnitTestSuite

const OceanControlsScript := preload("res://src/tools/ui/ocean_controls.gd")
const RenderLayersScript := preload("res://src/core/world/render_layers.gd")


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


func test_show_ocean_toggle_tracks_ocean_surface_without_clearing_water_preferences() -> void:
	var controls: OceanControls = OceanControlsScript.new({})
	controls.set_underwater_feature_enabled(&"snell", false)
	controls.set_underwater_feature_enabled(&"particles", false)

	controls.on_show_ocean_toggled(false)
	var status := controls.get_runtime_status()

	assert_bool(status["ocean_enabled"]).is_false()
	assert_bool(status["all_water_enabled"]).is_true()
	assert_bool(controls.is_underwater_feature_enabled(&"snell")).is_false()
	assert_bool(controls.is_underwater_feature_enabled(&"particles")).is_false()
	assert_bool(status["underwater_particles_enabled"]).is_false()

	var source := FileAccess.get_file_as_string("res://src/tools/ui/ocean_controls.gd")
	assert_bool(source.contains("set_world_space_ocean_visible(false)\n\t\tset_enabled(false)")).is_true()


func test_temporary_world_space_ocean_hide_does_not_clear_user_toggle() -> void:
	var controls: OceanControls = OceanControlsScript.new({})

	controls.set_world_space_ocean_visible(false)

	assert_bool(controls.show_ocean).is_true()
	assert_bool(controls.all_water_enabled).is_true()


func test_world_explorer_disables_main_scene_water_by_default_for_performance() -> void:
	var source := FileAccess.get_file_as_string("res://src/tools/world_explorer.gd")

	assert_bool(source.contains("_ocean_controls.show_ocean = false")).is_true()
	assert_bool(source.contains("_ocean_controls.set_all_water_enabled(false)")).is_true()


func test_ocean_toggle_restores_all_water_from_lazy_default() -> void:
	var controls: OceanControls = OceanControlsScript.new({})
	controls.all_water_enabled = false

	controls.on_show_ocean_toggled(true)

	assert_bool(controls.show_ocean).is_true()
	assert_bool(controls.all_water_enabled).is_true()


func test_ocean_camera_layer_uses_shared_render_policy() -> void:
	var camera := Camera3D.new()
	camera.cull_mask = RenderLayersScript.EXTERIOR_WORLD
	var controls: OceanControls = OceanControlsScript.new({})

	controls.set_camera(camera)

	assert_bool(RenderLayersScript.has_water_surface(camera.cull_mask)).is_true()
	assert_bool(RenderLayersScript.has_exterior_world(camera.cull_mask)).is_true()
	camera.free()


func test_world_space_ocean_restore_uses_active_camera_configuration_path() -> void:
	var source := FileAccess.get_file_as_string("res://src/tools/ui/ocean_controls.gd")

	assert_bool(source.contains("func set_world_space_ocean_visible(visible: bool)")).is_true()
	assert_bool(source.contains("var active_camera := _get_active_camera()")).is_true()
	assert_bool(source.contains("set_camera(active_camera)")).is_true()


func test_ocean_provider_release_stops_all_processing() -> void:
	var source := FileAccess.get_file_as_string("res://src/core/water/ocean_fft_provider.gd")

	assert_bool(source.contains("func release_runtime_resources()")).is_true()
	assert_bool(source.contains("set_process(false)\n\tset_physics_process(false)")).is_true()
	assert_bool(source.contains("func set_ocean_surface_visible(enabled: bool)")).is_true()
	assert_bool(source.contains("_ocean_spray.visible = enabled")).is_true()
