## JournalPanel — Quest journal UI
##
## Framework UI component. Displays quest list (active/completed tabs)
## with per-quest journal entries. Reuses parchment styling.
##
## Usage:
##   var panel := JournalPanel.new()
##   add_child(panel)
##   panel.set_quest_manager(quest_manager)
##   panel.show_journal()
class_name JournalPanel
extends CanvasLayer

const QuestManagerScript := preload("res://src/core/dialogue/quest_manager.gd")
const DEFAULT_THEME := preload("res://assets/ui/themes/default_theme.tres")

signal closed

var _quest_manager: RefCounted  # QuestManager
var _overlay: ColorRect
var _panel: PanelContainer
var _quest_list: VBoxContainer
var _entry_display: RichTextLabel
var _tab_active: Button
var _tab_completed: Button
var _close_button: Button
var _title_label: Label
var _showing_active: bool = true


func _ready() -> void:
	layer = 90
	_build_ui()
	hide_journal()


func _unhandled_input(event: InputEvent) -> void:
	if not _panel.visible:
		return
	if event.is_action_pressed("ui_cancel"):
		hide_journal()
		get_viewport().set_input_as_handled()


## Set the quest manager to read quests from
func set_quest_manager(qm: RefCounted) -> void:
	_quest_manager = qm


## Show the journal
func show_journal() -> void:
	_panel.visible = true
	if _overlay:
		_overlay.visible = true
	_showing_active = true
	_update_tab_style()
	_refresh_quest_list()


## Hide the journal
func hide_journal() -> void:
	_panel.visible = false
	if _overlay:
		_overlay.visible = false
	closed.emit()


## Is the journal currently displayed?
func is_open() -> bool:
	return _panel != null and _panel.visible


func _on_tab_active() -> void:
	_showing_active = true
	_update_tab_style()
	_refresh_quest_list()


func _on_tab_completed() -> void:
	_showing_active = false
	_update_tab_style()
	_refresh_quest_list()


func _update_tab_style() -> void:
	var active_color := Color(0.25, 0.15, 0.1)
	var inactive_color := Color(0.55, 0.45, 0.35)
	_tab_active.add_theme_color_override("font_color",
		active_color if _showing_active else inactive_color)
	_tab_completed.add_theme_color_override("font_color",
		inactive_color if _showing_active else active_color)


func _refresh_quest_list() -> void:
	# Clear old list
	for child in _quest_list.get_children():
		child.queue_free()

	_entry_display.clear()

	if _quest_manager == null:
		return

	var quests: Array
	if _showing_active:
		quests = _quest_manager.get_active_quests()
	else:
		quests = _quest_manager.get_completed_quests()

	if quests.is_empty():
		var label := Label.new()
		label.text = "(no quests)" if _showing_active else "(no completed quests)"
		label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_quest_list.add_child(label)
		return

	for quest in quests:
		var btn := Button.new()
		btn.text = quest.display_name
		btn.flat = true
		btn.add_theme_color_override("font_color", Color(0.2, 0.15, 0.1))
		btn.add_theme_color_override("font_hover_color", Color(0.4, 0.3, 0.2))
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var qid: String = quest.quest_id
		btn.pressed.connect(_on_quest_selected.bind(qid))
		_quest_list.add_child(btn)


func _on_quest_selected(quest_id: String) -> void:
	if _quest_manager == null:
		return

	var quest: RefCounted = _quest_manager.get_quest(quest_id)
	if quest == null:
		return

	_entry_display.clear()

	# Display quest title
	_entry_display.append_text("[b][font_size=20]%s[/font_size][/b]\n\n" % quest.display_name)

	# Display all journal entries in order
	for entry in quest.entries:
		var index_str := "[color=#888888][%d][/color] " % entry.index
		_entry_display.append_text(index_str)
		_entry_display.append_text(entry.text)
		if entry.finishes_quest:
			_entry_display.append_text(" [color=#448844](Quest Complete)[/color]")
		_entry_display.append_text("\n\n")


func _build_ui() -> void:
	# Full-screen dimming overlay (stored as member so hide_journal can toggle it)
	_overlay = ColorRect.new()
	_overlay.color = Color(0, 0, 0, 0.6)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)

	# Center panel — parchment (theme provides bg/border/padding/font)
	_panel = PanelContainer.new()
	_panel.theme = DEFAULT_THEME
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(800, 550)
	_panel.size = Vector2(800, 550)
	_panel.position = Vector2(-400, -275)
	add_child(_panel)

	# Main layout
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_panel.add_child(vbox)

	# Header row: title + close
	var header := HBoxContainer.new()
	vbox.add_child(header)

	_title_label = Label.new()
	_title_label.text = "Journal"
	_title_label.theme_type_variation = "TitleLabel"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title_label)

	_close_button = Button.new()
	_close_button.text = "X"
	_close_button.flat = true
	_close_button.theme_type_variation = "CloseButton"
	_close_button.pressed.connect(hide_journal)
	header.add_child(_close_button)

	# Tab row
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 20)
	vbox.add_child(tab_row)

	_tab_active = Button.new()
	_tab_active.text = "Active Quests"
	_tab_active.flat = true
	_tab_active.pressed.connect(_on_tab_active)
	tab_row.add_child(_tab_active)

	_tab_completed = Button.new()
	_tab_completed.text = "Completed"
	_tab_completed.flat = true
	_tab_completed.pressed.connect(_on_tab_completed)
	tab_row.add_child(_tab_completed)

	# Separator
	var sep := HSeparator.new()
	vbox.add_child(sep)

	# Content: quest list + entry display side by side
	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 15)
	vbox.add_child(content)

	# Quest list (left)
	var list_scroll := ScrollContainer.new()
	list_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.size_flags_stretch_ratio = 0.4
	content.add_child(list_scroll)

	_quest_list = VBoxContainer.new()
	_quest_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_quest_list.add_theme_constant_override("separation", 4)
	list_scroll.add_child(_quest_list)

	# Entry display (right) — theme provides font_size, default color, empty background
	_entry_display = RichTextLabel.new()
	_entry_display.bbcode_enabled = true
	_entry_display.fit_content = false
	_entry_display.scroll_active = true
	_entry_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_entry_display.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_entry_display.size_flags_stretch_ratio = 0.6
	content.add_child(_entry_display)
