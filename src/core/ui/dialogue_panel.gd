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
## var context := MWDialogueContext.new()  # adapter-specific subclass
## # ... populate context with player state ...
## dialogue_ui.open(provider, "fargoth", context)
## ```
class_name DialogueUI
extends CanvasLayer

const TextFormatterScript := preload("res://src/core/ui/text_formatter.gd")
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
	# Escape OR the interact action (E) close the panel — toggling with the
	# same key the player used to open it.
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("interact"):
		close()
		get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	# Node-level mouse tracer — fires for ALL input regardless of GUI hit test.
	# If this fires but _on_root_gui_input does NOT, the event reached the
	# Node tree but was eaten before GUI picking.
	# If this does NOT fire, the event never reached the Node at all —
	# upstream _input handler consumed it via set_input_as_handled().
	if not _root_control.visible:
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.pressed:
			Log.info("dialogue", "DialogueUI._input caught mouse button=%d pressed pos=(%.0f,%.0f) mouse_mode=%d" % [
				mb.button_index, mb.position.x, mb.position.y, Input.get_mouse_mode()
			])


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
	# Ensure the cursor is free for button clicks. If the caller had the
	# mouse captured for fly-camera look, dialogue would be uninteractable
	# without this.
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Log.info("dialogue", "DialogueUI.open('%s'): root_control.visible=%s mouse_mode=%d (0=visible 2=captured)" % [
		speaker_id, _root_control.visible, Input.get_mouse_mode()
	])
	opened.emit(speaker_id)
	_show_greeting()
	# Start polling mouse mode + visibility for diagnosis; stop on close.
	set_process(true)


func _process(_delta: float) -> void:
	# Only log if state is unexpected while dialogue is open.
	if not _root_control.visible:
		set_process(false)
		return
	var mm := Input.get_mouse_mode()
	if mm != Input.MOUSE_MODE_VISIBLE:
		Log.warn("dialogue", "DialogueUI: mouse_mode is %d (expected 0=VISIBLE) while dialogue open — input will be eaten by captured cursor" % mm)
		# Force it back — something upstream is re-capturing
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


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
	# Fall back to the raw speaker_id if the provider reports the speaker as
	# unknown. Previously the provider silently returned the ID itself, which
	# masked "NPC not in database" bugs as "NPC named <ID>".
	var display_name := _provider.get_speaker_name(_speaker_id)
	if display_name.is_empty():
		display_name = "<%s>" % _speaker_id
		Log.warn("dialogue", "DialogueUI: no display name for speaker_id='%s' — showing raw ID" % _speaker_id)
	_npc_name_label.text = display_name
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
	Log.info("dialogue", "DialogueUI: topic button clicked → '%s'" % topic_id)
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
	Log.info("dialogue", "DialogueUI: goodbye button clicked")
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
	Log.info("dialogue", "DialogueUI: topic link clicked → '%s'" % topic_id)
	_on_topic_clicked(topic_id)


## Debug: log any mouse click that hits the root Control's empty space.
## If topic buttons or the RichTextLabel consumed the click first, this
## won't fire. If this DOES fire, the click reached the GUI layer but no
## child control claimed it — pointing at a layout/sizing bug.
func _on_root_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.pressed:
			Log.info("dialogue", "DialogueUI: root gui_input caught click button=%d pos=(%.0f,%.0f) — click did NOT hit any topic button or response text" % [
				mb.button_index, mb.position.x, mb.position.y
			])


## Hover handlers — swap cursor shape so [url] keywords look clickable.
func _on_meta_hover_started(_meta: Variant) -> void:
	Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND)
	Log.info("dialogue", "DialogueUI: topic link hovered → '%s'" % str(_meta))


func _on_meta_hover_ended(_meta: Variant) -> void:
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)


func _build_ui() -> void:
	# Root container — full-screen, visibility toggles the whole panel.
	# IMPORTANT: a Control as a direct child of a CanvasLayer does NOT
	# automatically get sized to the viewport by `set_anchors_preset` —
	# CanvasLayer is not a Control and provides no parent rect. With
	# parent rect = 0×0, FULL_RECT anchors compute size = 0×0 too, and
	# the Control's hit-rect stays empty even though it visually renders
	# (because its CHILDREN have their own offset-based layout).
	#
	# Fix: zero the anchors entirely and set size + position manually.
	# Without anchors fighting it back, set_size sticks across layout
	# passes. Re-fire on viewport size_changed.
	_root_control = Control.new()
	_root_control.anchor_left = 0
	_root_control.anchor_top = 0
	_root_control.anchor_right = 0
	_root_control.anchor_bottom = 0
	_root_control.offset_left = 0
	_root_control.offset_top = 0
	_root_control.offset_right = 0
	_root_control.offset_bottom = 0
	_root_control.mouse_filter = Control.MOUSE_FILTER_STOP
	_root_control.gui_input.connect(_on_root_gui_input)
	add_child(_root_control)
	# Force initial size + keep it in sync with viewport size changes.
	_resize_root_to_viewport()
	get_viewport().size_changed.connect(_resize_root_to_viewport)

	# Dimming background. MOUSE_FILTER_IGNORE so clicks that miss the topic
	# buttons / response text and land on the dim background aren't swallowed.
	# (Godot picks deepest child first regardless of parent filter, so this
	# isn't about "passing through" — it's about the parent catching whiffs.)
	_bg = ColorRect.new()
	_bg.color = Color(0.08, 0.08, 0.1, 0.85)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root_control.add_child(_bg)

	# Main VBox. MOUSE_FILTER_PASS on all intermediate containers so clicks
	# that miss a button bubble up to _root_control.gui_input for diagnosis
	# (and more importantly: so the dim background logic at the root can
	# see unclaimed clicks instead of having them die silently inside a
	# container's default MOUSE_FILTER_STOP sink).
	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_vbox.set_anchor_and_offset(SIDE_LEFT, 0, 20)
	root_vbox.set_anchor_and_offset(SIDE_RIGHT, 1, -20)
	root_vbox.set_anchor_and_offset(SIDE_TOP, 0, 20)
	root_vbox.set_anchor_and_offset(SIDE_BOTTOM, 1, -20)
	root_vbox.add_theme_constant_override("separation", 10)
	root_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
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
	content_hbox.mouse_filter = Control.MOUSE_FILTER_PASS
	root_vbox.add_child(content_hbox)

	# Response panel (left, larger)
	var response_panel := PanelContainer.new()
	response_panel.theme = DEFAULT_THEME
	response_panel.theme_type_variation = "ParchmentTight"
	response_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	response_panel.size_flags_stretch_ratio = 2.0
	response_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	content_hbox.add_child(response_panel)

	_response_text = RichTextLabel.new()
	_response_text.bbcode_enabled = true
	_response_text.fit_content = false
	_response_text.scroll_active = true
	_response_text.selection_enabled = true  # Lets the cursor hover detection work for [url] tags
	_response_text.mouse_filter = Control.MOUSE_FILTER_STOP
	_response_text.meta_clicked.connect(_on_topic_link_clicked)
	# meta_hover_started/ended swap cursor to pointing_hand so the player
	# knows topic keywords are clickable. Without this the text looks
	# "decorative" and players don't realize they can click.
	_response_text.meta_hover_started.connect(_on_meta_hover_started)
	_response_text.meta_hover_ended.connect(_on_meta_hover_ended)
	response_panel.add_child(_response_text)

	# Topics panel (right, narrower)
	var topics_panel := PanelContainer.new()
	topics_panel.theme = DEFAULT_THEME
	topics_panel.theme_type_variation = "TopicsList"
	topics_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	topics_panel.size_flags_stretch_ratio = 1.0
	topics_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	content_hbox.add_child(topics_panel)

	var topics_scroll := ScrollContainer.new()
	topics_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	topics_panel.add_child(topics_scroll)

	_topics_container = VBoxContainer.new()
	_topics_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_topics_container.add_theme_constant_override("separation", 4)
	_topics_container.mouse_filter = Control.MOUSE_FILTER_PASS
	topics_scroll.add_child(_topics_container)

	# Info bar at bottom
	_info_label = Label.new()
	_info_label.text = ""
	_info_label.add_theme_font_size_override("font_size", 12)
	_info_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	root_vbox.add_child(_info_label)


func _resize_root_to_viewport() -> void:
	if _root_control == null:
		return
	var vp_size := get_viewport().get_visible_rect().size
	_root_control.position = Vector2.ZERO
	_root_control.size = vp_size
	Log.info("dialogue", "DialogueUI: _root_control sized to %s (rect=%s)" % [vp_size, _root_control.get_rect()])
