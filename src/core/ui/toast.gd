## Toast — Transient notification popup
##
## Framework UI component. Shows a brief message that fades out after a duration.
## Usage:
##   var toast := Toast.new()
##   add_child(toast)
##   toast.show_message("Your journal has been updated.")
class_name Toast
extends CanvasLayer

const DEFAULT_THEME := preload("res://assets/ui/themes/default_theme.tres")

var _label: Label
var _panel: PanelContainer
var _tween: Tween

const DEFAULT_DURATION := 3.0
const FADE_DURATION := 0.5


func _ready() -> void:
	layer = 95
	_build_ui()
	_panel.visible = false


## Show a toast message
func show_message(text: String, duration: float = DEFAULT_DURATION) -> void:
	_label.text = text
	_panel.visible = true
	_panel.modulate.a = 1.0

	# Cancel any existing tween
	if _tween != null and _tween.is_valid():
		_tween.kill()

	# Wait, then fade out
	_tween = create_tween()
	_tween.tween_interval(duration)
	_tween.tween_property(_panel, "modulate:a", 0.0, FADE_DURATION)
	_tween.tween_callback(_panel.set.bind("visible", false))


func _build_ui() -> void:
	# Panel at top-center of screen (Toast variation = dark bg, gold border)
	_panel = PanelContainer.new()
	_panel.theme = DEFAULT_THEME
	_panel.theme_type_variation = "Toast"
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_panel.offset_top = 20
	_panel.offset_left = -200
	_panel.offset_right = 200
	add_child(_panel)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.theme_type_variation = "ToastLabel"
	_panel.add_child(_label)
