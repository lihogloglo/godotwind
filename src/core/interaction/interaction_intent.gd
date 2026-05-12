## InteractionIntent -- shared tap/hold/release splitter for `interact`.
##
## The active input context owns raw input, then feeds press/release/poll times
## into this helper. It deliberately has no scene-tree or InputMap dependency.
class_name InteractionIntent
extends RefCounted

enum Outcome {
	NONE,
	TAP,
	HOLD_BEGIN,
	HOLD_RELEASE
}

const DEFAULT_HOLD_THRESHOLD: float = 0.20

var hold_threshold: float = DEFAULT_HOLD_THRESHOLD

var _press_time_msec: int = -1
var _hold_emitted: bool = false


func _init(p_hold_threshold: float = DEFAULT_HOLD_THRESHOLD) -> void:
	hold_threshold = maxf(p_hold_threshold, 0.0)


func press(now_msec: int) -> void:
	_press_time_msec = now_msec
	_hold_emitted = false


func release(_now_msec: int) -> int:
	if _press_time_msec < 0:
		_hold_emitted = false
		return Outcome.NONE
	_press_time_msec = -1
	if _hold_emitted:
		_hold_emitted = false
		return Outcome.HOLD_RELEASE
	_hold_emitted = false
	# Preserve the existing low-FPS behavior: a long press that never reached
	# poll() still resolves as a tap instead of silently dropping the action.
	return Outcome.TAP


func poll(now_msec: int) -> int:
	if _press_time_msec < 0 or _hold_emitted:
		return Outcome.NONE
	var held_msec: int = maxi(now_msec - _press_time_msec, 0)
	if held_msec >= get_hold_threshold_msec():
		_hold_emitted = true
		return Outcome.HOLD_BEGIN
	return Outcome.NONE


func cancel() -> void:
	_press_time_msec = -1
	_hold_emitted = false


func is_pressed() -> bool:
	return _press_time_msec >= 0


func has_hold_emitted() -> bool:
	return _hold_emitted


func get_hold_threshold_msec() -> int:
	return int(hold_threshold * 1000.0)
