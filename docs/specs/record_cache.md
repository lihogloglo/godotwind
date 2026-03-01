# Spec: RecordCache (ESM Query Layer)

**Status:** Draft  
**Owner:** gemini  
**Priority:** Critical (Phase 2 Foundation)

## Context
Currently, `ESMManager` parses Morrowind ESM/ESP records into dictionaries and objects, but there is no unified, in-memory, queryable cache for these records. Subsystems (AI, UI, Combat) have to either perform slow disk lookups or re-parse data when they need to know attributes of an object (e.g., "How much does this gold coin weigh?" or "What is this NPC's level?").

## Goals
- **O(1) Access:** Retrieve any record by its Unique ID (String) instantly.
- **Type-Safe Queries:** Filter records by type (e.g., "Give me all WEAPON records").
- **Framework-First:** The cache should be generic enough to hold any "Record" type, not just Morrowind ESM data.
- **Mod-Aware:** The cache must reflect the final state after all ESP overrides are applied.

## Architecture

### 1. The Abstract Record (Framework Layer)
`src/core/systems/record.gd`
```gdscript
class_name Record
extends RefCounted

var id: StringName
var type: StringName
var raw_data: Dictionary # Original parsed fields
```

### 2. The RecordCache Interface
`src/core/systems/record_cache.gd`
```gdscript
class_name RecordCache
extends RefCounted

# Primary Storage
var _records_by_id: Dictionary[StringName, Record] = {}
var _records_by_type: Dictionary[StringName, Array[Record]] = {}

func register_record(record: Record) -> void:
    # Handles overrides automatically (last one wins)
    _records_by_id[record.id] = record
    # ... logic to update type maps ...

func get_record(id: StringName) -> Record:
    return _records_by_id.get(id)

func get_records_by_type(type: StringName) -> Array[Record]:
    return _records_by_type.get(type, [])
```

### 3. Morrowind Implementation (Mod Layer)
`src/morrowind/esm_record.gd`
```gdscript
class_name ESMRecord
extends Record

# Convenience accessors for MW fields
func get_weight() -> float: ...
func get_value() -> int: ...
```

## Proposed Implementation Plan
1. **Core Base:** Create `src/core/systems/record.gd` and `src/core/systems/record_cache.gd`.
2. **ESM Integration:** Update `ESMManager` to wrap its parsed data into `ESMRecord` objects and feed them into a global `RecordCache` instance during the loading phase.
3. **Query Engine:** Add basic filtering (e.g., `find_records(criteria: Dictionary)`).
4. **Tooling:** Add a "Record Browser" to the Debug UI to inspect cached data in real-time.

## Success Criteria
- [ ] `RecordCache` can hold 50,000+ records with negligible memory impact.
- [ ] Retrieval of a record by ID takes < 0.01ms.
- [ ] Mod overrides (ESP stacking) are correctly reflected in the cache.
