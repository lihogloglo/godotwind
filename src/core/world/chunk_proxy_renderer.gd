## ChunkProxyRenderer — CHUNK tier runtime consumer (Phase 2 revised;
## boundary rework 2026-07-06). Streams OFFLINE-baked PER-CELL merged proxies
## (chunk_proxy_bake_runner.tscn) and publishes each as ONE RenderingServer
## instance.
##
## MID↔CHUNK boundary contract (content selection, NOT range fencing):
## a cell's proxy is visible exactly while that cell has NO published MID
## static buckets. The streaming manager drives `set_cell_covered` from
## StaticObjectRenderer's per-cell bucket presence events, and the covered
## buckets' own far band is released (see set_paged_coverage) so the
## streaming-ring unload is the swap point. Range-fencing a merged proxy
## against per-object MID culling had an irreducible ±radius error —
## z-fight shimmer leaning one way, cell-sized holes the other (both
## user-verified 2026-07-05). Canonical pattern: UE World Partition HLOD
## (one HLOD per streaming cell, swapped on cell load/unload) + distance
## object paging (active-grid content exclusion, chunks re-keyed on grid
## change).
##
## Consequences:
## - Near visibility band DELETED (begin = 0): proxies double as instant
##   stand-ins for cells the streamer hasn't published yet (kills the
##   fast-flight void). Far band stays engine-driven at CHUNK_END.
## - Proxies for covered cells stay resident but hidden — the unload swap
##   must be same-frame, never behind a single-flight load.
##
## Other design notes (unchanged from Phase 2):
## - Loads are SINGLE-FLIGHT threaded requests: chunk files share external
##   material dependencies (the baker's deduped library), and Godot ≤4.6's
##   loader races on contested sub-resources (godotengine/godot#111202).
## - No Node3D per chunk, no physics, no processing — server-direct pattern.
## - Shadows OFF: sun shadow maps never reach the ring anyway.
class_name ChunkProxyRenderer
extends Node3D

const DU := preload("res://src/core/world/distance_utils.gd")
const SC := preload("res://src/core/world/streaming_config.gd")

const EXTERIOR_RENDER_LAYER_MASK := 1

## Camera movement (meters) that triggers a wanted-set rescan.
const RESCAN_DISTANCE: float = 32.0
## Streaming margin beyond the render band, plus unload hysteresis.
const PRELOAD_MARGIN: float = 100.0
const EVICT_HYSTERESIS: float = 100.0

## index key "cx,cy" -> {origin: Vector3, center: Vector3, radius: float, path: String}
var _index: Dictionary = {}
## key -> {rid: RID, mesh: ArrayMesh}
var _active: Dictionary = {}
## Wanted-but-not-loaded keys, nearest first.
var _queue: Array[String] = []
var _pending_key: String = ""
var _pending_path: String = ""
var _enabled: bool = false
var _last_scan_pos: Vector3 = Vector3(1e20, 0, 0)
var _stats_published: int = 0
var _stats_evicted: int = 0
## Cover-side crossfade duration. When MID buckets start publishing for a
## cell, its proxy alpha-fades out instead of vanishing: static prepare
## publishes ~1 bucket/frame, so a cell fills over ~0.3-0.5 s, and an
## instant hide exposes that drain as a whole-cell pop (user-reported
## 2026-07-06). The ease-in curve (t²) keeps the proxy near-opaque while
## the cell is still sparse, then drops fast. This is alpha through the
## transparent pipeline (GeometryInstance3D `transparency` semantics,
## verified against the 4.6 docs) — acceptable because only publish-edge
## cells fade, a handful concurrently during traversal. The uncover
## direction stays instant: the proxy shows the same frame the buckets
## start hiding (complete-for-complete swap).
const COVER_FADE_DURATION_S: float = 0.6

## Cells whose MID static buckets are currently published — their proxies
## are hidden (content selection; see class header). Keyed like _index.
var _covered: Dictionary = {}
## key -> elapsed fade seconds for proxies fading out after being covered.
var _cover_fades: Dictionary = {}
## Mirrors StaticObjectRenderer._globally_visible: the Phase 0 ablation
## contract — `toggle static_visuals` hides ALL static output, proxies
## included.
var _globally_visible: bool = true


func is_enabled() -> bool:
	return _enabled and not _index.is_empty()


func set_enabled(enabled: bool) -> void:
	if _enabled == enabled:
		return
	_enabled = enabled
	if not enabled:
		_clear_all()
	else:
		_last_scan_pos = Vector3(1e20, 0, 0)


## Content selection: hide/show one cell's proxy in lockstep with its MID
## static-bucket presence. Coverage state persists across enable/disable and
## applies to proxies that finish loading later (they publish hidden).
## Cover of a currently-visible proxy starts the crossfade; uncover cancels
## any fade and restores the proxy instantly.
func set_cell_covered(cell: Vector2i, covered: bool) -> void:
	var key := "%d,%d" % [cell.x, cell.y]
	if covered:
		_covered[key] = true
		var entry: Dictionary = _active.get(key, {})
		if not entry.is_empty() and _globally_visible:
			_cover_fades[key] = 0.0
			return
		_cover_fades.erase(key)
	else:
		_covered.erase(key)
		_cover_fades.erase(key)
		_reset_instance_transparency(key)
	_apply_instance_visibility(key)


## Phase 0 ablation contract: `toggle static_visuals` hides ALL static
## renderer output — buckets, direct instances, AND visual proxies.
func set_globally_visible(visible: bool) -> void:
	if _globally_visible == visible:
		return
	_globally_visible = visible
	if not visible:
		for key: String in _cover_fades:
			_reset_instance_transparency(key)
		_cover_fades.clear()
	for key: String in _active:
		_apply_instance_visibility(key)


func _proxy_should_be_visible(key: String) -> bool:
	return _globally_visible and key not in _covered


func _apply_instance_visibility(key: String) -> void:
	var entry: Dictionary = _active.get(key, {})
	if entry.is_empty():
		return
	var rid: RID = entry["rid"]
	if rid.is_valid():
		RenderingServer.instance_set_visible(rid, _proxy_should_be_visible(key))


func _reset_instance_transparency(key: String) -> void:
	var entry: Dictionary = _active.get(key, {})
	if entry.is_empty():
		return
	var rid: RID = entry["rid"]
	if rid.is_valid():
		RenderingServer.instance_geometry_set_transparency(rid, 0.0)


## Advance cover-side crossfades (called once per frame from update()).
func _advance_cover_fades() -> void:
	if _cover_fades.is_empty():
		return
	var delta := get_process_delta_time()
	var finished: Array[String] = []
	for key: String in _cover_fades:
		var entry: Dictionary = _active.get(key, {})
		if entry.is_empty() or not (entry["rid"] as RID).is_valid():
			finished.append(key)
			continue
		var rid: RID = entry["rid"]
		var age := float(_cover_fades[key]) + delta
		if age >= COVER_FADE_DURATION_S:
			RenderingServer.instance_set_visible(rid, false)
			RenderingServer.instance_geometry_set_transparency(rid, 0.0)
			finished.append(key)
			continue
		var t := age / COVER_FADE_DURATION_S
		RenderingServer.instance_geometry_set_transparency(rid, t * t)
		_cover_fades[key] = age
	for key: String in finished:
		_cover_fades.erase(key)


## Resolve the baked chunk index from the shared cache. Returns the number
## of chunks found (0 = no bake on disk; tier stays dormant).
func initialize_from_cache() -> int:
	_index.clear()
	var settings: Node = get_node_or_null("/root/SettingsManager")
	if settings == null or not settings.has_method("get_cache_base_path"):
		return 0
	var chunks_dir: String = str(settings.call("get_cache_base_path")).path_join("chunks")
	var index_path := chunks_dir.path_join("chunk_index.json")
	if not FileAccess.file_exists(index_path):
		return 0
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(index_path))
	if parsed == null or not (parsed is Dictionary):
		Log.warn("streaming", "Chunk tier: unreadable index at %s" % index_path)
		return 0
	var data := parsed as Dictionary
	var chunk_cells := int(data.get("chunk_cells", 2))
	if chunk_cells != 1:
		# Legacy 2×2 bake: the per-cell MID↔CHUNK content selection cannot
		# toggle sub-chunk regions, and range fencing is the failure mode this
		# rework removed. Refuse rather than resurrect the broken seam.
		Log.warn("streaming", "Chunk tier: legacy bake (chunk_cells=%d) at %s — re-bake per-cell via chunk_proxy_bake_runner.tscn; tier stays dormant" % [chunk_cells, index_path])
		return 0
	var chunks: Dictionary = data.get("chunks", {})
	for key_variant: Variant in chunks.keys():
		var key := str(key_variant)
		var parts := key.split(",")
		if parts.size() != 2:
			continue
		var chunk_key := Vector2i(int(parts[0]), int(parts[1]))
		var entry: Dictionary = chunks[key]
		var origin := DU.cell_to_world_origin(Vector2i(chunk_key.x * chunk_cells, chunk_key.y * chunk_cells))
		var aabb_pos: Array = entry.get("aabb_pos", [0.0, 0.0, 0.0])
		var aabb_size: Array = entry.get("aabb_size", [0.0, 0.0, 0.0])
		var local_center := Vector3(
			float(aabb_pos[0]) + float(aabb_size[0]) * 0.5,
			float(aabb_pos[1]) + float(aabb_size[1]) * 0.5,
			float(aabb_pos[2]) + float(aabb_size[2]) * 0.5)
		var radius := Vector2(float(aabb_size[0]), float(aabb_size[2])).length() * 0.5
		_index[key] = {
			"origin": origin,
			"center": origin + local_center,
			"radius": radius,
			"path": chunks_dir.path_join("chunk_%d_%d.res" % [chunk_key.x, chunk_key.y]),
		}
	Log.info("streaming", "Chunk tier: %d baked chunks indexed (%s)" % [_index.size(), chunks_dir])
	return _index.size()


## Per-frame drive. Cheap: polls the single in-flight load, rescans the
## wanted set only after RESCAN_DISTANCE of camera travel.
func update(camera_pos: Vector3, deadline_usec: int) -> void:
	if not is_enabled():
		return

	_advance_cover_fades()
	_poll_pending_load()

	if camera_pos.distance_to(_last_scan_pos) >= RESCAN_DISTANCE:
		_last_scan_pos = camera_pos
		_rescan(camera_pos)

	if _pending_key.is_empty() and not _queue.is_empty() \
			and (deadline_usec <= 0 or Time.get_ticks_usec() < deadline_usec):
		_kick_next_load()


func get_stats() -> Dictionary:
	return {
		"chunk_tier_indexed": _index.size(),
		"chunk_tier_active": _active.size(),
		"chunk_tier_covered": _covered.size(),
		"chunk_tier_queue": _queue.size(),
		"chunk_tier_published_total": _stats_published,
		"chunk_tier_evicted_total": _stats_evicted,
	}


func _exit_tree() -> void:
	_clear_all()


func _rescan(camera_pos: Vector3) -> void:
	var load_range := DU.CHUNK_END + PRELOAD_MARGIN
	var evict_range := load_range + EVICT_HYSTERESIS
	var wanted: Array[String] = []
	var distances: Dictionary = {}

	for key: String in _index:
		var entry: Dictionary = _index[key]
		var dist: float = camera_pos.distance_to(entry["center"]) - float(entry["radius"])
		if key in _active:
			if dist > evict_range:
				_evict(key)
			continue
		if dist <= load_range:
			wanted.append(key)
			distances[key] = dist

	wanted.sort_custom(func(a: String, b: String) -> bool:
		return float(distances[a]) < float(distances[b]))
	_queue = wanted


func _kick_next_load() -> void:
	while not _queue.is_empty():
		var key: String = _queue.pop_front()
		if key in _active:
			continue
		var entry: Dictionary = _index[key]
		var path: String = entry["path"]
		var err := ResourceLoader.load_threaded_request(path, "ArrayMesh")
		if err != OK:
			Log.warn("streaming", "Chunk tier: threaded request failed for %s (%s)" % [path, error_string(err)])
			continue
		_pending_key = key
		_pending_path = path
		return


func _poll_pending_load() -> void:
	if _pending_key.is_empty():
		return
	var status := ResourceLoader.load_threaded_get_status(_pending_path)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return
	var key := _pending_key
	var path := _pending_path
	_pending_key = ""
	_pending_path = ""
	if status != ResourceLoader.THREAD_LOAD_LOADED:
		Log.warn("streaming", "Chunk tier: load failed for %s (status %d)" % [path, status])
		return
	var mesh := ResourceLoader.load_threaded_get(path) as ArrayMesh
	if mesh == null:
		Log.warn("streaming", "Chunk tier: %s did not contain an ArrayMesh" % path)
		return
	_publish(key, mesh)


func _publish(key: String, mesh: ArrayMesh) -> void:
	if key in _active or key not in _index:
		return
	var entry: Dictionary = _index[key]
	var radius := float(entry["radius"])
	var rid := RenderingServer.instance_create()
	RenderingServer.instance_set_base(rid, mesh.get_rid())
	RenderingServer.instance_set_scenario(rid, get_world_3d().scenario)
	RenderingServer.instance_set_transform(rid, Transform3D(Basis.IDENTITY, entry["origin"]))
	RenderingServer.instance_set_layer_mask(rid, EXTERIOR_RENDER_LAYER_MASK)
	# NO near band (begin = 0): the near-side handoff is content selection —
	# the proxy hides while this cell's MID buckets are published
	# (set_cell_covered) — so a distance fence here would only re-open the
	# gap for cells the streamer hasn't published yet. Both range-fence
	# variants failed with an irreducible ±radius error (z-fight shimmer /
	# cell-sized holes, user-verified 2026-07-05). Far band stays
	# engine-driven: the FAR impostor tier takes over past CHUNK_END.
	RenderingServer.instance_geometry_set_visibility_range(
		rid,
		0.0,
		DU.CHUNK_END + radius,
		0.0,
		DU.FADE_MARGIN_RENDER_FAR,
		SC.MID_VISIBILITY_FADE_MODE)
	RenderingServer.instance_geometry_set_cast_shadows_setting(
		rid, RenderingServer.SHADOW_CASTING_SETTING_OFF)
	RenderingServer.instance_geometry_set_lod_bias(rid, SC.DEFAULT_LOD_BIAS)
	if not _proxy_should_be_visible(key):
		RenderingServer.instance_set_visible(rid, false)
	_active[key] = {"rid": rid, "mesh": mesh}
	_stats_published += 1


func _evict(key: String) -> void:
	var entry: Dictionary = _active.get(key, {})
	if entry.is_empty():
		return
	var rid: RID = entry["rid"]
	if rid.is_valid():
		RenderingServer.free_rid(rid)
	_active.erase(key)
	_cover_fades.erase(key)
	_stats_evicted += 1


func _clear_all() -> void:
	for key: String in _active.keys():
		_evict(key)
	_queue.clear()
	_cover_fades.clear()
	_pending_key = ""
	_pending_path = ""
