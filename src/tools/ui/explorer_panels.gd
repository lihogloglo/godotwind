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

## Rendering Quality panel
var quality_panel: FoldablePanel = null
var taa_toggle: CheckBox = null
var ssao_toggle: CheckBox = null
var ssil_toggle: CheckBox = null
var glow_toggle: CheckBox = null
var native_vfog_toggle: CheckBox = null
var depth_fog_toggle: CheckBox = null
var shadow_cascade_toggle: CheckBox = null
var tonemapper_btn: OptionButton = null

## Shader panel widgets
var fog_toggle: CheckBox = null
var clouds_toggle: CheckBox = null
var color_grading_toggle: CheckBox = null

## Weather panel widgets
var weather_panel: FoldablePanel = null
var weather_enabled_toggle: CheckBox = null
var weather_preset_btn: OptionButton = null
var weather_type_btn: OptionButton = null
var fog_density_slider: HSlider = null
var cloud_coverage_slider: HSlider = null
var time_of_day_slider: HSlider = null
var time_scale_slider: HSlider = null
var time_pause_toggle: CheckBox = null
var weather_status_label: Label = null

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
	_create_weather_panel()
	_create_quality_panel()
	_create_shader_panel()
	_create_debug_panel()

	# Disable keyboard focus on all controls — prevents spacebar/keys from
	# toggling checkboxes and buttons while playing the game
	_strip_focus(panel_scroll)

	# Insert scroll container after title
	var separator_idx := 2  # After title and first separator
	vbox.add_child(panel_scroll)
	vbox.move_child(panel_scroll, separator_idx)


## Recursively disable keyboard focus on all child controls.
## Prevents spacebar/enter from toggling UI while playing.
func _strip_focus(node: Node) -> void:
	if node is Control:
		(node as Control).focus_mode = Control.FOCUS_NONE
	for child in node.get_children():
		_strip_focus(child)


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


func _create_weather_panel() -> void:
	weather_panel = FoldablePanelScript.new("Weather", true)  # Start folded

	# Enable toggle
	weather_enabled_toggle = CheckBox.new()
	weather_enabled_toggle.text = "Enable Weather"
	weather_enabled_toggle.button_pressed = false
	weather_enabled_toggle.toggled.connect(_cb.get("weather_toggled", Callable()))
	weather_enabled_toggle.tooltip_text = "Enable dynamic weather system"
	weather_panel.add_content(weather_enabled_toggle)

	# Weather presets dropdown (above individual controls)
	var preset_row := HBoxContainer.new()
	var preset_label := Label.new()
	preset_label.text = "Preset:"
	preset_label.add_theme_font_size_override("font_size", 11)
	preset_label.custom_minimum_size.x = 55
	preset_row.add_child(preset_label)

	weather_preset_btn = OptionButton.new()
	weather_preset_btn.add_item("Custom")
	weather_preset_btn.add_item("Morrowind Default")
	weather_preset_btn.add_item("Clear Day")
	weather_preset_btn.add_item("Foggy Morning")
	weather_preset_btn.add_item("Stormy Night")
	weather_preset_btn.add_item("Ashstorm")
	weather_preset_btn.add_item("Blizzard")
	weather_preset_btn.add_item("Golden Hour")
	weather_preset_btn.selected = 0
	weather_preset_btn.item_selected.connect(_cb.get("weather_preset_changed", Callable()))
	weather_preset_btn.tooltip_text = "Quick presets that set weather type + time + speed"
	weather_preset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_row.add_child(weather_preset_btn)
	weather_panel.add_content(preset_row)

	# Weather type dropdown
	var type_row := HBoxContainer.new()
	var type_label := Label.new()
	type_label.text = "Type:"
	type_label.add_theme_font_size_override("font_size", 11)
	type_label.custom_minimum_size.x = 55
	type_row.add_child(type_label)

	weather_type_btn = OptionButton.new()
	weather_type_btn.add_item("Auto", -1)
	for i: int in WeatherTypes.TYPE_NAMES.size():
		weather_type_btn.add_item(WeatherTypes.TYPE_NAMES[i], i)
	weather_type_btn.selected = 0
	weather_type_btn.item_selected.connect(_cb.get("weather_type_changed", Callable()))
	weather_type_btn.tooltip_text = "Weather type override (Auto = region-based)"
	weather_type_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	type_row.add_child(weather_type_btn)
	weather_panel.add_content(type_row)

	# Time of day slider (0-24)
	time_of_day_slider = create_slider_row(weather_panel.get_content_container(), "Time:", 0.0, 24.0, 8.0, _cb.get("time_of_day_changed", Callable()))
	time_of_day_slider.step = 0.1
	time_of_day_slider.tooltip_text = "Game hour (0 = midnight, 12 = noon)"

	# Time scale slider
	time_scale_slider = create_slider_row(weather_panel.get_content_container(), "Speed:", 0.0, 300.0, 30.0, _cb.get("time_scale_changed", Callable()))
	time_scale_slider.step = 5.0
	time_scale_slider.tooltip_text = "Time scale: game-seconds per real-second"

	# Pause toggle
	time_pause_toggle = CheckBox.new()
	time_pause_toggle.text = "Pause Time"
	time_pause_toggle.button_pressed = false
	time_pause_toggle.toggled.connect(_cb.get("time_pause_toggled", Callable()))
	weather_panel.add_content(time_pause_toggle)

	# Fog density multiplier slider
	fog_density_slider = create_slider_row(weather_panel.get_content_container(), "Fog:", 0.1, 3.0, 1.0, _cb.get("fog_density_changed", Callable()))
	fog_density_slider.step = 0.1
	fog_density_slider.tooltip_text = "Fog density multiplier (1.0 = default, higher = thicker)"

	# Cloud coverage slider
	cloud_coverage_slider = create_slider_row(weather_panel.get_content_container(), "Clouds:", 0.0, 1.0, 0.4, _cb.get("cloud_coverage_changed", Callable()))
	cloud_coverage_slider.step = 0.05
	cloud_coverage_slider.tooltip_text = "Cloud coverage (overridden by weather system when active)"

	# Status label
	weather_status_label = Label.new()
	weather_status_label.name = "WeatherStatus"
	weather_status_label.text = "Weather: Clear | Hour: 8.0"
	weather_status_label.add_theme_font_size_override("font_size", 10)
	weather_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	weather_panel.add_content(weather_status_label)

	panel_vbox.add_child(weather_panel)


func _create_quality_panel() -> void:
	quality_panel = FoldablePanelScript.new("Rendering Quality", true)  # Start folded

	# Info label
	var info_label := Label.new()
	info_label.add_theme_font_size_override("font_size", 10)
	info_label.text = "Native Godot rendering features"
	info_label.modulate = Color(0.7, 0.7, 0.7)
	quality_panel.add_content(info_label)

	# TAA toggle
	taa_toggle = CheckBox.new()
	taa_toggle.text = "TAA (Anti-Aliasing)"
	taa_toggle.button_pressed = false
	taa_toggle.toggled.connect(_cb.get("taa_toggled", Callable()))
	taa_toggle.tooltip_text = "Temporal Anti-Aliasing — eliminates edge shimmer. May ghost on ocean surface."
	quality_panel.add_content(taa_toggle)

	# SSAO toggle
	ssao_toggle = CheckBox.new()
	ssao_toggle.text = "SSAO"
	ssao_toggle.button_pressed = false
	ssao_toggle.toggled.connect(_cb.get("ssao_toggled", Callable()))
	ssao_toggle.tooltip_text = "Screen-Space Ambient Occlusion — contact shadows in crevices and corners"
	quality_panel.add_content(ssao_toggle)

	# SSIL toggle
	ssil_toggle = CheckBox.new()
	ssil_toggle.text = "SSIL"
	ssil_toggle.button_pressed = false
	ssil_toggle.toggled.connect(_cb.get("ssil_toggled", Callable()))
	ssil_toggle.tooltip_text = "Screen-Space Indirect Lighting — color bleeding between nearby surfaces"
	quality_panel.add_content(ssil_toggle)

	# Glow toggle
	glow_toggle = CheckBox.new()
	glow_toggle.text = "Glow / Bloom"
	glow_toggle.button_pressed = false
	glow_toggle.toggled.connect(_cb.get("glow_toggled", Callable()))
	glow_toggle.tooltip_text = "HDR bloom on bright surfaces (sun, torches, lava)"
	quality_panel.add_content(glow_toggle)

	# Separator
	var sep1 := HSeparator.new()
	quality_panel.add_content(sep1)

	# Volumetric Fog (native, god rays)
	native_vfog_toggle = CheckBox.new()
	native_vfog_toggle.text = "Volumetric Fog (god rays)"
	native_vfog_toggle.button_pressed = false
	native_vfog_toggle.toggled.connect(_cb.get("native_vfog_toggled", Callable()))
	native_vfog_toggle.tooltip_text = "Godot native volumetric fog — produces god rays via forward scattering"
	quality_panel.add_content(native_vfog_toggle)

	# Depth Fog (aerial perspective)
	depth_fog_toggle = CheckBox.new()
	depth_fog_toggle.text = "Depth Fog (aerial perspective)"
	depth_fog_toggle.button_pressed = false
	depth_fog_toggle.toggled.connect(_cb.get("depth_fog_toggled", Callable()))
	depth_fog_toggle.tooltip_text = "Distance haze — makes far objects fade to sky color for depth"
	quality_panel.add_content(depth_fog_toggle)

	# Separator
	var sep2 := HSeparator.new()
	quality_panel.add_content(sep2)

	# Shadow cascades
	shadow_cascade_toggle = CheckBox.new()
	shadow_cascade_toggle.text = "Shadow 4-Split Cascades"
	shadow_cascade_toggle.button_pressed = false
	shadow_cascade_toggle.toggled.connect(_cb.get("shadow_cascades_toggled", Callable()))
	shadow_cascade_toggle.tooltip_text = "4 shadow cascades with blending — sharper nearby, softer distant shadows"
	quality_panel.add_content(shadow_cascade_toggle)

	# Tonemapper dropdown
	var tone_row := HBoxContainer.new()
	var tone_label := Label.new()
	tone_label.text = "Tonemapper:"
	tone_label.add_theme_font_size_override("font_size", 11)
	tone_label.custom_minimum_size.x = 75
	tone_row.add_child(tone_label)

	tonemapper_btn = OptionButton.new()
	tonemapper_btn.add_item("Filmic", 0)
	tonemapper_btn.add_item("ACES", 1)
	tonemapper_btn.add_item("AgX", 2)
	tonemapper_btn.add_item("Linear", 3)
	tonemapper_btn.selected = 0
	tonemapper_btn.item_selected.connect(_cb.get("tonemapper_changed", Callable()))
	tonemapper_btn.tooltip_text = "Tonemapping algorithm:\n- Filmic: balanced (current)\n- ACES: cinematic\n- AgX: best hue preservation (Godot 4.6)\n- Linear: no tonemapping"
	tonemapper_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tone_row.add_child(tonemapper_btn)
	quality_panel.add_content(tone_row)

	# Separator
	var sep3 := HSeparator.new()
	quality_panel.add_content(sep3)

	# Preset buttons
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 4)

	var pretty_btn := Button.new()
	pretty_btn.text = "Pretty"
	pretty_btn.pressed.connect(_cb.get("quality_pretty_preset", Callable()))
	pretty_btn.tooltip_text = "Enable TAA + SSAO + Glow + Depth Fog + AgX + 4-split shadows"
	preset_row.add_child(pretty_btn)

	var balanced_btn := Button.new()
	balanced_btn.text = "Balanced"
	balanced_btn.pressed.connect(_cb.get("quality_balanced_preset", Callable()))
	balanced_btn.tooltip_text = "Enable TAA + SSAO + Glow only"
	preset_row.add_child(balanced_btn)

	var fast_btn := Button.new()
	fast_btn.text = "Fast"
	fast_btn.pressed.connect(_cb.get("quality_fast_preset", Callable()))
	fast_btn.tooltip_text = "Disable all rendering quality features"
	preset_row.add_child(fast_btn)

	quality_panel.add_content(preset_row)

	panel_vbox.add_child(quality_panel)


func _create_shader_panel() -> void:
	shader_panel = FoldablePanelScript.new("Shader Effects", true)  # Start folded

	# Info label
	var info_label := Label.new()
	info_label.add_theme_font_size_override("font_size", 10)
	info_label.text = "Post-processing effects"
	info_label.modulate = Color(0.7, 0.7, 0.7)
	shader_panel.add_content(info_label)

	# VAIO fog and clouds removed — redundant with native depth/volumetric fog
	# and SunshineClouds2. Fog is now in Weather panel, clouds driven by weather.

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
