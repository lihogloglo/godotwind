## SceneLoadingScreen — full-screen overlay shown while SceneTree.paused = true.
##
## Canonical-Godot pattern pairing with LoadingStateMachine (see
## docs/audit/LOADING_STATE_MACHINE_DESIGN.md). The overlay itself has
## `process_mode = PROCESS_MODE_ALWAYS` so fade tweens + progress label
## updates keep ticking while gameplay nodes are frozen by the tree pause.
##
## NOT a generic UI widget — it owns the fade-to-black ColorRect + a title
## label + a progress label. The caller (LoadingStateMachine) drives the
## visible state via show_with_fade/hide_with_fade + set_progress/set_title.
##
## Named `SceneLoadingScreen` because `LoadingScreen` is already taken by
## `src/core/ui/loading_screen.gd` — that one is a generic progress-bar
## widget used by test scenes during BSA/ESM data load. Different
## scope, different API, no reuse.
class_name SceneLoadingScreen
extends CanvasLayer

## Fade duration (s). 0.5 s matches OpenMW's exterior-teleport fade
## (see inspos/openmw/apps/openmw/mwworld/scene.cpp:936) — long enough to
## read as a transition, short enough to not feel sluggish on cold boot.
const FADE_DURATION: float = 0.5

## z-ordering — must beat the existing in-game UI (stats panel,
## benchmark HUD, etc). Higher = on top.
const LAYER: int = 1000

#region State
var _bg: ColorRect = null
var _title_label: Label = null
var _progress_label: Label = null
var _subtitle_label: Label = null
var _active_tween: Tween = null
var _visible: bool = false
#endregion


func _init() -> void:
	layer = LAYER
	# CRITICAL: the overlay must keep processing while the tree is paused.
	# Without this the fade tween freezes the instant get_tree().paused = true
	# (which is literally one frame after show_with_fade begins) and the
	# screen never fully darkens.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	_build_ui()
	# CanvasLayer doesn't have a modulate property — we fade the
	# underlying ColorRect's modulate instead, which cascades to its
	# label children. Same visual effect, different property target.
	if _bg:
		_bg.modulate.a = 0.0
	visible = false


## Construct the ColorRect + label hierarchy. All nodes PROCESS_MODE_ALWAYS
## so label text updates also tick during pause.
func _build_ui() -> void:
	_bg = ColorRect.new()
	_bg.color = Color(0.0, 0.0, 0.0, 1.0)
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_bg.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_bg)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vbox.custom_minimum_size = Vector2(600, 120)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	# Use the preset's center anchor, but pull the node up by half its min
	# height so it sits visually centred on screen. Preset anchors alone
	# would hang the top-left of the vbox at the center, not its center.
	vbox.offset_left = -300
	vbox.offset_top = -60
	vbox.offset_right = 300
	vbox.offset_bottom = 60
	vbox.process_mode = Node.PROCESS_MODE_ALWAYS
	_bg.add_child(vbox)

	_title_label = Label.new()
	_title_label.text = "Loading"
	_title_label.add_theme_font_size_override("font_size", 32)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.process_mode = Node.PROCESS_MODE_ALWAYS
	vbox.add_child(_title_label)

	_subtitle_label = Label.new()
	_subtitle_label.text = ""
	_subtitle_label.add_theme_font_size_override("font_size", 16)
	_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle_label.modulate = Color(0.7, 0.7, 0.7, 1.0)
	_subtitle_label.process_mode = Node.PROCESS_MODE_ALWAYS
	vbox.add_child(_subtitle_label)

	_progress_label = Label.new()
	_progress_label.text = ""
	_progress_label.add_theme_font_size_override("font_size", 14)
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_progress_label.modulate = Color(0.85, 0.85, 0.85, 1.0)
	_progress_label.process_mode = Node.PROCESS_MODE_ALWAYS
	vbox.add_child(_progress_label)


## Fade to opaque over FADE_DURATION. Caller can await
## get_tree().create_timer(FADE_DURATION) before pausing the tree.
func show_with_fade() -> void:
	if _visible or not _bg:
		return
	_visible = true
	visible = true
	_bg.modulate.a = clampf(_bg.modulate.a, 0.0, 1.0)
	_kill_active_tween()
	_active_tween = create_tween()
	# Tween must tick during pause — matches this node's PROCESS_MODE_ALWAYS.
	_active_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_active_tween.tween_property(_bg, "modulate:a", 1.0, FADE_DURATION)


## Fade to transparent over FADE_DURATION and hide the node entirely
## afterwards so it doesn't eat input from the now-interactive world.
func hide_with_fade() -> void:
	if not _visible or not _bg:
		return
	_visible = false
	_kill_active_tween()
	_active_tween = create_tween()
	_active_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_active_tween.tween_property(_bg, "modulate:a", 0.0, FADE_DURATION)
	_active_tween.tween_callback(func() -> void: visible = false)


func set_title(text: String) -> void:
	if _title_label:
		_title_label.text = text


func set_subtitle(text: String) -> void:
	if _subtitle_label:
		_subtitle_label.text = text


## Free-form progress label. Caller writes whatever makes sense —
## "Loading cells 5/9" or "Elapsed 12.3s / budget 30.0s".
func set_progress(text: String) -> void:
	if _progress_label:
		_progress_label.text = text


func is_currently_visible() -> bool:
	return _visible


func _kill_active_tween() -> void:
	if _active_tween and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null
