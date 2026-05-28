extends GdUnitTestSuite

const RiverWaterBodyScript := preload("res://src/core/water/river_water_body.gd")
const FlowingRiverLabScript := preload("res://tests/visual/test_flowing_river.gd")


func test_river_water_body_generates_curved_mesh_attributes() -> void:
	var river: RiverWaterBody3D = auto_free(_make_curved_river())
	add_child(river)
	await get_tree().process_frame
	await get_tree().process_frame

	var mesh_instance := river.get_node("RiverSurface") as MeshInstance3D
	assert_object(mesh_instance).is_not_null()
	var mesh := mesh_instance.mesh as ArrayMesh
	assert_object(mesh).is_not_null()
	assert_int(mesh.get_surface_count()).is_equal(1)

	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var uv2s: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	assert_int(vertices.size()).is_greater(16)
	assert_int(normals.size()).is_equal(vertices.size())
	assert_int(tangents.size()).is_equal(vertices.size() * 4)
	assert_int(uvs.size()).is_equal(vertices.size())
	assert_int(uv2s.size()).is_equal(vertices.size())
	assert_int(colors.size()).is_equal(vertices.size())
	assert_int(indices.size() % 3).is_equal(0)
	assert_bool(colors[0].b >= 0.0 and colors[0].b <= 1.0).is_true()


func test_river_water_body_coverage_rejects_land_outside_banks() -> void:
	var river: RiverWaterBody3D = auto_free(_make_curved_river())
	add_child(river)
	await get_tree().process_frame

	var center := river.global_position + Vector3(0.0, 0.0, -24.0)
	var outside := river.global_position + Vector3(12.0, 0.0, -24.0)
	var below_bottom := river.global_position + Vector3(0.0, -8.0, -24.0)

	assert_float(river.sample_water_coverage(center)).is_greater(0.9)
	assert_float(river.sample_water_coverage(outside)).is_equal_approx(0.0, 0.001)
	assert_float(river.sample_water_coverage(below_bottom)).is_equal_approx(0.0, 0.001)


func test_river_water_body_coverage_rejects_points_beyond_curve_ends() -> void:
	var river: RiverWaterBody3D = auto_free(_make_curved_river())
	add_child(river)
	await get_tree().process_frame

	var before_start := river.global_position + Vector3(0.0, 0.0, -38.0)
	var after_end := river.global_position + Vector3(0.0, 0.0, 38.0)
	var on_start := river.global_position + Vector3(0.0, 0.0, -32.0)

	assert_float(river.sample_water_coverage(before_start)).is_equal_approx(0.0, 0.001)
	assert_float(river.sample_water_coverage(after_end)).is_equal_approx(0.0, 0.001)
	assert_float(river.sample_water_coverage(on_start)).is_greater(0.9)


func test_river_water_body_binds_flowmap_material_contract() -> void:
	var river: RiverWaterBody3D = auto_free(_make_curved_river())
	river.flowmap_enabled = true
	river.flowmap_image = _make_flowmap_image()
	river.flowmap_region_bounds = AABB(Vector3(-10.0, -1.0, -20.0), Vector3(20.0, 2.0, 40.0))
	add_child(river)
	await get_tree().process_frame
	await get_tree().process_frame

	var mesh_instance := river.get_node("RiverSurface") as MeshInstance3D
	var material := mesh_instance.material_override as ShaderMaterial
	var bounds: Vector4 = material.get_shader_parameter(&"flowmap_region_bounds")
	var descriptor := river.get_water_body_descriptor()

	assert_object(material.get_shader_parameter(&"flowmap_texture")).is_not_null()
	assert_bool(material.get_shader_parameter(&"flowmap_enabled")).is_true()
	assert_float(bounds.x).is_equal_approx(-10.0, 0.001)
	assert_float(bounds.y).is_equal_approx(-20.0, 0.001)
	assert_float(bounds.z).is_equal_approx(20.0, 0.001)
	assert_float(bounds.w).is_equal_approx(40.0, 0.001)
	assert_float(float(material.get_shader_parameter(&"flowmap_max_speed_mps"))).is_equal_approx(6.0, 0.001)
	assert_object(descriptor.flowmap_texture).is_not_null()
	assert_bool(descriptor.metadata.get("flowmap_enabled", false)).is_true()


func test_river_water_body_binds_water_interaction_debug_uniform() -> void:
	var river: RiverWaterBody3D = auto_free(_make_curved_river())
	add_child(river)
	await get_tree().process_frame

	river.sync_water_interaction_texture(
		_make_flowmap_texture(),
		Vector4(-4.0, -4.0, 8.0, 0.25),
		true,
		true,
		_make_flowmap_texture(),
		Vector4(-4.0, -4.0, 8.0, 8.0),
		true,
		_make_flowmap_texture(),
		Vector4(-4.0, -4.0, 8.0, 0.25),
		true
	)
	var material := (river.get_node("RiverSurface") as MeshInstance3D).material_override as ShaderMaterial

	assert_bool(material.get_shader_parameter(&"water_interaction_enabled")).is_true()
	assert_bool(material.get_shader_parameter(&"water_interaction_debug_enabled")).is_true()
	assert_bool(material.get_shader_parameter(&"water_dynamic_flow_enabled")).is_true()


func test_river_descriptor_velocity_follows_curve_direction() -> void:
	var river: RiverWaterBody3D = auto_free(_make_curved_river())
	add_child(river)
	await get_tree().process_frame

	var descriptor := river.get_water_body_descriptor()
	var first := river.global_position + Vector3(0.0, 0.0, -26.0)
	var bend := river.global_position + Vector3(8.0, 0.0, 0.0)

	var first_velocity: Vector3 = descriptor.sample_velocity(first)
	var bend_velocity: Vector3 = descriptor.sample_velocity(bend)

	assert_float(first_velocity.length()).is_equal_approx(river.flow_speed, 0.05)
	assert_float(bend_velocity.length()).is_equal_approx(river.flow_speed, 0.05)
	assert_float(absf(first_velocity.normalized().dot(bend_velocity.normalized()))).is_less(0.98)


func test_river_flowmap_velocity_overrides_curve_direction() -> void:
	var river: RiverWaterBody3D = auto_free(_make_curved_river())
	river.flowmap_enabled = true
	river.flowmap_image = _make_east_flowmap_image()
	river.flowmap_region_bounds = AABB(Vector3(-20.0, -1.0, -40.0), Vector3(40.0, 2.0, 80.0))
	add_child(river)
	await get_tree().process_frame

	var velocity := river.sample_water_velocity(river.global_position + Vector3(0.0, 0.0, -24.0))

	assert_float(velocity.normalized().dot(Vector3.RIGHT)).is_greater(0.98)
	assert_float(velocity.length()).is_equal_approx(3.0, 0.05)


func test_neutral_zero_speed_flowmap_does_not_override_curve_velocity() -> void:
	var river: RiverWaterBody3D = auto_free(_make_curved_river())
	river.flowmap_enabled = true
	river.flowmap_image = _make_neutral_still_flowmap_image()
	river.flowmap_region_bounds = AABB(Vector3(-20.0, -1.0, -40.0), Vector3(40.0, 2.0, 80.0))
	add_child(river)
	await get_tree().process_frame

	var velocity := river.sample_water_velocity(river.global_position + Vector3(0.0, 0.0, -24.0))

	assert_float(velocity.length()).is_equal_approx(river.flow_speed, 0.05)
	assert_float(absf(velocity.normalized().dot(Vector3.RIGHT))).is_less(0.9)


func test_bilinear_flowmap_edge_fades_speed_without_diagonal_turn() -> void:
	var river: RiverWaterBody3D = auto_free(_make_curved_river())
	river.flowmap_enabled = true
	river.flowmap_image = _make_east_to_empty_flowmap_image()
	river.flowmap_region_bounds = AABB(Vector3(-20.0, -1.0, -40.0), Vector3(40.0, 2.0, 80.0))
	add_child(river)
	await get_tree().process_frame

	var velocity := river.sample_water_velocity(river.global_position + Vector3(0.0, 0.0, -24.0))

	assert_float(velocity.normalized().dot(Vector3.RIGHT)).is_greater(0.98)
	assert_float(velocity.length()).is_greater(0.35)
	assert_float(velocity.length()).is_less(1.2)


func test_generated_lab_flowmap_uses_constant_speed_and_alpha_only_bank_fade() -> void:
	var lab = auto_free(FlowingRiverLabScript.new())
	var river := _make_generated_lab_river()
	var image: Image = lab._make_generated_flowmap_image(river, 96, 96)
	var length := river.curve.get_baked_length()
	var center_local := river.curve.sample_baked(length * 0.48, true)
	var ahead := river.curve.sample_baked(length * 0.50, true)
	var behind := river.curve.sample_baked(length * 0.46, true)
	var tangent3 := (ahead - behind).normalized()
	var tangent := Vector2(tangent3.x, tangent3.z).normalized()
	var right := Vector2(tangent.y, -tangent.x).normalized()
	var center_xz := Vector2(center_local.x, center_local.z) + Vector2(river.position.x, river.position.z)
	var half_width := 0.5 * lab._river_width_at(river, 0.48)

	var center_sample: Color = lab._sample_flowmap_image_bilinear(image, _flowmap_uv_for_world_xz(river, center_xz))
	var bank_sample: Color = lab._sample_flowmap_image_bilinear(image, _flowmap_uv_for_world_xz(river, center_xz + right * half_width))
	var gutter_sample: Color = lab._sample_flowmap_image_bilinear(image, _flowmap_uv_for_world_xz(river, center_xz + right * (half_width + 3.0)))
	var expected_speed := river.flow_speed / 6.0

	assert_float(center_sample.b).is_equal_approx(expected_speed, 0.01)
	assert_float(bank_sample.b).is_equal_approx(expected_speed, 0.01)
	assert_float(gutter_sample.b).is_equal_approx(expected_speed, 0.01)
	assert_float(center_sample.a).is_greater(0.95)
	assert_float(bank_sample.a).is_less(center_sample.a)
	assert_float(gutter_sample.a).is_less(0.02)
	assert_float(_decode_flowmap_dir(center_sample).dot(tangent)).is_greater(0.96)
	assert_float(_decode_flowmap_dir(gutter_sample).dot(tangent)).is_greater(0.90)


func test_river_shader_uses_flowmap_direction_without_blending_zero_vector() -> void:
	var shader := FileAccess.get_file_as_string("res://src/core/water/shaders/river_surface.gdshader")

	assert_bool(shader.contains("bool flowmap_valid")).is_true()
	assert_bool(shader.contains("vec2 flowmap_velocity = flowmap_encoded_dir * flowmap_speed_mps")).is_true()
	assert_bool(shader.contains("float flowmap_weight = flowmap_valid ? flowmap_coverage_weight * flowmap_speed_weight : 0.0")).is_true()
	assert_bool(shader.contains("vec2 base_velocity = mix(curve_velocity, flowmap_velocity, flowmap_weight)")).is_true()
	assert_bool(shader.contains("vec2 combined_velocity = base_velocity + dynamic_flow_delta")).is_true()
	assert_bool(shader.contains("debug_display_mode == 8") and shader.contains("debug_display_mode == 10")).is_true()
	assert_bool(shader.contains("debug_display_mode == 13")).is_true()
	assert_bool(shader.contains("dFdx(flow_dir)") and shader.contains("river_flow_uv")).is_true()
	assert_bool(shader.contains("aligned_ripple_uv")).is_true()
	assert_bool(shader.contains("vec2 river_flow_uv = vec2((UV.x - 0.5) * 2.15, UV.y * flow_uv_scale)")).is_true()
	assert_bool(shader.contains("vec2 flow = vec2(0.0, 1.0)")).is_true()
	assert_bool(shader.contains("float phase_time = river_time * max(effective_flow_speed, 0.01) * 0.18")).is_true()
	assert_bool(not shader.contains("dot(v_world_pos.xz, chart_side)")).is_true()
	assert_bool(not shader.contains("chart_flow_dir")).is_true()
	assert_bool(not shader.contains("vec2 world_flow_uv = v_world_pos.xz * flow_uv_scale")).is_true()


func test_tight_bend_river_mesh_has_no_degenerate_triangles() -> void:
	var river: RiverWaterBody3D = auto_free(_make_tight_bend_river())
	add_child(river)
	await get_tree().process_frame
	await get_tree().process_frame

	var mesh_instance := river.get_node("RiverSurface") as MeshInstance3D
	var mesh := mesh_instance.mesh as ArrayMesh
	assert_object(mesh).is_not_null()
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	assert_int(indices.size()).is_greater(0)
	for i in range(0, indices.size(), 3):
		var a := vertices[indices[i]]
		var b := vertices[indices[i + 1]]
		var c := vertices[indices[i + 2]]
		var area := (b - a).cross(c - a).length() * 0.5
		assert_float(area).is_greater(0.0001)


func test_tight_bend_river_mesh_flow_basis_is_row_continuous() -> void:
	var river: RiverWaterBody3D = auto_free(_make_tight_bend_river())
	add_child(river)
	await get_tree().process_frame
	await get_tree().process_frame

	var mesh_instance := river.get_node("RiverSurface") as MeshInstance3D
	var mesh := mesh_instance.mesh as ArrayMesh
	assert_object(mesh).is_not_null()
	var arrays := mesh.surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var columns := river.width_subdivisions + 1
	var rows := colors.size() / columns

	assert_int(rows).is_greater(3)
	for row in range(rows - 1):
		var a := _decode_flow_color(colors[row * columns])
		var b := _decode_flow_color(colors[(row + 1) * columns])
		assert_float(a.dot(b)).is_greater(0.72)


func _make_curved_river() -> RiverWaterBody3D:
	var river: RiverWaterBody3D = RiverWaterBodyScript.new()
	river.name = "UnitRiver"
	river.curve = Curve3D.new()
	river.curve.add_point(Vector3(0.0, 0.0, -32.0), Vector3.ZERO, Vector3(9.0, 0.0, 10.0))
	river.curve.add_point(Vector3(8.0, 0.0, 0.0), Vector3(-8.0, 0.0, -10.0), Vector3(-8.0, 0.0, 10.0))
	river.curve.add_point(Vector3(0.0, 0.0, 32.0), Vector3(8.0, 0.0, -10.0), Vector3.ZERO)
	river.point_widths = [8.0, 12.0, 8.0]
	river.surface_height = 0.25
	river.depth = 4.0
	river.flow_speed = 2.0
	river.length_step_m = 1.5
	river.width_subdivisions = 6
	return river


func _make_tight_bend_river() -> RiverWaterBody3D:
	var river: RiverWaterBody3D = RiverWaterBodyScript.new()
	river.name = "TightBendUnitRiver"
	river.curve = Curve3D.new()
	river.curve.add_point(Vector3(-10.0, 0.0, -18.0), Vector3.ZERO, Vector3(16.0, 0.0, 0.0))
	river.curve.add_point(Vector3(8.0, 0.0, -10.0), Vector3(-16.0, 0.0, -1.0), Vector3(12.0, 0.0, 12.0))
	river.curve.add_point(Vector3(4.0, 0.0, 8.0), Vector3(12.0, 0.0, -12.0), Vector3(-14.0, 0.0, 10.0))
	river.curve.add_point(Vector3(-12.0, 0.0, 18.0), Vector3(14.0, 0.0, -10.0), Vector3.ZERO)
	river.point_widths = [12.0, 18.0, 17.0, 12.0]
	river.surface_height = 0.0
	river.depth = 4.0
	river.flow_speed = 2.0
	river.length_step_m = 0.75
	river.width_subdivisions = 10
	return river


func _make_generated_lab_river() -> RiverWaterBody3D:
	var river: RiverWaterBody3D = RiverWaterBodyScript.new()
	river.name = "GeneratedFlowmapRiverUnit"
	river.curve = Curve3D.new()
	river.curve.add_point(Vector3(-7.0, 0.0, -50.0), Vector3.ZERO, Vector3(7.0, 0.0, 13.0))
	river.curve.add_point(Vector3(7.0, 0.0, -24.0), Vector3(-7.0, 0.0, -13.0), Vector3(-6.0, 0.0, 13.0))
	river.curve.add_point(Vector3(-5.0, 0.0, 4.0), Vector3(6.0, 0.0, -13.0), Vector3(7.0, 0.0, 14.0))
	river.curve.add_point(Vector3(7.0, 0.0, 38.0), Vector3(-7.0, 0.0, -14.0), Vector3.ZERO)
	river.point_widths = [6.5, 7.5, 7.0, 7.5]
	river.flow_speed = 2.0
	river.position = Vector3(0.0, 4.1, 0.0)
	river.flowmap_region_bounds = AABB(Vector3(-45.0, -10.0, -70.0), Vector3(90.0, 20.0, 140.0))
	return river


func _flowmap_uv_for_world_xz(river: RiverWaterBody3D, world_xz: Vector2) -> Vector2:
	var bounds := river.flowmap_region_bounds
	return Vector2(
		(world_xz.x - bounds.position.x) / bounds.size.x,
		(world_xz.y - bounds.position.z) / bounds.size.z
	)


func _decode_flowmap_dir(color: Color) -> Vector2:
	var dir := Vector2(color.r * 2.0 - 1.0, color.g * 2.0 - 1.0)
	if dir.length_squared() <= 0.000001:
		return Vector2.ZERO
	return dir.normalized()


func _make_flowmap_image() -> Image:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.5, 1.0, 0.75, 1.0))
	return image


func _make_east_flowmap_image() -> Image:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color(1.0, 0.5, 0.5, 1.0))
	return image


func _make_neutral_still_flowmap_image() -> Image:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color(128.0 / 255.0, 128.0 / 255.0, 0.0, 1.0))
	return image


func _make_east_to_empty_flowmap_image() -> Image:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, Color(1.0, 0.5, 0.5, 1.0))
	image.set_pixel(0, 1, Color(1.0, 0.5, 0.5, 1.0))
	image.set_pixel(1, 0, Color(0.5, 0.5, 0.0, 0.0))
	image.set_pixel(1, 1, Color(0.5, 0.5, 0.0, 0.0))
	return image


func _make_flowmap_texture() -> Texture2D:
	return ImageTexture.create_from_image(_make_flowmap_image())


func _decode_flow_color(color: Color) -> Vector2:
	var flow := Vector2(color.r * 2.0 - 1.0, color.g * 2.0 - 1.0)
	if flow.length_squared() <= 0.0001:
		return Vector2.UP
	return flow.normalized()
