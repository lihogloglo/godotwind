## CarryableRegistry — Generic registry of "what record types are carryable"
##
## Framework class. Game-specific adapters call `register_type()` at boot to
## declare which type names produce physics-carryable world objects, and
## supply a Callable that extracts the mass (kg) from a base record. The
## reference instantiator queries this registry — it has no knowledge of
## any specific game's record schema.
##
## ## Framework/adapter boundary
##
## ZERO game-specific imports. No ESMManager, no MW record types. The
## registered Callables are the only place that touches concrete record
## fields, and those Callables are owned by the adapter (e.g.
## `src/core/interaction/morrowind/mw_carryable_registry.gd`).
##
## ## Filter callable
##
## Some types are carryable conditionally — Morrowind LIGH records carry a
## `FLAG_CAN_CARRY` bit and only ~half are grabbable (torches yes, room
## sconces no). The optional `filter` Callable runs against the record and
## returns false to suppress the carryable spawn for that instance. Returns
## true (or is unset) to allow.
##
## ## Lifetime
##
## Static state — the registry is process-global. `clear()` exists for tests.
## `register_type()` is idempotent: re-registering the same type_name
## overwrites the previous extractor.
##
## ## Usage
##
## ```gdscript
## # In an adapter at boot:
## CarryableRegistry.register_type(
##     &"weapon",
##     func(rec): return rec.weight,
## )
## CarryableRegistry.register_type(
##     &"light",
##     func(rec): return rec.weight,
##     func(rec): return rec.can_carry(),
## )
##
## # In the framework instantiator:
## if CarryableRegistry.is_carryable(type_name, record):
##     var mass := CarryableRegistry.get_mass(type_name, record)
##     CarryableBodyFactory.convert_static_to_rigid(instance, mass, record_id)
## ```
class_name CarryableRegistry
extends RefCounted


## Per-type entry: mass extractor + optional instance filter.
class Entry:
	var mass_extractor: Callable
	var filter: Callable  # optional — empty Callable means "always allow"

	func _init(p_mass: Callable, p_filter: Callable = Callable()) -> void:
		mass_extractor = p_mass
		filter = p_filter


static var _entries: Dictionary = {}  # StringName → Entry


## Register a carryable type. `type_name` is the generic record-type string
## the framework uses (e.g. &"weapon", &"book"). `mass_extractor` is a
## `func(record: Variant) -> float` returning kg. `filter` is an optional
## `func(record: Variant) -> bool` for conditional carryables (returns true
## to allow). Re-registering the same type overwrites.
static func register_type(
	type_name: StringName,
	mass_extractor: Callable,
	filter: Callable = Callable(),
) -> void:
	assert(mass_extractor.is_valid(), "CarryableRegistry: mass_extractor must be valid")
	_entries[type_name] = Entry.new(mass_extractor, filter)


## Is the given record carryable? Returns false if the type isn't registered
## or if the type's filter Callable rejects this specific record.
static func is_carryable(type_name: StringName, record: Variant) -> bool:
	var entry: Entry = _entries.get(type_name)
	if entry == null:
		return false
	if entry.filter.is_valid():
		return bool(entry.filter.call(record))
	return true


## Get the mass (kg) of a carryable record. Caller must have already
## confirmed `is_carryable()` returns true. Returns 0.0 if the type
## isn't registered (defensive — shouldn't happen in practice).
static func get_mass(type_name: StringName, record: Variant) -> float:
	var entry: Entry = _entries.get(type_name)
	if entry == null:
		return 0.0
	return float(entry.mass_extractor.call(record))


## Total number of registered types. Diagnostic helper.
static func type_count() -> int:
	return _entries.size()


## Clear all registrations. Test-only.
static func clear() -> void:
	_entries.clear()
