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
const NIFConverter := preload("res://src/core/nif/nif_converter.gd")
const CharacterFactoryV2 := preload("res://src/core/animation/character_factory_v2.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
const MeshVisibilityUtils := preload("res://src/core/world/mesh_visibility_utils.gd")

# Interaction framework (I.1) — generic carryable spawn path. The MW
# adapter (mw_carryable_registry.gd) registers MW record types into
# CarryableRegistry at boot. Reference instantiator stays adapter-agnostic
# by routing through the registry + body factory and only loading the
# adapter's PickupInteractable script as a Resource.
const CarryableRegistryScript := preload("res://src/core/interaction/carryable_registry.gd")
const CarryableBodyFactoryScript := preload("res://src/core/interaction/carryable_body_factory.gd")
const PickupInteractableScript := preload("res://src/core/interaction/morrowind/pickup_interactable.gd")

# I.7 — DOOR adapter. Attached to spawned door nodes so the interaction
# framework can raycast-target them. The `door_activated` signal payload
# is routed through `door_activated_handler` (set by CellManager, which
# in turn gets it from world_explorer). Keeping the handler as a Callable
# avoids importing world/streaming types into the instantiator.
const DoorInteractableScript := preload("res://src/core/interaction/morrowind/door_interactable.gd")

# C.5 — NPC dialogue adapter. NPCs get wrapped in an NPCInteractable so
# the InteractionRaycaster can target them for conversation. The wrapper
# holds the speaker_id; the actual dialogue lookup happens at interact()
# time via DialogueSession.current().
const NPCInteractableScript := preload("res://src/core/dialogue/morrowind/npc_interactable.gd")

# Preload crossfade shader for fade-in effect
const LOD_CROSSFADE_SHADER := preload("res://src/core/world/shaders/lod_crossfade.gdshader")

# S.1 follow-up — §12.2 crash-site diagnostic. Breadcrumbs bracket every
# post-model-load hazard in _instantiate_model_object so a native SIGSEGV
# post-instantiate_return narrows to a single named step. Remove once the
# second crash site is closed.
const CrashBreadcrumb := preload("res://src/core/logging/crash_breadcrumb.gd")

# Injected dependencies (set by CellManager)
var model_loader: RefCounted = null  # ModelLoader
var object_pool: RefCounted = null  # ObjectPool (optional)
var static_renderer: Node = null  # StaticObjectRenderer (optional)
var character_factory: CharacterFactoryV2 = null  # CharacterFactoryV2 for NPCs/creatures with new animation system

# Impostor candidates for determining significant objects
var _impostor_candidates: RefCounted = null

# Output data for non-Node3D instances (Phase 2)
var last_static_data: Dictionary = {}

# Configuration
var create_lights: bool = true
var load_lights: bool = true  # Skip ALL light ref instantiation (model + OmniLight3D). A/B benchmark gate.
var load_npcs: bool = true
var load_creatures: bool = true
var use_object_pool: bool = true
var use_static_renderer: bool = true
var debug_lod: bool = false
var enable_fade_in: bool = true  # Smooth fade-in for newly instantiated objects
var fade_in_duration: float = 0.3  # Duration of fade-in animation in seconds (matches StreamingConfig.FADE_DURATION)

# I.7 — Callback invoked when a spawned DoorInteractable emits
# `door_activated`. Signature mirrors the signal:
#   (record_id: String, door_record: Variant, player: Node3D) -> void
# Set by CellManager (which receives it from world_explorer). If null,
# spawned DoorInteractables still emit the signal but nothing listens;
# that is the test-scene / headless-load default.
var door_activated_handler: Callable = Callable()

# NEAR-tier actor filtering — skip NPC/creature creation beyond this distance from camera
# 150m matches the NEAR tier boundary in distance_utils.gd
var max_actor_distance: float = 150.0
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

# Scene tree reference for tweens (must be set by parent, e.g., CellManager)
var scene_tree: SceneTree = null

# Fade material pool - pre-allocated ShaderMaterials to avoid per-object allocation
const FADE_POOL_SIZE := 200  # Matches StreamingConfig.MAX_CONCURRENT_FADES
var _fade_pool: Array[ShaderMaterial] = []  # Available materials
var _fade_pool_initialized: bool = false

# Statistics
var stats: Dictionary = {
	"objects_instantiated": 0,
	"objects_failed": 0,
	"objects_from_pool": 0,
	"lights_created": 0,
	"npcs_loaded": 0,
	"creatures_loaded": 0,
	"static_renderer_instances": 0,
	"significant_objects_registered": 0,  # Objects registered with per-object LOD
}

# Morrowind light radius to Godot light range conversion factor
const MW_LIGHT_SCALE: float = CS.SCALE_FACTOR  # 1/70 — converts MW radius to meters

## Lazy-spawn distance for interactive refs (containers, doors, activators,
## carryables). Refs beyond this distance are deferred and re-queued on camera
## approach. OpenMW pattern: Node3D creation for 12-20 ms/ref interactives is
## skipped until gameplay can plausibly interact — eliminates 70-80% of the
## `inst:` overrun during cell-crossing bursts while preserving the invariant
## "containers appear before you can touch them." Set to 80 m = below NEAR
## render end (150 m) so interactives always arrive before they enter view.
const INTERACTIVE_PROXIMITY_THRESHOLD_M: float = 80.0

## Set true by `_instantiate_model_object` when a ref is skipped due to the
## lazy-spawn distance gate. Read by `cell_manager.process_async_instantiation`
## to route the ref into `_proximity_deferred` instead of treating as failed.
var last_proximity_deferred: bool = false


## Instantiate a cell reference into a Node3D
## Returns null if the reference cannot be instantiated or uses StaticObjectRenderer
var _inst_call_count: int = 0
## Diagnostic — set to the type_name of the most recent instantiate_reference
## call. Read by `cell_manager.process_async_instantiation` for per-type
## timing breakdown. Scientific-approach instrumentation, not hypothesis.
var last_type_name: String = ""
# PHASE_A:MAIN_ONLY — orchestrator. ESMManager.get_any_record autoload read +
# dispatch to type handlers. Stays main-thread; split lives in _instantiate_model_object.
func instantiate_reference(ref: CellReference, cell_grid: Vector2i = Vector2i.ZERO) -> Node3D:
	_inst_call_count += 1
	# Reset per-call state — caller (cell_manager) reads these after return.
	last_proximity_deferred = false

	# Use generic lookup to find the base record and its type
	var record_type: Array = [""]
	var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)

	if debug_lod and _inst_call_count <= 20:
		Log.debug("streaming", "[LOD-INST] #%d ref=%s, type=%s, found=%s, cell=%s" % [
			_inst_call_count, ref.ref_id, record_type[0] if record_type.size() > 0 else "?",
			base_record != null, cell_grid
		])

	if not base_record:
		# Not an error - some refs are for types we don't handle yet
		last_type_name = "unknown"
		return null

	var type_name: String = record_type[0] if record_type.size() > 0 else ""
	last_type_name = type_name

	# Handle different record types
	match type_name:
		"light":
			if not load_lights:
				return null
			return _instantiate_light(ref, base_record as LightRecord)
		"npc":
			if not load_npcs:
				return null
			return _instantiate_actor(ref, base_record as NPCRecord, "npc")
		"creature":
			if not load_creatures:
				return null
			return _instantiate_actor(ref, base_record as CreatureRecord, "creature")
		"leveled_creature":
			if not load_creatures:
				return null
			# Resolve leveled creature to an actual creature
			var resolved := _resolve_leveled_creature(base_record as LeveledCreatureRecord)
			if resolved:
				return _instantiate_actor(ref, resolved, "creature")
			return null
		"leveled_item":
			# Leveled items need to be resolved at runtime
			# Could spawn random items here if needed
			return null
		_:
			# Standard model-based object
			return _instantiate_model_object(ref, base_record, cell_grid, type_name)


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


## Instantiate a standard object with a NIF model
## For flora/rocks, uses StaticObjectRenderer for ~10x faster instantiation
var _model_obj_count: int = 0
# PHASE_A:MAIN_ONLY — the Phase A split point. Current body is fully synchronous;
# post-Phase-A this function becomes the orchestrator that dispatches worker
# tasks (lines 328-351 moved off-thread) and runs the main-thread tail
# (lines 353-410: carryable / door / interior-collision / anim).
func _instantiate_model_object(ref: CellReference, base_record: Variant, cell_grid: Vector2i = Vector2i.ZERO, type_name: String = "") -> Node3D:
	_model_obj_count += 1

	# Get model path and record ID
	var model_path: String = _get_model_path(base_record)
	if model_path.is_empty():
		return null

	# Get record_id for collision shape library lookup
	var record_id: String = ""
	if "record_id" in base_record:
		record_id = base_record.record_id

	# Per-call override: interior pockets must bypass the static renderer.
	var effective_use_static: bool = _effective_use_static_renderer()

	# I.1 — Carryable check. Generic via CarryableRegistry; the type list
	# lives in the MW adapter (mw_carryable_registry.gd). Carryables MUST
	# bypass the static-renderer fast path (no Node3D = no physics) and
	# the object pool (per-instance RigidBody3D state can't be pooled
	# safely without `(model_path, body_type)` keying — deferred).
	var is_carryable: bool = CarryableRegistryScript.is_carryable(type_name, base_record)

	# Debug: Log what path each object is taking
	if debug_lod and _model_obj_count <= 20:
		var is_static := effective_use_static and static_renderer and _is_static_render_model(model_path) and not is_carryable
		var is_sig := is_significant_object(model_path)
		Log.debug("streaming", "[LOD-PATH] #%d %s: static_render=%s, significant=%s, carryable=%s" % [
			_model_obj_count, model_path.get_file(), is_static, is_sig, is_carryable
		])

	# Check if this model should use static rendering (statics_no_node3d T.1)
	# Route statics via RenderingServer.instance_create2 (MultiMesh) instead
	# of Node3D. ~80% of MW refs are STAT type — eliminates per-object Node3D
	# + StaticBody3D construction. Cell-level merged trimesh collision
	# (cell_static_collision.gd) provides the physics. Interactive refs
	# (doors, activators, containers, carryables, animated statics) stay on
	# the Node3D path.
	#
	# Carve-outs:
	# - is_carryable — needs RigidBody3D for pickup physics
	# - effective_use_static false — interior pockets (§5.3 carve-out locked)
	# - has_animation — flags, banners, rotating objects need AnimationPlayer lifecycle
	if _should_route_to_renderer(type_name, model_path, is_carryable, effective_use_static):
		last_proximity_deferred = false
		return _instantiate_static_object(ref, model_path, cell_grid)

	# Lazy-spawn distance gate (statics_no_node3d follow-up 2026-04-19).
	# Containers/doors/activators/carryables cost 12-20 ms per instantiate —
	# defer until player is within interaction range. Re-queued by
	# `cell_manager.tick_proximity_deferred` when camera approaches.
	# Interior pockets always use_static=false → skip gate (pockets are
	# bounded, every ref is expected to spawn immediately).
	if effective_use_static and _is_proximity_gated(type_name, is_carryable):
		var ref_world_pos := CS.vector_to_godot(ref.position)
		if ref_world_pos.distance_squared_to(camera_position) > INTERACTIVE_PROXIMITY_THRESHOLD_M * INTERACTIVE_PROXIMITY_THRESHOLD_M:
			last_proximity_deferred = true
			return null
	last_proximity_deferred = false

	# Try to get from object pool first (if enabled). Skip for carryables —
	# the pool isn't keyed by body_type so a previously-converted RigidBody3D
	# could be returned for a non-carryable acquire (or vice versa).
	if not is_carryable and use_object_pool and object_pool:
		var pooled: Node3D = object_pool.call("acquire", model_path)
		if pooled:
			pooled.name = str(ref.ref_id) + "_" + str(ref.ref_num)
			# Note: visibility_range is already configured on pooled objects
			_apply_transform(pooled, ref, true)
			stats["objects_from_pool"] += 1
			return pooled

	# Load — get_model() returns a fresh Node3D (collision disabled) from PackedScene cache.
	var instance: Node3D = model_loader.call("get_model", model_path, record_id)
	if not instance:
		# Create a placeholder for missing models
		return _create_placeholder(ref)

	instance.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Enable collision immediately for objects within NEAR tier (<150m).
	# model_loader disables all CollisionShape3D at instantiate time to prevent
	# Jolt overwhelm during startup bursts. Re-enable here for close objects.
	var ref_pos := CS.vector_to_godot(ref.position)
	if ref_pos.distance_squared_to(camera_position) < DU.NEAR_END * DU.NEAR_END:
		_enable_collision_shapes_in_tree(instance)

	# Hide materialless meshes (collision geometry, placeholders)
	# LOD nodes (_LOD1, _LOD2, _LOD3) are now kept visible and configured with visibility_range
	_hide_lod_nodes(instance)

	# Apply transform
	_apply_transform(instance, ref, true)

	# Add metadata for console object picker
	_apply_metadata(instance, ref, base_record, model_path, type_name)

	# I.1 — Carryable conversion. Swap the baked StaticBody3D for a
	# RigidBody3D (frozen KINEMATIC, layers Environment+Interactable) and
	# attach a PickupInteractable child. Mass comes from the registered
	# extractor (MW: ESM `weight` field, treated as kg). If the prototype
	# has no baked collision, conversion returns null and the instance
	# stays static — log once and move on.
	if is_carryable:
		var mass_kg: float = CarryableRegistryScript.get_mass(type_name, base_record)
		var display_name: String = ""
		if "name" in base_record and not String(base_record.name).is_empty():
			display_name = base_record.name
		else:
			display_name = record_id
		var rb := CarryableBodyFactoryScript.convert_static_to_rigid(
			instance,
			mass_kg,
			StringName(record_id),
			display_name,
			PickupInteractableScript,
		)
		if rb == null:
			Log.info("interaction", "Carryable %s (%s) has no collision/mesh — staying static (non-interactable)" % [record_id, type_name])

	# I.7 — DOOR adapter attachment. Only teleport doors (DODT subrecord
	# present on the ref) get a DoorInteractable — decorative non-teleport
	# doors (e.g. a visual-only door stuck to an exterior wall with no
	# destination) stay silent. The adapter's signal payload carries the
	# `record_id` so the handler can look up the authoritative DoorInfo
	# via `InteriorPocketManager.get_door_info_by_ref_id()`.
	if type_name == "door" and ref.is_teleport:
		_attach_door_interactable(instance, ref, base_record, record_id)

	# Interior collision fallback — generate a StaticBody3D from the mesh
	# AABB for non-carryable, non-door objects that lack baked collision.
	# Interior pockets bypass the static renderer (all objects are Node3D),
	# so floors, walls, and furniture need collision for physics to work
	# (rigid body items resting on surfaces, player walking). The per-call
	# load_profile tells us if we're in an interior context. Exterior objects
	# that already have collision from the NIF converter are unaffected.
	if not is_carryable and not (type_name == "door" and ref.is_teleport):
		if not _effective_use_static_renderer():
			if not _has_static_body(instance):
				_generate_static_collision(instance)

	stats["objects_instantiated"] += 1

	# Auto-play NIF keyframe animations (flags, banners, rotating objects) in NEAR tier only
	_auto_play_nif_animation(instance, ref)
	# S.1 follow-up §12.2 — only ri:: breadcrumb kept in hot path. If crash
	# fires between model_loader's `instantiate_return` and this `ri::ret`,
	# the culprit is in the reference_instantiator post-load block above
	# (enable_coll / hide_lod / apply_xf / apply_meta / carryable / door /
	# gen_static / auto_anim). If `ri::ret` is the last crumb, crash is in
	# cell_manager post-return (VR apply, pending_children append, or the
	# batch add_child loop — those have their own `cm::` crumbs).
	CrashBreadcrumb.write("ri::ret", model_path)

	# NOTE: Fade-in is NOT applied here because the node isn't in the scene tree yet.
	# Fade-in must be applied AFTER add_child() - see CellManager._instantiate_cell()

	# NOTE: visibility_range configuration happens in NativeStreamingManager._configure_cell_visibility()
	# after the cell is added to the scene tree. No need to register with a separate distance manager.

	return instance


## Phase A — main-thread dispatcher pre-flight. Mirrors every bailout the sync
## `instantiate_reference` → `_instantiate_model_object` path makes BEFORE it
## would reach `model_loader.get_model`:
##
##   1. Type exclusion — light / npc / creature / leveled_* go through custom
##      paths (`_instantiate_light`, `_instantiate_actor`, leveled resolver).
##      These NEVER hit the cache-hit PackedScene.instantiate path.
##   2. STAT → static-renderer routing. `_should_route_to_renderer` returns
##      true for the ~80% STAT case; sync calls `_instantiate_static_object`
##      (RS.instance_create2, no Node3D). Dispatching these to worker would
##      REGRESS the T.1 statics_no_node3d win (reg_slots = 1301 → 0, phys_pairs
##      1 → ~1800). Never dispatch STAT refs that will route to RS.
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
# PHASE_A:MAIN_ONLY — reads static_renderer singleton + model_loader cache +
# ESMManager (via caller) + camera_position (main-thread-updated).
func should_dispatch_to_worker(
	entry: Variant,
	base_record: Variant,
	type_name: String,
) -> bool:
	# 1. Type exclusion — custom paths handle these, no cache-hit branch.
	match type_name:
		"light", "npc", "creature", "leveled_creature", "leveled_item":
			return false

	var is_carryable: bool = CarryableRegistryScript.is_carryable(type_name, base_record)

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

	var is_carryable: bool = CarryableRegistryScript.is_carryable(type_name, base_record)

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


## Phase F — Prototype pre-registration dispatcher (main-thread).
##
## Scans cell_record.references for unique STAT-routed model paths that are not
## yet registered, dispatches one WorkerThreadPool task per unique path to
## `_worker_preregister_prototype`. Runs in parallel with the cell's
## ResourceLoader.load_threaded_request pipeline so by the time static refs
## reach the instantiation queue, `should_dispatch_static_precompute` → true
## (fast path) instead of falling through to sync cold-register (~20ms per
## unique type). Eliminates the `static avg µs 200-2074 (cold 38050)` spike.
##
## Called by cell_manager.request_exterior_cell_async / request_cell_async
## immediately after ESMManager.get_exterior_cell / get_cell succeeds.
##
## Idempotent: if the cell's types are already registered (common after first
## visit), dispatches 0 tasks. Duplicates across cells are harmless — worker's
## own fast-path skips already-registered types after mutex-read of _mesh_types.
##
## Returns the number of tasks dispatched (for diagnostics).
##
## Plan: docs/plans/distant_rendering_2026_04/phase_f_prototype_prereg.md §3
# PHASE_F:MAIN_ONLY — reads ESMManager autoload + iterates cell refs.
func preregister_cell_statics(cell_record: Variant) -> int:
	if static_renderer == null or model_loader == null:
		return 0
	if cell_record == null:
		return 0

	# Dedupe model paths within the cell — many refs share types.
	var to_register: Dictionary = {}  # normalized_path -> disk_path

	for ref: CellReference in cell_record.references:
		var record_type: Array = [""]
		var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if base_record == null:
			continue
		var type_name: String = record_type[0] if record_type.size() > 0 else ""

		# Resolve model path from base record (STAT/CONT/DOOR/etc all have `model`).
		if not "model" in base_record:
			continue
		var model_path: String = base_record.model
		if model_path.is_empty():
			continue

		# Filter to STAT-routed refs only — interactives use _instantiate_model_object
		# (Phase A), which doesn't need _mesh_types pre-warming.
		var is_carryable: bool = CarryableRegistryScript.is_carryable(type_name, base_record)
		if not _should_route_to_renderer(type_name, model_path, is_carryable, use_static_renderer):
			continue

		var normalized: String = model_path.to_lower().replace("/", "\\")
		if normalized in to_register:
			continue

		# Already registered? Skip (mutex-wrapped has_type).
		if static_renderer.call("has_type", normalized):
			continue

		# Resolve disk path. If missing, sync path will handle it via BSA fallback
		# (prebake-mode only; runtime_mode returns null and skips the ref).
		var disk_path: String = model_loader.call("resolve_disk_path", model_path)
		if disk_path.is_empty():
			continue

		to_register[normalized] = disk_path

	var dispatched: int = 0
	for normalized: String in to_register:
		var disk_path: String = to_register[normalized]
		# HIGH priority — we're racing the cell's instantiation queue. The worker
		# pool is shared with Phase A/E tasks; high-priority queueing ensures
		# pre-reg lands before the static refs are drained.
		WorkerThreadPool.add_task(
			_worker_preregister_prototype.bind(normalized, disk_path),
			true,
			"ref_instantiator:phase_f_prereg"
		)
		dispatched += 1
	return dispatched


## Phase F — Prototype pre-registration worker.
##
## Loads the PackedScene off-thread (ResourceLoader.load is thread-safe),
## instantiates it (PackedScene.instantiate is thread-safe since Godot 4.1 per
## issue #79194), and calls static_renderer.register_from_prototype to extract
## sub-meshes into _mesh_types. The register_from_prototype method has a
## mutex-protected fast-path + atomic-insert under lock, so concurrent callers
## on the same type_name dedupe safely.
##
## Ephemeral prototype node: the detached Node3D subtree is used only to walk
## sub-meshes. register_from_prototype stores strong refs to mesh + material
## resources in MeshType; the prototype itself has no other owners after this
## function returns, so Godot's refcount reaper collects it. No main-thread
## queue_free needed for un-parented nodes with refcount 0.
##
## Plan: docs/plans/distant_rendering_2026_04/phase_f_prototype_prereg.md §4
# PHASE_F:WORKER_SAFE — by design. Zero autoload / signal / scene-tree access.
func _worker_preregister_prototype(type_name: String, disk_path: String) -> void:
	if static_renderer == null:
		return
	# Fast-path dedup: skip the ~20ms PackedScene.instantiate if another worker
	# beat us to this type. Mutex-wrapped via has_type.
	if static_renderer.call("has_type", type_name):
		return

	# ResourceLoader.load is thread-safe — returns cached PackedScene if another
	# worker already loaded the same path.
	var scene: PackedScene = ResourceLoader.load(disk_path, "PackedScene") as PackedScene
	if scene == null or not scene.can_instantiate():
		return

	# PackedScene.instantiate is thread-safe since Godot 4.1 (issue #79194).
	var raw: Node = scene.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
	if raw == null or not (raw is Node3D):
		return

	# register_from_prototype has mutex-protected fast-path + atomic insert.
	# Concurrent callers on the same type_name dedupe safely.
	static_renderer.call("register_from_prototype", type_name, raw as Node3D)


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
	var precomp: Variant = static_renderer.call("precompute_instance", normalized, entry.ref, cell_grid)
	# Populate ref-metadata fields the sync add_instance would fill. Builder
	# review 2026-04-21 BLOCKER 1: precompute_instance can't see
	# entry.model_path / entry.item_id from its signature (it only takes the
	# CellReference), so we fill them here. Empty strings break downstream
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
	if precomp == null or static_renderer == null:
		return null
	# `add_instance_precomputed` returns the new instance_id; we don't need it
	# here (remove_instance happens on cell unload via cell_grid index).
	var id: int = static_renderer.call("add_instance_precomputed", precomp)
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
## because they live only transiently inside instantiate_reference and the
## slice-2 schema deliberately didn't grow to hold them. The dispatcher looks
## them up on main thread (ESMManager call is worker-unsafe per plan §5.1).
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
	# Null path removed — the cell_manager drain only calls this when
	# entry.worker_instance != null. @roaster review 2026-04-20 §4c.
	var ref: CellReference = entry.ref
	var record_id: String = ""
	if base_record != null and "record_id" in base_record:
		record_id = base_record.record_id

	# NEAR-tier collision enable (mirror of _instantiate_model_object:339-342).
	var ref_pos := CS.vector_to_godot(ref.position)
	if ref_pos.distance_squared_to(camera_position) < DU.NEAR_END * DU.NEAR_END:
		_enable_collision_shapes_in_tree(instance)

	# Carryable conversion (mirror of _instantiate_model_object:353-374).
	var is_carryable: bool = CarryableRegistryScript.is_carryable(type_name, base_record)
	if is_carryable:
		var mass_kg: float = CarryableRegistryScript.get_mass(type_name, base_record)
		var display_name: String = ""
		if base_record != null and "name" in base_record and not String(base_record.name).is_empty():
			display_name = base_record.name
		else:
			display_name = record_id
		var rb := CarryableBodyFactoryScript.convert_static_to_rigid(
			instance,
			mass_kg,
			StringName(record_id),
			display_name,
			PickupInteractableScript,
		)
		if rb == null:
			Log.info("interaction", "Carryable %s (%s) has no collision/mesh — staying static (non-interactable)" % [record_id, type_name])

	# Door attachment (mirror of _instantiate_model_object:376-383).
	if type_name == "door" and ref.is_teleport:
		_attach_door_interactable(instance, ref, base_record, record_id)

	# Interior collision fallback (mirror of _instantiate_model_object:385-395).
	if not is_carryable and not (type_name == "door" and ref.is_teleport):
		if not _effective_use_static_renderer():
			if not _has_static_body(instance):
				_generate_static_collision(instance)

	stats["objects_instantiated"] += 1

	# NIF anim autoplay (mirror of _instantiate_model_object:400).
	_auto_play_nif_animation(instance, ref)

	return instance


## Instantiate a flora/rock using StaticObjectRenderer (RenderingServer direct)
## Returns null (no Node3D created) - the instance exists only in RenderingServer
## This is ~10x faster than Node3D.duplicate()
# PHASE_A:MAIN_ONLY — touches static_renderer singleton (register_from_prototype,
# add_instance). RS calls are thread-safe but registry mutation must stay main.
func _instantiate_static_object(ref: CellReference, model_path: String, cell_grid: Vector2i) -> Node3D:
	var normalized := model_path.to_lower().replace("/", "\\")

	# Ensure model is loaded and registered with static renderer
	if not static_renderer.call("has_type", normalized):
		# Load prototype to get mesh
		var prototype: Node3D = model_loader.call("get_model", model_path)
		if prototype:
			static_renderer.call("register_from_prototype", normalized, prototype)
		else:
			return null

	# Calculate transform using CoordinateSystem's ESM rotation conversion
	var pos := CS.vector_to_godot(ref.position)
	var scale := CS.scale_to_godot(ref.scale)
	var basis := CS.esm_rotation_to_godot_basis(ref.rotation)
	basis = basis.scaled(scale)
	var transform := Transform3D(basis, pos)

	# Get mesh AABB for GPU Scene Database
	var mesh_type_stats: Dictionary = static_renderer.call("get_mesh_type_stats", normalized)
	var aabb: AABB = mesh_type_stats.get("aabb", AABB())

	# Add instance to static renderer
	var instance_id: int = static_renderer.call("add_instance", normalized, transform, cell_grid)
	if instance_id >= 0:
		stats["static_renderer_instances"] += 1

		# Store data for GPU Scene Database collection by CellManager
		last_static_data = {
			"transform": transform,
			"aabb": aabb,
			"mesh_id": float(normalized.hash()), # Float-compatible float for SSBO
			"lod_mask": 0 # Default for now
		}

	# Return null - no Node3D created, exists only in RenderingServer
	# The cell_grid parameter lets us clean up when the cell unloads
	return null


## Instantiate a light object (model + OmniLight3D)
func _instantiate_light(ref: CellReference, light_record: LightRecord) -> Node3D:
	# Create container node
	var light_node := Node3D.new()
	light_node.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Load the model if it has one
	if not light_record.model.is_empty():
		var model_instance: Node3D = model_loader.call("get_model", light_record.model)
		if model_instance:
			model_instance.name = "Model"
			_hide_lod_nodes(model_instance)  # Hide materialless meshes only
			# Lights are always within NEAR tier (150m fade-out set on OmniLight3D)
			var ref_pos := CS.vector_to_godot(ref.position)
			if ref_pos.distance_squared_to(camera_position) < DU.NEAR_END * DU.NEAR_END:
				_enable_collision_shapes_in_tree(model_instance)
			# Auto-play NIF animations on light models (rotating lights, animated lanterns)
			_auto_play_nif_animation(model_instance, ref)
			light_node.add_child(model_instance)

	# Create the actual light source
	if create_lights and light_record.radius > 0 and not light_record.is_off_by_default():
		var omni := OmniLight3D.new()
		omni.name = "Light"

		# Convert MW radius to Godot range
		# MW radius is in game units, Godot uses meters
		# Enforce minimum 0.125m (16 game units) per OpenMW convention
		var godot_range: float = maxf(light_record.radius * MW_LIGHT_SCALE, 0.125)
		omni.omni_range = godot_range

		# Set light color
		omni.light_color = light_record.color

		# Negative lights subtract light (Morrowind feature)
		if light_record.is_negative():
			omni.light_negative = true

		# Set energy based on whether it's a fire/torch light
		omni.light_energy = 1.2 if light_record.is_fire() else 0.8

		# Shadows disabled by default — managed by LightShadowBudget if present
		omni.shadow_enabled = false

		# Attenuation: softer falloff for enclosed spaces
		omni.omni_attenuation = 1.0

		# Distance fade: remove lights from cluster budget beyond visibility
		# Begin fading at 120m, fully gone by 150m (matches NEAR tier boundary)
		omni.distance_fade_enabled = true
		omni.distance_fade_begin = 120.0
		omni.distance_fade_length = 30.0

		# Store light flags for animator and shadow budget manager
		omni.set_meta("mw_flags", light_record.flags)
		omni.set_meta("mw_radius", light_record.radius)
		omni.set_meta("base_energy", omni.light_energy)

		light_node.add_child(omni)
		stats["lights_created"] += 1

	# Apply transform to the container
	_apply_transform(light_node, ref, false)

	# Add metadata for console object picker
	light_node.set_meta("form_id", light_record.record_id if "record_id" in light_record else str(ref.ref_id))
	light_node.set_meta("record_type", "LIGH")
	light_node.set_meta("model_path", light_record.model if not light_record.model.is_empty() else "")
	light_node.set_meta("ref_id", str(ref.ref_id))
	light_node.set_meta("ref_num", ref.ref_num)
	light_node.set_meta("instance_id", ref.ref_num)

	return light_node


## Instantiate an NPC or Creature
## Uses CharacterFactory to create fully animated and functional characters
func _instantiate_actor(ref: CellReference, actor_record: Variant, actor_type: String) -> Node3D:
	# Skip actors beyond NEAR tier — full CharacterBody3D is too expensive at distance.
	# Per-request override via LoadProfile: interior pockets set this to 0.0
	# because the camera is still at exterior position during pocket load.
	var effective_actor_dist: float = _effective_max_actor_distance()
	if effective_actor_dist > 0.0:
		var ref_pos := CS.vector_to_godot(ref.position)
		if ref_pos.distance_squared_to(camera_position) > effective_actor_dist * effective_actor_dist:
			return null

	# Use CharacterFactory if available (new system)
	if character_factory:
		var character: CharacterBody3D = null

		if actor_record is CreatureRecord:
			var creature_rec: CreatureRecord = actor_record as CreatureRecord
			character = character_factory.create_creature(creature_rec, ref.ref_num)
			stats["creatures_loaded"] += 1
		elif actor_record is NPCRecord:
			var npc_rec: NPCRecord = actor_record as NPCRecord
			character = character_factory.create_npc(npc_rec, ref.ref_num)
			stats["npcs_loaded"] += 1

		if character:
			# Apply transform to the CharacterBody3D
			_apply_transform(character, ref, true)

			# Add additional metadata for console object picker
			character.set_meta("form_id", actor_record.record_id if "record_id" in actor_record else str(ref.ref_id))
			character.set_meta("ref_id", str(ref.ref_id))
			character.set_meta("instance_id", ref.ref_num)
			character.set_meta("actor_type", actor_type)

			# C.5 — NPC dialogue: wrap in NPCInteractable so the
			# raycaster can walk up from the character's collision shape
			# to find the Interactable ancestor. The wrapper inherits
			# the character's world-space transform; the character moves
			# to identity (local to wrapper). Same layer-3 stamp as doors.
			if actor_type == "npc" and actor_record is NPCRecord:
				var wrapper := Node3D.new()
				wrapper.set_script(NPCInteractableScript)
				wrapper.name = character.name + "_npc"
				wrapper.speaker_id = actor_record.record_id.to_lower()
				wrapper.transform = character.transform
				character.transform = Transform3D.IDENTITY
				wrapper.add_child(character)
				_add_interactable_layer_recursive(wrapper)
				return wrapper

			return character

	# Fallback to old system if CharacterFactory not available
	return _instantiate_actor_legacy(ref, actor_record, actor_type)


## Legacy actor instantiation (old system - basic model loading)
func _instantiate_actor_legacy(ref: CellReference, actor_record: Variant, actor_type: String) -> Node3D:
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
		return _create_actor_placeholder(ref, actor_record, actor_type)

	var instance: Node3D = model_loader.call("get_model", model_path)
	if not instance:
		return _create_actor_placeholder(ref, actor_record, actor_type)

	instance.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Actors are NEAR-only — enable collision (actor loading skips > max_actor_distance)
	_enable_collision_shapes_in_tree(instance)

	# Hide materialless meshes only
	_hide_lod_nodes(instance)

	# Check if model has actor collision metadata (from NIF "Bounding Box" node)
	# If so, ensure it has a capsule collision shape for proper physics
	if instance.has_meta("actor_collision_extents"):
		_ensure_actor_collision(instance, actor_type)

	# Apply transform
	_apply_transform(instance, ref, true)

	# Add metadata for console object picker
	var record_type := "NPC_" if actor_type == "npc" else "CREA"
	instance.set_meta("form_id", actor_record.record_id if "record_id" in actor_record else str(ref.ref_id))
	instance.set_meta("record_type", record_type)
	instance.set_meta("model_path", model_path)
	instance.set_meta("ref_id", str(ref.ref_id))
	instance.set_meta("ref_num", ref.ref_num)
	instance.set_meta("instance_id", ref.ref_num)
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
func _create_actor_placeholder(ref: CellReference, _actor_record: Variant, actor_type: String) -> Node3D:
	var container := Node3D.new()
	container.name = str(ref.ref_id) + "_" + str(ref.ref_num)

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
	_apply_transform(container, ref, false)

	return container


## Resolve a leveled creature list to an actual creature record
## Uses a simplified algorithm: pick a random creature from valid level range
## player_level defaults to 10 for now (could be passed in later)
func _resolve_leveled_creature(leveled: LeveledCreatureRecord, player_level: int = 10) -> CreatureRecord:
	if leveled.creatures.is_empty():
		return null

	# Check chance_none - random chance to spawn nothing
	if leveled.chance_none > 0 and randi() % 100 < leveled.chance_none:
		return null

	# Filter creatures by level (creatures spawn if player_level >= creature_level)
	var valid_creatures: Array[Dictionary] = []
	for entry in leveled.creatures:
		if entry.level <= player_level:
			valid_creatures.append(entry)

	if valid_creatures.is_empty():
		# No valid creatures for this level, pick lowest level one
		var lowest_entry: Dictionary = leveled.creatures[0]
		for entry in leveled.creatures:
			if entry.level < lowest_entry.level:
				lowest_entry = entry
		valid_creatures.append(lowest_entry)

	# Pick random creature from valid list
	var chosen: Dictionary = valid_creatures[randi() % valid_creatures.size()]
	var creature_id: String = chosen.creature_id

	# Look up the actual creature record
	var creature: CreatureRecord = ESMManager.get_creature(creature_id)
	if creature:
		return creature

	# Might be a nested leveled list - try to resolve recursively
	var nested_leveled: LeveledCreatureRecord = ESMManager.get_leveled_creature(creature_id)
	if nested_leveled:
		return _resolve_leveled_creature(nested_leveled, player_level)

	push_warning("ReferenceInstantiator: Could not resolve creature '%s' from leveled list '%s'" % [
		creature_id, leveled.record_id
	])
	return null


# PHASE_A:MAIN_ONLY — set_script + signal connect + door_activated_handler
# (bound to world_explorer). Plan §5 row 376-383; runs after worker returns.
## I.7 — Promote a spawned teleport door into a DoorInteractable.
## Called from _instantiate_model_object() for `type_name == "door"` refs
## whose `is_teleport` is true (DODT subrecord present).
##
## Approach: set the DoorInteractable script directly on the door root
## (it extends Node3D, same as the duplicated prototype), then fill in
## the adapter's @export fields and add collision layer 3 (Interactable)
## to the door's StaticBody3D so the InteractionRaycaster can hit it.
##
## ## Why set_script on the root instead of adding a child
##
## `InteractionRaycaster._find_interactable_ancestor()` walks UP from the
## hit collider looking for the first `Interactable` node. If the adapter
## were a sibling of the door's StaticBody3D, the walk-up from the
## collision shape would pass through the door root (which is NOT an
## Interactable) and exit the door subtree without ever seeing the
## adapter. Putting the adapter ON the root puts it directly on the
## walk-up path — same pattern as `CarryableBodyFactory` wraps the body
## in a `Pickup` parent.
##
## Collision-layer OR: we don't remove the existing Environment layer
## (bit 0) because the door must still block player movement. We just
## add the Interactable bit (bit 2) so the raycast can find it without
## disturbing physics.
func _attach_door_interactable(door_instance: Node3D, ref: CellReference, base_record: Variant, record_id: String) -> void:
	var display_name: String = ""
	if base_record != null and "name" in base_record and not String(base_record.name).is_empty():
		display_name = base_record.name
	elif not record_id.is_empty():
		display_name = record_id

	var destination_name: String = ref.teleport_cell
	var has_destination: bool = not destination_name.is_empty()

	# Promote the root Node3D into a DoorInteractable by attaching the
	# script. The node identity survives the set_script call; any existing
	# metadata stamped by `_apply_metadata` is preserved. After the call
	# the instance IS a DoorInteractable and we cast to fill @export fields.
	door_instance.set_script(DoorInteractableScript)
	var adapter := door_instance as DoorInteractable
	if adapter == null:
		Log.warn("interaction", "Door %s set_script failed — adapter cast null" % record_id)
		return
	adapter.record_id = record_id
	adapter.display_name = display_name
	adapter.destination_name = destination_name
	adapter.has_destination = has_destination
	adapter.door_record = base_record

	# Always generate a passive Area3D interaction target from the full mesh
	# AABB. This box covers the entire door model and is detectable from ANY
	# approach direction — both exterior and interior faces.
	#
	# We do NOT use _add_interactable_layer_recursive on the baked StaticBody3D
	# here. MW door NIF collision is often a one-sided concave trimesh that
	# faces the interior cell; stamping layer 3 onto it makes the door
	# interactable only from the wall-side (the bug: "flip somewhere").
	# The baked StaticBody3D keeps layer 1 (Environment) only — it handles
	# physics blocking. The Area3D below handles all interaction detection.
	_generate_interaction_area(door_instance)

	Log.info("interaction", "[DOOR_ATTACH] %s (dest='%s' teleport=%s has_collision=%s)" % [
		record_id, destination_name, has_destination,
		_has_interactable_collision(door_instance)])

	if door_activated_handler.is_valid():
		adapter.door_activated.connect(door_activated_handler)


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


## Generate a passive Area3D with a BoxShape3D derived from the combined
## mesh AABB of the subtree. Used as a raycast target for doors/items
## whose NIF models lack baked collision shapes. The Area3D sits on layer 3
## only (Interactable) with monitoring/monitorable OFF — it's a passive
## raycast target, not an overlap detector. Matches Jolt perf guidance.
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
func _auto_play_nif_animation(instance: Node3D, ref: CellReference) -> void:
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
	instance.set_meta("_anim_randomize", true)


## Apply position, rotation, and scale to a node
## Uses unified CoordinateSystem for all conversions
# PHASE_A:WORKER_SAFE — pure property writes on a detached Node3D.
# Plan §5 row 347-348 confirms worker dispatch.
func _apply_transform(node: Node3D, ref: CellReference, _apply_model_rotation: bool) -> void:
	# Position conversion via CoordinateSystem (outputs in meters)
	node.position = CS.vector_to_godot(ref.position)
	node.scale = CS.scale_to_godot(ref.scale)

	# Rotation conversion via CoordinateSystem
	# Uses esm_rotation_to_godot_basis() which matches OpenMW's makeOsgQuat
	node.basis = CS.esm_rotation_to_godot_basis(ref.rotation)


## Apply metadata to an object for console object picker identification
# PHASE_A:WORKER_SAFE — set_meta on a detached node. Plan §5 row 350-351.
func _apply_metadata(node: Node3D, ref: CellReference, base_record: Variant, model_path: String, type_name: String = "") -> void:
	# Form ID / record ID
	if "record_id" in base_record:
		node.set_meta("form_id", base_record.record_id)

	# Model path
	if not model_path.is_empty():
		node.set_meta("model_path", model_path)

	# Reference info
	node.set_meta("ref_id", str(ref.ref_id))
	node.set_meta("ref_num", ref.ref_num)

	# Record type - use type_name string from get_any_record() (Phase 4)
	var record_type := _type_name_to_meta(type_name)
	node.set_meta("record_type", record_type)

	# Instance ID (unique per cell)
	node.set_meta("instance_id", ref.ref_num)


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


## Create a placeholder for missing models
# PHASE_A:MAIN_ONLY — called as main-thread fallback when model_loader returns
# null. Construction is pure, but bundling with the main-thread fallback path
# keeps the §8.2 Q3 answer in the code.
func _create_placeholder(ref: CellReference) -> Node3D:
	var placeholder := MeshInstance3D.new()
	placeholder.name = str(ref.ref_id) + "_placeholder"

	# Simple box mesh (human-sized in Godot meters)
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 1.8, 0.5)  # Roughly human-sized
	placeholder.mesh = box

	# Magenta material to stand out
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.0, 1.0)  # Magenta
	placeholder.material_override = mat

	# Apply transform
	_apply_transform(placeholder, ref, false)

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


## Initialize the fade material pool (call once after scene_tree is set)
func _ensure_fade_pool() -> void:
	if _fade_pool_initialized:
		return
	_fade_pool_initialized = true
	_fade_pool.resize(FADE_POOL_SIZE)
	for i in FADE_POOL_SIZE:
		var mat := ShaderMaterial.new()
		mat.shader = LOD_CROSSFADE_SHADER
		_fade_pool[i] = mat


## Acquire a fade material from the pool, or null if exhausted
func _acquire_fade_material() -> ShaderMaterial:
	if _fade_pool.is_empty():
		return null
	return _fade_pool.pop_back()


## Return a fade material to the pool after use
func _release_fade_material(mat: ShaderMaterial) -> void:
	# Reset params to avoid holding references to textures
	mat.set_shader_parameter("albedo_texture", null)
	mat.set_shader_parameter("albedo_color", Color.WHITE)
	mat.set_shader_parameter("roughness", 1.0)
	mat.set_shader_parameter("metallic", 0.0)
	# Reset clock uniforms so the pooled material starts cleanly on reuse.
	mat.set_shader_parameter("spawn_time", 0.0)
	mat.set_shader_parameter("fade_duration", 0.3)
	mat.set_shader_parameter("use_alpha_cutout", false)
	mat.set_shader_parameter("alpha_cutout", 0.5)
	_fade_pool.append(mat)


## Apply fade-in effect to newly instantiated object
## Uses pooled dither crossfade shader for smooth appearance (prevents visual pop)
func _apply_fade_in(instance: Node3D) -> void:
	if not scene_tree:
		if debug_lod:
			Log.debug("streaming", "[ReferenceInstantiator] _apply_fade_in SKIPPED - no scene_tree")
		return  # Need scene tree for tweens

	# Guard: create_tween() requires the node to be in the scene tree.
	# Calling it on a detached node returns null or creates an immediately-killed tween,
	# leaving material_override stuck as the fade ShaderMaterial (invisible object).
	if not instance.is_inside_tree():
		if debug_lod:
			Log.debug("streaming", "[ReferenceInstantiator] _apply_fade_in SKIPPED - node not in tree: %s" % instance.name)
		return

	_ensure_fade_pool()

	# Find all MeshInstance3D nodes in the hierarchy
	var mesh_instances: Array[MeshInstance3D] = []
	_find_mesh_instances(instance, mesh_instances)

	if mesh_instances.is_empty():
		if debug_lod:
			Log.debug("streaming", "[ReferenceInstantiator] _apply_fade_in SKIPPED - no mesh instances in %s" % instance.name)
		return

	if debug_lod:
		Log.debug("streaming", "[ReferenceInstantiator] _apply_fade_in: %s with %d meshes" % [instance.name, mesh_instances.size()])

	# Current engine clock, passed to the fade shader via `spawn_time`. Matches
	# the `TIME` built-in Godot exposes inside fragment shaders.
	var now_sec: float = float(Time.get_ticks_msec()) / 1000.0

	# Store original materials and apply pooled fade materials
	var fade_data: Array[Dictionary] = []

	for mesh_inst: MeshInstance3D in mesh_instances:
		# Acquire from pool — if exhausted, skip fade (object pops in instantly)
		var fade_mat := _acquire_fade_material()
		if not fade_mat:
			break

		# Get the original material_override (may be null for multi-surface meshes).
		# CRITICAL: We must distinguish "had material_override" from "had no override"
		# because restoring a surface material as material_override would override ALL
		# surfaces — the root cause of the texture bug on ships/buildings.
		var original_mat: Material = mesh_inst.material_override
		var had_override := original_mat != null

		# Detect stuck fade ShaderMaterial from pool recycling: if the current
		# override carries our fade uniforms (post-phase-2 rename: spawn_time),
		# it's a leftover fade material. Discard it and fall through to the
		# surface material chain.
		if original_mat is ShaderMaterial:
			var sm := original_mat as ShaderMaterial
			if sm.get_shader_parameter("spawn_time") != null:
				mesh_inst.material_override = null
				original_mat = null
				had_override = false

		# For fade visual: read surface 0 material to copy its texture into the fade shader.
		# But do NOT use this as the "original" to restore — it's per-surface, not an override.
		var fade_source_mat: Material = original_mat
		if fade_source_mat == null and mesh_inst.mesh and mesh_inst.mesh.get_surface_count() > 0:
			fade_source_mat = mesh_inst.get_surface_override_material(0)
			if fade_source_mat == null:
				fade_source_mat = mesh_inst.mesh.surface_get_material(0)

		# Store whether this mesh originally had material_override.
		# If not, restore to null (lets per-surface materials take effect).
		mesh_inst.set_meta("_pre_fade_material", original_mat)
		mesh_inst.set_meta("_had_material_override", had_override)

		# Copy texture from the fade source material for visual during fade.
		# This uses surface 0's material for multi-surface meshes — during the brief
		# fade-in all surfaces show the same texture, which is acceptable for ~0.3s.
		if fade_source_mat is StandardMaterial3D:
			var std_mat: StandardMaterial3D = fade_source_mat as StandardMaterial3D
			if std_mat.albedo_texture:
				fade_mat.set_shader_parameter("albedo_texture", std_mat.albedo_texture)
			fade_mat.set_shader_parameter("albedo_color", std_mat.albedo_color)
			fade_mat.set_shader_parameter("roughness", std_mat.roughness)
			fade_mat.set_shader_parameter("metallic", std_mat.metallic)
			# Handle alpha cutout for vegetation
			if std_mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
				fade_mat.set_shader_parameter("use_alpha_cutout", true)
				fade_mat.set_shader_parameter("alpha_cutout", std_mat.alpha_scissor_threshold)

		# Shader auto-fades from (spawn_time) to (spawn_time + fade_duration) using
		# the engine's TIME built-in, so there is no per-frame CPU work and no
		# Tween lifecycle. One SceneTreeTimer per call triggers material
		# restoration; see the tail of this function.
		fade_mat.set_shader_parameter("spawn_time", now_sec)
		fade_mat.set_shader_parameter("fade_duration", fade_in_duration)
		mesh_inst.material_override = fade_mat

		fade_data.append({
			"mesh_instance": mesh_inst,
			"fade_material": fade_mat,
			"original_material": original_mat
		})

	if fade_data.is_empty():
		return

	# Schedule material restoration via a single SceneTreeTimer. Replaces the
	# prior per-object Tween whose lambda capture of `instance` was the root
	# cause of the "Lambda capture was freed" crash class when cells unloaded
	# mid-fade. The timer is owned by the SceneTree, independent of any
	# instance's lifetime — `is_instance_valid()` guards in `_restore_fade_data`
	# handle the freed-instance case cleanly, and the pool is always recovered.
	var timer: SceneTreeTimer = scene_tree.create_timer(fade_in_duration)
	timer.timeout.connect(_restore_fade_data.bind(fade_data))


## Restore original materials + return fade materials to the pool. Called by
## the SceneTreeTimer timeout scheduled from `_apply_fade_in`. Safe to call
## when meshes have been freed during the fade — `is_instance_valid()` guards
## every access, and the pool is always recovered regardless.
func _restore_fade_data(fade_data: Array[Dictionary]) -> void:
	for entry: Dictionary in fade_data:
		var fade_mat_ref: Variant = entry.get("fade_material")
		var mesh_inst_ref: Variant = entry.get("mesh_instance")

		# Return the fade material to the pool regardless of mesh validity.
		if is_instance_valid(fade_mat_ref):
			_release_fade_material(fade_mat_ref as ShaderMaterial)

		# Restore original material only when the mesh is still alive.
		if not is_instance_valid(mesh_inst_ref):
			continue
		var mesh_inst: MeshInstance3D = mesh_inst_ref as MeshInstance3D
		# Only restore material_override if the mesh originally had one.
		# Multi-surface meshes (ships, buildings) have no material_override —
		# their per-surface materials come from the mesh resource. Writing a
		# per-surface material back into material_override would override ALL
		# surfaces and break texture routing.
		var had_override: bool = mesh_inst.get_meta("_had_material_override", false)
		if had_override:
			var original_mat: Material = mesh_inst.get_meta(
				"_pre_fade_material", entry.get("original_material")
			)
			mesh_inst.material_override = original_mat
		else:
			mesh_inst.material_override = null
		mesh_inst.remove_meta("_pre_fade_material")
		mesh_inst.remove_meta("_had_material_override")


## Find all MeshInstance3D nodes in a hierarchy
func _find_mesh_instances(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node as MeshInstance3D)

	for child in node.get_children():
		_find_mesh_instances(child, result)


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
		"significant_objects_registered": 0,
	}


## Get current statistics
func get_stats() -> Dictionary:
	return stats.duplicate()
