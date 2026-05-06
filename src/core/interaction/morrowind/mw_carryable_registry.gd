## MWCarryableRegistry - Morrowind adapter for the generic CarryableRegistry
##
## Registers the Morrowind record types that produce carryable world objects.
## The framework registry stays game-agnostic; this adapter owns the MW-specific
## record-type mapping and weight/carry filters.
class_name MWCarryableRegistry
extends RefCounted

const CarryableRegistryScript := preload("res://src/core/interaction/carryable_registry.gd")

static var _callable_owner: MWCarryableRegistry = null


const CARRYABLE_TYPES: Array[StringName] = [
	&"weapon",
	&"armor",
	&"clothing",
	&"book",
	&"potion",
	&"ingredient",
	&"misc",
	&"apparatus",
	&"lockpick",
	&"probe",
	&"repair",
]


## Register all MW carryable types with the framework registry. Idempotent.
static func register_all() -> void:
	if _callable_owner == null:
		_callable_owner = MWCarryableRegistry.new()
	var weight_extractor := Callable(_callable_owner, "_extract_weight")

	for type_name in CARRYABLE_TYPES:
		CarryableRegistryScript.register_type(type_name, weight_extractor)

	CarryableRegistryScript.register_type(
		&"light",
		weight_extractor,
		Callable(_callable_owner, "_is_carryable_light"),
	)


static func release_callable_owner() -> void:
	_callable_owner = null


func _extract_weight(rec: Variant) -> float:
	if rec == null:
		return 1.0
	return float(rec.get("weight"))


func _is_carryable_light(rec: Variant) -> bool:
	if rec == null:
		return false
	if rec.has_method("can_carry"):
		return rec.can_carry()
	return false
