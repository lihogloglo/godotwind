## Interior Pocket Manager — Manages seamless interior/exterior transitions
##
## Loads interior cells as isolated "pockets" in the same World3D,
## separated by spatial offset, render layers, and physics layers.
##
## Architecture (Phase 1 consensus):
## - 2-slot offset pool (expandable), Y=-500 with 1km X spacing
## - Render layers: exterior=1-2, interior=3-4
## - Physics layers: exterior=1-4, interior=5-6 per slot
## - Door proximity triggers: 20m preload, 3m interact
## - Transition: fade-to-black + environment swap + layer mask swap
## - Eviction: distance-based with grace period for interior→interior
##
## Usage:
##   var pocket_mgr := InteriorPocketManager.new()
##   pocket_mgr.initialize(cell_manager, scene_root, world_environment)
##   # Each frame:
##   pocket_mgr.update(player_position, delta)
##   # To transition:
##   pocket_mgr.enter_interior(door_info)
##   pocket_mgr.exit_to_exterior()
class_name InteriorPocketManager
extends Node

const CS := preload("res://src/core/coordinate_system.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const DoorPortalScript := preload("res://src/core/world/door_portal.gd")
const DoorUtils := preload("res://src/core/world/door_utils.gd")
const DOOR_CLIP_SHADER := preload("res://src/core/world/shaders/door_clip.gdshader")
const LightAnimatorScript := preload("res://src/core/world/light_animator.gd")
const LightShadowBudgetScript := preload("res://src/core/world/light_shadow_budget.gd")

#region Constants

## Maximum simultaneously loaded pockets
const MAX_POCKET_SLOTS: int = 2

## Pocket placement offsets — far below and apart to avoid any overlap
const POCKET_BASE_Y: float = -500.0
const POCKET_SPACING_X: float = 1000.0

## Door detection radii (squared for fast distance checks)
## Preload radius triggers pocket loading before the player reaches the door.
## Only the CLOSEST door's pocket is preloaded (not all doors in range) to avoid
## thrashing the 2 pocket slots in dense areas like Seyda Neen.
const PRELOAD_RADIUS: float = 10.0
const PRELOAD_RADIUS_SQ: float = PRELOAD_RADIUS * PRELOAD_RADIUS
const INTERACT_RADIUS: float = 3.0
const INTERACT_RADIUS_SQ: float = INTERACT_RADIUS * INTERACT_RADIUS

## Eviction distance — if player is this far from ALL doors to an interior, evict
const EVICT_RADIUS: float = 250.0  # ~2 cell widths
const EVICT_RADIUS_SQ: float = EVICT_RADIUS * EVICT_RADIUS

## Grace period before evicting a pocket after leaving (seconds)
const EVICT_GRACE_PERIOD: float = 10.0

## Render layer masks
const EXTERIOR_RENDER_LAYERS: int = 0x3      # Layers 1-2 (bits 0-1)
const INTERIOR_RENDER_LAYERS: int = 0xC      # Layers 3-4 (bits 2-3)
const COMBINED_RENDER_LAYERS: int = 0xF     # Layers 1-4 (exterior + interior)
const ALL_RENDER_LAYERS: int = 0xFFFFF       # All 20 layers

## Physics layer assignments (per slot)
## Exterior uses layers 1-4, interior slots use 5-6 and 7-8
const EXTERIOR_PHYSICS_LAYERS: int = 0xF     # Layers 1-4 (bits 0-3)
const INTERIOR_PHYSICS_BASE: int = 4          # First interior physics layer bit index

## Fade duration for transitions
const FADE_DURATION: float = 0.3

## Building model path patterns for seamless transition support.
## Matched against ESM STAT model paths to identify the building containing a door.
## Order: most specific first. Patterns are substring-matched (lowercase).
const BUILDING_PATTERNS: Array[String] = [
	"ex_common_house", "ex_common_warehouse", "ex_common_tower", "ex_common_",
	"ex_hlaalu_b", "ex_hlaalu_tower", "ex_hlaalu_manor",
	"ex_redoran_b", "ex_redoran_tower", "ex_redoran_manor",
	"ex_velothi_tower", "ex_velothi_",
	"ex_telvanni_tower", "ex_telvanni_manor", "ex_t_",
	"ex_imperial_tower", "ex_imperial_fort", "ex_imperial_castle",
	"ex_ashl_tower", "ex_ashl_",
	"ex_nord_", "ex_de_shack",
	"ex_stronghold",
	"ex_vivec",
	"ex_dwe_", "ex_dwrv_",  # Dwemer exterior buildings (not caves)
	"ex_dae_",              # Daedric shrine exteriors
]

## Non-seamless entrance patterns — caves, tombs, terrain holes.
## Doors whose nearby STAT matches these use fade-to-black instead of seamless.
## NOTE: Only cave/terrain entrances go here. Building shells (ex_dwe_, ex_dae_)
## are actual structures with walls and support seamless — they go in BUILDING_PATTERNS.
const NON_SEAMLESS_PATTERNS: Array[String] = [
	"ex_cave", "cave_door", "ex_bc_cave", "ex_cavern",
	"ex_tomb", "tomb_door", "ancestral",
	"terrain_",
	"ex_ship", "ship_cabin", "trapdoor",  # Horizontal doors — alignment assumes Y-axis yaw only
]

## Maximum search radius for finding the building STAT near a door (meters)
const BUILDING_SEARCH_RADIUS: float = 5.0
const BUILDING_SEARCH_RADIUS_SQ: float = BUILDING_SEARCH_RADIUS * BUILDING_SEARCH_RADIUS

#endregion

#region Types

## Registered door information
class DoorInfo:
	var ref_id: StringName           ## Door object ID
	var world_position: Vector3      ## Door position in Godot world coords
	var door_rotation_mw: Vector3    ## Door's own rotation in MW coords (for portal quad orientation)
	var target_cell_name: String     ## Interior cell name
	var teleport_pos_mw: Vector3     ## Teleport destination (MW coords)
	var teleport_rot_mw: Vector3     ## Teleport rotation (MW coords)
	var exterior_grid: Vector2i      ## Which exterior cell this door belongs to
	var is_interior_door: bool       ## True if this door is inside an interior (leads out or to another interior)
	var source_cell_name: String     ## Cell this door is in (for interior doors)
	var building_ref_id: StringName = &""  ## STAT ref_id of the building containing this door
	var building_model_path: String = ""   ## Model path of the building (for logging/debugging)
	var supports_seamless: bool = true     ## False for caves, tombs, terrain entrances → use fade-to-black

	func get_teleport_pos_godot() -> Vector3:
		return CS.vector_to_godot(teleport_pos_mw)

	## Full 3-axis rotation basis — use for OBJECT placement, not player facing.
	func get_teleport_basis_godot() -> Basis:
		return CS.esm_rotation_to_godot_basis(teleport_rot_mw)

	## Player-facing yaw-only basis — use for teleport destinations.
	## DODT rotation is the player's facing direction. Only Z (yaw) matters
	## for actors (OpenMW ignores X/Y for player rotation).
	## MW builds yaw as Quaternion(Vector3(0,0,-1), angle) — rotation around
	## NEGATIVE Z. quaternion_to_godot() swaps (x,z,-y,w), which negates
	## the Y component, effectively giving Basis(UP, -angle) in Godot space.
	func get_teleport_yaw_basis_godot() -> Basis:
		return Basis(Vector3.UP, -teleport_rot_mw.z)

	func get_door_basis_godot() -> Basis:
		return CS.esm_rotation_to_godot_basis(door_rotation_mw)


## Loaded pocket state
class PocketSlot:
	var slot_index: int = -1
	var cell_name: String = ""
	var cell_node: Node3D = null
	var cell_record: CellRecord = null
	var interior_environment: Environment = null
	var is_occupied: bool = false
	var is_loading: bool = false
	var last_access_time: float = 0.0
	var evict_timer: float = -1.0  ## Countdown to eviction (-1 = not evicting)
	var physics_layer_mask: int = 0
	var doors_inside: Array[DoorInfo] = []  ## Doors within this interior

	func get_offset() -> Vector3:
		return Vector3(slot_index * POCKET_SPACING_X, POCKET_BASE_Y, 0.0)

	func clear() -> void:
		if cell_node and is_instance_valid(cell_node):
			cell_node.queue_free()
		cell_node = null
		cell_record = null
		interior_environment = null
		cell_name = ""
		is_occupied = false
		is_loading = false
		evict_timer = -1.0
		doors_inside.clear()

#endregion

#region State

## Dependencies (set via initialize())
var _cell_manager: CellManagerScript = null
var _scene_root: Node3D = null
var _world_environment: WorldEnvironment = null
var _camera: Camera3D = null
var _sun: DirectionalLight3D = null
var _sun_original_cull_mask: int = 0

## Container for all pocket geometry
var _pocket_container: Node3D = null

## Pocket slots
var _slots: Array[PocketSlot] = []

## Registered exterior doors (flat array, polled each frame)
var _exterior_doors: Array[DoorInfo] = []

## Currently active pocket (player is inside)
var _active_pocket: PocketSlot = null

## Whether player is currently in an interior
var _is_inside: bool = false

## Cached exterior environment for restoring on exit
var _exterior_environment: Environment = null

## Closest door info (for UI prompts)
var _closest_door: DoorInfo = null
var _closest_door_distance_sq: float = INF

## Player body for physics layer swapping (optional, set via set_player_body())
var _player_body: CollisionObject3D = null

## Track which doors are already in preload range (avoid signal spam)
var _doors_in_preload_range: Dictionary = {}  # StringName -> bool

## Fade state
var _fade_rect: ColorRect = null
var _is_transitioning: bool = false

## Portal rendering (Phase 2a — outside-looking-in)
var _active_portal: RefCounted = null  # DoorPortal
var _portal_door_ref_id: StringName = &""  # Track which door has the active portal

## Interior wall clip materials applied near door during seamless mode (view-out hole)
## Maps MeshInstance3D instance_id -> original Material (or null)
var _clipped_wall_materials: Dictionary = {}
var _disabled_interior_wall_collision: Dictionary = {}  # instance_id -> {layer, mask}

## Seamless walk-through: tracks which side of the door plane the player is on
## Maps door ref_id -> float (signed distance to door plane last frame, positive = exterior side)
var _door_plane_sides: Dictionary = {}

## Walk-through radius — player must be within this range for auto-transition
const WALKTHROUGH_RADIUS: float = 2.0
const WALKTHROUGH_RADIUS_SQ: float = WALKTHROUGH_RADIUS * WALKTHROUGH_RADIUS

## When false, disables seamless walk-through and stencil portal preview.
## Doors use classic Morrowind behavior: ENTER key → fade-to-black → teleport.
## Pocket preloading still runs for fast transitions. Hot-swappable at runtime;
## only affects NEW transitions (in-progress seamless sessions finish naturally).
var seamless_enabled: bool = false

## Seamless transition state — tracks the door used for zero-teleport entry
## so we can detect reverse crossing for seamless exit
var _seamless_entry_door: DoorInfo = null
var _seamless_door_forward: Vector3 = Vector3.ZERO
var _seamless_prev_side: float = 0.0

## Interior door meshes hidden during seamless mode (restored on exit)
var _seamless_hidden_doors: Array[Node3D] = []

## Exterior building meshes hidden during seamless interior visit
## (restored when player exits back to exterior)
var _hidden_building_meshes: Array[MeshInstance3D] = []

## Exterior collision bodies disabled during seamless interior visit
## Maps CollisionObject3D instance_id -> { layer: int, mask: int }
var _disabled_building_collision: Dictionary = {}

## Environment blend duration for seamless transitions
const ENV_BLEND_DURATION: float = 0.2

## Hysteresis dead zone for door plane crossing (meters past the plane).
## Enter triggers at -THRESHOLD (into interior), exit at +THRESHOLD (into exterior).
## Prevents oscillation from physics jitter without blocking intentional back-and-forth.
const SEAMLESS_PLANE_THRESHOLD: float = 0.3

## Signals
signal door_in_range(door: DoorInfo, distance: float)       ## Player within interact range
signal door_preload_range(door: DoorInfo)                     ## Player within preload range
signal transition_started(target_cell: String)
signal transition_completed(cell_name: String)
signal pocket_loaded(cell_name: String, slot_index: int)
signal pocket_evicted(cell_name: String)

#endregion

#region Initialization

## Initialize the pocket manager
## cell_manager: The CellManager used for loading cells
## world_env: WorldEnvironment node for environment swapping
## camera: Player camera for layer mask swapping
## Note: This node must be added to the scene tree before calling initialize()
func initialize(cell_manager: CellManagerScript,
				world_env: WorldEnvironment = null, camera: Camera3D = null,
				sun: DirectionalLight3D = null) -> void:
	_cell_manager = cell_manager
	_scene_root = get_parent() as Node3D
	_world_environment = world_env
	_camera = camera
	_sun = sun
	if _sun:
		_sun_original_cull_mask = _sun.light_cull_mask

	# Cache exterior environment
	if _world_environment and _world_environment.environment:
		_exterior_environment = _world_environment.environment.duplicate()

	# Create pocket container as child of this node's parent
	_pocket_container = Node3D.new()
	_pocket_container.name = "InteriorPockets"
	if _scene_root:
		_scene_root.add_child(_pocket_container)
	else:
		add_child(_pocket_container)

	# Initialize slots
	_slots.clear()
	for i in MAX_POCKET_SLOTS:
		var slot := PocketSlot.new()
		slot.slot_index = i
		# Each slot gets its own physics layers (2 layers per slot)
		slot.physics_layer_mask = (0x3 << (INTERIOR_PHYSICS_BASE + i * 2))
		_slots.append(slot)

	# Create fade overlay
	_create_fade_overlay()

	Log.info("streaming", "InteriorPocketManager initialized: %d slots" % MAX_POCKET_SLOTS)


## Set the player's physics body for collision layer swapping during transitions
func set_player_body(body: CollisionObject3D) -> void:
	_player_body = body


## Update the camera reference (call when switching between fly/player cameras)
func set_camera(cam: Camera3D) -> void:
	_camera = cam


func _exit_tree() -> void:
	if Engine.has_meta("_quitting"):
		return
	cleanup()

#endregion

#region Door Registration

## Register doors from a loaded exterior cell
## Call this when an exterior cell is loaded into the streaming system
func register_exterior_cell_doors(cell_record: CellRecord, cell_grid: Vector2i) -> int:
	var count := 0
	var cell_origin: Vector3 = CS.cell_grid_to_world_godot(cell_grid)

	for ref: CellReference in cell_record.references:
		if not ref.is_teleport:
			continue
		if ref.teleport_cell.is_empty():
			continue

		# Verify destination is an interior cell
		var dest_cell: CellRecord = ESMManager.get_cell(ref.teleport_cell)
		if not dest_cell or not dest_cell.is_interior():
			continue

		var door := DoorInfo.new()
		door.ref_id = ref.ref_id
		door.world_position = CS.vector_to_godot(ref.position)
		door.door_rotation_mw = ref.rotation
		door.target_cell_name = ref.teleport_cell
		door.teleport_pos_mw = ref.teleport_pos
		door.teleport_rot_mw = ref.teleport_rot
		door.exterior_grid = cell_grid
		door.is_interior_door = false

		# Check for duplicates (same door registered from overlapping cell loads)
		var already_registered := false
		for existing: DoorInfo in _exterior_doors:
			if existing.ref_id == door.ref_id and existing.exterior_grid == door.exterior_grid:
				already_registered = true
				break

		if not already_registered:
			# Identify the building containing this door from ESM data
			_identify_building_for_door(door, cell_record)
			_exterior_doors.append(door)
			count += 1

	if count > 0:
		Log.debug("streaming", "Registered %d doors from cell %s" % [count, cell_grid])
	return count


## Unregister doors from an unloaded exterior cell
func unregister_exterior_cell_doors(cell_grid: Vector2i) -> void:
	var before := _exterior_doors.size()
	_exterior_doors = _exterior_doors.filter(func(d: DoorInfo) -> bool:
		return d.exterior_grid != cell_grid
	)
	var removed := before - _exterior_doors.size()
	if removed > 0:
		Log.debug("streaming", "Unregistered %d doors from cell %s" % [removed, cell_grid])

	# Check if any loaded pockets lost all their doors
	_check_orphaned_pockets()


## Register doors found inside a loaded interior pocket
func _register_interior_doors(pocket: PocketSlot) -> void:
	if not pocket.cell_record:
		return

	pocket.doors_inside.clear()
	for ref: CellReference in pocket.cell_record.references:
		if not ref.is_teleport:
			continue
		# Note: teleport_cell CAN be empty for interior→exterior doors.
		# Morrowind stores exterior destinations as world-space coordinates
		# in DODT without a DNAM cell name. These are exit doors.

		var door := DoorInfo.new()
		door.ref_id = ref.ref_id
		# Interior door position is relative to pocket offset
		door.world_position = CS.vector_to_godot(ref.position) + pocket.get_offset()
		door.door_rotation_mw = ref.rotation
		door.target_cell_name = ref.teleport_cell  # Empty string = exterior exit
		door.teleport_pos_mw = ref.teleport_pos
		door.teleport_rot_mw = ref.teleport_rot
		door.is_interior_door = true
		door.source_cell_name = pocket.cell_name

		pocket.doors_inside.append(door)

	if not pocket.doors_inside.is_empty():
		Log.debug("streaming", "Found %d doors inside '%s'" % [
			pocket.doors_inside.size(), pocket.cell_name
		])


## Identify the building STAT that contains a door, using ESM cell reference data.
## Searches all STAT references in the cell, finds ones with building model patterns
## within BUILDING_SEARCH_RADIUS, then picks the one whose model path best matches
## known building patterns. Falls back to largest nearby STAT if no pattern matches.
## Sets door.building_ref_id, door.building_model_path, and door.supports_seamless.
func _identify_building_for_door(door: DoorInfo, cell_record: CellRecord) -> void:
	var door_pos_mw: Vector3 = CS.vector_to_mw(door.world_position)
	var best_ref_id: StringName = &""
	var best_model_path: String = ""
	var best_dist_sq: float = INF
	var is_non_seamless: bool = false

	# First pass: find all STAT refs near the door and check their model paths
	for ref: CellReference in cell_record.references:
		# Skip the door itself and non-static refs
		if ref.ref_id == door.ref_id:
			continue

		# Look up the record to get its type and model
		var record_type: Array = [""]
		var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if not base_record:
			continue
		var type_name: String = record_type[0]

		# Only consider STAT (static) and ACTI (activator) records — buildings/structures
		if type_name != "static" and type_name != "activator":
			continue

		# Get model path
		var model_path: String = ""
		if "model" in base_record and base_record.model:
			model_path = str(base_record.model).to_lower()
		if model_path.is_empty():
			continue

		# Check distance (in MW coords to avoid conversion overhead for every ref)
		var dist_sq: float = ref.position.distance_squared_to(door_pos_mw)
		if dist_sq > BUILDING_SEARCH_RADIUS_SQ * CS.UNITS_PER_METER * CS.UNITS_PER_METER:  # MW units²
			continue

		# Check for non-seamless entrance patterns (caves, tombs)
		for pattern: String in NON_SEAMLESS_PATTERNS:
			if model_path.contains(pattern):
				is_non_seamless = true
				break

		# Check building patterns — prefer building matches over generic proximity
		var is_building: bool = false
		for pattern: String in BUILDING_PATTERNS:
			if model_path.contains(pattern):
				is_building = true
				break

		if is_building and dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_ref_id = ref.ref_id
			best_model_path = model_path

	# Fallback: if no building pattern matched, try the closest large STAT within range
	# (handles mod content and unusual building names)
	if best_ref_id == &"" and not is_non_seamless:
		for ref: CellReference in cell_record.references:
			if ref.ref_id == door.ref_id:
				continue
			var record_type: Array = [""]
			var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)
			if not base_record or record_type[0] != "static":
				continue
			var model_path: String = ""
			if "model" in base_record and base_record.model:
				model_path = str(base_record.model).to_lower()
			if model_path.is_empty():
				continue
			var dist_sq: float = ref.position.distance_squared_to(door_pos_mw)
			# Tighter radius for fallback (3m Godot in MW units)
			var fallback_radius_mw: float = 3.0 * CS.UNITS_PER_METER
			if dist_sq > fallback_radius_mw * fallback_radius_mw:
				continue
			if dist_sq < best_dist_sq:
				best_dist_sq = dist_sq
				best_ref_id = ref.ref_id
				best_model_path = model_path

	# Apply results
	door.building_ref_id = best_ref_id
	door.building_model_path = best_model_path
	door.supports_seamless = not is_non_seamless and best_ref_id != &""

	# Diagnostic logging
	if best_ref_id != &"":
		var dist_godot: float = sqrt(best_dist_sq) * CS.SCALE_FACTOR  # Convert MW to meters
		Log.info("streaming", "Door '%s' -> building '%s' (%s, dist=%.1fm, seamless=%s)" % [
			door.ref_id, best_ref_id, best_model_path.get_file(),
			dist_godot, door.supports_seamless])
	else:
		Log.warn("streaming", "Door '%s' -> NO building found (seamless=%s, non_seamless_match=%s)" % [
			door.ref_id, door.supports_seamless, is_non_seamless])

#endregion

#region Frame Update

## Call each frame with the player's world position
func update(player_pos: Vector3, delta: float) -> void:
	if _is_transitioning:
		return

	_closest_door = null
	_closest_door_distance_sq = INF

	if _is_inside:
		_update_interior(player_pos, delta)
	else:
		_update_exterior(player_pos, delta)

	# Update eviction timers
	_update_eviction(delta)


func _update_exterior(player_pos: Vector3, _delta: float) -> void:
	var best_portal_door: DoorInfo = null
	var best_portal_dist_sq: float = DoorPortalScript.PORTAL_RANGE_SQ

	for door: DoorInfo in _exterior_doors:
		var dist_sq := player_pos.distance_squared_to(door.world_position)

		# Track closest door for UI
		if dist_sq < _closest_door_distance_sq:
			_closest_door_distance_sq = dist_sq
			_closest_door = door

		# Interact range
		if dist_sq < INTERACT_RADIUS_SQ:
			door_in_range.emit(door, sqrt(dist_sq))

		# Track best candidate for portal rendering (closest door with loaded pocket)
		if dist_sq < best_portal_dist_sq:
			var slot: PocketSlot = _get_slot_for_cell(door.target_cell_name)
			if slot and slot.is_occupied:
				best_portal_dist_sq = dist_sq
				best_portal_door = door

	# Preload only the CLOSEST door's pocket (not all doors in range).
	# Avoids thrashing the 2 pocket slots in dense areas with many nearby doors.
	if _closest_door and _closest_door_distance_sq < PRELOAD_RADIUS_SQ:
		_ensure_pocket_loaded(_closest_door.target_cell_name)
		if not _doors_in_preload_range.has(_closest_door.ref_id):
			_doors_in_preload_range[_closest_door.ref_id] = true
			door_preload_range.emit(_closest_door)
	# Clear preload tracking for doors no longer closest
	for ref_id: StringName in _doors_in_preload_range.keys():
		if not _closest_door or ref_id != _closest_door.ref_id:
			_doors_in_preload_range.erase(ref_id)

	# Update portal state
	if best_portal_door and not (_active_portal and _active_portal.is_active):
		Log.info("streaming", "Portal candidate: '%s' (dist=%.1fm)" % [
			best_portal_door.target_cell_name, sqrt(best_portal_dist_sq)])
	elif not best_portal_door and Engine.get_frames_drawn() % 300 == 0:
		# Periodic debug: why no portal candidate? (every ~5 seconds)
		var loaded_count := 0
		for s: PocketSlot in _slots:
			if s.is_occupied:
				loaded_count += 1
		Log.debug("streaming", "No portal candidate. Doors=%d, Loaded=%d" % [
			_exterior_doors.size(), loaded_count])
	# Guard all sub-updates against transition race (async enter_interior can yield)
	# Also guard portal: if _seamless_enter() set _is_inside during _update_walkthrough(),
	# do NOT re-activate the portal on the same frame (that would re-apply stencil-read
	# to interior materials while the player is inside → interior becomes invisible).
	if not _is_transitioning:
		# Classic mode: skip walk-through detection and portal preview entirely.
		# Doors only activate via enter_interior() (ENTER key in world_explorer).
		if seamless_enabled:
			_update_walkthrough(player_pos)
			if not _is_inside:
				_update_portal(best_portal_door, player_pos)
		else:
			# Classic mode: deactivate any active portal (e.g. toggled mid-approach)
			if _active_portal and _active_portal.is_active:
				_deactivate_portal()
				_portal_door_ref_id = &""


func _update_interior(player_pos: Vector3, _delta: float) -> void:
	if not _active_pocket:
		return

	# Door plane crossing exit: if player crosses back to the exterior side
	# of the entry door plane (past the hysteresis threshold), exit seamless mode.
	# Also exit if player walks far from the door (cleanup for edge cases).
	if _seamless_entry_door:
		var to_door: Vector3 = player_pos - _seamless_entry_door.world_position
		var signed_dist: float = to_door.dot(_seamless_door_forward)
		# Hysteresis exit: player crossed THRESHOLD past the door plane to exterior side
		if signed_dist > SEAMLESS_PLANE_THRESHOLD:
			Log.info("streaming", "Player exited interior '%s' (crossed door plane, dist=%.2fm)" % [
				_seamless_entry_door.target_cell_name, signed_dist])
			_seamless_exit()
			return
		# Fallback: 15m distance cleanup (in case plane detection misses)
		if player_pos.distance_squared_to(_seamless_entry_door.world_position) > 225.0:
			Log.info("streaming", "Player exited interior '%s' (far from door)" % [
				_seamless_entry_door.target_cell_name])
			_seamless_exit()
			return

	# Check doors inside the current interior
	for door: DoorInfo in _active_pocket.doors_inside:
		var dist_sq := player_pos.distance_squared_to(door.world_position)

		if dist_sq < _closest_door_distance_sq:
			_closest_door_distance_sq = dist_sq
			_closest_door = door

		# Preload destination (could be exterior or another interior)
		if dist_sq < PRELOAD_RADIUS_SQ:
			var dest_cell: CellRecord = ESMManager.get_cell(door.target_cell_name)
			if dest_cell and dest_cell.is_interior():
				_ensure_pocket_loaded(door.target_cell_name)

		if dist_sq < INTERACT_RADIUS_SQ:
			door_in_range.emit(door, sqrt(dist_sq))


func _update_eviction(delta: float) -> void:
	for slot: PocketSlot in _slots:
		if not slot.is_occupied or slot == _active_pocket:
			continue

		if slot.evict_timer > 0:
			slot.evict_timer -= delta
			if slot.evict_timer <= 0:
				_evict_pocket(slot)

#endregion

#region Pocket Loading

## Ensure a pocket is loaded for the given interior cell
func _ensure_pocket_loaded(cell_name: String) -> void:
	# Already loaded?
	for slot: PocketSlot in _slots:
		if slot.is_occupied and slot.cell_name == cell_name:
			slot.evict_timer = -1.0  # Cancel pending eviction
			slot.last_access_time = Time.get_ticks_msec() / 1000.0
			return

	# Already loading?
	for slot: PocketSlot in _slots:
		if slot.is_loading and slot.cell_name == cell_name:
			return

	# Find a free slot
	var free_slot: PocketSlot = _find_free_slot()
	if not free_slot:
		# Evict the oldest non-active pocket
		free_slot = _evict_oldest_pocket()
		if not free_slot:
			Log.warn("streaming", "No pocket slots available for '%s'" % cell_name)
			return

	_load_pocket(free_slot, cell_name)


func _find_free_slot() -> PocketSlot:
	for slot: PocketSlot in _slots:
		if not slot.is_occupied and not slot.is_loading:
			return slot
	return null


func _evict_oldest_pocket() -> PocketSlot:
	var oldest: PocketSlot = null
	var oldest_time: float = INF

	for slot: PocketSlot in _slots:
		if slot == _active_pocket:
			continue
		if slot.is_occupied and slot.last_access_time < oldest_time:
			oldest_time = slot.last_access_time
			oldest = slot

	if oldest:
		_evict_pocket(oldest)
	return oldest


func _load_pocket(slot: PocketSlot, cell_name: String) -> void:
	slot.is_loading = true
	slot.cell_name = cell_name

	Log.info("streaming", "[POCKET] Loading '%s' into slot %d" % [cell_name, slot.slot_index])

	# Get cell record
	var cell_record: CellRecord = ESMManager.get_cell(cell_name)
	if not cell_record:
		Log.error("streaming", "[POCKET] Cell not found in ESM: '%s'" % cell_name)
		slot.is_loading = false
		slot.cell_name = ""
		return

	slot.cell_record = cell_record
	Log.info("streaming", "[POCKET] Cell record found: '%s' (%d references, interior=%s)" % [
		cell_name, cell_record.references.size(), cell_record.is_interior()])

	# Validate cell_manager before accessing private members
	if not _cell_manager:
		Log.error("streaming", "[POCKET] _cell_manager is null!")
		slot.is_loading = false
		slot.cell_name = ""
		slot.cell_record = null
		return

	# Disable exterior streaming optimizations for pocket loads:
	# - fade-in: pockets at Y=-500 are invisible, fade causes stencil-read race condition
	# - static renderer: RS instances render at ESM world position, not pocket offset,
	#   and don't get INTERIOR_RENDER_LAYERS applied (they're not Node3D children)
	# - multimesh instancing: same issue — batched instances bypass pocket positioning
	# - max_actor_distance: camera is at exterior position during pocket load, but
	#   interior NPCs use small cell-local coords — distance check would skip all NPCs
	# Interior cells are small rooms — these exterior optimizations aren't needed.
	var prev_fade_in: bool = _cell_manager._instantiator.enable_fade_in
	var prev_static_cm: bool = _cell_manager.use_static_renderer
	var prev_static_inst: bool = _cell_manager._instantiator.use_static_renderer
	var prev_multimesh: bool = _cell_manager.use_multimesh_instancing
	var prev_actor_dist: float = _cell_manager._instantiator.max_actor_distance
	_cell_manager._instantiator.enable_fade_in = false
	_cell_manager.use_static_renderer = false
	_cell_manager._instantiator.use_static_renderer = false  # Must sync — instantiator has its own copy
	_cell_manager.use_multimesh_instancing = false
	_cell_manager._instantiator.max_actor_distance = 0.0  # Disable distance check for interior NPCs
	Log.info("streaming", "[POCKET] CellManager options saved, loading cell geometry...")

	# Load cell geometry
	var cell_node: Node3D = _cell_manager.load_cell(cell_name)

	# Restore settings regardless of load result
	_cell_manager._instantiator.enable_fade_in = prev_fade_in
	_cell_manager.use_static_renderer = prev_static_cm
	_cell_manager._instantiator.use_static_renderer = prev_static_inst
	_cell_manager.use_multimesh_instancing = prev_multimesh
	_cell_manager._instantiator.max_actor_distance = prev_actor_dist
	Log.info("streaming", "[POCKET] CellManager options restored")

	if not cell_node:
		Log.error("streaming", "[POCKET] load_cell() returned null for '%s'" % cell_name)
		slot.is_loading = false
		slot.cell_name = ""
		slot.cell_record = null
		return

	Log.info("streaming", "[POCKET] Cell loaded: %d children" % cell_node.get_child_count())

	# Position at slot offset
	cell_node.position = slot.get_offset()

	# Diagnostic: log loaded references for stray model investigation
	var child_count: int = cell_node.get_child_count()
	Log.info("streaming", "Pocket '%s': %d objects loaded" % [cell_name, child_count])
	if child_count < 200:  # Only log details for small-ish cells
		for child in cell_node.get_children():
			var model_path: String = str(child.get_meta("model_path", ""))
			if not model_path.is_empty():
				Log.debug("streaming", "  Pocket obj: '%s' model=%s pos=%s" % [
					child.name, model_path.get_file(), child.position])

	# Apply render layer isolation
	_set_layers_recursive(cell_node, INTERIOR_RENDER_LAYERS)

	# Apply physics layer isolation
	_set_physics_layers_recursive(cell_node, slot.physics_layer_mask)

	# Add to pocket container
	_pocket_container.add_child(cell_node)
	slot.cell_node = cell_node

	# Build interior environment from AMBI data
	slot.interior_environment = _build_interior_environment(cell_record)

	# Register doors inside this interior
	_register_interior_doors(slot)

	# Add light-blocking box around interior geometry.
	# MW interior meshes have gaps that let exterior sun leak through.
	# A black box on interior layers blocks stray light and provides a
	# dark void background visible through any holes.
	_add_lightbox(cell_node)

	# Add light animator for flicker/pulse effects
	var light_count := _count_lights(cell_node)
	if light_count > 0:
		var animator: Node = LightAnimatorScript.new()
		animator.name = "LightAnimator"
		cell_node.add_child(animator)

		# Add shadow budget manager with interior-appropriate thresholds.
		# Morrowind interiors have 5-15 lights — generous budget is fine.
		var shadow_budget: Node = LightShadowBudgetScript.new()
		shadow_budget.name = "LightShadowBudget"
		shadow_budget.camera = _camera
		shadow_budget.max_shadow_lights = 16
		shadow_budget.shadow_cube_enable = 18.0
		shadow_budget.shadow_cube_disable = 20.0
		shadow_budget.shadow_dual_enable = 48.0
		shadow_budget.shadow_dual_disable = 50.0
		cell_node.add_child(shadow_budget)

	# Mark as loaded
	slot.is_occupied = true
	slot.is_loading = false
	slot.last_access_time = Time.get_ticks_msec() / 1000.0
	slot.evict_timer = -1.0

	Log.info("streaming", "Interior pocket loaded: '%s' (slot %d, %d objects, %d doors, %d lights)" % [
		cell_name, slot.slot_index, cell_node.get_child_count(), slot.doors_inside.size(), light_count
	])
	pocket_loaded.emit(cell_name, slot.slot_index)


## Add a black box around interior geometry to block exterior sun leaking through gaps.
## Sized from the cell_node descendants' combined AABB + margin. Interior layers only.
func _add_lightbox(cell_node: Node3D) -> void:
	# Compute combined AABB of all MeshInstance3D descendants in local space
	var combined_aabb: AABB = _collect_lightbox_aabb_inner(cell_node, cell_node, AABB(), false)
	if combined_aabb.size.length_squared() < 0.01:
		Log.debug("streaming", "Lightbox: no mesh descendants found, skipping")
		return

	# Expand by margin to avoid clipping through interior walls
	combined_aabb = combined_aabb.grow(2.0)

	var box_mesh := BoxMesh.new()
	box_mesh.size = combined_aabb.size

	var box_mat := StandardMaterial3D.new()
	box_mat.albedo_color = Color(0.01, 0.01, 0.02)  # Near-black
	box_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box_mat.cull_mode = BaseMaterial3D.CULL_FRONT  # Only visible from inside
	box_mat.no_depth_test = false
	box_mat.render_priority = -5  # Render behind interior geometry

	var box_instance := MeshInstance3D.new()
	box_instance.name = "InteriorLightbox"
	box_instance.mesh = box_mesh
	box_instance.material_override = box_mat
	box_instance.position = combined_aabb.get_center()
	# Interior layers: the lightbox serves as both a visual depth-blocking backdrop
	# (prevents exterior objects from showing through gaps in interior geometry when
	# viewed through the stencil portal — the wall clip removes exterior wall depth,
	# so without this barrier exterior objects would be visible through interior gaps)
	# and a light blocker (sun rays via shadow casting).
	box_instance.layers = INTERIOR_RENDER_LAYERS
	box_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	cell_node.add_child(box_instance)
	Log.info("streaming", "Added lightbox: size=%s center=%s" % [combined_aabb.size, combined_aabb.get_center()])


## Recursively collect AABB from all MeshInstance3D descendants in cell_root local space.
func _collect_lightbox_aabb_inner(node: Node, cell_root: Node3D, aabb: AABB, found: bool) -> AABB:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh:
			var mesh_aabb: AABB = mi.mesh.get_aabb()
			# Transform to cell_root local space: get relative transform from mi to cell_root
			var rel_xf: Transform3D = cell_root.global_transform.affine_inverse() * mi.global_transform
			var local_aabb: AABB = rel_xf * mesh_aabb
			if not found:
				aabb = local_aabb
				found = true
			else:
				aabb = aabb.merge(local_aabb)
	for child in node.get_children():
		aabb = _collect_lightbox_aabb_inner(child, cell_root, aabb, found)
		if aabb.size.length_squared() > 0.01:
			found = true
	return aabb


func _evict_pocket(slot: PocketSlot) -> void:
	if not slot.is_occupied:
		return

	# Deactivate portal if it's rendering this pocket's interior
	if _active_portal and _active_portal.is_active and _active_portal.get_cell_name() == slot.cell_name:
		_deactivate_portal()

	var cell_name := slot.cell_name
	Log.info("streaming", "Evicting interior pocket: '%s' (slot %d)" % [cell_name, slot.slot_index])

	slot.clear()
	pocket_evicted.emit(cell_name)


func _check_orphaned_pockets() -> void:
	for slot: PocketSlot in _slots:
		if not slot.is_occupied or slot == _active_pocket:
			continue

		# Check if any registered door still points to this pocket's cell
		var has_door := false
		for door: DoorInfo in _exterior_doors:
			if door.target_cell_name == slot.cell_name:
				has_door = true
				break

		if not has_door and slot.evict_timer < 0:
			slot.evict_timer = EVICT_GRACE_PERIOD
			Log.debug("streaming", "Pocket '%s' orphaned — evicting in %.0fs" % [
				slot.cell_name, EVICT_GRACE_PERIOD
			])

#endregion

#region Transitions

## Enter an interior through a door
## door: The DoorInfo for the door being entered
## Returns true if transition started successfully
func enter_interior(door: DoorInfo) -> bool:
	Log.info("streaming", "[ENTER] enter_interior() called: '%s'" % door.target_cell_name)

	if _is_transitioning:
		Log.warn("streaming", "[ENTER] Blocked — already transitioning")
		return false

	# Ensure pocket is loaded
	Log.info("streaming", "[ENTER] Step 1: _ensure_pocket_loaded('%s')" % door.target_cell_name)
	_ensure_pocket_loaded(door.target_cell_name)
	Log.info("streaming", "[ENTER] Step 1 done: pocket loaded")

	# Find the slot
	var slot: PocketSlot = _get_slot_for_cell(door.target_cell_name)
	if not slot or not slot.is_occupied:
		Log.error("streaming", "[ENTER] FAILED — pocket not loaded: '%s' (slot=%s, occupied=%s)" % [
			door.target_cell_name,
			"found" if slot else "null",
			str(slot.is_occupied) if slot else "n/a"])
		return false

	if not slot.cell_node or not is_instance_valid(slot.cell_node):
		Log.error("streaming", "[ENTER] FAILED — slot.cell_node is invalid for '%s'" % door.target_cell_name)
		return false

	_is_transitioning = true
	transition_started.emit(door.target_cell_name)

	# Deactivate portal before transitioning (we're going inside)
	_deactivate_portal()

	# Calculate destination position in pocket space
	var dest_pos: Vector3 = door.get_teleport_pos_godot() + slot.get_offset()
	var dest_basis: Basis = door.get_teleport_yaw_basis_godot()

	Log.info("streaming", "[ENTER] Step 2: dest=%s, slot_offset=%s, objects=%d, cell_node_valid=%s" % [
		dest_pos, slot.get_offset(),
		slot.cell_node.get_child_count() if slot.cell_node else -1,
		str(is_instance_valid(slot.cell_node))])

	# Perform transition
	Log.info("streaming", "[ENTER] Step 3: _do_transition (fade out → teleport → fade in)")
	await _do_transition(slot, dest_pos, dest_basis, true)
	Log.info("streaming", "[ENTER] Step 3 done: transition complete")

	# Validate slot is still valid after await (could be evicted during fade)
	if not slot.is_occupied or not slot.cell_node or not is_instance_valid(slot.cell_node):
		Log.error("streaming", "[ENTER] FAILED — slot became invalid during transition for '%s'" % door.target_cell_name)
		_is_transitioning = false
		return false

	_active_pocket = slot
	_is_inside = true
	_is_transitioning = false

	Log.info("streaming", "[ENTER] SUCCESS — entered interior: '%s'" % door.target_cell_name)
	transition_completed.emit(door.target_cell_name)
	return true


## Exit from interior to exterior
## door: The DoorInfo for the exit door
func exit_to_exterior(door: DoorInfo) -> bool:
	Log.info("streaming", "[EXIT] exit_to_exterior() called: '%s'" % door.target_cell_name)

	if _is_transitioning or not _is_inside:
		Log.warn("streaming", "[EXIT] Blocked — transitioning=%s, inside=%s" % [_is_transitioning, _is_inside])
		return false

	_is_transitioning = true
	transition_started.emit("exterior")

	# Calculate destination in world space
	var dest_pos: Vector3 = door.get_teleport_pos_godot()
	var dest_basis: Basis = door.get_teleport_yaw_basis_godot()

	Log.info("streaming", "[EXIT] dest=%s, teleport_rot_mw=%s, yaw_z=%.2f rad (%.1f°)" % [
		dest_pos, door.teleport_rot_mw, door.teleport_rot_mw.z, rad_to_deg(door.teleport_rot_mw.z)])

	# Perform transition
	await _do_transition(null, dest_pos, dest_basis, false)

	# Start eviction timer for the pocket we just left
	if _active_pocket:
		_active_pocket.evict_timer = EVICT_GRACE_PERIOD

	_active_pocket = null
	_is_inside = false
	_is_transitioning = false

	Log.info("streaming", "[EXIT] SUCCESS — exited to exterior")
	transition_completed.emit("exterior")
	return true


## Transition between two interiors
func transition_interior_to_interior(door: DoorInfo) -> bool:
	Log.info("streaming", "[INT→INT] transition called: '%s'" % door.target_cell_name)

	if _is_transitioning:
		Log.warn("streaming", "[INT→INT] Blocked — already transitioning")
		return false

	_ensure_pocket_loaded(door.target_cell_name)
	var new_slot: PocketSlot = _get_slot_for_cell(door.target_cell_name)
	if not new_slot or not new_slot.is_occupied:
		Log.error("streaming", "[INT→INT] FAILED — pocket not loaded: '%s'" % door.target_cell_name)
		return false

	if not new_slot.cell_node or not is_instance_valid(new_slot.cell_node):
		Log.error("streaming", "[INT→INT] FAILED — cell_node invalid for '%s'" % door.target_cell_name)
		return false

	_is_transitioning = true
	transition_started.emit(door.target_cell_name)

	var dest_pos: Vector3 = door.get_teleport_pos_godot() + new_slot.get_offset()
	var dest_basis: Basis = door.get_teleport_yaw_basis_godot()

	Log.info("streaming", "[INT→INT] dest=%s" % dest_pos)
	await _do_transition(new_slot, dest_pos, dest_basis, true)

	# Grace period for old pocket
	if _active_pocket and _active_pocket != new_slot:
		_active_pocket.evict_timer = EVICT_GRACE_PERIOD

	_active_pocket = new_slot
	_is_transitioning = false

	Log.info("streaming", "[INT→INT] SUCCESS — entered '%s'" % door.target_cell_name)
	transition_completed.emit(door.target_cell_name)
	return true


## Core transition: fade out → swap → fade in
func _do_transition(target_slot: PocketSlot, dest_pos: Vector3,
					dest_basis: Basis, entering_interior: bool) -> void:
	Log.info("streaming", "[TRANSITION] Start: entering=%s, dest=%s" % [entering_interior, dest_pos])

	# Fade out
	Log.info("streaming", "[TRANSITION] Fading out...")
	await _fade(0.0, 1.0, FADE_DURATION)
	Log.info("streaming", "[TRANSITION] Fade out complete")

	# Teleport: use player body if camera is parented to it (player mode),
	# otherwise teleport camera directly (fly camera mode).
	# The player body may exist but be inactive while the fly camera is active.
	var camera_is_on_body: bool = (_player_body and is_instance_valid(_player_body)
		and _camera and is_instance_valid(_camera)
		and not _camera.is_ancestor_of(_player_body)
		and _player_body.is_ancestor_of(_camera))
	if camera_is_on_body:
		_player_body.global_position = dest_pos
		_player_body.global_basis = dest_basis
		Log.info("streaming", "[TRANSITION] Teleported BODY to %s" % dest_pos)
	elif _camera and is_instance_valid(_camera):
		_camera.global_position = dest_pos  # DODT position already includes player height
		_camera.global_basis = dest_basis
		Log.info("streaming", "[TRANSITION] Teleported CAMERA to %s" % dest_pos)
	else:
		Log.error("streaming", "[TRANSITION] No valid camera or body for teleport!")

	# Swap render layers on camera
	if _camera and is_instance_valid(_camera):
		if entering_interior:
			_camera.cull_mask = INTERIOR_RENDER_LAYERS
		else:
			_camera.cull_mask = EXTERIOR_RENDER_LAYERS
		Log.info("streaming", "[TRANSITION] Camera cull_mask set to 0x%X" % _camera.cull_mask)

	# Swap environment
	if _world_environment and is_instance_valid(_world_environment):
		if entering_interior and target_slot and target_slot.interior_environment:
			_world_environment.environment = target_slot.interior_environment
			Log.info("streaming", "[TRANSITION] Environment set to interior")
		elif not entering_interior and _exterior_environment:
			_world_environment.environment = _exterior_environment
			Log.info("streaming", "[TRANSITION] Environment set to exterior")
	else:
		Log.warn("streaming", "[TRANSITION] WorldEnvironment not available")

	# Swap player physics layers
	if _player_body and is_instance_valid(_player_body):
		if entering_interior and target_slot:
			_player_body.collision_layer = target_slot.physics_layer_mask
			_player_body.collision_mask = target_slot.physics_layer_mask
		else:
			_player_body.collision_layer = EXTERIOR_PHYSICS_LAYERS
			_player_body.collision_mask = EXTERIOR_PHYSICS_LAYERS
		Log.info("streaming", "[TRANSITION] Physics layers set: layer=0x%X" % _player_body.collision_layer)

	# Fade in
	Log.info("streaming", "[TRANSITION] Fading in...")
	await _fade(1.0, 0.0, FADE_DURATION)
	Log.info("streaming", "[TRANSITION] Fade in complete — transition done")


## Seamless walk-through entry — no teleport, no fade, no layer swap.
## The pocket is already repositioned to align with the exterior door (by DoorPortal).
## The player is physically inside the interior geometry. Interior walls provide
## natural occlusion via depth buffer. No hard transition needed.
##
## What this does:
##   - Deactivate stencil portal (interior renders normally, not just through doorframe)
##   - Keep camera on COMBINED layers (player sees both exterior and interior)
##   - Mark pocket as active (prevents eviction)
##   - Track entry door for cleanup when player walks far away
##
## What this does NOT do:
##   - No render layer swap (camera stays COMBINED)
##   - No physics layer swap (player collides with both exterior and interior)
##   - No environment swap (lighting handled separately via distance-based blend)
##   - No teleport (player keeps walking)
func _seamless_enter(door: DoorInfo, slot: PocketSlot, door_forward: Vector3) -> void:
	Log.info("streaming", "Seamless enter: '%s' (slot %d)" % [door.target_cell_name, slot.slot_index])

	# 1. Set active pocket FIRST (prevents eviction)
	_active_pocket = slot
	_is_inside = true
	slot.evict_timer = -1.0

	# 2. Deactivate stencil portal — interior now renders normally (no stencil mask).
	#    keep_pocket_position=true: pocket stays at door-aligned position.
	#    Note: deactivate() resets cull_mask to EXTERIOR — we override to COMBINED.
	_deactivate_portal(true)

	# 3. Keep camera on COMBINED layers — player sees both exterior and interior.
	if _camera:
		_camera.cull_mask = COMBINED_RENDER_LAYERS

	# 3b. Hide interior door meshes near the door opening.
	# Portal deactivation restored them; hide again for seamless mode.
	_hide_seamless_interior_doors(door, slot)

	# 3c. Hide interior wall near the door to create a view-out hole
	#    (mirrors step 4 for exterior — interior walls are also solid with no doorway holes)
	_hide_interior_wall_near_door(door, slot)

	# 4. Hide the exterior building mesh AND collision near the door.
	#    Morrowind buildings are solid boxes with no doorway holes. Without the
	#    stencil's no_depth_test bypass, the exterior wall occludes the interior.
	#    Hiding the building shell lets interior render normally. Disabling its
	#    collision lets the player physically walk through.
	_hide_building_near_door(door)

	# 5. Expand player physics to include interior layers (so they collide with
	#    interior floors/walls) while keeping exterior (terrain, other buildings).
	if _player_body:
		_player_body.collision_layer = EXTERIOR_PHYSICS_LAYERS | slot.physics_layer_mask
		_player_body.collision_mask = EXTERIOR_PHYSICS_LAYERS | slot.physics_layer_mask

	# 6. Exclude interior layers from sun — interior OmniLights handle illumination.
	#    Skip for quasi-exterior cells (they share exterior sky/weather).
	if _sun and slot.cell_record and not slot.cell_record.is_quasi_exterior():
		_sun.light_cull_mask = _sun_original_cull_mask & ~INTERIOR_RENDER_LAYERS

	# 6b. Blend environment to interior lighting (AMBI data)
	if slot.interior_environment:
		_blend_environment(slot.interior_environment)

	# 7. Track entry door for eventual cleanup (when player walks far enough away,
	#    we can restore the pocket to Y=-500 and re-enable portal if they return)
	_seamless_entry_door = door
	_seamless_door_forward = door_forward
	_seamless_prev_side = -0.1

	transition_started.emit(door.target_cell_name)
	transition_completed.emit(door.target_cell_name)

	# Diagnostic: log everything for debugging
	var pocket_pos: Vector3 = slot.cell_node.position if slot.cell_node else Vector3.ZERO
	var cam_mask: int = _camera.cull_mask if _camera else -1
	Log.info("streaming", "Seamless enter complete: '%s' | pocket_pos=%s | cam_mask=0x%X | hidden_meshes=%d | hidden_collision=%d" % [
		door.target_cell_name, pocket_pos, cam_mask,
		_hidden_building_meshes.size(), _disabled_building_collision.size()])


## Seamless walk-through exit — player walked back out through the door.
## Restores pocket to Y=-500 and re-enables stencil portal for future approach.
## Called when player crosses back to exterior side of the door plane.
func _seamless_exit() -> void:
	if not _seamless_entry_door or not _active_pocket:
		return

	var cell_name: String = _active_pocket.cell_name
	Log.info("streaming", "Seamless exit from '%s'" % cell_name)

	# 1. Instant black to mask mesh restore (fire-and-forget fade-in follows)
	if _fade_rect and is_instance_valid(_fade_rect):
		_fade_rect.color.a = 1.0

	# 2. Restore camera to exterior-only (portal will re-enable COMBINED when close)
	if _camera:
		_camera.cull_mask = EXTERIOR_RENDER_LAYERS

	# 3. Restore player physics to exterior-only
	if _player_body:
		_player_body.collision_layer = EXTERIOR_PHYSICS_LAYERS
		_player_body.collision_mask = EXTERIOR_PHYSICS_LAYERS

	# 4. Restore hidden exterior building meshes and collision (invisible behind black)
	_restore_building_meshes()

	# 5. Restore sun cull mask
	if _sun and is_instance_valid(_sun):
		_sun.light_cull_mask = _sun_original_cull_mask

	# 5b. Blend environment back to exterior
	if _exterior_environment:
		_blend_environment(_exterior_environment)

	# 6. Restore interior lights to interior-only layers (were on COMBINED during seamless)
	if _active_pocket.cell_node and is_instance_valid(_active_pocket.cell_node):
		_restore_lights_to_interior(_active_pocket.cell_node)

	# 6b. Restore seamless-hidden interior doors
	_restore_seamless_interior_doors()

	# 6c. Restore interior wall meshes hidden near door
	_restore_interior_walls()

	# 7. Restore pocket to its slot offset (Y=-500) so next portal activation
	#    saves the correct _pocket_original_pos.
	if _active_pocket.cell_node and is_instance_valid(_active_pocket.cell_node):
		_active_pocket.cell_node.position = _active_pocket.get_offset()
		_active_pocket.cell_node.basis = Basis.IDENTITY

	# 8. Start eviction timer for the pocket we just left
	_active_pocket.evict_timer = EVICT_GRACE_PERIOD

	# 9. Clear seamless state
	_active_pocket = null
	_is_inside = false
	_seamless_entry_door = null
	_seamless_door_forward = Vector3.ZERO
	_seamless_prev_side = 0.0

	transition_started.emit("exterior")
	transition_completed.emit("exterior")
	Log.info("streaming", "Seamless exit complete — pocket restored to Y=-500")

	# 10. Fire-and-forget fade-in (no await — called from per-frame update)
	if _fade_rect and is_instance_valid(_fade_rect) and _fade_rect.get_tree():
		var tween: Tween = _fade_rect.get_tree().create_tween()
		tween.tween_property(_fade_rect, "color:a", 0.0, 0.2)


## Interpolate WorldEnvironment properties over ENV_BLEND_DURATION.
## Non-blocking — creates a tween and returns immediately.
func _blend_environment(target_env: Environment) -> void:
	if not _world_environment or not target_env:
		return

	var current_env: Environment = _world_environment.environment
	if not current_env:
		_world_environment.environment = target_env
		return

	# Duplicate current to avoid modifying cached exterior/interior environments
	var blend_env: Environment = current_env.duplicate()
	_world_environment.environment = blend_env

	var tree: SceneTree = get_tree()
	if not tree:
		# Fallback: instant swap
		_world_environment.environment = target_env
		return

	var tween: Tween = tree.create_tween()
	tween.set_parallel(true)

	# Ambient light
	tween.tween_property(blend_env, "ambient_light_color",
		target_env.ambient_light_color, ENV_BLEND_DURATION)
	tween.tween_property(blend_env, "ambient_light_energy",
		target_env.ambient_light_energy, ENV_BLEND_DURATION)

	# Fog
	if target_env.fog_enabled:
		blend_env.fog_enabled = true
		tween.tween_property(blend_env, "fog_light_color",
			target_env.fog_light_color, ENV_BLEND_DURATION)
		tween.tween_property(blend_env, "fog_density",
			target_env.fog_density, ENV_BLEND_DURATION)
	elif blend_env.fog_enabled:
		tween.tween_property(blend_env, "fog_density", 0.0, ENV_BLEND_DURATION)

	# Background (snap — can't tween between modes)
	tween.tween_callback(func() -> void:
		blend_env.background_mode = target_env.background_mode
		if target_env.background_mode == Environment.BG_COLOR:
			blend_env.background_color = target_env.background_color
		elif target_env.background_mode == Environment.BG_SKY and target_env.sky:
			blend_env.sky = target_env.sky
	).set_delay(ENV_BLEND_DURATION * 0.5)

	# After blend, swap to the actual target environment
	tween.chain().tween_callback(func() -> void:
		_world_environment.environment = target_env
	)

#endregion

#region Environment Building

## Build an Environment resource from interior cell AMBI data
func _build_interior_environment(cell: CellRecord) -> Environment:
	var env := Environment.new()

	if cell.has_ambient:
		# Interior ambient from AMBI record
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = cell.ambient_color
		env.ambient_light_energy = 0.8

		# Fog from AMBI
		if cell.fog_density > 0.001:
			env.fog_enabled = true
			env.fog_light_color = cell.fog_color
			env.fog_density = cell.fog_density * 0.01  # Scale MW density to Godot
	else:
		# Default interior: dim ambient, no fog
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.15, 0.13, 0.11)
		env.ambient_light_energy = 0.5

	# No sky for interiors (unless quasi-exterior)
	if cell.is_quasi_exterior():
		env.background_mode = Environment.BG_SKY
		if _exterior_environment:
			env.sky = _exterior_environment.sky
	else:
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.02, 0.02, 0.03)  # Near black

	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	return env

#endregion

#region Layer Management

## Restore interior lights to interior-only cull mask after seamless exit.
## During seamless mode, lights were left on COMBINED layers (by the portal).
func _restore_lights_to_interior(node: Node) -> void:
	if node is Light3D:
		var light := node as Light3D
		light.light_cull_mask = INTERIOR_RENDER_LAYERS
	for child in node.get_children():
		_restore_lights_to_interior(child)


func _set_layers_recursive(node: Node, layer_mask: int) -> void:
	if node is VisualInstance3D:
		node.layers = layer_mask
	# Light3D.light_cull_mask controls which geometry layers the light illuminates.
	# Must match the render layers of interior geometry or lights won't affect it.
	if node is Light3D:
		node.light_cull_mask = layer_mask
	for child in node.get_children():
		_set_layers_recursive(child, layer_mask)


func _set_physics_layers_recursive(node: Node, layer_mask: int) -> void:
	if node is CollisionObject3D:
		node.collision_layer = layer_mask
		node.collision_mask = layer_mask
	for child in node.get_children():
		_set_physics_layers_recursive(child, layer_mask)

#endregion

#region Fade Overlay

func _create_fade_overlay() -> void:
	if not is_inside_tree():
		return

	var canvas := CanvasLayer.new()
	canvas.name = "PocketFadeOverlay"
	canvas.layer = 100  # On top of everything
	add_child(canvas)

	_fade_rect = ColorRect.new()
	_fade_rect.name = "FadeRect"
	_fade_rect.color = Color(0, 0, 0, 0)
	_fade_rect.anchors_preset = Control.PRESET_FULL_RECT
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(_fade_rect)


func _fade(from_alpha: float, to_alpha: float, duration: float) -> void:
	if not _fade_rect or not is_instance_valid(_fade_rect):
		Log.warn("streaming", "[FADE] _fade_rect invalid — skipping fade (%.1f → %.1f)" % [from_alpha, to_alpha])
		return

	var tree: SceneTree = _fade_rect.get_tree()
	if not tree:
		Log.warn("streaming", "[FADE] No SceneTree — skipping fade")
		return

	var tween: Tween = tree.create_tween()
	_fade_rect.color.a = from_alpha
	tween.tween_property(_fade_rect, "color:a", to_alpha, duration)
	await tween.finished

#endregion

#region Queries

## Get the closest interactable door (within INTERACT_RADIUS), or null
func get_closest_door() -> DoorInfo:
	if _closest_door_distance_sq <= INTERACT_RADIUS_SQ:
		return _closest_door
	return null


## Get the closest preloadable door (within PRELOAD_RADIUS), or null
func get_closest_preload_door() -> DoorInfo:
	if _closest_door_distance_sq <= PRELOAD_RADIUS_SQ:
		return _closest_door
	return null


## Whether the player is currently inside an interior
func is_inside() -> bool:
	return _is_inside


## Get the active interior cell name, or empty string
func get_active_interior_name() -> String:
	if _active_pocket:
		return _active_pocket.cell_name
	return ""


## Get slot for a given cell name
func _get_slot_for_cell(cell_name: String) -> PocketSlot:
	for slot: PocketSlot in _slots:
		if slot.is_occupied and slot.cell_name == cell_name:
			return slot
	return null


## Get loaded pocket count
func get_loaded_pocket_count() -> int:
	var count := 0
	for slot: PocketSlot in _slots:
		if slot.is_occupied:
			count += 1
	return count


## Get debug info string
func get_debug_info() -> String:
	var lines: PackedStringArray = []
	lines.append("Pockets: %d/%d | Inside: %s" % [
		get_loaded_pocket_count(), MAX_POCKET_SLOTS,
		get_active_interior_name() if _is_inside else "no"
	])
	lines.append("Doors registered: %d" % _exterior_doors.size())

	for slot: PocketSlot in _slots:
		if slot.is_occupied:
			var evict_str := ""
			if slot.evict_timer > 0:
				evict_str = " (evict in %.1fs)" % slot.evict_timer
			lines.append("  [%d] '%s' (%d children)%s" % [
				slot.slot_index, slot.cell_name,
				slot.cell_node.get_child_count() if slot.cell_node else 0,
				evict_str
			])

	if _closest_door:
		lines.append("Nearest door: %s -> '%s' (%.1fm)" % [
			_closest_door.ref_id, _closest_door.target_cell_name,
			sqrt(_closest_door_distance_sq)
		])

	return "\n".join(lines)

#endregion

#region Door Hiding & Walk-Through

## Hide interior door meshes near the door opening during seamless mode.
## Called after portal deactivation restores the portal's hidden doors.
## Uses two strategies: ref_id match for known exit doors, then name-based fallback.
func _hide_seamless_interior_doors(door: DoorInfo, slot: PocketSlot) -> void:
	_seamless_hidden_doors.clear()
	if not slot.cell_node or not is_instance_valid(slot.cell_node):
		return

	# Hide ALL door meshes inside the pocket (no distance check — global_position
	# is stale after pocket repositioning within the same frame).
	# Searching the entire pocket is safe: it's one interior cell, and we only
	# match "door" names (excluding doorframe/doorstep/doorjamb).
	_hide_all_doors_in_subtree(slot.cell_node)

	if not _seamless_hidden_doors.is_empty():
		Log.info("streaming", "Hidden %d interior door meshes for seamless mode" % _seamless_hidden_doors.size())
	else:
		Log.warn("streaming", "Failed to hide any interior doors near %s" % door.world_position)


func _hide_all_doors_in_subtree(node: Node) -> void:
	if node is Node3D:
		var n3d := node as Node3D
		var name_lower: String = n3d.name.to_lower()
		if name_lower.containsn("door") and not name_lower.containsn("doorframe") \
				and not name_lower.containsn("doorstep") and not name_lower.containsn("doorjamb"):
			if n3d.visible:
				n3d.visible = false
				_seamless_hidden_doors.append(n3d)
	for child in node.get_children():
		_hide_all_doors_in_subtree(child)


## Restore interior doors hidden during seamless mode
func _restore_seamless_interior_doors() -> void:
	for node: Node3D in _seamless_hidden_doors:
		if is_instance_valid(node):
			node.visible = true
	_seamless_hidden_doors.clear()


## Create a unified double-sided door from the pocket's interior door mesh.
## Morrowind interior doors have geometry on both faces (they swing open in-game).
## We duplicate that mesh, place it at the exterior door position, and hide both
## original one-sided doors. The unified door animates with the same swing logic.
## Apply clip shader to interior wall meshes near the door to cut a view-out hole.
## Instead of hiding entire meshes (which removes whole wall sections), the clip
## shader discards fragments inside a door-shaped box — surgically punching a
## hole while keeping the rest of the wall intact.
func _hide_interior_wall_near_door(door: DoorInfo, slot: PocketSlot) -> void:
	_clipped_wall_materials.clear()
	_disabled_interior_wall_collision.clear()
	if not slot.cell_node or not is_instance_valid(slot.cell_node):
		return

	# Force transform propagation after pocket repositioning so descendant
	# global_transforms reflect the new pocket position (not stale Y=-500).
	slot.cell_node.force_update_transform()

	# After pocket repositioning, the interior geometry is physically at the
	# exterior door's world position. Use it directly as the search position.
	var search_pos: Vector3 = door.world_position

	# Find the interior exit door ref_id to skip it (don't clip the door itself)
	var skip_ref_id: StringName = &""
	for int_door: DoorInfo in slot.doors_inside:
		if int_door.is_interior_door:
			skip_ref_id = int_door.ref_id
			break
	var skip_ref_lower: String = str(skip_ref_id).to_lower()

	# Oriented clip box: thin through wall, wide across doorway, full door height.
	# Door basis: -Z = wall normal (outward), X = door width direction, Y = up.
	var esm_basis: Basis = door.get_door_basis_godot()
	var scene_root: Node = _scene_root if _scene_root else get_parent()
	var door_mesh: Node3D = DoorUtils.find_by_ref_id(scene_root, door.ref_id, search_pos, 10.0) if scene_root else null
	if not door_mesh and scene_root:
		door_mesh = DoorUtils.find_near(scene_root, search_pos, 5.0)
	var door_basis: Basis = DoorUtils.compute_door_basis(esm_basis, door_mesh, _camera, search_pos)

	# Clip box center: use door mesh AABB center if available, else door position + half height
	var clip_center: Vector3
	var clip_half_extents: Vector3
	var door_mi: MeshInstance3D = DoorUtils.get_mesh_instance(door_mesh) if door_mesh else null
	if door_mi and door_mi.mesh:
		var aabb: AABB = door_mi.mesh.get_aabb()
		clip_center = door_mi.global_transform * aabb.get_center()
		# Use AABB dimensions for extents (width, height from mesh; thin through wall)
		var sizes: Array[float] = [aabb.size.x, aabb.size.y, aabb.size.z]
		sizes.sort()
		clip_half_extents = Vector3(sizes[1] * 0.5 + 0.2, sizes[2] * 0.5 + 0.2, 0.4)
	else:
		clip_center = search_pos + Vector3(0, 1.3, 0)
		clip_half_extents = Vector3(1.0, 1.4, 0.4)
	# Inverse rotation for transforming world pos to clip-local space
	var clip_rotation_inv: Basis = door_basis.inverse()

	# Search box: axis-aligned bounding box for finding candidate meshes
	var search_box := AABB(
		Vector3(search_pos.x - 2.0, search_pos.y - 0.5, search_pos.z - 2.0),
		Vector3(4.0, 4.0, 4.0)
	)

	_apply_clip_shader_recursive(slot.cell_node, search_box,
		clip_center, clip_half_extents, clip_rotation_inv, skip_ref_lower)

	if not _clipped_wall_materials.is_empty():
		Log.info("streaming", "Applied clip shader to %d interior meshes near door (center=%s, extents=%s, %d collision)" % [
			_clipped_wall_materials.size(), clip_center, clip_half_extents,
			_disabled_interior_wall_collision.size()])
	else:
		Log.warn("streaming", "No interior meshes found near door %s at %s" % [
			door.ref_id, search_pos])


## Recursively find meshes near the door and apply clip shader material override
func _apply_clip_shader_recursive(node: Node, search_box: AABB,
		clip_center: Vector3, clip_half_extents: Vector3,
		clip_rotation_inv: Basis, skip_ref_lower: String) -> void:
	if node is Node3D:
		var n3d := node as Node3D
		# Skip the door mesh itself
		if not skip_ref_lower.is_empty() and n3d.name.to_lower().begins_with(skip_ref_lower):
			return
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.visible and mi.mesh:
			var world_aabb: AABB = mi.global_transform * mi.mesh.get_aabb()
			if world_aabb.intersects(search_box):
				_apply_clip_to_mesh(mi, clip_center, clip_half_extents, clip_rotation_inv)
	if node is StaticBody3D:
		var body := node as StaticBody3D
		if body.collision_layer != 0:
			# Disable collision near door so player can walk through
			for child in node.get_children():
				if child is CollisionShape3D:
					_disabled_interior_wall_collision[body.get_instance_id()] = {
						"layer": body.collision_layer, "mask": body.collision_mask,
					}
					body.collision_layer = 0
					body.collision_mask = 0
					break
	for child in node.get_children():
		_apply_clip_shader_recursive(child, search_box,
			clip_center, clip_half_extents, clip_rotation_inv, skip_ref_lower)


## Apply clip shader to a single mesh, preserving its visual appearance outside the clip box.
## Handles multi-surface meshes: applies per-surface clip materials instead of material_override
## when the mesh has multiple surfaces (MW buildings have wood, stone, plaster, etc.).
func _apply_clip_to_mesh(mi: MeshInstance3D, clip_center: Vector3,
		clip_half_extents: Vector3, clip_rotation_inv: Basis) -> void:
	var iid := mi.get_instance_id()
	if _clipped_wall_materials.has(iid):
		return  # Already clipped

	if not mi.mesh:
		return

	var surface_count: int = mi.mesh.get_surface_count()

	# If material_override is set, apply clip as override (replaces all surfaces uniformly)
	if mi.material_override:
		_clipped_wall_materials[iid] = {
			"mesh_instance": mi,
			"original_override": mi.material_override,
			"surface_mats": [],
		}
		var clip_mat: ShaderMaterial = _create_clip_material(
			mi.material_override, clip_center, clip_half_extents, clip_rotation_inv)
		mi.material_override = clip_mat
		return

	# Multi-surface path: create a separate clip material per surface,
	# copying each surface's original visual properties.
	var original_surface_mats: Array = []
	for surf_idx in surface_count:
		original_surface_mats.append(mi.get_surface_override_material(surf_idx))

	_clipped_wall_materials[iid] = {
		"mesh_instance": mi,
		"original_override": null,
		"surface_mats": original_surface_mats,
	}

	for surf_idx in surface_count:
		var source_mat: Material = mi.get_active_material(surf_idx)
		var clip_mat: ShaderMaterial = _create_clip_material(
			source_mat, clip_center, clip_half_extents, clip_rotation_inv)
		mi.set_surface_override_material(surf_idx, clip_mat)


## Create a clip ShaderMaterial from a source material, copying its visual properties.
func _create_clip_material(source_mat: Material, clip_center: Vector3,
		clip_half_extents: Vector3, clip_rotation_inv: Basis) -> ShaderMaterial:
	var clip_mat := ShaderMaterial.new()
	clip_mat.shader = DOOR_CLIP_SHADER
	clip_mat.set_shader_parameter("clip_center", clip_center)
	clip_mat.set_shader_parameter("clip_half_extents", clip_half_extents)
	clip_mat.set_shader_parameter("clip_rotation_inv", clip_rotation_inv)

	if source_mat is StandardMaterial3D:
		var std: StandardMaterial3D = source_mat as StandardMaterial3D
		if std.albedo_texture:
			clip_mat.set_shader_parameter("albedo_texture", std.albedo_texture)
		clip_mat.set_shader_parameter("albedo_color", std.albedo_color)
		clip_mat.set_shader_parameter("roughness", std.roughness)
		clip_mat.set_shader_parameter("metallic", std.metallic)
		if std.normal_enabled and std.normal_texture:
			clip_mat.set_shader_parameter("has_normal", true)
			clip_mat.set_shader_parameter("normal_texture", std.normal_texture)
			clip_mat.set_shader_parameter("normal_scale", std.normal_scale)

	return clip_mat


## Restore clipped interior wall materials and collision
func _restore_interior_walls() -> void:
	for iid: int in _clipped_wall_materials:
		var info: Dictionary = _clipped_wall_materials[iid]
		var mi: MeshInstance3D = info.mesh_instance
		if mi and is_instance_valid(mi):
			mi.material_override = info.original_override
			# Restore per-surface materials if we applied per-surface clips
			var surface_mats: Array = info.surface_mats
			for surf_idx in surface_mats.size():
				mi.set_surface_override_material(surf_idx, surface_mats[surf_idx])
	_clipped_wall_materials.clear()
	for iid: int in _disabled_interior_wall_collision:
		var body := instance_from_id(iid) as StaticBody3D
		if body and is_instance_valid(body):
			var info: Dictionary = _disabled_interior_wall_collision[iid]
			body.collision_layer = info.layer
			body.collision_mask = info.mask
	_disabled_interior_wall_collision.clear()


## Seamless walk-through: detect when player crosses the door plane
## Uses signed distance to a plane at the door position. When the sign flips
## from positive (exterior side) to negative (interior side), auto-enter.
func _update_walkthrough(player_pos: Vector3) -> void:
	if _is_transitioning or _is_inside:
		return

	for door: DoorInfo in _exterior_doors:
		var dist_sq := player_pos.distance_squared_to(door.world_position)
		if dist_sq > WALKTHROUGH_RADIUS_SQ:
			# Too far — clear tracking for this door
			_door_plane_sides.erase(door.ref_id)
			continue

		# Check if pocket is loaded for this door
		var slot: PocketSlot = _get_slot_for_cell(door.target_cell_name)
		if not slot or not slot.is_occupied:
			continue

		# Compute signed distance to door plane.
		# Use the portal's computed plane position/forward when available (matches
		# the visual stencil plane exactly). Falls back to ESM-based calculation.
		var door_forward: Vector3
		var plane_origin: Vector3
		if _active_portal and _active_portal.is_active and _portal_door_ref_id == door.ref_id:
			plane_origin = _active_portal.portal_plane_position
			door_forward = _active_portal.portal_plane_forward
		else:
			var esm_basis: Basis = door.get_door_basis_godot()
			var wt_scene_root: Node = _scene_root if _scene_root else get_parent()
			var wt_door_mesh: Node3D = DoorUtils.find_near(wt_scene_root, door.world_position, 5.0) if wt_scene_root else null
			door_forward = DoorUtils.get_door_forward(esm_basis, wt_door_mesh)
			plane_origin = door.world_position

		var to_player: Vector3 = player_pos - plane_origin
		var signed_dist: float = to_player.dot(door_forward)

		var prev_side: float = _door_plane_sides.get(door.ref_id, signed_dist)
		_door_plane_sides[door.ref_id] = signed_dist

		# Crossing detection: player was on exterior side and has now crossed the
		# door plane into the interior. Entry uses zero threshold (immediate),
		# exit uses SEAMLESS_PLANE_THRESHOLD hysteresis to prevent oscillation.
		if prev_side > 0.0 and signed_dist <= 0.0:
			if door.supports_seamless:
				Log.info("streaming", "Walk-through detected (seamless): %s -> %s" % [
					door.ref_id, door.target_cell_name])
				_seamless_enter(door, slot, door_forward)
			else:
				Log.info("streaming", "Walk-through detected (fade-to-black, non-seamless): %s -> %s (model=%s)" % [
					door.ref_id, door.target_cell_name, door.building_model_path])
				enter_interior(door)
			_door_plane_sides.clear()
			return


#endregion

#region Building Mesh Hiding

## Hide exterior building meshes for seamless walk-through.
## Uses data-driven approach: DoorInfo.building_ref_id (set at registration from ESM data)
## identifies the building by its STAT ref_id stored as node metadata.
## Falls back to AABB-based heuristic if metadata match fails.
func _hide_building_near_door(door: DoorInfo) -> void:
	_hidden_building_meshes.clear()
	_disabled_building_collision.clear()
	var scene_root: Node = _scene_root if _scene_root else get_parent()
	if not scene_root:
		return

	# Step 1: Find the door node to get the cell container (parent)
	var door_node: Node3D = DoorUtils.find_by_ref_id(scene_root, door.ref_id, door.world_position, 10.0)
	if not door_node:
		door_node = DoorUtils.find_near(scene_root, door.world_position, 5.0)

	var cell_container: Node = door_node.get_parent() if door_node else scene_root

	Log.info("streaming", "Building hide: door=%s, building_ref=%s, model=%s, cell_children=%d" % [
		door.ref_id, door.building_ref_id, door.building_model_path.get_file(),
		cell_container.get_child_count()])

	# Step 2: Primary path — find building by metadata ref_id match
	var building_container: Node = null
	if door.building_ref_id != &"":
		var candidate: Node = _find_node_by_ref_id_metadata(cell_container, door.building_ref_id)
		if candidate:
			# Validate: check that the building's AABB actually covers the door position.
			# This catches misidentification in dense areas (e.g., lighthouse matched instead of shack).
			var covers_door: bool = _find_descendant_mesh_covering(candidate, door.world_position) != null
			if covers_door:
				building_container = candidate
				Log.info("streaming", "Building found by metadata+AABB: '%s' (ref_id=%s)" % [
					candidate.name, door.building_ref_id])
			else:
				Log.info("streaming", "Building '%s' found by metadata but AABB doesn't cover door — trying AABB fallback" % candidate.name)
		else:
			Log.warn("streaming", "Building ref_id '%s' not found in scene tree — trying AABB fallback" % door.building_ref_id)

	# Step 3: Fallback — AABB-based heuristic (original approach)
	if not building_container:
		building_container = _find_building_container(cell_container, door.world_position, door.ref_id)
		if building_container:
			Log.info("streaming", "Building found by AABB fallback: '%s'" % building_container.name)

	if building_container:
		# Step 4: Hide all MeshInstance3D descendants and disable all StaticBody3D descendants
		_hide_container_descendants(building_container)
		var building_count: int = _hidden_building_meshes.size()

		# Step 5: Also hide other exterior objects (windows, pillars, decorations)
		# whose AABB overlaps the building's AABB. These are separate cell references
		# (siblings) that are visually part of the building.
		var building_aabb: AABB = _compute_container_world_aabb(building_container)
		if building_aabb.size.length_squared() > 0.01:
			_hide_exterior_objects_in_aabb(cell_container, building_aabb, building_container, door.ref_id)

		Log.info("streaming", "Hidden building '%s': %d building + %d attached meshes, %d collision bodies" % [
			building_container.name, building_count,
			_hidden_building_meshes.size() - building_count,
			_disabled_building_collision.size()])
	else:
		# Final fallback: geometric hiding near door
		Log.warn("streaming", "No building found for door %s (ref=%s, model=%s) — geometric fallback" % [
			door.ref_id, door.building_ref_id, door.building_model_path])
		_find_building_meshes_at_door_fallback(scene_root, door.world_position, door.ref_id)
		if not _hidden_building_meshes.is_empty():
			Log.info("streaming", "Geometric fallback: hidden %d exterior meshes near door" % _hidden_building_meshes.size())


## Find a child node whose "ref_id" metadata matches the given ref_id.
## O(n) scan of direct children — cell containers are flat.
func _find_node_by_ref_id_metadata(cell_container: Node, target_ref_id: StringName) -> Node:
	var target_lower: String = str(target_ref_id).to_lower()
	for child in cell_container.get_children():
		if not child is Node3D:
			continue
		# Primary: check metadata (set by reference_instantiator._apply_metadata)
		var child_ref_id: Variant = child.get_meta("ref_id", "")
		if str(child_ref_id).to_lower() == target_lower:
			return child
		# Secondary: check node name prefix (fallback for pooled objects or edge cases)
		if child.name.to_lower().begins_with(target_lower):
			return child
	return null


## Find the building container node among siblings of the door.
## The building is the sibling (not the door itself) that has a descendant
## MeshInstance3D whose world AABB contains the door position.
func _find_building_container(cell_container: Node, door_pos: Vector3, door_ref_id: StringName,
		skip_layers: int = INTERIOR_RENDER_LAYERS) -> Node:
	var door_ref_lower: String = str(door_ref_id).to_lower()
	var best_container: Node = null
	var best_volume: float = 0.0  # Prefer LARGEST container — building shell is always biggest

	for child in cell_container.get_children():
		if not child is Node3D:
			continue
		# Skip the door container itself
		if child.name.to_lower().begins_with(door_ref_lower):
			continue
		# Skip nodes on filtered layers (exterior skips interior, interior skips exterior)
		if skip_layers != 0 and child is VisualInstance3D and (child as VisualInstance3D).layers & skip_layers:
			continue
		# Check if any descendant mesh covers the door position
		var covering_mesh: MeshInstance3D = _find_descendant_mesh_covering(child, door_pos)
		if covering_mesh:
			var aabb: AABB = covering_mesh.mesh.get_aabb()
			var volume: float = aabb.size.x * aabb.size.y * aabb.size.z
			if volume > best_volume:
				best_volume = volume
				best_container = child
				Log.debug("streaming", "Building candidate: '%s' (volume=%.1f)" % [child.name, volume])

	return best_container


## Find a descendant MeshInstance3D whose world AABB contains the given position.
func _find_descendant_mesh_covering(node: Node, pos: Vector3) -> MeshInstance3D:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh and mi.visible:
			var world_aabb := mi.global_transform * mi.mesh.get_aabb()
			# Expand slightly for tolerance
			var check_aabb := world_aabb.grow(0.5)
			if check_aabb.has_point(pos):
				return mi
	for child in node.get_children():
		var result: MeshInstance3D = _find_descendant_mesh_covering(child, pos)
		if result:
			return result
	return null


## Hide all MeshInstance3D descendants and disable all StaticBody3D descendants
## of a building container node.
func _hide_container_descendants(container: Node) -> void:
	if container is MeshInstance3D:
		var mi := container as MeshInstance3D
		if mi.layers & INTERIOR_RENDER_LAYERS == 0 and mi.visible:  # Skip interior-layer and already-hidden meshes
			mi.visible = false
			_hidden_building_meshes.append(mi)
	if container is StaticBody3D:
		var body := container as StaticBody3D
		if body.collision_layer & EXTERIOR_PHYSICS_LAYERS:
			_disabled_building_collision[body.get_instance_id()] = {
				"layer": body.collision_layer,
				"mask": body.collision_mask,
			}
			body.collision_layer = 0
			body.collision_mask = 0
	for child in container.get_children():
		_hide_container_descendants(child)


## Compute the world-space AABB of all visible MeshInstance3D descendants in a container.
func _compute_container_world_aabb(container: Node) -> AABB:
	var meshes: Array[AABB] = []
	_collect_mesh_aabbs(container, meshes)
	if meshes.is_empty():
		return AABB()
	var result: AABB = meshes[0]
	for i in range(1, meshes.size()):
		result = result.merge(meshes[i])
	return result


func _collect_mesh_aabbs(node: Node, out: Array[AABB]) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh:
			out.append(mi.global_transform * mi.mesh.get_aabb())
	for child in node.get_children():
		_collect_mesh_aabbs(child, out)


## Hide exterior objects (windows, pillars, decorations) whose world AABB overlaps
## the building's world AABB. These are separate cell references visually attached
## to the building but not children of the building container.
## Only hides siblings whose model_path matches BUILDING_PATTERNS — prevents
## hiding unrelated nearby objects (pontoons, docks, bridges, etc.).
func _hide_exterior_objects_in_aabb(cell_container: Node, building_aabb: AABB,
		building_container: Node, _door_ref_id: StringName) -> void:
	var siblings_checked := 0
	var siblings_hidden := 0
	for child in cell_container.get_children():
		if child == building_container:
			continue
		if not child is Node3D:
			continue
		# Skip interior-layer nodes
		if child is VisualInstance3D and (child as VisualInstance3D).layers & INTERIOR_RENDER_LAYERS:
			continue
		siblings_checked += 1
		# Only hide siblings that are part of the building (windows, pillars, etc.)
		# Check model_path metadata against BUILDING_PATTERNS allow-list
		var model_path: String = str(child.get_meta("model_path", "")).to_lower()
		if model_path.is_empty():
			continue
		var is_building_part: bool = false
		for pattern: String in BUILDING_PATTERNS:
			if model_path.contains(pattern):
				is_building_part = true
				break
		if not is_building_part:
			continue
		# Check if any descendant mesh overlaps the building AABB
		if _has_mesh_in_aabb(child, building_aabb):
			_hide_container_descendants(child)
			siblings_hidden += 1
			Log.debug("streaming", "  Hidden attached object: '%s' (model=%s)" % [child.name, model_path])
	Log.info("streaming", "Extended hiding: checked %d siblings, hidden %d (building AABB=%s)" % [
		siblings_checked, siblings_hidden, building_aabb])


## Check if any descendant MeshInstance3D has a world AABB that intersects the target AABB.
func _has_mesh_in_aabb(node: Node, target_aabb: AABB) -> bool:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh and mi.visible:
			var world_aabb: AABB = mi.global_transform * mi.mesh.get_aabb()
			if target_aabb.intersects(world_aabb):
				return true
	for child in node.get_children():
		if _has_mesh_in_aabb(child, target_aabb):
			return true
	return false


## Fallback geometric hiding — used when structural approach can't find the building
func _find_building_meshes_at_door_fallback(root: Node, door_pos: Vector3, _door_ref_id: StringName) -> void:
	if root is MeshInstance3D:
		var mi := root as MeshInstance3D
		if mi.layers & INTERIOR_RENDER_LAYERS:
			return
		if mi.mesh:
			var world_aabb := mi.global_transform * mi.mesh.get_aabb()
			var door_box := AABB(
				Vector3(door_pos.x - 0.5, door_pos.y - 0.1, door_pos.z - 0.5),
				Vector3(1.0, 2.5, 1.0)
			)
			if world_aabb.grow(0.5).intersects(door_box) and mi.visible:
				mi.visible = false
				_hidden_building_meshes.append(mi)
				# Also disable collision on the mesh's parent subtree
				var parent: Node = mi.get_parent() if mi.get_parent() else mi
				_disable_collision_in_subtree(parent)
	for child in root.get_children():
		_find_building_meshes_at_door_fallback(child, door_pos, _door_ref_id)


## Disable collision bodies in a subtree
func _disable_collision_in_subtree(node: Node) -> void:
	if node is StaticBody3D:
		var body := node as StaticBody3D
		if body.collision_layer & EXTERIOR_PHYSICS_LAYERS:
			if not _disabled_building_collision.has(body.get_instance_id()):
				_disabled_building_collision[body.get_instance_id()] = {
					"layer": body.collision_layer,
					"mask": body.collision_mask,
				}
				body.collision_layer = 0
				body.collision_mask = 0
	for child in node.get_children():
		_disable_collision_in_subtree(child)


## Restore previously hidden exterior building meshes and collision
func _restore_building_meshes() -> void:
	for mi: MeshInstance3D in _hidden_building_meshes:
		if is_instance_valid(mi):
			mi.visible = true
	_hidden_building_meshes.clear()

	# Restore collision bodies
	for iid: int in _disabled_building_collision:
		var body := instance_from_id(iid) as StaticBody3D
		if body and is_instance_valid(body):
			var info: Dictionary = _disabled_building_collision[iid]
			body.collision_layer = info.layer
			body.collision_mask = info.mask
	_disabled_building_collision.clear()

#endregion

#region Portal Rendering

## Update portal state — activate, deactivate, or switch based on nearest door
func _update_portal(best_door: DoorInfo, _player_pos: Vector3) -> void:
	# Don't activate/reactivate portal during transition — the pocket is being moved
	if _is_transitioning:
		return
	if best_door:
		if _active_portal and _active_portal.is_active:
			# Check if we need to switch to a different door's portal
			if _portal_door_ref_id != best_door.ref_id:
				_active_portal.deactivate()
				_activate_portal(best_door)
			else:
				# Same door — just update the camera
				if _camera:
					_active_portal.update(_camera)
		else:
			# No active portal — activate one
			_activate_portal(best_door)
	else:
		# No door in portal range — deactivate
		if _active_portal and _active_portal.is_active:
			_active_portal.deactivate()
			_portal_door_ref_id = &""


func _activate_portal(door: DoorInfo) -> void:
	var slot: PocketSlot = _get_slot_for_cell(door.target_cell_name)
	if not slot or not slot.is_occupied:
		Log.warn("streaming", "Portal activation failed: no loaded pocket for '%s'" % door.target_cell_name)
		return

	if not _active_portal:
		_active_portal = DoorPortalScript.new()

	var scene_root: Node = _scene_root if _scene_root else get_parent()
	Log.debug("streaming", "Activating portal for '%s' (slot %d)" % [
		door.target_cell_name, slot.slot_index])
	_active_portal.activate(door, slot, _camera, scene_root)
	_portal_door_ref_id = door.ref_id

	# Exclude interior layers from sun during portal — prevents sun from lighting
	# interior geometry visible through the stencil (same as Fix 1 for seamless mode)
	if _sun and is_instance_valid(_sun) and slot.cell_record and not slot.cell_record.is_quasi_exterior():
		_sun.light_cull_mask = _sun_original_cull_mask & ~INTERIOR_RENDER_LAYERS


## Deactivate portal when entering interior (no longer looking from outside)
## keep_pocket_position: forwarded to DoorPortal.deactivate() — if true, pocket
## stays at door-aligned position for seamless transitions.
func _deactivate_portal(keep_pocket_position: bool = false) -> void:
	if _active_portal and _active_portal.is_active:
		_active_portal.deactivate(keep_pocket_position)
		_portal_door_ref_id = &""
		# Restore sun cull mask (unless seamless — _seamless_enter manages sun separately)
		if not keep_pocket_position and _sun and is_instance_valid(_sun):
			_sun.light_cull_mask = _sun_original_cull_mask

#endregion

## Count OmniLight3D nodes in a subtree (diagnostic)
func _count_lights(node: Node) -> int:
	var count := 0
	if node is OmniLight3D:
		count += 1
	for child in node.get_children():
		count += _count_lights(child)
	return count

#region Cleanup

func cleanup() -> void:
	_restore_interior_walls()
	_deactivate_portal()
	_restore_building_meshes()
	if _sun and is_instance_valid(_sun):
		_sun.light_cull_mask = _sun_original_cull_mask
	for slot: PocketSlot in _slots:
		slot.clear()
	_slots.clear()
	_exterior_doors.clear()
	_active_pocket = null
	_is_inside = false
	_seamless_entry_door = null
	_seamless_door_forward = Vector3.ZERO
	_seamless_prev_side = 0.0
	_restore_seamless_interior_doors()

	if _pocket_container and is_instance_valid(_pocket_container):
		_pocket_container.queue_free()
		_pocket_container = null

#endregion

#region Debug

## Dump all registered door pairs with positions and wall normals.
## Call from console to diagnose portal alignment issues.
func debug_dump_doors() -> void:
	Log.info("streaming", "=== DOOR PAIR DUMP ===")
	Log.info("streaming", "Exterior doors: %d" % _exterior_doors.size())

	for door: DoorInfo in _exterior_doors:
		var esm_basis: Basis = door.get_door_basis_godot()
		var scene_root: Node = _scene_root if _scene_root else get_parent()
		var door_mesh: Node3D = DoorUtils.find_door_mesh(scene_root, door.ref_id, door.world_position, 10.0) if scene_root else null
		var wall_normal: Vector3 = DoorUtils.get_door_forward(esm_basis, door_mesh)
		var teleport_godot: Vector3 = door.get_teleport_pos_godot()

		Log.info("streaming", "  EXT '%s' -> '%s'" % [door.ref_id, door.target_cell_name])
		Log.info("streaming", "    pos=%s, wall_normal=%s, teleport_dest=%s" % [
			door.world_position, wall_normal, teleport_godot])
		Log.info("streaming", "    mesh_found=%s, esm_rot=%s" % [
			door_mesh != null, door.door_rotation_mw])
		Log.info("streaming", "    building=%s (%s), seamless=%s" % [
			door.building_ref_id, door.building_model_path.get_file(), door.supports_seamless])

		# Check for matching interior exit door
		var slot: PocketSlot = _get_slot_for_cell(door.target_cell_name)
		if slot and slot.is_occupied:
			Log.info("streaming", "    Interior pocket loaded (slot %d):" % slot.slot_index)
			for int_door: DoorInfo in slot.doors_inside:
				if not int_door.target_cell_name.is_empty():
					continue  # Skip interior→interior doors
				var int_local_pos: Vector3 = int_door.world_position - slot.get_offset()
				var int_teleport: Vector3 = CS.vector_to_godot(int_door.teleport_pos_mw)
				var dist_to_ext: float = int_teleport.distance_to(door.world_position)
				Log.info("streaming", "      EXIT '%s': cell_local=%s, teleport_back=%s (dist_to_ext=%.1fm)" % [
					int_door.ref_id, int_local_pos, int_teleport, dist_to_ext])
		else:
			Log.info("streaming", "    Interior NOT loaded")

	Log.info("streaming", "=== END DOOR DUMP ===")

#endregion
