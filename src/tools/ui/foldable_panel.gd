## FoldablePanel - A collapsible/foldable UI panel container
##
## Usage:
##   var panel := FoldablePanel.new("Section Title")
##   panel.add_content(some_control)
##   parent.add_child(panel)
##
## Features:
## - Click header to collapse/expand
## - Optional icon indicator (▼/▶)
## - Remembers fold state
## - Emits signal on fold state change
class_name FoldablePanel
extends VBoxContainer

signal folded_changed(is_folded: bool)

## The header button
var _header_btn: Button
## Container for content (hidden when folded)
var _content_container: VBoxContainer
## Whether panel is currently folded
var _is_folded: bool = false
## Title text
var _title: String = ""
## Optional icon for expanded state
var _icon_expanded: String = "▼"
## Optional icon for collapsed state
var _icon_collapsed: String = "▶"

## Style settings
var header_font_size: int = 13
var header_color: Color = Color(0.85, 0.85, 0.85)
var header_bg_color: Color = Color(0.2, 0.22, 0.25, 0.8)
var content_indent: int = 8


func _init(title: String = "Panel", start_folded: bool = false) -> void:
	_title = title
	_is_folded = start_folded

	# Setup layout
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 2)

	# Create header button
	_header_btn = Button.new()
	_header_btn.flat = true
	_header_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header_btn.add_theme_font_size_override("font_size", header_font_size)
	_header_btn.add_theme_color_override("font_color", header_color)
	_header_btn.pressed.connect(_on_header_pressed)
	_header_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_update_header_text()
	add_child(_header_btn)

	# Create content container
	_content_container = VBoxContainer.new()
	_content_container.add_theme_constant_override("separation", 4)
	_content_container.visible = not _is_folded
	add_child(_content_container)

	# Add left margin for content
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", content_indent)
	# We'll wrap content in this later if needed


## Update header text with fold icon
func _update_header_text() -> void:
	var icon := _icon_collapsed if _is_folded else _icon_expanded
	_header_btn.text = "%s %s" % [icon, _title]


## Handle header click
func _on_header_pressed() -> void:
	set_folded(not _is_folded)


## Set folded state
func set_folded(folded: bool) -> void:
	if _is_folded == folded:
		return
	_is_folded = folded
	_content_container.visible = not _is_folded
	_update_header_text()
	folded_changed.emit(_is_folded)


## Get folded state
func is_folded() -> bool:
	return _is_folded


## Toggle fold state
func toggle() -> void:
	set_folded(not _is_folded)


## Add content to the panel
func add_content(control: Control) -> void:
	_content_container.add_child(control)


## Remove content from the panel
func remove_content(control: Control) -> void:
	if control.get_parent() == _content_container:
		_content_container.remove_child(control)


## Get the content container for direct manipulation
func get_content_container() -> VBoxContainer:
	return _content_container


## Clear all content
func clear_content() -> void:
	for child in _content_container.get_children():
		child.queue_free()


## Set title
func set_title(title: String) -> void:
	_title = title
	_update_header_text()


## Get title
func get_title() -> String:
	return _title


## Set fold icons
func set_icons(expanded: String, collapsed: String) -> void:
	_icon_expanded = expanded
	_icon_collapsed = collapsed
	_update_header_text()


## Create a labeled row with a control
static func create_row(label_text: String, control: Control, label_width: int = 80) -> HBoxContainer:
	var row := HBoxContainer.new()

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = label_width
	label.add_theme_font_size_override("font_size", 11)
	row.add_child(label)

	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)

	return row


## Create a checkbox row
static func create_checkbox_row(label_text: String, initial_value: bool, callback: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()

	var checkbox := CheckBox.new()
	checkbox.text = label_text
	checkbox.button_pressed = initial_value
	checkbox.toggled.connect(callback)
	row.add_child(checkbox)

	return row


## Create a slider row with value label
static func create_slider_row(label_text: String, min_val: float, max_val: float,
							   initial: float, callback: Callable, label_width: int = 60) -> Dictionary:
	var row := HBoxContainer.new()

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = label_width
	label.add_theme_font_size_override("font_size", 11)
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.value = initial
	slider.step = 0.1 if (max_val - min_val) <= 10 else 1.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.x = 100
	row.add_child(slider)

	var value_label := Label.new()
	value_label.name = "Value"
	value_label.text = "%.1f" % initial
	value_label.custom_minimum_size.x = 40
	value_label.add_theme_font_size_override("font_size", 11)
	row.add_child(value_label)

	# Connect with value label update
	slider.value_changed.connect(func(val: float) -> void:
		value_label.text = "%.1f" % val
		callback.call(val)
	)

	return {
		"row": row,
		"slider": slider,
		"value_label": value_label
	}


## Create a dropdown row
static func create_dropdown_row(label_text: String, options: Array[String],
								 initial_index: int, callback: Callable, label_width: int = 60) -> Dictionary:
	var row := HBoxContainer.new()

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = label_width
	label.add_theme_font_size_override("font_size", 11)
	row.add_child(label)

	var dropdown := OptionButton.new()
	for i in options.size():
		dropdown.add_item(options[i], i)
	dropdown.selected = initial_index
	dropdown.item_selected.connect(callback)
	dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(dropdown)

	return {
		"row": row,
		"dropdown": dropdown
	}


## Create a button row
static func create_button_row(buttons: Array[Dictionary]) -> HBoxContainer:
	# buttons: [{"text": "Button", "callback": callable, "tooltip": "tip"}, ...]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	for btn_data: Dictionary in buttons:
		var btn := Button.new()
		btn.text = btn_data.get("text", "Button")
		if btn_data.has("callback"):
			btn.pressed.connect(btn_data["callback"])
		if btn_data.has("tooltip"):
			btn.tooltip_text = btn_data["tooltip"]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(btn)

	return row