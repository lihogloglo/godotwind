## BuoyancyBody3D — RigidBody3D with probe-based buoyancy physics.
## Add BuoyancyProbe3D children to define sampling points.
## Queries OceanManager for wave heights via GPU readback (exact match with visual).
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

## Buoyancy force multiplier (higher = floats more aggressively).
@export var buoyancy_force: float = 10.0

## Depth exponent for non-linear force curve. 1.0 = linear, 1.5 = gentler near surface.
@export var buoyancy_power: float = 1.5

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


func _physics_process(delta: float) -> void:
	if not OceanManager or not OceanManager.is_initialized():
		return
	if _probes.is_empty():
		return

	var gravity_vec: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3.DOWN)
	var gravity_mag: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var gravity: Vector3 = gravity_vec * gravity_mag

	_submerged_count = 0
	_is_submerged = false

	for probe: BuoyancyProbe3D in _probes:
		var probe_pos: Vector3 = probe.global_position
		var wave_height: float = OceanManager.get_wave_height(probe_pos)
		var depth: float = wave_height - probe_pos.y

		probe.depth = depth
		probe.is_submerged = depth > 0.0

		if depth > 0.0:
			_is_submerged = true
			_submerged_count += 1

			# Non-linear buoyancy: gentler near surface, stronger when deep
			var force_mag: float = pow(absf(depth), buoyancy_power) * buoyancy_force * probe.buoyancy_multiplier

			# Buoyancy force opposes gravity
			var buoyancy: Vector3 = -gravity.normalized() * force_mag * fluid_density * delta

			# Apply at probe position (generates torque around center of mass)
			var force_offset: Vector3 = probe_pos - global_position
			apply_force(buoyancy, force_offset)

			# Per-probe gravity if distributed mode
			if distributed_gravity:
				var probe_gravity: Vector3 = gravity * (mass / float(_probes.size())) * delta
				apply_force(probe_gravity, force_offset)

	# Hydrodynamic drag when submerged
	if _is_submerged:
		var submersion_ratio: float = float(_submerged_count) / float(_probes.size())
		linear_velocity *= 1.0 - drag_linear * submersion_ratio
		angular_velocity *= 1.0 - drag_angular * submersion_ratio


## Number of probes currently submerged.
func get_submerged_count() -> int:
	return _submerged_count


## Whether any probe is submerged.
func is_submerged() -> bool:
	return _is_submerged
