## BuoyancyBody3D — RigidBody3D with probe-based buoyancy physics.
## Add BuoyancyProbe3D children to define sampling points.
## Queries OceanManager's unified water surface; ocean remains the fallback body.
##
## Two modes:
## - Simple probe mode (default): each probe applies buoyancy force proportional to depth.
##   Good for crates, barrels, debris.
## - Volumetric mode (use_volumetric_cells = true): probes define cell volumes for partial
##   submersion. Good for boats, ships. Set cell_size on each probe.
##
## Forces are applied at probe positions, generating natural pitch/roll torque.
## Hydrodynamic drag dampens oscillation.
class_name BuoyancyBody3D
extends RigidBody3D

## Buoyancy force multiplier around the body's own weight.
## 1.0 = neutral support at full probe submersion, >1.0 floats higher.
@export var buoyancy_force: float = 1.25

## Depth exponent for non-linear force curve. 1.0 = linear, 1.5 = gentler near surface.
@export var buoyancy_power: float = 1.2

## Depth in meters at which a probe contributes its full buoyancy share.
@export var probe_submersion_depth: float = 1.0

## Water density in kg/m3 (1000 = freshwater, 1025 = seawater).
@export var fluid_density: float = 1025.0

## Linear drag when submerged (0-1, applied per physics frame).
@export_range(0.0, 0.5) var drag_linear: float = 0.05

## Angular drag when submerged (0-1, applied per physics frame).
@export_range(0.0, 0.5) var drag_angular: float = 0.1

## Whether to apply gravity per-probe instead of globally.
## Enable for boats where mass distribution matters (set gravity_scale = 0 on the body).
@export var distributed_gravity: bool = false

# Cached probes
var _probes: Array[BuoyancyProbe3D] = []
var _submerged_count: int = 0
var _is_submerged: bool = false


func _ready() -> void:
	_find_probes()


func _find_probes() -> void:
	_probes.clear()
	for child: Node in get_children():
		if child is BuoyancyProbe3D:
			_probes.append(child)
	if _probes.is_empty():
		Log.warn("water", "BuoyancyBody3D '%s': No BuoyancyProbe3D children found" % name)


func _physics_process(_delta: float) -> void:
	# I.5 / INTERACTION_SYSTEM.md §6.4 — frozen-body early-out guard.
	# Verified mandatory by `tests/diagnostic/frozen_rb_tick_check.tscn`:
	# Godot 4.6 ticks `_physics_process` on frozen RigidBody3Ds every
	# physics frame regardless of `freeze = true`. Without this guard,
	# every clutter item in a cell pays the full ocean wave-height
	# query each frame even though it's at rest on a table indoors.
	# With the guard, the cost collapses to one branch per frozen body.
	if freeze:
		return
	if not OceanManager:
		return
	if _probes.is_empty():
		return
	var water_state: WaterSurfaceState = OceanManager.get_water_surface_state()
	if water_state == null or not water_state.can_sample_height():
		return

	var gravity_vec: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3.DOWN)
	var gravity_mag: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var gravity: Vector3 = gravity_vec * gravity_mag

	_submerged_count = 0
	_is_submerged = false
	var water_velocity_sum := Vector3.ZERO

	for probe: BuoyancyProbe3D in _probes:
		var probe_pos: Vector3 = probe.global_position
		var wave_height: float = water_state.sample_height(probe_pos, -INF)
		if wave_height <= -INF * 0.5:
			probe.depth = -INF
			probe.is_submerged = false
			continue
		var depth: float = wave_height - probe_pos.y

		probe.depth = depth
		probe.is_submerged = depth > 0.0

		if depth > 0.0:
			_is_submerged = true
			_submerged_count += 1
			water_velocity_sum += water_state.sample_base_velocity(probe_pos, Vector3.ZERO)

			# Weight-relative Archimedes approximation. The previous depth * density
			# scalar produced huge forces for small props once apply_force() was no
			# longer incorrectly delta-scaled.
			var probe_weight: float = gravity_mag * mass / float(_probes.size())
			var submersion: float = clampf(depth / maxf(probe_submersion_depth, 0.001), 0.0, 1.0)
			var density_scale: float = fluid_density / 1025.0
			var force_mag: float = probe_weight * buoyancy_force * density_scale * pow(submersion, buoyancy_power) * probe.buoyancy_multiplier

			# Buoyancy force opposes gravity
			var buoyancy: Vector3 = -gravity.normalized() * force_mag

			# Apply at probe position (generates torque around center of mass)
			var force_offset: Vector3 = probe_pos - global_position
			apply_force(buoyancy, force_offset)

			# Per-probe gravity if distributed mode
			if distributed_gravity:
				var probe_gravity: Vector3 = gravity * (mass / float(_probes.size()))
				apply_force(probe_gravity, force_offset)

	# Hydrodynamic drag when submerged
	if _is_submerged:
		var submersion_ratio: float = float(_submerged_count) / float(_probes.size())
		var average_water_velocity := water_velocity_sum / float(maxi(_submerged_count, 1))
		var relative_velocity := linear_velocity - average_water_velocity
		relative_velocity *= 1.0 - drag_linear * submersion_ratio
		linear_velocity = average_water_velocity + relative_velocity
		angular_velocity *= 1.0 - drag_angular * submersion_ratio


## Number of probes currently submerged.
func get_submerged_count() -> int:
	return _submerged_count


## Whether any probe is submerged.
func is_submerged() -> bool:
	return _is_submerged
