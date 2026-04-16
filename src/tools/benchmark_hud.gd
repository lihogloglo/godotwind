## BenchmarkHUD — live performance overlay for in-session investigation.
##
## Per `docs/audit/BENCHMARK_V2_PLAN.md` §4.2: replaces cross-session isolation
## (v1) with the Unreal `stat` / Unity Profiler pattern — developer flies the
## camera, toggles subsystems live via `toggle <name>`, reads the HUD.
##
## Default hidden. Toggled with `hud` console command; rolling window cleared
## with `hud_reset`. Statistics collected every frame unconditionally so the
## user gets meaningful numbers immediately after `hud` without a 5s warm-up.
##
## Usage:
##   var hud := BenchmarkHUD.new()
##   get_tree().root.add_child(hud)
##   hud.set_streaming_manager(native_streaming_manager)
##   hud.set_subsystem_toggles(_subsystem_toggles)
##   BenchmarkHUD.register_console_commands(console, hud)
class_name BenchmarkHUD
extends CanvasLayer

## Rolling window size in seconds (matches plan spec)
const ROLLING_WINDOW_S := 5.0

## UI rebuild interval — throttled so the HUD itself doesn't perturb the
## measurement it's reporting. Statistics are still updated every frame.
const UI_UPDATE_INTERVAL_S := 0.1

## Percentile used for rolling tail-latency report
const P95_FRACTION := 0.95

#region State

## Rolling frame-time buffer. Each entry is (timestamp_ms, frame_ms).
## Timestamp is used to trim entries older than ROLLING_WINDOW_S.
var _rolling_times_ms: PackedFloat64Array = PackedFloat64Array()
var _rolling_timestamps_ms: PackedFloat64Array = PackedFloat64Array()

## Time since last UI rebuild
var _ui_elapsed: float = 0.0

## External references (injected via setters, optional)
var _streaming_manager: Node = null
var _subsystem_toggles: RefCounted = null

#endregion


#region UI Nodes

var _panel_bg: PanelContainer = null
var _vbox: VBoxContainer = null
var _label_frame: Label = null
var _label_rolling: Label = null
var _label_cpu: Label = null
var _label_phases: Label = null
var _label_memory: Label = null
var _label_streaming: Label = null
var _label_toggles: Label = null

#endregion


func _ready() -> void:
	layer = 100  # draw above the normal UI / console
	_build_ui()
	hide_hud()  # default hidden per plan


#region Injection

func set_streaming_manager(sm: Node) -> void:
	_streaming_manager = sm


func set_subsystem_toggles(t: RefCounted) -> void:
	_subsystem_toggles = t

#endregion


#region Visibility control

func show_hud() -> void:
	if _panel_bg:
		_panel_bg.visible = true


func hide_hud() -> void:
	if _panel_bg:
		_panel_bg.visible = false


func toggle_visibility() -> bool:
	if not _panel_bg:
		return false
	_panel_bg.visible = not _panel_bg.visible
	return _panel_bg.visible


func is_visible_hud() -> bool:
	return _panel_bg != null and _panel_bg.visible

#endregion


#region Rolling window

## Clear the rolling window — next statistics will reflect only frames from
## this moment on. Useful after a subsystem toggle change to get a fresh
## measurement without the pre-toggle samples polluting the average.
func reset_rolling() -> void:
	_rolling_times_ms.clear()
	_rolling_timestamps_ms.clear()
	_ui_elapsed = 0.0


func _push_rolling_sample(frame_ms: float, now_ms: float) -> void:
	_rolling_times_ms.append(frame_ms)
	_rolling_timestamps_ms.append(now_ms)

	# Trim entries older than ROLLING_WINDOW_S. We store timestamps in order
	# so we can walk from the front until we hit an entry still in-window.
	var cutoff_ms := now_ms - ROLLING_WINDOW_S * 1000.0
	var drop_count := 0
	for ts in _rolling_timestamps_ms:
		if ts >= cutoff_ms:
			break
		drop_count += 1
	if drop_count > 0:
		# PackedFloat64Array has no slice-remove, so rebuild the tail. Cheap
		# at our size (~300 entries at 60fps steady state).
		_rolling_times_ms = _rolling_times_ms.slice(drop_count)
		_rolling_timestamps_ms = _rolling_timestamps_ms.slice(drop_count)


func _rolling_avg_fps() -> float:
	if _rolling_times_ms.is_empty():
		return 0.0
	var total := 0.0
	for t: float in _rolling_times_ms:
		total += t
	var avg_ms := total / float(_rolling_times_ms.size())
	return 1000.0 / maxf(avg_ms, 0.001)


func _rolling_p95_ms() -> float:
	if _rolling_times_ms.is_empty():
		return 0.0
	var sorted: PackedFloat64Array = _rolling_times_ms.duplicate()
	sorted.sort()
	var idx := int(float(sorted.size()) * P95_FRACTION)
	return sorted[mini(idx, sorted.size() - 1)]

#endregion


func _process(delta: float) -> void:
	# Statistics update every frame (cheap), UI rebuild throttled.
	var frame_ms := delta * 1000.0
	var now_ms := float(Time.get_ticks_msec())
	_push_rolling_sample(frame_ms, now_ms)

	_ui_elapsed += delta
	if _ui_elapsed < UI_UPDATE_INTERVAL_S:
		return
	_ui_elapsed = 0.0

	# Skip UI work entirely while hidden — saves the string allocation cost
	# from perturbing measurements the user might be taking.
	if not is_visible_hud():
		return

	_rebuild_labels(frame_ms)


#region UI Construction / Update

func _build_ui() -> void:
	_panel_bg = PanelContainer.new()
	_panel_bg.name = "BenchmarkHUDPanel"
	_panel_bg.position = Vector2(10, 10)
	# Pass mouse events through to gameplay — without this the HUD rect
	# blackholes clicks/drags that originate over it (fly-cam drag near
	# top-left, UI raycast, etc). Children inherit pass-through.
	_panel_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel_bg.add_theme_stylebox_override("panel", _create_panel_style())
	add_child(_panel_bg)

	_vbox = VBoxContainer.new()
	_panel_bg.add_child(_vbox)

	var title := Label.new()
	title.text = "Benchmark HUD"
	title.add_theme_font_size_override("font_size", 16)
	_vbox.add_child(title)

	_label_frame = _add_label("frame: --")
	_label_rolling = _add_label("5s avg: -- | p95: --")
	_label_cpu = _add_label("proc: --ms | phys: --ms | objs: --")
	_label_phases = _add_label("stream: inst=-- async=-- promo=-- unload=-- (ms)")
	_label_memory = _add_label("vram: -- | tex: -- | nodes: --")
	_label_streaming = _add_label("cells: -- | queue: -- | async: --")
	_label_toggles = _add_label("toggles: --")


func _add_label(initial_text: String) -> Label:
	var label := Label.new()
	label.text = initial_text
	label.add_theme_font_size_override("font_size", 13)
	_vbox.add_child(label)
	return label


func _create_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.7)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	return style


func _rebuild_labels(frame_ms: float) -> void:
	# Current frame
	var cur_fps := Engine.get_frames_per_second()
	var cur_draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_label_frame.text = "frame: %.1fms (%d FPS) | draws: %d" % [frame_ms, cur_fps, cur_draws]

	# Rolling 5s window
	var avg_fps := _rolling_avg_fps()
	var p95_ms := _rolling_p95_ms()
	_label_rolling.text = "5s avg: %.1f FPS | p95: %.1fms (%d samples)" % [
		avg_fps, p95_ms, _rolling_times_ms.size()
	]

	# CPU breakdown — key for GPU vs CPU diagnosis
	# proc_ms ≈ total GDScript _process time; phys_ms ≈ Jolt tick time.
	# If frame_ms >> proc_ms + phys_ms → GPU bound. If proc_ms ≈ frame_ms → GDScript bound.
	var p := Performance
	var proc_ms := p.get_monitor(p.TIME_PROCESS) * 1000.0
	var phys_ms := p.get_monitor(p.TIME_PHYSICS_PROCESS) * 1000.0
	var rendered_objs := int(p.get_monitor(p.RENDER_TOTAL_OBJECTS_IN_FRAME))
	_label_cpu.text = "proc: %.1fms | phys: %.1fms | objs: %d" % [proc_ms, phys_ms, rendered_objs]

	# Fetch streaming stats once — shared by phase breakdown + streaming row below.
	var sm_stats: Dictionary = {}
	if _streaming_manager and _streaming_manager.has_method("get_stats"):
		sm_stats = _streaming_manager.get_stats()

	# Streaming phase breakdown — reads _last_phase_times from streaming manager.
	# Key: if inst≈frame_ms → streaming is bottleneck; if all phases small → GPU-bound.
	if _streaming_manager and _streaming_manager.has_method("get_phase_times"):
		var pt: PackedFloat64Array = _streaming_manager.get_phase_times()
		var n := pt.size()
		var burst := bool(sm_stats.get("burst_loading", false))
		var sm_total := float(sm_stats.get("frame_total_ms", 0.0))
		var startup := bool(sm_stats.get("startup_phase", false))
		_label_phases.text = "stream[%s%s]: inst=%.1f async=%.1f promo=%.1f unload=%.1f total=%.1f (ms)" % [
			"STARTUP " if startup else "",
			"BURST" if burst else "norm",
			pt[2]/1000.0 if n > 2 else 0.0,
			pt[1]/1000.0 if n > 1 else 0.0,
			pt[3]/1000.0 if n > 3 else 0.0,
			pt[0]/1000.0 if n > 0 else 0.0,
			sm_total
		]
	else:
		_label_phases.text = "stream: (no manager)"

	# Memory
	var vram_mb := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var tex_mb := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	_label_memory.text = "vram: %dMB | tex: %dMB | nodes: %d" % [int(vram_mb), int(tex_mb), nodes]

	# Streaming state
	var cells := int(sm_stats.get("loaded_cells", 0))
	var queue := int(sm_stats.get("instantiation_queue", 0))
	var async_req := int(sm_stats.get("async_requests", 0))
	_label_streaming.text = "cells: %d | queue: %d | async: %d" % [cells, queue, async_req]

	# Active toggles — list only the ones currently OFF (inverted default).
	# "[ALL ON]" is the common case during an idle HUD view.
	var toggles_text := "toggles: (no toggle system wired)"
	if _subsystem_toggles:
		var state: Dictionary = _subsystem_toggles.get_state()
		var off_names: PackedStringArray = PackedStringArray()
		for name: String in state:
			if not bool(state[name]):
				off_names.append(name)
		off_names.sort()
		if off_names.is_empty():
			toggles_text = "toggles: [ALL ON]"
		else:
			toggles_text = "toggles: [OFF: %s]" % ", ".join(off_names)
	_label_toggles.text = toggles_text

#endregion


#region Console Command Helpers

## Register `hud` + `hud_reset` console commands. Pass the HUD instance so
## multiple world_explorer scenes won't cross-talk.
static func register_console_commands(console: Node, hud: BenchmarkHUD) -> void:
	if not is_instance_valid(hud):
		push_warning("BenchmarkHUD.register_console_commands: hud instance invalid")
		return

	var cmd_hud := func(_args: Dictionary) -> Variant:
		var now_visible := hud.toggle_visibility()
		return "Benchmark HUD: %s" % ("ON" if now_visible else "OFF")

	var cmd_hud_reset := func(_args: Dictionary) -> Variant:
		hud.reset_rolling()
		return "Benchmark HUD: rolling window cleared"

	console.register_command(
		"hud", cmd_hud,
		"Toggle live benchmark HUD overlay",
		"debug",
		PackedStringArray([]),
	)
	console.register_command(
		"hud_reset", cmd_hud_reset,
		"Clear the HUD's rolling 5s window (fresh measurement)",
		"debug",
		PackedStringArray([]),
	)

#endregion
