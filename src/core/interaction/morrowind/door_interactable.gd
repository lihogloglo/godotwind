## DoorInteractable — Morrowind door adapter for the Interactable framework
##
## Wraps a Morrowind door (DOOR record) so the player can target it via
## the InteractionRaycaster and trigger open/travel via the existing
## `door_portal.gd` system in `src/core/world/`.
##
## ## Phase scope (I.7)
##
## Stub implementation:
## - `get_prompt_text()` returns "Open <door name>" or "Travel to <dest>"
## - `interact()` emits a signal that consumers (door_portal driver) can
##   listen to. Wiring the actual door_portal call is left as integration
##   work for whatever scene loads doors via this adapter.
##
## Carry-mode exclusivity: tap path is gated upstream by
## `PlayerController._emit_interact_tap()` (returns early if
## `_carry_controller.is_carrying()`). No gating needed in the adapter.
##
## ## Framework/adapter boundary
##
## Lives in `morrowind/` because the prompt format references "Open"/"Travel"
## verbs and the `door_record` payload is MW-specific. The base
## `Interactable` it extends is fully generic.
class_name DoorInteractable
extends Interactable


## Emitted when the player triggers door activation. The first argument is the
## placed-door key, not the base DOOR record id.
signal door_activated(door_instance_key: String, door_record: Variant, player: Node3D)


## ESM record_id (lowercase) of the DOOR record this adapter wraps.
@export var record_id: String = ""

## Stable placed-reference key used by InteriorPocketManager. Base record ids are
## shared by many placed doors, so gameplay activation must use this key.
@export var door_instance_key: String = ""

## Human-readable name shown in the prompt ("Open Iron Door").
@export var display_name: String = ""

## True if this door has a teleport destination (DODT data on the ref).
## Used to switch the prompt verb between "Open" and "Travel to".
@export var has_destination: bool = false

## Display name of the destination cell, if `has_destination` is true.
## Shown in the prompt as "Travel to <destination_name>".
@export var destination_name: String = ""

## Opaque payload — full DOOR record + DODT data — passed through to
## the consumer in the `door_activated` signal. Variant so this adapter
## doesn't depend on a specific DOOR record class.
@export var door_record: Variant = null


## Override: "Open <door>" or "Travel to <destination>".
func get_prompt_text() -> String:
	if has_destination and not destination_name.is_empty():
		return "Travel to %s" % destination_name
	var label := display_name if not display_name.is_empty() else record_id
	if label.is_empty():
		return "Open"
	return "Open %s" % label


## Tap path: emit the activation signal. Decoupled from door_portal.gd
## so this adapter has zero coupling to the world streaming system.
## The signal payload carries everything a portal driver needs.
func interact(player: Node3D) -> void:
	Log.info("interaction", "Door activated: %s%s" % [
		display_name if not display_name.is_empty() else record_id,
		(" → " + destination_name) if has_destination else "",
	])
	var activation_key := door_instance_key if not door_instance_key.is_empty() else record_id
	door_activated.emit(activation_key, door_record, player)
	super.interact(player)
