## test_input_phase_K0.gd — K.0 acceptance scene
##
## Visual test for the K.0 input action layer. Shows live state of every
## required action so a user can press each key/button and verify it lights up.
##
## ACCEPTANCE CRITERIA (manual, AZERTY user):
##   1. Press W (physical position, labelled Z on AZERTY) → move_forward fires
##   2. Press A (physical position, labelled Q on AZERTY) → move_left fires
##   3. Press S → move_backward fires
##   4. Press D → move_right fires
##   5. Press SPACE → jump fires
##   6. Press C and CTRL → crouch fires (both bindings)
##   7. Press SHIFT → sprint fires
##   8. Press TAB → toggle_camera fires; hold TAB → vanity in PlayerController
##   9. Press RS click on controller → camera_vanity fires
##  10. Press E → interact fires
##  11. Press the ²/` key (KEY_QUOTELEFT physical position) → debug_console fires
##  12. Press F1 → debug_console fires (fallback)
##  13. Press F2 → debug_screenshot fires
##  14. Plug in a controller → look_* axes light up when right stick moves
##
## Auto self-test: calls InputActions.verify() in _ready and asserts all
## REQUIRED_ACTIONS exist. Logs result via Log autoload.
extends Node3D

const InputActionsScript := preload("res://src/core/input/input_actions.gd")

var _label: Label = null


func _ready() -> void:
	Log.set_category_level("input", Log.Level.DEBUG)

	# Auto self-test: verify every required action exists in InputMap
	InputActionsScript.verify()
	Log.info("input", "test_input_phase_K0: self-test PASS — %d actions verified" % InputActionsScript.REQUIRED_ACTIONS.size())

	# Build the visual UI
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.modulate = Color(1, 1, 1, 0.9)
	canvas.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 14)
	_label.text = "K.0 input test — initializing..."
	margin.add_child(_label)


func _process(_delta: float) -> void:
	if _label == null:
		return

	var lines: Array[String] = []
	lines.append("[K.0 INPUT TEST] press keys/buttons — values should light up")
	lines.append("AZERTY users: WASD = physical positions (labelled ZQSD)")
	lines.append("")
	lines.append("--- MOVEMENT ---")
	lines.append("move_forward      : %s" % _state(&"move_forward"))
	lines.append("move_backward     : %s" % _state(&"move_backward"))
	lines.append("move_left         : %s" % _state(&"move_left"))
	lines.append("move_right        : %s" % _state(&"move_right"))
	lines.append("move_vec (x,y)    : %s" % str(Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward").snappedf(0.01)))
	lines.append("jump              : %s" % _state(&"jump"))
	lines.append("crouch            : %s   (C or CTRL)" % _state(&"crouch"))
	lines.append("sprint            : %s   (SHIFT)" % _state(&"sprint"))
	lines.append("walk              : %s   (unbound by default)" % _state(&"walk"))
	lines.append("")
	lines.append("--- CAMERA (gamepad right stick) ---")
	lines.append("look_left         : %s" % _state(&"look_left"))
	lines.append("look_right        : %s" % _state(&"look_right"))
	lines.append("look_up           : %s" % _state(&"look_up"))
	lines.append("look_down         : %s" % _state(&"look_down"))
	lines.append("look_vec (x,y)    : %s" % str(Input.get_vector(&"look_left", &"look_right", &"look_up", &"look_down").snappedf(0.01)))
	lines.append("toggle_camera     : %s   (TAB tap/hold)" % _state(&"toggle_camera"))
	lines.append("camera_vanity     : %s   (RS click)" % _state(&"camera_vanity"))
	lines.append("")
	lines.append("--- INTERACTION (owned by PlayerController) ---")
	lines.append("interact          : %s   (E — read-only display)" % _state(&"interact"))
	lines.append("")
	lines.append("--- DEBUG ---")
	lines.append("debug_console     : %s   (² / ` / F1)" % _state(&"debug_console"))
	lines.append("debug_screenshot  : %s   (F2)" % _state(&"debug_screenshot"))
	lines.append("")
	lines.append("--- NOTE ---")
	lines.append("mouse motion is NOT a bindable action. PlayerController._input")
	lines.append("handles mouse look directly via InputEventMouseMotion events.")

	_label.text = "\n".join(lines)


func _state(action: StringName) -> String:
	if not InputMap.has_action(action):
		return "[MISSING]"
	var pressed := Input.is_action_pressed(action)
	var strength := Input.get_action_strength(action)
	if pressed:
		return "PRESSED  (strength=%.2f)" % strength
	return "—"
