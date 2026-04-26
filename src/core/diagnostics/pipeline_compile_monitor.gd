## PipelineCompileMonitor — snapshot/delta wrapper around
## RenderingServer.get_pipeline_compilations_from_source.
##
## Verifies the canonical Godot 4.4+ pipeline pre-compile path:
## ResourceLoader.load(.res with mesh) should trigger MESH/SURFACE compiles
## off the render thread (per pipeline_compilations.html). DRAW spikes during
## gameplay frames = missed pre-warm = first-visibility stutter.
##
## Used by:
##   - native_streaming_manager heartbeat (per-5s totals)
##   - cell_preloader LOADING → READY transition (per-preload delta)
##   - native_streaming_manager cell_loaded.emit (per-cell-load delta)
##
## Diagnostic decision tree from logged deltas:
##   preload Δ:MESH/SURFACE > 0 → pre-compile working at load time. Fix=teleport-warm.
##   activate Δ:MESH/SURFACE > 0 (preload was 0) → pre-compile fires at instantiate.
##     Fix=hidden-instance pre-warm in CellPreloader DATA phase.
##   activate Δ:DRAW > 0 → first-visibility shader stutter. Fix as above + verify
##     ubershaders are enabled (default in Forward+ since 4.4 per PR #90400).
##
## Plan: docs/plans/distant_rendering_2026_04/cell_transition_stutter_phase2.md §2.2.
class_name PipelineCompileMonitor
extends RefCounted


## Cached snapshot of all 5 pipeline source counters.
## Order matches RenderingServer.PIPELINE_SOURCE_* enum (canvas, mesh, surface, draw, spec).
var _last: PackedInt64Array = PackedInt64Array()


func _init() -> void:
	_last.resize(5)
	_last.fill(0)


## One-shot snapshot. Returns counts in canonical order:
##   [canvas, mesh, surface, draw, specialization]
##
## Verified against Godot 4.6 doctool dump 2026-04-25:
##   RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS         = 6
##   RENDERING_INFO_PIPELINE_COMPILATIONS_MESH           = 7
##   RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE        = 8
##   RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW           = 9
##   RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION = 10
## Query API: RenderingServer.get_rendering_info(RenderingInfo) -> int.
## (Public PIPELINE_SOURCE enum is internal-use; the public counter API
## is RenderingInfo via get_rendering_info.)
static func snapshot() -> PackedInt64Array:
	var snap: PackedInt64Array = PackedInt64Array()
	snap.resize(5)
	snap[0] = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS)
	snap[1] = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH)
	snap[2] = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE)
	snap[3] = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW)
	snap[4] = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION)
	return snap


## Take a snapshot, compute delta vs last call, update internal state.
## Returns delta in canonical order [canvas, mesh, surface, draw, specialization].
## First call returns zeros (no prior snapshot).
func delta_and_update() -> PackedInt64Array:
	var snap := snapshot()
	var delta: PackedInt64Array = PackedInt64Array()
	delta.resize(5)
	for i in 5:
		delta[i] = snap[i] - _last[i]
	_last = snap
	return delta


## Reset internal baseline to current. Use AFTER warmup completes so deltas
## reflect steady-state cost only.
func reset_baseline() -> void:
	_last = snapshot()


## Format a delta as a compact log-friendly string.
## Example: "[c:0 m:5 sf:12 dr:0 sp:1]"
##
## Field key:
##   c  = CANVAS  — 2D draw pipelines (irrelevant for 3D streaming)
##   m  = MESH    — fired by ArrayMesh load. Should fire at preload time.
##   sf = SURFACE — fired by surface cache creation. Fires at instantiation.
##   dr = DRAW    — fired at first draw. NON-ZERO = stutter source.
##   sp = SPEC    — ubershader background optimization. Non-stuttering.
static func format_delta(delta: PackedInt64Array) -> String:
	if delta.size() < 5:
		return "[invalid]"
	return "[c:%d m:%d sf:%d dr:%d sp:%d]" % [delta[0], delta[1], delta[2], delta[3], delta[4]]


## True if any of the four "interesting" categories (mesh, surface, draw, spec)
## changed. Useful for skipping noise lines in a heartbeat where nothing happened.
static func has_activity(delta: PackedInt64Array) -> bool:
	if delta.size() < 5:
		return false
	return delta[1] != 0 or delta[2] != 0 or delta[3] != 0 or delta[4] != 0


## True if a compile fired in the DRAW source — almost always a user-visible
## stutter signal (the engine missed the pre-warm window). Used to escalate log
## level (info → warn) when something interesting happened.
static func has_draw_compile(delta: PackedInt64Array) -> bool:
	if delta.size() < 5:
		return false
	return delta[3] > 0
