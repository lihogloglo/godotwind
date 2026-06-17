extends Node3D

const LoadingScreenScript := preload("res://src/core/ui/loading_screen.gd")
const InputActionsScript := preload("res://src/core/input/input_actions.gd")
const MorrowindDataProviderScript := preload("res://src/core/world/morrowind/morrowind_data_provider.gd")
const GpuHydrologyBakerScript := preload("res://src/core/world/morrowind/morrowind_gpu_hydrology_baker.gd")
const MorrowindHydrologyProviderScript := preload("res://src/core/world/morrowind/morrowind_hydrology_provider.gd")
const MorrowindNativeBridgeScript := preload("res://src/core/world/morrowind/morrowind_native_bridge.gd")

const TERRAIN_STRIDE: int = 8
const BAKE_BUDGET_USEC: int = 18000
const MAX_REGIONS_PER_FRAME: int = 2
const CAMERA_SPEED_MPS: float = 180.0
const CAMERA_FAST_MULTIPLIER: float = 4.0
const MOUSE_SENSITIVITY: float = 0.002
const BALMORA_REGION: Vector2i = Vector2i(-1, -1)
const MAX_ENCODED_SPEED_MPS: float = 6.0
const OVERLAY_CLASSIFICATION := 0
const OVERLAY_COVERAGE := 1
const OVERLAY_SPEED := 2
const OVERLAY_DIRECTION := 3
const OVERLAY_RAW_RGBA := 4
const OVERLAY_WET_MASK := 5
const OVERLAY_OCEAN_CORE := 6
const OVERLAY_BANK_DISTANCE := 7
const OVERLAY_CORRIDOR := 8
const OVERLAY_ACCEPTED_RIVERS := 9
const OVERLAY_OUTLET_DISTANCE := 10
const OVERLAY_REJECTION_REASON := 11
const OVERLAY_LOCAL_WIDTH := 12
const OVERLAY_BODY_TYPE := 13
const OVERLAY_FLOW_ACCUMULATION := 14
const OVERLAY_COMPONENT_ID := 15
const OVERLAY_GRAPH_LINK := 16
const OVERLAY_STREAM_RANK := 17
const OVERLAY_SINK_ID := 18
const OVERLAY_BASIN_NODES := 19
const OVERLAY_COUNT := 20

var _terrain_provider: MorrowindDataProvider = null
var _hydrology_provider: MorrowindHydrologyProvider = null
var _gpu_baker: MorrowindGpuHydrologyBaker = null
var _camera: Camera3D = null
var _yaw: float = 0.0
var _pitch: float = -0.95
var _hud: Label = null
var _mouse_captured: bool = true
var _pending_regions: Array[Vector2i] = []
var _baked_regions: Dictionary[Vector2i, bool] = {}
var _failed_regions: Dictionary[Vector2i, bool] = {}
var _atlas_regions: Dictionary[Vector2i, Dictionary] = {}
var _atlas_directory: String = ""
var _classification_mode: String = "Runtime/GPU provider"
var _terrain_nodes: Array[MeshInstance3D] = []
var _river_nodes: Array[MeshInstance3D] = []
var _still_nodes: Array[MeshInstance3D] = []
var _coverage_nodes: Array[MeshInstance3D] = []
var _speed_nodes: Array[MeshInstance3D] = []
var _direction_nodes: Array[MeshInstance3D] = []
var _raw_rgba_nodes: Array[MeshInstance3D] = []
var _wet_mask_nodes: Array[MeshInstance3D] = []
var _ocean_core_nodes: Array[MeshInstance3D] = []
var _bank_distance_nodes: Array[MeshInstance3D] = []
var _corridor_nodes: Array[MeshInstance3D] = []
var _accepted_nodes: Array[MeshInstance3D] = []
var _outlet_nodes: Array[MeshInstance3D] = []
var _rejection_nodes: Array[MeshInstance3D] = []
var _local_width_nodes: Array[MeshInstance3D] = []
var _body_type_nodes: Array[MeshInstance3D] = []
var _flow_accumulation_nodes: Array[MeshInstance3D] = []
var _component_id_nodes: Array[MeshInstance3D] = []
var _graph_link_nodes: Array[MeshInstance3D] = []
var _stream_rank_nodes: Array[MeshInstance3D] = []
var _sink_id_nodes: Array[MeshInstance3D] = []
var _basin_node_nodes: Array[MeshInstance3D] = []
var _flow_arrow_nodes: Array[MeshInstance3D] = []
var _debug_images_by_region: Dictionary[Vector2i, Dictionary] = {}
var _runtime_atlas_regions: Dictionary[Vector2i, Dictionary] = {}
var _overlay_mode: int = OVERLAY_CLASSIFICATION
var _flow_arrows_visible: bool = true
var _river_pixels: int = 0
var _wet_pixels: int = 0
var _global_build_ms: float = 0.0
var _last_bake_ms: float = 0.0
var _total_bake_ms: float = 0.0
var _ready_for_baking: bool = false


func _ready() -> void:
	InputActionsScript.verify()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_mouse_captured = true
	_setup_world()
	_setup_camera()
	_setup_hud()

	var loading: LoadingScreen = LoadingScreenScript.new()
	add_child(loading)
	var ok := await loading.load_game_data()
	loading.queue_free()
	if not ok:
		_hud.text = "Failed to load Morrowind data."
		return

	_terrain_provider = MorrowindDataProviderScript.new()
	var terrain_err := _terrain_provider.initialize()
	if terrain_err != OK:
		_hud.text = "Failed to initialize Morrowind terrain provider."
		Log.warn("water", "Water classification visual: terrain provider failed with error %d" % terrain_err)
		return

	_hydrology_provider = MorrowindHydrologyProviderScript.new()
	_hydrology_provider.configure(_terrain_provider, null)
	_hydrology_provider.cache_enabled = false
	_hydrology_provider.use_prebaked_hydrology = false
	_hydrology_provider.allow_runtime_hydrology_bake = false
	var provider_err := _hydrology_provider.initialize()
	if provider_err != OK:
		_hud.text = "Hydrology provider unavailable; error %d." % provider_err
		Log.warn("water", "Water classification visual: hydrology provider failed (%d)" % provider_err)
		return

	_classification_mode = "Runtime/native hydrology atlas"
	_hud.text = "Building native global hydrology atlas..."
	await get_tree().process_frame
	var atlas_err := _build_runtime_native_hydrology_atlas()
	if atlas_err != OK:
		_hud.text = "Native hydrology atlas build failed; error %d." % atlas_err
		Log.warn("water", "Water classification visual: native hydrology atlas failed (%d)" % atlas_err)
		return

	_pending_regions = _terrain_provider.get_all_terrain_regions()
	_pending_regions.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return _region_sort_distance(a) < _region_sort_distance(b)
	)
	_pending_regions.reverse()
	_position_camera_for_region(BALMORA_REGION)
	_ready_for_baking = true
	Log.info("water", "Water classification visual: queued %d hydrology regions (%s)" % [_pending_regions.size(), _classification_mode])


func _exit_tree() -> void:
	if _gpu_baker != null:
		_gpu_baker.shutdown()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		var motion := event as InputEventMouseMotion
		_yaw -= motion.relative.x * MOUSE_SENSITIVITY
		_pitch = clampf(_pitch - motion.relative.y * MOUSE_SENSITIVITY, -1.48, -0.05)
	if event.is_action_pressed(&"ui_cancel"):
		_mouse_captured = not _mouse_captured
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE
	if event.is_action_pressed(&"ui_accept"):
		_overlay_mode = (_overlay_mode + 1) % OVERLAY_COUNT
		_apply_overlay_visibility()


func _process(delta: float) -> void:
	_update_camera(delta)
	if _ready_for_baking:
		_process_region_bakes()
	_update_hud()


func _setup_world() -> void:
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.18, 0.23, 0.30)
	sky_mat.sky_horizon_color = Color(0.42, 0.50, 0.56)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.8
	env_node.environment = env
	add_child(env_node)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-58.0, 32.0, 0.0)
	sun.light_energy = 1.35
	add_child(sun)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "DebugCamera"
	_camera.far = 50000.0
	_camera.near = 0.2
	_camera.current = true
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_camera)


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(12.0, 12.0)
	panel.custom_minimum_size = Vector2(430.0, 0.0)
	layer.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	_hud = Label.new()
	_hud.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hud.text = "Loading..."
	vbox.add_child(_hud)

	_add_toggle(vbox, "Terrain", true, func(enabled: bool) -> void: _set_nodes_visible(_terrain_nodes, enabled))
	var overlay_picker := OptionButton.new()
	overlay_picker.add_item("Classification", OVERLAY_CLASSIFICATION)
	overlay_picker.add_item("Coverage", OVERLAY_COVERAGE)
	overlay_picker.add_item("Speed", OVERLAY_SPEED)
	overlay_picker.add_item("Direction", OVERLAY_DIRECTION)
	overlay_picker.add_item("Raw RGBA", OVERLAY_RAW_RGBA)
	overlay_picker.add_item("Wet mask", OVERLAY_WET_MASK)
	overlay_picker.add_item("Ocean core", OVERLAY_OCEAN_CORE)
	overlay_picker.add_item("Bank distance", OVERLAY_BANK_DISTANCE)
	overlay_picker.add_item("Corridor candidates", OVERLAY_CORRIDOR)
	overlay_picker.add_item("Accepted rivers", OVERLAY_ACCEPTED_RIVERS)
	overlay_picker.add_item("Outlet distance", OVERLAY_OUTLET_DISTANCE)
	overlay_picker.add_item("Rejection reason", OVERLAY_REJECTION_REASON)
	overlay_picker.add_item("Local width", OVERLAY_LOCAL_WIDTH)
	overlay_picker.add_item("Body type", OVERLAY_BODY_TYPE)
	overlay_picker.add_item("Flow accumulation", OVERLAY_FLOW_ACCUMULATION)
	overlay_picker.add_item("Component id", OVERLAY_COMPONENT_ID)
	overlay_picker.add_item("Graph link", OVERLAY_GRAPH_LINK)
	overlay_picker.add_item("Stream rank", OVERLAY_STREAM_RANK)
	overlay_picker.add_item("Sink id", OVERLAY_SINK_ID)
	overlay_picker.add_item("Basin nodes", OVERLAY_BASIN_NODES)
	overlay_picker.item_selected.connect(func(index: int) -> void:
		_overlay_mode = overlay_picker.get_item_id(index)
		_apply_overlay_visibility()
	)
	vbox.add_child(overlay_picker)
	_add_toggle(vbox, "Flow arrows", true, func(enabled: bool) -> void:
		_flow_arrows_visible = enabled
		_apply_overlay_visibility()
	)


func _add_toggle(parent: Control, label: String, pressed: bool, callback: Callable) -> void:
	var button := CheckButton.new()
	button.text = label
	button.button_pressed = pressed
	button.toggled.connect(callback)
	parent.add_child(button)


func _process_region_bakes() -> void:
	if _pending_regions.is_empty():
		return
	var frame_start := Time.get_ticks_usec()
	var baked_this_frame := 0
	while baked_this_frame < MAX_REGIONS_PER_FRAME and not _pending_regions.is_empty():
		var region_coord: Vector2i = _pending_regions.pop_back()
		_bake_region(region_coord)
		baked_this_frame += 1
		if Time.get_ticks_usec() - frame_start >= BAKE_BUDGET_USEC:
			break


func _build_runtime_native_hydrology_atlas() -> Error:
	var bridge: RefCounted = MorrowindNativeBridgeScript.new()
	var builder := bridge.create_hydrology_atlas_builder()
	if builder == null:
		return ERR_UNAVAILABLE
	var regions := _terrain_provider.get_all_terrain_regions()
	if regions.is_empty():
		return ERR_DOES_NOT_EXIST
	var tiles: Array[Dictionary] = []
	for region_coord: Vector2i in regions:
		var heightmap: Image = _terrain_provider.get_heightmap_for_region(region_coord)
		if heightmap == null:
			continue
		tiles.append({
			"region": region_coord,
			"heightmap": heightmap,
		})
	if tiles.is_empty():
		return ERR_DOES_NOT_EXIST
	var start_usec := Time.get_ticks_usec()
	var result: Dictionary = builder.call(
		"BuildAtlas",
		tiles,
		float(_terrain_provider.vertex_spacing),
		float(_terrain_provider.sea_level),
		0.0,
		1.4,
		MAX_ENCODED_SPEED_MPS
	)
	_global_build_ms = float(Time.get_ticks_usec() - start_usec) / 1000.0
	if int(result.get("error", FAILED)) != OK:
		return int(result.get("error", FAILED))
	_runtime_atlas_regions.clear()
	for region_v: Variant in result.get("regions", []):
		if not region_v is Dictionary:
			continue
		var region_result: Dictionary = region_v as Dictionary
		var region_coord: Vector2i = region_result.get("region", Vector2i(2147483647, 2147483647))
		var flow_image: Image = region_result.get("image") as Image
		if flow_image == null:
			continue
		var cached := {
			"flow_image": flow_image,
			"components": _hydrology_provider._components_from_bake_result(region_result),
			"river_count": int(region_result.get("river_count", 0)),
			"bounds": _hydrology_provider._region_bounds(region_coord),
			"cache_key": "runtime_native_atlas_%d_%d" % [region_coord.x, region_coord.y],
			"algorithm": "morrowind_hydrology_atlas_v2",
			"debug_images": region_result.get("debug_images", {}),
		}
		_runtime_atlas_regions[region_coord] = cached
		_hydrology_provider._region_cache[region_coord] = cached
	return OK


func _bake_region(region_coord: Vector2i) -> void:
	if _classification_mode == "Runtime/native hydrology atlas":
		_load_runtime_native_atlas_region(region_coord)
		return
	if _classification_mode == "Runtime/GPU provider":
		_load_runtime_gpu_region(region_coord)
		return
	if _classification_mode == "Atlas/global":
		_load_atlas_region(region_coord)
		return
	var heightmap: Image = _terrain_provider.get_heightmap_for_region(region_coord)
	if heightmap == null:
		_failed_regions[region_coord] = true
		return

	var halo := _gpu_baker.halo_pixels
	var padded_heightmap := _build_padded_heightmap(region_coord, heightmap, halo)
	var crop_rect := Rect2i(halo, halo, heightmap.get_width(), heightmap.get_height())
	var result := _gpu_baker.bake_from_heightmap(padded_heightmap, float(_terrain_provider.vertex_spacing), crop_rect)
	if result.is_empty():
		_failed_regions[region_coord] = true
		Log.warn("water", "Water classification visual: GPU bake failed for region %s error %d" % [region_coord, _gpu_baker.get_last_error()])
		return

	var flow_image: Image = result.get("image") as Image
	if flow_image == null:
		_failed_regions[region_coord] = true
		return

	_last_bake_ms = float(result.get("bake_usec", 0)) / 1000.0
	_total_bake_ms += _last_bake_ms
	_baked_regions[region_coord] = true
	_add_region_terrain(region_coord, heightmap)
	_add_region_overlays(region_coord, flow_image, result.get("debug_images", {}))


func _load_runtime_gpu_region(region_coord: Vector2i) -> void:
	var heightmap: Image = _terrain_provider.get_heightmap_for_region(region_coord)
	if heightmap == null:
		_failed_regions[region_coord] = true
		return
	var err := _hydrology_provider.prepare_region(region_coord)
	if err != OK:
		_failed_regions[region_coord] = true
		return
	var cached: Dictionary = _hydrology_provider._region_cache.get(region_coord, {})
	var flow_image: Image = cached.get("flow_image") as Image
	if flow_image == null:
		_failed_regions[region_coord] = true
		return
	_baked_regions[region_coord] = true
	_add_region_terrain(region_coord, heightmap)
	_add_region_overlays(region_coord, flow_image, cached.get("debug_images", {}))


func _load_runtime_native_atlas_region(region_coord: Vector2i) -> void:
	var heightmap: Image = _terrain_provider.get_heightmap_for_region(region_coord)
	var cached: Dictionary = _runtime_atlas_regions.get(region_coord, {})
	var flow_image: Image = cached.get("flow_image") as Image
	if heightmap == null or flow_image == null:
		_failed_regions[region_coord] = true
		return
	_baked_regions[region_coord] = true
	_add_region_terrain(region_coord, heightmap)
	_add_region_overlays(region_coord, flow_image, cached.get("debug_images", {}))


func _load_atlas_region(region_coord: Vector2i) -> void:
	var heightmap: Image = _terrain_provider.get_heightmap_for_region(region_coord)
	var metadata: Dictionary = _atlas_regions.get(region_coord, {})
	var image_path := _atlas_directory.path_join(String(metadata.get("image", _prebaked_region_key(region_coord) + ".png")))
	var flow_image := Image.load_from_file(image_path)
	if heightmap == null or flow_image == null:
		_failed_regions[region_coord] = true
		return
	_baked_regions[region_coord] = true
	_add_region_terrain(region_coord, heightmap)
	_add_region_overlays(region_coord, flow_image, {})


func _try_load_global_hydrology_atlas() -> bool:
	_atlas_regions.clear()
	var dir := SettingsManager.get_cache_base_path().path_join("water").path_join("morrowind_hydrology_atlas")
	var manifest_path := dir.path_join("manifest.json")
	if not FileAccess.file_exists(manifest_path):
		return false
	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if file == null:
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		return false
	var manifest: Dictionary = parsed as Dictionary
	if String(manifest.get("algorithm", "")) != "morrowind_hydrology_atlas_v2":
		return false
	var regions: Array = manifest.get("regions", [])
	for region_v: Variant in regions:
		if not region_v is Dictionary:
			continue
		var metadata: Dictionary = region_v as Dictionary
		var region_arr: Array = metadata.get("region", [])
		if region_arr.size() < 2:
			continue
		_atlas_regions[Vector2i(int(region_arr[0]), int(region_arr[1]))] = metadata
	_atlas_directory = dir
	return not _atlas_regions.is_empty()


func _prebaked_region_key(region_coord: Vector2i) -> String:
	return "region_%d_%d" % [region_coord.x, region_coord.y]


func _build_padded_heightmap(region_coord: Vector2i, center_heightmap: Image, halo: int) -> Image:
	if center_heightmap == null or halo <= 0:
		return center_heightmap
	var width := center_heightmap.get_width()
	var height := center_heightmap.get_height()
	if width <= 0 or height <= 0:
		return center_heightmap
	var padded := Image.create(width + halo * 2, height + halo * 2, false, Image.FORMAT_RF)
	padded.fill(Color(float(_terrain_provider.sea_level) - 16.0, 0.0, 0.0, 1.0))
	for region_y_offset in range(-1, 2):
		for region_x_offset in range(-1, 2):
			var source_region := region_coord + Vector2i(region_x_offset, region_y_offset)
			var source: Image = center_heightmap if source_region == region_coord else _terrain_provider.get_heightmap_for_region(source_region)
			if source == null:
				continue
			var dest := Vector2i(halo + region_x_offset * width, halo - region_y_offset * height)
			_blit_clipped_heightmap(source, padded, dest)
	return padded


func _blit_clipped_heightmap(source: Image, target: Image, dest: Vector2i) -> void:
	var target_width := target.get_width()
	var target_height := target.get_height()
	var source_width := source.get_width()
	var source_height := source.get_height()
	var x0 := maxi(dest.x, 0)
	var y0 := maxi(dest.y, 0)
	var x1 := mini(dest.x + source_width, target_width)
	var y1 := mini(dest.y + source_height, target_height)
	if x1 <= x0 or y1 <= y0:
		return
	var source_rect := Rect2i(x0 - dest.x, y0 - dest.y, x1 - x0, y1 - y0)
	target.blit_rect(source, source_rect, Vector2i(x0, y0))


func _add_region_terrain(region_coord: Vector2i, heightmap: Image) -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "TerrainRegion_%d_%d" % [region_coord.x, region_coord.y]
	mesh_instance.mesh = _build_region_terrain_mesh(region_coord, heightmap)
	mesh_instance.material_override = _make_terrain_material()
	add_child(mesh_instance)
	_terrain_nodes.append(mesh_instance)


func _add_region_overlays(region_coord: Vector2i, flow_image: Image, debug_images: Dictionary = {}) -> void:
	var masks := _build_overlay_images(flow_image)
	var river_image: Image = masks["river"]
	var still_image: Image = masks["still"]
	var coverage_image: Image = masks["coverage"]
	var speed_image: Image = masks["speed"]
	var direction_image: Image = masks["direction"]
	var raw_rgba_image: Image = masks["raw_rgba"]
	if bool(masks.get("has_river", false)):
		var river_node := _make_region_overlay(region_coord, river_image, "RiverOverlay", 0.52)
		add_child(river_node)
		_river_nodes.append(river_node)
	if bool(masks.get("has_still", false)):
		var still_node := _make_region_overlay(region_coord, still_image, "StillWaterOverlay", 0.36)
		add_child(still_node)
		_still_nodes.append(still_node)
	if bool(masks.get("has_wet", false)):
		var coverage_node := _make_region_overlay(region_coord, coverage_image, "CoverageOverlay", 0.62)
		add_child(coverage_node)
		_coverage_nodes.append(coverage_node)
		var speed_node := _make_region_overlay(region_coord, speed_image, "SpeedOverlay", 0.64)
		add_child(speed_node)
		_speed_nodes.append(speed_node)
		var direction_node := _make_region_overlay(region_coord, direction_image, "DirectionOverlay", 0.66)
		add_child(direction_node)
		_direction_nodes.append(direction_node)
		var raw_node := _make_region_overlay(region_coord, raw_rgba_image, "RawRgbaOverlay", 0.68)
		add_child(raw_node)
		_raw_rgba_nodes.append(raw_node)
	if not debug_images.is_empty():
		_debug_images_by_region[region_coord] = debug_images
		_add_debug_overlay_node(region_coord, debug_images, "wet_mask", "WetMaskOverlay", _wet_mask_nodes, 0.70)
		_add_debug_overlay_node(region_coord, debug_images, "ocean_core", "OceanCoreOverlay", _ocean_core_nodes, 0.72)
		_add_debug_overlay_node(region_coord, debug_images, "bank_distance", "BankDistanceOverlay", _bank_distance_nodes, 0.74)
		_add_debug_overlay_node(region_coord, debug_images, "corridor_candidates", "CorridorOverlay", _corridor_nodes, 0.76)
		_add_debug_overlay_node(region_coord, debug_images, "accepted_rivers", "AcceptedRiverOverlay", _accepted_nodes, 0.78)
		_add_debug_overlay_node(region_coord, debug_images, "outlet_distance", "OutletDistanceOverlay", _outlet_nodes, 0.80)
		_add_debug_overlay_node(region_coord, debug_images, "rejection_reason", "RejectionReasonOverlay", _rejection_nodes, 0.82)
		_add_debug_overlay_node(region_coord, debug_images, "local_width", "LocalWidthOverlay", _local_width_nodes, 0.84)
		_add_debug_overlay_node(region_coord, debug_images, "body_type", "BodyTypeOverlay", _body_type_nodes, 0.86)
		_add_debug_overlay_node(region_coord, debug_images, "flow_accumulation", "FlowAccumulationOverlay", _flow_accumulation_nodes, 0.88)
		_add_debug_overlay_node(region_coord, debug_images, "component_id", "ComponentIdOverlay", _component_id_nodes, 0.90)
		_add_debug_overlay_node(region_coord, debug_images, "graph_link", "GraphLinkOverlay", _graph_link_nodes, 0.92)
		_add_debug_overlay_node(region_coord, debug_images, "stream_rank", "StreamRankOverlay", _stream_rank_nodes, 0.94)
		_add_debug_overlay_node(region_coord, debug_images, "sink_id", "SinkIdOverlay", _sink_id_nodes, 0.96)
		_add_debug_overlay_node(region_coord, debug_images, "basin_nodes", "BasinNodeOverlay", _basin_node_nodes, 0.98)
	var arrow_node := _make_flow_arrow_overlay(region_coord, flow_image)
	if arrow_node != null:
		add_child(arrow_node)
		_flow_arrow_nodes.append(arrow_node)
	_apply_overlay_visibility()


func _add_debug_overlay_node(
	region_coord: Vector2i,
	debug_images: Dictionary,
	key: String,
	label: String,
	target_nodes: Array[MeshInstance3D],
	y_offset: float
) -> void:
	var image: Image = debug_images.get(key) as Image
	if image == null:
		return
	var node := _make_region_overlay(region_coord, image, label, y_offset)
	add_child(node)
	target_nodes.append(node)


func _build_overlay_images(flow_image: Image) -> Dictionary:
	var width := flow_image.get_width()
	var height := flow_image.get_height()
	var river := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var still := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var coverage := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var speed := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var direction := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var raw_rgba := Image.create(width, height, false, Image.FORMAT_RGBA8)
	river.fill(Color.TRANSPARENT)
	still.fill(Color.TRANSPARENT)
	coverage.fill(Color.TRANSPARENT)
	speed.fill(Color.TRANSPARENT)
	direction.fill(Color.TRANSPARENT)
	raw_rgba.fill(Color.TRANSPARENT)
	var has_river := false
	var has_still := false
	var has_wet := false
	for y in range(height):
		for x in range(width):
			var c := flow_image.get_pixel(x, y)
			if c.a <= 0.0:
				continue
			has_wet = true
			_wet_pixels += 1
			coverage.set_pixel(x, y, Color(c.a, c.a, c.a, 0.80))
			speed.set_pixel(x, y, _speed_debug_color(c))
			direction.set_pixel(x, y, Color(c.r, c.g, 1.0 - maxf(c.r, c.g) * 0.35, 0.82))
			raw_rgba.set_pixel(x, y, Color(c.r, c.g, c.b, maxf(c.a, 0.18)))
			if c.b > 0.001:
				has_river = true
				_river_pixels += 1
				river.set_pixel(x, y, Color(0.0, 0.95, 0.72, 0.76))
			else:
				has_still = true
				still.set_pixel(x, y, Color(0.0, 0.20, 0.95, 0.34))
	return {
		"river": river,
		"still": still,
		"coverage": coverage,
		"speed": speed,
		"direction": direction,
		"raw_rgba": raw_rgba,
		"has_river": has_river,
		"has_still": has_still,
		"has_wet": has_wet,
	}


func _speed_debug_color(c: Color) -> Color:
	if c.a <= 0.0:
		return Color.TRANSPARENT
	var dir := Vector2(c.r * 2.0 - 1.0, c.g * 2.0 - 1.0)
	var speed_mps := c.b * MAX_ENCODED_SPEED_MPS * clampf(dir.length(), 0.0, 1.0)
	var t := clampf(speed_mps / MAX_ENCODED_SPEED_MPS, 0.0, 1.0)
	var slow := Color(0.05, 0.10, 0.36, 0.38)
	var mid := Color(1.0, 0.82, 0.10, 0.76)
	var fast := Color(1.0, 0.12, 0.02, 0.88)
	return slow.lerp(mid, minf(t * 2.0, 1.0)) if t < 0.5 else mid.lerp(fast, (t - 0.5) * 2.0)


func _build_region_terrain_mesh(region_coord: Vector2i, heightmap: Image) -> ArrayMesh:
	var width := heightmap.get_width()
	var height := heightmap.get_height()
	var cols := int(ceil(float(width) / float(TERRAIN_STRIDE))) + 1
	var rows := int(ceil(float(height) / float(TERRAIN_STRIDE))) + 1
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	vertices.resize(cols * rows)
	colors.resize(cols * rows)

	var min_h := INF
	var max_h := -INF
	for y in range(height):
		for x in range(width):
			var h := heightmap.get_pixel(x, y).r
			min_h = minf(min_h, h)
			max_h = maxf(max_h, h)

	for row in range(rows):
		var gy := mini(row * TERRAIN_STRIDE, height - 1)
		for col in range(cols):
			var gx := mini(col * TERRAIN_STRIDE, width - 1)
			var vertex_index := row * cols + col
			var pos := _region_pixel_to_world(region_coord, Vector2(float(gx), float(gy)), width, height)
			pos.y = heightmap.get_pixel(gx, gy).r
			vertices[vertex_index] = pos
			colors[vertex_index] = _terrain_color(pos.y, min_h, max_h)

	for row in range(rows - 1):
		for col in range(cols - 1):
			var a := row * cols + col
			var b := a + 1
			var c := a + cols
			var d := c + 1
			indices.append_array(PackedInt32Array([a, c, b, b, c, d]))

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _make_region_overlay(region_coord: Vector2i, image: Image, label: String, y_offset: float) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = "%s_%d_%d" % [label, region_coord.x, region_coord.y]
	node.mesh = _build_region_quad(region_coord, y_offset)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(image)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = false
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	node.material_override = mat
	return node


func _make_flow_arrow_overlay(region_coord: Vector2i, flow_image: Image) -> MeshInstance3D:
	var width := flow_image.get_width()
	var height := flow_image.get_height()
	if width <= 0 or height <= 0:
		return null
	var stride := maxi(6, ceili(float(maxi(width, height)) / 24.0))
	var arrows: Array[Dictionary] = []
	var offset := int(stride / 2)
	for y in range(offset, height, stride):
		for x in range(offset, width, stride):
			var c := flow_image.get_pixel(x, y)
			if c.a <= 0.05 or c.b <= 0.001:
				continue
			var dir := Vector2(c.r * 2.0 - 1.0, c.g * 2.0 - 1.0)
			if dir.length_squared() <= 0.0001:
				continue
			dir = dir.normalized()
			var speed_mps := c.b * MAX_ENCODED_SPEED_MPS
			var length_px := lerpf(float(stride) * 0.55, float(stride) * 1.65, clampf(speed_mps / MAX_ENCODED_SPEED_MPS, 0.0, 1.0))
			var start := Vector2(float(x), float(y)) - dir * length_px * 0.35
			var end := Vector2(float(x), float(y)) + dir * length_px * 0.65
			arrows.append({"start": start, "end": end, "speed": speed_mps})
	if arrows.is_empty():
		return null
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for arrow: Dictionary in arrows:
		_add_debug_arrow(mesh, region_coord, arrow["start"] as Vector2, arrow["end"] as Vector2, width, height, float(arrow["speed"]))
	mesh.surface_end()
	var node := MeshInstance3D.new()
	node.name = "FlowArrows_%d_%d" % [region_coord.x, region_coord.y]
	node.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	node.material_override = mat
	return node


func _add_debug_arrow(mesh: ImmediateMesh, region_coord: Vector2i, start_px: Vector2, end_px: Vector2, image_width: int, image_height: int, speed_mps: float) -> void:
	var y_offset := 0.82
	var start := _region_pixel_to_world(region_coord, start_px, image_width, image_height)
	var end := _region_pixel_to_world(region_coord, end_px, image_width, image_height)
	start.y = float(_terrain_provider.sea_level) + y_offset
	end.y = float(_terrain_provider.sea_level) + y_offset
	var color := _arrow_debug_color(speed_mps)
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(start)
	mesh.surface_add_vertex(end)
	var dir3 := (end - start).normalized()
	var side := Vector3(-dir3.z, 0.0, dir3.x)
	var head_len := maxf(start.distance_to(end) * 0.22, _region_world_size() * 0.002)
	var left := end - dir3 * head_len + side * head_len * 0.45
	var right := end - dir3 * head_len - side * head_len * 0.45
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(end)
	mesh.surface_add_vertex(left)
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(end)
	mesh.surface_add_vertex(right)


func _arrow_debug_color(speed_mps: float) -> Color:
	var t := clampf(speed_mps / MAX_ENCODED_SPEED_MPS, 0.0, 1.0)
	return Color(0.0, 0.95, 0.72, 1.0).lerp(Color(1.0, 0.20, 0.06, 1.0), t)


func _build_region_quad(region_coord: Vector2i, y_offset: float) -> ArrayMesh:
	var size := _region_world_size()
	var x0 := float(region_coord.x) * size
	var x1 := x0 + size
	var z0 := -float(region_coord.y + 1) * size
	var z1 := -float(region_coord.y) * size
	var y := float(_terrain_provider.sea_level) + y_offset
	var vertices := PackedVector3Array([
		Vector3(x0, y, z0),
		Vector3(x0, y, z1),
		Vector3(x1, y, z0),
		Vector3(x1, y, z0),
		Vector3(x0, y, z1),
		Vector3(x1, y, z1),
	])
	var uvs := PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(0.0, 1.0),
		Vector2(1.0, 0.0),
		Vector2(1.0, 0.0),
		Vector2(0.0, 1.0),
		Vector2(1.0, 1.0),
	])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _region_pixel_to_world(region_coord: Vector2i, pixel: Vector2, image_width: int, image_height: int) -> Vector3:
	var size := _region_world_size()
	var origin_x := float(region_coord.x) * size
	var origin_neg_z := float(region_coord.y) * size
	var u := clampf((pixel.x + 0.5) / maxf(float(image_width), 1.0), 0.0, 1.0)
	var v := clampf((float(image_height) - 0.5 - pixel.y) / maxf(float(image_height), 1.0), 0.0, 1.0)
	return Vector3(origin_x + u * size, 0.0, -(origin_neg_z + v * size))


func _terrain_color(height: float, min_h: float, max_h: float) -> Color:
	if height <= float(_terrain_provider.sea_level):
		return Color(0.12, 0.14, 0.15, 1.0)
	var t := clampf((height - float(_terrain_provider.sea_level)) / maxf(max_h - float(_terrain_provider.sea_level), 1.0), 0.0, 1.0)
	return Color(0.18, 0.19, 0.16, 1.0).lerp(Color(0.58, 0.56, 0.48, 1.0), sqrt(t))


func _make_terrain_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.92
	return mat


func _position_camera_for_region(region_coord: Vector2i) -> void:
	var size := _region_world_size()
	var center := Vector3(
		float(region_coord.x) * size + size * 0.5,
		0.0,
		-float(region_coord.y) * size - size * 0.5
	)
	_camera.global_position = center + Vector3(0.0, size * 1.15, size * 0.85)
	_camera.look_at(center, Vector3.UP)
	_yaw = _camera.rotation.y
	_pitch = _camera.rotation.x


func _update_camera(delta: float) -> void:
	if _camera == null:
		return
	_camera.rotation = Vector3(_pitch, _yaw, 0.0)
	var input := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")
	var vertical := 0.0
	if Input.is_action_pressed(&"jump"):
		vertical += 1.0
	if Input.is_action_pressed(&"crouch"):
		vertical -= 1.0
	var speed := CAMERA_SPEED_MPS * (CAMERA_FAST_MULTIPLIER if Input.is_action_pressed(&"sprint") else 1.0)
	var basis := _camera.global_transform.basis
	var motion := (basis.x * input.x + basis.z * input.y + Vector3.UP * vertical) * speed * delta
	_camera.global_position += motion


func _set_nodes_visible(nodes: Array[MeshInstance3D], visible: bool) -> void:
	for node: MeshInstance3D in nodes:
		if node != null:
			node.visible = visible


func _apply_overlay_visibility() -> void:
	_set_nodes_visible(_river_nodes, _overlay_mode == OVERLAY_CLASSIFICATION)
	_set_nodes_visible(_still_nodes, _overlay_mode == OVERLAY_CLASSIFICATION)
	_set_nodes_visible(_coverage_nodes, _overlay_mode == OVERLAY_COVERAGE)
	_set_nodes_visible(_speed_nodes, _overlay_mode == OVERLAY_SPEED)
	_set_nodes_visible(_direction_nodes, _overlay_mode == OVERLAY_DIRECTION)
	_set_nodes_visible(_raw_rgba_nodes, _overlay_mode == OVERLAY_RAW_RGBA)
	_set_nodes_visible(_wet_mask_nodes, _overlay_mode == OVERLAY_WET_MASK)
	_set_nodes_visible(_ocean_core_nodes, _overlay_mode == OVERLAY_OCEAN_CORE)
	_set_nodes_visible(_bank_distance_nodes, _overlay_mode == OVERLAY_BANK_DISTANCE)
	_set_nodes_visible(_corridor_nodes, _overlay_mode == OVERLAY_CORRIDOR)
	_set_nodes_visible(_accepted_nodes, _overlay_mode == OVERLAY_ACCEPTED_RIVERS)
	_set_nodes_visible(_outlet_nodes, _overlay_mode == OVERLAY_OUTLET_DISTANCE)
	_set_nodes_visible(_rejection_nodes, _overlay_mode == OVERLAY_REJECTION_REASON)
	_set_nodes_visible(_local_width_nodes, _overlay_mode == OVERLAY_LOCAL_WIDTH)
	_set_nodes_visible(_body_type_nodes, _overlay_mode == OVERLAY_BODY_TYPE)
	_set_nodes_visible(_flow_accumulation_nodes, _overlay_mode == OVERLAY_FLOW_ACCUMULATION)
	_set_nodes_visible(_component_id_nodes, _overlay_mode == OVERLAY_COMPONENT_ID)
	_set_nodes_visible(_graph_link_nodes, _overlay_mode == OVERLAY_GRAPH_LINK)
	_set_nodes_visible(_stream_rank_nodes, _overlay_mode == OVERLAY_STREAM_RANK)
	_set_nodes_visible(_sink_id_nodes, _overlay_mode == OVERLAY_SINK_ID)
	_set_nodes_visible(_basin_node_nodes, _overlay_mode == OVERLAY_BASIN_NODES)
	_set_nodes_visible(_flow_arrow_nodes, _flow_arrows_visible and (_overlay_mode == OVERLAY_SPEED or _overlay_mode == OVERLAY_DIRECTION or _overlay_mode == OVERLAY_RAW_RGBA or _overlay_mode == OVERLAY_ACCEPTED_RIVERS or _overlay_mode == OVERLAY_OUTLET_DISTANCE))


func _update_hud() -> void:
	if _hud == null:
		return
	if not _ready_for_baking:
		return
	var total := _baked_regions.size() + _pending_regions.size() + _failed_regions.size()
	var average_ms := _total_bake_ms / maxf(float(_baked_regions.size()), 1.0)
	var probe := _camera_center_probe()
	_hud.text = "Water classification (%s)\nOverlay: %s  arrows: %s\nGlobal build/load: %.2f ms\nRegions: %d/%d ready  pending: %d  failed: %d\nLast local GPU region: %.2f ms  avg: %.2f ms\nWet pixels: %d  river pixels: %d\nProbe: %s\nMove: mapped movement actions, jump/crouch vertical, sprint fast\nEsc: mouse capture, Enter: next overlay" % [
		_classification_mode,
		_overlay_mode_name(),
		"on" if _flow_arrows_visible else "off",
		_global_build_ms,
		_baked_regions.size(),
		total,
		_pending_regions.size(),
		_failed_regions.size(),
		_last_bake_ms,
		average_ms,
		_wet_pixels,
		_river_pixels,
		probe,
	]


func _overlay_mode_name() -> String:
	match _overlay_mode:
		OVERLAY_COVERAGE:
			return "coverage alpha"
		OVERLAY_SPEED:
			return "speed heatmap"
		OVERLAY_DIRECTION:
			return "flow direction RG"
		OVERLAY_RAW_RGBA:
			return "raw RGBA contract"
		OVERLAY_WET_MASK:
			return "wet mask"
		OVERLAY_OCEAN_CORE:
			return "ocean/broad core"
		OVERLAY_BANK_DISTANCE:
			return "bank distance"
		OVERLAY_CORRIDOR:
			return "corridor candidates"
		OVERLAY_ACCEPTED_RIVERS:
			return "accepted rivers"
		OVERLAY_OUTLET_DISTANCE:
			return "outlet-distance gradient"
		OVERLAY_REJECTION_REASON:
			return "rejection reason"
		OVERLAY_LOCAL_WIDTH:
			return "local width"
		OVERLAY_BODY_TYPE:
			return "body type"
		OVERLAY_FLOW_ACCUMULATION:
			return "flow accumulation"
		OVERLAY_COMPONENT_ID:
			return "component id"
		OVERLAY_GRAPH_LINK:
			return "graph link"
		OVERLAY_STREAM_RANK:
			return "stream rank"
		OVERLAY_SINK_ID:
			return "sink id"
		OVERLAY_BASIN_NODES:
			return "basin nodes"
		_:
			return "classification"


func _camera_center_probe() -> String:
	if _camera == null or _hydrology_provider == null:
		return "unavailable"
	var origin := _camera.project_ray_origin(get_viewport().get_visible_rect().size * 0.5)
	var dir := _camera.project_ray_normal(get_viewport().get_visible_rect().size * 0.5)
	if absf(dir.y) <= 0.0001:
		return "ray parallel to water plane"
	var sea_level := float(_terrain_provider.sea_level) if _terrain_provider != null else 0.0
	var t := (sea_level - origin.y) / dir.y
	if t < 0.0:
		return "camera center points above horizon"
	var pos := origin + dir * t
	var coverage := _hydrology_provider.sample_coverage(pos)
	var velocity := _hydrology_provider.sample_velocity(pos)
	var body_id := _hydrology_provider.sample_water_body_id(pos)
	var region_coord: Vector2i = _terrain_provider.world_pos_to_region(pos) if _terrain_provider != null else Vector2i.ZERO
	var debug_probe := _debug_probe_for_world(region_coord, pos)
	var direction := Vector2(velocity.x, velocity.z)
	var speed := direction.length()
	if speed > 0.001:
		direction = direction / speed
	return "body=%s cov=%.2f speed=%.2fm/s dir=(%.2f, %.2f) %s world=(%.1f, %.1f)" % [
		String(body_id),
		coverage,
		speed,
		direction.x,
		direction.y,
		debug_probe,
		pos.x,
		pos.z,
	]


func _debug_probe_for_world(region_coord: Vector2i, world_pos: Vector3) -> String:
	var debug_images: Dictionary = _debug_images_by_region.get(region_coord, {})
	if debug_images.is_empty():
		return "debug=unavailable"
	var size := _region_world_size()
	var u := (world_pos.x - float(region_coord.x) * size) / maxf(size, 0.001)
	var v := 1.0 - ((-world_pos.z - float(region_coord.y) * size) / maxf(size, 0.001))
	var image: Image = debug_images.get("wet_mask") as Image
	if image == null:
		return "debug=unavailable"
	var x := clampi(roundi(u * float(image.get_width() - 1)), 0, image.get_width() - 1)
	var y := clampi(roundi(v * float(image.get_height() - 1)), 0, image.get_height() - 1)
	var accepted := _debug_alpha(debug_images, "accepted_rivers", x, y)
	var ocean := _debug_alpha(debug_images, "ocean_core", x, y)
	var bank := _debug_luma(debug_images, "bank_distance", x, y)
	var outlet := _debug_luma(debug_images, "outlet_distance", x, y)
	var graph := _debug_alpha(debug_images, "graph_link", x, y)
	var rank := _debug_luma(debug_images, "stream_rank", x, y)
	var sink := _debug_luma(debug_images, "sink_id", x, y)
	var reason_image: Image = debug_images.get("rejection_reason") as Image
	var reason_color := reason_image.get_pixel(x, y) if reason_image != null else Color.TRANSPARENT
	var reason := _reason_name_from_color(reason_color)
	return "graph=%d accepted=%d ocean=%.0f bank=%.2f rank=%.2f sink=%.2f reason=%s" % [
		1 if graph > 0.05 else 0,
		1 if accepted > 0.05 else 0,
		ocean,
		bank,
		rank,
		sink if sink > 0.0 else outlet,
		reason,
	]


func _debug_alpha(debug_images: Dictionary, key: String, x: int, y: int) -> float:
	var image: Image = debug_images.get(key) as Image
	return image.get_pixel(x, y).a if image != null else 0.0


func _debug_luma(debug_images: Dictionary, key: String, x: int, y: int) -> float:
	var image: Image = debug_images.get(key) as Image
	if image == null:
		return 0.0
	var c := image.get_pixel(x, y)
	return (c.r + c.g + c.b) / 3.0


func _reason_name_from_color(c: Color) -> String:
	if c.a <= 0.01:
		return "none"
	if c.g > 0.8 and c.b > 0.6:
		return "accepted"
	if c.b > 0.8 and c.g < 0.35:
		return "broad"
	if c.r > 0.8 and c.g > 0.5:
		return "short"
	if c.r > 0.8 and c.b > 0.5:
		return "coastal"
	if c.b > 0.8:
		return "width"
	if c.r > 0.8:
		return "weak"
	return "no_outlet"


func _region_world_size() -> float:
	if _terrain_provider == null:
		return 1.0
	return float(_terrain_provider.region_size) * float(_terrain_provider.vertex_spacing)


func _region_sort_distance(region_coord: Vector2i) -> int:
	var delta := region_coord - BALMORA_REGION
	return delta.x * delta.x + delta.y * delta.y
