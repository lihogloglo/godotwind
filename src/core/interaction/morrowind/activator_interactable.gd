## ActivatorInteractable — Morrowind activator adapter
##
## Wraps a Morrowind activator (ACTI record) so the player can target it
## via the InteractionRaycaster and trigger the record's BNAM result
## script. This is the catch-all "press E on this thing" type for objects
## that don't fit Door / Container / Pickup / NPC: levers, signs, beds,
## bells, chairs, anvils, magic gems, etc.
##
## ## Phase scope (I.7)
##
## Stub implementation:
## - `get_prompt_text()` returns "Activate <name>"
## - `interact()` emits `activator_triggered` for the future BNAM script
##   interpreter to consume. Currently logs and falls through.
## - The BNAM result script interpreter (running MW script bytecode like
##   `PlaySound "drum.wav"; PlaceItemCell ...`) is a separate phase. This
##   adapter only opens the routing surface.
##
## ## Framework/adapter boundary
##
## Lives in `morrowind/` because ACTI records and BNAM scripts are
## MW-specific. The base `Interactable` is fully generic.
##
## Reference: OpenMW activator interpreter pattern (apps/openmw/mwscript/).
class_name ActivatorInteractable
extends Interactable


## Emitted when the player triggers activation. Consumers (a future
## MW script interpreter) listen and run the activator's BNAM bytecode.
signal activator_triggered(record_id: String, activator_record: Variant, script_id: String, player: Node3D)


## ESM record_id (lowercase) of the ACTI record this adapter wraps.
@export var record_id: String = ""

## Human-readable name shown in the prompt ("Activate Lever").
## Many activators have empty names — fall back to record_id.
@export var display_name: String = ""

## Opaque ACTI record payload — variant so this adapter doesn't depend
## on a specific ACTI record class.
@export var activator_record: Variant = null

## ID of the BNAM result script attached to this ACTI record. Empty for
## activators without scripts (decorative bells, signs, etc. — those
## fire the signal but the consumer ignores them).
@export var script_id: String = ""


## Override: "Activate <name>".
func get_prompt_text() -> String:
	var label := display_name if not display_name.is_empty() else record_id
	if label.is_empty():
		return "Activate"
	return "Activate %s" % label


## Tap path: emit the trigger signal. Consumer (future BNAM interpreter)
## decides what to do based on `script_id`.
func interact(player: Node3D) -> void:
	Log.info("interaction", "Activator triggered: %s%s" % [
		display_name if not display_name.is_empty() else record_id,
		(" [script: " + script_id + "]") if not script_id.is_empty() else "",
	])
	activator_triggered.emit(record_id, activator_record, script_id, player)
	super.interact(player)
