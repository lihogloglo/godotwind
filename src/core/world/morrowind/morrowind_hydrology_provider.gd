class_name MorrowindHydrologyProvider
extends "res://src/core/water/water_body_provider.gd"

const NativeBridgeScript := preload("res://src/core/native_bridge.gd")
const WaterBodyDescriptorScript := preload("res://src/core/water/water_body_descriptor.gd")

const REGION_PRIORITY := 160
const CACHE_VERSION := "river_flow_v3"
const DEFAULT_FLOW_SPEED_MPS := 1.4
const MAX_ENCODED_SPEED_MPS := 6.0
const DEFAULT_MAX_CACHED_REGIONS := 96
const DEFAULT_ASYNC_COMPLETIONS_PER_POLL := 4


class RegionBakeRequest:
	extends RefCounted

	var region_coord: Vector2i = Vector2i.ZERO
	var task_id: int = -1
	var cancelled: bool = false
	var error: int = OK
	var data: Dictionary = {}

var terrain_provider: RefCounted = null
var coordinate_mapper: RefCounted = null
var cache_enabled: bool = true
var cache_directory: String = ""
var max_cached_regions: int = DEFAULT_MAX_CACHED_REGIONS
var _native_bridge: NativeBridge = null
var _native_baker: RefCounted = null
var _terrain_provider_ready: bool = false
var _region_cache: Dictionary[Vector2i, Dictionary] = {}
var _region_cache_last_used: Dictionary[Vector2i, int] = {}
var _region_ref_counts: Dictionary[Vector2i, int] = {}
var _active_cell_regions: Dictionary[Vector2i, Vector2i] = {}
var _pending_region_tasks: Dictionary[Vector2i, RegionBakeRequest] = {}


func _init() -> void:
	provider_id = &"morrowind_hydrology"
	priority = REGION_PRIORITY


func configure(p_terrain_provider: RefCounted, p_coordinate_mapper: RefCounted) -> void:
	terrain_provider = p_terrain_provider
	coordinate_mapper = p_coordinate_mapper


func initialize() -> Error:
	if terrain_provider == null:
		return ERR_UNCONFIGURED
	_native_bridge = NativeBridgeScript.new()
	_native_baker = _native_bridge.create_river_flow_baker()
	if _native_baker == null:
		Log.warn("water", "MorrowindHydrologyProvider: NativeRiverFlowBaker unavailable; generated river flow is disabled until C# is built")
		return ERR_UNAVAILABLE
	return OK


func prepare_region(region_coord: Vector2i) -> Error:
	process_async_requests()
	if _region_cache.has(region_coord):
		_touch_region(region_coord)
		return OK
	if terrain_provider == null:
		return ERR_UNCONFIGURED
	if _native_baker == null:
		var init_err := initialize()
		if init_err != OK:
			return init_err
	var terrain_err := _ensure_terrain_provider_ready()
	if terrain_err != OK:
		return terrain_err

	var heightmap: Image = terrain_provider.call("get_heightmap_for_region", region_coord) as Image
	if heightmap == null:
		return ERR_DOES_NOT_EXIST

	var width := heightmap.get_width()
	var height := heightmap.get_height()
	var cache_key := _cache_key_for_region(region_coord, heightmap)
	var cached_result := _load_cached_region(cache_key, region_coord)
	if not cached_result.is_empty():
		_region_cache[region_coord] = cached_result
		_touch_region(region_coord)
		_trim_region_cache()
		return OK

	var heights := _height_samples_from_heightmap(heightmap)

	_native_baker.Width = width
	_native_baker.Height = height
	_native_baker.SeaLevel = float(terrain_provider.get("sea_level"))
	_native_baker.TexelSizeMeters = _get_vertex_spacing()
	_native_baker.FlowSpeedMetersPerSecond = DEFAULT_FLOW_SPEED_MPS
	_native_baker.MaxEncodedSpeedMetersPerSecond = MAX_ENCODED_SPEED_MPS

	var result: Dictionary = _native_baker.BakeFromHeights(heights)
	var flow_image: Image = result.get("image") as Image
	if flow_image == null:
		return FAILED

	_region_cache[region_coord] = {
		"flow_image": flow_image,
		"components": _components_from_bake_result(result),
		"river_count": int(result.get("river_count", 0)),
		"bounds": _region_bounds(region_coord),
		"cache_key": cache_key,
	}
	_touch_region(region_coord)
	_save_cached_region(cache_key, _region_cache[region_coord])
	_trim_region_cache()
	return OK


func request_prepare_region(region_coord: Vector2i) -> Error:
	process_async_requests()
	if _region_cache.has(region_coord):
		_touch_region(region_coord)
		return OK
	if _pending_region_tasks.has(region_coord):
		return OK
	if terrain_provider == null:
		return ERR_UNCONFIGURED
	if _native_baker == null:
		var init_err := initialize()
		if init_err != OK:
			return init_err
	var terrain_err := _ensure_terrain_provider_ready()
	if terrain_err != OK:
		return terrain_err
	var baker := _native_bridge.create_river_flow_baker() if _native_bridge != null else null
	if baker == null:
		return ERR_UNAVAILABLE
	var heightmap: Image = terrain_provider.call("get_heightmap_for_region", region_coord) as Image
	if heightmap == null:
		return ERR_DOES_NOT_EXIST
	var width := heightmap.get_width()
	var height := heightmap.get_height()
	var image_hash := hash(heightmap.get_data())
	var heights := _height_samples_from_heightmap(heightmap)
	var sea_level := float(terrain_provider.get("sea_level"))
	var vertex_spacing := _get_vertex_spacing()
	var region_world_size := _get_region_world_size()
	var cache_key := _cache_key_for_values(region_coord, width, height, sea_level, vertex_spacing, image_hash)

	var request := RegionBakeRequest.new()
	request.region_coord = region_coord
	var task_id := WorkerThreadPool.add_task(
		_execute_prepare_region_task.bind(
			request,
			baker,
			heights,
			width,
			height,
			sea_level,
			vertex_spacing,
			region_world_size,
			cache_key,
			cache_enabled,
			_get_cache_directory()
		),
		false,
		"Morrowind hydrology bake %s" % region_coord
	)
	if task_id < 0:
		return FAILED
	request.task_id = task_id
	_pending_region_tasks[region_coord] = request
	return OK


func process_async_requests(max_completions: int = DEFAULT_ASYNC_COMPLETIONS_PER_POLL) -> int:
	if _pending_region_tasks.is_empty():
		return 0
	var published := 0
	for region_coord: Vector2i in _pending_region_tasks.keys():
		if published >= max_completions:
			break
		var request: RegionBakeRequest = _pending_region_tasks.get(region_coord)
		if request == null or request.task_id < 0:
			_pending_region_tasks.erase(region_coord)
			continue
		if not WorkerThreadPool.is_task_completed(request.task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(request.task_id)
		_pending_region_tasks.erase(region_coord)
		if request.cancelled:
			published += 1
			continue
		if request.error == OK and not request.data.is_empty():
			_region_cache[region_coord] = request.data
			_touch_region(region_coord)
			_trim_region_cache()
		elif request.error != ERR_DOES_NOT_EXIST:
			Log.warn("water", "MorrowindHydrologyProvider: async region %s failed with error %d" % [region_coord, request.error])
		published += 1
	return published


func drain_async_requests(blocking: bool = false) -> void:
	for region_coord: Vector2i in _pending_region_tasks.keys():
		var request: RegionBakeRequest = _pending_region_tasks.get(region_coord)
		if request == null or request.task_id < 0:
			_pending_region_tasks.erase(region_coord)
			continue
		if blocking or WorkerThreadPool.is_task_completed(request.task_id):
			WorkerThreadPool.wait_for_task_completion(request.task_id)
			_pending_region_tasks.erase(region_coord)


func get_water_body_descriptors_for_region(region_coord: Vector2i) -> Array[RefCounted]:
	process_async_requests()
	var cached: Dictionary = _region_cache.get(region_coord, {})
	if cached.is_empty():
		return []
	var descriptor: RefCounted = WaterBodyDescriptorScript.new()
	descriptor.body_id = StringName("morrowind_hydrology_%d_%d" % [region_coord.x, region_coord.y])
	descriptor.body_type = &"river" if int(cached.get("river_count", 0)) > 0 else &"lake"
	descriptor.priority = priority
	descriptor.surface_height = float(terrain_provider.get("sea_level"))
	descriptor.flow_speed = DEFAULT_FLOW_SPEED_MPS
	descriptor.bounds = cached.get("bounds", AABB())
	descriptor.bounds_valid = true
	descriptor.metadata = {
		"renderable_water": _build_renderable_water_payloads_for_region(region_coord, cached),
		"renderable_rivers": _build_renderable_river_payloads_for_region(region_coord, cached),
		"cache_key": String(cached.get("cache_key", "")),
		"payload_schema": "godotwind.renderable_water.v2",
	}
	descriptor.coverage_query = Callable(self, "_sample_region_coverage").bind(region_coord)
	descriptor.height_query = Callable(self, "_sample_region_height").bind(region_coord)
	descriptor.velocity_query = Callable(self, "_sample_region_velocity").bind(region_coord)
	descriptor.water_body_id_query = Callable(self, "_sample_region_water_body_id").bind(region_coord)
	var descriptors: Array[RefCounted] = []
	descriptors.append(descriptor)
	return descriptors


func get_renderable_river_descriptors_for_region(region_coord: Vector2i) -> Array[Dictionary]:
	process_async_requests()
	var cached: Dictionary = _region_cache.get(region_coord, {})
	if cached.is_empty():
		return []
	return _build_renderable_river_payloads_for_region(region_coord, cached)


func get_renderable_water_descriptors_for_region(region_coord: Vector2i) -> Array[Dictionary]:
	process_async_requests()
	var cached: Dictionary = _region_cache.get(region_coord, {})
	if cached.is_empty():
		return []
	return _build_renderable_water_payloads_for_region(region_coord, cached)


func get_river_render_payloads_for_region(region_coord: Vector2i) -> Array[Dictionary]:
	return get_renderable_river_descriptors_for_region(region_coord)


func get_river_render_payloads_for_cell_grid(cell_grid: Vector2i) -> Array[Dictionary]:
	if terrain_provider == null or not terrain_provider.has_method("world_pos_to_region"):
		return []
	return get_renderable_river_descriptors_for_region(_cell_grid_to_region(cell_grid))


func get_water_render_payloads_for_cell_grid(cell_grid: Vector2i) -> Array[Dictionary]:
	if terrain_provider == null or not terrain_provider.has_method("world_pos_to_region"):
		return []
	return get_renderable_water_descriptors_for_region(_cell_grid_to_region(cell_grid))


func prepare_cell_grid(cell_grid: Vector2i) -> Error:
	if terrain_provider == null or not terrain_provider.has_method("world_pos_to_region"):
		return ERR_UNCONFIGURED
	var region_coord := _cell_grid_to_region(cell_grid)
	return prepare_region(region_coord)


func request_prepare_cell_grid(cell_grid: Vector2i) -> Error:
	if terrain_provider == null or not terrain_provider.has_method("world_pos_to_region"):
		return ERR_UNCONFIGURED
	var region_coord := _cell_grid_to_region(cell_grid)
	if _active_cell_regions.get(cell_grid, Vector2i(2147483647, 2147483647)) != region_coord:
		_active_cell_regions[cell_grid] = region_coord
		_region_ref_counts[region_coord] = int(_region_ref_counts.get(region_coord, 0)) + 1
	return request_prepare_region(region_coord)


func release_cell_grid(cell_grid: Vector2i) -> void:
	if not _active_cell_regions.has(cell_grid):
		return
	var region_coord: Vector2i = _active_cell_regions[cell_grid]
	_active_cell_regions.erase(cell_grid)
	var refs := int(_region_ref_counts.get(region_coord, 0)) - 1
	if refs > 0:
		_region_ref_counts[region_coord] = refs
		return
	_region_ref_counts.erase(region_coord)
	release_region(region_coord)


func release_region(region_coord: Vector2i) -> void:
	if int(_region_ref_counts.get(region_coord, 0)) > 0:
		return
	_region_cache.erase(region_coord)
	_region_cache_last_used.erase(region_coord)
	var request: RegionBakeRequest = _pending_region_tasks.get(region_coord)
	if request != null:
		request.cancelled = true


func trim_region_cache(max_regions: int = -1) -> void:
	_trim_region_cache(max_regions)


func sample_coverage(world_pos: Vector3) -> float:
	var sample := _sample_flow_pixel(world_pos)
	if sample.is_empty():
		return 0.0
	return float(sample.get("coverage", 0.0))


func sample_height(world_pos: Vector3, fallback: float = NAN) -> float:
	return float(terrain_provider.get("sea_level")) if sample_coverage(world_pos) > 0.0 else fallback


func sample_normal(_world_pos: Vector3, fallback: Vector3 = Vector3.UP) -> Vector3:
	return fallback


func sample_gradient(_world_pos: Vector3, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	return fallback


func sample_velocity(world_pos: Vector3, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	var sample := _sample_flow_pixel(world_pos)
	if sample.is_empty():
		return fallback
	var speed := float(sample.get("speed", 0.0))
	if speed <= 0.001:
		return Vector3.ZERO
	var direction: Vector2 = sample.get("direction", Vector2.ZERO)
	if direction.length_squared() <= 0.0001:
		return Vector3.ZERO
	direction = direction.normalized()
	return Vector3(direction.x, 0.0, direction.y) * speed


func sample_water_body_id(world_pos: Vector3, fallback: StringName = WaterSurfaceState.WATER_BODY_NONE) -> StringName:
	var sample := _sample_flow_pixel(world_pos)
	if sample.is_empty() or float(sample.get("coverage", 0.0)) <= 0.0:
		return fallback
	if float(sample.get("speed", 0.0)) > 0.001:
		return &"morrowind_generated_river"
	return &"morrowind_sea_level_water"


func _sample_flow_pixel(world_pos: Vector3) -> Dictionary:
	if terrain_provider == null or not terrain_provider.has_method("world_pos_to_region"):
		return {}
	var region_coord: Vector2i = terrain_provider.call("world_pos_to_region", world_pos)
	return _sample_flow_pixel_for_region(region_coord, world_pos)


func _sample_flow_pixel_for_region(region_coord: Vector2i, world_pos: Vector3) -> Dictionary:
	if not _region_cache.has(region_coord):
		return {}
	_touch_region(region_coord)
	var cached: Dictionary = _region_cache.get(region_coord, {})
	var flow_image: Image = cached.get("flow_image") as Image
	if flow_image == null:
		return {}

	var bounds: AABB = cached.get("bounds", _region_bounds(region_coord))
	if bounds.size.x <= 0.0 or bounds.size.z <= 0.0:
		return {}
	var uv := Vector2(
		(world_pos.x - bounds.position.x) / bounds.size.x,
		(world_pos.z - bounds.position.z) / bounds.size.z
	)
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return {}
	var c := _sample_flow_image_bilinear(flow_image, uv)
	if c.a <= 0.0:
		return {}
	var direction := Vector2(c.r * 2.0 - 1.0, c.g * 2.0 - 1.0)
	var speed := c.b * MAX_ENCODED_SPEED_MPS * clampf(direction.length(), 0.0, 1.0)
	if speed <= 0.001:
		direction = Vector2.ZERO
	elif direction.length_squared() > 0.000001:
		direction = direction.normalized()
	return {
		"coverage": c.a,
		"direction": direction,
		"speed": speed,
	}


func _sample_region_coverage(world_pos: Vector3, region_coord: Vector2i) -> float:
	if not _world_pos_in_region(world_pos, region_coord):
		return 0.0
	var sample := _sample_flow_pixel_for_region(region_coord, world_pos)
	if sample.is_empty():
		return 0.0
	return float(sample.get("coverage", 0.0))


func _sample_region_height(world_pos: Vector3, region_coord: Vector2i) -> float:
	return float(terrain_provider.get("sea_level")) if _sample_region_coverage(world_pos, region_coord) > 0.0 else NAN


func _sample_region_velocity(world_pos: Vector3, region_coord: Vector2i) -> Vector3:
	if not _world_pos_in_region(world_pos, region_coord):
		return Vector3.ZERO
	return sample_velocity(world_pos, Vector3.ZERO)


func _sample_region_water_body_id(world_pos: Vector3, region_coord: Vector2i) -> StringName:
	if not _world_pos_in_region(world_pos, region_coord):
		return WaterSurfaceState.WATER_BODY_NONE
	return sample_water_body_id(world_pos, WaterSurfaceState.WATER_BODY_NONE)


func _sample_flow_image_bilinear(image: Image, uv: Vector2) -> Color:
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		return Color(0.5, 0.5, 0.0, 0.0)
	var x := clampf(uv.x, 0.0, 1.0) * float(maxi(width - 1, 0))
	var y := clampf(uv.y, 0.0, 1.0) * float(maxi(height - 1, 0))
	var x0 := clampi(floori(x), 0, width - 1)
	var y0 := clampi(floori(y), 0, height - 1)
	var x1 := clampi(x0 + 1, 0, width - 1)
	var y1 := clampi(y0 + 1, 0, height - 1)
	var tx := x - float(x0)
	var ty := y - float(y0)
	var c00 := image.get_pixel(x0, y0)
	var c10 := image.get_pixel(x1, y0)
	var c01 := image.get_pixel(x0, y1)
	var c11 := image.get_pixel(x1, y1)
	return c00.lerp(c10, tx).lerp(c01.lerp(c11, tx), ty)


func _world_pos_in_region(world_pos: Vector3, region_coord: Vector2i) -> bool:
	if terrain_provider == null or not terrain_provider.has_method("world_pos_to_region"):
		return false
	var sampled_region: Vector2i = terrain_provider.call("world_pos_to_region", world_pos)
	return sampled_region == region_coord


func _cell_grid_to_region(cell_grid: Vector2i) -> Vector2i:
	var cell_size := float(terrain_provider.get("cell_size"))
	var center := Vector3(
		(float(cell_grid.x) + 0.5) * cell_size,
		0.0,
		-(float(cell_grid.y) + 0.5) * cell_size
	)
	return terrain_provider.call("world_pos_to_region", center)


func _get_region_world_size() -> float:
	return float(terrain_provider.get("region_size")) * _get_vertex_spacing()


func _get_vertex_spacing() -> float:
	return maxf(float(terrain_provider.get("vertex_spacing")), 0.001)


func _region_bounds(region_coord: Vector2i) -> AABB:
	var size_m := _get_region_world_size()
	var origin := Vector3(float(region_coord.x) * size_m, -1000.0, -float(region_coord.y + 1) * size_m)
	return AABB(origin, Vector3(size_m, 2000.0, size_m))


func _build_renderable_river_payloads_for_region(region_coord: Vector2i, cached: Dictionary) -> Array[Dictionary]:
	var payloads: Array[Dictionary] = []
	for payload: Dictionary in _build_renderable_water_payloads_for_region(region_coord, cached):
		if payload.get("body_type", &"") == WaterBodyDescriptorScript.TYPE_RIVER:
			payloads.append(payload)
	return payloads


func _build_renderable_water_payloads_for_region(region_coord: Vector2i, cached: Dictionary) -> Array[Dictionary]:
	var flow_image: Image = cached.get("flow_image") as Image
	if flow_image == null:
		return []
	var width := flow_image.get_width()
	var height := flow_image.get_height()
	if width <= 0 or height <= 0:
		return []

	var payloads: Array[Dictionary] = []
	var components: Array = cached.get("components", [])
	for component_v: Variant in components:
		if not component_v is Dictionary:
			continue
		var component: Dictionary = component_v as Dictionary
		var is_river := bool(component.get("is_river", false))
		var component_id := int(component.get("component_id", payloads.size()))
		var component_bounds := _component_world_bounds(region_coord, component, width, height)
		if not is_river:
			if not _is_local_still_water_component(component, width, height):
				continue
			var lake_polygon := _component_bounds_polygon_xz(component_bounds)
			if lake_polygon.size() < 3:
				continue
			payloads.append({
				"body_id": StringName("morrowind_hydrology_%d_%d_lake_%d" % [region_coord.x, region_coord.y, component_id]),
				"body_type": WaterBodyDescriptorScript.TYPE_LAKE,
				"bounds": component_bounds,
				"polygon_world_points_xz": lake_polygon,
				"surface_height": float(terrain_provider.get("sea_level")) if terrain_provider != null else 0.0,
				"depth": 3.0,
				"flow_speed_meters_per_second": 0.0,
				"flowmap_image": flow_image,
				"flowmap_region_bounds": cached.get("bounds", _region_bounds(region_coord)),
				"source_schema": "godotwind.renderable_water.v2",
			})
			continue
		var centerline_pixels: Array = component.get("centerline_pixels", [])
		if centerline_pixels.is_empty():
			continue
		var centerline_world := PackedVector3Array()
		for pixel_v: Variant in centerline_pixels:
			var pixel := _variant_to_vector2(pixel_v)
			if pixel.x < 0.0 or pixel.y < 0.0:
				continue
			centerline_world.append(_pixel_to_world_surface(region_coord, pixel, width, height))
		if centerline_world.size() < 2:
			continue
		var speed := float(component.get("flow_speed_meters_per_second", DEFAULT_FLOW_SPEED_MPS))
		var direction := _variant_to_vector2(component.get("flow_direction", Vector2.RIGHT))
		if direction.length_squared() <= 0.0001:
			direction = Vector2.RIGHT
		payloads.append({
			"body_id": StringName("morrowind_hydrology_%d_%d_river_%d" % [region_coord.x, region_coord.y, component_id]),
			"body_type": WaterBodyDescriptorScript.TYPE_RIVER,
			"bounds": _component_world_bounds(region_coord, component, width, height),
			"centerline_world_points": centerline_world,
			"mean_width_meters": float(component.get("mean_width_meters", _get_vertex_spacing())),
			"flow_direction": direction.normalized(),
			"flow_speed_meters_per_second": speed,
			"surface_height": float(terrain_provider.get("sea_level")) if terrain_provider != null else 0.0,
			"flowmap_image": flow_image,
			"flowmap_region_bounds": cached.get("bounds", _region_bounds(region_coord)),
			"source_schema": "godotwind.renderable_water.v2",
		})
	return payloads


func _is_local_still_water_component(component: Dictionary, image_width: int, image_height: int) -> bool:
	var bounds := _variant_to_rect2i(component.get("bounds", Rect2i()))
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return false
	var touches_region_edge := bounds.position.x <= 0 \
		or bounds.position.y <= 0 \
		or bounds.position.x + bounds.size.x >= image_width \
		or bounds.position.y + bounds.size.y >= image_height
	if touches_region_edge:
		return false
	var image_area := maxi(image_width * image_height, 1)
	var area_pixels := int(component.get("area_pixels", bounds.size.x * bounds.size.y))
	if float(area_pixels) / float(image_area) > 0.35:
		return false
	if float(bounds.size.x) / maxf(float(image_width), 1.0) > 0.8:
		return false
	if float(bounds.size.y) / maxf(float(image_height), 1.0) > 0.8:
		return false
	return true


func _component_bounds_polygon_xz(bounds: AABB) -> PackedVector2Array:
	if bounds.size.x <= 0.001 or bounds.size.z <= 0.001:
		return PackedVector2Array()
	var min_x := bounds.position.x
	var max_x := bounds.position.x + bounds.size.x
	var min_z := bounds.position.z
	var max_z := bounds.position.z + bounds.size.z
	return PackedVector2Array([
		Vector2(min_x, min_z),
		Vector2(max_x, min_z),
		Vector2(max_x, max_z),
		Vector2(min_x, max_z),
	])


func _component_world_bounds(region_coord: Vector2i, component: Dictionary, image_width: int, image_height: int) -> AABB:
	var pixel_bounds := _variant_to_rect2i(component.get("bounds", Rect2i(0, 0, image_width, image_height)))
	var min_pixel := Vector2(float(pixel_bounds.position.x), float(pixel_bounds.position.y))
	var max_pixel := Vector2(
		float(pixel_bounds.position.x + maxi(pixel_bounds.size.x, 1)),
		float(pixel_bounds.position.y + maxi(pixel_bounds.size.y, 1))
	)
	var a := _pixel_to_world_surface(region_coord, min_pixel, image_width, image_height)
	var b := _pixel_to_world_surface(region_coord, max_pixel, image_width, image_height)
	var min_x := minf(a.x, b.x)
	var max_x := maxf(a.x, b.x)
	var min_z := minf(a.z, b.z)
	var max_z := maxf(a.z, b.z)
	var surface_y := float(terrain_provider.get("sea_level")) if terrain_provider != null else 0.0
	return AABB(Vector3(min_x, surface_y - 1.0, min_z), Vector3(maxf(max_x - min_x, 0.001), 2.0, maxf(max_z - min_z, 0.001)))


func _pixel_to_world_surface(region_coord: Vector2i, pixel: Vector2, image_width: int, image_height: int) -> Vector3:
	var region_size_m := _get_region_world_size()
	var origin_x := float(region_coord.x) * region_size_m
	var origin_neg_z := float(region_coord.y) * region_size_m
	var u := clampf((pixel.x + 0.5) / maxf(float(image_width), 1.0), 0.0, 1.0)
	var v := clampf((float(image_height) - 0.5 - pixel.y) / maxf(float(image_height), 1.0), 0.0, 1.0)
	return Vector3(
		origin_x + u * region_size_m,
		float(terrain_provider.get("sea_level")) if terrain_provider != null else 0.0,
		-(origin_neg_z + v * region_size_m)
	)


func _components_from_bake_result(result: Dictionary) -> Array[Dictionary]:
	var normalized: Array[Dictionary] = []
	var components: Array = result.get("components", [])
	for component_v: Variant in components:
		if not component_v is Dictionary:
			continue
		var component: Dictionary = component_v as Dictionary
		normalized.append({
			"component_id": int(component.get("component_id", normalized.size())),
			"area_pixels": int(component.get("area_pixels", 0)),
			"bounds": _variant_to_rect2i(component.get("bounds", Rect2i())),
			"aspect": float(component.get("aspect", 0.0)),
			"mean_width_meters": float(component.get("mean_width_meters", 0.0)),
			"is_river": bool(component.get("is_river", false)),
			"flow_direction": _variant_to_vector2(component.get("flow_direction", Vector2.ZERO)),
			"flow_speed_meters_per_second": float(component.get("flow_speed_meters_per_second", 0.0)),
			"centerline_pixels": _normalize_centerline_pixels(component.get("centerline_pixels", [])),
		})
	return normalized


func _serialize_components(components_v: Variant) -> Array[Dictionary]:
	var serialized: Array[Dictionary] = []
	if not components_v is Array:
		return serialized
	var components: Array = components_v as Array
	for component_v: Variant in components:
		if not component_v is Dictionary:
			continue
		var component: Dictionary = component_v as Dictionary
		var bounds := _variant_to_rect2i(component.get("bounds", Rect2i()))
		var flow_direction := _variant_to_vector2(component.get("flow_direction", Vector2.ZERO))
		var centerline_pixels := _normalize_centerline_pixels(component.get("centerline_pixels", []))
		var serialized_centerline: Array[Array] = []
		for pixel_v: Variant in centerline_pixels:
			var pixel := _variant_to_vector2(pixel_v)
			serialized_centerline.append([pixel.x, pixel.y])
		serialized.append({
			"component_id": int(component.get("component_id", serialized.size())),
			"area_pixels": int(component.get("area_pixels", 0)),
			"bounds": [bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y],
			"aspect": float(component.get("aspect", 0.0)),
			"mean_width_meters": float(component.get("mean_width_meters", 0.0)),
			"is_river": bool(component.get("is_river", false)),
			"flow_direction": [flow_direction.x, flow_direction.y],
			"flow_speed_meters_per_second": float(component.get("flow_speed_meters_per_second", 0.0)),
			"centerline_pixels": serialized_centerline,
		})
	return serialized


func _deserialize_components(components_v: Variant) -> Array[Dictionary]:
	var components: Array[Dictionary] = []
	if not components_v is Array:
		return components
	for component_v: Variant in components_v:
		if not component_v is Dictionary:
			continue
		var component: Dictionary = component_v as Dictionary
		components.append({
			"component_id": int(component.get("component_id", components.size())),
			"area_pixels": int(component.get("area_pixels", 0)),
			"bounds": _variant_to_rect2i(component.get("bounds", Rect2i())),
			"aspect": float(component.get("aspect", 0.0)),
			"mean_width_meters": float(component.get("mean_width_meters", 0.0)),
			"is_river": bool(component.get("is_river", false)),
			"flow_direction": _variant_to_vector2(component.get("flow_direction", Vector2.ZERO)),
			"flow_speed_meters_per_second": float(component.get("flow_speed_meters_per_second", 0.0)),
			"centerline_pixels": _normalize_centerline_pixels(component.get("centerline_pixels", [])),
		})
	return components


func _normalize_centerline_pixels(centerline_v: Variant) -> Array[Vector2]:
	var pixels: Array[Vector2] = []
	if not centerline_v is Array:
		return pixels
	var centerline: Array = centerline_v as Array
	for pixel_v: Variant in centerline:
		var pixel := _variant_to_vector2(pixel_v)
		if pixel.x >= 0.0 and pixel.y >= 0.0:
			pixels.append(pixel)
	return pixels


func _variant_to_vector2(value: Variant) -> Vector2:
	if value is Vector2:
		return value as Vector2
	if value is Vector2i:
		var vi := value as Vector2i
		return Vector2(float(vi.x), float(vi.y))
	if value is Array:
		var array: Array = value as Array
		if array.size() >= 2:
			return Vector2(float(array[0]), float(array[1]))
	if value is Dictionary:
		var dict: Dictionary = value as Dictionary
		return Vector2(float(dict.get("x", -1.0)), float(dict.get("y", -1.0)))
	return Vector2(-1.0, -1.0)


func _variant_to_rect2i(value: Variant) -> Rect2i:
	if value is Rect2i:
		return value as Rect2i
	if value is Rect2:
		var rect := value as Rect2
		return Rect2i(
			int(floorf(rect.position.x)),
			int(floorf(rect.position.y)),
			int(ceilf(rect.size.x)),
			int(ceilf(rect.size.y))
		)
	if value is Array:
		var array: Array = value as Array
		if array.size() >= 4:
			return Rect2i(int(array[0]), int(array[1]), int(array[2]), int(array[3]))
	if value is Dictionary:
		var dict: Dictionary = value as Dictionary
		if dict.has("position") and dict.has("size"):
			var position := _variant_to_vector2(dict["position"])
			var size := _variant_to_vector2(dict["size"])
			return Rect2i(int(position.x), int(position.y), int(size.x), int(size.y))
		return Rect2i(int(dict.get("x", 0)), int(dict.get("y", 0)), int(dict.get("width", 0)), int(dict.get("height", 0)))
	return Rect2i()


func _height_samples_from_heightmap(heightmap: Image) -> Array[float]:
	var width := heightmap.get_width()
	var height := heightmap.get_height()
	var heights: Array[float] = []
	heights.resize(width * height)
	for y in range(height):
		for x in range(width):
			heights[y * width + x] = heightmap.get_pixel(x, y).r
	return heights


func _cache_key_for_region(region_coord: Vector2i, heightmap: Image) -> String:
	var image_hash := hash(heightmap.get_data())
	return _cache_key_for_values(
		region_coord,
		heightmap.get_width(),
		heightmap.get_height(),
		float(terrain_provider.get("sea_level")),
		_get_vertex_spacing(),
		image_hash
	)


func _cache_key_for_values(region_coord: Vector2i, width: int, height: int, sea_level: float, vertex_spacing: float, image_hash: int) -> String:
	return "%s_region_%d_%d_%dx%d_sl%.3f_vs%.3f_%d" % [
		CACHE_VERSION,
		region_coord.x,
		region_coord.y,
		width,
		height,
		sea_level,
		vertex_spacing,
		image_hash,
	]


func _load_cached_region(cache_key: String, region_coord: Vector2i) -> Dictionary:
	if not cache_enabled:
		return {}
	var dir := _get_cache_directory()
	if dir.is_empty():
		return {}
	var image_path := dir.path_join(cache_key + ".png")
	var metadata_path := dir.path_join(cache_key + ".json")
	if not FileAccess.file_exists(image_path) or not FileAccess.file_exists(metadata_path):
		return {}

	var image := Image.load_from_file(image_path)
	if image == null:
		return {}
	var metadata_file := FileAccess.open(metadata_path, FileAccess.READ)
	if metadata_file == null:
		return {}
	var parsed: Variant = JSON.parse_string(metadata_file.get_as_text())
	if not parsed is Dictionary:
		return {}
	var metadata := parsed as Dictionary
	return {
		"flow_image": image,
		"components": _deserialize_components(metadata.get("components", [])),
		"river_count": int(metadata.get("river_count", 0)),
		"bounds": _region_bounds(region_coord),
		"cache_key": cache_key,
	}


func _save_cached_region(cache_key: String, data: Dictionary) -> void:
	if not cache_enabled:
		return
	var dir := _get_cache_directory()
	if dir.is_empty():
		return
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK:
		Log.warn("water", "MorrowindHydrologyProvider: could not create flowmap cache directory %s" % dir)
		return
	var image: Image = data.get("flow_image") as Image
	if image == null:
		return
	var image_path := dir.path_join(cache_key + ".png")
	var metadata_path := dir.path_join(cache_key + ".json")
	if image.save_png(image_path) != OK:
		Log.warn("water", "MorrowindHydrologyProvider: could not save flowmap cache image %s" % image_path)
		return
	var metadata := {
		"river_count": int(data.get("river_count", 0)),
		"components": _serialize_components(data.get("components", [])),
		"algorithm": CACHE_VERSION,
		"format": "RGBA8 flowmap: RG=direction, B=speed, A=coverage",
	}
	var metadata_file := FileAccess.open(metadata_path, FileAccess.WRITE)
	if metadata_file != null:
		metadata_file.store_string(JSON.stringify(metadata, "\t"))
		metadata_file.close()


func _get_cache_directory() -> String:
	if not cache_directory.is_empty():
		return ProjectSettings.globalize_path(cache_directory) if cache_directory.begins_with("user://") or cache_directory.begins_with("res://") else cache_directory
	return SettingsManager.get_cache_base_path().path_join("water").path_join("morrowind_flowmaps")


func _ensure_terrain_provider_ready() -> Error:
	if _terrain_provider_ready:
		return OK
	if terrain_provider == null:
		return ERR_UNCONFIGURED
	if terrain_provider.has_method("initialize"):
		var err: int = terrain_provider.call("initialize")
		if err != OK:
			return err
	_terrain_provider_ready = true
	return OK


func _execute_prepare_region_task(
	request: RegionBakeRequest,
	baker: RefCounted,
	heights: Array[float],
	width: int,
	height: int,
	sea_level: float,
	vertex_spacing: float,
	region_world_size: float,
	cache_key: String,
	use_cache: bool,
	cache_dir: String
) -> void:
	var region_coord := request.region_coord
	var cached := _load_cached_region_for_values(use_cache, cache_dir, cache_key, region_coord, region_world_size)
	if not cached.is_empty():
		request.data = cached
		request.error = OK
		return

	baker.Width = width
	baker.Height = height
	baker.SeaLevel = sea_level
	baker.TexelSizeMeters = maxf(vertex_spacing, 0.001)
	baker.FlowSpeedMetersPerSecond = DEFAULT_FLOW_SPEED_MPS
	baker.MaxEncodedSpeedMetersPerSecond = MAX_ENCODED_SPEED_MPS

	var result: Dictionary = baker.BakeFromHeights(heights)
	var flow_image: Image = result.get("image") as Image
	if flow_image == null:
		request.error = FAILED
		return
	request.data = {
		"flow_image": flow_image,
		"components": _components_from_bake_result(result),
		"river_count": int(result.get("river_count", 0)),
		"bounds": _region_bounds_for_values(region_coord, region_world_size),
		"cache_key": cache_key,
	}
	_save_cached_region_for_values(use_cache, cache_dir, cache_key, request.data)
	request.error = OK


func _region_bounds_for_values(region_coord: Vector2i, size_m: float) -> AABB:
	var origin := Vector3(float(region_coord.x) * size_m, -1000.0, -float(region_coord.y + 1) * size_m)
	return AABB(origin, Vector3(size_m, 2000.0, size_m))


func _load_cached_region_for_values(use_cache: bool, dir: String, cache_key: String, region_coord: Vector2i, region_world_size: float) -> Dictionary:
	if not use_cache or dir.is_empty():
		return {}
	var image_path := dir.path_join(cache_key + ".png")
	var metadata_path := dir.path_join(cache_key + ".json")
	if not FileAccess.file_exists(image_path) or not FileAccess.file_exists(metadata_path):
		return {}

	var image := Image.load_from_file(image_path)
	if image == null:
		return {}
	var metadata_file := FileAccess.open(metadata_path, FileAccess.READ)
	if metadata_file == null:
		return {}
	var parsed: Variant = JSON.parse_string(metadata_file.get_as_text())
	if not parsed is Dictionary:
		return {}
	var metadata := parsed as Dictionary
	return {
		"flow_image": image,
		"components": _deserialize_components(metadata.get("components", [])),
		"river_count": int(metadata.get("river_count", 0)),
		"bounds": _region_bounds_for_values(region_coord, region_world_size),
		"cache_key": cache_key,
	}


func _save_cached_region_for_values(use_cache: bool, dir: String, cache_key: String, data: Dictionary) -> void:
	if not use_cache or dir.is_empty():
		return
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK:
		return
	var image: Image = data.get("flow_image") as Image
	if image == null:
		return
	var image_path := dir.path_join(cache_key + ".png")
	var metadata_path := dir.path_join(cache_key + ".json")
	if image.save_png(image_path) != OK:
		return
	var metadata := {
		"river_count": int(data.get("river_count", 0)),
		"components": _serialize_components(data.get("components", [])),
		"algorithm": CACHE_VERSION,
		"format": "RGBA8 flowmap: RG=direction, B=speed, A=coverage",
	}
	var metadata_file := FileAccess.open(metadata_path, FileAccess.WRITE)
	if metadata_file != null:
		metadata_file.store_string(JSON.stringify(metadata, "\t"))
		metadata_file.close()


func _touch_region(region_coord: Vector2i) -> void:
	_region_cache_last_used[region_coord] = Time.get_ticks_msec()


func _trim_region_cache(max_regions: int = -1) -> void:
	var limit := max_regions if max_regions >= 0 else max_cached_regions
	if limit <= 0:
		return
	while _region_cache.size() > limit:
		var lru_region := Vector2i(2147483647, 2147483647)
		var lru_time := 9223372036854775807
		for region_coord: Vector2i in _region_cache.keys():
			if int(_region_ref_counts.get(region_coord, 0)) > 0:
				continue
			var used := int(_region_cache_last_used.get(region_coord, 0))
			if used < lru_time:
				lru_time = used
				lru_region = region_coord
		if lru_region == Vector2i(2147483647, 2147483647):
			break
		_region_cache.erase(lru_region)
		_region_cache_last_used.erase(lru_region)
