## BookViewer — Displays books and scrolls
##
## Usage:
##   var viewer := BookViewer.new()
##   add_child(viewer)
##   viewer.show_book("Book Title", "<html>text</html>")
##   viewer.closed.connect(_on_book_closed)
##
## Renders HTML-tagged book text as formatted BBCode in a RichTextLabel.
## Images from <IMG SRC="..."> are resolved by the TextFormatter image callback
## (injected by the game-specific adapter at boot, e.g. MWTextFormatter.setup()).
class_name BookViewer
extends CanvasLayer

const TextFormatterScript := preload("res://src/core/ui/text_formatter.gd")
const DEFAULT_THEME := preload("res://assets/ui/themes/default_theme.tres")

signal closed

var _panel: PanelContainer
var _overlay: ColorRect
var _title_label: Label
var _text_display: RichTextLabel
var _close_button: Button
var _scroll_container: ScrollContainer


func _ready() -> void:
	layer = 90
	_build_ui()
	hide_book()


func _unhandled_input(event: InputEvent) -> void:
	if not _panel.visible:
		return
	# Escape OR the interact action (E) close the book — toggling with the
	# same key the player used to open it.
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("interact"):
		hide_book()
		get_viewport().set_input_as_handled()


## Show a book with the given title and HTML-tagged text.
## The caller (game-specific adapter) is responsible for resolving the book
## data from whatever source it uses — this panel just renders what it gets.
func show_book(title: String, text: String) -> void:
	_title_label.text = title

	# Format the text
	var formatted := TextFormatterScript.to_formatted_text(text)

	# Clear and set BBCode
	_text_display.clear()

	if formatted.images.is_empty():
		# Simple path: no images, just set BBCode
		_text_display.append_text(formatted.bbcode)
	else:
		# Complex path: split on image placeholders, insert images programmatically
		_render_with_images(formatted)

	_panel.visible = true
	_overlay.visible = true
	_text_display.scroll_to_line(0)


## Hide the book viewer
func hide_book() -> void:
	_panel.visible = false
	if _overlay != null:
		_overlay.visible = false
	closed.emit()


## Is a book currently being displayed?
func is_open() -> bool:
	return _panel != null and _panel.visible


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
	# Full-screen dimming overlay. Stored as a member so hide_book() can
	# toggle its visibility — without this, the overlay's MOUSE_FILTER_STOP
	# eats player mouse-look input even while the panel is hidden.
	_overlay = ColorRect.new()
	_overlay.color = Color(0, 0, 0, 0.6)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)

	# Center panel — parchment book (theme provides bg/border/padding/font)
	_panel = PanelContainer.new()
	_panel.theme = DEFAULT_THEME
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(700, 500)
	_panel.size = Vector2(700, 500)
	_panel.position = Vector2(-350, -250)  # Center it
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
	_title_label.theme_type_variation = "TitleLabel"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_bar.add_child(_title_label)

	_close_button = Button.new()
	_close_button.text = "✕"
	_close_button.flat = true
	_close_button.theme_type_variation = "CloseButton"
	_close_button.pressed.connect(hide_book)
	title_bar.add_child(_close_button)

	# Separator line
	var separator := HSeparator.new()
	separator.theme_type_variation = "ParchmentSeparator"
	separator.add_theme_constant_override("separation", 2)
	vbox.add_child(separator)

	# Scrollable text area (theme provides font_size, default color, empty background)
	_text_display = RichTextLabel.new()
	_text_display.bbcode_enabled = true
	_text_display.fit_content = false
	_text_display.scroll_active = true
	_text_display.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_text_display)
