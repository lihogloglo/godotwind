## InteractionRaycaster — Generic player interaction ray (pure state)
##
## Sits as a child of the player camera. Casts a ray forward each physics
## frame and updates `_current_target` to whichever Interactable lies under
## the crosshair (or null). **Pure state — does NOT read input.**
##
## Phase I.0 (2026-04-07) removed the raycaster's `_unhandled_input` block.
## Input handling for the `interact` action lives entirely in
## `PlayerController`, which calls `get_current_target()` and routes the
## press to the target's `interact()` method. See
## `docs/INTERACTION_SYSTEM.md` §3.1 + §4 for the contract.
##
## ## Framework/adapter boundary
##
## THIS FILE HAS ZERO GAME-SPECIFIC IMPORTS. It knows about Interactable
## (the framework base class) and that's it. No ESM, no NPC, no book
## records. Game-specific behavior lives in the concrete Interactable
## subclasses the raycaster finds at runtime.
##
## ## Collision mask
##
## Casts against collision layer 3 ("Interactable") — see project.godot
## 3d_physics/layer_3. Interactable objects must have a CollisionObject3D
## sibling (StaticBody3D, RigidBody3D, or Area3D) on that layer for the
## raycast to hit them. Layer choice is documented in project.godot:
##   layer_1 = Environment   (ground, walls, terrain)
##   layer_2 = Player        (player collider)
##   layer_3 = Interactable  (NPCs, books, activators, pickups)
##
## ## How the raycaster finds an Interactable from a colliding Node3D
##
## When the ray hits a CollisionObject3D, we walk UP the tree looking for
## the first Node that matches the Interactable class. This allows two
## layouts:
##   (a) Interactable is the collider itself (Area3D extends Node3D,
##       Interactable is attached as a script)
##   (b) Interactable is an ancestor of the collider (collider is a child
##       CollisionShape3D + StaticBody3D, Interactable wraps them)
## Layout (b) is the normal case — attach an Interactable to the root of
## an NPC/book prefab and the child collider relays the hit.
class_name InteractionRaycaster
extends Node3D


## Current interactable under the crosshair, or null.
## Emitted when it changes so the UI can show/hide the prompt.
signal prompt_changed(interactable: Interactable, distance: float)


## Collision mask bits the raycast checks. Default = layer 3 only.
## Bit index 0 = layer 1, bit 2 = layer 3.
@export_flags_3d_physics var collision_mask: int = 1 << 2  # Interactable layer

## Max raycast length (meters). Individual Interactables may require
## tighter range via their can_interact() override.
@export var max_distance: float = 5.0

## The camera this raycaster shoots from. If null at ready, uses parent.
@export var camera: Camera3D

## Optional node whose global_position overrides the ray origin. When set,
## the ray starts at `ray_origin_node.global_position` but still points in
## `camera.global_transform.basis.z` direction. Use this in third-person
## setups to cast from the CHARACTER'S eye while aiming with the camera —
## matches the canonical third-person interaction pattern (AC / RDR2 /
## Skyrim / Dark Souls): origin at head, direction from camera yaw+pitch.
## When null, the ray starts at `camera.global_position` (first-person
## default, also matches the I3/I4/I7 test scenes).
@export var ray_origin_node: Node3D

## Debug: log every prompt change. Off in release.
@export var debug_log: bool = false

## Debug: draw the cast ray each frame.
## GREEN = active Interactable. YELLOW = layer-3 hit but no Interactable.
## RED = no hit. Visible through walls (no_depth_test). Toggle via
## `raycast_debug` console command.
@export var debug_draw: bool = false


var _current_target: Interactable = null
var _current_distance: float = 0.0
# Tracks whether we've subscribed to the current target's `tree_exiting`
# signal. We can't query a Node's connection list cheaply at every read,
# so we mirror the connection state ourselves.
var _target_exiting_connected: bool = false

# Debug-draw state — only valid / meaningful when debug_draw is true.
var _debug_ray_from: Vector3 = Vector3.ZERO
var _debug_ray_to: Vector3 = Vector3.ZERO
var _debug_physics_hit: bool = false  # true = layer-3 hit (regardless of Interactable)
var _debug_mi: MeshInstance3D = null
var _debug_mesh: ImmediateMesh = null


func _ready() -> void:
	if camera == null:
		camera = get_parent() as Camera3D
	if camera == null:
		Log.warn("interaction", "InteractionRaycaster has no camera reference — disabling")
		set_physics_process(false)
		return
	# Raycaster does NOT read input. PlayerController owns the `interact`
	# action and calls get_current_target() when it fires.
	set_process_unhandled_input(false)


func _physics_process(_delta: float) -> void:
	_update_target()
	if debug_draw:
		_refresh_debug_draw()
	elif _debug_mi != null:
		_debug_mi.visible = false


## Returns the Interactable currently under the crosshair, or null.
## PlayerController calls this when the `interact` action fires.
##
## Defensive: if the cached target was freed (or queued-for-free in the
## deferred window) between physics frames, null it out before returning.
## Without this guard, callers receive a dangling reference and crash on
## the next property access. `is_instance_valid()` alone is NOT enough —
## a node that has had `queue_free()` called but hasn't reached the
## actual delete yet still returns valid, but assignment to a typed var
## triggers "Trying to assign invalid previously freed instance".
func get_current_target() -> Interactable:
	if _is_target_stale():
		_current_target = null
		_current_distance = 0.0
	return _current_target


## Returns the distance from camera to the current target's hit point,
## or 0.0 if no target.
func get_current_distance() -> float:
	if _is_target_stale():
		_current_target = null
		_current_distance = 0.0
	return _current_distance


## Stale = freed, queued-for-deletion, or no longer in the scene tree.
## The latter catches the case where a parent's queue_free has cascaded
## to its children — the children leave the tree before they're actually
## deleted, and `is_instance_valid()` still returns true on them.
func _is_target_stale() -> bool:
	if _current_target == null:
		return false
	if not is_instance_valid(_current_target):
		return true
	if _current_target.is_queued_for_deletion():
		return true
	# Detached from the tree — about to be freed (or already in the
	# free pass). Either way, untouchable for typed assignment.
	if not _current_target.is_inside_tree():
		return true
	# Also check the parent prop root — PickupInteractable frees its
	# parent (the carryable wrapper Node3D) on a successful pickup, not
	# `self`. The wrapper is still valid for one frame after the parent
	# is queued, but it's about to be freed transitively.
	var parent := _current_target.get_parent()
	if parent != null and parent.is_queued_for_deletion():
		return true
	return false


## Proactive cache invalidation. The reactive `_is_target_stale()` checks
## are best-effort but Godot's queue_free → actual delete window has many
## edge cases. The robust fix is to subscribe to the cached target's
## `tree_exiting` signal and clear `_current_target` the moment Godot
## tells us the node is leaving the tree, BEFORE any consumer can read it.
func _connect_target_exiting(t: Interactable) -> void:
	if t == null or _target_exiting_connected:
		return
	if not t.tree_exiting.is_connected(_on_target_tree_exiting):
		t.tree_exiting.connect(_on_target_tree_exiting, CONNECT_ONE_SHOT)
	_target_exiting_connected = true


func _disconnect_target_exiting() -> void:
	if not _target_exiting_connected:
		return
	if _current_target != null and is_instance_valid(_current_target):
		if _current_target.tree_exiting.is_connected(_on_target_tree_exiting):
			_current_target.tree_exiting.disconnect(_on_target_tree_exiting)
	_target_exiting_connected = false


func _on_target_tree_exiting() -> void:
	# Cleared synchronously from the signal — no consumer can see the
	# dangling reference between this point and the next read.
	_current_target = null
	_current_distance = 0.0
	_target_exiting_connected = false
	# Notify UI listeners that the prompt should hide. Without this
	# the "Take X" prompt persists until the next physics tick re-casts
	# and emits a fresh prompt_changed(null) — feels laggy when picking
	# up an item that despawns out from under the cursor.
	prompt_changed.emit(null, 0.0)


## Cast forward and update _current_target + _current_distance.
func _update_target() -> void:
	# Pre-flight: drop a stale cached target before we compare against it.
	# A PickupInteractable can free itself (or its parent prop root) between
	# frames; if we hold the dangling reference, the
	# `new_target != _current_target` compare below touches freed memory.
	if _is_target_stale():
		_current_target = null
		_current_distance = 0.0

	var space_state := get_world_3d().direct_space_state
	# Ray origin: character eye in third-person, camera in first-person.
	# Direction always matches camera forward so yaw+pitch aim naturally.
	var from: Vector3 = camera.global_position
	if ray_origin_node != null and is_instance_valid(ray_origin_node):
		from = ray_origin_node.global_position
	var to := from + -camera.global_transform.basis.z * max_distance

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = collision_mask
	query.collide_with_areas = true
	query.collide_with_bodies = true

	var hit := space_state.intersect_ray(query)

	# Capture debug state before Interactable filtering so we can distinguish
	# "no layer-3 hit" (RED) from "hit layer-3 but no Interactable" (YELLOW).
	if debug_draw:
		_debug_ray_from = from
		_debug_physics_hit = not hit.is_empty()
		_debug_ray_to = hit.get("position", to) if _debug_physics_hit else to

	var new_target: Interactable = null
	var new_distance: float = 0.0

	if not hit.is_empty():
		var collider: Node = hit.get("collider")
		new_target = _find_interactable_ancestor(collider)
		if new_target != null:
			new_distance = from.distance_to(hit.get("position", to))
			if not new_target.can_interact(camera, new_distance):
				new_target = null
				new_distance = 0.0

	if new_target != _current_target:
		# Disconnect from the old target's tree_exiting before we lose
		# the reference. Then subscribe to the new one.
		_disconnect_target_exiting()
		_current_target = new_target
		_current_distance = new_distance
		_connect_target_exiting(_current_target)
		prompt_changed.emit(_current_target, _current_distance)
		if debug_log:
			var label: String = "(none)" if _current_target == null else _current_target.get_prompt_text()
			Log.debug("interaction", "Target → %s @ %.2fm" % [label, new_distance])
	elif new_target != null:
		_current_distance = new_distance


## ── Debug draw ────────────────────────────────────────────────────────────

## Create the ImmediateMesh line renderer lazily on first use.
## Safe to call from _physics_process — MeshInstance3D has no physics body.
func _setup_debug_draw() -> void:
	_debug_mesh = ImmediateMesh.new()
	_debug_mi = MeshInstance3D.new()
	_debug_mi.name = "RaycastDebugLine"
	_debug_mi.mesh = _debug_mesh
	_debug_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	mat.render_priority = 1
	_debug_mi.material_override = mat
	add_child(_debug_mi)


## Called each physics frame when debug_draw is true.
## Creates the mesh node on first use, then delegates to _draw_debug_ray.
func _refresh_debug_draw() -> void:
	if _debug_mi == null:
		_setup_debug_draw()
	_debug_mi.visible = true
	_draw_debug_ray()


## Rebuild the ImmediateMesh line for this frame.
## GREEN  = active Interactable under crosshair.
## YELLOW = layer-3 physics hit but no Interactable (wrong side, no script, etc.)
## RED    = no layer-3 hit at all.
func _draw_debug_ray() -> void:
	_debug_mesh.clear_surfaces()
	if camera == null or _debug_ray_from == _debug_ray_to:
		return
	var color: Color
	if _current_target != null:
		color = Color.GREEN
	elif _debug_physics_hit:
		color = Color(1.0, 0.8, 0.0)  # Yellow
	else:
		color = Color.RED
	# Convert world-space endpoints to local space of the MeshInstance3D.
	# _debug_mi is a child of the raycaster (child of camera) at identity, so
	# its local space == camera local space. to_local() handles any drift cleanly.
	var lf: Vector3 = _debug_mi.to_local(_debug_ray_from)
	var lt: Vector3 = _debug_mi.to_local(_debug_ray_to)
	_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_debug_mesh.surface_set_color(color)
	_debug_mesh.surface_add_vertex(lf)
	_debug_mesh.surface_set_color(color)
	_debug_mesh.surface_add_vertex(lt)
	_debug_mesh.surface_end()


## Walk up the scene tree from a colliding Node, looking for the first
## ancestor (or the node itself) that is an Interactable.
static func _find_interactable_ancestor(node: Node) -> Interactable:
	var cur := node
	while cur != null:
		if cur is Interactable:
			return cur as Interactable
		cur = cur.get_parent()
	return null
