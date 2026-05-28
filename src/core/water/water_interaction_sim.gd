## WaterInteractionSim - near-field visual ripple atlas for water contacts.
## Owned by OceanManager. Gameplay emits compact impulses; shaders consume the
## resulting player-centered Texture2DRD in world XZ.
class_name WaterInteractionSim
extends Node

const SHADER_PATH := "res://src/core/water/shaders/compute/"
const FIXED_STEP_SECONDS := 1.0 / 60.0
const DEFAULT_WORLD_SIZE_M := 128.0
const LOW_WORLD_SIZE_M := 80.0
const HIGH_WORLD_SIZE_M := 160.0
const LOCAL_SIZE := 16
const SPLAT_LOCAL_SIZE := 8
const SPLAT_COMMAND_STRIDE_BYTES := 64
const SETTLE_STEPS_AFTER_IMPULSE := 180
const FLOW_SETTLE_STEPS_AFTER_OBSTACLE := 240
const WATER_HEIGHT_GATE_TOLERANCE_M := 0.35
const TIMESTAMP_BEGIN := "godotwind_water_ripple_begin"
const TIMESTAMP_END := "godotwind_water_ripple_end"

enum Quality { LOW, HIGH, FULL }

@export var enabled: bool = true
@export var quality: Quality = Quality.HIGH:
	set(value):
		quality = value
		_apply_quality_defaults()
@export var resolution: int = 512
@export var world_size_m: float = DEFAULT_WORLD_SIZE_M
@export var max_impulses_per_step: int = 128
@export var height_strength_m: float = 0.08

var _rd: RenderingDevice = null
var _context: RenderingContext = null
var _texture_a: RID = RID()
var _texture_b: RID = RID()
var _flow_texture_a: RID = RID()
var _flow_texture_b: RID = RID()
var _fallback_water_body_atlas: RID = RID()
var _splat_command_buffer: RID = RID()
var _flow_command_buffer: RID = RID()
var _sampler: RID = RID()
var _scroll_shader: RID = RID()
var _splat_shader: RID = RID()
var _simulate_shader: RID = RID()
var _flow_splat_shader: RID = RID()
var _flow_simulate_shader: RID = RID()
var _scroll_pipeline: RID = RID()
var _splat_pipeline: RID = RID()
var _simulate_pipeline: RID = RID()
var _flow_splat_pipeline: RID = RID()
var _flow_simulate_pipeline: RID = RID()
var _scroll_sets: Array[RID] = []
var _splat_sets: Array[RID] = []
var _simulate_sets: Array[RID] = []
var _flow_scroll_sets: Array[RID] = []
var _flow_splat_sets: Array[RID] = []
var _flow_simulate_sets: Array[RID] = []
var _texture_wrapper := Texture2DRD.new()
var _flow_texture_wrapper := Texture2DRD.new()

var _front_index: int = 0
var _center_xz: Vector2 = Vector2.ZERO
var _bounds_min_xz: Vector2 = Vector2.ZERO
var _last_bounds_min_xz: Vector2 = Vector2.ZERO
var _pending_impulses: Array[Dictionary] = []
var _pending_flow_obstacles: Array[Dictionary] = []
var _water_body_atlas_rid: RID = RID()
var _water_body_atlas_bounds: Vector4 = Vector4.ZERO
var _water_body_atlas_available: bool = false
var _accumulator: float = 0.0
var _settle_steps_remaining: int = 0
var _flow_settle_steps_remaining: int = 0
var _dispatch_count: int = 0
var _last_step_impulse_count: int = 0
var _last_step_flow_obstacle_count: int = 0
var _last_culled_impulse_count: int = 0
var _last_culled_flow_obstacle_count: int = 0
var _culled_impulses_total: int = 0
var _culled_flow_obstacles_total: int = 0
var _dropped_impulses_total: int = 0
var _dropped_flow_obstacles_total: int = 0
var _last_cpu_prepare_us: int = 0
var _last_gpu_ms: float = -1.0
var _last_active_dispatch: bool = false
var _last_atlas_scroll_px: Vector2i = Vector2i.ZERO
var _last_splat_dispatch_count: int = 0
var _last_splat_max_rect: Vector2i = Vector2i.ZERO
var _last_flow_splat_dispatch_count: int = 0
var _last_flow_splat_max_rect: Vector2i = Vector2i.ZERO
var _last_timestamp_frame: int = -1


func _ready() -> void:
	_apply_quality_defaults()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		shutdown()


func configure(new_quality: int = Quality.HIGH, atlas_resolution: int = 0, max_impulses: int = 0) -> void:
	quality = new_quality as Quality
	if atlas_resolution > 0:
		resolution = atlas_resolution
	if max_impulses > 0:
		max_impulses_per_step = max_impulses
	_recreate_gpu()


func set_center_world(world_pos: Vector3) -> void:
	var texel_size := _texel_size()
	var target := Vector2(world_pos.x, world_pos.z)
	_center_xz = Vector2(
		roundf(target.x / texel_size) * texel_size,
		roundf(target.y / texel_size) * texel_size
	)
	_last_bounds_min_xz = _bounds_min_xz
	_bounds_min_xz = _center_xz - Vector2.ONE * world_size_m * 0.5


func configure_water_body_mask(atlas_rid: RID, bounds: Vector4, available: bool) -> void:
	var next_rid := atlas_rid if available and atlas_rid.is_valid() else RID()
	if next_rid == _water_body_atlas_rid and bounds == _water_body_atlas_bounds and available == _water_body_atlas_available:
		return
	_water_body_atlas_rid = next_rid
	_water_body_atlas_bounds = bounds
	_water_body_atlas_available = available and next_rid.is_valid() and bounds.z > 0.0 and bounds.w > 0.0
	if _rd != null and _splat_shader.is_valid():
		_recreate_splat_sets()
	if _rd != null and _flow_splat_shader.is_valid():
		_recreate_flow_splat_sets()


func queue_impulse(
	world_pos: Vector3,
	radius_m: float,
	strength: float,
	water_height: float = NAN,
	body_gate: float = 1.0,
	requires_water_body_atlas: bool = false,
	wake_direction: Vector2 = Vector2.ZERO,
	wake_length_m: float = 0.0
) -> void:
	if not enabled:
		return
	var radius := clampf(radius_m, 0.04, world_size_m * 0.20)
	var trail := Vector4.ZERO
	if wake_direction.length_squared() > 0.0001 and wake_length_m > 0.0:
		var wake_dir := wake_direction.normalized()
		trail = Vector4(wake_dir.x, wake_dir.y, maxf(wake_length_m, 0.0), 1.0)
	var impulse := {
		"shape": Vector4(world_pos.x, world_pos.z, radius, strength),
		"water": Vector4(
			water_height if not is_nan(water_height) else 0.0,
			clampf(body_gate, 0.0, 1.0),
			1.0 if requires_water_body_atlas else 0.0,
			WATER_HEIGHT_GATE_TOLERANCE_M
		),
		"trail": trail,
	}
	_pending_impulses.append(impulse)
	if _pending_impulses.size() > max_impulses_per_step:
		_pending_impulses.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return absf((a["shape"] as Vector4).w) > absf((b["shape"] as Vector4).w)
		)
		var dropped := _pending_impulses.size() - max_impulses_per_step
		_pending_impulses.resize(max_impulses_per_step)
		_dropped_impulses_total += dropped


func queue_flow_obstacle(
	world_pos: Vector3,
	radius_m: float,
	base_velocity: Vector3,
	block_strength: float,
	wake_strength: float,
	water_height: float = NAN,
	body_gate: float = 1.0,
	requires_water_body_atlas: bool = false
) -> void:
	if not enabled:
		return
	var base_xz := Vector2(base_velocity.x, base_velocity.z)
	if base_xz.length_squared() <= 0.0001:
		return
	var radius := clampf(radius_m, 0.08, world_size_m * 0.20)
	var obstacle := {
		"shape": Vector4(world_pos.x, world_pos.z, radius, clampf(block_strength, 0.0, 2.0)),
		"water": Vector4(
			water_height if not is_nan(water_height) else 0.0,
			clampf(body_gate, 0.0, 1.0),
			1.0 if requires_water_body_atlas else 0.0,
			WATER_HEIGHT_GATE_TOLERANCE_M
		),
		"flow": Vector4(base_xz.x, base_xz.y, clampf(wake_strength, 0.0, 2.0), 1.0),
	}
	_pending_flow_obstacles.append(obstacle)
	if _pending_flow_obstacles.size() > max_impulses_per_step:
		_pending_flow_obstacles.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return absf((a["shape"] as Vector4).w) > absf((b["shape"] as Vector4).w)
		)
		var dropped := _pending_flow_obstacles.size() - max_impulses_per_step
		_pending_flow_obstacles.resize(max_impulses_per_step)
		_dropped_flow_obstacles_total += dropped


func update_sim(delta: float, center_world: Vector3) -> void:
	_refresh_gpu_timing()
	if not enabled:
		_last_active_dispatch = false
		return
	set_center_world(center_world)
	if delta <= 0.0 \
			and _pending_impulses.is_empty() \
			and _pending_flow_obstacles.is_empty() \
			and _settle_steps_remaining <= 0 \
			and _flow_settle_steps_remaining <= 0:
		_last_active_dispatch = false
		return
	if _rd == null:
		_init_gpu()
	if _rd == null:
		_last_active_dispatch = false
		return

	_last_active_dispatch = false
	_accumulator = minf(_accumulator + delta, FIXED_STEP_SECONDS * 4.0)
	var steps := 0
	while _accumulator >= FIXED_STEP_SECONDS and steps < 4:
		_step_gpu()
		_accumulator -= FIXED_STEP_SECONDS
		steps += 1


func get_texture() -> Texture2D:
	return _texture_wrapper


func get_texture_rd() -> RID:
	return _current_texture()


func get_flow_texture() -> Texture2D:
	return _flow_texture_wrapper


func get_flow_texture_rd() -> RID:
	return _current_flow_texture()


func get_bounds() -> Vector4:
	return Vector4(_bounds_min_xz.x, _bounds_min_xz.y, world_size_m, _texel_size())


func get_stats() -> Dictionary:
	return {
		"enabled": enabled and _rd != null,
		"atlas_size": resolution,
		"world_size_m": world_size_m,
		"bounds": get_bounds(),
		"dispatch_count": _dispatch_count,
		"last_impulse_count": _last_step_impulse_count,
		"last_flow_obstacle_count": _last_step_flow_obstacle_count,
		"last_culled_impulse_count": _last_culled_impulse_count,
		"last_culled_flow_obstacle_count": _last_culled_flow_obstacle_count,
		"pending_impulse_count": _pending_impulses.size(),
		"pending_flow_obstacle_count": _pending_flow_obstacles.size(),
		"max_impulses": max_impulses_per_step,
		"culled_impulses_total": _culled_impulses_total,
		"culled_flow_obstacles_total": _culled_flow_obstacles_total,
		"dropped_impulses_total": _dropped_impulses_total,
		"dropped_flow_obstacles_total": _dropped_flow_obstacles_total,
		"gpu_ms": _last_gpu_ms,
		"cpu_upload_us": _last_cpu_prepare_us,
		"cpu_prepare_us": _last_cpu_prepare_us,
		"active_dispatch": _last_active_dispatch,
		"atlas_scroll_px": _last_atlas_scroll_px,
		"splat_dispatch_count": _last_splat_dispatch_count,
		"flow_splat_dispatch_count": _last_flow_splat_dispatch_count,
	}


func get_pending_impulse_strengths_for_tests() -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for impulse: Dictionary in _pending_impulses:
		values.append((impulse["shape"] as Vector4).w)
	return values


func shutdown() -> void:
	if _context != null:
		_context.shutdown()
		_context.free()
	_context = null
	_rd = null
	_texture_a = RID()
	_texture_b = RID()
	_flow_texture_a = RID()
	_flow_texture_b = RID()
	_fallback_water_body_atlas = RID()
	_splat_command_buffer = RID()
	_flow_command_buffer = RID()
	_sampler = RID()
	_scroll_shader = RID()
	_splat_shader = RID()
	_simulate_shader = RID()
	_flow_splat_shader = RID()
	_flow_simulate_shader = RID()
	_scroll_pipeline = RID()
	_splat_pipeline = RID()
	_simulate_pipeline = RID()
	_flow_splat_pipeline = RID()
	_flow_simulate_pipeline = RID()
	_scroll_sets.clear()
	_splat_sets.clear()
	_simulate_sets.clear()
	_flow_scroll_sets.clear()
	_flow_splat_sets.clear()
	_flow_simulate_sets.clear()
	_texture_wrapper.texture_rd_rid = RID()
	_flow_texture_wrapper.texture_rd_rid = RID()


func _apply_quality_defaults() -> void:
	match quality:
		Quality.LOW:
			resolution = 256
			world_size_m = LOW_WORLD_SIZE_M
			max_impulses_per_step = 32
		Quality.FULL:
			resolution = 1024
			world_size_m = HIGH_WORLD_SIZE_M
			max_impulses_per_step = 128
		_:
			resolution = 512
			world_size_m = DEFAULT_WORLD_SIZE_M
			max_impulses_per_step = 128


func _recreate_gpu() -> void:
	shutdown()
	if is_inside_tree() and enabled:
		_init_gpu()


func _init_gpu() -> void:
	_context = RenderingContext.create(RenderingServer.get_rendering_device())
	_rd = _context.device
	if _rd == null:
		Log.warn("water", "WaterInteractionSim: RenderingDevice unavailable; ripples disabled")
		return

	_texture_a = _create_ripple_texture()
	_texture_b = _create_ripple_texture()
	_flow_texture_a = _create_ripple_texture()
	_flow_texture_b = _create_ripple_texture()
	_fallback_water_body_atlas = _create_ripple_texture(1)
	var splat_command_bytes := PackedByteArray()
	splat_command_bytes.resize(maxi(max_impulses_per_step, 1) * SPLAT_COMMAND_STRIDE_BYTES)
	_splat_command_buffer = _context.deletion_queue.push(_rd.storage_buffer_create(splat_command_bytes.size(), splat_command_bytes))
	var flow_command_bytes := PackedByteArray()
	flow_command_bytes.resize(maxi(max_impulses_per_step, 1) * SPLAT_COMMAND_STRIDE_BYTES)
	_flow_command_buffer = _context.deletion_queue.push(_rd.storage_buffer_create(flow_command_bytes.size(), flow_command_bytes))
	_sampler = _context.deletion_queue.push(_rd.sampler_create(_create_sampler_state()))

	_scroll_shader = _context.load_shader(SHADER_PATH + "water_ripple_scroll.glsl")
	_splat_shader = _context.load_shader(SHADER_PATH + "water_ripple_splat.glsl")
	_simulate_shader = _context.load_shader(SHADER_PATH + "water_ripple_simulate.glsl")
	_flow_splat_shader = _context.load_shader(SHADER_PATH + "water_flow_splat.glsl")
	_flow_simulate_shader = _context.load_shader(SHADER_PATH + "water_flow_simulate.glsl")
	_scroll_pipeline = _context.deletion_queue.push(_rd.compute_pipeline_create(_scroll_shader))
	_splat_pipeline = _context.deletion_queue.push(_rd.compute_pipeline_create(_splat_shader))
	_simulate_pipeline = _context.deletion_queue.push(_rd.compute_pipeline_create(_simulate_shader))
	_flow_splat_pipeline = _context.deletion_queue.push(_rd.compute_pipeline_create(_flow_splat_shader))
	_flow_simulate_pipeline = _context.deletion_queue.push(_rd.compute_pipeline_create(_flow_simulate_shader))

	_scroll_sets = [
		_create_image_pair_set(_scroll_shader, _texture_b, _texture_a),
		_create_image_pair_set(_scroll_shader, _texture_a, _texture_b),
	]
	_flow_scroll_sets = [
		_create_image_pair_set(_scroll_shader, _flow_texture_b, _flow_texture_a),
		_create_image_pair_set(_scroll_shader, _flow_texture_a, _flow_texture_b),
	]
	_recreate_splat_sets()
	_recreate_flow_splat_sets()
	_simulate_sets = [
		_create_image_pair_set(_simulate_shader, _texture_a, _texture_b),
		_create_image_pair_set(_simulate_shader, _texture_b, _texture_a),
	]
	_flow_simulate_sets = [
		_create_image_pair_set(_flow_simulate_shader, _flow_texture_a, _flow_texture_b),
		_create_image_pair_set(_flow_simulate_shader, _flow_texture_b, _flow_texture_a),
	]

	_front_index = 0
	_texture_wrapper.texture_rd_rid = _current_texture()
	_flow_texture_wrapper.texture_rd_rid = _current_flow_texture()
	Log.info("water", "WaterInteractionSim: Initialized %dx%d atlas, %.0fm world span" % [
		resolution,
		resolution,
		world_size_m
	])


func _create_ripple_texture(size_override: int = 0) -> RID:
	var texture_size := size_override if size_override > 0 else resolution
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = texture_size
	fmt.height = texture_size
	fmt.depth = 1
	fmt.array_layers = 1
	fmt.mipmaps = 1
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	var zero := PackedByteArray()
	zero.resize(texture_size * texture_size * 8)
	zero.fill(0)
	return _context.deletion_queue.push(_rd.texture_create(fmt, RDTextureView.new(), [zero]))


func _create_sampler_state() -> RDSamplerState:
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	return sampler_state


func _recreate_splat_sets() -> void:
	if _rd == null or not _splat_shader.is_valid():
		return
	for set_rid: RID in _splat_sets:
		if set_rid.is_valid():
			_context.deletion_queue.free_rid(_rd, set_rid)
	_splat_sets = [
		_create_splat_set(_texture_a),
		_create_splat_set(_texture_b),
	]


func _recreate_flow_splat_sets() -> void:
	if _rd == null or not _flow_splat_shader.is_valid():
		return
	for set_rid: RID in _flow_splat_sets:
		if set_rid.is_valid():
			_context.deletion_queue.free_rid(_rd, set_rid)
	_flow_splat_sets = [
		_create_flow_splat_set(_flow_texture_a),
		_create_flow_splat_set(_flow_texture_b),
	]


func _create_image_pair_set(shader: RID, output_texture: RID, input_texture: RID) -> RID:
	var uniforms: Array[RDUniform] = []
	var out_uniform := RDUniform.new()
	out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	out_uniform.binding = 0
	out_uniform.add_id(output_texture)
	uniforms.append(out_uniform)

	var in_uniform := RDUniform.new()
	in_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	in_uniform.binding = 1
	in_uniform.add_id(input_texture)
	uniforms.append(in_uniform)

	return _context.deletion_queue.push(_rd.uniform_set_create(uniforms, shader, 0))


func _create_splat_set(texture: RID) -> RID:
	var uniforms: Array[RDUniform] = []
	var state_uniform := RDUniform.new()
	state_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	state_uniform.binding = 0
	state_uniform.add_id(texture)
	uniforms.append(state_uniform)

	var atlas_uniform := RDUniform.new()
	atlas_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	atlas_uniform.binding = 1
	atlas_uniform.add_id(_sampler)
	atlas_uniform.add_id(_active_water_body_atlas_texture())
	uniforms.append(atlas_uniform)

	var command_uniform := RDUniform.new()
	command_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	command_uniform.binding = 2
	command_uniform.add_id(_splat_command_buffer)
	uniforms.append(command_uniform)

	return _context.deletion_queue.push(_rd.uniform_set_create(uniforms, _splat_shader, 0))


func _create_flow_splat_set(texture: RID) -> RID:
	var uniforms: Array[RDUniform] = []
	var state_uniform := RDUniform.new()
	state_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	state_uniform.binding = 0
	state_uniform.add_id(texture)
	uniforms.append(state_uniform)

	var atlas_uniform := RDUniform.new()
	atlas_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	atlas_uniform.binding = 1
	atlas_uniform.add_id(_sampler)
	atlas_uniform.add_id(_active_water_body_atlas_texture())
	uniforms.append(atlas_uniform)

	var command_uniform := RDUniform.new()
	command_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	command_uniform.binding = 2
	command_uniform.add_id(_flow_command_buffer)
	uniforms.append(command_uniform)

	return _context.deletion_queue.push(_rd.uniform_set_create(uniforms, _flow_splat_shader, 0))


func _step_gpu() -> void:
	var prepare_start_us := Time.get_ticks_usec()
	var old_min := _last_bounds_min_xz
	var new_min := _bounds_min_xz
	var texel_size := _texel_size()
	var scroll := Vector2i(
		roundi((new_min.x - old_min.x) / texel_size),
		roundi((new_min.y - old_min.y) / texel_size)
	)
	_last_atlas_scroll_px = scroll

	_cull_pending_impulses_to_atlas(new_min)
	_cull_pending_flow_obstacles_to_atlas(new_min)
	_pending_impulses.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return absf((a["shape"] as Vector4).w) > absf((b["shape"] as Vector4).w)
	)
	_pending_flow_obstacles.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return absf((a["shape"] as Vector4).w) > absf((b["shape"] as Vector4).w)
	)
	if _pending_impulses.size() > max_impulses_per_step:
		var dropped := _pending_impulses.size() - max_impulses_per_step
		_pending_impulses.resize(max_impulses_per_step)
		_dropped_impulses_total += dropped
	if _pending_flow_obstacles.size() > max_impulses_per_step:
		var dropped := _pending_flow_obstacles.size() - max_impulses_per_step
		_pending_flow_obstacles.resize(max_impulses_per_step)
		_dropped_flow_obstacles_total += dropped

	var impulse_count := _pending_impulses.size()
	var flow_obstacle_count := _pending_flow_obstacles.size()
	_last_step_impulse_count = impulse_count
	_last_step_flow_obstacle_count = flow_obstacle_count
	_last_splat_dispatch_count = 0
	_last_splat_max_rect = Vector2i.ZERO
	_last_flow_splat_dispatch_count = 0
	_last_flow_splat_max_rect = Vector2i.ZERO
	if impulse_count > 0:
		_settle_steps_remaining = SETTLE_STEPS_AFTER_IMPULSE
	if flow_obstacle_count > 0:
		_flow_settle_steps_remaining = FLOW_SETTLE_STEPS_AFTER_OBSTACLE
	elif scroll != Vector2i.ZERO and _settle_steps_remaining > 0:
		_settle_steps_remaining = max(_settle_steps_remaining, 2)
	if flow_obstacle_count == 0 and scroll != Vector2i.ZERO and _flow_settle_steps_remaining > 0:
		_flow_settle_steps_remaining = max(_flow_settle_steps_remaining, 2)
	elif flow_obstacle_count == 0 and _flow_settle_steps_remaining > 0:
		_flow_settle_steps_remaining -= 1
	if impulse_count == 0 and scroll == Vector2i.ZERO and _settle_steps_remaining > 0:
		_settle_steps_remaining -= 1
	if impulse_count == 0 and flow_obstacle_count == 0 and scroll == Vector2i.ZERO and _settle_steps_remaining <= 0 and _flow_settle_steps_remaining <= 0:
		_last_active_dispatch = false
		_last_cpu_prepare_us = 0
		_last_bounds_min_xz = _bounds_min_xz
		return

	var groups := int(ceilf(float(resolution) / float(LOCAL_SIZE)))
	var scroll_pc := RenderingContext.create_push_constant([
		resolution, scroll.x, scroll.y, 0,
	])
	var simulate_pc := RenderingContext.create_push_constant([
		resolution, 0, 0, 0,
		0.30, 0.985, 0.996, texel_size,
	])
	var flow_simulate_pc := RenderingContext.create_push_constant([
		resolution, 0, 0, 0,
		0.18, 0.90, 0.94, texel_size,
	])

	var source_index := _front_index
	var target_index := 1 - source_index
	var use_scroll_or_splat := scroll != Vector2i.ZERO or impulse_count > 0 or flow_obstacle_count > 0
	var splat_commands: Array[Dictionary] = []
	if impulse_count > 0:
		splat_commands = _build_splat_commands(new_min, impulse_count)
		_upload_splat_commands(splat_commands)
	var flow_commands: Array[Dictionary] = []
	if flow_obstacle_count > 0:
		flow_commands = _build_flow_commands(new_min, flow_obstacle_count)
		_upload_flow_commands(flow_commands)
	var splat_pc := RenderingContext.create_push_constant([
		new_min.x, new_min.y, world_size_m, texel_size,
		_water_body_atlas_bounds.x, _water_body_atlas_bounds.y, _water_body_atlas_bounds.z, _water_body_atlas_bounds.w,
		1.0 if _water_body_atlas_available else 0.0, WATER_HEIGHT_GATE_TOLERANCE_M, height_strength_m, float(resolution),
		splat_commands.size(), _last_splat_max_rect.x, _last_splat_max_rect.y, 0,
	])
	var flow_splat_pc := RenderingContext.create_push_constant([
		new_min.x, new_min.y, world_size_m, texel_size,
		_water_body_atlas_bounds.x, _water_body_atlas_bounds.y, _water_body_atlas_bounds.z, _water_body_atlas_bounds.w,
		1.0 if _water_body_atlas_available else 0.0, WATER_HEIGHT_GATE_TOLERANCE_M, 1.0, float(resolution),
		flow_commands.size(), _last_flow_splat_max_rect.x, _last_flow_splat_max_rect.y, 0,
	])
	_last_cpu_prepare_us = Time.get_ticks_usec() - prepare_start_us

	_rd.capture_timestamp(TIMESTAMP_BEGIN)
	var cl := _rd.compute_list_begin()

	if use_scroll_or_splat:
		_rd.compute_list_bind_compute_pipeline(cl, _scroll_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _scroll_sets[source_index], 0)
		_rd.compute_list_set_push_constant(cl, scroll_pc, scroll_pc.size())
		_rd.compute_list_dispatch(cl, groups, groups, 1)
		_rd.compute_list_add_barrier(cl)

		_rd.compute_list_bind_compute_pipeline(cl, _scroll_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _flow_scroll_sets[source_index], 0)
		_rd.compute_list_set_push_constant(cl, scroll_pc, scroll_pc.size())
		_rd.compute_list_dispatch(cl, groups, groups, 1)
		_rd.compute_list_add_barrier(cl)

		if not splat_commands.is_empty():
			_rd.compute_list_bind_compute_pipeline(cl, _splat_pipeline)
			_rd.compute_list_bind_uniform_set(cl, _splat_sets[target_index], 0)
			_rd.compute_list_set_push_constant(cl, splat_pc, splat_pc.size())
			_rd.compute_list_dispatch(
				cl,
				ceili(float(_last_splat_max_rect.x) / float(SPLAT_LOCAL_SIZE)),
				ceili(float(_last_splat_max_rect.y) / float(SPLAT_LOCAL_SIZE)),
				splat_commands.size()
			)
			_rd.compute_list_add_barrier(cl)
			_last_splat_dispatch_count = 1

		if not flow_commands.is_empty():
			_rd.compute_list_bind_compute_pipeline(cl, _flow_splat_pipeline)
			_rd.compute_list_bind_uniform_set(cl, _flow_splat_sets[target_index], 0)
			_rd.compute_list_set_push_constant(cl, flow_splat_pc, flow_splat_pc.size())
			_rd.compute_list_dispatch(
				cl,
				ceili(float(_last_flow_splat_max_rect.x) / float(SPLAT_LOCAL_SIZE)),
				ceili(float(_last_flow_splat_max_rect.y) / float(SPLAT_LOCAL_SIZE)),
				flow_commands.size()
			)
			_rd.compute_list_add_barrier(cl)
			_last_flow_splat_dispatch_count = 1

	if use_scroll_or_splat:
		_rd.compute_list_bind_compute_pipeline(cl, _simulate_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _simulate_sets[source_index], 0)
	else:
		_rd.compute_list_bind_compute_pipeline(cl, _simulate_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _simulate_sets[target_index], 0)
	_rd.compute_list_set_push_constant(cl, simulate_pc, simulate_pc.size())
	_rd.compute_list_dispatch(cl, groups, groups, 1)
	_rd.compute_list_add_barrier(cl)

	_rd.compute_list_bind_compute_pipeline(cl, _flow_simulate_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _flow_simulate_sets[source_index if use_scroll_or_splat else target_index], 0)
	_rd.compute_list_set_push_constant(cl, flow_simulate_pc, flow_simulate_pc.size())
	_rd.compute_list_dispatch(cl, groups, groups, 1)
	_rd.compute_list_end()
	_rd.capture_timestamp(TIMESTAMP_END)

	_front_index = source_index if use_scroll_or_splat else target_index
	_texture_wrapper.texture_rd_rid = _current_texture()
	_flow_texture_wrapper.texture_rd_rid = _current_flow_texture()
	_pending_impulses.clear()
	_pending_flow_obstacles.clear()
	_last_bounds_min_xz = _bounds_min_xz
	_dispatch_count += 1
	_last_active_dispatch = true


func _build_splat_commands(bounds_min: Vector2, impulse_count: int) -> Array[Dictionary]:
	var commands: Array[Dictionary] = []
	_last_splat_max_rect = Vector2i.ZERO
	var count := mini(impulse_count, _pending_impulses.size())
	for i in range(count):
		var impulse := _pending_impulses[i] as Dictionary
		var shape := impulse["shape"] as Vector4
		var water := impulse["water"] as Vector4
		var trail := impulse.get("trail", Vector4.ZERO) as Vector4
		var rect := _impulse_texel_rect(bounds_min, shape, trail)
		if rect.size.x <= 0 or rect.size.y <= 0:
			continue
		_last_splat_max_rect.x = maxi(_last_splat_max_rect.x, rect.size.x)
		_last_splat_max_rect.y = maxi(_last_splat_max_rect.y, rect.size.y)
		commands.append({
			"shape": shape,
			"water": water,
			"rect": rect,
			"trail": trail,
		})
	return commands


func _build_flow_commands(bounds_min: Vector2, obstacle_count: int) -> Array[Dictionary]:
	var commands: Array[Dictionary] = []
	_last_flow_splat_max_rect = Vector2i.ZERO
	var count := mini(obstacle_count, _pending_flow_obstacles.size())
	for i in range(count):
		var obstacle := _pending_flow_obstacles[i] as Dictionary
		var shape := obstacle["shape"] as Vector4
		var water := obstacle["water"] as Vector4
		var flow := obstacle["flow"] as Vector4
		var rect := _flow_obstacle_texel_rect(bounds_min, shape, flow)
		if rect.size.x <= 0 or rect.size.y <= 0:
			continue
		_last_flow_splat_max_rect.x = maxi(_last_flow_splat_max_rect.x, rect.size.x)
		_last_flow_splat_max_rect.y = maxi(_last_flow_splat_max_rect.y, rect.size.y)
		commands.append({
			"shape": shape,
			"water": water,
			"rect": rect,
			"flow": flow,
		})
	return commands


func _upload_splat_commands(commands: Array[Dictionary]) -> void:
	if commands.is_empty() or not _splat_command_buffer.is_valid():
		return
	var bytes := PackedByteArray()
	bytes.resize(commands.size() * SPLAT_COMMAND_STRIDE_BYTES)
	for i in range(commands.size()):
		var command := commands[i]
		var shape := command["shape"] as Vector4
		var water := command["water"] as Vector4
		var rect := command["rect"] as Rect2i
		var trail := command["trail"] as Vector4
		var offset := i * SPLAT_COMMAND_STRIDE_BYTES
		bytes.encode_float(offset + 0, shape.x)
		bytes.encode_float(offset + 4, shape.y)
		bytes.encode_float(offset + 8, shape.z)
		bytes.encode_float(offset + 12, shape.w)
		bytes.encode_float(offset + 16, water.x)
		bytes.encode_float(offset + 20, water.y)
		bytes.encode_float(offset + 24, water.z)
		bytes.encode_float(offset + 28, water.w)
		bytes.encode_s32(offset + 32, rect.position.x)
		bytes.encode_s32(offset + 36, rect.position.y)
		bytes.encode_s32(offset + 40, rect.size.x)
		bytes.encode_s32(offset + 44, rect.size.y)
		bytes.encode_float(offset + 48, trail.x)
		bytes.encode_float(offset + 52, trail.y)
		bytes.encode_float(offset + 56, trail.z)
		bytes.encode_float(offset + 60, trail.w)
	_rd.buffer_update(_splat_command_buffer, 0, bytes.size(), bytes)


func _upload_flow_commands(commands: Array[Dictionary]) -> void:
	if commands.is_empty() or not _flow_command_buffer.is_valid():
		return
	var bytes := PackedByteArray()
	bytes.resize(commands.size() * SPLAT_COMMAND_STRIDE_BYTES)
	for i in range(commands.size()):
		var command := commands[i]
		var shape := command["shape"] as Vector4
		var water := command["water"] as Vector4
		var rect := command["rect"] as Rect2i
		var flow := command["flow"] as Vector4
		var offset := i * SPLAT_COMMAND_STRIDE_BYTES
		bytes.encode_float(offset + 0, shape.x)
		bytes.encode_float(offset + 4, shape.y)
		bytes.encode_float(offset + 8, shape.z)
		bytes.encode_float(offset + 12, shape.w)
		bytes.encode_float(offset + 16, water.x)
		bytes.encode_float(offset + 20, water.y)
		bytes.encode_float(offset + 24, water.z)
		bytes.encode_float(offset + 28, water.w)
		bytes.encode_s32(offset + 32, rect.position.x)
		bytes.encode_s32(offset + 36, rect.position.y)
		bytes.encode_s32(offset + 40, rect.size.x)
		bytes.encode_s32(offset + 44, rect.size.y)
		bytes.encode_float(offset + 48, flow.x)
		bytes.encode_float(offset + 52, flow.y)
		bytes.encode_float(offset + 56, flow.z)
		bytes.encode_float(offset + 60, flow.w)
	_rd.buffer_update(_flow_command_buffer, 0, bytes.size(), bytes)


func _impulse_texel_rect(bounds_min: Vector2, shape: Vector4, trail: Vector4 = Vector4.ZERO) -> Rect2i:
	var texel_size := _texel_size()
	var radius := maxf(shape.z, 0.04)
	var ring_width := maxf(radius * 0.22, texel_size * 1.5)
	var center_width := maxf(radius * 0.42, texel_size * 1.5)
	var support := radius + maxf(ring_width, center_width) * 3.0
	var center := Vector2(shape.x, shape.y)
	var min_world := center - Vector2.ONE * support
	var max_world := center + Vector2.ONE * support
	if trail.w > 0.001 and trail.z > 0.001 and Vector2(trail.x, trail.y).length_squared() > 0.0001:
		var tail_end := center + Vector2(trail.x, trail.y).normalized() * trail.z
		min_world = min_world.min(tail_end - Vector2.ONE * support)
		max_world = max_world.max(tail_end + Vector2.ONE * support)
	var min_px := Vector2i(
		clampi(floori((min_world.x - bounds_min.x) / texel_size), 0, resolution - 1),
		clampi(floori((min_world.y - bounds_min.y) / texel_size), 0, resolution - 1)
	)
	var max_px := Vector2i(
		clampi(ceili((max_world.x - bounds_min.x) / texel_size), 0, resolution - 1),
		clampi(ceili((max_world.y - bounds_min.y) / texel_size), 0, resolution - 1)
	)
	return Rect2i(min_px, max_px - min_px + Vector2i.ONE)


func _flow_obstacle_texel_rect(bounds_min: Vector2, shape: Vector4, flow: Vector4) -> Rect2i:
	var texel_size := _texel_size()
	var radius := maxf(shape.z, 0.08)
	var speed := Vector2(flow.x, flow.y).length()
	var support := radius * 5.0 + clampf(speed, 0.0, 8.0) * 0.45
	var center := Vector2(shape.x, shape.y)
	var dir := Vector2(flow.x, flow.y).normalized() if speed > 0.001 else Vector2.ZERO
	var tail_end := center + dir * support
	var min_world := (center - Vector2.ONE * support).min(tail_end - Vector2.ONE * radius * 2.0)
	var max_world := (center + Vector2.ONE * support).max(tail_end + Vector2.ONE * radius * 2.0)
	var min_px := Vector2i(
		clampi(floori((min_world.x - bounds_min.x) / texel_size), 0, resolution - 1),
		clampi(floori((min_world.y - bounds_min.y) / texel_size), 0, resolution - 1)
	)
	var max_px := Vector2i(
		clampi(ceili((max_world.x - bounds_min.x) / texel_size), 0, resolution - 1),
		clampi(ceili((max_world.y - bounds_min.y) / texel_size), 0, resolution - 1)
	)
	return Rect2i(min_px, max_px - min_px + Vector2i.ONE)


func _cull_pending_impulses_to_atlas(bounds_min: Vector2) -> void:
	_last_culled_impulse_count = 0
	if _pending_impulses.is_empty():
		return
	var bounds_max := bounds_min + Vector2.ONE * world_size_m
	var kept: Array[Dictionary] = []
	for impulse: Dictionary in _pending_impulses:
		var shape := impulse["shape"] as Vector4
		var pad := maxf(shape.z * 2.0, _texel_size() * 4.0)
		if shape.x < bounds_min.x - pad or shape.x > bounds_max.x + pad or shape.y < bounds_min.y - pad or shape.y > bounds_max.y + pad:
			_last_culled_impulse_count += 1
			continue
		kept.append(impulse)
	_pending_impulses = kept
	_culled_impulses_total += _last_culled_impulse_count


func _cull_pending_flow_obstacles_to_atlas(bounds_min: Vector2) -> void:
	_last_culled_flow_obstacle_count = 0
	if _pending_flow_obstacles.is_empty():
		return
	var bounds_max := bounds_min + Vector2.ONE * world_size_m
	var kept: Array[Dictionary] = []
	for obstacle: Dictionary in _pending_flow_obstacles:
		var shape := obstacle["shape"] as Vector4
		var pad := maxf(shape.z * 6.0, _texel_size() * 8.0)
		if shape.x < bounds_min.x - pad or shape.x > bounds_max.x + pad or shape.y < bounds_min.y - pad or shape.y > bounds_max.y + pad:
			_last_culled_flow_obstacle_count += 1
			continue
		kept.append(obstacle)
	_pending_flow_obstacles = kept
	_culled_flow_obstacles_total += _last_culled_flow_obstacle_count


func _active_water_body_atlas_texture() -> RID:
	return _water_body_atlas_rid if _water_body_atlas_available and _water_body_atlas_rid.is_valid() else _fallback_water_body_atlas


func _refresh_gpu_timing() -> void:
	if _rd == null:
		return
	var frame := _rd.get_captured_timestamps_frame()
	if frame == _last_timestamp_frame:
		return
	_last_timestamp_frame = frame
	var pending_begin := -1
	var count := _rd.get_captured_timestamps_count()
	for i in range(count):
		var marker := _rd.get_captured_timestamp_name(i)
		if marker == TIMESTAMP_BEGIN:
			pending_begin = _rd.get_captured_timestamp_gpu_time(i)
		elif marker == TIMESTAMP_END and pending_begin >= 0:
			var gpu_ms := float(_rd.get_captured_timestamp_gpu_time(i) - pending_begin) / 1000000.0
			if gpu_ms >= 0.0 and gpu_ms <= 100.0:
				_last_gpu_ms = gpu_ms
			pending_begin = -1


func _current_texture() -> RID:
	return _texture_a if _front_index == 0 else _texture_b


func _current_flow_texture() -> RID:
	return _flow_texture_a if _front_index == 0 else _flow_texture_b


func _texel_size() -> float:
	return maxf(world_size_m / float(maxi(resolution, 1)), 0.001)
