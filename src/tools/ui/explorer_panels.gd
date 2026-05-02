## Builds tabbed UI panels for WorldExplorer.
##
## Organizes all controls into a 4-tab layout:
##   Environment — Sky & time, weather, ocean, terrain, NPCs
##   Rendering   — Quality presets, post-processing, fog, color grading, resolution
##   Navigation  — Camera info, view distance, teleport buttons
##   Debug       — Performance stats, LOD overlays, profiling
##
## A pinned FPS overlay sits above the tabs (always visible).
## Section headers (HSeparator + bold Label) separate groups within tabs.
## Debug tab uses FoldablePanel for collapsible subsections.
##
## Usage:
## [codeblock]
## var panels := ExplorerPanels.new(callbacks)
## panels.build(stats_panel_vbox)
## [/codeblock]
class_name ExplorerPanels
extends RefCounted

const FoldablePanelScript := preload("res://src/tools/ui/foldable_panel.gd")
const StreamingConfig := preload("res://src/core/world/streaming_config.gd")

# ── Public widget references (read by world_explorer for dynamic updates) ──

## TabContainer holding all tabs
var tab_container: TabContainer = null

## Panel instances (kept for backward compat with stats_collector lookups)
var performance_panel: Control = null
var visibility_panel: Control = null
var navigation_panel: Control = null
var terrain_panel: Control = null
var ocean_panel: Control = null
var shader_panel: Control = null
var debug_panel: FoldablePanel = null
var quality_panel: Control = null
var weather_panel: Control = null

## ScrollContainer that holds all panels (now wraps tab container)
var panel_scroll: ScrollContainer = null
## VBox inside the scroll container (legacy — points to active tab content)
var panel_vbox: VBoxContainer = null

## Rendering panel widgets
var show_characters_toggle: CheckBox = null
var show_ocean_toggle: CheckBox = null
var show_sky_toggle: CheckBox = null
var resolution_btn: OptionButton = null

## Ocean panel widgets
var water_quality_btn: OptionButton = null
var wave_scale_slider: HSlider = null  # Labelled "Wave Height" in UI
var choppiness_slider: HSlider = null
var debug_shore_toggle: CheckBox = null
var ocean_controls_container: VBoxContainer = null

## Rendering Quality panel
var godrays_toggle: CheckBox = null
var taa_toggle: CheckBox = null
var ssao_toggle: CheckBox = null
var ssil_toggle: CheckBox = null
var glow_toggle: CheckBox = null
var native_vfog_toggle: CheckBox = null
var depth_fog_toggle: CheckBox = null
var shadow_cascade_toggle: CheckBox = null
var tonemapper_btn: OptionButton = null

## Shader panel widgets (color grading now in Rendering tab)
var color_grading_toggle: CheckBox = null

## Weather panel widgets
var weather_enabled_toggle: CheckBox = null
var weather_type_btn: OptionButton = null  # Unified weather dropdown (Auto + 11 types)
var fog_density_slider: HSlider = null
var cloud_coverage_slider: HSlider = null
var cloud_density_slider: HSlider = null
var cloud_sharpness_slider: HSlider = null
var cloud_size_slider: HSlider = null
var wind_strength_slider: HSlider = null
var time_of_day_slider: HSlider = null
var time_scale_slider: HSlider = null
var time_pause_toggle: CheckBox = null
var weather_status_label: Label = null
var cirrus_slider: HSlider = null  # cirrus_coverage
var cirrus_size_slider: HSlider = null
var cirrus_thickness_slider: HSlider = null

## Debug panel widgets
var lod_mode_btn: Button = null
var view_distance_slider: HSlider = null


# ── Private ──

var _cb: Dictionary = {}
var _initial_state: Dictionary = {}

## Tab content VBoxes (for stats_collector label lookups)
var _env_vbox: VBoxContainer = null
var _render_vbox: VBoxContainer = null
var _nav_vbox: VBoxContainer = null
var _debug_vbox: VBoxContainer = null


func _init(callbacks: Dictionary, initial_state: Dictionary = {}) -> void:
	_cb = callbacks
	_initial_state = initial_state


## Build all panels inside the given VBox (stats_panel/VBox).
func build(vbox: VBoxContainer) -> void:
	if not vbox:
		return

	# Hide old static content
	var stats_text_node: Control = vbox.get_node_or_null("StatsText")
	if stats_text_node:
		stats_text_node.visible = false

	# ── Pinned FPS overlay (always visible above tabs) ──
	var fps_box := VBoxContainer.new()
	fps_box.name = "PinnedStats"
	fps_box.add_theme_constant_override("separation", 1)

	var fps_label := Label.new()
	fps_label.name = "FPSLabel"
	fps_label.add_theme_font_size_override("font_size", 12)
	fps_label.text = "FPS: --"
	fps_box.add_child(fps_label)

	var timing_label := Label.new()
	timing_label.name = "TimingLabel"
	timing_label.add_theme_font_size_override("font_size", 10)
	timing_label.text = "Frame: -- ms | P95: -- ms"
	fps_box.add_child(timing_label)

	vbox.add_child(fps_box)
	vbox.move_child(fps_box, 0)

	# ── Tab Container ──
	tab_container = TabContainer.new()
	tab_container.name = "Tabs"
	tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab_container.tab_alignment = TabBar.ALIGNMENT_CENTER
	tab_container.add_theme_font_size_override("font_size", 11)

	# Create 4 tabs — each is a ScrollContainer > VBoxContainer
	var env_scroll := _make_tab_scroll("Scene")
	_env_vbox = env_scroll.get_child(0) as VBoxContainer

	var render_scroll := _make_tab_scroll("Render")
	_render_vbox = render_scroll.get_child(0) as VBoxContainer

	var nav_scroll := _make_tab_scroll("Nav")
	_nav_vbox = nav_scroll.get_child(0) as VBoxContainer

	var debug_scroll := _make_tab_scroll("Debug")
	_debug_vbox = debug_scroll.get_child(0) as VBoxContainer

	tab_container.add_child(env_scroll)
	tab_container.add_child(render_scroll)
	tab_container.add_child(nav_scroll)
	tab_container.add_child(debug_scroll)

	# Populate each tab
	_build_environment_tab(_env_vbox)
	_build_rendering_tab(_render_vbox)
	_build_navigation_tab(_nav_vbox)
	_build_debug_tab(_debug_vbox)

	# Disable keyboard focus on all controls
	_strip_focus(tab_container)

	# For backward compat — panel_vbox points to env tab
	panel_vbox = _env_vbox

	# Insert into parent
	var separator_idx := 1  # After pinned stats
	vbox.add_child(tab_container)
	vbox.move_child(tab_container, separator_idx)


## Create a ScrollContainer for one tab
func _make_tab_scroll(tab_name: String) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = tab_name
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.name = "Content"
	vbox.add_theme_constant_override("separation", 4)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Invisible to mouse — only child widgets catch clicks, camera drag works over empty space
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.add_child(vbox)

	return scroll


## Recursively disable keyboard focus on all child controls.
func _strip_focus(node: Node) -> void:
	if node is Control:
		(node as Control).focus_mode = Control.FOCUS_NONE
	for child in node.get_children():
		_strip_focus(child)


## Helper: add a section header (bold label + separator)
func _add_section(parent: VBoxContainer, title: String) -> void:
	var sep := HSeparator.new()
	parent.add_child(sep)
	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	parent.add_child(label)


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


# ══════════════════════════════════════════════════════════════════════════════
# TAB 1: ENVIRONMENT
# ══════════════════════════════════════════════════════════════════════════════

func _build_environment_tab(vbox: VBoxContainer) -> void:
	# ── Sky & Time ──
	_add_section(vbox, "Sky & Time")

	show_sky_toggle = CheckBox.new()
	show_sky_toggle.text = "Sky"
	show_sky_toggle.button_pressed = _initial_state.get("show_sky", false)
	show_sky_toggle.toggled.connect(_cb.get("show_sky_toggled", Callable()))
	show_sky_toggle.tooltip_text = "Toggle sky/day-night cycle toggle in Environment tab"
	vbox.add_child(show_sky_toggle)

	cirrus_slider = create_slider_row(vbox, "Cirrus:", 0.0, 1.0, 0.55, _cb.get("cirrus_changed", Callable()) if _cb.has("cirrus_changed") else Callable())
	cirrus_slider.step = 0.05
	cirrus_slider.tooltip_text = "High-altitude cirrus cloud coverage (0 = clear, 1 = overcast wisps)"

	cirrus_size_slider = create_slider_row(vbox, "Cirrus Size:", 0.3, 2.5, 0.7, _cb.get("cirrus_size_changed", Callable()) if _cb.has("cirrus_size_changed") else Callable())
	cirrus_size_slider.step = 0.05
	cirrus_size_slider.tooltip_text = "Cirrus noise scale — LOWER = bigger individual wisps, HIGHER = tighter streaks"

	cirrus_thickness_slider = create_slider_row(vbox, "Cirrus Thick:", 0.0, 1.0, 0.6, _cb.get("cirrus_thickness_changed", Callable()) if _cb.has("cirrus_thickness_changed") else Callable())
	cirrus_thickness_slider.step = 0.05
	cirrus_thickness_slider.tooltip_text = "Cirrus layer thickness (higher = denser wisps)"

	time_of_day_slider = create_slider_row(vbox, "Time:", 0.0, 24.0, 8.0, _cb.get("time_of_day_changed", Callable()))
	time_of_day_slider.step = 0.1
	time_of_day_slider.tooltip_text = "Game hour (0 = midnight, 12 = noon)"

	var speed_pause_row := HBoxContainer.new()
	speed_pause_row.add_theme_constant_override("separation", 4)

	# Time speed as a compact slider
	var speed_label := Label.new()
	speed_label.text = "Speed:"
	speed_label.add_theme_font_size_override("font_size", 11)
	speed_label.custom_minimum_size.x = 40
	speed_pause_row.add_child(speed_label)

	time_scale_slider = HSlider.new()
	time_scale_slider.min_value = 0.0
	time_scale_slider.max_value = 300.0
	time_scale_slider.value = 30.0
	time_scale_slider.step = 5.0
	time_scale_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	time_scale_slider.custom_minimum_size.x = 80
	time_scale_slider.value_changed.connect(_cb.get("time_scale_changed", Callable()))
	time_scale_slider.tooltip_text = "Time scale: game-seconds per real-second"
	speed_pause_row.add_child(time_scale_slider)

	time_pause_toggle = CheckBox.new()
	time_pause_toggle.text = "Pause"
	time_pause_toggle.button_pressed = false
	time_pause_toggle.toggled.connect(_cb.get("time_pause_toggled", Callable()))
	speed_pause_row.add_child(time_pause_toggle)

	vbox.add_child(speed_pause_row)

	# ── Weather ──
	_add_section(vbox, "Weather")

	weather_enabled_toggle = CheckBox.new()
	weather_enabled_toggle.text = "Enable Weather"
	weather_enabled_toggle.button_pressed = false
	weather_enabled_toggle.toggled.connect(_cb.get("weather_toggled", Callable()))
	weather_enabled_toggle.tooltip_text = "Enable dynamic weather system (drives fog color + density from weather state)"
	vbox.add_child(weather_enabled_toggle)

	# Unified weather dropdown — single source of truth for the active weather.
	# "Auto" lets the region-based auto-weather system pick; any other entry
	# locks the weather to that type. Time-of-day / speed / pause live in the
	# Sky & Time section above — no duplication here.
	var weather_row := HBoxContainer.new()
	var weather_label := Label.new()
	weather_label.text = "Weather:"
	weather_label.add_theme_font_size_override("font_size", 11)
	weather_label.custom_minimum_size.x = 60
	weather_row.add_child(weather_label)

	weather_type_btn = OptionButton.new()
	weather_type_btn.add_item("Auto", -1)
	for i: int in WeatherTypes.TYPE_NAMES.size():
		weather_type_btn.add_item(WeatherTypes.TYPE_NAMES[i], i)
	weather_type_btn.selected = 0
	weather_type_btn.item_selected.connect(_cb.get("weather_type_changed", Callable()))
	weather_type_btn.tooltip_text = "Active weather (Auto = region-based, otherwise locks to the selected type)"
	weather_type_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	weather_row.add_child(weather_type_btn)
	vbox.add_child(weather_row)

	# Fog density multiplier
	fog_density_slider = create_slider_row(vbox, "Fog:", 0.1, 3.0, 1.0, _cb.get("fog_density_changed", Callable()))
	fog_density_slider.step = 0.1
	fog_density_slider.tooltip_text = "Fog density multiplier (1.0 = default, higher = thicker)"

	# Fog & atmosphere toggles — grouped with weather because weather drives
	# fog/godray parameters when active (authority model: Phase B refactor)
	depth_fog_toggle = CheckBox.new()
	depth_fog_toggle.text = "Depth Fog (aerial perspective)"
	depth_fog_toggle.button_pressed = false
	depth_fog_toggle.toggled.connect(_cb.get("depth_fog_toggled", Callable()))
	depth_fog_toggle.tooltip_text = "Distance haze — makes far objects fade to sky color for depth"
	vbox.add_child(depth_fog_toggle)

	native_vfog_toggle = CheckBox.new()
	native_vfog_toggle.text = "Volumetric Fog"
	native_vfog_toggle.button_pressed = false
	native_vfog_toggle.toggled.connect(_cb.get("native_vfog_toggled", Callable()))
	native_vfog_toggle.tooltip_text = "Godot native volumetric fog — produces god rays via forward scattering"
	vbox.add_child(native_vfog_toggle)

	godrays_toggle = CheckBox.new()
	godrays_toggle.text = "God Rays (compute)"
	godrays_toggle.button_pressed = false
	godrays_toggle.toggled.connect(_cb.get("godrays_toggled", Callable()))
	godrays_toggle.tooltip_text = "Compute shader god rays — requires Sky to be enabled"
	vbox.add_child(godrays_toggle)

	# --- Volumetric cloud parameters (SunshineClouds2) --------------------
	# Direct bindings onto the SunshineClouds2 resource. Weather presets
	# call on_* handlers to push their values here — there is NO per-frame
	# override, the slider is the single source of truth.
	cloud_coverage_slider = create_slider_row(vbox, "Clouds:", 0.0, 1.0, 0.45, _cb.get("cloud_coverage_changed", Callable()))
	cloud_coverage_slider.step = 0.02
	cloud_coverage_slider.tooltip_text = "SunshineClouds2 clouds_coverage (0 = clear, 1 = overcast)"

	cloud_density_slider = create_slider_row(vbox, "Cloud Density:", 0.02, 1.0, 0.14, _cb.get("cloud_density_changed", Callable()) if _cb.has("cloud_density_changed") else Callable())
	cloud_density_slider.step = 0.01
	cloud_density_slider.tooltip_text = "SunshineClouds2 clouds_density — safe range 0.02-1.0 (plugin default 0.14)"

	cloud_sharpness_slider = create_slider_row(vbox, "Cloud Sharpness:", 0.0, 2.0, 0.75, _cb.get("cloud_sharpness_changed", Callable()) if _cb.has("cloud_sharpness_changed") else Callable())
	cloud_sharpness_slider.step = 0.02
	cloud_sharpness_slider.tooltip_text = "SunshineClouds2 clouds_sharpness — edge definition"

	cloud_size_slider = create_slider_row(vbox, "Cloud Size:", 0.3, 3.0, 1.0, _cb.get("cloud_size_changed", Callable()) if _cb.has("cloud_size_changed") else Callable())
	cloud_size_slider.step = 0.05
	cloud_size_slider.tooltip_text = "Coarse multiplier applied to SunshineClouds2 noise scales (larger = bigger clumps)"

	wind_strength_slider = create_slider_row(vbox, "Wind:", 0.0, 1.0, 0.25, _cb.get("wind_strength_changed", Callable()) if _cb.has("wind_strength_changed") else Callable())
	wind_strength_slider.step = 0.02
	wind_strength_slider.tooltip_text = "Wind strength — drives cloud wind sweep + ocean wave chaos"

	# Weather status
	weather_status_label = Label.new()
	weather_status_label.name = "WeatherStatus"
	weather_status_label.text = "Weather: Clear | Hour: 8.0"
	weather_status_label.add_theme_font_size_override("font_size", 10)
	weather_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(weather_status_label)

	# ── Ocean ──
	_add_section(vbox, "Ocean")

	show_ocean_toggle = CheckBox.new()
	show_ocean_toggle.text = "Ocean"
	show_ocean_toggle.button_pressed = _initial_state.get("show_ocean", false)
	show_ocean_toggle.toggled.connect(_cb.get("show_ocean_toggled", Callable()))
	show_ocean_toggle.tooltip_text = "Toggle ocean toggle in Environment tab"
	vbox.add_child(show_ocean_toggle)

	# Quality dropdown
	var quality_row := HBoxContainer.new()
	var quality_label := Label.new()
	quality_label.text = "Quality:"
	quality_label.add_theme_font_size_override("font_size", 11)
	quality_label.custom_minimum_size.x = 50
	quality_row.add_child(quality_label)

	water_quality_btn = OptionButton.new()
	water_quality_btn.add_item("Auto", -1)
	water_quality_btn.add_item("Flat", 0)
	water_quality_btn.add_item("Standard", 1)
	water_quality_btn.add_item("High (FFT)", 2)
	water_quality_btn.selected = 0
	water_quality_btn.item_selected.connect(_cb.get("water_quality_changed", Callable()))
	water_quality_btn.tooltip_text = "Water quality:\n- Flat: Simple plane (fallback)\n- Standard: Analytical Gerstner waves\n- High: FFT compute ocean (JONSWAP spectrum)"
	water_quality_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quality_row.add_child(water_quality_btn)
	vbox.add_child(quality_row)

	# Ocean controls container (shown when ocean is enabled)
	ocean_controls_container = VBoxContainer.new()
	ocean_controls_container.name = "OceanControls"
	ocean_controls_container.visible = false

	wave_scale_slider = create_slider_row(ocean_controls_container, "Wave Height:", 0.0, 3.0, 1.0, _cb.get("wave_scale_changed", Callable()))
	wave_scale_slider.step = 0.05
	wave_scale_slider.tooltip_text = "Wave height multiplier — scales vertical displacement on all cascades"

	choppiness_slider = create_slider_row(ocean_controls_container, "Choppiness:", 0.0, 1.0, 0.3, _cb.get("choppiness_changed", Callable()) if _cb.has("choppiness_changed") else Callable())
	choppiness_slider.step = 0.02
	choppiness_slider.tooltip_text = "Wave directionality — 0 = smooth aligned swell, 1 = chaotic omnidirectional chop"

	debug_shore_toggle = CheckBox.new()
	debug_shore_toggle.text = "Debug Shore Mask"
	debug_shore_toggle.button_pressed = false
	debug_shore_toggle.toggled.connect(_cb.get("debug_shore_toggled", Callable()))
	debug_shore_toggle.tooltip_text = "Visualize shore damping"
	ocean_controls_container.add_child(debug_shore_toggle)

	vbox.add_child(ocean_controls_container)

	# ── Terrain ──
	_add_section(vbox, "Terrain")

	var terrain_label := Label.new()
	terrain_label.name = "TerrainLabel"
	terrain_label.add_theme_font_size_override("font_size", 11)
	terrain_label.text = "Regions: --"
	vbox.add_child(terrain_label)

	# ── NPCs ──
	_add_section(vbox, "Characters")

	show_characters_toggle = CheckBox.new()
	show_characters_toggle.text = "NPCs"
	show_characters_toggle.button_pressed = _initial_state.get("show_characters", false)
	show_characters_toggle.toggled.connect(_cb.get("show_characters_toggled", Callable()))
	show_characters_toggle.tooltip_text = "Toggle NPCs and creatures toggle in Environment tab"
	vbox.add_child(show_characters_toggle)


# ══════════════════════════════════════════════════════════════════════════════
# TAB 2: RENDERING
# ══════════════════════════════════════════════════════════════════════════════

func _build_rendering_tab(vbox: VBoxContainer) -> void:
	# ── Quality Presets ──
	_add_section(vbox, "Quality Presets")

	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 4)

	var pretty_btn := Button.new()
	pretty_btn.text = "Pretty"
	pretty_btn.pressed.connect(_cb.get("quality_pretty_preset", Callable()))
	pretty_btn.tooltip_text = "Enable TAA + SSAO + Glow + Depth Fog + AgX + 4-split shadows"
	pretty_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_row.add_child(pretty_btn)

	var balanced_btn := Button.new()
	balanced_btn.text = "Balanced"
	balanced_btn.pressed.connect(_cb.get("quality_balanced_preset", Callable()))
	balanced_btn.tooltip_text = "Enable TAA + SSAO + Glow only"
	balanced_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_row.add_child(balanced_btn)

	var fast_btn := Button.new()
	fast_btn.text = "Fast"
	fast_btn.pressed.connect(_cb.get("quality_fast_preset", Callable()))
	fast_btn.tooltip_text = "Disable all rendering quality features"
	fast_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_row.add_child(fast_btn)

	vbox.add_child(preset_row)

	# ── Post-Processing ──
	_add_section(vbox, "Post-Processing")

	taa_toggle = CheckBox.new()
	taa_toggle.text = "TAA (Anti-Aliasing)"
	taa_toggle.button_pressed = false
	taa_toggle.toggled.connect(_cb.get("taa_toggled", Callable()))
	taa_toggle.tooltip_text = "Temporal Anti-Aliasing — eliminates edge shimmer. May ghost on ocean surface."
	vbox.add_child(taa_toggle)

	ssao_toggle = CheckBox.new()
	ssao_toggle.text = "SSAO"
	ssao_toggle.button_pressed = false
	ssao_toggle.toggled.connect(_cb.get("ssao_toggled", Callable()))
	ssao_toggle.tooltip_text = "Screen-Space Ambient Occlusion — contact shadows in crevices and corners"
	vbox.add_child(ssao_toggle)

	ssil_toggle = CheckBox.new()
	ssil_toggle.text = "SSIL"
	ssil_toggle.button_pressed = false
	ssil_toggle.toggled.connect(_cb.get("ssil_toggled", Callable()))
	ssil_toggle.tooltip_text = "Screen-Space Indirect Lighting — color bleeding between nearby surfaces"
	vbox.add_child(ssil_toggle)

	glow_toggle = CheckBox.new()
	glow_toggle.text = "Glow / Bloom"
	glow_toggle.button_pressed = false
	glow_toggle.toggled.connect(_cb.get("glow_toggled", Callable()))
	glow_toggle.tooltip_text = "HDR bloom on bright surfaces (sun, torches, lava)"
	vbox.add_child(glow_toggle)

	# ── Shadows ──
	_add_section(vbox, "Shadows")

	shadow_cascade_toggle = CheckBox.new()
	shadow_cascade_toggle.text = "Shadow 4-Split Cascades"
	shadow_cascade_toggle.button_pressed = false
	shadow_cascade_toggle.toggled.connect(_cb.get("shadow_cascades_toggled", Callable()))
	shadow_cascade_toggle.tooltip_text = "4 shadow cascades with blending — sharper nearby, softer distant shadows"
	vbox.add_child(shadow_cascade_toggle)

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
	tonemapper_btn.tooltip_text = "Tonemapping algorithm:\n- Filmic: balanced\n- ACES: cinematic\n- AgX: best hue preservation (Godot 4.6)\n- Linear: no tonemapping"
	tonemapper_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tone_row.add_child(tonemapper_btn)
	vbox.add_child(tone_row)

	# ── Color Grading ──
	_add_section(vbox, "Color Grading")

	color_grading_toggle = CheckBox.new()
	color_grading_toggle.text = "Enable Color Grading"
	color_grading_toggle.button_pressed = false
	color_grading_toggle.toggled.connect(_cb.get("color_grading_toggled", Callable()))
	color_grading_toggle.tooltip_text = "Color correction and grading"
	vbox.add_child(color_grading_toggle)

	var cg_btn_row := HBoxContainer.new()
	cg_btn_row.add_theme_constant_override("separation", 4)

	var morrowind_btn := Button.new()
	morrowind_btn.text = "Morrowind"
	morrowind_btn.pressed.connect(_cb.get("morrowind_preset", Callable()))
	morrowind_btn.tooltip_text = "Warm Morrowind-style tones"
	morrowind_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cg_btn_row.add_child(morrowind_btn)

	var dramatic_btn := Button.new()
	dramatic_btn.text = "Dramatic"
	dramatic_btn.pressed.connect(_cb.get("dramatic_preset", Callable()))
	dramatic_btn.tooltip_text = "High contrast dramatic look"
	dramatic_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cg_btn_row.add_child(dramatic_btn)

	var reset_btn := Button.new()
	reset_btn.text = "Reset"
	reset_btn.pressed.connect(_cb.get("reset_color_grading", Callable()))
	reset_btn.tooltip_text = "Reset to defaults"
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cg_btn_row.add_child(reset_btn)

	vbox.add_child(cg_btn_row)

	# ── Display ──
	_add_section(vbox, "Display")

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

	vbox.add_child(res_row)


# ══════════════════════════════════════════════════════════════════════════════
# TAB 3: NAVIGATION
# ══════════════════════════════════════════════════════════════════════════════

func _build_navigation_tab(vbox: VBoxContainer) -> void:
	# Camera info (updated dynamically)
	var camera_label := Label.new()
	camera_label.name = "CameraLabel"
	camera_label.add_theme_font_size_override("font_size", 11)
	camera_label.text = "Cell: (0, 0) | Mode: Fly"
	vbox.add_child(camera_label)

	# View distance control
	_add_section(vbox, "View Distance")

	var view_row := HBoxContainer.new()
	var view_distance: int = _initial_state.get("view_distance", StreamingConfig.DEFAULT_LOAD_RADIUS_CELLS)
	var adjust_cb: Callable = _cb.get("adjust_view_distance", Callable())
	var set_cb: Callable = _cb.get("set_view_distance", Callable())

	var minus_btn := Button.new()
	minus_btn.text = "-"
	minus_btn.custom_minimum_size.x = 30
	minus_btn.pressed.connect(func() -> void: adjust_cb.call(-1))
	view_row.add_child(minus_btn)

	view_distance_slider = HSlider.new()
	view_distance_slider.name = "ViewDistanceSlider"
	view_distance_slider.min_value = StreamingConfig.MIN_LOAD_RADIUS_CELLS
	view_distance_slider.max_value = StreamingConfig.MAX_LOAD_RADIUS_CELLS
	view_distance_slider.step = 1.0
	view_distance_slider.value = StreamingConfig.clamp_load_radius_cells(view_distance)
	view_distance_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view_distance_slider.custom_minimum_size.x = 120
	view_distance_slider.value_changed.connect(func(value: float) -> void: set_cb.call(value))
	view_row.add_child(view_distance_slider)

	var plus_btn := Button.new()
	plus_btn.text = "+"
	plus_btn.custom_minimum_size.x = 30
	plus_btn.pressed.connect(func() -> void: adjust_cb.call(1))
	view_row.add_child(plus_btn)

	vbox.add_child(view_row)

	var dist_label := Label.new()
	dist_label.name = "DistLabel"
	dist_label.text = "%d cells" % view_distance
	dist_label.add_theme_font_size_override("font_size", 11)
	vbox.add_child(dist_label)

	# Quick teleport buttons
	_add_section(vbox, "Quick Teleport")

	var teleport_cb: Callable = _cb.get("teleport_to_cell", Callable())

	var btn_row1 := HBoxContainer.new()
	btn_row1.add_theme_constant_override("separation", 4)

	var seyda_btn := Button.new()
	seyda_btn.text = "Seyda Neen"
	seyda_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seyda_btn.pressed.connect(func() -> void: teleport_cb.call(-2, -9))
	btn_row1.add_child(seyda_btn)

	var balmora_btn := Button.new()
	balmora_btn.text = "Balmora"
	balmora_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	balmora_btn.pressed.connect(func() -> void: teleport_cb.call(-3, -2))
	btn_row1.add_child(balmora_btn)

	vbox.add_child(btn_row1)

	var btn_row2 := HBoxContainer.new()
	btn_row2.add_theme_constant_override("separation", 4)

	var vivec_btn := Button.new()
	vivec_btn.text = "Vivec"
	vivec_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vivec_btn.pressed.connect(func() -> void: teleport_cb.call(5, -6))
	btn_row2.add_child(vivec_btn)

	var origin_btn := Button.new()
	origin_btn.text = "Origin"
	origin_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	origin_btn.pressed.connect(func() -> void: teleport_cb.call(0, 0))
	btn_row2.add_child(origin_btn)

	vbox.add_child(btn_row2)


# ══════════════════════════════════════════════════════════════════════════════
# TAB 4: DEBUG
# ══════════════════════════════════════════════════════════════════════════════

func _build_debug_tab(vbox: VBoxContainer) -> void:
	# ── Performance (always visible in this tab) ──
	var render_label := Label.new()
	render_label.name = "RenderLabel"
	render_label.add_theme_font_size_override("font_size", 11)
	render_label.text = "Draw calls: -- | Tris: --k"
	vbox.add_child(render_label)

	var memory_label := Label.new()
	memory_label.name = "MemoryLabel"
	memory_label.add_theme_font_size_override("font_size", 11)
	memory_label.text = "Memory: -- MB"
	vbox.add_child(memory_label)

	# ── LOD Overlays (foldable) ──
	var lod_panel := FoldablePanelScript.new("LOD Overlays", true)

	var chunk_toggle := CheckBox.new()
	chunk_toggle.text = "Show Chunks (FAR tier)"
	chunk_toggle.button_pressed = _initial_state.get("show_chunk_debug", false)
	chunk_toggle.toggled.connect(_cb.get("show_chunks_toggled", Callable()))
	chunk_toggle.tooltip_text = "Visualize quadtree chunk boundaries (8x8 cells each)"
	lod_panel.add_content(chunk_toggle)

	var tier_toggle := CheckBox.new()
	tier_toggle.text = "Show Distance Tiers"
	tier_toggle.button_pressed = _initial_state.get("show_tier_debug", false)
	tier_toggle.toggled.connect(_cb.get("show_tiers_toggled", Callable()))
	tier_toggle.tooltip_text = "Visualize NEAR/MID/FAR tier zones with colors"
	lod_panel.add_content(tier_toggle)

	var cell_toggle := CheckBox.new()
	cell_toggle.text = "Show Cell Grid"
	cell_toggle.button_pressed = _initial_state.get("show_cell_debug", false)
	cell_toggle.toggled.connect(_cb.get("show_cells_toggled", Callable()))
	cell_toggle.tooltip_text = "Visualize individual cell boundaries and coordinates"
	lod_panel.add_content(cell_toggle)

	var lod_toggle := CheckBox.new()
	lod_toggle.text = "Show LOD Levels"
	lod_toggle.button_pressed = false
	lod_toggle.toggled.connect(_cb.get("show_lod_levels_toggled", Callable()))
	lod_toggle.tooltip_text = "Color batched LODs: Green=LOD0/NEAR, Yellow=LOD1, Orange=LOD2, Red=LOD3/FAR"
	lod_panel.add_content(lod_toggle)

	lod_mode_btn = Button.new()
	lod_mode_btn.text = "LOD Mode: Actual"
	lod_mode_btn.pressed.connect(_cb.get("lod_mode_pressed", Callable()))
	lod_mode_btn.tooltip_text = "Toggle between Actual (what IS rendered) and Expected (what SHOULD be by distance)"
	lod_panel.add_content(lod_mode_btn)

	vbox.add_child(lod_panel)

	# ── Streaming Stats (foldable) ──
	var stats_panel := FoldablePanelScript.new("Streaming Stats", true)

	var debug_info_label := Label.new()
	debug_info_label.name = "DebugInfoLabel"
	debug_info_label.add_theme_font_size_override("font_size", 10)
	debug_info_label.text = "Loaded cells: -- | Queue: --"
	stats_panel.add_content(debug_info_label)

	var odm_label := Label.new()
	odm_label.name = "ODMLabel"
	odm_label.add_theme_font_size_override("font_size", 10)
	odm_label.text = "ODM: -- tracked | NEAR: -- MID: -- FAR: --"
	stats_panel.add_content(odm_label)

	var profiler_label := Label.new()
	profiler_label.name = "ProfilerLabel"
	profiler_label.add_theme_font_size_override("font_size", 10)
	profiler_label.text = "Profiler: --"
	stats_panel.add_content(profiler_label)

	var dump_btn := Button.new()
	dump_btn.text = "Dump Profiling Report [F4]"
	dump_btn.pressed.connect(_cb.get("dump_profiling", Callable()))
	stats_panel.add_content(dump_btn)

	vbox.add_child(stats_panel)

	# Keep debug_panel reference for backward compat (stats_collector uses it)
	debug_panel = stats_panel
