## AssetBrowser - Reusable browsing component with search, categories, and item list
##
## Features:
## - Search with debounce
## - Category filter buttons
## - ItemList with metadata
## - Result count display
## - Max display limit for performance
@warning_ignore("untyped_declaration")
class_name AssetBrowser
extends VBoxContainer

signal item_selected(item: Dictionary)
signal item_activated(item: Dictionary)
signal category_changed(category: String)
signal search_changed(text: String)

# UI nodes (created in _ready)
var title_label: Label = null
var search_edit: LineEdit = null
var result_label: Label = null
var category_container: HFlowContainer = null
var item_list: ItemList = null

# Configuration
@export var title: String = "Browser"
@export var search_placeholder: String = "Search..."
@export var max_display_items: int = 500
@export var debounce_time: float = 0.2

# State
var _all_items: Array[Dictionary] = []  # {id, name, category, metadata}
var _filtered_items: Array[Dictionary] = []
var _categories: Array[String] = []
var _current_category: String = ""
var _search_timer: Timer = null
var _category_buttons: Dictionary = {}  # category -> Button


func _ready() -> void:
	_setup_ui()
	_setup_search_timer()


func _setup_ui() -> void:
	# Title
	title_label = Label.new()
	title_label.name = "Title"
	title_label.text = title
	title_label.add_theme_font_size_override("font_size", 16)
	add_child(title_label)

	# Separator
	var sep1 := HSeparator.new()
	add_child(sep1)

	# Search
	var search_label := Label.new()
	search_label.text = "Search:"
	add_child(search_label)

	search_edit = LineEdit.new()
	search_edit.name = "SearchEdit"
	search_edit.placeholder_text = search_placeholder
	search_edit.clear_button_enabled = true
	search_edit.text_changed.connect(_on_search_text_changed)
	add_child(search_edit)

	# Result count
	result_label = Label.new()
	result_label.name = "ResultCount"
	result_label.text = "0 items"
	result_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	add_child(result_label)

	# Category buttons container
	var cat_label := Label.new()
	cat_label.text = "Category:"
	add_child(cat_label)

	category_container = HFlowContainer.new()
	category_container.name = "Categories"
	add_child(category_container)

	# Separator
	var sep2 := HSeparator.new()
	add_child(sep2)

	# Item list
	item_list = ItemList.new()
	item_list.name = "ItemList"
	item_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	item_list.allow_reselect = true
	item_list.item_selected.connect(_on_item_selected)
	item_list.item_activated.connect(_on_item_activated)
	add_child(item_list)


func _setup_search_timer() -> void:
	_search_timer = Timer.new()
	_search_timer.one_shot = true
	_search_timer.wait_time = debounce_time
	_search_timer.timeout.connect(_apply_filter)
	add_child(_search_timer)


## Set available categories
func set_categories(categories: Array[String]) -> void:
	_categories = categories
	_rebuild_category_buttons()


func _rebuild_category_buttons() -> void:
	# Clear existing
	for child in category_container.get_children():
		child.queue_free()
	_category_buttons.clear()

	# "All" button
	var all_btn := Button.new()
	all_btn.text = "All"
	all_btn.toggle_mode = true
	all_btn.button_pressed = true
	all_btn.pressed.connect(func() -> void: _set_category(""))
	category_container.add_child(all_btn)
	_category_buttons[""] = all_btn

	# Category buttons
	for cat in _categories:
		var btn := Button.new()
		btn.text = cat.capitalize()
		btn.toggle_mode = true
		btn.pressed.connect(_make_category_callback(cat))
		category_container.add_child(btn)
		_category_buttons[cat] = btn


func _make_category_callback(cat: String) -> Callable:
	return func() -> void: _set_category(cat)


func _set_category(category: String) -> void:
	_current_category = category

	# Update button states
	for cat_key: String in _category_buttons:
		var btn: Button = _category_buttons[cat_key]
		btn.button_pressed = (cat_key == category)

	_apply_filter()
	category_changed.emit(category)


## Set items to browse
func set_items(items: Array[Dictionary]) -> void:
	_all_items = items
	_apply_filter()


## Add items (append to existing)
func add_items(items: Array[Dictionary]) -> void:
	_all_items.append_array(items)
	_apply_filter()


## Clear all items
func clear_items() -> void:
	_all_items.clear()
	_filtered_items.clear()
	item_list.clear()
	result_label.text = "0 items"


func _on_search_text_changed(_text: String) -> void:
	_search_timer.start()
	search_changed.emit(_text)


func _apply_filter() -> void:
	_filtered_items.clear()

	var search_text := search_edit.text.strip_edges().to_lower()

	for item: Dictionary in _all_items:
		# Category filter
		if not _current_category.is_empty():
			var item_cat: String = item.get("category", "")
			if item_cat != _current_category:
				continue

		# Search filter
		if not search_text.is_empty():
			var item_name: String = item.get("name", "").to_lower()
			var item_id: String = item.get("id", "").to_lower()
			if search_text not in item_name and search_text not in item_id:
				continue

		_filtered_items.append(item)

	_populate_list()


func _populate_list() -> void:
	item_list.clear()

	var display_count := mini(_filtered_items.size(), max_display_items)
	for i in display_count:
		var item: Dictionary = _filtered_items[i]
		var display_name: String = item.get("name", item.get("id", "Unknown"))
		var item_idx := item_list.add_item(display_name)
		item_list.set_item_metadata(item_idx, item)
		item_list.set_item_tooltip(item_idx, item.get("tooltip", item.get("id", "")))

	# Update result count
	if _filtered_items.size() > max_display_items:
		result_label.text = "%d items (showing first %d)" % [_filtered_items.size(), max_display_items]
	else:
		result_label.text = "%d items" % _filtered_items.size()


func _on_item_selected(index: int) -> void:
	var item: Dictionary = item_list.get_item_metadata(index)
	item_selected.emit(item)


func _on_item_activated(index: int) -> void:
	var item: Dictionary = item_list.get_item_metadata(index)
	item_activated.emit(item)


## Get currently selected item
func get_selected_item() -> Dictionary:
	var selected := item_list.get_selected_items()
	if selected.is_empty():
		return {}
	return item_list.get_item_metadata(selected[0])


## Select item by ID
func select_item_by_id(item_id: String) -> void:
	for i in item_list.item_count:
		var item: Dictionary = item_list.get_item_metadata(i)
		if item.get("id", "") == item_id:
			item_list.select(i)
			item_list.ensure_current_is_visible()
			return


## Set search text programmatically
func set_search_text(text: String) -> void:
	search_edit.text = text
	_apply_filter()


## Get current filter state
func get_filter_state() -> Dictionary:
	return {
		"search": search_edit.text,
		"category": _current_category
	}


## Restore filter state
func set_filter_state(state: Dictionary) -> void:
	search_edit.text = state.get("search", "")
	_set_category(state.get("category", ""))
