## ContainerInteractable — Morrowind container adapter
##
## Wraps a Morrowind container (CONT record) so the player can target it
## via the InteractionRaycaster and trigger an inventory-transfer UI.
##
## ## Phase scope (I.7)
##
## Stub implementation:
## - `get_prompt_text()` returns "Open <container name>"
## - `interact()` emits a signal that consumers (a future container UI)
##   listen to. The actual UI ships in a separate phase — this adapter
##   only opens the routing surface.
## - Lock/trap handling deferred — when present, refuse and surface
##   "Locked" / "Trapped" prompts via `pickup_refused`-style signal.
##
## ## Framework/adapter boundary
##
## Lives in `morrowind/` because CONT records carry MW-specific item
## lists and lock/trap data. The base `Interactable` is fully generic.
class_name ContainerInteractable
extends Interactable


## Emitted when the player triggers container activation. Consumers
## (a future container UI) listen and open the inventory transfer
## panel using the supplied record + items.
signal container_opened(record_id: String, container_record: Variant, player: Node3D)

## Emitted when the player tries to open a locked or trapped container.
## Phase 2 hook — currently never fires (lock/trap detection deferred).
signal container_refused(record_id: String, reason: String)


## ESM record_id (lowercase) of the CONT record this adapter wraps.
@export var record_id: String = ""

## Human-readable name ("Iron Crate", "Old Chest").
@export var display_name: String = ""

## Opaque container payload — full CONT record + initial inventory.
## Variant so this adapter doesn't depend on a specific CONT class.
@export var container_record: Variant = null

## True if the container is locked. Refuses interact + emits refused.
## Phase 2: integrate with lockpicking system when it lands.
@export var locked: bool = false

## Lock level (0 = unlocked, > 0 = locked with that difficulty).
@export var lock_level: int = 0


## Override: "Open <container>".
func get_prompt_text() -> String:
	var label := display_name if not display_name.is_empty() else record_id
	if label.is_empty():
		return "Open"
	if locked and lock_level > 0:
		return "Open %s (Locked)" % label
	return "Open %s" % label


## Tap path: refuse if locked, otherwise emit container_opened.
func interact(player: Node3D) -> void:
	if locked and lock_level > 0:
		Log.info("interaction", "Container refused (locked): %s level=%d" % [
			display_name, lock_level,
		])
		container_refused.emit(record_id, "Locked")
		return
	Log.info("interaction", "Container opened: %s" % display_name)
	container_opened.emit(record_id, container_record, player)
	super.interact(player)
