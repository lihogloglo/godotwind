## MWCarryableRegistry — Morrowind adapter for the generic CarryableRegistry
##
## Registers the 12 Morrowind record types that produce carryable world
## objects, supplying a mass extractor (every MW carryable has a `weight`
## float field treated as kg per `INTERACTION_SYSTEM.md` §6.1) and, for
## LIGH records, a filter checking `FLAG_CAN_CARRY`.
##
## Type names match the strings exposed by `ESMManager.get_any_record()` —
## see `src/core/esm/esm_manager.gd` `_store_dispatch` for the source list.
##
## ## When this is called
##
## `register_all()` is invoked once at boot from world_explorer (or any
## main scene that streams MW data). The registry is process-global and
## idempotent — calling `register_all()` twice is harmless.
##
## ## Framework/adapter boundary
##
## This file is the ONLY place that maps MW record types to the carryable
## abstraction. The framework `CarryableRegistry` and
## `CarryableBodyFactory` know nothing about Morrowind.
class_name MWCarryableRegistry
extends RefCounted

const CarryableRegistryScript := preload("res://src/core/interaction/carryable_registry.gd")


## Type names exposed by ESMManager.get_any_record() for MW carryables.
## Static-final because adding a new entry is the whole edit you'd make
## to support a new MW record class — keep it grep-discoverable.
const CARRYABLE_TYPES: Array[StringName] = [
	&"weapon",     # WEAP
	&"armor",      # ARMO
	&"clothing",   # CLOT
	&"book",       # BOOK
	&"potion",     # ALCH
	&"ingredient", # INGR
	&"misc",       # MISC
	&"apparatus",  # APPA
	&"lockpick",   # LOCK
	&"probe",      # PROB
	&"repair",     # REPA
	# light is registered separately because it needs a filter Callable
]


## Register all MW carryable types with the framework registry. Idempotent.
static func register_all() -> void:
	var weight_extractor := func(rec: Variant) -> float:
		# Every MW carryable record (WEAP, ARMO, CLOT, BOOK, ALCH, INGR,
		# MISC, APPA, LOCK, PROB, REPA, LIGH) has a `weight: float` field.
		# Treated as kg directly per INTERACTION_SYSTEM.md §6.1.
		if rec == null:
			return 1.0
		return float(rec.get("weight"))

	for type_name in CARRYABLE_TYPES:
		CarryableRegistryScript.register_type(type_name, weight_extractor)

	# LIGH is conditional on the can-carry flag. Torches qualify; room
	# sconces nailed to walls don't.
	CarryableRegistryScript.register_type(
		&"light",
		weight_extractor,
		func(rec: Variant) -> bool:
			if rec == null:
				return false
			# LightRecord exposes can_carry() — see
			# src/core/esm/records/light_record.gd
			if rec.has_method("can_carry"):
				return rec.can_carry()
			return false,
	)
