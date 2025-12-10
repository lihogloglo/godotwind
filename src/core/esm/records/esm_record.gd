## Base class for all ESM records
class_name ESMRecord
extends RefCounted

# Common record properties
var record_id: String      # The NAME subrecord (unique identifier)
var record_flags: int      # Flags from record header
var is_deleted: bool       # DELE subrecord present

## Get the record type constant (override in subclasses)
static func get_record_type() -> int:
	return 0

## Get human-readable record type name (override in subclasses)
static func get_record_type_name() -> String:
	return "Unknown"

## Load record from ESM reader (override in subclasses)
func load(esm: ESMReader) -> void:
	record_flags = esm.get_record_flags()
	is_deleted = false
	# Subclasses implement actual loading

## Check if record is marked as persistent
func is_persistent() -> bool:
	return (record_flags & ESMDefs.FLAG_PERSISTENT) != 0

## Check if record is marked as blocked
func is_blocked() -> bool:
	return (record_flags & ESMDefs.FLAG_BLOCKED) != 0

## Check if record is marked as ignored
func is_ignored() -> bool:
	return (record_flags & ESMDefs.FLAG_IGNORED) != 0

func _to_string() -> String:
	return "%s('%s')" % [get_record_type_name(), record_id]
