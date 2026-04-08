## MWInventoryService — Morrowind adapter for InventoryService
##
## I.2 stub implementation. Logs every accepted item, always returns OK.
## Real inventory backing (slot count, weight cap, faction restrictions,
## stealing flag) lands when the inventory UI ships — see
## `INTERACTION_SYSTEM.md` §7 + Phase D in the dialogue/inventory roadmap.
##
## ## Framework/adapter boundary
##
## Lives in `morrowind/` because the eventual real implementation will
## know about MW item slots, weight caps from PC strength, faction
## ownership flags from ESM. The stub keeps zero MW imports for now —
## that hardening is part of the I.2+ followup, not the framework spec.
class_name MWInventoryService
extends "res://src/core/interaction/inventory_service.gd"


func store_item(record_id: StringName, qty: int = 1) -> int:
	# I.2 stub: accept everything, log it, defer real bookkeeping.
	Log.info("interaction", "Inventory: stored %d × %s" % [qty, String(record_id)])
	return StoreResult.OK
