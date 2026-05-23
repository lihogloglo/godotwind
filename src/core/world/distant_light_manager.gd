## DistantLightManager - paged billboard MultiMeshes for lights beyond NEAR tier.
##
## Canonical Godot pattern:
## - Use MultiMesh for many simple instances.
## - Split large worlds into bounded spatial batches because a MultiMesh is
##   culled as one object, not per slot.
## - Keep per-frame work sparse; stream cells and rebuild dirty pages under a
##   small deadline instead of rebuilding one global buffer on cell crossing.
class_name DistantLightManager
extends RefCounted

const DU := preload("res://src/core/world/distance_utils.gd")
const WorldObjectRecordScript := preload("res://src/core/world/world_object_record.gd")

#region Configuration

const MIN_DISTANCE: float = DU.NEAR_END
const MAX_DISTANCE: float = DU.FAR_END
const FADE_MARGIN: float = 30.0
const BASE_SPRITE_SIZE: float = 3.0
const MIN_SCREEN_FACTOR: float = 0.005
const MAX_INSTANCES: int = 4096
const DUSK_THRESHOLD: float = 0.15
const NIGHT_THRESHOLD: float = -0.05

const LIGHT_PAGE_SIZE_CELLS: int = 4
const SCAN_CELLS_MAX_PER_FRAME: int = 96
const SCAN_BUDGET_USEC: int = 1200
const FULL_RING_ENUM_CELLS_MAX_PER_FRAME: int = 512
const FULL_RING_ENUM_BUDGET_USEC: int = 600
const PAGE_REBUILD_MAX_PER_FRAME: int = 16
const PAGE_REBUILD_BUDGET_USEC: int = 1200
const PAGE_AABB_MARGIN: float = 32.0

#endregion


#region Data classes

class LightData:
	var id: int
	var cell_grid: Vector2i
	var page_key: Vector2i
	var position: Vector3
	var color: Color
	var radius: float
	var light_animation: int
	var is_fire: bool


class LightPage:
	var key: Vector2i
	var center: Vector3
	var multimesh: MultiMesh
	var instance_rid: RID
	var light_ids: Array[int] = []

#endregion


#region Internal state

var _parent_node: Node3D = null
var _scenario: RID = RID()
var _material: ShaderMaterial = null
var _quad_mesh: QuadMesh = null
var _is_setup: bool = false
var _streaming_enabled: bool = true
var _world_object_source: RefCounted = null
var _coordinate_mapper: RefCounted = null

var _lights: Dictionary[int, LightData] = {}
var _next_id: int = 0
var _cell_index: Dictionary[Vector2i, Array] = {}
var _loaded_cells: Dictionary[Vector2i, bool] = {}
var _pending_cells: Array[Vector2i] = []
var _pending_cell_set: Dictionary[Vector2i, bool] = {}
var _pages: Dictionary[Vector2i, LightPage] = {}
var _dirty_pages: Array[Vector2i] = []
var _dirty_page_set: Dictionary[Vector2i, bool] = {}

var _center_cell: Vector2i = Vector2i(999999, 999999)
var _radius_cells: int = 0
var _night_factor: float = 0.0
var _full_ring_active: bool = false
var _full_ring_center: Vector2i = Vector2i.ZERO
var _full_ring_radius: int = 0
var _full_ring_dx: int = 0
var _full_ring_dy: int = 0

var _stats: Dictionary = {
	"distant_light_count": 0,
	"distant_light_loaded_cells": 0,
	"distant_light_pending_cells": 0,
	"distant_light_page_count": 0,
	"distant_light_dirty_pages": 0,
	"distant_light_pages_rebuilt": 0,
	"distant_light_scan_us": 0,
	"distant_light_cells_scanned": 0,
	"distant_light_rebuild_us": 0,
	"distant_light_rebuild_max_us": 0,
	"distant_light_full_enum_us": 0,
	"distant_light_full_enum_cells": 0,
}

#endregion


func setup(parent: Node3D) -> void:
	_parent_node = parent
	if _parent_node:
		_scenario = _parent_node.get_world_3d().scenario
	_create_material()
	_create_quad_mesh()
	_is_setup = true
	Log.info("streaming", "DistantLightManager: initialized (paged, max %d instances)" % MAX_INSTANCES)


## Queue/scavenge the streamed light ring. Work is performed incrementally from
## update(), so this is cheap to call on camera-cell changes.
func scan_cells_around(center_cell: Vector2i, radius_cells: int) -> void:
	if not _is_setup or not _streaming_enabled:
		return
	radius_cells = maxi(0, radius_cells)
	if center_cell == _center_cell and radius_cells == _radius_cells:
		return

	var old_center := _center_cell
	var old_radius := _radius_cells
	_center_cell = center_cell
	_radius_cells = radius_cells

	var delta := Vector2i(absi(center_cell.x - old_center.x), absi(center_cell.y - old_center.y))
	var use_differential := old_center != Vector2i(999999, 999999) and old_radius == radius_cells and delta.x <= 2 and delta.y <= 2

	if use_differential:
		_update_ring_differential(old_center, center_cell, radius_cells)
	else:
		_update_ring_full(center_cell, radius_cells)


## Process pending scans, rebuild dirty pages, and update the shader uniforms.
func update(camera_pos: Vector3, sun_elevation_rad: float, deadline_usec: int = 0) -> void:
	if not _is_setup or not _streaming_enabled:
		return

	if _deadline_exhausted(deadline_usec):
		return
	_process_full_ring_enum(deadline_usec)
	if _deadline_exhausted(deadline_usec):
		return
	_process_pending_scans(deadline_usec)
	if _deadline_exhausted(deadline_usec):
		return
	_process_dirty_page_rebuilds(deadline_usec)

	if sun_elevation_rad <= NIGHT_THRESHOLD:
		_night_factor = 1.0
	elif sun_elevation_rad >= DUSK_THRESHOLD:
		_night_factor = 0.0
	else:
		_night_factor = 1.0 - (sun_elevation_rad - NIGHT_THRESHOLD) / (DUSK_THRESHOLD - NIGHT_THRESHOLD)

	if _material:
		_material.set_shader_parameter("camera_position", camera_pos)
		_material.set_shader_parameter("night_factor", _night_factor)


func clear() -> void:
	_clear_streamed_data()
	_full_ring_active = false
	_center_cell = Vector2i(999999, 999999)
	_radius_cells = 0
	_refresh_stats()


func set_enabled(enabled: bool) -> void:
	_streaming_enabled = enabled
	if enabled:
		if not _is_setup and _parent_node:
			setup(_parent_node)
		for page: LightPage in _pages.values():
			if page.instance_rid.is_valid():
				RenderingServer.instance_set_visible(page.instance_rid, true)
	else:
		clear()
		cleanup()


func set_visible(visible: bool) -> void:
	set_enabled(visible)


func set_world_object_source(source: RefCounted) -> void:
	_world_object_source = source


func set_coordinate_mapper(mapper: RefCounted) -> void:
	_coordinate_mapper = mapper


func cleanup() -> void:
	for page_key: Vector2i in _pages.keys():
		_free_page(page_key)
	_pages.clear()
	_material = null
	_quad_mesh = null
	_is_setup = false
	_scenario = RID()


func get_stats() -> Dictionary:
	var s := _stats.duplicate()
	s["distant_light_count"] = _lights.size()
	s["distant_light_loaded_cells"] = _loaded_cells.size()
	s["distant_light_pending_cells"] = _pending_cells.size()
	s["distant_light_page_count"] = _pages.size()
	s["distant_light_dirty_pages"] = _dirty_pages.size()
	s["distant_light_enabled"] = _streaming_enabled and _is_setup
	s["distant_light_full_ring_active"] = _full_ring_active
	return s


#region Ring updates

func _update_ring_full(center_cell: Vector2i, radius_cells: int) -> void:
	_clear_streamed_data()
	_full_ring_active = true
	_full_ring_center = center_cell
	_full_ring_radius = radius_cells
	_full_ring_dx = -radius_cells
	_full_ring_dy = -radius_cells


func _process_full_ring_enum(deadline_usec: int = 0) -> void:
	if not _full_ring_active:
		_stats["distant_light_full_enum_us"] = 0
		_stats["distant_light_full_enum_cells"] = 0
		return

	var start_usec := Time.get_ticks_usec()
	var visited := 0
	var queued := 0
	var radius_meters := _cell_radius_to_distance(_full_ring_radius)
	var radius_sq := radius_meters * radius_meters

	while _full_ring_dy <= _full_ring_radius and visited < FULL_RING_ENUM_CELLS_MAX_PER_FRAME:
		var now_usec := Time.get_ticks_usec()
		if _deadline_exhausted(deadline_usec, now_usec):
			break
		if visited > 0 and now_usec - start_usec >= FULL_RING_ENUM_BUDGET_USEC:
			break
		var grid := Vector2i(_full_ring_center.x + _full_ring_dx, _full_ring_center.y + _full_ring_dy)
		if _cell_distance_squared(_full_ring_center, grid) <= radius_sq:
			if grid not in _loaded_cells and not _pending_cell_set.has(grid):
				_pending_cells.append(grid)
				_pending_cell_set[grid] = true
				_loaded_cells[grid] = true
				queued += 1

		visited += 1
		_full_ring_dx += 1
		if _full_ring_dx > _full_ring_radius:
			_full_ring_dx = -_full_ring_radius
			_full_ring_dy += 1

	if _full_ring_dy > _full_ring_radius:
		_full_ring_active = false

	_stats["distant_light_full_enum_us"] = Time.get_ticks_usec() - start_usec
	_stats["distant_light_full_enum_cells"] = visited
	if queued > 0:
		_refresh_stats()


func _clear_streamed_data() -> void:
	for page_key: Vector2i in _pages.keys():
		_free_page(page_key)
	_lights.clear()
	_cell_index.clear()
	_loaded_cells.clear()
	_pending_cells.clear()
	_pending_cell_set.clear()
	_dirty_pages.clear()
	_dirty_page_set.clear()
	_next_id = 0
	_refresh_stats()


func _update_ring_differential(old_center: Vector2i, new_center: Vector2i, radius_cells: int) -> void:
	var radius_meters := _cell_radius_to_distance(radius_cells)
	var radius_sq := radius_meters * radius_meters
	var move := new_center - old_center
	var load: Array[Vector2i] = []
	var unload: Array[Vector2i] = []

	if move.x != 0:
		var sx := signi(move.x)
		for step: int in range(1, absi(move.x) + 1):
			var lead_x := new_center.x + radius_cells * sx - (step - 1) * sx
			var trail_x := old_center.x - radius_cells * sx + (step - 1) * sx
			for cy: int in range(-radius_cells, radius_cells + 1):
				var lead := Vector2i(lead_x, new_center.y + cy)
				if _cell_distance_squared(new_center, lead) <= radius_sq:
					if lead not in _loaded_cells and not _pending_cell_set.has(lead):
						load.append(lead)
						_loaded_cells[lead] = true
				var trail := Vector2i(trail_x, old_center.y + cy)
				if _cell_distance_squared(old_center, trail) <= radius_sq and trail in _loaded_cells:
					unload.append(trail)

	if move.y != 0:
		var sy := signi(move.y)
		for step: int in range(1, absi(move.y) + 1):
			var lead_y := new_center.y + radius_cells * sy - (step - 1) * sy
			var trail_y := old_center.y - radius_cells * sy + (step - 1) * sy
			for cx: int in range(-radius_cells, radius_cells + 1):
				var lead := Vector2i(new_center.x + cx, lead_y)
				if _cell_distance_squared(new_center, lead) <= radius_sq:
					if lead not in _loaded_cells and not _pending_cell_set.has(lead):
						load.append(lead)
						_loaded_cells[lead] = true
				var trail := Vector2i(old_center.x + cx, trail_y)
				if _cell_distance_squared(old_center, trail) <= radius_sq and trail in _loaded_cells:
					unload.append(trail)

	if not unload.is_empty():
		_unload_cells(unload)
	_queue_cells(load)


func _queue_cells(cells: Array[Vector2i]) -> void:
	for cell: Vector2i in cells:
		if _pending_cell_set.has(cell):
			continue
		_pending_cells.append(cell)
		_pending_cell_set[cell] = true
	_stats["distant_light_pending_cells"] = _pending_cells.size()

#endregion


#region Scanning and lifetime

func _process_pending_scans(deadline_usec: int = 0) -> void:
	if _pending_cells.is_empty() or _lights.size() >= MAX_INSTANCES:
		_stats["distant_light_scan_us"] = 0
		_stats["distant_light_cells_scanned"] = 0
		return

	var start_usec := Time.get_ticks_usec()
	var scanned := 0
	while not _pending_cells.is_empty() and scanned < SCAN_CELLS_MAX_PER_FRAME:
		var now_usec := Time.get_ticks_usec()
		if _deadline_exhausted(deadline_usec, now_usec):
			break
		if scanned > 0 and now_usec - start_usec >= SCAN_BUDGET_USEC:
			break
		var grid: Vector2i = _pending_cells.pop_back()
		_pending_cell_set.erase(grid)
		if grid not in _loaded_cells:
			continue
		_scan_cell(grid, deadline_usec)
		scanned += 1
		if _lights.size() >= MAX_INSTANCES:
			break

	_stats["distant_light_scan_us"] = Time.get_ticks_usec() - start_usec
	_stats["distant_light_cells_scanned"] = scanned
	_refresh_stats()


func _scan_cell(grid: Vector2i, deadline_usec: int = 0) -> void:
	if _world_object_source == null:
		return

	var records: Array = _world_object_source.get_objects_in_cell(grid, WorldObjectRecordScript.CAP_DISTANT_LIGHT)
	for record: RefCounted in records:
		if _deadline_exhausted(deadline_usec):
			return
		if _lights.size() >= MAX_INSTANCES:
			return

		if record.light_radius <= 0.0:
			continue

		var data := LightData.new()
		data.id = _next_id
		data.cell_grid = grid
		data.position = record.transform.origin
		data.color = record.light_color
		data.radius = record.light_radius
		data.light_animation = record.light_animation
		data.is_fire = record.light_is_fire
		data.page_key = _page_key_for_position(data.position)
		_next_id += 1

		_lights[data.id] = data
		if grid not in _cell_index:
			_cell_index[grid] = []
		(_cell_index[grid] as Array).append(data.id)

		var page := _get_or_create_page(data.page_key)
		page.light_ids.append(data.id)
		_mark_page_dirty(data.page_key)


func _unload_cells(cells: Array[Vector2i]) -> void:
	var dirty: Dictionary[Vector2i, bool] = {}
	for grid: Vector2i in cells:
		_loaded_cells.erase(grid)
		_pending_cell_set.erase(grid)
		if grid not in _cell_index:
			continue
		for id: int in _cell_index[grid]:
			var data: LightData = _lights.get(id)
			if data != null:
				dirty[data.page_key] = true
				_lights.erase(id)
		_cell_index.erase(grid)

	for page_key: Vector2i in dirty.keys():
		_mark_page_dirty(page_key)
	_refresh_stats()

#endregion


#region Page rendering

func _create_material() -> void:
	_material = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = _get_shader_code()
	_material.shader = shader
	_material.set_shader_parameter("camera_position", Vector3.ZERO)
	_material.set_shader_parameter("night_factor", 0.0)
	_material.set_shader_parameter("base_size", BASE_SPRITE_SIZE)
	_material.set_shader_parameter("min_screen_factor", MIN_SCREEN_FACTOR)
	_material.set_shader_parameter("min_distance", MIN_DISTANCE)
	_material.set_shader_parameter("max_distance", MAX_DISTANCE)
	_material.set_shader_parameter("fade_margin", FADE_MARGIN)


func _create_quad_mesh() -> void:
	_quad_mesh = QuadMesh.new()
	_quad_mesh.size = Vector2(1.0, 1.0)
	_quad_mesh.orientation = PlaneMesh.FACE_Z
	_quad_mesh.material = _material


func _get_or_create_page(page_key: Vector2i) -> LightPage:
	if page_key in _pages:
		return _pages[page_key]

	var page := LightPage.new()
	page.key = page_key
	page.center = _page_center_for_key(page_key)
	page.multimesh = MultiMesh.new()
	page.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	page.multimesh.use_colors = true
	page.multimesh.use_custom_data = true
	page.multimesh.mesh = _quad_mesh

	page.instance_rid = RenderingServer.instance_create()
	RenderingServer.instance_set_base(page.instance_rid, page.multimesh.get_rid())
	if _scenario.is_valid():
		RenderingServer.instance_set_scenario(page.instance_rid, _scenario)
	RenderingServer.instance_set_transform(page.instance_rid, Transform3D(Basis.IDENTITY, page.center))
	RenderingServer.instance_set_layer_mask(page.instance_rid, 1)
	RenderingServer.instance_geometry_set_cast_shadows_setting(
		page.instance_rid,
		RenderingServer.SHADOW_CASTING_SETTING_OFF
	)
	RenderingServer.instance_geometry_set_visibility_range(
		page.instance_rid,
		0.0,
		MAX_DISTANCE + _page_visibility_extra_margin(),
		0.0,
		500.0,
		RenderingServer.VISIBILITY_RANGE_FADE_DISABLED
	)
	RenderingServer.instance_set_visible(page.instance_rid, true)

	_pages[page_key] = page
	_stats["distant_light_page_count"] = _pages.size()
	return page


func _free_page(page_key: Vector2i) -> void:
	if page_key not in _pages:
		return
	var page: LightPage = _pages[page_key]
	if page.instance_rid.is_valid():
		RenderingServer.free_rid(page.instance_rid)
		page.instance_rid = RID()
	if page.multimesh:
		page.multimesh.instance_count = 0
		page.multimesh.mesh = null
	_pages.erase(page_key)
	_dirty_pages.erase(page_key)
	_dirty_page_set.erase(page_key)


func _mark_page_dirty(page_key: Vector2i) -> void:
	if _dirty_page_set.has(page_key):
		return
	_dirty_pages.append(page_key)
	_dirty_page_set[page_key] = true
	_stats["distant_light_dirty_pages"] = _dirty_pages.size()


func _process_dirty_page_rebuilds(deadline_usec: int = 0) -> void:
	if _dirty_pages.is_empty():
		_stats["distant_light_pages_rebuilt"] = 0
		_stats["distant_light_rebuild_us"] = 0
		return

	var start_usec := Time.get_ticks_usec()
	var rebuilt := 0
	while not _dirty_pages.is_empty() and rebuilt < PAGE_REBUILD_MAX_PER_FRAME:
		var now_usec := Time.get_ticks_usec()
		if _deadline_exhausted(deadline_usec, now_usec):
			break
		if rebuilt > 0 and now_usec - start_usec >= PAGE_REBUILD_BUDGET_USEC:
			break
		var page_key: Vector2i = _dirty_pages.pop_back()
		_dirty_page_set.erase(page_key)
		var page: LightPage = _pages.get(page_key)
		if deadline_usec > 0 and page != null and page.light_ids.size() > 128:
			_mark_page_dirty(page_key)
			break
		_rebuild_page(page_key)
		rebuilt += 1

	var elapsed := Time.get_ticks_usec() - start_usec
	_stats["distant_light_pages_rebuilt"] = rebuilt
	_stats["distant_light_rebuild_us"] = elapsed
	_stats["distant_light_rebuild_max_us"] = maxi(int(_stats.get("distant_light_rebuild_max_us", 0)), elapsed)
	_refresh_stats()


func _deadline_exhausted(deadline_usec: int, now_usec: int = 0) -> bool:
	if deadline_usec <= 0:
		return false
	if now_usec <= 0:
		now_usec = Time.get_ticks_usec()
	return now_usec >= deadline_usec


func _rebuild_page(page_key: Vector2i) -> void:
	if page_key not in _pages:
		return
	var page: LightPage = _pages[page_key]
	var live_ids: Array[int] = []
	for id: int in page.light_ids:
		if id in _lights:
			live_ids.append(id)

	if live_ids.is_empty():
		_free_page(page_key)
		return
	page.light_ids = live_ids

	page.multimesh.instance_count = live_ids.size()
	page.multimesh.visible_instance_count = live_ids.size()

	var stride := 20 # 12 transform floats + 4 color floats + 4 custom-data floats.
	var buffer := PackedFloat32Array()
	buffer.resize(live_ids.size() * stride)
	var aabb_min := Vector3.ZERO
	var aabb_max := Vector3.ZERO
	var has_aabb := false
	for i: int in range(live_ids.size()):
		var data: LightData = _lights[live_ids[i]]
		var size_scale := clampf(data.radius / 3.0, 0.5, 4.0)
		var local_pos := data.position - page.center
		var is_fire := 1.0 if data.is_fire else 0.0
		var has_flicker := 1.0 if data.light_animation != WorldObjectRecordScript.LightAnimation.NONE else 0.0
		var phase_offset := fmod(float(data.id) * 0.618033988749, 1.0)

		var offset := i * stride
		buffer[offset + 0] = size_scale
		buffer[offset + 1] = 0.0
		buffer[offset + 2] = 0.0
		buffer[offset + 3] = local_pos.x
		buffer[offset + 4] = 0.0
		buffer[offset + 5] = size_scale
		buffer[offset + 6] = 0.0
		buffer[offset + 7] = local_pos.y
		buffer[offset + 8] = 0.0
		buffer[offset + 9] = 0.0
		buffer[offset + 10] = size_scale
		buffer[offset + 11] = local_pos.z
		buffer[offset + 12] = data.color.r
		buffer[offset + 13] = data.color.g
		buffer[offset + 14] = data.color.b
		buffer[offset + 15] = data.color.a
		buffer[offset + 16] = is_fire
		buffer[offset + 17] = has_flicker
		buffer[offset + 18] = phase_offset
		buffer[offset + 19] = 0.0

		var half := maxf(BASE_SPRITE_SIZE, data.radius) * 2.0 + PAGE_AABB_MARGIN
		var imp_min := local_pos - Vector3(half, half, half)
		var imp_max := local_pos + Vector3(half, half, half)
		if not has_aabb:
			aabb_min = imp_min
			aabb_max = imp_max
			has_aabb = true
		else:
			aabb_min = Vector3(minf(aabb_min.x, imp_min.x), minf(aabb_min.y, imp_min.y), minf(aabb_min.z, imp_min.z))
			aabb_max = Vector3(maxf(aabb_max.x, imp_max.x), maxf(aabb_max.y, imp_max.y), maxf(aabb_max.z, imp_max.z))

	page.multimesh.set_buffer(buffer)
	if has_aabb:
		var aabb := AABB(aabb_min, aabb_max - aabb_min)
		page.multimesh.custom_aabb = aabb
		if page.instance_rid.is_valid():
			RenderingServer.instance_set_custom_aabb(page.instance_rid, aabb)


func _page_key_for_position(position: Vector3) -> Vector2i:
	var cell := _world_to_cell(position)
	return Vector2i(
		floori(float(cell.x) / float(LIGHT_PAGE_SIZE_CELLS)),
		floori(float(cell.y) / float(LIGHT_PAGE_SIZE_CELLS))
	)


func _page_center_for_key(page_key: Vector2i) -> Vector3:
	var origin_x := page_key.x * LIGHT_PAGE_SIZE_CELLS
	var origin_y := page_key.y * LIGHT_PAGE_SIZE_CELLS
	if _coordinate_mapper != null and _coordinate_mapper.has_method("chunk_center_world"):
		var center_value: Variant = _coordinate_mapper.call("chunk_center_world", Vector2i(origin_x, origin_y), 2)
		if center_value is Vector2:
			var center_2d := center_value as Vector2
			return Vector3(center_2d.x, 0.0, center_2d.y)
	var cell_size := _cell_size_meters()
	var center_x := (float(origin_x) + float(LIGHT_PAGE_SIZE_CELLS) * 0.5) * cell_size
	var center_z := -(float(origin_y) + float(LIGHT_PAGE_SIZE_CELLS) * 0.5) * cell_size
	return Vector3(center_x, 0.0, center_z)


func _world_to_cell(position: Vector3) -> Vector2i:
	if _coordinate_mapper != null and _coordinate_mapper.has_method("world_to_cell"):
		var mapped: Variant = _coordinate_mapper.call("world_to_cell", position)
		if mapped is Vector2i:
			return mapped
	return DU.world_to_cell(position)


func _cell_distance_squared(cell_a: Vector2i, cell_b: Vector2i) -> float:
	if _coordinate_mapper != null and _coordinate_mapper.has_method("cell_distance_squared"):
		return float(_coordinate_mapper.call("cell_distance_squared", cell_a, cell_b))
	return DU.cell_distance_squared(cell_a, cell_b)


func _cell_size_meters() -> float:
	if _coordinate_mapper != null and _coordinate_mapper.has_method("get_cell_size_meters"):
		return float(_coordinate_mapper.call("get_cell_size_meters"))
	return DU.CELL_SIZE_METERS


func _cell_radius_to_distance(radius_cells: int) -> float:
	if _coordinate_mapper != null and _coordinate_mapper.has_method("cell_radius_to_distance"):
		return float(_coordinate_mapper.call("cell_radius_to_distance", radius_cells))
	return float(radius_cells) * DU.CELL_SIZE_METERS


func _page_visibility_extra_margin() -> float:
	return float(LIGHT_PAGE_SIZE_CELLS) * _cell_size_meters() * 1.5

#endregion


func _refresh_stats() -> void:
	_stats["distant_light_count"] = _lights.size()
	_stats["distant_light_loaded_cells"] = _loaded_cells.size()
	_stats["distant_light_pending_cells"] = _pending_cells.size()
	_stats["distant_light_page_count"] = _pages.size()
	_stats["distant_light_dirty_pages"] = _dirty_pages.size()


func _get_shader_code() -> String:
	return """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec3 camera_position;
uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
uniform float base_size = 3.0;
uniform float min_screen_factor = 0.005;
uniform float min_distance = 150.0;
uniform float max_distance = 5000.0;
uniform float fade_margin = 30.0;

varying flat vec3 v_emission;

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float dist = length(world_pos - camera_position);
	vec3 light_col = COLOR.rgb;

	float is_fire = INSTANCE_CUSTOM.r;
	float has_flicker = INSTANCE_CUSTOM.g;
	float phase_offset = INSTANCE_CUSTOM.b;

	float flicker = 1.0;
	if (has_flicker > 0.5) {
		float t = TIME * 2.0 + phase_offset * 6.283;
		flicker = 0.7 + 0.3 * (sin(t) * sin(t * 2.7 + 1.3) * 0.5 + 0.5);
	}

	float visibility = night_factor;
	if (is_fire > 0.5) {
		visibility = max(visibility, 0.3);
	}

	float final_size = max(base_size, dist * min_screen_factor);
	float near_fade = smoothstep(min_distance - fade_margin, min_distance + fade_margin, dist);
	float far_fade = 1.0 - smoothstep(max_distance - 500.0, max_distance, dist);
	float brightness = visibility * flicker * near_fade * far_fade;
	v_emission = light_col * brightness * 3.0;

	vec3 to_cam = camera_position - world_pos;
	to_cam.y = 0.0;
	vec3 forward = normalize(to_cam);
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), forward));
	vec3 up = vec3(0.0, 1.0, 0.0);

	mat4 billboard_model = mat4(
		vec4(right * final_size, 0.0),
		vec4(up * final_size, 0.0),
		vec4(forward, 0.0),
		vec4(world_pos, 1.0)
	);
	MODELVIEW_MATRIX = VIEW_MATRIX * billboard_model;
}

void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	float r = dot(uv, uv);
	float glow = exp(-r * 4.0);
	ALBEDO = v_emission * glow;
}
"""

#endregion
