## Combo — Base class for conditional move transitions
##
## Combos are child nodes of a Move. During the move's queueing window,
## combos are checked to see if they should chain into another move.
class_name Combo
extends Node

## The move to transition to when this combo triggers
@export var triggered_move: StringName = &""

## Reference to the parent Move (set by Move.assign_combos())
var move: Move = null


## Override in subclasses to define trigger conditions
func is_triggered(_input: InputPackage) -> bool:
	return false
