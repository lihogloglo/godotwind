## Diagnostic: does Godot 4.6 still call `_physics_process` on a frozen RigidBody3D?
##
## Used to validate the assumption in `docs/INTERACTION_SYSTEM.md` §6.4 that
## `BuoyancyBody3D` can early-out cheaply when the body is frozen.
##
## Run: godot --headless --path . res://tests/diagnostic/frozen_rb_tick_check.tscn
## Expected output (one of):
##   "FROZEN_TICKS=N" (N > 0) — frozen bodies DO tick, early-out guard required
##   "FROZEN_TICKS=0"          — frozen bodies skipped by engine, no guard needed
extends Node


class TickCounter:
	extends RigidBody3D
	var frozen_tick_count: int = 0
	var unfrozen_tick_count: int = 0

	func _physics_process(_delta: float) -> void:
		if freeze:
			frozen_tick_count += 1
		else:
			unfrozen_tick_count += 1


var _counter: TickCounter
var _frames: int = 0


func _ready() -> void:
	_counter = TickCounter.new()
	_counter.freeze = true
	_counter.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	_counter.add_child(shape)
	add_child(_counter)
	print("[diag] frozen RB created, freeze=", _counter.freeze)


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _frames == 60:
		print("[diag] FROZEN_TICKS=", _counter.frozen_tick_count, " over ", _frames, " physics frames")
		print("[diag] UNFROZEN_TICKS=", _counter.unfrozen_tick_count)
		# Now unfreeze and confirm the counter works
		_counter.freeze = false
	if _frames == 120:
		print("[diag] AFTER_UNFREEZE FROZEN=", _counter.frozen_tick_count, " UNFROZEN=", _counter.unfrozen_tick_count)
		get_tree().quit()
