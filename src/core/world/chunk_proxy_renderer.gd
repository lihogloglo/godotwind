## ChunkProxyRenderer — CHUNK tier runtime consumer (Phase 2 revised,
## 2026-07-05). Streams OFFLINE-baked merged chunk proxies
## (chunk_proxy_bake_runner.tscn) for the 400-1200m ring and publishes each
## as ONE RenderingServer instance with an engine visibility band.
##
## Design contract (plan: docs/plans/distant_rendering_recovery_2026_07.md):
## - Loads are SINGLE-FLIGHT threaded requests: chunk files share external
##   material dependencies (the baker's deduped library), and Godot ≤4.6's
##   loader races on contested sub-resources (godotengine/godot#111202).
##   One in-flight chunk at a time removes intra-tier contention; the model
##   loader's own single flight touches a disjoint file set.
## - No Node3D per chunk, no physics, no processing — server-direct pattern.
## - Shadows OFF: sun shadow maps never reach the ring anyway.
## - Fade margins mirror cell_static_bucket (begin/end padded by the chunk's
##   horizontal radius — visibility_range measures instance-origin distance).
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
	RenderingServer.instance_geometry_set_visibility_range(
		rid,
		maxf(0.0, DU.CHUNK_START - radius),
		DU.CHUNK_END + radius,
		DU.FADE_MARGIN_RENDER_FAR,
		DU.FADE_MARGIN_RENDER_FAR,
		SC.MID_VISIBILITY_FADE_MODE)
	RenderingServer.instance_geometry_set_cast_shadows_setting(
		rid, RenderingServer.SHADOW_CASTING_SETTING_OFF)
	RenderingServer.instance_geometry_set_lod_bias(rid, SC.DEFAULT_LOD_BIAS)
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
	_stats_evicted += 1


func _clear_all() -> void:
	for key: String in _active.keys():
		_evict(key)
	_queue.clear()
	_pending_key = ""
	_pending_path = ""
