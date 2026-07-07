## Builds tabbed UI panels for WorldExplorer.
##
## Organizes all controls into a 7-tab layout:
##   Sky      — time of day, celestial, cirrus
##   Weather  — weather system, fog (depth / engine volumetric / ground fog + cloud banks), god rays
##   Clouds   — SunshineClouds2 / cheap skydome renderer
##   Water    — ocean, underwater effects
##   Distance — rendering tiers, view distance, teleports
##   Render   — quality presets, post-processing, color grading, resolution
##   Debug    — performance stats, LOD overlays, profiling
##
## NOTE (2026-07-06): the pre-tab legacy builders (_build_environment_tab,
## _build_navigation_tab) were dead code — never called, but re-assigning the
## same widget vars as the live tabs. They have been DELETED. If a control
## seems to have no effect, check it isn't being built twice.
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
const LightTuning := preload("res://src/core/world/light_tuning.gd")

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
var all_water_toggle: CheckBox = null
var show_ocean_toggle: CheckBox = null
var rivers_toggle: CheckBox = null
var lakes_pools_toggle: CheckBox = null
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
var sdfgi_toggle: CheckBox = null
var native_vfog_toggle: CheckBox = null
var depth_fog_toggle: CheckBox = null
var shadow_cascade_toggle: CheckBox = null
var tonemapper_btn: OptionButton = null

## Shader panel widgets (color grading now in Rendering tab)
var color_grading_toggle: CheckBox = null

## Weather panel widgets
var weather_enabled_toggle: CheckBox = null
var weather_type_btn: OptionButton = null  # Unified weather dropdown (Auto + 11 types)
var depth_fog_strength_slider: HSlider = null
var vfog_strength_slider: HSlider = null
var cloud_renderer_dropdown: OptionButton = null

## Ground fog / cloud banks (raymarch effect) — param name -> HSlider
var ground_fog_toggle: CheckBox = null
var ground_fog_sliders: Dictionary = {}
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

## Water effects widgets
var underwater_medium_toggle: CheckBox = null
var underwater_absorption_toggle: CheckBox = null
var underwater_snell_toggle: CheckBox = null
var underwater_wobble_toggle: CheckBox = null
var underwater_caustics_toggle: CheckBox = null
var underwater_particles_toggle: CheckBox = null
var underwater_particle_quality_btn: OptionButton = null
var underwater_particle_opacity_slider: HSlider = null
var water_turbidity_slider: HSlider = null
var water_visibility_slider: HSlider = null
var water_color_picker: ColorPickerButton = null
var surface_ssr_toggle: CheckBox = null
var sea_spray_toggle: CheckBox = null
var sea_spray_quality_btn: OptionButton = null
var water_status_label: Label = null

## Distance/rendering tier widgets
var near_gameplay_toggle: CheckBox = null
var static_visuals_toggle: CheckBox = null
var far_impostors_toggle: CheckBox = null
var chunk_toggle: CheckBox = null
var distant_lights_toggle: CheckBox = null
var chunk_status_label: Label = null

## Debug panel widgets
var lod_mode_btn: Button = null
var view_distance_label: Label = null


# ── Private ──

var _cb: Dictionary = {}
var _initial_state: Dictionary = {}

## Tab content VBoxes (for stats_collector label lookups)
var _env_vbox: VBoxContainer = null
var _render_vbox: VBoxContainer = null
var _nav_vbox: VBoxContainer = null
var _debug_vbox: VBoxContainer = null
var _sky_vbox: VBoxContainer = null
var _weather_vbox: VBoxContainer = null
var _clouds_vbox: VBoxContainer = null
var _water_vbox: VBoxContainer = null
var _distance_vbox: VBoxContainer = null
var _lighting_vbox: VBoxContainer = null


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
	var sky_scroll := _make_tab_scroll("Sky")
	_sky_vbox = sky_scroll.get_child(0) as VBoxContainer

	var weather_scroll := _make_tab_scroll("Weather")
	_weather_vbox = weather_scroll.get_child(0) as VBoxContainer

	var clouds_scroll := _make_tab_scroll("Clouds")
	_clouds_vbox = clouds_scroll.get_child(0) as VBoxContainer

	var water_scroll := _make_tab_scroll("Water")
	_water_vbox = water_scroll.get_child(0) as VBoxContainer

	var distance_scroll := _make_tab_scroll("Distance")
	_distance_vbox = distance_scroll.get_child(0) as VBoxContainer

	var lighting_scroll := _make_tab_scroll("Lighting")
	_lighting_vbox = lighting_scroll.get_child(0) as VBoxContainer

	var render_scroll := _make_tab_scroll("Render")
	_render_vbox = render_scroll.get_child(0) as VBoxContainer

	var debug_scroll := _make_tab_scroll("Debug")
	_debug_vbox = debug_scroll.get_child(0) as VBoxContainer

	tab_container.add_child(sky_scroll)
	tab_container.add_child(weather_scroll)
	tab_container.add_child(clouds_scroll)
	tab_container.add_child(water_scroll)
	tab_container.add_child(distance_scroll)
	tab_container.add_child(lighting_scroll)
	tab_container.add_child(render_scroll)
	tab_container.add_child(debug_scroll)

	_build_sky_tab(_sky_vbox)
	_build_weather_tab(_weather_vbox)
	_build_clouds_tab(_clouds_vbox)
	_build_water_tab(_water_vbox)
	_build_distance_tab(_distance_vbox)
	_build_lighting_tab(_lighting_vbox)
	_build_rendering_tab(_render_vbox)
	_build_debug_tab(_debug_vbox)

	# Disable keyboard focus on all controls
	_strip_focus(tab_container)

	# For backward compat — panel_vbox points to env tab
	_env_vbox = _distance_vbox
	_nav_vbox = _distance_vbox
	panel_vbox = _sky_vbox

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


## Ground-fog slider helper: binds the shared "ground_fog_param" callback with
## the effect parameter name and registers the slider for push_ground_fog_params.
func _add_ground_fog_slider(parent: VBoxContainer, label_text: String, min_val: float, max_val: float, default_val: float, step: float, param_name: String, tooltip: String) -> void:
	var cbv: Callable = _cb.get("ground_fog_param", Callable())
	var bound := cbv.bind(param_name) if cbv.is_valid() else Callable()
	var slider := create_slider_row(parent, label_text, min_val, max_val, default_val, bound, step)
	slider.tooltip_text = tooltip
	ground_fog_sliders[param_name] = slider


## Push every ground-fog slider's current value to the effect. Called when the
## toggle turns ON so the effect matches the panel instead of its own defaults.
func push_ground_fog_params() -> void:
	var cbv: Callable = _cb.get("ground_fog_param", Callable())
	if not cbv.is_valid():
		return
	for param_name: String in ground_fog_sliders:
		cbv.call((ground_fog_sliders[param_name] as HSlider).value, param_name)


## Helper to create a labeled slider row. The value label tracks the slider
## automatically, with precision derived from the step (0.0002 → 4 decimals).
func create_slider_row(parent: Control, label_text: String, min_val: float, max_val: float, default_val: float, callback: Callable, step: float = 1.0) -> HSlider:
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
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.x = 120
	row.add_child(slider)

	var value_label := Label.new()
	value_label.name = "Value"
	value_label.text = _format_slider_value(default_val, step)
	value_label.custom_minimum_size.x = 35
	value_label.add_theme_font_size_override("font_size", 11)
	row.add_child(value_label)

	var refresh_label := func() -> void:
		value_label.text = _format_slider_value(slider.value, slider.step)
	slider.value_changed.connect(func(_v: float) -> void: refresh_label.call())
	if callback.is_valid():
		slider.value_changed.connect(callback)

	# Some callers adjust slider.step after creation — re-render the label once
	# the current call stack has finished so its precision matches the step.
	refresh_label.call_deferred()

	parent.add_child(row)
	return slider


## Step-aware value formatting: step 5 → "140", step 0.05 → "0.90", step 0.0002 → "0.0030"
static func _format_slider_value(value: float, step: float) -> String:
	var decimals := 0
	if step > 0.0 and step < 1.0:
		decimals = clampi(ceili(-log(step) / log(10.0)), 0, 4)
	return "%.*f" % [decimals, value]


## Update value label next to slider
func update_slider_label(slider: HSlider, value: float) -> void:
	var row: HBoxContainer = slider.get_parent()
	var value_label: Label = row.get_node_or_null("Value")
	if value_label:
		value_label.text = _format_slider_value(value, slider.step)


func _build_sky_tab(vbox: VBoxContainer) -> void:
	_add_section(vbox, "Sky")
	show_sky_toggle = CheckBox.new()
	show_sky_toggle.text = "Sky"
	show_sky_toggle.button_pressed = _initial_state.get("show_sky", false)
	show_sky_toggle.toggled.connect(_cb.get("show_sky_toggled", Callable()))
	vbox.add_child(show_sky_toggle)

	time_of_day_slider = create_slider_row(vbox, "Time:", 0.0, 24.0, 8.0, _cb.get("time_of_day_changed", Callable()))
	time_of_day_slider.step = 0.1

	var speed_pause_row := HBoxContainer.new()
	speed_pause_row.add_theme_constant_override("separation", 4)
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
	time_scale_slider.value_changed.connect(_cb.get("time_scale_changed", Callable()))
	speed_pause_row.add_child(time_scale_slider)
	time_pause_toggle = CheckBox.new()
	time_pause_toggle.text = "Pause"
	time_pause_toggle.toggled.connect(_cb.get("time_pause_toggled", Callable()))
	speed_pause_row.add_child(time_pause_toggle)
	vbox.add_child(speed_pause_row)

	_add_section(vbox, "Cirrus")
	cirrus_slider = create_slider_row(vbox, "Coverage:", 0.0, 1.0, 0.55, _cb.get("cirrus_changed", Callable()) if _cb.has("cirrus_changed") else Callable())
	cirrus_slider.step = 0.05
	cirrus_size_slider = create_slider_row(vbox, "Size:", 0.3, 2.5, 0.7, _cb.get("cirrus_size_changed", Callable()) if _cb.has("cirrus_size_changed") else Callable())
	cirrus_size_slider.step = 0.05
	cirrus_thickness_slider = create_slider_row(vbox, "Thickness:", 0.0, 1.0, 0.6, _cb.get("cirrus_thickness_changed", Callable()) if _cb.has("cirrus_thickness_changed") else Callable())
	cirrus_thickness_slider.step = 0.05


func _build_weather_tab(vbox: VBoxContainer) -> void:
	_add_section(vbox, "Weather")
	weather_enabled_toggle = CheckBox.new()
	weather_enabled_toggle.text = "Enable Weather"
	weather_enabled_toggle.toggled.connect(_cb.get("weather_toggled", Callable()))
	vbox.add_child(weather_enabled_toggle)

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
	weather_type_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	weather_row.add_child(weather_type_btn)
	vbox.add_child(weather_row)

	# --- Fog — each system has its own independent Strength slider ----------
	_add_section(vbox, "Fog")
	depth_fog_toggle = CheckBox.new()
	depth_fog_toggle.text = "Depth Fog"
	depth_fog_toggle.tooltip_text = "Engine exponential distance fog — hazes far geometry into the horizon"
	depth_fog_toggle.button_pressed = true
	depth_fog_toggle.toggled.connect(_cb.get("depth_fog_toggled", Callable()))
	vbox.add_child(depth_fog_toggle)
	depth_fog_strength_slider = create_slider_row(vbox, "Strength:", 0.0, 3.0, 1.0, _cb.get("depth_fog_strength_changed", Callable()), 0.05)
	depth_fog_strength_slider.tooltip_text = "Depth fog strength only — independent of the volumetric and ground fog"
	native_vfog_toggle = CheckBox.new()
	native_vfog_toggle.text = "Volumetric Fog"
	native_vfog_toggle.tooltip_text = "Engine froxel fog — light scattering near the camera; lets the sun and lights form shafts. Does NOT enable the ground fog below."
	native_vfog_toggle.toggled.connect(_cb.get("native_vfog_toggled", Callable()))
	vbox.add_child(native_vfog_toggle)
	vfog_strength_slider = create_slider_row(vbox, "Strength:", 0.0, 3.0, 1.0, _cb.get("volumetric_fog_strength_changed", Callable()), 0.05)
	vfog_strength_slider.tooltip_text = "Volumetric (froxel) fog strength only — independent of the depth and ground fog"
	godrays_toggle = CheckBox.new()
	godrays_toggle.text = "God Rays"
	godrays_toggle.tooltip_text = "Screen-space radial sun shafts"
	godrays_toggle.toggled.connect(_cb.get("godrays_toggled", Callable()))
	vbox.add_child(godrays_toggle)

	# --- Ground fog + cloud banks (analytic layer 2026-07-06) ----
	# Analytic exponential height fog (closed-form optical depth) + raymarched
	# noise detail and an altitude-band cloud deck. World-anchored: pools in
	# valleys, closes the horizon geometrically, covers the sky — unlike the
	# engine froxel fog it has no range cap.
	_add_section(vbox, "Ground Fog + Cloud Banks")
	ground_fog_toggle = CheckBox.new()
	ground_fog_toggle.text = "Enable"
	ground_fog_toggle.button_pressed = false
	ground_fog_toggle.toggled.connect(_cb.get("ground_fog_toggled", Callable()))
	ground_fog_toggle.tooltip_text = "World-anchored fog layer: foggy valleys, hazy horizon, mountain-hugging cloud banks"
	vbox.add_child(ground_fog_toggle)

	_add_ground_fog_slider(vbox, "Strength:", 0.0, 3.0, 1.0, 0.05, "fog_intensity", "Overall ground fog opacity (0 = off). Independent of the depth and volumetric fog")
	_add_ground_fog_slider(vbox, "Fog Dist:", 200.0, 8000.0, 1000.0, 50.0, "fog_distance", "How far away the ground fog builds into a solid misty wall (the 'curtain'). Higher = see further before it closes in; lower brings the wall in close")
	_add_ground_fog_slider(vbox, "Base Alt:", -100.0, 400.0, 0.0, 5.0, "fog_base_height", "World altitude (m) where fog is full density; 0 = sea level")
	_add_ground_fog_slider(vbox, "Layer Height:", 10.0, 500.0, 60.0, 5.0, "fog_layer_height", "Fog thins with altitude over this many meters — small = shallow ground fog, large = tall fog bank")
	_add_ground_fog_slider(vbox, "Detail:", 0.0, 1.0, 0.6, 0.05, "fog_detail", "Animated noise texture in the fog (0 = perfectly smooth)")
	_add_ground_fog_slider(vbox, "Detail Dist:", 500.0, 12000.0, 2000.0, 100.0, "detail_distance", "How far the noise + cloud deck reach before dissolving into smooth fog. Raise it to push the detail/deck edge out; raise Ray Steps too if it looks blocky")
	_add_ground_fog_slider(vbox, "Ray Steps:", 12.0, 96.0, 24.0, 4.0, "ray_steps", "Detail/deck sampling quality. Higher = smoother at long Detail Dist, costs performance")
	_add_ground_fog_slider(vbox, "Wind:", 0.0, 25.0, 8.0, 0.5, "fog_speed", "How fast the fog detail drifts")
	_add_ground_fog_slider(vbox, "Deck Height:", 0.0, 600.0, 140.0, 5.0, "cloud_height", "Altitude of the cloud deck center (m)")
	_add_ground_fog_slider(vbox, "Deck Thick:", 0.0, 400.0, 90.0, 5.0, "cloud_thickness", "Vertical extent of the cloud deck (m)")
	_add_ground_fog_slider(vbox, "Deck Cover:", 0.0, 1.0, 0.35, 0.02, "cloud_coverage", "How much of the deck is filled (0 = no clouds)")
	_add_ground_fog_slider(vbox, "Deck Density:", 0.0, 8.0, 2.5, 0.1, "cloud_density", "Opacity of the cloud banks")

	weather_status_label = Label.new()
	weather_status_label.name = "WeatherStatus"
	weather_status_label.text = "Weather: Clear | Hour: 8.0"
	weather_status_label.add_theme_font_size_override("font_size", 10)
	weather_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(weather_status_label)


func _build_clouds_tab(vbox: VBoxContainer) -> void:
	_add_section(vbox, "Clouds")
	# Renderer selector: ids match WeatherControls.CloudRenderer enum
	var renderer_row := HBoxContainer.new()
	var renderer_label := Label.new()
	renderer_label.text = "Renderer:"
	renderer_label.add_theme_font_size_override("font_size", 11)
	renderer_label.custom_minimum_size.x = 70
	renderer_row.add_child(renderer_label)
	cloud_renderer_dropdown = OptionButton.new()
	cloud_renderer_dropdown.add_item("Off", 0)
	cloud_renderer_dropdown.add_item("Cheap (Skydome)", 1)
	cloud_renderer_dropdown.add_item("Volumetric (SunshineClouds2)", 2)
	cloud_renderer_dropdown.selected = 2
	cloud_renderer_dropdown.item_selected.connect(_cb.get("cloud_renderer_changed", Callable()))
	cloud_renderer_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	renderer_row.add_child(cloud_renderer_dropdown)
	vbox.add_child(renderer_row)
	cloud_coverage_slider = create_slider_row(vbox, "Coverage:", 0.0, 1.0, 0.45, _cb.get("cloud_coverage_changed", Callable()))
	cloud_coverage_slider.step = 0.02
	cloud_density_slider = create_slider_row(vbox, "Density:", 0.02, 1.0, 0.14, _cb.get("cloud_density_changed", Callable()) if _cb.has("cloud_density_changed") else Callable())
	cloud_density_slider.step = 0.01
	cloud_sharpness_slider = create_slider_row(vbox, "Sharpness:", 0.0, 2.0, 0.75, _cb.get("cloud_sharpness_changed", Callable()) if _cb.has("cloud_sharpness_changed") else Callable())
	cloud_sharpness_slider.step = 0.02
	cloud_size_slider = create_slider_row(vbox, "Size:", 0.3, 3.0, 1.0, _cb.get("cloud_size_changed", Callable()) if _cb.has("cloud_size_changed") else Callable())
	cloud_size_slider.step = 0.05
	wind_strength_slider = create_slider_row(vbox, "Wind:", 0.0, 1.0, 0.25, _cb.get("wind_strength_changed", Callable()) if _cb.has("wind_strength_changed") else Callable())
	wind_strength_slider.step = 0.02


func _build_water_tab(vbox: VBoxContainer) -> void:
	_add_section(vbox, "Water Layers")
	all_water_toggle = _add_checkbox(vbox, "All Water", _initial_state.get("all_water", true), _cb.get("all_water_toggled", Callable()))
	show_ocean_toggle = CheckBox.new()
	show_ocean_toggle.text = "Ocean Surface"
	show_ocean_toggle.button_pressed = _initial_state.get("show_ocean", false)
	show_ocean_toggle.toggled.connect(_cb.get("show_ocean_toggled", Callable()))
	vbox.add_child(show_ocean_toggle)
	rivers_toggle = _add_checkbox(vbox, "Rivers", _initial_state.get("rivers", true), _cb.get("rivers_toggled", Callable()))
	lakes_pools_toggle = _add_checkbox(vbox, "Lakes/Pools", _initial_state.get("lakes_pools", true), _cb.get("lakes_pools_toggled", Callable()))

	ocean_controls_container = VBoxContainer.new()
	ocean_controls_container.name = "OceanControls"
	ocean_controls_container.visible = _initial_state.get("all_water", true)
	vbox.add_child(ocean_controls_container)

	_add_section(ocean_controls_container, "Underwater")
	underwater_medium_toggle = _add_checkbox(ocean_controls_container, "Medium", true, _cb.get("underwater_medium_toggled", Callable()))
	underwater_absorption_toggle = _add_checkbox(ocean_controls_container, "Absorption Fog", true, _cb.get("underwater_absorption_toggled", Callable()))
	underwater_snell_toggle = _add_checkbox(ocean_controls_container, "Snell Window", true, _cb.get("underwater_snell_toggled", Callable()))
	underwater_wobble_toggle = _add_checkbox(ocean_controls_container, "Wobble", true, _cb.get("underwater_wobble_toggled", Callable()))
	underwater_caustics_toggle = _add_checkbox(ocean_controls_container, "Caustics", true, _cb.get("underwater_caustics_toggled", Callable()))
	underwater_particles_toggle = _add_checkbox(ocean_controls_container, "Particles", true, _cb.get("underwater_particles_toggled", Callable()))
	underwater_particle_quality_btn = _add_quality_dropdown(ocean_controls_container, "Particle Q:", 3, _cb.get("underwater_particle_quality_changed", Callable()))
	underwater_particle_opacity_slider = create_slider_row(ocean_controls_container, "Particle Opacity:", 0.0, 2.0, 1.0, _cb.get("underwater_particle_opacity_changed", Callable()))
	underwater_particle_opacity_slider.step = 0.05

	_add_section(ocean_controls_container, "Optics")
	water_turbidity_slider = create_slider_row(ocean_controls_container, "Turbidity:", 0.0, 1.0, 0.0, _cb.get("water_turbidity_changed", Callable()))
	water_turbidity_slider.step = 0.01
	water_visibility_slider = create_slider_row(ocean_controls_container, "Visibility m:", 1.0, 500.0, 58.0, _cb.get("water_visibility_changed", Callable()))
	water_visibility_slider.step = 1.0
	var color_row := HBoxContainer.new()
	var color_label := Label.new()
	color_label.text = "Color:"
	color_label.add_theme_font_size_override("font_size", 11)
	color_label.custom_minimum_size.x = 70
	color_row.add_child(color_label)
	water_color_picker = ColorPickerButton.new()
	water_color_picker.color = Color(0.02, 0.04, 0.06, 1.0)
	water_color_picker.edit_alpha = false
	water_color_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	water_color_picker.color_changed.connect(_cb.get("water_color_changed", Callable()))
	color_row.add_child(water_color_picker)
	ocean_controls_container.add_child(color_row)

	_add_section(ocean_controls_container, "Surface")
	wave_scale_slider = create_slider_row(ocean_controls_container, "Wave Height:", 0.0, 3.0, 1.0, _cb.get("wave_scale_changed", Callable()))
	wave_scale_slider.step = 0.05
	choppiness_slider = create_slider_row(ocean_controls_container, "Choppiness:", 0.0, 1.0, 0.3, _cb.get("choppiness_changed", Callable()) if _cb.has("choppiness_changed") else Callable())
	choppiness_slider.step = 0.02
	surface_ssr_toggle = _add_checkbox(ocean_controls_container, "Surface SSR", true, _cb.get("surface_ssr_toggled", Callable()))
	sea_spray_toggle = _add_checkbox(ocean_controls_container, "Sea Spray", true, _cb.get("sea_spray_toggled", Callable()))
	sea_spray_quality_btn = _add_quality_dropdown(ocean_controls_container, "Spray Q:", 2, _cb.get("sea_spray_quality_changed", Callable()))

	_add_section(ocean_controls_container, "Advanced")
	var quality_row := HBoxContainer.new()
	var quality_label := Label.new()
	quality_label.text = "Quality:"
	quality_label.add_theme_font_size_override("font_size", 11)
	quality_label.custom_minimum_size.x = 70
	quality_row.add_child(quality_label)
	water_quality_btn = OptionButton.new()
	water_quality_btn.add_item("Auto", -1)
	water_quality_btn.add_item("Flat", 0)
	water_quality_btn.add_item("High FFT", 1)
	water_quality_btn.selected = 0
	water_quality_btn.item_selected.connect(_cb.get("water_quality_changed", Callable()))
	water_quality_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quality_row.add_child(water_quality_btn)
	ocean_controls_container.add_child(quality_row)

	water_status_label = Label.new()
	water_status_label.name = "WaterStatus"
	water_status_label.text = "Water: medium ON | particles ON"
	water_status_label.add_theme_font_size_override("font_size", 10)
	water_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	ocean_controls_container.add_child(water_status_label)


func _build_distance_tab(vbox: VBoxContainer) -> void:
	var camera_label := Label.new()
	camera_label.name = "CameraLabel"
	camera_label.add_theme_font_size_override("font_size", 11)
	camera_label.text = "Cell: (0, 0) | Mode: Fly"
	vbox.add_child(camera_label)

	_add_section(vbox, "View")
	var dist_label := Label.new()
	dist_label.name = "DistLabel"
	dist_label.text = StreamingConfig.format_view_distance(_initial_state.get("view_distance", StreamingConfig.DEFAULT_VIEW_DISTANCE_METERS))
	dist_label.add_theme_font_size_override("font_size", 11)
	view_distance_label = dist_label
	vbox.add_child(dist_label)

	_add_section(vbox, "Streaming Tiers")
	near_gameplay_toggle = _add_checkbox(vbox, "Gameplay Objects", _initial_state.get("near_gameplay", true), _cb.get("near_gameplay_toggled", Callable()))
	near_gameplay_toggle.tooltip_text = "NEAR Node3D cells: doors, containers, NPCs, activators. Not scenery."
	static_visuals_toggle = _add_checkbox(vbox, "Static Scenery", _initial_state.get("static_visuals", true), _cb.get("static_visuals_toggled", Callable()))
	static_visuals_toggle.tooltip_text = "All static scenery from 0m out (the static renderer owns the whole 0-400m visual world)."
	far_impostors_toggle = _add_checkbox(vbox, "Impostors", _initial_state.get("far_impostors", true), _cb.get("far_impostors_toggled", Callable()))
	far_impostors_toggle.tooltip_text = "FAR-tier billboards (1.2km+ with CHUNK on, else 400m+)."
	chunk_toggle = _add_checkbox(vbox, "Merged Cells (CHUNK)", _initial_state.get("chunk", false), _cb.get("chunk_toggled", Callable()))
	chunk_toggle.tooltip_text = "Offline-baked merged ring proxies (400-1200m). Requires a bake on disk (chunk_proxy_bake_runner.tscn)."
	distant_lights_toggle = _add_checkbox(vbox, "Distant Lights", _initial_state.get("distant_lights", true), _cb.get("distant_lights_toggled", Callable()))

	chunk_status_label = Label.new()
	chunk_status_label.name = "ChunkStatusLabel"
	chunk_status_label.text = "CHUNK: Off"
	chunk_status_label.add_theme_font_size_override("font_size", 10)
	chunk_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(chunk_status_label)

	_add_section(vbox, "Terrain")
	var terrain_label := Label.new()
	terrain_label.name = "TerrainLabel"
	terrain_label.add_theme_font_size_override("font_size", 11)
	terrain_label.text = "Regions: --"
	vbox.add_child(terrain_label)

	_add_section(vbox, "Characters")
	show_characters_toggle = _add_checkbox(vbox, "NPCs", _initial_state.get("show_characters", false), _cb.get("show_characters_toggled", Callable()))

	_add_section(vbox, "Quick Teleport")
	_add_teleport_row(vbox, [{"label": "Seyda Neen", "x": -2, "y": -9}, {"label": "Balmora", "x": -3, "y": -2}])
	_add_teleport_row(vbox, [{"label": "Vivec", "x": 5, "y": -6}, {"label": "Origin", "x": 0, "y": 0}])


func _add_checkbox(parent: Control, text: String, pressed: bool, callback: Callable) -> CheckBox:
	var check := CheckBox.new()
	check.text = text
	check.button_pressed = pressed
	check.toggled.connect(callback)
	parent.add_child(check)
	return check


func _add_quality_dropdown(parent: Control, label_text: String, selected_id: int, callback: Callable) -> OptionButton:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 11)
	label.custom_minimum_size.x = 70
	row.add_child(label)
	var dropdown := OptionButton.new()
	dropdown.add_item("Off", 0)
	dropdown.add_item("Low", 1)
	dropdown.add_item("Medium", 2)
	dropdown.add_item("High", 3)
	dropdown.selected = clampi(selected_id, 0, 3)
	dropdown.item_selected.connect(callback)
	dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(dropdown)
	parent.add_child(row)
	return dropdown


func _add_teleport_row(parent: Control, entries: Array[Dictionary]) -> void:
	var teleport_cb: Callable = _cb.get("teleport_to_cell", Callable())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	for data: Dictionary in entries:
		var btn := Button.new()
		var target_x := int(data["x"])
		var target_y := int(data["y"])
		btn.text = str(data["label"])
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(func() -> void: teleport_cb.call(target_x, target_y))
		row.add_child(btn)
	parent.add_child(row)


# ══════════════════════════════════════════════════════════════════════════════
# TAB: LIGHTING (live LightTuning knobs)
# ══════════════════════════════════════════════════════════════════════════════

## Light-tuning slider helper: binds the "light_tuning_param" callback with the
## LightTuning field name (mirrors _add_ground_fog_slider).
func _add_light_slider(parent: VBoxContainer, label_text: String, min_val: float, max_val: float, default_val: float, step: float, param_name: String, tooltip: String) -> void:
	var cbv: Callable = _cb.get("light_tuning_param", Callable())
	var bound := cbv.bind(param_name) if cbv.is_valid() else Callable()
	var slider := create_slider_row(parent, label_text, min_val, max_val, default_val, bound, step)
	slider.tooltip_text = tooltip


## Live lighting knobs (LightTuning). Aggregate + distant energy read live every
## tick; size/reach/spread re-apply via DistantLightManager.refresh_tunables();
## near lights pick up new values as cells restream.
func _build_lighting_tab(vbox: VBoxContainer) -> void:
	_add_section(vbox, "Near / Real Lights")
	_add_light_slider(vbox, "Size", 1.0, 12.0, LightTuning.radius_multiplier, 0.1, "radius_multiplier",
		"Multiplier on every real light's radius (near + distant). Bigger pools overlap into a warm town wash.")
	_add_light_slider(vbox, "Near", 0.2, 8.0, LightTuning.near_energy_multiplier, 0.1, "near_energy_multiplier",
		"Brightness of the close-up lanterns (0-60 m). Live.")
	_add_light_slider(vbox, "Distant", 0.2, 8.0, LightTuning.distant_energy_multiplier, 0.1, "distant_energy_multiplier",
		"Brightness of the individual distant lights (55-350 m). Live.")

	_add_section(vbox, "Town Glow (far)")
	_add_light_slider(vbox, "Glow", 0.0, 8.0, LightTuning.aggregate_energy_base, 0.1, "aggregate_energy_base",
		"Brightness of the aggregated warm town-glow seen from afar (250 m-1.2 km). Live.")
	_add_light_slider(vbox, "Reach", 300.0, 900.0, LightTuning.aggregate_near_full_m, 25.0, "aggregate_near_full_m",
		"Distance at which the town-glow fully takes over from the individual lights. Live.")
	_add_light_slider(vbox, "Spread", 0.0, 300.0, LightTuning.aggregate_range_margin_m, 10.0, "aggregate_range_margin_m",
		"How far each town-glow blob spreads beyond the town's lights.")


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

	# ── Global Illumination ──
	_add_section(vbox, "Global Illumination")

	sdfgi_toggle = CheckBox.new()
	sdfgi_toggle.text = "SDFGI"
	# Defaults OFF — matches EnvironmentControls._visual_state["sdfgi"] and the
	# environment SkyManager builds. Camera-centered cascades produce a bright
	# GI bubble around the camera at night; when enabled, SkyManager dims its
	# energy with the day/night cycle so the halo doesn't return.
	sdfgi_toggle.button_pressed = false
	sdfgi_toggle.toggled.connect(_cb.get("sdfgi_toggled", Callable()))
	sdfgi_toggle.tooltip_text = "Signed-Distance-Field Global Illumination — camera-centered indirect bounce/ambient. Off by default (frame cost + night halo); energy tracks the day/night cycle when on."
	vbox.add_child(sdfgi_toggle)

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

	var chunk_debug_toggle := CheckBox.new()
	chunk_debug_toggle.text = "Show HLOD Chunks"
	chunk_debug_toggle.button_pressed = _initial_state.get("show_chunk_debug", false)
	chunk_debug_toggle.toggled.connect(_cb.get("show_chunks_toggled", Callable()))
	chunk_debug_toggle.tooltip_text = "Visualize HLOD chunk state: active, queued, pending, or rejected"
	lod_panel.add_content(chunk_debug_toggle)

	var tier_toggle := CheckBox.new()
	tier_toggle.text = "Show Distance Tiers"
	tier_toggle.button_pressed = _initial_state.get("show_tier_debug", false)
	tier_toggle.toggled.connect(_cb.get("show_tiers_toggled", Callable()))
	tier_toggle.tooltip_text = "Visualize NEAR/MID/HLOD/FAR tier zones with colors"
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
