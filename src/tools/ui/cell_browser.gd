## Interior/exterior cell browser for WorldExplorer.
##
## Extracted from world_explorer.gd (Session 3). Manages cell list building,
## filtering, search, and cell loading. World-affecting side effects (terrain
## visibility, streaming pause/resume, camera positioning) are delegated back
## to world_explorer via callbacks.
##
## Usage:
## [codeblock]
## var browser := CellBrowser.new(callbacks, ui_nodes)
## browser.setup()
## [/codeblock]
class_name CellBrowser
extends RefCounted

const CS := preload("res://src/core/coordinate_system.gd")

# ── Public state (readable by world_explorer) ──

enum ExplorerMode { WORLD, INTERIOR }

var current_mode: ExplorerMode = ExplorerMode.WORLD
var loaded_interior_cell: Node3D = null


# ── Private state ──

var _all_cells: Array[Dictionary] = []  # {name, is_interior, record, ref_count, grid_x, grid_y}
var _filtered_cells: Array[Dictionary] = []
var _current_filter: String = "interior"  # "interior", "exterior", "all"
var _search_timer: Timer = null
var _max_display_items: int = 500

## Callback dictionary — keys are action names, values are Callables on world_explorer
var _cb: Dictionary = {}

## UI node references passed in from world_explorer
var _ui: Dictionary = {}


## Create the cell browser.
## [param callbacks] Dictionary mapping action names to Callables:
##   log, switch_to_interior, switch_to_world, load_cell, load_exterior_cell,
##   position_camera, add_child, get_cell_count
## [param ui_nodes] Dictionary with UI node references:
##   interior_panel, cell_search_edit, cell_list, interior_filter_btn,
##   exterior_filter_btn, all_filter_btn, mode_toggle_btn, interior_container
func _init(callbacks: Dictionary, ui_nodes: Dictionary) -> void:
	_cb = callbacks
	_ui = ui_nodes


## Setup the browser: create timer, connect signals, hide panel.
## Must be called after _init from world_explorer._ready().
func setup(owner: Node) -> void:
	# Create search debounce timer
	_search_timer = Timer.new()
	_search_timer.one_shot = true
	_search_timer.wait_time = 0.2
	_search_timer.timeout.connect(_apply_cell_filter)
	owner.add_child(_search_timer)

	# Create interior container if it doesn't exist
	var container: Node3D = _ui.get("interior_container")
	if not container:
		container = Node3D.new()
		container.name = "InteriorContainer"
		owner.add_child(container)
		_ui["interior_container"] = container

	# Connect UI signals if elements exist
	var mode_btn: Button = _ui.get("mode_toggle_btn")
	if mode_btn:
		mode_btn.pressed.connect(toggle_explorer_mode)

	var search_edit: LineEdit = _ui.get("cell_search_edit")
	if search_edit:
		search_edit.text_changed.connect(_on_cell_search_changed)

	var list: ItemList = _ui.get("cell_list")
	if list:
		list.item_selected.connect(_on_cell_list_selected)
		list.item_activated.connect(_on_cell_list_activated)

	var int_btn: Button = _ui.get("interior_filter_btn")
	if int_btn:
		int_btn.pressed.connect(func() -> void: _set_cell_filter("interior"))

	var ext_btn: Button = _ui.get("exterior_filter_btn")
	if ext_btn:
		ext_btn.pressed.connect(func() -> void: _set_cell_filter("exterior"))

	var all_btn: Button = _ui.get("all_filter_btn")
	if all_btn:
		all_btn.pressed.connect(func() -> void: _set_cell_filter("all"))

	# Hide interior panel by default
	var panel: Panel = _ui.get("interior_panel")
	if panel:
		panel.visible = false


## Toggle between World and Interior modes.
func toggle_explorer_mode() -> void:
	if current_mode == ExplorerMode.WORLD:
		switch_to_interior_mode()
	else:
		switch_to_world_mode()


## Switch to interior cell browsing mode.
func switch_to_interior_mode() -> void:
	current_mode = ExplorerMode.INTERIOR
	_log("[color=cyan]Switched to INTERIOR mode[/color]")

	# Delegate world-affecting side effects to world_explorer
	var cb: Callable = _cb.get("switch_to_interior", Callable())
	if cb.is_valid():
		cb.call()

	# Show interior panel
	var panel: Panel = _ui.get("interior_panel")
	if panel:
		panel.visible = true

	# Update mode button text
	var mode_btn: Button = _ui.get("mode_toggle_btn")
	if mode_btn:
		mode_btn.text = "Switch to World Mode"

	# Build cell list if not already built
	var cell_count_cb: Callable = _cb.get("get_cell_count", Callable())
	var esm_cell_count: int = cell_count_cb.call() if cell_count_cb.is_valid() else 0
	if _all_cells.is_empty() and esm_cell_count > 0:
		_build_cell_list()
		_apply_cell_filter()


## Switch back to world streaming mode.
func switch_to_world_mode() -> void:
	current_mode = ExplorerMode.WORLD
	_log("[color=cyan]Switched to WORLD mode[/color]")

	# Clear loaded interior cell
	if loaded_interior_cell:
		loaded_interior_cell.queue_free()
		loaded_interior_cell = null

	# Delegate world-affecting side effects to world_explorer
	var cb: Callable = _cb.get("switch_to_world", Callable())
	if cb.is_valid():
		cb.call()

	# Hide interior panel
	var panel: Panel = _ui.get("interior_panel")
	if panel:
		panel.visible = false

	# Update mode button text
	var mode_btn: Button = _ui.get("mode_toggle_btn")
	if mode_btn:
		mode_btn.text = "Switch to Interior Mode"


# ── Private methods ──

## Build list of all cells for browser.
func _build_cell_list() -> void:
	_all_cells.clear()

	var cells_dict: Dictionary = ESMManager.cells
	for cell_id: String in cells_dict:
		var cell: CellRecord = cells_dict[cell_id]
		var cell_info := {
			"name": cell.name if cell.is_interior() else "Exterior (%d, %d)" % [cell.grid_x, cell.grid_y],
			"is_interior": cell.is_interior(),
			"record": cell,
			"ref_count": cell.references.size(),
			"grid_x": cell.grid_x,
			"grid_y": cell.grid_y,
		}
		_all_cells.append(cell_info)

	# Sort: interiors by name, exteriors by grid
	_all_cells.sort_custom(func(a: Dictionary, b: Dictionary) -> int:
		if a["is_interior"] != b["is_interior"]:
			return -1 if a["is_interior"] else 1  # Interiors first
		if a["is_interior"]:
			var name_a: String = a["name"]
			var name_b: String = b["name"]
			return name_a.naturalnocasecmp_to(name_b)
		else:
			var grid_x_a: int = a["grid_x"]
			var grid_x_b: int = b["grid_x"]
			if grid_x_a != grid_x_b:
				return grid_x_a - grid_x_b
			var grid_y_a: int = a["grid_y"]
			var grid_y_b: int = b["grid_y"]
			return grid_y_a - grid_y_b
	)

	_log("Built cell list: %d cells (%d interior, %d exterior)" % [
		_all_cells.size(),
		_all_cells.filter(func(c: Dictionary) -> bool: return c["is_interior"]).size(),
		_all_cells.filter(func(c: Dictionary) -> bool: return not c["is_interior"]).size()
	])


## Handle cell search text changed.
func _on_cell_search_changed(_new_text: String) -> void:
	if _search_timer:
		_search_timer.start()


## Set cell filter type (interior/exterior/all).
func _set_cell_filter(filter: String) -> void:
	_current_filter = filter

	# Update button states
	var int_btn: Button = _ui.get("interior_filter_btn")
	if int_btn:
		int_btn.button_pressed = filter == "interior"
	var ext_btn: Button = _ui.get("exterior_filter_btn")
	if ext_btn:
		ext_btn.button_pressed = filter == "exterior"
	var all_btn: Button = _ui.get("all_filter_btn")
	if all_btn:
		all_btn.button_pressed = filter == "all"

	_apply_cell_filter()


## Apply search and filter to cell list.
func _apply_cell_filter() -> void:
	var list: ItemList = _ui.get("cell_list")
	if not list or _all_cells.is_empty():
		return

	_filtered_cells.clear()

	var search_text := ""
	var search_edit: LineEdit = _ui.get("cell_search_edit")
	if search_edit:
		search_text = search_edit.text.strip_edges().to_lower()

	for cell_info: Dictionary in _all_cells:
		# Apply type filter
		if _current_filter == "interior" and not cell_info["is_interior"]:
			continue
		if _current_filter == "exterior" and cell_info["is_interior"]:
			continue

		# Apply search filter
		if not search_text.is_empty():
			var cell_name: String = cell_info["name"]
			var name_lower: String = cell_name.to_lower()
			if name_lower.find(search_text) < 0:
				continue

		_filtered_cells.append(cell_info)

	_populate_cell_list()


## Populate the cell list UI with filtered cells.
func _populate_cell_list() -> void:
	var list: ItemList = _ui.get("cell_list")
	if not list:
		return

	list.clear()

	var display_count := mini(_filtered_cells.size(), _max_display_items)
	for i in display_count:
		var cell_info: Dictionary = _filtered_cells[i]
		var display_name: String = cell_info["name"]
		if cell_info["ref_count"] > 0:
			display_name += " (%d objects)" % cell_info["ref_count"]

		list.add_item(display_name)
		list.set_item_metadata(i, cell_info)

		# Color code: interiors white, exteriors light blue
		if not cell_info["is_interior"]:
			list.set_item_custom_fg_color(i, Color(0.7, 0.85, 1.0))


## Handle cell list item selected.
func _on_cell_list_selected(_index: int) -> void:
	pass  # Could show preview or details


## Handle cell list item activated (double-clicked).
func _on_cell_list_activated(index: int) -> void:
	var list: ItemList = _ui.get("cell_list")
	if not list:
		return

	var cell_info: Dictionary = list.get_item_metadata(index)
	_load_cell(cell_info)


## Load an interior or exterior cell for viewing.
func _load_cell(cell_info: Dictionary) -> void:
	var cell_record: CellRecord = cell_info["record"]

	_log("\n[b]Loading cell: '%s'[/b]" % cell_info["name"])

	# Clear existing interior cell
	if loaded_interior_cell:
		loaded_interior_cell.queue_free()
		loaded_interior_cell = null

	var container: Node3D = _ui.get("interior_container")
	if not container:
		return

	# Clear interior container
	for child in container.get_children():
		child.queue_free()

	var start_time := Time.get_ticks_msec()
	var cell_node: Node3D = null

	# Load the cell via callback to cell_manager
	if cell_info["is_interior"]:
		var load_cb: Callable = _cb.get("load_cell", Callable())
		if load_cb.is_valid():
			cell_node = load_cb.call(cell_record.name)
	else:
		var load_ext_cb: Callable = _cb.get("load_exterior_cell", Callable())
		if load_ext_cb.is_valid():
			cell_node = load_ext_cb.call(cell_info["grid_x"], cell_info["grid_y"])

	if not cell_node:
		_log("[color=red]Failed to load cell[/color]")
		return

	var elapsed := Time.get_ticks_msec() - start_time
	container.add_child(cell_node)
	loaded_interior_cell = cell_node

	_log("[color=green]Cell loaded in %d ms[/color]" % elapsed)
	_log("Objects: %d" % cell_node.get_child_count())

	# Position camera for cell via callback
	var pos_cb: Callable = _cb.get("position_camera", Callable())
	if pos_cb.is_valid():
		pos_cb.call(cell_record)


## Log a message via callback.
func _log(message: String) -> void:
	var cb: Callable = _cb.get("log", Callable())
	if cb.is_valid():
		cb.call(message)
