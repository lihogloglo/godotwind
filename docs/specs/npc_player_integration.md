# NPCs + Player Character in Main Scene — Implementation Plan

**Status:** Roast-approved (reviewed by both coder and roaster agents)
**Date:** 2026-03-13
**Estimated:** ~61 lines changed, 0 new files

---

## Goal

1. Player gets a visible Morrowind NPC body (Fargoth) when pressing P to enter player controller mode
2. NPCs spawn at their ESM-defined positions and play idle animations
3. NPCs wander randomly near their spawn points

---

## Current State

### What already works
- **NPC spawning infrastructure:** N key toggles `_show_characters` in world_explorer.gd (line 85, default OFF). Sets `cell_manager.load_npcs/load_creatures` and lazy-loads character assets on first enable (~23s)
- **NPC assembly pipeline:** `reference_instantiator.gd:316-343` creates full CharacterBody3D NPCs from cell references via `character_factory.create_npc(actor_record, ref.ref_num)`
- **Player controller:** `player_controller.gd` has `attach_character()` which reparents a character root, wires IK, creates input gatherer, switches to third person
- **Wander system:** `CharacterMovementController` already has `wander_enabled`, `wander_radius`, `wander_interval`, `_update_wander()`, AND calls `animation_system.update_from_movement(velocity, is_on_floor())` at line 129-130 to drive animation state
- **Proven test pipeline:** `tests/visual/test_character_controller.gd:87-175` — assemble -> rename bones -> load anims -> setup_character -> enable

### What's missing
1. **Player has no body** — `_setup_cameras()` (line 403) creates a bare CharacterBody3D. Pressing P gives invisible player
2. **Wander is disabled** — factory has `enable_wander = false`
3. **NPCs off by default** — `_show_characters = false`

---

## Phase 1: Player Character Body (~60 lines in world_explorer.gd)

### What to do

In `_switch_to_player_controller()` (line 595), BEFORE `player_controller.enable()`, spawn a Morrowind NPC as the player character if not already attached.

### Implementation

Add new method `_attach_player_character()` to world_explorer.gd:

```gdscript
var _player_npc_id: String = "fargoth"  # Default player character

func _attach_player_character() -> void:
    # Ensure character assets are preloaded
    if not _character_assets_preloaded:
        _character_assets_preloaded = true
        _log("Pre-loading character assets...")
        CharacterFactoryV2Script.preload_character_assets()
        _log("Character assets pre-loaded")

    # Look up NPC record
    var npc_record: NPCRecord = ESMManager.get_npc(_player_npc_id)
    if not npc_record:
        _log("Player NPC not found: %s" % _player_npc_id)
        return

    var race = ESMManager.get_race(npc_record.race_id)
    if not race:
        _log("Race not found: %s" % npc_record.race_id)
        return

    var is_female: bool = npc_record.is_female()
    var is_beast: bool = race.is_beast() if race else false

    # Assemble body parts (skeleton + meshes)
    var MorrowindNPCAssembler := preload("res://src/core/character/morrowind/morrowind_npc_assembler.gd")
    var character_root: Node3D = MorrowindNPCAssembler.assemble(npc_record, race)
    if not character_root:
        _log("Failed to assemble player NPC: %s" % _player_npc_id)
        return

    # Find and rename skeleton bones (Bip01 -> profile names)
    var SkeletonUtils := preload("res://src/core/animation/skeleton_utils.gd")
    var skeleton: Skeleton3D = _find_skeleton_in(character_root)
    if skeleton:
        var factory := CharacterFactoryV2Script.new()
        factory._ensure_bone_remap(skeleton, is_beast)
        var rename_map := SkeletonUtils.rename_bones_to_profile(skeleton)
        if not rename_map.is_empty():
            factory._update_bone_attachment_names(skeleton, rename_map)

        # Load KF animations
        factory._load_character_animations(character_root, skeleton, is_female, is_beast)

        # Add character to player controller
        player_controller.add_child(character_root)

        # Wire animation system (MoveContainer, AnimationManager, IK)
        factory.setup_character(player_controller, is_female, is_beast,
            npc_record.race_id, npc_record.record_id)

        # Wire input and camera
        player_controller._setup_input_gatherer()

    _log("Player character attached: %s" % _player_npc_id)
```

### Call site

In `_switch_to_player_controller()`, add before `player_controller.enable()`:

```gdscript
# Spawn player character if not already attached
if not player_controller.character_root:
    _attach_player_character()
```

### IMPORTANT: Do NOT use `create_npc()`

`CharacterFactoryV2.create_npc()` returns a `CharacterMovementController` (its own CharacterBody3D). The player uses `PlayerController` (different CharacterBody3D). Must use the assemble+setup pipeline from the test scene instead.

### Known issue: KF load time

First KF parse takes ~10s (`Parsed KF file 'meshes/xbase_anim.kf' in 10115 ms`). User presses P and waits ~10 seconds. Consider:
- Showing a loading indicator
- Or preloading in `_ready()` / on first N toggle (which already does `preload_character_assets()`)

---

## Phase 2: NPC Idle Animations (likely FREE — verify only)

NPCs spawned by `reference_instantiator` already go through `character_factory.create_npc()` which calls `_setup_animation_system()`. This creates a `MorrowindCharacterSystem` with `AnimationManager` that auto-starts in Idle state via `ADVANCE_MODE_AUTO`.

### Verification steps
1. Toggle NPCs on (N key)
2. Observe spawned NPCs — they should be playing idle animation
3. If not, debug: check AnimationManager state machine starts, Idle animation found in library

---

## Phase 3: NPC Wandering (1 line)

`CharacterMovementController` already has full wander built in:
- `wander_enabled: bool` (line 18)
- `wander_radius: float = 5.0` (line 19)
- `wander_interval: float = 3.0` (line 20)
- `_update_wander()` picks random points, drives velocity
- `animation_system.update_from_movement(velocity, is_on_floor())` at line 129-130 drives Idle<->Walk animation transitions

### Implementation

In world_explorer.gd where the factory is configured (around line 150), or wherever NPCs are enabled:

```gdscript
# Enable NPC wandering
_factory.enable_wander = true
```

That's it. The factory passes this to `CharacterMovementController.wander_enabled` during `create_npc()`.

### Verification
1. Toggle NPCs on (N key)
2. NPCs should wander randomly within 5m of spawn, switching between Idle and Walk animations
3. If animation doesn't switch, check that `update_from_movement()` is being called and that the velocity threshold triggers Walk state

---

## What We DON'T Do

- No pathfinding — NPCs wander in straight lines, collision handles obstacles
- No dialogue/interaction — pure visual demo
- No NPC collision avoidance — they walk through each other
- No interior NPCs — interior transition system not integrated
- No equipment rendering — body parts only, no weapons/armor
- No ESM AI packages (wander distance, idle chances) — random wander only

---

## Jump Animation Double-Bounce Fix (separate issue)

**Root cause found during review:** `is_on_floor()` flickers on landing (Jolt physics bounce), causing IdleMove -> MidairMove -> IdleMove rapid state switching. Each switch triggers animation crossfade (Fall<->Idle), producing visual double-bounce.

**Evidence:** `MidairMove` has `landing_lockout: float = 0.1` (line 10) declared but NEVER USED.

**Fix:** Add `works_longer_than(0.1)` guard before `not player.is_on_floor()` check in all ground moves:

```gdscript
# idle_move.gd, walk_move.gd, run_move.gd, crouch_move.gd
# Before:
if not player.is_on_floor() and container and container.has_move(&"midair"):
    return &"midair"

# After:
if works_longer_than(0.1) and not player.is_on_floor() and container and container.has_move(&"midair"):
    return &"midair"
```

Files affected: `idle_move.gd`, `walk_move.gd`, `run_move.gd`, `crouch_move.gd` (1 line each).

---

## File Impact Summary

| File | Change | Lines (est.) |
|------|--------|-------------|
| `world_explorer.gd` | Add `_attach_player_character()`, call in `_switch_to_player_controller()`, set `enable_wander = true` | ~61 |
| `idle_move.gd` | Landing lockout guard | 1 |
| `walk_move.gd` | Landing lockout guard | 1 |
| `run_move.gd` | Landing lockout guard | 1 |
| `crouch_move.gd` | Landing lockout guard | 1 |

Total: ~65 lines changed. No new files.
