# ESM Batch Export: Near-Zero Populate Time

## Context

ESM loading takes ~8s at startup, of which ~7s+ is `_populate_from_native()` in
`esm_manager.gd`. This GDScript method copies C# record objects into GDScript
record objects field-by-field via `native_rec.get("PropertyName")` calls.
Each `.get()` crosses the C#<->GDScript boundary with Variant marshalling.
With ~100k cell references x 12 fields + ~30k records x 5-15 fields, that's
**~1.4M boundary crossings**. The fix: batch export from C# as packed arrays,
then create GDScript objects from local data (no per-field boundary crossings).

## Estimated Impact

| Phase | Current | After | Savings |
|-------|---------|-------|---------|
| Cell + reference population | ~7s | ~0.5s | ~6.5s |
| Simple record population | ~1s | ~0ms (on-demand) | ~1s |
| Land population | ~0.3s | ~0.05s | ~0.25s |
| **Total** | **~8s** | **~0.5s** | **~7.5s** |

---

## Phase 1: Batch Cell + Reference Export (biggest win)

### C# changes — `src/native/NativeESMLoader.cs`

Add `ExportAllCellsPacked()` method. Returns a single Dictionary with flat
packed arrays for all cells and all their references:

```csharp
public Godot.Collections.Dictionary ExportAllCellsPacked()
```

**Cell data** — parallel arrays indexed by cell:
- `cell_keys: PackedStringArray` (3600 entries)
- `cell_names: PackedStringArray`
- `cell_flags: PackedInt32Array`
- `cell_grid_x: PackedInt32Array`
- `cell_grid_y: PackedInt32Array`
- `cell_region_ids: PackedStringArray`
- `cell_has_ambient: PackedByteArray` (0/1)
- `cell_ambient_colors: Godot.Collections.Array<Color>`
- `cell_sunlight_colors: Godot.Collections.Array<Color>`
- `cell_fog_colors: Godot.Collections.Array<Color>`
- `cell_fog_densities: PackedFloat32Array`
- `cell_water_heights: PackedFloat32Array`
- `cell_has_water_heights: PackedByteArray`
- `cell_map_colors: PackedInt32Array`

**Reference data** — flat arrays for ALL refs across ALL cells:
- `ref_counts: PackedInt32Array` (per-cell ref count, for slicing)
- `ref_ids: PackedStringArray`
- `ref_nums: PackedInt32Array`
- `ref_positions: PackedVector3Array`
- `ref_rotations: PackedVector3Array`
- `ref_scales: PackedFloat32Array`
- `ref_is_deleted: PackedByteArray`
- `ref_is_teleport: PackedByteArray`
- `ref_teleport_pos: PackedVector3Array`
- `ref_teleport_rot: PackedVector3Array`
- `ref_teleport_cells: PackedStringArray`

Total: ~30 array marshalling calls instead of ~1.2M individual `.get()` calls.

### Bridge changes — `src/core/native_bridge.gd`

Add:
```gdscript
func export_all_cells_packed(loader: RefCounted) -> Dictionary
```
Calls `loader.call("ExportAllCellsPacked")`.

### ESMManager changes — `src/core/esm/esm_manager.gd`

Replace the cell+reference section of `_populate_from_native()` with:

```gdscript
func _populate_cells_from_packed(data: Dictionary) -> void:
    var keys: PackedStringArray = data["cell_keys"]
    var names: PackedStringArray = data["cell_names"]
    var flags_arr: PackedInt32Array = data["cell_flags"]
    # ... etc for all cell arrays

    var ref_ids: PackedStringArray = data["ref_ids"]
    var ref_positions: PackedVector3Array = data["ref_positions"]
    # ... etc for all ref arrays
    var ref_counts: PackedInt32Array = data["ref_counts"]

    var ref_offset: int = 0
    for i in keys.size():
        var rec := CellRecord.new()
        rec.record_id = names[i]  # or keys[i] depending
        rec.name = names[i]
        rec.flags = flags_arr[i]
        rec.grid_x = grid_x_arr[i]
        rec.grid_y = grid_y_arr[i]
        # ... set all cell fields from arrays (all local, no boundary crossings)

        # Create CellReferences from flat ref arrays
        var count: int = ref_counts[i]
        for j in count:
            var idx: int = ref_offset + j
            var ref := CellReference.new()
            ref.ref_id = StringName(ref_ids[idx])
            ref.ref_num = ref_nums[idx]
            ref.position = ref_positions[idx]
            ref.rotation = ref_rotations[idx]
            ref.scale = ref_scales[idx]
            ref.is_deleted = ref_is_deleted[idx] != 0
            ref.is_teleport = ref_is_teleport[idx] != 0
            ref.teleport_pos = ref_teleport_pos[idx]
            ref.teleport_rot = ref_teleport_rot[idx]
            ref.teleport_cell = ref_teleport_cells[idx]
            rec.references.append(ref)
        ref_offset += count

        cells[keys[i]] = rec
        _all_records[keys[i]] = {"record": rec, "type": "cell"}
        if rec.is_exterior():
            exterior_cells["%d,%d" % [rec.grid_x, rec.grid_y]] = rec
```

Key: all data is already in GDScript Variants after the single batch call.
The inner loop creates GDScript objects from local arrays — no C# crossings.

---

## Phase 2: On-Demand Record Queries (zero upfront cost)

### C# changes — `src/native/NativeESMLoader.cs`

Add priority-aware lookup method:

```csharp
// Returns [type_string, model_path, record_id_original]
// Searches dicts in priority order (static > door > container > ... > light)
public Godot.Collections.Array GetRecordInfo(string recordId)

// For lights specifically — returns extra data
// Returns {radius: int, color: Color, flags: int, name: string, ...}
public Godot.Collections.Dictionary GetLightData(string recordId)

// For NPCs
public Godot.Collections.Dictionary GetNPCData(string recordId)

// For creatures
public Godot.Collections.Dictionary GetCreatureData(string recordId)
```

The priority order in `GetRecordInfo()` must match the existing
`_get_type_priority()` logic — statics/activators (100) beat lights (10)
when they share an ID (the "bc mushroom 256" problem).

### ESMManager changes — `src/core/esm/esm_manager.gd`

Modify `get_any_record()` to query C# on cache miss:

```gdscript
func get_any_record(id: String, out_type: Array = []) -> ESMRecord:
    var key := id.to_lower()

    # Check cache first (O(1))
    var entry: Dictionary = _all_records.get(key, {})
    if not entry.is_empty():
        if out_type.size() > 0:
            out_type[0] = entry.get("type", "unknown")
        return entry.get("record") as ESMRecord

    # Query C# on miss — create GDScript record on demand
    if _use_native and _native_loader:
        var info: Array = _native_loader.call("GetRecordInfo", key)
        if info != null and info.size() >= 3:
            var type_str: String = info[0]
            var model: String = info[1]
            var rec_id: String = info[2]
            var rec: ESMRecord = _create_record_on_demand(key, type_str, model, rec_id)
            if rec != null:
                _all_records[key] = {"record": rec, "type": type_str}
                if out_type.size() > 0:
                    out_type[0] = type_str
                return rec

    return null
```

The `_create_record_on_demand()` factory creates the **correct GDScript type**:

```gdscript
func _create_record_on_demand(key: String, type: String, model: String, rec_id: String) -> ESMRecord:
    match type:
        "static":
            var rec := StaticRecord.new()
            rec.record_id = rec_id
            rec.model = model
            return rec
        "door":
            var rec := DoorRecord.new()
            rec.record_id = rec_id
            rec.model = model
            return rec
        "light":
            var rec := LightRecord.new()
            rec.record_id = rec_id
            rec.model = model
            var light_data: Dictionary = _native_loader.call("GetLightData", key)
            if light_data:
                rec.radius = light_data.get("radius", 0)
                rec.color = light_data.get("color", Color.WHITE)
                rec.flags = light_data.get("flags", 0)
            return rec
        "npc":
            var rec := NPCRecord.new()
            rec.record_id = rec_id
            rec.model = model
            var npc_data: Dictionary = _native_loader.call("GetNPCData", key)
            if npc_data:
                rec.name = npc_data.get("name", "")
                rec.race_id = npc_data.get("race_id", "")
                rec.head_id = npc_data.get("head_id", "")
                rec.hair_id = npc_data.get("hair_id", "")
                rec.npc_flags = npc_data.get("npc_flags", 0)
                # ... other NPC fields as needed
            return rec
        "creature":
            var rec := CreatureRecord.new()
            rec.record_id = rec_id
            rec.model = model
            var creature_data: Dictionary = _native_loader.call("GetCreatureData", key)
            if creature_data:
                rec.name = creature_data.get("name", "")
                rec.creature_type = creature_data.get("creature_type", 0)
                rec.scale = creature_data.get("scale", 1.0)
            return rec
        # Generic fallback for activator, container, weapon, armor, etc.
        _:
            var rec := ESMRecord.new()
            rec.record_id = rec_id
            rec.set("model", model)  # duck-typed
            return rec
```

This preserves `is StaticRecord`, `is LightRecord` etc. checks downstream
because we create the correct GDScript type. Records are only created when
first queried and cached in `_all_records` for subsequent lookups.

### Remove bulk record population from `_populate_from_native()`

Delete the `_populate_simple_records()` calls for: statics, doors, activators,
containers, lights, land_textures, NPCs, creatures, races, body_parts,
weapons, armors, clothing. These are all served on demand now.

Keep: cell population (Phase 1 batch) and land population (Phase 3 batch).

### Typed dictionary lazy population (for prebaking tools)

The typed dicts (`ESMManager.statics`, `.doors`, etc.) are only accessed by
prebaking tools (model_prebaker.gd, targeted_rebake.gd). Add a lazy
population method that baking tools call before iterating:

```gdscript
var _typed_dicts_populated: bool = false

func ensure_typed_dicts_populated() -> void:
    if _typed_dicts_populated:
        return
    if _use_native and _native_loader:
        _populate_typed_dicts_from_native()
    _typed_dicts_populated = true
```

Also for `body_parts` dict which is used by `get_body_parts_for_race()` at
runtime (NPC assembly) — populate body_parts eagerly since it's small (~400
records) and used at runtime.

---

## Phase 3: Batch Land Export

### C# changes — `src/native/NativeESMLoader.cs`

Add `ExportAllLandsPacked()`:
```csharp
public Godot.Collections.Dictionary ExportAllLandsPacked()
```

Returns:
- `land_keys: PackedStringArray`
- `land_cell_x: PackedInt32Array`
- `land_cell_y: PackedInt32Array`
- `land_heights: Godot.Collections.Array<float[]>` (or one flat array + counts)
- `land_normals: Godot.Collections.Array<byte[]>`
- `land_texture_indices: Godot.Collections.Array<int[]>`
- `land_vertex_colors: Godot.Collections.Array<byte[]>`

Heights/normals/textures are already packed arrays in C# (`float[]`, `byte[]`,
`int[]`). Godot marshals these to `PackedFloat32Array`, `PackedByteArray`,
`PackedInt32Array` automatically.

### ESMManager changes

Replace land section in `_populate_from_native()` with batch consumption,
same pattern as cells (iterate local arrays, create LandRecord objects).

---

## Phase 4: Replace `is` Type Checks (optional, for robustness)

Two files use `is StaticRecord` / `is LightRecord` checks on records returned
by `get_any_record()`. With on-demand creation, these still work because we
create the correct GDScript type. However, for the generic fallback case
(types not in the match statement), records are plain ESMRecord — the `is`
checks would fail.

**Change in `object_position_index.gd:140-167`:**
Replace `is StaticRecord` etc. with type string from `get_any_record()` out_type.

**Change in `reference_instantiator.gd:_apply_metadata()`:**
Replace `is StaticRecord` etc. with type string (already available in local scope).

Both files already have the type string available — this is a small cleanup.

---

## Files Modified

| File | Change |
|------|--------|
| `src/native/NativeESMLoader.cs` | Add `ExportAllCellsPacked()`, `ExportAllLandsPacked()`, `GetRecordInfo()`, `GetLightData()`, `GetNPCData()`, `GetCreatureData()` |
| `src/core/native_bridge.gd` | Add bridge wrappers for new C# methods |
| `src/core/esm/esm_manager.gd` | Rewrite `_populate_from_native()` to use batch cell data + on-demand records |
| `src/core/world/object_position_index.gd` | Replace `is XxxRecord` with type string checks |
| `src/core/world/reference_instantiator.gd` | Replace `is XxxRecord` with type string in `_apply_metadata()` |
| `src/tools/prebaking/model_prebaker.gd` | Call `ESMManager.ensure_typed_dicts_populated()` before iteration |
| `src/tools/prebaking/targeted_rebake.gd` | Same |

## Files NOT Modified

- `cell_manager.gd` — consumes CellRecord/CellReference objects (unchanged API)
- `static_object_renderer.gd` — doesn't call ESMManager
- `native_streaming_manager.gd` — doesn't call ESMManager
- `native_impostor_renderer.gd` — uses `get_any_record()` (unchanged API)
- `ESMRecords.cs` — existing C# record classes unchanged
- `ESMCache.cs` — cache format unchanged (still caches all data)

---

## Implementation Order

1. **Phase 1** — Batch cell export (`ExportAllCellsPacked` + GDScript consumer)
2. **Phase 3** — Batch land export (same pattern, quick)
3. **Phase 2** — On-demand record queries (most code changes)
4. **Phase 4** — `is` type check cleanup (small, can do with Phase 2)

Phase 1 alone delivers ~80% of the speedup. Each phase is independently
testable.

---

## Verification

1. Launch world_explorer, check startup log for timing:
   `Loaded Morrowind.esm in X ms (C#: Y ms, populate: Z ms, actors: W ms)`
   Target: populate < 500ms (was ~7000ms)
2. Fly around — cells load normally, objects appear, lights work
3. Check LOD transitions at 150m/500m boundaries
4. Open cell browser — interior/exterior cells listed correctly
5. Check impostor rendering at distance (native_impostor_renderer)
6. Run prebaking tool — verify it can still iterate all statics
7. Object position index: check console for build time and object count
   (should match previous values)
