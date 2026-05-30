class_name MorrowindHydrologyAtlasPrebaker
extends RefCounted

const GpuHydrologyBakerScript := preload("res://src/core/world/morrowind/morrowind_gpu_hydrology_baker.gd")
const CS := preload("res://src/core/coordinate_system.gd")

const SCHEMA := "godotwind.morrowind.hydrology.global_flow_atlas.v1"
const PREBAKED_CACHE_VERSION := "morrowind_gpu_hydrology_region_v1"
const FLOW_FORMAT := "RGBA8 flowmap: RG=direction, B=speed, A=coverage"
const DEFAULT_REGION_SIZE_PIXELS := 256
const DEFAULT_VERTEX_SPACING_M := CS.CELL_SIZE_GODOT / 64.0

signal progress(current: int, total: int, region_key: String)

var terrain_data_directory: String = ""
var output_directory: String = ""
var region_size_pixels: int = DEFAULT_REGION_SIZE_PIXELS
var vertex_spacing_m: float = DEFAULT_VERTEX_SPACING_M
var sea_level: float = 0.0
var wet_tolerance_m: float = 0.0
var max_river_width_m: float = 125.0
var min_river_width_m: float = 7.0
var halo_pixels: int = 64
var min_open_sea_area_pixels: int = 16384
var stop_requested: bool = false


func bake_from_terrain3d_directory() -> Dictionary:
	var settings := _get_settings_manager()
	var terrain_dir := _resolve_path(terrain_data_directory)
	if terrain_dir.is_empty():
		if settings == null:
			return {"error": ERR_UNCONFIGURED, "message": "SettingsManager autoload is unavailable"}
		terrain_dir = settings.get_terrain_path()
	var out_dir := _resolve_path(output_directory)
	if out_dir.is_empty():
		if settings == null:
			return {"error": ERR_UNCONFIGURED, "message": "SettingsManager autoload is unavailable"}
		out_dir = settings.get_cache_base_path().path_join("water").path_join("morrowind_hydrology_atlas")
	if not DirAccess.dir_exists_absolute(terrain_dir):
		return {"error": ERR_DOES_NOT_EXIST, "message": "Terrain3D cache directory not found: %s" % terrain_dir}
	var mk_err := DirAccess.make_dir_recursive_absolute(out_dir)
	if mk_err != OK:
		return {"error": mk_err, "message": "Could not create hydrology atlas directory: %s" % out_dir}

	var terrain_data := Terrain3DData.new()
	terrain_data.load_directory(terrain_dir)
	return _bake_from_loaded_terrain_data(terrain_data, terrain_dir, out_dir)


func bake_from_terrain3d(terrain: Terrain3D) -> Dictionary:
	if terrain == null or terrain.data == null:
		return {"error": ERR_INVALID_PARAMETER, "message": "Terrain3D node or Terrain3D data is unavailable"}
	var settings := _get_settings_manager()
	var terrain_dir := _resolve_path(terrain_data_directory)
	if terrain_dir.is_empty() and settings != null:
		terrain_dir = settings.get_terrain_path()
	var out_dir := _resolve_path(output_directory)
	if out_dir.is_empty():
		if settings == null:
			return {"error": ERR_UNCONFIGURED, "message": "SettingsManager autoload is unavailable"}
		out_dir = settings.get_cache_base_path().path_join("water").path_join("morrowind_hydrology_atlas")
	var mk_err := DirAccess.make_dir_recursive_absolute(out_dir)
	if mk_err != OK:
		return {"error": mk_err, "message": "Could not create hydrology atlas directory: %s" % out_dir}
	return _bake_from_loaded_terrain_data(terrain.data, terrain_dir, out_dir)


func _bake_from_loaded_terrain_data(terrain_data: Terrain3DData, terrain_dir: String, out_dir: String) -> Dictionary:
	var heightmaps := _load_heightmaps_from_terrain_data(terrain_data)
	if heightmaps.is_empty():
		return {"error": ERR_DOES_NOT_EXIST, "message": "No active Terrain3D height regions found in %s" % terrain_dir}

	var sorted_regions: Array[Vector2i] = []
	for region_v: Variant in heightmaps.keys():
		sorted_regions.append(region_v as Vector2i)
	sorted_regions.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x)
	)

	var baker: MorrowindGpuHydrologyBaker = GpuHydrologyBakerScript.new()
	_configure_baker(baker)
	var init_err := baker.initialize()
	if init_err != OK:
		return {
			"error": init_err,
			"success": 0,
			"failed": sorted_regions.size(),
			"skipped": 0,
			"output_directory": out_dir,
			"message": "GPU hydrology baker unavailable",
		}

	var manifest_regions: Array[Dictionary] = []
	var baked := 0
	var failed := 0
	var total_bake_ms := 0.0
	for i in range(sorted_regions.size()):
		if stop_requested:
			break
		var region_coord := sorted_regions[i]
		var key := _prebaked_region_key(region_coord)
		var heightmap: Image = heightmaps[region_coord]
		var padded_heightmap := _build_padded_heightmap(region_coord, heightmap, heightmaps)
		var crop_rect := Rect2i(halo_pixels, halo_pixels, heightmap.get_width(), heightmap.get_height())
		var region_result: Dictionary = baker.bake_from_heightmap(padded_heightmap, vertex_spacing_m, crop_rect)
		var flow_image: Image = region_result.get("image") as Image
		if flow_image == null:
			failed += 1
			progress.emit(i + 1, sorted_regions.size(), key)
			continue
		total_bake_ms += float(region_result.get("bake_usec", 0)) / 1000.0
		var image_path := out_dir.path_join(key + ".png")
		var metadata_path := out_dir.path_join(key + ".json")
		var save_err := flow_image.save_png(image_path)
		if save_err != OK:
			failed += 1
			progress.emit(i + 1, sorted_regions.size(), key)
			continue
		var metadata := {
			"schema": SCHEMA,
			"algorithm": PREBAKED_CACHE_VERSION,
			"source": "offline_global_prebake",
			"flow_format": FLOW_FORMAT,
			"region": [region_coord.x, region_coord.y],
			"neighbor_edges": _build_neighbor_edges(region_coord, heightmaps),
			"region_size_pixels": flow_image.get_width(),
			"vertex_spacing_meters": vertex_spacing_m,
			"sea_level_meters": sea_level,
			"river_count": int(region_result.get("river_count", 0)),
			"components": _serialize_components(region_result.get("components", [])),
		}
		_write_json(metadata_path, metadata)
		manifest_regions.append({
			"region": [region_coord.x, region_coord.y],
			"image": key + ".png",
			"metadata": key + ".json",
			"neighbor_edges": _build_neighbor_edges(region_coord, heightmaps),
			"river_count": int(region_result.get("river_count", 0)),
		})
		baked += 1
		progress.emit(i + 1, sorted_regions.size(), key)
	baker.shutdown()

	var manifest := {
		"schema": SCHEMA,
		"algorithm": PREBAKED_CACHE_VERSION,
		"source": "offline_global_prebake",
		"flow_format": FLOW_FORMAT,
		"terrain_data_directory": terrain_dir,
		"region_size_pixels": region_size_pixels,
		"vertex_spacing_meters": vertex_spacing_m,
		"sea_level_meters": sea_level,
		"regions": manifest_regions,
	}
	_write_json(out_dir.path_join("manifest.json"), manifest)
	return {
		"error": OK,
		"success": baked,
		"failed": failed,
		"skipped": sorted_regions.size() - baked - failed,
		"output_directory": out_dir,
		"total_bake_ms": total_bake_ms,
	}


func request_stop() -> void:
	stop_requested = true


func _configure_baker(baker: MorrowindGpuHydrologyBaker) -> void:
	baker.sea_level = sea_level
	baker.wet_tolerance_m = wet_tolerance_m
	baker.max_river_width_m = max_river_width_m
	baker.min_river_width_m = min_river_width_m
	baker.halo_pixels = halo_pixels
	baker.require_open_water_connection = true
	baker.local_ocean_postprocess_enabled = false


func _load_heightmaps_from_terrain_data(terrain_data: Terrain3DData) -> Dictionary:
	var heightmaps: Dictionary = {}
	for region: Terrain3DRegion in terrain_data.get_regions_active():
		if region == null:
			continue
		var t3d_loc := Vector2i(region.get_location())
		var region_coord := _terrain3d_location_to_mw_region(t3d_loc)
		var heightmap := region.get_map(Terrain3DRegion.TYPE_HEIGHT) as Image
		if heightmap == null:
			continue
		var copy := heightmap.duplicate()
		if copy.get_format() != Image.FORMAT_RF:
			copy.convert(Image.FORMAT_RF)
		region_size_pixels = copy.get_width()
		heightmaps[region_coord] = copy
	return heightmaps


func _build_padded_heightmap(region_coord: Vector2i, center_heightmap: Image, heightmaps: Dictionary) -> Image:
	if center_heightmap == null or halo_pixels <= 0:
		return center_heightmap
	var width := center_heightmap.get_width()
	var height := center_heightmap.get_height()
	var padded := Image.create(width + halo_pixels * 2, height + halo_pixels * 2, false, Image.FORMAT_RF)
	padded.fill(Color(sea_level - 16.0, 0.0, 0.0, 1.0))
	for region_y_offset in range(-1, 2):
		for region_x_offset in range(-1, 2):
			var source_region := region_coord + Vector2i(region_x_offset, region_y_offset)
			var source: Image = center_heightmap if source_region == region_coord else heightmaps.get(source_region) as Image
			if source == null:
				continue
			var dest := Vector2i(halo_pixels + region_x_offset * width, halo_pixels - region_y_offset * height)
			_blit_clipped_heightmap(source, padded, dest)
	return padded


func _blit_clipped_heightmap(source: Image, target: Image, dest: Vector2i) -> void:
	var x0 := maxi(dest.x, 0)
	var y0 := maxi(dest.y, 0)
	var x1 := mini(dest.x + source.get_width(), target.get_width())
	var y1 := mini(dest.y + source.get_height(), target.get_height())
	if x1 <= x0 or y1 <= y0:
		return
	target.blit_rect(source, Rect2i(x0 - dest.x, y0 - dest.y, x1 - x0, y1 - y0), Vector2i(x0, y0))


func _serialize_components(components_v: Variant) -> Array[Dictionary]:
	var serialized: Array[Dictionary] = []
	if not components_v is Array:
		return serialized
	var components: Array = components_v as Array
	for component_v: Variant in components:
		if not component_v is Dictionary:
			continue
		var component: Dictionary = component_v as Dictionary
		var bounds: Rect2i = component.get("bounds", Rect2i())
		var flow_direction: Vector2 = component.get("flow_direction", Vector2.ZERO)
		var centerline_pixels := _normalize_centerline_pixels(component.get("centerline_pixels", []))
		var serialized_centerline: Array[Array] = []
		for pixel: Vector2 in centerline_pixels:
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


func _normalize_centerline_pixels(centerline_v: Variant) -> Array[Vector2]:
	var pixels: Array[Vector2] = []
	if not centerline_v is Array:
		return pixels
	for pixel_v: Variant in centerline_v:
		if pixel_v is Vector2:
			pixels.append(pixel_v as Vector2)
		elif pixel_v is Array:
			var arr: Array = pixel_v as Array
			if arr.size() >= 2:
				pixels.append(Vector2(float(arr[0]), float(arr[1])))
	return pixels


func _build_neighbor_edges(region_coord: Vector2i, heightmaps: Dictionary) -> Dictionary:
	return {
		"west": heightmaps.has(region_coord + Vector2i.LEFT),
		"east": heightmaps.has(region_coord + Vector2i.RIGHT),
		"north": heightmaps.has(region_coord + Vector2i.UP),
		"south": heightmaps.has(region_coord + Vector2i.DOWN),
	}


func _write_json(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()


func _resolve_path(path: String) -> String:
	if path.is_empty():
		return ""
	if path.begins_with("user://") or path.begins_with("res://"):
		return ProjectSettings.globalize_path(path)
	return path


func _get_settings_manager() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("SettingsManager")


static func _terrain3d_location_to_mw_region(t3d_loc: Vector2i) -> Vector2i:
	return Vector2i(t3d_loc.x, -t3d_loc.y)


static func _prebaked_region_key(region_coord: Vector2i) -> String:
	return "region_%d_%d" % [region_coord.x, region_coord.y]
