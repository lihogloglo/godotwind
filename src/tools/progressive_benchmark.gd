## ProgressiveBenchmark — automated additive subsystem cost sweep.
##
## Per `docs/audit/BENCHMARK_V2_PLAN.md` §4.4: runs the v2 scripted 85s flyby
## 10 times in one session, enabling subsystems one-at-a-time in a fixed order.
## Each row of the output CSV is the rendering cost of the *stack up to and
## including* that subsystem — the delta to the previous row is that
## subsystem's marginal cost under realistic (not warm-cache) conditions.
##
## This is NOT the same as v1's cross-session isolation: allocations (VRAM
## atlases, prebaked meshes) persist across passes, so "progressive" measures
## RENDERING cost. Allocation cost only shows up in the launch-time delta
## between runs, not in this sweep.
##
## Wall-clock: ~15.5 min (11 × 85s flyby + 11 × 2s settle + finalization).
class_name ProgressiveBenchmark
extends Node

const StreamingBenchmarkScript := preload("res://src/tools/streaming_benchmark.gd")

## Additive toggle order. HLOD is included before impostors now that distant
## rendering is default-on again. Ordering builds up the render cost from
## cheapest (terrain alone) to heaviest (terrain + everything).
const PROGRESSIVE_ORDER: Array[String] = [
	"terrain",
	"near_objects",
	"mid_objects",
	"hlod",
	"impostors",
	"shadows",
	"postfx",
	"sky",
	"weather",
	"characters",
]

## Settle time between toggle state changes (before the next flyby starts).
## Gives RS instance create/destroy churn a chance to quiesce so the flyby
## measurement isn't contaminated by the transition cost.
const SETTLE_BETWEEN_PASSES_S := 2.0

#region State

var _streaming_manager: Variant = null  # NativeStreamingManager
var _cell_manager: Variant = null       # CellManager
var _camera: Camera3D = null
var _console: Node = null
var _toggles: RefCounted = null          # SubsystemToggles

## -1 = baseline (all OFF), 0..N-1 = enable PROGRESSIVE_ORDER[i] cumulatively
var _index: int = -1

## Aggregate results, one entry per pass, ordered same as flyby order.
var _results: Array[Dictionary] = []

## Reference to the currently-running flyby benchmark node, for safety checks.
var _active_bench: Node = null

## Wall-clock start for progress reporting.
var _start_ms: int = 0

## Tracks the currently-active progressive orchestrator so bench_progressive
## refuses to spawn a second one while one is running.
static var _active_progressive: ProgressiveBenchmark = null

#endregion


func init_progressive(
	streaming_manager: Variant,
	cell_manager: Variant,
	camera: Camera3D,
	console: Node,
	toggles: RefCounted
) -> void:
	_streaming_manager = streaming_manager
	_cell_manager = cell_manager
	_camera = camera
	_console = console
	_toggles = toggles
	_start_ms = Time.get_ticks_msec()

	var total_passes := PROGRESSIVE_ORDER.size() + 1  # baseline + each
	var est_s := total_passes * (85 + int(SETTLE_BETWEEN_PASSES_S))
	Log.info("tools", "ProgressiveBenchmark: starting %d passes (~%d min wall-clock)" % [
		total_passes, int(est_s / 60.0 + 0.5)
	])
	_print_console("progressive: %d passes (~%d min), baseline then additive toggle order" % [
		total_passes, int(est_s / 60.0 + 0.5)
	])

	# Start with everything OFF — baseline pass measures empty-world render cost.
	_toggles.disable_all()
	_run_next_pass()


func _run_next_pass() -> void:
	if _index >= PROGRESSIVE_ORDER.size():
		_finalize()
		return

	# Apply the toggle for this pass (skip on baseline index=-1)
	var label := "baseline"
	if _index >= 0:
		label = PROGRESSIVE_ORDER[_index]
		_toggles.set_flag(label, true)

	Log.info("tools", "ProgressiveBenchmark: pass %d/%d — label '%s'" % [
		_index + 2, PROGRESSIVE_ORDER.size() + 1, label
	])
	_print_console("progressive pass %d/%d: %s" % [
		_index + 2, PROGRESSIVE_ORDER.size() + 1, label
	])

	# Let the RS instance churn from the just-applied toggle settle before
	# we start measuring the steady-state render cost of this stack.
	await get_tree().create_timer(SETTLE_BETWEEN_PASSES_S).timeout

	# Spawn a fresh StreamingBenchmark instance. It runs its own 85s flyby,
	# writes per-frame CSV + events CSV + JSON summary (under the default
	# benchmark_* filenames), and emits benchmark_complete on finish. We
	# don't touch its internals — this orchestrator is purely external.
	var bench := StreamingBenchmarkScript.new()
	bench.name = "ProgressivePass_%s" % label
	get_tree().root.add_child(bench)
	bench.benchmark_complete.connect(_on_pass_complete.bind(label), CONNECT_ONE_SHOT)
	bench.init_console_mode(_streaming_manager, _cell_manager, _camera, _console)
	_active_bench = bench


func _on_pass_complete(results: Dictionary, label: String) -> void:
	_active_bench = null

	# Attach the label + the current toggle state snapshot for the aggregate CSV
	results["label"] = label
	results["enabled_subsystems"] = _enabled_list_string()
	_results.append(results)

	_index += 1
	# The just-finished StreamingBenchmark queue_frees itself 1s after emit.
	# We can safely start the next pass immediately; the _cleanup timer runs
	# in parallel without interfering.
	_run_next_pass()


func _finalize() -> void:
	var elapsed_s := float(Time.get_ticks_msec() - _start_ms) / 1000.0
	_print_summary_table(elapsed_s)
	_save_progressive_csv()

	# Restore toggles to their defaults so the next user interaction starts
	# from a known baseline instead of everything-on.
	if _toggles:
		_toggles.reset()

	if _active_progressive == self:
		_active_progressive = null

	# Brief hold so the user can read the final summary in the console, then
	# free the orchestrator node.
	get_tree().create_timer(1.0).timeout.connect(queue_free)


#region Reporting

func _enabled_list_string() -> String:
	if _index < 0:
		return "(baseline — none)"
	var names: PackedStringArray = PackedStringArray()
	for i in range(_index + 1):
		names.append(PROGRESSIVE_ORDER[i])
	return ", ".join(names)


func _print_summary_table(elapsed_s: float) -> void:
	if _results.is_empty():
		return

	var lines: PackedStringArray = PackedStringArray()
	lines.append("")
	lines.append("========== PROGRESSIVE BENCHMARK RESULTS ==========")
	lines.append("Wall-clock: %.1f min (%.1fs)" % [elapsed_s / 60.0, elapsed_s])
	lines.append("")
	lines.append("%-16s %8s %8s %10s %10s %8s" % [
		"label", "avg_fps", "p95_ms", "draw_avg", "vram_mb", "delta_ms"
	])
	lines.append("----------------------------------------------------------------------")

	# Row per pass; delta_ms is "this_pass.avg_ms - prev_pass.avg_ms" so the
	# reader sees each subsystem's marginal cost at a glance.
	var prev_avg_ms := 0.0
	for i in range(_results.size()):
		var r: Dictionary = _results[i]
		var label: String = r.get("label", "?")
		var avg_fps: float = r.get("avg_fps", 0.0)
		var p95_ms: float = r.get("p95_ms", 0.0)
		var draw_avg: int = int(r.get("avg_draw_calls", 0))
		var vram_mb: float = r.get("peak_vram_mb", 0.0)
		var avg_ms: float = r.get("avg_time_ms", 0.0)
		var delta_ms_str := "—" if i == 0 else "%+.2f" % (avg_ms - prev_avg_ms)
		lines.append("%-16s %8.1f %8.1f %10d %10.0f %8s" % [
			label, avg_fps, p95_ms, draw_avg, vram_mb, delta_ms_str
		])
		prev_avg_ms = avg_ms

	lines.append("======================================================================")
	lines.append("delta_ms shows THIS pass's avg frame time minus the previous pass —")
	lines.append("that subsystem's marginal render cost in realistic play conditions.")
	lines.append("NOTE: allocation cost (VRAM atlases etc) persists across passes, so")
	lines.append("delta is RENDERING cost only. Launch-time cost is NOT captured here.")
	lines.append("")

	var output := "\n".join(lines)
	Log.info("tools", output)
	if _console and _console.has_method("print_line"):
		for line: String in lines:
			_console.print_line(line)


func _save_progressive_csv() -> void:
	var dir_path := "user://benchmark_results"
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var file_path := "%s/progressive_%s.csv" % [dir_path, timestamp]

	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if not file:
		Log.error("tools", "ProgressiveBenchmark: Failed to write CSV to %s" % file_path)
		return

	file.store_line("pass,label,enabled_subsystems,avg_fps,avg_ms,p50_ms,p95_ms,p99_ms,max_ms,avg_draw_calls,peak_draw_calls,peak_vram_mb,peak_texture_mb,total_frames")
	for i in range(_results.size()):
		var r: Dictionary = _results[i]
		var enabled: String = str(r.get("enabled_subsystems", "")).replace(",", ";")
		file.store_line("%d,%s,%s,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%d,%.0f,%.0f,%d" % [
			i,
			str(r.get("label", "?")),
			enabled,
			r.get("avg_fps", 0.0),
			r.get("avg_time_ms", 0.0),
			r.get("p50_ms", 0.0),
			r.get("p95_ms", 0.0),
			r.get("p99_ms", 0.0),
			r.get("max_time_ms", 0.0),
			int(r.get("avg_draw_calls", 0)),
			int(r.get("peak_draw_calls", 0)),
			r.get("peak_vram_mb", 0.0),
			r.get("peak_texture_mb", 0.0),
			int(r.get("total_frames", 0)),
		])
	file.close()
	Log.info("tools", "ProgressiveBenchmark: CSV saved to %s" % file_path)
	_print_console("progressive CSV: %s" % file_path)


func _print_console(text: String) -> void:
	if _console and _console.has_method("print_line"):
		_console.print_line(text)

#endregion


#region Console Command Helper

static func register_console_commands(
	console: Node,
	streaming_manager: Variant,
	cell_manager: Variant,
	camera: Camera3D,
	toggles: RefCounted
) -> void:
	var run_progressive := func(_args: Dictionary) -> Variant:
		if _active_progressive != null and is_instance_valid(_active_progressive):
			return "bench_progressive: already running (in-flight, cannot restart)"
		var orchestrator := ProgressiveBenchmark.new()
		orchestrator.name = "ProgressiveBenchmark"
		console.get_tree().root.add_child(orchestrator)
		_active_progressive = orchestrator
		# init runs asynchronously (awaits settle timers) — return a string
		# immediately so the console doesn't block.
		orchestrator.init_progressive(streaming_manager, cell_manager, camera, console, toggles)
		var total := PROGRESSIVE_ORDER.size() + 1
		var est_min := int((total * (85 + SETTLE_BETWEEN_PASSES_S)) / 60.0 + 0.5)
		return "bench_progressive: %d passes, ~%d min. Watch the HUD or wait for summary." % [total, est_min]

	console.register_command(
		"bench_progressive", run_progressive,
		"Run additive subsystem cost sweep (%d passes × 85s flyby, ~%d min)" % [
			PROGRESSIVE_ORDER.size() + 1,
			int((PROGRESSIVE_ORDER.size() + 1) * (85 + SETTLE_BETWEEN_PASSES_S) / 60.0 + 0.5),
		],
		"debug",
		PackedStringArray([]),
	)

#endregion
