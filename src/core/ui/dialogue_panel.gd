## DialogueUI — Framework dialogue panel
##
## Persistent, generic NPC conversation panel. Add one instance to your main
## scene and call `open(provider, speaker_id, context)` whenever the player
## starts talking to someone. Call `close()` (or press Escape) to end the
## conversation and fire the `closed` signal.
##
## ## Framework/adapter boundary
##
## This panel consumes a `DialogueProvider` (framework base) and speaker IDs
## as strings. Zero MW-specific imports. Any game can plug in its own
## provider implementation and this panel will render its topics and
## responses.
##
## ## Architecture
##
## - Extends CanvasLayer so it sits above the 3D world at layer 90.
## - Layout: NPC name header row (name + disposition) → response panel
##   (parchment) + topics list (dark) side-by-side → info bar at bottom.
## - Styling comes entirely from `assets/ui/themes/default_theme.tres`.
## - Topic cross-referencing: response text with `[url=topic_id]...[/url]`
##   BBCode (emitted by provider.highlight_topics_in_text) is clickable;
##   click calls back into `_on_topic_clicked`.
## - Goodbye: "Goodbye" is a synthetic topic appended to every topic list;
##   clicking it queries the provider for a farewell response (if any),
##   then calls `close()`.
##
## ## Signals
##
## - `opened(speaker_id)` — fired right before the first greeting is displayed
## - `closed(speaker_id)` — fired when the conversation ends
## - `response_selected(topic_id, response)` — fired each time the player
##   picks a topic and a response is shown. Phase B-5 hooks this to advance
##   the journal based on `response.quest_updated`.
##
## ## Usage
##
## ```gdscript
## var dialogue_ui := DialogueUI.new()
## add_child(dialogue_ui)
## var provider := MWDialogueProvider.new()
## var context := DialogueContext.new()
## # ... populate context with player state ...
## dialogue_ui.open(provider, "fargoth", context)
## ```
class_name DialogueUI
extends CanvasLayer

const TextFormatterScript := preload("res://src/core/ui/text_formatter.gd")
const DialogueContextScript := preload("res://src/core/dialogue/dialogue_context.gd")
const DEFAULT_THEME := preload("res://assets/ui/themes/default_theme.tres")


signal opened(speaker_id: String)
signal closed(speaker_id: String)
signal response_selected(topic_id: String, response: DialogueProvider.Response)


var _provider: DialogueProvider
var _context: DialogueContext
var _speaker_id: String = ""

# UI elements (built lazily in _ready)
var _root_control: Control
var _bg: ColorRect
var _npc_name_label: Label
var _disposition_label: Label
var _response_text: RichTextLabel
var _topics_container: VBoxContainer
var _info_label: Label


func _ready() -> void:
	layer = 90
	_build_ui()
	_root_control.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not _root_control.visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


## Open a conversation with the given speaker.
## Safe to call while another conversation is open — the previous one is
## closed implicitly (without firing `closed`, since it's a handoff).
func open(provider: DialogueProvider, speaker_id: String, context: DialogueContext) -> void:
	if provider == null:
		Log.warn("dialogue", "DialogueUI.open() called with null provider")
		return
	if speaker_id.is_empty():
		Log.warn("dialogue", "DialogueUI.open() called with empty speaker_id")
		return

	_provider = provider
	_context = context
	_speaker_id = speaker_id
	_root_control.visible = true
	opened.emit(speaker_id)
	_show_greeting()


## Close the current conversation. Fires `closed` signal.
func close() -> void:
	if not _root_control.visible:
		return
	_root_control.visible = false
	var speaker := _speaker_id
	_speaker_id = ""
	_provider = null
	_context = null
	closed.emit(speaker)


## Is a conversation currently open?
func is_open() -> bool:
	return _root_control.visible


func _show_greeting() -> void:
	_npc_name_label.text = _provider.get_speaker_name(_speaker_id)
	_disposition_label.text = "Disposition: %d" % _context.disposition

	var greeting: DialogueProvider.Response = _provider.get_greeting(_speaker_id, _context)

	_response_text.clear()
	if greeting.ok() and greeting.line != null:
		var line: RefCounted = greeting.line
		# Discover topics from greeting text first so highlighting knows them
		var discovered := _provider.discover_topics_in_text(line.text)
		for topic_id in discovered:
			_context.add_topic(topic_id)
		var highlighted := _provider.highlight_topics_in_text(line.text, _context.known_topics)
		_response_text.append_text(highlighted)
	else:
		match greeting.error:
			DialogueProvider.Error.SPEAKER_NOT_FOUND:
				_response_text.append_text("[color=#cc6666]NPC not found in database.[/color]")
			_:
				_response_text.append_text("[color=#888888]...[/color]")

	var topics_resp: DialogueProvider.Response = _provider.get_available_topics(_speaker_id, _context)
	_rebuild_topic_list(topics_resp.topics)

	_info_label.text = "Disposition: %d | Known topics: %d" % [
		_context.disposition, _context.known_topics.size()
	]


func _rebuild_topic_list(topics: Array) -> void:
	for child in _topics_container.get_children():
		child.queue_free()

	if topics.is_empty():
		var label := Label.new()
		label.text = "(no topics available)"
		label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_topics_container.add_child(label)
	else:
		for topic in topics:
			var btn := Button.new()
			btn.text = topic.display_name
			btn.flat = true
			btn.add_theme_color_override("font_color", Color(0.2, 0.4, 0.7))
			btn.add_theme_color_override("font_hover_color", Color(0.3, 0.5, 0.9))
			btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			var topic_id: String = topic.topic_id
			btn.pressed.connect(_on_topic_clicked.bind(topic_id))
			_topics_container.add_child(btn)

	# Always add Goodbye at the bottom
	var sep := HSeparator.new()
	_topics_container.add_child(sep)
	var goodbye_btn := Button.new()
	goodbye_btn.text = "Goodbye"
	goodbye_btn.flat = true
	goodbye_btn.add_theme_color_override("font_color", Color(0.6, 0.4, 0.3))
	goodbye_btn.add_theme_color_override("font_hover_color", Color(0.8, 0.5, 0.3))
	goodbye_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	goodbye_btn.pressed.connect(_on_goodbye_clicked)
	_topics_container.add_child(goodbye_btn)


func _on_topic_clicked(topic_id: String) -> void:
	if _speaker_id.is_empty():
		return

	var result: DialogueProvider.Response = _provider.get_response(topic_id, _speaker_id, _context)

	_response_text.clear()
	if not result.ok() or result.line == null:
		match result.error:
			DialogueProvider.Error.SPEAKER_NOT_FOUND:
				_response_text.append_text("[color=#cc6666]NPC not found in database.[/color]")
			_:
				_response_text.append_text("[color=#888888]No response for this topic.[/color]")
		return

	# Discover topics first, then highlight
	for new_topic in result.topics_discovered:
		_context.add_topic(new_topic)

	var line: RefCounted = result.line
	var highlighted := _provider.highlight_topics_in_text(line.text, _context.known_topics)
	_response_text.append_text(highlighted)

	# Refresh topic list (may have new topics now)
	var topics_resp: DialogueProvider.Response = _provider.get_available_topics(_speaker_id, _context)
	_rebuild_topic_list(topics_resp.topics)

	_info_label.text = "Topic: '%s' | Discovered: %d | Known: %d | Disposition: %d" % [
		topic_id, result.topics_discovered.size(), _context.known_topics.size(), _context.disposition
	]

	# Let listeners (e.g. quest adapter) react to the response's metadata
	response_selected.emit(topic_id, result)


func _on_goodbye_clicked() -> void:
	if _speaker_id.is_empty():
		return
	var farewell: DialogueProvider.Response = _provider.get_response("goodbye", _speaker_id, _context)
	if farewell.ok() and farewell.line != null:
		var line: RefCounted = farewell.line
		_response_text.clear()
		_response_text.append_text(TextFormatterScript.to_bbcode(line.text))
		# Let quest adapter react even on goodbye response
		response_selected.emit("goodbye", farewell)
		# Brief delay so the player can read the farewell, then close
		await get_tree().create_timer(1.5).timeout
	close()


## Handle clickable topic links in response text
func _on_topic_link_clicked(meta: Variant) -> void:
	var topic_id: String = str(meta)
	_on_topic_clicked(topic_id)


func _build_ui() -> void:
	# Root container — full-screen, visibility toggles the whole panel
	_root_control = Control.new()
	_root_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_control.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root_control)

	# Dimming background
	_bg = ColorRect.new()
	_bg.color = Color(0.08, 0.08, 0.1, 0.85)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_control.add_child(_bg)

	# Main VBox
	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_vbox.set_anchor_and_offset(SIDE_LEFT, 0, 20)
	root_vbox.set_anchor_and_offset(SIDE_RIGHT, 1, -20)
	root_vbox.set_anchor_and_offset(SIDE_TOP, 0, 20)
	root_vbox.set_anchor_and_offset(SIDE_BOTTOM, 1, -20)
	root_vbox.add_theme_constant_override("separation", 10)
	_root_control.add_child(root_vbox)

	# NPC name + disposition row
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 15)
	root_vbox.add_child(name_row)

	_npc_name_label = Label.new()
	_npc_name_label.text = ""
	_npc_name_label.add_theme_font_size_override("font_size", 28)
	_npc_name_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7))
	name_row.add_child(_npc_name_label)

	_disposition_label = Label.new()
	_disposition_label.text = ""
	_disposition_label.theme = DEFAULT_THEME
	_disposition_label.theme_type_variation = "DispositionLabel"
	name_row.add_child(_disposition_label)

	# Main content: response + topics side by side
	var content_hbox := HBoxContainer.new()
	content_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_hbox.add_theme_constant_override("separation", 15)
	root_vbox.add_child(content_hbox)

	# Response panel (left, larger)
	var response_panel := PanelContainer.new()
	response_panel.theme = DEFAULT_THEME
	response_panel.theme_type_variation = "ParchmentTight"
	response_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	response_panel.size_flags_stretch_ratio = 2.0
	content_hbox.add_child(response_panel)

	_response_text = RichTextLabel.new()
	_response_text.bbcode_enabled = true
	_response_text.fit_content = false
	_response_text.scroll_active = true
	_response_text.meta_clicked.connect(_on_topic_link_clicked)
	response_panel.add_child(_response_text)

	# Topics panel (right, narrower)
	var topics_panel := PanelContainer.new()
	topics_panel.theme = DEFAULT_THEME
	topics_panel.theme_type_variation = "TopicsList"
	topics_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	topics_panel.size_flags_stretch_ratio = 1.0
	content_hbox.add_child(topics_panel)

	var topics_scroll := ScrollContainer.new()
	topics_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	topics_panel.add_child(topics_scroll)

	_topics_container = VBoxContainer.new()
	_topics_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_topics_container.add_theme_constant_override("separation", 4)
	topics_scroll.add_child(_topics_container)

	# Info bar at bottom
	_info_label = Label.new()
	_info_label.text = ""
	_info_label.add_theme_font_size_override("font_size", 12)
	_info_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	root_vbox.add_child(_info_label)
