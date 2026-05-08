## OceanPhysicsEvaluator — CPU-side FFT-synced wave evaluation for buoyancy
## Extracts top-K spectral components from the same JONSWAP spectrum used by
## the GPU FFT pipeline, then evaluates at query points via truncated DFT sum.
## Sea of Thieves approach: same math on CPU and GPU, no GPU readback needed.
##
## Usage:
##   evaluator.init_from_cascades(cascade_params, map_size, seed)
##   var h := evaluator.get_height(world_pos, time)
##   var d := evaluator.get_displacement(world_pos, time)
##   var n := evaluator.get_normal(world_pos, time)
class_name OceanPhysicsEvaluator

const G := 9.81
const TAU_CONST := TAU  # 2*PI
const MAX_COMPONENTS := 256

# Extracted spectral components (packed for fast iteration)
var _amplitudes: PackedFloat32Array     # amplitude per component
var _kx: PackedFloat32Array             # wave vector x
var _kz: PackedFloat32Array             # wave vector z
var _omega: PackedFloat32Array          # angular frequency
var _phase: PackedFloat32Array          # initial phase (from spectrum)
var _k_mag: PackedFloat32Array          # |k| per component (precomputed)
var _component_count: int = 0

# Per-cascade displacement scale for proper weighting
var _cascade_disp_scales: PackedFloat32Array


## Initialize from the same cascade parameters used by the GPU FFT pipeline.
## Generates JONSWAP spectrum on CPU, extracts top-K components by energy.
func init_from_cascades(cascades: Array[WaveCascadeParameters], map_size: int) -> void:
	# Collect all spectral components across all cascades
	var all_amplitudes: PackedFloat32Array = []
	var all_kx: PackedFloat32Array = []
	var all_kz: PackedFloat32Array = []
	var all_omega: PackedFloat32Array = []
	var all_phase: PackedFloat32Array = []
	var all_energy: PackedFloat32Array = []  # for sorting

	for cascade_idx: int in cascades.size():
		var params: WaveCascadeParameters = cascades[cascade_idx]
		var alpha: float = _jonswap_alpha(params.wind_speed, params.fetch_length * 1e3)
		var omega_p: float = _jonswap_peak_frequency(params.wind_speed, params.fetch_length * 1e3)
		var wind_rad: float = deg_to_rad(params.wind_direction)
		var dk: Vector2 = TAU_CONST * Vector2.ONE / params.tile_length
		var seed: Vector2i = params.spectrum_seed
		var disp_scale: float = params.displacement_scale

		# Sample the spectrum grid (same as GPU spectrum_compute.glsl)
		var half: int = map_size / 2
		for iy: int in range(map_size):
			for ix: int in range(map_size):
				var kx_val: float = float(ix - half) * dk.x
				var kz_val: float = float(iy - half) * dk.y
				var k: float = sqrt(kx_val * kx_val + kz_val * kz_val)
				if k < 1e-6:
					continue

				var theta: float = atan2(kx_val, kz_val)

				# Dispersion relation (same as GPU)
				var disp: Vector2 = _dispersion_relation(k)
				var w: float = disp.x
				var dw_dk: float = disp.y
				var w_norm: float = dw_dk / k * dk.x * dk.y

				# TMA/JONSWAP spectrum
				var s: float = _tma_spectrum(w, omega_p, alpha)

				# Directional spreading
				var d: float = lerpf(
					0.5 / PI,
					_hasselmann_spread(w, omega_p, params.wind_speed, theta, wind_rad, params.swell),
					1.0 - params.spread
				) * exp(-(1.0 - params.detail) * (1.0 - params.detail) * k * k)

				# Amplitude = sqrt(2 * S * D * w_norm) * displacement_scale
				var amplitude: float = sqrt(maxf(2.0 * s * d * w_norm, 0.0)) * disp_scale
				var energy: float = amplitude * amplitude

				if energy < 1e-12:
					continue

				# Phase from hash (must match GPU's hash function)
				var h: Vector2 = _hash(Vector2i(ix, iy) + seed)
				var gauss: Vector2 = _box_muller(h)
				# The GPU multiplies gaussian * sqrt(2*S*D*w_norm), giving complex amplitude.
				# For our real-valued sum, we use |gaussian| * amplitude as effective amplitude
				# and atan2(gaussian.y, gaussian.x) as phase offset.
				var gauss_mag: float = sqrt(gauss.x * gauss.x + gauss.y * gauss.y)
				var gauss_phase: float = atan2(gauss.y, gauss.x)

				all_amplitudes.append(amplitude * gauss_mag)
				all_kx.append(kx_val)
				all_kz.append(kz_val)
				all_omega.append(w)
				all_phase.append(gauss_phase)
				all_energy.append(energy * gauss_mag * gauss_mag)

	# Sort by energy (descending) and keep top MAX_COMPONENTS
	var count: int = all_amplitudes.size()
	if count == 0:
		_component_count = 0
		Log.warn("water", "OceanPhysicsEvaluator: No spectral components extracted!")
		return

	# Build index array for sorting
	var indices: PackedInt32Array = []
	indices.resize(count)
	for i: int in count:
		indices[i] = i

	# Sort indices by energy (descending) — simple selection of top-K
	# For large arrays, partial sort is more efficient but this runs once at init
	indices.sort()  # Default sort — we'll use a manual top-K selection instead

	# Manual top-K: find the K largest energy values
	var keep_count: int = mini(MAX_COMPONENTS, count)
	var top_indices: PackedInt32Array = []
	top_indices.resize(keep_count)

	# Copy energy for in-place selection
	var energy_copy: PackedFloat32Array = all_energy.duplicate()
	for k_idx: int in keep_count:
		var max_e: float = -1.0
		var max_i: int = 0
		for j: int in count:
			if energy_copy[j] > max_e:
				max_e = energy_copy[j]
				max_i = j
		top_indices[k_idx] = max_i
		energy_copy[max_i] = -1.0  # Mark as taken

	# Pack into final arrays
	_amplitudes = PackedFloat32Array()
	_kx = PackedFloat32Array()
	_kz = PackedFloat32Array()
	_omega = PackedFloat32Array()
	_phase = PackedFloat32Array()
	_k_mag = PackedFloat32Array()
	_amplitudes.resize(keep_count)
	_kx.resize(keep_count)
	_kz.resize(keep_count)
	_omega.resize(keep_count)
	_phase.resize(keep_count)
	_k_mag.resize(keep_count)

	var total_energy: float = 0.0
	for i: int in keep_count:
		var idx: int = top_indices[i]
		_amplitudes[i] = all_amplitudes[idx]
		_kx[i] = all_kx[idx]
		_kz[i] = all_kz[idx]
		_omega[i] = all_omega[idx]
		_phase[i] = all_phase[idx]
		_k_mag[i] = sqrt(all_kx[idx] * all_kx[idx] + all_kz[idx] * all_kz[idx])
		total_energy += all_energy[idx]

	_component_count = keep_count

	# Report energy capture
	var full_energy: float = 0.0
	for e: float in all_energy:
		full_energy += e
	var capture_pct: float = (total_energy / maxf(full_energy, 1e-10)) * 100.0

	Log.info("water", "OceanPhysicsEvaluator: Extracted %d/%d components (%.1f%% energy captured)" % [
		keep_count, count, capture_pct])


## Get wave height (Y displacement) at a world position.
func get_height(world_pos: Vector3, time: float, shore_factor: float = 1.0) -> float:
	if _component_count == 0:
		return 0.0

	var h: float = 0.0
	var wx: float = world_pos.x
	var wz: float = world_pos.z

	for i: int in _component_count:
		var p: float = _kx[i] * wx + _kz[i] * wz - _omega[i] * time + _phase[i]
		h += _amplitudes[i] * cos(p)

	return h * shore_factor


## Get full 3D displacement (horizontal + vertical).
func get_displacement(world_pos: Vector3, time: float, shore_factor: float = 1.0) -> Vector3:
	if _component_count == 0:
		return Vector3.ZERO

	var dx: float = 0.0
	var dy: float = 0.0
	var dz: float = 0.0
	var wx: float = world_pos.x
	var wz: float = world_pos.z

	for i: int in _component_count:
		var p: float = _kx[i] * wx + _kz[i] * wz - _omega[i] * time + _phase[i]
		var cos_p: float = cos(p)
		var sin_p: float = sin(p)
		var a: float = _amplitudes[i]
		var k: float = _k_mag[i]

		dy += a * cos_p
		if k > 0.001:
			var inv_k: float = a / k
			dx -= _kx[i] * inv_k * sin_p
			dz -= _kz[i] * inv_k * sin_p

	return Vector3(dx, dy, dz) * shore_factor


## Get analytical surface normal at a world position.
func get_normal(world_pos: Vector3, time: float, shore_factor: float = 1.0) -> Vector3:
	if _component_count == 0:
		return Vector3.UP

	var nx: float = 0.0
	var nz: float = 0.0
	var wx: float = world_pos.x
	var wz: float = world_pos.z

	for i: int in _component_count:
		var p: float = _kx[i] * wx + _kz[i] * wz - _omega[i] * time + _phase[i]
		var sin_p: float = sin(p)
		var a: float = _amplitudes[i]
		nx += _kx[i] * a * sin_p
		nz += _kz[i] * a * sin_p

	nx *= shore_factor
	nz *= shore_factor
	return Vector3(-nx, 1.0, -nz).normalized()


# ==========================================================================
# JONSWAP / TMA spectrum (matches GPU spectrum_compute.glsl exactly)
# ==========================================================================

## JONSWAP alpha parameter
static func _jonswap_alpha(wind_speed: float, fetch: float) -> float:
	return 0.076 * pow(wind_speed * wind_speed / (fetch * G), 0.22)


## JONSWAP peak angular frequency
static func _jonswap_peak_frequency(wind_speed: float, fetch: float) -> float:
	return 22.0 * pow(G * G / (wind_speed * fetch), 1.0 / 3.0)


## Dispersion relation: returns (omega, d_omega/dk)
static func _dispersion_relation(k: float) -> Vector2:
	const DEPTH := 20.0
	var a: float = k * DEPTH
	var b: float = tanh(a)
	var omega: float = sqrt(G * k * b)
	var d_omega: float = 0.5 * G * (b + a * (1.0 - b * b)) / omega
	return Vector2(omega, d_omega)


## TMA spectrum (JONSWAP + Kitaigorodskii depth attenuation)
static func _tma_spectrum(w: float, w_p: float, alpha: float) -> float:
	const DEPTH := 20.0
	const BETA := 1.25
	const GAMMA := 3.3

	var sigma: float = 0.07 if w <= w_p else 0.09
	var r: float = exp(-(w - w_p) * (w - w_p) / (2.0 * sigma * sigma * w_p * w_p))
	var jonswap: float = (alpha * G * G) / pow(w, 5) * exp(-BETA * pow(w_p / w, 4)) * pow(GAMMA, r)

	var w_h: float = minf(w * sqrt(DEPTH / G), 2.0)
	var depth_atten: float
	if w_h <= 1.0:
		depth_atten = 0.5 * w_h * w_h
	else:
		depth_atten = 1.0 - 0.5 * (2.0 - w_h) * (2.0 - w_h)

	return jonswap * depth_atten


## Longuet-Higgins normalization factor
static func _longuet_higgins_norm(s: float) -> float:
	var a: float = sqrt(s)
	if s < 0.4:
		return (0.5 / PI) + s * (0.220636 + s * (-0.109 + s * 0.090))
	return (1.0 / sqrt(PI)) * (a * 0.5 + (1.0 / a) * 0.0625)


## Hasselmann directional spreading
static func _hasselmann_spread(w: float, w_p: float, wind_spd: float, theta: float, wind_angle: float, swell_param: float) -> float:
	var p: float = w / w_p
	var s: float
	if w <= w_p:
		s = 6.97 * pow(absf(p), 4.06)
	else:
		s = 9.77 * pow(absf(p), -2.33 - 1.45 * (wind_spd * w_p / G - 1.17))

	var s_xi: float = 16.0 * tanh(w_p / w) * swell_param * swell_param
	var cos_half: float = cos((theta - wind_angle) * 0.5)
	return _longuet_higgins_norm(s + s_xi) * pow(absf(cos_half), 2.0 * (s + s_xi))


## Hash function matching GPU (uint32 operations emulated via wrapping)
static func _hash(x: Vector2i) -> Vector2:
	# Emulate GPU's uint32 hash — use wrapi to simulate 32-bit overflow
	var h32: int = wrapi(x.y + 374761393 + x.x * 3266489917, -2147483648, 2147483647)
	h32 = wrapi(2246822519 * (h32 ^ (h32 >> 15)), -2147483648, 2147483647)
	h32 = wrapi(3266489917 * (h32 ^ (h32 >> 13)), -2147483648, 2147483647)
	var n: int = h32 ^ (h32 >> 16)
	var n2: int = wrapi(n * 48271, -2147483648, 2147483647)
	# Convert to [0,1] range
	var r1: float = float((n >> 1) & 0x7FFFFFFF) / float(0x7FFFFFFF)
	var r2: float = float((n2 >> 1) & 0x7FFFFFFF) / float(0x7FFFFFFF)
	return Vector2(maxf(r1, 1e-10), r2)  # Clamp r1 away from 0 for log()


## Box-Muller transform: uniform [0,1] -> normal distribution
static func _box_muller(uniform: Vector2) -> Vector2:
	var r: float = sqrt(-2.0 * log(uniform.x))
	var theta: float = TAU * uniform.y
	return Vector2(r * cos(theta), r * sin(theta))
