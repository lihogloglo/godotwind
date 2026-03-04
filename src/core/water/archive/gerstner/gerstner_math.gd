## GerstnerMath - CPU-side Gerstner wave evaluation
## Mirrors the GPU shader wave functions for physics sync (buoyancy, footsteps)
##
## WARNING: Wave parameters MUST stay in sync with ocean_standard.gdshader.
## If you change wave constants here, update the shader too (and vice versa).
## The shader has identical constants as W0_DF..W11_DF / W0_SS..W11_SS.
class_name GerstnerMath
extends RefCounted


## Wave definition: [direction_x, direction_z, frequency, amplitude, steepness, speed]
## 3 octaves x 4 waves = 12 waves total
## Octave 0: Swell (large, slow)
## Octave 1: Chop (medium, moderate)
## Octave 2: Ripple (small, fast)
## NOTE: static var instead of const — Godot can't evaluate PackedFloat32Array as const
static var WAVES: Array[PackedFloat32Array] = [
	# Octave 0 — Swell (wavelength ~150-250m, calm Morrowind Inner Sea)
	PackedFloat32Array([0.8, 0.6, 0.04, 1.0, 0.3, 0.8]),
	PackedFloat32Array([-0.3, 0.95, 0.035, 0.7, 0.25, 0.7]),
	PackedFloat32Array([0.5, -0.86, 0.03, 0.55, 0.2, 0.6]),
	PackedFloat32Array([-0.7, -0.7, 0.045, 0.4, 0.2, 0.75]),
	# Octave 1 — Chop (wavelength ~25-40m)
	PackedFloat32Array([0.9, 0.4, 0.18, 0.25, 0.4, 1.8]),
	PackedFloat32Array([-0.5, 0.87, 0.22, 0.2, 0.35, 2.0]),
	PackedFloat32Array([0.3, -0.95, 0.15, 0.22, 0.3, 1.6]),
	PackedFloat32Array([-0.85, -0.5, 0.2, 0.15, 0.25, 1.9]),
	# Octave 2 — Ripple (wavelength ~3-5m, close range detail)
	PackedFloat32Array([0.7, 0.7, 1.5, 0.05, 0.5, 3.5]),
	PackedFloat32Array([-0.6, 0.8, 1.8, 0.04, 0.45, 4.0]),
	PackedFloat32Array([0.4, -0.9, 1.2, 0.045, 0.4, 3.2]),
	PackedFloat32Array([-0.9, -0.4, 1.6, 0.03, 0.35, 3.8]),
]

## Number of waves per octave
const WAVES_PER_OCTAVE: int = 4

## Octave distance fade thresholds — MUST match shader constants
## SWELL_FADE = 5000.0, CHOP_FADE = 500.0, RIPPLE_FADE = 150.0
static var OCTAVE_FADE_DISTANCES: PackedFloat32Array = PackedFloat32Array([
	5000.0,  # Swell visible to 5km
	500.0,   # Chop visible to 500m
	150.0,   # Ripple visible to 150m
])

## Fade start multipliers — match shader smoothstep inner edges
static var OCTAVE_FADE_STARTS: PackedFloat32Array = PackedFloat32Array([
	0.8,  # Swell starts fading at 80% of max
	0.7,  # Chop starts fading at 70% of max
	0.5,  # Ripple starts fading at 50% of max
])


## Compute octave fade factor matching the shader's smoothstep logic
static func _octave_fade(dist: float, octave: int) -> float:
	var fade_end: float = OCTAVE_FADE_DISTANCES[octave]
	var fade_start: float = fade_end * OCTAVE_FADE_STARTS[octave]
	if dist >= fade_end:
		return 0.0
	if dist <= fade_start:
		return 1.0
	# smoothstep(edge1, edge0, x) where edge1 > edge0 → inverted
	var t: float = (fade_end - dist) / (fade_end - fade_start)
	return t * t * (3.0 - 2.0 * t)


## Get wave height at a world position (Y-up, XZ plane)
## camera_pos: optional camera position for distance-based LOD (pass Vector3.ZERO to skip)
static func get_height(world_pos: Vector3, time: float, shore_factor: float = 1.0, camera_pos: Vector3 = Vector3.ZERO) -> float:
	var height: float = 0.0
	var dist: float = Vector2(world_pos.x - camera_pos.x, world_pos.z - camera_pos.z).length() if camera_pos != Vector3.ZERO else 0.0

	for i in range(WAVES.size()):
		# Distance LOD: skip octave if faded out
		var octave: int = i / WAVES_PER_OCTAVE
		var fade: float = _octave_fade(dist, octave) if dist > 0.0 else 1.0
		if fade <= 0.0:
			continue

		var w: PackedFloat32Array = WAVES[i]
		var dir_x: float = w[0]
		var dir_z: float = w[1]
		var freq: float = w[2]
		var amp: float = w[3]
		var speed: float = w[5]
		var phase: float = (dir_x * world_pos.x + dir_z * world_pos.z) * freq + time * speed
		height += amp * sin(phase) * fade
	return height * shore_factor


## Get displaced position (XYZ) at a world XZ coordinate
## Gerstner waves move vertices horizontally as well as vertically
static func get_displacement(world_pos: Vector3, time: float, shore_factor: float = 1.0, camera_pos: Vector3 = Vector3.ZERO) -> Vector3:
	var disp := Vector3.ZERO
	var dist: float = Vector2(world_pos.x - camera_pos.x, world_pos.z - camera_pos.z).length() if camera_pos != Vector3.ZERO else 0.0

	for i in range(WAVES.size()):
		var octave: int = i / WAVES_PER_OCTAVE
		var fade: float = _octave_fade(dist, octave) if dist > 0.0 else 1.0
		if fade <= 0.0:
			continue

		var w: PackedFloat32Array = WAVES[i]
		var dir_x: float = w[0]
		var dir_z: float = w[1]
		var freq: float = w[2]
		var amp: float = w[3]
		var steep: float = w[4]
		var speed: float = w[5]
		var phase: float = (dir_x * world_pos.x + dir_z * world_pos.z) * freq + time * speed
		var c: float = cos(phase)
		var s: float = sin(phase)
		disp.x += steep * amp * dir_x * c * fade
		disp.y += amp * s * fade
		disp.z += steep * amp * dir_z * c * fade
	return disp * shore_factor


## Get the surface normal at a world position (analytical derivative)
static func get_normal(world_pos: Vector3, time: float, shore_factor: float = 1.0, camera_pos: Vector3 = Vector3.ZERO) -> Vector3:
	var nx: float = 0.0
	var nz: float = 0.0
	var dist: float = Vector2(world_pos.x - camera_pos.x, world_pos.z - camera_pos.z).length() if camera_pos != Vector3.ZERO else 0.0

	for i in range(WAVES.size()):
		var octave: int = i / WAVES_PER_OCTAVE
		var fade: float = _octave_fade(dist, octave) if dist > 0.0 else 1.0
		if fade <= 0.0:
			continue

		var w: PackedFloat32Array = WAVES[i]
		var dir_x: float = w[0]
		var dir_z: float = w[1]
		var freq: float = w[2]
		var amp: float = w[3]
		var speed: float = w[5]
		var phase: float = (dir_x * world_pos.x + dir_z * world_pos.z) * freq + time * speed
		var c: float = cos(phase)
		nx -= dir_x * freq * amp * c * fade
		nz -= dir_z * freq * amp * c * fade
	nx *= shore_factor
	nz *= shore_factor
	return Vector3(nx, 1.0, nz).normalized()
