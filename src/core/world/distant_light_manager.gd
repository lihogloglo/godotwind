## DistantLightManager - lights beyond the NEAR tier, two layers:
##
## 1. REAL point lights (150-600 m): server-direct RS omni lights for the most
##    significant nearby-distant lights. Godot Forward+ is a clustered-forward
##    renderer (clustered / "volume tiled forward shading") — a few hundred
##    unshadowed omnis are cheap. Budgeted
##    nearest-first, faded in over the NEAR_END boundary to crossfade with the
##    NEAR tier's OmniLight3D distance fade (both are zero at exactly 150 m).
## 2. Billboard MultiMesh glow sprites (~55 m - FAR_END): the corona/halo layer,
##    one draw call per page, carries the "town glitter" out to view distance.
##    Persists (shrunken) down to the NEAR 60 m spawn gate so towns don't dim
##    on approach; crossfades with the spawned lantern's emissive + bloom.
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
const LightTuning := preload("res://src/core/world/light_tuning.gd")

#region Configuration

const MIN_DISTANCE: float = DU.NEAR_END
const MAX_DISTANCE: float = DU.FAR_END
const FADE_MARGIN: float = 30.0
const BASE_SPRITE_SIZE: float = 3.0
const MIN_SCREEN_FACTOR: float = 0.005
## Billboard corona near handoff (2026-07-06 Balmora fix). The corona used to
## hard-fade at 120-180 m while the near lantern look (spawned mesh emissive +
## bloom) only starts at NEAR's 60 m lazy-spawn gate — the 60-120 m band had
## NEITHER, so towns visibly "turned off" on approach. The corona now persists
## down to the handoff, shrinking as it nears (see shader size_taper) so it
## reads as the lantern's halo rather than a floating ball. Zero at 55 m =
## REAL_LIGHT_NEAR_MIN_SMALL_M, 5 m inside the 60 m spawn gate — the swap is
## covered on both ends.
const BILLBOARD_NEAR_FADE_CENTER_M: float = 70.0
const BILLBOARD_NEAR_FADE_HALF_M: float = 15.0
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

## Real-light layer (60-350 m). The far cap is a HARD GPU constraint, not
## taste: Forward+ cluster cells are depth-sliced logarithmically, so at
## 400 m+ every light in a vista lands in the same few huge clusters and each
## distant pixel shades all of them — measured +30 ms GPU on an RTX 4060
## laptop with the original 600 m / 160-light config (2026-07-06). Beyond
## 350 m per-surface lighting is near sub-pixel and the billboard glow
## carries the visual alone.
const REAL_LIGHT_MAX_DISTANCE_M: float = 350.0
## Only lights with a meaningful radius get a real light at distance. data.radius
## is now real metres (units fix 2026-07-07: MW_LIGHT_SCALE was 70/64 ≈ MW-units,
## so this gate compared metres against ~50-500 and every light wrongly passed).
## 1 m ≈ 70 MW units — keeps lanterns/torches, drops only the tiniest candles, so
## more of a town's lights illuminate on approach (Solution 2: lower the gate).
const REAL_LIGHT_MIN_RADIUS_M: float = 1.0
## Hard cap on simultaneous real distant lights (nearest-first). Raised 64→128
## after the units fix (2026-07-07): correctly-scaled ranges (a few metres, not
## the old ~100-500 m monsters) cost far less per light in the Forward+ clusters,
## so a dense town can afford more overlapping pools. Nearest-first ordering
## fills these with the closest (cheapest, best-distributed) lights first.
const REAL_LIGHT_BUDGET: int = 128
## Crossfade half-width at the big-light handoff and the far cutoff.
## Matches FADE_MARGIN used by the billboard shader's near fade.
const REAL_LIGHT_FADE_M: float = 30.0
## Near handoff is per-light. Big lights (>= REAL_LIGHT_BIG_RADIUS_M) are
## ALWAYS spawned by the NEAR tier when their cell loads (reference_instantiator
## LIGHT_ALWAYS_SPAWN_RADIUS_MW = 700 MW = 10 m), so they hand off at NEAR_END
## with a crossfade. Small lights only spawn in NEAR within its 60 m lazy-spawn
## gate (LIGHT_PROXIMITY_THRESHOLD_M) — the distant layer must carry them all
## the way down to that boundary or they blink out across the 60-150 m band
## (user-reported pop, 2026-07-06). The 55 m floor overlaps NEAR's spawn by
## 5 m so the handoff is a swap, not a dark blink.
const REAL_LIGHT_BIG_RADIUS_M: float = 10.0
const REAL_LIGHT_NEAR_MIN_SMALL_M: float = 55.0
## Re-evaluation cadence. Selection + energy ramps update at this interval,
## not per frame.
const REAL_LIGHT_UPDATE_INTERVAL_S: float = 0.5
## RS light creation is spread across ticks — a cold start near a town would
## otherwise create the full budget in one 0.5s tick (measured 5-13 ms spikes
## in the streaming autopsy on first boot, 2026-07-06).
const REAL_LIGHT_MAX_CREATES_PER_TICK: int = 24
## Selection is purely a function of camera position, so re-running the
## candidate gather + nearest-N sort while the camera is stationary is wasted
## work. Skip re-selection until the camera has moved this far since the last
## one. Zeroes out the steady-state cost (standing/looking around) and caps the
## moving-case cadence. 4 m gives ~6 energy re-evals across the 30 m crossfade
## bands — smooth enough for a subtle distant glow (2026-07-06 perf fix).
const REAL_LIGHT_RESELECT_MOVE_M: float = 4.0

## Aggregate town-glow layer (light LOD — the direct analog of mesh HLOD/CHUNK).
## One dim, large-range proxy omni per LIT PAGE (4×4 cells) fakes a whole
## settlement's combined illumination at distance: it crossfades IN as the
## individual real lights fade OUT (~320-400 m), restoring the "warm town from
## afar" SURFACE glow that the old units bug produced by accident. Few proxies
## (only lit pages, budgeted) so the Forward+ cluster cost stays bounded —
## unlike extending 128 individual lights out to 1.2 km, which is the +30 ms
## cluster trap the REAL_LIGHT_MAX_DISTANCE_M cap exists to avoid.
const AGGREGATE_ENABLED: bool = true
## Fade band: fully individual below _FADE_M, fully aggregate above the live
## LightTuning.aggregate_near_full_m. _FADE_M sits ~70 m under
## REAL_LIGHT_MAX_DISTANCE_M so the crossfade with the individual lights' own
## far-fade (320-350 m) overlaps rather than gapping.
const AGGREGATE_NEAR_FADE_M: float = 250.0
## Far cutoff — matches the CHUNK/impostor horizon; beyond this the page is
## usually outside the light stream ring anyway.
const AGGREGATE_FAR_FULL_M: float = 1000.0
const AGGREGATE_FAR_CUTOFF_M: float = 1200.0
## Proxy range = light spread within the page + LightTuning.aggregate_range_margin_m
## (min floor), so a compact town gets a tight glow and a spread page a wider one.
const AGGREGATE_RANGE_MIN_M: float = 120.0
## Count factor: brightness scales with the page's light count (clamped) so a
## dense town glows more than a lone roadside lantern. Base energy is the live
## LightTuning.aggregate_energy_base.
const AGGREGATE_COUNT_NORM: float = 8.0
const AGGREGATE_COUNT_FACTOR_MIN: float = 0.3
const AGGREGATE_COUNT_FACTOR_MAX: float = 1.6
## Hard cap on simultaneous proxies (nearest-first). Lit pages are sparse, so
## this rarely binds — it's a safety rail against a light-dense worldspace.
const AGGREGATE_BUDGET: int = 48

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
	## Aggregate town-glow proxy params, recomputed on every page rebuild.
	var agg_centroid: Vector3 = Vector3.ZERO
	var agg_color: Color = Color.BLACK
	var agg_spread: float = 0.0
	var agg_range: float = 0.0
	var agg_count: int = 0
	var agg_dirty: bool = true
	var agg_light: RealLight = null


## Server-direct RS omni light + its scenario instance for one distant light.
class RealLight:
	var light_rid: RID
	var instance_rid: RID
	var base_energy: float = 0.0
	var current_energy: float = -1.0

	func free_rids() -> void:
		if instance_rid.is_valid():
			RenderingServer.free_rid(instance_rid)
			instance_rid = RID()
		if light_rid.is_valid():
			RenderingServer.free_rid(light_rid)
			light_rid = RID()

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

var _real_lights: Dictionary[int, RealLight] = {}
## Lights whose radius passes REAL_LIGHT_MIN_RADIUS_M — maintained at scan /
## unload time so the 0.5s selection tick iterates a few hundred entries, not
## the full 4096-light billboard set.
var _real_light_candidates: Dictionary[int, bool] = {}
var _real_light_next_update_s: float = 0.0
## Camera position at the last selection pass. Sentinel-far so the first tick
## always runs. Drives the movement gate in _update_real_lights.
var _real_light_last_select_pos: Vector3 = Vector3(1e9, 1e9, 1e9)
## True while the per-tick creation cap left selected lights uncreated. Keeps
## the movement gate open so the backlog drains even if the camera is static
## after arriving somewhere dense (otherwise only the first cap-worth spawn).
var _real_light_creates_pending: bool = false
## Last camera position seen by update(). Lets refresh_tunables re-run the
## selection + aggregate passes synchronously on a slider change (instant),
## instead of waiting on the deadline-gated 0.5 s streaming tick.
var _last_camera_pos: Vector3 = Vector3.ZERO
var _has_camera_pos: bool = false

var _center_cell: Vector2i = Vector2i(999999, 999999)
var _radius_cells: int = 0
var _night_factor: float = 0.0
var _full_ring_active: bool = false
var _full_ring_center: Vector2i = Vector2i.ZERO
var _full_ring_radius: int = 0
var _full_ring_dx: int = 0
var _full_ring_dy: int = 0

var _stats: Dictionary = {
	"distant_real_light_count": 0,
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
	"distant_light_aggregates": 0,
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

	_last_camera_pos = camera_pos
	_has_camera_pos = true

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

	var now_s := Time.get_ticks_msec() / 1000.0
	if now_s >= _real_light_next_update_s and not _deadline_exhausted(deadline_usec):
		_real_light_next_update_s = now_s + REAL_LIGHT_UPDATE_INTERVAL_S
		_update_real_lights(camera_pos)
		if AGGREGATE_ENABLED:
			_update_page_aggregates(camera_pos)


func clear() -> void:
	_clear_streamed_data()
	_full_ring_active = false
	_center_cell = Vector2i(999999, 999999)
	_radius_cells = 0
	_refresh_stats()


## Re-apply live LightTuning values to already-created distant lights (called by
## the Lighting UI on a slider change). Re-applies RANGE in place (no free/recreate
## — that thrashes when a slider fires 60×/s during a drag) and forces the next
## 0.5 s tick to re-push energy; aggregate energy/reach are read live already, only
## the range MARGIN needs recomputing from the cached spread.
func refresh_tunables() -> void:
	var mult := LightTuning.radius_multiplier
	for id: int in _real_lights:
		var data: LightData = _lights.get(id)
		var real: RealLight = _real_lights[id]
		if data != null and real.light_rid.is_valid():
			RenderingServer.light_set_param(real.light_rid, RenderingServer.LIGHT_PARAM_RANGE, data.radius * mult)
			real.current_energy = -1.0  # force energy re-push on the next selection tick
	_real_light_last_select_pos = Vector3(1e9, 1e9, 1e9)  # open the movement gate so energy recomputes
	for page: LightPage in _pages.values():
		if page.agg_count > 0:
			page.agg_range = maxf(page.agg_spread + LightTuning.aggregate_range_margin_m, AGGREGATE_RANGE_MIN_M)
			page.agg_dirty = true
	# Drive the selection + aggregate passes NOW (synchronous, cached camera pos)
	# so distant energy + town-glow update the instant a slider moves, instead of
	# waiting on the deadline-gated 0.5 s streaming tick (which may be starved).
	if _has_camera_pos:
		_update_real_lights(_last_camera_pos)
		if AGGREGATE_ENABLED:
			_update_page_aggregates(_last_camera_pos)


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
	_free_all_real_lights()
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
	_free_all_real_lights()
	_real_light_candidates.clear()
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
		if data.radius >= REAL_LIGHT_MIN_RADIUS_M:
			_real_light_candidates[data.id] = true
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
			_real_light_candidates.erase(id)
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
	_material.set_shader_parameter("min_distance", BILLBOARD_NEAR_FADE_CENTER_M)
	_material.set_shader_parameter("max_distance", MAX_DISTANCE)
	_material.set_shader_parameter("fade_margin", BILLBOARD_NEAR_FADE_HALF_M)


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
	_free_page_aggregate(page)
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
	var agg_pos_sum := Vector3.ZERO
	var agg_col_sum := Color(0.0, 0.0, 0.0, 0.0)
	for i: int in range(live_ids.size()):
		var data: LightData = _lights[live_ids[i]]
		agg_pos_sum += data.position
		agg_col_sum += data.color
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

	# Aggregate town-glow proxy params (light LOD). Centroid + mean colour of the
	# page's lights; range = their spread + margin. Cached so _update_page_aggregates
	# only reads per tick. agg_dirty forces the live proxy to re-apply these.
	var count := live_ids.size()
	page.agg_count = count
	page.agg_centroid = agg_pos_sum / float(count)
	page.agg_color = agg_col_sum / float(count)
	var spread := 0.0
	for id: int in live_ids:
		spread = maxf(spread, _lights[id].position.distance_to(page.agg_centroid))
	page.agg_spread = spread
	page.agg_range = maxf(spread + LightTuning.aggregate_range_margin_m, AGGREGATE_RANGE_MIN_M)
	page.agg_dirty = true


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


#region Real distant lights (150-600 m)

## Re-select which distant lights deserve a real RS omni light and drive their
## crossfade energies. Runs every REAL_LIGHT_UPDATE_INTERVAL_S, not per frame.
##
## Selection: lights with radius >= REAL_LIGHT_MIN_RADIUS_M inside their
## per-light band, nearest-first up to REAL_LIGHT_BUDGET. Big lights crossfade
## in over NEAR_END..NEAR_END+fade (the NEAR tier's distance fade hits zero at
## NEAR_END, so the handoff is continuous); small lights hold full energy down
## to the NEAR lazy-spawn boundary. Both fade out over the last band before
## the far cutoff.
func _update_real_lights(camera_pos: Vector3) -> void:
	if not _scenario.is_valid():
		return

	# Movement gate: the nearest-N selection and its crossfade energies only
	# change as the camera moves. Standing still (or a tiny look-around jitter)
	# re-runs the exact same result — skip it. This zeroes the steady-state cost
	# that the streaming autopsy pinned at 13-17 ms spikes (2026-07-06). Stays
	# open while a creation backlog is draining so all selected lights spawn even
	# if the camera stops the instant it arrives.
	if not _real_light_creates_pending \
			and camera_pos.distance_squared_to(_real_light_last_select_pos) < REAL_LIGHT_RESELECT_MOVE_M * REAL_LIGHT_RESELECT_MOVE_M:
		return
	_real_light_last_select_pos = camera_pos

	var select_max_sq := REAL_LIGHT_MAX_DISTANCE_M * REAL_LIGHT_MAX_DISTANCE_M
	var small_min_sq := REAL_LIGHT_NEAR_MIN_SMALL_M * REAL_LIGHT_NEAR_MIN_SMALL_M
	var big_min := MIN_DISTANCE - REAL_LIGHT_FADE_M
	var big_min_sq := big_min * big_min

	# Gather candidates as packed keys so the nearest-N cull uses the engine's
	# native (C++) sort instead of a per-comparison GDScript lambda — the lambda
	# sort was the 13-17 ms main-thread spike in dense towns. Key = integer
	# distance² in bits 40+ (max 350² = 122500 → 17 bits) OR'd with the light id
	# in the low 40 bits. Sorting ascending orders by distance first, id as a
	# stable tie-break. Sub-metre distance ties resolving by id is irrelevant for
	# picking nearest distant coronas.
	var packed: PackedInt64Array = PackedInt64Array()
	var stale_ids: Array[int] = []
	for id: int in _real_light_candidates.keys():
		var data: LightData = _lights.get(id)
		if data == null:
			stale_ids.append(id)
			continue
		var d_sq := camera_pos.distance_squared_to(data.position)
		var min_sq := big_min_sq if data.radius >= REAL_LIGHT_BIG_RADIUS_M else small_min_sq
		if d_sq < min_sq or d_sq > select_max_sq:
			continue
		packed.append((int(d_sq) << 40) | (id & 0xFFFFFFFFFF))
	for id: int in stale_ids:
		_real_light_candidates.erase(id)

	if packed.size() > REAL_LIGHT_BUDGET:
		packed.sort()
		packed.resize(REAL_LIGHT_BUDGET)

	# Diff: free real lights that fell out of selection (or whose data unloaded).
	# Exact distance is recomputed per surviving light below (≤ budget count),
	# so the integer-truncated key distance never feeds the crossfade math.
	var selected: Dictionary[int, float] = {}
	for key: int in packed:
		var id := key & 0xFFFFFFFFFF
		var data: LightData = _lights.get(id)
		if data != null:
			selected[id] = camera_pos.distance_to(data.position)
	for id: int in _real_lights.keys():
		if id not in selected or id not in _lights:
			_real_lights[id].free_rids()
			_real_lights.erase(id)

	# Create missing (capped per tick) + drive crossfade energy.
	var creates_left := REAL_LIGHT_MAX_CREATES_PER_TICK
	var creates_pending := false
	for id: int in selected.keys():
		var data: LightData = _lights.get(id)
		if data == null:
			continue
		var real: RealLight = _real_lights.get(id)
		if real == null:
			if creates_left <= 0:
				creates_pending = true
				continue
			creates_left -= 1
			real = _create_real_light(data)
			_real_lights[id] = real
		var dist: float = selected[id]
		var near_ramp := 1.0
		if data.radius >= REAL_LIGHT_BIG_RADIUS_M:
			near_ramp = smoothstep(MIN_DISTANCE, MIN_DISTANCE + REAL_LIGHT_FADE_M, dist)
		var far_ramp := 1.0 - smoothstep(REAL_LIGHT_MAX_DISTANCE_M - REAL_LIGHT_FADE_M, REAL_LIGHT_MAX_DISTANCE_M, dist)
		var energy := real.base_energy * LightTuning.distant_energy_multiplier * near_ramp * far_ramp
		if not is_equal_approx(energy, real.current_energy):
			real.current_energy = energy
			RenderingServer.light_set_param(real.light_rid, RenderingServer.LIGHT_PARAM_ENERGY, energy)

	_real_light_creates_pending = creates_pending
	_stats["distant_real_light_count"] = _real_lights.size()


func _create_real_light(data: LightData) -> RealLight:
	var real := RealLight.new()
	real.base_energy = 1.2 if data.is_fire else 0.8

	real.light_rid = RenderingServer.omni_light_create()
	# Global light-radius multiplier ("light bounds multiplier"): scales the
	# real-world pool so lanterns overlap into a warm town glow. Same knob the NEAR
	# tier applies, so a lamp's near and distant pools match across the handoff.
	RenderingServer.light_set_param(real.light_rid, RenderingServer.LIGHT_PARAM_RANGE, data.radius * LightTuning.radius_multiplier)
	RenderingServer.light_set_param(real.light_rid, RenderingServer.LIGHT_PARAM_ATTENUATION, 1.0)
	RenderingServer.light_set_color(real.light_rid, data.color)
	RenderingServer.light_set_shadow(real.light_rid, false)
	# Distant eye-candy lights stay out of SDFGI — GI updates for 160 far-away
	# omnis are wasted work at these distances.
	RenderingServer.light_set_bake_mode(real.light_rid, RenderingServer.LIGHT_BAKE_DISABLED)

	real.instance_rid = RenderingServer.instance_create()
	RenderingServer.instance_set_base(real.instance_rid, real.light_rid)
	RenderingServer.instance_set_scenario(real.instance_rid, _scenario)
	RenderingServer.instance_set_transform(real.instance_rid, Transform3D(Basis.IDENTITY, data.position))
	return real


func _free_all_real_lights() -> void:
	for real: RealLight in _real_lights.values():
		real.free_rids()
	_real_lights.clear()
	_stats["distant_real_light_count"] = 0

#endregion


#region Aggregate town-glow (light LOD)

## Drive the per-page proxy omnis. Same 0.5 s cadence as the real lights. Lit
## pages are sparse, so iterating them is cheap; each gets one proxy whose energy
## ramps so it crossfades IN as the individual real lights fade OUT near 320-400 m,
## and fades OUT again toward the 1.2 km horizon. Budgeted nearest-first.
func _update_page_aggregates(camera_pos: Vector3) -> void:
	if not _scenario.is_valid():
		return

	var in_band: Array[Vector2i] = []
	for page_key: Vector2i in _pages.keys():
		var page: LightPage = _pages[page_key]
		if page.agg_count <= 0:
			continue
		var dist := camera_pos.distance_to(page.agg_centroid)
		if dist < AGGREGATE_NEAR_FADE_M or dist >= AGGREGATE_FAR_CUTOFF_M:
			_free_page_aggregate(page)
			continue
		in_band.append(page_key)

	if in_band.size() > AGGREGATE_BUDGET:
		in_band.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return camera_pos.distance_squared_to(_pages[a].agg_centroid) \
				< camera_pos.distance_squared_to(_pages[b].agg_centroid))
		for i: int in range(AGGREGATE_BUDGET, in_band.size()):
			_free_page_aggregate(_pages[in_band[i]])
		in_band.resize(AGGREGATE_BUDGET)

	var active := 0
	for page_key: Vector2i in in_band:
		var page: LightPage = _pages[page_key]
		var dist := camera_pos.distance_to(page.agg_centroid)
		var near_full := maxf(AGGREGATE_NEAR_FADE_M + 10.0, LightTuning.aggregate_near_full_m)
		var near_ramp := smoothstep(AGGREGATE_NEAR_FADE_M, near_full, dist)
		var far_ramp := 1.0 - smoothstep(AGGREGATE_FAR_FULL_M, AGGREGATE_FAR_CUTOFF_M, dist)
		var count_factor := clampf(float(page.agg_count) / AGGREGATE_COUNT_NORM,
			AGGREGATE_COUNT_FACTOR_MIN, AGGREGATE_COUNT_FACTOR_MAX)
		var energy := LightTuning.aggregate_energy_base * count_factor * near_ramp * far_ramp
		if energy <= 0.0001:
			_free_page_aggregate(page)
			continue
		if page.agg_light == null:
			_create_aggregate_light(page)
		elif page.agg_dirty:
			_apply_aggregate_params(page)
		if not is_equal_approx(energy, page.agg_light.current_energy):
			page.agg_light.current_energy = energy
			RenderingServer.light_set_param(page.agg_light.light_rid, RenderingServer.LIGHT_PARAM_ENERGY, energy)
		active += 1
	_stats["distant_light_aggregates"] = active


func _create_aggregate_light(page: LightPage) -> void:
	var proxy := RealLight.new()
	proxy.light_rid = RenderingServer.omni_light_create()
	RenderingServer.light_set_shadow(proxy.light_rid, false)
	RenderingServer.light_set_bake_mode(proxy.light_rid, RenderingServer.LIGHT_BAKE_DISABLED)
	RenderingServer.light_set_param(proxy.light_rid, RenderingServer.LIGHT_PARAM_ATTENUATION, 1.0)
	proxy.instance_rid = RenderingServer.instance_create()
	RenderingServer.instance_set_base(proxy.instance_rid, proxy.light_rid)
	RenderingServer.instance_set_scenario(proxy.instance_rid, _scenario)
	page.agg_light = proxy
	_apply_aggregate_params(page)


## Push the cached centroid / colour / range onto the proxy's RIDs.
func _apply_aggregate_params(page: LightPage) -> void:
	if page.agg_light == null:
		return
	RenderingServer.light_set_color(page.agg_light.light_rid, page.agg_color)
	RenderingServer.light_set_param(page.agg_light.light_rid, RenderingServer.LIGHT_PARAM_RANGE, page.agg_range)
	RenderingServer.instance_set_transform(page.agg_light.instance_rid, Transform3D(Basis.IDENTITY, page.agg_centroid))
	page.agg_dirty = false


func _free_page_aggregate(page: LightPage) -> void:
	if page.agg_light != null:
		page.agg_light.free_rids()
		page.agg_light = null

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

	// Corona glow is a NIGHT-ONLY phenomenon (2026-07-06). MW placed lights
	// have no glow halos; they stay lit 24/7 but wash out in daylight.
	// The old `is_fire -> 0.3` floor kept our halos glowing in full sun, which
	// read as "lights on during the day". Drive visibility purely by
	// night_factor so halos fade out as the sun rises and return at dusk.
	float visibility = night_factor;

	// Near fade → ZERO (2026-07-07). The old 0.45 floor dated from when the
	// corona was the only source of ambient town warmth; with the units-fixed
	// real-light layer (55-350 m) + aggregated town-glow omnis (320 m-1.2 km)
	// carrying real illumination, a floored corona reads as a naked floating
	// ball up close (user report). Fade to zero across the 55-85 m handoff —
	// the NEAR lantern mesh (60 m spawn) + its real light take over.
	float size_taper = mix(0.5, 1.0, smoothstep(min_distance - fade_margin, 200.0, dist));
	float final_size = max(base_size * size_taper, dist * min_screen_factor);
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
