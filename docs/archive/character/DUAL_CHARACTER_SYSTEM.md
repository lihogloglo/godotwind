# Dual Character System Architecture

**Status:** Planning phase (2026-02-15)
**Decision:** Abandon animation retargeting. Run two parallel character systems instead.

---

## Rationale

After 15+ sessions attempting to fix Mixamo→MW animation retargeting (root causes 1-5, CoB math, hierarchy mismatches, rest vs idle confusion), the complexity cost exceeds the benefit. The retargeting approach has fundamental issues:

1. **FBX import inconsistencies** - Pre-rotations don't match animation data
2. **Hierarchy mismatches** - Profile hierarchy ≠ actual skeleton structure
3. **Axis mapping errors** - 90° errors compound down bone chains
4. **Quality degradation** - Even "working" retargets look worse than native animations
5. **Maintenance burden** - Complex CoB math that nobody fully understands

**New approach:** Run two independent character systems that coexist in the same world.

---

## System Overview

### MW Character System (ALREADY WORKING)
- **Skeleton:** Native Morrowind skeleton from xbase_anim.nif
- **Animations:** 132 KF files (Morrowind native format)
- **Assembly:** Body part system (`morrowind_npc_assembler.gd`)
- **Use case:** Morrowind NPCs, nostalgia factor, authentic port
- **Status:** ✅ Fully functional (Phase 3B/3C/3D complete)

### Mixamo Character System (NEW)
- **Skeleton:** Native Mixamo skeleton from FBX files
- **Animations:** Mixamo FBX animations (no retargeting)
- **Assembly:** Simple model loader (FBX character + equipment)
- **Use case:** Modern characters, framework extensibility, next-gen look
- **Status:** 🔴 Not implemented

### Shared Systems
- **IK:** TwoBoneIK3D works with any skeleton via SkeletonProfileHumanoid
- **FABIK:** (Future) Full-body IK, skeleton-agnostic
- **State machines:** Animation states (idle/walk/run/combat) are logic, not skeleton-specific
- **World integration:** Both types can exist in same scene/cell
- **Rendering:** Same LOD/streaming/impostor pipeline

---

## Architecture Diagram

```
World Explorer
├── MW Character Pipeline
│   ├── CharacterFactoryV2 (exists)
│   ├── MorrowindNPCAssembler (exists)
│   ├── KF Animation Loader (exists)
│   └── MW Skeleton Profile (exists)
│
├── Mixamo Character Pipeline (NEW)
│   ├── MixamoCharacterFactory
│   ├── FBX Model Loader
│   ├── FBX Animation Loader (simplified)
│   └── Mixamo Skeleton Profile
│
└── Shared Systems
    ├── IKController (works with both)
    ├── AnimationManager (dual-mode)
    ├── StreamingManager (spawns both types)
    └── Equipment/Customization (type-specific)
```

---

## Implementation Plan

### Phase 1: Code Cleanup (Delete Retargeting)
**Goal:** Remove all failed retargeting attempts

**Files to DELETE:**
- `src/core/animation/retarget_setup.gd` (~250 lines) - RetargetModifier3D utilities
- `src/core/animation/skeleton_profile_adapter.gd` (~800+ lines) - All CoB math, rest chain computation, retarget logic
- `docs/MIXAMO_RETARGET_TRACKER.md` - Diagnostic document (archive, don't delete - keep for historical reference)

**Files to SIMPLIFY:**
- `src/core/animation/animation_loader.gd`
  - Remove `_apply_change_of_basis()` and all CoB logic
  - Remove `compute_skeleton_global_idles()`
  - Remove `extract_anim_rest_poses()`
  - Keep two simple paths: `load_kf()` and `load_fbx()` with NO cross-skeleton support
  - Each loader only works with its native skeleton type

- `src/core/animation/character_factory_v2.gd`
  - Remove retargeting code paths
  - Only support MW skeleton + MW animations
  - Remove any Mixamo-specific logic

- `src/tools/animation_integration_test.gd`
  - Remove CoB toggle, Mixamo wireframe comparison
  - Keep MW skeleton tests only
  - Remove diagnostic overlays

**Estimated cleanup:** ~1,500+ lines of dead code removed

---

### Phase 2: Mixamo Character Factory (NEW)
**Goal:** Create parallel system for Mixamo characters

**New file:** `src/core/character/mixamo_character_factory.gd`

```gdscript
# Mixamo Character Factory
# Loads Mixamo FBX models with native skeleton + animations
# NO retargeting - animations are used as-is from FBX files

class_name MixamoCharacterFactory
extends RefCounted

# Load Mixamo character from FBX
func create_character(fbx_path: String) -> Node3D:
    # 1. Load FBX scene
    # 2. Extract skeleton
    # 3. Set up AnimationPlayer/AnimationTree
    # 4. Apply SkeletonProfileHumanoid for IK
    # 5. Return character root
    pass

# Load Mixamo animation library (from FBX or GLB)
func load_animation_library(anim_path: String, skeleton: Skeleton3D) -> AnimationLibrary:
    # 1. Import FBX animations
    # 2. Verify bone names match skeleton
    # 3. Return AnimationLibrary
    pass

# Set up equipment/customization (simpler than MW body parts)
func attach_equipment(character: Node3D, equipment_data: Dictionary) -> void:
    # Mixamo uses simple attachment points, not body part system
    pass
```

**Dependencies:**
- FBX import (Godot native)
- Animation library management
- Equipment system (simpler than MW)

---

### Phase 3: Character Type System
**Goal:** Route character creation to appropriate factory

**New file:** `src/core/character/character_types.gd`

```gdscript
enum CharacterType {
    MORROWIND,  # MW skeleton + KF animations
    MIXAMO,     # Mixamo skeleton + FBX animations
}

class CharacterSpawnData:
    var type: CharacterType
    var data: Dictionary  # Type-specific spawn data

    # MW: race, body parts, equipment
    # Mixamo: FBX path, equipment, customization
```

**Update:** `src/core/world/native_streaming_manager.gd`
- Add character type detection
- Route to appropriate factory
- Handle both types in same cell

---

### Phase 4: Animation Manager Dual-Mode
**Goal:** Support both skeleton types in same animation system

**Update:** `src/core/animation/animation_manager.gd`

```gdscript
# Support multiple skeleton types
var mw_animation_cache := {}      # MW skeleton animations
var mixamo_animation_cache := {}  # Mixamo skeleton animations

func get_animation_library(skeleton_type: CharacterType, anim_name: String) -> AnimationLibrary:
    match skeleton_type:
        CharacterType.MORROWIND:
            return _get_mw_animation(anim_name)
        CharacterType.MIXAMO:
            return _get_mixamo_animation(anim_name)
```

**State machine stays skeleton-agnostic:**
- States are logic: idle, walk, run, combat, death
- Each character type has its own animation names
- Mapping layer: logical state → animation name (per type)

---

### Phase 5: Integration Test Scene
**Goal:** Show both character types coexisting

**New file:** `src/tools/dual_character_test.tscn`

```
Scene structure:
├── WorldEnvironment
├── DirectionalLight3D
├── Ground plane
├── MW Character (from CharacterFactoryV2)
│   └── Playing MW walk animation
└── Mixamo Character (from MixamoCharacterFactory)
    └── Playing Mixamo walk animation
```

**Test cases:**
1. Both characters visible simultaneously
2. Both animations playing correctly
3. IK works on both (if targets provided)
4. LOD/streaming works for both types
5. No conflicts or crashes

---

### Phase 6: Documentation Updates
**Files to update:**

1. **CLAUDE.md**
   - Remove retargeting references
   - Add dual character system overview
   - Update animation system section

2. **ANIMATION_SYSTEM.md**
   - Rewrite to describe two parallel systems
   - Remove retargeting chapter
   - Add Mixamo native chapter

3. **STATUS.md**
   - Mark retargeting as "Abandoned"
   - Add Mixamo character system status

4. **MEMORY.md**
   - Archive retargeting attempt history
   - Document dual system decision

---

## File Organization

### Current Structure (MW System)
```
src/core/character/
├── morrowind_npc_assembler.gd (keep)
├── body_part_slots.gd (keep)
├── mesh_extractor.gd (keep)
└── character_factory_v2.gd (keep, simplify)

src/core/animation/
├── animation_loader.gd (simplify - remove retargeting)
├── animation_manager.gd (update for dual-mode)
├── character_factory_v2.gd (simplify)
├── ik_controller.gd (keep - works with both)
├── retarget_setup.gd (DELETE)
└── skeleton_profile_adapter.gd (DELETE)
```

### New Structure (Dual System)
```
src/core/character/
├── character_types.gd (NEW - enums + spawn data)
├── morrowind/
│   ├── morrowind_npc_assembler.gd
│   ├── body_part_slots.gd
│   └── mesh_extractor.gd
└── mixamo/
    ├── mixamo_character_factory.gd (NEW)
    └── mixamo_equipment.gd (NEW - simpler than body parts)

src/core/animation/
├── animation_loader.gd (simplified - no retargeting)
├── animation_manager.gd (dual-mode support)
├── ik_controller.gd (shared)
└── character_factory_v2.gd (MW-only, simplified)
```

---

## Migration Checklist

- [x] **Phase 1: Cleanup** (DONE — ~3,176 lines removed)
  - [x] Archive MIXAMO_RETARGET_TRACKER.md (rename to .archive.md)
  - [x] Delete retarget_setup.gd
  - [x] Delete skeleton_profile_adapter.gd
  - [x] Simplify animation_loader.gd (remove CoB math)
  - [x] Simplify character_factory_v2.gd (MW-only)
  - [x] Clean up animation_integration_test.gd (deleted)

- [x] **Phase 2: Mixamo Factory** (DONE)
  - [x] Create character_types.gd
  - [x] Create mixamo_character_factory.gd (create_character + create_npc)
  - [x] Implement FBX character loading
  - [x] Implement FBX animation loading (no retarget)
  - [x] Create equipment system (mixamo_equipment.gd)

- [x] **Phase 3: Integration** (DONE — AnimationManager already skeleton-agnostic)
  - [x] AnimationManager works with any skeleton (no changes needed)
  - [x] MixamoCharacterFactory.create_npc() wires HumanoidAnimationSystem
  - [x] skeleton_utils.gd for MW bone remap
  - [ ] Update streaming_manager.gd for character routing (deferred)

- [x] **Phase 4: Testing** (DONE — verified 2026-02-15)
  - [x] Create dual_character_test.tscn (Mixamo player + MW NPC)
  - [x] mixamo_character_test.gd updated to full pipeline
  - [x] PlayerController extended with 3rd person camera + character model
  - [x] Mixamo character visible + animating in mixamo_character_test.tscn
  - [x] State machine plays idle (neck_stretching mapped via animation_name_overrides)
  - [x] Walk animation plays, transitions work (idle↔walk)
  - [x] Key 1-4 animation switching works
  - [x] Ground collision enabled on both test scenes
  - [x] AnimationManager fallback: Start→Walk when no Idle exists
  - [ ] Test MW character regression in world_explorer (manual)
  - [ ] Test dual_character_test.tscn end-to-end (deferred — needs ESM data or placeholder)
  - [ ] Test in world_explorer.tscn (deferred — streaming integration)

- [ ] **Phase 5: Documentation**
  - [ ] Update CLAUDE.md
  - [ ] Update ANIMATION_SYSTEM.md
  - [ ] Update STATUS.md
  - [ ] Update MEMORY.md

---

## Benefits of Dual System

### Technical
1. **Simpler code** - No complex retargeting math (CoB, rest chains, hierarchy mapping)
2. **Better quality** - Native animations always look better than retargeted
3. **Maintainable** - Two simple systems easier than one complex system
4. **Debuggable** - Clear separation makes issues easier to isolate
5. **Extensible** - Easy to add more character types later

### User Experience
1. **MW authenticity** - Original animations preserve Morrowind feel
2. **Modern characters** - Mixamo provides industry-standard modern look
3. **Framework flexibility** - Users can choose MW or modern characters
4. **Visual variety** - Both styles coexist in same world

### Project Goals
1. **Morrowind port** - MW system handles this (working)
2. **Modern framework** - Mixamo system shows next-gen potential
3. **Best of both worlds** - No compromise needed

---

## Known Limitations

1. **No animation sharing** between character types
   - MW walk animation cannot be used on Mixamo skeleton
   - Mixamo run animation cannot be used on MW skeleton
   - **Accepted trade-off** - each type has its own animation library

2. **Separate equipment systems**
   - MW uses body part assembly (complex, 17 slots)
   - Mixamo uses attachment points (simple, standard)
   - **Accepted trade-off** - cleaner than trying to unify

3. **Duplicate animation logic**
   - State machines replicated per type
   - **Mitigation** - Share state logic, only animation names differ

4. **Asset duplication**
   - Some animations exist in both KF and FBX
   - **Accepted trade-off** - disk space is cheap, developer time is not

---

## Success Criteria

### Phase 1 Complete When:
- ✅ All retargeting code deleted
- ✅ animation_loader.gd simplified
- ✅ character_factory_v2.gd MW-only
- ✅ No compiler errors
- ✅ MW character system still works (regression test)

### Phase 2 Complete When:
- ✅ Mixamo character loads from FBX
- ✅ Mixamo animations play on Mixamo skeleton
- ✅ Equipment attaches correctly
- ✅ Visual test passes (character looks correct)

### Phase 3 Complete When:
- ✅ Both character types spawn in world
- ✅ StreamingManager routes correctly
- ✅ AnimationManager handles both types
- ✅ No performance regression

### Phase 4 Complete When:
- ✅ Dual character test scene works
- ✅ Both types visible simultaneously
- ✅ IK works on both (if applicable)
- ✅ No crashes or conflicts

### Phase 5 Complete When:
- ✅ All docs updated
- ✅ MEMORY.md reflects new architecture
- ✅ CLAUDE.md accurate
- ✅ STATUS.md current

---

## Timeline Estimate

| Phase | Estimated Time | Complexity |
|-------|---------------|------------|
| Phase 1: Cleanup | 1-2 hours | Low (deletion + simplification) |
| Phase 2: Mixamo Factory | 4-6 hours | Medium (new system, FBX handling) |
| Phase 3: Integration | 2-3 hours | Medium (routing, dual-mode) |
| Phase 4: Testing | 1-2 hours | Low (validation) |
| Phase 5: Documentation | 1 hour | Low (updates) |
| **Total** | **9-14 hours** | **Medium overall** |

**Much faster** than continuing to debug retargeting (already spent 15+ sessions with no solution).

---

## Future Enhancements

1. **More character types**
   - Unreal Mannequin skeleton
   - Custom skeletons from Blender
   - Framework supports N character types

2. **Character type mixing**
   - MW character with Mixamo weapon animations (hand-authored)
   - Mixamo character with MW emote animations (hand-authored)
   - Selective sharing where it makes sense

3. **Animation blending**
   - Cross-fade between MW and Mixamo in cinematics
   - Hybrid characters (advanced users)

4. **Asset pipeline tools**
   - Batch convert MW→Mixamo (manual authoring, not retarget)
   - Animation style transfer (ML-based, future research)

---

## Lessons Learned

### What We Tried (Retargeting)
1. FBX import with pre-rotations (Root Cause 1)
2. CoB parent chain computation (Root Causes 2-4)
3. Rest vs idle pose handling (Root Cause 5)
4. Hemisphere normalization, position handling
5. Diagnostic tools, side-by-side comparison

### Why It Failed
- **Fundamental incompatibility** - MW skeleton from 2002, Mixamo from 2010s
- **FBX import black box** - Can't control Godot's importer behavior
- **Hierarchy differences** - Profile doesn't match actual skeleton
- **Compounding errors** - Small per-bone errors accumulate down chains
- **Diminishing returns** - Each fix revealed deeper issues

### What We Should Have Done
- **Start with dual system** from day one
- **Don't fight the tools** - use native formats
- **Simpler is better** - two simple systems beat one complex system

### Takeaway for Future
> "When retargeting takes 15+ sessions with no clear solution, it's a sign to try a different approach. Native animations are always better than retargeted ones."

---

## References

- MW Animation System: `docs/ANIMATION_SYSTEM.md`
- Current Status: `docs/STATUS.md`
- Retargeting Attempts: `docs/MIXAMO_RETARGET_TRACKER.md` (historical)
- Memory/History: `MEMORY.md` (Mixamo Retarget Quality Fix section)
