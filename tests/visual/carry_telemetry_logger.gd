## CarryTelemetryLogger — motion sample recorder for the carry audit
##
## Framework-agnostic diagnostic node that samples position + orientation
## data at BOTH physics tick rate AND render frame rate, so stutter in
## the carry hold loop can be attributed to one of three distinct causes:
##
## 1. PHYSICAL stutter — the held body's actual world position moves in
##    discrete steps (e.g. writes landing on physics ticks, not smoothly
##    every render frame). Signature in data: per-frame Δpos has a
##    bimodal distribution (many near-zero, occasional spikes equal to
##    a full physics-tick worth of motion).
##
## 2. VISUAL stutter — the body's world position is smooth but the
##    camera / composition that determines "where to render" samples it
##    at beat-frequency points. Signature: smooth Δpos in PHYS samples
##    but jagged Δpos in REND samples, with period matching the refresh
##    vs physics tick LCM.
##
## 3. COMPOSITION jitter — the target_world_pos the body chases already
##    contains jitter before the lerp ever runs. Signature: the computed
##    target (player_interp × rig_offset_live) has non-monotonic Δ per
##    frame, even when the player walks in a straight line.
##
## Two sample streams are interleaved in the output. Each sample carries
## a `source` flag (PHYS or REND) and a monotonic timestamp. Downstream
## analysis (CSV → spreadsheet, or the in-scene HUD) splits them.
##
## Usage:
##   var logger := CarryTelemetryLoggerScript.new()
##   logger.player = player
##   logger.camera_pivot = player.camera_pivot
##   logger.spring_arm = player.spring_arm
##   logger.camera = player.get_camera()
##   logger.marker = carry.get_hold_marker()  # see CarryController.setup
##   logger.carry = carry
##   add_child(logger)
##   ...
##   logger.export_csv("user://carry_audit_2026-04-08_180000.csv")
##
## Buffer is a ring of MAX_SAMPLES entries (bounded memory). Older
## samples are discarded when full.
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access", "unsafe_cast")
class_name CarryTelemetryLogger
extends Node

## Ring buffer capacity. At 60 Hz physics + 144 Hz render = ~204
## samples/sec. 4096 samples = ~20 seconds of history.
const MAX_SAMPLES: int = 4096

enum SampleSource {
	PHYS,
	REND,
}

class MotionSample:
	var time_usec: int
	var source: int  # SampleSource
	var phys_tick: int
	var render_frame: int
	var phys_interp_fraction: float
	# Inputs to the composition
	var player_raw: Vector3
	var player_interp: Vector3
	var camera_pivot_rot: Vector3
	var spring_arm_current_length: float
	var camera_pos_live: Vector3
	var marker_pos_live: Vector3
	# Target the held body is chasing (mirrors carry_controller._process)
	var target_world_pos: Vector3
	# Actual held body state
	var held_body_pos: Vector3
	var held_body_rot: Vector3
	var has_held_body: bool

# --- External wiring (set by the test scene before the logger processes)
var player: CharacterBody3D = null
var camera_pivot: Node3D = null
var spring_arm: SpringArm3D = null
var camera: Camera3D = null
var marker: Marker3D = null
var carry: Node = null  # CarryController — duck-typed to avoid hard import

# --- Ring buffer
var _samples: Array = []  # Array[MotionSample]
var _ring_head: int = 0
var _ring_full: bool = false
var _phys_tick_counter: int = 0
var _render_frame_counter: int = 0

# --- Recording state (scene can toggle to pause sampling)
var recording: bool = true


func _ready() -> void:
	_samples.resize(MAX_SAMPLES)
	set_physics_process(true)
	set_process(true)
	# Make sure we sample AFTER carry_controller has written the body
	# this frame. Godot runs _process in tree order; we put the logger
	# as the LAST child of the scene root so carry writes land first.
	process_priority = 1000
	# Same for physics_process.


## Shutdown safety — when the scene tree tears down, we null out all
## our node references and disable processing so the frame callbacks
## can't try to read stale pointers into freed `CharacterBody3D` /
## `Camera3D` / `RigidBody3D` instances. Matches the `CarryController._exit_tree`
## pattern from `INTERACTION_SYSTEM.md` §17.3 — any node that holds
## cross-subsystem refs MUST null them in `_exit_tree`, not rely on
## normal teardown ordering.
func _exit_tree() -> void:
	set_physics_process(false)
	set_process(false)
	player = null
	camera_pivot = null
	spring_arm = null
	camera = null
	marker = null
	carry = null


func _physics_process(_delta: float) -> void:
	_phys_tick_counter += 1
	if recording:
		_capture(SampleSource.PHYS)


func _process(_delta: float) -> void:
	_render_frame_counter += 1
	if recording:
		_capture(SampleSource.REND)


func _capture(source: int) -> void:
	# Belt-and-braces: every ref is checked with is_instance_valid because
	# the carry + player + camera chain is owned by different subsystems
	# and can be freed asymmetrically (e.g. held body despawned via
	# tap-to-inventory mid-session). Returning early on any stale ref
	# keeps sampling crash-safe.
	if player == null or not is_instance_valid(player):
		return
	if camera == null or not is_instance_valid(camera):
		return
	var s := MotionSample.new()
	s.time_usec = Time.get_ticks_usec()
	s.source = source
	s.phys_tick = _phys_tick_counter
	s.render_frame = _render_frame_counter
	s.phys_interp_fraction = Engine.get_physics_interpolation_fraction()
	s.player_raw = player.global_position
	# Interpolated read — only meaningful in REND, PHYS returns the
	# current tick value anyway.
	s.player_interp = player.get_global_transform_interpolated().origin
	s.camera_pivot_rot = camera_pivot.rotation if (camera_pivot != null and is_instance_valid(camera_pivot)) else Vector3.ZERO
	s.spring_arm_current_length = (
		float(spring_arm.get_hit_length())
		if (spring_arm != null and is_instance_valid(spring_arm))
		else 0.0
	)
	s.camera_pos_live = camera.global_position
	s.marker_pos_live = marker.global_position if (marker != null and is_instance_valid(marker)) else Vector3.ZERO
	s.target_world_pos = _compose_target_same_as_carry()

	var held: RigidBody3D = null
	if carry != null and is_instance_valid(carry) and carry.has_method("get_held_body"):
		held = carry.get_held_body() as RigidBody3D
	if held != null and is_instance_valid(held):
		s.has_held_body = true
		s.held_body_pos = held.global_position
		s.held_body_rot = held.global_rotation
	else:
		s.has_held_body = false
		s.held_body_pos = Vector3.INF
		s.held_body_rot = Vector3.INF

	_samples[_ring_head] = s
	_ring_head += 1
	if _ring_head >= MAX_SAMPLES:
		_ring_head = 0
		_ring_full = true


## Mirrors `CarryController._process` composition — interp player
## position × live camera rig offset. Kept as a FIRST-PARTY recomputation
## so the logger can flag when carry's own target diverges (e.g. bug in
## the composition vs what the logger expects).
func _compose_target_same_as_carry() -> Vector3:
	if player == null or not is_instance_valid(player):
		return Vector3.INF
	if camera_pivot == null or not is_instance_valid(camera_pivot):
		return Vector3.INF
	if spring_arm == null or not is_instance_valid(spring_arm):
		return Vector3.INF
	if camera == null or not is_instance_valid(camera):
		return Vector3.INF
	if marker == null or not is_instance_valid(marker):
		return Vector3.INF
	var player_xf_interp: Transform3D = player.get_global_transform_interpolated()
	var rig_offset: Transform3D = (
		camera_pivot.transform
		* spring_arm.transform
		* camera.transform
		* marker.transform
	)
	return (player_xf_interp * rig_offset).origin


## Iterate samples in chronological order regardless of ring state.
func get_samples_ordered() -> Array:
	var out: Array = []
	if not _ring_full:
		for i in _ring_head:
			out.append(_samples[i])
		return out
	# Ring is full — walk from _ring_head (oldest) through the whole buffer.
	for i in MAX_SAMPLES:
		out.append(_samples[(_ring_head + i) % MAX_SAMPLES])
	return out


func clear_samples() -> void:
	_ring_head = 0
	_ring_full = false
	_phys_tick_counter = 0
	_render_frame_counter = 0


## Compute simple stutter statistics over the LAST `window_count` samples
## of the requested source. Returns a dictionary:
##   max_dpos_mm:  peak per-frame held-body displacement (mm)
##   rms_dpos_mm:  RMS of per-frame held-body displacements (mm)
##   max_target_dpos_mm: same for target_world_pos
##   rms_target_dpos_mm: same
##   n: number of deltas summed
## Returns NaN-valued dict if insufficient samples.
func compute_jitter_stats(source: int, window_count: int) -> Dictionary:
	var samples := get_samples_ordered()
	# Filter to the requested source.
	var filtered: Array = []
	for s in samples:
		if s != null and s.source == source:
			filtered.append(s)
	var n: int = filtered.size()
	if n < 2:
		return {
			"n": 0,
			"max_dpos_mm": NAN,
			"rms_dpos_mm": NAN,
			"max_target_dpos_mm": NAN,
			"rms_target_dpos_mm": NAN,
		}
	var start: int = maxi(0, n - window_count - 1)
	var max_body: float = 0.0
	var sum_sq_body: float = 0.0
	var max_target: float = 0.0
	var sum_sq_target: float = 0.0
	var count: int = 0
	var prev_body: Vector3 = (filtered[start] as MotionSample).held_body_pos
	var prev_target: Vector3 = (filtered[start] as MotionSample).target_world_pos
	var prev_has_held: bool = (filtered[start] as MotionSample).has_held_body
	for i in range(start + 1, n):
		var s := filtered[i] as MotionSample
		if s.has_held_body and prev_has_held and prev_body.is_finite() and s.held_body_pos.is_finite():
			var d_body: float = s.held_body_pos.distance_to(prev_body) * 1000.0
			max_body = maxf(max_body, d_body)
			sum_sq_body += d_body * d_body
			count += 1
		if s.target_world_pos.is_finite() and prev_target.is_finite():
			var d_target: float = s.target_world_pos.distance_to(prev_target) * 1000.0
			max_target = maxf(max_target, d_target)
			sum_sq_target += d_target * d_target
		prev_body = s.held_body_pos
		prev_target = s.target_world_pos
		prev_has_held = s.has_held_body
	var rms_body: float = sqrt(sum_sq_body / float(maxi(count, 1)))
	var rms_target: float = sqrt(sum_sq_target / float(maxi(count, 1)))
	return {
		"n": count,
		"max_dpos_mm": max_body,
		"rms_dpos_mm": rms_body,
		"max_target_dpos_mm": max_target,
		"rms_target_dpos_mm": rms_target,
	}


## Export all buffered samples to a CSV file at `path`. Path can use
## `user://` prefix. Returns OK on success, FileAccess error otherwise.
func export_csv(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_line(
		"time_usec,source,phys_tick,render_frame,phys_interp_fraction,"
		+ "player_raw_x,player_raw_y,player_raw_z,"
		+ "player_interp_x,player_interp_y,player_interp_z,"
		+ "camera_pivot_rx,camera_pivot_ry,camera_pivot_rz,"
		+ "spring_arm_len,"
		+ "camera_live_x,camera_live_y,camera_live_z,"
		+ "marker_live_x,marker_live_y,marker_live_z,"
		+ "target_x,target_y,target_z,"
		+ "held_pos_x,held_pos_y,held_pos_z,"
		+ "held_rot_x,held_rot_y,held_rot_z,"
		+ "has_held"
	)
	var samples := get_samples_ordered()
	for s_var in samples:
		if s_var == null:
			continue
		var s: MotionSample = s_var
		var source_str: String = "PHYS" if s.source == SampleSource.PHYS else "REND"
		var held_str: String = "1" if s.has_held_body else "0"
		file.store_line(
			"%d,%s,%d,%d,%.8f,"
			% [s.time_usec, source_str, s.phys_tick, s.render_frame, s.phys_interp_fraction]
			+ "%.8f,%.8f,%.8f," % [s.player_raw.x, s.player_raw.y, s.player_raw.z]
			+ "%.8f,%.8f,%.8f," % [s.player_interp.x, s.player_interp.y, s.player_interp.z]
			+ "%.8f,%.8f,%.8f," % [s.camera_pivot_rot.x, s.camera_pivot_rot.y, s.camera_pivot_rot.z]
			+ "%.6f," % s.spring_arm_current_length
			+ "%.8f,%.8f,%.8f," % [s.camera_pos_live.x, s.camera_pos_live.y, s.camera_pos_live.z]
			+ "%.8f,%.8f,%.8f," % [s.marker_pos_live.x, s.marker_pos_live.y, s.marker_pos_live.z]
			+ "%.8f,%.8f,%.8f," % [s.target_world_pos.x, s.target_world_pos.y, s.target_world_pos.z]
			+ "%.8f,%.8f,%.8f," % [s.held_body_pos.x, s.held_body_pos.y, s.held_body_pos.z]
			+ "%.8f,%.8f,%.8f," % [s.held_body_rot.x, s.held_body_rot.y, s.held_body_rot.z]
			+ held_str
		)
	file.close()
	return OK


## Convenience: total sample count currently in the ring.
func sample_count() -> int:
	return MAX_SAMPLES if _ring_full else _ring_head
