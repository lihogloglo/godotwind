# Vibe Coding Methodology

## What is Vibe Coding?

**Vibe Coding** is a development philosophy for large, ambitious projects like Godotwind. Instead of meticulous planning and waterfall development, it embraces:

1. **Rapid Iteration** - Ship features fast, refine later
2. **AI-Assisted Development** - Leverage Claude, Copilot, etc.
3. **Documentation-First** - Write docs before code (you're reading one!)
4. **Modular Architecture** - Loosely coupled systems
5. **Prototype Everything** - Prove concepts quickly
6. **Performance Later** - Make it work, then make it fast
7. **Trust Your Instincts** - Follow the "vibe" of what feels right

**Core Principle:** *Get something working end-to-end, then polish. Perfection is the enemy of progress.*

---

## The Godotwind Development Cycle

### 1. Define the Feature (Documentation First)

**Before writing any code**, document the feature in detail:

```markdown
# Feature: Player Swimming

## Goals
- Player can swim on water surface
- Underwater view (blue tint, reduced visibility)
- Fatigue drains while swimming
- Drowning when fatigue reaches zero

## Architecture
- Add water plane detection (raycast down from player)
- Modify player controller physics (reduced gravity, different movement speed)
- Add underwater post-processing shader
- Integrate with stats system (fatigue drain)

## Tasks
- [ ] Detect water surface
- [ ] Modify player controller for swimming
- [ ] Add underwater shader
- [ ] Fatigue drain logic
- [ ] Drowning mechanic
- [ ] Sound effects (splash, underwater ambience)
```

**Why?**
- Clarifies thinking before coding
- Creates shareable spec for AI assistants
- Documents decisions for future reference
- Prevents scope creep

---

### 2. Prototype Rapidly (Make It Work)

**Goal:** Get a working proof-of-concept as fast as possible.

**Techniques:**
- **Use placeholders:** Colored boxes, simple shapes, debug text
- **Hardcode values:** Don't create UI sliders yet
- **Skip edge cases:** Handle the happy path first
- **Use print statements:** Debug with `print()`, not breakpoints
- **Leverage AI:** Feed your documentation to Claude/Copilot

**Example: Swimming Prototype**

```gdscript
# Prototype in 30 minutes
extends CharacterBody3D

var is_swimming := false

func _physics_process(delta):
    # Water detection (hardcoded Y=0 for now)
    if global_position.y < 0:
        is_swimming = true
    else:
        is_swimming = false

    if is_swimming:
        # Reduced gravity
        velocity.y += -2.0 * delta  # Instead of -9.8
        # Reduced speed
        var speed := 2.0  # Instead of 5.0
        var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
        velocity.x = input.x * speed
        velocity.z = input.y * speed

        # Underwater shader (just tint screen blue for now)
        $Camera3D.environment.adjustment_color_correction = preload("res://underwater_tint.tres")

        print("Swimming! Fatigue: TODO")

    move_and_slide()
```

**Result:** You can now swim! It's ugly, hardcoded, and incomplete, but it **proves the concept**.

---

### 3. Test in Context (Integrate Early)

**Don't develop in isolation.** Test your feature in the real game world immediately.

**Example:**
- Load a coastal cell with water
- Jump in and try swimming
- Walk out and verify walking works again
- Jump back in to test transition

**Why?**
- Catches integration issues early
- Surfaces unexpected edge cases
- Maintains project momentum
- Keeps you motivated (you see progress!)

---

### 4. Refactor & Polish (Make It Good)

**Now that it works, make it better:**

**Refactoring Checklist:**
- [ ] Replace hardcoded values with exports
- [ ] Extract magic numbers to constants
- [ ] Replace placeholders with real assets
- [ ] Add error handling
- [ ] Remove debug prints
- [ ] Add comments for complex logic
- [ ] Create reusable components

**Example: Swimming Refactor**

```gdscript
extends CharacterBody3D

const SWIM_GRAVITY := -2.0
const SWIM_SPEED := 2.0
const FATIGUE_DRAIN_RATE := 5.0  # Per second
const WATER_SURFACE_Y := 0.0  # TODO: Get from water plane

@export var underwater_environment: Environment

var is_swimming := false
var is_underwater := false

@onready var stats: PlayerStats = $Stats
@onready var camera: Camera3D = $Camera3D
@onready var water_detector: RayCast3D = $WaterDetector

func _ready():
    water_detector.target_position = Vector3.DOWN * 2.0

func _physics_process(delta):
    _update_water_state()

    if is_swimming:
        _apply_swim_physics(delta)
        _drain_fatigue(delta)

    if is_underwater:
        _apply_underwater_effects()
    else:
        _remove_underwater_effects()

    move_and_slide()

func _update_water_state() -> void:
    # Proper water detection via raycast
    water_detector.force_raycast_update()
    is_swimming = water_detector.is_colliding() and water_detector.get_collider().is_in_group("water")
    is_underwater = is_swimming and global_position.y < WATER_SURFACE_Y

func _apply_swim_physics(delta: float) -> void:
    # Reduced gravity
    velocity.y += SWIM_GRAVITY * delta

    # Swim movement
    var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
    var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
    velocity.x = direction.x * SWIM_SPEED
    velocity.z = direction.z * SWIM_SPEED

    # Swim up/down
    if Input.is_action_pressed("jump"):
        velocity.y = SWIM_SPEED
    if Input.is_action_pressed("crouch"):
        velocity.y = -SWIM_SPEED

func _drain_fatigue(delta: float) -> void:
    stats.fatigue -= FATIGUE_DRAIN_RATE * delta
    if stats.fatigue <= 0:
        _start_drowning()

func _apply_underwater_effects() -> void:
    camera.environment = underwater_environment

func _remove_underwater_effects() -> void:
    camera.environment = null

func _start_drowning() -> void:
    stats.health -= 5.0  # Per second, handled elsewhere
    # TODO: Play drowning animation, sound
```

**Result:** Clean, maintainable, configurable code!

---

### 5. Optimize (Make It Fast)

**Only optimize when you have performance problems.**

**Profiling First:**
```gdscript
var start_time := Time.get_ticks_usec()
_expensive_function()
var elapsed := (Time.get_ticks_usec() - start_time) / 1000.0
print("Function took %.2fms" % elapsed)
```

**Common Optimizations:**
- **Object pooling** for frequent instantiations
- **LOD** for distant objects
- **Caching** for repeated lookups
- **Batching** for similar operations
- **RenderingServer** for visual-only objects

**Example: Optimize Water Detection**

```gdscript
# ❌ Before: Raycast every frame (expensive)
func _physics_process(delta):
    water_detector.force_raycast_update()
    is_swimming = water_detector.is_colliding()

# ✅ After: Check every 100ms (10 FPS is enough)
var _water_check_timer := 0.0
var _water_check_interval := 0.1

func _physics_process(delta):
    _water_check_timer += delta
    if _water_check_timer >= _water_check_interval:
        _water_check_timer = 0.0
        water_detector.force_raycast_update()
        is_swimming = water_detector.is_colliding()
```

**Result:** 10x less CPU usage for water detection!

---

## AI-Assisted Development

### How to Use AI (Claude, Copilot, etc.)

**1. Provide Context**

Don't just say "write a swimming system." Give Claude:
- The feature documentation
- Relevant existing code (player controller, stats system)
- Architecture constraints (must integrate with X, Y, Z)
- Code style preferences

**Example Prompt:**

```
I'm adding a swimming system to Godotwind, an open-world Godot game.

Context:
- Player is a CharacterBody3D with a Stats system (health, fatigue, magicka)
- Water surfaces are StaticBody3D in the "water" group
- Fatigue should drain while swimming at 5 pts/sec
- When fatigue reaches 0, player drowns (health drains)

Existing code:
[Paste player_controller.gd]
[Paste stats.gd]

Please implement swimming with:
1. Water detection via raycast
2. Modified physics (reduced gravity, different movement)
3. Fatigue drain
4. Drowning mechanic

Follow these patterns:
- Use @export for configurable values
- Create helper functions for each responsibility
- Add comments for complex logic
```

**2. Iterate in Small Steps**

Don't ask AI to write entire systems. Break it down:

**Bad:** "Write the entire combat system"

**Good:**
1. "Write hit detection for melee attacks"
2. "Add damage calculation based on weapon stats"
3. "Add armor reduction"
4. "Add combat animations"
5. "Add hit markers and UI feedback"

**3. Verify AI Output**

**Never blindly copy AI code.** Always:
- Read and understand what it does
- Test it in your project
- Refactor to match your code style
- Add error handling if missing
- Remove unnecessary complexity

**4. Use AI for Tedious Work**

AI excels at:
- **Boilerplate code** (getters/setters, signals)
- **Data conversion** (ESM records → Godot resources)
- **Repetitive patterns** (27 skill properties? Let AI write them)
- **Documentation** (generate doc comments from code)

**Example: Generate 27 Skill Properties**

```
Prompt: "Generate 27 skill properties for Morrowind:
block, armorer, medium_armor, heavy_armor, blunt_weapon, long_blade,
axe, spear, athletics, enchant, destruction, alteration, illusion,
conjuration, mysticism, restoration, alchemy, unarmored, security,
sneak, acrobatics, light_armor, short_blade, marksman, mercantile,
speechcraft, hand_to_hand

Each should be:
var skill_name: int = 5
"

Output:
var block: int = 5
var armorer: int = 5
var medium_armor: int = 5
# ... (24 more)
```

**5. Ask AI to Review Your Code**

```
Prompt: "Review this code for bugs, performance issues, and code smell:

[Paste your code]
"
```

AI can spot:
- Null pointer dereferences
- Inefficient algorithms
- Missing error handling
- Code duplication

---

## Modular Architecture for Vibe Coding

**Key Principle:** Systems should be **loosely coupled** so you can work on one without breaking others.

### Example: Good vs Bad Architecture

**❌ Bad (Tight Coupling):**

```gdscript
# player_controller.gd
func _on_attack_button_pressed():
    var weapon := inventory.get_equipped_weapon()
    var target := get_target()
    var damage := weapon.damage + stats.strength / 5.0
    target.health -= damage
    if target.health <= 0:
        target.die()
        quest_manager.on_enemy_killed(target)
        inventory.add_item(target.loot)
```

**Problems:**
- Player controller knows about inventory, combat, quests, loot
- Can't change combat system without editing player controller
- Hard to test in isolation

**✅ Good (Loose Coupling via Signals):**

```gdscript
# player_controller.gd
signal attack_requested(target: Node3D)

func _on_attack_button_pressed():
    var target := get_target()
    if target:
        attack_requested.emit(target)

# combat_system.gd
func _ready():
    player.attack_requested.connect(_on_player_attack)

func _on_player_attack(target: Node3D):
    var weapon := player.inventory.get_equipped_weapon()
    var damage := calculate_damage(player, target, weapon)
    target.take_damage(damage)

# quest_manager.gd
func _ready():
    # Listen to ANY enemy death, not just from player
    get_tree().call_group("enemies", "connect", "died", _on_enemy_died)

func _on_enemy_died(enemy: Node3D):
    update_quests(enemy)
```

**Benefits:**
- Each system has one responsibility
- Easy to test in isolation
- Can swap implementations easily
- Clear data flow

---

## Common Vibe Coding Patterns

### Pattern 1: Placeholder → Real Implementation

**Start with the simplest possible version:**

```gdscript
# Placeholder: Just print
func cast_spell(spell: SpellRecord) -> void:
    print("Casting: ", spell.name)

# Later: Add actual logic
func cast_spell(spell: SpellRecord) -> void:
    if stats.magicka < spell.cost:
        return

    stats.magicka -= spell.cost

    for effect in spell.effects:
        apply_magic_effect(effect)

    play_animation(spell.animation)
    play_sound(spell.sound)
```

**Why:** Proves the concept without getting bogged down in details.

---

### Pattern 2: Hardcode → Export → Config File

**Evolution of configuration:**

```gdscript
# V1: Hardcoded
const PLAYER_SPEED := 5.0

# V2: Export (configurable in editor)
@export var player_speed := 5.0

# V3: Config file (for modding)
var player_speed := GameConfig.get_value("player", "speed", 5.0)
```

**Why:** Start simple, add flexibility when needed.

---

### Pattern 3: Monolith → Modular

**Start with everything in one file, split later:**

```gdscript
# V1: Everything in player_controller.gd (300 lines)
extends CharacterBody3D

func _ready(): ...
func _physics_process(delta): ...
func move(): ...
func jump(): ...
func attack(): ...
func cast_spell(): ...
func open_inventory(): ...
# ... etc ...

# V2: Split into modules
extends CharacterBody3D

@onready var movement: PlayerMovement = $Movement
@onready var combat: PlayerCombat = $Combat
@onready var magic: PlayerMagic = $Magic
@onready var inventory: PlayerInventory = $Inventory

func _physics_process(delta):
    movement.update(delta)

func _input(event):
    if event.is_action_pressed("attack"):
        combat.attack()
    if event.is_action_pressed("cast_spell"):
        magic.cast_active_spell()
```

**Why:** Easier to start with one file, refactor when it gets too large (>200 lines).

---

### Pattern 4: Debug Visualization → Polished UI

**Start with debug overlays:**

```gdscript
# V1: Debug text
func _process(delta):
    $DebugLabel.text = "Health: %d\nMagicka: %d\nFatigue: %d" % [
        stats.health, stats.magicka, stats.fatigue
    ]

# V2: Simple UI
func _process(delta):
    $UI/HealthBar.value = stats.health
    $UI/MagickaBar.value = stats.magicka
    $UI/FatigueBar.value = stats.fatigue

# V3: Polished UI with animations
func _on_stat_changed(stat_name: String, old_value: float, new_value: float):
    var bar := get_node("UI/%sBar" % stat_name)
    var tween := create_tween()
    tween.tween_property(bar, "value", new_value, 0.3).set_trans(Tween.TRANS_CUBIC)

    if new_value < old_value:
        # Flash red on damage
        _flash_bar(bar, Color.RED)
```

**Why:** Debug visualization gets you results fast, polish comes later.

---

## The Vibe Coding Mindset

### Embrace Imperfection

**❌ Perfectionist:** "I need to architect the perfect magic system before writing any code."

**✅ Vibe Coder:** "Let me hardcode a fireball spell and see it work, then I'll generalize."

**Result:** The vibe coder has a working fireball in 1 hour. The perfectionist is still designing UML diagrams.

---

### Ship Features, Not Code

**❌ Code-Focused:** "I refactored the combat system to use a Strategy pattern with dependency injection."

**✅ Feature-Focused:** "I added blocking, dodging, and critical hits to combat."

**Result:** Users don't care about your architecture. They care about features.

---

### Iterate Based on Feedback

**❌ Waterfall:** Plan entire game → Implement for 6 months → Release → Get feedback (too late!)

**✅ Agile/Vibe:** Build smallest playable version → Release → Get feedback → Iterate

**Example:**
1. Week 1: Player can walk and attack
2. Week 2: Add blocking (feedback: attacks too fast!)
3. Week 3: Add attack cooldown (feedback: combat feels good now!)
4. Week 4: Add special attacks

---

### Trust the Process

**Vibe coding feels messy at first.** Your code will be ugly, your features will be incomplete, and you'll have placeholders everywhere.

**That's okay.** You're building **momentum**. Every feature you ship gives you:
- Proof that the system works
- Feedback for the next iteration
- Motivation to keep going
- Something to show others

**The refactoring comes naturally.** Once you have 5 messy features, patterns emerge:
- "Oh, these 3 systems all need to access player stats. Let me make a Stats autoload."
- "These 4 scripts all convert ESM records. Let me make a RecordConverter class."

**Don't force architecture prematurely.** Let it **emerge** from your code.

---

## Practical Vibe Coding for Godotwind

### Example: Adding Water Rendering

#### Week 1: Placeholder Water

```gdscript
# Just a flat blue plane
var water_plane := MeshInstance3D.new()
water_plane.mesh = PlaneMesh.new()
water_plane.mesh.size = Vector2(10000, 10000)
var mat := StandardMaterial3D.new()
mat.albedo_color = Color(0.2, 0.4, 0.8, 0.7)
mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
water_plane.material_override = mat
add_child(water_plane)
```

**Result:** Blue water! Ugly, but proves the concept.

---

#### Week 2: Simple Shader

```glsl
shader_type spatial;

uniform vec3 water_color : source_color = vec3(0.2, 0.4, 0.8);
uniform float wave_speed : hint_range(0, 5) = 1.0;
uniform float wave_height : hint_range(0, 1) = 0.1;

void vertex() {
    VERTEX.y += sin(TIME * wave_speed + VERTEX.x * 0.5) * wave_height;
}

void fragment() {
    ALBEDO = water_color;
    ALPHA = 0.7;
}
```

**Result:** Animated waves! Still simple, but looks better.

---

#### Week 3: Foam & Reflections

```glsl
// Add foam near shore
uniform sampler2D foam_texture;
uniform float shore_distance : hint_range(0, 10) = 2.0;

void fragment() {
    // ... existing code ...

    // Sample depth (requires depth texture)
    float depth = texture(DEPTH_TEXTURE, SCREEN_UV).r;
    float foam_amount = smoothstep(shore_distance, 0.0, depth);
    vec3 foam = texture(foam_texture, UV * 10.0).rgb;

    ALBEDO = mix(water_color, foam, foam_amount);

    // Simple reflection
    ROUGHNESS = 0.1;
    METALLIC = 0.5;
}
```

**Result:** Professional-looking water with foam and reflections!

---

#### Week 4: Multiple Water Levels

```gdscript
# Water manager supports multiple water planes
class_name WaterManager

var water_planes: Array[WaterPlane] = []

func create_water_plane(altitude: float, size: Vector2, type: String) -> WaterPlane:
    var plane := WaterPlane.new()
    plane.altitude = altitude
    plane.size = size
    plane.type = type  # "ocean", "river", "pond"
    plane.shader = _get_shader_for_type(type)
    water_planes.append(plane)
    add_child(plane)
    return plane

func _get_shader_for_type(type: String) -> Shader:
    match type:
        "ocean":
            return preload("res://shaders/ocean_water.gdshader")
        "river":
            return preload("res://shaders/river_water.gdshader")
        "pond":
            return preload("res://shaders/pond_water.gdshader")
```

**Result:** Next-gen water system with different water types!

---

**Total Time:** 4 weeks from nothing to production-quality water system, iterating based on visual feedback each week.

---

## Vibe Coding Checklist

### Before Starting a Feature

- [ ] Write feature documentation (goals, architecture, tasks)
- [ ] Identify dependencies (what systems does this need?)
- [ ] Plan the smallest possible prototype
- [ ] Set a time limit (1 hour? 1 day? 1 week?)

### While Implementing

- [ ] Start with placeholders (colored boxes, print statements)
- [ ] Hardcode values first, make them configurable later
- [ ] Test in the real game world immediately
- [ ] Commit frequently (every hour or major milestone)
- [ ] Use AI for boilerplate and repetitive tasks
- [ ] Take breaks (vibe coding is intense!)

### After Completing Prototype

- [ ] Does it work end-to-end?
- [ ] Can I show this to someone?
- [ ] What's the next iteration?
- [ ] What did I learn?

### Before Refactoring

- [ ] Profile first (don't optimize blindly)
- [ ] Extract constants and exports
- [ ] Replace placeholders with real assets
- [ ] Add error handling
- [ ] Write tests (if applicable)
- [ ] Document complex logic

### Before Merging/Releasing

- [ ] Remove debug code
- [ ] Update documentation
- [ ] Test integration with other systems
- [ ] Get feedback from others
- [ ] Plan next iteration based on feedback

---

## Anti-Patterns to Avoid

### 1. Premature Optimization

**❌ Bad:**
```gdscript
# Optimizing before you have working code
var _object_pool: Dictionary = {}
var _spatial_hash: Dictionary = {}
var _octree: Octree = Octree.new()

func spawn_object(pos: Vector3):
    # Wait, I don't even have objects spawning yet!
```

**✅ Good:**
```gdscript
# Make it work first
func spawn_object(pos: Vector3):
    var obj := preload("res://object.tscn").instantiate()
    obj.position = pos
    add_child(obj)

# Optimize later when you have 1000 objects and FPS drops
```

---

### 2. Analysis Paralysis

**❌ Bad:** Spending 3 days researching the perfect dialogue system architecture.

**✅ Good:** Spending 1 hour hardcoding 3 dialogue lines to see what works, **then** researching.

---

### 3. Over-Engineering

**❌ Bad:**
```gdscript
# Abstract factory pattern for creating spells
class SpellFactory:
    static func create_spell(type: SpellType, config: SpellConfig) -> ISpell:
        match type:
            SpellType.PROJECTILE:
                return ProjectileSpellFactory.create(config)
            # ... 50 more lines of abstraction
```

**✅ Good:**
```gdscript
# Just create spells directly
func create_fireball() -> Spell:
    var spell := Spell.new()
    spell.name = "Fireball"
    spell.damage = 25
    spell.projectile_scene = preload("res://fireball.tscn")
    return spell
```

**Refactor to factory pattern later if you're creating 100+ spells programmatically.**

---

### 4. Feature Creep

**❌ Bad:**
- Start working on player controller
- "Oh, I need swimming"
- "Swimming needs water"
- "Water needs shader"
- "Shader needs foam texture"
- "Foam needs wave simulation"
- **6 weeks later, no player controller**

**✅ Good:**
- Work on player controller
- Use placeholder water (blue plane)
- Player controller done in 1 week
- **Then** add swimming
- **Then** improve water

---

## Final Wisdom

### The Godotwind Vibe

Godotwind is **ambitious**. It's porting a 300-hour RPG to a new engine while building a next-gen framework. That's HUGE.

**You can't do it perfectly.** You'll make mistakes. You'll write bad code. You'll have to refactor.

**That's the process.** Every successful game engine was built this way:
- Unity started as a simple Mac game engine
- Unreal started as a Quake mod
- Godot started as an in-house tool

**Trust the vibe:**
1. Ship something small
2. Get feedback
3. Iterate
4. Repeat

**Before you know it, you'll have a production-quality open-world framework.**

---

## Questions & Mantras

### When stuck, ask yourself:

**"What's the simplest version I can ship today?"**

**"Can I hardcode this for now and make it flexible later?"**

**"Am I building this for users, or for my ego?"**

**"What would I do if I only had 1 hour?"**

---

### Vibe Coding Mantras

- **"Ship it now, polish it later."**
- **"Placeholders are your friend."**
- **"Refactoring is easier than perfecting."**
- **"Feedback beats planning."**
- **"Momentum is everything."**
- **"If it works, it's good enough."**
- **"AI writes code, you architect systems."**
- **"Messy code that works > clean code that doesn't."**
- **"Feature complete > bug free."** (for prototypes!)

---

## Let's Build Something Amazing

Godotwind has the potential to be **the** open-world framework for Godot. But it needs:
- Rapid iteration
- Community contributions
- Proven features
- Momentum

**Vibe coding gives you all of this.**

Now go forth and **ship features**! 🚀

---

**See Also:**
- [10_DEVELOPMENT_STATUS.md](10_DEVELOPMENT_STATUS.md) - What to work on next
- [09_GAMEPLAY_SYSTEMS.md](09_GAMEPLAY_SYSTEMS.md) - Gameplay features to implement
- [01_PROJECT_OVERVIEW.md](01_PROJECT_OVERVIEW.md) - Project vision and goals
