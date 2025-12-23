## Console UI - Visual interface for the developer console
##
## Creates and manages the console overlay UI including:
## - Output area with scrolling and syntax highlighting
## - Input line with autocomplete suggestions
## - Selection info panel (when object is selected)
##
## Position: Top-left overlay (Quake/Bethesda style)
class_name ConsoleUI
extends CanvasLayer


#region Signals

## Emitted when a command is submitted
signal command_submitted(command: String)

## Emitted when console visibility changes
signal console_visibility_changed(is_visible: bool)

## Emitted when autocomplete suggestions are requested
signal autocomplete_requested(text: String)

#endregion


#region Constants

const DEFAULT_HEIGHT_RATIO := 0.4  # 40% of screen height
const MIN_HEIGHT := 200.0
const MAX_HEIGHT_RATIO := 0.8

const COLORS := {
	"background": Color(0.05, 0.05, 0.08, 0.95),
	"input_bg": Color(0.08, 0.08, 0.12, 1.0),
	"text": Color(0.9, 0.9, 0.9, 1.0),
	"text_dim": Color(0.6, 0.6, 0.6, 1.0),
	"command": Color(0.4, 0.8, 1.0, 1.0),  # Cyan
	"success": Color(0.4, 1.0, 0.4, 1.0),  # Green
	"warning": Color(1.0, 0.8, 0.3, 1.0),  # Yellow
	"error": Color(1.0, 0.4, 0.4, 1.0),    # Red
	"selection": Color(1.0, 0.7, 0.0, 1.0), # Golden
	"string": Color(0.6, 1.0, 0.6, 1.0),   # Light green
	"number": Color(1.0, 0.8, 0.5, 1.0),   # Orange
	"border": Color(0.3, 0.3, 0.4, 1.0),
}

#endregion


#region UI Elements

var panel: PanelContainer
var vbox: VBoxContainer
var output_scroll: ScrollContainer
var output_text: RichTextLabel
var input_container: HBoxContainer
var prompt_label: Label
var input_line: LineEdit
var suggestion_panel: PanelContainer
var suggestion_list: ItemList
var selection_panel: PanelContainer
var selection_label: RichTextLabel

#endregion


#region State

var _visible: bool = false
var _height_ratio: float = DEFAULT_HEIGHT_RATIO
var _command_history: PackedStringArray = []
var _history_index: int = -1
var _current_input: String = ""  # Saved input when browsing history

## Autocomplete state
var _suggestions: Array[Dictionary] = []  # [{name, description, aliases}]
var _suggestion_index: int = 0
var _autocomplete_timer: Timer = null
var _last_input_for_suggestions: String = ""

#endregion


func _ready() -> void:
	layer = 100  # High layer to render on top
	_build_ui()
	_connect_signals()
	_setup_autocomplete_timer()
	hide_console()


## Setup debounce timer for autocomplete
func _setup_autocomplete_timer() -> void:
	_autocomplete_timer = Timer.new()
	_autocomplete_timer.one_shot = true
	_autocomplete_timer.wait_time = 0.15  # 150ms debounce
	_autocomplete_timer.timeout.connect(_request_suggestions)
	add_child(_autocomplete_timer)


func _input(event: InputEvent) -> void:
	if not _visible:
		return

	# Handle input when console is visible
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				if suggestion_panel.visible:
					hide_suggestions()
				else:
					hide_console()
				get_viewport().set_input_as_handled()

			KEY_UP:
				if suggestion_panel.visible and not _suggestions.is_empty():
					_select_suggestion(_suggestion_index - 1)
				else:
					_history_previous()
				get_viewport().set_input_as_handled()

			KEY_DOWN:
				if suggestion_panel.visible and not _suggestions.is_empty():
					_select_suggestion(_suggestion_index + 1)
				else:
					_history_next()
				get_viewport().set_input_as_handled()

			KEY_TAB:
				_do_autocomplete()
				get_viewport().set_input_as_handled()

			KEY_ENTER, KEY_KP_ENTER:
				# If suggestions visible and one is selected, complete it
				if suggestion_panel.visible and not _suggestions.is_empty():
					_apply_suggestion(_suggestion_index)
					get_viewport().set_input_as_handled()
				# Otherwise let it submit normally

			KEY_PAGEUP:
				_scroll_output(-200)
				get_viewport().set_input_as_handled()

			KEY_PAGEDOWN:
				_scroll_output(200)
				get_viewport().set_input_as_handled()


## Build the console UI programmatically
func _build_ui() -> void:
	# Main panel container
	panel = PanelContainer.new()
	panel.name = "ConsolePanel"
	panel.visible = false  # Hidden by default

	# Style the panel
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = COLORS.background
	panel_style.border_color = COLORS.border
	panel_style.border_width_bottom = 2
	panel_style.corner_radius_bottom_left = 4
	panel_style.corner_radius_bottom_right = 4
	panel.add_theme_stylebox_override("panel", panel_style)

	add_child(panel)

	# Vertical layout
	vbox = VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	# Header
	var header := _create_header()
	vbox.add_child(header)

	# Output area (scrollable)
	output_scroll = ScrollContainer.new()
	output_scroll.name = "OutputScroll"
	output_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	output_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(output_scroll)

	output_text = RichTextLabel.new()
	output_text.name = "OutputText"
	output_text.bbcode_enabled = true
	output_text.scroll_following = true
	output_text.selection_enabled = true
	output_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	output_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	output_text.fit_content = true
	output_text.add_theme_color_override("default_color", COLORS.text)

	# Use monospace font
	var font := SystemFont.new()
	font.font_names = ["JetBrains Mono", "Fira Code", "Consolas", "Monaco", "monospace"]
	output_text.add_theme_font_override("normal_font", font)
	output_text.add_theme_font_override("bold_font", font)
	output_text.add_theme_font_override("mono_font", font)
	output_text.add_theme_font_size_override("normal_font_size", 14)
	output_text.add_theme_font_size_override("bold_font_size", 14)
	output_text.add_theme_font_size_override("mono_font_size", 14)

	output_scroll.add_child(output_text)

	# Selection info panel (hidden by default)
	selection_panel = _create_selection_panel()
	vbox.add_child(selection_panel)
	selection_panel.visible = false

	# Suggestion panel (hidden by default)
	suggestion_panel = _create_suggestion_panel()
	vbox.add_child(suggestion_panel)
	suggestion_panel.visible = false

	# Input line
	input_container = _create_input_area()
	vbox.add_child(input_container)

	# Initial layout
	_update_layout()


## Create header bar
func _create_header() -> Control:
	var header := HBoxContainer.new()
	header.name = "Header"

	var title := Label.new()
	title.text = "Console"
	title.add_theme_color_override("font_color", COLORS.text_dim)
	header.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	var help_hint := Label.new()
	help_hint.text = "~ toggle | ESC close | TAB complete | ↑↓ history"
	help_hint.add_theme_color_override("font_color", COLORS.text_dim)
	help_hint.add_theme_font_size_override("font_size", 11)
	header.add_child(help_hint)

	return header


## Create input area with prompt and line edit
func _create_input_area() -> HBoxContainer:
	var container := HBoxContainer.new()
	container.name = "InputContainer"

	# Style the container
	var input_style := StyleBoxFlat.new()
	input_style.bg_color = COLORS.input_bg
	input_style.content_margin_left = 8
	input_style.content_margin_right = 8
	input_style.content_margin_top = 4
	input_style.content_margin_bottom = 4

	var input_panel := PanelContainer.new()
	input_panel.add_theme_stylebox_override("panel", input_style)
	input_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var inner_hbox := HBoxContainer.new()
	input_panel.add_child(inner_hbox)

	prompt_label = Label.new()
	prompt_label.text = "> "
	prompt_label.add_theme_color_override("font_color", COLORS.command)
	inner_hbox.add_child(prompt_label)

	input_line = LineEdit.new()
	input_line.name = "InputLine"
	input_line.placeholder_text = "Type a command..."
	input_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_line.flat = true
	input_line.add_theme_color_override("font_color", COLORS.text)
	input_line.add_theme_color_override("font_placeholder_color", COLORS.text_dim)
	input_line.caret_blink = true

	# Remove background
	var empty_style := StyleBoxEmpty.new()
	input_line.add_theme_stylebox_override("normal", empty_style)
	input_line.add_theme_stylebox_override("focus", empty_style)

	inner_hbox.add_child(input_line)

	container.add_child(input_panel)
	return container


## Create suggestion popup panel
func _create_suggestion_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "SuggestionPanel"
	panel.custom_minimum_size.y = 80
	panel.custom_minimum_size.x = 400

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.12, 0.98)
	style.border_color = COLORS.command
	style.border_width_top = 2
	style.border_width_bottom = 0
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	panel.add_theme_stylebox_override("panel", style)

	suggestion_list = ItemList.new()
	suggestion_list.name = "SuggestionList"
	suggestion_list.max_columns = 1
	suggestion_list.same_column_width = true
	suggestion_list.auto_height = true
	suggestion_list.max_text_lines = 1
	suggestion_list.add_theme_color_override("font_color", COLORS.text_dim)
	suggestion_list.add_theme_color_override("font_selected_color", COLORS.text)
	suggestion_list.add_theme_constant_override("v_separation", 2)

	# Use monospace font for suggestions too
	var font := SystemFont.new()
	font.font_names = ["JetBrains Mono", "Fira Code", "Consolas", "Monaco", "monospace"]
	suggestion_list.add_theme_font_override("font", font)
	suggestion_list.add_theme_font_size_override("font_size", 13)

	# Connect click to apply suggestion
	suggestion_list.item_clicked.connect(_on_suggestion_clicked)

	panel.add_child(suggestion_list)

	return panel


## Handle suggestion item click
func _on_suggestion_clicked(index: int, _at_position: Vector2, _mouse_button_index: int) -> void:
	_apply_suggestion(index)
	input_line.grab_focus()


## Create selection info panel
func _create_selection_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "SelectionPanel"
	panel.custom_minimum_size.y = 60

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.12, 0.05, 0.95)
	style.border_color = COLORS.selection
	style.border_width_left = 3
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	panel.add_theme_stylebox_override("panel", style)

	selection_label = RichTextLabel.new()
	selection_label.name = "SelectionLabel"
	selection_label.bbcode_enabled = true
	selection_label.fit_content = true
	selection_label.add_theme_color_override("default_color", COLORS.text)
	panel.add_child(selection_label)

	return panel


## Connect UI signals
func _connect_signals() -> void:
	input_line.text_submitted.connect(_on_command_submitted)
	input_line.text_changed.connect(_on_input_changed)

	get_viewport().size_changed.connect(_update_layout)


## Update layout based on viewport size
func _update_layout() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	var console_height := maxf(viewport_size.y * _height_ratio, MIN_HEIGHT)

	panel.position = Vector2.ZERO
	panel.size = Vector2(viewport_size.x, console_height)


## Show the console
func show_console() -> void:
	if _visible:
		return

	_visible = true
	panel.visible = true
	input_line.grab_focus()
	input_line.clear()
	console_visibility_changed.emit(true)


## Hide the console
func hide_console() -> void:
	if not _visible:
		return

	_visible = false
	panel.visible = false
	input_line.release_focus()
	console_visibility_changed.emit(false)


## Toggle console visibility
func toggle() -> void:
	if _visible:
		hide_console()
	else:
		show_console()


## Check if console is visible
func is_console_visible() -> bool:
	return _visible


## Print a line to the console output
func print_line(text: String) -> void:
	output_text.append_text(text + "\n")


## Print with color
func print_colored(text: String, color: Color) -> void:
	output_text.push_color(color)
	output_text.append_text(text)
	output_text.pop()
	output_text.append_text("\n")


## Print a command echo
func print_command(cmd: String) -> void:
	output_text.push_color(COLORS.command)
	output_text.append_text("> ")
	output_text.pop()
	output_text.append_text(cmd + "\n")


## Print success message
func print_success(text: String) -> void:
	print_colored(text, COLORS.success)


## Print warning message
func print_warning(text: String) -> void:
	print_colored(text, COLORS.warning)


## Print error message
func print_error(text: String) -> void:
	print_colored(text, COLORS.error)


## Clear the output
func clear_output() -> void:
	output_text.clear()


## Update selection display
func show_selection(info: String) -> void:
	if info.is_empty():
		selection_panel.visible = false
		return

	selection_label.clear()
	selection_label.append_text("[b][color=#FFB300]SELECTED[/color][/b]\n")
	selection_label.append_text(info)
	selection_panel.visible = true


## Hide selection display
func hide_selection() -> void:
	selection_panel.visible = false


## Set suggestions data (called by Console)
## Each suggestion is {name: String, description: String, aliases: PackedStringArray}
func set_suggestions(suggestions: Array[Dictionary]) -> void:
	_suggestions = suggestions
	_suggestion_index = 0
	_update_suggestion_display()


## Update the suggestion panel display
func _update_suggestion_display() -> void:
	if _suggestions.is_empty():
		suggestion_panel.visible = false
		return

	suggestion_list.clear()

	for suggestion in _suggestions:
		var name: String = suggestion.get("name", "")
		var desc: String = suggestion.get("description", "")
		var aliases: PackedStringArray = suggestion.get("aliases", PackedStringArray())

		# Format: "command - description (aliases: a, b)"
		var display := name
		if not desc.is_empty():
			display += "  -  " + desc
		if not aliases.is_empty():
			display += "  (" + ", ".join(aliases) + ")"

		suggestion_list.add_item(display)

	if suggestion_list.item_count > 0:
		suggestion_list.select(_suggestion_index)

	suggestion_panel.visible = true


## Show autocomplete suggestions (simple string array version for compatibility)
func show_suggestions(suggestions: Array[String]) -> void:
	var dict_suggestions: Array[Dictionary] = []
	for s in suggestions:
		dict_suggestions.append({"name": s, "description": "", "aliases": PackedStringArray()})
	set_suggestions(dict_suggestions)


## Hide suggestions
func hide_suggestions() -> void:
	suggestion_panel.visible = false
	_suggestions.clear()
	_suggestion_index = 0


## Handle command submission
func _on_command_submitted(text: String) -> void:
	var cmd := text.strip_edges()
	if cmd.is_empty():
		return

	# Echo command
	print_command(cmd)

	# Add to history
	if _command_history.is_empty() or _command_history[-1] != cmd:
		_command_history.append(cmd)

	_history_index = -1
	_current_input = ""

	# Clear input
	input_line.clear()

	# Hide suggestions
	hide_suggestions()

	# Emit signal for command processing
	command_submitted.emit(cmd)


## Handle input text changed
func _on_input_changed(new_text: String) -> void:
	# Trigger autocomplete with debounce
	if new_text.strip_edges().is_empty():
		hide_suggestions()
		return

	# Start/restart the debounce timer
	if _autocomplete_timer:
		_autocomplete_timer.start()


## Request suggestions from the console (called after debounce)
func _request_suggestions() -> void:
	var text := input_line.text.strip_edges()
	if text.is_empty():
		hide_suggestions()
		return

	_last_input_for_suggestions = text
	autocomplete_requested.emit(text)


## Navigate to previous command in history
func _history_previous() -> void:
	if _command_history.is_empty():
		return

	if _history_index == -1:
		_current_input = input_line.text
		_history_index = _command_history.size() - 1
	elif _history_index > 0:
		_history_index -= 1

	input_line.text = _command_history[_history_index]
	input_line.caret_column = input_line.text.length()


## Navigate to next command in history
func _history_next() -> void:
	if _history_index == -1:
		return

	_history_index += 1

	if _history_index >= _command_history.size():
		_history_index = -1
		input_line.text = _current_input
	else:
		input_line.text = _command_history[_history_index]

	input_line.caret_column = input_line.text.length()


## Handle Tab key for autocomplete
func _do_autocomplete() -> void:
	if _suggestions.is_empty():
		# No suggestions yet, request them immediately
		var text := input_line.text.strip_edges()
		if not text.is_empty():
			autocomplete_requested.emit(text)
		return

	if suggestion_panel.visible:
		# Apply current selection
		_apply_suggestion(_suggestion_index)
	else:
		# Show suggestions
		_update_suggestion_display()


## Select a suggestion by index
func _select_suggestion(index: int) -> void:
	if _suggestions.is_empty():
		return

	# Wrap around
	_suggestion_index = index % _suggestions.size()
	if _suggestion_index < 0:
		_suggestion_index = _suggestions.size() + _suggestion_index

	# Update visual selection
	if suggestion_list.item_count > 0:
		suggestion_list.select(_suggestion_index)
		suggestion_list.ensure_current_is_visible()


## Apply a suggestion to the input
func _apply_suggestion(index: int) -> void:
	if index < 0 or index >= _suggestions.size():
		return

	var suggestion: Dictionary = _suggestions[index]
	var cmd_name: String = suggestion.get("name", "")

	if cmd_name.is_empty():
		return

	# Get current input to preserve any arguments after the command
	var current := input_line.text.strip_edges()
	var parts := current.split(" ", false, 1)

	if parts.size() > 1:
		# Keep arguments
		input_line.text = cmd_name + " " + parts[1]
	else:
		# Just the command, add space for convenience
		input_line.text = cmd_name + " "

	input_line.caret_column = input_line.text.length()
	hide_suggestions()


## Scroll the output area
func _scroll_output(amount: int) -> void:
	output_scroll.scroll_vertical += amount


## Get current input text
func get_input_text() -> String:
	return input_line.text


## Set input text
func set_input_text(text: String) -> void:
	input_line.text = text
	input_line.caret_column = text.length()
