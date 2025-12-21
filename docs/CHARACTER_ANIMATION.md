# Character Animation System

This document describes the character animation and NPC system implementation in godotwind, based on OpenMW's character animation architecture.

## Overview

The character animation system handles:
- **Body part assembly** - NPCs are constructed from multiple body part meshes (head, hair, body parts)
- **Animation playback** - Loading and playing animations from .kf files
- **Animation state management** - State machine for idle/walk/run/combat transitions
- **Physics-based movement** - CharacterBody3D integration for collision and movement
- **AI behaviors** - Basic wander AI (can be extended with Beehave)

## Architecture

### Core Components

#### 1. BodyPartAssembler (`src/core/character/body_part_assembler.gd`)
Assembles NPCs from body parts, similar to OpenMW's TagPoint system.

**Features:**
- Loads base skeleton (xbase_anim, xbase_anim_female, xbase_animkna for beast races)
- Attaches body parts to specific bones (HEAD → "Head" bone, HAIR → "Head" bone, etc.)
- Supports race-specific body parts
- NPC-specific head and hair overrides

**Usage:**
```gdscript
var assembler = BodyPartAssembler.new()
assembler.model_loader = model_loader
var character_root = assembler.assemble_npc(npc_record)
```

#### 2. CharacterAnimationController (`src/core/character/character_animation_controller.gd`)
Manages animation states and transitions using Godot's AnimationTree.

**Animation States:**
- `IDLE` - Standing still
- `WALK` - Walking movement
- `RUN` - Running movement
- `JUMP` - Jumping/falling
- `SWIM_IDLE` / `SWIM_FORWARD` - Swimming
- `COMBAT_IDLE` - Combat stance
- `ATTACK` / `BLOCK` / `SPELL_CAST` - Combat actions
- `HIT` - Hit reaction
- `DEATH` - Death animation

**Features:**
- Automatic state transitions based on velocity and state
- AnimationTree with state machine for smooth blending
- Morrowind text key support (searches for animations by name)
- Combat mode toggle

**Usage:**
```gdscript
var anim_controller = CharacterAnimationController.new()
anim_controller.setup(character_root)
anim_controller.update_animation(delta, velocity, is_grounded)
anim_controller.play_attack()  # Trigger specific animations
```

#### 3. CharacterMovementController (`src/core/character/character_movement_controller.gd`)
Physics-based character controller using CharacterBody3D.

**Features:**
- Walk/run movement with configurable speeds
- Jump and gravity
- Swimming support
- Basic wander AI for NPCs
- Collision with world geometry

**Configuration:**
```gdscript
var movement = CharacterMovementController.new()
movement.walk_speed = 1.5  # m/s
movement.run_speed = 4.0   # m/s
movement.wander_enabled = true
```

#### 4. CharacterFactory (`src/core/character/character_factory.gd`)
Factory that combines all components to create complete character instances.

**Features:**
- Creates NPCs with body part assembly
- Creates creatures from single models
- Sets up animation controllers
- Configures collision shapes based on race/creature type
- Handles both animated characters and placeholders

**Usage:**
```gdscript
var factory = CharacterFactory.new()
factory.set_model_loader(model_loader)
factory.enable_wander = true

var npc = factory.create_npc(npc_record, ref_num)
var creature = factory.create_creature(creature_record, ref_num)
```

## Integration with World System

### ReferenceInstantiator
Updated to use CharacterFactory when instantiating NPCs and creatures:

```gdscript
# In _instantiate_actor():
if character_factory:
    var character = character_factory.create_npc(npc_record, ref.ref_num)
    if character:
        # Character is a CharacterBody3D with animations
        _apply_transform(character, ref, true)
        return character
```

### CellManager
Initializes and injects CharacterFactory into ReferenceInstantiator:

```gdscript
var _character_factory: CharacterFactory = CharacterFactory.new()

func _sync_instantiator_config():
    _character_factory.set_model_loader(_model_loader)
    _instantiator.character_factory = _character_factory
```

## Body Part System

### Morrowind Body Part Assembly

NPCs in Morrowind are assembled from multiple parts:

1. **Race body parts** - Base body (chest, hands, feet, legs, etc.)
2. **NPC head** - Unique head mesh for each NPC
3. **NPC hair** - Unique hair mesh
4. **Equipment** - Armor/clothing that replaces body parts

### Body Part Bone Mapping

```gdscript
HEAD → "Head" bone
HAIR → "Head" bone
NECK → "Neck" bone
CHEST → "Chest" bone
GROIN → "Groin" bone
HAND → "Left Hand" / "Right Hand" bones
FOOT → "Left Foot" / "Right Foot" bones
# ... etc
```

### Base Skeletons

- **Male humanoid**: `meshes/base_anim.nif`
- **Female humanoid**: `meshes/base_anim_female.nif`
- **Beast race** (Argonian/Khajiit): `meshes/base_animkna.nif`

## Animation System

### Animation Files (.kf)

Morrowind stores animations in separate .kf files:
- `meshes/xbase_anim.kf` - Male character animations
- `meshes/xbase_anim_female.kf` - Female character animations
- `meshes/xbase_animkna.kf` - Beast race animations
- `meshes/<creature_id>.kf` - Creature-specific animations

**KF Loading Implementation:**
The CharacterFactory automatically loads .kf animation files using NIFKFLoader:
1. Loads .kf file from BSA based on character type (gender, beast race)
2. Parses NiSequenceStreamHelper structure with text key markers
3. Extracts bone animations from NiKeyframeController data
4. Creates separate Animation resources for each text key range (Idle, Walk, Run, etc.)
5. Adds all animations to the character's AnimationPlayer

See `src/core/nif/nif_kf_loader.gd` and `src/core/character/character_factory.gd` for implementation.

### Animation Text Keys

Morrowind animations use text keys to mark animation segments:
```
Idle: Start → Idle: Stop
Walk: Loop Start → Walk: Loop Stop
Run: Loop Start → Run: Loop Stop
Attack: Start → Attack: Stop
```

The animation system searches for animations by name and plays them appropriately.

### Animation Blending

Uses Godot's AnimationTree with AnimationNodeStateMachine for smooth transitions:
- Idle ↔ Walk ↔ Run
- Combat transitions (idle → attack → idle)
- Hit reactions
- Swimming states

## OpenMW Comparison

### OpenMW Implementation

**Skeleton System:**
- Uses OGRE's TagPoint to attach body parts to bones
- Creates empty skeleton mesh as base
- Attaches body part entities to specific bones

**Animation:**
- Uses NIF keyframe controllers
- Manages animation channels (lower body, upper body, left arm)
- Text key parsing for animation states

**Body Parts:**
- Priority system for clothing/armor replacement
- Dynamic part swapping at runtime
- Equipment attachment to bones

### godotwind Implementation

**Skeleton System:**
- Uses Godot's Skeleton3D and BoneAttachment3D
- Loads base skeleton from NIF
- Attaches MeshInstance3D to bones via BoneAttachment3D

**Animation:**
- Uses AnimationPlayer + AnimationTree
- State machine for animation transitions
- Compatible with Morrowind animation naming

**Body Parts:**
- Assembly at instantiation time
- Currently no dynamic swapping (TODO)
- Uses same bone attachment mapping as OpenMW

### Key Differences

1. **Attachment Method**: OpenMW uses TagPoints, godotwind uses BoneAttachment3D
2. **Animation Blending**: OpenMW has bone groups, godotwind uses full AnimationTree
3. **Dynamic Changes**: OpenMW supports runtime part swapping, godotwind currently doesn't
4. **Physics**: godotwind uses CharacterBody3D, OpenMW uses custom physics

## TODO / Future Improvements

### High Priority
- [x] **Load .kf animation files and apply to characters** ✅ **IMPLEMENTED**
  - Uses NIFKFLoader to load xbase_anim.kf, xbase_anim_female.kf, xbase_animkna.kf
  - Extracts animations using text key markers (Idle, Walk, Run, etc.)
  - Automatically adds all animations to AnimationPlayer
- [ ] Test with actual Morrowind data in-game
- [ ] Fix any animation track path issues with bone names
- [ ] Dynamic body part swapping for equipment changes
- [ ] Equipment attachment (weapons, shields, arrows)

### Medium Priority
- [ ] Clothing/armor layering system with priority
- [ ] First-person skeleton (xbase_anim_1st.nif)
- [ ] Proper swimming state detection (water level)
- [ ] Animation bone groups for upper/lower body blending

### Low Priority
- [ ] IK (Inverse Kinematics) for foot placement
- [ ] Facial animations (blinking, talking)
- [ ] Werewolf transformation support
- [ ] Vampire visual effects

## Example Usage

```gdscript
# In your game scene:
var cell_manager = CellManager.new()
cell_manager.load_npcs = true
cell_manager.load_creatures = true

# Load a cell - NPCs and creatures will be automatically instantiated
var cell = cell_manager.load_cell("Balmora, Guild of Mages")
add_child(cell)

# NPCs will appear as animated CharacterBody3D nodes with:
# - Assembled body parts
# - Animation controllers
# - Basic wander AI
```

## References

- OpenMW npcanimation.cpp: https://github.com/OpenMW/openmw/blob/master/apps/openmw/mwrender/npcanimation.cpp
- OpenMW actoranimation.cpp: https://github.com/OpenMW/openmw/blob/master/apps/openmw/mwrender/actoranimation.cpp
- OpenMW character.cpp: https://github.com/OpenMW/openmw/blob/master/apps/openmw/mwmechanics/character.cpp
- Morrowind Animation Guidelines: https://wiki.project-tamriel.com/wiki/Animations_Guidelines
