## Cell Manager - Loads and instantiates Morrowind cells in Godot
## Handles loading cells and placing provider-supplied model objects
## Ported from OpenMW apps/openmw/mwworld/cellstore.cpp and scene.cpp
##
## Supports both synchronous and asynchronous cell loading:
## - load_exterior_cell() / load_cell() - Synchronous, blocks until complete
## - request_cell_async() - Async, uses BackgroundProcessor for source-model parsing
##
## Phase 2 Refactoring: Uses ReferenceInstantiator for object creation (SRP)
class_name CellManager
extends RefCounted

# Preload coordinate utilities
const CS := preload("res://src/core/coordinate_system.gd")
const ModelLoader := preload("res://src/core/world/model_loader.gd")
const ReferenceInstantiator := preload("res://src/core/world/reference_instantiator.gd")
const ObjectPoolScript := preload("res://src/core/world/object_pool.gd")
const StaticObjectRendererScript := preload("res://src/core/world/static_object_renderer.gd")
const CharacterFactoryV2 := preload("res://src/core/animation/character_factory_v2.gd")
const MeshVisibilityUtils := preload("res://src/core/world/mesh_visibility_utils.gd")
const StreamingPolicyScript := preload("res://src/core/world/streaming_policy.gd")
const CellPayloadScript := preload("res://src/core/world/cell_payload.gd")
const DU := preload("res://src/core/world/distance_utils.gd")
const StaticShapeCacheScript := preload("res://src/core/world/static_shape_cache.gd")
const CellStaticCollisionScript := preload("res://src/core/world/cell_static_collision.gd")
const CarryableRegistryScript := preload("res://src/core/interaction/carryable_registry.gd")
const WorldObjectRecordScript := preload("res://src/core/world/world_object_record.gd")
const WorldCellManifestScript := preload("res://src/core/world/world_cell_manifest.gd")
const WorldSpaceHandleScript := preload("res://src/core/world/transition/world_space_handle.gd")
# Model loader for source-model loading and caching
var _model_loader: ModelLoader = ModelLoader.new()

# Reference instantiator for creating Node3D objects from cell references
var _instantiator: ReferenceInstantiator = ReferenceInstantiator.new()

# Character factory for creating animated NPCs and creatures
# Use V2 factory for new animation system with IK, procedural animation, and LOD
var _character_factory: CharacterFactoryV2 = CharacterFactoryV2.new()
var enable_npc_wander: bool = true  # NPCs wander near spawn points

# Object pool for frequently used models
var _object_pool: RefCounted = null  # ObjectPool

# Static object renderer for fast flora rendering (uses RenderingServer directly)
var _static_renderer: Node = null  # StaticObjectRenderer

# Phase 4 / statics_no_node3d T.2 — per-cell merged trimesh collision. Restores
# physics collision that was dropped when statics moved to RS-direct rendering
# (no Node3D → no StaticBody3D). One StaticBody3D + one ConcavePolygonShape3D
# per cell, parented to the cell_node so unload cascades cleanly.
var _static_shape_cache: StaticShapeCacheScript = StaticShapeCacheScript.new()
var _cell_static_collision: CellStaticCollisionScript = CellStaticCollisionScript.new()
var _world_object_source: RefCounted = null
var _world_object_spawn_adapter: RefCounted = null
var _asset_provider: RefCounted = null
var _impostor_candidates: RefCounted = null
const MAX_LIFECYCLE_EVENTS := 256
var debug_lifecycle_capture_enabled: bool = false
var _lifecycle_events: Array[Dictionary] = []
var _lifecycle_event_write_index: int = 0

# MID-tier batch pool removed — StaticObjectRenderer now handles MID with per-instance LOD

# Statistics (instantiation stats now in ReferenceInstantiator, model stats in ModelLoader)
var _stats: Dictionary = {
	"multimesh_instances": 0,
	"objects_instantiated": 0,
	"lights_created": 0,
	"objects_from_pool": 0,
}

var _route_usage_stats: Dictionary = {
	"world_manifest_lookups": 0,
	"world_manifest_hits": 0,
	"async_world_manifest_requests": 0,
	"async_world_manifest_interior_requests": 0,
	"sync_world_manifest_exterior_cells": 0,
	"sync_world_manifest_interior_cells": 0,
	"metadata_world_manifest_exterior_cells": 0,
	"character_world_manifest_cells": 0,
}

# Configuration
var create_lights: bool = true   # Whether to create OmniLight3D for light refs
var load_lights: bool = true:    # Whether to load light refs at all (model + OmniLight3D). A/B gate.
	set(value):
		load_lights = value
		_sync_instantiator_config()
var load_npcs: bool = true:      # Whether to load NPC models
	set(value):
		load_npcs = value
		_sync_instantiator_config()
var load_creatures: bool = true: # Whether to load creature models
	set(value):
		load_creatures = value
		_sync_instantiator_config()
var use_object_pool: bool = true # Whether to use object pooling for common models
var use_static_renderer: bool = true:  # Use RenderingServer for flora (much faster)
	set(value):
		use_static_renderer = value
		_sync_instantiator_config()
var use_multimesh_instancing: bool = true  # Use MultiMesh for batching identical objects
var min_instances_for_multimesh: int = 10  # Minimum instances to use MultiMesh instead of individual nodes

# Pool pre-warming: fraction of max pool size to pre-create during preload
const POOL_PREWARM_RATIO: float = 0.2
# Pool pre-warming: minimum instances to pre-create per model
const POOL_PREWARM_MIN_COUNT: int = 10
# Default maximum pool size when auto-registering models
const DEFAULT_POOL_MAX_SIZE: int = 50

# Phase A off-thread PackedScene.instantiate is parked. The implementation
# remains compiled out until an isolated Godot 4.6 harness proves the pattern
# safe; production publishing stays on the main-thread path.
const PHASE_A_OFFTHREAD_INSTANTIATE: bool = false


## Initialize instantiator with current configuration and dependencies
func _init() -> void:
	_sync_instantiator_config()
	# Phase 4 / T.2 — wire static-shape cache and collision builder.
	# _static_shape_cache needs the model_loader to miss-fill on first query;
	# _cell_static_collision pulls shape entries from the cache + classifies
	# refs via the instantiator (exact mirror of Phase F's static routing).
	_static_shape_cache.set_model_loader(_model_loader)
	_cell_static_collision.configure(_static_shape_cache)
	# T.6 — expose the same shape cache to Phase F so the worker can warm
	# `.shapes.res` sidecars off-thread before cell_static_collision asks for
	# them at cell-activation time. Keeps CellManager as the single owner of
	# the shape cache lifetime (mirrors the static_renderer/model_loader wiring).


func set_world_object_source(source: RefCounted) -> void:
	_world_object_source = source
	if _instantiator and _instantiator.has_method("set_world_object_source"):
		_instantiator.call("set_world_object_source", source)


func set_world_object_spawn_adapter(adapter: RefCounted) -> void:
	_world_object_spawn_adapter = adapter
	if _instantiator and _instantiator.has_method("set_world_object_spawn_adapter"):
		_instantiator.call("set_world_object_spawn_adapter", adapter)


func set_impostor_candidates(candidates: RefCounted) -> void:
	_impostor_candidates = candidates
	if _instantiator and _instantiator.has_method("set_impostor_candidates"):
		_instantiator.call("set_impostor_candidates", candidates)


func set_asset_provider(provider: RefCounted) -> void:
	_asset_provider = provider
	if _model_loader and _model_loader.has_method("set_asset_provider"):
		_model_loader.call("set_asset_provider", provider)


func set_static_renderer(renderer: Node) -> void:
	_static_renderer = renderer
	_sync_instantiator_config()


func get_model_loader() -> ModelLoader:
	return _model_loader


func get_instantiator() -> ReferenceInstantiator:
	return _instantiator


func is_model_loader_runtime_mode() -> bool:
	return _model_loader != null and _model_loader.runtime_mode


func prewarm_model_cache_index() -> int:
	if _model_loader == null:
		return 0
	return _model_loader.prewarm_disk_cache_index()


func set_world_source(source: RefCounted) -> void:
	if source == null:
		set_world_object_source(null)
		set_world_object_spawn_adapter(null)
		set_asset_provider(null)
		set_impostor_candidates(null)
		return
	if source.has_method("get_object_source"):
		set_world_object_source(source.call("get_object_source") as RefCounted)
	if source.has_method("get_object_spawn_adapter"):
		set_world_object_spawn_adapter(source.call("get_object_spawn_adapter") as RefCounted)
	if source.has_method("get_asset_provider"):
		set_asset_provider(source.call("get_asset_provider") as RefCounted)
	if source.has_method("get_impostor_candidates"):
		set_impostor_candidates(source.call("get_impostor_candidates") as RefCounted)


func _get_world_cell_manifest(grid: Vector2i) -> Variant:
	if _world_object_source == null or not _world_object_source.has_method("get_cell_manifest"):
		return null
	_increment_route_usage_stat("world_manifest_lookups")
	var manifest: Variant = _world_object_source.call("get_cell_manifest", grid)
	if manifest != null:
		_increment_route_usage_stat("world_manifest_hits")
	return manifest


func _get_world_space_manifest(space_handle: RefCounted) -> Variant:
	if _world_object_source == null or not _world_object_source.has_method("get_space_manifest"):
		return null
	_increment_route_usage_stat("world_manifest_lookups")
	var manifest: Variant = _world_object_source.call("get_space_manifest", space_handle)
	if manifest != null:
		_increment_route_usage_stat("world_manifest_hits")
	return manifest


func _get_interior_world_cell_manifest(cell_name: String) -> Variant:
	return _get_world_space_manifest(WorldSpaceHandleScript.interior(cell_name))


func _increment_route_usage_stat(key: String) -> void:
	_route_usage_stats[key] = int(_route_usage_stats.get(key, 0)) + 1


func _resolve_source_reference_base_record(source_ref: Variant, record_type_out: Array) -> Variant:
	if _world_object_spawn_adapter == null:
		Log.error("streaming", "CellManager has no WorldObjectSpawnAdapter for source ref")
		return null
	if not _world_object_spawn_adapter.has_method("resolve_source_reference_base_record"):
		Log.error("streaming", "WorldObjectSpawnAdapter cannot resolve source ref")
		return null
	return _world_object_spawn_adapter.call("resolve_source_reference_base_record", source_ref, record_type_out)


func _make_pending_payload(
	ref: Variant,
	base_record: Variant,
	type_name: String,
	item_id: String,
	cache_item_id: String,
	object_id: StringName = &"",
) -> Dictionary:
	return {
		"ref": ref,
		"base_record": base_record,
		"type_name": type_name,
		"item_id": item_id,
		"cache_item_id": cache_item_id,
		"object_id": object_id,
	}


func _make_pending_record_payload(
	record: RefCounted,
	type_name: String,
	item_id: String,
	cache_item_id: String,
	static_only: bool = false,
) -> Dictionary:
	return {
		"record": record,
		"type_name": type_name,
		"item_id": item_id,
		"cache_item_id": cache_item_id,
		"static_only": static_only,
	}


func _make_payload_record_from_ref(
	ref: Variant,
	type_name: String,
	model_path: String,
	item_id: String,
	cache_item_id: String,
	static_route: bool,
	cell_grid: Vector2i,
	base_record: Variant = null,
) -> RefCounted:
	if _world_object_spawn_adapter != null \
			and _world_object_spawn_adapter.has_method("make_world_object_record_from_source_reference"):
		var adapter_record: RefCounted = _world_object_spawn_adapter.call(
			"make_world_object_record_from_source_reference",
			ref,
			base_record,
			type_name,
			model_path,
			item_id,
			cache_item_id,
			static_route,
			cell_grid
		) as RefCounted
		if adapter_record != null:
			return adapter_record
	var record: RefCounted = WorldObjectRecordScript.new()
	var ref_id := str(ref.ref_id)
	record.object_id = WorldObjectRecordScript.make_object_id(cell_grid, ref_id, int(ref.ref_num))
	record.record_id = StringName(item_id if not item_id.is_empty() else ref_id)
	record.source_ref_id = StringName(ref_id)
	record.source_key = "%s:%s" % [type_name, str(record.object_id)]
	record.cell_grid = cell_grid
	record.transform = _calculate_transform(ref)
	record.model_path = model_path
	record.model_item_id = item_id
	record.cache_item_id = cache_item_id
	record.source_type = StringName(type_name)
	record.category = _category_for_type_name(type_name)
	record.spawn_route = WorldObjectRecordScript.SpawnRoute.STATIC_BATCH if static_route else WorldObjectRecordScript.SpawnRoute.NODE
	record.static_batch_allowed = static_route
	if static_route:
		record.capability_flags = WorldObjectRecordScript.CAP_STATIC_VISUAL | WorldObjectRecordScript.CAP_COLLISION
	else:
		record.capability_flags = WorldObjectRecordScript.CAP_GAMEPLAY if type_name != "static" else WorldObjectRecordScript.CAP_STATIC_VISUAL
	return record


func _instantiate_source_reference_record(
	ref: Variant,
	cell_grid: Vector2i,
	base_record: Variant = null,
	type_name: String = "",
	model_path: String = "",
	item_id: String = "",
	cache_item_id: String = "",
	static_route: bool = false,
) -> Node3D:
	if ref == null:
		return null

	var resolved_base_record: Variant = base_record
	var resolved_type_name := type_name
	if resolved_base_record == null or resolved_type_name.is_empty():
		var record_type: Array = [resolved_type_name]
		resolved_base_record = _resolve_source_reference_base_record(ref, record_type)
		resolved_type_name = record_type[0] if record_type.size() > 0 else resolved_type_name
	if resolved_base_record == null:
		return null

	var resolved_model_path := model_path
	if resolved_model_path.is_empty():
		resolved_model_path = _get_model_path(resolved_base_record)
	var resolved_item_id := item_id
	if resolved_item_id.is_empty() and "record_id" in resolved_base_record:
		resolved_item_id = str(resolved_base_record.record_id)
	var resolved_cache_item_id := cache_item_id if not cache_item_id.is_empty() else resolved_item_id
	var resolved_static_route := static_route
	if not resolved_static_route:
		resolved_static_route = _should_prepare_static_ref(
			resolved_base_record,
			resolved_type_name,
			resolved_model_path,
			null,
			resolved_item_id,
			ref
		)

	var record: RefCounted = _make_payload_record_from_ref(
		ref,
		resolved_type_name,
		resolved_model_path,
		resolved_item_id,
		resolved_cache_item_id,
		resolved_static_route,
		cell_grid,
		resolved_base_record
	)
	if record == null or _instantiator == null:
		return null
	if _instantiator.has_method("instantiate_world_object_record"):
		return _instantiator.call(
			"instantiate_world_object_record",
			record,
			cell_grid,
			resolved_cache_item_id
		) as Node3D
	return null


func _category_for_type_name(type_name: String) -> int:
	match type_name:
		"static":
			return WorldObjectRecordScript.Category.STATIC
		"door":
			return WorldObjectRecordScript.Category.DOOR
		"container":
			return WorldObjectRecordScript.Category.CONTAINER
		"activator":
			return WorldObjectRecordScript.Category.ACTIVATOR
		"light":
			return WorldObjectRecordScript.Category.LIGHT
		"npc":
			return WorldObjectRecordScript.Category.NPC
		"creature", "leveled_creature":
			return WorldObjectRecordScript.Category.CREATURE
		_:
			return WorldObjectRecordScript.Category.OTHER


## Initialize object pool for frequently used models
## parent_node: Node3D to store pooled objects when not in use (required for proper pooling)
func init_object_pool(parent_node: Node3D = null) -> void:
	if _object_pool == null:
		_object_pool = ObjectPoolScript.new()
		# Initialize pool with parent node for storing inactive instances
		# Without this, released objects have no parent and may be garbage collected
		if parent_node:
			_object_pool.call("init", parent_node)
		_sync_instantiator_config()


## Get the object pool (for releasing objects back when unloading cells)
func get_object_pool() -> RefCounted:
	return _object_pool


## Set the mod registry for asset resolution
func set_mod_registry(registry: ModRegistry) -> void:
	if _model_loader:
		_model_loader.set_mod_registry(registry)


## I.7 — Install a callback that receives every DoorInteractable's
## `door_activated` signal. Called by world_explorer after the pocket
## manager is ready so door taps can drive `enter_interior()`.
## Headless / test-scene callers can leave it unset — teleport doors
## still emit their signal but no listener consumes it.
func set_door_activated_handler(handler: Callable) -> void:
	_instantiator.door_activated_handler = handler


func reconnect_door_activated_handlers(root: Node, handler: Callable) -> int:
	if root == null or not handler.is_valid():
		return 0
	var connected := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.has_signal("door_activated") and not node.is_connected(&"door_activated", handler):
			node.connect(&"door_activated", handler)
			connected += 1
		for child: Node in node.get_children():
			stack.push_back(child)
	return connected


# REMOVED: set_object_streamer()
# Native streaming system uses visibility_range, not a separate ObjectStreamer


## Sync configuration to instantiator
func _sync_instantiator_config() -> void:
	# Set up character factory
	_character_factory.set_model_loader(_model_loader)
	_character_factory.enable_wander = enable_npc_wander

	# Configure instantiator
	_instantiator.model_loader = _model_loader
	_instantiator.object_pool = _object_pool
	_instantiator.static_renderer = _static_renderer
	_instantiator.character_factory = _character_factory
	_instantiator.create_lights = create_lights
	_instantiator.load_lights = load_lights
	_instantiator.load_npcs = load_npcs
	_instantiator.load_creatures = load_creatures
	_instantiator.use_object_pool = use_object_pool
	_instantiator.use_static_renderer = use_static_renderer

	# Pass scene tree for fade-in tweens (will be set when first called from a Node)
	var main_loop: MainLoop = Engine.get_main_loop()
	if main_loop is SceneTree:
		_instantiator.scene_tree = main_loop as SceneTree


## Load an interior cell by name and return a Node3D containing all objects
func load_cell(cell_name: String) -> Node3D:
	var manifest: Variant = _get_interior_world_cell_manifest(cell_name)
	if manifest == null:
		push_error("CellManager: Cell not found: '%s'" % cell_name)
		return null

	_increment_route_usage_stat("sync_world_manifest_interior_cells")
	return _instantiate_world_cell_manifest(manifest, Vector2i.ZERO)


## Load an exterior cell by grid coordinates and return a Node3D containing all objects
func load_exterior_cell(x: int, y: int) -> Node3D:
	var cell_grid := Vector2i(x, y)
	var manifest: Variant = _get_world_cell_manifest(cell_grid)
	if manifest != null:
		_increment_route_usage_stat("sync_world_manifest_exterior_cells")
		return _instantiate_world_cell_manifest(manifest, cell_grid)

	push_error("CellManager: Exterior cell not found: %d, %d" % [x, y])
	return null


## Load exterior cell metadata only (no objects) for AAA streaming mode
## Returns an empty Node3D container - terrain is handled separately via Terrain3D
## Objects are streamed by manifest-backed async requests
func load_exterior_cell_metadata_only(x: int, y: int) -> Node3D:
	var cell_grid := Vector2i(x, y)
	var manifest: Variant = _get_world_cell_manifest(cell_grid)
	if manifest != null:
		_increment_route_usage_stat("metadata_world_manifest_exterior_cells")
		var manifest_node := Node3D.new()
		manifest_node.name = "Cell_%d_%d" % [x, y]
		manifest_node.set_meta("world_cell_manifest", manifest)
		manifest_node.set_meta("grid_x", x)
		manifest_node.set_meta("grid_y", y)
		manifest_node.set_meta("aaa_mode", true)
		return manifest_node

	push_error("CellManager: Exterior cell not found: %d, %d" % [x, y])
	return null


## Load only NPCs/creatures into an existing cell node
## Used when toggling NPCs on after cells were loaded without them
func load_characters_into_cell(x: int, y: int, cell_node: Node3D) -> int:
	var cell_grid := Vector2i(x, y)
	var loaded := 0

	# Temporarily enable NPC/creature loading
	var was_loading_npcs := load_npcs
	var was_loading_creatures := load_creatures
	load_npcs = true
	load_creatures = true

	var manifest: Variant = _get_character_load_manifest(cell_grid, cell_node)
	if manifest != null:
		_increment_route_usage_stat("character_world_manifest_cells")
		loaded = _instantiate_character_records_from_manifest(manifest, cell_grid, cell_node)
		load_npcs = was_loading_npcs
		load_creatures = was_loading_creatures
		return loaded

	# Restore original loading settings
	load_npcs = was_loading_npcs
	load_creatures = was_loading_creatures

	return loaded


func _instantiate_world_cell_manifest(manifest: RefCounted, cell_grid: Vector2i) -> Node3D:
	var cell_node := Node3D.new()
	var cell_name := str(manifest.get("cell_name")) if manifest != null else ""
	if cell_name.is_empty():
		cell_node.name = "Cell_%d_%d" % [cell_grid.x, cell_grid.y]
	else:
		cell_node.name = cell_name.replace(" ", "_").replace(",", "")
	cell_node.set_meta("world_cell_manifest", manifest)
	cell_node.set_meta("grid_x", cell_grid.x)
	cell_node.set_meta("grid_y", cell_grid.y)

	var loaded := 0
	var routed_static := 0
	var failed := 0
	for record: RefCounted in manifest.objects:
		var cache_item_id := str(record.get("cache_item_id"))
		var obj: Node3D = null
		if _instantiator != null and _instantiator.has_method("instantiate_world_object_record"):
			obj = _instantiator.call("instantiate_world_object_record", record, cell_grid, cache_item_id) as Node3D
		var route_name := str(_instantiator.get("last_inst_route")) if _instantiator != null else ""
		if obj != null:
			cell_node.add_child(obj)
			loaded += 1
		elif route_name.begins_with("static"):
			routed_static += 1
		else:
			failed += 1

	Log.info("streaming", "CellManager: Loaded manifest cell %s (%d nodes, %d static-routed, %d failed)" % [
		cell_name if not cell_name.is_empty() else str(cell_grid),
		loaded,
		routed_static,
		failed,
	])
	return cell_node


func _get_character_load_manifest(cell_grid: Vector2i, cell_node: Node3D) -> Variant:
	if cell_node != null and cell_node.has_meta("world_cell_manifest"):
		var node_manifest: Variant = cell_node.get_meta("world_cell_manifest")
		if node_manifest != null:
			return node_manifest
	return _get_world_cell_manifest(cell_grid)


func _instantiate_character_records_from_manifest(manifest: Variant, cell_grid: Vector2i, cell_node: Node3D) -> int:
	if manifest == null or not (manifest is Object):
		return 0
	var records_value: Variant = manifest.get("objects")
	if not (records_value is Array):
		return 0

	var loaded := 0
	for record_value: Variant in records_value:
		var record: RefCounted = record_value as RefCounted
		if not _is_character_world_record(record):
			continue
		var cache_item_id := str(record.get("cache_item_id"))
		var obj: Node3D = null
		if _instantiator != null and _instantiator.has_method("instantiate_world_object_record"):
			obj = _instantiator.call("instantiate_world_object_record", record, cell_grid, cache_item_id) as Node3D
		if obj != null:
			_tag_character_cell_child(obj)
			cell_node.add_child(obj)
			loaded += 1
	return loaded


func _is_character_world_record(record: RefCounted) -> bool:
	if record == null:
		return false
	if int(record.get("spawn_route")) == WorldObjectRecordScript.SpawnRoute.ACTOR:
		return true
	match int(record.get("category")):
		WorldObjectRecordScript.Category.NPC, WorldObjectRecordScript.Category.CREATURE:
			return true
	var source_type := str(record.get("source_type"))
	return source_type in ["npc", "creature", "leveled_creature"]


func _tag_character_cell_child(node: Node3D) -> void:
	if node != null:
		node.set_meta("is_character", true)


## Calculate transform for a cell reference
func _calculate_transform(ref: Variant) -> Transform3D:
	var pos := CS.vector_to_godot(ref.position)
	var scale := CS.scale_to_godot(ref.scale)
	var basis := CS.esm_rotation_to_godot_basis(ref.rotation)
	basis = basis.scaled(scale)
	return Transform3D(basis, pos)



## Preload common models into cache to reduce initial loading delays
## Call this during game initialization for smoother first-cell loading
## Also pre-warms the object pool with initial instances for instant acquire()
## Returns number of models successfully preloaded
func preload_common_models() -> int:
	var common_models := ObjectPoolScript.identify_common_models(self)
	var loaded := 0
	var pool_instances := 0

	for model_path: String in common_models:
		# Skip if already cached
		if _model_loader.has_model(model_path):
			continue

		# Skip flora that will use StaticObjectRenderer instead
		if use_static_renderer and _static_renderer and _instantiator._is_static_render_model(model_path):
			continue

		# Try to load the model
		var prototype: Node3D = _model_loader.get_model(model_path)
		if prototype:
			loaded += 1

			# Register with pool AND pre-warm with initial instances
			# Pre-warming means acquire() returns instantly without duplicate()
			# Increased from 50% to 80% for higher cache hit rate (targeting 70%+)
			if _object_pool and not _object_pool.call("has_model", model_path):
				var pool_size: int = common_models[model_path]
				# Pre-create 80% of max pool size for maximum cache hit rate
				# This front-loads the duplicate() cost during preload instead of gameplay
				var initial_count: int = maxi(POOL_PREWARM_MIN_COUNT, int(pool_size * POOL_PREWARM_RATIO))
				_object_pool.call("register_model", model_path, prototype, initial_count, pool_size)
				pool_instances += initial_count

	return loaded


## Preload models asynchronously using the background processor
## Emits preload_complete signal when done
## Returns immediately - check preload_progress for status
signal preload_progress(loaded: int, total: int)
signal preload_complete(loaded: int, failed: int)

var _preload_pending: Dictionary = {}  # model_path -> task_id
var _preload_loaded: int = 0
var _preload_failed: int = 0
var _preload_total: int = 0

func preload_common_models_async() -> void:
	# In runtime mode, load from disk cache only - no source-model parsing
	if _model_loader.runtime_mode:
		var common_models := ObjectPoolScript.identify_common_models(self)
		var loaded := 0
		var skipped := 0

		for model_path: String in common_models:
			# Skip if already in memory cache
			if _model_loader.has_model(model_path):
				continue

			# Try to load from disk cache
			var prototype := _model_loader.get_model(model_path)
			if prototype:
				loaded += 1
			else:
				skipped += 1  # Not prebaked - that's fine

		Log.info("streaming", "CellManager: Preloaded %d models from disk cache (%d not prebaked)" % [loaded, skipped])
		preload_complete.emit(loaded, skipped)
		return

	# PREBAKING MODE: Do async source-model parsing
	if not _background_processor:
		push_warning("CellManager: No background processor, falling back to sync preload")
		preload_common_models()
		return

	var common_models := ObjectPoolScript.identify_common_models(self)
	_preload_loaded = 0
	_preload_failed = 0
	_preload_total = 0
	_preload_pending.clear()

	for model_path: String in common_models:
		# Skip if already cached
		if _model_loader.has_model(model_path):
			continue

		_preload_total += 1

		# Submit parse task
		var task_id := _submit_parse_task(model_path, "", -1)  # -1 = preload, not tied to a cell request
		if task_id >= 0:
			_preload_pending[model_path] = task_id

	if _preload_pending.is_empty():
		preload_complete.emit(0, 0)
		return

	Log.info("streaming", "CellManager: Preloading %d models asynchronously..." % _preload_pending.size())


func _check_preload_completion(task_id: int, result: Variant) -> bool:
	# Check if this task is a preload task
	var model_path := ""
	for path: String in _preload_pending:
		if _preload_pending[path] == task_id:
			model_path = path
			break

	if model_path.is_empty():
		return false  # Not a preload task

	_preload_pending.erase(model_path)

	if _is_provider_parse_result_valid(result):
		var prototype := _create_provider_model_scene_from_parse_result(result)
		if prototype:
			_model_loader.add_to_cache(model_path, prototype, "")
			_preload_loaded += 1

			# Register with pool
			if _object_pool and not _object_pool.call("has_model", model_path):
				var common_models: Dictionary = ObjectPoolScript.identify_common_models(self)
				_object_pool.call("register_model", model_path, prototype, 0, common_models.get(model_path, DEFAULT_POOL_MAX_SIZE))
		else:
			_preload_failed += 1
	else:
		_preload_failed += 1

	preload_progress.emit(_preload_loaded, _preload_total)

	if _preload_pending.is_empty():
		Log.info("streaming", "CellManager: Preload complete - %d loaded, %d failed" % [_preload_loaded, _preload_failed])
		preload_complete.emit(_preload_loaded, _preload_failed)

	return true


# =============================================================================
# ASYNC CELL LOADING API
# =============================================================================
# Uses BackgroundProcessor to parse source models on worker threads.
# The main thread then instantiates from parsed data within time budget.
# =============================================================================

## Maximum concurrent async cell requests (prevents memory buildup)
## Industry standard: 4-8 concurrent operations max to avoid I/O saturation
## Diagnostics show duplicate() is fast (~0.35ms), so we can handle more concurrent requests
const MAX_ASYNC_REQUESTS := 6

## Maximum items in instantiation queue (prevents memory buildup)
## Morrowind cells can have 200+ objects each, 32 cells × 200 = 6400 objects max
const MAX_INSTANTIATION_QUEUE := 8000

## Maximum objects to instantiate per frame (prevents frame spikes)
## With prebaked models (no source conversion), instantiation is very fast (~0.35ms per object)
## Increased from 30 to 50 for faster loading without significant FPS impact
const MAX_INSTANTIATIONS_PER_FRAME := 50

## Enable diagnostic logging for performance analysis
var diagnostic_logging: bool = true

## Diagnostic counters (reset periodically)
var _diag_instantiate_time_total_us: int = 0
var _diag_instantiate_count: int = 0
var _diag_last_log_frame: int = 0

## Per-type breakdown (scientific-approach instrumentation 2026-04-19).
## Answers "inside inst: 60ms, which type_name dominates?" Reset every
## ~5s after a log dump in `_maybe_log_per_type_breakdown`.
var _diag_per_type_time_us: Dictionary[String, int] = {}
var _diag_per_type_count: Dictionary[String, int] = {}
var _diag_per_type_last_log_msec: int = 0

## Proximity-deferred interactives (containers, doors, activators, carryables).
## Each entry mirrors `InstantiationEntry` but lives off the main queue until
## the camera approaches the ref. Re-queued by `tick_proximity_deferred`.
## OpenMW lazy-spawn pattern: Node3D interactives at 12-20 ms/ref don't
## instantiate until gameplay can plausibly interact (< 25 m from camera for
## generic interactives; lights use their wider light threshold).
var _proximity_deferred: Array[InstantiationEntry] = []
## Enforce retry budget so we don't re-queue the entire deferred list every frame.
var _proximity_last_tick_msec: int = 0
const PROXIMITY_TICK_INTERVAL_MSEC: int = 250
const PROXIMITY_REQUEUE_MAX_PER_TICK: int = 4

## Queue for pending source-model conversions (deferred to avoid main thread stall)
## Each entry: {parse_result: Variant, model_path: String, request_id: int, item_id: String}
var _pending_conversions: Array[Dictionary] = []
var _pending_conversion_index: int = 0

## Model disk-request starts staged by classification. Classification records
## refs into the CellPayload, then this queue starts ResourceLoader threaded
## requests under its own budget. This mirrors engine streaming managers: ref
## classification and I/O request submission are separate frame-budgeted lanes.
var _model_request_start_queue: Array[Dictionary] = []
var _model_request_start_queued: Dictionary[String, bool] = {}
var _model_request_start_active: Dictionary[String, bool] = {}

## Maximum conversion time per frame in milliseconds
## NOTE: A single complex model can take 500ms-6s to convert
## We can't interrupt mid-conversion, so this is really just a guide
## The key optimization is doing only ONE conversion per frame
const MAX_CONVERSION_TIME_MS := 50.0  # Allow one conversion to complete

## Maximum conversions per frame - keeps FPS stable even with complex models
const MAX_CONVERSIONS_PER_FRAME := 1

## Maximum retries for failed async requests
const MAX_ASYNC_RETRIES := 2

# =============================================================================
# NEAR TIER BURST LOADING (Aggressive instantiation for critical cells)
# =============================================================================

## Import StreamingConfig for burst loading parameters
const SC := preload("res://src/core/world/streaming_config.gd")

## Whether burst loading is currently active
var _burst_loading_active: bool = false

## Burst loading budget (ms) - higher than normal for faster cell population
var _burst_budget_ms: float = SC.NEAR_BURST_BUDGET_MS

## Burst loading max instantiations per frame
var _burst_max_instantiations: int = SC.NEAR_BURST_MAX_INSTANTIATIONS

## Distance threshold for burst loading (objects closer than this get burst priority)
var _burst_distance: float = SC.NEAR_BURST_DISTANCE



# =============================================================================
# POOL PRE-WARMING
# =============================================================================

## Enable pool pre-warming when objects are discovered near player
var pool_prewarm_enabled: bool = SC.POOL_PREWARM_ENABLED

## Models pending pre-warm: model_path -> count needed
var _prewarm_pending: Dictionary = {}

## Pre-warm budget per frame
var _prewarm_per_frame: int = SC.POOL_PREWARM_MAX_PER_FRAME

## Per-request load configuration that overrides shared instantiator defaults.
##
## Carried on AsyncCellRequest and copied onto each spawned InstantiationEntry
## so that concurrent exterior + interior loads can use different settings
## without stomping on each other's shared state.
##
## Prior to this class, InteriorPocketManager had to mutate _instantiator's
## shared flags during a sync load (ipm.gd:753-774). With async loads the
## same mutation would be read across frames by concurrent exterior
## instantiations — LoadProfile eliminates that race by making the settings
## per-request.
class LoadProfile:
	## Route mid-worthy objects through the RS / static-renderer batching path.
	## Must be OFF for interior pockets — RS instances render at ESM world
	## position and ignore the pocket Y=-500 offset + INTERIOR_RENDER_LAYERS.
	var use_static_renderer: bool = true
	## NPC/creature distance cull from camera. 0.0 disables the check — needed
	## for interior pockets because the camera is at the exterior position
	## during pocket load but interior actors use small cell-local coordinates.
	var max_actor_distance: float = 150.0
	## Priority-lane flag — entries with this set jump to the tail of the
	## instantiation queue (pop_back() = next out) regardless of distance
	## priority. Only set to true during an active interior transition to
	## drain the interior ahead of exterior work.
	var interior_priority: bool = false

	static func exterior_default() -> LoadProfile:
		return LoadProfile.new()

	static func interior_pocket() -> LoadProfile:
		var p := LoadProfile.new()
		p.use_static_renderer = false
		p.max_actor_distance = 0.0
		p.interior_priority = false  # Flipped to true by IPM during transition
		return p


## Async cell request tracking
class AsyncCellRequest:
	var cell_record: Variant
	var grid: Vector2i  # For exterior cells
	var is_interior: bool
	var request_id: int
	var load_profile: LoadProfile = null  # Per-request settings (null -> use exterior defaults)
	var pending_parses: Dictionary[String, int] = {}  # model_path -> task_id
	var parsed_results: Dictionary[String, Variant] = {}  # model_path -> provider parse result
	var uses_world_manifest: bool = false
	var world_objects_to_classify: Array = []  # WorldObjectRecord objects for exterior generic-source classification
	var references_to_process: Array = []  # Pending payload dictionaries awaiting model availability
	var models_to_load: Dictionary = {}  # model_path -> {item_ids: Array}
	var classify_index: int = 0
	var classification_complete: bool = false
	var pending_instantiations: int = 0  # Count of items queued for instantiation
	var payload: CellPayloadScript = null
	var state: int = CellPayloadScript.State.QUEUED_DATA
	var cell_node: Node3D = null  # The cell node being built
	var started: bool = false
	var completed: bool = false
	var failed: bool = false  # Whether the request failed
	var error_message: String = ""  # Error description if failed
	var retry_count: int = 0  # Number of retries attempted
	var failed_models: Array[String] = []  # Models that failed to parse


## Next async request ID
var _next_async_id: int = 1

## Active async requests
var _async_requests: Dictionary[int, AsyncCellRequest] = {}


## Entry in the instantiation queue
class InstantiationEntry:
	var request_id: int
	var ref: Variant
	var world_object_record: RefCounted = null
	var world_object_id: StringName = &""
	var model_path: String
	var item_id: String
	var cache_item_id: String = ""
	var position: Vector3
	var cell_grid: Vector2i = Vector2i.ZERO
	var type_name: String = ""
	## Nearby interactives/lights should publish before distant visual tail work
	## so walk-up gameplay is responsive while the rest of the cell trickles in.
	var player_local_priority: bool = false
	var static_prepare_key: String = ""
	var static_prepare_failed: bool = false
	## Per-entry load profile copied from the owning AsyncCellRequest at queue
	## time. Read during _process_instantiation_queue so that concurrent loads
	## with different profiles don't stomp on each other.
	## Null means "use instantiator defaults" (sync path compatibility).
	var load_profile: LoadProfile = null
	## Mirrored from load_profile.interior_priority for cheap sort access.
	## Flipped to true by InteriorPocketManager when a transition begins so
	## that in-flight interior entries drain ahead of exterior work.
	var interior_priority: bool = false

	# Phase A (off-thread PackedScene.instantiate) — currently unused, wired in
	# slices 3-5. Plan: docs/plans/distant_rendering_2026_04/phase_a_offthread_instantiate.md §3.
	## Detached Node3D produced by the worker (null until worker completes).
	## Main thread reads this ONLY after WorkerThreadPool.is_task_completed
	## returns true — that boundary is the implicit mutex.
	var worker_instance: Node3D = null
	## Set true by the dispatch pass after WorkerThreadPool.add_task succeeds.
	## Guards against re-dispatching the same entry on subsequent frames.
	var worker_dispatched: bool = false
	## Task id returned by WorkerThreadPool.add_task, used by
	## is_task_completed polling (drain pass) and wait_for_task_completion
	## (cancellation pass). -1 means "never dispatched".
	var worker_task_id: int = -1
	## Resolved at dispatch time (main thread, ESMManager is autoload),
	## consumed by the drain pass to avoid a duplicate ESMManager lookup.
	## Plan §3.1 binds these into _worker_instantiate; we also stash them
	## here so the main-thread tail (complete_worker_instantiate) can read
	## them without a second autoload round-trip.
	var phase_a_base_record: Variant = null
	var phase_a_type_name: String = ""

	# Phase E (off-thread STAT precompute) — parallel to Phase A but for STAT
	# refs that route to StaticObjectRenderer. Worker fills
	# `worker_static_precomp` with a PrecomputedInstance; drain publishes via
	# static_renderer.add_instance_precomputed. Plan:
	# docs/plans/distant_rendering_2026_04/phase_e_static_bulk_upload.md §3.1.
	##
	## Typed as Variant to avoid a hard preload dependency on
	## static_object_renderer.gd from this inner class (keeps cell_manager
	## owning its own scope). Runtime guard in drain checks `!= null`.
	var worker_static_precomp: Variant = null
	var worker_static_dispatched: bool = false
	var worker_static_task_id: int = -1


## BackgroundProcessor reference (must be set via set_background_processor)
var _background_processor: Node = null

## Instantiation queue for time-budgeted processing
## Entries include position for distance-priority sorting
var _instantiation_queue: Array[InstantiationEntry] = []

## Static renderer prototype prepare failure cache. The queued work now lives on
## CellPayload and is rotated by NativeStreamingManager through publish_step().
var _static_prepare_failed: Dictionary[String, bool] = {}

## Detached Node3Ds waiting for a budgeted scene-tree attach. This replaces
## bulk call_deferred("add_child") bursts with visible, frame-budgeted work.
## Each entry: {request_id: int, parent: Node3D, child: Node3D}
var _pending_child_attaches: Array[Dictionary] = []
const CHILD_ATTACH_DROP := 0
const CHILD_ATTACH_READY := 1
const CHILD_ATTACH_PAUSED := 2
const CHILD_ATTACH_SLOW_LOG_USEC := 16_000
const STATIC_PREPARE_ENTRY_SKIPPED := 0
const STATIC_PREPARE_ENTRY_PREPARED := 1
const STATIC_PREPARE_ENTRY_RETRY := 2
const STATIC_PREPARE_ENTRY_PAUSED := 3

## Per-frame instantiation timing buckets, keyed by ESM record type. Reset at
## the top of every `process_async_instantiation` call, accumulated as each
## ref publishes, snapshotted by `streaming_benchmark` for CSV per-frame
## columns. `light_modelload` is a sub-slice of `light` — the time spent
## inside `model_loader.get_model()` for the light's model — so the caller
## can split disk/parse cost from `OmniLight3D` construction cost.
##
## Plan: docs/plans/near_streaming_2026_04_28_interactive_spawn.md step 1.
var _frame_inst_door_us: int = 0
var _frame_inst_light_us: int = 0
var _frame_inst_light_modelload_us: int = 0
var _frame_inst_container_us: int = 0
var _frame_inst_activator_us: int = 0
var _frame_inst_static_us: int = 0

## Camera position for distance-based prioritization
var _camera_position: Vector3 = Vector3.ZERO

## Camera forward direction for frustum-aware priority sorting
var _camera_forward: Vector3 = Vector3.FORWARD

## Frame counter for periodic queue re-sorting
var _queue_sort_frame: int = 0
const QUEUE_SORT_INTERVAL: int = 10  # Re-sort every N frames
const QUEUE_SORT_MAX_ITEMS: int = 512

## Parsed model prototypes waiting to be cached (from async results)
var _pending_prototype_cache: Dictionary = {}  # cache_key -> provider parse result

## AABB max dimension cache — avoids recomputing for same model path.
## Maps model_path -> float (max dimension in meters). 0.0 = unknown/no mesh.
## Retained for future use (projected-size metric, interaction reach, etc).
## S.1: AABB-based mid-worthy upgrade moved to prebake; runtime cache kept idle.
var _aabb_cache: Dictionary = {}  # String -> float


## Update camera position for NEAR-tier actor filtering
func set_camera_position(pos: Vector3) -> void:
	_instantiator.camera_position = pos


## Set the background processor to use for async loading
func set_background_processor(processor: Node) -> void:
	if _background_processor:
		var task_completed_signal: Signal = _background_processor.get("task_completed")
		if task_completed_signal and task_completed_signal.is_connected(_on_parse_completed):
			task_completed_signal.disconnect(_on_parse_completed)

	_background_processor = processor

	if _background_processor:
		var task_completed_signal: Signal = _background_processor.get("task_completed")
		if task_completed_signal:
			task_completed_signal.connect(_on_parse_completed)


## Check if there's capacity for more async requests
## Use this before calling request_exterior_cell_async to avoid fallback to sync
func has_async_capacity() -> bool:
	return _background_processor != null and _get_active_async_load_slot_count() < MAX_ASYNC_REQUESTS


## Set the interior_priority flag on all in-flight instantiation entries for
## the given async request. Called by InteriorPocketManager at the start of
## a transition so that the interior drains ahead of exterior streaming. A
## subsequent force_queue_resort() push the flagged entries to the tail.
func set_request_priority(request_id: int, priority: bool) -> void:
	if request_id in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]
		if request and request.load_profile:
			request.load_profile.interior_priority = priority
	for entry: InstantiationEntry in _instantiation_queue:
		if entry.request_id == request_id:
			entry.interior_priority = priority
			if entry.load_profile:
				entry.load_profile.interior_priority = priority


## Force an immediate queue re-sort. Use after mutating priority flags so
## the new order takes effect on the next _process_instantiation_queue pass.
func force_queue_resort() -> void:
	_sort_queue_by_priority()
	_sort_model_request_start_queue_by_priority()
	_queue_sort_frame = Engine.get_frames_drawn()


## Get the number of available async request slots
func get_async_slots_available() -> int:
	if not _background_processor:
		return 0
	return maxi(0, MAX_ASYNC_REQUESTS - _get_active_async_load_slot_count())


func _get_active_async_load_slot_count() -> int:
	var count := 0
	for request_id: int in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]
		if request == null:
			continue
		if not _is_request_visual_playable(request):
			count += 1
	return count


func _request_has_interior_priority(request_id: int) -> bool:
	if request_id not in _async_requests:
		return false
	var request: AsyncCellRequest = _async_requests[request_id]
	return request != null and request.load_profile != null and request.load_profile.interior_priority


func _has_interior_priority_request() -> bool:
	for request_id: int in _async_requests:
		if _request_has_interior_priority(request_id):
			return true
	return false


func _is_request_visual_playable(request: AsyncCellRequest) -> bool:
	if request == null:
		return true
	if request.completed:
		return true
	if not is_instance_valid(request.cell_node):
		return false
	if not request.classification_complete:
		return false
	if not request.pending_parses.is_empty():
		return false
	if _get_pending_model_load_count_for_request(request) > 0:
		return false
	if request.payload != null and request.payload.get_static_prepare_queue_size() > 0:
		return false
	if not request.references_to_process.is_empty():
		return false
	return true


func _should_prepare_static_ref(
	base_record: Variant,
	type_name: String,
	model_path: String,
	profile: LoadProfile,
	item_id: String = "",
	ref: Variant = null,
) -> bool:
	if _instantiator == null or _static_renderer == null:
		return false
	if model_path.is_empty():
		return false
	var effective_use_static: bool = use_static_renderer
	if profile != null:
		effective_use_static = profile.use_static_renderer
	if not effective_use_static:
		return false
	if CarryableRegistryScript.is_carryable(type_name, base_record):
		return false
	match type_name:
		"door", "activator", "container", "light":
			return false
	if type_name != "static" and not _instantiator._is_static_render_model(model_path):
		return false
	var cached_max_dim := _get_cached_model_max_dimension(model_path, item_id)
	if cached_max_dim > 0.0:
		return _is_model_dimension_mid_worthy(cached_max_dim, ref)
	if StreamingPolicyScript.is_mid_worthy(type_name, model_path):
		return true
	return false


func _is_model_dimension_mid_worthy(max_dim: float, ref: Variant = null) -> bool:
	var scale_max := 1.0
	if ref != null:
		var scale := CS.scale_to_godot(ref.scale)
		scale_max = maxf(absf(scale.x), maxf(absf(scale.y), absf(scale.z)))
	var scaled_max_dim := max_dim * maxf(scale_max, 0.001)
	if scaled_max_dim >= SC.AABB_MID_WORTHY_THRESHOLD:
		return true
	var radius := scaled_max_dim * 0.5
	return radius * radius >= DU.NEAR_END * DU.NEAR_END * DU.PAGING_MIN_SIZE_SQ


func _should_prepare_static_record(record: RefCounted, model_path: String, profile: LoadProfile, item_id: String = "") -> bool:
	if record == null or _instantiator == null or _static_renderer == null:
		return false
	if model_path.is_empty():
		return false
	if not bool(record.get("static_batch_allowed")):
		return false
	var effective_use_static: bool = use_static_renderer
	if profile != null:
		effective_use_static = profile.use_static_renderer
	if not effective_use_static:
		return false
	if not _instantiator._is_static_render_model(model_path):
		return false
	var cached_max_dim := _get_cached_model_max_dimension(model_path, item_id)
	if cached_max_dim > 0.0:
		return _is_model_dimension_mid_worthy_for_record(cached_max_dim, record)
	var source_type := str(record.get("source_type"))
	if source_type.is_empty():
		source_type = _type_name_for_record(record)
	return StreamingPolicyScript.is_mid_worthy(source_type, model_path)


func _is_model_dimension_mid_worthy_for_record(max_dim: float, record: RefCounted) -> bool:
	var scale_max := 1.0
	if record != null:
		var transform_value: Variant = record.get("transform")
		if transform_value is Transform3D:
			var basis: Basis = (transform_value as Transform3D).basis
			scale_max = maxf(
				basis.x.length(),
				maxf(basis.y.length(), basis.z.length()),
			)
	var scaled_max_dim := max_dim * maxf(scale_max, 0.001)
	if scaled_max_dim >= SC.AABB_MID_WORTHY_THRESHOLD:
		return true
	var radius := scaled_max_dim * 0.5
	return radius * radius >= DU.NEAR_END * DU.NEAR_END * DU.PAGING_MIN_SIZE_SQ


func _get_cached_model_max_dimension(model_path: String, item_id: String = "") -> float:
	var normalized := model_path.to_lower().replace("/", "\\")
	if normalized.is_empty():
		return 0.0
	if normalized in _aabb_cache:
		return float(_aabb_cache[normalized])
	if _static_renderer != null and bool(_static_renderer.call("has_type", normalized)):
		var renderer_aabb: AABB = _static_renderer.call("get_mesh_aabb", normalized)
		var renderer_max := _aabb_max_dimension(renderer_aabb)
		if renderer_max > 0.0:
			_aabb_cache[normalized] = renderer_max
			return renderer_max
	if _model_loader == null or not _model_loader.has_model(model_path, item_id):
		return 0.0
	var packed_scene: PackedScene = _model_loader.get_cached_packed_scene(model_path, item_id)
	if packed_scene == null:
		return 0.0
	var scene_aabb := _estimate_packed_scene_aabb(packed_scene)
	var scene_max := _aabb_max_dimension(scene_aabb)
	if scene_max > 0.0:
		_aabb_cache[normalized] = scene_max
	return scene_max


func _estimate_packed_scene_aabb(packed_scene: PackedScene) -> AABB:
	var state := packed_scene.get_state()
	if state == null:
		return AABB()
	var transforms: Dictionary[String, Transform3D] = {".": Transform3D.IDENTITY}
	var merged := AABB()
	var has_aabb := false
	for node_index in range(state.get_node_count()):
		var path := str(state.get_node_path(node_index, false))
		var parent_path := str(state.get_node_path(node_index, true))
		var parent_transform: Transform3D = transforms.get(parent_path, Transform3D.IDENTITY)
		var local_transform := Transform3D.IDENTITY
		var mesh: Mesh = null
		for property_index in range(state.get_node_property_count(node_index)):
			var property_name := String(state.get_node_property_name(node_index, property_index))
			var property_value: Variant = state.get_node_property_value(node_index, property_index)
			if property_name == "transform" and property_value is Transform3D:
				local_transform = property_value
			elif property_name == "mesh" and property_value is Mesh:
				mesh = property_value
		var world_transform := parent_transform * local_transform
		transforms[path] = world_transform
		if state.get_node_type(node_index) != &"MeshInstance3D" or mesh == null or not is_instance_valid(mesh):
			continue
		var mesh_aabb := world_transform * mesh.get_aabb()
		merged = mesh_aabb if not has_aabb else merged.merge(mesh_aabb)
		has_aabb = true
	return merged if has_aabb else AABB()


static func _aabb_max_dimension(aabb: AABB) -> float:
	if aabb.size == Vector3.ZERO:
		return 0.0
	return maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))


func _get_static_expected_count_for_request(request_id: int, model_path: String, item_id: String) -> int:
	if request_id not in _async_requests:
		return 0
	var request: AsyncCellRequest = _async_requests[request_id]
	if request == null or request.payload == null:
		return 0
	var payload_key := CellPayloadScript.make_model_key(model_path, item_id)
	return int(request.payload.static_expected_counts.get(payload_key, 0))


func _sum_static_expected_count_for_type(type_name: String) -> int:
	var total := 0
	for request_id: int in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]
		if request == null or request.payload == null:
			continue
		for key_variant: Variant in request.payload.static_expected_counts.keys():
			var payload_key := str(key_variant)
			if payload_key == type_name or payload_key.begins_with(type_name + ":"):
				total += int(request.payload.static_expected_counts[payload_key])
	return total


func _enqueue_static_prepare(request_id: int, model_path: String, item_id: String = "") -> void:
	if not SC.STATIC_PREPARE_ENABLED:
		return
	if _static_renderer == null or _model_loader == null:
		return
	if model_path.is_empty():
		return
	if request_id not in _async_requests:
		return
	var request: AsyncCellRequest = _async_requests[request_id]
	if request == null or request.payload == null:
		return
	var normalized := model_path.to_lower().replace("/", "\\")
	var expected_count := _get_static_expected_count_for_request(request_id, model_path, item_id)
	var type_registered := bool(_static_renderer.call("has_type", normalized))
	if type_registered and expected_count <= 0:
		return
	if bool(_static_prepare_failed.get(normalized, false)):
		return
	var queue_key := ("%d:%s" % [request_id, normalized]) if type_registered else normalized
	var enqueued := request.payload.enqueue_static_prepare(
		request_id,
		normalized,
		model_path,
		item_id,
		queue_key,
		expected_count,
	)
	if enqueued:
		_mark_request_visual_publishing(request)


func _pin_payload_cached_scene(request: AsyncCellRequest, model_path: String, item_id: String) -> void:
	if request == null or request.payload == null or _model_loader == null:
		return
	var key := CellPayloadScript.make_model_key(model_path, item_id)
	var already_pinned := request.payload.resource_refs_by_key.has(key)
	if _model_loader.has_method("get_cached_resource_handle"):
		var handle: RefCounted = _model_loader.call("get_cached_resource_handle", model_path, item_id) as RefCounted
		if handle != null:
			request.payload.pin_model_handle(model_path, item_id, handle)
			if not already_pinned and _model_loader.has_method("pin_cached_model"):
				_model_loader.call("pin_cached_model", model_path, item_id, _cache_pin_owner_for_request(request.request_id))
			return
	var packed_scene: PackedScene = _model_loader.get_cached_packed_scene(model_path, item_id)
	if packed_scene != null:
		request.payload.pin_model_resource(model_path, item_id, packed_scene)
		if not already_pinned and _model_loader.has_method("pin_cached_model"):
			_model_loader.call("pin_cached_model", model_path, item_id, _cache_pin_owner_for_request(request.request_id))


func _cache_pin_owner_for_request(request_id: int) -> String:
	return "cell_request:%d" % request_id


func _unpin_payload_cached_scenes(request: AsyncCellRequest) -> void:
	if request == null or _model_loader == null:
		return
	if _model_loader.has_method("unpin_cache_owner"):
		_model_loader.call("unpin_cache_owner", _cache_pin_owner_for_request(request.request_id))
	if request.payload != null and request.payload.has_method("release_resource_handles"):
		request.payload.release_resource_handles()


func _restore_payload_cached_scene(request: AsyncCellRequest, model_path: String, item_id: String) -> void:
	if request == null or request.payload == null or _model_loader == null:
		return
	request.payload.restore_model_resource(_model_loader, model_path, item_id)


func _get_static_prepare_queue_size() -> int:
	var total := 0
	for request_id: int in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]
		if request != null and request.payload != null:
			total += request.payload.get_static_prepare_queue_size()
	return total


func _discard_all_static_prepare() -> void:
	for request_id: int in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]
		if request != null and request.payload != null:
			_cancel_payload_static_bucket_builds(request)
			request.payload.discard_static_prepare_queue()


func _mark_request_visual_publishing(request: AsyncCellRequest) -> void:
	if request == null:
		return
	if request.state < CellPayloadScript.State.VISUAL_PUBLISHING:
		request.state = CellPayloadScript.State.VISUAL_PUBLISHING
		if request.payload != null:
			request.payload.state = request.state


func _publish_payload_step(payload: CellPayloadScript, budget_usec: int) -> int:
	if payload == null or budget_usec <= 0:
		return 0

	var start_us := Time.get_ticks_usec()
	var published := _publish_payload_model_callbacks(payload, budget_usec, start_us)
	if not SC.STATIC_PREPARE_ENABLED \
			or payload.get_static_prepare_queue_size() <= 0 \
			or _static_renderer == null \
			or _model_loader == null \
			or SC.STATIC_PREPARE_MAX_PER_FRAME <= 0:
		return published

	var prepared := 0
	var keys := payload.static_prepare_entries_by_key.keys()
	for key_variant: Variant in keys:
		if prepared >= SC.STATIC_PREPARE_MAX_PER_FRAME:
			break
		if Time.get_ticks_usec() - start_us >= budget_usec:
			break
		var key := str(key_variant)
		var entry: Dictionary = payload.pop_static_prepare_entry(key)
		if entry.is_empty():
			continue

		var result := _process_static_prepare_entry(entry, start_us + budget_usec)
		match result:
			STATIC_PREPARE_ENTRY_PREPARED:
				prepared += 1
			STATIC_PREPARE_ENTRY_RETRY:
				payload.requeue_static_prepare_entry(entry)
			STATIC_PREPARE_ENTRY_PAUSED:
				payload.requeue_static_prepare_entry(entry)
			STATIC_PREPARE_ENTRY_SKIPPED:
				var request_id := int(entry.get("request_id", -1))
				if request_id in _async_requests:
					var request: AsyncCellRequest = _async_requests[request_id]
					if request != null and _is_request_complete(request):
						_finalize_request(request)

	return published + prepared


func _publish_payload_model_callbacks(payload: CellPayloadScript, budget_usec: int, start_us: int) -> int:
	var completed := 0
	while payload.get_completed_model_load_count() > 0:
		if Time.get_ticks_usec() - start_us >= budget_usec:
			break
		var completion := payload.pop_model_load_completion()
		if completion.is_empty():
			break
		var request_id := int(completion.get("request_id", -1))
		var model_path := str(completion.get("model_path", ""))
		var item_id := str(completion.get("item_id", ""))
		if request_id not in _async_requests:
			continue
		var request: AsyncCellRequest = _async_requests[request_id]
		if request == null or request.payload != payload:
			continue
		if not is_instance_valid(request.cell_node):
			if _is_request_complete(request):
				request.completed = true
				request.failed = true
				request.error_message = "Cell node freed during disk load"
			continue
		_pin_payload_cached_scene(request, model_path, item_id)
		var waiting_refs: Array = completion.get("waiting_refs", [])
		for ref_info: Dictionary in waiting_refs:
			if bool(ref_info.get("static_only", false)):
				continue
			var record: RefCounted = ref_info.get("record", null) as RefCounted
			var ref: Variant = ref_info.get("ref", null)
			var base_record: Variant = ref_info.get("base_record", null)
			var ref_item_id: String = str(ref_info.get("item_id", ""))
			var cache_item_id: String = ref_info.get("cache_item_id", item_id)
			var type_name: String = str(ref_info.get("type_name", ""))
			var object_id: StringName = ref_info.get("object_id", &"")
			if record != null:
				object_id = _object_id_for_record(record)
			elif ref != null:
				if base_record == null:
					var record_type: Array = [type_name]
					base_record = _resolve_source_reference_base_record(ref, record_type)
					type_name = record_type[0] if record_type.size() > 0 else type_name
				record = _make_payload_record_from_ref(
					ref,
					type_name,
					model_path,
					ref_item_id,
					cache_item_id,
					false,
					request.grid,
					base_record
				)
				object_id = _object_id_for_record(record) if record != null else object_id
			_queue_instantiation(request_id, null if record != null else ref, model_path, ref_item_id, cache_item_id, type_name, object_id, record)
		if _is_request_complete(request):
			_finalize_request(request)
		completed += 1
	return completed


## Drive payload-side publication for every active async request.
##
## NativeStreamingManager owns the frame-budget slice, but CellManager owns
## the request table. Keeping this iteration here prevents interior-only
## requests from starving when no exterior request is present in the streaming
## manager's grid map.
func process_async_payloads(budget_usec: int) -> int:
	if budget_usec <= 0 or _async_requests.is_empty():
		return 0

	var request_ids: Array[int] = []
	for request_id: int in _async_requests:
		request_ids.append(request_id)
	if request_ids.size() > 1 and _has_interior_priority_request():
		request_ids.sort_custom(func(a: int, b: int) -> bool:
			if _request_has_interior_priority(a) != _request_has_interior_priority(b):
				return _request_has_interior_priority(a)
			return a < b
		)

	var start_us := Time.get_ticks_usec()
	var published := 0
	for request_id: int in request_ids:
		if Time.get_ticks_usec() - start_us >= budget_usec:
			break
		if request_id not in _async_requests:
			continue
		var request: AsyncCellRequest = _async_requests[request_id]
		if request == null or request.payload == null:
			continue
		if request.state == CellPayloadScript.State.UNLOADING:
			continue
		var remaining_usec := maxi(0, budget_usec - int(Time.get_ticks_usec() - start_us))
		published += int(request.payload.publish_step(remaining_usec))
	return published


func _process_static_prepare_entry(entry: Dictionary, deadline_usec: int = 0) -> int:
	var request_id := int(entry.get("request_id", -1))
	if request_id not in _async_requests:
		return STATIC_PREPARE_ENTRY_SKIPPED
	var request: AsyncCellRequest = _async_requests[request_id]
	if request == null or request.payload == null:
		return STATIC_PREPARE_ENTRY_SKIPPED
	if not is_instance_valid(request.cell_node):
		return STATIC_PREPARE_ENTRY_SKIPPED
	if _is_request_publish_paused(request):
		return STATIC_PREPARE_ENTRY_PAUSED
	_mark_request_visual_publishing(request)

	var type_name := str(entry.get("type_name", ""))
	var model_path := str(entry.get("model_path", ""))
	var item_id := str(entry.get("item_id", ""))
	if type_name.is_empty() or model_path.is_empty():
		return STATIC_PREPARE_ENTRY_SKIPPED
	if bool(_static_prepare_failed.get(type_name, false)):
		return STATIC_PREPARE_ENTRY_SKIPPED

	var has_registered_type := bool(_static_renderer.call("has_type", type_name))
	var payload_key := CellPayloadScript.make_model_key(model_path, item_id)
	var expected_count := int(request.payload.static_expected_counts.get(payload_key, 0))
	var transforms: Array = request.payload.static_instance_transforms.get(payload_key, [])

	# Static refs are discovered incrementally during classification. Publishing
	# a bucket before that pass completes can freeze a partial transform list,
	# leaving a pickable payload AABB with no matching visual slot for refs
	# discovered later in the same cell.
	if not request.classification_complete:
		return STATIC_PREPARE_ENTRY_RETRY

	# Never sync-load in the prepare lane. Wait until the async disk path has
	# promoted the PackedScene into memory, then instantiate/register.
	if not has_registered_type and not _model_loader.has_model(model_path, item_id):
		return STATIC_PREPARE_ENTRY_RETRY

	var prep_start := Time.get_ticks_usec()
	var reg_us := 0
	if not has_registered_type:
		var packed_scene: PackedScene = _model_loader.get_cached_packed_scene(model_path, item_id)
		if packed_scene == null:
			_static_prepare_failed[type_name] = true
			return STATIC_PREPARE_ENTRY_SKIPPED
		if _model_loader.has_method("get_cached_resource_handle"):
			var handle: RefCounted = _model_loader.call("get_cached_resource_handle", model_path, item_id) as RefCounted
			if handle != null:
				request.payload.pin_model_handle(model_path, item_id, handle)
			else:
				request.payload.pin_model_resource(model_path, item_id, packed_scene)
		else:
			request.payload.pin_model_resource(model_path, item_id, packed_scene)

		var reg_start := Time.get_ticks_usec()
		var registered := false
		if _static_renderer.has_method("request_register_from_packed_scene"):
			var register_status := str(_static_renderer.call("request_register_from_packed_scene", type_name, packed_scene))
			match register_status:
				"ready":
					registered = true
				"pending":
					request.payload.pin_model_resource(model_path, item_id, packed_scene)
					return STATIC_PREPARE_ENTRY_RETRY
				_:
					registered = false
		elif _static_renderer.has_method("register_from_packed_scene"):
			registered = bool(_static_renderer.call("register_from_packed_scene", type_name, packed_scene))
		reg_us = Time.get_ticks_usec() - reg_start
		if not registered:
			_static_prepare_failed[type_name] = true
			return STATIC_PREPARE_ENTRY_SKIPPED

	var batch_us := 0
	var batch_count := 0
	if request.payload.has_static_bucket(payload_key):
		var existing_bucket: RefCounted = request.payload.static_buckets_by_key.get(payload_key) as RefCounted
		var existing_count := int(existing_bucket.get("instance_count")) if existing_bucket != null else 0
		if expected_count > 0 and existing_count != expected_count:
			Log.error("streaming", "[static-prepare-invariant] existing bucket count mismatch after classification grid=%s key=%s expected=%d bucket=%d" % [
				str(request.grid),
				payload_key,
				expected_count,
				existing_count,
			])
			return STATIC_PREPARE_ENTRY_SKIPPED
	else:
		_pin_payload_cached_scene(request, model_path, item_id)
		var resource_handle: RefCounted = request.payload.get_model_handle(model_path, item_id) if request.payload.has_method("get_model_handle") else null
		if not transforms.is_empty() and _static_renderer.has_method("create_cell_bucket_budgeted"):
			var batch_start := Time.get_ticks_usec()
			var build_result: Dictionary = _static_renderer.call(
				"create_cell_bucket_budgeted",
				type_name,
				payload_key,
				transforms,
				request.grid,
				resource_handle,
				deadline_usec
			)
			batch_us = Time.get_ticks_usec() - batch_start
			var build_status := str(build_result.get("status", "failed"))
			if build_status == "pending":
				return STATIC_PREPARE_ENTRY_RETRY
			var bucket: RefCounted = build_result.get("bucket", null) as RefCounted
			if build_status == "ready" and bucket != null:
				var bucket_instances := int(bucket.get("instance_count"))
				if expected_count > 0 and bucket_instances != expected_count:
					Log.warn("streaming", "[static-prepare-invariant] new bucket count mismatch grid=%s key=%s expected=%d bucket=%d reason=%s" % [
						str(request.grid),
						payload_key,
						expected_count,
						bucket_instances,
						str(build_result.get("reason", "")),
					])
					return STATIC_PREPARE_ENTRY_RETRY
				request.payload.add_static_bucket(payload_key, bucket)
				batch_count = transforms.size()
			elif not transforms.is_empty():
				var reason := str(build_result.get("reason", "unknown"))
				var retryable := bool(build_result.get("retryable", false))
				var msg := "[static-prepare-failed] grid=%s key=%s type=%s transforms=%d expected=%d status=%s reason=%s retryable=%s" % [
					str(request.grid),
					payload_key,
					type_name.get_file(),
					transforms.size(),
					expected_count,
					build_status,
					reason,
					"Y" if retryable else "N",
				]
				if retryable:
					Log.warn("streaming", msg)
					return STATIC_PREPARE_ENTRY_RETRY
				Log.error("streaming", msg)
				_static_prepare_failed[type_name] = true
				return STATIC_PREPARE_ENTRY_SKIPPED
		elif not transforms.is_empty() and _static_renderer.has_method("create_cell_bucket"):
			var batch_start := Time.get_ticks_usec()
			var bucket: RefCounted = _static_renderer.call("create_cell_bucket", type_name, payload_key, transforms, request.grid, resource_handle) as RefCounted
			batch_us = Time.get_ticks_usec() - batch_start
			if bucket != null:
				var bucket_instances := int(bucket.get("instance_count"))
				if expected_count > 0 and bucket_instances != expected_count:
					Log.warn("streaming", "[static-prepare-invariant] sync bucket count mismatch grid=%s key=%s expected=%d bucket=%d" % [
						str(request.grid),
						payload_key,
						expected_count,
						bucket_instances,
					])
					if bucket.has_method("cleanup"):
						bucket.call("cleanup")
					return STATIC_PREPARE_ENTRY_RETRY
				request.payload.add_static_bucket(payload_key, bucket)
				batch_count = transforms.size()
			else:
				Log.warn("streaming", "[static-prepare-failed] grid=%s key=%s type=%s transforms=%d expected=%d status=sync_failed retryable=Y" % [
					str(request.grid),
					payload_key,
					type_name.get_file(),
					transforms.size(),
					expected_count,
				])
				return STATIC_PREPARE_ENTRY_RETRY
		elif expected_count > 0:
			Log.warn("streaming", "[static-prepare-invariant] expected static refs but no transforms grid=%s key=%s expected=%d" % [
				str(request.grid),
				payload_key,
				expected_count,
			])
			return STATIC_PREPARE_ENTRY_RETRY

	var total_us := Time.get_ticks_usec() - prep_start
	if total_us > 16_000:
		Log.warn("streaming", "[static-prepare-spike %.1fms] state=%.1f batch=%.1f/%d type=%s key=%s grid=%s queue=%d" % [
			total_us / 1000.0,
			reg_us / 1000.0,
			batch_us / 1000.0,
			batch_count,
			type_name.get_file(),
			payload_key,
			str(request.grid),
			_get_static_prepare_queue_size(),
		])

	if _is_request_complete(request):
		_finalize_request(request)

	return STATIC_PREPARE_ENTRY_PREPARED


func _process_request_classification_queue(budget_usec: int, max_refs: int) -> int:
	if budget_usec <= 0 or max_refs <= 0:
		return 0
	if _async_requests.is_empty():
		return 0

	var start_us := Time.get_ticks_usec()
	var request_ids: Array[int] = []
	for request_id: int in _async_requests:
		request_ids.append(request_id)
	if request_ids.size() > 1 and _has_interior_priority_request():
		request_ids.sort_custom(func(a: int, b: int) -> bool:
			if _request_has_interior_priority(a) != _request_has_interior_priority(b):
				return _request_has_interior_priority(a)
			return a < b
		)

	var processed := 0
	for request_id: int in request_ids:
		if processed >= max_refs:
			break
		if Time.get_ticks_usec() - start_us >= budget_usec:
			break
		var request: AsyncCellRequest = _async_requests[request_id]
		if request == null or request.classification_complete:
			continue
		processed += _classify_request_refs(
			request,
			start_us,
			budget_usec,
			max_refs - processed,
		)
	return processed


func _classify_request_refs(
	request: AsyncCellRequest,
	start_us: int,
	budget_usec: int,
	max_refs: int,
) -> int:
	if request == null or request.classification_complete:
		return 0
	if request.cell_record == null and not request.uses_world_manifest:
		return 0

	var processed := 0
	var using_world_objects: bool = request.uses_world_manifest
	var refs: Array = request.world_objects_to_classify if using_world_objects else request.cell_record.references
	var profile_start_us := Time.get_ticks_usec()
	var profile_record_us := 0
	var profile_route_us := 0
	var profile_cache_us := 0
	var profile_disk_us := 0
	var profile_finish_us := 0
	var worst_ref_us := 0
	var worst_ref_id := ""
	var worst_ref_type := ""
	var worst_model_path := ""
	while request.classify_index < refs.size() and processed < max_refs:
		if Time.get_ticks_usec() - start_us >= budget_usec:
			break

		var iter_start_us := Time.get_ticks_usec()
		var object_record: RefCounted = null
		var ref: Variant = null
		var base_record: Variant = null
		var type_name: String = ""
		var object_id: StringName = &""
		var model_path: String = ""
		if using_world_objects:
			object_record = refs[request.classify_index] as RefCounted
			if object_record == null:
				request.classify_index += 1
				processed += 1
				continue
			type_name = _type_name_for_record(object_record)
			object_id = _object_id_for_record(object_record)
			model_path = str(object_record.get("model_path"))
		else:
			ref = refs[request.classify_index]
		request.classify_index += 1
		processed += 1

		var record_start_us := Time.get_ticks_usec()
		var record_type: Array = [type_name]
		if not using_world_objects:
			base_record = _resolve_source_reference_base_record(ref, record_type)
			type_name = record_type[0] if record_type.size() > 0 else ""
		profile_record_us += Time.get_ticks_usec() - record_start_us
		if not using_world_objects and not base_record:
			continue
		if using_world_objects and int(object_record.get("spawn_route")) == WorldObjectRecordScript.SpawnRoute.SKIP:
			continue

		# Skip types that don't use models or are disabled.
		if type_name == "leveled_item":
			continue
		if type_name == "npc" and not load_npcs:
			continue
		if type_name == "creature" and not load_creatures:
			continue
		if type_name == "leveled_creature" and not load_creatures:
			continue

		var route_start_us := Time.get_ticks_usec()
		if not using_world_objects and model_path.is_empty():
			model_path = _get_model_path(base_record)
		if model_path.is_empty():
			var payload_record: RefCounted = object_record if using_world_objects else _make_payload_record_from_ref(
				ref,
				type_name,
				"",
				"",
				"",
				false,
				request.grid,
				base_record
			)
			if request.payload != null:
				if using_world_objects and type_name == "light":
					request.payload.add_light_record("", "", payload_record)
				elif using_world_objects:
					request.payload.add_interactive_record(type_name, "", "", payload_record)
				elif type_name == "light":
					request.payload.add_light_record("", "", payload_record)
				else:
					request.payload.add_interactive_record(type_name, "", "", payload_record)
			_queue_instantiation(request.request_id, ref, "", "", "", type_name, object_id, payload_record)
			profile_route_us += Time.get_ticks_usec() - route_start_us
			continue

		var item_id: String = ""
		if using_world_objects:
			item_id = str(object_record.get("model_item_id"))
		elif "record_id" in base_record:
			item_id = base_record.record_id
		var static_route := false
		if using_world_objects:
			static_route = _should_prepare_static_record(object_record, model_path, request.load_profile, item_id)
		else:
			static_route = _should_prepare_static_ref(
				base_record,
				type_name,
				model_path,
				request.load_profile,
				item_id,
				ref,
			)
		var load_item_id := ""
		if using_world_objects:
			load_item_id = str(object_record.get("cache_item_id"))
		else:
			load_item_id = "" if static_route or type_name == "light" or type_name == "npc" or type_name == "creature" else item_id
		profile_route_us += Time.get_ticks_usec() - route_start_us
		if request.payload != null:
			var payload_record: RefCounted = object_record if using_world_objects else _make_payload_record_from_ref(
				ref,
				type_name,
				model_path,
				item_id,
				load_item_id,
				static_route,
				request.grid,
				base_record
			)
			if static_route:
				request.payload.add_static_record(model_path, load_item_id, payload_record)
			elif using_world_objects and type_name == "light":
				request.payload.add_light_record(model_path, load_item_id, payload_record)
			elif using_world_objects:
				request.payload.add_interactive_record(type_name, model_path, load_item_id, payload_record)
			elif type_name == "light":
				request.payload.add_light_record(model_path, load_item_id, payload_record)
			else:
				request.payload.add_interactive_record(type_name, model_path, load_item_id, payload_record)
		if static_route:
			_enqueue_static_prepare(request.request_id, model_path, load_item_id)

		var cache_start_us := Time.get_ticks_usec()
		if _model_loader.has_model(model_path, load_item_id):
			_pin_payload_cached_scene(request, model_path, load_item_id)
			profile_cache_us += Time.get_ticks_usec() - cache_start_us
			var iter_elapsed_cached := Time.get_ticks_usec() - iter_start_us
			if iter_elapsed_cached > worst_ref_us:
				worst_ref_us = iter_elapsed_cached
				worst_ref_id = _debug_ref_id(ref, object_record)
				worst_ref_type = type_name
				worst_model_path = model_path
			if static_route:
				continue
			_queue_instantiation(request.request_id, ref, model_path, item_id, load_item_id, type_name, object_id, object_record)
			continue
		profile_cache_us += Time.get_ticks_usec() - cache_start_us

		var disk_start_us := Time.get_ticks_usec()
		if _model_loader.enable_disk_cache and _model_loader.has_disk_cached(model_path, load_item_id):
			var pending_key := _get_cache_key(model_path, load_item_id)
			if request.payload != null:
				var pending_payload: Dictionary = {}
				if using_world_objects:
					pending_payload = _make_pending_record_payload(
						object_record,
						type_name,
						item_id,
						load_item_id,
						static_route,
					)
				else:
					pending_payload = {
						"ref": ref,
						"base_record": base_record,
						"item_id": item_id,
						"cache_item_id": load_item_id,
						"type_name": type_name,
						"static_only": static_route,
						"object_id": object_id,
					}
				request.payload.enqueue_pending_model_load(pending_key, pending_payload)

			_queue_model_request_start(request.request_id, model_path, load_item_id, pending_key)
			profile_disk_us += Time.get_ticks_usec() - disk_start_us
			var iter_elapsed_disk := Time.get_ticks_usec() - iter_start_us
			if iter_elapsed_disk > worst_ref_us:
				worst_ref_us = iter_elapsed_disk
				worst_ref_id = _debug_ref_id(ref, object_record)
				worst_ref_type = type_name
				worst_model_path = model_path
			continue
		profile_disk_us += Time.get_ticks_usec() - disk_start_us

		if _model_loader.runtime_mode:
			var iter_elapsed_runtime := Time.get_ticks_usec() - iter_start_us
			if iter_elapsed_runtime > worst_ref_us:
				worst_ref_us = iter_elapsed_runtime
				worst_ref_id = _debug_ref_id(ref, object_record)
				worst_ref_type = type_name
				worst_model_path = model_path
			continue

		if model_path not in request.models_to_load:
			request.models_to_load[model_path] = {"item_ids": []}
		var item_ids_array: Array = request.models_to_load[model_path].item_ids
		var parse_item_id := load_item_id if using_world_objects else item_id
		if parse_item_id and parse_item_id not in item_ids_array:
			item_ids_array.append(parse_item_id)
		if not static_route:
			if using_world_objects:
				request.references_to_process.append(_make_pending_record_payload(object_record, type_name, item_id, load_item_id))
			else:
				request.references_to_process.append(_make_pending_payload(ref, base_record, type_name, item_id, item_id, object_id))
		var iter_elapsed_parse := Time.get_ticks_usec() - iter_start_us
		if iter_elapsed_parse > worst_ref_us:
			worst_ref_us = iter_elapsed_parse
			worst_ref_id = _debug_ref_id(ref, object_record)
			worst_ref_type = type_name
			worst_model_path = model_path

	if request.classify_index >= refs.size():
		var finish_start_us := Time.get_ticks_usec()
		_finish_request_classification(request)
		profile_finish_us += Time.get_ticks_usec() - finish_start_us

	var profile_total_us := Time.get_ticks_usec() - profile_start_us
	if profile_total_us > 16_000:
		Log.warn("streaming", "[class-spike %.1fms] grid=%s processed=%d idx=%d/%d rec=%.1f route=%.1f cache=%.1f disk=%.1f finish=%.1f worst=%.1f ref=%s type=%s model=%s" % [
			profile_total_us / 1000.0,
			str(request.grid),
			processed,
			request.classify_index,
			refs.size(),
			profile_record_us / 1000.0,
			profile_route_us / 1000.0,
			profile_cache_us / 1000.0,
			profile_disk_us / 1000.0,
			profile_finish_us / 1000.0,
			worst_ref_us / 1000.0,
			worst_ref_id,
			worst_ref_type,
			worst_model_path,
		])

	return processed


func _type_name_for_record(record: RefCounted) -> String:
	if record == null:
		return ""
	var source_type := str(record.get("source_type"))
	if not source_type.is_empty():
		return source_type
	match int(record.get("category")):
		WorldObjectRecordScript.Category.STATIC:
			return "static"
		WorldObjectRecordScript.Category.DOOR:
			return "door"
		WorldObjectRecordScript.Category.CONTAINER:
			return "container"
		WorldObjectRecordScript.Category.ACTIVATOR:
			return "activator"
		WorldObjectRecordScript.Category.LIGHT:
			return "light"
		WorldObjectRecordScript.Category.NPC:
			return "npc"
		WorldObjectRecordScript.Category.CREATURE:
			return "creature"
		_:
			return "object"


func _object_id_for_record(record: RefCounted) -> StringName:
	if record == null:
		return &""
	var value: Variant = record.get("object_id")
	if value is StringName:
		return value
	return StringName(str(value))


func _debug_ref_id(ref: Variant, record: RefCounted) -> String:
	if ref != null:
		return str(ref.ref_id)
	if record != null:
		var source_ref: Variant = record.get("source_ref_id")
		if source_ref != null and not str(source_ref).is_empty():
			return str(source_ref)
		return str(record.get("object_id"))
	return ""


func _finish_request_classification(request: AsyncCellRequest) -> void:
	if request == null or request.classification_complete:
		return

	for model_path: String in request.models_to_load:
		var model_info: Variant = request.models_to_load[model_path]
		var item_ids: Array = model_info.get("item_ids", []) if model_info is Dictionary else []
		var item_id: String = item_ids[0] if item_ids.size() > 0 else ""

		var task_id := _submit_parse_task(str(model_path), item_id, request.request_id)
		if task_id >= 0:
			request.pending_parses[model_path] = task_id

	request.classification_complete = true
	request.started = true
	request.state = CellPayloadScript.State.PAYLOAD_READY
	if request.payload != null:
		request.payload.state = request.state

	if _is_request_complete(request):
		_finalize_request(request)


func _model_request_start_key(request_id: int, pending_key: String) -> String:
	return "%d:%s" % [request_id, pending_key]


func _queue_model_request_start(request_id: int, model_path: String, item_id: String, pending_key: String) -> void:
	if pending_key.is_empty():
		return
	var start_key := _model_request_start_key(request_id, pending_key)
	if bool(_model_request_start_queued.get(start_key, false)):
		return
	if bool(_model_request_start_active.get(start_key, false)):
		return
	_model_request_start_queue.append({
		"request_id": request_id,
		"model_path": model_path,
		"item_id": item_id,
		"pending_key": pending_key,
		"start_key": start_key,
	})
	_model_request_start_queued[start_key] = true


func _process_model_request_start_queue(budget_usec: int, max_requests: int) -> int:
	if budget_usec <= 0 or max_requests <= 0:
		return 0
	if _model_request_start_queue.is_empty():
		return 0
	if _has_interior_priority_request():
		_sort_model_request_start_queue_by_priority()

	var start_us := Time.get_ticks_usec()
	var started := 0
	while not _model_request_start_queue.is_empty() and started < max_requests:
		if Time.get_ticks_usec() - start_us >= budget_usec:
			break

		var entry: Dictionary = _model_request_start_queue.pop_back()
		var start_key := str(entry.get("start_key", ""))
		_model_request_start_queued.erase(start_key)

		var request_id := int(entry.get("request_id", -1))
		var model_path := str(entry.get("model_path", ""))
		var item_id := str(entry.get("item_id", ""))
		var pending_key := str(entry.get("pending_key", ""))
		if request_id not in _async_requests:
			_model_request_start_active.erase(start_key)
			continue

		var request: AsyncCellRequest = _async_requests[request_id]
		if request == null or request.payload == null:
			_model_request_start_active.erase(start_key)
			continue
		if request.state == CellPayloadScript.State.UNLOADING or not is_instance_valid(request.cell_node):
			request.payload.discard_pending_model_load(pending_key)
			_model_request_start_active.erase(start_key)
			if _is_request_complete(request):
				request.completed = true
				request.failed = true
				request.error_message = "Cell node freed before disk request start"
			continue

		if _model_loader.has_model(model_path, item_id):
			_on_disk_load_completed(request_id, model_path, item_id, null)
			_model_request_start_active.erase(start_key)
			if _is_request_complete(request):
				_finalize_request(request)
			continue
		if not _model_loader.enable_disk_cache or not _model_loader.has_disk_cached(model_path, item_id):
			request.payload.discard_pending_model_load(pending_key)
			_model_request_start_active.erase(start_key)
			if _is_request_complete(request):
				_finalize_request(request)
			continue

		var request_start_us := Time.get_ticks_usec()
		var callback := _make_disk_load_callback(request_id, model_path, item_id)
		_model_request_start_active[start_key] = true
		var requested := _model_loader.request_model_async(model_path, item_id, callback, false)
		var elapsed_us := Time.get_ticks_usec() - request_start_us
		started += 1

		if not requested:
			_model_request_start_active.erase(start_key)
			request.payload.discard_pending_model_load(pending_key)
			if _is_request_complete(request):
				_finalize_request(request)
		if elapsed_us > 8_000:
			Log.warn("streaming", "[model-request-start-spike %.1fms] request=%d grid=%s key=%s queue=%d active=%d model=%s" % [
				float(elapsed_us) / 1000.0,
				request_id,
				str(request.grid),
				pending_key,
				_model_request_start_queue.size(),
				_model_request_start_active.size(),
				model_path,
			])

	return started


func _discard_model_request_starts_for_request(request_id: int) -> void:
	var kept: Array[Dictionary] = []
	for entry: Dictionary in _model_request_start_queue:
		var entry_request_id := int(entry.get("request_id", -1))
		var start_key := str(entry.get("start_key", ""))
		if entry_request_id == request_id:
			_model_request_start_queued.erase(start_key)
			_model_request_start_active.erase(start_key)
		else:
			kept.append(entry)
	_model_request_start_queue = kept

	var prefix := "%d:" % request_id
	var queued_to_remove: Array[String] = []
	for key: String in _model_request_start_queued:
		if key.begins_with(prefix):
			queued_to_remove.append(key)
	for key: String in queued_to_remove:
		_model_request_start_queued.erase(key)

	var active_to_remove: Array[String] = []
	for key: String in _model_request_start_active:
		if key.begins_with(prefix):
			active_to_remove.append(key)
	for key: String in active_to_remove:
		_model_request_start_active.erase(key)


func _static_entry_waiting_for_prepare(entry: InstantiationEntry) -> bool:
	if not SC.STATIC_PREPARE_ENABLED:
		return false
	if entry.static_prepare_key.is_empty():
		return false
	if bool(_static_prepare_failed.get(entry.static_prepare_key, false)):
		entry.static_prepare_failed = true
		return false
	if _static_renderer == null:
		return false
	if _static_renderer.call("has_type", entry.static_prepare_key):
		return false
	_enqueue_static_prepare(entry.request_id, entry.model_path, entry.cache_item_id)
	return true


## Request async loading of an exterior cell
## Returns request_id for tracking, or -1 if async not available or at capacity
## `profile` — optional per-request override of instantiator defaults. Pass
## null (default) to use the shared instantiator flags (current behavior).
func request_exterior_cell_async(x: int, y: int, profile: LoadProfile = null) -> int:
	return request_world_cell_async(Vector2i(x, y), profile)


func request_world_cell_async(grid: Vector2i, profile: LoadProfile = null) -> int:
	if not _background_processor:
		if not _stats.get("_warned_no_processor", false):
			push_warning("CellManager: No background processor set, falling back to sync load")
			_stats["_warned_no_processor"] = true
		return -1

	if _get_active_async_load_slot_count() >= MAX_ASYNC_REQUESTS:
		return -1
	if _world_object_source == null or not _world_object_source.has_method("get_cell_manifest"):
		return -1

	var manifest: Variant = _get_world_cell_manifest(grid)
	if manifest == null:
		return -1

	var capability_mask: int = WorldObjectRecordScript.CAP_GAMEPLAY | WorldObjectRecordScript.CAP_STATIC_VISUAL
	var objects: Array = []
	if manifest.has_method("get_capable_objects"):
		objects = manifest.call("get_capable_objects", capability_mask)
	else:
		for record: RefCounted in manifest.objects:
			if (int(record.get("capability_flags")) & capability_mask) != 0:
				objects.append(record)

	var request_id := _start_async_request(null, grid, false, profile, objects, true)
	if request_id > 0:
		_increment_route_usage_stat("async_world_manifest_requests")
	return request_id


func request_world_space_async(space_handle: RefCounted, profile: LoadProfile = null) -> int:
	if space_handle == null:
		return -1
	if not _background_processor:
		if not _stats.get("_warned_no_processor", false):
			push_warning("CellManager: No background processor set, falling back to sync load")
			_stats["_warned_no_processor"] = true
		return -1

	if _get_active_async_load_slot_count() >= MAX_ASYNC_REQUESTS:
		return -1

	var manifest: Variant = _get_world_space_manifest(space_handle)
	if manifest == null:
		return -1

	var capability_mask: int = WorldObjectRecordScript.CAP_GAMEPLAY | WorldObjectRecordScript.CAP_STATIC_VISUAL
	var objects: Array = []
	if manifest.has_method("get_capable_objects"):
		objects = manifest.call("get_capable_objects", capability_mask)
	else:
		for record: RefCounted in manifest.objects:
			if (int(record.get("capability_flags")) & capability_mask) != 0:
				objects.append(record)

	var grid: Vector2i = manifest.get("cell_grid") if manifest is Object else Vector2i.ZERO
	var is_interior := bool(space_handle.call("is_interior")) if space_handle.has_method("is_interior") else false
	var request_id := _start_async_request(null, grid, is_interior, profile, objects, true, str(space_handle.get("key")))
	if request_id > 0:
		if is_interior:
			_increment_route_usage_stat("async_world_manifest_interior_requests")
		else:
			_increment_route_usage_stat("async_world_manifest_requests")
	return request_id


## Request async loading of an interior cell
## Returns request_id for tracking, or -1 if async not available or at capacity
## `profile` — per-request override. Interior pockets should pass
## `LoadProfile.interior_pocket()` so RS/static-renderer batching is disabled
## (RS instances render at ESM world position, not pocket offset).
func request_cell_async(cell_name: String, profile: LoadProfile = null) -> int:
	return request_world_space_async(WorldSpaceHandleScript.interior(cell_name), profile)


## Check if an async request is complete
func is_async_complete(request_id: int) -> bool:
	if request_id not in _async_requests:
		return true  # Not found = already completed or invalid
	var request: AsyncCellRequest = _async_requests.get(request_id)
	return request.completed if request else true


## Return true once the request has enough data for first-playable gating.
##
## Full completion can remain false for a long time because proximity-deferred
## doors/containers/lights intentionally keep pending_instantiations alive until
## the camera approaches. Loading screens should wait for cell data/resource
## readiness, then let the interactive tail drain under runtime budgets.
func is_async_visual_playable(request_id: int) -> bool:
	if request_id not in _async_requests:
		return true  # Completed/erased requests are no longer async blockers.
	var request: AsyncCellRequest = _async_requests.get(request_id)
	return _is_request_visual_playable(request)


## Check if an async request has failed (some models couldn't be parsed)
func has_async_failed(request_id: int) -> bool:
	if request_id not in _async_requests:
		return false
	var request: AsyncCellRequest = _async_requests[request_id]
	return not request.failed_models.is_empty()


## Get the error message for a failed request
func get_async_error(request_id: int) -> String:
	if request_id not in _async_requests:
		return ""
	var request: AsyncCellRequest = _async_requests.get(request_id)
	return request.error_message if request else ""


## Get number of failed models in an async request
func get_async_failed_count(request_id: int) -> int:
	if request_id not in _async_requests:
		return 0
	var request: AsyncCellRequest = _async_requests[request_id]
	var failed_models_array: Array = request.failed_models
	return failed_models_array.size()


## Get the result of a completed async request
## Returns the cell Node3D, or null if not ready
func get_async_result(request_id: int) -> Node3D:
	if request_id not in _async_requests:
		return null

	var request: AsyncCellRequest = _async_requests[request_id]
	if not request.completed:
		return null

	if is_instance_valid(request.cell_node) \
			and request.payload != null \
			and request.payload.has_method("bind_resource_handles_to_node"):
		request.payload.bind_resource_handles_to_node(request.cell_node)

	# Remove from tracking and return result
	_discard_model_request_starts_for_request(request_id)
	_unpin_payload_cached_scenes(request)
	_async_requests.erase(request_id)
	return request.cell_node


## Get the cell node for an in-progress async request (for progressive loading)
## Returns the cell Node3D even if not complete - objects will appear as instantiated
## Returns null if request_id is invalid
func get_async_cell_node(request_id: int) -> Node3D:
	if request_id not in _async_requests:
		return null
	var request: AsyncCellRequest = _async_requests.get(request_id)
	return request.cell_node if request else null


func get_async_payload(request_id: int) -> CellPayloadScript:
	if request_id not in _async_requests:
		return null
	var request: AsyncCellRequest = _async_requests.get(request_id)
	return request.payload if request else null


func _get_pending_model_load_count_for_request(request: AsyncCellRequest) -> int:
	if request == null or request.payload == null:
		return 0
	return request.payload.get_pending_model_load_count() + request.payload.get_completed_model_load_count()


## Re-queue proximity-deferred refs that are now within spawn distance.
## Called from `native_streaming_manager._update_loaded_cells` after the
## load/unload dispatch. Throttled to PROXIMITY_TICK_INTERVAL_MSEC so walking
## the deferred list is bounded (targets ~4 checks/sec = cheap even at 10k refs).
## Also drops entries whose request is gone (cell fully unloaded).
func tick_proximity_deferred(camera_pos: Vector3) -> void:
	var now_msec := Time.get_ticks_msec()
	if now_msec - _proximity_last_tick_msec < PROXIMITY_TICK_INTERVAL_MSEC:
		return
	_proximity_last_tick_msec = now_msec
	if _proximity_deferred.is_empty():
		return

	var kept: Array[InstantiationEntry] = []
	var requeued: int = 0
	var dropped: int = 0
	for entry: InstantiationEntry in _proximity_deferred:
		# Drop entries whose request vanished (cell unloaded or finalized).
		if entry.request_id not in _async_requests:
			dropped += 1
			continue
		var request: AsyncCellRequest = _async_requests[entry.request_id]
		if not is_instance_valid(request.cell_node):
			dropped += 1
			# `pending_instantiations` gets resolved at cell-fail finalize.
			continue
		var threshold := _proximity_threshold_for_entry(entry)
		var threshold_sq: float = threshold * threshold
		if entry.position.distance_squared_to(camera_pos) <= threshold_sq and requeued < PROXIMITY_REQUEUE_MAX_PER_TICK:
			_instantiation_queue.push_back(entry)
			requeued += 1
		else:
			kept.append(entry)
	# Rebuild to kept entries — avoid O(N²) from in-place remove.
	_proximity_deferred = kept
	if requeued > 0 or dropped > 0:
		Log.debug("streaming", "[proximity-tick] requeued=%d dropped=%d still_deferred=%d by_type=%s" % [
			requeued, dropped, _proximity_deferred.size(), str(get_proximity_deferred_counts())
		])


func _proximity_threshold_for_entry(entry: InstantiationEntry) -> float:
	if entry != null and entry.world_object_record != null:
		var radius := float(entry.world_object_record.get("proximity_radius_m"))
		if radius > 0.0:
			return radius
	match entry.type_name:
		"light":
			return ReferenceInstantiator.LIGHT_PROXIMITY_THRESHOLD_M
		"npc", "creature", "leveled_creature":
			return ReferenceInstantiator.ACTOR_PROXIMITY_THRESHOLD_M
		_:
			return ReferenceInstantiator.INTERACTIVE_PROXIMITY_THRESHOLD_M


func get_proximity_deferred_counts() -> Dictionary:
	var counts: Dictionary = {}
	for entry: InstantiationEntry in _proximity_deferred:
		var type_name := entry.type_name if not entry.type_name.is_empty() else "unknown"
		counts[type_name] = int(counts.get(type_name, 0)) + 1
	return counts


## Periodic dump of per-type instantiate breakdown. Logs every 5s when any
## instantiate activity happened in the window. Resets counters after dump.
func _maybe_log_per_type_breakdown() -> void:
	var now_msec := Time.get_ticks_msec()
	if _diag_per_type_last_log_msec == 0:
		_diag_per_type_last_log_msec = now_msec
		return
	if now_msec - _diag_per_type_last_log_msec < 5000:
		return
	_diag_per_type_last_log_msec = now_msec
	if _diag_per_type_count.is_empty():
		return
	# Sort by total time descending
	var entries: Array = []
	for t_name: String in _diag_per_type_time_us:
		var total_us: int = _diag_per_type_time_us[t_name]
		var count: int = _diag_per_type_count.get(t_name, 0)
		var avg_us: float = float(total_us) / float(count) if count > 0 else 0.0
		entries.append({"type": t_name, "total_ms": total_us / 1000.0, "count": count, "avg_us": avg_us})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["total_ms"] > b["total_ms"])
	var summary_parts: Array[String] = []
	for e: Dictionary in entries:
		summary_parts.append("%s(n=%d tot=%.1fms avg=%dµs)" % [e["type"], e["count"], e["total_ms"], int(e["avg_us"])])
	Log.info("streaming", "[inst-breakdown 5s] " + "  ".join(summary_parts))
	_diag_per_type_time_us.clear()
	_diag_per_type_count.clear()


## Phase F — shutdown cleanup hook. Called by NativeStreamingManager.fast_cleanup
## on WM_CLOSE_REQUEST (Alt+F4 / quit menu) BEFORE it clears the static
## renderer. Drains any in-flight prototype pre-registration workers so they
## complete their writes into `_mesh_types` before the dict is freed. Without
## this, a worker mid-`register_from_prototype` + a main-thread `_static_renderer.
## clear()` race produces the shutdown sig 11 cluster.
##
## Plan: phase_f_prototype_prereg.md §5
##
## Win 1 (NEAR refactor 2026-04-25): also drains in-flight collision workers
## so they don't write into a dead payload after `_async_requests` is cleared
## by the shutdown path. Mirrors Phase F's drain — same wait_for_task_completion
## contract on every WorkerThreadPool task we own.
func fast_cleanup() -> void:
	# Win 1 — drain any in-flight per-cell collision workers.
	for request_id: int in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]
		_drain_collision_worker_for_request(request)
		_unpin_payload_cached_scenes(request)
	_discard_all_pending_child_attaches()
	_discard_all_static_prepare()
	_model_request_start_queue.clear()
	_model_request_start_queued.clear()
	_model_request_start_active.clear()
	_static_prepare_failed.clear()


## Cancel an async request — HARD cancel, destroys everything.
##
## Used by interior-pocket teardown where there is no unload-container limbo
## and no state-reversal path. Exterior cell unload DOES have state reversal
## (see `finalize_unloaded_cell` below) — don't use this from the exterior
## `_unload_cell` path, that would re-introduce the missing-objects-on-return
## bug (2026-04-19): filtering the queue during unload discards 100-300 pending
## instantiations per cell; reclaim then returns a half-populated cell_node.
func cancel_async_request(request_id: int) -> void:
	if request_id not in _async_requests:
		return

	var request: AsyncCellRequest = _async_requests[request_id]
	request.state = CellPayloadScript.State.UNLOADING
	if request.payload != null:
		request.payload.state = request.state

	# Cancel pending parse tasks
	for task_id: int in request.pending_parses.values():
		_background_processor.call("cancel_task", task_id)

	# Phase A (§7.7 2026-04-20) — drain any in-flight worker instantiates for
	# this request so they don't write to entries we're about to drop, and
	# queue_free any worker-produced Node3Ds that never reached the scene tree.
	# MUST run before the queue filter below — once filtered, the entries are
	# unreachable and their worker tasks would leak their instance.
	_phase_a_cancel_workers_for_request(request_id)

	# Win 1 (NEAR refactor 2026-04-25) — drain any in-flight collision worker.
	# The worker writes into request.payload.collision_payload's BuildPayload; if we
	# erase the request without waiting, the worker would write to a payload
	# whose only strong ref is gone, then the payload destructs mid-write.
	# wait_for_task_completion is also required by the WorkerThreadPool contract
	# to release task resources — same rule that bites Phase F at shutdown.
	_drain_collision_worker_for_request(request)

	# Remove all pending instantiations for this request from the queue
	# This prevents orphan objects when the cell is unloaded mid-loading
	var queue_before := _instantiation_queue.size()
	_instantiation_queue = _instantiation_queue.filter(
		func(entry: InstantiationEntry) -> bool: return entry.request_id != request_id
	)
	var removed := queue_before - _instantiation_queue.size()
	if removed > 0:
		# This is expected behavior when cells are unloaded mid-loading
		# Using print instead of push_warning since it's informational, not a problem
		Log.info("streaming", "CellManager: Cleaned up %d pending instantiations for unloaded cell (request %d)" % [removed, request_id])
	_discard_pending_child_attaches_for_request(request_id)
	_discard_static_prepare_for_request(request_id)
	_discard_model_request_starts_for_request(request_id)
	if _static_renderer != null and _static_renderer.has_method("remove_cell_instances"):
		_static_renderer.call("remove_cell_instances", request.grid)

	# Clean up cell node if started
	if request.cell_node:
		request.cell_node.queue_free()

	_unpin_payload_cached_scenes(request)
	_async_requests.erase(request_id)


## Pause scene-tree publishing for a request whose cell has entered unload
## limbo. Queue entries and detached children are preserved so state-reversal
## reclaim can resume without rebuilding the cell from scratch.
func pause_request_publish(request_id: int) -> void:
	if request_id not in _async_requests:
		return
	var request: AsyncCellRequest = _async_requests[request_id]
	request.state = CellPayloadScript.State.UNLOADING
	if request.payload != null:
		request.payload.state = request.state
	_record_lifecycle_event("publish_paused", request.grid, "request=%d" % request_id)


## Resume scene-tree publishing after unload-limbo state reversal.
func resume_request_publish(request_id: int) -> void:
	if request_id not in _async_requests:
		return
	var request: AsyncCellRequest = _async_requests[request_id]
	request.state = CellPayloadScript.State.VISUAL_READY if request.completed else CellPayloadScript.State.VISUAL_PUBLISHING
	if request.payload != null:
		request.payload.state = request.state
	_record_lifecycle_event("publish_resumed", request.grid, "request=%d completed=%s" % [
		request_id,
		"Y" if request.completed else "N",
	])


## Finalize an unloaded cell — SOFT cleanup after state-reversal window closes.
##
## Call when a cell's unload-container entry has fully drained to empty and the
## cell_node is being queue_free'd by `_process_budgeted_unloading`. Cleans up
## residual async request state WITHOUT touching cell_node (already dying on
## the caller's side) and WITHOUT any early queue filter (drain path's existing
## is_instance_valid guard handles orphaned entries).
##
## This is the exterior-cell counterpart to `cancel_async_request`. Canonical
## state-reversal pattern per UE5 World Partition + OpenMW UnrefQueue: keep
## request + queue intact through the unload-container limbo so reclaim can
## reverse the transition without losing pending instantiation work.
func finalize_unloaded_cell(request_id: int) -> void:
	if request_id not in _async_requests:
		return
	var request: AsyncCellRequest = _async_requests[request_id]
	request.state = CellPayloadScript.State.UNLOADING
	if request.payload != null:
		request.payload.state = request.state
	# Cancel any still-in-flight parse tasks (cell's gone, results have no home).
	for task_id: int in request.pending_parses.values():
		_background_processor.call("cancel_task", task_id)
	# Phase A (§7.7 2026-04-20) — drain any in-flight worker instantiates and
	# queue_free worker-produced Node3Ds BEFORE filtering the queue. See
	# cancel_async_request counterpart for rationale.
	_phase_a_cancel_workers_for_request(request_id)
	# Win 1 (NEAR refactor 2026-04-25) — drain any in-flight collision worker.
	# Same rationale as cancel_async_request: the worker writes into a payload
	# we're about to drop the last strong ref to.
	_drain_collision_worker_for_request(request)
	_unpin_payload_cached_scenes(request)
	# Filter any remaining queue entries for this request. Unlike the unload-
	# path filter (which was the bug), this runs AFTER the cell has truly died
	# and the state-reversal window is closed — no reclaim can use these.
	_instantiation_queue = _instantiation_queue.filter(
		func(entry: InstantiationEntry) -> bool: return entry.request_id != request_id
	)
	_discard_pending_child_attaches_for_request(request_id)
	_discard_static_prepare_for_request(request_id)
	_discard_model_request_starts_for_request(request_id)
	# Note: DON'T queue_free(request.cell_node) — caller (_process_budgeted_unloading)
	# owns the cell_node teardown and has already queue_free'd it.
	_async_requests.erase(request_id)


## Cancel async request by cell grid (useful when unloading cells)
func cancel_async_request_for_cell(grid: Vector2i) -> void:
	# Find and cancel any async request for this cell
	var request_ids_to_cancel: Array[int] = []
	for request_id: int in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]
		if not request.is_interior and request.grid == grid:
			request_ids_to_cancel.append(request_id)

	for request_id in request_ids_to_cancel:
		cancel_async_request(request_id)


## Process pending source-model conversions - DISABLED AT RUNTIME
## At runtime, all models should already be in disk cache from prebaking.
## This function is kept for prebaking tools but does nothing in runtime mode.
## Returns true if any conversions were done (always false in runtime mode)
func process_pending_conversions(_budget_ms: float) -> bool:
	# In runtime mode (world explorer), skip all conversion - models must be prebaked
	if _model_loader.runtime_mode:
		# Clear any pending conversions - they shouldn't exist in runtime mode
		if _pending_conversion_index < _pending_conversions.size():
			push_warning("CellManager: %d models queued for conversion but runtime_mode=true. Run prebaking first!" % (_pending_conversions.size() - _pending_conversion_index))
			_pending_conversions.clear()
			_pending_conversion_index = 0
		return false

	# PREBAKING MODE ONLY: Process conversions for prebaking tools
	if _pending_conversion_index >= _pending_conversions.size():
		return false

	var converted := 0

	while _pending_conversion_index < _pending_conversions.size() and converted < MAX_CONVERSIONS_PER_FRAME:
		var entry: Dictionary = _pending_conversions[_pending_conversion_index]
		_pending_conversion_index += 1
		var parse_result: Variant = entry.parse_result
		var model_path: String = entry.model_path
		var request_id: int = entry.request_id
		var item_id: String = entry.item_id

		# Check if request still exists
		if request_id not in _async_requests:
			continue

		var request: AsyncCellRequest = _async_requests[request_id]
		var prototype: Node3D = null

		# Perform the conversion (PREBAKING ONLY - can take 500ms-6s!)
		prototype = _create_provider_model_scene_from_parse_result(parse_result)

		if prototype:
			# Add to memory cache AND disk cache (handled inside add_to_cache)
			_model_loader.add_to_cache(model_path, prototype, item_id)
			# NOW queue references for this model
			_queue_references_for_model(request, model_path)
		else:
			request.failed_models.append(model_path)
			# Still queue references - they'll get placeholders
			_queue_references_for_model(request, model_path)

		converted += 1

		# Check if request is now complete
		if _is_request_complete(request):
			_finalize_request(request)

	# Periodic cleanup of the queue
	if _pending_conversion_index >= _pending_conversions.size():
		_pending_conversions.clear()
		_pending_conversion_index = 0
	elif _pending_conversion_index > 50:
		_pending_conversions = _pending_conversions.slice(_pending_conversion_index)
		_pending_conversion_index = 0

	return converted > 0


## Process async disk loads - call this every frame to complete pending model loads
## budget_usec: time budget for PackedScene instantiation; 0 uses loader fallback.
## Returns number of models that finished loading this frame
func process_async_disk_loads(budget_usec: int = 0) -> int:
	return _model_loader.process_async_loads(budget_usec)


## Get count of pending async disk loads
func get_pending_disk_load_count() -> int:
	return _model_loader.get_pending_async_count()


## Queue a detached Node3D for a budgeted scene-tree attach.
func _queue_child_attach(
	request_id: int,
	parent: Node3D,
	child: Node3D,
	source_entry: InstantiationEntry = null,
	type_name: String = "",
) -> void:
	var grid_text := ""
	if request_id in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]
		if request != null:
			grid_text = str(request.grid)
	var model_path := ""
	var item_id := ""
	var ref_id := ""
	var ref_num := 0
	if source_entry != null:
		model_path = source_entry.model_path
		item_id = source_entry.item_id
		if source_entry.ref != null:
			ref_id = str(source_entry.ref.ref_id)
			ref_num = source_entry.ref.ref_num
		elif source_entry.world_object_record != null:
			ref_id = str(source_entry.world_object_record.get("source_ref_id"))
	_pending_child_attaches.append({
		"request_id": request_id,
		"parent": parent,
		"child": child,
		"grid": grid_text,
		"type_name": type_name,
		"model_path": model_path,
		"item_id": item_id,
		"ref_id": ref_id,
		"ref_num": ref_num,
	})


func _is_request_publish_paused(request: AsyncCellRequest) -> bool:
	if request == null:
		return true
	if request.state == CellPayloadScript.State.UNLOADING:
		return true
	if not is_instance_valid(request.cell_node):
		return false
	if request.cell_node.is_queued_for_deletion():
		return false
	return not request.cell_node.visible


func _get_child_attach_state(request_id: int, parent: Node3D) -> int:
	if request_id not in _async_requests:
		return CHILD_ATTACH_DROP
	var request: AsyncCellRequest = _async_requests[request_id]
	if not is_instance_valid(parent) or not is_instance_valid(request.cell_node):
		return CHILD_ATTACH_DROP
	if parent != request.cell_node:
		return CHILD_ATTACH_DROP
	if request.cell_node.is_queued_for_deletion():
		return CHILD_ATTACH_DROP
	if request.state == CellPayloadScript.State.UNLOADING or not request.cell_node.visible:
		return CHILD_ATTACH_PAUSED
	return CHILD_ATTACH_READY


## Attach queued children within a small count/time budget. Invalid parents
## mean the owning cell died before publish; free the detached child instead.
func _drain_pending_child_attaches(max_count: int, budget_usec: float) -> int:
	if _pending_child_attaches.is_empty() or max_count <= 0 or budget_usec <= 0.0:
		return 0

	var start_usec := Time.get_ticks_usec()
	var processed := 0
	var attached := 0
	var blocked := 0
	var dropped := 0
	var blocked_entries: Array[Dictionary] = []
	while not _pending_child_attaches.is_empty() and processed < max_count:
		if float(Time.get_ticks_usec() - start_usec) >= budget_usec:
			break
		var entry: Dictionary = _pending_child_attaches.pop_back()
		processed += 1
		var request_id := int(entry.get("request_id", -1))
		var parent: Node3D = entry.get("parent") as Node3D
		var child: Node3D = entry.get("child") as Node3D
		if not is_instance_valid(child):
			continue
		var attach_state := _get_child_attach_state(request_id, parent)
		if attach_state == CHILD_ATTACH_READY:
			var attach_label := "%s grid=%s type=%s model=%s ref=%s#%d child=%s:%s direct=%d" % [
				request_id,
				str(entry.get("grid", "")),
				str(entry.get("type_name", "")),
				str(entry.get("model_path", "")),
				str(entry.get("ref_id", "")),
				int(entry.get("ref_num", 0)),
				child.get_class(),
				child.name,
				child.get_child_count(),
			]
			var attach_one_start := Time.get_ticks_usec()
			parent.add_child(child)
			var attach_one_us := Time.get_ticks_usec() - attach_one_start
			if attach_one_us >= CHILD_ATTACH_SLOW_LOG_USEC:
				Log.warn("streaming", "[child-attach-spike %.1fms] %s" % [
					float(attach_one_us) / 1000.0,
					attach_label,
				])
			attached += 1
		elif attach_state == CHILD_ATTACH_PAUSED:
			blocked_entries.append(entry)
			blocked += 1
		else:
			child.queue_free()
			dropped += 1
	for i in range(blocked_entries.size() - 1, -1, -1):
		_pending_child_attaches.push_front(blocked_entries[i])
	return attached


func _get_pending_child_attach_count_for_request(request_id: int) -> int:
	var count := 0
	for entry: Dictionary in _pending_child_attaches:
		if int(entry.get("request_id", -1)) == request_id:
			count += 1
	return count


func _finalize_requests_completed_by_child_attaches() -> void:
	for request_id: int in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]
		if request != null and _is_request_complete(request):
			_finalize_request(request)


func _discard_pending_child_attaches_for_request(request_id: int) -> void:
	if _pending_child_attaches.is_empty():
		return
	var kept: Array[Dictionary] = []
	for entry: Dictionary in _pending_child_attaches:
		if int(entry.get("request_id", -1)) != request_id:
			kept.append(entry)
			continue
		var child: Node3D = entry.get("child") as Node3D
		if is_instance_valid(child):
			child.queue_free()
	_pending_child_attaches = kept


func _discard_all_pending_child_attaches() -> void:
	for entry: Dictionary in _pending_child_attaches:
		var child: Node3D = entry.get("child") as Node3D
		if is_instance_valid(child):
			child.queue_free()
	_pending_child_attaches.clear()


func _discard_static_prepare_for_request(request_id: int) -> void:
	if request_id not in _async_requests:
		return
	var request: AsyncCellRequest = _async_requests[request_id]
	if request != null and request.payload != null:
		_cancel_payload_static_bucket_builds(request)
		request.payload.discard_static_prepare_queue()


func _cancel_payload_static_bucket_builds(request: AsyncCellRequest) -> void:
	if request == null or request.payload == null or _static_renderer == null:
		return
	if not _static_renderer.has_method("cancel_cell_bucket_build"):
		return
	for entry_value: Variant in request.payload.static_prepare_entries_by_key.values():
		var entry: Dictionary = entry_value
		var model_path := str(entry.get("model_path", ""))
		if model_path.is_empty():
			continue
		var item_id := str(entry.get("item_id", ""))
		var payload_key := CellPayloadScript.make_model_key(model_path, item_id)
		var bucket_key := "%d,%d:%s" % [request.grid.x, request.grid.y, payload_key]
		_static_renderer.call("cancel_cell_bucket_build", bucket_key)


## Process async instantiation within time budget (call from _process)
## Returns number of objects instantiated this frame
## Uses BOTH time budget AND object count cap for consistent frame times
## Objects sorted by frustum-aware priority - visible nearest objects first
##
## BURST LOADING: When objects are very close to camera (< NEAR_BURST_DISTANCE),
## uses higher budget and limits for faster cell population.
##
## Parameters:
##   budget_ms: Time budget in milliseconds (may be overridden by burst loading)
##   camera_pos: Camera position for priority sorting (optional, uses cached if not provided)
##   camera_fwd: Camera forward direction for frustum priority (optional)
func process_async_instantiation(
	budget_ms: float,
	camera_pos: Vector3 = Vector3.INF,
	camera_fwd: Vector3 = Vector3.INF,
	allow_collision_finalize: bool = true,
) -> int:
	# Update camera position/forward if provided
	if camera_pos != Vector3.INF:
		_camera_position = camera_pos
	if camera_fwd != Vector3.INF:
		_camera_forward = camera_fwd

	# Phase 4 / T.2 — build merged static collision for any cell whose static
	# models have fully loaded but hasn't yet been collided. Fires independent
	# of `_finalize_request` (which is gated by `pending_instantiations == 0`,
	# a condition that never clears when interactive refs are proximity-
	# deferred). One build per frame to bound cold-cache stalls.
	# Fix B (streaming_stutter_2026_04_25 §11.4) — sub-bracket the four pre-loop
	# steps so the autopsy can attribute the 100-540 ms `instantiate=` spike
	# either to a substep here or to the main loop below.
	var t_pre0 := Time.get_ticks_usec()
	var start_time := t_pre0
	var budget_usec_total := int(budget_ms * 1000.0)
	if allow_collision_finalize and not _has_collision_blocking_visual_work():
		var collision_dispatch_budget_us: int = mini(
			int(SC.CELL_STATIC_COLLISION_DISPATCH_BUDGET_MS * 1000.0),
			budget_usec_total,
		)
		_tick_static_collision_build(
			false,
			collision_dispatch_budget_us,
			SC.CELL_STATIC_COLLISION_DISPATCH_MAX_PER_FRAME,
		)
	var t_pre_collision := Time.get_ticks_usec()

	# Start budget clock BEFORE pre-loop work — collision dispatch, disk loads,
	# conversions, and pool prewarm all consume frame time that must count
	# against the budget.
	# Without this, these operations can blow the budget before the main
	# instantiation loop even begins (root cause of 112ms frame overruns).

	# First process any pending async disk loads, budgeted so they can't eat the
	# entire frame allocation before the main instantiation loop runs.
	var classify_cap_ms := SC.CELL_REQUEST_CLASSIFY_BUDGET_MS
	var classify_max_refs := SC.CELL_REQUEST_CLASSIFY_MAX_REFS
	if budget_ms > SC.POST_STARTUP_INSTANTIATION_BUDGET_MS:
		classify_cap_ms = SC.STARTUP_CELL_REQUEST_CLASSIFY_BUDGET_MS
		classify_max_refs = SC.STARTUP_CELL_REQUEST_CLASSIFY_MAX_REFS
	var classify_budget_us: int = mini(int(classify_cap_ms * 1000.0), budget_usec_total)
	var classified_refs := _process_request_classification_queue(classify_budget_us, classify_max_refs)
	var t_pre_classify := Time.get_ticks_usec()

	var request_start_elapsed_us := Time.get_ticks_usec() - start_time
	var request_start_remaining_us: int = maxi(0, budget_usec_total - int(request_start_elapsed_us))
	var request_start_cap_ms := SC.MODEL_REQUEST_START_BUDGET_MS
	var request_start_max := SC.MODEL_REQUEST_START_MAX_PER_FRAME
	if budget_ms > SC.POST_STARTUP_INSTANTIATION_BUDGET_MS:
		request_start_cap_ms = SC.STARTUP_MODEL_REQUEST_START_BUDGET_MS
		request_start_max = SC.STARTUP_MODEL_REQUEST_START_MAX_PER_FRAME
	var request_start_budget_us: int = mini(int(request_start_cap_ms * 1000.0), request_start_remaining_us)
	var model_request_starts := _process_model_request_start_queue(request_start_budget_us, request_start_max)
	var t_pre_request_start := Time.get_ticks_usec()

	var disk_elapsed_us := Time.get_ticks_usec() - start_time
	var disk_remaining_us: int = maxi(0, budget_usec_total - int(disk_elapsed_us))
	var disk_cap_ms := SC.MODEL_LOADER_DRAIN_BUDGET_MS
	if budget_ms > SC.POST_STARTUP_INSTANTIATION_BUDGET_MS:
		disk_cap_ms = SC.STARTUP_MODEL_LOADER_DRAIN_BUDGET_MS
	var disk_budget_us: int = mini(int(disk_cap_ms * 1000.0), disk_remaining_us)
	process_async_disk_loads(disk_budget_us)
	var t_pre_disk := Time.get_ticks_usec()

	# Then process any pending conversions to feed the cache
	# Runtime mode no-ops here, but keep the prebake path inside remaining time.
	var conv_remaining_ms := maxf(0.0, budget_ms - (float(t_pre_disk - start_time) / 1000.0))
	var conversion_budget_ms := minf(budget_ms * 0.25, conv_remaining_ms)
	process_pending_conversions(conversion_budget_ms)
	var t_pre_conv := Time.get_ticks_usec()

	# Process pool pre-warming in background (only if budget permits)
	var pre_loop_elapsed := float(Time.get_ticks_usec() - start_time) / 1000.0
	if pool_prewarm_enabled and pre_loop_elapsed < budget_ms * 0.7:
		_process_pool_prewarm()
	var t_pre_prewarm := Time.get_ticks_usec()
	var static_prepare_count := 0
	var t_pre_static_prepare := Time.get_ticks_usec()

	# BURST LOADING: Check if nearest objects are very close (critical loading)
	# If so, use aggressive budget to populate cells faster
	var effective_budget_ms := budget_ms
	var effective_max_instantiations := MAX_INSTANTIATIONS_PER_FRAME

	if not _instantiation_queue.is_empty():
		var last_entry: InstantiationEntry = _instantiation_queue[-1]
		var last_pos: Vector3 = last_entry.position
		var last_distance := _camera_position.distance_to(last_pos)

		if last_distance < _burst_distance:
			# Activate burst loading for nearby objects
			_burst_loading_active = true
			effective_budget_ms = _burst_budget_ms
			effective_max_instantiations = _burst_max_instantiations
		else:
			_burst_loading_active = false

	var budget_usec := effective_budget_ms * 1000.0
	var attach_time_us := 0
	var attach_start := Time.get_ticks_usec()
	var attach_budget_pre := minf(
		SC.CHILD_ATTACH_BUDGET_MS * 1000.0,
		maxf(0.0, budget_usec - float(attach_start - start_time))
	)
	var pre_attached_children := _drain_pending_child_attaches(SC.CHILD_ATTACH_MAX_PER_FRAME, attach_budget_pre)
	attach_time_us += Time.get_ticks_usec() - attach_start
	if pre_attached_children > 0:
		_finalize_requests_completed_by_child_attaches()

	if _instantiation_queue.is_empty():
		if not allow_collision_finalize:
			return 0
		_maybe_finalize_static_collision_when_idle(start_time, budget_usec)
		return 0

	# Sort queue by priority periodically (not every frame - too expensive)
	var current_frame := Engine.get_frames_drawn()
	if current_frame - _queue_sort_frame >= QUEUE_SORT_INTERVAL:
		_queue_sort_frame = current_frame
		_sort_queue_by_priority()

	var instantiated := 0
	var exit_reason := ""
	var route_static_us := 0
	var route_node_us := 0
	var route_light_us := 0
	var route_actor_us := 0
	var route_worker_static_us := 0
	var route_worker_node_us := 0
	var route_deferred_us := 0
	var route_skip_us := 0
	var route_other_us := 0
	var route_model_load_us := 0
	var route_static_register_us := 0
	var route_static_add_us := 0
	var phase_a_dispatch_us := 0
	var collision_finalize_us := 0
	var route_static_count := 0
	var route_node_count := 0
	var route_light_count := 0
	var route_actor_count := 0
	var route_worker_static_count := 0
	var route_worker_node_count := 0
	var route_deferred_count := 0
	var route_skip_count := 0
	var worker_pending_count := 0

	# Step 1 instrumentation — reset per-frame ESM-type buckets. Snapshotted
	# by streaming_benchmark; do NOT accumulate across calls.
	_frame_inst_door_us = 0
	_frame_inst_light_us = 0
	_frame_inst_light_modelload_us = 0
	_frame_inst_container_us = 0
	_frame_inst_activator_us = 0
	_frame_inst_static_us = 0

	# Periodic per-type breakdown dump (every 5s). Answers "inside inst:, which
	# ref type dominates" with real data, not intuition.
	_maybe_log_per_type_breakdown()

	# Phase A — dispatch pass before drain. Peek-iterates the queue, submits a
	# WorkerThreadPool task per survivor (see `should_dispatch_to_worker` for
	# the routing gate). Ready tasks are consumed by the drain loop via
	# `complete_worker_instantiate`; in-flight tasks park on `phase_a_deferred`
	# and get re-queued at loop exit. Plan §3.1, §7.4.
	if PHASE_A_OFFTHREAD_INSTANTIATE:
		var dispatch_start_us := Time.get_ticks_usec()
		_phase_a_dispatch_pass()
		phase_a_dispatch_us = Time.get_ticks_usec() - dispatch_start_us

	# Phase A — entries whose worker task is still running get parked here
	# and re-appended to the queue after the loop exits, so they get another
	# chance next frame without spin-waiting. See phase_a_offthread_instantiate.md §3.3.
	var phase_a_deferred: Array[InstantiationEntry] = []

	while not _instantiation_queue.is_empty():
		# Check time budget
		var elapsed := Time.get_ticks_usec() - start_time
		if elapsed >= budget_usec:
			exit_reason = "time_budget"
			break

		# Check object count cap (critical for consistent frame times)
		if instantiated >= effective_max_instantiations:
			exit_reason = "object_cap"
			break

		var entry: InstantiationEntry = _instantiation_queue.pop_back()
		var request_id: int = entry.request_id
		var ref: Variant = entry.ref
		var model_path: String = entry.model_path
		var item_id: String = entry.item_id
		var cache_item_id: String = entry.cache_item_id

		# Phase A / E — dispatched-but-running entries get parked. Their worker
		# is still executing; trying to consume worker_instance / worker_static_precomp
		# now would race against the writer. Park and retry next frame.
		if PHASE_A_OFFTHREAD_INSTANTIATE:
			if entry.worker_dispatched \
					and not WorkerThreadPool.is_task_completed(entry.worker_task_id):
				phase_a_deferred.append(entry)
				worker_pending_count += 1
				continue
			if entry.worker_static_dispatched \
					and not WorkerThreadPool.is_task_completed(entry.worker_static_task_id):
				phase_a_deferred.append(entry)
				worker_pending_count += 1
				continue

		# Check if request still exists
		if request_id not in _async_requests:
			continue

		var request: AsyncCellRequest = _async_requests[request_id]
		if request.state < CellPayloadScript.State.VISUAL_PUBLISHING:
			request.state = CellPayloadScript.State.VISUAL_PUBLISHING
			if request.payload != null:
				request.payload.state = request.state

		# CRITICAL: Check if cell_node is still valid (cell may have been unloaded)
		# This prevents crash when camera moves and cell is freed mid-instantiation
		if not is_instance_valid(request.cell_node):
			# Cell was unloaded, skip remaining items for this request
			request.pending_instantiations -= 1
			if _is_request_complete(request):
				request.completed = true
				request.failed = true
				request.error_message = "Cell node freed during instantiation"
			continue
		if _is_request_publish_paused(request):
			phase_a_deferred.append(entry)
			route_deferred_count += 1
			continue

		if _static_entry_waiting_for_prepare(entry):
			phase_a_deferred.append(entry)
			continue
		if not model_path.is_empty():
			_restore_payload_cached_scene(request, model_path, cache_item_id)

		# Decrement pending count
		request.pending_instantiations -= 1

		# S.1 refactor (near_tier_refactor.md 2026-04-19): per-object distance +
		# tier branching removed. Cell-level tier is the axis of variation, not
		# per-object. If a cell is in the active set, every ref in it becomes a
		# Node3D — no defer queue, no MID RS instances, no "near:" RS shims.
		# MID / HLOD / impostor re-enable is driven by `request_cell_tier` in
		# phases S.7+. Until then, NEAR is the only tier and the only codepath.
		_instantiator._set_transient_profile(entry.load_profile)
		var inst_start := Time.get_ticks_usec()
		var inst_cell_grid: Vector2i = request.grid if not request.is_interior else Vector2i.ZERO
		var obj: Node3D = null
		var inst_result: Variant = null
		# Phase A §7.5 + §7.6 — dispatched entries NEVER fall back to sync
		# normalized instantiate fallback. Either:
		#   (a) worker_instance != null → run main-thread tail and publish.
		#   (b) worker_instance == null → worker produced nothing (malformed
		#       PackedScene, non-Node3D root, can_instantiate false). Drop
		#       the ref; pending_instantiations was already decremented so
		#       the request finalizes cleanly. Sync re-try would just repeat
		#       the same failure against the same cached PackedScene.
		# Non-dispatched entries (type-excluded light/npc/creature/leveled,
		# static-renderer-routed STAT, proximity-deferred, cache-miss,
		# debug_lod bailout, or PHASE_A flag off) take the sync path — it
		# owns all non-Node3D routing (_instantiate_light, _instantiate_actor,
		# _instantiate_static_object, proximity gate).
		if PHASE_A_OFFTHREAD_INSTANTIATE and entry.worker_dispatched:
			# Clear stale sync-call state so per-type diag + proximity routing
			# don't inherit values from a prior iteration. complete_worker_
			# instantiate resets these on the success branch; the failure
			# branch needs them zeroed explicitly because it doesn't run.
			_instantiator.last_type_name = entry.phase_a_type_name
			_instantiator.last_proximity_deferred = false
			if entry.worker_instance != null:
				obj = _instantiator.complete_worker_instantiate(
					entry,
					entry.worker_instance,
					entry.phase_a_base_record,
					entry.phase_a_type_name,
				)
				# Clear so we don't double-consume in any error path.
				entry.worker_instance = null
			else:
				_instantiator._reset_last_inst_diagnostics("worker_node_empty")
			# else: worker failed, obj stays null, ref drops silently.
		elif PHASE_A_OFFTHREAD_INSTANTIATE and entry.worker_static_dispatched:
			# Phase E — worker precomputed a PrecomputedInstance off-thread;
			# publish via static_renderer.add_instance_precomputed. Always
			# returns null (no Node3D). On null precomp (worker failure),
			# `complete_worker_static_precompute` is a no-op — ref drops
			# silently, pending_instantiations already decremented.
			_instantiator.last_type_name = "static"
			_instantiator.last_proximity_deferred = false
			if entry.worker_static_precomp != null:
				obj = _instantiator.complete_worker_static_precompute(
					entry,
					entry.worker_static_precomp,
				)
				entry.worker_static_precomp = null
			else:
				_instantiator._reset_last_inst_diagnostics("worker_static_empty")
			# else: worker failed (e.g. type unregistered at precompute time,
			# e.g. clear() ran mid-flight). Drop silently.
		else:
			if entry.world_object_record != null and _instantiator.has_method("instantiate_world_object_record_result"):
				inst_result = _instantiator.call("instantiate_world_object_record_result", entry.world_object_record, inst_cell_grid, cache_item_id)
				if inst_result != null:
					obj = inst_result.get("node") as Node3D
			elif entry.world_object_id != &"" and _instantiator.has_method("instantiate_world_object"):
				obj = _instantiator.call("instantiate_world_object", entry.world_object_id, inst_cell_grid, cache_item_id) as Node3D
			else:
				var fallback_record: RefCounted = null
				if ref != null:
					var fallback_type_name: String = entry.type_name
					var fallback_base_record: Variant = null
					var fallback_record_type: Array = [fallback_type_name]
					fallback_base_record = _resolve_source_reference_base_record(ref, fallback_record_type)
					fallback_type_name = fallback_record_type[0] if fallback_record_type.size() > 0 else fallback_type_name
					if fallback_base_record != null:
						var fallback_item_id := item_id
						if fallback_item_id.is_empty() and "record_id" in fallback_base_record:
							fallback_item_id = str(fallback_base_record.record_id)
						var fallback_cache_item_id := cache_item_id if not cache_item_id.is_empty() else fallback_item_id
						fallback_record = _make_payload_record_from_ref(
							ref,
							fallback_type_name,
							model_path,
							fallback_item_id,
							fallback_cache_item_id,
							false,
							inst_cell_grid,
							fallback_base_record
						)
				if fallback_record != null and _instantiator.has_method("instantiate_world_object_record_result"):
					inst_result = _instantiator.call("instantiate_world_object_record_result", fallback_record, inst_cell_grid, cache_item_id)
					if inst_result != null:
						obj = inst_result.get("node") as Node3D
		var inst_elapsed := Time.get_ticks_usec() - inst_start
		var route_name: String = str(inst_result.get("route")) if inst_result != null else _instantiator.last_inst_route
		if route_name.is_empty():
			route_name = "unknown"
		var route_model_load_delta_us := int(inst_result.get("model_load_us")) if inst_result != null else int(_instantiator.last_model_load_us)
		var route_static_register_delta_us := int(inst_result.get("static_register_us")) if inst_result != null else int(_instantiator.last_static_register_us)
		var route_static_add_delta_us := int(inst_result.get("static_add_us")) if inst_result != null else int(_instantiator.last_static_add_us)
		route_model_load_us += route_model_load_delta_us
		route_static_register_us += route_static_register_delta_us
		route_static_add_us += route_static_add_delta_us
		if route_name.begins_with("static_"):
			route_static_us += inst_elapsed
			route_static_count += 1
		elif route_name == "light":
			route_light_us += inst_elapsed
			route_light_count += 1
		elif route_name == "actor":
			route_actor_us += inst_elapsed
			route_actor_count += 1
		elif route_name == "worker_static_publish" or route_name == "worker_static_empty":
			route_worker_static_us += inst_elapsed
			route_worker_static_count += 1
		elif route_name == "worker_node_tail" or route_name == "worker_node_empty":
			route_worker_node_us += inst_elapsed
			route_worker_node_count += 1
		elif route_name == "deferred":
			route_deferred_us += inst_elapsed
			route_deferred_count += 1
		elif route_name == "skip":
			route_skip_us += inst_elapsed
			route_skip_count += 1
		elif route_name.begins_with("node_") or route_name == "placeholder":
			route_node_us += inst_elapsed
			route_node_count += 1
		else:
			route_other_us += inst_elapsed
		_instantiator._clear_transient_profile()
		_diag_instantiate_time_total_us += inst_elapsed
		_diag_instantiate_count += 1
		# Per-type breakdown — direct attribution of inst: cost to specific ref types.
		var t_name: String = str(inst_result.get("type_name")) if inst_result != null else _instantiator.last_type_name
		if t_name.is_empty():
			t_name = "unknown"
		_diag_per_type_time_us[t_name] = _diag_per_type_time_us.get(t_name, 0) + inst_elapsed
		_diag_per_type_count[t_name] = _diag_per_type_count.get(t_name, 0) + 1

		# Step 1 instrumentation — per-frame ESM-type bucket. Light's model-load
		# subslice splits disk/parse cost from `OmniLight3D` construction so a
		# follow-up plan can tell whether light cost is disk/parse vs construction.
		match t_name:
			"door":
				_frame_inst_door_us += inst_elapsed
			"light":
				_frame_inst_light_us += inst_elapsed
				_frame_inst_light_modelload_us += route_model_load_delta_us
			"container":
				_frame_inst_container_us += inst_elapsed
			"activator":
				_frame_inst_activator_us += inst_elapsed
			"static":
				_frame_inst_static_us += inst_elapsed

		# Lazy-spawn deferral — interactive ref too far, park it for later.
		# The reference_instantiator returned null without decrementing our
		# pending counter (see below). Push to the deferred list; it'll be
		# re-queued when the camera is within its proximity threshold via
		# tick_proximity_deferred.
		var proximity_deferred := bool(inst_result.get("proximity_deferred")) if inst_result != null else _instantiator.last_proximity_deferred
		if obj == null and proximity_deferred:
			_proximity_deferred.append(entry)
			# Rewind the pending counter — this ref isn't instantiated OR failed,
			# it's paused. `_is_request_complete` must still see it as in-flight.
			request.pending_instantiations += 1
			continue

		if obj:
			# Override legacy prebaked VR to 0-NEAR_END so NEAR Node3Ds cull at
			# 150m. MID/HLOD/FAR render ownership is handled by renderer tiers.
			_apply_near_visibility_range(obj)
			obj.set_meta("visibility_prebaked", true)

			# Double-check parent is still valid before queuing (defensive)
			if is_instance_valid(request.cell_node):
				_queue_child_attach(request_id, request.cell_node, obj, entry, t_name)
				instantiated += 1
			else:
				obj.queue_free()

		# Check if this was the last reference — route through _finalize_request
		# so batching + GPU scene DB upload fire (inline `request.completed = true`
		# was a pre-existing bypass for content cells).
		if _is_request_complete(request):
			_finalize_request(request)

	# Phase A — restore dispatched-but-running entries to the queue so they
	# get re-evaluated next frame. pop_back() returned the highest-priority
	# entry first, so phase_a_deferred is in descending priority order. We
	# push_back in reverse so the queue ends up with highest priority at the
	# back (ready for the next pop_back). _sort_queue_by_priority will
	# re-sort on QUEUE_SORT_INTERVAL anyway, but this keeps the priority
	# invariant between sorts.
	if not phase_a_deferred.is_empty():
		for i in range(phase_a_deferred.size() - 1, -1, -1):
			_instantiation_queue.push_back(phase_a_deferred[i])

	# Attach children under an explicit budget. Large cell-boundary batches
	# used to be dumped into call_deferred(), which hid the cost from this
	# loop but still produced idle-time add_child bursts.
	var add_child_start := Time.get_ticks_usec()
	var attach_budget_post := minf(
		SC.CHILD_ATTACH_BUDGET_MS * 1000.0,
		maxf(0.0, budget_usec - float(add_child_start - start_time))
	)
	var attached_children := _drain_pending_child_attaches(
		SC.CHILD_ATTACH_MAX_PER_FRAME,
		attach_budget_post
	)
	attach_time_us += Time.get_ticks_usec() - add_child_start
	if attached_children > 0:
		_finalize_requests_completed_by_child_attaches()
	if allow_collision_finalize:
		collision_finalize_us = _maybe_finalize_static_collision_when_idle(start_time, budget_usec)

	# Fix B (streaming_stutter_2026_04_25 §11.4) — when this call exceeded a
	# threshold, dump the pre-loop split so we can tell whether
	# _tick_static_collision_build / disk_loads / conversions / pool_prewarm
	# is the spike, vs the main loop. Dropped from 100 ms to 16 ms (2026-04-26)
	# to catch the routine 12-25 ms overruns visible during walking traversal,
	# not just the catastrophic class. 16 ms = one 60 fps frame.
	var t_end_inst := Time.get_ticks_usec()
	var total_inst_us := t_end_inst - t_pre0
	if total_inst_us > 16_000:
		Log.warn("streaming", "[inst-spike %.1fms] coll=%.1f class=%.1f/%d mreq=%.1f/%d disk=%.1f conv=%.1f prewarm=%.1f sprep=%.1f/%d dispatch=%.1f cfin=%.1f loop=%.1f addc=%.1f static=%.1f/%d light=%.1f/%d actor=%.1f/%d node=%.1f/%d wstatic=%.1f/%d wnode=%.1f/%d defer=%.1f/%d skip=%.1f/%d other=%.1f ml=%.1f sreg=%.1f sadd=%.1f wp=%d instantiated=%d queue=%d burst=%s" % [
			total_inst_us / 1000.0,
			float(t_pre_collision - t_pre0) / 1000.0,
			float(t_pre_classify - start_time) / 1000.0,
			classified_refs,
			float(t_pre_request_start - t_pre_classify) / 1000.0,
			model_request_starts,
			float(t_pre_disk - t_pre_request_start) / 1000.0,
			float(t_pre_conv - t_pre_disk) / 1000.0,
			float(t_pre_prewarm - t_pre_conv) / 1000.0,
			float(t_pre_static_prepare - t_pre_prewarm) / 1000.0,
			static_prepare_count,
			float(phase_a_dispatch_us) / 1000.0,
			float(collision_finalize_us) / 1000.0,
			maxf(0.0, float(t_end_inst - t_pre_static_prepare - attach_time_us)) / 1000.0,
			float(attach_time_us) / 1000.0,
			float(route_static_us) / 1000.0,
			route_static_count,
			float(route_light_us) / 1000.0,
			route_light_count,
			float(route_actor_us) / 1000.0,
			route_actor_count,
			float(route_node_us) / 1000.0,
			route_node_count,
			float(route_worker_static_us) / 1000.0,
			route_worker_static_count,
			float(route_worker_node_us) / 1000.0,
			route_worker_node_count,
			float(route_deferred_us) / 1000.0,
			route_deferred_count,
			float(route_skip_us) / 1000.0,
			route_skip_count,
			float(route_other_us) / 1000.0,
			float(route_model_load_us) / 1000.0,
			float(route_static_register_us) / 1000.0,
			float(route_static_add_us) / 1000.0,
			worker_pending_count,
			instantiated,
			_instantiation_queue.size() + _pending_child_attaches.size(),
			"Y" if _burst_loading_active else "N",
		])
	return instantiated


## Phase A — dispatch WorkerThreadPool tasks for every cache-hit entry that
## hasn't been dispatched yet. Runs ONCE per process_async_instantiation call,
## before the drain loop. No popping here — entries stay queued until the
## drain consumes them.
##
## Per-entry gate (must ALL pass to dispatch):
##   - not already dispatched / completed (guards re-dispatch)
##   - `get_cached_packed_scene` returns non-null (cache-hit precondition —
##     worker only runs .instantiate, it does not disk-load)
##   - ESMManager.get_any_record returns a record on this ref_id
##   - `ReferenceInstantiator.should_dispatch_to_worker` passes — mirrors all
##     sync bailouts before get_model (type exclusion light/npc/creature/
##     leveled_*, STAT → static-renderer, proximity gate)
##
## Coarse bailouts for the whole pass:
##   - debug_lod=true (Log.debug calls inside _hide_lod_nodes are autoload
##     writes → sync path handles the whole frame)
##   - get_cached_packed_scene method missing (defensive, pre-§7.3 model_loader)
##
## Runtime guard: PHASE_A_OFFTHREAD_INSTANTIATE gates the call site; once true
## this function runs every drain frame.
func _phase_a_dispatch_pass() -> void:
	if _instantiator == null:
		return
	# §4b (2026-04-20 @roaster review) — debug_lod=true makes
	# MeshVisibilityUtils.hide_lod_and_materialless call Log.debug() from inside
	# _hide_lod_nodes. Log is an autoload → worker-unsafe per plan §5.2. Bail
	# the whole dispatch pass so debug_lod runs stay on the sync path.
	if _instantiator.debug_lod:
		return
	var ml: RefCounted = _instantiator.model_loader
	var start_us := Time.get_ticks_usec()
	var dispatched := 0
	if ml == null:
		return
	if not ml.has_method("get_cached_packed_scene"):
		return  # slice 3 API not present — defensive
	# The queue is sorted farthest-first and drained with pop_back(), so worker
	# dispatch must scan from the back as well. Scanning forward spent the tiny
	# dispatch budget on low-priority entries, then the drain immediately popped
	# high-priority entries that had not been dispatched and sync-instantiated
	# them on the main thread.
	for i in range(_instantiation_queue.size() - 1, -1, -1):
		var entry: InstantiationEntry = _instantiation_queue[i]
		# Skip entries already dispatched on either worker path, or whose
		# previous-frame worker result hasn't yet been consumed by the drain.
		if dispatched >= SC.WORKER_DISPATCH_MAX_PER_FRAME:
			break
		if Time.get_ticks_usec() - start_us >= SC.WORKER_DISPATCH_BUDGET_US:
			break
		if entry.worker_dispatched or entry.worker_static_dispatched:
			continue
		if entry.worker_instance != null or entry.worker_static_precomp != null:
			continue
		if entry.ref == null:
			continue

		# Resolve base_record + type_name on main thread — both Phase A and
		# Phase E gates need them. ESMManager is an autoload and worker-unsafe
		# per plan §5.1. Cheap (dict lookup).
		var record_type: Array = [""]
		var base_record: Variant = _resolve_source_reference_base_record(entry.ref, record_type)
		if base_record == null:
			continue
		var type_name: String = record_type[0] if record_type.size() > 0 else ""

		# ---- Phase A path (off-thread PackedScene.instantiate, interactives) ----
		# Cache-peek first — cheapest gate, drops ~20% of entries (cache miss)
		# before we spend the should_dispatch check. get_cached_packed_scene
		# returns null on miss / null sentinel / non-PackedScene entry.
		var packed_scene: PackedScene = ml.call("get_cached_packed_scene", entry.model_path, entry.cache_item_id)
		if packed_scene != null and _instantiator.should_dispatch_to_worker(entry, base_record, type_name):
			if entry.world_object_record == null:
				entry.world_object_record = _make_payload_record_from_ref(
					entry.ref,
					type_name,
					entry.model_path,
					entry.item_id,
					entry.cache_item_id,
					false,
					entry.cell_grid,
					base_record
				)
				if entry.world_object_record == null:
					continue
			# Stash resolved records so the drain's main-thread tail can reuse
			# them (avoids duplicate ESMManager lookup in complete_worker_instantiate).
			entry.phase_a_base_record = base_record
			entry.phase_a_type_name = type_name
			entry.worker_dispatched = true
			entry.worker_task_id = WorkerThreadPool.add_task(
				_instantiator._worker_instantiate.bind(entry, packed_scene, base_record, type_name),
				false,
				"cell_manager:phase_a_instantiate",
			)
			dispatched += 1
			continue

		# ---- Phase E path (off-thread STAT precompute, RS-routed clutter) ----
		# Mirror of Phase A for the ~80% STAT path that routes to
		# StaticObjectRenderer. Phase E worker reads _mesh_types (set-once
		# after register_from_prototype) + runs CS.* static math + composes
		# sub-mesh world xforms. Main-thread drain publishes via
		# complete_worker_static_precompute. See
		# phase_e_static_bulk_upload.md §3.
		if _instantiator.should_dispatch_static_precompute(entry, base_record, type_name):
			if entry.request_id not in _async_requests:
				continue
			var request: AsyncCellRequest = _async_requests[entry.request_id]
			var inst_cell_grid: Vector2i = request.grid if not request.is_interior else Vector2i.ZERO
			# Stash type_name so the drain's diag path knows to attribute to
			# "static" (complete_worker_static_precompute sets last_type_name
			# directly but the Phase-A-shaped diag uses entry.phase_a_type_name
			# to prime the renderer before the call).
			entry.phase_a_type_name = type_name
			entry.worker_static_dispatched = true
			entry.worker_static_task_id = WorkerThreadPool.add_task(
				_instantiator._worker_static_precompute.bind(entry, inst_cell_grid),
				false,
				"cell_manager:phase_e_static_precompute",
			)
			dispatched += 1


## Phase A — cancel worker instantiate tasks for a cancelled/unloaded request
## BEFORE the caller filters the queue. Plan §4 / §7.7.
##
## Worker tasks run off-thread; the caller is about to drop the InstantiationEntry
## from the queue, which orphans (a) any in-flight write to entry.worker_instance
## and (b) any already-produced Node3D that never reached the scene tree. This
## helper closes both leaks:
##
##   1. For dispatched-but-running tasks: wait_for_task_completion so the worker
##      finishes its write before we read worker_instance. Bounded at ~1 × the
##      per-entry instantiate cost (~11ms) per in-flight entry. Acceptable in
##      the unload path (already budgeted).
##   2. For completed tasks with a non-null worker_instance: queue_free it. The
##      Node3D is still detached (main thread never added_child'd), so this is
##      a thread-safe deferred destruct.
##
## Both cancel_async_request (interior-pocket teardown) and
## finalize_unloaded_cell (exterior cell unload) call this before their queue
## filter. Idempotent: entries that were never dispatched, or whose task is
## already consumed by the drain pass, are no-ops.
func _phase_a_cancel_workers_for_request(request_id: int) -> void:
	for entry: InstantiationEntry in _instantiation_queue:
		if entry.request_id != request_id:
			continue
		# Phase A (PackedScene.instantiate) cancellation.
		if entry.worker_dispatched:
			if entry.worker_task_id >= 0:
				# Block if the worker is still writing entry.worker_instance.
				# is_task_completed is the cheap check; wait_for_task_completion
				# is idempotent once the task is done.
				if not WorkerThreadPool.is_task_completed(entry.worker_task_id):
					WorkerThreadPool.wait_for_task_completion(entry.worker_task_id)
			if entry.worker_instance != null:
				entry.worker_instance.queue_free()
				entry.worker_instance = null
		# Phase E (STAT precompute) cancellation. Same wait-for-completion
		# discipline; unlike Phase A there's no Node3D to free — the worker
		# only produced a PrecomputedInstance struct, which is RefCounted and
		# self-destructs when we null the reference.
		if entry.worker_static_dispatched:
			if entry.worker_static_task_id >= 0:
				if not WorkerThreadPool.is_task_completed(entry.worker_static_task_id):
					WorkerThreadPool.wait_for_task_completion(entry.worker_static_task_id)
			entry.worker_static_precomp = null


## Sort instantiation queue by frustum-aware priority
## Objects in front of camera get priority; objects behind are deprioritized 4x
## Queue is sorted FARTHEST-first so pop_back() returns highest priority (nearest/in-frustum)
##
## PRIORITY LANES:
## - `interior_priority` entries sort to the tail ahead of everything else.
## - nearby player-local interactives/lights sort behind interior work but
##   ahead of distant visual/static tail work.
## Within each lane, existing distance/frustum ordering still applies.
## InteriorPocketManager flips this flag on all in-flight interior entries at
## the start of a transition so that the interior drains ahead of exterior
## streaming during the critical fade window.
func _sort_queue_by_priority() -> void:
	if _instantiation_queue.size() < 2:
		return
	if _instantiation_queue.size() > QUEUE_SORT_MAX_ITEMS:
		var start_index := _instantiation_queue.size() - QUEUE_SORT_MAX_ITEMS
		var priority_window: Array[InstantiationEntry] = []
		for i in range(start_index, _instantiation_queue.size()):
			priority_window.append(_instantiation_queue[i])
		_sort_entries_by_priority(priority_window)
		for i in range(priority_window.size()):
			_instantiation_queue[start_index + i] = priority_window[i]
		return

	_sort_entries_by_priority(_instantiation_queue)


func _sort_entries_by_priority(entries: Array[InstantiationEntry]) -> void:
	if entries.size() < 2:
		return

	var cam_pos := _camera_position
	var cam_fwd := _camera_forward

	# Pre-calculate priorities to avoid expensive lambda logic during sort
	# GDScript sort_custom is much faster with simple float comparisons
	var priorities := {} # entry -> float
	for entry in entries:
		var pos: Vector3 = entry.position
		var dist_sq := cam_pos.distance_squared_to(pos)

		if cam_fwd != Vector3.ZERO:
			var dir := (pos - cam_pos)
			# Frustum penalty: objects behind camera (dot < 0.3) get 4x distance penalty
			if dist_sq > 1.0 and cam_fwd.dot(dir) < 0.3 * dir.length():
				dist_sq *= 4.0

		priorities[entry] = dist_sq

	entries.sort_custom(func(a: InstantiationEntry, b: InstantiationEntry) -> bool:
		# PRIMARY KEY: priority lane. Non-priority entries come first (head
		# of the array); priority entries go to the tail so pop_back() takes
		# them first. Returning `false` when a is priority and b is not puts
		# a AFTER b; returning `true` when a is non-priority and b is priority
		# puts a BEFORE b.
		if a.interior_priority != b.interior_priority:
			return not a.interior_priority  # non-priority before priority
		if a.player_local_priority != b.player_local_priority:
			return not a.player_local_priority
		# LAST KEY: existing distance/frustum priority. Farthest first,
		# so pop_back() returns nearest/highest-priority within the lane.
		return priorities[a] > priorities[b]
	)


func _sort_model_request_start_queue_by_priority() -> void:
	if _model_request_start_queue.size() < 2:
		return
	_model_request_start_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_priority := _request_has_interior_priority(int(a.get("request_id", -1)))
		var b_priority := _request_has_interior_priority(int(b.get("request_id", -1)))
		if a_priority != b_priority:
			return not a_priority
		return str(a.get("model_path", "")) > str(b.get("model_path", ""))
	)


# =============================================================================
# POOL PRE-WARMING IMPLEMENTATION
# =============================================================================

## Queue models for pre-warming based on nearby objects
## Called when objects are registered with ObjectStreamer
func queue_prewarm(model_path: String, count: int = 1) -> void:
	if not pool_prewarm_enabled or not _object_pool:
		return

	var normalized := model_path.to_lower().replace("/", "\\")

	# Check if pool already has enough available
	if _object_pool.has_method("get_available_count"):
		var available: int = _object_pool.get_available_count(normalized)
		if available >= SC.POOL_PREWARM_MAX_PER_MODEL:
			return

	# Add to pending pre-warm
	var current: int = _prewarm_pending.get(normalized, 0)
	_prewarm_pending[normalized] = mini(current + count, SC.POOL_PREWARM_MAX_PER_MODEL)


## Process pool pre-warming within budget
func _process_pool_prewarm() -> void:
	if _prewarm_pending.is_empty() or not _object_pool:
		return

	var prewarmed := 0
	var to_remove: Array[String] = []

	for model_path: String in _prewarm_pending:
		if prewarmed >= _prewarm_per_frame:
			break

		var count: int = _prewarm_pending[model_path]
		var remaining := _prewarm_per_frame - prewarmed

		# Only pre-warm if pool has the model registered
		if _object_pool.has_method("prewarm"):
			var created: int = _object_pool.prewarm(model_path, mini(count, remaining))
			prewarmed += created

			if created >= count:
				to_remove.append(model_path)
			else:
				_prewarm_pending[model_path] = count - created

	# Remove completed entries
	for path in to_remove:
		_prewarm_pending.erase(path)


## Check if burst loading is currently active
func is_burst_loading() -> bool:
	return _burst_loading_active




## Internal: Start an async request
func _start_async_request(
	cell: Variant,
	grid: Vector2i,
	is_interior: bool,
	profile: LoadProfile = null,
	world_objects: Array = [],
	uses_world_manifest: bool = false,
	cell_name: String = "",
) -> int:
	var request := AsyncCellRequest.new()
	request.cell_record = cell
	request.grid = grid
	request.is_interior = is_interior
	request.uses_world_manifest = uses_world_manifest
	request.world_objects_to_classify = world_objects.duplicate()
	# Default to exterior profile if caller didn't provide one. Having a
	# non-null profile on every request simplifies _queue_instantiation and
	# _process_instantiation_queue (no null checks on the hot path).
	request.load_profile = profile if profile else LoadProfile.exterior_default()
	request.request_id = _next_async_id
	_next_async_id += 1
	request.payload = CellPayloadScript.new(grid)
	request.payload.configure_publish_driver(Callable(self, "_publish_payload_step"))
	request.state = CellPayloadScript.State.PREPARING_PAYLOAD
	request.payload.state = request.state

	# Create the cell node
	request.cell_node = Node3D.new()
	if is_interior:
		var interior_name := cell_name
		if interior_name.is_empty() and cell != null and "name" in cell:
			interior_name = str(cell.name)
		if interior_name.is_empty():
			interior_name = "Interior"
		request.cell_node.name = interior_name.replace(" ", "_").replace(",", "")
	else:
		request.cell_node.name = "Cell_%d_%d" % [grid.x, grid.y]

	# Store request BEFORE processing so _queue_instantiation can find it
	_async_requests[request.request_id] = request

	return request.request_id


## Internal: Submit a source-model parse task to background processor.
## Source archive extraction and format parsing are owned by the asset provider.
func _submit_parse_task(model_path: String, item_id: String, _request_id: int) -> int:
	if _asset_provider == null or not _asset_provider.has_method("submit_model_parse_task"):
		return -1
	return int(_asset_provider.call("submit_model_parse_task", _background_processor, model_path, item_id))


func _is_provider_parse_result_valid(parse_result: Variant) -> bool:
	return _asset_provider != null \
		and _asset_provider.has_method("is_model_parse_result_valid") \
		and bool(_asset_provider.call("is_model_parse_result_valid", parse_result))


func _get_provider_parse_result_item_id(parse_result: Variant) -> String:
	if _asset_provider == null or not _asset_provider.has_method("get_model_parse_result_item_id"):
		return ""
	return str(_asset_provider.call("get_model_parse_result_item_id", parse_result))


func _create_provider_model_scene_from_parse_result(parse_result: Variant) -> Node3D:
	if _asset_provider == null or not _asset_provider.has_method("create_model_scene_from_parse_result"):
		return null
	return _asset_provider.call("create_model_scene_from_parse_result", parse_result) as Node3D


## Internal: Handle parse completion from background processor
func _on_parse_completed(task_id: int, result: Variant) -> void:
	# First check if this is a preload task
	if _check_preload_completion(task_id, result):
		return  # Was handled as preload

	# Find which cell request this belongs to
	for request_id: int in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]

		for model_path: String in request.pending_parses:
			if request.pending_parses[model_path] == task_id:
				# Found it - store result
				request.pending_parses.erase(model_path)

				var parse_success := false
				var convert_start := Time.get_ticks_usec()

				if _is_provider_parse_result_valid(result):
					request.parsed_results[model_path] = result
					parse_success = true

					# DEFERRED CONVERSION: Queue for processing in process_pending_conversions()
					# This prevents 300ms-6s freezes when complex source models finish parsing
					_pending_conversions.append({
						"parse_result": result,
						"model_path": model_path,
						"request_id": request_id,
						"item_id": _get_provider_parse_result_item_id(result)
					})
				else:
					request.failed_models.append(model_path)

				var convert_elapsed := (Time.get_ticks_usec() - convert_start) / 1000.0

				# NOTE: Conversion and reference queuing is now DEFERRED
				# See process_pending_conversions() which handles both
				# This prevents 300ms-6s freezes when complex models complete

				return


## Internal: Queue references that were waiting for a model to be parsed
func _queue_references_for_model(request: AsyncCellRequest, model_path: String) -> void:
	var remaining: Array = []

	for pending: Variant in request.references_to_process:
		var payload: Dictionary = pending if pending is Dictionary else {}
		var record: RefCounted = payload.get("record", null) as RefCounted
		var ref: Variant = payload.get("ref", pending)
		var base_record: Variant = payload.get("base_record", null)
		var type_name: String = str(payload.get("type_name", ""))
		var item_id: String = str(payload.get("item_id", ""))
		var cache_item_id: String = str(payload.get("cache_item_id", item_id))
		var object_id: StringName = payload.get("object_id", &"")
		if record != null:
			object_id = _object_id_for_record(record)
			var ref_model_path: String = str(record.get("model_path"))
			if ref_model_path.to_lower().replace("/", "\\") == model_path.to_lower().replace("/", "\\"):
				_queue_instantiation(request.request_id, null, model_path, item_id, cache_item_id, type_name, object_id, record)
			else:
				remaining.append(pending)
			continue
		if ref == null:
			continue
		if base_record == null:
			var record_type: Array = [""]
			base_record = _resolve_source_reference_base_record(ref, record_type)
			type_name = record_type[0] if record_type.size() > 0 else ""
			if "record_id" in base_record:
				item_id = base_record.record_id
				cache_item_id = item_id

		var ref_model_path: String = _get_model_path(base_record)
		if ref_model_path.to_lower().replace("/", "\\") == model_path.to_lower().replace("/", "\\"):
			# This reference uses the model that was just parsed
			record = _make_payload_record_from_ref(
				ref,
				type_name,
				model_path,
				item_id,
				cache_item_id,
				false,
				request.grid,
				base_record
			)
			object_id = _object_id_for_record(record) if record != null else object_id
			_queue_instantiation(request.request_id, null if record != null else ref, model_path, item_id, cache_item_id, type_name, object_id, record)
		else:
			remaining.append(pending)

	request.references_to_process = remaining


## Internal: Check if an async request is complete
func _is_request_complete(request: AsyncCellRequest) -> bool:
	var static_prepare_count := request.payload.get_static_prepare_queue_size() if request.payload != null else 0
	return request.classification_complete \
		and request.pending_parses.is_empty() \
		and _get_pending_model_load_count_for_request(request) <= 0 \
		and static_prepare_count <= 0 \
		and request.references_to_process.is_empty() \
		and _get_pending_child_attach_count_for_request(request.request_id) <= 0 \
		and request.pending_instantiations <= 0


## Internal: Create a callback for async disk load completion
## This is called when ModelLoader finishes loading a model from disk cache
func _make_disk_load_callback(request_id: int, model_path: String, _item_id: String) -> Callable:
	return func(loaded_model_path: String, loaded_item_id: String, model: Node3D) -> void:
		_on_disk_load_completed(request_id, loaded_model_path, loaded_item_id, model)


## Internal: Handle async disk load completion
func _on_disk_load_completed(request_id: int, model_path: String, item_id: String, _model: Node3D) -> void:
	var pending_key := _get_cache_key(model_path, item_id)
	var start_key := _model_request_start_key(request_id, pending_key)
	_model_request_start_active.erase(start_key)
	_model_request_start_queued.erase(start_key)

	if request_id not in _async_requests:
		return  # Request was cancelled

	var request: AsyncCellRequest = _async_requests[request_id]
	if request == null or request.payload == null:
		return

	# Check if cell_node is still valid (cell may have been unloaded)
	if not is_instance_valid(request.cell_node):
		request.payload.discard_pending_model_load(pending_key)
		if _is_request_complete(request):
			request.completed = true
			request.failed = true
			request.error_message = "Cell node freed during disk load"
		return

	_pin_payload_cached_scene(request, model_path, item_id)
	request.payload.mark_model_load_completed(pending_key, request_id, model_path, item_id)


## Helper methods delegated to ReferenceInstantiator
## These are thin wrappers used by async loading code

func _get_model_path(record: Variant) -> String:
	return _instantiator._get_model_path(record)


# REMOVED: _instantiate_reference_from_parsed (duplicate fast-path).
# Raw source refs are now wrapped through the spawn adapter as WorldObjectRecord
# payloads before publication. The duplicate
# silently skipped DoorInteractable attach (I.7), carryable RigidBody
# conversion (I.1), _apply_metadata, and _auto_play_nif_animation — see
# the "Simplicity Over Over-Engineering" principle in .claude/CLAUDE.md
# for why two parallel instantiation paths is a drift landmine.


## Check if a cell reference must always use the NEAR (full Node3D) path
## Returns true for lights, NPCs, creatures — these need physics, interaction, or animation
## Internal: Finalize a request (mark completed). Phase 3 step 7 removed the
## per-cell MultiMesh batcher — MID instances are already routed through the
## world-scoped PrototypeRegistry at add-time by static_object_renderer.
func _finalize_request(request: AsyncCellRequest) -> void:
	if request.completed:
		return
	request.completed = true
	request.state = CellPayloadScript.State.VISUAL_READY
	if request.payload != null:
		request.payload.state = request.state


## Phase 4 / statics_no_node3d T.2 + Win 1 (NEAR refactor 2026-04-25) — per-frame
## tick that builds the merged collision StaticBody3D for each cell ONCE its
## static models have loaded.
##
## Why a tick and not a `_finalize_request` hook: proximity-deferred interactive
## refs re-increment `pending_instantiations` at process time, which means
## `_is_request_complete` stays false forever for any cell where the player
## hasn't walked within the proximity threshold of an interactive ref. The T.2 build only needs
## static models loaded, not every interactive spawned — so it fires on the
## earlier signal (`pending_parses.is_empty && payload model callbacks empty`).
##
## Interior pockets (`load_profile.use_static_renderer=false`) skip early via
## `collect_payload_static_entries`'s first guard; their refs have per-Node3D collision.
##
## Win 1 split: two phases per tick.
##   1. DISPATCH — for any ready cell that hasn't been dispatched, classify on
##      main and submit a WorkerThreadPool task to build vertices off-thread.
##      Cheap; can dispatch many cells per frame because work runs in workers.
##   2. DRAIN — for any cell whose worker has completed, run `finalize_body`
##      on main (BVH `set_faces` + StaticBody3D assembly) and attach. Limited
##      to one finalize per frame to bound the BVH build spike.
##
## Cold-cache cell wall-clock used to be 20-50ms entirely on main; post-Win 1
## the worker absorbs most of it (triangle assembly + transform), main pays
## only the ~10-20ms BVH build.
func _tick_static_collision_build(
	allow_finalize: bool = true,
	dispatch_budget_usec: int = -1,
	max_dispatches: int = -1,
) -> int:
	if SC.DEBUG_DISABLE_CELL_STATIC_COLLISION:
		for request_id: int in _async_requests:
			var request: AsyncCellRequest = _async_requests[request_id]
			if request.payload.collision_built:
				continue
			_drain_collision_worker_for_request(request)
			request.payload.collision_built = true
			request.payload.collision_dispatched = true
		return 0

	# Phase 1: dispatch — for each cell ready and not yet dispatched, classify
	# on main and fire a worker task. Cheap (O(N_refs) main work, no BVH).
	var dispatch_start_us := Time.get_ticks_usec()
	var dispatched_this_tick := 0
	for request_id: int in _async_requests:
		if max_dispatches >= 0 and dispatched_this_tick >= max_dispatches:
			break
		if dispatch_budget_usec >= 0 and Time.get_ticks_usec() - dispatch_start_us >= dispatch_budget_usec:
			break
		var request: AsyncCellRequest = _async_requests[request_id]
		if request.payload.collision_built or request.payload.collision_dispatched:
			continue
		if not request.classification_complete:
			continue
		if not request.pending_parses.is_empty():
			continue
		if _get_pending_model_load_count_for_request(request) > 0:
			continue
		if not is_instance_valid(request.cell_node):
			# Cell already torn down / never built. Mark built so we never retry.
			request.payload.collision_built = true
			continue
		# Win 2: skip cells in unload-container limbo. native_streaming_manager
		# `_unload_cell` sets cell_node.visible=false but keeps the cell_node
		# alive for state-reversal. Building physics here would be wasted
		# work (the body would get freed seconds later by finalize_unloaded
		# _cell). cancel_collision_build_for_request drained any in-flight
		# build at limbo start; this guard catches the rare edge case where
		# the limbo entry races with the next tick.
		if not request.cell_node.visible:
			continue

		var use_static: bool = true
		if request.load_profile != null:
			use_static = request.load_profile.use_static_renderer

		# Payload was built during request classification, so collision never
		# needs to walk source parser records.
		var payload: Variant = _cell_static_collision.collect_payload_static_entries(request.grid, request.payload, use_static)
		if payload == null:
			# Nothing to build for this cell (interior pocket or no static refs).
			request.payload.collision_built = true
			continue

		request.payload.collision_payload = payload
		# High priority — racing the cell's draw / interaction hooks. Worker
		# does pure data work, no autoload/scene-tree access. Mirror Phase F's
		# task-id tracking pattern.
		request.payload.collision_task_id = WorkerThreadPool.add_task(
			_cell_static_collision.worker_collect_triangles.bind(payload),
			true,
			"cell_static_collision:collect_triangles",
		)
		request.payload.collision_dispatched = true
		_record_lifecycle_event("collision_dispatched", request.grid, "request=%d" % request_id)
		dispatched_this_tick += 1

	if not allow_finalize:
		return 0

	# Phase 2: drain — for each cell whose worker finished, finalize on main.
	# One per frame to bound `set_faces` BVH-build cost (~10-20ms cold).
	#
	# Win 3 (NEAR refactor 2026-04-25): collect READY candidates first, sort
	# by camera distance, finalize closest first. Without this, dict iteration
	# order is insertion order — on a teleport (3-9 cells dispatch in one
	# frame) the chronologically-first cell would drain first regardless of
	# its position relative to the player. Closest-first matters because the
	# player is likely to interact with nearby geometry FIRST (ball drop, walk
	# into rock, etc); distant cells can wait their 1-frame turn.
	#
	# 1-cell-per-frame floor preserved as the safe default. A microsecond
	# budget loop can be added later if measurement shows multiple finalizes
	# per frame are needed, but Wins 1+2 should have brought the per-cell
	# main-thread work down enough that 1/frame is comfortable.
	var ready: Array[int] = []
	for request_id: int in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]
		if request.payload.collision_built:
			continue
		if not request.payload.collision_dispatched:
			continue
		if request.payload.collision_task_id < 0 and request.payload.collision_payload == null:
			continue
		if request.payload.collision_task_id >= 0 and not WorkerThreadPool.is_task_completed(request.payload.collision_task_id):
			continue
		ready.append(request_id)

	if ready.is_empty():
		return 0

	# Sort by camera distance to cell center. Interior cells (no grid in the
	# exterior sense) end up using Vector2i.ZERO which sorts them based on
	# world origin distance — fine for the rare interior+exterior overlap.
	if ready.size() > 1:
		var cam: Vector3 = _camera_position
		ready.sort_custom(func(a: int, b: int) -> bool:
			var ga: Vector2i = _async_requests[a].grid
			var gb: Vector2i = _async_requests[b].grid
			var pa := DU.cell_to_world_center(ga, 0.0)
			var pb := DU.cell_to_world_center(gb, 0.0)
			return cam.distance_squared_to(pa) < cam.distance_squared_to(pb))

	var winner_id: int = ready[0]
	var winner: AsyncCellRequest = _async_requests[winner_id]

	# Worker done — finalize one bounded collision slice on main.
	winner.state = CellPayloadScript.State.PHYSICS_PUBLISHING
	if winner.payload != null:
		winner.payload.state = winner.state
	var task_id: int = winner.payload.collision_task_id
	var payload: Variant = winner.payload.collision_payload

	# Defensive — wait_for_task_completion is idempotent once done; pairs
	# with the is_task_completed gate above. Required by Godot's
	# WorkerThreadPool contract to release task resources.
	if task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(task_id)
		winner.payload.collision_task_id = -1

	if not is_instance_valid(winner.cell_node):
		# Cell torn down between dispatch and drain — discard worker output.
		winner.payload.collision_built = true
		winner.payload.collision_payload = null
		return 0

	# Win 2 — server-direct: finalize_body needs World3D for the physics
	# space registration. Pulled from cell_node which is in the tree by
	# this point (verified by is_instance_valid above + add-child sequence
	# during cell construction).
	if not winner.cell_node.visible:
		# Unload limbo or visibility reversal in progress. Do not publish a
		# server-direct body for a cell that is not currently playable.
		return 0

	var world: World3D = winner.cell_node.get_world_3d()
	if world == null:
		# Defensive — would only fire if cell_node was reparented out of a
		# viewport between dispatch and drain. Skip the build; collision
		# stays absent for this cell. Surfaces as ball-falls-through-rock
		# during play, which is more visible than a silent free.
		push_warning("CellStaticCollision: cell %s has no World3D — skipping body register" % str(winner.grid))
		winner.payload.collision_built = true
		winner.payload.collision_payload = null
		return 0

	var finalize_start_us := Time.get_ticks_usec()
	var finalized: Variant = _cell_static_collision.finalize_body_slice(
		payload,
		world,
		SC.CELL_STATIC_COLLISION_FINALIZE_MAX_TRIS_PER_FRAME,
	)
	var finalize_us := Time.get_ticks_usec() - finalize_start_us
	if finalized != null:
		winner.payload.collision_body = finalized
	var tri_count := 0
	var total_tri_count := 0
	var worker_us := 0
	var complete := true
	if payload != null:
		total_tri_count = int(payload.vertices.size() / 3)
		tri_count = mini(SC.CELL_STATIC_COLLISION_FINALIZE_MAX_TRIS_PER_FRAME, total_tri_count)
		worker_us = int(payload.build_time_us)
		complete = bool(_cell_static_collision.is_finalize_complete(payload))
	if finalize_us > 8_000:
		Log.warn("streaming", "[collision-finalize %.1fms] cell=%s tris=%d/%d worker=%.1fms ready=%d done=%s" % [
			finalize_us / 1000.0,
			str(winner.grid),
			tri_count,
			total_tri_count,
			float(worker_us) / 1000.0,
			ready.size(),
			"Y" if complete else "N",
		])
	if complete:
		winner.payload.collision_built = true
		winner.payload.collision_payload = null
		winner.state = CellPayloadScript.State.ACTIVE
		if winner.payload != null:
			winner.payload.state = winner.state
		_record_lifecycle_event("collision_finalized", winner.grid, "request=%d tris=%d" % [
			winner_id,
			total_tri_count,
		])
	return finalize_us


func _maybe_finalize_static_collision_when_idle(start_time_usec: int, budget_usec: float) -> int:
	if SC.DEBUG_DISABLE_CELL_STATIC_COLLISION:
		return 0
	if _has_collision_blocking_visual_work():
		return 0
	var elapsed_us := float(Time.get_ticks_usec() - start_time_usec)
	if elapsed_us >= budget_usec:
		return 0
	var remaining_us := budget_usec - elapsed_us
	if remaining_us < SC.CELL_STATIC_COLLISION_FINALIZE_MIN_REMAINING_MS * 1000.0:
		return 0
	return _tick_static_collision_build(
		true,
		int(minf(SC.CELL_STATIC_COLLISION_DISPATCH_BUDGET_MS * 1000.0, remaining_us)),
		SC.CELL_STATIC_COLLISION_DISPATCH_MAX_PER_FRAME,
	)


func _has_collision_blocking_visual_work() -> bool:
	if not _instantiation_queue.is_empty():
		return true
	if not _pending_child_attaches.is_empty():
		return true
	if _get_static_prepare_queue_size() > 0:
		return true
	for request_id: int in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]
		if request == null:
			continue
		if not request.classification_complete:
			return true
		if not request.pending_parses.is_empty():
			return true
		if _get_pending_model_load_count_for_request(request) > 0:
			return true
		if not request.references_to_process.is_empty():
			return true
	return false


## Win 1 + Win 2 — wait on any in-flight collision worker for the request,
## release the worker payload, AND free the server-direct body if one was
## already finalized. Called from cancel paths (cancel_async_request,
## finalize_unloaded_cell, fast_cleanup) BEFORE the request is erased so:
## - the worker doesn't write into a dead payload after we drop our last ref
## - the PhysicsServer3D body is removed from the broadphase before the
##   underlying Shape3D resource is GC'd (Win 2 RID-lifetime hazard)
##
## Idempotent — no-op when no worker is dispatched and no body is finalized.
##
## The payload itself is RefCounted; once both `request.payload.collision_payload`
## and the worker's `.bind()` release, GDScript's refcount reaper collects it.
func _drain_collision_worker_for_request(request: AsyncCellRequest) -> void:
	if request == null:
		return
	if request.payload == null:
		return
	# Drain in-flight worker first so it doesn't race with payload teardown.
	if request.payload.collision_task_id >= 0:
		# wait_for_task_completion is idempotent once done; required by the
		# WorkerThreadPool contract to release task resources.
		WorkerThreadPool.wait_for_task_completion(request.payload.collision_task_id)
		request.payload.collision_task_id = -1
	request.payload.collision_payload = null
	# Win 2 — free the server-direct body if one was finalized. MUST run
	# before the cell_node teardown elsewhere; PhysicsServer3D doesn't care
	# about the cell_node, but freeing first means the body is gone from the
	# broadphase before any stale references could become an issue.
	if request.payload.collision_body != null:
		CellStaticCollisionScript.free_body(request.payload.collision_body)
		request.payload.collision_body = null
	# Mark built so the drain phase doesn't try to finalize on a cancelled cell.
	request.payload.collision_built = true


## Win 2 — public hook: drain the collision build for a request that's about
## to enter the unload-container limbo. Called from native_streaming_manager.
## _unload_cell BEFORE the cell's request_id is moved into _unloading_request_ids.
##
## Why this is separate from `cancel_async_request`/`finalize_unloaded_cell`:
## the unload-container pattern keeps the AsyncCellRequest alive across the
## limbo window for state-reversal. We don't want to erase the request here,
## just stop the collision build (no point finalizing a body for a cell the
## player has walked past — Jolt would briefly insert it into the broadphase
## then immediately remove it on the next finalize_unloaded_cell call). This
## hook drains the worker + frees any already-finalized body without touching
## anything else on the request.
##
## Resets collision_built + collision_dispatched so that if state-reversal
## reclaims the cell, the dispatch phase fires again on the next tick. The
## dispatch phase guards on `cell_node.visible` to avoid rebuilding while
## the cell sits in limbo (hidden but cell_node still alive).
##
## Idempotent: no-op when the request isn't tracked or has no collision work.
func cancel_collision_build_for_request(request_id: int) -> void:
	if request_id not in _async_requests:
		return
	var request: AsyncCellRequest = _async_requests[request_id]
	_drain_collision_worker_for_request(request)
	# Re-arm for reclaim: clear the flags so the dispatch phase can rebuild
	# if the cell comes back via state-reversal. The dispatch gate on
	# cell_node.visible prevents wasted work while the cell is in limbo.
	request.payload.collision_built = false
	request.payload.collision_dispatched = false
	_record_lifecycle_event("collision_rearmed", request.grid, "request=%d" % request_id)


## Internal: Queue an object for instantiation with limit checking
## Includes object position for distance-priority sorting
## S.1: queue-time classification (always_near / mid_worthy) removed — per-cell
## tier is the axis of variation, every queued ref becomes a Node3D.
func _queue_instantiation(
	request_id: int,
	ref: Variant,
	model_path: String,
	item_id: String,
	cache_item_id: String = "",
	type_name: String = "",
	object_id: StringName = &"",
	world_object_record: RefCounted = null,
) -> bool:
	# Check queue limit to prevent memory buildup
	if _instantiation_queue.size() >= MAX_INSTANTIATION_QUEUE:
		push_warning("CellManager: Instantiation queue full (%d items), dropping object" % MAX_INSTANTIATION_QUEUE)
		return false

	# Get object position for distance-priority sorting
	var position := Vector3.ZERO
	if world_object_record != null:
		var transform_value: Variant = world_object_record.get("transform")
		if transform_value is Transform3D:
			position = (transform_value as Transform3D).origin
	elif ref != null:
		position = CS.vector_to_godot(ref.position)
	else:
		return false

	var entry := InstantiationEntry.new()
	entry.request_id = request_id
	entry.ref = ref
	entry.world_object_record = world_object_record
	entry.world_object_id = object_id
	entry.model_path = model_path
	entry.item_id = item_id
	entry.cache_item_id = cache_item_id
	entry.position = position
	entry.type_name = type_name
	var owning_request: AsyncCellRequest = _async_requests.get(request_id) if request_id in _async_requests else null
	entry.cell_grid = owning_request.grid if owning_request != null and not owning_request.is_interior else Vector2i.ZERO
	entry.player_local_priority = _is_player_local_interactive_priority(type_name, position)

	# Copy the per-request LoadProfile onto the entry so the instantiation
	# queue processor can read it without a dictionary lookup, and so that
	# concurrent loads with different profiles don't collide on shared state.
	if owning_request and owning_request.load_profile:
		entry.load_profile = owning_request.load_profile
		entry.interior_priority = owning_request.load_profile.interior_priority
		if not model_path.is_empty() and world_object_record != null:
			if _should_prepare_static_record(world_object_record, model_path, owning_request.load_profile, cache_item_id):
				entry.static_prepare_key = model_path.to_lower().replace("/", "\\")
				_enqueue_static_prepare(request_id, model_path, cache_item_id)
		elif not model_path.is_empty() and object_id == &"":
			var record_type: Array = [""]
			var base_record: Variant = _resolve_source_reference_base_record(ref, record_type)
			if base_record != null:
				var record_type_name: String = record_type[0] if record_type.size() > 0 else ""
				if _should_prepare_static_ref(base_record, record_type_name, model_path, owning_request.load_profile, cache_item_id, ref):
					entry.static_prepare_key = model_path.to_lower().replace("/", "\\")
					_enqueue_static_prepare(request_id, model_path, cache_item_id)

	_instantiation_queue.append(entry)

	# Track pending instantiation count for completion checking
	if owning_request:
		owning_request.pending_instantiations += 1

	return true


func _is_player_local_interactive_priority(type_name: String, position: Vector3) -> bool:
	var threshold := ReferenceInstantiator.INTERACTIVE_PROXIMITY_THRESHOLD_M
	match type_name:
		"light":
			threshold = ReferenceInstantiator.LIGHT_PROXIMITY_THRESHOLD_M
		"door", "container", "activator":
			pass
		_:
			return false
	return position.distance_squared_to(_camera_position) <= threshold * threshold


## Internal: Get cache key for a model
func _get_cache_key(model_path: String, item_id: String) -> String:
	var normalized := model_path.to_lower().replace("/", "\\")
	if not item_id.is_empty():
		return normalized + ":" + item_id.to_lower()
	return normalized


## Hide LOD sibling nodes and materialless meshes in a scene tree
## Calls MeshVisibilityUtils directly for consistent behavior
## CRITICAL: Must be called after every duplicate() to prevent white mesh overlays
func _hide_lod_nodes(node: Node) -> void:
	MeshVisibilityUtils.hide_lod_and_materialless(node)


## Get count of pending async requests
func get_async_pending_count() -> int:
	var count := 0
	for request_id: int in _async_requests:
		var request: AsyncCellRequest = _async_requests.get(request_id)
		if request and not request.completed:
			count += 1
	return count


## Get total objects waiting in instantiation queue
func get_instantiation_queue_size() -> int:
	return _instantiation_queue.size() + _pending_child_attaches.size()


## Step 1 instrumentation — per-frame instantiation timing buckets keyed by
## ESM record type. Last call to `process_async_instantiation` populated these.
## Read by `streaming_benchmark` for CSV per-frame columns.
##
## Plan: docs/plans/near_streaming_2026_04_28_interactive_spawn.md step 1.
func get_frame_inst_route_times() -> Dictionary:
	return {
		"door": _frame_inst_door_us,
		"light": _frame_inst_light_us,
		"light_modelload": _frame_inst_light_modelload_us,
		"container": _frame_inst_container_us,
		"activator": _frame_inst_activator_us,
		"static": _frame_inst_static_us,
	}


func consume_lifecycle_events() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _lifecycle_events.size() < MAX_LIFECYCLE_EVENTS:
		out.append_array(_lifecycle_events)
	else:
		var start := _lifecycle_event_write_index % MAX_LIFECYCLE_EVENTS
		for i in range(MAX_LIFECYCLE_EVENTS):
			out.append(_lifecycle_events[(start + i) % MAX_LIFECYCLE_EVENTS])
	_lifecycle_events.clear()
	_lifecycle_event_write_index = 0
	return out


func set_lifecycle_capture_enabled(enabled: bool) -> void:
	debug_lifecycle_capture_enabled = enabled
	_lifecycle_events.clear()
	_lifecycle_event_write_index = 0


func _record_lifecycle_event(event_name: String, grid: Vector2i, detail: String = "") -> void:
	if not debug_lifecycle_capture_enabled:
		return
	var entry := {
		"frame": Engine.get_frames_drawn(),
		"elapsed_s": Time.get_ticks_msec() / 1000.0,
		"event": event_name,
		"detail": "%s %s" % [str(grid), detail],
	}
	if _lifecycle_events.size() < MAX_LIFECYCLE_EVENTS:
		_lifecycle_events.append(entry)
	else:
		_lifecycle_events[_lifecycle_event_write_index % MAX_LIFECYCLE_EVENTS] = entry
	_lifecycle_event_write_index += 1
	Log.info("streaming", "[P0.4-LIFECYCLE] %s %s" % [event_name, entry["detail"]])


## Get comprehensive loading stats
func get_loading_stats() -> Dictionary:
	var payloads := 0
	var pinned_resources := 0
	var pending_model_loads := 0
	for request_id: int in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]
		if request != null and request.payload != null:
			payloads += 1
			pinned_resources += int(request.payload.stats.get("pinned_resources", 0))
		if request != null:
			pending_model_loads += _get_pending_model_load_count_for_request(request)
	var pending_conversions := maxi(0, _pending_conversions.size() - _pending_conversion_index)
	var instantiator_route_usage: Dictionary = {}
	if _instantiator != null and _instantiator.has_method("get_route_usage_stats"):
		instantiator_route_usage = _instantiator.call("get_route_usage_stats")
	return {
		"instantiation_queue_size": _instantiation_queue.size() + _pending_child_attaches.size(),
		"pending_child_attaches": _pending_child_attaches.size(),
		"active_async_load_slots": _get_active_async_load_slot_count(),
		"resident_async_requests": _async_requests.size(),
		"pending_conversions": pending_conversions,
		"pending_disk_loads": get_pending_disk_load_count() + pending_model_loads,
		"model_request_start_queue": _model_request_start_queue.size(),
		"model_request_start_active": _model_request_start_active.size(),
		"static_prepare_queue": _get_static_prepare_queue_size(),
		"proximity_deferred": _proximity_deferred.size(),
		"proximity_deferred_by_type": get_proximity_deferred_counts(),
		"cell_payloads": payloads,
		"cell_payload_pinned_resources": pinned_resources,
		"burst_loading_active": _burst_loading_active,
		"burst_budget_ms": _burst_budget_ms,
		"burst_max_instantiations": _burst_max_instantiations,
		"prewarm_pending_count": _prewarm_pending.size(),
		"route_usage": _route_usage_stats.duplicate(),
		"instantiator_route_usage": instantiator_route_usage,
		"objects_instantiated": int(_stats.get("objects_instantiated", 0)) + int(_instantiator.stats.get("objects_instantiated", 0)),
		"objects_from_pool": int(_stats.get("objects_from_pool", 0)) + int(_instantiator.stats.get("objects_from_pool", 0)),
		"avg_instantiate_time_us": (_diag_instantiate_time_total_us / _diag_instantiate_count) if _diag_instantiate_count > 0 else 0
	}


## Get overall stats including pool stats
func get_stats() -> Dictionary:
	var result := _stats.duplicate()
	result["route_usage"] = _route_usage_stats.duplicate()
	if _instantiator != null and _instantiator.has_method("get_route_usage_stats"):
		result["instantiator_route_usage"] = _instantiator.call("get_route_usage_stats")

	# Merge instantiator stats. Post-drift-fix the instantiator owns the
	# objects_instantiated / objects_from_pool / lights_created counters for
	# the streaming queue path (Step 3 of _process_instantiation_queue).
	for key in ["objects_instantiated", "objects_from_pool", "lights_created"]:
		result[key] = int(result.get(key, 0)) + int(_instantiator.stats.get(key, 0))

	# Add pool stats if pool is available
	if _object_pool and _object_pool.has_method("get_stats"):
		var pool_stats: Dictionary = _object_pool.call("get_stats")
		result["pool_available"] = pool_stats.get("total_available", 0)
		result["pool_in_use"] = pool_stats.get("total_in_use", 0)
		result["pool_total_pools"] = pool_stats.get("total_pools", 0)
		result["pool_hit_rate"] = pool_stats.get("hit_rate", 0.0)
		result["pool_new_instances"] = pool_stats.get("new_instances_created", 0)
		result["pool_acquires"] = pool_stats.get("acquires", 0)
		result["pool_releases"] = pool_stats.get("releases", 0)

	return result


## Override VR on every GeometryInstance3D descendant to the NEAR range (~155m).
## Prebaked prototypes can carry legacy MID-tier ranges. NEAR Node3Ds
## must cull at NEAR_END so the visible disc follows the camera instead of bleeding
## into renderer-owned tiers.
func _apply_near_visibility_range(node: Node3D) -> void:
	for geo: Node in node.find_children("*", "GeometryInstance3D", true, false):
		var g := geo as GeometryInstance3D
		g.visibility_range_begin = 0.0
		g.visibility_range_end = DU.NEAR_END + DU.FADE_MARGIN_NEAR_LOD1
		g.visibility_range_begin_margin = 0.0
		g.visibility_range_end_margin = DU.FADE_MARGIN_NEAR_LOD1
		g.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
