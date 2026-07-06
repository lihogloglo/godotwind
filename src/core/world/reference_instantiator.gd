## ReferenceInstantiator - Converts ESM cell references into Node3D objects
##
## Handles instantiation of different reference types:
## - Static objects (furniture, architecture, clutter)
## - Lights (model + OmniLight3D)
## - Actors (NPCs and creatures)
## - Flora/rocks via StaticObjectRenderer for performance
##
## Part of Phase 2 refactoring: Separating instantiation logic from cell management
## Extracted from CellManager to enforce Single Responsibility Principle
class_name ReferenceInstantiator
extends RefCounted

# Dependencies
const CS := preload("res://src/core/coordinate_system.gd")
const DU := preload("res://src/core/world/distance_utils.gd")
const CharacterFactoryV2 := preload("res://src/core/animation/character_factory_v2.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
const MeshVisibilityUtils := preload("res://src/core/world/mesh_visibility_utils.gd")
const WorldObjectRecordScript := preload("res://src/core/world/world_object_record.gd")


# Plan 2026-04-28 step 2 — shared interaction-area geometry per door
# prototype. The 10.7 ms door instantiate cost is dominated by the AABB
# subtree walk + BoxShape3D allocation, both deterministic per prototype.
# Cached and reused on every subsequent door of the same prototype. Plan:
# docs/plans/near_streaming_2026_04_28_interactive_spawn.md step 2.
const InteractionShapeCacheScript := preload("res://src/core/world/interaction_shape_cache.gd")

# Injected dependencies (set by CellManager)
var model_loader: RefCounted = null  # ModelLoader
var object_pool: RefCounted = null  # ObjectPool (optional)
var static_renderer: Node = null  # StaticObjectRenderer (optional)
var character_factory: CharacterFactoryV2 = null  # CharacterFactoryV2 for NPCs/creatures with new animation system
var _world_object_source: RefCounted = null
var _world_object_spawn_adapter: RefCounted = null

# Impostor candidates for determining significant objects
var _impostor_candidates: RefCounted = null

# Output data for non-Node3D instances (Phase 2)
var last_static_data: Dictionary = {}

func set_world_object_source(source: RefCounted) -> void:
	_world_object_source = source


func set_world_object_spawn_adapter(adapter: RefCounted) -> void:
	_world_object_spawn_adapter = adapter


func set_impostor_candidates(candidates: RefCounted) -> void:
	_impostor_candidates = candidates


func _source_is_carryable(type_name: String, base_record: Variant) -> bool:
	if _world_object_spawn_adapter != null and _world_object_spawn_adapter.has_method("is_source_record_carryable"):
		return bool(_world_object_spawn_adapter.call("is_source_record_carryable", type_name, base_record))
	return false


func _postprocess_source_model_object(
	instance: Node3D,
	ref: Variant,
	base_record: Variant,
	type_name: String,
	cell_grid: Vector2i,
	record_id: String,
	source_key: String = "",
) -> void:
	if _world_object_spawn_adapter == null:
		return
	if not _world_object_spawn_adapter.has_method("postprocess_source_model_object"):
		return
	_world_object_spawn_adapter.call(
		"postprocess_source_model_object",
		instance,
		ref,
		base_record,
		type_name,
		cell_grid,
		record_id,
		self,
		source_key,
	)


func _postprocess_source_actor(
	character: Node3D,
	ref: Variant,
	actor_record: Variant,
	actor_type: String,
) -> Node3D:
	if _world_object_spawn_adapter == null:
		return character
	if not _world_object_spawn_adapter.has_method("postprocess_source_actor"):
		return character
	var processed: Node3D = _world_object_spawn_adapter.call(
		"postprocess_source_actor",
		character,
		ref,
		actor_record,
		actor_type,
		self,
	) as Node3D
	return processed if processed != null else character


func _resolve_source_reference_base_record(source_ref: Variant, record_type_out: Array, cached: bool = false) -> Variant:
	if _world_object_spawn_adapter == null:
		Log.error("streaming", "ReferenceInstantiator has no WorldObjectSpawnAdapter for source ref")
		return null
	if not _world_object_spawn_adapter.has_method("resolve_source_reference_base_record"):
		Log.error("streaming", "WorldObjectSpawnAdapter cannot resolve source ref")
		return null
	return _world_object_spawn_adapter.call("resolve_source_reference_base_record", source_ref, record_type_out, cached)


func _source_light_animation_for_record(light_record: Variant) -> int:
	if _world_object_spawn_adapter != null and _world_object_spawn_adapter.has_method("source_light_animation_for_record"):
		return int(_world_object_spawn_adapter.call("source_light_animation_for_record", light_record))
	return WorldObjectRecordScript.LightAnimation.NONE


## Plan 2026-04-28 step 2 — shared interaction-area geometry cache (one
## entry per door / activator prototype). Lazily allocated on first
## door / activator publish so test scenes that don't spawn interactives
## pay nothing.
##
## Typed as RefCounted because `InteractionShapeCacheScript` is preloaded
## without a class_name. Underlying type is `InteractionShapeCacheScript`.
var _interaction_shape_cache: RefCounted = null

# Configuration
var create_lights: bool = true
var load_lights: bool = true  # Skip ALL light ref instantiation (model + OmniLight3D). A/B benchmark gate.
var load_npcs: bool = true
var load_creatures: bool = true
var use_object_pool: bool = true
var use_static_renderer: bool = true
var debug_lod: bool = false

# I.7 — Callback invoked when a spawned DoorInteractable emits
# `door_activated`. Signature mirrors the signal:
#   (record_id: String, door_record: Variant, player: Node3D) -> void
# Set by CellManager (which receives it from world_explorer). If null,
# spawned DoorInteractables still emit the signal but nothing listens;
# that is the test-scene / headless-load default.
var door_activated_handler: Callable = Callable()

# NEAR-tier actor filtering — skip NPC/creature creation beyond this distance from camera
# 150m matches the NEAR tier boundary in distance_utils.gd
const ACTOR_PROXIMITY_THRESHOLD_M: float = 150.0
var max_actor_distance: float = ACTOR_PROXIMITY_THRESHOLD_M
var camera_position: Vector3 = Vector3.ZERO  # Updated by streaming manager each frame

# Transient per-call override: read by the static-renderer gate and
# actor-distance gate when set. CellManager._process_instantiation_queue sets
# this from entry.load_profile before dispatching an instantiator call, and
# clears it immediately after. Because the queue processor is main-thread and
# fully synchronous, there is no race — but this must NEVER be left set
# across function boundaries. Always save/clear symmetrically via the
# helpers below; do not assign _current_load_profile directly from outside.
# See CellManager.LoadProfile for the struct shape.
var _current_load_profile: Variant = null  # LoadProfile or null

# Debug counter for leaked-transient detection. _effective_* helpers track
# that we saw a non-null profile during a processing window; if the window
# closes with a residual that wasn't cleared, we assert. Only active in
# debug builds so production has zero overhead.
var _transient_set_depth: int = 0


## Set the transient profile — USE THIS instead of direct assignment so the
## debug book-keeping stays consistent. Call _clear_transient_profile() in a
## matched pair (structured as if wrapping a try/finally).
func _set_transient_profile(profile: Variant) -> void:
	# Detect a leaked transient from the previous call. If _current_load_profile
	# is non-null here it means the previous set didn't have a matching clear.
	assert(_current_load_profile == null,
		"LoadProfile transient leaked from previous call (depth=%d)" % _transient_set_depth)
	_current_load_profile = profile
	_transient_set_depth += 1


## Clear the transient profile. Must be called after every _set_transient_profile.
## Unconditional — call this even on error paths or early returns from the
## instantiator call it wraps.
func _clear_transient_profile() -> void:
	_current_load_profile = null
	_transient_set_depth -= 1


## Get the effective max_actor_distance for the current call, honoring any
## per-call override set via _current_load_profile.
# PHASE_A:MAIN_ONLY — reads _current_load_profile transient; dispatcher must
# snapshot this into entry state before enqueue if worker path ever needs it.
func _effective_max_actor_distance() -> float:
	if _current_load_profile != null:
		return _current_load_profile.max_actor_distance
	return max_actor_distance


## Get the effective use_static_renderer for the current call.
# PHASE_A:MAIN_ONLY — same reason as _effective_max_actor_distance.
func _effective_use_static_renderer() -> bool:
	if _current_load_profile != null:
		return _current_load_profile.use_static_renderer
	return use_static_renderer

# Scene tree reference (must be set by parent, e.g., CellManager)
var scene_tree: SceneTree = null

# Statistics
var stats: Dictionary = {
	"objects_instantiated": 0,
	"objects_failed": 0,
	"objects_from_pool": 0,
	"lights_created": 0,
	"npcs_loaded": 0,
	"creatures_loaded": 0,
	"static_renderer_instances": 0,
	"visual_proxies_created": 0,
	"significant_objects_registered": 0,  # Objects registered with per-object LOD
}

var _route_usage_stats: Dictionary = {
	"world_object_id_calls": 0,
	"world_object_record_calls": 0,
	"world_object_static_record_calls": 0,
	"world_object_node_record_calls": 0,
}

const SOURCE_LIGHT_RADIUS_SCALE: float = CS.SCALE_FACTOR

## Lazy-spawn distance for interactive refs (containers, doors, activators,
## carryables). Refs beyond this distance are deferred and re-queued on camera
## approach. OpenMW pattern: Node3D creation for 12-20 ms/ref interactives is
## skipped until gameplay can plausibly interact — eliminates 70-80% of the
## `inst:` overrun during cell-crossing bursts while preserving the invariant
## "containers appear before you can touch them." Keep this comfortably above
## actual interaction range but well below NEAR render end; a wider radius spends
## too many frames instantiating doors/containers the player cannot use.
const INTERACTIVE_PROXIMITY_THRESHOLD_M: float = 25.0

## Door visuals are source-key-backed proxies. The full DoorInteractable stays
## near-only, but architectural door silhouettes should not wait for gameplay.
const DOOR_VISUAL_PROXY_ENABLED: bool = true
const CONTAINER_VISUAL_PROXY_ENABLED: bool = true
const CONTAINER_VISUAL_PROXY_RANGE_M: float = DU.NEAR_END

## Win 4a (NEAR refactor 2026-04-25) — lazy-spawn distance for OmniLight3D refs.
##
## Lights are the dominant per-type cost post-Phase A (~3000-9000 µs/instance
## per session 14.2 measurement). Most MW lights have ~3-7m omni range that
## fades to nothing well within 60 m, so building a Node3D + OmniLight3D + model
## subtree for a light 100 m from the camera is wasted work — the light won't
## visibly contribute past ~120 m anyway (existing distance_fade_begin = 120m
## in `_instantiate_light`).
##
## Threshold wider than INTERACTIVE_PROXIMITY_THRESHOLD_M because
## lights cull at shadow distance, not interaction distance. Big lights
## (radius ≥ LIGHT_ALWAYS_SPAWN_RADIUS_MW) bypass the gate so braziers /
## templar lanterns / sconces always cast shadows even from far away.
const LIGHT_PROXIMITY_THRESHOLD_M: float = 60.0

## Win 4a — lights with MW radius >= this value spawn unconditionally,
## regardless of camera distance. 700 MW units ≈ 10m Godot range — matches
## "big light" intuition (templar braziers, large sconces). Smaller lights
## (candles, torches, small lanterns) get the lazy-spawn gate.
const LIGHT_ALWAYS_SPAWN_RADIUS_MW: float = 700.0

## Emission boost for light-source models (lighting roadmap: fire textures
## should emit strongly enough to trigger bloom). Data-driven: only surfaces
## whose NIF material already carries emission (emissive color / glow texture)
## qualify — wooden handles and metal cages stay unlit.
const LIGHT_MODEL_EMISSION_FIRE: float = 2.5
const LIGHT_MODEL_EMISSION_OTHER: float = 1.5

## Win 4b — MW light flag mask for animated lights (flicker / pulse). Lights
## with any of these flags need per-frame energy writes through the existing
## OmniLight3D Node3D path because LightAnimator (light_animator.gd) walks
## the scene tree for `OmniLight3D` instances with `light_animation` metadata. RS
## RIDs aren't visible to that walker, so server-direct + animation needs a
## separate per-RID animator (out of scope this pass — flag-gate to keep
## existing flicker working).
##
## Bits (from LightRecord flag constants):
##   FLAG_FLICKER       = 0x0008
##   FLAG_FLICKER_SLOW  = 0x0040
##   FLAG_PULSE         = 0x0080
##   FLAG_PULSE_SLOW    = 0x0100


## Win 4b — RefCounted holder for the RS RIDs of a server-direct light.
## Attached as metadata on the light's container Node3D; when the container
## is queue_freed (via cell_node teardown), the metadata's strong ref drops,
## the RefCounted destructs, and `_notification(NOTIFICATION_PREDELETE)`
## frees the RIDs. No signal connection, no per-cell registry — the existing
## scene-tree teardown drives the cleanup.
##
## Reference: server_direct_pattern.md §"Memory ownership model" — RIDs must
## be explicitly freed; using a RefCounted destructor wires the explicit free
## into Godot's existing scene-tree lifecycle without bespoke bookkeeping.
class LightRids:
	extends RefCounted
	var light_rid: RID = RID()
	var instance_rid: RID = RID()

	func _notification(what: int) -> void:
		if what != NOTIFICATION_PREDELETE:
			return
		# Free instance first — removes from rendering scenario before the
		# underlying light data is released. RS.free_rid is no-op on invalid
		# RIDs but the validity check keeps the diagnostic clean.
		if instance_rid.is_valid():
			RenderingServer.free_rid(instance_rid)
			instance_rid = RID()
		if light_rid.is_valid():
			RenderingServer.free_rid(light_rid)
			light_rid = RID()


class InstantiationResult:
	extends RefCounted
	var node: Node3D = null
	var type_name: String = ""
	var route: String = ""
	var model_load_us: int = 0
	var static_register_us: int = 0
	var static_add_us: int = 0
	var proximity_deferred: bool = false
	var static_data: Dictionary = {}

	func capture_from(instantiator: Variant, result_node: Node3D) -> void:
		node = result_node
		type_name = str(instantiator.last_type_name)
		route = str(instantiator.last_inst_route)
		model_load_us = int(instantiator.last_model_load_us)
		static_register_us = int(instantiator.last_static_register_us)
		static_add_us = int(instantiator.last_static_add_us)
		proximity_deferred = bool(instantiator.last_proximity_deferred)
		static_data = instantiator.last_static_data.duplicate()

## Set true when a source adapter spawn route skips a ref due to the lazy-spawn
## distance gate. Read by `cell_manager.process_async_instantiation` to route
## the ref into `_proximity_deferred` instead of treating it as failed.
var last_proximity_deferred: bool = false


## Instantiate a cell reference into a Node3D
## Returns null if the reference cannot be instantiated or uses StaticObjectRenderer
var _inst_call_count: int = 0
## Diagnostic — set to the type_name of the most recent spawn call. Read by
## `cell_manager.process_async_instantiation` for per-type timing breakdown.
## Scientific-approach instrumentation, not hypothesis.
var last_type_name: String = ""
## Route-level diagnostic for the most recent instantiate/publish call.
## Read by CellManager to split the broad `inst` phase into actionable buckets.
var last_inst_route: String = ""
var last_model_load_us: int = 0

var last_static_register_us: int = 0
var last_static_add_us: int = 0


func _reset_last_inst_diagnostics(route: String = "") -> void:
	last_inst_route = route
	last_model_load_us = 0
	last_static_register_us = 0
	last_static_add_us = 0
	last_static_data = {}


func instantiate_world_object(object_id: StringName, cell_grid: Vector2i = Vector2i.ZERO, cache_item_id: String = "") -> Node3D:
	_increment_route_usage_stat("world_object_id_calls")
	if _world_object_source == null or not _world_object_source.has_method("get_object_record"):
		_inst_call_count += 1
		last_proximity_deferred = false
		_reset_last_inst_diagnostics("world_object")
		Log.error("streaming", "ReferenceInstantiator has no WorldObjectSource record lookup for object '%s'" % str(object_id))
		last_inst_route = "skip"
		return null
	var record: RefCounted = _world_object_source.call("get_object_record", object_id) as RefCounted
	return instantiate_world_object_record(record, cell_grid, cache_item_id)


func instantiate_world_object_record(record: RefCounted, cell_grid: Vector2i = Vector2i.ZERO, cache_item_id: String = "") -> Node3D:
	_inst_call_count += 1
	_increment_route_usage_stat("world_object_record_calls")
	last_proximity_deferred = false
	_reset_last_inst_diagnostics("world_object")
	if record == null:
		last_type_name = "unknown"
		last_inst_route = "skip"
		return null
	if _world_object_spawn_adapter == null:
		Log.error("streaming", "ReferenceInstantiator has no WorldObjectSpawnAdapter for object '%s'" % str(record.get("object_id")))
		last_inst_route = "skip"
		return null
	return _world_object_spawn_adapter.call(
		"instantiate_world_object",
		record,
		self,
		cell_grid,
		cache_item_id,
	) as Node3D


func instantiate_world_object_record_result(record: RefCounted, cell_grid: Vector2i = Vector2i.ZERO, cache_item_id: String = "") -> InstantiationResult:
	var node := instantiate_world_object_record(record, cell_grid, cache_item_id)
	var result := InstantiationResult.new()
	result.capture_from(self, node)
	return result


func instantiate_static_world_object_record(record: RefCounted, cell_grid: Vector2i = Vector2i.ZERO) -> Node3D:
	_increment_route_usage_stat("world_object_static_record_calls")
	if record == null:
		last_type_name = "unknown"
		last_inst_route = "skip"
		return null
	var model_path := str(record.get("model_path"))
	var type_name := _record_source_type(record)
	last_type_name = type_name
	if model_path.is_empty():
		last_inst_route = "skip"
		return null
	if not _should_route_to_renderer(type_name, model_path, false, _effective_use_static_renderer()):
		return instantiate_node_world_object_record(record, cell_grid, str(record.get("cache_item_id")))

	var normalized := model_path.to_lower().replace("/", "\\")
	last_inst_route = "static_hot"
	if not static_renderer.call("has_type", normalized):
		last_inst_route = "static_cold"
		var load_start := Time.get_ticks_usec()
		var prototype: Node3D = model_loader.call("get_model", model_path)
		last_model_load_us = Time.get_ticks_usec() - load_start
		if prototype:
			var reg_start := Time.get_ticks_usec()
			static_renderer.call("register_from_prototype", normalized, prototype)
			last_static_register_us = Time.get_ticks_usec() - reg_start
		else:
			last_inst_route = "static_cold_fail"
			return null

	var transform := _record_transform(record)
	var mesh_type_stats: Dictionary = static_renderer.call("get_mesh_type_stats", normalized)
	var aabb: AABB = mesh_type_stats.get("aabb", AABB())
	var add_start := Time.get_ticks_usec()
	var instance_id: int = static_renderer.call("add_instance", normalized, transform, cell_grid)
	last_static_add_us = Time.get_ticks_usec() - add_start
	if instance_id >= 0:
		stats["static_renderer_instances"] += 1
		last_static_data = {
			"transform": transform,
			"aabb": aabb,
			"mesh_id": float(normalized.hash()),
			"lod_mask": 0,
		}
	return null


func instantiate_node_world_object_record(
	record: RefCounted,
	_cell_grid: Vector2i = Vector2i.ZERO,
	cache_item_id: String = "",
) -> Node3D:
	_increment_route_usage_stat("world_object_node_record_calls")
	if record == null:
		last_type_name = "unknown"
		last_inst_route = "skip"
		return null
	var model_path := str(record.get("model_path"))
	var type_name := _record_source_type(record)
	last_type_name = type_name
	if model_path.is_empty():
		last_inst_route = "skip"
		return null

	var record_id := str(record.get("record_id"))
	if record_id.is_empty():
		record_id = str(record.get("model_item_id"))
	var load_item_id := cache_item_id if not cache_item_id.is_empty() else str(record.get("cache_item_id"))
	if load_item_id.is_empty():
		load_item_id = record_id

	last_inst_route = "node_sync"
	var model_load_start := Time.get_ticks_usec()
	var instance: Node3D = model_loader.call("get_model", model_path, load_item_id)
	last_model_load_us = Time.get_ticks_usec() - model_load_start
	if not instance:
		last_inst_route = "placeholder"
		return _create_placeholder_for_record(record)

	var source_ref := str(record.get("source_ref_id"))
	instance.name = source_ref if not source_ref.is_empty() else str(record.get("object_id"))
	var ref_pos := _record_transform(record).origin
	if ref_pos.distance_squared_to(camera_position) < DU.NEAR_END * DU.NEAR_END:
		if not StreamingConfig.DEBUG_DISABLE_JOLT_ATTACH:
			_enable_collision_shapes_in_tree(instance)
	_hide_lod_nodes(instance)
	instance.transform = _record_transform(record)
	_apply_record_metadata(instance, record, model_path, type_name)
	stats["objects_instantiated"] += 1
	return instance


func set_source_spawn_diagnostics(
	type_name: String,
	route: String,
	proximity_deferred: bool = false
) -> void:
	last_type_name = type_name
	last_inst_route = route
	last_proximity_deferred = proximity_deferred


func is_source_static_renderer_effective() -> bool:
	return _effective_use_static_renderer()


func get_source_spawn_camera_position() -> Vector3:
	return camera_position


func should_source_load_lights() -> bool:
	return load_lights


func should_source_load_npcs() -> bool:
	return load_npcs


func should_source_load_creatures() -> bool:
	return load_creatures


func instantiate_source_light_record(record: RefCounted, light_record: Variant) -> Node3D:
	if record == null or light_record == null:
		return null
	var typed_light := light_record as LightRecord
	if typed_light == null:
		return null
	return _instantiate_light(record, typed_light)


func instantiate_source_actor_record(record: RefCounted, actor_record: Variant, actor_type: String) -> Node3D:
	if record == null or actor_record == null:
		return null
	return _instantiate_actor(record, actor_record, actor_type)


func apply_source_metadata(
	node: Node3D,
	ref: Variant,
	base_record: Variant,
	model_path: String,
	type_name: String = ""
) -> void:
	if node == null or ref == null:
		return
	_apply_metadata(node, ref, base_record, model_path, type_name)


func ensure_source_visual_proxy_for_record(
	record: RefCounted,
	type_name: String,
	cache_item_id: String = ""
) -> bool:
	if record == null:
		return false
	var source_key := _record_source_key(record, type_name)
	if source_key.is_empty():
		return false
	return _ensure_visual_proxy(
		source_key,
		_record_transform(record),
		str(record.get("model_path")),
		_record_cell_grid(record),
		type_name,
		cache_item_id,
		StringName(str(record.get("source_ref_id"))),
		_record_ref_num(record)
	)


func apply_source_visual_proxy_runtime_for_record(
	instance: Node3D,
	record: RefCounted,
	type_name: String
) -> void:
	if instance == null or record == null or not _uses_visual_proxy(type_name):
		return
	var source_key := _record_source_key(record, type_name)
	if source_key.is_empty():
		return
	instance.set_meta("source_key", source_key)
	instance.set_meta("cell_grid", _record_cell_grid(record))
	_suppress_visual_proxy(source_key, type_name)
	_wire_visual_proxy_restore_on_exit(instance, source_key)


func uses_source_visual_proxy(type_name: String) -> bool:
	return _uses_visual_proxy(type_name)


func attach_source_carryable_light_source(instance: Node3D, base_record: Variant) -> void:
	var light_record := base_record as LightRecord
	if instance == null or light_record == null:
		return
	_attach_carryable_light_source(instance, light_record)


func get_source_door_activated_handler() -> Callable:
	return door_activated_handler


func add_source_interactable_layer_recursive(node: Node) -> void:
	if node == null:
		return
	_add_interactable_layer_recursive(node)


func generate_source_interaction_area(root: Node3D, model_path: String = "") -> Area3D:
	if root == null:
		return null
	if not model_path.is_empty():
		return _generate_interaction_area_cached(root, model_path)
	return _generate_interaction_area(root)


func mark_source_visual_proxy_dirty(source_key: String, reason: String) -> void:
	if source_key.is_empty() or static_renderer == null or not static_renderer.has_method("mark_proxy_dirty"):
		return
	static_renderer.call("mark_proxy_dirty", source_key, reason)


## Check if a model is considered "significant" for per-object LOD
## Significant objects include buildings, towers, large rocks, landmarks
## Uses ImpostorCandidates patterns (same ones used for impostor generation)
# PHASE_A:MAIN_ONLY — lazy-inits _impostor_candidates; writable shared state.
func is_significant_object(model_path: String) -> bool:
	# Lazy initialization of impostor candidates
	if not _impostor_candidates:
		_impostor_candidates = ImpostorCandidatesScript.new()

	return _impostor_candidates.should_have_impostor(model_path)


# REMOVED: _register_with_distance_manager()
# The native streaming system uses visibility_range for distance-based visibility,
# not a separate ObjectStreamer/DistanceTierManager.
# LOD configuration is handled by NativeStreamingManager._configure_cell_visibility()


## Phase A — main-thread dispatcher pre-flight. Mirrors every bailout the sync
## source-ref node path makes BEFORE it
## would reach `model_loader.get_model`:
##
##   1. Type exclusion — light / npc / creature / leveled_* go through custom
##      paths (`_instantiate_light`, `_instantiate_actor`, leveled resolver).
##      These NEVER hit the cache-hit PackedScene.instantiate path.
##   2. STAT → static-renderer routing. `_should_route_to_renderer` returns
##      true for the ~80% STAT case. Dispatching these to the Node3D worker
##      would REGRESS the T.1 statics_no_node3d win by spawning per-ref
##      physics bodies. Never dispatch STAT refs that will route to RS.
##   3. Proximity gate — `_is_proximity_gated` + > INTERACTIVE_PROXIMITY_THRESHOLD_M
##      returns null in sync, which cell_manager routes into _proximity_deferred.
##      Dispatching these to worker would spawn Node3Ds that sync would have
##      deferred; re-queue on proximity still works but the PackedScene
##      instantiate burns worker thread for a ref the camera can't interact
##      with yet.
##
## Returns true ONLY when dispatch should proceed. False means sync path
## handles it; dispatcher MUST fall through (no worker task added).
##
## entry is typed Variant (cell_manager.InstantiationEntry inner class — avoids
## circular import). entry.load_profile may be null (content-cell loads without
## a LoadProfile fall back to the instantiator's own `use_static_renderer`).
# PHASE_A:MAIN_ONLY - reads static_renderer singleton, model_loader cache, and
# camera_position. Source-specific parser access is supplied before this call.
func should_dispatch_to_worker(
	entry: Variant,
	base_record: Variant,
	type_name: String,
) -> bool:
	# 1. Type exclusion — custom paths handle these, no cache-hit branch.
	match type_name:
		"light", "npc", "creature", "leveled_creature", "leveled_item":
			return false

	var is_carryable: bool = _source_is_carryable(type_name, base_record)

	# 2. Static-renderer routing — STAT → RS.instance_create2 path. Must mirror
	# sync's effective_use_static resolution: per-request LoadProfile override
	# if present, else the instantiator's own `use_static_renderer` field.
	var effective_use_static: bool = use_static_renderer
	if entry.load_profile != null:
		effective_use_static = entry.load_profile.use_static_renderer
	if _should_route_to_renderer(type_name, entry.model_path, is_carryable, effective_use_static):
		return false

	# 3. Proximity gate — sync would return null with `last_proximity_deferred`
	# for interactives beyond INTERACTIVE_PROXIMITY_THRESHOLD_M. Dispatch would
	# succeed but produce a Node3D the caller was about to defer. Skip.
	# Interior pockets set effective_use_static=false → skip gate (pockets are
	# bounded, every ref spawns immediately; matches sync).
	if effective_use_static and _is_proximity_gated(type_name, is_carryable):
		var ref_world_pos := CS.vector_to_godot(entry.ref.position)
		if ref_world_pos.distance_squared_to(camera_position) > INTERACTIVE_PROXIMITY_THRESHOLD_M * INTERACTIVE_PROXIMITY_THRESHOLD_M:
			return false

	return true


## Phase E — main-thread dispatcher pre-flight for STAT refs.
##
## MIRROR of `should_dispatch_to_worker` (Phase A) but for the STAT path that
## routes to StaticObjectRenderer. Returns true ONLY when:
##
##   1. The sync path WOULD route this ref to `_instantiate_static_object`
##      (i.e. `_should_route_to_renderer` returns true). Phase A returns
##      false for these; Phase E takes the mirror branch.
##   2. The static_renderer is non-null.
##   3. The prototype is ALREADY registered via register_from_prototype.
##      Cold register walks a scene tree and must stay main-thread; the
##      dispatcher skips unregistered types (they'll fall through to the
##      sync `_instantiate_static_object` which triggers cold register).
##
## Phase E and Phase A dispatch are mutually exclusive — Phase A's gate
## excludes STAT routing, so a given ref is eligible for at most one of
## the two worker paths.
##
## Plan: phase_e_static_bulk_upload.md §3.3, §5
# PHASE_E:MAIN_ONLY — reads static_renderer + _mesh_types + camera-derived state.
func should_dispatch_static_precompute(
	entry: Variant,
	base_record: Variant,
	type_name: String,
) -> bool:
	if static_renderer == null:
		return false

	var is_carryable: bool = _source_is_carryable(type_name, base_record)

	# Effective-use-static mirror (matches should_dispatch_to_worker).
	var effective_use_static: bool = use_static_renderer
	if entry.load_profile != null:
		effective_use_static = entry.load_profile.use_static_renderer

	# Must take the STAT-routed branch in the sync path.
	if not _should_route_to_renderer(type_name, entry.model_path, is_carryable, effective_use_static):
		return false

	# Must be already registered — cold register stays main-thread.
	var normalized: String = entry.model_path.to_lower().replace("/", "\\")
	if not static_renderer.call("has_type", normalized):
		return false

	return true


## Shared main-thread classifier for callers that need to know whether a model
## will use the static renderer before an InstantiationEntry exists.
func should_route_model_to_static_renderer(
	type_name: String,
	model_path: String,
	base_record: Variant,
	effective_use_static: bool,
) -> bool:
	var is_carryable: bool = _source_is_carryable(type_name, base_record)
	return _should_route_to_renderer(type_name, model_path, is_carryable, effective_use_static)


## Phase E — worker that precomputes a PrecomputedInstance for a STAT ref.
##
## Runs on WorkerThreadPool. Reads `static_renderer._mesh_types` (set-once by
## register_from_prototype, dispatcher gate blocks race). Writes only to
## `entry.worker_static_precomp`.
##
## On failure (type not registered, scenario invalid) leaves
## `worker_static_precomp == null`; drain falls back to the sync path which
## will trigger cold register_from_prototype on main thread.
##
## Plan: phase_e_static_bulk_upload.md §3.4
# PHASE_E:WORKER_SAFE — by design. Zero autoload / signal / scene-tree access.
func _worker_static_precompute(entry: Variant, cell_grid: Vector2i) -> void:
	if static_renderer == null:
		return
	var normalized: String = entry.model_path.to_lower().replace("/", "\\")
	var world_transform := _source_ref_transform(entry.ref)
	var precomp: Variant = static_renderer.call(
		"precompute_instance",
		normalized,
		cell_grid,
		world_transform,
		StringName(str(entry.ref.ref_id)),
		int(entry.ref.ref_num),
	)
	# Populate fields that do not belong in the worker-safe renderer contract.
	# Empty strings break downstream
	# readers — e.g. `find_instances_near` at static_object_renderer.gd ~1073
	# skips any InstanceData whose model_path is empty. Future promotion work
	# relies on this field being populated.
	if precomp != null:
		precomp.model_path = entry.model_path
		precomp.item_id = entry.item_id
	# Last write — becomes visible to main-thread drain once
	# WorkerThreadPool.is_task_completed returns true.
	entry.worker_static_precomp = precomp


## Phase E main-thread publish — consumes a worker-built PrecomputedInstance.
##
## Called from cell_manager drain when a static-precompute task completes.
## Publishes the instance to StaticObjectRenderer (MultiMesh slot allocation +
## dict bookkeeping), updates `last_type_name` for diag attribution, and
## resets `last_proximity_deferred` since STAT refs don't use that path.
##
## Returns null unconditionally — statics don't produce a Node3D. The
## `null` return mirrors the sync `_instantiate_static_object` return contract.
## On a null precomp (worker failed), returns null and the caller drops the
## ref silently (pending_instantiations already decremented).
##
## Plan: phase_e_static_bulk_upload.md §3.5
# PHASE_E:MAIN_ONLY
func complete_worker_static_precompute(entry: Variant, precomp: Variant) -> Node3D:
	last_type_name = "static"
	last_proximity_deferred = false
	_reset_last_inst_diagnostics("worker_static_publish")
	if precomp == null or static_renderer == null:
		return null
	# `add_instance_precomputed` returns the new instance_id; we don't need it
	# here (remove_instance happens on cell unload via cell_grid index).
	var add_start := Time.get_ticks_usec()
	var id: int = static_renderer.call("add_instance_precomputed", precomp)
	last_static_add_us = Time.get_ticks_usec() - add_start
	if id >= 0:
		stats["static_renderer_instances"] += 1
		# Mirror of the sync path's `last_static_data` side-channel for the GPU
		# Scene Database collector (see cell_manager._collect_static_data).
		last_static_data = {
			"transform": precomp.world_transform,
			"aabb": precomp.aabb,
			"mesh_id": float(precomp.type_name.hash()),
			"lod_mask": 0,
		}
	return null


## Phase A — off-thread PackedScene.instantiate worker. Executes on a
## WorkerThreadPool thread. Touches only the detached Node3D subtree:
## NO autoloads, NO signals, NO scene-tree ops. The dispatcher (cell_manager)
## calls WorkerThreadPool.add_task with this bound; the drain (main thread)
## reads entry.worker_instance only after WorkerThreadPool.is_task_completed
## returns true — that boundary is the implicit mutex (plan §3.4).
##
## base_record + type_name are passed via .bind() rather than on the entry
## because adapter source lookup may be worker-unsafe and should stay on the
## main thread.
##
## Mirrors model_loader._instantiate_from_scene's post-processing
## (strip_occluders + disable_collision) plus the main-thread "setup" tail
## currently at reference_instantiator.gd:334-351 (name, transform, metadata,
## hide_lod). Carryable conversion / door attachment / interior-collision
## fallback / auto-anim stay on the main-thread tail per plan §5.
##
## Plan: docs/plans/distant_rendering_2026_04/phase_a_offthread_instantiate.md §3.2
# PHASE_A:WORKER_SAFE — by design. Zero autoload / signal / scene-tree access.
func _worker_instantiate(
	entry: Variant,
	packed_scene: PackedScene,
	base_record: Variant,
	type_name: String,
) -> void:
	if packed_scene == null or not packed_scene.can_instantiate():
		entry.worker_instance = null
		return
	var raw: Node = packed_scene.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
	if raw == null:
		entry.worker_instance = null
		return
	if not raw is Node3D:
		# Not a Node3D — worker can't queue_free safely mid-flight; leave the
		# node orphaned and main thread will never pick it up (worker_instance
		# stays null). GC handles the leak because `raw` goes out of scope.
		entry.worker_instance = null
		return
	var instance: Node3D = raw as Node3D
	# model_loader owns the post-instantiate post-processing helpers. Both are
	# detached-subtree pure-mutation ops — safe off-thread.
	if model_loader != null:
		model_loader.call("_strip_occluders", instance)
	# Static helper — class-level callable (no instance state).
	@warning_ignore("unsafe_method_access")
	model_loader._disable_collision_shapes_in_tree(instance)
	var record: RefCounted = entry.world_object_record
	if record != null:
		var source_ref := str(record.get("source_ref_id"))
		instance.name = source_ref if not source_ref.is_empty() else str(record.get("object_id"))
		instance.transform = _record_transform(record)
		_apply_record_metadata(instance, record, entry.model_path, type_name)
	else:
		instance.name = str(entry.ref.ref_id) + "_" + str(entry.ref.ref_num)
		_apply_transform(instance, entry.ref, true)
		_apply_metadata(instance, entry.ref, base_record, entry.model_path, type_name)
	_hide_lod_nodes(instance)
	# Last write — becomes visible to the main-thread drain once
	# WorkerThreadPool.is_task_completed returns true.
	entry.worker_instance = instance


## Phase A main-thread tail — completes the per-ref work that couldn't run
## off-thread. The worker already applied name / transform / metadata /
## hide_lod / disabled-collision on a detached Node3D. This function runs:
##
##   - NEAR-tier collision enable (if ref is < 150m from camera)
##   - Carryable conversion (StaticBody3D → frozen RigidBody3D + pickup)
##   - Door attachment (set_script + signal connect for teleport doors)
##   - Interior collision fallback (generate StaticBody3D from AABB)
##   - NIF animation autoplay (flags / banners / rotating lights)
##   - stats + last_type_name bookkeeping so diag counters stay correct
##
## Mirrors the tail of _instantiate_model_object (lines 334-410 of the
## synchronous path). Returns the passed-in instance, or a placeholder if
## instance is null (worker failure or non-Node3D result).
##
## Plan: docs/plans/distant_rendering_2026_04/phase_a_offthread_instantiate.md §3.3
# PHASE_A:MAIN_ONLY — runs autoload reads, signal connects, add_child.
func complete_worker_instantiate(
	entry: Variant,
	instance: Node3D,
	base_record: Variant,
	type_name: String,
) -> Node3D:
	# Match the sync path's diagnostic hook so cell_manager's per-type
	# breakdown picks up worker-path entries under the right type key.
	last_type_name = type_name
	last_proximity_deferred = false
	_reset_last_inst_diagnostics("worker_node_tail")
	# Null path removed — the cell_manager drain only calls this when
	# entry.worker_instance != null. @roaster review 2026-04-20 §4c.
	var ref: Variant = entry.ref
	var record: RefCounted = entry.world_object_record
	var record_id: String = ""
	if base_record != null and "record_id" in base_record:
		record_id = base_record.record_id
	var cell_grid: Vector2i = _record_cell_grid(record) if record != null else entry.cell_grid
	var source_key := ""
	if _uses_visual_proxy(type_name):
		source_key = _record_source_key(record, type_name) if record != null else ""
		if not source_key.is_empty():
			instance.set_meta("source_key", source_key)
			instance.set_meta("cell_grid", cell_grid)
			_suppress_visual_proxy(source_key, type_name)
			_wire_visual_proxy_restore_on_exit(instance, source_key)

	# NEAR-tier collision enable (mirror of _instantiate_model_object:339-342).
	var ref_pos := _record_transform(record).origin if record != null else CS.vector_to_godot(ref.position)
	if ref_pos.distance_squared_to(camera_position) < DU.NEAR_END * DU.NEAR_END:
		if not StreamingConfig.DEBUG_DISABLE_JOLT_ATTACH:
			_enable_collision_shapes_in_tree(instance)

	# Carryable conversion (mirror of _instantiate_model_object:353-374).
	var is_carryable: bool = _source_is_carryable(type_name, base_record)
	_postprocess_source_model_object(instance, ref, base_record, type_name, cell_grid, record_id, source_key)
	# Interior collision fallback (mirror of _instantiate_model_object:385-395).
	var is_teleport_door := bool(ref != null and "is_teleport" in ref and ref.is_teleport)
	if not is_carryable and not (type_name == "door" and is_teleport_door):
		if not _effective_use_static_renderer():
			if not _has_static_body(instance) and not StreamingConfig.DEBUG_DISABLE_JOLT_ATTACH:
				_generate_static_collision(instance)

	stats["objects_instantiated"] += 1

	# NIF anim autoplay (mirror of _instantiate_model_object:400).
	_auto_play_nif_animation(instance, ref)

	return instance


func _record_transform(record: RefCounted) -> Transform3D:
	if record == null:
		return Transform3D.IDENTITY
	var value: Variant = record.get("transform")
	if value is Transform3D:
		return value as Transform3D
	return Transform3D.IDENTITY


func _source_ref_transform(ref: Variant) -> Transform3D:
	if ref == null:
		return Transform3D.IDENTITY
	var pos := CS.vector_to_godot(ref.position)
	var scale := CS.scale_to_godot(ref.scale)
	var basis := CS.esm_rotation_to_godot_basis(ref.rotation)
	basis = basis.scaled(scale)
	return Transform3D(basis, pos)


func _record_source_type(record: RefCounted) -> String:
	if record == null:
		return "object"
	var source_type := str(record.get("source_type"))
	if not source_type.is_empty():
		return source_type
	return "object"


func _record_cell_grid(record: RefCounted) -> Vector2i:
	if record == null:
		return Vector2i.ZERO
	var value: Variant = record.get("cell_grid")
	if value is Vector2i:
		return value
	return Vector2i.ZERO


func _record_source_key(record: RefCounted, type_name: String) -> String:
	if record == null:
		return ""
	var source_key := str(record.get("source_key"))
	if not source_key.is_empty():
		return source_key
	var object_id := str(record.get("object_id"))
	if object_id.is_empty():
		return ""
	return "%s:%s" % [type_name, object_id]


func _record_ref_num(record: RefCounted) -> int:
	if record == null:
		return 0
	var object_id := str(record.get("object_id"))
	if object_id.is_empty():
		return 0
	var parts := object_id.split(":")
	if parts.is_empty():
		return 0
	return int(parts[parts.size() - 1])


func _record_node_name(record: RefCounted) -> String:
	if record == null:
		return ""
	var source_ref := str(record.get("source_ref_id"))
	var ref_num := _record_ref_num(record)
	if not source_ref.is_empty() and ref_num != 0:
		return "%s_%d" % [source_ref, ref_num]
	var object_id := str(record.get("object_id"))
	return object_id if not object_id.is_empty() else source_ref


func _ensure_visual_proxy(
	source_key: String,
	transform: Transform3D,
	model_path: String,
	cell_grid: Vector2i,
	type_name: String,
	cache_item_id: String = "",
	ref_id: StringName = &"",
	ref_num: int = 0
) -> bool:
	if not _uses_visual_proxy(type_name):
		return false
	if type_name == "container":
		if transform.origin.distance_squared_to(camera_position) > CONTAINER_VISUAL_PROXY_RANGE_M * CONTAINER_VISUAL_PROXY_RANGE_M:
			return false
	if static_renderer == null or model_loader == null:
		return false
	if not static_renderer.has_method("add_visual_proxy"):
		return false
	if static_renderer.has_method("is_proxy_dirty") and bool(static_renderer.call("is_proxy_dirty", source_key)):
		return false

	var normalized := model_path.to_lower().replace("/", "\\")
	if not _ensure_visual_proxy_type_registered(normalized, model_path, cache_item_id):
		return false

	var add_start := Time.get_ticks_usec()
	var instance_id: int = static_renderer.call(
		"add_visual_proxy",
		source_key,
		normalized,
		transform,
		cell_grid,
		model_path,
		"",
		ref_id,
		ref_num
	)
	last_static_add_us += Time.get_ticks_usec() - add_start
	if instance_id < 0:
		return false
	stats["visual_proxies_created"] = int(stats.get("visual_proxies_created", 0)) + 1
	return true


func _ensure_visual_proxy_type_registered(type_name: String, model_path: String, cache_item_id: String = "") -> bool:
	if static_renderer.call("has_type", type_name):
		return true

	# Visual proxies may use only the already-promoted PackedScene. This keeps
	# the MID-lag fix's no-sync-load rule while still letting deferred doors
	# publish their cheap render proxy after the async model load completes.
	if not model_loader.has_method("get_cached_packed_scene") or not static_renderer.has_method("register_from_packed_scene"):
		return false
	var packed_scene: PackedScene = model_loader.call("get_cached_packed_scene", model_path, cache_item_id)
	if packed_scene == null and not cache_item_id.is_empty():
		packed_scene = model_loader.call("get_cached_packed_scene", model_path, "")
	if packed_scene == null:
		return false
	var reg_start := Time.get_ticks_usec()
	var registered := bool(static_renderer.call("register_from_packed_scene", type_name, packed_scene))
	last_static_register_us += Time.get_ticks_usec() - reg_start
	return registered


func _suppress_visual_proxy(source_key: String, type_name: String) -> void:
	if not _uses_visual_proxy(type_name) or static_renderer == null or not static_renderer.has_method("suppress_proxy"):
		return
	static_renderer.call("suppress_proxy", source_key)


static func _uses_visual_proxy(type_name: String) -> bool:
	match type_name:
		"door":
			return DOOR_VISUAL_PROXY_ENABLED
		"container":
			return CONTAINER_VISUAL_PROXY_ENABLED
		_:
			return false


func _wire_visual_proxy_restore_on_exit(instance: Node3D, source_key: String) -> void:
	if instance == null or source_key.is_empty():
		return
	if static_renderer == null or not static_renderer.has_method("restore_proxy_if_clean"):
		return
	instance.tree_exiting.connect(_restore_visual_proxy_if_clean.bind(source_key), CONNECT_ONE_SHOT)


func _restore_visual_proxy_if_clean(source_key: String) -> void:
	if static_renderer == null or not static_renderer.has_method("restore_proxy_if_clean"):
		return
	static_renderer.call("restore_proxy_if_clean", source_key)


## Instantiate a light object (model + OmniLight3D)
func _instantiate_light(record: RefCounted, light_record: LightRecord) -> Node3D:
	last_inst_route = "light"
	# Create container node
	var light_node := Node3D.new()
	light_node.name = _record_node_name(record)

	# Load the model if it has one
	if not light_record.model.is_empty():
		var model_load_start := Time.get_ticks_usec()
		var model_instance: Node3D = model_loader.call("get_model", light_record.model)
		last_model_load_us = Time.get_ticks_usec() - model_load_start
		if model_instance:
			model_instance.name = "Model"
			_hide_lod_nodes(model_instance)  # Hide materialless meshes only
			# Lights are always within NEAR tier (150m fade-out set on OmniLight3D)
			var ref_pos := _record_transform(record).origin
			if ref_pos.distance_squared_to(camera_position) < DU.NEAR_END * DU.NEAR_END:
				_enable_collision_shapes_in_tree(model_instance)
			# Auto-play NIF animations on light models (rotating lights, animated lanterns)
			_auto_play_nif_animation_for_transform(model_instance, _record_transform(record))
			_boost_light_model_emission(model_instance, light_record)
			light_node.add_child(model_instance)

	# Apply transform first — Win 4b needs the world transform up front to
	# register the server-direct light instance with the correct position.
	# Reordering is safe: _apply_transform only writes node.position/scale/basis
	# with no side effects on children (which are already attached above).
	light_node.transform = _record_transform(record)

	# Create the actual light source
	if create_lights and light_record.radius > 0 and not light_record.is_off_by_default():
		# Win 4b — server-direct path UNLESS the light needs flicker/pulse
		# animation. LightAnimator (light_animator.gd) walks the cell tree for
		# OmniLight3D nodes with `light_animation` meta; RS RIDs aren't visible
		# to that walker. Animated lights keep the OmniLight3D Node3D so the
		# existing flicker/pulse system continues to work. Static lights go
		# server-direct, saving the OmniLight3D wrapper cost (per
		# server_direct_pattern.md, OmniLight3D is just a thin Node3D + RID
		# wrapper around the same underlying server-side light data).
		var animated := _source_light_animation_for_record(light_record) != WorldObjectRecordScript.LightAnimation.NONE
		if animated:
			_attach_animated_omni_light(light_node, light_record)
		else:
			_attach_server_direct_light(light_node, light_record)
		stats["lights_created"] += 1

	# Add metadata for console object picker
	_apply_record_metadata(light_node, record, light_record.model if not light_record.model.is_empty() else "", "light")
	light_node.set_meta("form_id", light_record.record_id if "record_id" in light_record else str(record.get("record_id")))

	return light_node


## Boosted-emission material cache — keyed by the SOURCE material object (holds
## a reference, so instance-id reuse can't alias). Prebaked materials are shared
## across every torch/candle using the same NIF, so each source is duplicated
## exactly once per boost tier.
var _emission_boost_fire: Dictionary[Material, StandardMaterial3D] = {}
var _emission_boost_other: Dictionary[Material, StandardMaterial3D] = {}


## Raise emission energy on light-model surfaces that already emit (flame quads,
## glow textures from the NIF). Applied as per-instance surface overrides so the
## shared prebaked materials are never mutated.
func _boost_light_model_emission(root: Node3D, light_record: LightRecord) -> void:
	var is_fire := light_record.is_fire()
	var target_energy := LIGHT_MODEL_EMISSION_FIRE if is_fire else LIGHT_MODEL_EMISSION_OTHER
	var cache := _emission_boost_fire if is_fire else _emission_boost_other
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child: Node in node.get_children():
			stack.append(child)
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for surface: int in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(surface) as StandardMaterial3D
			if mat == null or not mat.emission_enabled:
				continue
			if mat.emission_energy_multiplier >= target_energy:
				continue
			var boosted: StandardMaterial3D = cache.get(mat)
			if boosted == null:
				boosted = mat.duplicate() as StandardMaterial3D
				boosted.emission_energy_multiplier = target_energy
				cache[mat] = boosted
			mi.set_surface_override_material(surface, boosted)


## Legacy OmniLight3D path — used for lights with flicker/pulse flags so
## LightAnimator's scene-tree walker can find them. Identical to the pre-Win-4b
## OmniLight3D setup.
func _attach_animated_omni_light(light_node: Node3D, light_record: LightRecord) -> void:
	var omni := OmniLight3D.new()
	omni.name = "Light"

	# Convert MW radius to Godot range — enforce 0.125m min per OpenMW.
	var godot_range: float = maxf(light_record.radius * SOURCE_LIGHT_RADIUS_SCALE, 0.125)
	omni.omni_range = godot_range
	omni.light_color = light_record.color
	if light_record.is_negative():
		omni.light_negative = true
	omni.light_energy = 1.2 if light_record.is_fire() else 0.8
	omni.shadow_enabled = false  # managed by LightShadowBudget if present
	omni.omni_attenuation = 1.0
	# Distance fade: 120m begin, 150m end (matches NEAR tier boundary).
	omni.distance_fade_enabled = true
	omni.distance_fade_begin = 120.0
	omni.distance_fade_length = 30.0
	# Metadata read by LightAnimator + diagnostics.
	omni.set_meta("light_animation", _source_light_animation_for_record(light_record))
	omni.set_meta("base_energy", omni.light_energy)

	light_node.add_child(omni)


func _attach_carryable_light_source(instance: Node3D, light_record: LightRecord) -> void:
	if instance == null or light_record == null:
		return
	if not create_lights or light_record.radius <= 0 or light_record.is_off_by_default():
		return
	_attach_animated_omni_light(instance, light_record)


## Win 4b — server-direct light: RS.omni_light_create + RS.instance_create
## paired with a LightRids RefCounted attached as metadata. The RefCounted's
## PREDELETE handler frees both RIDs when light_node is queue_freed via cell
## teardown.
##
## Mirrors `_attach_animated_omni_light` parameters: same range / color / energy
## / attenuation / shadow defaults / distance-fade band. Distance fade uses
## RenderingServer.instance_geometry_set_visibility_range with FADE_SELF mode,
## which is exactly what OmniLight3D.distance_fade_* sets internally.
##
## World transform pulled from light_node.transform — _apply_transform ran
## just above, and light_node hasn't been parented yet, so .transform IS the
## world transform (cell_node sits at world origin in Godot coords).
func _attach_server_direct_light(light_node: Node3D, light_record: LightRecord) -> void:
	var world_3d: World3D = null
	if scene_tree != null and scene_tree.root != null:
		world_3d = scene_tree.root.world_3d
	if world_3d == null:
		# No scene_tree wired — fall back to OmniLight3D so the light still
		# functions. Surfaces in tests that don't init the streaming layer
		# fully (rare in production but cheap defensive code).
		_attach_animated_omni_light(light_node, light_record)
		return

	var rids := LightRids.new()

	# Create the omni light data RID.
	rids.light_rid = RenderingServer.omni_light_create()

	# Range — MW radius scaled to meters with 0.125m floor (OpenMW convention).
	var godot_range: float = maxf(light_record.radius * SOURCE_LIGHT_RADIUS_SCALE, 0.125)
	RenderingServer.light_set_param(rids.light_rid, RenderingServer.LIGHT_PARAM_RANGE, godot_range)

	RenderingServer.light_set_color(rids.light_rid, light_record.color)

	if light_record.is_negative():
		RenderingServer.light_set_negative(rids.light_rid, true)

	var energy: float = 1.2 if light_record.is_fire() else 0.8
	RenderingServer.light_set_param(rids.light_rid, RenderingServer.LIGHT_PARAM_ENERGY, energy)

	# Attenuation 1.0 matches OmniLight3D default.
	RenderingServer.light_set_param(rids.light_rid, RenderingServer.LIGHT_PARAM_ATTENUATION, 1.0)

	# Shadows off by default — LightShadowBudget toggles per-light if present.
	# Server-direct lights are NOT scanned by LightShadowBudget today (it
	# walks for OmniLight3D Node3Ds the same way LightAnimator does); shadows
	# stay off for the entire static-light set until that walker is extended
	# to also drive RIDs. Acceptable tradeoff — most MW omni lights ship with
	# shadows off anyway, and ambient lighting carries the visual.
	RenderingServer.light_set_shadow(rids.light_rid, false)

	# Create the scenario instance and bind the light data.
	rids.instance_rid = RenderingServer.instance_create()
	RenderingServer.instance_set_base(rids.instance_rid, rids.light_rid)
	RenderingServer.instance_set_scenario(rids.instance_rid, world_3d.scenario)
	RenderingServer.instance_set_transform(rids.instance_rid, light_node.transform)

	# Distance fade — fade out from 120m (NEAR fade begin) to 150m (NEAR_END).
	# VISIBILITY_RANGE_FADE_SELF dithers self-alpha in the band; matches the
	# OmniLight3D.distance_fade_* behavior.
	RenderingServer.instance_geometry_set_visibility_range(
		rids.instance_rid,
		0.0, 150.0,
		0.0, 30.0,
		RenderingServer.VISIBILITY_RANGE_FADE_SELF,
	)

	# Metadata-attach the RID holder so cell_node.queue_free → light_node
	# .queue_free → meta release → LightRids destructor → RS.free_rid.
	light_node.set_meta("rs_light_rids", rids)


## Instantiate an NPC or Creature
## Uses CharacterFactory to create fully animated and functional characters
func _instantiate_actor(record: RefCounted, actor_record: Variant, actor_type: String) -> Node3D:
	last_inst_route = "actor"
	# Skip actors beyond NEAR tier — full CharacterBody3D is too expensive at distance.
	# Per-request override via LoadProfile: interior pockets set this to 0.0
	# because the camera is still at exterior position during pocket load.
	var effective_actor_dist: float = _effective_max_actor_distance()
	if effective_actor_dist > 0.0:
		var ref_pos := _record_transform(record).origin
		if ref_pos.distance_squared_to(camera_position) > effective_actor_dist * effective_actor_dist:
			last_proximity_deferred = true
			last_inst_route = "deferred"
			return null

	# Use CharacterFactory if available (new system)
	if character_factory:
		var character: CharacterBody3D = null

		if actor_record is CreatureRecord:
			var creature_rec: CreatureRecord = actor_record as CreatureRecord
			character = character_factory.create_creature(creature_rec, _record_ref_num(record))
			stats["creatures_loaded"] += 1
		elif actor_record is NPCRecord:
			var npc_rec: NPCRecord = actor_record as NPCRecord
			character = character_factory.create_npc(npc_rec, _record_ref_num(record))
			stats["npcs_loaded"] += 1

		if character:
			# Apply transform to the CharacterBody3D
			character.transform = _record_transform(record)

			# Add additional metadata for console object picker
			_apply_record_metadata(character, record, str(actor_record.model) if "model" in actor_record else "", actor_type)
			character.set_meta("form_id", actor_record.record_id if "record_id" in actor_record else str(record.get("record_id")))
			character.set_meta("actor_type", actor_type)

			# C.5 — NPC dialogue: wrap in NPCInteractable so the
			# raycaster can walk up from the character's collision shape
			# to find the Interactable ancestor. The wrapper inherits
			# the character's world-space transform; the character moves
			# to identity (local to wrapper). Same layer-3 stamp as doors.
			return _postprocess_source_actor(character, null, actor_record, actor_type)

	# Fallback to old system if CharacterFactory not available
	return _instantiate_actor_legacy(record, actor_record, actor_type)


## Legacy actor instantiation (old system - basic model loading)
func _instantiate_actor_legacy(record: RefCounted, actor_record: Variant, actor_type: String) -> Node3D:
	var model_path: String = ""

	if actor_record is CreatureRecord:
		model_path = actor_record.model
		stats["creatures_loaded"] += 1
	elif actor_record is NPCRecord:
		# NPCs are complex - they use body parts assembled together
		# For now, use the base model if available, otherwise skip
		model_path = actor_record.model
		stats["npcs_loaded"] += 1

	if model_path.is_empty():
		# NPC without direct model - would need body part assembly
		# Create a simple placeholder for now
		return _create_actor_placeholder(record, actor_record, actor_type)

	var instance: Node3D = model_loader.call("get_model", model_path)
	if not instance:
		return _create_actor_placeholder(record, actor_record, actor_type)

	instance.name = _record_node_name(record)

	# Actors are NEAR-only — enable collision (actor loading skips > max_actor_distance)
	_enable_collision_shapes_in_tree(instance)

	# Hide materialless meshes only
	_hide_lod_nodes(instance)

	# Check if model has actor collision metadata (from NIF "Bounding Box" node)
	# If so, ensure it has a capsule collision shape for proper physics
	if instance.has_meta("actor_collision_extents"):
		_ensure_actor_collision(instance, actor_type)

	# Apply transform
	instance.transform = _record_transform(record)

	# Add metadata for console object picker
	var record_type := "NPC_" if actor_type == "npc" else "CREA"
	instance.set_meta("form_id", actor_record.record_id if "record_id" in actor_record else str(record.get("record_id")))
	instance.set_meta("record_type", record_type)
	instance.set_meta("model_path", model_path)
	var source_ref := str(record.get("source_ref_id"))
	if not source_ref.is_empty():
		instance.set_meta("ref_id", source_ref)
	var ref_num := _record_ref_num(record)
	if ref_num != 0:
		instance.set_meta("ref_num", ref_num)
		instance.set_meta("instance_id", ref_num)
	instance.set_meta("actor_type", actor_type)

	return instance


## Ensure actor has proper capsule collision for CharacterBody3D compatibility
func _ensure_actor_collision(instance: Node3D, actor_type: String) -> void:
	# Get collision data from metadata (set by NIFConverter)
	var extents: Vector3 = instance.get_meta("actor_collision_extents", Vector3(0.3, 0.9, 0.3))
	var center: Vector3 = instance.get_meta("actor_collision_center", Vector3.ZERO)

	# Convert extents to Godot coordinates (Y-up) and meters
	extents = CS.vector_to_godot(extents).abs()
	center = CS.vector_to_godot(center)

	# Calculate dimensions
	var width := maxf(extents.x, extents.z) * 2.0
	var height := extents.y * 2.0

	# Create collision shape - capsule for humanoids, box for squat creatures
	var coll_shape := CollisionShape3D.new()
	coll_shape.name = "ActorCollision"

	if height > width * 1.2:
		# Capsule for humanoid shapes
		var capsule := CapsuleShape3D.new()
		capsule.radius = width / 2.0
		capsule.height = height
		coll_shape.shape = capsule
	else:
		# Box for squat creatures (rats, mudcrabs, etc.)
		var box := BoxShape3D.new()
		box.size = Vector3(width, height, width)
		coll_shape.shape = box

	# Position collision shape at center
	coll_shape.position = center

	# Add to actor model
	# Find or create physics body
	var body: StaticBody3D = null
	for child in instance.get_children():
		if child is StaticBody3D:
			body = child
			break

	if not body:
		body = StaticBody3D.new()
		body.name = "ActorBody"
		body.collision_layer = 2  # Actor layer
		body.collision_mask = 1   # World collision
		instance.add_child(body)

	body.add_child(coll_shape)


## Create a placeholder for actors without models
func _create_actor_placeholder(record: RefCounted, _actor_record: Variant, actor_type: String) -> Node3D:
	var container := Node3D.new()
	container.name = _record_node_name(record)

	# Visual placeholder mesh
	var placeholder := MeshInstance3D.new()
	placeholder.name = "Visual"

	# Capsule mesh for humanoid shape (in meters)
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35  # ~35cm radius
	capsule.height = 1.8   # ~1.8m tall
	placeholder.mesh = capsule

	# Color based on type
	var mat := StandardMaterial3D.new()
	if actor_type == "npc":
		mat.albedo_color = Color(0.2, 0.6, 1.0, 0.7)  # Blue for NPCs
	else:
		mat.albedo_color = Color(1.0, 0.4, 0.2, 0.7)  # Orange for creatures
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	placeholder.material_override = mat

	# Offset visual so bottom is at origin (feet at ground level)
	placeholder.position.y = capsule.height / 2.0

	container.add_child(placeholder)

	# Add collision body with capsule shape
	var body := StaticBody3D.new()
	body.name = "ActorBody"
	body.collision_layer = 2  # Actor layer
	body.collision_mask = 1   # World collision

	var coll_shape := CollisionShape3D.new()
	coll_shape.name = "ActorCollision"
	var coll_capsule := CapsuleShape3D.new()
	coll_capsule.radius = 0.35
	coll_capsule.height = 1.8
	coll_shape.shape = coll_capsule
	coll_shape.position.y = capsule.height / 2.0  # Match visual

	body.add_child(coll_shape)
	container.add_child(body)

	# Store metadata
	container.set_meta("actor_type", actor_type)
	container.set_meta("is_placeholder", true)

	# Apply transform (no model rotation needed for placeholder)
	container.transform = _record_transform(record)

	return container



## Walk a subtree and OR the Interactable bit (layer 3, bit index 2) onto
## every CollisionObject3D's collision_layer. Used by the DOOR adapter
## wiring above so door StaticBody3Ds become raycast-targetable without
## losing their existing Environment layer.
# PHASE_A:WORKER_SAFE — pure property mutation on a detached subtree. Currently
# only called from _attach_door_interactable (main-thread tail), but the helper
# itself is safe either thread.
func _add_interactable_layer_recursive(node: Node) -> void:
	const INTERACTABLE_BIT: int = 1 << 2  # layer 3 = Interactable
	if node is CollisionObject3D:
		var co := node as CollisionObject3D
		co.collision_layer |= INTERACTABLE_BIT
	for child in node.get_children():
		_add_interactable_layer_recursive(child)


## Check if any CollisionObject3D in the subtree has the Interactable bit set.
## Used after _add_interactable_layer_recursive to verify the stamp took effect
## (false when the door/item model has no baked collision shapes at all).
# PHASE_A:WORKER_SAFE — pure property read.
static func _has_interactable_collision(node: Node) -> bool:
	const INTERACTABLE_BIT: int = 1 << 2
	if node is CollisionObject3D:
		var co := node as CollisionObject3D
		if co.collision_layer & INTERACTABLE_BIT:
			return true
	for child in node.get_children():
		if _has_interactable_collision(child):
			return true
	return false


## Plan 2026-04-28 step 2 — cached variant of _generate_interaction_area.
##
## Routes the per-prototype AABB walk + BoxShape3D allocation through
## `InteractionShapeCache`, so the same door model published 66 times pays
## the walk + alloc once. Per-instance cost reduces to: Area3D.new +
## CollisionShape3D.new + add_child + 2 transform writes.
##
## The cached `BoxShape3D` is shared across every Area3D produced from this
## prototype — see `InteractionShapeCache` mutation contract. Callers MUST
## NOT mutate `shape.size` per instance.
##
## `model_path` is the raw ESM model path (e.g. "doors\\hlaalu_loaddoor_01.nif").
## Normalized via `InteractionShapeCache.make_key` so the cache lines up
## with the rest of the codebase's prototype identity convention.
##
## Returns the new Area3D (already child of root).
##
## Plan: docs/plans/near_streaming_2026_04_28_interactive_spawn.md step 2.
func _generate_interaction_area_cached(root: Node3D, model_path: String) -> Area3D:
	if _interaction_shape_cache == null:
		_interaction_shape_cache = InteractionShapeCacheScript.new()

	var key := InteractionShapeCacheScript.make_key(model_path)
	# Geom is `InteractionShapeCacheScript.CachedInteractionGeometry` — typed
	# as RefCounted because the script has no class_name (load-order safety).
	var geom: RefCounted = _interaction_shape_cache.get_or_compute(key, root)

	var area := Area3D.new()
	area.name = "InteractionArea"
	area.collision_layer = 1 << 2  # Layer 3 only — Interactable
	area.collision_mask = 0        # Detects nothing
	area.monitoring = false
	area.monitorable = false

	var shape := CollisionShape3D.new()
	shape.name = "InteractionShape"
	# Reuse the shared BoxShape3D Resource — multiple Area3Ds reference the
	# same shape RID. This is the canonical Godot Resource sharing pattern.
	# Mutating shape.size here would propagate to every other instance.
	shape.shape = geom.shape
	shape.position = geom.aabb_center
	area.add_child(shape)

	root.add_child(area)
	return area


## Generate a passive Area3D with a BoxShape3D derived from the combined
## mesh AABB of the subtree. Used as a raycast target for doors/items
## whose NIF models lack baked collision shapes. The Area3D sits on layer 3
## only (Interactable) with monitoring/monitorable OFF — it's a passive
## raycast target, not an overlap detector. Matches Jolt perf guidance.
##
## NOTE: this is the legacy uncached path — kept for callers without a
## model_path key (test scenes, defensive fallback). Hot ESM-driven door
## publishes go through `_generate_interaction_area_cached` above.
# PHASE_A:MAIN_ONLY — called from _attach_door_interactable (main tail).
# add_child on a detached root is likely safe off-thread, but keep main until
# a future phase needs it on worker.
static func _generate_interaction_area(root: Node3D) -> Area3D:
	var aabb := _compute_mesh_aabb(root)
	if not aabb.has_volume():
		# Degenerate AABB — no meshes or zero-size. Use a small default box
		# centered on the root so the door is at least clickable from close range.
		aabb = AABB(Vector3(-0.3, -0.3, -0.3), Vector3(0.6, 0.6, 0.6))

	var area := Area3D.new()
	area.name = "InteractionArea"
	area.collision_layer = 1 << 2  # Layer 3 only — Interactable
	area.collision_mask = 0        # Detects nothing
	area.monitoring = false
	area.monitorable = false

	var shape := CollisionShape3D.new()
	shape.name = "InteractionShape"
	var box := BoxShape3D.new()
	box.size = aabb.size
	shape.shape = box
	# Center the shape on the AABB center (local to root)
	shape.position = aabb.get_center()
	area.add_child(shape)

	root.add_child(area)
	return area


## Compute the combined AABB of all MeshInstance3D nodes under root,
## expressed in root's LOCAL space. Uses local transforms only — safe
## to call before the node enters the scene tree.
# PHASE_A:WORKER_SAFE — pure math on detached subtree.
static func _compute_mesh_aabb(root: Node3D) -> AABB:
	var aabbs: Array[AABB] = []
	# Check root itself (if it has a mesh)
	if root is MeshInstance3D and (root as MeshInstance3D).mesh != null:
		aabbs.append((root as MeshInstance3D).mesh.get_aabb())
	# Recurse children — their transforms are relative to root
	for child in root.get_children():
		_collect_mesh_aabbs(child, Transform3D.IDENTITY, aabbs)
	if aabbs.is_empty():
		return AABB()
	var combined: AABB = aabbs[0]
	for i in range(1, aabbs.size()):
		combined = combined.merge(aabbs[i])
	return combined


## Recursive AABB collector. Accumulates mesh AABBs into `out` array,
## each transformed by the cumulative local transform chain from root.
# PHASE_A:WORKER_SAFE — pure traversal + math.
static func _collect_mesh_aabbs(node: Node, parent_xf: Transform3D, out: Array[AABB]) -> void:
	var xf: Transform3D = parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			out.append(xf * mi.mesh.get_aabb())
	for child in node.get_children():
		_collect_mesh_aabbs(child, xf, out)


## Re-enable all CollisionShape3D nodes disabled by model_loader at instantiate time.
## Mirror of NativeStreamingManager._enable_collision_shapes(). Call when an object
## is confirmed to be within NEAR tier (<150m from camera).
# PHASE_A:WORKER_SAFE — pure property mutation + remove_meta on detached subtree.
# Plan §5 row 336-345 confirms worker dispatch.
static func _enable_collision_shapes_in_tree(node: Node) -> void:
	if node is CollisionShape3D:
		(node as CollisionShape3D).disabled = false
	for child in node.get_children():
		_enable_collision_shapes_in_tree(child)
	if node is Node3D:
		(node as Node3D).remove_meta("collision_disabled")


## Check if a node subtree contains any StaticBody3D.
# PHASE_A:WORKER_SAFE — pure traversal.
static func _has_static_body(node: Node) -> bool:
	if node is StaticBody3D:
		return true
	for child in node.get_children():
		if _has_static_body(child):
			return true
	return false


## Generate a StaticBody3D + BoxShape3D from the mesh AABB for objects
## that lack baked collision. Used for interior statics (floors, walls,
## furniture) so physics objects can rest on surfaces. Layer 1 (Environment)
## only — consistent with NIF-baked collision.
# PHASE_A:MAIN_ONLY — plan §5 row 385-410 keeps interior collision fallback on
# main thread. add_child on detached root + StaticBody3D construction stay main.
static func _generate_static_collision(root: Node3D) -> void:
	var aabb := _compute_mesh_aabb(root)
	if not aabb.has_volume():
		return
	var body := StaticBody3D.new()
	body.name = "GeneratedCollision"
	body.collision_layer = 1  # Environment
	body.collision_mask = 0   # Static — doesn't need to detect anything
	var shape := CollisionShape3D.new()
	shape.name = "AABBShape"
	var box := BoxShape3D.new()
	box.size = aabb.size
	shape.shape = box
	shape.position = aabb.get_center()
	body.add_child(shape)
	root.add_child(body)


## Auto-play NIF keyframe animations on objects within NEAR tier (0-150m)
## Handles animated world objects like flags, banners, rotating lights, etc.
## Only plays if the object has a prebaked AnimationPlayer from NIF conversion.
# PHASE_A:MAIN_ONLY — reads _current_load_profile via _effective_max_actor_distance.
# Also called from the post-worker main-thread tail per plan §5 line 400.
func _auto_play_nif_animation(instance: Node3D, ref: Variant) -> void:
	if ref == null:
		return
	# Skip if beyond NEAR tier — animations are only visible up close
	var effective_actor_dist: float = _effective_max_actor_distance()
	if effective_actor_dist > 0.0:
		var ref_pos := CS.vector_to_godot(ref.position)
		if ref_pos.distance_squared_to(camera_position) > effective_actor_dist * effective_actor_dist:
			return

	# Find AnimationPlayer in the duplicated instance
	var anim_player: AnimationPlayer = null
	for child in instance.get_children():
		if child is AnimationPlayer:
			anim_player = child as AnimationPlayer
			break

	if not anim_player:
		return

	# Get the animation list from the default library
	var library := anim_player.get_animation_library("")
	if not library:
		return

	var anim_list := library.get_animation_list()
	if anim_list.is_empty():
		return

	# Play the first animation (most NIF objects have a single looping animation)
	# Set looping on the animation resource
	var first_anim_name: StringName = anim_list[0]
	var anim: Animation = library.get_animation(first_anim_name)
	if anim:
		anim.loop_mode = Animation.LOOP_LINEAR

	# Autoplay — AnimationPlayer needs to be in the tree to play, so defer
	anim_player.autoplay = first_anim_name

	# Randomize playback position to avoid synchronized animations across instances
	# (flags, banners, water wheels). autoplay starts the clip on tree_entered,
	# so we seek to a random offset once the player is in the tree.
	var player_ref: AnimationPlayer = anim_player
	instance.tree_entered.connect(
		func() -> void:
			if is_instance_valid(player_ref) and player_ref.is_playing():
				player_ref.seek(randf() * player_ref.current_animation_length),
		CONNECT_ONE_SHOT,
	)


func _auto_play_nif_animation_for_transform(instance: Node3D, transform: Transform3D) -> void:
	var effective_actor_dist: float = _effective_max_actor_distance()
	if effective_actor_dist > 0.0:
		if transform.origin.distance_squared_to(camera_position) > effective_actor_dist * effective_actor_dist:
			return

	var anim_player: AnimationPlayer = null
	for child in instance.get_children():
		if child is AnimationPlayer:
			anim_player = child as AnimationPlayer
			break

	if not anim_player:
		return

	var library := anim_player.get_animation_library("")
	if not library:
		return

	var anim_list := library.get_animation_list()
	if anim_list.is_empty():
		return

	var first_anim_name: StringName = anim_list[0]
	var anim: Animation = library.get_animation(first_anim_name)
	if anim:
		anim.loop_mode = Animation.LOOP_LINEAR

	anim_player.autoplay = first_anim_name

	var player_ref: AnimationPlayer = anim_player
	instance.tree_entered.connect(
		func() -> void:
			if is_instance_valid(player_ref) and player_ref.is_playing():
				player_ref.seek(randf() * player_ref.current_animation_length),
		CONNECT_ONE_SHOT,
	)


## Apply position, rotation, and scale to a node
## Uses unified CoordinateSystem for all conversions
# PHASE_A:WORKER_SAFE — pure property writes on a detached Node3D.
# Plan §5 row 347-348 confirms worker dispatch.
func _apply_transform(node: Node3D, ref: Variant, _apply_model_rotation: bool) -> void:
	# Position conversion via CoordinateSystem (outputs in meters)
	node.position = CS.vector_to_godot(ref.position)
	node.scale = CS.scale_to_godot(ref.scale)

	# Rotation conversion via CoordinateSystem
	# Uses esm_rotation_to_godot_basis() which matches OpenMW's makeOsgQuat
	node.basis = CS.esm_rotation_to_godot_basis(ref.rotation)


## Apply metadata to an object for console object picker identification
# PHASE_A:WORKER_SAFE — set_meta on a detached node. Plan §5 row 350-351.
func _apply_metadata(node: Node3D, ref: Variant, base_record: Variant, model_path: String, type_name: String = "") -> void:
	# Form ID / record ID
	if "record_id" in base_record:
		node.set_meta("form_id", base_record.record_id)

	# Model path
	if not model_path.is_empty():
		node.set_meta("model_path", model_path)

	# Reference info
	node.set_meta("ref_id", str(ref.ref_id))
	node.set_meta("ref_num", ref.ref_num)

	# Record type - use the adapter-resolved type_name string (Phase 4)
	var record_type := _type_name_to_meta(type_name)
	node.set_meta("record_type", record_type)

	# Instance ID (unique per cell)
	node.set_meta("instance_id", ref.ref_num)


func _apply_record_metadata(node: Node3D, record: RefCounted, model_path: String, type_name: String = "") -> void:
	var record_id := str(record.get("record_id"))
	if not record_id.is_empty():
		node.set_meta("form_id", record_id)
	if not model_path.is_empty():
		node.set_meta("model_path", model_path)
	node.set_meta("object_id", str(record.get("object_id")))
	var source_ref_id := str(record.get("source_ref_id"))
	node.set_meta("source_ref_id", source_ref_id)
	if not source_ref_id.is_empty():
		node.set_meta("ref_id", source_ref_id)
	var ref_num := _record_ref_num(record)
	if ref_num != 0:
		node.set_meta("ref_num", ref_num)
		node.set_meta("instance_id", ref_num)
	node.set_meta("source_type", type_name)
	node.set_meta("record_type", _type_name_to_meta(type_name))
	node.set_meta("cell_grid", record.get("cell_grid"))


## Convert internal type_name string to ESM record type code for metadata (Phase 4)
# PHASE_A:WORKER_SAFE — pure string match.
static func _type_name_to_meta(type_name: String) -> String:
	match type_name:
		"static": return "STAT"
		"activator": return "ACTI"
		"container": return "CONT"
		"door": return "DOOR"
		"light": return "LIGH"
		"npc": return "NPC_"
		"creature": return "CREA"
		"misc": return "MISC"
		"weapon": return "WEAP"
		"armor": return "ARMO"
		"clothing": return "CLOT"
		"book": return "BOOK"
		"ingredient": return "INGR"
		"apparatus": return "APPA"
		"potion": return "ALCH"
		_: return "UNKNOWN"


## Get the model path from a base record
# PHASE_A:WORKER_SAFE — pure Variant property read.
func _get_model_path(record: Variant) -> String:
	if "model" in record and record.model:
		return record.model
	return ""


func _create_placeholder_for_record(record: RefCounted) -> Node3D:
	var placeholder := MeshInstance3D.new()
	placeholder.name = str(record.get("object_id")) + "_placeholder"
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 1.8, 0.5)
	placeholder.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.0, 1.0)
	placeholder.material_override = mat
	placeholder.transform = _record_transform(record)
	stats["objects_failed"] += 1
	return placeholder


## Check if a model should use StaticObjectRenderer (fast flora/rock rendering)
## Kept as a fallback for the T.1 routing gate (covers flora + small-rock
## patterns explicitly). The broader `_should_route_to_renderer` is the
## primary routing decision post-statics_no_node3d migration.
# PHASE_A:WORKER_SAFE — pure string ops.
func _is_static_render_model(model_path: String) -> bool:
	var lower := model_path.to_lower()

	# Flora - grass, kelp, flowers, ferns (visual only, no interaction)
	if "flora_" in lower:
		# Exclude trees (need collision) and harvestable plants
		if "tree" in lower:
			return false
		if "comberry" in lower or "marshmerrow" in lower or "wickwheat" in lower:
			return false  # Harvestable
		return true

	# Small rocks (purely decorative)
	if "rock_" in lower and "_small" in lower:
		return true

	return false


## Check if a ref type qualifies for the lazy-spawn distance gate.
## Interactive refs whose instantiate cost is dominated by PackedScene.instantiate
## (~12-20 ms per container/door/activator per [inst-breakdown] measurement).
## Actors (npc/creature) already use `max_actor_distance` at line ~195, separate path.
# PHASE_A:WORKER_SAFE — pure match on inputs.
func _is_proximity_gated(type_name: String, is_carryable: bool) -> bool:
	if is_carryable:
		return true
	match type_name:
		"door", "activator", "container":
			return true
	return false


## Win 4a — return true when the light should be deferred (skipped this call,
## re-queued when camera approaches via cell_manager.tick_proximity_deferred).
##
## False = spawn now. Big lights (radius >= LIGHT_ALWAYS_SPAWN_RADIUS_MW)
## always spawn so braziers / large sconces never disappear at distance.
## Small lights only spawn when camera is within LIGHT_PROXIMITY_THRESHOLD_M.
##
## Reads `camera_position` (main-thread updated by streaming manager each frame).
# PHASE_A:MAIN_ONLY — reads `camera_position`.


## Route decision for statics_no_node3d T.1 — return true if the ref should
## render via RS.instance_create2 (MultiMesh) instead of Node3D.
##
## True when ALL of:
## - renderer available + effective_use_static on
## - NOT carryable (pickup physics requires RigidBody3D)
## - NOT interactive type (door/activator/container/light — need Node3D lifecycle)
## - NOT animated (AnimationPlayer requires per-instance state, can't ride MultiMesh)
## - type is STAT or matches legacy flora/small-rock pattern
##
## Interior pockets already self-carve via `effective_use_static == false`
## (LoadProfile override in cell_manager for interior loads).
# PHASE_A:MAIN_ONLY — reads static_renderer singleton + calls
# model_loader.has_animation (cache-accessing method).
func _should_route_to_renderer(
	type_name: String,
	model_path: String,
	is_carryable: bool,
	effective_use_static: bool,
) -> bool:
	if not effective_use_static:
		return false  # interior pocket carve-out (§5.3)
	if static_renderer == null:
		return false
	if is_carryable:
		return false

	# Interactive types always stay on Node3D path
	match type_name:
		"door", "activator", "container":
			return false

	# Animated statics (flags, banners, rotating objects) need AnimationPlayer.
	# Check via model_loader's per-prototype cache (one-time instantiate per
	# unique model_path, reused across all refs). ~500 prototypes vs ~316k refs.
	if model_loader != null and model_loader.has_method("has_animation"):
		if model_loader.call("has_animation", model_path):
			return false

	# STAT — the ~80% case. MW architecture, rocks, clutter, containers-without-loot, etc.
	if type_name == "static":
		return true

	# Legacy flora + small-rock heuristic (covers some "misc" type refs that are really just clutter).
	return _is_static_render_model(model_path)


## Hide materialless meshes in a scene tree (LOD nodes are kept visible)
## Uses centralized MeshVisibilityUtils for consistent behavior across the codebase
# PHASE_A:WORKER_SAFE — pure property writes on detached subtree. Plan §5 row 345.
func _hide_lod_nodes(node: Node) -> void:
	MeshVisibilityUtils.hide_lod_and_materialless(node, debug_lod)


## Reset statistics
func reset_stats() -> void:
	stats = {
		"objects_instantiated": 0,
		"objects_failed": 0,
		"objects_from_pool": 0,
		"lights_created": 0,
		"npcs_loaded": 0,
		"creatures_loaded": 0,
		"static_renderer_instances": 0,
		"visual_proxies_created": 0,
		"significant_objects_registered": 0,
	}
	_route_usage_stats = {
		"world_object_id_calls": 0,
		"world_object_record_calls": 0,
		"world_object_static_record_calls": 0,
		"world_object_node_record_calls": 0,
	}


## Get current statistics
func get_stats() -> Dictionary:
	var result := stats.duplicate()
	result["route_usage"] = _route_usage_stats.duplicate()
	return result


func get_route_usage_stats() -> Dictionary:
	return _route_usage_stats.duplicate()


func _increment_route_usage_stat(key: String) -> void:
	_route_usage_stats[key] = int(_route_usage_stats.get(key, 0)) + 1
