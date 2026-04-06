## Visual test harness for the DialogueUI panel
##
## Loads ESM data, builds an NPC selector, and opens the DialogueUI panel
## for the currently selected NPC. Used to verify that the framework panel
## (src/core/ui/dialogue_panel.gd) consumes the MWDialogueProvider
## correctly end-to-end: greetings, topics, response scripts, and goodbye.
##
## Run: godot --path . res://tests/visual/test_dialogue.tscn
@warning_ignore("untyped_declaration", "unsafe_method_access")
extends Node

const MWDialogueProviderScript := preload("res://src/core/dialogue/morrowind/mw_dialogue_provider.gd")
const DialogueContextScript := preload("res://src/core/dialogue/dialogue_context.gd")
const DialogueUIScript := preload("res://src/core/ui/dialogue_panel.gd")

var _provider: RefCounted  # MWDialogueProvider
var _context: RefCounted   # DialogueContext
var _dialogue_ui: DialogueUI
var _loading_screen: LoadingScreen
var _npc_selector: OptionButton

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

	# Setup provider and context
	_provider = MWDialogueProviderScript.new()
	_context = DialogueContextScript.new()
	_context.pc_race = "imperial"
	_context.pc_class = "rogue"
	_context.pc_gender = 0  # Male
	_context.pc_level = 1
	_context.detected = true       # Player is visible to NPC (normal conversation)
	_context.talked_to_pc = false  # First meeting
	# MW global: CharGenState >= 10 means character creation is complete
	_context.set_global("chargenstate", 10.0)
	# Set reasonable starting stats
	_context.pc_health = 50
	_context.pc_health_percent = 100
	_context.pc_magicka = 50
	_context.pc_fatigue = 100
	_context.pc_clothing_value = 100

	# Build UI
	_build_harness_ui()

	# Instantiate the DialogueUI panel that we're testing
	_dialogue_ui = DialogueUIScript.new()
	add_child(_dialogue_ui)
	_dialogue_ui.closed.connect(_on_dialogue_closed)

	# Find first available test NPC and open the dialogue
	_populate_npc_selector()


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
	var speaker_id: String = _npc_selector.get_item_metadata(index)
	if speaker_id.is_empty():
		return

	# Look up NPC for disposition (adapter-level responsibility; in the real game
	# this would come from the MW derived-disposition formula — see Phase 7)
	var npc: NPCRecord = ESMManager.npcs.get(speaker_id.to_lower())
	if npc != null:
		_context.disposition = npc.disposition

	_dialogue_ui.open(_provider, speaker_id, _context)


func _on_dialogue_closed(speaker_id: String) -> void:
	Log.info("dialogue", "Conversation with %s ended" % speaker_id)


func _build_harness_ui() -> void:
	# NPC selector row at the top of the screen, above the DialogueUI CanvasLayer
	var selector_layer := CanvasLayer.new()
	selector_layer.layer = 91  # Above DialogueUI (layer 90) so it stays clickable
	add_child(selector_layer)

	# Anchor at the bottom so it doesn't collide with the DialogueUI's top name header
	var selector_row := HBoxContainer.new()
	selector_row.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	selector_row.offset_left = 20
	selector_row.offset_top = -50
	selector_row.offset_right = -20
	selector_row.offset_bottom = -20
	selector_layer.add_child(selector_row)

	var selector_label := Label.new()
	selector_label.text = "NPC: "
	selector_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	selector_row.add_child(selector_label)

	_npc_selector = OptionButton.new()
	_npc_selector.custom_minimum_size.x = 300
	_npc_selector.item_selected.connect(_on_npc_selected)
	selector_row.add_child(_npc_selector)


func _show_error(message: String) -> void:
	var label := Label.new()
	label.text = message
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	add_child(label)
