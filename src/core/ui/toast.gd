## Toast — Transient notification popup
##
## Framework UI component. Shows a brief message that fades out after a duration.
## Usage:
##   var toast := Toast.new()
##   add_child(toast)
##   toast.show_message("Your journal has been updated.")
class_name Toast
extends CanvasLayer

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
	# Panel at top-center of screen
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_panel.offset_top = 20
	_panel.offset_left = -200
	_panel.offset_right = 200

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.10, 0.08, 0.9)
	style.border_color = Color(0.6, 0.5, 0.35)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 16)
	_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7))
	_panel.add_child(_label)
