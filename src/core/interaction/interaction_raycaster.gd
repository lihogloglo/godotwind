## InteractionRaycaster — Generic player interaction ray
##
## Sits as a child of the player camera. Casts a ray forward each frame,
## checks for an Interactable at the hit point, and calls interact() when
## the player presses the "interact" action.
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
##
## ## Input
##
## Uses the "interact" action from InputMap — bind a key in project.godot
## or at runtime. If the action is not defined, logs a warning once.
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

## InputMap action name to trigger interact().
@export var interact_action: String = "interact"

## The camera this raycaster shoots from. If null at ready, uses parent.
@export var camera: Camera3D

## Debug: log every prompt change. Off in release.
@export var debug_log: bool = false


var _current_target: Interactable = null
var _current_distance: float = 0.0
var _warned_missing_action: bool = false


func _ready() -> void:
	if camera == null:
		camera = get_parent() as Camera3D
	if camera == null:
		Log.warn("interaction", "InteractionRaycaster has no camera reference — disabling")
		set_physics_process(false)
		set_process_unhandled_input(false)
		return
	if not InputMap.has_action(interact_action):
		Log.warn("interaction", "InputMap action '%s' not defined — bind a key to enable interaction" % interact_action)
		_warned_missing_action = true


func _physics_process(_delta: float) -> void:
	_update_target()


func _unhandled_input(event: InputEvent) -> void:
	if _warned_missing_action:
		return
	if _current_target == null:
		return
	if not event.is_action_pressed(interact_action):
		return
	if not _current_target.can_interact(camera, _current_distance):
		return
	var player_node := camera.get_parent() as Node3D
	if player_node == null:
		player_node = camera
	_current_target.interact(player_node)
	get_viewport().set_input_as_handled()


## Returns the Interactable currently under the crosshair, or null.
func get_current_target() -> Interactable:
	return _current_target


## Cast forward and update _current_target + _current_distance.
func _update_target() -> void:
	var space_state := get_world_3d().direct_space_state
	var from := camera.global_position
	var to := from + -camera.global_transform.basis.z * max_distance

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = collision_mask
	query.collide_with_areas = true
	query.collide_with_bodies = true

	var hit := space_state.intersect_ray(query)
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
		_current_target = new_target
		_current_distance = new_distance
		prompt_changed.emit(_current_target, _current_distance)
		if debug_log:
			var label: String = "(none)" if _current_target == null else _current_target.get_prompt_text()
			Log.debug("interaction", "Target → %s @ %.2fm" % [label, new_distance])
	elif new_target != null:
		_current_distance = new_distance


## Walk up the scene tree from a colliding Node, looking for the first
## ancestor (or the node itself) that is an Interactable.
static func _find_interactable_ancestor(node: Node) -> Interactable:
	var cur := node
	while cur != null:
		if cur is Interactable:
			return cur as Interactable
		cur = cur.get_parent()
	return null
