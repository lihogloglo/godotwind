## Visual test for Morrowind dialogue system
##
## Loads ESM data, picks a known NPC, runs the dialogue filter to get
## greeting + available topics, then displays a basic dialogue panel.
## Click topics to see responses. Topics discovered in response text
## are highlighted and added to known topics.
##
## Run: godot --path . res://tests/visual/test_dialogue.tscn
@warning_ignore("untyped_declaration", "unsafe_method_access")
extends Node

const MWDialogueProviderScript := preload("res://src/core/dialogue/morrowind/mw_dialogue_provider.gd")
const MWTextFormatterScript := preload("res://src/core/dialogue/morrowind/mw_text_formatter.gd")
const DialogueContextScript := preload("res://src/core/dialogue/dialogue_context.gd")
const TextFormatterScript := preload("res://src/core/ui/text_formatter.gd")

var _provider: RefCounted  # MWDialogueProvider
var _context: RefCounted   # DialogueContext
var _current_npc_id: String = ""
var _loading_screen: LoadingScreen

# UI elements
var _panel: PanelContainer
var _npc_name_label: Label
var _disposition_label: Label
var _response_text: RichTextLabel
var _topics_container: VBoxContainer
var _info_label: Label
var _npc_selector: OptionButton
var _greeting_keys_found: Array = []

# NPCs to test with (known MW NPCs with dialogue)
var _test_npcs: Array = [
	"fargoth", "arrille", "caius cosades", "hla oad, fatleg's drop, baladas demnevanni",
	"socucius ergalla", "sellus gravius", "ranis athrys", "ajira",
	"edwinna elbert", "sugar-lips habasi", "gentleman jim stacey",
]


func _ready() -> void:
	_loading_screen = LoadingScreen.new()
	add_child(_loading_screen)
	var success = await _loading_screen.load_game_data()
	_loading_screen.queue_free()

	if not success:
		_show_error("Failed to load ESM data.")
		return

	# Ensure NPC records are populated (C# loader populates lazily)
	ESMManager.ensure_typed_dicts_populated()

	# Dump greeting key info for verification
	_verify_greeting_keys()

	# Dump journal data to verify disposition-as-index mapping
	var MWQuestAdapterScript = preload("res://src/core/dialogue/morrowind/mw_quest_adapter.gd")
	MWQuestAdapterScript.dump_journal_sample(5)

	# Setup provider and context
	_provider = MWDialogueProviderScript.new()
	_context = DialogueContextScript.new()
	_context.pc_race = "imperial"
	_context.pc_class = "rogue"
	_context.pc_gender = 0  # Male
	_context.pc_level = 1
	_context.detected = true       # Player is visible to NPC (normal conversation)
	_context.talked_to_pc = false   # First meeting
	# MW global: CharGenState >= 10 means character creation is complete
	_context.set_global("chargenstate", 10.0)
	# Set reasonable starting stats
	_context.pc_health = 50
	_context.pc_health_percent = 100
	_context.pc_magicka = 50
	_context.pc_fatigue = 100
	_context.pc_clothing_value = 100  # Wearing basic clothes

	# Build UI
	_build_ui()

	# Find first available test NPC
	_populate_npc_selector()


func _verify_greeting_keys() -> void:
	# Log all greeting-type DIAL records to verify the key format
	for dial_id in ESMManager.dialogues:
		var dial: DialogueRecord = ESMManager.dialogues[dial_id]
		if dial.is_greeting():
			_greeting_keys_found.append(dial_id)

	_greeting_keys_found.sort()
	Log.info("dialogue", "Greeting DIAL keys found: %s" % str(_greeting_keys_found))

	# Also log counts for all dialogue types
	var type_counts := {}
	for dial_id in ESMManager.dialogues:
		var dial: DialogueRecord = ESMManager.dialogues[dial_id]
		var t = dial.dialogue_type
		type_counts[t] = type_counts.get(t, 0) + 1
	Log.info("dialogue", "Dialogue type counts: %s" % str(type_counts))


func _populate_npc_selector() -> void:
	var found_any := false
	for npc_id in _test_npcs:
		var npc: NPCRecord = ESMManager.npcs.get(npc_id.to_lower())
		if npc != null:
			_npc_selector.add_item("%s (%s)" % [npc.name, npc.record_id], _npc_selector.item_count)
			_npc_selector.set_item_metadata(_npc_selector.item_count - 1, npc.record_id)
			if not found_any:
				found_any = true

	# Also add a few random NPCs
	var count := 0
	for npc_id in ESMManager.npcs:
		if count >= 10:
			break
		var npc: NPCRecord = ESMManager.npcs[npc_id]
		if npc.name.is_empty():
			continue
		_npc_selector.add_item("%s (%s)" % [npc.name, npc.record_id], _npc_selector.item_count)
		_npc_selector.set_item_metadata(_npc_selector.item_count - 1, npc.record_id)
		count += 1

	if _npc_selector.item_count > 0:
		_npc_selector.selected = 0
		_on_npc_selected(0)


func _on_npc_selected(index: int) -> void:
	_current_npc_id = _npc_selector.get_item_metadata(index)
	if _current_npc_id.is_empty():
		return

	# Look up NPC for disposition and debug info
	var npc: NPCRecord = ESMManager.npcs.get(_current_npc_id.to_lower())
	if npc == null:
		return

	# Reset context for new conversation
	_context.disposition = npc.disposition
	Log.info("dialogue", "NPC: %s, race=%s, class=%s, faction=%s, rank=%d, disposition=%d" % [
		npc.name, npc.race_id, npc.class_id,
		npc.faction_id, npc.rank, npc.disposition
	])

	# Get greeting
	var start := Time.get_ticks_msec()
	var greeting = _provider.get_greeting(_current_npc_id, _context)
	var greeting_ms := Time.get_ticks_msec() - start

	# Debug: if no greeting, run debug search on greeting 0
	if greeting == null:
		var MWFilter = preload("res://src/core/dialogue/morrowind/mw_dialogue_filter.gd")
		MWFilter.debug_search("greeting 0", npc, _context)

	_npc_name_label.text = _provider.get_speaker_name(_current_npc_id)
	_disposition_label.text = "Disposition: %d" % _context.disposition

	if greeting != null:
		# Discover topics from greeting text first (so highlighting knows them)
		var discovered = _provider.discover_topics_in_text(greeting.text)
		for topic_id in discovered:
			_context.add_topic(topic_id)

		# Display with topic highlighting
		_response_text.clear()
		var highlighted = _provider.highlight_topics_in_text(greeting.text, _context.known_topics)
		_response_text.append_text(highlighted)

		Log.info("dialogue", "Greeting for %s (%dms): %s... [discovered %d topics]" % [
			_current_npc_id, greeting_ms,
			greeting.text.substr(0, 80),
			discovered.size()
		])
	else:
		_response_text.clear()
		_response_text.append_text("[color=#888888]No greeting found for this NPC.[/color]")
		Log.info("dialogue", "No greeting for %s (%dms)" % [_current_npc_id, greeting_ms])

	# Get available topics
	start = Time.get_ticks_msec()
	var topics = _provider.get_available_topics(_current_npc_id, _context)
	var topics_ms := Time.get_ticks_msec() - start

	_rebuild_topic_list(topics)

	_info_label.text = "Greeting: %dms | Topics: %d found in %dms | Disposition: %d | Known topics: %d" % [
		greeting_ms, topics.size(), topics_ms, _context.disposition, _context.known_topics.size()
	]


func _rebuild_topic_list(topics: Array) -> void:
	# Clear old topics
	for child in _topics_container.get_children():
		child.queue_free()

	if topics.is_empty():
		var label := Label.new()
		label.text = "(no topics available)"
		label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_topics_container.add_child(label)
		return

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
	goodbye_btn.pressed.connect(_on_topic_clicked.bind("goodbye"))
	_topics_container.add_child(goodbye_btn)


func _on_topic_clicked(topic_id: String) -> void:
	if _current_npc_id.is_empty():
		return

	# Handle goodbye — show MW farewell response if available
	if topic_id == "goodbye":
		var farewell = _provider.get_response("goodbye", _current_npc_id, _context)
		_response_text.clear()
		if farewell != null and farewell.line != null:
			_response_text.append_text(TextFormatterScript.to_bbcode(farewell.line.text))
		else:
			_response_text.append_text("[color=#666666]Goodbye.[/color]")
		for child in _topics_container.get_children():
			child.queue_free()
		_info_label.text = "Conversation ended. Select another NPC to start a new dialogue."
		return

	var result = _provider.get_response(topic_id, _current_npc_id, _context)
	if result == null or result.line == null:
		_response_text.clear()
		_response_text.append_text("[color=#888888]No response for this topic.[/color]")
		return

	# Discover topics first, then highlight
	for new_topic in result.topics_discovered:
		_context.add_topic(new_topic)

	_response_text.clear()
	var highlighted = _provider.highlight_topics_in_text(result.line.text, _context.known_topics)
	_response_text.append_text(highlighted)

	# Refresh topic list (may have new topics now)
	var topics = _provider.get_available_topics(_current_npc_id, _context)
	_rebuild_topic_list(topics)

	_info_label.text = "Topic: '%s' | Discovered: %d new topics | Known: %d | Disposition: %d" % [
		topic_id, result.topics_discovered.size(), _context.known_topics.size(), _context.disposition
	]


## Handle clickable topic links in response text
func _on_topic_link_clicked(meta) -> void:
	var topic_id: String = str(meta)
	_on_topic_clicked(topic_id)


func _build_ui() -> void:
	# Dark background
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Main VBox
	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_vbox.set_anchor_and_offset(SIDE_LEFT, 0, 20)
	root_vbox.set_anchor_and_offset(SIDE_RIGHT, 1, -20)
	root_vbox.set_anchor_and_offset(SIDE_TOP, 0, 20)
	root_vbox.set_anchor_and_offset(SIDE_BOTTOM, 1, -20)
	root_vbox.add_theme_constant_override("separation", 10)
	add_child(root_vbox)

	# NPC selector row
	var selector_row := HBoxContainer.new()
	root_vbox.add_child(selector_row)

	var selector_label := Label.new()
	selector_label.text = "NPC: "
	selector_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	selector_row.add_child(selector_label)

	_npc_selector = OptionButton.new()
	_npc_selector.custom_minimum_size.x = 300
	_npc_selector.item_selected.connect(_on_npc_selected)
	selector_row.add_child(_npc_selector)

	# NPC name
	# NPC name + disposition row
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 15)
	root_vbox.add_child(name_row)

	_npc_name_label = Label.new()
	_npc_name_label.text = ""
	_npc_name_label.add_theme_font_size_override("font_size", 24)
	_npc_name_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7))
	name_row.add_child(_npc_name_label)

	_disposition_label = Label.new()
	_disposition_label.text = ""
	_disposition_label.add_theme_font_size_override("font_size", 16)
	_disposition_label.add_theme_color_override("font_color", Color(0.6, 0.7, 0.6))
	name_row.add_child(_disposition_label)

	# Main content: response + topics side by side
	var content_hbox := HBoxContainer.new()
	content_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_hbox.add_theme_constant_override("separation", 15)
	root_vbox.add_child(content_hbox)

	# Response panel (left, larger)
	var response_panel := PanelContainer.new()
	response_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	response_panel.size_flags_stretch_ratio = 2.0
	var resp_style := StyleBoxFlat.new()
	resp_style.bg_color = Color(0.91, 0.87, 0.78)
	resp_style.set_border_width_all(2)
	resp_style.border_color = Color(0.45, 0.35, 0.25)
	resp_style.set_content_margin_all(15)
	resp_style.set_corner_radius_all(4)
	response_panel.add_theme_stylebox_override("panel", resp_style)
	content_hbox.add_child(response_panel)

	_response_text = RichTextLabel.new()
	_response_text.bbcode_enabled = true
	_response_text.fit_content = false
	_response_text.scroll_active = true
	_response_text.add_theme_font_size_override("normal_font_size", 16)
	_response_text.add_theme_color_override("default_color", Color(0.15, 0.1, 0.05))
	var empty_style := StyleBoxEmpty.new()
	_response_text.add_theme_stylebox_override("normal", empty_style)
	_response_text.meta_clicked.connect(_on_topic_link_clicked)
	response_panel.add_child(_response_text)

	# Topics panel (right, narrower)
	var topics_panel := PanelContainer.new()
	topics_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	topics_panel.size_flags_stretch_ratio = 1.0
	var topic_style := StyleBoxFlat.new()
	topic_style.bg_color = Color(0.12, 0.12, 0.15)
	topic_style.set_border_width_all(2)
	topic_style.border_color = Color(0.3, 0.3, 0.4)
	topic_style.set_content_margin_all(10)
	topic_style.set_corner_radius_all(4)
	topics_panel.add_theme_stylebox_override("panel", topic_style)
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
	_info_label.text = "Select an NPC to start"
	_info_label.add_theme_font_size_override("font_size", 12)
	_info_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	root_vbox.add_child(_info_label)


func _show_error(message: String) -> void:
	var label := Label.new()
	label.text = message
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	add_child(label)
