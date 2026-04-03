## Visual test for Quest Journal system
##
## Loads ESM data, simulates quest progressions using real Morrowind journal entries,
## then displays the JournalPanel. Press J to toggle journal. Toast notifications
## appear when journal updates.
##
## Run: godot --path . res://tests/visual/test_journal.tscn
@warning_ignore("untyped_declaration", "unsafe_method_access")
extends Node

const QuestManagerScript := preload("res://src/core/dialogue/quest_manager.gd")
const MWQuestAdapterScript := preload("res://src/core/dialogue/morrowind/mw_quest_adapter.gd")
const JournalPanelScript := preload("res://src/core/ui/journal_panel.gd")
const ToastScript := preload("res://src/core/ui/toast.gd")

var _quest_manager
var _mw_adapter
var _journal_panel
var _toast
var _loading_screen: LoadingScreen
var _info_label: Label
var _simulate_button: Button
var _simulation_step: int = 0


func _ready() -> void:
	_loading_screen = LoadingScreen.new()
	add_child(_loading_screen)
	var success = await _loading_screen.load_game_data()
	_loading_screen.queue_free()

	if not success:
		_show_error("Failed to load ESM data.")
		return

	# Setup quest system
	_quest_manager = QuestManagerScript.new()
	_mw_adapter = MWQuestAdapterScript.new(_quest_manager)

	# Wire toast to quest signals
	_toast = ToastScript.new()
	add_child(_toast)
	_quest_manager.quest_started.connect(_on_quest_started)
	_quest_manager.quest_updated.connect(_on_quest_updated)
	_quest_manager.quest_completed.connect(_on_quest_completed)

	# Setup journal panel
	_journal_panel = JournalPanelScript.new()
	_journal_panel.set_quest_manager(_quest_manager)
	add_child(_journal_panel)

	# Build UI
	_build_ui()

	# Simulate initial quest entries
	_simulate_quest_step()


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed:
		return

	if event.keycode == KEY_J:
		_journal_panel.show_journal()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_RIGHT or event.keycode == KEY_SPACE:
		_on_simulate_pressed()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ESCAPE:
		_journal_panel.hide_journal()
		get_viewport().set_input_as_handled()


func _on_quest_started(quest_id: String) -> void:
	_toast.show_message("New Quest: %s" % quest_id)


func _on_quest_updated(quest_id: String, _index: int) -> void:
	_toast.show_message("Your journal has been updated.")


func _on_quest_completed(quest_id: String) -> void:
	_toast.show_message("Quest Complete: %s" % quest_id)


## Simulate quest progression using real MW journal entries
func _simulate_quest_step() -> void:
	var all_journals = MWQuestAdapterScript.get_all_journal_entries()

	# Pick a few well-known quests to simulate
	var quest_sequence: Array = [
		# Caius Cosades main quest: talk to Hasphat
		{"quest": "a1_2_antabolisinformant", "up_to_index": 1},
		{"quest": "a1_2_antabolisinformant", "up_to_index": 5},
		# Fargoth's ring quest
		{"quest": "ms_fargothring", "up_to_index": 100},
		# Continue Hasphat quest
		{"quest": "a1_2_antabolisinformant", "up_to_index": 10},
		{"quest": "a1_2_antabolisinformant", "up_to_index": 20},
		# Addhiranirr informant
		{"quest": "a1_6_addhiranirrinformant", "up_to_index": 5},
		{"quest": "a1_6_addhiranirrinformant", "up_to_index": 30},
	]

	if _simulation_step >= quest_sequence.size():
		_info_label.text = "All quest steps simulated. Press J to open journal."
		_simulate_button.text = "Reset"
		return

	var step = quest_sequence[_simulation_step]
	var quest_id: String = step["quest"]
	var up_to_index: int = step["up_to_index"]

	if not all_journals.has(quest_id):
		Log.warn("dialogue", "Quest '%s' not found in journal data" % quest_id)
		_simulation_step += 1
		return

	var entries: Array = all_journals[quest_id]
	for entry: Dictionary in entries:
		if entry["index"] <= up_to_index:
			# Check if we already added this entry
			var existing = _quest_manager.get_quest(quest_id)
			if existing != null and existing.current_index >= entry["index"]:
				continue
			_quest_manager.update_journal(
				quest_id, entry["index"], entry["text"],
				entry["quest_finish"], entry["quest_restart"]
			)

	_simulation_step += 1
	_info_label.text = "Step %d/%d — Quest: %s (index %d). Press 'Next Step' or J for journal." % [
		_simulation_step, quest_sequence.size(), quest_id, up_to_index
	]


func _on_simulate_pressed() -> void:
	if _simulation_step >= 7:
		# Reset
		_quest_manager = QuestManagerScript.new()
		_mw_adapter = MWQuestAdapterScript.new(_quest_manager)
		_journal_panel.set_quest_manager(_quest_manager)
		_simulation_step = 0
		_simulate_button.text = "Next Step"
	_simulate_quest_step()


func _build_ui() -> void:
	# Dark background (pass-through clicks to controls on top)
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Controls at top
	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_TOP_WIDE)
	hbox.offset_top = 20
	hbox.offset_left = 20
	hbox.offset_right = -20
	hbox.add_theme_constant_override("separation", 15)
	add_child(hbox)

	_simulate_button = Button.new()
	_simulate_button.text = "Next Step"
	_simulate_button.pressed.connect(_on_simulate_pressed)
	hbox.add_child(_simulate_button)

	var journal_button := Button.new()
	journal_button.text = "Open Journal (J)"
	journal_button.pressed.connect(func(): _journal_panel.show_journal())
	hbox.add_child(journal_button)

	_info_label = Label.new()
	_info_label.text = "Press 'Next Step' to simulate quest progression"
	_info_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
	_info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(_info_label)


func _show_error(message: String) -> void:
	var label := Label.new()
	label.text = message
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	add_child(label)
