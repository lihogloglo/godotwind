# Gameplay Systems

## Overview

Gameplay systems cover player interaction, RPG mechanics, AI, dialogue, quests, inventory, combat, and magic. While the world streaming and rendering are production-ready, most gameplay systems are **prepared but not yet implemented**.

---

## Status Audit

### ✅ Completed
- ESM record parsing (all gameplay data available)
- Plugin installation (Dialogue Manager, Questify, GLoot, Beehave, GOAP)
- NPC/Creature body part parsing
- Item stat parsing (weapons, armor, potions, etc.)
- Spell/enchantment data parsing
- Dialogue/quest data parsing

### ⚠️ In Progress
- Dialogue system (30% - records parsed, UI not connected)
- NPC body assembly (placeholder models used)

### ❌ Not Started
- Player controller (using simple fly camera)
- Character creation
- Stat system (attributes, skills)
- Combat system (melee, ranged, magic)
- Magic system (spells, enchantments)
- AI system (NPC behavior, schedules)
- Quest system (journal, tracking)
- Inventory system (equipment, containers)
- Dialogue UI (conversation interface)
- Persuasion mini-game
- Stealth system
- Crime/reputation system
- Factions
- Alchemy
- Enchanting

---

## Architecture

### Gameplay System Hierarchy

```
Player
├─ Stats (attributes, skills, health, magicka, fatigue)
├─ Inventory (equipment, items)
├─ Spellbook (known spells)
├─ Journal (quests, topics)
└─ Controller (movement, input)

NPCs
├─ Stats
├─ Inventory
├─ AI (Beehave behavior trees)
├─ Schedule (GOAP goals)
├─ Dialogue (Dialogue Manager)
└─ Body Assembly (body parts → skeleton)

World Interaction
├─ Activators (doors, levers, etc.)
├─ Containers (chests, barrels)
├─ Items (loot, quest items)
└─ Triggers (scripts)

Systems
├─ Combat (melee, ranged, magic)
├─ Magic (spells, enchantments)
├─ Alchemy (potion crafting)
├─ Enchanting (item enchanting)
├─ Crime (theft, murder, trespassing)
└─ Reputation (factions, disposition)
```

---

## Player Controller (❌ Not Started - 0%)

### Current State
Simple fly camera for testing:

```gdscript
# src/tools/streaming_demo.gd
var camera_speed := 10.0

func _process(delta):
    var input := Vector3.ZERO

    if Input.is_action_pressed("move_forward"):
        input.z -= 1
    if Input.is_action_pressed("move_back"):
        input.z += 1
    if Input.is_action_pressed("move_left"):
        input.x -= 1
    if Input.is_action_pressed("move_right"):
        input.x += 1

    camera.translate(input.normalized() * camera_speed * delta)
```

### Planned Implementation

```gdscript
# src/core/player/player_controller.gd
extends CharacterBody3D

var move_speed := 5.0
var sprint_speed := 10.0
var jump_velocity := 5.0

@onready var camera: Camera3D = $Camera3D
@onready var stats: PlayerStats = $Stats

func _physics_process(delta):
    # Gravity
    if not is_on_floor():
        velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * delta

    # Jump
    if Input.is_action_just_pressed("jump") and is_on_floor():
        velocity.y = jump_velocity

    # Movement
    var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
    var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

    var speed := sprint_speed if Input.is_action_pressed("sprint") else move_speed
    speed *= stats.get_speed_multiplier()  # Encumbrance, buffs, etc.

    velocity.x = direction.x * speed
    velocity.z = direction.z * speed

    move_and_slide()

    # Camera rotation
    if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
        var mouse_delta := Input.get_last_mouse_velocity()
        camera.rotate_y(-mouse_delta.x * 0.001)
        camera.rotate_x(-mouse_delta.y * 0.001)
        camera.rotation.x = clamp(camera.rotation.x, -PI/2, PI/2)
```

### Tasks
- [ ] CharacterBody3D setup
- [ ] Movement (walk, run, jump, sneak)
- [ ] Camera control (1st/3rd person)
- [ ] Input mapping
- [ ] Collision detection
- [ ] Swimming
- [ ] Flying (levitation)

---

## Character Creation (❌ Not Started - 0%)

### Morrowind Character Creation
1. **Race selection** (10 races from ESM)
2. **Class selection** (21 classes) or custom class
3. **Birthsign selection** (13 birthsigns)
4. **Attribute distribution** (starts based on race)
5. **Starting spells** (based on race/class)

### Planned Implementation

```gdscript
# src/core/player/character_creator.gd
class_name CharacterCreator

func create_character(config: Dictionary) -> Player:
    var player := Player.new()

    # Race
    var race: RaceRecord = ESMManager.races[config["race"]]
    player.stats.apply_race_bonuses(race)

    # Class
    var char_class: ClassRecord = ESMManager.classes[config["class"]]
    player.stats.set_major_skills(char_class.major_skills)
    player.stats.set_minor_skills(char_class.minor_skills)

    # Birthsign
    var birthsign: BirthsignRecord = ESMManager.birthsigns[config["birthsign"]]
    player.stats.apply_birthsign(birthsign)

    # Starting gear
    for item in char_class.starting_items:
        player.inventory.add_item(item)

    # Starting spells
    for spell in race.starting_spells:
        player.spellbook.add_spell(spell)

    return player
```

### Tasks
- [ ] Race selection UI
- [ ] Class selection UI (+ custom class builder)
- [ ] Birthsign selection UI
- [ ] Attribute preview
- [ ] Starting equipment
- [ ] Name input

---

## Stats System (❌ Not Started - 0%)

### Morrowind Stats
- **Attributes (8):** Strength, Intelligence, Willpower, Agility, Speed, Endurance, Personality, Luck
- **Skills (27):** Combat, Magic, Stealth categories
- **Derived Stats:** Health, Magicka, Fatigue, Encumbrance

### Planned Implementation

```gdscript
# src/core/player/player_stats.gd
class_name PlayerStats

# Attributes
var strength: int = 40
var intelligence: int = 40
var willpower: int = 40
var agility: int = 40
var speed: int = 40
var endurance: int = 40
var personality: int = 40
var luck: int = 40

# Skills (27 total)
var block: int = 5
var armorer: int = 5
var medium_armor: int = 5
var heavy_armor: int = 5
var blunt_weapon: int = 5
var long_blade: int = 5
# ... (21 more skills)

# Derived stats
var health: float = 100.0
var magicka: float = 100.0
var fatigue: float = 100.0

func calculate_health() -> float:
    return strength / 2.0 + endurance * 5.0

func calculate_magicka() -> float:
    return intelligence * 2.0

func calculate_fatigue() -> float:
    return strength + willpower + agility + endurance

func get_encumbrance() -> float:
    return strength * 5.0  # Max carry weight

func gain_skill_xp(skill_name: String, amount: float) -> void:
    set(skill_name, get(skill_name) + amount)
    _check_level_up()

func _check_level_up() -> void:
    # Morrowind leveling: gain 10 skill points → level up
    pass
```

### Tasks
- [ ] Attribute system
- [ ] Skill system (27 skills)
- [ ] Health/Magicka/Fatigue
- [ ] Leveling system
- [ ] Skill XP gain
- [ ] Level-up UI
- [ ] Stat effects (buffs, debuffs)

---

## Combat System (❌ Not Started - 0%)

### Morrowind Combat
- **Melee:** Slash, chop, thrust attacks (based on weapon type)
- **Ranged:** Bows, crossbows, throwing weapons
- **Magic:** Offensive spells
- **Hit chance:** Dice roll based on skill + agility
- **Damage:** Weapon damage + strength bonus

### Planned Implementation

```gdscript
# src/core/combat/combat_system.gd
class_name CombatSystem

func attack_melee(attacker: Actor, target: Actor) -> Dictionary:
    var weapon: WeaponRecord = attacker.inventory.get_equipped_weapon()

    # Hit chance calculation
    var hit_chance := _calculate_hit_chance(attacker, target, weapon)
    var roll := randf()

    if roll > hit_chance:
        return {"hit": false, "damage": 0}

    # Damage calculation
    var base_damage := randi_range(weapon.damage_min, weapon.damage_max)
    var strength_bonus := attacker.stats.strength / 5.0
    var total_damage := base_damage + strength_bonus

    # Armor reduction
    var armor_rating := target.get_armor_rating()
    total_damage -= armor_rating

    # Apply damage
    target.stats.health -= max(total_damage, 0)

    return {"hit": true, "damage": total_damage}

func _calculate_hit_chance(attacker: Actor, target: Actor, weapon: WeaponRecord) -> float:
    var skill := attacker.stats.get_weapon_skill(weapon.weapon_type)
    var agility := attacker.stats.agility
    var luck := attacker.stats.luck

    var hit_chance := (skill + agility / 5.0 + luck / 10.0) / 100.0
    hit_chance -= target.get_evasion()

    return clamp(hit_chance, 0.05, 0.95)  # 5-95% hit chance
```

### Tasks
- [ ] Melee combat (hit detection, damage)
- [ ] Ranged combat (projectiles, arrows)
- [ ] Magic combat (spell projectiles, target selection)
- [ ] Hit chance calculation
- [ ] Armor system
- [ ] Blocking
- [ ] Critical hits
- [ ] Combat animations
- [ ] Combat UI (health bars, hit markers)

---

## Magic System (❌ Not Started - 0%)

### Morrowind Magic
- **143 magic effects** (from ESM MGEF records)
- **Spells:** Pre-made combinations of effects
- **Enchantments:** Magic on items
- **Spell types:** Target, Touch, Self, Area
- **Magicka cost:** Based on effect magnitude/duration

### Planned Implementation

```gdscript
# src/core/magic/magic_system.gd
class_name MagicSystem

func cast_spell(caster: Actor, spell: SpellRecord, target: Node3D = null) -> bool:
    # Magicka cost
    var cost := _calculate_spell_cost(spell)
    if caster.stats.magicka < cost:
        return false  # Not enough magicka

    caster.stats.magicka -= cost

    # Apply effects
    for effect in spell.effects:
        _apply_magic_effect(effect, caster, target)

    return true

func _apply_magic_effect(effect: MagicEffect, caster: Actor, target: Node3D) -> void:
    match effect.effect_id:
        "RestoreHealth":
            target.stats.health += effect.magnitude
        "DamageHealth":
            target.stats.health -= effect.magnitude
        "Paralyze":
            target.apply_status_effect("paralyzed", effect.duration)
        "Levitate":
            target.enable_levitation(effect.duration)
        # ... 139 more effects
```

### Tasks
- [ ] Spell casting (target selection, projectiles)
- [ ] Magic effects (143 types!)
- [ ] Spell creation (spellmaking)
- [ ] Enchanting
- [ ] Magicka regeneration
- [ ] Spell failure chance
- [ ] Visual effects (particles, shaders)
- [ ] Sound effects

---

## AI System (❌ Not Started - 0%)

### Morrowind AI
- **NPC schedules:** Eat, sleep, work, wander
- **Combat AI:** Attack, flee, heal
- **Dialogue:** Greet player, respond to topics
- **Pathfinding:** Navigate to locations

### Planned Implementation (Beehave + GOAP)

```gdscript
# src/core/ai/npc_ai.gd
extends CharacterBody3D

@onready var behavior_tree: BeehaveTree = $BeehaveTree
@onready var goap_planner: GOAPPlanner = $GOAPPlanner

func _ready():
    # Define GOAP goals
    goap_planner.add_goal("not_hungry", 5)
    goap_planner.add_goal("not_tired", 3)
    goap_planner.add_goal("safe", 10)

    # Define GOAP actions
    goap_planner.add_action("eat", {
        "cost": 1,
        "preconditions": {"has_food": true},
        "effects": {"not_hungry": true}
    })

    goap_planner.add_action("find_food", {
        "cost": 5,
        "effects": {"has_food": true}
    })

    goap_planner.add_action("sleep", {
        "cost": 1,
        "preconditions": {"at_bed": true},
        "effects": {"not_tired": true}
    })

    goap_planner.add_action("go_to_bed", {
        "cost": 3,
        "effects": {"at_bed": true}
    })

    # Behavior tree executes GOAP plan
    behavior_tree.root = _build_behavior_tree()

func _build_behavior_tree() -> BeehaveNode:
    return Selector.new([
        # Combat
        Sequence.new([
            IsInCombat.new(),
            FightOrFlee.new()
        ]),

        # Schedule
        Sequence.new([
            ExecuteGOAPPlan.new(goap_planner),
        ]),

        # Idle
        Idle.new()
    ])
```

### Tasks
- [ ] NPC behavior trees (Beehave)
- [ ] NPC goals (GOAP)
- [ ] Schedule system (8am eat, 12pm work, 8pm sleep)
- [ ] Combat AI (attack, block, flee, heal)
- [ ] Pathfinding (A*, NavMesh)
- [ ] Dialogue initiation (greet player)
- [ ] Wandering

---

## Dialogue System (⚠️ In Progress - 30%)

### Current State
- ESM DIAL/INFO records parsed
- Dialogue Manager plugin installed
- Converter partially written

### Planned UI

```gdscript
# src/ui/dialogue_ui.gd
extends Control

@onready var speaker_label: Label = $SpeakerName
@onready var text_label: RichTextLabel = $DialogueText
@onready var topic_list: ItemList = $TopicList

func start_dialogue(npc: NPC) -> void:
    speaker_label.text = npc.name

    # Populate topics (from ESM DIAL records)
    topic_list.clear()
    for topic in npc.get_available_topics():
        topic_list.add_item(topic)

func _on_topic_selected(index: int) -> void:
    var topic := topic_list.get_item_text(index)
    var response := _get_dialogue_response(current_npc, topic)

    text_label.text = response.text

    # Show responses (if any)
    if response.has("responses"):
        _show_responses(response.responses)

func _get_dialogue_response(npc: NPC, topic: String) -> Dictionary:
    var dialogue: DialogueRecord = ESMManager.dialogues[topic]

    # Find matching INFO (filter by conditions)
    for info in dialogue.infos:
        if _check_conditions(info, npc):
            return {
                "text": info.text,
                "speaker": info.speaker_name,
                "sound": info.sound,
                "script": info.result_script
            }

    return {"text": "I don't know anything about that."}

func _check_conditions(info: DialogueInfoRecord, npc: NPC) -> bool:
    # Check disposition
    if npc.disposition < info.disposition:
        return false

    # Check faction/rank
    if info.faction and not player.is_in_faction(info.faction, info.rank):
        return false

    # Check script conditions
    for condition in info.conditions:
        if not _evaluate_script_condition(condition):
            return false

    return true
```

### Tasks
- [x] ESM record parsing
- [x] Dialogue Manager installation
- [ ] ESM → Dialogue Manager converter
- [ ] Dialogue UI
- [ ] Condition checking (faction, rank, disposition)
- [ ] Persuasion mini-game
- [ ] Disposition system
- [ ] Dialogue sound playback

---

## Quest System (❌ Not Started - 0%)

### Morrowind Quests
- **Journal-based:** Quests update journal entries
- **INFO records:** Type 4 = journal entries
- **No explicit quest structure** (player reads journal to track)

### Planned Implementation (Questify)

```gdscript
# src/core/quests/quest_manager.gd
class_name QuestManager

var active_quests: Array[Quest] = []
var completed_quests: Array[Quest] = []
var journal_entries: Array[JournalEntry] = []

func start_quest(quest_id: String) -> void:
    var quest := _create_quest_from_esm(quest_id)
    active_quests.append(quest)
    emit_signal("quest_started", quest)

func update_quest(quest_id: String, step: int, text: String) -> void:
    var entry := JournalEntry.new()
    entry.quest_id = quest_id
    entry.step = step
    entry.text = text
    entry.timestamp = Time.get_datetime_dict_from_system()

    journal_entries.append(entry)
    emit_signal("journal_updated", entry)

    # Check if quest completed
    var quest := _get_quest(quest_id)
    if quest.is_completed():
        _complete_quest(quest)

func _create_quest_from_esm(quest_name: String) -> Quest:
    # Parse journal entries for this quest
    var quest := Quest.new()
    quest.name = quest_name

    # Find all journal INFO records for this quest
    for dialogue_id in ESMManager.dialogues.keys():
        var dialogue: DialogueRecord = ESMManager.dialogues[dialogue_id]
        if dialogue.type == 4:  # Journal
            for info in dialogue.infos:
                if _is_quest_related(info, quest_name):
                    var step := QuestStep.new()
                    step.index = info.journal_index
                    step.description = info.text
                    quest.add_step(step)

    return quest
```

### Tasks
- [ ] Quest data parser (journal INFO records)
- [ ] Quest tracking
- [ ] Journal UI
- [ ] Quest markers (waypoints)
- [ ] Quest rewards

---

## Inventory System (❌ Not Started - 0%)

### Planned Implementation (GLoot + Pandora)

```gdscript
# src/core/inventory/player_inventory.gd
class_name PlayerInventory

var inventory: Inventory  # GLoot
var equipment: Equipment  # GLoot

# Equipment slots
enum EquipSlot {
    HEAD, CHEST, LEGS, FEET, HANDS,
    LEFT_HAND, RIGHT_HAND,
    LEFT_RING, RIGHT_RING,
    AMULET, BELT
}

func add_item(item_id: String, count: int = 1) -> void:
    var item_data := Pandora.get_entity(item_id)
    var item := InventoryItem.new()
    item.prototype_id = item_id
    item.properties = item_data.properties
    inventory.add_item(item, count)

func equip_item(item: InventoryItem, slot: EquipSlot) -> void:
    var prev_item := equipment.get_item_in_slot(slot)
    if prev_item:
        unequip_item(slot)

    equipment.equip(item, slot)
    _update_stats()

func _update_stats() -> void:
    # Recalculate armor rating, damage, etc.
    player.stats.update_from_equipment(equipment)
```

### Tasks
- [ ] Pandora database from ESM items
- [ ] GLoot inventory setup
- [ ] Equipment system (11 slots)
- [ ] Inventory UI (grid, list views)
- [ ] Container UI (chests, barrels)
- [ ] Weight/encumbrance
- [ ] Item tooltips

---

## Next-Gen Features (Future)

### Water Systems
- Ocean simulation (FFT waves, foam)
- Rivers (flow maps, currents)
- Ponds (simple ripples)
- Multiple altitudes
- Swimming physics
- Underwater effects

### Weather Systems
- Dynamic weather per region
- Particle effects (rain, snow, ash)
- Sky3D integration
- Sound ambience
- Lightning
- Fog

### Advanced AI
- Radiant AI (emergent behavior)
- NPC relationships
- Dynamic schedules
- Crime witnessing
- Memory system

---

## Task Tracker

- [x] ESM record parsing (all gameplay data)
- [x] Plugin installation
- [ ] Player controller
- [ ] Character creation
- [ ] Stats system (attributes, skills, leveling)
- [ ] Combat system (melee, ranged, magic)
- [ ] Magic system (spells, effects)
- [ ] AI system (schedules, combat)
- [ ] Dialogue system (UI, conditions)
- [ ] Quest system (journal, tracking)
- [ ] Inventory system (equipment, containers)
- [ ] Alchemy
- [ ] Enchanting
- [ ] Crime/reputation
- [ ] Factions
- [ ] Stealth

---

**See Also:**
- [05_ESM_SYSTEM.md](05_ESM_SYSTEM.md) - Gameplay data parsing
- [08_PLUGIN_INTEGRATION.md](08_PLUGIN_INTEGRATION.md) - Plugin status
- [10_DEVELOPMENT_STATUS.md](10_DEVELOPMENT_STATUS.md) - Overall roadmap
- [11_VIBE_CODING_METHODOLOGY.md](11_VIBE_CODING_METHODOLOGY.md) - Development workflow
