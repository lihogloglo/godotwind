## BookViewer — Displays Morrowind books and scrolls
##
## Usage:
##   var viewer := BookViewer.new()
##   add_child(viewer)
##   viewer.show_book(book_record)  # or show_book_by_id("book_id")
##   viewer.closed.connect(_on_book_closed)
##
## Renders MW book markup as formatted BBCode in a RichTextLabel.
## Images from <IMG SRC="..."> are loaded from BSA and inserted programmatically.
class_name BookViewer
extends CanvasLayer

const TextFormatterScript := preload("res://src/core/ui/text_formatter.gd")

signal closed

var _panel: PanelContainer
var _title_label: Label
var _text_display: RichTextLabel
var _close_button: Button
var _scroll_container: ScrollContainer
var _current_book: BookRecord


func _ready() -> void:
	layer = 90
	_build_ui()
	hide_book()


func _unhandled_input(event: InputEvent) -> void:
	if not _panel.visible:
		return
	if event.is_action_pressed("ui_cancel"):
		hide_book()
		get_viewport().set_input_as_handled()


## Show a book from a BookRecord
func show_book(book: BookRecord) -> void:
	if book == null:
		Log.warn("ui", "BookViewer.show_book() called with null book")
		return

	_current_book = book
	_title_label.text = book.name if not book.name.is_empty() else book.record_id

	# Format the text
	var formatted := TextFormatterScript.to_formatted_text(book.text)

	# Clear and set BBCode
	_text_display.clear()

	if formatted.images.is_empty():
		# Simple path: no images, just set BBCode
		_text_display.append_text(formatted.bbcode)
	else:
		# Complex path: split on image placeholders, insert images programmatically
		_render_with_images(formatted)

	_panel.visible = true
	_text_display.scroll_to_line(0)


## Show a book by its ESM record ID
func show_book_by_id(book_id: String) -> void:
	var book: BookRecord = ESMManager.get_book(book_id)
	if book == null:
		Log.warn("ui", "BookViewer: book '%s' not found in ESM" % book_id)
		return
	show_book(book)


## Hide the book viewer
func hide_book() -> void:
	_panel.visible = false
	_current_book = null
	closed.emit()


## Render formatted text with inline images
func _render_with_images(formatted: TextFormatterScript.FormattedText) -> void:
	var text := formatted.bbcode

	# Build a map of placeholder → texture
	var image_map: Dictionary = {}
	for img_data: Dictionary in formatted.images:
		image_map[img_data["placeholder"]] = img_data["texture"]

	# Split text on image placeholders and render segments
	var remaining := text
	for img_data: Dictionary in formatted.images:
		var placeholder: String = img_data["placeholder"]
		var split_pos := remaining.find(placeholder)
		if split_pos < 0:
			continue

		# Append text before the image
		var before := remaining.substr(0, split_pos)
		if not before.is_empty():
			_text_display.append_text(before)

		# Insert the image
		var texture: ImageTexture = img_data["texture"]
		if texture != null:
			# Scale image to fit within the text area (max 256px wide)
			var max_width := 256
			var scale_factor := 1.0
			if texture.get_width() > max_width:
				scale_factor = float(max_width) / float(texture.get_width())
			var display_width := int(texture.get_width() * scale_factor)
			var display_height := int(texture.get_height() * scale_factor)
			_text_display.add_image(texture, display_width, display_height)

		remaining = remaining.substr(split_pos + placeholder.length())

	# Append any remaining text
	if not remaining.is_empty():
		_text_display.append_text(remaining)


func _build_ui() -> void:
	# Full-screen dimming overlay
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.6)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)

	# Center panel — parchment-style book
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(700, 500)
	_panel.size = Vector2(700, 500)
	_panel.position = Vector2(-350, -250)  # Center it

	# Style the panel
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.91, 0.87, 0.78)  # Parchment
	panel_style.border_color = Color(0.45, 0.35, 0.25)
	panel_style.set_border_width_all(3)
	panel_style.set_corner_radius_all(4)
	panel_style.set_content_margin_all(20)
	_panel.add_theme_stylebox_override("panel", panel_style)
	add_child(_panel)

	# VBox layout
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_panel.add_child(vbox)

	# Title bar (HBox: title + close button)
	var title_bar := HBoxContainer.new()
	vbox.add_child(title_bar)

	_title_label = Label.new()
	_title_label.text = "Book Title"
	_title_label.add_theme_font_size_override("font_size", 22)
	_title_label.add_theme_color_override("font_color", Color(0.25, 0.15, 0.1))
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_bar.add_child(_title_label)

	_close_button = Button.new()
	_close_button.text = "✕"
	_close_button.flat = true
	_close_button.add_theme_font_size_override("font_size", 18)
	_close_button.pressed.connect(hide_book)
	title_bar.add_child(_close_button)

	# Separator line
	var separator := HSeparator.new()
	separator.add_theme_constant_override("separation", 2)
	var sep_style := StyleBoxFlat.new()
	sep_style.bg_color = Color(0.45, 0.35, 0.25, 0.5)
	sep_style.set_content_margin_all(0)
	sep_style.content_margin_top = 1
	sep_style.content_margin_bottom = 1
	separator.add_theme_stylebox_override("separator", sep_style)
	vbox.add_child(separator)

	# Scrollable text area
	_text_display = RichTextLabel.new()
	_text_display.bbcode_enabled = true
	_text_display.fit_content = false
	_text_display.scroll_active = true
	_text_display.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_display.add_theme_font_size_override("normal_font_size", 16)
	_text_display.add_theme_font_size_override("bold_font_size", 16)
	_text_display.add_theme_font_size_override("italics_font_size", 16)
	_text_display.add_theme_color_override("default_color", Color(0.15, 0.1, 0.05))
	# Transparent background (panel provides the parchment color)
	var empty_style := StyleBoxEmpty.new()
	_text_display.add_theme_stylebox_override("normal", empty_style)
	vbox.add_child(_text_display)
