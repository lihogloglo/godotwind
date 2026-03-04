## Builds all foldable UI panels for WorldExplorer.
##
## Extracted from world_explorer.gd. Constructs the Performance, Rendering,
## Navigation, Terrain, Ocean, Shader Effects, and Debug panels inside a
## ScrollContainer, and stores widget references so world_explorer can
## read/update them each frame.
##
## Usage:
## [codeblock]
## var panels := ExplorerPanels.new(callbacks)
## panels.build(stats_panel_vbox)
## [/codeblock]
class_name ExplorerPanels
extends RefCounted

const FoldablePanelScript := preload("res://src/tools/ui/foldable_panel.gd")

# ── Public widget references (read by world_explorer for dynamic updates) ──

## ScrollContainer that holds all panels
var panel_scroll: ScrollContainer = null
## VBox inside the scroll container
var panel_vbox: VBoxContainer = null

## Panel instances
var performance_panel: FoldablePanel = null
var visibility_panel: FoldablePanel = null
var navigation_panel: FoldablePanel = null
var terrain_panel: FoldablePanel = null
var ocean_panel: FoldablePanel = null
var shader_panel: FoldablePanel = null
var debug_panel: FoldablePanel = null

## Rendering panel widgets
var show_characters_toggle: CheckBox = null
var show_ocean_toggle: CheckBox = null
var show_sky_toggle: CheckBox = null
var resolution_btn: OptionButton = null

## Ocean panel widgets
var water_quality_btn: OptionButton = null
var wave_scale_slider: HSlider = null
var debug_shore_toggle: CheckBox = null
var ocean_controls_container: VBoxContainer = null

## Shader panel widgets
var fog_toggle: CheckBox = null
var clouds_toggle: CheckBox = null
var color_grading_toggle: CheckBox = null

## Debug panel widgets
var lod_mode_btn: Button = null


# ── Private ──

## Callback dictionary — keys are signal names, values are Callables on world_explorer
var _cb: Dictionary = {}

## Cached initial state values from world_explorer
var _initial_state: Dictionary = {}


## Create the panel builder.
## [param callbacks] Dictionary mapping signal/action names to Callables:
##   show_characters_toggled, show_ocean_toggled, show_sky_toggled,
##   resolution_changed, water_quality_changed,
##   wind_speed_changed, wind_dir_changed, wave_scale_changed,
##   choppiness_changed, debug_shore_toggled,
##   fog_toggled, fog_intensity_changed, clouds_toggled, cloud_coverage_changed,
##   color_grading_toggled, morrowind_preset, dramatic_preset, reset_color_grading,
##   show_chunks_toggled, show_tiers_toggled, show_cells_toggled,
##   show_lod_levels_toggled, lod_mode_pressed, dump_profiling,
##   teleport_to_cell, adjust_view_distance, preprocess_pressed
## [param initial_state] Dictionary with initial toggle/value states:
##   show_characters, show_ocean, show_sky, view_distance,
##   show_chunk_debug, show_tier_debug, show_cell_debug
func _init(callbacks: Dictionary, initial_state: Dictionary = {}) -> void:
	_cb = callbacks
	_initial_state = initial_state


## Build all panels inside the given VBox (stats_panel/VBox).
## Hides the old StatsText node and inserts a ScrollContainer with panels.
func build(vbox: VBoxContainer) -> void:
	if not vbox:
		return

	# Hide old static content
	var stats_text_node: Control = vbox.get_node_or_null("StatsText")
	if stats_text_node:
		stats_text_node.visible = false

	# Create scroll container for panels
	panel_scroll = ScrollContainer.new()
	panel_scroll.name = "PanelScroll"
	panel_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	panel_vbox = VBoxContainer.new()
	panel_vbox.name = "PanelVBox"
	panel_vbox.add_theme_constant_override("separation", 4)
	panel_scroll.add_child(panel_vbox)

	# Create foldable panels
	_create_performance_panel()
	_create_visibility_panel()
	_create_navigation_panel()
	_create_terrain_panel()
	_create_ocean_panel()
	_create_shader_panel()
	_create_debug_panel()

	# Insert scroll container after title
	var separator_idx := 2  # After title and first separator
	vbox.add_child(panel_scroll)
	vbox.move_child(panel_scroll, separator_idx)


## Helper to create a labeled slider row
func create_slider_row(parent: Control, label_text: String, min_val: float, max_val: float, default_val: float, callback: Callable) -> HSlider:
	var row := HBoxContainer.new()

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 40
	label.add_theme_font_size_override("font_size", 11)
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.value = default_val
	slider.step = 1.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.x = 120
	slider.value_changed.connect(callback)
	row.add_child(slider)

	var value_label := Label.new()
	value_label.name = "Value"
	value_label.text = "%.1f" % default_val
	value_label.custom_minimum_size.x = 35
	value_label.add_theme_font_size_override("font_size", 11)
	row.add_child(value_label)

	parent.add_child(row)
	return slider


## Update value label next to slider
func update_slider_label(slider: HSlider, value: float) -> void:
	var row: HBoxContainer = slider.get_parent()
	var value_label: Label = row.get_node_or_null("Value")
	if value_label:
		value_label.text = "%.1f" % value


# ── Private panel builders ──

func _create_performance_panel() -> void:
	performance_panel = FoldablePanelScript.new("Performance", false)

	var fps_label := Label.new()
	fps_label.name = "FPSLabel"
	fps_label.add_theme_font_size_override("font_size", 11)
	fps_label.text = "FPS: --"
	performance_panel.add_content(fps_label)

	var timing_label := Label.new()
	timing_label.name = "TimingLabel"
	timing_label.add_theme_font_size_override("font_size", 11)
	timing_label.text = "Frame: -- ms | P95: -- ms"
	performance_panel.add_content(timing_label)

	var render_label := Label.new()
	render_label.name = "RenderLabel"
	render_label.add_theme_font_size_override("font_size", 11)
	render_label.text = "Draw calls: -- | Tris: --k"
	performance_panel.add_content(render_label)

	var memory_label := Label.new()
	memory_label.name = "MemoryLabel"
	memory_label.add_theme_font_size_override("font_size", 11)
	memory_label.text = "Memory: -- MB"
	performance_panel.add_content(memory_label)

	panel_vbox.add_child(performance_panel)


func _create_visibility_panel() -> void:
	visibility_panel = FoldablePanelScript.new("Rendering", false)

	# Row 1: NPCs only (Models always visible now)
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 8)

	show_characters_toggle = CheckBox.new()
	show_characters_toggle.text = "NPCs [N]"
	show_characters_toggle.button_pressed = _initial_state.get("show_characters", false)
	show_characters_toggle.toggled.connect(_cb.get("show_characters_toggled", Callable()))
	show_characters_toggle.tooltip_text = "Toggle NPCs and creatures (shortcut: N)"
	row1.add_child(show_characters_toggle)

	visibility_panel.add_content(row1)

	# Row 2: Ocean, Sky
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)

	show_ocean_toggle = CheckBox.new()
	show_ocean_toggle.text = "Ocean [O]"
	show_ocean_toggle.button_pressed = _initial_state.get("show_ocean", false)
	show_ocean_toggle.toggled.connect(_cb.get("show_ocean_toggled", Callable()))
	show_ocean_toggle.tooltip_text = "Toggle ocean (shortcut: O)"
	row2.add_child(show_ocean_toggle)

	show_sky_toggle = CheckBox.new()
	show_sky_toggle.text = "Sky [K]"
	show_sky_toggle.button_pressed = _initial_state.get("show_sky", false)
	show_sky_toggle.toggled.connect(_cb.get("show_sky_toggled", Callable()))
	show_sky_toggle.tooltip_text = "Toggle sky/day-night cycle (shortcut: K)"
	row2.add_child(show_sky_toggle)

	visibility_panel.add_content(row2)

	# Row 3: Resolution dropdown
	var res_row := HBoxContainer.new()
	var res_label := Label.new()
	res_label.text = "Resolution:"
	res_label.add_theme_font_size_override("font_size", 11)
	res_label.custom_minimum_size.x = 70
	res_row.add_child(res_label)

	resolution_btn = OptionButton.new()
	resolution_btn.add_item("720p", 0)
	resolution_btn.add_item("900p", 1)
	resolution_btn.add_item("1080p", 2)
	resolution_btn.add_item("1440p", 3)
	resolution_btn.add_item("Full", 4)
	resolution_btn.selected = 2
	resolution_btn.item_selected.connect(_cb.get("resolution_changed", Callable()))
	resolution_btn.tooltip_text = "Window resolution"
	resolution_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	res_row.add_child(resolution_btn)

	visibility_panel.add_content(res_row)

	panel_vbox.add_child(visibility_panel)


func _create_navigation_panel() -> void:
	navigation_panel = FoldablePanelScript.new("Navigation", true)  # Start folded

	# Camera info (updated dynamically)
	var camera_label := Label.new()
	camera_label.name = "CameraLabel"
	camera_label.add_theme_font_size_override("font_size", 11)
	camera_label.text = "Cell: (0, 0) | Mode: Fly"
	navigation_panel.add_content(camera_label)

	# View distance control
	var view_row := HBoxContainer.new()
	var view_label := Label.new()
	view_label.text = "View dist:"
	view_label.add_theme_font_size_override("font_size", 11)
	view_label.custom_minimum_size.x = 60
	view_row.add_child(view_label)

	var view_distance: int = _initial_state.get("view_distance", 5)

	var minus_btn := Button.new()
	minus_btn.text = "-"
	minus_btn.custom_minimum_size.x = 30
	var adjust_cb: Callable = _cb.get("adjust_view_distance", Callable())
	minus_btn.pressed.connect(func() -> void: adjust_cb.call(-1))
	view_row.add_child(minus_btn)

	var dist_label := Label.new()
	dist_label.name = "DistLabel"
	dist_label.text = "%d cells" % view_distance
	dist_label.add_theme_font_size_override("font_size", 11)
	dist_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dist_label.custom_minimum_size.x = 60
	view_row.add_child(dist_label)

	var plus_btn := Button.new()
	plus_btn.text = "+"
	plus_btn.custom_minimum_size.x = 30
	plus_btn.pressed.connect(func() -> void: adjust_cb.call(1))
	view_row.add_child(plus_btn)

	navigation_panel.add_content(view_row)

	# Quick teleport buttons
	var teleport_label := Label.new()
	teleport_label.text = "Quick Teleport:"
	teleport_label.add_theme_font_size_override("font_size", 11)
	navigation_panel.add_content(teleport_label)

	var teleport_cb: Callable = _cb.get("teleport_to_cell", Callable())

	var btn_row1 := HBoxContainer.new()
	btn_row1.add_theme_constant_override("separation", 4)

	var seyda_btn := Button.new()
	seyda_btn.text = "Seyda Neen"
	seyda_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seyda_btn.pressed.connect(func() -> void: teleport_cb.call(-2, -9))
	btn_row1.add_child(seyda_btn)

	var balmora_btn_new := Button.new()
	balmora_btn_new.text = "Balmora"
	balmora_btn_new.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	balmora_btn_new.pressed.connect(func() -> void: teleport_cb.call(-3, -2))
	btn_row1.add_child(balmora_btn_new)

	navigation_panel.add_content(btn_row1)

	var btn_row2 := HBoxContainer.new()
	btn_row2.add_theme_constant_override("separation", 4)

	var vivec_btn_new := Button.new()
	vivec_btn_new.text = "Vivec"
	vivec_btn_new.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vivec_btn_new.pressed.connect(func() -> void: teleport_cb.call(5, -6))
	btn_row2.add_child(vivec_btn_new)

	var origin_btn_new := Button.new()
	origin_btn_new.text = "Origin"
	origin_btn_new.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	origin_btn_new.pressed.connect(func() -> void: teleport_cb.call(0, 0))
	btn_row2.add_child(origin_btn_new)

	navigation_panel.add_content(btn_row2)

	panel_vbox.add_child(navigation_panel)


func _create_terrain_panel() -> void:
	terrain_panel = FoldablePanelScript.new("Terrain", true)  # Start folded

	var terrain_label := Label.new()
	terrain_label.name = "TerrainLabel"
	terrain_label.add_theme_font_size_override("font_size", 11)
	terrain_label.text = "Regions: --"
	terrain_panel.add_content(terrain_label)

	var status_lbl := Label.new()
	status_lbl.name = "PreprocessStatusLabel"
	status_lbl.add_theme_font_size_override("font_size", 11)
	status_lbl.text = "Status: Checking..."
	terrain_panel.add_content(status_lbl)

	var preprocess_btn_new := Button.new()
	preprocess_btn_new.name = "PreprocessBtnNew"
	preprocess_btn_new.text = "Preprocess Terrain"
	preprocess_btn_new.pressed.connect(_cb.get("preprocess_pressed", Callable()))
	terrain_panel.add_content(preprocess_btn_new)

	panel_vbox.add_child(terrain_panel)


func _create_ocean_panel() -> void:
	ocean_panel = FoldablePanelScript.new("Ocean Settings", true)  # Start folded

	# Water quality dropdown
	var quality_row := HBoxContainer.new()
	var quality_label := Label.new()
	quality_label.text = "Quality:"
	quality_label.add_theme_font_size_override("font_size", 11)
	quality_label.custom_minimum_size.x = 55
	quality_row.add_child(quality_label)

	water_quality_btn = OptionButton.new()
	water_quality_btn.add_item("Auto", -1)
	water_quality_btn.add_item("Flat", 0)
	water_quality_btn.add_item("Standard", 1)
	water_quality_btn.add_item("High (FFT)", 2)
	water_quality_btn.selected = 0  # Auto by default
	water_quality_btn.item_selected.connect(_cb.get("water_quality_changed", Callable()))
	water_quality_btn.tooltip_text = "Water quality:\n- Flat: Simple plane (fallback)\n- Standard: Analytical Gerstner waves\n- High: FFT compute ocean (JONSWAP spectrum)"
	water_quality_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quality_row.add_child(water_quality_btn)

	ocean_panel.add_content(quality_row)

	# Ocean controls container (for sliders - populated when ocean is enabled)
	ocean_controls_container = VBoxContainer.new()
	ocean_controls_container.name = "OceanControls"
	ocean_controls_container.visible = false  # Hidden until ocean is enabled

	# Wave Scale slider
	wave_scale_slider = create_slider_row(ocean_controls_container, "Scale:", 0.0, 3.0, 1.0, _cb.get("wave_scale_changed", Callable()))
	wave_scale_slider.step = 0.1
	wave_scale_slider.tooltip_text = "Wave height multiplier"

	# Debug shore mask toggle
	debug_shore_toggle = CheckBox.new()
	debug_shore_toggle.text = "Debug Shore Mask"
	debug_shore_toggle.button_pressed = false
	debug_shore_toggle.toggled.connect(_cb.get("debug_shore_toggled", Callable()))
	debug_shore_toggle.tooltip_text = "Visualize shore damping"
	ocean_controls_container.add_child(debug_shore_toggle)

	ocean_panel.add_content(ocean_controls_container)

	panel_vbox.add_child(ocean_panel)


func _create_shader_panel() -> void:
	shader_panel = FoldablePanelScript.new("Shader Effects", true)  # Start folded

	# Info label
	var info_label := Label.new()
	info_label.add_theme_font_size_override("font_size", 10)
	info_label.text = "Post-processing effects (VAIO-style)"
	info_label.modulate = Color(0.7, 0.7, 0.7)
	shader_panel.add_content(info_label)

	# Volumetric Fog toggle
	fog_toggle = CheckBox.new()
	fog_toggle.text = "Volumetric Fog"
	fog_toggle.button_pressed = false
	fog_toggle.toggled.connect(_cb.get("fog_toggled", Callable()))
	fog_toggle.tooltip_text = "Ray-marched volumetric fog with 3D noise"
	shader_panel.add_content(fog_toggle)

	# Fog intensity slider
	var fog_row := HBoxContainer.new()
	var fog_label := Label.new()
	fog_label.text = "  Intensity:"
	fog_label.add_theme_font_size_override("font_size", 11)
	fog_label.custom_minimum_size.x = 70
	fog_row.add_child(fog_label)

	var fog_slider := HSlider.new()
	fog_slider.name = "FogIntensitySlider"
	fog_slider.min_value = 0.0
	fog_slider.max_value = 2.0
	fog_slider.step = 0.05
	fog_slider.value = 0.5
	fog_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fog_slider.value_changed.connect(_cb.get("fog_intensity_changed", Callable()))
	fog_row.add_child(fog_slider)
	shader_panel.add_content(fog_row)

	# Volumetric Clouds toggle
	clouds_toggle = CheckBox.new()
	clouds_toggle.text = "Volumetric Clouds"
	clouds_toggle.button_pressed = false
	clouds_toggle.toggled.connect(_cb.get("clouds_toggled", Callable()))
	clouds_toggle.tooltip_text = "Ray-marched volumetric clouds"
	shader_panel.add_content(clouds_toggle)

	# Cloud coverage slider
	var cloud_row := HBoxContainer.new()
	var cloud_label := Label.new()
	cloud_label.text = "  Coverage:"
	cloud_label.add_theme_font_size_override("font_size", 11)
	cloud_label.custom_minimum_size.x = 70
	cloud_row.add_child(cloud_label)

	var cloud_slider := HSlider.new()
	cloud_slider.name = "CloudCoverageSlider"
	cloud_slider.min_value = 0.0
	cloud_slider.max_value = 1.0
	cloud_slider.step = 0.05
	cloud_slider.value = 0.5
	cloud_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cloud_slider.value_changed.connect(_cb.get("cloud_coverage_changed", Callable()))
	cloud_row.add_child(cloud_slider)
	shader_panel.add_content(cloud_row)

	# Separator
	var sep := HSeparator.new()
	shader_panel.add_content(sep)

	# Color Grading toggle
	color_grading_toggle = CheckBox.new()
	color_grading_toggle.text = "Color Grading"
	color_grading_toggle.button_pressed = false
	color_grading_toggle.toggled.connect(_cb.get("color_grading_toggled", Callable()))
	color_grading_toggle.tooltip_text = "Color correction and grading"
	shader_panel.add_content(color_grading_toggle)

	# Preset buttons
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 4)

	var morrowind_btn := Button.new()
	morrowind_btn.text = "Morrowind"
	morrowind_btn.pressed.connect(_cb.get("morrowind_preset", Callable()))
	morrowind_btn.tooltip_text = "Warm Morrowind-style tones"
	preset_row.add_child(morrowind_btn)

	var dramatic_btn := Button.new()
	dramatic_btn.text = "Dramatic"
	dramatic_btn.pressed.connect(_cb.get("dramatic_preset", Callable()))
	dramatic_btn.tooltip_text = "High contrast dramatic look"
	preset_row.add_child(dramatic_btn)

	var reset_btn := Button.new()
	reset_btn.text = "Reset"
	reset_btn.pressed.connect(_cb.get("reset_color_grading", Callable()))
	reset_btn.tooltip_text = "Reset to defaults"
	preset_row.add_child(reset_btn)

	shader_panel.add_content(preset_row)

	panel_vbox.add_child(shader_panel)


func _create_debug_panel() -> void:
	debug_panel = FoldablePanelScript.new("Debug Overlays", true)  # Start folded

	# Chunk visualization toggle
	var chunk_toggle := CheckBox.new()
	chunk_toggle.text = "Show Chunks (FAR tier)"
	chunk_toggle.button_pressed = _initial_state.get("show_chunk_debug", false)
	chunk_toggle.toggled.connect(_cb.get("show_chunks_toggled", Callable()))
	chunk_toggle.tooltip_text = "Visualize quadtree chunk boundaries (8x8 cells each)"
	debug_panel.add_content(chunk_toggle)

	# Tier visualization toggle
	var tier_toggle := CheckBox.new()
	tier_toggle.text = "Show Distance Tiers"
	tier_toggle.button_pressed = _initial_state.get("show_tier_debug", false)
	tier_toggle.toggled.connect(_cb.get("show_tiers_toggled", Callable()))
	tier_toggle.tooltip_text = "Visualize NEAR/MID/FAR tier zones with colors"
	debug_panel.add_content(tier_toggle)

	# Cell grid visualization toggle
	var cell_toggle := CheckBox.new()
	cell_toggle.text = "Show Cell Grid"
	cell_toggle.button_pressed = _initial_state.get("show_cell_debug", false)
	cell_toggle.toggled.connect(_cb.get("show_cells_toggled", Callable()))
	cell_toggle.tooltip_text = "Visualize individual cell boundaries and coordinates"
	debug_panel.add_content(cell_toggle)

	# LOD level visualization toggle
	var lod_toggle := CheckBox.new()
	lod_toggle.text = "Show LOD Levels"
	lod_toggle.button_pressed = false
	lod_toggle.toggled.connect(_cb.get("show_lod_levels_toggled", Callable()))
	lod_toggle.tooltip_text = "Color batched LODs: Green=LOD0/NEAR, Yellow=LOD1, Orange=LOD2, Red=LOD3/FAR"
	debug_panel.add_content(lod_toggle)

	# LOD mode toggle button (actual vs expected)
	lod_mode_btn = Button.new()
	lod_mode_btn.text = "LOD Mode: Actual"
	lod_mode_btn.pressed.connect(_cb.get("lod_mode_pressed", Callable()))
	lod_mode_btn.tooltip_text = "Toggle between Actual (what IS rendered) and Expected (what SHOULD be by distance)"
	debug_panel.add_content(lod_mode_btn)

	# Separator
	var sep := HSeparator.new()
	debug_panel.add_content(sep)

	# Debug info (updated dynamically)
	var debug_info_label := Label.new()
	debug_info_label.name = "DebugInfoLabel"
	debug_info_label.add_theme_font_size_override("font_size", 10)
	debug_info_label.text = "Loaded cells: -- | Queue: --"
	debug_panel.add_content(debug_info_label)

	# Object Distance Manager stats
	var odm_label := Label.new()
	odm_label.name = "ODMLabel"
	odm_label.add_theme_font_size_override("font_size", 10)
	odm_label.text = "ODM: -- tracked | NEAR: -- MID: -- FAR: --"
	debug_panel.add_content(odm_label)

	# Streaming profiler summary
	var profiler_label := Label.new()
	profiler_label.name = "ProfilerLabel"
	profiler_label.add_theme_font_size_override("font_size", 10)
	profiler_label.text = "Profiler: --"
	debug_panel.add_content(profiler_label)

	# F4 dump button
	var dump_btn := Button.new()
	dump_btn.text = "Dump Profiling Report [F4]"
	dump_btn.pressed.connect(_cb.get("dump_profiling", Callable()))
	debug_panel.add_content(dump_btn)

	panel_vbox.add_child(debug_panel)
