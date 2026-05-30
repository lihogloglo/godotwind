class_name MorrowindGpuHydrologyBaker
extends RefCounted

const SHADER_PATH := "res://src/core/world/morrowind/shaders/morrowind_hydrology_bake.glsl"
const LOCAL_SIZE := 8
const DEFAULT_FLOW_SPEED_MPS := 1.4
const DEFAULT_MAX_ENCODED_SPEED_MPS := 6.0
const PASS_INIT_MASKS := 0
const PASS_BANK_DISTANCE := 1
const PASS_CORRIDOR_CANDIDATE := 2
const PASS_OCEAN_INIT := 3
const PASS_OCEAN_FLOOD := 4
const PASS_LABEL_INIT := 5
const PASS_LABEL_RELAX := 6
const PASS_OUTLET_INIT := 7
const PASS_OUTLET_RELAX := 8
const PASS_STATS_RESET := 9
const PASS_STATS_ACCUMULATE := 10
const PASS_CLASSIFY_AND_FLOW := 11
const STATS_FIELDS := 14
const STAT_AREA := 0
const STAT_MIN_X := 1
const STAT_MIN_Y := 2
const STAT_MAX_X := 3
const STAT_MAX_Y := 4
const STAT_BROAD_ADJ := 5
const STAT_OUTLET_PIXELS := 6
const STAT_MAX_OUTLET := 7
const STAT_WIDTH_SUM := 8
const STAT_WIDTH_MAX := 9
const STAT_HEIGHT_MIN_CM := 10
const STAT_HEIGHT_MAX_CM := 11
const STAT_RIVER_PIXELS := 12
const STAT_RESERVED := 13

var sea_level: float = 0.0
var wet_tolerance_m: float = 0.12
var max_river_width_m: float = 125.0
var min_river_width_m: float = 7.0
var halo_pixels: int = 64
var coast_band_pixels: int = 8
var min_inland_run_m: float = 130.0
var max_candidate_coast_fraction: float = 0.55
var max_candidate_ocean_contact_fraction: float = 0.22
var require_open_water_connection: bool = true
var local_ocean_postprocess_enabled: bool = true
var topology_fallback_multiplier: int = 2
var min_terrain_drop_m: float = 0.25
var debug_enabled: bool = false
var flow_speed_mps: float = DEFAULT_FLOW_SPEED_MPS
var max_encoded_speed_mps: float = DEFAULT_MAX_ENCODED_SPEED_MPS
var enabled: bool = true

var _rd: RenderingDevice = null
var _shader: RID
var _pipeline: RID
var _available: bool = false
var _last_error: Error = OK
var _last_bake_usec: int = 0


func is_available() -> bool:
	if not enabled:
		return false
	if _available:
		return true
	return initialize() == OK


func initialize() -> Error:
	if _available:
		return OK
	if not enabled:
		_last_error = ERR_UNAVAILABLE
		return _last_error
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		_last_error = ERR_UNAVAILABLE
		return _last_error
	var shader_file := load(SHADER_PATH) as RDShaderFile
	if shader_file == null:
		_shutdown_device()
		_last_error = ERR_FILE_CANT_OPEN
		return _last_error
	var shader_spirv := shader_file.get_spirv()
	_shader = _rd.shader_create_from_spirv(shader_spirv)
	if not _shader.is_valid():
		_shutdown_device()
		_last_error = ERR_CANT_CREATE
		return _last_error
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_shutdown_device()
		_last_error = ERR_CANT_CREATE
		return _last_error
	_available = true
	_last_error = OK
	return OK


func shutdown() -> void:
	_shutdown_device()


func get_last_error() -> Error:
	return _last_error


func get_last_bake_usec() -> int:
	return _last_bake_usec


func bake_from_heightmap(heightmap: Image, vertex_spacing_m: float, crop_rect: Rect2i = Rect2i()) -> Dictionary:
	if heightmap == null:
		return {}
	var width := heightmap.get_width()
	var height := heightmap.get_height()
	if heightmap.get_format() == Image.FORMAT_RF:
		var height_bytes := heightmap.get_data()
		if height_bytes.size() >= width * height * 4:
			return _bake_from_height_bytes(width, height, height_bytes, vertex_spacing_m, crop_rect)
	var heights := PackedFloat32Array()
	heights.resize(width * height)
	for y in range(height):
		for x in range(width):
			heights[y * width + x] = heightmap.get_pixel(x, y).r
	return bake_from_heights(width, height, heights, vertex_spacing_m, crop_rect)


func bake_from_heights(
	width: int,
	height: int,
	heights: PackedFloat32Array,
	vertex_spacing_m: float,
	crop_rect: Rect2i = Rect2i()
) -> Dictionary:
	if width <= 0 or height <= 0 or heights.size() < width * height:
		_last_error = ERR_INVALID_PARAMETER
		return {}
	return _bake_from_height_bytes(width, height, heights.to_byte_array(), vertex_spacing_m, crop_rect)


func _bake_from_height_bytes(
	width: int,
	height: int,
	height_bytes: PackedByteArray,
	vertex_spacing_m: float,
	crop_rect: Rect2i = Rect2i()
) -> Dictionary:
	if width <= 0 or height <= 0 or height_bytes.size() < width * height * 4:
		_last_error = ERR_INVALID_PARAMETER
		return {}
	if initialize() != OK:
		return {}

	var start_usec := Time.get_ticks_usec()
	var pixel_count := width * height
	var zeroed_flow_bytes := PackedByteArray()
	zeroed_flow_bytes.resize(pixel_count * 4)
	zeroed_flow_bytes.fill(0)
	var zeroed_flag_bytes := zeroed_flow_bytes.duplicate()
	var zeroed_label_bytes := zeroed_flow_bytes.duplicate()
	var zeroed_bank_bytes := zeroed_flow_bytes.duplicate()
	var zeroed_outlet_bytes := zeroed_flow_bytes.duplicate()
	var zeroed_width_bytes := zeroed_flow_bytes.duplicate()
	var zeroed_reason_bytes := zeroed_flow_bytes.duplicate()
	var zeroed_stats_bytes := PackedByteArray()
	zeroed_stats_bytes.resize(pixel_count * STATS_FIELDS * 4)
	zeroed_stats_bytes.fill(0)
	var zeroed_change_bytes := PackedByteArray()
	zeroed_change_bytes.resize(4)
	zeroed_change_bytes.fill(0)

	var height_buffer := _rd.storage_buffer_create(height_bytes.size(), height_bytes)
	var flow_buffer := _rd.storage_buffer_create(zeroed_flow_bytes.size(), zeroed_flow_bytes)
	var flag_buffer := _rd.storage_buffer_create(zeroed_flag_bytes.size(), zeroed_flag_bytes)
	var label_buffer := _rd.storage_buffer_create(zeroed_label_bytes.size(), zeroed_label_bytes)
	var stats_buffer := _rd.storage_buffer_create(zeroed_stats_bytes.size(), zeroed_stats_bytes)
	var change_buffer := _rd.storage_buffer_create(zeroed_change_bytes.size(), zeroed_change_bytes)
	var bank_buffer := _rd.storage_buffer_create(zeroed_bank_bytes.size(), zeroed_bank_bytes)
	var outlet_buffer := _rd.storage_buffer_create(zeroed_outlet_bytes.size(), zeroed_outlet_bytes)
	var width_buffer := _rd.storage_buffer_create(zeroed_width_bytes.size(), zeroed_width_bytes)
	var reason_buffer := _rd.storage_buffer_create(zeroed_reason_bytes.size(), zeroed_reason_bytes)
	var buffers := [
		height_buffer,
		flow_buffer,
		flag_buffer,
		label_buffer,
		stats_buffer,
		change_buffer,
		bank_buffer,
		outlet_buffer,
		width_buffer,
		reason_buffer,
	]
	if not _all_rids_valid(buffers):
		_free_rids(buffers)
		_last_error = ERR_CANT_CREATE
		return {}

	var uniforms: Array[RDUniform] = []
	for binding in range(buffers.size()):
		uniforms.append(_storage_buffer_uniform(binding, buffers[binding]))

	var uniform_set := _rd.uniform_set_create(uniforms, _shader, 0)
	if not uniform_set.is_valid():
		_free_rids(buffers)
		_last_error = ERR_CANT_CREATE
		return {}

	var max_bank_radius_px := maxi(2, ceili(max_river_width_m * 0.5 / maxf(vertex_spacing_m, 0.001)))
	var min_bank_radius_px := maxi(1, floori(min_river_width_m * 0.5 / maxf(vertex_spacing_m, 0.001)))
	var min_inland_run_px := maxi(1, ceili(min_inland_run_m / maxf(vertex_spacing_m, 0.001)))

	var groups_x := ceili(float(width) / float(LOCAL_SIZE))
	var groups_y := ceili(float(height) / float(LOCAL_SIZE))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	_dispatch_pass(cl, uniform_set, PASS_INIT_MASKS, width, height, max_bank_radius_px, min_bank_radius_px, min_inland_run_px, vertex_spacing_m, groups_x, groups_y)
	for _i in range(max_bank_radius_px + 3):
		_rd.compute_list_add_barrier(cl)
		_dispatch_pass(cl, uniform_set, PASS_BANK_DISTANCE, width, height, max_bank_radius_px, min_bank_radius_px, min_inland_run_px, vertex_spacing_m, groups_x, groups_y)
	_rd.compute_list_add_barrier(cl)
	_dispatch_pass(cl, uniform_set, PASS_CORRIDOR_CANDIDATE, width, height, max_bank_radius_px, min_bank_radius_px, min_inland_run_px, vertex_spacing_m, groups_x, groups_y)
	_rd.compute_list_add_barrier(cl)
	_dispatch_pass(cl, uniform_set, PASS_OCEAN_INIT, width, height, max_bank_radius_px, min_bank_radius_px, min_inland_run_px, vertex_spacing_m, groups_x, groups_y)
	for _i in range(width + height):
		_rd.compute_list_add_barrier(cl)
		_dispatch_pass(cl, uniform_set, PASS_OCEAN_FLOOD, width, height, max_bank_radius_px, min_bank_radius_px, min_inland_run_px, vertex_spacing_m, groups_x, groups_y)
	_rd.compute_list_add_barrier(cl)
	_dispatch_pass(cl, uniform_set, PASS_LABEL_INIT, width, height, max_bank_radius_px, min_bank_radius_px, min_inland_run_px, vertex_spacing_m, groups_x, groups_y)
	for _i in range(maxi(width, height)):
		_rd.compute_list_add_barrier(cl)
		_dispatch_pass(cl, uniform_set, PASS_LABEL_RELAX, width, height, max_bank_radius_px, min_bank_radius_px, min_inland_run_px, vertex_spacing_m, groups_x, groups_y)
	_rd.compute_list_add_barrier(cl)
	_dispatch_pass(cl, uniform_set, PASS_OUTLET_INIT, width, height, max_bank_radius_px, min_bank_radius_px, min_inland_run_px, vertex_spacing_m, groups_x, groups_y)
	for _i in range(width + height):
		_rd.compute_list_add_barrier(cl)
		_dispatch_pass(cl, uniform_set, PASS_OUTLET_RELAX, width, height, max_bank_radius_px, min_bank_radius_px, min_inland_run_px, vertex_spacing_m, groups_x, groups_y)
	_rd.compute_list_add_barrier(cl)
	_dispatch_pass(cl, uniform_set, PASS_STATS_RESET, width, height, max_bank_radius_px, min_bank_radius_px, min_inland_run_px, vertex_spacing_m, groups_x, groups_y)
	_rd.compute_list_add_barrier(cl)
	_dispatch_pass(cl, uniform_set, PASS_STATS_ACCUMULATE, width, height, max_bank_radius_px, min_bank_radius_px, min_inland_run_px, vertex_spacing_m, groups_x, groups_y)
	_rd.compute_list_add_barrier(cl)
	_dispatch_pass(cl, uniform_set, PASS_CLASSIFY_AND_FLOW, width, height, max_bank_radius_px, min_bank_radius_px, min_inland_run_px, vertex_spacing_m, groups_x, groups_y)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	var flow_bytes := _rd.buffer_get_data(flow_buffer)
	var label_bytes := _rd.buffer_get_data(label_buffer)
	var stats_bytes := _rd.buffer_get_data(stats_buffer)
	var flag_bytes := _rd.buffer_get_data(flag_buffer) if debug_enabled else PackedByteArray()
	var bank_bytes := _rd.buffer_get_data(bank_buffer) if debug_enabled else PackedByteArray()
	var outlet_bytes := _rd.buffer_get_data(outlet_buffer) if debug_enabled else PackedByteArray()
	var width_bytes := _rd.buffer_get_data(width_buffer) if debug_enabled else PackedByteArray()
	var reason_bytes := _rd.buffer_get_data(reason_buffer) if debug_enabled else PackedByteArray()
	_rd.free_rid(uniform_set)
	_free_rids(buffers)
	if flow_bytes.size() < pixel_count * 4 or label_bytes.size() < pixel_count * 4 or stats_bytes.size() < pixel_count * STATS_FIELDS * 4:
		_last_error = FAILED
		return {}

	var output_width := width
	var output_height := height
	var output_bytes := flow_bytes
	var output_label_bytes := label_bytes
	var output_flag_bytes := flag_bytes
	var output_bank_bytes := bank_bytes
	var output_outlet_bytes := outlet_bytes
	var output_width_bytes := width_bytes
	var output_reason_bytes := reason_bytes
	if crop_rect.size.x > 0 and crop_rect.size.y > 0:
		var clipped_crop := crop_rect.intersection(Rect2i(0, 0, width, height))
		if clipped_crop.size.x <= 0 or clipped_crop.size.y <= 0:
			_last_error = ERR_INVALID_PARAMETER
			return {}
		output_bytes = _crop_flow_bytes(flow_bytes, width, clipped_crop)
		output_label_bytes = _crop_flow_bytes(label_bytes, width, clipped_crop)
		if debug_enabled:
			output_flag_bytes = _crop_flow_bytes(flag_bytes, width, clipped_crop)
			output_bank_bytes = _crop_flow_bytes(bank_bytes, width, clipped_crop)
			output_outlet_bytes = _crop_flow_bytes(outlet_bytes, width, clipped_crop)
			output_width_bytes = _crop_flow_bytes(width_bytes, width, clipped_crop)
			output_reason_bytes = _crop_flow_bytes(reason_bytes, width, clipped_crop)
		output_width = clipped_crop.size.x
		output_height = clipped_crop.size.y

	var flow_image := Image.create_from_data(output_width, output_height, false, Image.FORMAT_RGBA8, output_bytes)
	var components := _extract_components_from_labeled_flow(
		output_bytes,
		output_label_bytes,
		output_width,
		output_height,
		maxf(vertex_spacing_m, 0.001)
	)
	var river_count := 0
	for component: Dictionary in components:
		if bool(component.get("is_river", false)):
			river_count += 1
	var result := {
		"image": flow_image,
		"components": components,
		"river_count": river_count,
		"bake_usec": 0,
		"backend": "gpu_compute",
		"body_stats_backend": "gpu_corridor_label_stats",
	}
	if debug_enabled:
		result["debug_images"] = _build_debug_images(
			output_bytes,
			output_flag_bytes,
			output_bank_bytes,
			output_outlet_bytes,
			output_width_bytes,
			output_reason_bytes,
			output_width,
			output_height,
			max_bank_radius_px,
			min_inland_run_px
		)
	_last_bake_usec = Time.get_ticks_usec() - start_usec
	result["bake_usec"] = _last_bake_usec
	_last_error = OK
	return result


func _dispatch_pass(
	compute_list: int,
	_uniform_set: RID,
	pass_index: int,
	width: int,
	height: int,
	max_bank_radius_px: int,
	min_bank_radius_px: int,
	min_inland_run_px: int,
	vertex_spacing_m: float,
	groups_x: int,
	groups_y: int
) -> void:
	var push_constants := RenderingContext.create_push_constant([
		width,
		height,
		pass_index,
		max_bank_radius_px,
		min_bank_radius_px,
		roundi(clampf(max_candidate_ocean_contact_fraction, 0.01, 1.0) * 100.0),
		min_inland_run_px,
		maxi(topology_fallback_multiplier, 1),
		sea_level,
		wet_tolerance_m,
		maxf(vertex_spacing_m, 0.001),
		max_encoded_speed_mps,
		flow_speed_mps,
		max_river_width_m,
		min_river_width_m,
		min_terrain_drop_m,
	])
	_rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
	_rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)


func _storage_buffer_uniform(binding: int, rid: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(rid)
	return uniform


func _all_rids_valid(rids: Array) -> bool:
	for rid_v: Variant in rids:
		var rid: RID = rid_v
		if not rid.is_valid():
			return false
	return true


func _free_rids(rids: Array) -> void:
	if _rd == null:
		return
	for rid_v: Variant in rids:
		var rid: RID = rid_v
		if rid.is_valid():
			_rd.free_rid(rid)


func _postprocess_ocean_connected_candidates(
	flow_bytes: PackedByteArray,
	width: int,
	height: int,
	vertex_spacing_m: float
) -> int:
	var pixel_count := width * height
	var wet := PackedByteArray()
	var candidate := PackedByteArray()
	wet.resize(pixel_count)
	candidate.resize(pixel_count)
	for i in range(pixel_count):
		if _alpha_at(flow_bytes, i) > 0:
			wet[i] = 1
		if _speed_at(flow_bytes, i) > 0:
			candidate[i] = 1

	var candidate_block_radius := maxi(1, ceili(maxf(min_river_width_m, vertex_spacing_m * 2.0) / maxf(vertex_spacing_m, 0.001)))
	var candidate_block := _dilate_mask(candidate, wet, width, height, candidate_block_radius)
	var ocean := _build_ocean_core_mask(wet, candidate_block, width, height)
	var coast_band := _build_coast_band(ocean, wet, width, height, coast_band_pixels)
	var water_segments := _segment_mask_with_metadata(wet, width, height)
	var water_ids: PackedInt32Array = water_segments.get("ids", PackedInt32Array())
	var water_components: Array = water_segments.get("components", [])
	var components := _segment_mask(candidate, width, height)
	var rejected := 0
	for pixels: PackedInt32Array in components:
		var water_component := _dominant_water_component_for_pixels(pixels, water_ids, water_components)
		if _should_reject_candidate_as_ocean(pixels, water_component, wet, ocean, coast_band, width, height, vertex_spacing_m):
			for idx: int in pixels:
				if _speed_at(flow_bytes, idx) > 0:
					flow_bytes[idx * 4 + 2] = 0
					rejected += 1
	return rejected


func _build_ocean_core_mask(wet: PackedByteArray, candidate: PackedByteArray, width: int, height: int) -> PackedByteArray:
	var ocean := PackedByteArray()
	ocean.resize(width * height)
	var queue := PackedInt32Array()
	for x in range(width):
		_enqueue_ocean_seed(queue, ocean, wet, candidate, width, x, 0)
		_enqueue_ocean_seed(queue, ocean, wet, candidate, width, x, height - 1)
	for y in range(height):
		_enqueue_ocean_seed(queue, ocean, wet, candidate, width, 0, y)
		_enqueue_ocean_seed(queue, ocean, wet, candidate, width, width - 1, y)

	var head := 0
	while head < queue.size():
		var idx := queue[head]
		head += 1
		var x := idx % width
		var y := int(idx / width)
		for oy in range(-1, 2):
			for ox in range(-1, 2):
				if ox == 0 and oy == 0:
					continue
				_enqueue_ocean_seed(queue, ocean, wet, candidate, width, x + ox, y + oy)
	return ocean


func _dilate_mask(mask: PackedByteArray, limit_mask: PackedByteArray, width: int, height: int, radius: int) -> PackedByteArray:
	var result := mask.duplicate()
	for y in range(height):
		for x in range(width):
			var idx := y * width + x
			if mask[idx] == 0:
				continue
			for oy in range(-radius, radius + 1):
				for ox in range(-radius, radius + 1):
					var nx := x + ox
					var ny := y + oy
					if nx < 0 or ny < 0 or nx >= width or ny >= height:
						continue
					var nidx := ny * width + nx
					if limit_mask[nidx] > 0:
						result[nidx] = 1
	return result


func _enqueue_ocean_seed(
	queue: PackedInt32Array,
	ocean: PackedByteArray,
	wet: PackedByteArray,
	candidate: PackedByteArray,
	width: int,
	x: int,
	y: int
) -> void:
	var height := int(wet.size() / maxi(width, 1))
	if x < 0 or y < 0 or x >= width or y >= height:
		return
	var idx := y * width + x
	if wet[idx] == 0 or candidate[idx] > 0 or ocean[idx] > 0:
		return
	ocean[idx] = 1
	queue.append(idx)


func _build_coast_band(ocean: PackedByteArray, wet: PackedByteArray, width: int, height: int, radius: int) -> PackedByteArray:
	var band := ocean.duplicate()
	var frontier := ocean.duplicate()
	for _step in range(maxi(radius, 0)):
		var next := band.duplicate()
		for y in range(height):
			for x in range(width):
				var idx := y * width + x
				if frontier[idx] == 0:
					continue
				for oy in range(-1, 2):
					for ox in range(-1, 2):
						var nx := x + ox
						var ny := y + oy
						if nx < 0 or ny < 0 or nx >= width or ny >= height:
							continue
						var nidx := ny * width + nx
						if wet[nidx] > 0:
							next[nidx] = 1
		frontier = _mask_difference(next, band)
		band = next
	return band


func _mask_difference(a: PackedByteArray, b: PackedByteArray) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(a.size())
	for i in range(a.size()):
		if a[i] > 0 and b[i] == 0:
			result[i] = 1
	return result


func _segment_mask(mask: PackedByteArray, width: int, height: int) -> Array[PackedInt32Array]:
	var visited := PackedByteArray()
	visited.resize(width * height)
	var components: Array[PackedInt32Array] = []
	var queue := PackedInt32Array()
	for y in range(height):
		for x in range(width):
			var start_idx := y * width + x
			if visited[start_idx] > 0 or mask[start_idx] == 0:
				continue
			var pixels := PackedInt32Array()
			queue.clear()
			queue.append(start_idx)
			visited[start_idx] = 1
			var head := 0
			while head < queue.size():
				var idx := queue[head]
				head += 1
				pixels.append(idx)
				var px := idx % width
				var py := int(idx / width)
				for oy in range(-1, 2):
					for ox in range(-1, 2):
						if ox == 0 and oy == 0:
							continue
						var nx := px + ox
						var ny := py + oy
						if nx < 0 or ny < 0 or nx >= width or ny >= height:
							continue
						var nidx := ny * width + nx
						if visited[nidx] == 0 and mask[nidx] > 0:
							visited[nidx] = 1
							queue.append(nidx)
			components.append(pixels)
	return components


func _segment_mask_with_metadata(mask: PackedByteArray, width: int, height: int) -> Dictionary:
	var ids := PackedInt32Array()
	ids.resize(width * height)
	ids.fill(-1)
	var components: Array[Dictionary] = []
	var queue := PackedInt32Array()
	for y in range(height):
		for x in range(width):
			var start_idx := y * width + x
			if ids[start_idx] >= 0 or mask[start_idx] == 0:
				continue
			var component_id := components.size()
			queue.clear()
			queue.append(start_idx)
			ids[start_idx] = component_id
			var head := 0
			var area := 0
			var min_x := x
			var max_x := x
			var min_y := y
			var max_y := y
			var touches_edge := false
			while head < queue.size():
				var idx := queue[head]
				head += 1
				var px := idx % width
				var py := int(idx / width)
				area += 1
				min_x = mini(min_x, px)
				max_x = maxi(max_x, px)
				min_y = mini(min_y, py)
				max_y = maxi(max_y, py)
				if px == 0 or py == 0 or px == width - 1 or py == height - 1:
					touches_edge = true
				for oy in range(-1, 2):
					for ox in range(-1, 2):
						if ox == 0 and oy == 0:
							continue
						var nx := px + ox
						var ny := py + oy
						if nx < 0 or ny < 0 or nx >= width or ny >= height:
							continue
						var nidx := ny * width + nx
						if ids[nidx] < 0 and mask[nidx] > 0:
							ids[nidx] = component_id
							queue.append(nidx)
			components.append({
				"component_id": component_id,
				"area_pixels": area,
				"bounds": Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1),
				"touches_edge": touches_edge,
			})
	return {
		"ids": ids,
		"components": components,
	}


func _dominant_water_component_for_pixels(
	pixels: PackedInt32Array,
	water_ids: PackedInt32Array,
	water_components: Array
) -> Dictionary:
	if pixels.is_empty() or water_ids.is_empty() or water_components.is_empty():
		return {}
	var counts: Dictionary = {}
	for idx: int in pixels:
		if idx < 0 or idx >= water_ids.size():
			continue
		var component_id := water_ids[idx]
		if component_id < 0:
			continue
		counts[component_id] = int(counts.get(component_id, 0)) + 1
	var best_id := -1
	var best_count := 0
	for component_id_v: Variant in counts.keys():
		var component_id := int(component_id_v)
		var count := int(counts[component_id_v])
		if count > best_count:
			best_count = count
			best_id = component_id
	if best_id < 0 or best_id >= water_components.size():
		return {}
	var component_v: Variant = water_components[best_id]
	return component_v as Dictionary if component_v is Dictionary else {}


func _should_reject_candidate_as_ocean(
	pixels: PackedInt32Array,
	water_component: Dictionary,
	wet: PackedByteArray,
	ocean: PackedByteArray,
	coast_band: PackedByteArray,
	width: int,
	height: int,
	vertex_spacing_m: float
) -> bool:
	if pixels.is_empty():
		return false
	if require_open_water_connection and not bool(water_component.get("touches_edge", false)):
		return true
	var coast_pixels := 0
	var ocean_contact_pixels := 0
	var points := PackedVector2Array()
	for idx: int in pixels:
		if coast_band[idx] > 0:
			coast_pixels += 1
		var x := idx % width
		var y := int(idx / width)
		if _touches_mask(x, y, ocean, width, height, maxi(coast_band_pixels, 2)):
			ocean_contact_pixels += 1
		points.append(Vector2(float(x), float(y)))
	var coast_fraction := float(coast_pixels) / float(pixels.size())
	var ocean_contact_fraction := float(ocean_contact_pixels) / float(pixels.size())
	var inland_run_m := _longest_inland_run(points, coast_band, width, height) * vertex_spacing_m
	if inland_run_m >= min_inland_run_m:
		return false
	if ocean_contact_fraction <= 0.0:
		return false
	var endpoint_contacts := _component_endpoint_ocean_contacts(points, ocean, coast_band, width, height)
	if int(endpoint_contacts.get("start", 0)) > 0 and int(endpoint_contacts.get("end", 0)) > 0:
		return true
	var wet_axis_contacts := _wet_axis_ocean_contacts(points, wet, width, height)
	if int(wet_axis_contacts.get("start", 0)) > 0 and int(wet_axis_contacts.get("end", 0)) > 0:
		return true
	if ocean_contact_fraction > max_candidate_ocean_contact_fraction:
		return true
	if coast_fraction > max_candidate_coast_fraction:
		return true
	return inland_run_m < min_inland_run_m


func _wet_axis_ocean_contacts(points: PackedVector2Array, wet: PackedByteArray, width: int, height: int) -> Dictionary:
	if points.is_empty():
		return {"start": 0, "end": 0}
	var axis := _dominant_axis(points)
	var min_x := width
	var max_x := -1
	var min_y := height
	var max_y := -1
	for point: Vector2 in points:
		var x := clampi(roundi(point.x), 0, width - 1)
		var y := clampi(roundi(point.y), 0, height - 1)
		min_x = mini(min_x, x)
		max_x = maxi(max_x, x)
		min_y = mini(min_y, y)
		max_y = maxi(max_y, y)
	if absf(axis.x) >= absf(axis.y):
		return {
			"start": 1 if _wet_reaches_edge_horizontally(wet, width, height, min_y, max_y, min_x, -1) else 0,
			"end": 1 if _wet_reaches_edge_horizontally(wet, width, height, min_y, max_y, max_x, 1) else 0,
		}
	return {
		"start": 1 if _wet_reaches_edge_vertically(wet, width, height, min_x, max_x, min_y, -1) else 0,
		"end": 1 if _wet_reaches_edge_vertically(wet, width, height, min_x, max_x, max_y, 1) else 0,
	}


func _wet_reaches_edge_horizontally(wet: PackedByteArray, width: int, height: int, min_y: int, max_y: int, start_x: int, step: int) -> bool:
	var x := start_x
	while x >= 0 and x < width:
		var has_wet := false
		for y in range(maxi(min_y - 2, 0), mini(max_y + 3, height)):
			if wet[y * width + x] > 0:
				has_wet = true
				break
		if not has_wet:
			return false
		x += step
	return true


func _wet_reaches_edge_vertically(wet: PackedByteArray, width: int, height: int, min_x: int, max_x: int, start_y: int, step: int) -> bool:
	var y := start_y
	while y >= 0 and y < height:
		var has_wet := false
		for x in range(maxi(min_x - 2, 0), mini(max_x + 3, width)):
			if wet[y * width + x] > 0:
				has_wet = true
				break
		if not has_wet:
			return false
		y += step
	return true


func _component_endpoint_ocean_contacts(
	points: PackedVector2Array,
	ocean: PackedByteArray,
	coast_band: PackedByteArray,
	width: int,
	height: int
) -> Dictionary:
	if points.is_empty():
		return {"start": 0, "end": 0}
	var ordered := _ordered_centerline(points, _dominant_axis(points))
	var sample_count := clampi(ceili(float(ordered.size()) * 0.25), 1, 24)
	return {
		"start": _centerline_range_contacts(ordered, 0, sample_count, ocean, coast_band, width, height),
		"end": _centerline_range_contacts(ordered, ordered.size() - sample_count, ordered.size(), ocean, coast_band, width, height),
	}


func _centerline_range_contacts(
	points: Array[Vector2],
	start: int,
	end: int,
	ocean: PackedByteArray,
	coast_band: PackedByteArray,
	width: int,
	height: int
) -> int:
	var contacts := 0
	for i in range(maxi(start, 0), mini(end, points.size())):
		var point := points[i]
		var x := clampi(roundi(point.x), 0, width - 1)
		var y := clampi(roundi(point.y), 0, height - 1)
		if _touches_mask(x, y, ocean, width, height, maxi(coast_band_pixels, 4)) or _touches_mask(x, y, coast_band, width, height, 2):
			contacts += 1
	return contacts


func _longest_inland_run(points: PackedVector2Array, coast_band: PackedByteArray, width: int, height: int) -> int:
	if points.is_empty():
		return 0
	var axis := _dominant_axis(points)
	var ordered := _ordered_centerline(points, axis)
	var longest := 0
	var current := 0
	var last_axis_coord := -2147483648
	for point: Vector2 in ordered:
		var x := clampi(roundi(point.x), 0, width - 1)
		var y := clampi(roundi(point.y), 0, height - 1)
		var axis_coord := x if absf(axis.x) >= absf(axis.y) else y
		if axis_coord == last_axis_coord:
			continue
		last_axis_coord = axis_coord
		if coast_band[y * width + x] == 0:
			current += 1
			longest = maxi(longest, current)
		else:
			current = 0
	return longest


func _dominant_axis(points: PackedVector2Array) -> Vector2:
	if points.size() < 2:
		return Vector2.RIGHT
	var min_x := points[0].x
	var max_x := points[0].x
	var min_y := points[0].y
	var max_y := points[0].y
	for point: Vector2 in points:
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
		min_y = minf(min_y, point.y)
		max_y = maxf(max_y, point.y)
	return Vector2.RIGHT if (max_x - min_x) >= (max_y - min_y) else Vector2.DOWN


func _touches_mask(x: int, y: int, mask: PackedByteArray, width: int, height: int, radius: int) -> bool:
	for oy in range(-radius, radius + 1):
		for ox in range(-radius, radius + 1):
			var nx := x + ox
			var ny := y + oy
			if nx < 0 or ny < 0 or nx >= width or ny >= height:
				continue
			if mask[ny * width + nx] > 0:
				return true
	return false


func _crop_flow_bytes(flow_bytes: PackedByteArray, source_width: int, crop_rect: Rect2i) -> PackedByteArray:
	var cropped := PackedByteArray()
	cropped.resize(crop_rect.size.x * crop_rect.size.y * 4)
	for y in range(crop_rect.size.y):
		var source_offset := ((crop_rect.position.y + y) * source_width + crop_rect.position.x) * 4
		var target_offset := y * crop_rect.size.x * 4
		for byte_index in range(crop_rect.size.x * 4):
			cropped[target_offset + byte_index] = flow_bytes[source_offset + byte_index]
	return cropped


func _extract_components_from_labeled_flow(
	flow_bytes: PackedByteArray,
	label_bytes: PackedByteArray,
	width: int,
	height: int,
	vertex_spacing_m: float
) -> Array[Dictionary]:
	var components: Array[Dictionary] = []
	var by_key: Dictionary = {}
	for y in range(height):
		for x in range(width):
			var idx := y * width + x
			if _alpha_at(flow_bytes, idx) == 0 or _speed_at(flow_bytes, idx) <= 0:
				continue
			var label := _decode_u32(label_bytes, idx * 4)
			if label == 0:
				label = idx + 1
			var key := "%d:river" % label
			if not by_key.has(key):
				by_key[key] = {
					"label": label,
					"area_pixels": 0,
					"min_x": x,
					"max_x": x,
					"min_y": y,
					"max_y": y,
					"river_pixels": 0,
					"dir_sum": Vector2.ZERO,
					"river_points": PackedVector2Array(),
					"touches_edge": false,
				}
			var component: Dictionary = by_key[key]
			component["area_pixels"] = int(component["area_pixels"]) + 1
			component["min_x"] = mini(int(component["min_x"]), x)
			component["max_x"] = maxi(int(component["max_x"]), x)
			component["min_y"] = mini(int(component["min_y"]), y)
			component["max_y"] = maxi(int(component["max_y"]), y)
			if x == 0 or y == 0 or x == width - 1 or y == height - 1:
				component["touches_edge"] = true
			var river_pixels := int(component["river_pixels"]) + 1
			component["river_pixels"] = river_pixels
			component["dir_sum"] = (component["dir_sum"] as Vector2) + _direction_at(flow_bytes, idx)
			var river_points: PackedVector2Array = component["river_points"]
			if river_points.size() < 512 or river_pixels % 8 == 0:
				river_points.append(Vector2(float(x), float(y)))
			component["river_points"] = river_points

	var sortable: Array = by_key.values()
	sortable.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_y := int(a.get("min_y", 0))
		var b_y := int(b.get("min_y", 0))
		if a_y == b_y:
			return int(a.get("min_x", 0)) < int(b.get("min_x", 0))
		return a_y < b_y
	)
	for component_v: Variant in sortable:
		var source: Dictionary = component_v as Dictionary
		var min_x := int(source.get("min_x", 0))
		var max_x := int(source.get("max_x", min_x))
		var min_y := int(source.get("min_y", 0))
		var max_y := int(source.get("max_y", min_y))
		var bounds := Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)
		var river_pixels := int(source.get("river_pixels", 0))
		var is_river := river_pixels > 0
		var flow_direction := (source.get("dir_sum", Vector2.ZERO) as Vector2)
		flow_direction = flow_direction.normalized() if flow_direction.length_squared() > 0.0001 else Vector2.RIGHT
		var river_points: PackedVector2Array = source.get("river_points", PackedVector2Array())
		components.append({
			"component_id": components.size(),
			"source_label": int(source.get("label", 0)),
			"area_pixels": int(source.get("area_pixels", 0)),
			"bounds": bounds,
			"aspect": maxf(float(bounds.size.x), float(bounds.size.y)) / maxf(minf(float(bounds.size.x), float(bounds.size.y)), 1.0),
			"mean_width_meters": maxf(minf(float(bounds.size.x), float(bounds.size.y)) * vertex_spacing_m, vertex_spacing_m),
			"is_river": is_river,
			"body_type": &"river" if is_river else &"lake",
			"ocean_contact": bool(source.get("touches_edge", false)),
			"flow_direction": flow_direction,
			"flow_speed_meters_per_second": flow_speed_mps if is_river else 0.0,
			"centerline_pixels": _ordered_centerline(river_points, flow_direction) if is_river else [],
		})
	_append_still_components(components, flow_bytes, width, height, vertex_spacing_m)
	return components


func _append_still_components(
	components: Array[Dictionary],
	flow_bytes: PackedByteArray,
	width: int,
	height: int,
	vertex_spacing_m: float
) -> void:
	var visited := PackedByteArray()
	visited.resize(width * height)
	var queue := PackedInt32Array()
	for y in range(height):
		for x in range(width):
			var start_idx := y * width + x
			if visited[start_idx] > 0 or _alpha_at(flow_bytes, start_idx) == 0 or _speed_at(flow_bytes, start_idx) > 0:
				continue
			queue.clear()
			queue.append(start_idx)
			visited[start_idx] = 1
			var head := 0
			var min_x := x
			var max_x := x
			var min_y := y
			var max_y := y
			var area := 0
			var touches_edge := false
			while head < queue.size():
				var idx := queue[head]
				head += 1
				var px := idx % width
				var py := int(idx / width)
				area += 1
				min_x = mini(min_x, px)
				max_x = maxi(max_x, px)
				min_y = mini(min_y, py)
				max_y = maxi(max_y, py)
				if px == 0 or py == 0 or px == width - 1 or py == height - 1:
					touches_edge = true
				_append_still_neighbor(flow_bytes, visited, queue, width, height, px - 1, py)
				_append_still_neighbor(flow_bytes, visited, queue, width, height, px + 1, py)
				_append_still_neighbor(flow_bytes, visited, queue, width, height, px, py - 1)
				_append_still_neighbor(flow_bytes, visited, queue, width, height, px, py + 1)
			var bounds := Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)
			components.append({
				"component_id": components.size(),
				"source_label": 0,
				"area_pixels": area,
				"bounds": bounds,
				"aspect": maxf(float(bounds.size.x), float(bounds.size.y)) / maxf(minf(float(bounds.size.x), float(bounds.size.y)), 1.0),
				"mean_width_meters": maxf(minf(float(bounds.size.x), float(bounds.size.y)) * vertex_spacing_m, vertex_spacing_m),
				"is_river": false,
				"body_type": &"lake",
				"ocean_contact": touches_edge,
				"flow_direction": Vector2.ZERO,
				"flow_speed_meters_per_second": 0.0,
				"centerline_pixels": [],
			})


func _append_still_neighbor(
	flow_bytes: PackedByteArray,
	visited: PackedByteArray,
	queue: PackedInt32Array,
	width: int,
	height: int,
	x: int,
	y: int
) -> void:
	if x < 0 or y < 0 or x >= width or y >= height:
		return
	var idx := y * width + x
	if visited[idx] > 0 or _alpha_at(flow_bytes, idx) == 0 or _speed_at(flow_bytes, idx) > 0:
		return
	visited[idx] = 1
	queue.append(idx)


func _build_debug_images(
	flow_bytes: PackedByteArray,
	flag_bytes: PackedByteArray,
	bank_bytes: PackedByteArray,
	outlet_bytes: PackedByteArray,
	width_bytes: PackedByteArray,
	reason_bytes: PackedByteArray,
	width: int,
	height: int,
	max_bank_radius_px: int,
	min_inland_run_px: int
) -> Dictionary:
	if flag_bytes.is_empty() or bank_bytes.is_empty() or outlet_bytes.is_empty() or reason_bytes.is_empty():
		return {}
	var wet := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var ocean := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var bank := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var corridor := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var accepted := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var outlet := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var rejection := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var width_img := Image.create(width, height, false, Image.FORMAT_RGBA8)
	for img: Image in [wet, ocean, bank, corridor, accepted, outlet, rejection, width_img]:
		img.fill(Color.TRANSPARENT)
	var outlet_norm := maxf(float(min_inland_run_px * topology_fallback_multiplier), 1.0)
	for y in range(height):
		for x in range(width):
			var idx := y * width + x
			var flags := _decode_u32(flag_bytes, idx * 4)
			var is_wet := (flags & 1) != 0
			if not is_wet:
				continue
			wet.set_pixel(x, y, Color(0.0, 0.55, 1.0, 0.72))
			if (flags & 4) != 0:
				ocean.set_pixel(x, y, Color(0.0, 0.20, 1.0, 0.74))
			elif (flags & 2) != 0:
				ocean.set_pixel(x, y, Color(0.08, 0.44, 0.82, 0.50))
			var bank_px := _decode_u32(bank_bytes, idx * 4)
			var bank_t := clampf(float(bank_px) / maxf(float(max_bank_radius_px), 1.0), 0.0, 1.0)
			bank.set_pixel(x, y, Color(bank_t, bank_t, bank_t, 0.80))
			var local_width := _decode_u32(width_bytes, idx * 4) if not width_bytes.is_empty() else 0
			if local_width > 0:
				var width_t := clampf(float(local_width) / maxf(float(max_bank_radius_px * 2), 1.0), 0.0, 1.0)
				width_img.set_pixel(x, y, Color(width_t, 1.0 - width_t, 0.25, 0.82))
			if (flags & 8) != 0:
				corridor.set_pixel(x, y, Color(1.0, 0.78, 0.05, 0.76))
			if (flags & 32) != 0:
				accepted.set_pixel(x, y, Color(0.0, 0.95, 0.72, 0.84))
			var od := _decode_u32(outlet_bytes, idx * 4)
			if od < 0x3ffffff:
				var t := clampf(float(od) / outlet_norm, 0.0, 1.0)
				outlet.set_pixel(x, y, Color(1.0 - t, t, 0.95, 0.82))
			var reason := _decode_u32(reason_bytes, idx * 4)
			rejection.set_pixel(x, y, _reason_color(reason))
	return {
		"wet_mask": wet,
		"ocean_core": ocean,
		"bank_distance": bank,
		"corridor_candidates": corridor,
		"accepted_rivers": accepted,
		"outlet_distance": outlet,
		"local_width": width_img,
		"rejection_reason": rejection,
	}


func _reason_color(reason: int) -> Color:
	match reason:
		255:
			return Color(0.0, 0.95, 0.72, 0.84)
		1:
			return Color(0.0, 0.20, 0.95, 0.42)
		2:
			return Color(0.85, 0.85, 0.85, 0.78)
		3:
			return Color(1.0, 0.68, 0.05, 0.82)
		4:
			return Color(1.0, 0.05, 0.72, 0.82)
		5:
			return Color(0.72, 0.25, 1.0, 0.82)
		6:
			return Color(1.0, 0.15, 0.08, 0.82)
		_:
			return Color.TRANSPARENT


func _decode_u32(bytes: PackedByteArray, offset: int) -> int:
	if offset < 0 or offset + 3 >= bytes.size():
		return 0
	return bytes.decode_u32(offset)


func _extract_components(flow_bytes: PackedByteArray, width: int, height: int, vertex_spacing_m: float) -> Array[Dictionary]:
	var visited := PackedByteArray()
	visited.resize(width * height)
	var components: Array[Dictionary] = []
	var queue := PackedInt32Array()
	for y in range(height):
		for x in range(width):
			var start_idx := y * width + x
			if visited[start_idx] > 0 or _alpha_at(flow_bytes, start_idx) == 0:
				continue
			queue.clear()
			queue.append(start_idx)
			visited[start_idx] = 1
			var head := 0
			var min_x := x
			var max_x := x
			var min_y := y
			var max_y := y
			var area := 0
			var river_pixels := 0
			var dir_sum := Vector2.ZERO
			var river_points := PackedVector2Array()
			while head < queue.size():
				var idx := queue[head]
				head += 1
				var px := idx % width
				var py := int(idx / width)
				area += 1
				min_x = mini(min_x, px)
				max_x = maxi(max_x, px)
				min_y = mini(min_y, py)
				max_y = maxi(max_y, py)
				if _speed_at(flow_bytes, idx) > 0:
					river_pixels += 1
					dir_sum += _direction_at(flow_bytes, idx)
					if river_points.size() < 512 or river_pixels % 8 == 0:
						river_points.append(Vector2(float(px), float(py)))
				_append_neighbor_if_wet(flow_bytes, visited, queue, width, height, px - 1, py)
				_append_neighbor_if_wet(flow_bytes, visited, queue, width, height, px + 1, py)
				_append_neighbor_if_wet(flow_bytes, visited, queue, width, height, px, py - 1)
				_append_neighbor_if_wet(flow_bytes, visited, queue, width, height, px, py + 1)
			var bounds := Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)
			var is_river := river_pixels > 0
			var flow_direction := dir_sum.normalized() if dir_sum.length_squared() > 0.0001 else Vector2.RIGHT
			var centerline := _ordered_centerline(river_points, flow_direction)
			components.append({
				"component_id": components.size(),
				"area_pixels": area,
				"bounds": bounds,
				"aspect": maxf(float(bounds.size.x), float(bounds.size.y)) / maxf(minf(float(bounds.size.x), float(bounds.size.y)), 1.0),
				"mean_width_meters": maxf(minf(float(bounds.size.x), float(bounds.size.y)) * vertex_spacing_m, vertex_spacing_m),
				"is_river": is_river,
				"flow_direction": flow_direction,
				"flow_speed_meters_per_second": flow_speed_mps if is_river else 0.0,
				"centerline_pixels": centerline,
			})
	return components


func _append_neighbor_if_wet(
	flow_bytes: PackedByteArray,
	visited: PackedByteArray,
	queue: PackedInt32Array,
	width: int,
	height: int,
	x: int,
	y: int
) -> void:
	if x < 0 or y < 0 or x >= width or y >= height:
		return
	var idx := y * width + x
	if visited[idx] > 0 or _alpha_at(flow_bytes, idx) == 0:
		return
	visited[idx] = 1
	queue.append(idx)


func _ordered_centerline(points: PackedVector2Array, direction: Vector2) -> Array[Vector2]:
	var result: Array[Vector2] = []
	if points.is_empty():
		return result
	var axis := direction.normalized()
	if axis.length_squared() <= 0.0001:
		axis = Vector2.RIGHT
	var sortable: Array[Dictionary] = []
	for point: Vector2 in points:
		sortable.append({"point": point, "t": point.dot(axis)})
	sortable.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["t"]) < float(b["t"])
	)
	var stride := maxi(1, ceili(float(sortable.size()) / 128.0))
	for i in range(0, sortable.size(), stride):
		result.append(sortable[i]["point"] as Vector2)
	if result.size() == 1 and sortable.size() > 1:
		result.append(sortable[sortable.size() - 1]["point"] as Vector2)
	return result


func _alpha_at(bytes: PackedByteArray, pixel_index: int) -> int:
	return bytes[pixel_index * 4 + 3]


func _speed_at(bytes: PackedByteArray, pixel_index: int) -> int:
	return bytes[pixel_index * 4 + 2]


func _direction_at(bytes: PackedByteArray, pixel_index: int) -> Vector2:
	var base := pixel_index * 4
	return Vector2(float(bytes[base]) / 255.0 * 2.0 - 1.0, float(bytes[base + 1]) / 255.0 * 2.0 - 1.0)


func _shutdown_device() -> void:
	if _rd == null:
		_available = false
		return
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	if _shader.is_valid():
		_rd.free_rid(_shader)
	_pipeline = RID()
	_shader = RID()
	_rd.free()
	_rd = null
	_available = false
