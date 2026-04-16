## PerfSweep — quick per-subsystem isolation cost sweep (~60s total).
##
## Tests each subsystem in isolation (one off at a time, all others on).
## Shows FPS gain when each subsystem is disabled → sorted cost table.
##
## Console: perf_sweep
## Use `hud` for live FPS while sweep runs.
##
## Output:
##   === Perf Sweep Results ===
##   Baseline: 52 FPS (all on)
##   postfx:      +18 FPS → 70 FPS  (5.5ms / 35% of frame)
##   shadows:     +12 FPS → 64 FPS  (3.7ms / 23%)
##   ...
##   Recommendation: postfx is primary bottleneck
class_name PerfSweep
extends Node

## Subsystems to sweep. Ordered so the most disruptive (terrain blackout) comes last.
## Skips "sky", "weather", "characters", "ocean" — not integrated or not load-bearing.
const SWEEP_ORDER: Array[String] = [
	"near_objects",
	"mid_objects",
	"impostors",
	"shadows",
	"postfx",
	"terrain",
]

## Settle time after disabling a subsystem (let RS instances hide / shaders recompile)
const SETTLE_S := 2.0
## Record window per subsystem
const RECORD_S := 4.0
## Re-enable settle before next test (let objects show again cleanly)
const REENABLE_S := 1.5

enum _State { BASELINE_RECORD, DISABLE_NEXT, SETTLE, RECORD, REENABLE, PAUSE, DONE }

var _state: _State = _State.BASELINE_RECORD
var _timer: float = 0.0

## Accumulated FPS samples for the current measurement window
var _sample_sum: float = 0.0
var _sample_count: int = 0

## Results
var _baseline_fps: float = 0.0
var _results: Array[Dictionary] = []  ## [{name, fps, gain_fps, cost_ms}]
var _current_idx: int = 0

## Dependencies (injected)
var _toggles: RefCounted = null  # SubsystemToggles
var _console: Node = null

## Name of the subsystem currently being tested (for live console feedback)
var _current_name: String = ""


static func register_console_commands(
	console: Node,
	streaming_manager: Variant,
	cell_manager: Variant,
	toggles: RefCounted  # SubsystemToggles — untyped to avoid compile-time resolution failure
) -> void:
	# Can't use PerfSweep.new() directly in a static lambda — self-reference
	# in closures fails at compile time. Load by path instead (same workaround
	# used in streaming_benchmark.gd for the manual-bench lambda).
	var script_ref := load("res://src/tools/perf_sweep.gd")
	var run := func(_args: Dictionary) -> Variant:
		var sweep: Node = script_ref.new()
		sweep.name = "PerfSweep"
		console.get_tree().root.add_child(sweep)
		sweep.init(toggles, console)
		var total_s := int((SETTLE_S + RECORD_S + REENABLE_S) * SWEEP_ORDER.size() + RECORD_S + 4.0)
		return "perf_sweep: starting ~%ds isolation sweep — keep camera still, results logged to console" % total_s

	console.register_command(
		"perf_sweep",
		run,
		"Quick subsystem isolation sweep — shows per-subsystem FPS cost (~60s, keep camera still)",
		"benchmark",
		PackedStringArray(["sweep"]),
	)


func init(toggles: RefCounted, console: Node) -> void:  # toggles: SubsystemToggles
	_toggles = toggles
	_console = console
	_state = _State.BASELINE_RECORD
	_timer = 0.0
	_sample_sum = 0.0
	_sample_count = 0
	_current_idx = 0
	_results.clear()
	Log.info("tools", "PerfSweep: started — baseline %.0fs, then %d subsystems × %.0fs each" % [
		RECORD_S, SWEEP_ORDER.size(), SETTLE_S + RECORD_S + REENABLE_S])
	_print("perf_sweep: recording baseline %.0fs — keep camera still" % RECORD_S)


func _process(delta: float) -> void:
	_timer += delta

	match _state:
		_State.BASELINE_RECORD:
			_accumulate_fps()
			if _timer >= RECORD_S:
				_baseline_fps = _flush_avg()
				_print("baseline: %.0f FPS — starting subsystem sweep..." % _baseline_fps)
				_advance_sweep()

		_State.DISABLE_NEXT:
			# Handled inline in _advance_sweep; state flips to SETTLE immediately
			pass

		_State.SETTLE:
			if _timer >= SETTLE_S:
				_timer = 0.0
				_sample_sum = 0.0
				_sample_count = 0
				_state = _State.RECORD

		_State.RECORD:
			_accumulate_fps()
			if _timer >= RECORD_S:
				var fps := _flush_avg()
				var gain := fps - _baseline_fps
				var frame_ms_baseline := 1000.0 / maxf(_baseline_fps, 0.001)
				var frame_ms_now := 1000.0 / maxf(fps, 0.001)
				var cost_ms := frame_ms_baseline - frame_ms_now  # positive = baseline more expensive
				_results.append({
					"name": _current_name,
					"fps": fps,
					"gain_fps": gain,
					"cost_ms": cost_ms,
				})
				_print("  %s: %.0f FPS (baseline Δ%+.0f FPS)" % [_current_name, fps, gain])
				# Re-enable the subsystem
				if _toggles:
					_toggles.set_flag(_current_name, true)
				_timer = 0.0
				_state = _State.REENABLE

		_State.REENABLE:
			if _timer >= REENABLE_S:
				_current_idx += 1
				_advance_sweep()

		_State.DONE:
			pass


func _advance_sweep() -> void:
	if _current_idx >= SWEEP_ORDER.size():
		_finish()
		_state = _State.DONE
		return

	_current_name = SWEEP_ORDER[_current_idx]

	# Skip subsystems that aren't registered
	if _toggles and not _current_name in _toggles.get_flag_names():
		_current_idx += 1
		_advance_sweep()
		return

	_print("  testing: %s (disabling — wait %.0fs settle + %.0fs record)" % [
		_current_name, SETTLE_S, RECORD_S])

	if _toggles:
		_toggles.set_flag(_current_name, false)

	_timer = 0.0
	_state = _State.SETTLE


func _accumulate_fps() -> void:
	_sample_sum += Engine.get_frames_per_second()
	_sample_count += 1


func _flush_avg() -> float:
	if _sample_count == 0:
		return 0.0
	var avg := _sample_sum / float(_sample_count)
	_sample_sum = 0.0
	_sample_count = 0
	_timer = 0.0
	return avg


func _finish() -> void:
	# Sort results by gain_fps descending (biggest bottleneck first)
	_results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.gain_fps > b.gain_fps
	)

	var lines: PackedStringArray = PackedStringArray()
	lines.append("")
	lines.append("========== PERF SWEEP RESULTS ==========")
	lines.append("Baseline: %.0f FPS (all on)" % _baseline_fps)
	lines.append("  (%.1f ms/frame)" % (1000.0 / maxf(_baseline_fps, 0.001)))
	lines.append("")
	lines.append("Subsystem costs (sorted, highest first):")
	lines.append("  %-15s %8s %10s %8s %8s" % ["subsystem", "FPS w/o", "Δ FPS", "Δ ms", "% frame"])

	var frame_ms_base := 1000.0 / maxf(_baseline_fps, 0.001)
	var primary := ""
	var primary_gain := 0.0
	for r: Dictionary in _results:
		var gain: float = r.gain_fps
		var cost_ms: float = r.cost_ms
		var pct := (cost_ms / frame_ms_base) * 100.0 if frame_ms_base > 0.0 else 0.0
		var marker := " ← PRIMARY" if primary.is_empty() and gain > 5.0 else ""
		lines.append("  %-15s %8.0f %+10.0f %+8.1f %7.1f%%%s" % [
			r.name, r.fps, gain, cost_ms, pct, marker
		])
		if primary.is_empty() and gain > primary_gain:
			primary_gain = gain
			primary = r.name

	lines.append("")
	if not primary.is_empty() and primary_gain > 5.0:
		var fps_after := _baseline_fps + primary_gain
		lines.append("Primary bottleneck: %s (%.0f FPS → %.0f FPS if fixed)" % [primary, _baseline_fps, fps_after])
	elif _baseline_fps >= 60.0:
		lines.append("All subsystems OK — baseline already ≥60 FPS")
	else:
		lines.append("No single bottleneck dominates — may be GPU-bound across all systems")

	lines.append("")
	lines.append("Notes:")
	lines.append("  Δ FPS = FPS gain when subsystem disabled (= its render cost)")
	lines.append("  Negative Δ = subsystem removal made things worse (unexpected, may be GPU pipeline artifact)")
	lines.append("  Run bench_progressive for allocation-phase costs (loading time analysis)")
	lines.append("=========================================")

	var output := "\n".join(lines)
	Log.info("tools", output)
	if _console and _console.has_method("print_line"):
		for line: String in lines:
			_console.print_line(line)

	# Ensure all subsystems are back to defaults
	if _toggles:
		_toggles.reset()

	# Self-destruct after a short delay
	get_tree().create_timer(2.0).timeout.connect(queue_free)


func _print(msg: String) -> void:
	Log.info("tools", "PerfSweep: %s" % msg)
	if _console and _console.has_method("print_line"):
		_console.print_line(msg)
