## PickupInteractable — Morrowind pickup adapter for the Interactable framework
##
## Wraps a carryable RigidBody3D produced by `CarryableBodyFactory`. Holds
## the ESM record_id + display name + cached mass so the prompt UI and
## `InventoryService` can route the tap path without re-walking the
## parent body's metadata.
##
## ## Phase scope
##
## - I.1: the body exists, the prompt shows.
## - I.2 (this phase): tap → `InventoryServiceScript.current().store_item(record_id)`
##   → despawn the wrapped RigidBody3D on `OK`, surface a prompt on
##   `INVENTORY_FULL` / `FORBIDDEN`, log on `INVALID_RECORD`.
## - I.3: hold path → `CarryController.grab(parent_body)`.
##
## ## Framework/adapter boundary
##
## Lives in `morrowind/` because the prompt format references "Take" — a
## verb specific to the MW pickup taxonomy. The base `Interactable` it
## extends + `CarryableBodyFactory` that spawns it are both fully generic.
class_name PickupInteractable
extends Interactable

const InventoryServiceScript := preload("res://src/core/interaction/inventory_service.gd")

## ESM record_id (lowercase). Set by CarryableBodyFactory at spawn time.
@export var record_id: String = ""

## Display name shown in the prompt ("Take longsword"). Set at spawn time
## from the record's `name` field; falls back to record_id if empty.
@export var display_name: String = ""

## Mass in kg, copied from the parent RigidBody3D. Used by the prompt UI
## (eventually) and by future `CarryController.grab()` weight checks.
@export var mass_kg: float = 1.0


## Override: show "Take <name>". The Interactable raycaster only displays
## a single line — the tap-vs-hold side-by-side prompt from
## INTERACTION_SYSTEM.md §13 Q2 lands when CarryController ships in I.3.
func get_prompt_text() -> String:
	var label := display_name if not display_name.is_empty() else record_id
	if label.is_empty():
		return "Take"
	return "Take %s" % label


## Tap path: route the record through `InventoryServiceScript.current()` and
## act on the result. The PickupInteractable is the WRAPPER around the
## RigidBody3D — see `carryable_body_factory.gd` — so freeing `self`
## frees the body too.
func interact(player: Node3D) -> void:
	var service := InventoryServiceScript.current()
	if service == null:
		# No service registered — boot wiring missed `set_current()`. Loud.
		Log.warn("interaction", "Pickup tap: %s (%s) — no InventoryService registered" % [
			display_name, record_id,
		])
		super.interact(player)
		return

	var result: int = service.store_item(StringName(record_id), 1)
	match result:
		InventoryServiceScript.StoreResult.OK:
			Log.info("interaction", "Pickup taken: %s (%.1f kg)" % [display_name, mass_kg])
			pickup_taken.emit(record_id)
			# Despawn the WHOLE prop node, not just `self`. The factory
			# leaves the visual `Mesh` as a sibling of this Pickup wrapper
			# under the prop's Node3D root — if we only free `self`, the
			# physics body goes but the mesh stays behind as a phantom.
			# Free the parent so the entire prop disappears.
			#
			# Deferred via the atomic helper below: per
			# `INTERACTION_SYSTEM.md` §6.2 deferred-mutation rule, the
			# RigidBody3D quiescing (freeze + clear layers) must happen
			# from a post-tick context to avoid Jolt sig-11s when the
			# space state still has lingering refs from the last tick.
			var prop_root: Node = get_parent()
			if prop_root != null and prop_root.has_meta("carryable_wrapper"):
				_despawn_prop.call_deferred(prop_root)
			else:
				# Defensive fallback — parent isn't tagged as a carryable
				# wrapper (could be a hand-built test case that bypassed
				# the factory). Free just the wrapper to avoid nuking an
				# unrelated parent. Visual mesh leak is acceptable in this
				# edge case; the spawn-path bug it would mask is loud
				# (no `carryable_wrapper` meta = factory wasn't used).
				push_warning("PickupInteractable: parent missing 'carryable_wrapper' meta — freeing self only")
				call_deferred("queue_free")
		InventoryServiceScript.StoreResult.INVENTORY_FULL:
			Log.info("interaction", "Pickup refused (inventory full): %s" % display_name)
			pickup_refused.emit(record_id, "Inventory full")
		InventoryServiceScript.StoreResult.FORBIDDEN:
			Log.info("interaction", "Pickup refused (not allowed): %s" % display_name)
			pickup_refused.emit(record_id, "You are not allowed to take this")
		InventoryServiceScript.StoreResult.INVALID_RECORD:
			Log.error("interaction", "Pickup invalid record: %s" % record_id)
			pickup_refused.emit(record_id, "")
	super.interact(player)


## Emitted on a successful pickup (StoreResult.OK), just before despawn.
signal pickup_taken(record_id: String)

## Emitted on a refused pickup (FULL/FORBIDDEN/INVALID). `reason` is the
## human-readable string the prompt UI should show, or empty for INVALID.
signal pickup_refused(record_id: String, reason: String)


## Atomic deferred despawn helper. Quiesces the contained RigidBody3D
## (freeze + clear collision layers) BEFORE freeing the prop root, so
## Jolt has a clean window to release the body. The previous "just
## queue_free the prop_root" approach hit sig-11s after rapid
## tap-take-tap-take sequences — Jolt was still holding lingering refs
## from the previous physics tick when the deferred free pass ran.
##
## Per `INTERACTION_SYSTEM.md` §6.2 deferred-mutation rule, all RB
## state writes (`freeze`, `collision_layer`, `collision_mask`) happen
## from this `call_deferred` helper, never inline from the interact()
## handler that runs in the input flow.
func _despawn_prop(prop_root: Node) -> void:
	if prop_root == null or not is_instance_valid(prop_root):
		return
	# Find the RigidBody3D inside the wrapper subtree and quiesce it.
	# The factory output structure puts it under
	#   prop_root → Pickup → RigidBody3D → [meshes + shapes]
	# but a deeper search is robust against future restructures.
	var rb := _find_rigidbody_descendant(prop_root)
	if rb != null:
		rb.freeze = true
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
		# Clear all collision masks so Jolt stops considering this body
		# for any further queries before the actual delete pass runs.
		rb.collision_layer = 0
		rb.collision_mask = 0
	prop_root.queue_free()


static func _find_rigidbody_descendant(node: Node) -> RigidBody3D:
	if node is RigidBody3D:
		return node
	for child in node.get_children():
		var found := _find_rigidbody_descendant(child)
		if found != null:
			return found
	return null
