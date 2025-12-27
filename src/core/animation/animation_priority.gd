## AnimationPriority - Manages animation priority and conflict resolution
##
## Based on OpenMW's Animation::AnimPriority system
## Higher priority animations override lower priority ones
## Same priority animations can blend based on mask
##
## Priority Levels (from OpenMW):
## - 0: None/Idle
## - 1: Movement (walk, run)
## - 2: Combat Idle
## - 3: Attack/Block/Cast
## - 4: Hit Reaction
## - 5: Death
## - 6: Scripted (highest priority)
class_name AnimationPriority
extends RefCounted

# Priority levels
const PRIORITY_IDLE: int = 0
const PRIORITY_MOVEMENT: int = 1
const PRIORITY_COMBAT_IDLE: int = 2
const PRIORITY_ACTION: int = 3       # Attack, Block, Cast
const PRIORITY_HIT: int = 4
const PRIORITY_DEATH: int = 5
const PRIORITY_SCRIPTED: int = 6
const PRIORITY_PERSISTENT: int = 7   # Never interrupted

# Animation groups that can play together (on different body parts)
enum AnimGroup {
	LOWER_BODY = 0,   # Legs, pelvis - locomotion
	UPPER_BODY = 1,   # Torso - actions
	LEFT_ARM = 2,     # Left arm - shield
	RIGHT_ARM = 3,    # Right arm - weapon
	HEAD = 4,         # Head - look-at, dialogue
	FULL_BODY = 5,    # Entire skeleton (death, scripted)
}

# Mapping of animation states to priorities
const STATE_PRIORITIES := {
	&"Idle": PRIORITY_IDLE,
	&"Walk": PRIORITY_MOVEMENT,
	&"Run": PRIORITY_MOVEMENT,
	&"Sprint": PRIORITY_MOVEMENT,
	&"Jump": PRIORITY_MOVEMENT,
	&"Fall": PRIORITY_MOVEMENT,
	&"Land": PRIORITY_MOVEMENT,
	&"SwimIdle": PRIORITY_MOVEMENT,
	&"SwimForward": PRIORITY_MOVEMENT,
	&"CombatIdle": PRIORITY_COMBAT_IDLE,
	&"Attack": PRIORITY_ACTION,
	&"Block": PRIORITY_ACTION,
	&"SpellCast": PRIORITY_ACTION,
	&"Hit": PRIORITY_HIT,
	&"Death": PRIORITY_DEATH,
}

# Mapping of states to animation groups
const STATE_GROUPS := {
	&"Idle": AnimGroup.FULL_BODY,
	&"Walk": AnimGroup.LOWER_BODY,
	&"Run": AnimGroup.LOWER_BODY,
	&"Sprint": AnimGroup.LOWER_BODY,
	&"Jump": AnimGroup.FULL_BODY,
	&"Fall": AnimGroup.FULL_BODY,
	&"Land": AnimGroup.FULL_BODY,
	&"SwimIdle": AnimGroup.FULL_BODY,
	&"SwimForward": AnimGroup.FULL_BODY,
	&"CombatIdle": AnimGroup.UPPER_BODY,
	&"Attack": AnimGroup.UPPER_BODY,
	&"Block": AnimGroup.LEFT_ARM,
	&"SpellCast": AnimGroup.UPPER_BODY,
	&"Hit": AnimGroup.FULL_BODY,
	&"Death": AnimGroup.FULL_BODY,
}

# Current animation state per group
var _group_animations: Array[Dictionary] = []  # [{name: StringName, priority: int, time: float}]

# Queued animations (for combos, sequences)
var _animation_queue: Array[Dictionary] = []

# Debug mode
var debug_mode: bool = false


func _init() -> void:
	# Initialize group state
	_group_animations.resize(AnimGroup.size())
	for i in AnimGroup.size():
		_group_animations[i] = {"name": &"", "priority": -1, "time": 0.0}


## Request to play an animation
## Returns true if the animation was accepted (not blocked by higher priority)
func request_animation(state: StringName, force: bool = false) -> bool:
	var priority := get_priority_for_state(state)
	var group := get_group_for_state(state)

	return request_animation_with_priority(state, priority, group, force)


## Request animation with explicit priority and group
func request_animation_with_priority(state: StringName, priority: int,
		group: int, force: bool = false) -> bool:

	var current: Dictionary = _group_animations[group]

	# Check if current animation has higher priority
	if not force and current["priority"] > priority:
		if debug_mode:
			print("AnimationPriority: Blocked '%s' (prio %d) by '%s' (prio %d)" % [
				state, priority, current["name"], current["priority"]
			])
		return false

	# Full body animations clear all groups
	if group == AnimGroup.FULL_BODY:
		_clear_all_groups()

	# Accept the animation
	_group_animations[group] = {
		"name": state,
		"priority": priority,
		"time": 0.0,
	}

	if debug_mode:
		print("AnimationPriority: Accepted '%s' (prio %d, group %d)" % [
			state, priority, group
		])

	return true


## Clear animation from a group (call when animation finishes)
func clear_animation(state: StringName) -> void:
	var group := get_group_for_state(state)
	var current: Dictionary = _group_animations[group]

	if current["name"] == state:
		_group_animations[group] = {"name": &"", "priority": -1, "time": 0.0}

		if debug_mode:
			print("AnimationPriority: Cleared '%s' from group %d" % [state, group])


## Clear all groups
func _clear_all_groups() -> void:
	for i in AnimGroup.size():
		_group_animations[i] = {"name": &"", "priority": -1, "time": 0.0}


## Get current animation for a group
func get_current_animation(group: int) -> StringName:
	if group < 0 or group >= _group_animations.size():
		return &""
	return _group_animations[group].get("name", &"")


## Get current priority for a group
func get_current_priority(group: int) -> int:
	if group < 0 or group >= _group_animations.size():
		return -1
	return _group_animations[group].get("priority", -1)


## Check if a state can interrupt the current animation in its group
func can_interrupt(state: StringName) -> bool:
	var priority := get_priority_for_state(state)
	var group := get_group_for_state(state)

	var current: Dictionary = _group_animations[group]
	return current["priority"] <= priority


## Get priority for a state
func get_priority_for_state(state: StringName) -> int:
	return STATE_PRIORITIES.get(state, PRIORITY_IDLE)


## Get animation group for a state
func get_group_for_state(state: StringName) -> int:
	return STATE_GROUPS.get(state, AnimGroup.FULL_BODY)


## Queue an animation to play after current
func queue_animation(state: StringName) -> void:
	var priority := get_priority_for_state(state)
	var group := get_group_for_state(state)

	_animation_queue.append({
		"name": state,
		"priority": priority,
		"group": group,
	})

	if debug_mode:
		print("AnimationPriority: Queued '%s'" % state)


## Get and remove next queued animation for a group
func pop_queued_animation(group: int) -> StringName:
	for i in range(_animation_queue.size()):
		if _animation_queue[i]["group"] == group:
			var anim: Dictionary = _animation_queue[i]
			_animation_queue.remove_at(i)
			return anim["name"]
	return &""


## Clear animation queue
func clear_queue() -> void:
	_animation_queue.clear()


## Update animation times (call each frame)
func update(delta: float) -> void:
	for i in AnimGroup.size():
		if _group_animations[i]["priority"] >= 0:
			_group_animations[i]["time"] += delta


## Get combined state of all active animations
func get_active_animations() -> Array[StringName]:
	var result: Array[StringName] = []
	for group: Dictionary in _group_animations:
		var name: StringName = group.get("name", &"")
		if not name.is_empty():
			result.append(name)
	return result


## Check if any animation is playing
func is_playing() -> bool:
	for group: Dictionary in _group_animations:
		if group.get("priority", -1) >= 0:
			return true
	return false


## Check if a specific group is playing
func is_group_playing(group: int) -> bool:
	if group < 0 or group >= _group_animations.size():
		return false
	return _group_animations[group].get("priority", -1) >= 0


## Get debug info
func get_debug_info() -> String:
	var info := "AnimationPriority State:\n"
	for i in AnimGroup.size():
		var group: Dictionary = _group_animations[i]
		var group_name := _get_group_name(i)
		if group.get("priority", -1) >= 0:
			info += "  %s: %s (prio %d, time %.2f)\n" % [
				group_name, group["name"], group["priority"], group["time"]
			]
		else:
			info += "  %s: (empty)\n" % group_name

	if not _animation_queue.is_empty():
		info += "Queue:\n"
		for queued: Dictionary in _animation_queue:
			info += "  - %s (prio %d)\n" % [queued["name"], queued["priority"]]

	return info


## Get group name for debugging
func _get_group_name(group: int) -> String:
	match group:
		AnimGroup.LOWER_BODY: return "LOWER_BODY"
		AnimGroup.UPPER_BODY: return "UPPER_BODY"
		AnimGroup.LEFT_ARM: return "LEFT_ARM"
		AnimGroup.RIGHT_ARM: return "RIGHT_ARM"
		AnimGroup.HEAD: return "HEAD"
		AnimGroup.FULL_BODY: return "FULL_BODY"
		_: return "UNKNOWN"
