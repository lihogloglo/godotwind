## AssetViewer - Unified asset visualization tool
##
## Features:
## - Swappable providers for different asset types (NIF, NPC, etc.)
## - Shared 3D preview with orbit camera
## - Common browser with search/filter
## - Provider-specific info and custom tabs
## - Status bar and log output
##
## Usage:
## - Select provider from dropdown
## - Browse/search assets in left panel
## - Click to preview in 3D viewport
## - View info and use provider tabs on right
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_cast", "unsafe_call_argument")
extends Control

# Available providers
const PROVIDERS := {
	"nif": preload("res://src/tools/asset_viewer/providers/nif_provider.gd"),
	"npc": preload("res://src/tools/asset_viewer/providers/npc_provider.gd"),
}

# UI references
@onready var provider_dropdown: OptionButton = $VBox/TopBar/ProviderDropdown
@onready var load_btn: Button = $VBox/TopBar/LoadBtn
@onready var status_label: Label = $VBox/StatusBar/StatusLabel
@onready var hsplit: HSplitContainer = $VBox/HSplit
@onready var left_panel: Panel = $VBox/HSplit/LeftPanel
@onready var right_panel: Panel = $VBox/HSplit/RightPanel

# Components (created dynamically)
var browser: AssetBrowser = null
var preview_3d: Preview3D = null
var tab_container: TabContainer = null
var info_text: RichTextLabel = null
var log_text: RichTextLabel = null

# State
var _current_provider: AssetProvider = null
var _providers_initialized: Dictionary = {}  # provider_name -> AssetProvider
var _current_item: Dictionary = {}


func _ready() -> void:
	_setup_ui()
	_setup_provider_dropdown()
	_connect_signals()
	_set_status("Select a provider and click Load")


func _setup_ui() -> void:
	# Left panel - Browser
	var left_vbox := VBoxContainer.new()
	left_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	left_vbox.offset_left = 8
	left_vbox.offset_top = 8
	left_vbox.offset_right = -8
	left_vbox.offset_bottom = -8
	left_panel.add_child(left_vbox)

	browser = AssetBrowser.new()
	browser.title = "Asset Browser"
	browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_vbox.add_child(browser)

	# Right panel - Preview + Tabs
	var right_vbox := VBoxContainer.new()
	right_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	right_vbox.offset_left = 8
	right_vbox.offset_top = 8
	right_vbox.offset_right = -8
	right_vbox.offset_bottom = -8
	right_panel.add_child(right_vbox)

	# 3D Preview
	preview_3d = Preview3D.new()
	preview_3d.custom_minimum_size = Vector2(400, 300)
	preview_3d.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_3d.size_flags_stretch_ratio = 2.0
	right_vbox.add_child(preview_3d)

	# Tab container
	tab_container = TabContainer.new()
	tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(tab_container)

	# Info tab (always present)
	var info_panel := Panel.new()
	info_panel.name = "Info"
	tab_container.add_child(info_panel)

	info_text = RichTextLabel.new()
	info_text.bbcode_enabled = true
	info_text.set_anchors_preset(Control.PRESET_FULL_RECT)
	info_text.offset_left = 8
	info_text.offset_top = 8
	info_text.offset_right = -8
	info_text.offset_bottom = -8
	info_panel.add_child(info_text)

	# Log tab (always present)
	var log_panel := Panel.new()
	log_panel.name = "Log"
	tab_container.add_child(log_panel)

	log_text = RichTextLabel.new()
	log_text.bbcode_enabled = true
	log_text.scroll_following = true
	log_text.set_anchors_preset(Control.PRESET_FULL_RECT)
	log_text.offset_left = 8
	log_text.offset_top = 8
	log_text.offset_right = -8
	log_text.offset_bottom = -8
	log_panel.add_child(log_text)


func _setup_provider_dropdown() -> void:
	provider_dropdown.clear()
	var idx := 0
	for provider_key: String in PROVIDERS:
		var display_name := provider_key.capitalize()
		if provider_key == "nif":
			display_name = "NIF Meshes"
		elif provider_key == "npc":
			display_name = "NPCs & Creatures"
		provider_dropdown.add_item(display_name, idx)
		provider_dropdown.set_item_metadata(idx, provider_key)
		idx += 1


func _connect_signals() -> void:
	load_btn.pressed.connect(_on_load_pressed)
	provider_dropdown.item_selected.connect(_on_provider_selected)
	browser.item_selected.connect(_on_item_selected)
	browser.item_activated.connect(_on_item_activated)


func _on_provider_selected(_index: int) -> void:
	# Just update UI, actual loading happens on Load button
	var provider_key: String = provider_dropdown.get_item_metadata(provider_dropdown.selected)
	_set_status("Provider: %s - Click Load to initialize" % provider_key)


func _on_load_pressed() -> void:
	var selected_idx := provider_dropdown.selected
	if selected_idx < 0:
		_set_status("Please select a provider first")
		return

	var provider_key: String = provider_dropdown.get_item_metadata(selected_idx)

	# Check if already initialized
	if provider_key in _providers_initialized:
		_switch_provider(_providers_initialized[provider_key])
		return

	# Initialize new provider
	_set_status("Loading %s..." % provider_key)
	load_btn.disabled = true

	var provider_script: GDScript = PROVIDERS[provider_key]
	var provider: AssetProvider = provider_script.new()

	# Connect provider signals
	provider.loading_started.connect(func() -> void:
		_set_status("Loading...")
	)
	provider.loading_progress.connect(func(current: int, total: int, msg: String) -> void:
		_set_status("%s (%d/%d)" % [msg, current, total])
	)
	provider.loading_completed.connect(func() -> void:
		_providers_initialized[provider_key] = provider
		_switch_provider(provider)
		load_btn.disabled = false
	)
	provider.loading_failed.connect(func(error: String) -> void:
		_set_status("[color=red]Error: %s[/color]" % error)
		_log("[color=red]Failed to load provider: %s[/color]" % error)
		load_btn.disabled = false
	)
	provider.log_message.connect(func(text: String) -> void:
		_log(text)
	)

	# Initialize in background
	var error := provider.initialize()
	if error != OK:
		load_btn.disabled = false


func _switch_provider(provider: AssetProvider) -> void:
	_current_provider = provider

	# Update browser
	browser.set_categories(provider.get_categories())
	browser.set_items(provider.get_items())

	# Clear preview
	preview_3d.clear_object()
	info_text.text = "[b]Select an item to preview[/b]"

	# Rebuild custom tabs
	_rebuild_custom_tabs()

	_set_status("Ready - %s items" % browser._filtered_items.size())
	_log("[color=green]Switched to %s[/color]" % provider.provider_name)


func _rebuild_custom_tabs() -> void:
	# Remove old custom tabs (keep Info and Log)
	while tab_container.get_child_count() > 2:
		var child := tab_container.get_child(2)
		tab_container.remove_child(child)
		child.queue_free()

	if not _current_provider:
		return

	# Add provider's custom tabs
	for tab_def: Dictionary in _current_provider.get_custom_tabs():
		var tab_name: String = tab_def.get("name", "Tab")
		var panel := Panel.new()
		panel.name = tab_name
		tab_container.add_child(panel)


func _on_item_selected(item: Dictionary) -> void:
	_current_item = item
	if _current_provider:
		_current_provider.on_item_selected(item)


func _on_item_activated(item: Dictionary) -> void:
	if not _current_provider:
		return

	_current_item = item
	_set_status("Loading: %s" % item.get("name", "Unknown"))

	# Load the item
	var node := _current_provider.load_item(item)
	if node:
		preview_3d.display_object(node)
		info_text.text = _current_provider.get_info_text(item)
		_rebuild_custom_tab_contents()
		_set_status("Loaded: %s" % item.get("name", "Unknown"))
	else:
		_set_status("[color=red]Failed to load: %s[/color]" % item.get("name", "Unknown"))


func _rebuild_custom_tab_contents() -> void:
	if not _current_provider:
		return

	var custom_tabs := _current_provider.get_custom_tabs()
	for i in custom_tabs.size():
		var tab_def: Dictionary = custom_tabs[i]
		var tab_idx := i + 2  # Skip Info and Log
		if tab_idx >= tab_container.get_child_count():
			continue

		var panel: Panel = tab_container.get_child(tab_idx) as Panel

		# Clear existing content
		for child in panel.get_children():
			child.queue_free()

		# Build new content
		var build_func: Callable = tab_def.get("build_func")
		if build_func.is_valid():
			build_func.call(panel, _current_item)


func _log(text: String) -> void:
	if log_text:
		log_text.append_text(text + "\n")
	# Also print to console
	var plain := text
	for tag in ["[b]", "[/b]", "[color=red]", "[color=green]", "[color=yellow]", "[/color]"]:
		plain = plain.replace(tag, "")
	print("[AssetViewer] %s" % plain)


func _set_status(text: String) -> void:
	if status_label:
		status_label.text = text


func _input(event: InputEvent) -> void:
	# Handle keyboard shortcuts
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and key.keycode == KEY_C:
			# Toggle collision (if NIF provider)
			if _current_provider and _current_provider is NIFProvider:
				var nif: NIFProvider = _current_provider as NIFProvider
				nif._show_collision = not nif._show_collision
				nif._update_collision_display()
				_log("Collision: %s" % ("ON" if nif._show_collision else "OFF"))
