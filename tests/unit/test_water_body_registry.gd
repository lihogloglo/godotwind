extends GdUnitTestSuite

const WaterBodyDescriptorScript := preload("res://src/core/water/water_body_descriptor.gd")
const WaterBodyRegistryScript := preload("res://src/core/water/water_body_registry.gd")
const WaterSystemScript := preload("res://src/core/water/water_system.gd")
const WaterVolumeScript := preload("res://src/core/water/water_volume.gd")
const PolygonWaterVolumeScript := preload("res://src/core/water/polygon_water_volume.gd")

class CountingCoverageSource:
	extends RefCounted

	var body_id: StringName = &"counting_source"
	var body_type: StringName = &"lake"
	var priority: int = 100
	var bounds: AABB = AABB(Vector3(-5.0, -10.0, -5.0), Vector3(10.0, 20.0, 10.0))
	var bounds_valid: bool = true
	var coverage_calls: int = 0

	func sample_coverage(_world_pos: Vector3) -> float:
		coverage_calls += 1
		return 1.0

	func sample_height(_world_pos: Vector3, _fallback: float = NAN) -> float:
		return 0.0


func test_registry_uses_highest_priority_active_body() -> void:
	var registry: RefCounted = WaterBodyRegistryScript.new()
	var lake := _descriptor(&"lake", WaterBodyDescriptorScript.TYPE_LAKE, 100, 1.0, Vector3.ZERO, 1.0, Vector3.ZERO)
	var river := _descriptor(&"river", WaterBodyDescriptorScript.TYPE_RIVER, 200, 3.0, Vector3.ZERO, 1.0, Vector3(2.0, 0.0, 0.0))

	assert_int(registry.register_body(lake)).is_equal(OK)
	assert_int(registry.register_body(river)).is_equal(OK)

	var pos := Vector3(0.0, 0.0, 0.0)
	assert_float(registry.sample_height(pos, -INF)).is_equal_approx(3.0, 0.001)
	assert_that(registry.sample_water_body_id(pos)).is_equal(&"river")
	assert_vector(registry.sample_velocity(pos)).is_equal(Vector3(2.0, 0.0, 0.0))


func test_registry_falls_back_when_no_body_covers_position() -> void:
	var registry: RefCounted = WaterBodyRegistryScript.new()
	var lake := _descriptor(&"lake", WaterBodyDescriptorScript.TYPE_LAKE, 100, 1.0, Vector3(100.0, 0.0, 100.0), 1.0, Vector3.ZERO)
	assert_int(registry.register_body(lake)).is_equal(OK)

	assert_float(registry.sample_height(Vector3.ZERO, -123.0)).is_equal_approx(-123.0, 0.001)
	assert_that(registry.sample_water_body_id(Vector3.ZERO)).is_equal(WaterSurfaceState.WATER_BODY_NONE)


func test_registry_skips_coverage_sampling_outside_valid_source_bounds() -> void:
	var registry: RefCounted = WaterBodyRegistryScript.new()
	var source := CountingCoverageSource.new()
	assert_int(registry.register_body(source)).is_equal(OK)

	assert_float(registry.sample_coverage(Vector3(50.0, 1000.0, 0.0), -1.0)).is_equal_approx(-1.0, 0.001)
	assert_int(source.coverage_calls).is_equal(0)

	assert_float(registry.sample_coverage(Vector3(0.0, 1000.0, 0.0), -1.0)).is_equal_approx(1.0, 0.001)
	assert_int(source.coverage_calls).is_equal(1)
	var stats: Dictionary = registry.get_stats()
	assert_int(int(stats.get("bounds_reject_count", 0))).is_equal(1)


func test_ocean_manager_unified_query_does_not_report_sea_level_outside_registered_body_when_ocean_disabled() -> void:
	var manager: Node = auto_free(WaterSystemScript.new())
	var lake := _descriptor(&"lake", WaterBodyDescriptorScript.TYPE_LAKE, 100, 1.0, Vector3(100.0, 0.0, 100.0), 1.0, Vector3.ZERO)

	assert_int(manager.register_water_body(lake)).is_equal(OK)

	assert_float(manager.sample_water_height(Vector3.ZERO)).is_equal(-INF)
	assert_float(manager.sample_water_coverage(Vector3.ZERO)).is_equal_approx(0.0, 0.001)


func test_ocean_manager_water_body_atlas_is_disabled_by_default() -> void:
	var manager: Node = auto_free(WaterSystemScript.new())
	var lake := _descriptor(&"lake", WaterBodyDescriptorScript.TYPE_LAKE, 100, 7.0, Vector3.ZERO, 10.0, Vector3.ZERO)
	assert_int(manager.register_water_body(lake)).is_equal(OK)

	manager.force_update_water_body_atlas(Vector3.ZERO)

	assert_bool(manager.has_water_body_atlas()).is_false()
	assert_bool(manager.is_water_body_atlas_enabled()).is_false()
	var status: Dictionary = manager.get_water_body_runtime_status()
	assert_bool(bool(status.get("atlas_enabled", true))).is_false()
	assert_bool(bool(status.get("atlas_available", true))).is_false()


func test_ocean_toggle_does_not_enable_water_body_atlas() -> void:
	var manager: Node = auto_free(WaterSystemScript.new())
	add_child(manager)
	var lake := _descriptor(&"lake", WaterBodyDescriptorScript.TYPE_LAKE, 100, 7.0, Vector3.ZERO, 10.0, Vector3.ZERO)

	manager.set_enabled(true)
	assert_bool(manager.is_system_enabled()).is_true()
	assert_int(manager.register_water_body(lake)).is_equal(OK)
	manager.force_update_water_body_atlas(Vector3.ZERO)

	assert_bool(manager.has_water_body_atlas()).is_false()
	assert_bool(manager.is_water_body_atlas_enabled()).is_false()
	manager.set_enabled(false)
	manager.release_runtime_resources()
	await get_tree().process_frame


func test_water_system_generated_water_root_is_owned_by_water_world() -> void:
	var manager: Node = auto_free(WaterSystemScript.new())
	add_child(manager)
	await get_tree().process_frame

	var water_world: Node = manager.get_water_world()
	var ocean_provider: Node = manager.get_ocean_provider()
	var generated_root: Node3D = manager.get_generated_water_root()

	assert_object(water_world).is_not_null()
	assert_object(ocean_provider).is_not_null()
	assert_object(generated_root).is_not_null()
	assert_object(generated_root.get_parent()).is_same(water_world)
	assert_str(generated_root.name).is_equal("GeneratedWaterBodies")

	manager.set_enabled(false)
	await get_tree().process_frame

	assert_bool(is_instance_valid(generated_root)).is_true()
	assert_object(generated_root.get_parent()).is_same(water_world)


func test_ocean_toggle_disables_ocean_surface_without_disabling_registered_water() -> void:
	var manager: Node = auto_free(WaterSystemScript.new())
	add_child(manager)
	await get_tree().process_frame

	var lake := _descriptor(&"lake", WaterBodyDescriptorScript.TYPE_LAKE, 100, 7.0, Vector3.ZERO, 10.0, Vector3.ZERO)
	assert_int(manager.register_water_body(lake)).is_equal(OK)

	manager.set_enabled(true)
	assert_bool(manager.is_system_enabled()).is_true()
	manager.set_water_layer_enabled(&"ocean_surface", false)

	assert_bool(manager.is_system_enabled()).is_true()
	assert_bool(manager.is_water_layer_enabled(&"ocean_surface")).is_false()
	assert_float(manager.sample_water_height(Vector3.ZERO)).is_equal_approx(7.0, 0.001)
	assert_that(manager.sample_water_body_id_at(Vector3.ZERO)).is_equal(&"lake")

	manager.set_water_layer_enabled(&"all", false)

	assert_bool(manager.is_water_layer_enabled(&"all")).is_false()
	assert_float(manager.sample_water_height(Vector3.ZERO)).is_equal(-INF)
	assert_float(manager.sample_water_coverage(Vector3.ZERO)).is_equal_approx(0.0, 0.001)


func test_ocean_manager_water_body_atlas_encodes_registered_coverage_and_height() -> void:
	var manager: Node = auto_free(WaterSystemScript.new())
	var lake := _descriptor(&"lake", WaterBodyDescriptorScript.TYPE_LAKE, 100, 7.0, Vector3.ZERO, 10.0, Vector3.ZERO)
	assert_int(manager.register_water_body(lake)).is_equal(OK)

	manager.set_water_body_atlas_enabled(true)
	manager.force_update_water_body_atlas(Vector3.ZERO)

	assert_bool(manager.has_water_body_atlas()).is_true()
	var center_sample: Dictionary = manager.sample_water_body_atlas(Vector3.ZERO)
	assert_float(center_sample.get("coverage", 0.0)).is_greater(0.5)
	assert_float(center_sample.get("height", 0.0)).is_equal_approx(7.0, 0.001)
	var dry_sample: Dictionary = manager.sample_water_body_atlas(Vector3(80.0, 0.0, 0.0))
	assert_float(dry_sample.get("coverage", 1.0)).is_equal_approx(0.0, 0.001)


func test_water_surface_state_exposes_water_body_atlas_cpu_sample() -> void:
	var manager: Node = auto_free(WaterSystemScript.new())
	var river := _descriptor(&"river", WaterBodyDescriptorScript.TYPE_RIVER, 100, 3.5, Vector3.ZERO, 12.0, Vector3(1.0, 0.0, 0.0))
	assert_int(manager.register_water_body(river)).is_equal(OK)
	manager.set_water_body_atlas_enabled(true)
	manager.force_update_water_body_atlas(Vector3.ZERO)

	var state: WaterSurfaceState = manager.get_water_surface_state()
	var sample := state.sample_water_body_atlas(Vector3.ZERO)

	assert_bool(state.water_body_atlas_available).is_true()
	assert_object(state.water_body_atlas_texture).is_not_null()
	assert_float(sample.get("coverage", 0.0)).is_greater(0.5)
	assert_float(sample.get("height", 0.0)).is_equal_approx(3.5, 0.001)


func test_public_local_water_update_rebuilds_atlas_before_interaction_step() -> void:
	var manager: Node = auto_free(WaterSystemScript.new())
	var river := _descriptor(&"river", WaterBodyDescriptorScript.TYPE_RIVER, 100, 1.25, Vector3.ZERO, 12.0, Vector3(2.0, 0.0, 0.0))
	assert_int(manager.register_water_body(river)).is_equal(OK)

	manager.set_water_body_atlas_enabled(true)
	manager.update_local_water_interactions(0.0, Vector3.ZERO)

	assert_bool(manager.has_water_body_atlas()).is_true()
	var sample: Dictionary = manager.sample_water_body_atlas(Vector3.ZERO)
	assert_float(sample.get("coverage", 0.0)).is_greater(0.5)
	assert_float(sample.get("height", 0.0)).is_equal_approx(1.25, 0.001)
	manager.release_runtime_resources()
	await get_tree().process_frame


func test_ocean_manager_local_flow_obstacle_changes_sampled_registered_velocity() -> void:
	var manager: Node = auto_free(WaterSystemScript.new())
	var river := _descriptor(&"river", WaterBodyDescriptorScript.TYPE_RIVER, 100, 0.0, Vector3.ZERO, 20.0, Vector3(2.0, 0.0, 0.0))
	assert_int(manager.register_water_body(river)).is_equal(OK)

	var baseline: Vector3 = manager.sample_water_velocity(Vector3.ZERO)
	manager.emit_water_flow_obstacle(Vector3.ZERO, 1.5, 0.5, 0.0, &"river")
	var obstructed: Vector3 = manager.sample_water_velocity(Vector3.ZERO)
	var base_after_obstacle: Vector3 = manager.sample_base_water_velocity(Vector3.ZERO)

	assert_float(baseline.x).is_equal_approx(2.0, 0.001)
	assert_float(obstructed.x).is_less(baseline.x)
	assert_float(base_after_obstacle.x).is_equal_approx(2.0, 0.001)
	assert_float(obstructed.z).is_equal_approx(0.0, 0.001)
	manager.release_runtime_resources()
	await get_tree().process_frame


func test_water_volume_descriptor_reports_flow_velocity() -> void:
	var volume: WaterVolume = auto_free(WaterVolumeScript.new())
	add_child(volume)
	volume.water_type = WaterVolume.WaterType.RIVER
	volume.flow_direction = Vector2(0.0, 1.0)
	volume.flow_speed = 2.0
	volume.current_strength = 1.5
	volume.size = Vector3(10.0, 4.0, 10.0)
	volume.water_surface_height = 1.0
	await get_tree().process_frame

	var descriptor := volume.get_water_body_descriptor()
	var pos := volume.global_position + Vector3(0.0, 0.5, 0.0)

	assert_float(descriptor.sample_coverage(pos)).is_equal_approx(1.0, 0.001)
	assert_float(descriptor.sample_height(pos)).is_equal_approx(1.0, 0.001)
	assert_vector(descriptor.sample_velocity(pos)).is_equal(Vector3(0.0, 0.0, 3.0))


func test_water_volume_uses_shared_shader_resource() -> void:
	var volume: WaterVolume = auto_free(WaterVolumeScript.new())
	add_child(volume)
	await get_tree().process_frame

	var mesh_instance := volume.get_node("WaterSurface") as MeshInstance3D
	var material := mesh_instance.material_override as ShaderMaterial

	assert_object(material).is_not_null()
	assert_object(material.shader).is_not_null()
	assert_str(material.shader.resource_path).is_equal("res://src/core/water/shaders/water_volume.gdshader")


func test_water_volume_does_not_own_buoyancy_physics() -> void:
	var volume: WaterVolume = auto_free(WaterVolumeScript.new())
	add_child(volume)
	await get_tree().process_frame

	var source := FileAccess.get_file_as_string("res://src/core/water/water_volume.gd")

	assert_bool(_object_has_property(volume, "enable_buoyancy")).is_false()
	assert_bool(source.contains("apply_central_force")).is_false()
	assert_bool(source.contains("_apply_buoyancy_force")).is_false()
	assert_bool(source.contains("_calculate_submersion")).is_false()


func test_water_volume_area_uses_exported_detection_collision_mask() -> void:
	var volume: WaterVolume = auto_free(WaterVolumeScript.new())
	volume.detection_collision_mask = 4
	add_child(volume)
	await get_tree().process_frame

	var area := volume.get_node("WaterArea") as Area3D
	assert_int(area.collision_layer).is_equal(0)
	assert_int(area.collision_mask).is_equal(4)

	volume.detection_collision_mask = 2
	assert_int(area.collision_mask).is_equal(2)


func test_polygon_volume_area_uses_exported_detection_collision_mask() -> void:
	var volume: PolygonWaterVolume = auto_free(PolygonWaterVolumeScript.new())
	volume.detection_collision_mask = 4
	add_child(volume)
	await get_tree().process_frame

	var area := volume.get_node("WaterArea") as Area3D
	assert_int(area.collision_layer).is_equal(0)
	assert_int(area.collision_mask).is_equal(4)


func test_polygon_volume_registers_and_unregisters_water_interaction_renderer() -> void:
	var volume: PolygonWaterVolume = PolygonWaterVolumeScript.new()
	add_child(volume)
	await get_tree().process_frame

	var volume_id := volume.get_instance_id()
	var renderers: Array = WaterSystem.get("_water_interaction_renderers")
	assert_bool(_renderer_list_has_instance(renderers, volume_id)).is_true()

	volume.queue_free()
	await get_tree().process_frame

	renderers = WaterSystem.get("_water_interaction_renderers")
	assert_bool(_renderer_list_has_instance(renderers, volume_id)).is_false()


func test_polygon_volume_mesh_subdivisions_is_pinned_until_supported() -> void:
	var volume: PolygonWaterVolume = auto_free(PolygonWaterVolumeScript.new())

	volume.mesh_subdivisions = 16

	assert_int(volume.mesh_subdivisions).is_equal(1)


func test_polygon_volume_coverage_uses_polygon_not_convex_collision() -> void:
	var volume: PolygonWaterVolume = auto_free(PolygonWaterVolumeScript.new())
	add_child(volume)
	volume.water_surface_height = 0.0
	volume.size = Vector3(10.0, 5.0, 10.0)
	volume.polygon_points = PackedVector2Array([
		Vector2(-4.0, -4.0),
		Vector2(4.0, -4.0),
		Vector2(4.0, -1.0),
		Vector2(-1.0, -1.0),
		Vector2(-1.0, 4.0),
		Vector2(-4.0, 4.0),
	])
	await get_tree().process_frame

	assert_float(volume.sample_water_coverage(Vector3(-3.0, -1.0, 3.0))).is_equal_approx(1.0, 0.001)
	assert_float(volume.sample_water_coverage(Vector3(2.0, -1.0, 2.0))).is_equal_approx(0.0, 0.001)


func test_polygon_volume_triangulates_clockwise_polygon_and_samples_coverage() -> void:
	var volume: PolygonWaterVolume = auto_free(PolygonWaterVolumeScript.new())
	add_child(volume)
	volume.water_surface_height = 0.0
	volume.size = Vector3(10.0, 5.0, 10.0)
	volume.polygon_points = PackedVector2Array([
		Vector2(-4.0, -2.0),
		Vector2(-4.0, 2.0),
		Vector2(4.0, 2.0),
		Vector2(4.0, -2.0),
	])
	await get_tree().process_frame

	var mesh_instance := volume.get_node("WaterSurface") as MeshInstance3D
	var mesh := mesh_instance.mesh as ArrayMesh
	assert_object(mesh).is_not_null()
	assert_int(mesh.get_surface_count()).is_equal(1)

	var arrays := mesh.surface_get_arrays(0)
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	assert_int(indices.size()).is_equal(6)
	for i in range(0, indices.size(), 3):
		assert_float(_triangle_area_2d(
			volume.polygon_points[indices[i]],
			volume.polygon_points[indices[i + 1]],
			volume.polygon_points[indices[i + 2]]
		)).is_greater(0.0)

	assert_float(volume.sample_water_coverage(Vector3(0.0, -1.0, 0.0))).is_equal_approx(1.0, 0.001)
	assert_float(volume.sample_water_coverage(Vector3(5.0, -1.0, 0.0))).is_equal_approx(0.0, 0.001)


func test_polygon_volume_descriptor_bounds_follow_polygon_and_height_edits() -> void:
	var volume: PolygonWaterVolume = auto_free(PolygonWaterVolumeScript.new())
	add_child(volume)
	volume.global_position = Vector3(10.0, 5.0, -2.0)
	volume.water_surface_height = 1.0
	volume.size = Vector3(100.0, 4.0, 100.0)
	volume.polygon_points = PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(8.0, 0.0),
		Vector2(8.0, 2.0),
		Vector2(0.0, 2.0),
	])
	await get_tree().process_frame

	var descriptor := volume.get_water_body_descriptor()
	assert_vector(descriptor.bounds.position).is_equal_approx(Vector3(10.0, 2.0, -2.0), Vector3.ONE * 0.001)
	assert_vector(descriptor.bounds.size).is_equal_approx(Vector3(8.0, 4.0, 2.0), Vector3.ONE * 0.001)

	volume.water_surface_height = 3.0
	volume.size = Vector3(100.0, 6.0, 100.0)
	volume.polygon_points = PackedVector2Array([
		Vector2(1.0, 3.0),
		Vector2(4.0, 3.0),
		Vector2(4.0, 9.0),
		Vector2(1.0, 9.0),
	])
	await get_tree().process_frame

	assert_vector(descriptor.bounds.position).is_equal_approx(Vector3(11.0, 2.0, 1.0), Vector3.ONE * 0.001)
	assert_vector(descriptor.bounds.size).is_equal_approx(Vector3(3.0, 6.0, 6.0), Vector3.ONE * 0.001)


func test_polygon_volume_json_import_preserves_zero_flow_speed() -> void:
	var volume: PolygonWaterVolume = auto_free(PolygonWaterVolumeScript.new())
	volume.flow_speed = 2.5

	volume.import_from_json({
		"water_type": "RIVER",
		"flow_speed": 0.0,
	})

	assert_float(volume.flow_speed).is_equal_approx(0.0, 0.001)


func _descriptor(
	body_id: StringName,
	body_type: StringName,
	priority: int,
	height: float,
	center: Vector3,
	coverage_radius: float,
	velocity: Vector3,
) -> RefCounted:
	var descriptor: RefCounted = WaterBodyDescriptorScript.new()
	descriptor.body_id = body_id
	descriptor.body_type = body_type
	descriptor.priority = priority
	descriptor.surface_height = height
	descriptor.coverage_query = func(pos: Vector3) -> float:
		var delta := Vector2(pos.x - center.x, pos.z - center.z)
		return 1.0 if delta.length() <= coverage_radius else 0.0
	descriptor.height_query = func(_pos: Vector3) -> float:
		return height
	descriptor.velocity_query = func(_pos: Vector3) -> Vector3:
		return velocity
	descriptor.water_body_id_query = func(pos: Vector3) -> StringName:
		return body_id if descriptor.sample_coverage(pos) > 0.0 else WaterSurfaceState.WATER_BODY_NONE
	return descriptor


func _triangle_area_2d(a: Vector2, b: Vector2, c: Vector2) -> float:
	return ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) * 0.5


func _renderer_list_has_instance(renderers: Array, instance_id: int) -> bool:
	for renderer in renderers:
		if is_instance_valid(renderer) and renderer.get_instance_id() == instance_id:
			return true
	return false


func _object_has_property(object: Object, property_name: String) -> bool:
	for property: Dictionary in object.get_property_list():
		if str(property.get("name", "")) == property_name:
			return true
	return false
