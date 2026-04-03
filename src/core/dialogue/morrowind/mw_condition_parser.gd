## MWConditionParser — Parses Morrowind SCVR condition strings into typed objects
##
## Morrowind-specific translation layer. SCVR is a MW ESM format detail.
##
## SCVR byte format (from OpenMW components/esm3/loadinfo):
##   Byte 0: Index ('0'-'9') — condition slot number
##   Byte 1: Type char — '1'=function, '2'=global, '3'=local, '4'=journal,
##           '5'=item, '6'=dead, '7'=NotId, '8'=NotFaction, '9'=NotClass,
##           'A'=NotRace, 'B'=NotCell, 'C'=NotLocal
##   Byte 2-3: Function ID (for type '1') or type qualifier
##   Byte 4: Comparison op ('0'=eq, '1'=ne, '2'=gt, '3'=ge, '4'=lt, '5'=le)
##   Byte 5+: Variable/ID name (for types '2'-'C')
class_name MWConditionParser
extends RefCounted


## Comparison operators
enum CompareOp {
	EQUAL = 0,
	NOT_EQUAL = 1,
	GREATER = 2,
	GREATER_OR_EQUAL = 3,
	LESS = 4,
	LESS_OR_EQUAL = 5,
}

## Condition types (matches DialogueInfoRecord.FilterType)
enum ConditionType {
	FUNCTION = 1,
	GLOBAL = 2,
	LOCAL = 3,
	JOURNAL = 4,
	ITEM = 5,
	DEAD = 6,
	NOT_ID = 7,
	NOT_FACTION = 8,
	NOT_CLASS = 9,
	NOT_RACE = 10,
	NOT_CELL = 11,
	NOT_LOCAL = 12,
}


## Parsed condition — all fields from an SCVR + INTV/FLTV pair
class ParsedCondition extends RefCounted:
	var index: int = 0                         # Slot index (0-9)
	var type: int = ConditionType.FUNCTION      # ConditionType enum
	var function_id: int = -1                   # Built-in function ID (0-73), only for type FUNCTION
	var compare_op: int = CompareOp.EQUAL       # CompareOp enum
	var variable_name: String = ""              # Variable/ID name (for non-function types)
	var int_value: int = 0                      # Comparison value (int)
	var float_value: float = 0.0               # Comparison value (float)
	var is_float: bool = false                 # Whether to use float_value vs int_value

	func get_value() -> float:
		return float_value if is_float else float(int_value)


## Parse a raw condition dictionary (from DialogueInfoRecord.conditions) into a ParsedCondition
static func parse(condition_dict: Dictionary) -> ParsedCondition:
	var result := ParsedCondition.new()
	var raw: String = condition_dict.get("raw", "")

	if raw.length() < 5:
		return result  # Malformed

	# Byte 0: index
	result.index = raw.unicode_at(0) - 0x30  # '0' = 48

	# Byte 1: type
	var type_char := raw[1]
	result.type = _char_to_type(type_char)

	# Byte 4: comparison operator
	if raw.length() > 4:
		result.compare_op = raw.unicode_at(4) - 0x30

	# Type-specific parsing
	if result.type == ConditionType.FUNCTION:
		# Bytes 2-3: two-digit function ID
		if raw.length() >= 4:
			var id_str := raw.substr(2, 2)
			result.function_id = id_str.to_int()
	else:
		# Bytes 5+: variable/ID name
		if raw.length() > 5:
			result.variable_name = raw.substr(5)

	# Values from INTV/FLTV
	if condition_dict.has("int_value"):
		result.int_value = condition_dict["int_value"]
	if condition_dict.has("float_value"):
		result.float_value = condition_dict["float_value"]
		result.is_float = true

	return result


## Parse all conditions from a DialogueInfoRecord
static func parse_all(conditions: Array[Dictionary]) -> Array[ParsedCondition]:
	var results: Array[ParsedCondition] = []
	for cond_dict in conditions:
		results.append(parse(cond_dict))
	return results


## Convert type character to ConditionType enum
static func _char_to_type(c: String) -> int:
	match c:
		"1": return ConditionType.FUNCTION
		"2": return ConditionType.GLOBAL
		"3": return ConditionType.LOCAL
		"4": return ConditionType.JOURNAL
		"5": return ConditionType.ITEM
		"6": return ConditionType.DEAD
		"7": return ConditionType.NOT_ID
		"8": return ConditionType.NOT_FACTION
		"9": return ConditionType.NOT_CLASS
		"A", "a": return ConditionType.NOT_RACE
		"B", "b": return ConditionType.NOT_CELL
		"C", "c": return ConditionType.NOT_LOCAL
		_: return ConditionType.FUNCTION  # Fallback


## Compare a value against a condition
static func compare(value: float, op: int, target: float) -> bool:
	match op:
		CompareOp.EQUAL: return is_equal_approx(value, target)
		CompareOp.NOT_EQUAL: return not is_equal_approx(value, target)
		CompareOp.GREATER: return value > target
		CompareOp.GREATER_OR_EQUAL: return value >= target
		CompareOp.LESS: return value < target
		CompareOp.LESS_OR_EQUAL: return value <= target
		_: return false
