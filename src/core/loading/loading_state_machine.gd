## LoadingStateMachine — the single owner of the boot-and-teleport loading flow.
##
## Canonical Godot-4.6 pattern: flip `SceneTree.paused = true`, keep the
## streaming pipeline ticking via `PROCESS_MODE_WHEN_PAUSED` on the
## streaming manager, hold the fullscreen `LoadingScreen` overlay visible
## until a caller-supplied exit predicate returns true (or a timeout
## fires), then unpause. Mirrors OpenMW's `Loading::ScopedLoad` scope
## guard in shape — see docs/audit/LOADING_STATE_MACHINE_DESIGN.md for
## the side-by-side.
##
## Two triggers on the gameplay side today:
##   - `boot`     — cold scene load. Camera starts frozen, fade-out is a
##                  no-op (screen is already opaque at spawn).
##   - `teleport` — camera jump > 500 m (native_streaming_manager's
##                  _teleport_detected threshold). Fade out BEFORE
##                  pausing to hide the warp visually.
##
## The exit condition is opaque to this class — callers pass a Callable
## returning bool plus a label/ETA strings. We poll the predicate every
## frame, update the overlay progress text, and unpause when it returns
## true OR the timeout fires.
class_name LoadingStateMachine
extends Node

const SceneLoadingScreenScript: GDScript = preload("res://src/core/loading/loading_screen.gd")

#region Signals

## Fires when we enter the LOADING state (pause applied, overlay shown).
signal loading_started(reason: String)

## Fires when we exit (overlay faded out, tree unpaused). `timed_out` is
## true if the timeout fallback unblocked us rather than the predicate.
signal loading_finished(reason: String, duration_s: float, timed_out: bool)

#endregion


#region State

enum State { IDLE, ENTERING, LOADING, EXITING }

var _state: State = State.IDLE
var _current_reason: String = ""
var _current_predicate: Callable = Callable()
var _current_progress_fn: Callable = Callable()  # optional — returns String for overlay progress label
var _current_subtitle: String = ""
var _current_title: String = "Loading"
var _current_timeout_s: float = 30.0
var _current_pause_gameplay: bool = true
var _enter_msec: int = 0
var _screen: SceneLoadingScreenScript = null

#endregion


func _init() -> void:
	# The driver must tick during pause so it can poll the exit predicate.
	# Without PROCESS_MODE_ALWAYS _process halts the instant tree.paused
	# flips and we'd never call the predicate — deadlock.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	_screen = SceneLoadingScreenScript.new()
	_screen.name = "LoadingScreen"
	add_child(_screen)
	# Screen starts hidden — LoadingStateMachine is IDLE until the caller
	# fires enter_loading(). Cold-boot consumers (world_explorer) call
	# enter_loading with fade_in=true so the first visible frame fades
	# in from transparent; callers that want an always-opaque boot can
	# pre-set modulate.a=1 before calling.


# -----------------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------------

## Enter the LOADING state. Idempotent — a second call while already
## loading replaces the exit predicate + progress function but does NOT
## re-fire the `loading_started` signal.
##
## Parameters:
##   reason         — short tag, ends up in loading_started/_finished
##                    signals + plan telemetry. Use "boot" / "teleport".
##   exit_predicate — Callable() -> bool. Returns true when safe to
##                    unpause. Typical: streaming_manager.is_inner_ring_ready()
##   title          — headline label ("Loading the world", "Fast travel…").
##   subtitle       — optional smaller line under the title.
##   progress_fn    — optional Callable() -> String for the third line
##                    (e.g. "cells 6/9 · queue 12"). Nil = leave blank.
##   timeout_s      — force-exit after N seconds even if the predicate
##                    is still false. Default 30s matches the Phase 8
##                    design-doc agreement.
##   fade_in        — true for teleport (hide the warp). false for cold
##                    boot (screen is already opaque from _ready).
## `pause_gameplay` default true — production behaviour. Tests can flip
## it false to exercise the state machine without freezing the test
## runner itself (which is also pausable by default). Same knob is
## available to any future caller that wants "show the overlay but
## let gameplay keep running behind it" — a legitimate future use
## case (e.g. non-blocking background asset warmup).
func enter_loading(
	reason: String,
	exit_predicate: Callable,
	title: String = "Loading",
	subtitle: String = "",
	progress_fn: Callable = Callable(),
	timeout_s: float = 30.0,
	fade_in: bool = false,
	pause_gameplay: bool = true
) -> void:
	_current_reason = reason
	_current_predicate = exit_predicate
	_current_progress_fn = progress_fn
	_current_title = title
	_current_subtitle = subtitle
	_current_timeout_s = timeout_s
	_current_pause_gameplay = pause_gameplay
	if _screen:
		_screen.set_title(title)
		_screen.set_subtitle(subtitle)
		_screen.set_progress("")
	if _state == State.LOADING or _state == State.ENTERING:
		# Already loading — just update labels + predicate. No re-pause.
		return
	_enter_msec = Time.get_ticks_msec()
	_state = State.ENTERING
	if fade_in:
		# Start transparent so the fade-to-black is visible mid-warp.
		# CanvasLayer has no `modulate` — fade the underlying ColorRect
		# `_bg` which cascades alpha to its label children.
		if _screen:
			_screen.visible = true
			if _screen._bg:
				_screen._bg.modulate.a = 0.0
			_screen.show_with_fade()
		# Wait for the fade before pausing the tree — otherwise the world
		# goes still behind a still-transparent overlay and the player
		# briefly sees the teleport frozen.
		var fade_timer := get_tree().create_timer(SceneLoadingScreenScript.FADE_DURATION, true, false, true)
		fade_timer.timeout.connect(_pause_and_enter_loading)
	else:
		# Boot: overlay is already opaque from _ready(), pause immediately.
		_pause_and_enter_loading()


## Force an exit (caller aborted or is tearing down). Skips the predicate
## check. Used at shutdown; not part of the normal flow.
func force_exit() -> void:
	if _state == State.IDLE:
		return
	_exit_loading(true)


func is_loading() -> bool:
	return _state == State.LOADING or _state == State.ENTERING


func get_current_reason() -> String:
	return _current_reason


func get_loading_screen() -> SceneLoadingScreenScript:
	return _screen


# -----------------------------------------------------------------------------
# Internal transitions
# -----------------------------------------------------------------------------

func _pause_and_enter_loading() -> void:
	if _state != State.ENTERING:
		return  # force_exit beat us to it
	# Ensure overlay is opaque at the moment of pause — if a fast fade_in
	# tween is still in flight we snap it to 1.0 so nothing leaks through.
	if _screen:
		if _screen._bg:
			_screen._bg.modulate.a = 1.0
		_screen.visible = true
	if _current_pause_gameplay:
		get_tree().paused = true
	_state = State.LOADING
	loading_started.emit(_current_reason)
	Log.info("loading", "[LOADING] entered state — reason='%s', timeout=%.1fs" % [
		_current_reason, _current_timeout_s
	])


func _process(_delta: float) -> void:
	if _state != State.LOADING:
		return

	# Update overlay progress label from the user-supplied callable.
	if _current_progress_fn.is_valid() and _screen:
		var text: String = str(_current_progress_fn.call())
		_screen.set_progress(text)

	# Poll the exit predicate.
	var ready := false
	if _current_predicate.is_valid():
		var v: Variant = _current_predicate.call()
		ready = v if v is bool else false

	var elapsed_s := (Time.get_ticks_msec() - _enter_msec) / 1000.0
	if ready:
		_exit_loading(false)
		return
	if elapsed_s >= _current_timeout_s:
		Log.warn("loading", "[LOADING] timeout after %.1fs — forcing exit (reason='%s')" % [
			elapsed_s, _current_reason
		])
		_exit_loading(true)


func _exit_loading(timed_out: bool) -> void:
	if _state == State.IDLE or _state == State.EXITING:
		return
	var duration_s := (Time.get_ticks_msec() - _enter_msec) / 1000.0
	_state = State.EXITING
	if _current_pause_gameplay:
		get_tree().paused = false
	if _screen:
		_screen.hide_with_fade()
	# Fire immediately — consumers use the signal for telemetry/state-machine
	# handoffs, not for rendering. The fade-out animation runs in parallel.
	loading_finished.emit(_current_reason, duration_s, timed_out)
	Log.info("loading", "[LOADING] exited — reason='%s', duration=%.2fs, timed_out=%s" % [
		_current_reason, duration_s, timed_out
	])
	# State flips back to IDLE after the fade finishes so a new enter_loading
	# during the fade is queued correctly.
	var timer := get_tree().create_timer(SceneLoadingScreenScript.FADE_DURATION, true, false, true)
	timer.timeout.connect(_finalize_exit)


func _finalize_exit() -> void:
	_state = State.IDLE
	_current_reason = ""
	_current_predicate = Callable()
	_current_progress_fn = Callable()
