## InventoryService — Generic abstract inventory store
##
## Framework class. The interaction system routes pickup taps through
## `current().store_item()`; concrete subclasses (e.g.
## `morrowind/mw_inventory_service.gd`) provide the actual inventory
## backing. The base class is process-globally addressable via
## `set_current()` / `current()` so adapters and tests can swap
## implementations without modifying every call site.
##
## ## Framework/adapter boundary
##
## ZERO game-specific imports. The `record_id` is a `StringName` opaque
## key — concrete services interpret it however they like (MW ESM ID,
## generic UUID, item GUID).
##
## ## Result enum
##
## Defined per `INTERACTION_SYSTEM.md` §7. The "world body action" column
## from the spec lives in `pickup_interactable.gd` (the call site decides
## whether to despawn or surface a prompt based on this enum). The service
## itself never touches scene-tree state — it only reports.
class_name InventoryService
extends RefCounted


## Per `INTERACTION_SYSTEM.md` §7. Caller maps these to world-body actions:
##   - OK              → despawn (queue_free deferred)
##   - INVENTORY_FULL  → stay in world, prompt "Inventory full"
##   - FORBIDDEN       → stay in world, prompt "Not allowed"
##   - INVALID_RECORD  → stay in world, log error
enum StoreResult {
	OK,
	INVENTORY_FULL,
	FORBIDDEN,
	INVALID_RECORD,
}


static var _current: InventoryService = null


## Set the active service. Idempotent — replaces any previous current.
static func set_current(service: InventoryService) -> void:
	_current = service


## Get the active service, or null if none has been registered. Call
## sites should be defensive: a missing service is a setup bug, not a
## runtime expectation.
static func current() -> InventoryService:
	return _current


## Store an item in the inventory. Override in subclasses.
## Returns one of the `StoreResult` enum values. Base implementation
## refuses everything as INVALID_RECORD so a missing override fails loud.
func store_item(_record_id: StringName, _qty: int = 1) -> StoreResult:
	push_warning("InventoryService base store_item() called — adapter not registered?")
	return StoreResult.INVALID_RECORD
