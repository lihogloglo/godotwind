## ConsecutiveAttack — Combo that triggers when a specific action is in input
##
## Example: attach to Attack1 with primary_input="longsword_2" to chain
## into Attack2 when the player presses attack during the queueing window.
class_name ConsecutiveAttack
extends Combo

@export var primary_input: StringName = &""


func is_triggered(input: InputPackage) -> bool:
	return input.actions.has(primary_input)
