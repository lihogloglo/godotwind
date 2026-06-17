extends GdUnitTestSuite

const RenderLayersScript := preload("res://src/core/world/render_layers.gd")


func test_classic_interior_switch_preserves_water_layer() -> void:
	var initial_mask := RenderLayersScript.EXTERIOR_WORLD | RenderLayersScript.WATER_SURFACE
	var interior_mask: int = RenderLayersScript.replace_world_layers(initial_mask, RenderLayersScript.INTERIOR_WORLD)

	assert_bool(RenderLayersScript.has_interior_world(interior_mask)).is_true()
	assert_bool(RenderLayersScript.has_exterior_world(interior_mask)).is_false()
	assert_bool(RenderLayersScript.has_water_surface(interior_mask)).is_true()


func test_classic_exterior_switch_preserves_water_layer() -> void:
	var initial_mask := RenderLayersScript.INTERIOR_WORLD | RenderLayersScript.WATER_SURFACE
	var exterior_mask: int = RenderLayersScript.replace_world_layers(initial_mask, RenderLayersScript.EXTERIOR_WORLD)

	assert_bool(RenderLayersScript.has_exterior_world(exterior_mask)).is_true()
	assert_bool(RenderLayersScript.has_interior_world(exterior_mask)).is_false()
	assert_bool(RenderLayersScript.has_water_surface(exterior_mask)).is_true()


func test_seamless_combined_switch_preserves_non_world_layers() -> void:
	var debug_layer := 1 << 8
	var initial_mask := RenderLayersScript.EXTERIOR_WORLD | RenderLayersScript.WATER_SURFACE | debug_layer
	var combined_mask: int = RenderLayersScript.replace_world_layers(initial_mask, RenderLayersScript.COMBINED_WORLD)

	assert_bool(RenderLayersScript.has_exterior_world(combined_mask)).is_true()
	assert_bool(RenderLayersScript.has_interior_world(combined_mask)).is_true()
	assert_bool(RenderLayersScript.has_water_surface(combined_mask)).is_true()
	assert_bool((combined_mask & debug_layer) != 0).is_true()
